# Configure Protection (PUT Backup Instance) with Cross Region Backup
# Target: /subscriptions/<subid>/resourceGroups/<rg>/providers/Microsoft.DataProtection/BackupVaults/<vaultname>/backupInstances/pgflexrestore

$vaultSubscriptionId = "<subid>"
$vaultResourceGroup = "demo"
$vaultName = "<vaultname>"
$vaultRegion = "westcentralus"
$backupInstanceName = "pgflexrestore" #provide name for the BI

# Datasource details
$datasourceSubscriptionId = "<subid>"
$datasourceResourceGroup = "pgflexrestorefix"
$datasourceServerName = "pgflexrestore"

# Policy details
$policyName = "<policyname>"

# Populating paths based on the inputs
$apiVersion = "2025-08-15-preview"
$resourceId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.DataProtection/BackupVaults/$vaultName/backupInstances/$backupInstanceName"
$datasourceResourceId = "/subscriptions/$datasourceSubscriptionId/resourceGroups/$datasourceResourceGroup/providers/Microsoft.DBforPostgreSQL/flexibleServers/$datasourceServerName"
$policyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.DataProtection/backupVaults/$vaultName/backupPolicies/$policyName"
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

# Build the PUT body for ConfigureProtection
$body = @{
    properties = @{
        friendlyName    = "pgflexrestore"
        dataSourceInfo  = @{
            resourceID       = $datasourceResourceId
            resourceUri      = $datasourceResourceId
            datasourceType   = "Microsoft.DBforPostgreSQL/flexibleServers"
            resourceName     = $datasourceServerName
            resourceType     = "Microsoft.DBforPostgreSQL/flexibleServers"
            resourceLocation = $vaultRegion
            objectType       = "Datasource"
        }
        dataSourceSetInfo = @{
            resourceID       = $datasourceResourceId
            resourceUri      = $datasourceResourceId
            datasourceType   = "Microsoft.DBforPostgreSQL/flexibleServers"
            resourceName     = $datasourceServerName
            resourceType     = "Microsoft.DBforPostgreSQL/flexibleServers"
            resourceLocation = $vaultRegion
            objectType       = "DatasourceSet"
        }
        policyInfo      = @{
            policyId      = $policyId
            policyVersion = ""
        }
        objectType      = "BackupInstance"
    }
} | ConvertTo-Json -Depth 10

Write-Host "`nPUT body:" -ForegroundColor Yellow
Write-Host $body

# Execute the PUT request to configure protection
Write-Host "`nConfiguring protection (PUT BackupInstance)..." -ForegroundColor Cyan
$putResponse = Invoke-WebRequest -Method PUT -Uri $uri -Headers $headers -Body $body
$statusCode = $putResponse.StatusCode
$responseBody = $putResponse.Content | ConvertFrom-Json

Write-Host "PUT request returned status: $statusCode" -ForegroundColor Green
Write-Host ($responseBody | ConvertTo-Json -Depth 10)

if ($statusCode -in @(200, 201)) {
    Write-Host "`nPUT returned $statusCode. Checking protectionStatus..." -ForegroundColor Green
} else {
    Write-Host "`nUnexpected status code: $statusCode" -ForegroundColor Red
}

# Poll the backup instance until protectionStatus reaches ProtectionConfigured
$getUri = "https://management.azure.com${resourceId}?api-version=$apiVersion"
$getHeaders = @{
    "Authorization" = "Bearer $token"
}

$maxRetries = 30
$retryCount = 0
$pollIntervalSeconds = 20

$currentState = $responseBody.properties.currentProtectionState
if ($currentState -ne "ProtectionConfigured") {
    Write-Host "`nProtection state is '$currentState'. Polling until ProtectionConfigured..." -ForegroundColor Cyan

    do {
        Start-Sleep -Seconds $pollIntervalSeconds
        $retryCount++

        $biResponse = Invoke-RestMethod -Method GET -Uri $getUri -Headers $getHeaders
        $currentState = $biResponse.properties.currentProtectionState
        $protectionStatus = $biResponse.properties.protectionStatus.status
        Write-Host "[$retryCount] currentProtectionState: $currentState | protectionStatus: $protectionStatus" -ForegroundColor Yellow

        if ($currentState -in @("ProtectionConfigured", "ProtectionError")) {
            break
        }
    } while ($retryCount -lt $maxRetries)

    Write-Host "`nFinal protectionState: $currentState" -ForegroundColor $(if ($currentState -eq "ProtectionConfigured") { "Green" } else { "Red" })
    Write-Host ($biResponse | ConvertTo-Json -Depth 10)
} else {
    Write-Host "`nProtection already in ProtectionConfigured state." -ForegroundColor Green
}
