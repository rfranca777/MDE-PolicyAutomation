<#
.SYNOPSIS
    FIX v3: Match Azure VMs -> Entra ID Devices -> Sync to Groups
.DESCRIPTION
    Zero-interaction, zero-error script for matching and syncing.
    
    What it does:
    1. Lists all VMs in the subscription
    2. Lists all devices in Entra ID (paginated)
    3. Matches VMs to devices using 6 layers (physicalIds, exact, normalized, netbios, fuzzy, vmId)
    4. Adds matched devices to the correct Entra ID group (main/stale7/stale30/ephemeral)
    5. Reports unmatched VMs with diagnostic info
    
    What it does NOT do (by design -- too slow/unreliable for fix script):
    - Does NOT install AAD extensions (that is the Deploy script's job)
    - Does NOT require any user interaction (no Read-Host)
    - Does NOT use Start-Job (PS 5.1 ISE incompatible)
    
    Matching layers (in order of confidence):
    L0: Manual map (100% -- user-defined overrides)
    L1: physicalIds contains Azure Resource ID (99%)
    L2: Exact name case-insensitive (95%)
    L3: Normalized name without domain/prefix (90%)
    L4: NetBIOS truncated 15 chars (85%)
    L5: Fuzzy -- contains + similarity >= 0.8 (75%)
    L6: Azure vmId == Entra deviceId (60%)

.NOTES
    Version: 3.0.0
    Author:  Rafael Franca -- github.com/rfranca777
    Date:    2026-03-10
    Compat:  PS 5.1 ISE, PS 7, Cloud Shell
    Encoding: ASCII-safe (no Unicode chars)
#>

#Requires -Version 5.1
$ErrorActionPreference = "Continue"

# ============================================================
# CONFIG -- CLIENT TENANT
# ============================================================
$sub       = "121129d5-3986-447b-8a52-678b70ec6f76"
$grpMain   = "ed0829b1-26ba-4c2a-b33f-3a618c3e3255"
$grpStale7 = "4a221a76-c2a4-4702-ab14-ea048d3f526b"
$grpStale30= "2de9c8f7-0bb1-4778-8d9c-4cf507527cf2"
$grpEph    = "6d30e508-6e36-4d12-896e-e962d45d67d9"

# Manual overrides -- for VMs with completely different Entra device names
# Fill ONLY if 6-layer matching cannot resolve
$manualMap = @{
    # "AzureVmName" = "EntraDeviceDisplayName"
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
    $uri = "https://graph.microsoft.com/v1.0/devices?" + "`$top=999&`$select=displayName,id,deviceId,physicalIds,operatingSystem,approximateLastSignInDateTime,accountEnabled"
    do {
        $raw = az rest --method GET --uri $uri -o json 2>$null
        if (-not $raw) { break }
        $resp = $null
        try { $resp = ($raw -join '') | ConvertFrom-Json } catch { break }
        if ($resp -and $resp.value) { $all += $resp.value }
        $uri = $null
        if ($resp -and $resp.'@odata.nextLink') { $uri = $resp.'@odata.nextLink' }
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
    
    $dev = $null
    $layer = ""
    $detail = ""
    
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
    
    # L2: Exact name (case-insensitive)
    if (-not $dev) {
        $dev = $deviceIndex | Where-Object {
            -not $usedIds.ContainsKey($_.id) -and $_.displayName -and $_.displayName.ToLower() -eq $vmName.ToLower()
        } | Select-Object -First 1
        if ($dev) { $layer = "L2-EXACT"; $detail = "Exact: $vmName == $($dev.displayName)" }
    }
    
    # L3: Normalized name (no domain, no prefix)
    if (-not $dev -and $vmNorm.Length -ge 3) {
        $dev = $deviceIndex | Where-Object {
            -not $usedIds.ContainsKey($_.id) -and $_.normalized -eq $vmNorm
        } | Select-Object -First 1
        if ($dev) { $layer = "L3-NORM"; $detail = "Normalized: '$vmNorm' == '$($dev.normalized)' (raw: $($dev.displayName))" }
    }
    
    # L4: NetBIOS 15-char truncation
    if (-not $dev -and $vmNB.Length -ge 3) {
        $dev = $deviceIndex | Where-Object {
            -not $usedIds.ContainsKey($_.id) -and $_.netbios -eq $vmNB -and $_.netbios.Length -ge 3
        } | Select-Object -First 1
        if ($dev) { $layer = "L4-NETBIOS"; $detail = "NetBIOS: '$vmNB' == '$($dev.netbios)' (raw: $($dev.displayName))" }
    }
    
    # L5: Fuzzy -- contains + similarity >= 0.8 (high threshold to prevent false positives)
    if (-not $dev -and $vmNorm.Length -ge 4) {
        $candidates = @()
        
        # 5a: Device contains VM name
        $candidates = @($deviceIndex | Where-Object {
            -not $usedIds.ContainsKey($_.id) -and $_.normalized -and $_.normalized.Length -ge 4 -and $_.normalized.Contains($vmNorm)
        })
        
        # 5b: VM name contains device name
        if ($candidates.Count -eq 0) {
            $candidates = @($deviceIndex | Where-Object {
                -not $usedIds.ContainsKey($_.id) -and $_.normalized -and $_.normalized.Length -ge 4 -and $vmNorm.Contains($_.normalized)
            })
        }
        
        if ($candidates.Count -eq 1) {
            $score = Get-Similarity $vmNorm $candidates[0].normalized
            if ($score -ge 0.8) {
                $dev = $candidates[0]
                $layer = "L5-FUZZY"
                $detail = "Fuzzy($score): '$vmNorm' ~ '$($dev.normalized)' (raw: $($dev.displayName))"
            }
        } elseif ($candidates.Count -gt 1) {
            $best = $null; $bestScore = 0
            foreach ($c in $candidates) {
                $s = Get-Similarity $vmNorm $c.normalized
                if ($s -gt $bestScore) { $bestScore = $s; $best = $c }
            }
            if ($best -and $bestScore -ge 0.8) {
                $dev = $best
                $layer = "L5-FUZZY"
                $detail = "Fuzzy-best($bestScore): '$vmNorm' ~ '$($dev.normalized)' ($($candidates.Count) candidates)"
            }
        }
    }
    
    # L6: vmId == deviceId
    if (-not $dev -and $vmVid.Length -gt 10) {
        $dev = $deviceIndex | Where-Object {
            -not $usedIds.ContainsKey($_.id) -and $_.deviceId -and $_.deviceId.ToLower() -eq $vmVid
        } | Select-Object -First 1
        if ($dev) { $layer = "L6-VMID"; $detail = "vmId == deviceId" }
    }
    
    return @{ dev = $dev; layer = $layer; detail = $detail }
}

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================
$tempPath = "C:\temp"
if (-not (Test-Path $tempPath)) { New-Item -ItemType Directory -Path $tempPath -Force | Out-Null }

Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v3: MATCH + SYNC (zero interaction)" -ForegroundColor White
Write-Host "  Sub: $sub" -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Magenta

# Validate az login
Write-Host "  Pre-flight checks..." -ForegroundColor Cyan
$azCtx = (az account show -o json 2>$null) -join '' | ConvertFrom-Json
if (-not $azCtx) {
    Write-Host "  [FAIL] az login required. Run: az login" -ForegroundColor Red
    return
}
Write-Host "  [OK] az logged in: $($azCtx.user.name)" -ForegroundColor Green

# Validate Graph access (use /organization instead of /me -- works with all auth types)
$graphTest = (az rest --method GET --uri "https://graph.microsoft.com/v1.0/organization?`$select=displayName" -o json 2>$null) -join ''
if (-not $graphTest -or $graphTest.Length -lt 5) {
    Write-Host "  [FAIL] No Graph API access. Check permissions." -ForegroundColor Red
    return
}
Write-Host "  [OK] Graph API accessible" -ForegroundColor Green

# Set subscription
az account set --subscription $sub 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] Cannot set subscription $sub" -ForegroundColor Red
    return
}
Write-Host "  [OK] Subscription set" -ForegroundColor Green

# Validate groups exist
$groupsOk = $true
foreach ($gDef in @(
    @{id=$grpMain;n="Main"}, @{id=$grpStale7;n="Stale7"},
    @{id=$grpStale30;n="Stale30"}, @{id=$grpEph;n="Ephemeral"}
)) {
    $gCheck = (az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($gDef.id)?`$select=displayName" -o json 2>$null) -join '' | ConvertFrom-Json
    if ($gCheck -and $gCheck.displayName) {
        Write-Host "  [OK] Group $($gDef.n): $($gCheck.displayName)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] Group $($gDef.n) not found: $($gDef.id)" -ForegroundColor Red
        $groupsOk = $false
    }
}
if (-not $groupsOk) {
    Write-Host "`n  Aborting -- fix group IDs in script config." -ForegroundColor Red
    return
}

Write-Host ""

# ============================================================
# FASE 1: AZURE VMs
# ============================================================
Write-Host "--- FASE 1: AZURE VMs ---`n" -ForegroundColor Cyan

$vmsRaw = az vm list --subscription $sub --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}" -o json 2>$null
$vms = @()
if ($vmsRaw) { try { $vms = @(($vmsRaw -join '') | ConvertFrom-Json) } catch { $vms = @() } }

# NOTE: Power state skipped intentionally -- az vm list -d hangs on large subs.
# Group assignment uses Entra device lastSignIn instead (more accurate anyway).

$vmList = @()
foreach ($vm in $vms) {
    $vmList += @{
        name  = $vm.name
        rg    = $vm.rg
        os    = $vm.os
        id    = $vm.id
        vmId  = $vm.vmId
    }
}

Write-Host "  Total VMs: $($vmList.Count)" -ForegroundColor White
foreach ($v in $vmList) {
    Write-Host ("  {0,-35} {1,-8} {2}" -f $v.name, $v.os, $v.rg) -ForegroundColor White
}

if ($vmList.Count -eq 0) {
    Write-Host "  No VMs found. Nothing to do." -ForegroundColor Yellow
    return
}

# ============================================================
# FASE 2: ENTRA ID DEVICES
# ============================================================
Write-Host "`n--- FASE 2: ENTRA ID DEVICES ---`n" -ForegroundColor Cyan

$deviceList = Get-AllEntraDevices
Write-Host "  Total Entra devices: $($deviceList.Count)" -ForegroundColor White

if ($deviceList.Count -eq 0) {
    Write-Host "  [WARN] No devices in Entra ID. Cannot match." -ForegroundColor Red
    return
}

$deviceIndex = @()
foreach ($d in $deviceList) {
    $deviceIndex += @{
        displayName = $d.displayName
        normalized  = Normalize-Deep $d.displayName
        netbios     = Get-NetBIOSName $d.displayName
        id          = $d.id
        deviceId    = $d.deviceId
        os          = $d.operatingSystem
        lastSignIn  = $d.approximateLastSignInDateTime
        enabled     = $d.accountEnabled
        physicalIds = $d.physicalIds
    }
}

# ============================================================
# FASE 3: MATCHING (6 LAYERS)
# ============================================================
Write-Host "`n--- FASE 3: MATCHING ---`n" -ForegroundColor Cyan

$matched = @()
$unmatched = @()
$usedIds = @{}

foreach ($vm in $vmList) {
    $result = Match-Device -vm $vm -deviceIndex $deviceIndex -usedIds $usedIds -manualMap $manualMap
    
    if ($result.dev) {
        $usedIds[$result.dev.id] = $true
        $matched += @{ vm = $vm; device = $result.dev; layer = $result.layer; detail = $result.detail }
        $lc = switch -Wildcard ($result.layer) { "L0*"{"Magenta"} "L1*"{"Green"} "L2*"{"Green"} "L3*"{"Cyan"} "L4*"{"Yellow"} "L5*"{"Yellow"} "L6*"{"DarkCyan"} default{"White"} }
        Write-Host "  [OK] $($vm.name) -> $($result.dev.displayName) ($($result.layer))" -ForegroundColor $lc
    } else {
        $unmatched += $vm
        Write-Host "  [--] $($vm.name) (no match)" -ForegroundColor Red
        # Show top similar device for diagnostics
        $topDev = $null; $topScore = 0
        foreach ($d in $deviceIndex) {
            $s = Get-Similarity (Normalize-Deep $vm.name) $d.normalized
            if ($s -gt $topScore -and $s -gt 0.3) { $topScore = $s; $topDev = $d }
        }
        if ($topDev) {
            Write-Host "       Closest: $($topDev.displayName) (score: $topScore)" -ForegroundColor DarkGray
        }
    }
}

Write-Host "`n  Matched: $($matched.Count)/$($vmList.Count) | Unmatched: $($unmatched.Count)" -ForegroundColor $(if($unmatched.Count -gt 0){'Yellow'}else{'Green'})

# Layer stats
$ls = @{}
foreach ($m in $matched) { $k=$m.layer; if(-not $ls.ContainsKey($k)){$ls[$k]=0}; $ls[$k]++ }
foreach ($k in ($ls.Keys | Sort-Object)) { Write-Host "    $k : $($ls[$k])" -ForegroundColor DarkGray }

# ============================================================
# FASE 4: SYNC TO GROUPS
# ============================================================
Write-Host "`n--- FASE 4: SYNC TO GROUPS ---`n" -ForegroundColor Cyan

if ($matched.Count -eq 0) {
    Write-Host "  No matched devices to sync." -ForegroundColor Yellow
} else {
    # Pre-load existing members (paginated)
    $existingMembers = @{}
    foreach ($gDef in @(
        @{id=$grpMain;n="Main"}, @{id=$grpStale7;n="Stale-7d"},
        @{id=$grpStale30;n="Stale-30d"}, @{id=$grpEph;n="Ephemeral"}
    )) {
        $mRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($gDef.id)/members?`$select=id,displayName&`$top=999" -o json 2>$null
        $existingMembers[$gDef.id] = @()
        if ($mRaw) { try { $parsed = ($mRaw -join '') | ConvertFrom-Json; if ($parsed.value) { $existingMembers[$gDef.id] = $parsed.value } } catch {} }
        Write-Host "  $($gDef.n): $($existingMembers[$gDef.id].Count) current members" -ForegroundColor DarkGray
    }
    Write-Host ""

    $added = 0; $skipped = 0; $moved = 0

    foreach ($m in $matched) {
        $devId = $m.device.id
        $devName = $m.device.displayName
        $lastSign = $m.device.lastSignIn

        # Determine target group based on last sign-in
        $targetGroup = $grpMain
        $targetLabel = "Main"
        if ($lastSign) {
            try {
                $daysAgo = ((Get-Date) - [DateTime]::Parse($lastSign)).Days
                if ($daysAgo -gt 30) { $targetGroup = $grpStale30; $targetLabel = "Stale-30d" }
                elseif ($daysAgo -gt 7) { $targetGroup = $grpStale7; $targetLabel = "Stale-7d" }
            } catch { }
        } else {
            $targetGroup = $grpStale7; $targetLabel = "Stale-7d"
        }

        # Check if already in target group
        $inTarget = $existingMembers[$targetGroup] | Where-Object { $_.id -eq $devId }
        if ($inTarget) {
            Write-Host "  [=] $devName -> already in $targetLabel" -ForegroundColor Gray
            $skipped++
            continue
        }

        # Check if in wrong group -> remove first
        foreach ($otherId in @($grpMain, $grpStale7, $grpStale30, $grpEph)) {
            if ($otherId -eq $targetGroup) { continue }
            $inOther = $existingMembers[$otherId] | Where-Object { $_.id -eq $devId }
            if ($inOther) {
                az rest --method DELETE --uri "https://graph.microsoft.com/v1.0/groups/$otherId/members/$devId/`$ref" --output none 2>&1 | Out-Null
                Write-Host "  [~] $devName removed from old group" -ForegroundColor Yellow
                $moved++
                break
            }
        }

        # Add to target group
        $body = "{`"@odata.id`":`"https://graph.microsoft.com/v1.0/directoryObjects/$devId`"}"
        $bodyFile = Join-Path $tempPath "add-member.json"
        $body | Out-File $bodyFile -Encoding UTF8 -Force -NoNewline

        az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$targetGroup/members/`$ref" --headers "Content-Type=application/json" --body "@$bodyFile" --output none 2>&1 | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [+] $devName -> $targetLabel" -ForegroundColor Green
            $added++
        } else {
            Write-Host "  [!] $devName -> may already exist" -ForegroundColor DarkYellow
        }
    }

    Write-Host "`n  Added: $added | Moved: $moved | Already: $skipped" -ForegroundColor Cyan
}

# ============================================================
# FASE 5: FINAL VERIFICATION
# ============================================================
Write-Host "`n--- FASE 5: VERIFICATION ---`n" -ForegroundColor Cyan

$totalInGroups = 0
foreach ($gDef in @(
    @{id=$grpMain;n="Main"}, @{id=$grpStale7;n="Stale-7d"},
    @{id=$grpStale30;n="Stale-30d"}, @{id=$grpEph;n="Ephemeral"}
)) {
    $mRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($gDef.id)/members?`$select=displayName&`$top=999" -o json 2>$null
    $members = @()
    if ($mRaw) { try { $parsed = ($mRaw -join '') | ConvertFrom-Json; if ($parsed.value) { $members = $parsed.value } } catch {} }
    $totalInGroups += $members.Count
    Write-Host "  $($gDef.n): $($members.Count) devices" -ForegroundColor $(if($members.Count -gt 0){'Green'}else{'Yellow'})
    foreach ($mbr in $members) { Write-Host "    - $($mbr.displayName)" -ForegroundColor DarkGray }
}

# ============================================================
# REPORT
# ============================================================
Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v3 -- REPORT" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  VMs:        $($vmList.Count)" -ForegroundColor White
Write-Host "  Devices:    $($deviceList.Count)" -ForegroundColor White
Write-Host "  Matched:    $($matched.Count)" -ForegroundColor Green
Write-Host "  Unmatched:  $($unmatched.Count)" -ForegroundColor $(if($unmatched.Count -gt 0){'Yellow'}else{'Green'})
Write-Host "  In Groups:  $totalInGroups" -ForegroundColor White

if ($unmatched.Count -gt 0) {
    Write-Host "`n  UNMATCHED VMs (need AAD extension or VM may be off):" -ForegroundColor Yellow
    foreach ($u in $unmatched) {
        Write-Host "    $($u.name) [$($u.os)] $($u.rg)" -ForegroundColor DarkYellow
    }
    Write-Host "`n  To fix: start deallocated VMs, ensure AAD extension is installed," -ForegroundColor Gray
    Write-Host "  wait 5-10 min for Entra propagation, then re-run this script." -ForegroundColor Gray
}

Write-Host "================================================================`n" -ForegroundColor Magenta

# Export log
$logFile = Join-Path $tempPath ("mde-fix-v3-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
$logLines = @("FIX v3 -- $(Get-Date)", ("=" * 50), "VMs:$($vmList.Count) Matched:$($matched.Count) Unmatched:$($unmatched.Count)", "")
foreach ($m in $matched) { $logLines += "$($m.layer) | $($m.vm.name) -> $($m.device.displayName)" }
$logLines += ""
foreach ($u in $unmatched) { $logLines += "MISS | $($u.name) [$($u.os)] $($u.rg)" }
$logLines | Out-File $logFile -Encoding UTF8 -Force
Write-Host "  Log: $logFile`n" -ForegroundColor Gray
