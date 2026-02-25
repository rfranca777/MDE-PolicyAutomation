# Changelog

All notable changes to MDE Policy Automation will be documented in this file.

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
