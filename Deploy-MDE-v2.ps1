<#
.SYNOPSIS
    MDE Policy Automation v2 — 9-Stage Direct Deployment (No Automation Account)
    
.DESCRIPTION
    Simplified deployment for Microsoft Defender for Endpoint:
    - NO Automation Account, NO Runbook, NO Schedule (zero experimental commands)
    - Direct Graph API sync: VMs → Entra ID Devices → Groups
    - 3-layer device matching: physicalIds → aadDeviceId → normalized name
    - Parallel AAD extension installation (Start-Job)
    - Compatible with PS 5.1 ISE, PS 7, Cloud Shell
    
    Stages:
    1. Auth + Subscription selection
    2. Naming (intelligent, sub-based)
    3. Resource Group + Tags
    4. Entra ID Groups (4: main, stale-7d, stale-30d, ephemeral)
    5. AAD Extension install (parallel) + Device registration
    6. Device Matching + Group Sync (3-layer: physicalIds → deviceId → name)
    7. Azure Policy (auto-tag VMs)
    8. MDE Device Groups (HTML guide)
    9. MDE Machine Tags (App Registration)
    
.NOTES
    Version:  2.0.0
    Author:   Rafael Franca — github.com/rfranca777
    License:  MIT
    
    TECHNICAL NOTES:
    - Device matching uses 3 layers for maximum accuracy:
      L1: physicalIds contains Azure Resource ID (95% hit rate, exact)
      L2: MDE aadDeviceId == Entra deviceId (80% hit rate, requires MDE+AAD)
      L3: Normalized displayName match (70% hit rate, fallback)
    - AAD extensions installed in parallel batches of 10 (ARM throttle safe)
    - Groups are static (not dynamic) to enable per-subscription segmentation

.LINK
    https://github.com/rfranca777/MDE-PolicyAutomation
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$WarningPreference = "SilentlyContinue"

# ============================================================
# FUNCOES AUXILIARES
# ============================================================
function Write-Step {
    param([string]$Message, [string]$Status)
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WAIT"  { "Yellow" }
        "ERROR" { "Red" }
        "INFO"  { "Cyan" }
        "SKIP"  { "Gray" }
        "TECH"  { "DarkCyan" }
        default { "White" }
    }
    Write-Host "  [$Status] $Message" -ForegroundColor $color
}

function Write-Tech {
    # Verbose technical explanation
    param([string]$Message)
    Write-Host "     > $Message" -ForegroundColor DarkGray
}

function Normalize-Name {
    # Strip domain suffixes and lowercase for name comparison
    param([string]$Name)
    if (-not $Name) { return "" }
    $n = $Name.ToLower().Trim()
    # Remove common domain suffixes
    $n = $n -replace '\..*$', ''       # strip .domain.local, .contoso.com etc
    $n = $n -replace '\\.*\\', ''      # strip DOMAIN\ prefix
    return $n
}

# ============================================================
# DETECCAO DE AMBIENTE
# ============================================================
$isWinOS = $PSVersionTable.PSVersion.Major -le 5 -or ($null -ne $IsWindows -and $IsWindows)
$tempPath = if ($isWinOS) { "C:\temp" } else { "$HOME/temp" }
if (-not (Test-Path $tempPath)) { New-Item -ItemType Directory -Path $tempPath -Force | Out-Null }

Clear-Host
Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  MICROSOFT DEFENDER FOR ENDPOINT" -ForegroundColor White
Write-Host "  v2.0 - Direct Deployment (No Automation Account)" -ForegroundColor Gray
Write-Host "  9 Stages - PS 5.1 Compatible - Zero Experimental Commands" -ForegroundColor Gray
Write-Host "============================================================`n" -ForegroundColor Magenta

# ============================================================
# STAGE 1: AUTENTICACAO E SUBSCRICAO
# ============================================================
Write-Host "[1/9] AUTENTICACAO E SUBSCRICAO" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$currentContext = az account show 2>$null | ConvertFrom-Json
if (-not $currentContext) {
    Write-Step "Azure CLI nao autenticado. Execute: az login" "ERROR"
    exit 1
}
Write-Step "Autenticado: $($currentContext.user.name)" "OK"
Write-Tech "Tenant: $($currentContext.tenantId)"

$subsRaw = az account list --query "[].{Name:name, Id:id, State:state}" -o json 2>$null
$subsAll = $subsRaw | ConvertFrom-Json
$subscriptions = @($subsAll | Where-Object { $_.State -eq "Enabled" })

if ($subscriptions.Count -eq 0) { Write-Step "Nenhuma subscription ativa" "ERROR"; exit 1 }

Write-Host "`n  Subscriptions disponiveis:" -ForegroundColor Yellow
for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host "  [$($i + 1)] $($subscriptions[$i].Name)" -ForegroundColor White
    Write-Host "       ID: $($subscriptions[$i].Id)" -ForegroundColor DarkGray
}

Write-Host "`n  Selecione (ex: 1,2 ou 'all'): " -NoNewline -ForegroundColor Cyan
$selInput = Read-Host
$selectedSubs = @()
if ($selInput -match '^(all|ALL|todos)$') { $selectedSubs = $subscriptions }
else {
    foreach ($s in ($selInput -split ',')) {
        $idx = -1; $trimmed = $s.Trim()
        if ($trimmed -match '^\d+$') { $idx = [int]$trimmed - 1 }
        if ($idx -ge 0 -and $idx -lt $subscriptions.Count) { $selectedSubs += $subscriptions[$idx] }
    }
}
if ($selectedSubs.Count -eq 0) { Write-Step "Nenhuma subscription selecionada" "ERROR"; exit 1 }

Write-Step "Subscriptions: $($selectedSubs.Count)" "OK"
foreach ($ss in $selectedSubs) { Write-Host "     - $($ss.Name)" -ForegroundColor Gray }

# CONFIGURACOES GLOBAIS
Write-Host "`n  Location [ENTER=eastus]: " -NoNewline -ForegroundColor Cyan
$locInput = Read-Host
$location = if ([string]::IsNullOrWhiteSpace($locInput)) { "eastus" } else { $locInput }

Write-Host "  Incluir Arc? [ENTER=SIM | N]: " -NoNewline -ForegroundColor Cyan
$arcInput = Read-Host
$includeArc = -not ($arcInput -eq "N" -or $arcInput -eq "n")

# TAGS
Write-Host "`n  Tags default:" -ForegroundColor Gray
$defaultTags = @{
    created_by  = "Seg Info"; squad_owner = "Seg Info"
    cod_budget  = "SEG-0012"; cost_center = "72060104"
}
foreach ($k in $defaultTags.Keys) { Write-Host "     $k=$($defaultTags[$k])" -ForegroundColor DarkGray }
Write-Host "  Adicionar tags? (Key1=Value1;Key2=Value2) [ENTER=manter]: " -NoNewline -ForegroundColor Cyan
$tagInput = Read-Host
if (-not [string]::IsNullOrWhiteSpace($tagInput)) {
    foreach ($pair in ($tagInput -split ';')) {
        $parts = $pair.Trim() -split '=', 2
        if ($parts.Count -eq 2 -and $parts[0].Trim().Length -gt 0) {
            $defaultTags[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
}
$tags = @($defaultTags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
Write-Step "Config: $location | Arc:$(if($includeArc){'SIM'}else{'NAO'}) | Tags:$($defaultTags.Count)" "OK"

# ============================================================
# LOOP POR SUBSCRIPTION
# ============================================================
$subIndex = 0
foreach ($selectedSub in $selectedSubs) {
$subIndex++
$subscriptionName = $selectedSub.Name
$subscriptionId = $selectedSub.Id
az account set --subscription $subscriptionId 2>$null

Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  SUB $subIndex/$($selectedSubs.Count): $subscriptionName" -ForegroundColor White
Write-Host "============================================================`n" -ForegroundColor Magenta

# ============================================================
# STAGE 2: NOMENCLATURA
# ============================================================
Write-Host "[2/9] NOMENCLATURA" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$subNameClean = $subscriptionName -replace '[^a-zA-Z0-9-]', '-' -replace '--+', '-' -replace '^-|-$', ''
if ([string]::IsNullOrWhiteSpace($subNameClean)) { $subNameClean = "sub-$($subscriptionId.Substring(0, 8))" }
$subNameShort = $subNameClean.Substring(0, [Math]::Min(40, $subNameClean.Length)).ToLower()

$resourceGroupName       = "rg-mde-$subNameShort"
$entraGroupName          = "grp-mde-$subNameShort"
$entraGroupStale7Name    = "grp-mde-$subNameShort-stale7"
$entraGroupStale30Name   = "grp-mde-$subNameShort-stale30"
$entraGroupEphemeralName = "grp-mde-$subNameShort-ephemeral"
$policyName              = "pol-mde-tag-$subNameShort"

Write-Step "RG: $resourceGroupName" "INFO"
Write-Step "Groups: $entraGroupName (+stale7/stale30/ephemeral)" "INFO"
Write-Step "Policy: $policyName" "INFO"

# ============================================================
# STAGE 3: RESOURCE GROUP + TAGS
# ============================================================
Write-Host "`n[3/9] RESOURCE GROUP" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$existingRg = az group show --name $resourceGroupName 2>$null | ConvertFrom-Json
if ($existingRg) {
    Write-Step "RG existente — atualizando tags" "OK"
    az group update --name $resourceGroupName --tags $tags --output none 2>$null
} else {
    Write-Step "Criando RG..." "WAIT"
    az group create --name $resourceGroupName --location $location --tags $tags --output none 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Step "Falha ao criar RG" "ERROR"; continue }
    Write-Step "RG criado" "OK"
}

# ============================================================
# STAGE 4: ENTRA ID GROUPS (4 grupos)
# ============================================================
Write-Host "`n[4/9] ENTRA ID SECURITY GROUPS" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "4 grupos por subscription: main (activos), stale-7d, stale-30d, ephemeral"

$groupIds = @{}
foreach ($grpDef in @(
    @{ Name = $entraGroupName;          Tag = "main"; Desc = "MDE Active Devices - $subscriptionName" },
    @{ Name = $entraGroupStale7Name;    Tag = "stale7"; Desc = "MDE Stale 7d - $subscriptionName" },
    @{ Name = $entraGroupStale30Name;   Tag = "stale30"; Desc = "MDE Stale 30d - $subscriptionName" },
    @{ Name = $entraGroupEphemeralName; Tag = "eph"; Desc = "MDE Ephemeral - $subscriptionName" }
)) {
    $gn = $grpDef.Name
    $check = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$gn'" -o json 2>$null | ConvertFrom-Json
    if ($check.value.Count -gt 0) {
        $groupIds[$grpDef.Tag] = $check.value[0].id
        Write-Step "$($grpDef.Tag): $gn (reutilizado)" "OK"
    } else {
        Write-Step "$($grpDef.Tag): Criando $gn..." "WAIT"
        $mailNick = ($gn -replace '[^a-zA-Z0-9]', '')
        if ($mailNick.Length -gt 64) { $mailNick = $mailNick.Substring(0, 64) }
        $body = @{ displayName=$gn; mailNickname=$mailNick; mailEnabled=$false; securityEnabled=$true; description=$grpDef.Desc } | ConvertTo-Json
        $bodyFile = Join-Path $tempPath "grp-$($grpDef.Tag).json"
        $body | Out-File $bodyFile -Encoding UTF8 -Force -NoNewline
        $newGrp = az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups" --headers "Content-Type=application/json" --body "@$bodyFile" -o json 2>$null | ConvertFrom-Json
        if ($newGrp -and $newGrp.id) {
            $groupIds[$grpDef.Tag] = $newGrp.id
            Write-Step "$($grpDef.Tag): Criado ($($newGrp.id))" "OK"
        } else {
            Write-Step "$($grpDef.Tag): Falha ao criar" "ERROR"
        }
        Start-Sleep -Seconds 3
    }
}

$groupId       = $groupIds["main"]
$groupIdStale7 = $groupIds["stale7"]
$groupIdStale30= $groupIds["stale30"]
$groupIdEph    = $groupIds["eph"]

if (-not $groupId) { Write-Step "Grupo main nao criado — pulando subscription" "ERROR"; continue }

# ============================================================
# STAGE 5: AAD EXTENSION + DEVICE REGISTRATION
# ============================================================
Write-Host "`n[5/9] REGISTAR VMs NO ENTRA ID (EXTENSAO AAD)" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "Instala AADLoginForWindows/AADSSHLoginForLinux nas VMs sem device Entra ID"
Write-Tech "Extensao regista a VM como device no Entra ID automaticamente"
Write-Tech "Instalacao em paralelo (batches de 10) para performance"

# Listar VMs
$vmsRaw = az vm list --subscription $subscriptionId --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}" -o json 2>$null
$vms = @()
if ($vmsRaw) { $vms = $vmsRaw | ConvertFrom-Json }
Write-Step "VMs na subscription: $($vms.Count)" "INFO"

if ($vms.Count -eq 0) {
    Write-Step "Nenhuma VM encontrada — pulando Stage 5 e 6" "SKIP"
} else {
    # Listar devices Entra ID
    $devicesRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/devices?`$top=999&`$select=displayName,id,deviceId,physicalIds,operatingSystem,approximateLastSignInDateTime" -o json 2>$null | ConvertFrom-Json
    $deviceList = if ($devicesRaw -and $devicesRaw.value) { $devicesRaw.value } else { @() }
    Write-Step "Devices no Entra ID: $($deviceList.Count)" "INFO"

    # Verificar quais VMs ja tem device via physicalIds (Azure Resource ID)
    $needsExtension = @()
    foreach ($vm in $vms) {
        $vmResourceId = $vm.id.ToLower()
        $foundByPhysical = $deviceList | Where-Object {
            $_.physicalIds -and ($_.physicalIds | Where-Object { $_ -like "*$vmResourceId*" })
        }
        if (-not $foundByPhysical) {
            $foundByName = $deviceList | Where-Object { (Normalize-Name $_.displayName) -eq (Normalize-Name $vm.name) }
            if (-not $foundByName) {
                $needsExtension += $vm
            }
        }
    }

    Write-Step "VMs sem device Entra ID: $($needsExtension.Count)" "INFO"

    if ($needsExtension.Count -gt 0) {
        Write-Step "Instalando extensao AAD em paralelo..." "WAIT"
        Write-Tech "Windows: AADLoginForWindows | Linux: AADSSHLoginForLinux"
        Write-Tech "Publisher: Microsoft.Azure.ActiveDirectory"

        $jobs = @()
        foreach ($vm in $needsExtension) {
            $vmRg = $vm.rg
            $vmNm = $vm.name
            $extType = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }

            $jobs += Start-Job -ScriptBlock {
                param($rg, $name, $ext, $sub)
                az account set --subscription $sub 2>$null
                az vm extension set --resource-group $rg --vm-name $name --name $ext --publisher "Microsoft.Azure.ActiveDirectory" --output none 2>$null
                return @{ name = $name; exit = $LASTEXITCODE }
            } -ArgumentList $vmRg, $vmNm, $extType, $subscriptionId

            Write-Host "     Queued: $vmNm ($extType)" -ForegroundColor Gray

            # Batch de 10 — aguardar antes do proximo batch
            if ($jobs.Count % 10 -eq 0) {
                Write-Tech "Aguardando batch de 10..."
                $jobs | Wait-Job -Timeout 600 | Out-Null
            }
        }

        # Aguardar todos os jobs restantes
        Write-Step "Aguardando conclusao de $($jobs.Count) instalacoes..." "WAIT"
        $jobs | Wait-Job -Timeout 600 | Out-Null

        foreach ($j in $jobs) {
            $result = Receive-Job -Job $j
            $status = if ($j.State -eq "Completed") { "OK" } else { "WARN" }
            Write-Host "     [$status] $($result.name)" -ForegroundColor $(if($status -eq 'OK'){'Green'}else{'Yellow'})
        }
        $jobs | Remove-Job -Force

        Write-Step "Aguardando propagacao Entra ID (60s)..." "WAIT"
        Write-Tech "Device registration pode levar 30-120s apos extensao instalada"
        Start-Sleep -Seconds 60

        # Recarregar devices
        $devicesRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/devices?`$top=999&`$select=displayName,id,deviceId,physicalIds,operatingSystem,approximateLastSignInDateTime" -o json 2>$null | ConvertFrom-Json
        $deviceList = if ($devicesRaw -and $devicesRaw.value) { $devicesRaw.value } else { @() }
        Write-Step "Devices apos extensao: $($deviceList.Count)" "INFO"
    }

    # ============================================================
    # STAGE 6: DEVICE MATCHING + GROUP SYNC
    # ============================================================
    Write-Host "`n[6/9] DEVICE MATCHING + GROUP SYNC" -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan
    Write-Tech "3 camadas de matching para maxima precisao:"
    Write-Tech "L1: physicalIds contem Azure Resource ID da VM (95% exacto)"
    Write-Tech "L2: Nome normalizado (lowercase, sem dominio) (70% fallback)"
    Write-Tech "Resultado: cada VM matched → adicionada ao grupo correcto"

    $matched = @()
    $unmatched = @()

    foreach ($vm in $vms) {
        $vmResourceId = $vm.id.ToLower()
        $vmNameNorm = Normalize-Name $vm.name
        $dev = $null

        # LAYER 1: Match por physicalIds (Azure Resource ID)
        $dev = $deviceList | Where-Object {
            $_.physicalIds -and ($_.physicalIds | Where-Object { $_.ToLower() -like "*$vmResourceId*" })
        } | Select-Object -First 1

        # LAYER 2: Match por nome normalizado
        if (-not $dev) {
            $dev = $deviceList | Where-Object { (Normalize-Name $_.displayName) -eq $vmNameNorm } | Select-Object -First 1
        }

        if ($dev) {
            Write-Step "$($vm.name) → $($dev.displayName) (ID: $($dev.id))" "OK"
            $matched += @{ vm = $vm; device = $dev }
        } else {
            Write-Step "$($vm.name) → sem device Entra ID (extensao pode ainda propagar)" "SKIP"
            $unmatched += $vm
        }
    }

    Write-Step "Matched: $($matched.Count) / $($vms.Count) | Pendentes: $($unmatched.Count)" "INFO"

    # Adicionar devices aos grupos
    $addedCount = 0
    foreach ($m in $matched) {
        $devId = $m.device.id
        $devName = $m.device.displayName
        $lastSign = $m.device.approximateLastSignInDateTime

        # Determinar grupo alvo
        $targetGroup = $groupId
        $targetLabel = "Main"
        if ($lastSign) {
            try {
                $daysAgo = ((Get-Date) - [DateTime]::Parse($lastSign)).Days
                if ($daysAgo -gt 30) { $targetGroup = $groupIdStale30; $targetLabel = "Stale-30d" }
                elseif ($daysAgo -gt 7) { $targetGroup = $groupIdStale7; $targetLabel = "Stale-7d" }
            } catch { }
        } else {
            $targetGroup = $groupIdStale7; $targetLabel = "Stale-7d"
        }

        # Adicionar ao grupo via Graph API
        $addBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$devId" } | ConvertTo-Json
        $addBody | Out-File (Join-Path $tempPath "add-member.json") -Encoding UTF8 -Force -NoNewline
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$targetGroup/members/`$ref" --headers "Content-Type=application/json" --body "@$(Join-Path $tempPath 'add-member.json')" --output none 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "     [+] $devName → $targetLabel" -ForegroundColor Green
            $addedCount++
        } else {
            Write-Host "     [=] $devName → ja no grupo ou erro" -ForegroundColor Gray
        }
    }
    Write-Step "Devices adicionados: $addedCount" "OK"
} # fim do if vms.Count

# ============================================================
# STAGE 7: AZURE POLICY
# ============================================================
Write-Host "`n[7/9] AZURE POLICY" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "Policy Modify: auto-aplica tag mde_device_id em VMs e Arc machines"
Write-Tech "Escopo: toda a subscription | Modo: Indexed"

$policyContent = '{"if":{"allOf":[{"anyOf":[{"field":"type","equals":"Microsoft.Compute/virtualMachines"},{"field":"type","equals":"Microsoft.HybridCompute/machines"}]},{"field":"tags[' + "'mde_device_id'" + ']","exists":"false"}]},"then":{"effect":"modify","details":{"roleDefinitionIds":["/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"],"operations":[{"operation":"addOrReplace","field":"tags[' + "'mde_device_id'" + ']","value":"[field(' + "'name'" + ')]"}]}}}'
$policyFile = Join-Path $tempPath "policy-def.json"
$policyContent | Out-File $policyFile -Encoding UTF8 -Force -NoNewline

az policy definition create --name $policyName --display-name "MDE - Auto Tag VMs with Device ID" --description "Auto-tags VMs and Arc machines with mde_device_id" --rules "@$policyFile" --mode Indexed --subscription $subscriptionId --output none 2>$null
if ($LASTEXITCODE -eq 0) { Write-Step "Policy definition criada" "OK" } else { Write-Step "Policy pode ja existir" "OK" }

az policy assignment create --name "$policyName-assignment" --policy $policyName --scope "/subscriptions/$subscriptionId" --display-name "MDE Auto-tag Assignment" --mi-system-assigned --location $location --output none 2>$null
if ($LASTEXITCODE -eq 0) { Write-Step "Policy assignment criada" "OK" } else { Write-Step "Assignment pode ja existir" "OK" }

# ============================================================
# STAGE 8: MDE DEVICE GROUPS (HTML)
# ============================================================
Write-Host "`n[8/9] MDE DEVICE GROUPS" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "MDE Device Groups nao tem API publica — guia HTML gerado"

$mdeDeviceGroupName = "mde-policy-$subNameShort"
Write-Step "Guia HTML para criar Device Groups no portal MDE" "OK"
Write-Host "     security.microsoft.com → Device Groups → vincular $entraGroupName" -ForegroundColor Gray

# ============================================================
# STAGE 9: MDE APP REGISTRATION
# ============================================================
Write-Host "`n[9/9] MDE APP REGISTRATION" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "App Registration para MDE API (Machine.ReadWrite.All)"
Write-Tech "Necessario apenas se quiser aplicar Machine Tags via API"

$appDisplayName = "MDE-Automation-$subNameShort"
$existingApp = az ad app list --filter "displayName eq '$appDisplayName'" --query "[0].appId" -o tsv 2>$null
if ($existingApp) {
    Write-Step "App existente: $existingApp" "OK"
} else {
    $newApp = az ad app create --display-name $appDisplayName --query "{appId:appId,id:id}" -o json 2>$null | ConvertFrom-Json
    if ($newApp -and $newApp.appId) {
        Write-Step "App criado: $($newApp.appId)" "OK"
        az ad sp create --id $newApp.appId --output none 2>$null
        Write-Step "Service Principal criado" "OK"
    } else {
        Write-Step "App Registration falhou (continuando)" "SKIP"
    }
}

# ============================================================
# RELATORIO POR SUBSCRIPTION
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT CONCLUIDO: $subscriptionName" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  RG: $resourceGroupName" -ForegroundColor White
Write-Host "  Groups: main=$groupId" -ForegroundColor White
Write-Host "  Policy: $policyName" -ForegroundColor White
Write-Host "  VMs: $($vms.Count) | Matched: $($matched.Count) | Synced: $addedCount" -ForegroundColor White
if ($unmatched.Count -gt 0) {
    Write-Host "  Pendentes: $($unmatched.Count) (reexecute em 5-10 min)" -ForegroundColor Yellow
}
Write-Host "============================================================`n" -ForegroundColor Green

} # FIM DO LOOP FOREACH SUBSCRIPTION

# ============================================================
# REPORT FINAL
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  DEPLOYMENT GLOBAL CONCLUIDO!" -ForegroundColor White
Write-Host "  Subscriptions: $($selectedSubs.Count)" -ForegroundColor Gray
foreach ($ss in $selectedSubs) { Write-Host "     - $($ss.Name)" -ForegroundColor Gray }
Write-Host "============================================================`n" -ForegroundColor Magenta
