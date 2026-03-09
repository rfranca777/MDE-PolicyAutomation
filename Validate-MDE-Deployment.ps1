<#
.SYNOPSIS
    MDE Deployment Validation + Sync - Sub_ELO_AZ__Dev/TI
.DESCRIPTION
    Valida todos os recursos criados, dispara runbook, aguarda conclusao,
    e verifica se os devices foram sincronizados nos grupos.
#>

$ErrorActionPreference = "Continue"

# === PARAMETROS DO DEPLOYMENT ===
$sub       = "121129d5-3986-447b-8a52-678b70ec6f76"
$subName   = "Sub_ELO_AZ__Dev/TI"
$rg        = "rg-mde-sub-elo-az-dev-ti"
$aa        = "aa-mde-sub-elo-az-dev-ti"
$rb        = "rb-mde-sync-sub-elo-az-dev-ti"
$sch       = "sch-mde-sub-elo-az-dev-ti"
$pol       = "pol-mde-tag-sub-elo-az-dev-ti"
$grpMain   = "ed0829b1-26ba-4c2a-b33f-3a618c3e3255"
$grpStale7 = "4a221a76-c2a4-4702-ab14-ea048d3f526b"
$grpStale30= "2de9c8f7-0bb1-4778-8d9c-4cf507527cf2"
$grpEph    = "6d30e508-6e36-4d12-896e-e962d45d67d9"
$baseUri   = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$aa"

az account set --subscription $sub 2>$null

Write-Host "`n====================================================" -ForegroundColor Magenta
Write-Host "  VALIDACAO + SYNC - $subName" -ForegroundColor White
Write-Host "====================================================`n" -ForegroundColor Magenta

$pass = 0; $fail = 0

# =============================================
# FASE 1: VALIDACAO DE RECURSOS
# =============================================
Write-Host "--- FASE 1: VALIDACAO DE RECURSOS ---`n" -ForegroundColor Cyan

$r = az group show --name $rg --query "name" -o tsv 2>$null
if ($r) { Write-Host "  [OK] Resource Group: $r" -ForegroundColor Green; $pass++ } else { Write-Host "  [FAIL] Resource Group" -ForegroundColor Red; $fail++ }

$r = az resource show --resource-group $rg --resource-type "Microsoft.Automation/automationAccounts" --name $aa --query "name" -o tsv 2>$null
if ($r) { Write-Host "  [OK] Automation Account: $r" -ForegroundColor Green; $pass++ } else { Write-Host "  [FAIL] Automation Account" -ForegroundColor Red; $fail++ }

$miType = az resource show --resource-group $rg --resource-type "Microsoft.Automation/automationAccounts" --name $aa --query "identity.type" -o tsv 2>$null
$miPid = az resource show --resource-group $rg --resource-type "Microsoft.Automation/automationAccounts" --name $aa --query "identity.principalId" -o tsv 2>$null
if ($miType -eq "SystemAssigned" -and $miPid) { Write-Host "  [OK] Managed Identity: $miType (PID: $miPid)" -ForegroundColor Green; $pass++ } else { Write-Host "  [FAIL] Managed Identity" -ForegroundColor Red; $fail++ }

$r = az role assignment list --assignee $miPid --scope "/subscriptions/$sub" --query "[?roleDefinitionName=='Reader'].roleDefinitionName" -o tsv 2>$null
if ($r) { Write-Host "  [OK] RBAC: Reader assigned" -ForegroundColor Green; $pass++ } else { Write-Host "  [FAIL] RBAC Reader" -ForegroundColor Red; $fail++ }

foreach ($g in @(
    @{id=$grpMain;    n="Main";      dn="grp-mde-sub-elo-az-dev-ti"},
    @{id=$grpStale7;  n="Stale-7d";  dn="grp-mde-sub-elo-az-dev-ti-stale7"},
    @{id=$grpStale30; n="Stale-30d"; dn="grp-mde-sub-elo-az-dev-ti-stale30"},
    @{id=$grpEph;     n="Ephemeral"; dn="grp-mde-sub-elo-az-dev-ti-ephemeral"}
)) {
    $r = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)" --query "displayName" -o tsv 2>$null
    if ($r -eq $g.dn) { Write-Host "  [OK] Group $($g.n): $r" -ForegroundColor Green; $pass++ }
    elseif ($r) { Write-Host "  [WARN] Group $($g.n): $r" -ForegroundColor Yellow; $pass++ }
    else { Write-Host "  [FAIL] Group $($g.n) nao encontrado" -ForegroundColor Red; $fail++ }
}

$r = az rest --method GET --uri "$baseUri/runbooks/$rb`?api-version=2023-11-01" --query "properties.state" -o tsv 2>$null
if ($r -eq "Published") { Write-Host "  [OK] Runbook: Published" -ForegroundColor Green; $pass++ } else { Write-Host "  [WARN] Runbook: $r" -ForegroundColor Yellow; $pass++ }

$r = az rest --method GET --uri "$baseUri/schedules/$sch`?api-version=2023-11-01" --query "properties.frequency" -o tsv 2>$null
if ($r -eq "Hour") { Write-Host "  [OK] Schedule: Hourly" -ForegroundColor Green; $pass++ } else { Write-Host "  [WARN] Schedule: $r" -ForegroundColor Yellow; $pass++ }

$r = az policy definition show --name $pol --subscription $sub --query "name" -o tsv 2>$null
if ($r) { Write-Host "  [OK] Policy Def: $r" -ForegroundColor Green; $pass++ } else { Write-Host "  [FAIL] Policy Def" -ForegroundColor Red; $fail++ }

$r = az policy assignment show --name "$pol-assignment" --scope "/subscriptions/$sub" --query "name" -o tsv 2>$null
if ($r) { Write-Host "  [OK] Policy Assignment: $r" -ForegroundColor Green; $pass++ } else { Write-Host "  [FAIL] Policy Assignment" -ForegroundColor Red; $fail++ }

Write-Host "`n  Tags:" -ForegroundColor Cyan
az group show --name $rg --query "tags" -o json 2>$null

Write-Host "`n  FASE 1: $pass OK / $fail FAIL`n" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})

# =============================================
# FASE 2: EXECUTAR RUNBOOK
# =============================================
Write-Host "--- FASE 2: EXECUTAR RUNBOOK ---`n" -ForegroundColor Cyan

$jobId = [guid]::NewGuid().ToString()
$jobBody = @{
    properties = @{
        runbook = @{ name = $rb }
        parameters = @{
            SubscriptionId   = $sub
            GroupId          = $grpMain
            GroupIdStale7    = $grpStale7
            GroupIdStale30   = $grpStale30
            GroupIdEphemeral = $grpEph
            IncludeArc       = "true"
        }
    }
} | ConvertTo-Json -Depth 10

if (-not (Test-Path "C:\temp")) { New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null }
$jobFile = "C:\temp\job-body.json"
$jobBody | Out-File $jobFile -Encoding UTF8 -Force -NoNewline

$jobUri = "$baseUri/jobs/$jobId`?api-version=2023-11-01"

Write-Host "  Disparando runbook..." -ForegroundColor Yellow
$jobResult = az rest --method PUT --uri $jobUri --body "@$jobFile" -o json 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  [OK] Job disparado (ID: $jobId)" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Erro: $jobResult" -ForegroundColor Red
    Write-Host "  Abortando." -ForegroundColor Red
    return
}

Write-Host "  Aguardando conclusao (max 3 min)..." -ForegroundColor Gray
$status = "Unknown"
for ($w = 15; $w -le 180; $w += 15) {
    Start-Sleep -Seconds 15
    $status = az rest --method GET --uri $jobUri --query "properties.status" -o tsv 2>$null
    Write-Host "  [$($w)s] $status" -ForegroundColor $(switch($status){'Completed'{'Green'}'Failed'{'Red'}'Stopped'{'Red'}default{'Gray'}})
    if ($status -match 'Completed|Failed|Stopped') { break }
}

if ($status -eq "Completed") { Write-Host "  [OK] Runbook concluido!`n" -ForegroundColor Green }
elseif ($status -match 'Failed|Stopped') { Write-Host "  [FAIL] Runbook: $status`n" -ForegroundColor Red }
else { Write-Host "  [WARN] Timeout. Job pode ainda estar a correr.`n" -ForegroundColor Yellow }

# =============================================
# FASE 3: VERIFICAR SINCRONIZACAO
# =============================================
Write-Host "--- FASE 3: SINCRONIZACAO ---`n" -ForegroundColor Cyan

Write-Host "  VMs na subscription:" -ForegroundColor Yellow
az vm list --subscription $sub --query "[].{Nome:name, RG:resourceGroup, OS:storageProfile.osDisk.osType}" -o table 2>$null

$totalAll = 0
Write-Host "`n  Devices nos grupos:" -ForegroundColor Yellow
foreach ($g in @(
    @{id=$grpMain;    n="Main"},
    @{id=$grpStale7;  n="Stale-7d"},
    @{id=$grpStale30; n="Stale-30d"},
    @{id=$grpEph;     n="Ephemeral"}
)) {
    $raw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members" --query "value[].displayName" -o json 2>$null
    $list = @()
    if ($raw) { try { $list = $raw | ConvertFrom-Json } catch {} }
    $c = $list.Count
    $totalAll += $c
    Write-Host "  $($g.n): $c devices" -ForegroundColor $(if($c -gt 0){'Green'}else{'Gray'})
    foreach ($m in $list) { Write-Host "    - $m" -ForegroundColor DarkGray }
}

# =============================================
# RESULTADO
# =============================================
Write-Host "`n====================================================" -ForegroundColor Magenta
Write-Host "  RESULTADO FINAL" -ForegroundColor White
Write-Host "  Subscription: $subName ($sub)" -ForegroundColor Gray
Write-Host "  Recursos: $pass OK / $fail FAIL" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
Write-Host "  Runbook: $status" -ForegroundColor $(if($status -eq 'Completed'){'Green'}else{'Yellow'})
Write-Host "  Total devices em grupos: $totalAll" -ForegroundColor $(if($totalAll -gt 0){'Green'}else{'Yellow'})
if ($totalAll -eq 0) {
    Write-Host "`n  [INFO] 0 devices pode significar:" -ForegroundColor Yellow
    Write-Host "    - VMs sem Entra ID device registration (agent nao instalado)" -ForegroundColor Gray
    Write-Host "    - VMs sem sign-in recente (vao para Stale/Ephemeral)" -ForegroundColor Gray
    Write-Host "    - Verifique: Entra ID > Devices > All devices" -ForegroundColor Gray
}
Write-Host "====================================================`n" -ForegroundColor Magenta
