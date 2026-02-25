# Architecture

## Overview

MDE Policy Automation uses a **three-layer approach** to ensure complete device governance:

### Layer 1: Azure Policy (Infrastructure-Level)

- **Mechanism**: `DeployIfNotExists` Azure Policy
- **What it does**: Deploys a Custom Script Extension on every Windows VM
- **Script**: `Set-MDEDeviceTag.ps1` configures the registry key
- **Registry**: `HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging\Group`
- **Result**: MDE agent reads the tag and syncs it to the cloud

### Layer 2: Azure Automation (Operational-Level)

- **Mechanism**: Automation Account with SystemAssigned Managed Identity
- **What it does**: Runs a PowerShell runbook every hour
- **Runbook logic**: Discovers Azure VMs + Arc machines → matches Entra ID devices → adds to Security Group
- **Result**: Entra ID group always reflects current Azure VM fleet

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
