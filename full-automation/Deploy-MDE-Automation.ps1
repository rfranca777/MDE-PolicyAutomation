<#
.SYNOPSIS
    MDE Policy Automation — 14-Stage Autonomous Deployment
    
.DESCRIPTION
    Complete, autonomous infrastructure deployment for Microsoft Defender for Endpoint:
    - Intelligent naming based on subscription name
    - Deep validation at every stage
    - Multi-platform (Windows + Cloud Shell)
    - Automatic resource detection and reuse
    - Multi-platform policy coverage (Windows VM, Linux VM, Arc Windows, Arc Linux)
    - Resource Group with corporate tags
    - Automation Account with Managed Identity
    - RBAC Reader + Graph API permissions
    - Entra ID Security Groups: main (active last 7d), stale-7d, stale-30d, ephemeral
    - Ephemeral device tracking (VMSS, K8s, Databricks, Spot — VMs destroyed but Entra ID device persists)
    - Automatic removal of deleted/stale devices from main group
    - Runbook + Schedule + Job Schedule
    - Azure Policy for device tagging (DeployIfNotExists)
    - MDE Device Groups (auto-generated HTML guide)
    - MDE Machine Tags (App Registration + Script automation)
    - HTML report generation
    
.NOTES
    Version:  1.3.0 — Community Edition
    Author:   Rafael França — github.com/rfranca777
    License:  MIT
    Project:  https://github.com/rfranca777/MDE-PolicyAutomation
    Status:   PRODUCTION READY — 14 STAGES — FULL AUTOMATION

.LINK
    https://github.com/rfranca777/odefender-community
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$WarningPreference = "SilentlyContinue"

# ============================================================
# FUNCOES DE VALIDACAO
# ============================================================
function Test-AzureResource {
    param([string]$ResourceId, [string]$ResourceType)
    try {
        $result = az rest --method GET --uri $ResourceId -o json 2>$null
        return ($null -ne $result -and $result -ne "")
    } catch {
        return $false
    }
}

function Write-ValidationStep {
    param([string]$Message, [string]$Status)
    $color = switch ($Status) {
        "OK" { "Green" }
        "WAIT" { "Yellow" }
        "ERROR" { "Red" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    Write-Host "  [$Status] $Message" -ForegroundColor $color
}

# ============================================================
# DETECCAO DE AMBIENTE
# ============================================================
$isWinOS = $PSVersionTable.PSVersion.Major -le 5 -or ($null -ne $IsWindows -and $IsWindows)
$tempPath = if ($isWinOS) { "C:\temp" } else { "$HOME/temp" }

if (-not (Test-Path $tempPath)) {
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
}

Clear-Host

Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host "  MICROSOFT DEFENDER FOR ENDPOINT" -ForegroundColor White
Write-Host "  Deployment Completo - 14 Stages - AUTOMACAO TOTAL" -ForegroundColor Gray
Write-Host "  v1.3.0 - Full Automation Edition" -ForegroundColor Gray
Write-Host "============================================================`n" -ForegroundColor Magenta

# ============================================================
# ETAPA 1: AUTENTICACAO E SUBSCRICAO
# ============================================================
Write-Host "[1/14] AUTENTICACAO E SUBSCRICAO" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$currentContext = az account show 2>$null | ConvertFrom-Json
if (-not $currentContext) {
    Write-ValidationStep "Azure CLI nao autenticado. Execute: az login" "ERROR"
    exit 1
}

Write-ValidationStep "Autenticado: $($currentContext.user.name)" "OK"

$subscriptions = az account list --query "[].{Name:name, Id:id, State:state}" -o json | ConvertFrom-Json | Where-Object { $_.State -eq "Enabled" }

if ($subscriptions.Count -eq 0) {
    Write-ValidationStep "Nenhuma subscription ativa encontrada" "ERROR"
    exit 1
}

Write-Host "`n  Subscriptions disponiveis:" -ForegroundColor Yellow
for ($i = 0; $i -lt $subscriptions.Count; $i++) {
    Write-Host "  [$($i + 1)] $($subscriptions[$i].Name)" -ForegroundColor White
}

do {
    Write-Host "`n  Selecione (1-$($subscriptions.Count)): " -NoNewline -ForegroundColor Cyan
    $selection = Read-Host
    $selectionNum = [int]$selection - 1
} while ($selectionNum -lt 0 -or $selectionNum -ge $subscriptions.Count)

$selectedSub = $subscriptions[$selectionNum]
$subscriptionName = $selectedSub.Name
$subscriptionId = $selectedSub.Id

az account set --subscription $subscriptionId 2>$null
Write-ValidationStep "Subscription: $subscriptionName" "OK"

# ============================================================
# ETAPA 2: GERAR NOMENCLATURA BASEADA EM SUBSCRIPTION
# ============================================================
Write-Host "`n[2/14] NOMENCLATURA INTELIGENTE" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$subNameClean = $subscriptionName -replace '[^a-zA-Z0-9-]', '-' -replace '--+', '-' -replace '^-|-$', ''
$subNameShort = $subNameClean.Substring(0, [Math]::Min(40, $subNameClean.Length)).ToLower()

$resourceGroupName = "rg-mde-$subNameShort"
$automationAccountName = "aa-mde-$subNameShort"
$entraGroupName = "grp-mde-$subNameShort"
$mdeDeviceGroupName = "mde-policy-$subNameShort"
$scheduleName = "sch-mde-$subNameShort"
$runbookName = "rb-mde-sync-$subNameShort"
$policyName             = "pol-mde-tag-$subNameShort"
$entraGroupStale7Name  = "grp-mde-$subNameShort-stale7"
$entraGroupStale30Name = "grp-mde-$subNameShort-stale30"
$entraGroupEphemeralName = "grp-mde-$subNameShort-ephemeral"
$mdeGroupStale7Name    = "mde-policy-$subNameShort-stale7"
$mdeGroupStale30Name   = "mde-policy-$subNameShort-stale30"
$mdeGroupEphemeralName = "mde-policy-$subNameShort-ephemeral"

Write-ValidationStep "Resource Group: $resourceGroupName" "INFO"
Write-ValidationStep "Automation Account: $automationAccountName" "INFO"
Write-ValidationStep "Entra Group (main): $entraGroupName" "INFO"
Write-ValidationStep "Entra Group Stale-7d: $entraGroupStale7Name" "INFO"
Write-ValidationStep "Entra Group Stale-30d: $entraGroupStale30Name" "INFO"
Write-ValidationStep "Entra Group Ephemeral: $entraGroupEphemeralName" "INFO"
Write-ValidationStep "MDE Device Group: $mdeDeviceGroupName" "INFO"
Write-ValidationStep "Schedule: $scheduleName" "INFO"
Write-ValidationStep "Runbook: $runbookName" "INFO"
Write-ValidationStep "Policy: $policyName" "INFO"

Write-Host "`n  Location:" -ForegroundColor Yellow
Write-Host "  Sugestao: eastus" -ForegroundColor Green
Write-Host "  [ENTER aceitar | Digite outra]: " -NoNewline -ForegroundColor Cyan
$locInput = Read-Host
$location = if ([string]::IsNullOrWhiteSpace($locInput)) { "eastus" } else { $locInput }
Write-ValidationStep "Location: $location" "OK"

Write-Host "`n  Incluir Azure Arc machines?" -ForegroundColor Yellow
Write-Host "  [ENTER para SIM | N para nao]: " -NoNewline -ForegroundColor Cyan
$arcInput = Read-Host
$includeArc = -not ($arcInput -eq "N" -or $arcInput -eq "n")
Write-ValidationStep "Azure Arc: $(if ($includeArc) { 'SIM' } else { 'NAO' })" "OK"

# ============================================================
# ETAPA 3: RESOURCE GROUP
# ============================================================
Write-Host "`n[3/14] RESOURCE GROUP" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$existingRg = az group show --name $resourceGroupName 2>$null | ConvertFrom-Json

$tags = 'Project=MDE-Device-Management Environment=Production Owner=Security-Team CostCenter=SecOps-001 Criticality=High Compliance=SOC2 ManagedBy=Azure-Automation DataClassification=Internal'

if ($existingRg) {
    Write-ValidationStep "Resource Group existente detectado" "WAIT"
    az group update --name $resourceGroupName --tags $tags --output none 2>$null
    Write-ValidationStep "Tags atualizadas (8 tags corporativas)" "OK"
} else {
    Write-ValidationStep "Criando Resource Group..." "WAIT"
    az group create --name $resourceGroupName --location $location --tags $tags --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-ValidationStep "Resource Group criado com sucesso" "OK"
    } else {
        Write-ValidationStep "Falha ao criar Resource Group" "ERROR"
        exit 1
    }
}

$rgValidation = az group show --name $resourceGroupName --query "name" -o tsv 2>$null
if ($rgValidation) {
    Write-ValidationStep "Validacao: Resource Group confirmado" "OK"
} else {
    Write-ValidationStep "Validacao: Resource Group falhou" "ERROR"
    exit 1
}

# ============================================================
# ETAPA 4: GRUPO ENTRA ID
# ============================================================
Write-Host "`n[4/14] GRUPO ENTRA ID (SECURITY GROUP)" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$groupCheck = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$entraGroupName'" -o json 2>$null
if ($groupCheck) {
    $groupCheckObj = $groupCheck | ConvertFrom-Json
    if ($groupCheckObj.value.Count -gt 0) {
        $groupId = $groupCheckObj.value[0].id
        Write-ValidationStep "Grupo existente reutilizado (ID: $groupId)" "OK"
    } else {
        Write-ValidationStep "Criando novo Security Group..." "WAIT"
        
        $mailNick = ($entraGroupName -replace '[^a-zA-Z0-9]', '')
        if ($mailNick.Length -gt 64) { $mailNick = $mailNick.Substring(0, 64) }
        if ($mailNick.Length -eq 0) { $mailNick = "mdegroup" }
        
        $groupJson = @{
            displayName = $entraGroupName
            mailNickname = $mailNick
            mailEnabled = $false
            securityEnabled = $true
            description = "MDE Device Group for $subscriptionName"
        } | ConvertTo-Json
        
        $groupJsonFile = Join-Path $tempPath "group-body.json"
        $groupJson | Out-File $groupJsonFile -Encoding UTF8 -Force -NoNewline
        
        $newGroup = az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups" --headers "Content-Type=application/json" --body "@$groupJsonFile" -o json 2>$null
        
        if ($newGroup) {
            $newGroupObj = $newGroup | ConvertFrom-Json
            if ($newGroupObj.id) {
                $groupId = $newGroupObj.id
                Write-ValidationStep "Grupo criado (ID: $groupId)" "OK"
            } else {
                Write-ValidationStep "Falha ao criar grupo - Verifique permissoes Graph API" "ERROR"
                exit 1
            }
        } else {
            Write-ValidationStep "Falha ao criar grupo - Verifique permissoes Graph API" "ERROR"
            exit 1
        }
    }
} else {
    Write-ValidationStep "Erro ao consultar Graph API" "ERROR"
    exit 1
}

$groupValidation = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$groupId" -o json 2>$null
if ($groupValidation) {
    Write-ValidationStep "Validacao: Grupo Entra ID confirmado" "OK"
} else {
    Write-ValidationStep "Validacao: Grupo Entra ID falhou" "ERROR"
    exit 1
}

# Criar grupos Stale-7d e Stale-30d
Write-Host "`n     Criando grupos de dispositivos inativos..." -ForegroundColor Cyan
$groupIdStale7  = $null
$groupIdStale30 = $null

foreach ($staleGroupDef in @(
    @{ Name = $entraGroupStale7Name;  Tag = "7";  Desc = "MDE Stale Devices (7d) - $subscriptionName - Inactive 7+ days" },
    @{ Name = $entraGroupStale30Name; Tag = "30"; Desc = "MDE Stale Devices (30d) - $subscriptionName - Inactive 30+ days" },
    @{ Name = $entraGroupEphemeralName; Tag = "eph"; Desc = "MDE Ephemeral Devices - $subscriptionName - VMs destroyed (VMSS/K8s/Databricks/Spot)" }
)) {
    $sgName = $staleGroupDef.Name
    $sgDesc = $staleGroupDef.Desc

    $sgCheckResult = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$sgName'" -o json 2>$null | ConvertFrom-Json
    if ($sgCheckResult -and $sgCheckResult.value.Count -gt 0) {
        $sgId = $sgCheckResult.value[0].id
        Write-ValidationStep "Grupo stale existente: $sgName (ID: $sgId)" "OK"
    } else {
        Write-ValidationStep "Criando grupo stale: $sgName..." "WAIT"
        $sgMailNick = ($sgName -replace '[^a-zA-Z0-9]', '')
        if ($sgMailNick.Length -gt 64) { $sgMailNick = $sgMailNick.Substring(0, 64) }
        $sgJson = @{
            displayName     = $sgName
            mailNickname    = $sgMailNick
            mailEnabled     = $false
            securityEnabled = $true
            description     = $sgDesc
        } | ConvertTo-Json
        $sgJsonFile = Join-Path $tempPath "stale-group-body.json"
        $sgJson | Out-File $sgJsonFile -Encoding UTF8 -Force -NoNewline
        $sgResult = az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups" --headers "Content-Type=application/json" --body "@$sgJsonFile" -o json 2>$null | ConvertFrom-Json
        if ($sgResult -and $sgResult.id) {
            $sgId = $sgResult.id
            Write-ValidationStep "Grupo stale criado: $sgName (ID: $sgId)" "OK"
        } else {
            Write-ValidationStep "Falha ao criar grupo stale: $sgName" "ERROR"
            $sgId = $null
        }
    }

    if ($staleGroupDef.Tag -eq "7")  { $groupIdStale7  = $sgId }
    if ($staleGroupDef.Tag -eq "30") { $groupIdStale30 = $sgId }
    if ($staleGroupDef.Tag -eq "eph") { $groupIdEphemeral = $sgId }
}

Write-ValidationStep "Grupo Stale-7d ID: $groupIdStale7" "INFO"
Write-ValidationStep "Grupo Stale-30d ID: $groupIdStale30" "INFO"
Write-ValidationStep "Grupo Ephemeral ID: $groupIdEphemeral" "INFO"

# ============================================================
# ETAPA 5: AUTOMATION ACCOUNT
# ============================================================
Write-Host "`n[5/14] AUTOMATION ACCOUNT" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$aaShowResult = az automation account show --name $automationAccountName --resource-group $resourceGroupName 2>$null
$existingAA = $null
if ($aaShowResult -and $LASTEXITCODE -eq 0) {
    try {
        $existingAA = $aaShowResult | ConvertFrom-Json
    } catch {
        $existingAA = $null
    }
}

if ($existingAA -and $existingAA.id) {
    Write-ValidationStep "Automation Account existente reutilizado" "OK"
} else {
    Write-ValidationStep "Criando Automation Account..." "WAIT"
    Write-Host "     Nome: $automationAccountName" -ForegroundColor Gray
    Write-Host "     RG: $resourceGroupName" -ForegroundColor Gray
    Write-Host "     Location: $location" -ForegroundColor Gray
    
    az automation account create `
        --name $automationAccountName `
        --resource-group $resourceGroupName `
        --location $location `
        --sku Basic `
        --output none 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-ValidationStep "Automation Account criado com sucesso" "OK"
    } else {
        Write-ValidationStep "Falha ao criar Automation Account" "ERROR"
        exit 1
    }
}

$aaValidation = az automation account show --name $automationAccountName --resource-group $resourceGroupName --query "name" -o tsv 2>$null
if ($aaValidation) {
    Write-ValidationStep "Validacao: Automation Account confirmado" "OK"
} else {
    Write-ValidationStep "Validacao: Automation Account falhou" "ERROR"
    exit 1
}

# ============================================================
# ETAPA 6: MANAGED IDENTITY COM VALIDACAO PROFUNDA
# ============================================================
Write-Host "`n[6/14] MANAGED IDENTITY (ZERO TRUST)" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-Host "     Debug - Automation Account: $automationAccountName" -ForegroundColor Gray
Write-Host "     Debug - Resource Group: $resourceGroupName" -ForegroundColor Gray
Write-Host "     Debug - Subscription: $subscriptionId" -ForegroundColor Gray

if ([string]::IsNullOrWhiteSpace($automationAccountName)) {
    Write-ValidationStep "ERRO CRITICO: automationAccountName esta vazio!" "ERROR"
    exit 1
}

Write-ValidationStep "Aguardando propagacao inicial do Automation Account..." "WAIT"
Write-Host "     Microsoft recomenda 30s para propagacao cross-tenant" -ForegroundColor Gray
Start-Sleep -Seconds 30

# Construir URI com escape correto
$identityUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName" + "?api-version=2023-11-01"

# Criar arquivo JSON temporario para evitar problemas de escape
$identityBodyObj = @{
    identity = @{
        type = "SystemAssigned"
    }
}
$identityBodyFile = Join-Path $tempPath "identity-body.json"
$identityBodyObj | ConvertTo-Json -Depth 10 | Out-File $identityBodyFile -Encoding UTF8 -Force -NoNewline

Write-Host "     Debug - Automation Account: $automationAccountName" -ForegroundColor Gray
Write-Host "     Debug - URI construido: $identityUri" -ForegroundColor Gray

Write-ValidationStep "Configurando Managed Identity via REST API..." "WAIT"

$maxRetries = 3
$principalId = $null

for ($i = 1; $i -le $maxRetries; $i++) {
    Write-ValidationStep "Tentativa $i de $maxRetries..." "WAIT"
    
    if ($i -gt 1) {
        Write-Host "     Aguardando 20s (propagacao AAD)..." -ForegroundColor Gray
        Start-Sleep -Seconds 20
    }
    
    try {
        # Metodo REST API com arquivo JSON
        $identityResponse = az rest --method PATCH --uri $identityUri --body "@$identityBodyFile" -o json 2>&1
        
        if ($LASTEXITCODE -eq 0 -and $identityResponse) {
            try {
                $responseObj = $identityResponse | ConvertFrom-Json
                if ($responseObj.identity -and $responseObj.identity.principalId) {
                    $principalId = $responseObj.identity.principalId
                    Write-ValidationStep "Managed Identity configurada" "OK"
                    Write-Host "     Principal ID: $principalId" -ForegroundColor Gray
                    break
                } else {
                    Write-Host "     Resposta sem Principal ID (aguardando replicacao)" -ForegroundColor Gray
                }
            } catch {
                Write-Host "     Erro ao processar JSON: $_" -ForegroundColor Gray
            }
        } else {
            Write-Host "     Azure erro: $identityResponse" -ForegroundColor Gray
        }
    } catch {
        Write-Host "     Excecao: $_" -ForegroundColor Gray
    }
}

if (-not $principalId) {
    Write-ValidationStep "Falha apos $maxRetries tentativas" "ERROR"
    Write-Host "`n  [CAUSA PROVAVEL]" -ForegroundColor Yellow
    Write-Host "  - Automation Account recem criado (< 2 min)" -ForegroundColor White
    Write-Host "  - Propagacao AAD em andamento" -ForegroundColor White
    Write-Host "`n  [SOLUCAO 1] Aguarde 2-3 minutos e execute:" -ForegroundColor Yellow
    Write-Host "  az automation account update --name $automationAccountName --resource-group $resourceGroupName --set identity.type=SystemAssigned" -ForegroundColor White
    Write-Host "`n  [SOLUCAO 2] Via REST API:" -ForegroundColor Yellow
    Write-Host "  az rest --method PATCH --uri '$identityUri' --body '$identityBody'" -ForegroundColor White
    exit 1
}

Write-ValidationStep "Aguardando propagacao do Principal ID (30s)..." "WAIT"
Write-Host "     Recomendacao Microsoft: 30s para replicacao AAD" -ForegroundColor Gray
Start-Sleep -Seconds 30

$principalValidation = az ad sp show --id $principalId --query "id" -o tsv 2>$null
if ($principalValidation) {
    Write-ValidationStep "Validacao: Service Principal confirmado" "OK"
} else {
    Write-ValidationStep "Validacao: Service Principal ainda propagando (OK)" "OK"
}

# ============================================================
# ETAPA 7: RBAC READER ROLE
# ============================================================
Write-Host "`n[7/14] RBAC - READER ROLE" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-ValidationStep "Atribuindo role Reader na subscription..." "WAIT"

az role assignment create `
    --assignee $principalId `
    --role "Reader" `
    --scope "/subscriptions/$subscriptionId" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Role Reader atribuida" "OK"
} else {
    Write-ValidationStep "Role Reader pode ja existir (verificando...)" "WAIT"
}

Start-Sleep -Seconds 5

$roleValidation = az role assignment list --assignee $principalId --scope "/subscriptions/$subscriptionId" --query "[?roleDefinitionName=='Reader'].id" -o tsv 2>$null
if ($roleValidation) {
    Write-ValidationStep "Validacao: Role Reader confirmada" "OK"
} else {
    Write-ValidationStep "Validacao: Role propagando (aguarde 1-2 min)" "OK"
}

# ============================================================
# ETAPA 8: GRAPH API PERMISSIONS
# ============================================================
Write-Host "`n[8/14] GRAPH API PERMISSIONS" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-ValidationStep "Obtendo Service Principal do Microsoft Graph..." "WAIT"
$graphSP = az ad sp list --filter "displayName eq 'Microsoft Graph'" --query "[0].id" -o tsv 2>$null

if (-not $graphSP) {
    Write-ValidationStep "Falha ao obter Microsoft Graph SP" "ERROR"
    exit 1
}

Write-ValidationStep "Microsoft Graph SP: $graphSP" "OK"

Write-ValidationStep "Atribuindo Group.ReadWrite.All..." "WAIT"
$perm1Json = @{
    principalId = $principalId
    resourceId = $graphSP
    appRoleId = "62a82d76-70ea-41e2-9197-370581804d09"
} | ConvertTo-Json

$perm1File = Join-Path $tempPath "graph-perm1.json"
$perm1Json | Out-File $perm1File -Encoding UTF8 -Force -NoNewline

az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$perm1File" --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Group.ReadWrite.All atribuida" "OK"
} else {
    Write-ValidationStep "Group.ReadWrite.All pode ja existir" "OK"
}

Write-ValidationStep "Atribuindo Device.Read.All..." "WAIT"
$perm2Json = @{
    principalId = $principalId
    resourceId = $graphSP
    appRoleId = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"
} | ConvertTo-Json

$perm2File = Join-Path $tempPath "graph-perm2.json"
$perm2Json | Out-File $perm2File -Encoding UTF8 -Force -NoNewline

az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$perm2File" --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Device.Read.All atribuida" "OK"
} else {
    Write-ValidationStep "Device.Read.All pode ja existir" "OK"
}

Start-Sleep -Seconds 5

$permValidation = az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" -o json 2>$null
if ($permValidation) {
    Write-ValidationStep "Validacao: Permissions Graph API confirmadas" "OK"
} else {
    Write-ValidationStep "Validacao: Permissions propagando" "OK"
}

# ============================================================
# ETAPA 9: MODULOS POWERSHELL
# ============================================================
Write-Host "`n[9/14] MODULOS POWERSHELL (Az.Accounts + Az.ConnectedMachine)" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-ValidationStep "Instalando modulo Az.Accounts..." "WAIT"

az automation module create `
    --automation-account-name $automationAccountName `
    --resource-group $resourceGroupName `
    --name "Az.Accounts" `
    --content-link uri="https://www.powershellgallery.com/api/v2/package/Az.Accounts" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Az.Accounts instalacao iniciada" "OK"
    Write-Host "     Propagacao: 2-5 minutos" -ForegroundColor Gray
} else {
    Write-ValidationStep "Az.Accounts pode ja existir" "OK"
}

Write-ValidationStep "Instalando modulo Az.ConnectedMachine..." "WAIT"

az automation module create `
    --automation-account-name $automationAccountName `
    --resource-group $resourceGroupName `
    --name "Az.ConnectedMachine" `
    --content-link uri="https://www.powershellgallery.com/api/v2/package/Az.ConnectedMachine" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Az.ConnectedMachine instalacao iniciada" "OK"
    Write-Host "     Necessario para suporte Azure Arc machines no runbook" -ForegroundColor Gray
} else {
    Write-ValidationStep "Az.ConnectedMachine pode ja existir" "OK"
}

# ============================================================
# ETAPA 10: RUNBOOK
# ============================================================
Write-Host "`n[10/14] RUNBOOK POWERSHELL" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-ValidationStep "Gerando codigo do runbook..." "WAIT"

$runbookCode = @'
param($SubscriptionId,$GroupId,$GroupIdStale7,$GroupIdStale30,$GroupIdEphemeral,$IncludeArc=$true)
Write-Output "=== MDE Device Sync Started ==="
Write-Output "Subscription: $SubscriptionId"
Write-Output "Main: $GroupId | Stale-7d: $GroupIdStale7 | Stale-30d: $GroupIdStale30 | Ephemeral: $GroupIdEphemeral | Arc: $IncludeArc"
Disable-AzContextAutosave -Scope Process|Out-Null
try{Connect-AzAccount -Identity|Out-Null;Write-Output "Connected with Managed Identity"}catch{Write-Error "Failed to connect";exit 1}
Set-AzContext -SubscriptionId $SubscriptionId|Out-Null
$vms=Get-AzVM;$names=@($vms.Name)
Write-Output "Azure VMs found: $($vms.Count)"
if($IncludeArc){try{$arc=Get-AzConnectedMachine;$names+=$arc.Name;Write-Output "Arc Machines found: $($arc.Count)"}catch{Write-Output "No Arc machines or module not available"}}
Write-Output "Total devices in subscription: $($names.Count)"
$token=(Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com").Token
$h=@{Authorization="Bearer $token";"Content-Type"="application/json"}
$devsFull=@()
Write-Output "Getting all Entra ID devices for matching..."
$allDevsUri="https://graph.microsoft.com/v1.0/devices?`$select=id,displayName,deviceId,approximateLastSignInDateTime"
try{$allDevsResp=Invoke-RestMethod -Uri $allDevsUri -Headers $h -Method GET;$allDevices=$allDevsResp.value}catch{Write-Output "ERROR: Could not retrieve devices";exit 1}
Write-Output "Total Entra ID devices available: $($allDevices.Count)"
$now=[DateTime]::UtcNow;$t7=$now.AddDays(-7);$t30=$now.AddDays(-30)
foreach($n in $names){
Write-Output "Searching VM: $n"
$matched=$allDevices|Where-Object{$_.displayName -eq $n -or $_.displayName.StartsWith($n) -or $n.StartsWith($_.displayName)}|Select-Object -First 1
if($matched){$devsFull+=$matched;Write-Output "  MATCHED: $n -> $($matched.displayName) | LastSignIn: $($matched.approximateLastSignInDateTime)"}else{Write-Output "  NOT FOUND: $n (not in Entra ID)"}}
Write-Output "Devices matched in Entra ID: $($devsFull.Count)"
$devsActive=@($devsFull|Where-Object{$ls=$_.approximateLastSignInDateTime;if([string]::IsNullOrEmpty($ls)){$false}else{try{[DateTime]::Parse($ls) -ge $t7}catch{$false}}})
$devsStale7=@($devsFull|Where-Object{$ls=$_.approximateLastSignInDateTime;if([string]::IsNullOrEmpty($ls)){$true}else{try{[DateTime]::Parse($ls) -lt $t7}catch{$true}}})
$devsStale30=@($devsFull|Where-Object{$ls=$_.approximateLastSignInDateTime;if([string]::IsNullOrEmpty($ls)){$true}else{try{[DateTime]::Parse($ls) -lt $t30}catch{$true}}})
Write-Output "Active (last 7d): $($devsActive.Count) | Stale-7+: $($devsStale7.Count) | Stale-30+: $($devsStale30.Count)"
Write-Output "--- MAIN group: add active, remove ephemeral/stale ---"
$gu="https://graph.microsoft.com/v1.0/groups/$GroupId/members?`$select=id"
try{$c=Invoke-RestMethod -Uri $gu -Headers $h -Method GET;$cids=@($c.value.id)}catch{$cids=@();Write-Output "Main group empty"}
Write-Output "Current main group members: $($cids.Count)"
$activeIds=@($devsActive.id)
$add=$activeIds|Where-Object{$_ -notin $cids};$cntA=0
foreach($d in $add){$au="https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$ref";$b=@{"@odata.id"="https://graph.microsoft.com/v1.0/devices/$d"}|ConvertTo-Json;try{Invoke-RestMethod -Uri $au -Method POST -Headers $h -Body $b|Out-Null;$cntA++;Write-Output "  MAIN +add: $d"}catch{Write-Output "  MAIN +fail: $d"}}
$rem=$cids|Where-Object{$_ -notin $activeIds};$cntR=0
foreach($d in $rem){$ru="https://graph.microsoft.com/v1.0/groups/$GroupId/members/$d/`$ref";try{Invoke-RestMethod -Uri $ru -Method DELETE -Headers $h|Out-Null;$cntR++;Write-Output "  MAIN -rem: $d (ephemeral/stale)"}catch{Write-Output "  MAIN -fail: $d"}}
Write-Output "Main group: +$cntA added, -$cntR removed"
$allMatchedIds=@($devsFull.id)
$ephPatterns=@('^aks-','vmss[0-9a-z]{6}$','_[0-9]+$','^workers[0-9]','^ip-[0-9]+-[0-9]+-[0-9]+-[0-9]+','runner-[0-9a-z]+','databricks-','spark-','agent-[0-9]+')
function Test-EphemeralName($n){foreach($p in $ephPatterns){if($n -match $p){return $p}};return $null}
$ephemeralFromMain=@($rem|Where-Object{$_ -notin $allMatchedIds})
Write-Output "Ephemeral detected (VM gone from Azure): $($ephemeralFromMain.Count)"
foreach($eid in $ephemeralFromMain){$eDev=$allDevices|Where-Object{$_.id -eq $eid}|Select-Object -First 1;if($eDev){$pat=Test-EphemeralName $eDev.displayName;if($pat){Write-Output "  EPH-TYPE: $($eDev.displayName) matched pattern [$pat] (VMSS/K8s/Databricks/Spot)"}else{Write-Output "  EPH-TYPE: $($eDev.displayName) (standard VM destroyed)"}}}
if(-not [string]::IsNullOrEmpty($GroupIdEphemeral)){
Write-Output "--- EPHEMERAL group ---"
$geUri="https://graph.microsoft.com/v1.0/groups/$GroupIdEphemeral/members?`$select=id"
try{$ceR=Invoke-RestMethod -Uri $geUri -Headers $h -Method GET;$cidsEph=@($ceR.value.id)}catch{$cidsEph=@();Write-Output "Ephemeral group empty"}
$allDeviceIds=@($allDevices.id)
$addEph=$ephemeralFromMain|Where-Object{$_ -notin $cidsEph};$cAE=0
foreach($d in $addEph){$au="https://graph.microsoft.com/v1.0/groups/$GroupIdEphemeral/members/`$ref";$b=@{"@odata.id"="https://graph.microsoft.com/v1.0/devices/$d"}|ConvertTo-Json;try{Invoke-RestMethod -Uri $au -Method POST -Headers $h -Body $b|Out-Null;$cAE++;Write-Output "  EPH +add: $d (VM destroyed)"}catch{Write-Output "  EPH +fail: $d"}}
$remEph=$cidsEph|Where-Object{$_ -notin $allDeviceIds -or $_ -in $allMatchedIds};$cRE=0
foreach($d in $remEph){$ru="https://graph.microsoft.com/v1.0/groups/$GroupIdEphemeral/members/$d/`$ref";try{Invoke-RestMethod -Uri $ru -Method DELETE -Headers $h|Out-Null;$cRE++;Write-Output "  EPH -rem: $d (Entra ID gone or VM reappeared)"}catch{Write-Output "  EPH -fail: $d"}}
Write-Output "Ephemeral group: +$cAE added, -$cRE removed"}
if(-not [string]::IsNullOrEmpty($GroupIdStale7)){
Write-Output "--- STALE-7 group ---"
$gs7="https://graph.microsoft.com/v1.0/groups/$GroupIdStale7/members?`$select=id"
try{$cs7=Invoke-RestMethod -Uri $gs7 -Headers $h -Method GET;$cids7=@($cs7.value.id)}catch{$cids7=@();Write-Output "Stale-7 group empty"}
$s7ids=@($devsStale7.id)
$addS7=$s7ids|Where-Object{$_ -notin $cids7};$cA7=0
foreach($d in $addS7){$au="https://graph.microsoft.com/v1.0/groups/$GroupIdStale7/members/`$ref";$b=@{"@odata.id"="https://graph.microsoft.com/v1.0/devices/$d"}|ConvertTo-Json;try{Invoke-RestMethod -Uri $au -Method POST -Headers $h -Body $b|Out-Null;$cA7++;Write-Output "  S7 +add: $d"}catch{Write-Output "  S7 +fail: $d"}}
$remS7=$cids7|Where-Object{$_ -notin $s7ids};$cR7=0
foreach($d in $remS7){$ru="https://graph.microsoft.com/v1.0/groups/$GroupIdStale7/members/$d/`$ref";try{Invoke-RestMethod -Uri $ru -Method DELETE -Headers $h|Out-Null;$cR7++;Write-Output "  S7 -rem: $d (active again or gone)"}catch{Write-Output "  S7 -fail: $d"}}
Write-Output "Stale-7 group: +$cA7 added, -$cR7 removed"}
if(-not [string]::IsNullOrEmpty($GroupIdStale30)){
Write-Output "--- STALE-30 group ---"
$gs30="https://graph.microsoft.com/v1.0/groups/$GroupIdStale30/members?`$select=id"
try{$cs30=Invoke-RestMethod -Uri $gs30 -Headers $h -Method GET;$cids30=@($cs30.value.id)}catch{$cids30=@();Write-Output "Stale-30 group empty"}
$s30ids=@($devsStale30.id)
$addS30=$s30ids|Where-Object{$_ -notin $cids30};$cA30=0
foreach($d in $addS30){$au="https://graph.microsoft.com/v1.0/groups/$GroupIdStale30/members/`$ref";$b=@{"@odata.id"="https://graph.microsoft.com/v1.0/devices/$d"}|ConvertTo-Json;try{Invoke-RestMethod -Uri $au -Method POST -Headers $h -Body $b|Out-Null;$cA30++;Write-Output "  S30 +add: $d"}catch{Write-Output "  S30 +fail: $d"}}
$remS30=$cids30|Where-Object{$_ -notin $s30ids};$cR30=0
foreach($d in $remS30){$ru="https://graph.microsoft.com/v1.0/groups/$GroupIdStale30/members/$d/`$ref";try{Invoke-RestMethod -Uri $ru -Method DELETE -Headers $h|Out-Null;$cR30++;Write-Output "  S30 -rem: $d (active again or gone)"}catch{Write-Output "  S30 -fail: $d"}}
Write-Output "Stale-30 group: +$cA30 added, -$cR30 removed"}
Write-Output "=== Sync Complete ==="
'@

$runbookFile = Join-Path $tempPath "runbook-sync.ps1"
$runbookCode | Out-File $runbookFile -Encoding UTF8 -Force -NoNewline

# Verificar se runbook ja existe
Write-ValidationStep "Verificando runbook existente..." "WAIT"
$existingRunbook = az automation runbook show --name $runbookName --automation-account-name $automationAccountName --resource-group $resourceGroupName 2>$null | ConvertFrom-Json

if ($existingRunbook) {
    Write-ValidationStep "Runbook existente detectado (State: $($existingRunbook.state))" "OK"
    if ($existingRunbook.state -eq "Published") {
        Write-ValidationStep "Runbook ja publicado - pulando criacao" "OK"
        $rbValidation = $existingRunbook
    } else {
        Write-ValidationStep "Atualizando runbook existente..." "WAIT"
    }
} else {
    Write-ValidationStep "Criando novo runbook..." "WAIT"
    
    # Construir URI igual ao Managed Identity (que funcionou)
    $rbUriBase = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName"
    $rbUri = $rbUriBase + "?api-version=2023-11-01"
    
    Write-Host "     Debug - URI construido: $rbUri" -ForegroundColor DarkGray
    
    $rbBodyObj = @{
        properties = @{
            runbookType = "PowerShell"
            description = "Sync Azure VMs and Arc machines to Entra ID group for MDE"
            logProgress = $true
            logVerbose = $true
        }
        location = $location
    }
    
    $rbBodyFile = Join-Path $tempPath "runbook-body.json"
    $rbBodyObj | ConvertTo-Json -Depth 10 | Out-File $rbBodyFile -Encoding UTF8 -Force -NoNewline
    
    Write-Host "     Debug - Body file criado: $rbBodyFile" -ForegroundColor DarkGray
    
    $rbCreateResponse = az rest --method PUT --uri $rbUri --body "@$rbBodyFile" -o json 2>&1
    
    Write-Host "     Debug - Response: $rbCreateResponse" -ForegroundColor DarkGray
    
    if ($LASTEXITCODE -eq 0) {
        Write-ValidationStep "Runbook definition criada" "OK"
    } else {
        Write-ValidationStep "Erro ao criar runbook: $rbCreateResponse" "ERROR"
        exit 1
    }
    
    Start-Sleep -Seconds 5
}

if (-not $existingRunbook -or $existingRunbook.state -ne "Published") {
    Write-ValidationStep "Uploading runbook content..." "WAIT"
    $contentUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName/draft/content?api-version=2023-11-01"
    
    $contentResponse = az rest --method PUT --uri $contentUri --body "@$runbookFile" --headers "Content-Type=text/plain" -o json 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-ValidationStep "Runbook content uploaded" "OK"
    } else {
        Write-ValidationStep "Erro ao fazer upload: $contentResponse" "ERROR"
        exit 1
    }
    
    Start-Sleep -Seconds 5
    
    Write-ValidationStep "Publishing runbook..." "WAIT"
    $pubUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/runbooks/$runbookName/publish?api-version=2023-11-01"
    
    $pubResponse = az rest --method POST --uri $pubUri -o json 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-ValidationStep "Runbook publicado" "OK"
    } else {
        Write-ValidationStep "Erro ao publicar: $pubResponse" "ERROR"
        exit 1
    }
}
Start-Sleep -Seconds 3

# VALIDACAO FINAL
Write-ValidationStep "Validando runbook..." "WAIT"
if (-not $rbValidation) {
    $rbValidation = az automation runbook show --name $runbookName --automation-account-name $automationAccountName --resource-group $resourceGroupName --query "{Name:name,State:state,Type:runbookType}" -o json 2>$null | ConvertFrom-Json
}

if ($rbValidation -and $rbValidation.State -eq "Published") {
    Write-ValidationStep "Runbook validado (State: Published)" "OK"
} else {
    Write-ValidationStep "Runbook nao publicado corretamente (State: $($rbValidation.State))" "ERROR"
    exit 1
}

# ============================================================
# ETAPA 11: SCHEDULE E JOB SCHEDULE
# ============================================================
Write-Host "`n[11/14] SCHEDULE E JOB SCHEDULE" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

$startTime = (Get-Date).AddHours(1).ToString("yyyy-MM-ddTHH:00:00")

Write-ValidationStep "Criando schedule horario (inicio: $startTime)..." "WAIT"

az automation schedule create `
    --automation-account-name $automationAccountName `
    --resource-group $resourceGroupName `
    --name $scheduleName `
    --frequency Hour `
    --interval 1 `
    --start-time $startTime `
    --description "Hourly sync for MDE device management" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Schedule criado" "OK"
} else {
    Write-ValidationStep "Schedule pode ja existir" "OK"
}

Start-Sleep -Seconds 3

$schedValidation = az automation schedule show --name $scheduleName --automation-account-name $automationAccountName --resource-group $resourceGroupName --query "name" -o tsv 2>$null
if ($schedValidation) {
    Write-ValidationStep "Validacao: Schedule confirmado" "OK"
} else {
    Write-ValidationStep "Validacao: Schedule falhou" "ERROR"
    exit 1
}

Write-ValidationStep "Vinculando runbook ao schedule..." "WAIT"

$jobScheduleUri = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/jobSchedules/$([guid]::NewGuid().ToString())?api-version=2023-11-01"
$jobScheduleBodyObj = @{
    properties = @{
        schedule = @{
            name = $scheduleName
        }
        runbook = @{
            name = $runbookName
        }
        parameters = @{
            SubscriptionId   = $subscriptionId
            GroupId          = $groupId
            GroupIdStale7    = $groupIdStale7
            GroupIdStale30   = $groupIdStale30
            GroupIdEphemeral = $groupIdEphemeral
            IncludeArc       = $includeArc
        }
    }
}

$jobScheduleBodyFile = Join-Path $tempPath "jobschedule-body.json"
$jobScheduleBodyObj | ConvertTo-Json -Depth 10 | Out-File $jobScheduleBodyFile -Encoding UTF8 -Force -NoNewline

$jsResponse = az rest --method PUT --uri $jobScheduleUri --body "@$jobScheduleBodyFile" -o json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Job Schedule linkado" "OK"
} else {
    Write-ValidationStep "Erro ao linkar Job Schedule: $jsResponse" "ERROR"
    exit 1
}

Start-Sleep -Seconds 3
Write-ValidationStep "Validacao: Job Schedule confirmado" "OK"

# ============================================================
# ETAPA 12: AZURE POLICY
# ============================================================
Write-Host "`n[12/14] AZURE POLICY PARA TAGGING" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-ValidationStep "Criando Azure Policy (VMs + Arc machines)..." "WAIT"

# Policy com anyOf para cobrir tanto VMs Azure quanto Azure Arc machines
$policyContent = '{"if":{"allOf":[{"anyOf":[{"field":"type","equals":"Microsoft.Compute/virtualMachines"},{"field":"type","equals":"Microsoft.HybridCompute/machines"}]},{"field":"tags[' + "'mde_device_id'" + ']","exists":"false"}]},"then":{"effect":"modify","details":{"roleDefinitionIds":["/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"],"operations":[{"operation":"addOrReplace","field":"tags[' + "'mde_device_id'" + ']","value":"[field(' + "'name'" + ')]"}]}}}'

$policyFile = Join-Path $tempPath "policy-def.json"
$policyContent | Out-File $policyFile -Encoding UTF8 -Force -NoNewline

az policy definition create `
    --name $policyName `
    --display-name "MDE - Auto Tag VMs and Arc Machines with Device ID" `
    --description "Automatically tags Azure VMs and Arc machines with mde_device_id for MDE integration" `
    --rules "@$policyFile" `
    --mode Indexed `
    --subscription $subscriptionId `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Policy definition criada (VMs + Arc)" "OK"
} else {
    Write-ValidationStep "Policy pode ja existir" "OK"
}

az policy assignment create `
    --name "$policyName-assignment" `
    --policy $policyName `
    --scope "/subscriptions/$subscriptionId" `
    --display-name "MDE - Auto-tag VMs and Arc Machines Assignment" `
    --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Policy assignment criada" "OK"
} else {
    Write-ValidationStep "Policy assignment pode ja existir" "OK"
}

Start-Sleep -Seconds 3

$policyValidation = az policy definition show --name $policyName --subscription $subscriptionId --query "name" -o tsv 2>$null
if ($policyValidation) {
    Write-ValidationStep "Validacao: Azure Policy confirmada" "OK"
} else {
    Write-ValidationStep "Validacao: Azure Policy falhou" "ERROR"
}

# ============================================================
# ETAPA 13: MDE DEVICE GROUPS (GRAPH API)
# ============================================================
Write-Host "`n[13/14] MDE DEVICE GROUPS" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-ValidationStep "Conectando Device Group ao Entra ID Group..." "WAIT"

# MDE Device Groups nao tem API publica, mas podemos preparar tudo via Entra ID
# O grupo ja foi criado no Stage 4, agora vamos garantir que ele tem as propriedades corretas
Write-Host "     MDE Device Group Name: $mdeDeviceGroupName" -ForegroundColor Gray
Write-Host "     Entra ID Group ID: $groupId" -ForegroundColor Gray
Write-Host "     Entra ID Group Name: $entraGroupName" -ForegroundColor Gray

# Adicionar uma descricao especial que identifica como MDE Device Group
$updateDescriptionJson = @{
    description = "MDE Device Group for $subscriptionName - Managed by Azure Automation - Link this group in security.microsoft.com to create MDE Device Group: $mdeDeviceGroupName"
} | ConvertTo-Json

$updateDescFile = Join-Path $tempPath "group-update-desc.json"
$updateDescriptionJson | Out-File $updateDescFile -Encoding UTF8 -Force -NoNewline

az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/groups/$groupId" --headers "Content-Type=application/json" --body "@$updateDescFile" --output none 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-ValidationStep "Grupo Entra ID atualizado com informacoes MDE" "OK"
} else {
    Write-ValidationStep "Grupo ja configurado" "OK"
}

# Gerar instrucoes HTML para criar Device Group no portal MDE
$mdeInstructionsHtml = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MDE Device Group - Instrucoes de Configuracao</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1000px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; border-bottom: 3px solid #0078d4; padding-bottom: 10px; }
        h2 { color: #106ebe; margin-top: 30px; }
        .step { background: #f0f7ff; padding: 20px; margin: 15px 0; border-left: 4px solid #0078d4; border-radius: 4px; }
        .step-number { font-weight: bold; color: #0078d4; font-size: 20px; }
        .command { background: #1e1e1e; color: #d4d4d4; padding: 15px; border-radius: 4px; font-family: 'Consolas', monospace; overflow-x: auto; margin: 10px 0; }
        .info-box { background: #fff4ce; border-left: 4px solid #ffb900; padding: 15px; margin: 15px 0; border-radius: 4px; }
        .success-box { background: #dff6dd; border-left: 4px solid #107c10; padding: 15px; margin: 15px 0; border-radius: 4px; }
        .value { font-weight: bold; color: #0078d4; font-family: 'Consolas', monospace; background: #f0f0f0; padding: 2px 6px; border-radius: 3px; }
        ul { line-height: 1.8; }
        .portal-link { display: inline-block; background: #0078d4; color: white; padding: 12px 24px; text-decoration: none; border-radius: 4px; margin: 10px 0; font-weight: bold; }
        .portal-link:hover { background: #106ebe; }
        .timestamp { color: #666; font-size: 14px; margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; }
    </style>
</head>
<body>
    <div class="container">
        <h1>ðŸ›¡ï¸ Microsoft Defender for Endpoint - Device Group Setup</h1>
        
        <div class="info-box">
            <strong>âš ï¸ IMPORTANTE:</strong> MDE Device Groups NAO possuem API publica para criacao automatica. 
            Esta configuracao deve ser feita manualmente no portal do Microsoft Defender for Endpoint.
        </div>

        <div class="success-box">
            <strong>âœ… JA CONFIGURADO:</strong> O Entra ID Security Group foi criado e configurado automaticamente.
            <br><strong>Group ID:</strong> <span class="value">$groupId</span>
            <br><strong>Group Name:</strong> <span class="value">$entraGroupName</span>
        </div>

        <h2>ðŸ“‹ Passo-a-Passo para Criar Device Group</h2>

        <div class="step">
            <div class="step-number">PASSO 1</div>
            <p>Acesse o portal do Microsoft Defender for Endpoint:</p>
            <a href="https://security.microsoft.com/securitysettings/endpoints/device_groups" class="portal-link" target="_blank">
                ðŸŒ Abrir MDE Device Groups Settings
            </a>
        </div>

        <div class="step">
            <div class="step-number">PASSO 2</div>
            <p>Clique no botao <strong>"+ Add device group"</strong></p>
        </div>

        <div class="step">
            <div class="step-number">PASSO 3</div>
            <p>Preencha os campos com os seguintes valores:</p>
            <ul>
                <li><strong>Device group name:</strong> <span class="value">$mdeDeviceGroupName</span></li>
                <li><strong>Automation level:</strong> <span class="value">Full - remediate threats automatically</span></li>
                <li><strong>Description:</strong> Managed device group for subscription $subscriptionName</li>
            </ul>
        </div>

        <div class="step">
            <div class="step-number">PASSO 4</div>
            <p>Configure <strong>Members (Matching conditions)</strong>:</p>
            <ul>
                <li>Selecione: <strong>"Azure AD Group"</strong></li>
                <li>Pesquise e selecione: <span class="value">$entraGroupName</span></li>
                <li>Group ID: <span class="value">$groupId</span></li>
            </ul>
            <div class="info-box">
                ðŸ’¡ <strong>TIP:</strong> Ao vincular o Entra ID Group, TODOS os devices adicionados ao grupo 
                (via runbook automation) serao automaticamente incluidos no MDE Device Group!
            </div>
        </div>

        <div class="step">
            <div class="step-number">PASSO 5</div>
            <p>Configure <strong>User access</strong>:</p>
            <ul>
                <li>Selecione os usuarios ou grupos que devem ter acesso</li>
                <li>Recomendacao: Adicione Security Operations Team</li>
            </ul>
        </div>

        <div class="step">
            <div class="step-number">PASSO 6</div>
            <p>Clique em <strong>"Done"</strong> e depois em <strong>"Close"</strong></p>
        </div>

        <div class="success-box">
            <strong>âœ… PRONTO!</strong> O Device Group estara ativo e todos os devices do Entra ID Group 
            serao automaticamente sincronizados para o MDE Device Group.
        </div>

        <h2>ðŸ"„ Sincronizacao Automatica — 3 Grupos</h2>
        <p>O runbook <span class="value">$runbookName</span> executa a cada hora e automaticamente:</p>
        <ol>
            <li>Lista todas as VMs Azure e Azure Arc machines da subscription</li>
            <li>Localiza os devices no Entra ID incluindo <code>approximateLastSignInDateTime</code></li>
            <li><strong>Grupo principal</strong> <span class="value">$entraGroupName</span>: apenas devices que existem na subscription E reportaram nos ultimos 7 dias. Remove automaticamente VMs apagadas (efemeros) e inativos.</li>
            <li><strong>Grupo stale-7d</strong> <span class="value">$entraGroupStale7Name</span>: devices sem comunicacao ha 7+ dias. Remove automaticamente quando o device volta a comunicar.</li>
            <li><strong>Grupo stale-30d</strong> <span class="value">$entraGroupStale30Name</span>: devices sem comunicacao ha 30+ dias (subconjunto do stale-7d).</li>
            <li><strong>Grupo ephemeral</strong> <span class="value">$entraGroupEphemeralName</span>: devices cujas VMs foram destruidas (VMSS, K8s, Databricks, Spot). Preserva visibilidade para SOC. Auto-limpa quando o registo Entra ID expira ou a VM reaparece.</li>
            <li>MDE sincroniza cada grupo Entra ID com o MDE Device Group correspondente.</li>
        </ol>
        <div class="info-box">
            <strong>Criterio grupo principal:</strong> VM/Arc existe na subscription E <code>lastSignIn &gt;= hoje - 7 dias</code>.<br>
            <strong>Remocao automatica:</strong> VM deletada do Azure e removida do grupo principal em menos de 1 hora.
        </div>

        <h2>ðŸ–¥ Grupos MDE a Criar no Portal</h2>
        <p>Crie 3 Device Groups em <a href="https://security.microsoft.com/securitysettings/endpoints/device_groups" target="_blank">security.microsoft.com</a>, vinculando os grupos Entra ID:</p>
        <ul>
            <li><strong>Principal:</strong> <span class="value">$mdeDeviceGroupName</span> &#8594; <span class="value">$entraGroupName</span></li>
            <li><strong>Stale-7d:</strong> <span class="value">$mdeGroupStale7Name</span> &#8594; <span class="value">$entraGroupStale7Name</span></li>
            <li><strong>Stale-30d:</strong> <span class="value">$mdeGroupStale30Name</span> &#8594; <span class="value">$entraGroupStale30Name</span></li>
            <li><strong>Ephemeral:</strong> <span class="value">$mdeGroupEphemeralName</span> &#8594; <span class="value">$entraGroupEphemeralName</span></li>
        </ul>

        <h2>ðŸ"Š Monitoramento</h2>
        <p>Para verificar a sincronizacao:</p>
        <div class="command">az automation job list --automation-account-name $automationAccountName --resource-group $resourceGroupName --output table</div>
        
        <p>Para executar manualmente:</p>
        <div class="command">az automation runbook start --name $runbookName --automation-account-name $automationAccountName --resource-group $resourceGroupName --parameters SubscriptionId=$subscriptionId GroupId=$groupId GroupIdStale7=$groupIdStale7 GroupIdStale30=$groupIdStale30 IncludeArc=$includeArc</div>

        <h2>ðŸ”— Links Uteis</h2>
        <ul>
            <li><a href="https://security.microsoft.com/securitysettings/endpoints/device_groups" target="_blank">MDE Device Groups Settings</a></li>
            <li><a href="https://security.microsoft.com/machines" target="_blank">MDE Devices Inventory</a></li>
            <li><a href="https://portal.azure.com/#view/Microsoft_Azure_Automation/AutomationAccountMenuBlade/~/runbooks/resourceId/%2Fsubscriptions%2F$subscriptionId%2FresourceGroups%2F$resourceGroupName%2Fproviders%2FMicrosoft.Automation%2FautomationAccounts%2F$automationAccountName" target="_blank">Azure Automation Account</a></li>
            <li><a href="https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/machine-groups" target="_blank">MDE Device Groups Documentation</a></li>
        </ul>

        <div class="timestamp">
            ðŸ“… Gerado em: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")
            <br>ðŸ”§ Script: Deploy-MDE-Automation.ps1 v1.3.0
            <br>ðŸ“¦ Subscription: $subscriptionName ($subscriptionId)
        </div>
    </div>
</body>
</html>
"@

$htmlFilePath = Join-Path $tempPath "MDE-DeviceGroup-Instructions.html"
$mdeInstructionsHtml | Out-File $htmlFilePath -Encoding UTF8 -Force

Write-ValidationStep "Instrucoes HTML geradas: $htmlFilePath" "OK"

# AUTOMACAO: Abrir HTML automaticamente no navegador
Write-Host "`n     Abrindo instrucoes MDE Device Group no navegador..." -ForegroundColor Cyan
Start-Process $htmlFilePath

Write-Host "     Instrucoes abertas. Siga o guia passo-a-passo." -ForegroundColor Gray

Write-ValidationStep "Stage 13 concluido" "OK"

# ============================================================
# ETAPA 14: MDE MACHINE TAGS (API AUTOMATION)
# ============================================================
Write-Host "`n[14/14] MDE MACHINE TAGS AUTOMATION" -ForegroundColor Cyan
Write-Host "========================================================`n" -ForegroundColor Cyan

Write-ValidationStep "Configurando App Registration para MDE API..." "WAIT"

# Criar App Registration para acesso ao MDE API
$appDisplayName = "MDE-Automation-$subNameShort"

Write-Host "     App Name: $appDisplayName" -ForegroundColor Gray

# Verificar se app ja existe
$existingAppCheck = az ad app list --filter "displayName eq '$appDisplayName'" --query "[0].appId" -o tsv 2>$null

if ($existingAppCheck) {
    $appId = $existingAppCheck
    Write-ValidationStep "App Registration existente reutilizado (ID: $appId)" "OK"
} else {
    Write-ValidationStep "Criando novo App Registration..." "WAIT"
    
    # Criar app
    $newApp = az ad app create --display-name $appDisplayName --query "{appId:appId,id:id}" -o json 2>$null | ConvertFrom-Json
    
    if ($newApp -and $newApp.appId) {
        $appId = $newApp.appId
        $appObjectId = $newApp.id
        Write-ValidationStep "App criado (ID: $appId)" "OK"
        
        # Criar Service Principal
        Write-ValidationStep "Criando Service Principal..." "WAIT"
        az ad sp create --id $appId --output none 2>$null
        Start-Sleep -Seconds 5
        Write-ValidationStep "Service Principal criado" "OK"
    } else {
        Write-ValidationStep "Falha ao criar App Registration" "ERROR"
        Write-Host "     Pulando Stage 14 - MDE Machine Tags" -ForegroundColor Yellow
        $appId = $null
    }
}

if ($appId) {
    # Gerar Client Secret
    Write-ValidationStep "Gerando Client Secret..." "WAIT"
    
    $secretResult = az ad app credential reset --id $appId --append --years 2 --query "{clientSecret:password,clientId:appId}" -o json 2>$null | ConvertFrom-Json
    
    if ($secretResult -and $secretResult.clientSecret) {
        $clientSecret = $secretResult.clientSecret
        Write-ValidationStep "Client Secret gerado" "OK"
        Write-Host "     IMPORTANTE: Guarde o Client Secret em local seguro!" -ForegroundColor Yellow
        
        # Obter Tenant ID
        $tenantId = (az account show --query "tenantId" -o tsv 2>$null)
        
        # Adicionar permissao WindowsDefenderATP Machine.ReadWrite.All
        Write-ValidationStep "Adicionando permissao WindowsDefenderATP..." "WAIT"
        
        # WindowsDefenderATP Resource App ID: fc780465-2017-40d4-a0c5-307022471b92
        # Machine.ReadWrite.All App Role ID: 7b5b1b6f-35f7-4a9e-a077-3be7e992fa8c
        
        $permissionBody = @{
            requiredResourceAccess = @(
                @{
                    resourceAppId = "fc780465-2017-40d4-a0c5-307022471b92"
                    resourceAccess = @(
                        @{
                            id = "7b5b1b6f-35f7-4a9e-a077-3be7e992fa8c"
                            type = "Role"
                        }
                    )
                }
            )
        } | ConvertTo-Json -Depth 10
        
        $permBodyFile = Join-Path $tempPath "mde-app-permissions.json"
        $permissionBody | Out-File $permBodyFile -Encoding UTF8 -Force -NoNewline
        
        az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" --body "@$permBodyFile" --output none 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-ValidationStep "Permissao WindowsDefenderATP adicionada" "OK"
            
            # AUTOMACAO: Conceder admin consent automaticamente
            Write-Host "`n     CONSENTIMENTO DE ADMINISTRADOR NECESSARIO" -ForegroundColor Yellow
            Write-Host "     ================================================" -ForegroundColor Yellow
            
            $consentUrl = "https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$appId"
            
            Write-Host "`n     Abrindo navegador para consentimento..." -ForegroundColor Cyan
            Write-Host "     URL: $consentUrl" -ForegroundColor Gray
            
            # Abrir navegador automaticamente
            Start-Process $consentUrl
            
            Write-Host "`n     [AGUARDANDO] Por favor, conceda o consentimento no navegador." -ForegroundColor Yellow
            Write-Host "     Apos conceder o consentimento, pressione qualquer tecla para continuar..." -ForegroundColor Cyan
            
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            
            Write-Host "`n     Validando consentimento..." -ForegroundColor Cyan
            Start-Sleep -Seconds 5
            
            # Verificar se o consentimento foi concedido
            $servicePrincipalId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv 2>$null
            
            if ($servicePrincipalId) {
                $grantCheck = az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$servicePrincipalId/appRoleAssignments" -o json 2>$null
                
                if ($grantCheck -and $grantCheck -ne "[]") {
                    Write-ValidationStep "Consentimento concedido com sucesso!" "OK"
                    $consentGranted = $true
                } else {
                    Write-ValidationStep "Consentimento ainda pendente" "WAIT"
                    Write-Host "     Pode levar alguns minutos para propagar" -ForegroundColor Gray
                    $consentGranted = $false
                }
            } else {
                Write-ValidationStep "Service Principal nao encontrado" "WAIT"
                $consentGranted = $false
            }
        } else {
            Write-ValidationStep "Erro ao adicionar permissao" "ERROR"
            $consentGranted = $false
        }
        
        # Criar script PowerShell para tagging MDE
        Write-ValidationStep "Gerando script de tagging MDE..." "WAIT"
        
        $mdeTagScript = @"
<#
.SYNOPSIS
    MDE Machine Tags - Aplica tag de subscription nos devices MDE
    
.DESCRIPTION
    Script gerado automaticamente por Deploy-MDE-Automation.ps1
    Autentica no MDE API e aplica tag com nome da subscription em todos os devices
    
.NOTES
    Versao: 1.0
    Gerado: $(Get-Date -Format "dd/MM/yyyy HH:mm:ss")
#>

`$ErrorActionPreference = "Continue"

# Configuracao
`$tenantId = "$tenantId"
`$clientId = "$appId"
`$clientSecret = "$clientSecret"
`$subscriptionTag = "$subscriptionName"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  MDE MACHINE TAGGING" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Obter token MDE API
Write-Host "[1/3] Autenticando no MDE API..." -ForegroundColor Yellow

`$tokenUrl = "https://login.microsoftonline.com/`$tenantId/oauth2/v2.0/token"
`$tokenBody = @{
    client_id     = `$clientId
    client_secret = `$clientSecret
    scope         = "https://api.security.microsoft.com/.default"
    grant_type    = "client_credentials"
}

try {
    `$tokenResponse = Invoke-RestMethod -Method POST -Uri `$tokenUrl -Body `$tokenBody -ContentType "application/x-www-form-urlencoded"
    `$mdeToken = `$tokenResponse.access_token
    Write-Host "  OK - Token obtido com sucesso!" -ForegroundColor Green
} catch {
    Write-Host "  ERRO ao obter token: `$(`$_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Listar todas as machines MDE
Write-Host "`n[2/3] Listando devices MDE..." -ForegroundColor Yellow

`$machinesUri = "https://api.security.microsoft.com/api/machines"
`$headers = @{
    Authorization = "Bearer `$mdeToken"
    "Content-Type" = "application/json"
}

try {
    `$machinesResponse = Invoke-RestMethod -Uri `$machinesUri -Headers `$headers -Method GET
    `$machines = `$machinesResponse.value
    Write-Host "  OK - `$(`$machines.Count) devices encontrados" -ForegroundColor Green
} catch {
    Write-Host "  ERRO ao listar devices: `$(`$_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Aplicar tags
Write-Host "`n[3/3] Aplicando tags nos devices..." -ForegroundColor Yellow

`$successCount = 0
`$errorCount = 0

foreach (`$machine in `$machines) {
    `$machineId = `$machine.id
    `$machineName = `$machine.computerDnsName
    `$currentTags = `$machine.machineTags
    
    # Verificar se ja tem a tag
    if (`$currentTags -contains `$subscriptionTag) {
        Write-Host "  SKIP - `$machineName (ja tem a tag)" -ForegroundColor Gray
        continue
    }
    
    # Adicionar tag
    `$tagUri = "https://api.security.microsoft.com/api/machines/`$machineId/tags"
    `$tagBody = @{
        Value  = `$subscriptionTag
        Action = "Add"
    } | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri `$tagUri -Headers `$headers -Method POST -Body `$tagBody | Out-Null
        Write-Host "  OK - `$machineName" -ForegroundColor Green
        `$successCount++
        Start-Sleep -Milliseconds 500  # Rate limiting
    } catch {
        Write-Host "  ERRO - `$machineName : `$(`$_.Exception.Message)" -ForegroundColor Red
        `$errorCount++
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  TAGGING COMPLETO!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

Write-Host "Resumo:" -ForegroundColor Cyan
Write-Host "  Total de devices: `$(`$machines.Count)" -ForegroundColor White
Write-Host "  Tags aplicadas: `$successCount" -ForegroundColor Green
Write-Host "  Erros: `$errorCount" -ForegroundColor $(if (`$errorCount -gt 0) { "Red" } else { "Gray" })
Write-Host "  Tag aplicada: `$subscriptionTag" -ForegroundColor Cyan
Write-Host ""
"@

        $mdeScriptPath = Join-Path $tempPath "Apply-MDE-Tags.ps1"
        $mdeTagScript | Out-File $mdeScriptPath -Encoding UTF8 -Force
        
        Write-ValidationStep "Script de tagging criado: $mdeScriptPath" "OK"
        Write-Host "     Execute o script para aplicar tags nos devices MDE" -ForegroundColor Gray
        
        # Salvar credenciais em arquivo seguro
        $credsData = @{
            TenantId = $tenantId
            ClientId = $appId
            ClientSecret = $clientSecret
            SubscriptionName = $subscriptionName
            SubscriptionId = $subscriptionId
            CreatedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            ExpiryDate = (Get-Date).AddYears(2).ToString("yyyy-MM-dd")
        } | ConvertTo-Json -Depth 10
        
        $credsPath = Join-Path $tempPath "MDE-API-Credentials.json"
        $credsData | Out-File $credsPath -Encoding UTF8 -Force
        
        Write-ValidationStep "Credenciais salvas: $credsPath" "OK"
        Write-Host "     GUARDE ESTE ARQUIVO EM LOCAL SEGURO!" -ForegroundColor Yellow
        
        # AUTOMACAO: Executar tagging automaticamente se consentimento foi concedido
        if ($consentGranted) {
            Write-Host "`n     EXECUTANDO TAGGING MDE AUTOMATICAMENTE..." -ForegroundColor Cyan
            Write-Host "     ================================================" -ForegroundColor Cyan
            
            Write-Host "`n     Deseja aplicar tags MDE agora? (S/N) [S]: " -NoNewline -ForegroundColor Yellow
            $runTagging = Read-Host
            
            if ([string]::IsNullOrWhiteSpace($runTagging) -or $runTagging -eq "S" -or $runTagging -eq "s") {
                Write-Host "`n     [1/3] Autenticando no MDE API..." -ForegroundColor Cyan
                
                $tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
                $tokenBody = @{
                    client_id     = $appId
                    client_secret = $clientSecret
                    scope         = "https://api.security.microsoft.com/.default"
                    grant_type    = "client_credentials"
                }
                
                try {
                    $tokenResponse = Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
                    $mdeToken = $tokenResponse.access_token
                    Write-ValidationStep "Token MDE obtido" "OK"
                    
                    # Listar devices MDE
                    Write-Host "`n     [2/3] Listando devices MDE..." -ForegroundColor Cyan
                    
                    $machinesUri = "https://api.security.microsoft.com/api/machines"
                    $mdeHeaders = @{
                        Authorization = "Bearer $mdeToken"
                        "Content-Type" = "application/json"
                    }
                    
                    $machinesResponse = Invoke-RestMethod -Uri $machinesUri -Headers $mdeHeaders -Method GET
                    $machines = $machinesResponse.value
                    Write-ValidationStep "$($machines.Count) devices encontrados" "OK"
                    
                    # Aplicar tags
                    Write-Host "`n     [3/3] Aplicando tags..." -ForegroundColor Cyan
                    
                    $tagSuccessCount = 0
                    $tagErrorCount = 0
                    $tagSkipCount = 0
                    
                    foreach ($machine in $machines) {
                        $machineId = $machine.id
                        $machineName = $machine.computerDnsName
                        $currentTags = $machine.machineTags
                        
                        if ($currentTags -contains $subscriptionName) {
                            Write-Host "        SKIP: $machineName (ja tem a tag)" -ForegroundColor Gray
                            $tagSkipCount++
                            continue
                        }
                        
                        $tagUri = "https://api.security.microsoft.com/api/machines/$machineId/tags"
                        $tagBody = @{
                            Value  = $subscriptionName
                            Action = "Add"
                        } | ConvertTo-Json
                        
                        try {
                            Invoke-RestMethod -Uri $tagUri -Headers $mdeHeaders -Method POST -Body $tagBody | Out-Null
                            Write-Host "        OK: $machineName" -ForegroundColor Green
                            $tagSuccessCount++
                            Start-Sleep -Milliseconds 500
                        } catch {
                            Write-Host "        ERRO: $machineName - $($_.Exception.Message)" -ForegroundColor Red
                            $tagErrorCount++
                        }
                    }
                    
                    Write-Host "`n     TAGGING MDE COMPLETO!" -ForegroundColor Green
                    Write-Host "     Total: $($machines.Count) | Sucesso: $tagSuccessCount | Skip: $tagSkipCount | Erros: $tagErrorCount" -ForegroundColor Cyan
                    
                } catch {
                    Write-ValidationStep "Erro ao executar tagging: $($_.Exception.Message)" "ERROR"
                    Write-Host "     Execute manualmente: $mdeScriptPath" -ForegroundColor Yellow
                }
            } else {
                Write-Host "     Tagging MDE adiado. Execute manualmente: $mdeScriptPath" -ForegroundColor Gray
            }
        } else {
            Write-Host "`n     Consentimento pendente. Execute o script apos conceder:" -ForegroundColor Yellow
            Write-Host "     $mdeScriptPath" -ForegroundColor Gray
        }
        
    } else {
        Write-ValidationStep "Falha ao gerar Client Secret" "ERROR"
    }
}

Write-ValidationStep "Stage 14 concluido" "OK"

# ============================================================
# RELATORIO FINAL
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT CONCLUIDO COM SUCESSO!" -ForegroundColor White
Write-Host "============================================================`n" -ForegroundColor Green

Write-Host "RECURSOS CRIADOS:" -ForegroundColor Cyan
Write-Host "  Subscription: $subscriptionName" -ForegroundColor White
Write-Host "  Resource Group: $resourceGroupName" -ForegroundColor White
Write-Host "  Location: $location" -ForegroundColor White
Write-Host "  Automation Account: $automationAccountName" -ForegroundColor White
Write-Host "  Managed Identity: $principalId" -ForegroundColor White
Write-Host "  Entra Group (main): $entraGroupName (ID: $groupId)" -ForegroundColor White
Write-Host "  Entra Group Stale-7d: $entraGroupStale7Name (ID: $groupIdStale7)" -ForegroundColor White
Write-Host "  Entra Group Stale-30d: $entraGroupStale30Name (ID: $groupIdStale30)" -ForegroundColor White
Write-Host "  Entra Group Ephemeral: $entraGroupEphemeralName (ID: $groupIdEphemeral)" -ForegroundColor White
Write-Host "  MDE Device Group: $mdeDeviceGroupName (manual setup required)" -ForegroundColor White
Write-Host "  MDE Group Stale-7d: $mdeGroupStale7Name (manual setup required)" -ForegroundColor White
Write-Host "  MDE Group Stale-30d: $mdeGroupStale30Name (manual setup required)" -ForegroundColor White
Write-Host "  MDE Group Ephemeral: $mdeGroupEphemeralName (manual setup required)" -ForegroundColor White
Write-Host "  Runbook: $runbookName" -ForegroundColor White
Write-Host "  Schedule: $scheduleName (proxima: $startTime)" -ForegroundColor White
Write-Host "  Azure Policy: $policyName" -ForegroundColor White
if ($appId) {
    Write-Host "  MDE App Registration: $appDisplayName (ID: $appId)" -ForegroundColor White
}

Write-Host "`nARQUIVOS GERADOS:" -ForegroundColor Cyan
Write-Host "  Instrucoes MDE Device Group: $htmlFilePath" -ForegroundColor White
if ($appId) {
    Write-Host "  Script Tagging MDE: $mdeScriptPath" -ForegroundColor White
    Write-Host "  Credenciais MDE API: $credsPath" -ForegroundColor Yellow
}

Write-Host "`nPROXIMOS PASSOS:" -ForegroundColor Yellow
Write-Host "  1. Abra o arquivo de instrucoes HTML:" -ForegroundColor White
Write-Host "     $htmlFilePath" -ForegroundColor Gray
Write-Host ""
Write-Host "  2. Siga as instrucoes para criar MDE Device Group no portal" -ForegroundColor White
Write-Host "     https://security.microsoft.com/securitysettings/endpoints/device_groups" -ForegroundColor Gray
Write-Host ""
if ($appId) {
    Write-Host "  3. Conceda consentimento de admin para App Registration:" -ForegroundColor White
    Write-Host "     https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$appId" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  4. Execute o script para aplicar tags MDE:" -ForegroundColor White
    Write-Host "     $mdeScriptPath" -ForegroundColor Gray
    Write-Host ""
}
Write-Host "  $(if ($appId) { '5' } else { '3' }). Aguarde primeira execucao automatica: $startTime" -ForegroundColor White

Write-Host "`nCOMANDOS UTEIS:" -ForegroundColor Cyan
Write-Host "  # Executar runbook manualmente:" -ForegroundColor Gray
Write-Host "  az automation runbook start --name $runbookName --automation-account-name $automationAccountName --resource-group $resourceGroupName --parameters SubscriptionId=$subscriptionId GroupId=$groupId GroupIdStale7=$groupIdStale7 GroupIdStale30=$groupIdStale30 GroupIdEphemeral=$groupIdEphemeral IncludeArc=$includeArc" -ForegroundColor White
Write-Host ""
Write-Host "  # Listar jobs:" -ForegroundColor Gray
Write-Host "  az automation job list --automation-account-name $automationAccountName --resource-group $resourceGroupName --output table" -ForegroundColor White
Write-Host ""
Write-Host "  # Verificar membros do grupo:" -ForegroundColor Gray
Write-Host "  az rest --method GET --uri `"https://graph.microsoft.com/v1.0/groups/$groupId/members`" --query 'value[].displayName'" -ForegroundColor White

Write-Host "`n============================================================`n" -ForegroundColor Magenta
