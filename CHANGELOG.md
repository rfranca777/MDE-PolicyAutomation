# Changelog

All notable changes to MDE Policy Automation will be documented in this file.

## [1.5.0] — 2026-03-10

### Fixed (PS 5.1 ISE Compatibility)
- **CRITICAL: `ConvertFrom-Json` fails in PS 5.1 ISE with az CLI output** — az returns
  `System.Object[]` instead of a string. All JSON parsing now uses `Safe-AzJson` (file-based):
  write to temp file → `[IO.File]::ReadAllText` → `ConvertFrom-Json -InputObject`.
- **Graph OData URI mangling in PS 5.1 ISE** — `$filter` expressions with `physicalIds/any`
  were mangled by PS 5.1 shell quoting. Fix: write full `az rest` command to a `.cmd` file
  and execute via `cmd.exe /c`. Bypasses PowerShell interpolation entirely.
- **Full-tenant device scan too slow** — previous versions fetched all Entra devices (10k+).
  Now queries only devices from the target subscription via `physicalIds` filter.
  Performance: minutes → seconds. Requires `ConsistencyLevel: eventual` header.

### Added
- **`Safe-AzJson` helper function** — universal PS 5.1/PS 7/Cloud Shell compatible JSON parser
- **6-layer VM-to-Device matching** (L0–L6) in `Fix-RegisterAndSync.ps1`:
  L0-Manual override, L1-physicalIds, L2-Exact, L3-Normalised, L4-NetBIOS, L5-Fuzzy (≥0.8), L6-vmId
- **Direct group add (idempotent)** — no pre-check; Graph HTTP 400 "already member" treated as success
- **ADR-001 through ADR-006** in `docs/ARCHITECTURE.md` — all architectural decisions documented
- **`.specify/memory/project-context.md`** — canonical script map + tech debt register for agents

### Changed (Constitution S7 Remediation)
- `Fix-RegisterAndSync.ps1` — promoted to canonical with all v6 fixes (266 lines, production-ready)
- `Deploy-MDE-v2.ps1` → **`Deploy-MDE.ps1`** — renamed via `git mv` (history preserved)
- `Fix-RegisterAndSync-v2` through `Fix-v6.ps1` — marked DEPRECATED (git history only, do not run)
- `.github/copilot-instructions.md` — added to enforce constitution in every AI agent session
- Version bumped to 1.5.0

## [1.4.0] — 2026-03-08

### Added
- **Multi-subscription support**: Select multiple subscriptions at once (comma-separated `1,2,3` or `all`). Stages 2-14 execute per subscription with a global summary at the end
- **Custom tags prompt**: Interactive prompt to add/override tags (format: `Key1=Value1 Key2=Value2`). Default 8 corporate tags shown, user can extend. Tags applied to Resource Group + Automation Account
- **MDE license detection**: Stage 14 now checks if WindowsDefenderATP Service Principal exists in tenant before attempting consent. Graceful skip with guidance for tenants without MDE P2 license (fixes AADSTS65006)
- Tags applied to Automation Account via `--tags` parameter

### Changed
- Global config (location, Arc, tags) asked once and reused across all subscriptions
- Stage 1 refactored: subscription selection separated from global config
- Version bumped to 1.4.0

## [1.3.0] — 2026-03-06

### Added
- **Ephemeral device group**: New Entra ID Security Group `grp-mde-{sub}-ephemeral` for tracking destroyed VMs (VMSS autoscale, Kubernetes nodes, Databricks clusters, Spot instances, CI/CD runners)
- **Ephemeral naming pattern detection**: Runbook identifies VMSS (`_N`, `vmssXXXXXX`), AKS (`aks-*`), Databricks (`workers*`), Spot/Arc (`ip-*`), CI runners (`runner-*`) patterns in device names and logs the ephemeral type for SOC
- **Graph API pagination**: Runbook now follows `@odata.nextLink` for all Graph API calls — supports environments with 100+ devices/members
- **Runbook always updated on re-deploy**: Re-running the script now uploads the latest runbook code even if runbook was already Published (ensures version upgrades take effect)

### Fixed
- **CRITICAL: `$IncludeArc` boolean/string bug** — Azure Automation serializes params as strings; `if("False")` was always truthy in PowerShell. Now uses explicit string comparison. Arc support can now actually be disabled
- **CRITICAL: Policy Assignment missing Managed Identity** — `Modify` effect requires `--mi-system-assigned` for remediation. Without it, tags were never auto-applied. Added `--mi-system-assigned --location` to assignment
- **`$appObjectId` undefined on App Registration reuse** — PATCH permissions failed on re-runs (pre-existing since v1.0.4). Now resolved via `az ad app list` query

### Changed
- Runbook `param()` now accepts `$GroupIdEphemeral`
- Stage 4 loop creates 3 auxiliary groups (stale-7d, stale-30d, ephemeral)
- Stage 11 Job Schedule passes `GroupIdEphemeral` parameter
- Stage 13 HTML guide updated with 4-group architecture
- Report shows all 8 groups (4 Entra + 4 MDE) and updated manual run command
- Version bumped to 1.3.0

## [1.2.0] — 2026-03-06

### Added
- **Stale device groups**: Two new Entra ID Security Groups created automatically per subscription (Stage 4):
  - `grp-mde-{sub}-stale7` — devices inactive for 7+ days
  - `grp-mde-{sub}-stale30` — devices inactive for 30+ days
- **Ephemeral device cleanup**: Main group now automatically removes devices whose VMs no longer exist in the subscription (deleted/decommissioned)
- **Smart main group criteria**: Main group (`grp-mde-{sub}`) now contains only devices that (1) exist as VM/Arc in the subscription AND (2) reported (`approximateLastSignInDateTime`) within the last 7 days
- **Bi-directional sync**: Runbook now adds AND removes members from all 3 groups every hour
- Stage 4: stale-7d and stale-30d groups created with same idempotent detect/reuse pattern as main group
- Stage 11: Job Schedule passes `GroupIdStale7` and `GroupIdStale30` parameters to runbook
- Stage 13: HTML guide updated with 3-group architecture and instructions for creating all MDE Device Groups in portal

### Changed
- Runbook `param()` now accepts `$GroupIdStale7` and `$GroupIdStale30`
- Runbook `$select` query extended with `approximateLastSignInDateTime`
- Runbook classification: devices bucketed into `active`, `stale-7`, `stale-30` before any group sync
- Report final shows all 5 groups (main + 2 stale Entra + 2 stale MDE) and updated manual run command
- Version bumped to 1.2.0

## [1.1.0] — 2026-03-03

### Added
- **Linux VM support**: Azure Policy (`policy-definition-linux.json`) deploys CustomScript extension to configure MDE device tags on Linux VMs via `mdatp_managed.json`
- **Azure Arc Windows support**: Azure Policy (`policy-definition-arc-windows.json`) deploys CustomScriptExtension on Arc-enabled Windows machines
- **Azure Arc Linux support**: Azure Policy (`policy-definition-arc-linux.json`) deploys CustomScript extension on Arc-enabled Linux machines
- `Set-MDEDeviceTag.sh`: Bash script for MDE device tag configuration on Linux (Ubuntu, RHEL, CentOS, SLES, Debian, Oracle Linux, Amazon Linux 2, Fedora, Rocky, Alma)
- `Az.ConnectedMachine` module installation in Stage 9 for reliable Azure Arc machine discovery in runbook
- Stage 12 policy now covers both `Microsoft.Compute/virtualMachines` and `Microsoft.HybridCompute/machines` via `anyOf` condition

### Changed
- Stage 9 header updated to reflect dual module installation (Az.Accounts + Az.ConnectedMachine)
- Stage 12 inline Modify policy expanded with `anyOf` to match both Azure VMs and Azure Arc machines
- ARCHITECTURE.md Layer 1 updated to document 4 policy definitions (Windows VM, Linux VM, Arc Windows, Arc Linux)
- ARCHITECTURE.md Layer 2 updated to document Az.ConnectedMachine module dependency
- README.md: Linux Policy Support moved from Roadmap to implemented features
- README.md: Project structure updated with new files
- Version bumped to 1.1.0

### Security
- `Set-MDEDeviceTag.sh` uses Python `sys.argv` for safe argument passing (no shell interpolation)
- `Set-MDEDeviceTag.sh` uses atomic write (temp file + rename) to prevent config corruption
- `Set-MDEDeviceTag.sh` validates tag length (max 200 chars per MDE specification)
- Arc policies use `Azure Connected Machine Resource Administrator` role (minimum privilege for extension deployment)

## [1.0.4] — 2026-01-29

### Added
- **Stage 14**: MDE Machine Tags via API — App Registration + OAuth2 + auto-tagging
- Auto-open browser for admin consent workflow
- Automatic MDE device tagging after consent is granted
- Credential file generation with 2-year expiry tracking

### Changed
- HTML instructions auto-open in default browser
- Enhanced retry logic for Managed Identity propagation (30s AAD recommended)

## [1.0.3] — 2026-01-25

### Added
- **Stage 13**: App Registration for MDE API access
- Client Secret generation with WindowsDefenderATP permissions
- MDE tagging script auto-generation (Apply-MDE-Tags.ps1)

## [1.0.2] — 2026-01-20

### Added
- **12-stage** autonomous deployment pipeline
- Resource Group with 8 corporate tags
- Entra ID Security Group creation via Graph API
- Automation Account with SystemAssigned Managed Identity
- RBAC Reader role assignment with validation
- Graph API permissions: Group.ReadWrite.All, Device.Read.All
- Az.Accounts module installation via PowerShell Gallery
- Runbook with VM ↔ Entra ID device sync logic
- Hourly schedule with Job Schedule linking
- Azure Policy (DeployIfNotExists) for VM tagging
- MDE Device Group HTML instructions with portal deep links
- Full HTML report generation
- Cross-platform support (Windows + Cloud Shell)
- Automatic resource detection and reuse

## [1.0.0] — 2026-01-15

### Added
- Initial Azure Policy for MDE Device Tags
- Set-MDEDeviceTag.ps1 registry configuration script
- Policy definition with CustomScriptExtension deployment
- Support for DeployIfNotExists, AuditIfNotExists, and Disabled effects
