# Manual Deployment Guide

If you prefer to deploy each component separately (instead of using the full automation script), follow these steps.

## Step 1: Create Resource Group

```powershell
az group create --name "rg-mde-production" --location "eastus" `
    --tags "Project=MDE-Device-Management" "Environment=Production" "Owner=Security-Team"
```

## Step 2: Create Entra ID Security Group

```powershell
az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups" `
    --headers "Content-Type=application/json" `
    --body '{"displayName":"grp-mde-production","mailNickname":"grpmdeproduction","mailEnabled":false,"securityEnabled":true}'
```

## Step 3: Create Automation Account

```powershell
az automation account create --name "aa-mde-production" `
    --resource-group "rg-mde-production" --location "eastus" --sku Basic
```

## Step 4: Enable Managed Identity

```powershell
az automation account update --name "aa-mde-production" `
    --resource-group "rg-mde-production" --set identity.type=SystemAssigned
```

## Step 5: Assign RBAC + Graph Permissions

See the full automation script (Stages 7-8) for the exact REST API calls.

## Step 6: Deploy Azure Policy

```powershell
# Upload Set-MDEDeviceTag.ps1 to a Storage Account first
New-AzPolicyDefinition -Name "mde-device-tag" -Policy ".\azure-policy\policy-definition.json"
```

## Step 7: Create MDE Device Group

Follow the auto-generated HTML instructions from the full automation script, or manually create in the MDE portal:
`https://security.microsoft.com/securitysettings/endpoints/device_groups`
