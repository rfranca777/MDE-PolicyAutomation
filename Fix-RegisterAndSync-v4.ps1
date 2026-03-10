<#
.SYNOPSIS
    FIX v4: Match Azure VMs -> Entra ID Devices -> Sync to Groups
.DESCRIPTION
    Bulletproof for PS 5.1 ISE. Zero interaction. Zero error.
    
    PS 5.1 ISE fixes over v3:
    - Custom Parse-Json function that handles string[] from az CLI
    - Forces array unwrap ([array] cast) on all JSON array results
    - No pipeline into ConvertFrom-Json (uses -InputObject)
    - Debug output shows raw type info for troubleshooting
    
.NOTES
    Version: 4.0.0
    Author:  Rafael Franca -- github.com/rfranca777
    Date:    2026-03-10
    Compat:  PS 5.1 ISE, PS 7, Cloud Shell
    Encoding: ASCII-safe (no Unicode chars)
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
# CORE: Parse-Json -- THE fix for PS 5.1 ISE
# ============================================================
function Parse-Json {
    # PS 5.1 ISE: az CLI returns string[] (one per line).
    # ConvertFrom-Json via pipeline wraps arrays as single object.
    # This function: joins lines, uses -InputObject, forces array unwrap.
    param([object]$RawInput)
    if (-not $RawInput) { return $null }
    $jsonStr = ""
    if ($RawInput -is [array]) {
        $jsonStr = [string]::Join("", $RawInput)
    } else {
        $jsonStr = [string]$RawInput
    }
    $jsonStr = $jsonStr.Trim()
    if ($jsonStr.Length -eq 0) { return $null }
    try {
        $result = ConvertFrom-Json -InputObject $jsonStr
        return $result
    } catch {
        return $null
    }
}

function Force-Array {
    # Ensures result is always a PS array, even for single items
    param([object]$Data)
    if ($null -eq $Data) { return @() }
    if ($Data -is [System.Collections.IEnumerable] -and $Data -isnot [string]) {
        return @($Data)
    }
    return @(,$Data)
}

# ============================================================
# FUNCTIONS
# ============================================================
function Normalize-Deep {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $n = $Name.Trim().ToLower()
    if ($n -match '^[^\\]+\\(.+)$') { $n = $Matches[1] }
    if ($n -match '^([^.]+)\.') { $n = $Matches[1] }
    $n = $n -replace '[_]', '-'
    $n = $n -replace '--+', '-'
    $n = $n -replace '^-|-$', ''
    return $n
}

function Get-NetBIOSName {
    param([string]$Name)
    $norm = Normalize-Deep $Name
    if ($norm.Length -gt 15) { return $norm.Substring(0, 15) }
    return $norm
}

function Get-Similarity {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return 0.0 }
    $a1 = $A.ToLower(); $b1 = $B.ToLower()
    if ($a1 -eq $b1) { return 1.0 }
    $maxLen = 0
    for ($i = 0; $i -lt $a1.Length; $i++) {
        for ($j = 0; $j -lt $b1.Length; $j++) {
            $len = 0
            while (($i + $len) -lt $a1.Length -and ($j + $len) -lt $b1.Length -and $a1[$i + $len] -eq $b1[$j + $len]) { $len++ }
            if ($len -gt $maxLen) { $maxLen = $len }
        }
    }
    return [Math]::Round($maxLen / [Math]::Max($a1.Length, $b1.Length), 2)
}

function Get-AllEntraDevices {
    $all = @()
    $uri = 'https://graph.microsoft.com/v1.0/devices?$top=999&$select=displayName,id,deviceId,physicalIds,operatingSystem,approximateLastSignInDateTime,accountEnabled'
    do {
        $raw = az rest --method GET --uri $uri -o json 2>$null
        $resp = Parse-Json $raw
        if (-not $resp) { break }
        if ($resp.value) {
            $items = Force-Array $resp.value
            $all += $items
        }
        $uri = $null
        if ($resp.'@odata.nextLink') { $uri = $resp.'@odata.nextLink' }
    } while ($uri)
    return ,$all
}

function Match-Device {
    param($vm, $deviceIndex, $usedIds, $manualMap)
    $vmName = $vm.name
    $vmNorm = Normalize-Deep $vmName
    $vmNB = Get-NetBIOSName $vmName
    $vmRid = if ($vm.id) { $vm.id.ToLower() } else { "" }
    $vmVid = if ($vm.vmId) { $vm.vmId.ToLower() } else { "" }
    $dev = $null; $layer = ""; $detail = ""

    # L0: Manual map
    if ($manualMap.ContainsKey($vmName)) {
        $target = $manualMap[$vmName].ToLower()
        $dev = $deviceIndex | Where-Object { -not $usedIds.ContainsKey($_.id) -and $_.displayName -and $_.displayName.ToLower() -eq $target } | Select-Object -First 1
        if ($dev) { $layer = "L0-MANUAL"; $detail = "Manual: $vmName -> $($dev.displayName)" }
    }
    # L1: physicalIds contains Azure Resource ID
    if (-not $dev -and $vmRid.Length -gt 20) {
        $dev = $deviceIndex | Where-Object {
            -not $usedIds.ContainsKey($_.id) -and $_.physicalIds -and ($_.physicalIds | Where-Object { $_.ToLower().Contains($vmRid) })
        } | Select-Object -First 1
        if ($dev) { $layer = "L1-PHYSICAL"; $detail = "physicalIds contains resourceId" }
    }
    # L2: Exact name
    if (-not $dev) {
        $dev = $deviceIndex | Where-Object { -not $usedIds.ContainsKey($_.id) -and $_.displayName -and $_.displayName.ToLower() -eq $vmName.ToLower() } | Select-Object -First 1
        if ($dev) { $layer = "L2-EXACT"; $detail = "Exact: $vmName == $($dev.displayName)" }
    }
    # L3: Normalized
    if (-not $dev -and $vmNorm.Length -ge 3) {
        $dev = $deviceIndex | Where-Object { -not $usedIds.ContainsKey($_.id) -and $_.normalized -eq $vmNorm } | Select-Object -First 1
        if ($dev) { $layer = "L3-NORM"; $detail = "Norm: '$vmNorm' == '$($dev.normalized)'" }
    }
    # L4: NetBIOS
    if (-not $dev -and $vmNB.Length -ge 3) {
        $dev = $deviceIndex | Where-Object { -not $usedIds.ContainsKey($_.id) -and $_.netbios -eq $vmNB -and $_.netbios.Length -ge 3 } | Select-Object -First 1
        if ($dev) { $layer = "L4-NETBIOS"; $detail = "NetBIOS: '$vmNB' == '$($dev.netbios)'" }
    }
    # L5: Fuzzy (>= 0.8)
    if (-not $dev -and $vmNorm.Length -ge 4) {
        $candidates = @($deviceIndex | Where-Object { -not $usedIds.ContainsKey($_.id) -and $_.normalized -and $_.normalized.Length -ge 4 -and $_.normalized.Contains($vmNorm) })
        if ($candidates.Count -eq 0) {
            $candidates = @($deviceIndex | Where-Object { -not $usedIds.ContainsKey($_.id) -and $_.normalized -and $_.normalized.Length -ge 4 -and $vmNorm.Contains($_.normalized) })
        }
        if ($candidates.Count -ge 1) {
            $best = $null; $bestScore = 0
            foreach ($c in $candidates) { $s = Get-Similarity $vmNorm $c.normalized; if ($s -gt $bestScore) { $bestScore = $s; $best = $c } }
            if ($best -and $bestScore -ge 0.8) { $dev = $best; $layer = "L5-FUZZY"; $detail = "Fuzzy($bestScore): '$vmNorm' ~ '$($dev.normalized)'" }
        }
    }
    # L6: vmId == deviceId
    if (-not $dev -and $vmVid.Length -gt 10) {
        $dev = $deviceIndex | Where-Object { -not $usedIds.ContainsKey($_.id) -and $_.deviceId -and $_.deviceId.ToLower() -eq $vmVid } | Select-Object -First 1
        if ($dev) { $layer = "L6-VMID"; $detail = "vmId == deviceId" }
    }
    return @{ dev = $dev; layer = $layer; detail = $detail }
}

# ============================================================
# PRE-FLIGHT
# ============================================================
$tempPath = "C:\temp"
if (-not (Test-Path $tempPath)) { New-Item -ItemType Directory -Path $tempPath -Force | Out-Null }

Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v4: MATCH + SYNC (PS 5.1 ISE bulletproof)" -ForegroundColor White
Write-Host "  Sub: $sub" -ForegroundColor Gray
Write-Host "  PS: $($PSVersionTable.PSVersion) Host: $($Host.Name)" -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Magenta

Write-Host "  Pre-flight..." -ForegroundColor Cyan
$azCtx = Parse-Json (az account show -o json 2>$null)
if (-not $azCtx) { Write-Host "  [FAIL] az login required" -ForegroundColor Red; return }
Write-Host "  [OK] Logged in: $($azCtx.user.name)" -ForegroundColor Green

$graphTest = Parse-Json (az rest --method GET --uri 'https://graph.microsoft.com/v1.0/organization?$select=displayName' -o json 2>$null)
if (-not $graphTest) { Write-Host "  [FAIL] No Graph access" -ForegroundColor Red; return }
Write-Host "  [OK] Graph API" -ForegroundColor Green

az account set --subscription $sub 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "  [FAIL] Sub $sub" -ForegroundColor Red; return }
Write-Host "  [OK] Subscription" -ForegroundColor Green

$allGroupsOk = $true
foreach ($g in @(@{id=$grpMain;n="Main"},@{id=$grpStale7;n="Stale7"},@{id=$grpStale30;n="Stale30"},@{id=$grpEph;n="Ephemeral"})) {
    $gc = Parse-Json (az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)?`$select=displayName" -o json 2>$null)
    if ($gc -and $gc.displayName) { Write-Host "  [OK] $($g.n): $($gc.displayName)" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $($g.n): $($g.id)" -ForegroundColor Red; $allGroupsOk = $false }
}
if (-not $allGroupsOk) { Write-Host "  Aborting." -ForegroundColor Red; return }
Write-Host ""

# ============================================================
# FASE 1: VMs
# ============================================================
Write-Host "--- FASE 1: AZURE VMs ---`n" -ForegroundColor Cyan
$vmsRaw = az vm list --subscription $sub --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}" -o json 2>$null
$vmsParsed = Parse-Json $vmsRaw
$vms = Force-Array $vmsParsed

Write-Host "  Total VMs: $($vms.Count) (type: $($vmsParsed.GetType().Name))" -ForegroundColor White
$vmList = @()
foreach ($vm in $vms) {
    if (-not $vm.name) { continue }  # skip null entries
    $vmList += @{ name=$vm.name; rg=$vm.rg; os=$vm.os; id=$vm.id; vmId=$vm.vmId }
    Write-Host ("  {0,-35} {1,-8} {2}" -f $vm.name, $vm.os, $vm.rg) -ForegroundColor White
}
Write-Host "  Valid VMs: $($vmList.Count)" -ForegroundColor Cyan

if ($vmList.Count -eq 0) { Write-Host "  No VMs. Done." -ForegroundColor Yellow; return }

# ============================================================
# FASE 2: ENTRA DEVICES
# ============================================================
Write-Host "`n--- FASE 2: ENTRA DEVICES ---`n" -ForegroundColor Cyan
$deviceList = Get-AllEntraDevices
Write-Host "  Total devices: $($deviceList.Count)" -ForegroundColor White
if ($deviceList.Count -eq 0) { Write-Host "  No devices. Done." -ForegroundColor Yellow; return }

$deviceIndex = @()
foreach ($d in $deviceList) {
    if (-not $d.displayName) { continue }
    $deviceIndex += @{
        displayName = $d.displayName; normalized = Normalize-Deep $d.displayName
        netbios = Get-NetBIOSName $d.displayName; id = $d.id; deviceId = $d.deviceId
        os = $d.operatingSystem; lastSignIn = $d.approximateLastSignInDateTime
        enabled = $d.accountEnabled; physicalIds = $d.physicalIds
    }
}

# ============================================================
# FASE 3: MATCHING
# ============================================================
Write-Host "`n--- FASE 3: MATCHING ---`n" -ForegroundColor Cyan
$matched = @(); $unmatched = @(); $usedIds = @{}

foreach ($vm in $vmList) {
    $r = Match-Device -vm $vm -deviceIndex $deviceIndex -usedIds $usedIds -manualMap $manualMap
    if ($r.dev) {
        $usedIds[$r.dev.id] = $true
        $matched += @{ vm=$vm; device=$r.dev; layer=$r.layer; detail=$r.detail }
        $lc = switch -Wildcard ($r.layer) {"L0*"{"Magenta"}"L1*"{"Green"}"L2*"{"Green"}"L3*"{"Cyan"}"L4*"{"Yellow"}"L5*"{"Yellow"}"L6*"{"DarkCyan"}default{"White"}}
        Write-Host "  [OK] $($vm.name) -> $($r.dev.displayName) ($($r.layer))" -ForegroundColor $lc
    } else {
        $unmatched += $vm
        Write-Host "  [--] $($vm.name)" -ForegroundColor Red
        $top = $null; $ts = 0
        foreach ($d in $deviceIndex) { $s = Get-Similarity (Normalize-Deep $vm.name) $d.normalized; if ($s -gt $ts -and $s -gt 0.3) { $ts=$s; $top=$d } }
        if ($top) { Write-Host "       ~$($top.displayName) ($ts)" -ForegroundColor DarkGray }
    }
}
Write-Host "`n  Result: $($matched.Count)/$($vmList.Count) matched | $($unmatched.Count) unmatched" -ForegroundColor $(if($unmatched.Count -gt 0){'Yellow'}else{'Green'})
$ls = @{}; foreach ($m in $matched) { $k=$m.layer; if(-not $ls.ContainsKey($k)){$ls[$k]=0}; $ls[$k]++ }
foreach ($k in ($ls.Keys | Sort-Object)) { Write-Host "    $k : $($ls[$k])" -ForegroundColor DarkGray }

# ============================================================
# FASE 4: SYNC GROUPS
# ============================================================
Write-Host "`n--- FASE 4: SYNC GROUPS ---`n" -ForegroundColor Cyan
if ($matched.Count -eq 0) { Write-Host "  Nothing to sync." -ForegroundColor Yellow }
else {
    $existingMembers = @{}
    foreach ($g in @(@{id=$grpMain;n="Main"},@{id=$grpStale7;n="Stale-7d"},@{id=$grpStale30;n="Stale-30d"},@{id=$grpEph;n="Ephemeral"})) {
        $mr = Parse-Json (az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members?`$select=id,displayName&`$top=999" -o json 2>$null)
        $existingMembers[$g.id] = @()
        if ($mr -and $mr.value) { $existingMembers[$g.id] = Force-Array $mr.value }
        Write-Host "  $($g.n): $($existingMembers[$g.id].Count) members" -ForegroundColor DarkGray
    }
    Write-Host ""

    $added = 0; $skip = 0; $moved = 0
    foreach ($m in $matched) {
        $did = $m.device.id; $dn = $m.device.displayName; $ls2 = $m.device.lastSignIn
        $tg = $grpMain; $tl = "Main"
        if ($ls2) { try { $d2 = ((Get-Date) - [DateTime]::Parse($ls2)).Days; if($d2 -gt 30){$tg=$grpStale30;$tl="Stale-30d"}elseif($d2 -gt 7){$tg=$grpStale7;$tl="Stale-7d"} } catch {} }
        else { $tg = $grpStale7; $tl = "Stale-7d" }

        $inT = $existingMembers[$tg] | Where-Object { $_.id -eq $did }
        if ($inT) { Write-Host "  [=] $dn -> $tl" -ForegroundColor Gray; $skip++; continue }

        foreach ($oid in @($grpMain,$grpStale7,$grpStale30,$grpEph)) {
            if ($oid -eq $tg) { continue }
            $inO = $existingMembers[$oid] | Where-Object { $_.id -eq $did }
            if ($inO) { az rest --method DELETE --uri "https://graph.microsoft.com/v1.0/groups/$oid/members/$did/`$ref" --output none 2>&1 | Out-Null; $moved++; break }
        }

        $body = '{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/' + $did + '"}'
        $bf = Join-Path $tempPath "add-m.json"
        [System.IO.File]::WriteAllText($bf, $body)
        az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$tg/members/`$ref" --headers "Content-Type=application/json" --body "@$bf" --output none 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  [+] $dn -> $tl" -ForegroundColor Green; $added++ }
        else { Write-Host "  [!] $dn -> exists?" -ForegroundColor DarkYellow }
    }
    Write-Host "`n  Added:$added Moved:$moved Already:$skip" -ForegroundColor Cyan
}

# ============================================================
# FASE 5: VERIFY
# ============================================================
Write-Host "`n--- FASE 5: VERIFY ---`n" -ForegroundColor Cyan
$total = 0
foreach ($g in @(@{id=$grpMain;n="Main"},@{id=$grpStale7;n="Stale-7d"},@{id=$grpStale30;n="Stale-30d"},@{id=$grpEph;n="Ephemeral"})) {
    $mr = Parse-Json (az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members?`$select=displayName&`$top=999" -o json 2>$null)
    $ml = @(); if ($mr -and $mr.value) { $ml = Force-Array $mr.value }
    $total += $ml.Count
    Write-Host "  $($g.n): $($ml.Count)" -ForegroundColor $(if($ml.Count -gt 0){'Green'}else{'Yellow'})
    foreach ($x in $ml) { Write-Host "    - $($x.displayName)" -ForegroundColor DarkGray }
}

# ============================================================
# REPORT
# ============================================================
Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v4 REPORT" -ForegroundColor White
Write-Host "  VMs: $($vmList.Count) | Matched: $($matched.Count) | Groups: $total" -ForegroundColor White
Write-Host "  Unmatched: $($unmatched.Count)" -ForegroundColor $(if($unmatched.Count -gt 0){'Yellow'}else{'Green'})
if ($unmatched.Count -gt 0) {
    Write-Host "  --" -ForegroundColor Gray
    foreach ($u in $unmatched) { Write-Host "    $($u.name) [$($u.os)] $($u.rg)" -ForegroundColor DarkYellow }
    Write-Host "  Start VMs + install AAD ext + wait 5min + re-run" -ForegroundColor Gray
}
Write-Host "================================================================`n" -ForegroundColor Magenta

$separator = "=" * 50
$logFile = Join-Path $tempPath ("mde-fix-v4-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
$logLines = @("FIX v4 -- $(Get-Date) -- PS $($PSVersionTable.PSVersion) $($Host.Name)")
$logLines += $separator
$logLines += "VMs:$($vmList.Count) Matched:$($matched.Count) Unmatched:$($unmatched.Count) InGroups:$total"
$logLines += ""
foreach ($m in $matched) { $logLines += "$($m.layer) | $($m.vm.name) -> $($m.device.displayName)" }
$logLines += ""
foreach ($u in $unmatched) { $logLines += "MISS | $($u.name) [$($u.os)] $($u.rg)" }
$logLines | Out-File $logFile -Encoding UTF8 -Force
Write-Host "  Log: $logFile`n" -ForegroundColor Gray
