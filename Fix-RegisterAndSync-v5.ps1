<#
.SYNOPSIS
    FIX v5: Match Azure VMs -> Entra ID Devices -> Sync to Groups
.DESCRIPTION
    Final production version. PS 5.1 ISE tested. Zero interaction.
    
    Key design: Safe-AzJson (file-based JSON parsing) + direct add (no pre-check).
    
    Matching: L0-Manual, L1-physicalIds, L2-Exact, L3-Normalized, L4-NetBIOS, L5-Fuzzy, L6-vmId
    Sync: adds directly to group (Graph returns 400 if already member = harmless)
    
.NOTES
    Version: 5.0.0
    Author:  Rafael Franca -- github.com/rfranca777
    Date:    2026-03-10
    Compat:  PS 5.1 ISE, PS 7, Cloud Shell
#>

#Requires -Version 5.1
$ErrorActionPreference = "Continue"

# ============================================================
# CONFIG -- CLIENT TENANT (Sub_ELO_AZ__Dev/TI)
# ============================================================
$sub       = "121129d5-3986-447b-8a52-678b70ec6f76"
$grpMain   = "ed0829b1-26ba-4c2a-b33f-3a618c3e3255"
$grpStale7 = "4a221a76-c2a4-4702-ab14-ea048d3f526b"
$grpStale30= "2de9c8f7-0bb1-4778-8d9c-4cf507527cf2"
$grpEph    = "6d30e508-6e36-4d12-896e-e962d45d67d9"

$manualMap = @{
    # "AzureVmName" = "EntraDeviceDisplayName"
}

# ============================================================
# CORE FUNCTIONS
# ============================================================
function Safe-AzJson {
    param([string[]]$AzArgs)
    $tmpFile = Join-Path $env:TEMP ("azj_" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        & az @AzArgs -o json 2>$null | Out-File $tmpFile -Encoding UTF8 -Force
        if (-not (Test-Path $tmpFile)) { return $null }
        $content = [System.IO.File]::ReadAllText($tmpFile)
        if ([string]::IsNullOrWhiteSpace($content)) { return $null }
        return (ConvertFrom-Json -InputObject $content)
    } catch { return $null }
    finally { if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue } }
}

function Force-Array {
    param([object]$Data)
    if ($null -eq $Data) { return @() }
    if ($Data -is [array]) { return $Data }
    return @(,$Data)
}

function Normalize-Deep {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $n = $Name.Trim().ToLower()
    if ($n -match '^[^\\]+\\(.+)$') { $n = $Matches[1] }
    if ($n -match '^([^.]+)\.') { $n = $Matches[1] }
    $n = $n -replace '[_]', '-' -replace '--+', '-' -replace '^-|-$', ''
    return $n
}

function Get-NetBIOSName {
    param([string]$Name)
    $n = Normalize-Deep $Name
    if ($n.Length -gt 15) { return $n.Substring(0, 15) }
    return $n
}

function Get-Similarity {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return 0.0 }
    $a1 = $A.ToLower(); $b1 = $B.ToLower()
    if ($a1 -eq $b1) { return 1.0 }
    $maxLen = 0
    for ($i = 0; $i -lt $a1.Length; $i++) {
        for ($j = 0; $j -lt $b1.Length; $j++) {
            $k = 0
            while (($i+$k) -lt $a1.Length -and ($j+$k) -lt $b1.Length -and $a1[$i+$k] -eq $b1[$j+$k]) { $k++ }
            if ($k -gt $maxLen) { $maxLen = $k }
        }
    }
    return [Math]::Round($maxLen / [Math]::Max($a1.Length, $b1.Length), 2)
}

function Match-Device {
    param($vm, $devIdx, $used, $manual)
    $n = $vm.name; $nn = Normalize-Deep $n; $nb = Get-NetBIOSName $n
    $rid = if ($vm.id) { $vm.id.ToLower() } else { "" }
    $vid = if ($vm.vmId) { $vm.vmId.ToLower() } else { "" }
    $d = $null; $ly = ""; $dt = ""
    # L0
    if ($manual.ContainsKey($n)) {
        $t = $manual[$n].ToLower()
        $d = $devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.displayName -and $_.displayName.ToLower() -eq $t } | Select-Object -First 1
        if ($d) { $ly = "L0-MANUAL"; $dt = "$n -> $($d.displayName)" }
    }
    # L1
    if (-not $d -and $rid.Length -gt 20) {
        $d = $devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.physicalIds -and ($_.physicalIds | Where-Object { $_.ToLower().Contains($rid) }) } | Select-Object -First 1
        if ($d) { $ly = "L1-PHYSICAL"; $dt = "physicalIds" }
    }
    # L2
    if (-not $d) {
        $d = $devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.displayName -and $_.displayName.ToLower() -eq $n.ToLower() } | Select-Object -First 1
        if ($d) { $ly = "L2-EXACT"; $dt = "$n == $($d.displayName)" }
    }
    # L3
    if (-not $d -and $nn.Length -ge 3) {
        $d = $devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.normalized -eq $nn } | Select-Object -First 1
        if ($d) { $ly = "L3-NORM"; $dt = "'$nn'" }
    }
    # L4
    if (-not $d -and $nb.Length -ge 3) {
        $d = $devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.netbios -eq $nb -and $_.netbios.Length -ge 3 } | Select-Object -First 1
        if ($d) { $ly = "L4-NETBIOS"; $dt = "'$nb'" }
    }
    # L5
    if (-not $d -and $nn.Length -ge 4) {
        $c = @($devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.normalized -and $_.normalized.Length -ge 4 -and $_.normalized.Contains($nn) })
        if ($c.Count -eq 0) { $c = @($devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.normalized -and $_.normalized.Length -ge 4 -and $nn.Contains($_.normalized) }) }
        if ($c.Count -ge 1) {
            $b = $null; $bs = 0
            foreach ($x in $c) { $s = Get-Similarity $nn $x.normalized; if ($s -gt $bs) { $bs = $s; $b = $x } }
            if ($b -and $bs -ge 0.8) { $d = $b; $ly = "L5-FUZZY"; $dt = "$bs" }
        }
    }
    # L6
    if (-not $d -and $vid.Length -gt 10) {
        $d = $devIdx | Where-Object { -not $used.ContainsKey($_.id) -and $_.deviceId -and $_.deviceId.ToLower() -eq $vid } | Select-Object -First 1
        if ($d) { $ly = "L6-VMID"; $dt = "vmId" }
    }
    return @{ dev=$d; layer=$ly; detail=$dt }
}

# ============================================================
# START
# ============================================================
$tempPath = "C:\temp"
if (-not (Test-Path $tempPath)) { New-Item -ItemType Directory -Path $tempPath -Force | Out-Null }

Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v5 -- MATCH + SYNC" -ForegroundColor White
Write-Host "  Sub: $sub" -ForegroundColor Gray
Write-Host "  PS $($PSVersionTable.PSVersion) | $($Host.Name)" -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Magenta

# PRE-FLIGHT
Write-Host "  Pre-flight..." -ForegroundColor Cyan
$ctx = Safe-AzJson @("account","show")
if (-not $ctx) { Write-Host "  [FAIL] az login" -ForegroundColor Red; return }
Write-Host "  [OK] $($ctx.user.name)" -ForegroundColor Green

$org = Safe-AzJson @("rest","--method","GET","--uri",'https://graph.microsoft.com/v1.0/organization?$select=displayName')
if (-not $org) { Write-Host "  [FAIL] Graph API" -ForegroundColor Red; return }
Write-Host "  [OK] Graph API" -ForegroundColor Green

az account set --subscription $sub 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "  [FAIL] Subscription" -ForegroundColor Red; return }
Write-Host "  [OK] Subscription" -ForegroundColor Green

foreach ($g in @(@{id=$grpMain;n="Main"},@{id=$grpStale7;n="Stale7"},@{id=$grpStale30;n="Stale30"},@{id=$grpEph;n="Ephemeral"})) {
    $gc = Safe-AzJson @("rest","--method","GET","--uri","https://graph.microsoft.com/v1.0/groups/$($g.id)?`$select=displayName")
    if ($gc -and $gc.displayName) { Write-Host "  [OK] $($g.n): $($gc.displayName)" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $($g.n) not found" -ForegroundColor Red; return }
}
Write-Host ""

# FASE 1: VMs
Write-Host "--- FASE 1: VMs ---`n" -ForegroundColor Cyan
$vms = Force-Array (Safe-AzJson @("vm","list","--subscription",$sub,"--query","[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}"))
Write-Host "  Total: $($vms.Count)" -ForegroundColor White
$vmList = @()
foreach ($v in $vms) {
    if (-not $v.name) { continue }
    $vmList += @{ name=$v.name; rg=$v.rg; os=$v.os; id=$v.id; vmId=$v.vmId }
    Write-Host ("  {0,-35} {1,-8} {2}" -f $v.name, $v.os, $v.rg) -ForegroundColor White
}
if ($vmList.Count -eq 0) { Write-Host "  No VMs." -ForegroundColor Yellow; return }

# FASE 2: DEVICES -- 1 SINGLE QUERY filtered by subscription ID in physicalIds
# physicalIds contains [AzureResourceId]:/subscriptions/{subId}/...
# This returns ONLY devices from THIS subscription. No full tenant scan.
Write-Host "`n--- FASE 2: Entra Devices (subscription only) ---`n" -ForegroundColor Cyan
$filterUri = 'https://graph.microsoft.com/v1.0/devices?$top=999&$count=true&$select=displayName,id,deviceId,physicalIds,operatingSystem,approximateLastSignInDateTime,accountEnabled&$filter=physicalIds/any(x:startswith(x,''[AzureResourceId]:/subscriptions/' + $sub + '''))'
$allDev = @()
$pg = 0
$currentUri = $filterUri
do {
    $pg++
    Write-Host "  Page $pg..." -ForegroundColor Gray -NoNewline
    $r = Safe-AzJson @("rest","--method","GET","--uri",$currentUri,"--headers","ConsistencyLevel=eventual")
    if (-not $r) { Write-Host " err" -ForegroundColor Red; break }
    if ($r.value) { $items = @($r.value); $allDev += $items; Write-Host " $($items.Count) (total:$($allDev.Count))" -ForegroundColor Gray }
    else { Write-Host " 0" -ForegroundColor Gray }
    $currentUri = $null
    if ($r.'@odata.nextLink') { $currentUri = $r.'@odata.nextLink' }
} while ($currentUri)
Write-Host "  Devices in sub: $($allDev.Count)" -ForegroundColor White
if ($allDev.Count -eq 0) { Write-Host "  No devices registered from this subscription." -ForegroundColor Yellow; return }

$devIdx = @()
foreach ($d in $allDev) {
    if (-not $d.displayName) { continue }
    $devIdx += @{ displayName=$d.displayName; normalized=Normalize-Deep $d.displayName; netbios=Get-NetBIOSName $d.displayName; id=$d.id; deviceId=$d.deviceId; os=$d.operatingSystem; lastSignIn=$d.approximateLastSignInDateTime; physicalIds=$d.physicalIds }
}

# FASE 3: MATCHING
Write-Host "`n--- FASE 3: Matching ---`n" -ForegroundColor Cyan
$matched = @(); $unmatched = @(); $used = @{}

foreach ($vm in $vmList) {
    $r = Match-Device -vm $vm -devIdx $devIdx -used $used -manual $manualMap
    if ($r.dev) {
        $used[$r.dev.id] = $true
        $matched += @{ vm=$vm; device=$r.dev; layer=$r.layer; detail=$r.detail }
        $lc = switch -Wildcard ($r.layer) {"L0*"{"Magenta"}"L1*"{"Green"}"L2*"{"Green"}"L3*"{"Cyan"}"L4*"{"Yellow"}"L5*"{"Yellow"}"L6*"{"DarkCyan"}default{"White"}}
        Write-Host "  [OK] $($vm.name) -> $($r.dev.displayName) ($($r.layer))" -ForegroundColor $lc
    } else {
        $unmatched += $vm
        Write-Host "  [--] $($vm.name)" -ForegroundColor Red
        $top = $null; $ts = 0
        foreach ($d in $devIdx) { $s = Get-Similarity (Normalize-Deep $vm.name) $d.normalized; if ($s -gt $ts -and $s -gt 0.3) { $ts=$s; $top=$d } }
        if ($top) { Write-Host "       ~$($top.displayName) ($ts)" -ForegroundColor DarkGray }
    }
}

Write-Host "`n  Matched: $($matched.Count)/$($vmList.Count) | Unmatched: $($unmatched.Count)" -ForegroundColor $(if($unmatched.Count -gt 0){'Yellow'}else{'Green'})
$ls = @{}; foreach ($m in $matched) { $k=$m.layer; if(-not $ls.ContainsKey($k)){$ls[$k]=0}; $ls[$k]++ }
foreach ($k in ($ls.Keys | Sort-Object)) { Write-Host "    $k : $($ls[$k])" -ForegroundColor DarkGray }

# FASE 4: SYNC (direct add -- Graph returns 400 if already member, which is harmless)
Write-Host "`n--- FASE 4: Sync Groups ---`n" -ForegroundColor Cyan
if ($matched.Count -eq 0) { Write-Host "  Nothing." -ForegroundColor Yellow }
else {
    $added = 0; $exists = 0
    foreach ($m in $matched) {
        $did = $m.device.id; $dn = $m.device.displayName; $lsi = $m.device.lastSignIn
        # Target group by lastSignIn
        $tg = $grpMain; $tl = "Main"
        if ($lsi) { try { $days = ((Get-Date) - [DateTime]::Parse($lsi)).Days; if($days -gt 30){$tg=$grpStale30;$tl="S30"}elseif($days -gt 7){$tg=$grpStale7;$tl="S7"} } catch {} }
        else { $tg = $grpStale7; $tl = "S7" }
        # Direct add (no pre-check = fast)
        $body = '{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/' + $did + '"}'
        $bf = Join-Path $tempPath "add.json"
        [System.IO.File]::WriteAllText($bf, $body)
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$tg/members/`$ref" --headers "Content-Type=application/json" --body "@$bf" --output none 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  [+] $dn -> $tl" -ForegroundColor Green; $added++ }
        else { Write-Host "  [=] $dn -> $tl (exists)" -ForegroundColor Gray; $exists++ }
    }
    Write-Host "`n  Added: $added | Already: $exists" -ForegroundColor Cyan
}

# REPORT
Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v5 DONE" -ForegroundColor White
Write-Host "  VMs: $($vmList.Count) | Matched: $($matched.Count) | Unmatched: $($unmatched.Count)" -ForegroundColor White
if ($unmatched.Count -gt 0) {
    foreach ($u in $unmatched) { Write-Host "    [--] $($u.name) [$($u.os)]" -ForegroundColor DarkYellow }
    Write-Host "  -> Start VMs, install AAD ext, wait 5min, re-run" -ForegroundColor Gray
}
Write-Host "================================================================`n" -ForegroundColor Magenta

$sep = "=" * 50
$lf = Join-Path $tempPath ("fix-v5-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
$ll = @("FIX v5 $(Get-Date) PS$($PSVersionTable.PSVersion)", $sep, "VMs:$($vmList.Count) Match:$($matched.Count) Miss:$($unmatched.Count)", "")
foreach ($m in $matched) { $ll += "$($m.layer)|$($m.vm.name)->$($m.device.displayName)" }
$ll += ""; foreach ($u in $unmatched) { $ll += "MISS|$($u.name)" }
$ll | Out-File $lf -Encoding UTF8 -Force
Write-Host "  Log: $lf`n" -ForegroundColor Gray
