# =========================
# Stop Protection (Retain Data Forever) — using az dataprotection CLI
# =========================

$subscriptionId = "<your-subscription-id>"
$resourceGroupName = "<your-resource-group>"
$vaultName = "<your-vault-name>"
$backupInstanceName = "<your-backup-instance-name>"

az account set --subscription $subscriptionId

Write-Host "`nStopping protection (retain data forever)..." -ForegroundColor Cyan

try {
    az dataprotection backup-instance stop-protection `
        --name $backupInstanceName `
        --resource-group $resourceGroupName `
        --vault-name $vaultName

    if ($LASTEXITCODE -ne 0) { throw "az dataprotection backup-instance stop-protection failed with exit code $LASTEXITCODE" }

    Write-Host "stop-protection completed successfully." -ForegroundColor Green
}
catch {
    Write-Host "StopProtection failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

# Poll until the backup instance reaches a stopped state
$maxRetries = 30
$retryCount = 0
$pollIntervalSeconds = 20

Write-Host "`nPolling BackupInstance until protection is stopped..." -ForegroundColor Cyan

do {
    Start-Sleep -Seconds $pollIntervalSeconds
    $retryCount++

    $biJson = az dataprotection backup-instance show `
        --name $backupInstanceName `
        --resource-group $resourceGroupName `
        --vault-name $vaultName `
        -o json
    $bi = $biJson | ConvertFrom-Json

    $currentState = $bi.properties.currentProtectionState
    $protectionStatus = $bi.properties.protectionStatus.status

    Write-Host "[$retryCount] currentProtectionState: $currentState | protectionStatus: $protectionStatus" -ForegroundColor Yellow

    if ($currentState -match "Stopped|Error" -or $protectionStatus -match "Stopped|Error") {
        break
    }

} while ($retryCount -lt $maxRetries)

Write-Host "`nFinal state:" -ForegroundColor Cyan
Write-Host ($bi | ConvertTo-Json -Depth 10)
