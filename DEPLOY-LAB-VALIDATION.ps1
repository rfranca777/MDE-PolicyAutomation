<#
.SYNOPSIS
    Lab Validation - Deploy MDE Device Tag Azure Policy (SecurityLab)
    
.DESCRIPTION
    Deploys the Azure Policy for MDE Device Tags using the GitHub-hosted script.
    Uses the published community repo at github.com/rfranca777/MDE-PolicyAutomation
    
.NOTES
    Author  : Rafael França | Microsoft CSA Cyber Security
    Lab     : SecurityLab / ME-MngEnvMCAP186458-rafaelluizf-1
    Target  : lab-agencia4, lab-mde-policy-tag-mng
    
.USAGE
    cd C:\vscode\MDE-PolicyAutomation
    .\DEPLOY-LAB-VALIDATION.ps1
#>

$ErrorActionPreference = "Stop"

#region CONFIGURATION
$SubscriptionId    = "fbb41bf3-dc95-4c71-8e14-396d3ed38b91"
$ResourceGroup     = "SecurityLab"
$PolicyName        = "mde-device-tag-windows-vms"
$PolicyDisplayName = "Deploy MDE Device Tag to Windows Virtual Machines"
$AssignmentName    = "mde-tag-securitylab"
## TagValue segue a mesma lógica do projeto original v1.0.4:
## $subNameClean = $subscriptionName -replace '[^a-zA-Z0-9-]','-' -replace '--+','-' -replace '^-|-$',''
## $subNameShort = $subNameClean.Substring(0,[Math]::Min(40,$subNameClean.Length)).ToLower()
## $TagValue     = "mde-policy-$subNameShort"
$TagValue          = "mde-policy-me-mngenvmcap186458-rafaelluizf-1"
# Script hosted on GitHub community repo (no storage dependency)
$ScriptUri         = "https://raw.githubusercontent.com/rfranca777/MDE-PolicyAutomation/main/azure-policy/Set-MDEDeviceTag.ps1"
$PolicyDefFile     = "$PSScriptRoot\azure-policy\policy-definition.json"
#endregion

#region HELPERS
function Write-Step { param($n,$msg) Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg)    Write-Host "  ✓ $msg"   -ForegroundColor Green }
function Write-Warn { param($msg)    Write-Host "  ⚠ $msg"   -ForegroundColor Yellow }
function Write-Err  { param($msg)    Write-Host "  ✗ $msg"   -ForegroundColor Red }
#endregion

Write-Host @"

╔══════════════════════════════════════════════════════════╗
║   MDE Policy Automation — Lab Validation Deploy          ║
║   SecurityLab | rfranca777/MDE-PolicyAutomation          ║
╚══════════════════════════════════════════════════════════╝

"@ -ForegroundColor Magenta

#region STEP 1 — Verify Azure CLI auth
Write-Step "1/6" "Verifying Azure CLI authentication..."
try {
    $account = az account show --subscription $SubscriptionId -o json 2>&1 | ConvertFrom-Json
    Write-OK "Logged in as: $($account.user.name)"
    Write-OK "Subscription: $($account.name)"
    Write-OK "Tenant: $($account.tenantId)"
} catch {
    Write-Err "Not logged in. Run: az login"
    exit 1
}
#endregion

#region STEP 2 — Set active subscription
Write-Step "2/6" "Setting active subscription..."
az account set --subscription $SubscriptionId 2>&1 | Out-Null
Write-OK "Subscription set: $SubscriptionId"
#endregion

#region STEP 3 — Deploy/Update Policy Definition
Write-Step "3/6" "Deploying Azure Policy definition..."
if (-not (Test-Path $PolicyDefFile)) {
    Write-Err "Policy definition not found: $PolicyDefFile"
    exit 1
}

# Parse full policy JSON and extract sections to temp files (az CLI requires separate files)
$policyObj     = Get-Content $PolicyDefFile -Raw | ConvertFrom-Json
$rulesFile     = [System.IO.Path]::GetTempFileName() + ".json"
$paramsFile    = [System.IO.Path]::GetTempFileName() + ".json"
($policyObj.policyRule  | ConvertTo-Json -Depth 20) | Set-Content $rulesFile  -Encoding UTF8
($policyObj.parameters  | ConvertTo-Json -Depth 20) | Set-Content $paramsFile -Encoding UTF8

$existing = az policy definition show --name $PolicyName --subscription $SubscriptionId 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Warn "Policy already exists — updating..."
    az policy definition update `
        --name $PolicyName `
        --display-name $PolicyDisplayName `
        --description "ODefender Community - github.com/rfranca777/MDE-PolicyAutomation" `
        --rules "@$rulesFile" `
        --params "@$paramsFile" `
        --mode "Indexed" `
        --subscription $SubscriptionId 2>&1 | Out-Null
} else {
    az policy definition create `
        --name $PolicyName `
        --display-name $PolicyDisplayName `
        --description "ODefender Community - github.com/rfranca777/MDE-PolicyAutomation" `
        --rules "@$rulesFile" `
        --params "@$paramsFile" `
        --mode "Indexed" `
        --subscription $SubscriptionId 2>&1 | Out-Null
}
Remove-Item $rulesFile, $paramsFile -ErrorAction SilentlyContinue
if ($LASTEXITCODE -ne 0) { Write-Err "Failed to create/update policy definition"; exit 1 }
Write-OK "Policy definition deployed: $PolicyName"
$policyDefId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyDefinitions/$PolicyName"
Write-OK "Policy ID: $policyDefId"
#endregion

#region STEP 4 — Assign Policy to SecurityLab RG
Write-Step "4/6" "Assigning policy to ResourceGroup: $ResourceGroup..."
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

# Check if assignment exists
$existingAssignment = az policy assignment show --name $AssignmentName --scope $rgScope 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Warn "Assignment already exists — will reuse"
} else {
    az policy assignment create `
        --name $AssignmentName `
        --display-name "MDE Device Tag | SecurityLab" `
        --policy $policyDefId `
        --scope $rgScope `
        --assign-identity `
        --identity-scope $rgScope `
        --role "Contributor" `
        --location "eastus2" `
        --params "{
            `"tagValue`": { `"value`": `"$TagValue`" },
            `"scriptUri`": { `"value`": `"$ScriptUri`" },
            `"effect`": { `"value`": `"DeployIfNotExists`" }
        }" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to create policy assignment"; exit 1 }
}
$assignment = az policy assignment show --name $AssignmentName --scope $rgScope -o json 2>&1 | ConvertFrom-Json
$miPrincipalId = $assignment.identity.principalId
Write-OK "Assignment created: $AssignmentName"
Write-OK "Managed Identity Principal: $miPrincipalId"
#endregion

#region STEP 5 — Trigger compliance evaluation
Write-Step "5/6" "Triggering policy compliance evaluation..."
az policy state trigger-scan --resource-group $ResourceGroup --no-wait 2>&1 | Out-Null
Write-OK "Compliance scan triggered (async — results in 5-10 min)"
Write-OK "Monitor at: portal.azure.com → Policy → Compliance"
#endregion

#region STEP 6 — Apply directly to VMs (immediate validation)
Write-Step "6/6" "Applying tag directly to lab VMs for immediate validation..."
$vms = @("lab-agencia4", "lab-mde-policy-tag-mng")
foreach ($vmName in $vms) {
    Write-Host "`n  → Applying to: $vmName" -ForegroundColor White
    
    # Check VM power state
    $state = az vm get-instance-view -g $ResourceGroup -n $vmName --query "instanceView.statuses[1].displayStatus" -o tsv 2>&1
    if ($state -ne "VM running") {
        Write-Warn "$vmName is not running ($state) — skipping"
        continue
    }
    
    # Apply registry directly via Run Command (immediate — no policy propagation wait)
    $result = az vm run-command invoke `
        -g $ResourceGroup `
        -n $vmName `
        --command-id RunPowerShellScript `
        --scripts @"
`$regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'
if (-not (Test-Path `$regPath)) { New-Item -Path `$regPath -Force | Out-Null }
Set-ItemProperty -Path `$regPath -Name 'Group' -Value '$TagValue' -Type String -Force
`$val = (Get-ItemProperty -Path `$regPath -Name 'Group').Group
Write-Host ('TAG SET: ' + `$val)
Get-Service Sense | Select-Object Status,StartType | Format-Table
"@ `
        --query "value[0].message" -o tsv 2>&1
    
    if ($result -match "TAG SET") {
        Write-OK "$vmName → Tag applied: $TagValue"
        $result | Where-Object {$_ -match "TAG|Sense|Status"} | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
    } else {
        Write-Warn "$vmName → Result: $result"
    }
}
#endregion

#region SUMMARY
Write-Host @"

╔══════════════════════════════════════════════════════════╗
║   VALIDATION SUMMARY                                     ║
╠══════════════════════════════════════════════════════════╣
║  Policy Definition : $PolicyName
║  Assignment        : $AssignmentName
║  Scope             : $ResourceGroup
║  Tag Applied       : $TagValue
║  Script Source     : GitHub (rfranca777/MDE-PolicyAutomation)
╠══════════════════════════════════════════════════════════╣
║  NEXT STEPS:                                             ║
║  1. MDE Portal → Devices → filter tag: $TagValue
║     https://security.microsoft.com/machines              ║
║  2. Azure Portal → Policy → Compliance                   ║
║     Assignment: $AssignmentName
║  3. Check MDE Device Groups in portal                    ║
╚══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Green
#endregion
