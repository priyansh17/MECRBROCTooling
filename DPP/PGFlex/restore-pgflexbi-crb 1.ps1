# Restore from Backup 
# PREREQ: Grant the VaultMSI required permisison on the storage account before running the script

$vaultSubscriptionId = "subscriptionIdGuid"
$vaultResourceGroup = "testrg"
$vaultName = "testvault"
$vaultRegion = "westcentralus"
$backupInstanceName = "pgflexresource-pgflexresource-828e8752-f4b0-4c3e-a11d-bf34c050f032"

# Restore details
$recoveryPointId = "recoveryPointId"
$restoreTargetUrl = "https://teststorageaccount.blob.core.windows.net/testcontainer"
$restoreLocation = "eastasia"

# Populating paths based on the inputs
$filePrefix = "dummyprefix"
$apiVersion = "2025-08-15-preview"
$resourceId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.DataProtection/BackupVaults/$vaultName/backupInstances/$backupInstanceName"
$uri = "https://management.azure.com${resourceId}/restore?api-version=$apiVersion"

# Get current access token using az CLI login
Write-Host "Fetching access token from az CLI..." -ForegroundColor Cyan
$tokenResponse = az account get-access-token --resource "https://management.azure.com" --output json | ConvertFrom-Json
$token = $tokenResponse.accessToken
Write-Host "Token acquired. Expires on: $($tokenResponse.expiresOn)" -ForegroundColor Green

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# Build the POST body for Restore
$body = @{
    objectType          = "AzureBackupRecoveryPointBasedRestoreRequest"
    sourceDataStoreType = "VaultStore"
    restoreTargetInfo   = @{
        targetDetails = @{
            url                       = $restoreTargetUrl
            filePrefix                = $filePrefix
            restoreTargetLocationType = "AzureBlobs"
        }
        restoreLocation = $restoreLocation
        recoveryOption  = "FailIfExists"
        objectType      = "RestoreFilesTargetInfo"
    }
    recoveryPointId     = $recoveryPointId
} | ConvertTo-Json -Depth 10

Write-Host "`nPOST body:" -ForegroundColor Yellow
Write-Host $body

# Execute the POST request to trigger restore
Write-Host "`nTriggering restore (POST restore)..." -ForegroundColor Cyan
$postResponse = Invoke-WebRequest -Method POST -Uri $uri -Headers $headers -Body $body -UseBasicParsing
$statusCode = $postResponse.StatusCode

Write-Host "POST request returned status: $statusCode" -ForegroundColor Green

if ($statusCode -eq 202) {
    # Get the Azure-AsyncOperation or Location header for tracking
    # Headers return string arrays in PowerShell - always take [0]
    $asyncUrl = $postResponse.Headers["Azure-AsyncOperation"]
    if ($asyncUrl -is [array]) { $asyncUrl = $asyncUrl[0] }
    if (-not $asyncUrl) {
        $asyncUrl = $postResponse.Headers["Location"]
        if ($asyncUrl -is [array]) { $asyncUrl = $asyncUrl[0] }
    }

    if ($asyncUrl) {
        Write-Host "`nAsync operation detected. Polling for completion..." -ForegroundColor Cyan
        Write-Host "Tracking URL: $asyncUrl" -ForegroundColor DarkGray

        $pollHeaders = @{
            "Authorization" = "Bearer $token"
        }

        $maxRetries = 30
        $retryCount = 0
        $pollIntervalSeconds = 20

        do {
            Start-Sleep -Seconds $pollIntervalSeconds
            $retryCount++

            $pollResponse = Invoke-RestMethod -Method GET -Uri $asyncUrl -Headers $pollHeaders
            $opStatus = $pollResponse.status
            Write-Host "[$retryCount] Status: $opStatus" -ForegroundColor Yellow

            if ($opStatus -in @("Succeeded", "Failed", "Cancelled")) {
                break
            }
        } while ($retryCount -lt $maxRetries)

        Write-Host "`nFinal operation status: $opStatus" -ForegroundColor $(if ($opStatus -eq "Succeeded") { "Green" } else { "Red" })
        Write-Host ($pollResponse | ConvertTo-Json -Depth 10)

        if ($opStatus -eq "Succeeded") {
            # Extract jobId from the response and track the job to completion
            $jobId = $pollResponse.properties.jobId
            if (-not $jobId) {
                $jobId = $pollResponse.jobId
            }

            if ($jobId) {
                # jobId may be a full resource path - extract just the GUID if so
                if ($jobId -match "/backupJobs/(.+)$") {
                    $jobIdGuid = $Matches[1]
                } else {
                    $jobIdGuid = $jobId
                }
                Write-Host "`nTrigger Restore operation succeeded, tracking job now to completion. JobId: $jobIdGuid" -ForegroundColor Green
                Write-Host "Tracking job to completion..." -ForegroundColor Cyan

                $jobUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.DataProtection/BackupVaults/$vaultName/backupJobs/${jobIdGuid}?api-version=$apiVersion"

                $jobMaxRetries = 30
                $jobRetryCount = 0
                $jobPollIntervalSeconds = 30

                do {
                    Start-Sleep -Seconds $jobPollIntervalSeconds
                    $jobRetryCount++

                    $jobResponse = Invoke-RestMethod -Method GET -Uri $jobUri -Headers $pollHeaders
                    $jobStatus = $jobResponse.properties.status
                    $jobStartTime = $jobResponse.properties.startTime
                    $jobEndTime = $jobResponse.properties.endTime
                    Write-Host "[$jobRetryCount] Job Status: $jobStatus | StartTime: $jobStartTime | EndTime: $jobEndTime" -ForegroundColor Yellow

                    if ($jobStatus -in @("Completed", "Failed", "Cancelled", "CompletedWithWarnings")) {
                        break
                    }
                } while ($jobRetryCount -lt $jobMaxRetries)

                Write-Host "`nFinal job status: $jobStatus" -ForegroundColor $(if ($jobStatus -eq "Completed") { "Green" } else { "Red" })
                Write-Host ($jobResponse | ConvertTo-Json -Depth 10)
            } else {
                Write-Host "`nNo jobId found in the Succeeded response." -ForegroundColor Red
                Write-Host ($pollResponse | ConvertTo-Json -Depth 10)
            }
        } else {
            Write-Host "Restore operation did not succeed. Check the response above for error details." -ForegroundColor Red
        }
    } else {
        Write-Host "No Azure-AsyncOperation or Location header found in 202 response." -ForegroundColor Red
    }
} elseif ($statusCode -in @(200, 201)) {
    Write-Host "`nRestore completed synchronously." -ForegroundColor Green
    $responseBody = $postResponse.Content | ConvertFrom-Json
    Write-Host ($responseBody | ConvertTo-Json -Depth 10)
} else {
    Write-Host "`nUnexpected status code: $statusCode" -ForegroundColor Red
}

