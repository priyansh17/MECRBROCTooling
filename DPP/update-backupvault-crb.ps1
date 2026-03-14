# Update Backup Vault to enable Cross Region Backup Settings
# Target: /subscriptions/<subid>/resourcegroups/<rg>/providers/Microsoft.DataProtection/BackupVaults/<vaultname>

$subscriptionId = "<subid>"
$resourceGroup = "<rg>"
$vaultName = "<vaultname>"
$apiVersion = "2025-08-15-preview"

$resourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.DataProtection/BackupVaults/$vaultName"
$uri = "https://management.azure.com${resourceId}?api-version=$apiVersion"

# Get current access token using az CLI login
Write-Host "Fetching access token from az CLI..." -ForegroundColor Cyan
$tokenResponse = az account get-access-token --resource "https://management.azure.com" --output json | ConvertFrom-Json
$token = $tokenResponse.accessToken
Write-Host "Token acquired. Expires on: $($tokenResponse.expiresOn)" -ForegroundColor Green

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# First, GET the existing vault to preserve current properties
Write-Host "Getting existing vault configuration..." -ForegroundColor Cyan
$existingVault = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
Write-Host "Current vault configuration retrieved." -ForegroundColor Green

# Build the PUT body with required fields
$body = @{
    location   = $existingVault.location
    identity   = $existingVault.identity
    properties = @{
        storageSettings            = $existingVault.properties.storageSettings
        isVaultProtectedByResourceGuard = $existingVault.properties.isVaultProtectedByResourceGuard
        securitySettings           = @{
            softDeleteSettings = @{
                state                    = $existingVault.properties.securitySettings.softDeleteSettings.state
                retentionDurationInDays  = $existingVault.properties.securitySettings.softDeleteSettings.retentionDurationInDays
            }
        }
        crossRegionBackupSettings  = "Enabled"
    }
} | ConvertTo-Json -Depth 10

Write-Host "`nPUT body:" -ForegroundColor Yellow
Write-Host $body

# Execute the PUT request
Write-Host "`nUpdating vault with crossRegionBackupSettings = Enabled..." -ForegroundColor Cyan
$response = Invoke-RestMethod -Method PUT -Uri $uri -Headers $headers -Body $body
Write-Host "Vault updated successfully." -ForegroundColor Green
Write-Host ($response | ConvertTo-Json -Depth 10)
