#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures Microsoft Defender for Endpoint device tag via Windows registry

.DESCRIPTION
    This script configures the required registry key to apply a device tag 
    in Microsoft Defender for Endpoint. The tag will be automatically synchronized 
    with MDE and can be used to apply specific policies through Device Groups 
    in the Defender portal.

.PARAMETER TagValue
    The tag value to apply (e.g., DEV, PROD, TEST, STAGING)

.EXAMPLE
    .\Set-MDEDeviceTag.ps1 -TagValue "PROD"

.NOTES
    - Requires Administrator privileges
    - The tag will sync with MDE on the next device check-in
    - Registry path: HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging
    - Registry value: Group (String)

.LINK
    https://learn.microsoft.com/microsoft-365/security/defender-endpoint/machine-tags
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$TagValue
)

# Registry configuration
$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging"
$registryName = "Group"

try {
    Write-Output "Starting MDE device tag configuration: $TagValue"
    Write-Output "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    
    # Check if registry path exists, create if not
    if (!(Test-Path $registryPath)) {
        Write-Output "Creating registry key: $registryPath"
        New-Item -Path $registryPath -Force | Out-Null
    }
    
    # Set the tag value
    Write-Output "Configuring tag: $TagValue"
    Set-ItemProperty -Path $registryPath -Name $registryName -Value $TagValue -Type String -Force
    
    # Verify configuration
    $currentValue = Get-ItemProperty -Path $registryPath -Name $registryName -ErrorAction SilentlyContinue
    
    if ($currentValue.$registryName -eq $TagValue) {
        Write-Output "✓ MDE device tag configured successfully: $TagValue"
        Write-Output "The tag will be synchronized with MDE on the next device check-in."
        Write-Output "You can view the tag in the Microsoft Defender portal under Device > Device tags"
        exit 0
    }
    else {
        Write-Error "Failed to verify tag configuration"
        exit 1
    }
}
catch {
    Write-Error "Error configuring MDE device tag: $_"
    Write-Error $_.Exception.Message
    Write-Error $_.ScriptStackTrace
    exit 1
}
