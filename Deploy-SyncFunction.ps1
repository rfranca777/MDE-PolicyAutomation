# Deploy-SyncFunction.ps1
# Creates Azure Function App for MDE Group Sync (Timer 12/12h)
# Prereq: Deploy-MDE-v2.ps1 executed first (creates groups + App Registration)
# Version: 1.0.0 | Author: Rafael Franca

param(
    [string]$ResourceGroupName,
    [string]$Location = "eastus",
    [string]$FunctionAppName = "func-mde-sync",
    [string]$SubscriptionIds,
    [string]$MdeAppId,
    [string]$MdeTenantId
)

$ErrorActionPreference = "Stop"

$context = az account show -o json 2>$null | ConvertFrom-Json
if (-not $context) { Write-Host "Run 'az login' first." -Fore Red; exit 1 }

$tenantId = $context.tenantId
if (-not $MdeTenantId) { $MdeTenantId = $tenantId }

Write-Host "`n=== MDE SYNC FUNCTION DEPLOY ===" -Fore Magenta
Write-Host "Tenant: $tenantId"
Write-Host "Sub: $($context.name) ($($context.id))"

if (-not $ResourceGroupName) {
    Write-Host "`nResource Group name: " -NoNewline -Fore Cyan; $ResourceGroupName = Read-Host
}
if (-not $SubscriptionIds) {
    Write-Host "Subscription IDs to sync (comma-separated): " -NoNewline -Fore Cyan; $SubscriptionIds = Read-Host
}
if (-not $MdeAppId) {
    Write-Host "MDE App Registration Client ID (from Stage 9): " -NoNewline -Fore Cyan; $MdeAppId = Read-Host
}

$storageName = "stmdesync$(Get-Random -Min 10000 -Max 99999)"

# [1/5] STORAGE ACCOUNT
Write-Host "`n[1/5] STORAGE ACCOUNT" -Fore Cyan
az storage account create --name $storageName --resource-group $ResourceGroupName --location $Location --sku Standard_LRS --allow-shared-key-access true --output none 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Falha ao criar storage" -Fore Red; exit 1 }
Write-Host "  [OK] $storageName" -Fore Green

# [2/5] FUNCTION APP
Write-Host "`n[2/5] FUNCTION APP" -Fore Cyan
az functionapp create --name $FunctionAppName --resource-group $ResourceGroupName --storage-account $storageName --consumption-plan-location $Location --runtime powershell --runtime-version 7.4 --functions-version 4 --os-type Windows --assign-identity "[system]" --output none 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Falha ao criar Function App" -Fore Red; exit 1 }
Write-Host "  [OK] $FunctionAppName (Managed Identity enabled)" -Fore Green

$miPrincipalId = az functionapp identity show --name $FunctionAppName --resource-group $ResourceGroupName --query "principalId" -o tsv 2>$null
Write-Host "  MI Principal: $miPrincipalId" -Fore Gray

# [3/5] APP SETTINGS
Write-Host "`n[3/5] APP SETTINGS" -Fore Cyan
az functionapp config appsettings set --name $FunctionAppName --resource-group $ResourceGroupName --settings "SUBSCRIPTION_IDS=$SubscriptionIds" "MDE_APP_ID=$MdeAppId" "MDE_TENANT_ID=$MdeTenantId" --output none 2>$null
Write-Host "  [OK] SUBSCRIPTION_IDS, MDE_APP_ID, MDE_TENANT_ID" -Fore Green
Write-Host "  [WARN] Set MDE_APP_SECRET manually (Key Vault reference):" -Fore Yellow
Write-Host "    az functionapp config appsettings set --name $FunctionAppName --resource-group $ResourceGroupName --settings MDE_APP_SECRET=your-secret" -Fore DarkGray

# [4/5] GRAPH API PERMISSIONS
Write-Host "`n[4/5] GRAPH API PERMISSIONS" -Fore Cyan

$graphAppId = "00000003-0000-0000-c000-000000000000"
$graphSpId = az ad sp show --id $graphAppId --query "id" -o tsv 2>$null

$groupRwId = az ad sp show --id $graphAppId --query "appRoles[?value=='GroupMember.ReadWrite.All'].id" -o tsv 2>$null
$deviceReadId = az ad sp show --id $graphAppId --query "appRoles[?value=='Device.Read.All'].id" -o tsv 2>$null

foreach ($roleId in @($groupRwId, $deviceReadId)) {
    if ($roleId -and $miPrincipalId -and $graphSpId) {
        $body = @{ principalId = $miPrincipalId; resourceId = $graphSpId; appRoleId = $roleId } | ConvertTo-Json
        $bodyFile = Join-Path $env:TEMP "grant-$roleId.json"
        $body | Out-File $bodyFile -Encoding UTF8 -Force -NoNewline
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$miPrincipalId/appRoleAssignments" --headers "Content-Type=application/json" --body "@$bodyFile" --output none 2>&1 | Out-Null
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "  [OK] GroupMember.ReadWrite.All + Device.Read.All" -Fore Green

# [5/5] DEPLOY CODE
Write-Host "`n[5/5] DEPLOY CODE" -Fore Cyan
$funcTools = Get-Command func -ErrorAction SilentlyContinue
$syncPath = Join-Path $PSScriptRoot "sync-function"

if ($funcTools -and (Test-Path $syncPath)) {
    Push-Location $syncPath
    func azure functionapp publish $FunctionAppName --powershell 2>&1
    Pop-Location
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Code deployed" -Fore Green
    } else {
        Write-Host "  [WARN] Publish failed. Manual deploy:" -Fore Yellow
        Write-Host "    cd sync-function; func azure functionapp publish $FunctionAppName" -Fore DarkGray
    }
} else {
    Write-Host "  [WARN] func tools not found. Install + deploy:" -Fore Yellow
    Write-Host "    npm i -g azure-functions-core-tools@4" -Fore DarkGray
    Write-Host "    cd sync-function; func azure functionapp publish $FunctionAppName" -Fore DarkGray
}

# SUMMARY
Write-Host "`n============================================================" -Fore Green
Write-Host "  FUNCTION APP DEPLOYED" -Fore White
Write-Host "============================================================" -Fore Green
Write-Host "  Name: $FunctionAppName" -Fore White
Write-Host "  RG: $ResourceGroupName" -Fore White
Write-Host "  Storage: $storageName" -Fore White
Write-Host "  MI: $miPrincipalId" -Fore White
Write-Host "  Schedule: Every 12h (0 0 */12 * * *)" -Fore White
Write-Host "  Subs: $SubscriptionIds" -Fore White
Write-Host "" -Fore White
Write-Host "  NEXT STEPS:" -Fore Yellow
Write-Host "  1. Set MDE_APP_SECRET (Key Vault reference recommended)" -Fore Gray
Write-Host "  2. Grant MI Reader role on each subscription:" -Fore Gray
foreach ($sid in ($SubscriptionIds -split ',')) {
    $sid = $sid.Trim()
    if ($sid) {
        Write-Host "     az role assignment create --assignee $miPrincipalId --role Reader --scope /subscriptions/$sid" -Fore DarkGray
    }
}
Write-Host "  3. Verify: portal.azure.com > $FunctionAppName > Functions" -Fore Gray
Write-Host "============================================================`n" -Fore Green
