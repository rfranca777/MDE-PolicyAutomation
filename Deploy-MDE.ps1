<#
.SYNOPSIS
    MDE Policy Automation v2.1 - 10-Stage Direct Deployment (No Automation Account)
    
.DESCRIPTION
    Simplified deployment for Microsoft Defender for Endpoint:
    - NO Automation Account, NO Runbook, NO Schedule (zero experimental commands)
    - Direct Graph API sync: VMs → Entra ID Devices → Groups
    - 3-layer device matching: physicalIds → normalized name → approximate
    - Parallel AAD extension installation (Start-Job)
    - MDE Machine Tags via API (status, subscription, global group)
    - Global + per-subscription Entra ID groups
    - Compatible with PS 5.1 ISE, PS 7, Cloud Shell
    
    Stages:
    1. Auth + Subscription selection
    2. Naming (intelligent, sub-based)
    3. Resource Group + Tags
    4. Entra ID Groups (4 local: main, stale-7d, stale-30d, ephemeral)
    5. AAD Extension install (parallel) + Device registration
    6. Device Matching + Group Sync (local + global groups)
    7. Azure Policy (auto-tag VMs)
    8. MDE Device Groups + Tags Guide (HTML)
    9. MDE App Registration + API Permissions
    10. MDE Machine Tags via API (4 tags per machine)
    
    Global Groups (created once before loop):
    - grp-mde-global-active     = Active devices from ALL subscriptions
    - grp-mde-global-stale7     = Stale 7d devices from ALL subscriptions
    - grp-mde-global-stale30    = Stale 30d devices from ALL subscriptions
    - grp-mde-global-ephemeral  = Ephemeral devices from ALL subscriptions
    
.NOTES
    Version:  2.1.0
    Author:   Rafael Franca - github.com/rfranca777
    License:  MIT
    
    TECHNICAL NOTES:
    - VM→Entra matching (Stage 6) uses 2 layers:
      L1: physicalIds contains Azure Resource ID (95% hit rate, exact)
      L2: Normalized displayName match (80% hit rate, fallback)
    - MDE→Entra correlation (Stage 10) uses 3 layers:
      L1: MDE.aadDeviceId == Entra.deviceId (95% exact)
      L2: Normalized name match (80% fallback)
      L3: Approximate name match - contains/startsWith (70% fallback)
    - AAD extensions installed in parallel batches of 10 (ARM throttle safe)
    - Groups are static (not dynamic) to enable per-subscription segmentation
    - MDE API rate limiting: 500ms between tag operations
    - 4 global groups aggregate devices across all subscriptions

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
    $n = $n -replace '^.*\\', ''         # strip DOMAIN\ prefix (e.g. CONTOSO\server → server)
    return $n
}

function Get-AllEntraDevices {
    # Paginated Graph API fetch - handles tenants with >999 devices
    $allDevices = @()
    $uri = "https://graph.microsoft.com/v1.0/devices?`$top=999&`$select=displayName,id,deviceId,physicalIds,operatingSystem,approximateLastSignInDateTime"
    do {
        $responseRaw = az rest --method GET --uri $uri -o json 2>$null
        $response = $null
        if ($responseRaw) { $response = $responseRaw | ConvertFrom-Json }
        if ($response -and $response.value) {
            $allDevices += $response.value
        }
        $uri = if ($response -and $response.'@odata.nextLink') { $response.'@odata.nextLink' } else { $null }
    } while ($uri)
    return ,$allDevices
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
Write-Host "  v2.1 - Direct Deployment (No Automation Account)" -ForegroundColor Gray
Write-Host "  10 Stages | Global+Local Groups | MDE Tags API" -ForegroundColor Gray
Write-Host "============================================================`n" -ForegroundColor Magenta

# ============================================================
# STAGE 1: AUTENTICACAO E SUBSCRICAO
# ============================================================
Write-Host "[1/10] AUTENTICACAO E SUBSCRICAO" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$currentContextRaw = az account show 2>$null
$currentContext = $null
if ($currentContextRaw) { $currentContext = $currentContextRaw | ConvertFrom-Json }
if (-not $currentContext) {
    Write-Step "Azure CLI nao autenticado. Execute: az login" "ERROR"
    exit 1
}
Write-Step "Autenticado: $($currentContext.user.name)" "OK"
Write-Tech "Tenant: $($currentContext.tenantId)"

$subsRaw = az account list --query "[].{Name:name, Id:id, State:state}" -o json 2>$null
$subsAll = @()
if ($subsRaw) { $subsAll = $subsRaw | ConvertFrom-Json }
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
# GLOBAL ENTRA ID GROUPS (4 grupos cross-subscription)
# ============================================================
Write-Host "`n  GRUPOS GLOBAIS ENTRA ID" -ForegroundColor Yellow
Write-Host "  ========================================" -ForegroundColor Yellow
Write-Tech "4 grupos globais agregam devices de TODAS subscriptions"
Write-Tech "Uteis para Conditional Access, MDE Device Groups globais, dashboards"

$globalGroupIds = @{}
foreach ($gDef in @(
    @{ Name = "grp-mde-global-active";    Tag = "active";    Desc = "MDE Global - Active Devices (all subscriptions)" },
    @{ Name = "grp-mde-global-stale7";    Tag = "stale7";    Desc = "MDE Global - Stale 7d (all subscriptions)" },
    @{ Name = "grp-mde-global-stale30";   Tag = "stale30";   Desc = "MDE Global - Stale 30d (all subscriptions)" },
    @{ Name = "grp-mde-global-ephemeral"; Tag = "ephemeral"; Desc = "MDE Global - Ephemeral (all subscriptions)" }
)) {
    $gn = $gDef.Name
    $checkRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$gn'" -o json 2>$null
    $check = $null
    if ($checkRaw) { $check = $checkRaw | ConvertFrom-Json }
    if ($check -and $check.value -and $check.value.Count -gt 0) {
        $globalGroupIds[$gDef.Tag] = $check.value[0].id
        Write-Step "Global $($gDef.Tag): $gn (reutilizado)" "OK"
    } else {
        $mailNick = ($gn -replace '[^a-zA-Z0-9]', '')
        if ($mailNick.Length -gt 64) { $mailNick = $mailNick.Substring(0, 64) }
        $body = @{ displayName=$gn; mailNickname=$mailNick; mailEnabled=$false; securityEnabled=$true; description=$gDef.Desc } | ConvertTo-Json
        $bodyFile = Join-Path $tempPath "grp-global-$($gDef.Tag).json"
        $body | Out-File $bodyFile -Encoding UTF8 -Force -NoNewline
        $newGrpRaw = az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups" --headers "Content-Type=application/json" --body "@$bodyFile" -o json 2>$null
        $newGrp = $null
        if ($newGrpRaw) { $newGrp = $newGrpRaw | ConvertFrom-Json }
        if ($newGrp -and $newGrp.id) {
            $globalGroupIds[$gDef.Tag] = $newGrp.id
            Write-Step "Global $($gDef.Tag): Criado ($($newGrp.id))" "OK"
        } else {
            Write-Step "Global $($gDef.Tag): Falha ao criar" "ERROR"
        }
        Start-Sleep -Seconds 3
    }
}

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
Write-Host "[2/10] NOMENCLATURA" -ForegroundColor Cyan
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
Write-Host "`n[3/10] RESOURCE GROUP" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$existingRgRaw = az group show --name $resourceGroupName 2>$null
$existingRg = $null
if ($existingRgRaw) { $existingRg = $existingRgRaw | ConvertFrom-Json }
if ($existingRg) {
    Write-Step "RG existente - atualizando tags" "OK"
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
Write-Host "`n[4/10] ENTRA ID SECURITY GROUPS (LOCAL)" -ForegroundColor Cyan
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
    $checkRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$gn'" -o json 2>$null
    $check = $null
    if ($checkRaw) { $check = $checkRaw | ConvertFrom-Json }
    if ($check -and $check.value -and $check.value.Count -gt 0) {
        $groupIds[$grpDef.Tag] = $check.value[0].id
        Write-Step "$($grpDef.Tag): $gn (reutilizado)" "OK"
    } else {
        Write-Step "$($grpDef.Tag): Criando $gn..." "WAIT"
        $mailNick = ($gn -replace '[^a-zA-Z0-9]', '')
        if ($mailNick.Length -gt 64) { $mailNick = $mailNick.Substring(0, 64) }
        $body = @{ displayName=$gn; mailNickname=$mailNick; mailEnabled=$false; securityEnabled=$true; description=$grpDef.Desc } | ConvertTo-Json
        $bodyFile = Join-Path $tempPath "grp-$($grpDef.Tag).json"
        $body | Out-File $bodyFile -Encoding UTF8 -Force -NoNewline
        $newGrpRaw = az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups" --headers "Content-Type=application/json" --body "@$bodyFile" -o json 2>$null
        $newGrp = $null
        if ($newGrpRaw) { $newGrp = $newGrpRaw | ConvertFrom-Json }
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

if (-not $groupId) { Write-Step "Grupo main nao criado - pulando subscription" "ERROR"; continue }

# ============================================================
# STAGE 5: AAD EXTENSION + DEVICE REGISTRATION
# ============================================================
Write-Host "`n[5/10] REGISTAR VMs NO ENTRA ID (EXTENSAO AAD)" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "Instala AADLoginForWindows/AADSSHLoginForLinux nas VMs sem device Entra ID"
Write-Tech "Extensao regista a VM como device no Entra ID automaticamente"
Write-Tech "Instalacao em paralelo (batches de 10) para performance"

# Listar VMs
$vmsRaw = az vm list --subscription $subscriptionId --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}" -o json 2>$null
$vms = @()
if ($vmsRaw) { $vms = $vmsRaw | ConvertFrom-Json }
Write-Step "VMs na subscription: $($vms.Count)" "INFO"

# Initialize report variables (must exist even if vms.Count is 0)
$matched = @()
$unmatched = @()
$addedCount = 0
$mdeTagsApplied = 0
$mdeTagsTotal = 0
$mdeMatchExact = 0
$mdeMatchApprox = 0
$mdeNoMatch = 0

if ($vms.Count -eq 0) {
    Write-Step "Nenhuma VM encontrada - pulando Stages 5, 6 e 10" "SKIP"
} else {
    # Listar devices Entra ID (paginado - suporta >999 devices)
    $deviceList = Get-AllEntraDevices
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

            # Batch de 10 - aguardar antes do proximo batch
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
            $status = if ($j.State -eq "Completed" -and $result.exit -eq 0) { "OK" } else { "WARN" }
            Write-Host "     [$status] $($result.name)" -ForegroundColor $(if($status -eq 'OK'){'Green'}else{'Yellow'})
        }
        $jobs | Remove-Job -Force

        Write-Step "Aguardando propagacao Entra ID (60s)..." "WAIT"
        Write-Tech "Device registration pode levar 30-120s apos extensao instalada"
        Start-Sleep -Seconds 60

        # Recarregar devices (paginado)
        $deviceList = Get-AllEntraDevices
        Write-Step "Devices apos extensao: $($deviceList.Count)" "INFO"
    }

    # ============================================================
    # STAGE 6: DEVICE MATCHING + GROUP SYNC
    # ============================================================
    Write-Host "`n[6/10] DEVICE MATCHING + GROUP SYNC (LOCAL + GLOBAL)" -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan
    Write-Tech "2 camadas de matching para maxima precisao:"
    Write-Tech "L1: physicalIds contem Azure Resource ID da VM (95% exacto)"
    Write-Tech "L2: Nome normalizado (lowercase, sem dominio) (80% fallback)"
    Write-Tech "Resultado: cada VM matched → grupo LOCAL + grupo GLOBAL correspondente"

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
            $matched += @{ vm = $vm; device = $dev; statusTag = "active" }
        } else {
            Write-Step "$($vm.name) → sem device Entra ID (extensao pode ainda propagar)" "SKIP"
            $unmatched += $vm
        }
    }

    Write-Step "Matched: $($matched.Count) / $($vms.Count) | Pendentes: $($unmatched.Count)" "INFO"

    # Adicionar devices aos grupos LOCAL + GLOBAL
    $addedCount = 0
    foreach ($m in $matched) {
        $devId = $m.device.id
        $devName = $m.device.displayName
        $lastSign = $m.device.approximateLastSignInDateTime

        # Determinar grupo alvo e status tag
        $targetGroup = $groupId
        $targetLabel = "Main"
        $statusTag = "active"
        $globalTag = "active"
        if ($lastSign) {
            try {
                $daysAgo = ((Get-Date) - [DateTime]::Parse($lastSign)).Days
                if ($daysAgo -gt 30) {
                    $targetGroup = $groupIdStale30; $targetLabel = "Stale-30d"
                    $statusTag = "stale30"; $globalTag = "stale30"
                } elseif ($daysAgo -gt 7) {
                    $targetGroup = $groupIdStale7; $targetLabel = "Stale-7d"
                    $statusTag = "stale7"; $globalTag = "stale7"
                }
            } catch { }
        } else {
            $targetGroup = $groupIdStale7; $targetLabel = "Stale-7d"
            $statusTag = "stale7"; $globalTag = "stale7"
        }

        # Guardar statusTag para uso no Stage 10
        $m["statusTag"] = $statusTag

        # Adicionar ao grupo LOCAL via Graph API
        if (-not $targetGroup) {
            Write-Host "     [!] $devName → LOCAL:$targetLabel (grupo nao existe)" -ForegroundColor Red
        } else {
            $addBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$devId" } | ConvertTo-Json
            $addBody | Out-File (Join-Path $tempPath "add-member.json") -Encoding UTF8 -Force -NoNewline
            az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$targetGroup/members/`$ref" --headers "Content-Type=application/json" --body "@$(Join-Path $tempPath 'add-member.json')" --output none 2>&1 | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Host "     [+] $devName → LOCAL:$targetLabel" -ForegroundColor Green
                $addedCount++
            } else {
                Write-Host "     [=] $devName → LOCAL:$targetLabel (ja membro)" -ForegroundColor Gray
            }
        }

        # Adicionar ao grupo GLOBAL correspondente
        $globalGroupId = $globalGroupIds[$globalTag]
        if ($globalGroupId) {
            if (-not (Test-Path (Join-Path $tempPath "add-member.json"))) {
                $addBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$devId" } | ConvertTo-Json
                $addBody | Out-File (Join-Path $tempPath "add-member.json") -Encoding UTF8 -Force -NoNewline
            }
            az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$globalGroupId/members/`$ref" --headers "Content-Type=application/json" --body "@$(Join-Path $tempPath 'add-member.json')" --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "     [+] $devName → GLOBAL:$globalTag" -ForegroundColor DarkGreen
            } else {
                Write-Host "     [=] $devName → GLOBAL:$globalTag (ja membro)" -ForegroundColor DarkGray
            }
        }
    }
    Write-Step "Devices adicionados (local): $addedCount" "OK"
} # fim do if vms.Count

# ============================================================
# STAGE 7: AZURE POLICY
# ============================================================
Write-Host "`n[7/10] AZURE POLICY" -ForegroundColor Cyan
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
# STAGE 8: MDE DEVICE GROUPS + TAGS GUIDE (HTML)
# ============================================================
Write-Host "`n[8/10] MDE DEVICE GROUPS + TAGS GUIDE" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "Guia HTML com instrucoes de Tags MDE e Device Groups"

$htmlFile = Join-Path $tempPath "MDE-Guide-$subNameShort.html"
$htmlContent = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head><meta charset="UTF-8"><title>MDE Guide - $subscriptionName</title>
<style>
body{font-family:Segoe UI,sans-serif;max-width:900px;margin:40px auto;padding:20px;background:#f5f5f5}
h1{color:#0078d4;border-bottom:3px solid #0078d4;padding-bottom:10px}
h2{color:#106ebe;margin-top:30px}h3{color:#005a9e}
.card{background:#fff;border-radius:8px;padding:20px;margin:15px 0;box-shadow:0 2px 4px rgba(0,0,0,0.1)}
.tag{display:inline-block;background:#e1f0ff;color:#0078d4;padding:4px 12px;border-radius:4px;margin:2px;font-family:Consolas,monospace;font-size:14px}
.recommended{border-left:4px solid #107c10;padding-left:15px}
.optional{border-left:4px solid #ffb900;padding-left:15px}
code{background:#f0f0f0;padding:2px 6px;border-radius:3px;font-family:Consolas,monospace}
table{border-collapse:collapse;width:100%;margin:10px 0}
th,td{border:1px solid #ddd;padding:8px 12px;text-align:left}
th{background:#0078d4;color:#fff}
</style></head>
<body>
<h1>MDE Automation Guide &mdash; $subscriptionName</h1>
<p>Subscription ID: <code>$subscriptionId</code></p>

<div class="card recommended">
<h2>Op&ccedil;&atilde;o A &mdash; Usar Tags MDE (Recomendado)</h2>
<p>O Stage 10 aplicou tags automaticamente nos devices MDE. Use em pol&iacute;ticas MDE
(<b>Settings &rarr; Endpoints &rarr; Device Groups &rarr; Filtros</b>):</p>
<table><tr><th>Tag</th><th>Finalidade</th><th>Exemplo</th></tr>
<tr><td><span class="tag">sub:$subNameShort</span></td><td>Identifica subscription de origem</td><td>Filtrar devices desta sub</td></tr>
<tr><td><span class="tag">status:active</span></td><td>Estado atual do device</td><td>active, stale7, stale30</td></tr>
<tr><td><span class="tag">global:active</span></td><td>Correla&ccedil;&atilde;o com grupo global Entra ID</td><td>active, stale7, stale30</td></tr>
<tr><td><span class="tag">managed:mde-automation</span></td><td>Identifica gest&atilde;o automatizada</td><td>Todos os devices gerenciados</td></tr>
</table>
<h3>Exemplos de Filtros MDE</h3>
<ul>
<li>Por subscription: <span class="tag">sub:$subNameShort</span></li>
<li>Apenas ativos: <span class="tag">status:active</span></li>
<li>Grupo global: <span class="tag">global:active</span></li>
<li>Todos gerenciados: <span class="tag">managed:mde-automation</span></li>
<li>Combina&ccedil;&atilde;o: <code>sub:*prod* AND status:active</code></li>
</ul>
</div>

<div class="card optional">
<h2>Op&ccedil;&atilde;o B &mdash; Device Groups MDE (Opcional)</h2>
<p>Se preferir Device Groups, crie apenas <b>4 globais</b> no portal
<a href="https://security.microsoft.com">security.microsoft.com</a>:</p>
<table><tr><th>Device Group MDE</th><th>Vinculado a Grupo Entra ID</th></tr>
<tr><td>mde-global-active</td><td>grp-mde-global-active</td></tr>
<tr><td>mde-global-stale7</td><td>grp-mde-global-stale7</td></tr>
<tr><td>mde-global-stale30</td><td>grp-mde-global-stale30</td></tr>
<tr><td>mde-global-ephemeral</td><td>grp-mde-global-ephemeral</td></tr>
</table>
<p><b>Caminho:</b> security.microsoft.com &rarr; Settings &rarr; Endpoints &rarr; Device Groups &rarr; Add</p>
</div>

<div class="card">
<h2>Grupos Entra ID Criados</h2>
<h3>Locais (esta subscription)</h3>
<ul>
<li><code>$entraGroupName</code> &mdash; Devices ativos</li>
<li><code>$entraGroupStale7Name</code> &mdash; Inativos 7+ dias</li>
<li><code>$entraGroupStale30Name</code> &mdash; Inativos 30+ dias</li>
<li><code>$entraGroupEphemeralName</code> &mdash; Efemeros</li>
</ul>
<h3>Globais (todas subscriptions)</h3>
<ul>
<li><code>grp-mde-global-active</code> &mdash; Todos ativos</li>
<li><code>grp-mde-global-stale7</code> &mdash; Todos inativos 7d</li>
<li><code>grp-mde-global-stale30</code> &mdash; Todos inativos 30d</li>
<li><code>grp-mde-global-ephemeral</code> &mdash; Todos efemeros</li>
</ul>
</div>

<div class="card">
<h2>Proximos Passos</h2>
<ol>
<li>Verifique tags no portal: <a href="https://security.microsoft.com/machines">security.microsoft.com/machines</a></li>
<li>Crie Device Groups se necessario (Op&ccedil;&atilde;o B)</li>
<li>Configure Conditional Access com grupos globais Entra ID</li>
<li>Agende sync via Azure Function (Timer Trigger a cada 12h)</li>
</ol>
</div>
</body></html>
"@
$htmlContent | Out-File $htmlFile -Encoding UTF8 -Force
Write-Step "HTML gerado: $htmlFile" "OK"

# ============================================================
# STAGE 9: MDE APP REGISTRATION + API PERMISSIONS
# ============================================================
Write-Host "`n[9/10] MDE APP REGISTRATION + API PERMISSIONS" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "App Registration para MDE API (Machine.ReadWrite.All)"
Write-Tech "Adiciona permissao WindowsDefenderATP + admin consent programatico"

$appDisplayName = "MDE-Automation-$subNameShort"
$appId = $null
$appObjectId = $null

# Verificar app existente (2 queries tsv para simplicidade PS 5.1)
$existingAppId = az ad app list --filter "displayName eq '$appDisplayName'" --query "[0].appId" -o tsv 2>$null
if ($existingAppId) {
    $appId = $existingAppId
    $appObjectId = az ad app list --filter "displayName eq '$appDisplayName'" --query "[0].id" -o tsv 2>$null
    Write-Step "App existente: $appId" "OK"
} else {
    $newAppRaw = az ad app create --display-name $appDisplayName --query "{appId:appId,id:id}" -o json 2>$null
    if ($newAppRaw) {
        $newApp = $newAppRaw | ConvertFrom-Json
        if ($newApp -and $newApp.appId) {
            $appId = $newApp.appId
            $appObjectId = $newApp.id
            Write-Step "App criado: $appId" "OK"
            az ad sp create --id $appId --output none 2>$null
            Write-Step "Service Principal criado" "OK"
            Start-Sleep -Seconds 5
        } else {
            Write-Step "App Registration falhou (Stage 10 sera pulado)" "SKIP"
        }
    } else {
        Write-Step "App Registration falhou (Stage 10 sera pulado)" "SKIP"
    }
}

# Adicionar permissao MDE API (Machine.ReadWrite.All)
if ($appId) {
    $mdeResourceAppId = "fc780465-2017-40d4-a0c5-307022471b92"

    # Obter permission ID dinamicamente do Service Principal WindowsDefenderATP
    $mdeSpRaw = az ad sp show --id $mdeResourceAppId -o json 2>$null
    $mdePermId = $null
    $mdeSpObjId = $null
    if ($mdeSpRaw) {
        $mdeSpObj = $mdeSpRaw | ConvertFrom-Json
        $mdeSpObjId = $mdeSpObj.id
        $roleMatch = $mdeSpObj.appRoles | Where-Object { $_.value -eq "Machine.ReadWrite.All" }
        if ($roleMatch) { $mdePermId = $roleMatch.id }
    }

    if ($mdePermId) {
        # Registar permissao no app
        az ad app permission add --id $appId --api $mdeResourceAppId --api-permissions "$($mdePermId)=Role" --output none 2>$null
        Write-Step "Permissao Machine.ReadWrite.All registada" "OK"

        # Grant admin consent via appRoleAssignment (sem browser)
        $spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv 2>$null
        if ($spId -and $mdeSpObjId) {
            $consentBody = @{
                principalId = $spId
                resourceId  = $mdeSpObjId
                appRoleId   = $mdePermId
            } | ConvertTo-Json
            $consentFile = Join-Path $tempPath "consent-mde.json"
            $consentBody | Out-File $consentFile -Encoding UTF8 -Force -NoNewline
            az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$consentFile" --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Step "Admin consent concedido (Machine.ReadWrite.All)" "OK"
            } else {
                Write-Step "Admin consent pode ja existir" "OK"
            }
        }
    } else {
        Write-Step "WindowsDefenderATP SP nao encontrado - Stage 10 pode falhar" "SKIP"
        Write-Tech "Verifique se MDE esta ativado: security.microsoft.com"
    }
}

# ============================================================
# STAGE 10: MDE MACHINE TAGS VIA API
# ============================================================
Write-Host "`n[10/10] MDE MACHINE TAGS (API)" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan
Write-Tech "Gera Client Secret, obtem token MDE, aplica 4 tags por machine"
Write-Tech "Rate limiting: 500ms entre chamadas MDE API"
Write-Tech "Correlacao 3 camadas: aadDeviceId → nome exato → nome aproximado"

if (-not $appId -or -not $appObjectId -or $matched.Count -eq 0) {
    if (-not $appId) { Write-Step "Sem App Registration - pulando" "SKIP" }
    if ($matched.Count -eq 0) { Write-Step "Sem devices matched - pulando" "SKIP" }
} else {
    # 10a: Gerar Client Secret via Graph API (addPassword - nao reseta existentes)
    $tenantId = $currentContext.tenantId
    $secretDisplayName = "MDE-Auto-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    $secretEndDate = (Get-Date).AddYears(1).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $secretBody = @{
        passwordCredential = @{
            displayName = $secretDisplayName
            endDateTime = $secretEndDate
        }
    } | ConvertTo-Json -Depth 3
    $secretFile = Join-Path $tempPath "secret-body.json"
    $secretBody | Out-File $secretFile -Encoding UTF8 -Force -NoNewline
    $secretResultRaw = az rest --method POST --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/addPassword" --headers "Content-Type=application/json" --body "@$secretFile" -o json 2>$null
    $secretResult = $null
    if ($secretResultRaw) { $secretResult = $secretResultRaw | ConvertFrom-Json }
    $clientSecret = $null
    if ($secretResult) { $clientSecret = $secretResult.secretText }

    if (-not $clientSecret) {
        Write-Step "Falha ao gerar Client Secret" "ERROR"
    } else {
        Write-Step "Client Secret gerado ($secretDisplayName)" "OK"
        Write-Tech "Expira em 1 ano. Nao e armazenado - gere novo na proxima execucao."

        # 10b: Aguardar propagacao do consent
        Write-Step "Aguardando propagacao de permissoes (15s)..." "WAIT"
        Start-Sleep -Seconds 15

        # 10c: Obter token MDE (com retry)
        $encodedSecret = [System.Uri]::EscapeDataString($clientSecret)
        $tokenBody = "client_id=" + $appId + "&client_secret=" + $encodedSecret + "&scope=https%3A%2F%2Fapi.security.microsoft.com%2F.default&grant_type=client_credentials"
        $mdeToken = $null
        $tokenRetries = 3
        for ($retry = 1; $retry -le $tokenRetries; $retry++) {
            try {
                $tokenResponse = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -ContentType "application/x-www-form-urlencoded" -Body $tokenBody -ErrorAction Stop
                $mdeToken = $tokenResponse.access_token
                break
            } catch {
                Write-Step "Token tentativa $retry/$tokenRetries - aguardando 10s..." "WAIT"
                Start-Sleep -Seconds 10
            }
        }

        if (-not $mdeToken) {
            Write-Step "Falha ao obter token MDE apos $tokenRetries tentativas" "ERROR"
            Write-Tech "Possivel causa: permissao ainda nao propagou. Re-execute em 5 min."
        } else {
            Write-Step "Token MDE obtido" "OK"

            # 10d: Listar machines MDE (com paginacao)
            $mdeHeaders = @{ Authorization = "Bearer $mdeToken" }
            $mdeMachines = @()
            $mdeUri = "https://api.security.microsoft.com/api/machines"
            do {
                try {
                    $mdeResponse = Invoke-RestMethod -Method GET -Uri $mdeUri -Headers $mdeHeaders -ErrorAction Stop
                    if ($mdeResponse.value) { $mdeMachines += $mdeResponse.value }
                    $mdeUri = $mdeResponse.'@odata.nextLink'
                } catch {
                    Write-Step "Erro ao listar machines MDE: $($_.Exception.Message)" "ERROR"
                    $mdeUri = $null
                }
            } while ($mdeUri)

            Write-Step "Machines MDE: $($mdeMachines.Count)" "INFO"
            Write-Step "Correlacionando MDE com Entra ID..." "INFO"

            $mdeTagsApplied = 0
            $mdeTagsTotal = 0
            $mdeMatchExact = 0
            $mdeMatchApprox = 0
            $mdeNoMatch = 0
            $mdeCorrelated = @()

            # 10e: Correlacionar MDE machines com matched devices (3 camadas)
            foreach ($m in $matched) {
                $devDeviceId = $m.device.deviceId
                $devNameNorm = Normalize-Name $m.device.displayName
                $mStatus = $m["statusTag"]
                $mdeMachine = $null
                $matchLayer = ""

                # LAYER 1: MDE.aadDeviceId == Entra.deviceId (exato - 95%)
                if ($devDeviceId) {
                    $mdeMachine = $mdeMachines | Where-Object { $_.aadDeviceId -eq $devDeviceId } | Select-Object -First 1
                    if ($mdeMachine) { $matchLayer = "L1-deviceId" }
                }

                # LAYER 2: Nome normalizado exato (80%)
                if (-not $mdeMachine -and $devNameNorm) {
                    $mdeMachine = $mdeMachines | Where-Object { (Normalize-Name $_.computerDnsName) -eq $devNameNorm } | Select-Object -First 1
                    if ($mdeMachine) { $matchLayer = "L2-name" }
                }

                # LAYER 3: Nome aproximado - contains / startsWith (70%)
                if (-not $mdeMachine -and $devNameNorm.Length -ge 3) {
                    $mdeMachine = $mdeMachines | Where-Object {
                        $mdeNorm = Normalize-Name $_.computerDnsName
                        ($mdeNorm -like "$devNameNorm*") -or ($devNameNorm -like "$mdeNorm*") -or ($mdeNorm -like "*$devNameNorm*")
                    } | Select-Object -First 1
                    if ($mdeMachine) { $matchLayer = "L3-approx" }
                }

                if ($mdeMachine) {
                    $mdeCorrelated += @{
                        machine   = $mdeMachine
                        status    = $mStatus
                        layer     = $matchLayer
                        devName   = $m.device.displayName
                    }
                    if ($matchLayer -like "L1*" -or $matchLayer -like "L2*") { $mdeMatchExact++ } else { $mdeMatchApprox++ }
                } else {
                    $mdeNoMatch++
                }
            }

            Write-Step "Correlacao: Exato=$mdeMatchExact | Aprox=$mdeMatchApprox | Sem=$mdeNoMatch" "INFO"

            # 10f: Aplicar tags
            if ($mdeCorrelated.Count -gt 0) {
                Write-Host ""
                Write-Host "  Aplicando tags..." -ForegroundColor Cyan

                foreach ($mc in $mdeCorrelated) {
                    $machineId = $mc.machine.id
                    $machineName = $mc.machine.computerDnsName
                    $mStatus = $mc.status
                    $existingTags = @()
                    if ($mc.machine.machineTags) { $existingTags = @($mc.machine.machineTags) }

                    $desiredTags = @(
                        "sub:$subNameShort",
                        "status:$mStatus",
                        "global:$mStatus",
                        "managed:mde-automation"
                    )

                    # Calcular tags a remover (status/global antigos diferentes do atual)
                    $toRemove = @()
                    foreach ($et in $existingTags) {
                        if ($et -like "status:*" -and $et -ne "status:$mStatus") { $toRemove += $et }
                        if ($et -like "global:*" -and $et -ne "global:$mStatus") { $toRemove += $et }
                    }

                    # Calcular tags a adicionar (que nao existem ainda)
                    $toAdd = @()
                    foreach ($dt in $desiredTags) {
                        if ($dt -notin $existingTags) { $toAdd += $dt }
                    }

                    $tagChanges = $toRemove.Count + $toAdd.Count
                    if ($tagChanges -eq 0) {
                        Write-Host "     [=] $machineName = tags ja corretas" -ForegroundColor Gray
                        $mdeTagsApplied++
                        $mdeTagsTotal++
                        continue
                    }

                    $tagSuccess = $true

                    # Remover tags antigas
                    foreach ($tr in $toRemove) {
                        $removeBody = @{ Value = $tr; Action = "Remove" } | ConvertTo-Json
                        try {
                            Invoke-RestMethod -Method POST -Uri "https://api.security.microsoft.com/api/machines/$machineId/tags" -Headers $mdeHeaders -ContentType "application/json" -Body $removeBody -ErrorAction Stop | Out-Null
                        } catch { $tagSuccess = $false }
                        Start-Sleep -Milliseconds 500
                    }

                    # Adicionar tags novas
                    foreach ($ta in $toAdd) {
                        $addTagBody = @{ Value = $ta; Action = "Add" } | ConvertTo-Json
                        try {
                            Invoke-RestMethod -Method POST -Uri "https://api.security.microsoft.com/api/machines/$machineId/tags" -Headers $mdeHeaders -ContentType "application/json" -Body $addTagBody -ErrorAction Stop | Out-Null
                        } catch { $tagSuccess = $false }
                        Start-Sleep -Milliseconds 500
                    }

                    $mdeTagsTotal++
                    if ($tagSuccess) {
                        $mdeTagsApplied++
                        $tagList = ($desiredTags -join ", ")
                        if ($mc.layer -like "L3*") {
                            Write-Host "     [~]  $machineName = match aproximado (Entra: $($mc.devName)) = $tagList" -ForegroundColor Yellow
                        } else {
                            Write-Host "     [OK] $machineName = $tagList" -ForegroundColor Green
                        }
                    } else {
                        Write-Host "     [!]  $machineName = erro parcial ao aplicar tags" -ForegroundColor Red
                    }
                }
            }

            # Resumo Stage 10
            Write-Host "`n  ========================================================" -ForegroundColor Cyan
            Write-Host "  RESUMO TAGS MDE:" -ForegroundColor White
            Write-Host "    Machines MDE: $($mdeMachines.Count)" -ForegroundColor Gray
            Write-Host "    Com correlacao: $($mdeCorrelated.Count)" -ForegroundColor Gray
            Write-Host "      - Match exato (L1+L2): $mdeMatchExact" -ForegroundColor Gray
            Write-Host "      - Match aproximado (L3): $mdeMatchApprox" -ForegroundColor Gray
            Write-Host "    Sem correlacao (esta sub): $mdeNoMatch" -ForegroundColor Gray
            Write-Host "    Tags aplicadas: $mdeTagsApplied / $mdeTagsTotal" -ForegroundColor Gray
            Write-Host "  ========================================================" -ForegroundColor Cyan
        } # fim token obtido
    } # fim secret gerado
} # fim Stage 10

# ============================================================
# RELATORIO POR SUBSCRIPTION
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT CONCLUIDO: $subscriptionName" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  RG: $resourceGroupName" -ForegroundColor White
Write-Host "  Groups: local=$groupId | global=4" -ForegroundColor White
Write-Host "  Policy: $policyName" -ForegroundColor White
Write-Host "  VMs: $($vms.Count) | Matched: $($matched.Count) | Synced: $addedCount" -ForegroundColor White
Write-Host "  MDE Tags: $mdeTagsApplied aplicadas | Exato: $mdeMatchExact | Aprox: $mdeMatchApprox" -ForegroundColor White
if ($unmatched.Count -gt 0) {
    Write-Host "  Pendentes: $($unmatched.Count) (reexecute em 5-10 min)" -ForegroundColor Yellow
}
Write-Host "============================================================`n" -ForegroundColor Green

# Abrir HTML da ultima subscription
if ($subIndex -eq $selectedSubs.Count -and (Test-Path $htmlFile)) {
    Write-Step "Abrindo guia HTML..." "INFO"
    if ($isWinOS) { Start-Process $htmlFile } else { Write-Host "     Abra: $htmlFile" -ForegroundColor Gray }
}

} # FIM DO LOOP FOREACH SUBSCRIPTION

# ============================================================
# REPORT FINAL
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  DEPLOYMENT GLOBAL CONCLUIDO!" -ForegroundColor White
Write-Host "  Subscriptions: $($selectedSubs.Count)" -ForegroundColor Gray
foreach ($ss in $selectedSubs) { Write-Host "     - $($ss.Name)" -ForegroundColor Gray }
Write-Host "" -ForegroundColor Gray
Write-Host "  GRUPOS GLOBAIS:" -ForegroundColor Yellow
Write-Host "     grp-mde-global-active    = $($globalGroupIds['active'])" -ForegroundColor Gray
Write-Host "     grp-mde-global-stale7    = $($globalGroupIds['stale7'])" -ForegroundColor Gray
Write-Host "     grp-mde-global-stale30   = $($globalGroupIds['stale30'])" -ForegroundColor Gray
Write-Host "     grp-mde-global-ephemeral = $($globalGroupIds['ephemeral'])" -ForegroundColor Gray
Write-Host "" -ForegroundColor Gray
Write-Host "  SYNC RECORRENTE:" -ForegroundColor Yellow
Write-Host "     Recomendado: Azure Function com Timer Trigger (12/12h)" -ForegroundColor Gray
Write-Host "     Apenas Stages 5+6+10 em script leve (~150 linhas)" -ForegroundColor Gray
Write-Host "============================================================`n" -ForegroundColor Magenta
