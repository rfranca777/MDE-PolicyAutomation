# MDE-PolicyAutomation — Project Context

> Maintained by sync-constitution.ps1 and updated after each significant session.
> Read this file alongside constitution.md before acting in this project.

## Project Purpose

Automate Microsoft Defender for Endpoint (MDE) policy deployment and device governance
across Azure VMs and Arc-connected machines using Azure Policy, Automation Accounts,
and Microsoft Graph API.

## Canonical Scripts

| Script | Purpose | Status |
|---|---|---|
| `Fix-RegisterAndSync.ps1` | Match Azure VMs → Entra Devices → Sync to Groups | ✅ Canonical (v6 content) |
| `Deploy-MDE.ps1` | Full MDE deployment orchestration (was Deploy-MDE-v2.ps1) | ✅ Canonical |
| `Validate-MDE-Deployment.ps1` | Post-deployment validation | ✅ Canonical |
| `DEPLOY-LAB-VALIDATION.ps1` | Lab environment validation | ✅ Canonical |
| `full-automation/Deploy-MDE-Automation.ps1` | Automation Account runbook | ✅ Canonical |

## Deprecated Scripts (DO NOT RUN — history only)

- `Fix-RegisterAndSync-v2.ps1` — v2, basic expansion
- `Fix-RegisterAndSync-v3.ps1` — v3, initial PS 5.1 ISE fixes
- `Fix-RegisterAndSync-v4.ps1` — v4, Safe-AzJson introduction
- `Fix-RegisterAndSync-v5.ps1` — v5, direct-add approach
- `Fix-v6.ps1` — v6, content promoted to Fix-RegisterAndSync.ps1

## Key Technical Decisions (summary — see docs/ARCHITECTURE.md for full ADRs)

- **ADR-001**: `Safe-AzJson` function — file-based JSON parsing for PS 5.1 ISE compat
- **ADR-002**: `cmd.exe .cmd` trick for complex Graph OData URIs in PS 5.1 ISE
- **ADR-003**: Subscription-scoped device query via `physicalIds` filter (not full tenant)
- **ADR-004**: Direct group add without pre-check — Graph HTTP 400 = idempotent harmless
- **ADR-005**: 6-layer VM-to-device matching (L0-Manual → L6-vmId)
- **ADR-006**: S7 remediation — all versioned files deprecated, canonicals updated

## Environment / Runtime

- **PS Version**: Compatible with PS 5.1 ISE, PS 7, Azure Cloud Shell
- **Dependencies**: `az CLI`, `Microsoft Graph API`, `Entra ID` (Azure AD)
- **Subscription Config**: Hardcoded in script CONFIG sections (S1 known debt — future: move to params)
- **Temp files**: Written to `$env:TEMP` (always cleaned up in finally blocks) and `C:\temp` for log output

## Known Technical Debt

| ID | Violation | Description | Priority | Status |
|---|---|---|---|---|
| TD-001 | S1 | Subscription IDs / Group IDs hardcoded in Fix-RegisterAndSync.ps1 | Medium | ✅ RESOLVED 2026-03-10 — param() block added; defaults preserved for backward compat |
| TD-002 | S1 | Subscription IDs hardcoded in Deploy-MDE.ps1 | Medium | ✅ CLOSED 2026-03-10 — verified compliant; uses `az account list` dynamic selection |
| TD-003 | S7 | Deprecated -vN files still exist in repo (history only) | Low | ⚠️ ACCEPTED — intentional, DEPRECATED headers added; history only |

## Last Updated

2026-03-10 | Session: constitution v1.1.0 sync + TD-001 S1 remediation + runbook version align
