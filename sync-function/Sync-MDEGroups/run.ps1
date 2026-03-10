<#
.SYNOPSIS
    MDE Group Sync - Azure Function Timer Trigger (12/12h)

.DESCRIPTION
    Lightweight sync that runs Stages 5+6+10 from Deploy-MDE-v2.ps1:
    - Stage 5: Checks for VMs without Entra ID device (logs only, no extension install)
    - Stage 6: Device Matching + Group Sync (local + global groups)
    - Stage 10: MDE Machine Tags via API

    Authentication:
    - Managed Identity for Graph API + ARM (zero credentials)
    - Client Credentials for MDE API (App Registration from Stage 9)

    Configuration via Function App Settings:
    - SUBSCRIPTION_IDS: comma-separated subscription IDs
    - MDE_APP_ID: App Registration client ID
    - MDE_APP_SECRET: Client secret (use Key Vault reference)
    - MDE_TENANT_ID: Entra ID tenant ID

.NOTES
    Version:  1.0.0
    Author:   Rafael Franca - github.com/rfranca777
    Runtime:  PowerShell 7.4 (Azure Functions v4)
    Schedule: Every 12 hours (0 0 */12 * * *)
#>

param($Timer)

$ErrorActionPreference = "Continue"

# ============================================================
# HELPER FUNCTIONS
# ============================================================
function Normalize-Name {
    param([string]$Name)
    if (-not $Name) { return "" }
    $n = $Name.ToLower().Trim()
    $n = $n -replace '\..*$', ''
    $n = $n -replace '^.*\\', ''
    return $n
}

function Get-GraphToken {
    # Get token for Microsoft Graph via Managed Identity
    $resource = "https://graph.microsoft.com"
    $tokenResult = Get-AzAccessToken -ResourceUrl $resource
    return $tokenResult.Token
}

function Get-ArmToken {
    # Get token for Azure Resource Manager via Managed Identity
    $resource = "https://management.azure.com"
    $tokenResult = Get-AzAccessToken -ResourceUrl $resource
    return $tokenResult.Token
}

function Get-MdeToken {
    # Get token for MDE API via Client Credentials
    param([string]$TenantId, [string]$AppId, [string]$AppSecret)
    $body = @{
        client_id     = $AppId
        client_secret = $AppSecret
        scope         = "https://api.security.microsoft.com/.default"
        grant_type    = "client_credentials"
    }
    try {
        $response = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ContentType "application/x-www-form-urlencoded" -Body $body -ErrorAction Stop
        return $response.access_token
    } catch {
        Write-Error "MDE token failed: $($_.Exception.Message)"
        return $null
    }
}

function Invoke-GraphApi {
    param([string]$Token, [string]$Method, [string]$Uri, [object]$Body)
    $headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = "Stop" }
    if ($Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 5) }
    try {
        return Invoke-RestMethod @params
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 400) { return $null }  # already member, etc
        Write-Warning "Graph $Method $Uri = $status"
        return $null
    }
}

function Get-AllEntraDevices {
    param([string]$Token)
    $all = @()
    $uri = "https://graph.microsoft.com/v1.0/devices?`$top=999&`$select=displayName,id,deviceId,physicalIds,operatingSystem,approximateLastSignInDateTime"
    do {
        $response = Invoke-GraphApi -Token $Token -Method GET -Uri $uri
        if ($response -and $response.value) { $all += $response.value }
        $uri = if ($response.'@odata.nextLink') { $response.'@odata.nextLink' } else { $null }
    } while ($uri)
    return $all
}

function Get-SubscriptionVMs {
    param([string]$Token, [string]$SubscriptionId)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01"
    $all = @()
    do {
        $headers = @{ Authorization = "Bearer $Token" }
        try {
            $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
            if ($response.value) { $all += $response.value }
            $uri = $response.nextLink
        } catch {
            Write-Warning "ARM list VMs failed: $($_.Exception.Message)"
            $uri = $null
        }
    } while ($uri)
    return $all
}

# ============================================================
# CONFIGURATION
# ============================================================
$subscriptionIds = @()
if ($env:SUBSCRIPTION_IDS) {
    $subscriptionIds = $env:SUBSCRIPTION_IDS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

$mdeAppId     = $env:MDE_APP_ID
$mdeAppSecret = $env:MDE_APP_SECRET
$mdeTenantId  = $env:MDE_TENANT_ID

if ($subscriptionIds.Count -eq 0) {
    Write-Error "SUBSCRIPTION_IDS not configured. Set in Function App Settings."
    return
}

Write-Host "=== MDE SYNC START === $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
Write-Host "Subscriptions: $($subscriptionIds.Count)"
Write-Host "MDE API: $(if($mdeAppId){'Configured'}else{'Not configured (tags will be skipped)'})"

# ============================================================
# GET TOKENS
# ============================================================
$graphToken = Get-GraphToken
$armToken   = Get-ArmToken
$mdeToken   = $null

if ($mdeAppId -and $mdeAppSecret -and $mdeTenantId) {
    $mdeToken = Get-MdeToken -TenantId $mdeTenantId -AppId $mdeAppId -AppSecret $mdeAppSecret
    if ($mdeToken) { Write-Host "[OK] MDE Token obtained" }
    else { Write-Host "[WARN] MDE Token failed - tags will be skipped" }
}

if (-not $graphToken -or -not $armToken) {
    Write-Error "Failed to obtain Graph or ARM token via Managed Identity"
    return
}
Write-Host "[OK] Graph + ARM tokens obtained via Managed Identity"

# ============================================================
# LOAD ENTRA ID DEVICES (once, shared across all subs)
# ============================================================
$deviceList = Get-AllEntraDevices -Token $graphToken
Write-Host "[OK] Entra ID devices: $($deviceList.Count)"

# ============================================================
# GLOBAL GROUPS (ensure they exist)
# ============================================================
$globalGroupIds = @{}
foreach ($gDef in @(
    @{ Name = "grp-mde-global-active";    Tag = "active" },
    @{ Name = "grp-mde-global-stale7";    Tag = "stale7" },
    @{ Name = "grp-mde-global-stale30";   Tag = "stale30" },
    @{ Name = "grp-mde-global-ephemeral"; Tag = "ephemeral" }
)) {
    $gn = $gDef.Name
    $check = Invoke-GraphApi -Token $graphToken -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$gn'&`$select=id"
    if ($check -and $check.value -and $check.value.Count -gt 0) {
        $globalGroupIds[$gDef.Tag] = $check.value[0].id
    } else {
        Write-Warning "Global group $gn not found. Run Deploy-MDE-v2.ps1 first."
    }
}
Write-Host "[OK] Global groups: $($globalGroupIds.Count)/4 found"

# ============================================================
# MDE MACHINES (load once if token available)
# ============================================================
$mdeMachines = @()
if ($mdeToken) {
    $mdeHeaders = @{ Authorization = "Bearer $mdeToken" }
    $mdeUri = "https://api.security.microsoft.com/api/machines"
    do {
        try {
            $mdeResp = Invoke-RestMethod -Method GET -Uri $mdeUri -Headers $mdeHeaders -ErrorAction Stop
            if ($mdeResp.value) { $mdeMachines += $mdeResp.value }
            $mdeUri = $mdeResp.'@odata.nextLink'
        } catch {
            Write-Warning "MDE machines list: $($_.Exception.Message)"
            $mdeUri = $null
        }
    } while ($mdeUri)
    Write-Host "[OK] MDE machines: $($mdeMachines.Count)"
}

# ============================================================
# SYNC PER SUBSCRIPTION
# ============================================================
$totalStats = @{ Matched = 0; Synced = 0; Pending = 0; TagsApplied = 0; TotalVMs = 0 }

foreach ($subId in $subscriptionIds) {
    Write-Host ""
    Write-Host "=== SUBSCRIPTION: $subId ==="

    # Get subscription name for group naming
    $subNameShort = $subId.Substring(0, 8)
    try {
        $subInfo = Invoke-RestMethod -Method GET -Uri "https://management.azure.com/subscriptions/${subId}?api-version=2022-12-01" -Headers @{ Authorization = "Bearer $armToken" } -ErrorAction Stop
        $subName = $subInfo.displayName
        $subNameClean = $subName -replace '[^a-zA-Z0-9-]', '-' -replace '--+', '-' -replace '^-|-$', ''
        if (-not [string]::IsNullOrWhiteSpace($subNameClean)) {
            $subNameShort = $subNameClean.Substring(0, [Math]::Min(40, $subNameClean.Length)).ToLower()
        }
        Write-Host "  Name: $subName"
    } catch {
        Write-Warning "  Could not get subscription name, using ID prefix"
    }

    # Resolve local group IDs
    $localGroupIds = @{}
    foreach ($grpDef in @(
        @{ Name = "grp-mde-$subNameShort";           Tag = "main" },
        @{ Name = "grp-mde-$subNameShort-stale7";    Tag = "stale7" },
        @{ Name = "grp-mde-$subNameShort-stale30";   Tag = "stale30" },
        @{ Name = "grp-mde-$subNameShort-ephemeral"; Tag = "eph" }
    )) {
        $gn = $grpDef.Name
        $check = Invoke-GraphApi -Token $graphToken -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$gn'&`$select=id"
        if ($check -and $check.value -and $check.value.Count -gt 0) {
            $localGroupIds[$grpDef.Tag] = $check.value[0].id
        }
    }

    if (-not $localGroupIds["main"]) {
        Write-Warning "  Local main group not found for $subNameShort. Run Deploy-MDE-v2.ps1 first. Skipping."
        continue
    }
    Write-Host "  Local groups: $($localGroupIds.Count)/4 found"

    # List VMs via ARM API
    $vms = Get-SubscriptionVMs -Token $armToken -SubscriptionId $subId
    Write-Host "  VMs: $($vms.Count)"
    $totalStats.TotalVMs += $vms.Count

    if ($vms.Count -eq 0) { continue }

    # ============================================================
    # DEVICE MATCHING + GROUP SYNC
    # ============================================================
    $matched = @()
    $unmatched = @()

    foreach ($vm in $vms) {
        $vmResourceId = $vm.id.ToLower()
        $vmName = $vm.name
        $vmNameNorm = Normalize-Name $vmName
        $dev = $null

        # LAYER 1: physicalIds contains Azure Resource ID
        $dev = $deviceList | Where-Object {
            $_.physicalIds -and ($_.physicalIds | Where-Object { $_.ToLower() -like "*$vmResourceId*" })
        } | Select-Object -First 1

        # LAYER 2: Normalized name match
        if (-not $dev) {
            $dev = $deviceList | Where-Object { (Normalize-Name $_.displayName) -eq $vmNameNorm } | Select-Object -First 1
        }

        if ($dev) {
            $matched += @{ vm = $vm; device = $dev; statusTag = "active" }
        } else {
            $unmatched += $vm
        }
    }

    Write-Host "  Matched: $($matched.Count) / $($vms.Count) | Pending: $($unmatched.Count)"
    $totalStats.Matched += $matched.Count
    $totalStats.Pending += $unmatched.Count

    # Assign to groups (local + global)
    $syncCount = 0
    foreach ($m in $matched) {
        $devId = $m.device.id
        $devName = $m.device.displayName
        $lastSign = $m.device.approximateLastSignInDateTime

        # Determine target group + status
        $targetLocalTag = "main"
        $statusTag = "active"
        $globalTag = "active"

        if ($lastSign) {
            try {
                $daysAgo = ((Get-Date) - [DateTime]::Parse($lastSign)).Days
                if ($daysAgo -gt 30) {
                    $targetLocalTag = "stale30"; $statusTag = "stale30"; $globalTag = "stale30"
                } elseif ($daysAgo -gt 7) {
                    $targetLocalTag = "stale7"; $statusTag = "stale7"; $globalTag = "stale7"
                }
            } catch { }
        } else {
            $targetLocalTag = "stale7"; $statusTag = "stale7"; $globalTag = "stale7"
        }

        $m["statusTag"] = $statusTag

        # Add to LOCAL group
        $localGrpId = $localGroupIds[$targetLocalTag]
        if ($localGrpId) {
            $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$devId" }
            $result = Invoke-GraphApi -Token $graphToken -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$localGrpId/members/`$ref" -Body $body
            if ($result -ne $null -or $LASTEXITCODE -eq 0) { $syncCount++ }
        }

        # Add to GLOBAL group
        $globalGrpId = $globalGroupIds[$globalTag]
        if ($globalGrpId) {
            $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$devId" }
            Invoke-GraphApi -Token $graphToken -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$globalGrpId/members/`$ref" -Body $body | Out-Null
        }
    }

    $totalStats.Synced += $syncCount
    Write-Host "  Synced to groups: $syncCount"

    # ============================================================
    # MDE TAGS (if token available)
    # ============================================================
    if ($mdeToken -and $mdeMachines.Count -gt 0 -and $matched.Count -gt 0) {
        $tagCount = 0

        foreach ($m in $matched) {
            $devDeviceId = $m.device.deviceId
            $devNameNorm = Normalize-Name $m.device.displayName
            $mStatus = $m["statusTag"]
            $mdeMachine = $null

            # L1: aadDeviceId match
            if ($devDeviceId) {
                $mdeMachine = $mdeMachines | Where-Object { $_.aadDeviceId -eq $devDeviceId } | Select-Object -First 1
            }

            # L2: Normalized name match
            if (-not $mdeMachine -and $devNameNorm) {
                $mdeMachine = $mdeMachines | Where-Object { (Normalize-Name $_.computerDnsName) -eq $devNameNorm } | Select-Object -First 1
            }

            # L3: Approximate match
            if (-not $mdeMachine -and $devNameNorm.Length -ge 3) {
                $mdeMachine = $mdeMachines | Where-Object {
                    $mdeNorm = Normalize-Name $_.computerDnsName
                    ($mdeNorm -like "$devNameNorm*") -or ($devNameNorm -like "$mdeNorm*") -or ($mdeNorm -like "*$devNameNorm*")
                } | Select-Object -First 1
            }

            if (-not $mdeMachine) { continue }

            $machineId = $mdeMachine.id
            $existingTags = @()
            if ($mdeMachine.machineTags) { $existingTags = @($mdeMachine.machineTags) }

            $desiredTags = @(
                "sub:$subNameShort",
                "status:$mStatus",
                "global:$mStatus",
                "managed:mde-automation"
            )

            # Remove old status/global tags
            foreach ($et in $existingTags) {
                if (($et -like "status:*" -and $et -ne "status:$mStatus") -or
                    ($et -like "global:*" -and $et -ne "global:$mStatus")) {
                    try {
                        Invoke-RestMethod -Method POST -Uri "https://api.security.microsoft.com/api/machines/$machineId/tags" -Headers $mdeHeaders -ContentType "application/json" -Body (@{ Value = $et; Action = "Remove" } | ConvertTo-Json) -ErrorAction Stop | Out-Null
                    } catch { }
                    Start-Sleep -Milliseconds 500
                }
            }

            # Add missing tags
            $addedAny = $false
            foreach ($dt in $desiredTags) {
                if ($dt -notin $existingTags) {
                    try {
                        Invoke-RestMethod -Method POST -Uri "https://api.security.microsoft.com/api/machines/$machineId/tags" -Headers $mdeHeaders -ContentType "application/json" -Body (@{ Value = $dt; Action = "Add" } | ConvertTo-Json) -ErrorAction Stop | Out-Null
                        $addedAny = $true
                    } catch { }
                    Start-Sleep -Milliseconds 500
                }
            }

            if ($addedAny) { $tagCount++ }
        }

        $totalStats.TagsApplied += $tagCount
        Write-Host "  MDE tags applied: $tagCount"
    }
}

# ============================================================
# SUMMARY
# ============================================================
Write-Host ""
Write-Host "=== MDE SYNC COMPLETE === $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
Write-Host "  Subscriptions: $($subscriptionIds.Count)"
Write-Host "  Total VMs: $($totalStats.TotalVMs)"
Write-Host "  Matched: $($totalStats.Matched)"
Write-Host "  Synced to groups: $($totalStats.Synced)"
Write-Host "  Pending (no device): $($totalStats.Pending)"
Write-Host "  MDE tags applied: $($totalStats.TagsApplied)"
Write-Host "==========================="
