# MDE Policy Automation v2 — Architecture Design Document

**Author:** Rafael França  
**Date:** 2026-03-09  
**Status:** DRAFT — Ready for Review  
**Scope:** Replace Automation Account-centric v1 with direct Graph API sync + parallel operations

---

## 1. Executive Summary

v1 uses Azure Automation Account (stages 5–11) for device sync, requiring:
- Automation Account + Managed Identity + RBAC + Graph permissions + PS modules + Runbook + Schedule + JobSchedule
- **7 stages** of fragile infrastructure that hangs in PS 5.1 ISE and uses experimental `az automation` commands
- Name-based matching only (unreliable for VMs with domain suffixes, duplicate names, or naming conventions that differ between Azure/Entra/MDE)

**v2 eliminates 5 stages** by running the sync directly via `az rest` (proven in `Fix-RegisterAndSync.ps1`) and adds a **3-layer matching strategy** for deterministic VM ↔ Entra ↔ MDE correlation.

### Comparison

| Aspect | v1 (14 stages) | v2 (9 stages) |
|--------|----------------|---------------|
| Sync mechanism | Automation Account Runbook | Direct Graph API via `az rest` |
| Matching | Name-only (Layer 3) | 3-layer: physicalIds → aadDeviceId → name |
| Extension install | Sequential (~3min/VM) | Parallel via `Start-Job` (~3min total for batch) |
| PS 5.1 ISE compat | ❌ Hangs on `az automation` | ✅ All commands stable |
| Stages | 14 | 9 |
| Automation Account | Required | Optional (for hourly auto-sync clients) |
| Human interaction | MDE Device Group manual setup | Same (no API available) |

---

## 2. Research Findings

### 2.1 — physicalIds Field (Entra ID Device)

**Source:** [Microsoft Graph API — device resource](https://learn.microsoft.com/en-us/graph/api/resources/device)

The `physicalIds` property is documented as `String collection — For internal use only. Not nullable.`

Despite the "internal use" label, **it IS populated and queryable** via Graph API. When an Azure VM has the AAD login extension (`AADLoginForWindows` or `AADSSHLoginForLinux`) installed, the Device Registration Service writes entries to `physicalIds` including:

```
[AzureResourceId]:/subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Compute/virtualMachines/{vmName}
[USER-GID]:{guid}
[GID]:{guid}
```

**Key finding:** The `[AzureResourceId]:` prefix entry contains the **full ARM resource ID** of the VM. This allows deterministic matching — no ambiguity.

**Query example:**
```powershell
# Get Entra device by Azure Resource ID (exact match)
$armId = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Compute/virtualMachines/$vmName"
$filter = "physicalIds/any(p:p eq '[AzureResourceId]:$armId')"
$uri = "https://graph.microsoft.com/v1.0/devices?`$filter=$filter&`$select=id,deviceId,displayName,physicalIds,approximateLastSignInDateTime"
$result = az rest --method GET --uri $uri -o json | ConvertFrom-Json
```

**Limitations:**
- Only works for VMs that have the AAD extension installed
- `physicalIds` is listed as "internal use" — Microsoft could change format (low risk, has been stable since 2020+)
- Requires `Device.Read.All` permission to query (already used in v1)
- `$filter` on `physicalIds` requires `ConsistencyLevel: eventual` header and `$count=true`

### 2.2 — MDE aadDeviceId ↔ Entra deviceId Correlation

**Source:** [MDE Machine API](https://learn.microsoft.com/en-us/defender-endpoint/api/machine)

The MDE Machine resource exposes:
```json
{
    "id": "1e5bc9d7e413ddd7902c2932e418702b84d0cc07",
    "computerDnsName": "mymachine1.contoso.com",
    "aadDeviceId": "80fe8ff8-2624-418e-9591-41f0491218f9",
    "isAadJoined": true,
    "machineTags": ["test tag 1"]
}
```

The `aadDeviceId` in MDE **directly equals** the `deviceId` property on the Entra ID device object (NOT the `id` which is the directory object ID).

**Correlation logic:**
```
MDE Machine.aadDeviceId == Entra Device.deviceId  (GUID, unique per device)
```

**This is the strongest correlation** because:
- It's a Microsoft-maintained GUID relationship
- Both sides populate it when the device is AAD-joined
- `aadDeviceId` is filterable in the MDE List Machines API
- No naming ambiguity

**Limitations:**
- `aadDeviceId` is `null` when the machine is NOT AAD-joined
- Requires MDE P2 license and `Machine.Read.All` API permission
- Requires the VM to be both MDE-onboarded AND Entra-registered

### 2.3 — Parallel Extension Installation

**Finding:** `az vm extension set` is a synchronous ARM operation (blocks until provisioned or timeout). Each call takes 1–3 minutes per VM.

**Parallel approach using `Start-Job` in PS 5.1:**
```powershell
# PS 5.1 compatible parallel extension installation
$jobs = @()
foreach ($vm in $unregisteredVMs) {
    $extName = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }
    $jobs += Start-Job -ScriptBlock {
        param($rg, $name, $ext)
        az vm extension set --resource-group $rg --vm-name $name `
            --name $ext --publisher "Microsoft.Azure.ActiveDirectory" `
            --output none 2>$null
    } -ArgumentList $vm.rg, $vm.name, $extName
}

# Wait for all jobs (with timeout)
$jobs | Wait-Job -Timeout 600
$results = $jobs | Receive-Job
$jobs | Remove-Job -Force
```

**Key considerations:**
- `Start-Job` spawns a new process per job — fine for 30 VMs, avoid 500+ simultaneous
- Batch in groups of 10–20 to avoid ARM throttling (1200 writes/sub/hour)
- Each child process needs `az` on PATH (always true if parent has it)
- `Wait-Job -Timeout` prevents infinite hangs
- Works in PS 5.1, PS 7, Cloud Shell, and ISE

---

## 3. 3-Layer Matching Strategy

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Azure Subscription                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │  VM-001   │  │  VM-002   │  │  VM-003   │  ...       │
│  │ armId: /s │  │ armId: /s │  │ armId: /s │             │
│  │ vmId: abc │  │ vmId: def │  │ vmId: ghi │             │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘            │
│        │              │              │                    │
└────────┼──────────────┼──────────────┼────────────────────┘
         │              │              │
    ┌────▼──────────────▼──────────────▼────┐
    │          MATCH ENGINE (3 Layers)       │
    │                                        │
    │  L1: physicalIds contains armId  ────► 95% hit rate   │
    │  L2: deviceId == aadDeviceId     ────► 80% hit rate   │
    │  L3: normalized name match       ────► 70% hit rate   │
    │                                        │
    │  Priority: L1 > L2 > L3               │
    │  Confidence: L1=EXACT, L2=HIGH, L3=MEDIUM │
    └────────────────────────────────────────┘
         │              │              │
    ┌────▼──────────────▼──────────────▼────┐
    │            Entra ID Devices            │
    │  ┌──────────┐  ┌──────────┐           │
    │  │Device-001│  │Device-002│  ...      │
    │  │ id: xxx  │  │ id: yyy  │           │
    │  │deviceId: │  │deviceId: │           │
    │  │ aaa-bbb  │  │ ccc-ddd  │           │
    │  └──────────┘  └──────────┘           │
    └────────────────────────────────────────┘
         │              │
    ┌────▼──────────────▼───────────────────┐
    │            MDE Machines                │
    │  aadDeviceId == Entra deviceId         │
    │  machineTags: subscription tag         │
    └────────────────────────────────────────┘
```

### Layer Details

#### Layer 1: physicalIds → Azure Resource ID (BEST — deterministic)

```powershell
function Match-ByPhysicalIds {
    param([object[]]$VMs, [hashtable]$Headers)
    
    $matched = @{}
    foreach ($vm in $VMs) {
        $armId = $vm.id  # Full ARM resource ID
        $encodedFilter = [System.Uri]::EscapeDataString(
            "physicalIds/any(p:p eq '[AzureResourceId]:$armId')"
        )
        $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=$encodedFilter&`$select=id,deviceId,displayName,approximateLastSignInDateTime&`$count=true"
        
        $result = az rest --method GET --uri $uri `
            --headers "ConsistencyLevel=eventual" -o json 2>$null | ConvertFrom-Json
        
        if ($result.value.Count -gt 0) {
            $matched[$vm.name] = @{
                VM = $vm
                Device = $result.value[0]
                MatchLayer = "L1-PhysicalIds"
                Confidence = "EXACT"
            }
        }
    }
    return $matched
}
```

**When this works:** VM has AAD extension installed → Device Registration Service wrote ARM ID to `physicalIds`.  
**When this fails:** VM does NOT have AAD extension, or extension failed to install.  
**Expected hit rate:** ~95% of VMs with AAD extension.

#### Layer 2: aadDeviceId ↔ deviceId (HIGH — requires MDE)

```powershell
function Match-ByAadDeviceId {
    param([object[]]$UnmatchedVMs, [object[]]$EntraDevices, [object[]]$MDEMachines)
    
    $matched = @{}
    
    # Build lookup: MDE computerDnsName → aadDeviceId
    $mdeByName = @{}
    foreach ($m in $MDEMachines) {
        if ($m.aadDeviceId) {
            # Strip domain from DNS name: "vm001.contoso.com" → "vm001"
            $shortName = ($m.computerDnsName -split '\.')[0].ToLower()
            $mdeByName[$shortName] = $m
        }
    }
    
    # Build lookup: Entra deviceId → device object
    $entraByDeviceId = @{}
    foreach ($d in $EntraDevices) {
        if ($d.deviceId) {
            $entraByDeviceId[$d.deviceId] = $d
        }
    }
    
    foreach ($vm in $UnmatchedVMs) {
        $vmShort = $vm.name.ToLower()
        $mdeMachine = $mdeByName[$vmShort]
        
        if ($mdeMachine -and $mdeMachine.aadDeviceId) {
            $entraDevice = $entraByDeviceId[$mdeMachine.aadDeviceId]
            if ($entraDevice) {
                $matched[$vm.name] = @{
                    VM = $vm
                    Device = $entraDevice
                    MDEMachine = $mdeMachine
                    MatchLayer = "L2-AadDeviceId"
                    Confidence = "HIGH"
                }
            }
        }
    }
    return $matched
}
```

**When this works:** VM is onboarded to MDE AND AAD-joined → MDE records `aadDeviceId`.  
**When this fails:** VM not in MDE, or `aadDeviceId` is null (not AAD-joined).  
**Expected hit rate:** ~80% (your VMs are already MDE-onboarded, so this should be very high).

#### Layer 3: Normalized Name Match (MEDIUM — fallback)

```powershell
function Match-ByNormalizedName {
    param([object[]]$UnmatchedVMs, [object[]]$EntraDevices)
    
    $matched = @{}
    foreach ($vm in $UnmatchedVMs) {
        $vmNorm = $vm.name.ToLower().Trim()
        
        $found = $EntraDevices | Where-Object {
            $devNorm = $_.displayName.ToLower().Trim()
            # Exact match
            $devNorm -eq $vmNorm -or
            # VM name is prefix of device name (domain suffix: "vm001.contoso.com")
            $devNorm.StartsWith("$vmNorm.") -or
            # Device name is prefix (short name registered)
            $vmNorm.StartsWith("$devNorm.")
        } | Select-Object -First 1
        
        if ($found) {
            $matched[$vm.name] = @{
                VM = $vm
                Device = $found
                MatchLayer = "L3-NameMatch"
                Confidence = "MEDIUM"
            }
        }
    }
    return $matched
}
```

**When this works:** Names happen to match between Azure VM and Entra device.  
**When this fails:** Name collisions (two VMs named "web01" in different RGs), domain suffixes that don't parse cleanly, VMs renamed after registration.  
**Expected hit rate:** ~70% (current v1 approach).

### Combined Match Pipeline

```powershell
function Invoke-3LayerMatch {
    param($VMs, $EntraDevices, $MDEMachines, $Headers)
    
    $allMatched = @{}
    $remaining = @($VMs)
    
    # Layer 1: physicalIds (most reliable)
    Write-Host "  [L1] Matching by physicalIds..." -ForegroundColor Cyan
    $l1 = Match-ByPhysicalIds -VMs $remaining -Headers $Headers
    foreach ($k in $l1.Keys) { $allMatched[$k] = $l1[$k] }
    $remaining = @($remaining | Where-Object { $_.name -notin $l1.Keys })
    Write-Host "    L1 matched: $($l1.Count) | Remaining: $($remaining.Count)"
    
    # Layer 2: aadDeviceId (high confidence)
    if ($remaining.Count -gt 0 -and $MDEMachines) {
        Write-Host "  [L2] Matching by aadDeviceId..." -ForegroundColor Cyan
        $l2 = Match-ByAadDeviceId -UnmatchedVMs $remaining -EntraDevices $EntraDevices -MDEMachines $MDEMachines
        foreach ($k in $l2.Keys) { $allMatched[$k] = $l2[$k] }
        $remaining = @($remaining | Where-Object { $_.name -notin $l2.Keys })
        Write-Host "    L2 matched: $($l2.Count) | Remaining: $($remaining.Count)"
    }
    
    # Layer 3: Name matching (fallback)
    if ($remaining.Count -gt 0) {
        Write-Host "  [L3] Matching by normalized name..." -ForegroundColor Cyan
        $l3 = Match-ByNormalizedName -UnmatchedVMs $remaining -EntraDevices $EntraDevices
        foreach ($k in $l3.Keys) { $allMatched[$k] = $l3[$k] }
        $remaining = @($remaining | Where-Object { $_.name -notin $l3.Keys })
        Write-Host "    L3 matched: $($l3.Count) | Remaining: $($remaining.Count)"
    }
    
    # Report unmatched
    if ($remaining.Count -gt 0) {
        Write-Host "  [UNMATCHED] $($remaining.Count) VMs have no Entra device:" -ForegroundColor Yellow
        foreach ($vm in $remaining) {
            Write-Host "    - $($vm.name) (needs AAD extension)" -ForegroundColor Yellow
        }
    }
    
    return @{ Matched = $allMatched; Unmatched = $remaining }
}
```

---

## 4. v2 Stage Breakdown (9 Stages)

### Stage 1: Authentication & Subscription Selection
**Same as v1.** Authenticate via `az login`, list subscriptions, select one or more.

### Stage 2: Intelligent Naming
**Same as v1.** Generate deterministic names from subscription name.

### Stage 3: Resource Group
**Same as v1.** Create/reuse RG with corporate tags.  
*Note: In v2, the RG is lighter — it may only contain the Azure Policy assignment. No Automation Account required by default.*

### Stage 4: Entra ID Security Groups (4 groups)
**Same as v1.** Create Main, Stale-7d, Stale-30d, Ephemeral groups.

### Stage 5: AAD Extension — Parallel Installation ⭐ NEW
**Replaces:** Nothing (v1 didn't install extensions)

```
FOR EACH subscription:
  1. List all VMs (az vm list)
  2. Check which VMs already have AAD extension
  3. For unregistered VMs → install AAD extension in PARALLEL via Start-Job
  4. Wait for completion (timeout: 10 min)
  5. Batch: max 15 concurrent jobs (ARM throttling protection)
```

```powershell
# Stage 5: Parallel AAD Extension Installation
$vmList = az vm list --subscription $subId `
    --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id}" `
    -o json | ConvertFrom-Json

$unregistered = @()
foreach ($vm in $vmList) {
    $extName = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }
    $extCheck = az vm extension show --resource-group $vm.rg --vm-name $vm.name `
        --name $extName --query "provisioningState" -o tsv 2>$null
    if ($extCheck -ne "Succeeded") {
        $unregistered += $vm
    }
}

Write-Host "  VMs without AAD extension: $($unregistered.Count)" -ForegroundColor Yellow

# Install in parallel batches of 15
$batchSize = 15
for ($i = 0; $i -lt $unregistered.Count; $i += $batchSize) {
    $batch = $unregistered[$i..([Math]::Min($i + $batchSize - 1, $unregistered.Count - 1))]
    $jobs = @()
    
    foreach ($vm in $batch) {
        $extType = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }
        $jobs += Start-Job -ScriptBlock {
            param($rg, $name, $ext)
            $r = az vm extension set --resource-group $rg --vm-name $name `
                --name $ext --publisher "Microsoft.Azure.ActiveDirectory" `
                --output none 2>&1
            return @{ VM = $name; Success = ($LASTEXITCODE -eq 0); Output = $r }
        } -ArgumentList $vm.rg, $vm.name, $extType
    }
    
    $jobs | Wait-Job -Timeout 600
    $results = $jobs | Receive-Job
    $jobs | Remove-Job -Force
    
    foreach ($r in $results) {
        $status = if ($r.Success) { "OK" } else { "WARN" }
        Write-Host "    [$status] $($r.VM)" -ForegroundColor $(if ($r.Success) { "Green" } else { "Yellow" })
    }
    
    # Brief pause between batches for ARM to breathe
    if ($i + $batchSize -lt $unregistered.Count) { Start-Sleep -Seconds 5 }
}

# Wait for Entra ID propagation
Write-Host "  Waiting 90s for Entra ID device propagation..." -ForegroundColor Gray
Start-Sleep -Seconds 90
```

### Stage 6: Direct Device Sync ⭐ NEW (Replaces v1 Stages 5–11)
**Replaces:** Automation Account, Managed Identity, RBAC, Graph Permissions, PS Modules, Runbook, Schedule, Job Schedule

This is the **core of v2** — proven logic from `Fix-RegisterAndSync.ps1`, enhanced with 3-layer matching.

```powershell
# Stage 6: Direct Device Sync via Graph API
Write-Host "[6/9] DEVICE SYNC (DIRECT GRAPH API)" -ForegroundColor Cyan

# 6a. Gather all data sources
$vms = az vm list --subscription $subId `
    --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}" `
    -o json | ConvertFrom-Json

$entraDevices = @()  # paginated fetch
$nextUri = "https://graph.microsoft.com/v1.0/devices?`$select=id,deviceId,displayName,physicalIds,approximateLastSignInDateTime&`$top=999"
while ($nextUri) {
    $page = az rest --method GET --uri $nextUri -o json | ConvertFrom-Json
    $entraDevices += $page.value
    $nextUri = $page.'@odata.nextLink'
}

# 6b. Optional: MDE machines (if P2 licensed)
$mdeMachines = $null
if ($hasMDELicense) {
    # Use App Registration token (from Stage 8) or user token
    $mdeMachines = Invoke-RestMethod -Uri "https://api.security.microsoft.com/api/machines" `
        -Headers @{ Authorization = "Bearer $mdeToken" } -Method GET
    $mdeMachines = $mdeMachines.value
}

# 6c. Run 3-layer match
$matchResult = Invoke-3LayerMatch -VMs $vms -EntraDevices $entraDevices -MDEMachines $mdeMachines

# 6d. Classify by staleness
$now = [DateTime]::UtcNow
$t7 = $now.AddDays(-7)
$t30 = $now.AddDays(-30)

$active = @(); $stale7 = @(); $stale30 = @()
foreach ($entry in $matchResult.Matched.Values) {
    $lastSign = $entry.Device.approximateLastSignInDateTime
    if ($lastSign) {
        $dt = [DateTime]::Parse($lastSign)
        if ($dt -ge $t7) { $active += $entry }
        elseif ($dt -ge $t30) { $stale7 += $entry }
        else { $stale30 += $entry }
    } else {
        $stale7 += $entry  # No sign-in data → assume stale
    }
}

# 6e. Sync each group (add/remove members)
# ... (same logic as v1 runbook but running directly)
```

### Stage 7: Azure Policy for Tagging
**Same as v1 Stage 12.** Create/assign Azure Policy for `mde_device_id` tag.

### Stage 8: MDE Device Groups (HTML guide)
**Same as v1 Stage 13.** Generate HTML instructions for manual MDE Device Group setup.

### Stage 9: MDE Machine Tags (App Registration + API)
**Same as v1 Stage 14.** Create App Registration, grant MDE permissions, apply subscription tags.

### NEW — Optional Stage 10: Automation Account (OPT-IN)
For clients who want **hourly auto-sync**, offer to create the Automation Account infrastructure:

```
  Want to enable hourly auto-sync? (requires Automation Account) [N]: 
  [ENTER for NO | Y for YES]
```

If YES → deploy v1 stages 5–11 (AA, MI, RBAC, Graph, Modules, Runbook, Schedule).  
If NO → user runs the script manually or schedules via Task Scheduler / cron.

---

## 5. Automation Account: OPTIONAL vs DEFAULT

### Recommendation: Direct sync DEFAULT, Automation Account OPTIONAL

| Scenario | Approach |
|----------|----------|
| **Initial deployment** (30 subs) | Direct sync — run script once, done |
| **Ongoing governance** (daily/hourly) | Optional AA for auto-sync |
| **Cloud Shell / ad-hoc** | Direct sync — no infrastructure needed |
| **Enterprise compliance** (audit trail) | AA — provides job history and logs |

**Justification:**
1. Most clients run the deployment once and then use Azure Policy for ongoing tag management
2. The Automation Account runbook logic is identical to the direct sync — no functional difference
3. Removing 7 stages from the default path dramatically simplifies the script
4. Clients who need hourly sync can opt in — the code is the same, just wrapped in a runbook

---

## 6. Risks and Limitations

### 6.1 — physicalIds Stability Risk
- **Risk:** `physicalIds` is documented as "For internal use only"
- **Mitigation:** Has been stable since 2020+. Used by Microsoft's own tools (Intune, Defender). Field format hasn't changed. We fall back to Layer 2 and 3 if Layer 1 fails.
- **Severity:** LOW

### 6.2 — Graph API Rate Limiting
- **Risk:** Querying `physicalIds` per-VM makes N API calls (one per VM)
- **Mitigation:** For 30 subs × 50 VMs = 1500 calls → well within Graph limits (10,000/10min per tenant). Add 100ms delay between calls.
- **Alternative:** Bulk-fetch all devices with `$select=physicalIds` and match client-side (1 call instead of N)
- **Severity:** LOW

### 6.3 — Start-Job Process Overhead
- **Risk:** `Start-Job` spawns a new PowerShell process per job. 500+ jobs = resource exhaustion.
- **Mitigation:** Batch in groups of 15. For 30 subs × 50 VMs = 1500 VMs, that's 100 batches sequentially — still fast (100 × 5s gap = ~8 min overhead).
- **Severity:** LOW

### 6.4 — MDE API Access
- **Risk:** Layer 2 matching requires MDE P2 license and API access
- **Mitigation:** Layer 2 is optional — we only use it if MDE token is available. Layer 1 + Layer 3 handle most cases.
- **Severity:** LOW (client already has MDE)

### 6.5 — AAD Extension on Running VMs Only
- **Risk:** `az vm extension set` requires VM to be running. Deallocated VMs are skipped.
- **Mitigation:** Report deallocated VMs separately. User can start them and re-run.
- **Severity:** MEDIUM

### 6.6 — ConsistencyLevel: eventual
- **Risk:** Queries with `physicalIds` filter require `ConsistencyLevel: eventual` header. Results may be stale by a few seconds.
- **Mitigation:** We're running this as a batch process, not real-time. Eventual consistency is fine.
- **Severity:** NEGLIGIBLE

---

## 7. Bulk physicalIds Matching (Optimization)

Instead of N individual Graph API calls for Layer 1, we can **bulk-fetch all devices** and match client-side:

```powershell
# Fetch ALL Entra devices with physicalIds (paginated)
$allDevices = @()
$uri = "https://graph.microsoft.com/v1.0/devices?`$select=id,deviceId,displayName,physicalIds,approximateLastSignInDateTime&`$top=999"
while ($uri) {
    $page = az rest --method GET --uri $uri `
        --headers "ConsistencyLevel=eventual" -o json | ConvertFrom-Json
    $allDevices += $page.value
    $uri = $page.'@odata.nextLink'
}

# Build lookup: ARM Resource ID → Entra Device
$armIdToDevice = @{}
foreach ($dev in $allDevices) {
    foreach ($pid in $dev.physicalIds) {
        if ($pid -like '[AzureResourceId]:*') {
            $armId = $pid.Replace('[AzureResourceId]:', '')
            $armIdToDevice[$armId.ToLower()] = $dev
        }
    }
}

# Layer 1: Direct hashtable lookup (O(1) per VM)
foreach ($vm in $vms) {
    $device = $armIdToDevice[$vm.id.ToLower()]
    if ($device) {
        # EXACT MATCH via physicalIds
    }
}
```

**Performance:** 1–3 Graph API calls (pagination) instead of N. O(N) build + O(1) per lookup.

---

## 8. v2 Script Structure

```
Deploy-MDE-Automation-v2.ps1
│
├── [Functions]
│   ├── Test-AzureResource
│   ├── Write-ValidationStep
│   ├── Match-ByPhysicalIds        ← NEW
│   ├── Match-ByAadDeviceId        ← NEW
│   ├── Match-ByNormalizedName     ← NEW (improved v1 logic)
│   ├── Invoke-3LayerMatch         ← NEW (orchestrator)
│   ├── Sync-GroupMembers          ← NEW (extracted from runbook)
│   ├── Install-AADExtensionParallel ← NEW
│   └── Get-AllGraphPages          ← Existing (from runbook)
│
├── [Stage 1] Authentication & Subscription Selection
├── [Stage 2] Intelligent Naming
├── [Stage 3] Resource Group + Tags
├── [Stage 4] Entra ID Security Groups (4 groups)
├── [Stage 5] AAD Extension — Parallel Install     ← NEW
├── [Stage 6] Direct Device Sync (3-Layer Match)    ← NEW (replaces 5-11)
├── [Stage 7] Azure Policy for Tagging
├── [Stage 8] MDE Device Groups (HTML guide)
├── [Stage 9] MDE Machine Tags (App Reg + API)
├── [Stage 10?] OPTIONAL: Automation Account        ← Opt-in
│
└── [Report] HTML Deployment Report
```

**Estimated line count:** ~1200 (vs 1709 in v1)  
**Estimated runtime per sub:** ~5 min (vs ~12 min in v1, due to eliminated AA propagation waits)

---

## 9. Migration Path (v1 → v2)

For clients already running v1:

1. **v2 detects existing v1 resources** (AA, Runbook, Schedule) and reports them
2. **v2 does NOT delete v1 resources** — they can coexist
3. **User can choose:**
   - Keep AA running (hourly sync) + run v2 direct sync (one-time)
   - Disable AA schedule and rely on manual v2 runs
   - Delete AA resources after confirming v2 works

```powershell
# v2 Migration Detection
$existingAA = az resource list --resource-group $rgName `
    --resource-type "Microsoft.Automation/automationAccounts" -o json | ConvertFrom-Json
if ($existingAA.Count -gt 0) {
    Write-Host "  [DETECTED] v1 Automation Account: $($existingAA[0].name)" -ForegroundColor Yellow
    Write-Host "  v1 resources will NOT be deleted. They can coexist with v2." -ForegroundColor Gray
    Write-Host "  To remove after v2 is confirmed working:" -ForegroundColor Gray
    Write-Host "    az resource delete --ids $($existingAA[0].id)" -ForegroundColor White
}
```

---

## 10. Decision Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Primary sync method | Direct Graph API | Proven in Fix-RegisterAndSync.ps1, no infra needed |
| Matching strategy | 3-layer cascade | Maximizes match rate, degrades gracefully |
| Layer 1 implementation | Bulk fetch + client-side lookup | 1-3 API calls vs N, faster for 30+ subs |
| Parallel extension install | `Start-Job` with batch of 15 | PS 5.1 compatible, ARM throttle-safe |
| Automation Account | Optional opt-in | Simplifies default path, available for enterprise |
| v1 migration | Non-destructive coexistence | Zero risk for existing deployments |

---

## 11. Next Steps

- [ ] Review this design document
- [ ] Approve 3-layer matching approach
- [ ] Decide on Automation Account opt-in flow (prompt or flag?)
- [ ] Implement `Deploy-MDE-Automation-v2.ps1`
- [ ] Test with 2–3 subscriptions before rolling to 30
- [ ] Update `ARCHITECTURE.md` with v2 diagrams
- [ ] Update `README.md` with v2 instructions

---

*Document generated: 2026-03-09 | MDE Policy Automation v2 Design*
