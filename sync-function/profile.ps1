# Azure Functions profile - runs on every cold start
# Authenticate with Managed Identity
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Write-Host "Authenticated via Managed Identity"
}
