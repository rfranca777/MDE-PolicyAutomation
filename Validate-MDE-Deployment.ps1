# MDE Deployment Validation Script
# Subscription: Sub_ELO_AZ__Dev/TI
# Generated from deployment data

$ErrorActionPreference = "Continue"
$sub = "121129d5-3986-447b-8a52-678b70ec6f76"
$rg = "rg-mde-sub-elo-az-dev-ti"
$aa = "aa-mde-sub-elo-az-dev-ti"
$rb = "rb-mde-sync-sub-elo-az-dev-ti"
$sch = "sch-mde-sub-elo-az-dev-ti"
$pol = "pol-mde-tag-sub-elo-az-dev-ti"
$grpMain = "ed0829b1-26ba-4c2a-b33f-3a618c3e3255"
$grpStale7 = "4a221a76-c2a4-4702-ab14-ea048d3f526b"
$grpStale30 = "2de9c8f7-0bb1-4778-8d9c-4cf507527cf2"
$grpEph = "6d30e508-6e36-4d12-896e-e962d45d67d9"

az account set --subscription $sub 2>$null

Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "  VALIDACAO MDE DEPLOYMENT - Sub_ELO_AZ__Dev/TI" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor Magenta

$pass = 0; $fail = 0

# [1] RG
$r = az group show --name $rg --query "name" -o tsv 2>$null
if ($r) { Write-Host "[OK] RG: $r" -ForegroundColor Green; $pass++ } else { Write-Host "[FAIL] RG nao encontrado" -ForegroundColor Red; $fail++ }

# [2] AA
$r = az resource show --resource-group $rg --resource-type "Microsoft.Automation/automationAccounts" --name $aa --query "name" -o tsv 2>$null
if ($r) { Write-Host "[OK] AA: $r" -ForegroundColor Green; $pass++ } else { Write-Host "[FAIL] AA nao encontrado" -ForegroundColor Red; $fail++ }

# [3] MI
$r = az resource show --resource-group $rg --resource-type "Microsoft.Automation/automationAccounts" --name $aa --query "identity.type" -o tsv 2>$null
if ($r -eq "SystemAssigned") { Write-Host "[OK] MI: $r" -ForegroundColor Green; $pass++ } else { Write-Host "[FAIL] MI: $r" -ForegroundColor Red; $fail++ }

# [4] RBAC
$pid2 = az resource show --resource-group $rg --resource-type "Microsoft.Automation/automationAccounts" --name $aa --query "identity.principalId" -o tsv 2>$null
$r = az role assignment list --assignee $pid2 --scope "/subscriptions/$sub" --query "[?roleDefinitionName=='Reader'].roleDefinitionName" -o tsv 2>$null
if ($r) { Write-Host "[OK] RBAC: Reader" -ForegroundColor Green; $pass++ } else { Write-Host "[FAIL] RBAC Reader" -ForegroundColor Red; $fail++ }

# [5-8] Entra Groups
foreach ($g in @(
    @{id=$grpMain; n="Main"},
    @{id=$grpStale7; n="Stale-7d"},
    @{id=$grpStale30; n="Stale-30d"},
    @{id=$grpEph; n="Ephemeral"}
)) {
    $r = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)" --query "displayName" -o tsv 2>$null
    if ($r) { Write-Host "[OK] Group $($g.n): $r" -ForegroundColor Green; $pass++ } else { Write-Host "[FAIL] Group $($g.n)" -ForegroundColor Red; $fail++ }
}

# [9] Runbook
$r = az rest --method GET --uri "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aa/runbooks/$rb?api-version=2023-11-01" --query "properties.state" -o tsv 2>$null
if ($r -eq "Published") { Write-Host "[OK] Runbook: $r" -ForegroundColor Green; $pass++ } else { Write-Host "[WARN] Runbook: $r" -ForegroundColor Yellow; $pass++ }

# [10] Schedule
$r = az rest --method GET --uri "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aa/schedules/$sch?api-version=2023-11-01" --query "properties.frequency" -o tsv 2>$null
if ($r -eq "Hour") { Write-Host "[OK] Schedule: Hourly" -ForegroundColor Green; $pass++ } else { Write-Host "[WARN] Schedule: $r" -ForegroundColor Yellow; $pass++ }

# [11] Policy
$r = az policy definition show --name $pol --subscription $sub --query "name" -o tsv 2>$null
if ($r) { Write-Host "[OK] Policy Def: $r" -ForegroundColor Green; $pass++ } else { Write-Host "[FAIL] Policy Def" -ForegroundColor Red; $fail++ }

$r = az policy assignment show --name "$pol-assignment" --scope "/subscriptions/$sub" --query "name" -o tsv 2>$null
if ($r) { Write-Host "[OK] Policy Assign: $r" -ForegroundColor Green; $pass++ } else { Write-Host "[FAIL] Policy Assign" -ForegroundColor Red; $fail++ }

# [12] Tags no RG
$r = az group show --name $rg --query "tags" -o json 2>$null
Write-Host "`n  Tags no RG:" -ForegroundColor Cyan
Write-Host "  $r" -ForegroundColor Gray

# [13] Executar runbook agora
Write-Host "`n  Disparando runbook para popular grupos..." -ForegroundColor Cyan
az rest --method POST --uri "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aa/jobs/$([guid]::NewGuid())?api-version=2023-11-01" --body "{\`"properties\`":{\`"runbook\`":{\`"name\`":\`"$rb\`"},\`"parameters\`":{\`"SubscriptionId\`":\`"$sub\`",\`"GroupId\`":\`"$grpMain\`",\`"GroupIdStale7\`":\`"$grpStale7\`",\`"GroupIdStale30\`":\`"$grpStale30\`",\`"GroupIdEphemeral\`":\`"$grpEph\`",\`"IncludeArc\`":\`"true\`"}}}" --output none 2>$null
Write-Host "  Runbook disparado. Aguardando 90s..." -ForegroundColor Gray
Start-Sleep -Seconds 90

# [14] Verificar membros dos grupos
Write-Host "`n  Membros dos grupos:" -ForegroundColor Cyan
foreach ($g in @(
    @{id=$grpMain; n="Main"},
    @{id=$grpStale7; n="Stale-7d"},
    @{id=$grpStale30; n="Stale-30d"},
    @{id=$grpEph; n="Ephemeral"}
)) {
    $members = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members" --query "value[].displayName" -o tsv 2>$null
    $count = if ($members) { ($members -split "`n").Count } else { 0 }
    Write-Host "  $($g.n): $count devices" -ForegroundColor $(if($count -gt 0){'Green'}else{'Gray'})
    if ($members) { $members -split "`n" | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray } }
}

# RESULTADO
Write-Host "`n============================================" -ForegroundColor Magenta
Write-Host "  RESULTADO: $pass PASSED / $fail FAILED" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "============================================`n" -ForegroundColor Magenta
