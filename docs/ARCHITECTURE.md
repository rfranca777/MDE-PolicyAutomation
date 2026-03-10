# Architecture

## Overview

MDE Policy Automation uses a **three-layer approach** to ensure complete device governance:

### Layer 1: Azure Policy (Infrastructure-Level)

- **Mechanism**: `DeployIfNotExists` Azure Policy (4 policy definitions)
- **Targets**:
  - **Windows VMs** (`policy-definition.json`): CustomScriptExtension → `Set-MDEDeviceTag.ps1` → Registry key
  - **Linux VMs** (`policy-definition-linux.json`): CustomScript Extension → `Set-MDEDeviceTag.sh` → `mdatp_managed.json`
  - **Arc Windows** (`policy-definition-arc-windows.json`): CustomScriptExtension → `Set-MDEDeviceTag.ps1` → Registry key
  - **Arc Linux** (`policy-definition-arc-linux.json`): CustomScript Extension → `Set-MDEDeviceTag.sh` → `mdatp_managed.json`
- **Windows Script**: `Set-MDEDeviceTag.ps1` configures `HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging\Group`
- **Linux Script**: `Set-MDEDeviceTag.sh` configures `/etc/opt/microsoft/mdatp/managed/mdatp_managed.json` with `edr.tags[].GROUP`
- **Result**: MDE agent reads the tag (registry on Windows, managed JSON on Linux) and syncs it to the cloud

### Layer 2: Azure Automation (Operational-Level)

- **Mechanism**: Automation Account with SystemAssigned Managed Identity
- **What it does**: Runs a PowerShell runbook every hour
- **Runbook logic**: Discovers Azure VMs (`Get-AzVM`) + Arc machines (`Get-AzConnectedMachine`) → matches Entra ID devices → adds to Security Group
- **Required modules**: `Az.Accounts`, `Az.ConnectedMachine`
- **Result**: Entra ID group always reflects current Azure VM + Arc machine fleet

### Layer 3: MDE Integration (Security-Level)

- **Mechanism**: MDE Device Groups linked to Entra ID Security Groups
- **What it does**: MDE applies differentiated policies based on group membership
- **Optional**: Direct MDE API tagging via App Registration (Stage 14)
- **Result**: Correct AV/ASR policies per environment — automatically

## Security Model

```
Zero Trust Approach:
├── Managed Identity (no stored credentials)
├── Reader RBAC (minimum privilege)
├── Graph API (scoped to Group + Device operations)
└── MDE API (Machine.ReadWrite.All — only for Stage 14)
```

## Naming Convention

All resources follow a deterministic naming pattern based on the subscription name:

| Resource | Pattern | Example |
|----------|---------|---------|
| Resource Group | `rg-mde-{sub}` | `rg-mde-production` |
| Automation Account | `aa-mde-{sub}` | `aa-mde-production` |
| Entra Group | `grp-mde-{sub}` | `grp-mde-production` |
| Runbook | `rb-mde-sync-{sub}` | `rb-mde-sync-production` |
| Schedule | `sch-mde-{sub}` | `sch-mde-production` |
| Policy | `pol-mde-tag-{sub}` | `pol-mde-tag-production` |
| MDE Device Group | `mde-policy-{sub}` | `mde-policy-production` |

---

## Architecture Decision Records (ADR)

> Decisions made during development sessions — required by **S3 (Decision Documentation)**.

### ADR-001 — Safe-AzJson: File-Based JSON Parsing for PS 5.1 ISE Compatibility
**Date**: 2026-03-10 | **Status**: Active

**Context**: PowerShell 5.1 ISE does not reliably handle `ConvertFrom-Json` when input
comes from `az CLI` via pipeline. The `az` output is returned as `System.Object[]` instead
of a single string, causing silent parse failures.

**Decision**: All `az` JSON output is written to a temporary file first using
`Out-File -Encoding UTF8`, then read back with `[IO.File]::ReadAllText()`, then parsed
with `ConvertFrom-Json -InputObject`. Temp file always deleted in `finally` block.

**Rejected alternatives**:
- `-join ''` before `ConvertFrom-Json` — worked in PS7, failed in PS 5.1 ISE for some payloads.
- `-InputObject` directly from pipeline — unreliable in PS 5.1 ISE.

**Pattern** (`Safe-AzJson` function in `Fix-RegisterAndSync.ps1`):
```powershell
$tmpFile = Join-Path $env:TEMP ("azj_" + [guid]::NewGuid().ToString("N") + ".json")
& az @AzArgs -o json 2>$null | Out-File $tmpFile -Encoding UTF8 -Force
$content = [System.IO.File]::ReadAllText($tmpFile)
return (ConvertFrom-Json -InputObject $content)
```

---

### ADR-002 — cmd.exe .cmd File for Complex Graph URIs in PS 5.1 ISE
**Date**: 2026-03-10 | **Status**: Active

**Context**: Graph API URIs with `$filter` containing `physicalIds/any(x:startswith(...))`
are mangled by PS 5.1 ISE shell quoting rules when passed directly to `az rest --uri`.
Backtick escaping, single-quote wrapping, and `Safe-AzJson` all failed for this specific case.

**Decision**: Write the full `az rest` command to a temp `.cmd` file using
`[IO.File]::WriteAllText()`, then execute with `& cmd.exe /c $tmpCmd`. This bypasses
PowerShell's string interpolation entirely for the URI value.

**Scope**: Only applied to the FASE 2 device pagination loop where the URI contains
OData filter expressions. All other `az` calls continue to use `Safe-AzJson`.

---

### ADR-003 — Subscription-Scoped Device Query (Not Full Tenant Scan)
**Date**: 2026-03-10 | **Status**: Active

**Context**: Original implementation fetched ALL Entra ID devices (10k+ in large tenants),
taking minutes and creating timeout risk. Per-VM-name queries via Graph `startswith` filter
were tried but broke L1/L4/L6 matching layers that require `physicalIds`.

**Decision**: Query devices filtered by
`physicalIds/any(x:startswith(x,'[AzureResourceId]:/subscriptions/{subId}'))`.
This returns only devices registered from the target subscription — typically a small subset
of the full tenant. Performance: seconds instead of minutes.

**Trade-off**: Requires `ConsistencyLevel: eventual` header. Devices not yet registered
(pending propagation) may not appear. Operator must re-run after ~5 min if VMs are new.

---

### ADR-004 — Direct Group Add Without Pre-Check (Harmless 400)
**Date**: 2026-03-10 | **Status**: Active

**Context**: Pre-checking group membership before adding (`GET members → check → POST`)
doubles API calls and introduces a TOCTOU race condition.

**Decision**: POST directly to `groups/{id}/members/$ref`. If the device is already a
member, Graph returns HTTP 400 with `"One or more added object references already exist"`
— treated as a non-error (idempotent). The script logs `[=] already` and continues.

**Benefit**: Half the API calls, no race condition, simpler code.

---

### ADR-005 — 6-Layer VM-to-Device Matching (L0–L6)
**Date**: 2026-03-10 | **Status**: Active

**Context**: Azure VM names and Entra device display names diverge due to domain suffixes,
NetBIOS truncation, normalisation differences and manual overrides.

**Decision**: Implement layered matching with deterministic priority:

| Layer | Name | Method | Notes |
|---|---|---|---|
| L0 | Manual | `$manualMap` hashtable override | Explicit operator override |
| L1 | Physical IDs | `physicalIds` contains Azure resource ID | Most reliable for Azure VMs |
| L2 | Exact | `displayName == vmName` (case-insensitive) | Same name, no suffix |
| L3 | Normalised | Strip domain, lowercase, `-` unify | `vm-prod.contoso.com` → `vm-prod` |
| L4 | NetBIOS | Truncate to 15 chars | `VERY-LONG-VM-NAME` → `VERY-LONG-VM-NA` |
| L5 | Fuzzy | Longest common substring ≥ 0.8 score | Near-matches |
| L6 | VM ID | `deviceId == vmId` (GUID) | Last resort GUID match |

Each layer only runs if the previous failed. `$used` hashtable prevents duplicate assignments.

---

### ADR-006 — File Naming: Git Versioning Only (S7 Remediation)
**Date**: 2026-03-10 | **Status**: Active (remediated)

**Context**: During the 2026-03-10 development session, version proliferation occurred:
`Fix-RegisterAndSync-v2` through `v5`, `Fix-v6.ps1`, `Deploy-MDE-v2.ps1`. Direct violation
of **S7 (Git Versioning Only)** from the project constitution.

**Remediation applied**:
- `Fix-RegisterAndSync.ps1` — canonical file, updated with v6 content (266 lines, production).
- `Fix-RegisterAndSync-v2.ps1` through `Fix-v6.ps1` — marked DEPRECATED, kept for git history.
- `Deploy-MDE-v2.ps1` → `Deploy-MDE.ps1` — renamed via `git mv` (history preserved).

**Rule going forward**: All changes MUST be made to the canonical file via surgical edits
(O4) and committed with descriptive messages. No new `-vN` files ever.
