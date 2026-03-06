# Changelog

All notable changes to MDE Policy Automation will be documented in this file.

## [1.3.0] — 2026-03-06

### Added
- **Ephemeral device group**: New Entra ID Security Group `grp-mde-{sub}-ephemeral` for tracking destroyed VMs (VMSS autoscale, Kubernetes nodes, Databricks clusters, Spot instances, CI/CD runners)
- **Ephemeral naming pattern detection**: Runbook identifies VMSS (`_N`, `vmssXXXXXX`), AKS (`aks-*`), Databricks (`workers*`), Spot/Arc (`ip-*`), CI runners (`runner-*`) patterns in device names and logs the ephemeral type for SOC
- Ephemeral detection: devices that were in the main group but whose VM no longer exists in Azure are moved to the ephemeral group
- Auto-cleanup: devices removed from ephemeral group when their Entra ID record expires or when a new VM matches the same device
- Ephemeral group syncs bidirectionally every hour (add new ephemeral + remove recovered/expired)
- SOC visibility preserved: security teams can investigate incidents on VMs that no longer exist
- **Source**: MDE "Transient device" tagging excludes Servers (confirmed MS docs) — making this automation the only way to track ephemeral server VMs

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
