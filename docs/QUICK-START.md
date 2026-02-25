# Quick Start Guide

## Option A: Full Automation (Recommended)

### Prerequisites

| Requirement | How to Verify |
|-------------|--------------|
| Azure CLI 2.0+ | `az version` |
| PowerShell 5.1+ | `$PSVersionTable.PSVersion` |
| Azure Contributor role | `az role assignment list --assignee <your-upn>` |
| Internet connectivity | Required for Azure API calls |

### Step 1: Clone

```powershell
git clone https://github.com/rfranca777/MDE-PolicyAutomation.git
cd MDE-PolicyAutomation
```

### Step 2: Authenticate

```powershell
az login
```

### Step 3: Run

```powershell
.\full-automation\Deploy-MDE-Automation.ps1
```

The script will interactively:
1. List your subscriptions — pick one
2. Ask for Azure region (default: `eastus`)
3. Ask if you want Azure Arc machines included
4. Deploy all 14 stages autonomously
5. Open HTML instructions for MDE Device Group creation
6. Optionally apply MDE tags immediately

### Step 4: Create MDE Device Group (Manual — one time)

After the script completes, it opens an HTML file with step-by-step instructions to create the MDE Device Group in the portal. This is the **only manual step** — MDE Device Groups don't have a public API for creation.

### Step 5: Relax

The Automation Account runbook will sync VMs to the Entra ID group every hour. Azure Policy will auto-tag new VMs. MDE will apply the correct policies. You're done. 🎉

---

## Option B: Azure Policy Only

If you only want the Azure Policy for device tagging (no Automation Account, no groups):

```powershell
# See the azure-policy/ folder
# Upload Set-MDEDeviceTag.ps1 to a Storage Account
# Deploy policy-definition.json
# Assign the policy with your desired tag value
```

See the main [README.md](../README.md) for detailed instructions.
