<#
.SYNOPSIS
    Restores missing encryption keys for Confidential VM (CVM + CMK) restore from Azure Backup.

.DESCRIPTION
    When a CVM restore operation fails, this script interactively collects inputs and then:
      1. Connects to the Recovery Services vault.
      2. Lists failed restore jobs and lets the user pick one.
      3. Extracts storage account, container, and blob details from the job.
      4. Downloads the encrypted key configuration blob.
      5. Writes the key blob file locally.
      6. Restores the key into the specified Key Vault or Managed HSM.

.NOTES
    Author:    Azure Backup Support
    Date:      March 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-automation
#>

#Requires -Modules @{ ModuleName = 'Az.Accounts'; ModuleVersion = '3.0.0' }

# ============================================================================
# RUNTIME GUARD
# ============================================================================
# Az module 5.x requires PowerShell 7+.  Windows PowerShell 5.1 loads a .NET
# Framework build of the SDK that is missing methods such as
# get_SerializationSettings, causing TypeLoadExceptions on every Az cmdlet.
#
# If this script was launched under PS 5.1, detect that and transparently
# re-launch under pwsh 7 (which we already confirmed works).  If pwsh is not
# installed, fail with a clear message.

if (-not $env:_CVM_CLEAN_SESSION) {

    $needRelaunch = $false
    $pwshPath     = $null

    # Locate pwsh.exe (PowerShell 7+).
    $pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Source -First 1

    # ------------------------------------------------------------------
    # Case 1: Running under Windows PowerShell 5.1 – must relaunch.
    # ------------------------------------------------------------------
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        if (-not $pwshPath) {
            Write-Host 'ERROR: This script requires PowerShell 7 (pwsh) but only Windows PowerShell 5.1 was found.' -ForegroundColor Red
            Write-Host '       Install PowerShell 7: https://aka.ms/install-powershell' -ForegroundColor Yellow
            exit 1
        }
        $needRelaunch = $true
    }

    # ------------------------------------------------------------------
    # Case 2: Running under pwsh 7+ but a stale assembly is already
    #         loaded in this session (e.g. prior manual Import-Module).
    # ------------------------------------------------------------------
    if (-not $needRelaunch) {
        try {
            Import-Module Az.Accounts -MinimumVersion 3.0.0 -Force -ErrorAction Stop
            # Actually exercise the cmdlet; Import-Module alone may succeed
            # even when the underlying assembly is stale.
            $null = Get-AzContext -ErrorAction Stop
        } catch [System.TypeLoadException] {
            if (-not $pwshPath) {
                Write-Host 'ERROR: Stale Azure assembly in this session and pwsh.exe not found.' -ForegroundColor Red
                Write-Host '       Close all terminals, open a new one, and retry.' -ForegroundColor Yellow
                exit 1
            }
            $needRelaunch = $true
        } catch {
            # Get-AzContext may throw "Run Connect-AzAccount" – that is fine.
            if ($_.Exception -is [System.TypeLoadException] -or
                $_.Exception.InnerException -is [System.TypeLoadException]) {
                $needRelaunch = $true
            }
            # Otherwise the error is benign (no context yet) – continue.
        }
    }

    if ($needRelaunch) {
        Write-Host 'Re-launching script under PowerShell 7...' -ForegroundColor Yellow
        $env:_CVM_CLEAN_SESSION = '1'
        try {
            & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
            exit $LASTEXITCODE
        } finally {
            Remove-Item Env:\_CVM_CLEAN_SESSION -ErrorAction SilentlyContinue
        }
    }
}

# Clean up the env marker if it was set.
Remove-Item Env:\_CVM_CLEAN_SESSION -ErrorAction SilentlyContinue

$ErrorActionPreference = 'Stop'
$downloadPath = $env:TEMP

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  CVM Encryption Key Restore Script" -ForegroundColor Cyan
Write-Host "  (Restore missing MHSM / Key Vault key for CVM + CMK)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host "Checking Azure authentication..." -ForegroundColor Cyan

$context = Get-AzContext -ErrorAction SilentlyContinue

if (-not $context -or -not $context.Account) {
    Write-Host "  No active session. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
    $context = Get-AzContext
}

Write-Host "  Authenticated as: $($context.Account.Id)" -ForegroundColor Green
Write-Host "  Subscription:     $($context.Subscription.Name) `($($context.Subscription.Id)`)" -ForegroundColor Gray
Write-Host ""

# ----------------------------------------------------------------------------
# Helper: prompt for a subscription and switch context if needed.
# ----------------------------------------------------------------------------
function Switch-SubscriptionIfNeeded {
    param([string]$ResourceLabel)
    $cur = (Get-AzContext).Subscription
    Write-Host "Current subscription: $($cur.Name) `($($cur.Id)`)" -ForegroundColor Gray
    Write-Host "Subscription ID for ${ResourceLabel} (press Enter to keep current):" -ForegroundColor Cyan
    $subInput = Read-Host "    Enter Subscription ID"
    if (-not [string]::IsNullOrWhiteSpace($subInput) -and $subInput -ne $cur.Id) {
        Write-Host "    Switching to subscription '$subInput'..." -ForegroundColor Yellow
        Set-AzContext -SubscriptionId $subInput -ErrorAction Stop | Out-Null
        $newCtx = Get-AzContext
        Write-Host "    Now using: $($newCtx.Subscription.Name) `($($newCtx.Subscription.Id)`)" -ForegroundColor Green
    }
    Write-Host ""
}

# ============================================================================
# SECTION 1: RECOVERY SERVICES VAULT
# ============================================================================

Write-Host "SECTION 1: Recovery Services Vault Information" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Switch-SubscriptionIfNeeded -ResourceLabel 'Recovery Services Vault'

Write-Host "Vault Resource Group Name:" -ForegroundColor Cyan
$vaultResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($vaultResourceGroup)) {
    Write-Host "ERROR: Vault Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Recovery Services Vault Name:" -ForegroundColor Cyan
$vaultName = Read-Host "  Enter Vault Name"
if ([string]::IsNullOrWhiteSpace($vaultName)) {
    Write-Host "ERROR: Vault Name cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Retrieving vault '$vaultName'..." -ForegroundColor Cyan

$vault = Get-AzRecoveryServicesVault -ResourceGroupName $vaultResourceGroup -Name $vaultName
if (-not $vault) {
    Write-Host "ERROR: Vault '$vaultName' not found in resource group '$vaultResourceGroup'." -ForegroundColor Red
    exit 1
}

Write-Host "  Vault found: $($vault.Name)" -ForegroundColor Green
Write-Host ""

# ============================================================================
# SECTION 2: FAILED RESTORE JOB SELECTION
# ============================================================================

Write-Host "SECTION 2: Failed Restore Job Selection" -ForegroundColor Yellow
Write-Host "-----------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Days to look back for failed restore jobs (default: 7):" -ForegroundColor Cyan
$lookbackInput = Read-Host "  Enter days (or press Enter for 7)"
$lookbackDays = if ([string]::IsNullOrWhiteSpace($lookbackInput)) { 7 } else { [int]$lookbackInput }

Write-Host ""
Write-Host "Searching for failed restore jobs from the last $lookbackDays day(s)..." -ForegroundColor Cyan

$fromDate = (Get-Date).AddDays(-$lookbackDays).ToUniversalTime()
$failedJobs = @(Get-AzRecoveryServicesBackupJob -From $fromDate -Status Failed -Operation Restore -VaultId $vault.ID)

if ($failedJobs.Count -eq 0) {
    Write-Host "  No failed restore jobs found. Try increasing the lookback window." -ForegroundColor Yellow
    exit 0
}

Write-Host "  Found $($failedJobs.Count) failed restore job(s)" -ForegroundColor Green
Write-Host ""

$index = 1
foreach ($job in $failedJobs) {
    Write-Host "  [$index] Activity ID:     $($job.ActivityId)" -ForegroundColor White
    Write-Host "       VM Name:    $($job.WorkloadName)" -ForegroundColor Gray
    Write-Host "       Start Time: $($job.StartTime)" -ForegroundColor Gray
    Write-Host "       End Time:   $($job.EndTime)" -ForegroundColor Gray
    Write-Host ""
    $index++
}

Write-Host "Select a failed job (1-$($failedJobs.Count)):" -ForegroundColor Cyan
$jobIndex = [int](Read-Host "  Enter choice") - 1
if ($jobIndex -lt 0 -or $jobIndex -ge $failedJobs.Count) {
    Write-Host "ERROR: Invalid selection." -ForegroundColor Red
    exit 1
}

$selectedJob = $failedJobs[$jobIndex]
Write-Host "  Selected Job: $($selectedJob.JobId)" -ForegroundColor Green
Write-Host ""

# ============================================================================
# SECTION 3: EXTRACT JOB DETAILS
# ============================================================================

Write-Host "SECTION 3: Extracting Job Details" -ForegroundColor Yellow
Write-Host "-----------------------------------" -ForegroundColor Yellow
Write-Host ""

$jobDetails = Get-AzRecoveryServicesBackupJobDetail -Job $selectedJob -VaultId $vault.ID
$properties = $jobDetails.Properties

$storageAccountName        = $properties["Target Storage Account Name"]
$containerName             = $properties["Config Blob Container Name"]
$securedEncryptionBlobName = $properties["Secured Encryption Info Blob Name"]

if ([string]::IsNullOrWhiteSpace($storageAccountName) -or
    [string]::IsNullOrWhiteSpace($containerName) -or
    [string]::IsNullOrWhiteSpace($securedEncryptionBlobName)) {
    Write-Host "ERROR: Required properties missing from job details." -ForegroundColor Red
    Write-Host "  Storage Account : '$storageAccountName'" -ForegroundColor Red
    Write-Host "  Container       : '$containerName'" -ForegroundColor Red
    Write-Host "  Blob            : '$securedEncryptionBlobName'" -ForegroundColor Red
    exit 1
}

Write-Host "  Storage Account : $storageAccountName" -ForegroundColor Gray
Write-Host "  Container       : $containerName" -ForegroundColor Gray
Write-Host "  Blob            : $securedEncryptionBlobName" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# SECTION 4: DOWNLOAD ENCRYPTION CONFIG BLOB
# ============================================================================

Write-Host "SECTION 4: Download Encryption Config Blob" -ForegroundColor Yellow
Write-Host "--------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Switch-SubscriptionIfNeeded -ResourceLabel 'Storage Account'

Write-Host "Storage Account Resource Group for '$storageAccountName':" -ForegroundColor Cyan
$storageResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($storageResourceGroup)) {
    Write-Host "ERROR: Storage Account Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

$configFilePath  = Join-Path $downloadPath "cvmcmkencryption_config_$(Get-Date -Format 'yyyyMMddHHmmss').json"
$keyBlobFilePath = Join-Path $downloadPath "keyDetails_$(Get-Date -Format 'yyyyMMddHHmmss').blob"

Write-Host ""
Write-Host "Downloading blob to '$configFilePath'..." -ForegroundColor Cyan

Set-AzCurrentStorageAccount -Name $storageAccountName -ResourceGroupName $storageResourceGroup
Get-AzStorageBlobContent -Blob $securedEncryptionBlobName -Container $containerName -Destination $configFilePath -Force | Out-Null

Write-Host "  Download complete." -ForegroundColor Green
Write-Host ""

# ============================================================================
# SECTION 5: EXTRACT KEY BACKUP DATA
# ============================================================================

Write-Host "SECTION 5: Extract Key Backup Data" -ForegroundColor Yellow
Write-Host "------------------------------------" -ForegroundColor Yellow
Write-Host ""

$encryptionObject = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
$keyBackupData = $encryptionObject.OsDiskEncryptionDetails.KeyBackupData

if ([string]::IsNullOrWhiteSpace($keyBackupData)) {
    Write-Host "ERROR: KeyBackupData is missing in the encryption config." -ForegroundColor Red
    exit 1
}

[io.file]::WriteAllBytes($keyBlobFilePath, [System.Convert]::FromBase64String($encryptionObject.OsDiskEncryptionDetails.KeyBackupData))
Write-Host "  Key blob file created: $keyBlobFilePath - $keyBlobSize KB" -ForegroundColor Green
Write-Host ""

# ============================================================================
# SECTION 6: RESTORE KEY TO KEY VAULT OR MANAGED HSM
# ============================================================================

Write-Host 'SECTION 6: Restore Key to Key Vault or Managed HSM' -ForegroundColor Yellow
Write-Host "----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Switch-SubscriptionIfNeeded -ResourceLabel 'Key Vault / Managed HSM'

# Auto-detect the target type from the encryption config blob.
$kvResourceType = $encryptionObject.OsDiskEncryptionDetails.KeyVaultResourceType
$isMhsm = $kvResourceType -eq 'Microsoft.KeyVault/managedHSMs'

if ($isMhsm) {
    Write-Host "  Detected target type: Managed HSM (KeyVaultResourceType = $kvResourceType)" -ForegroundColor Cyan
} else {
    Write-Host "  Detected target type: Key Vault (KeyVaultResourceType = $kvResourceType)" -ForegroundColor Cyan
}
Write-Host ""

$restoredKey = $null

if ($isMhsm) {
    Write-Host "  Target Managed HSM Name:" -ForegroundColor Cyan
    $targetMhsmName = Read-Host "    Enter Managed HSM Name"
    if ([string]::IsNullOrWhiteSpace($targetMhsmName)) {
        Write-Host "ERROR: Managed HSM Name cannot be empty." -ForegroundColor Red
        exit 1
    }

    Write-Host "  Restoring key into Managed HSM '$targetMhsmName'..." -ForegroundColor Cyan
    $restoredKey = Restore-AzKeyVaultKey -HsmName $targetMhsmName -InputFile $keyBlobFilePath

} else {
    Write-Host "  Target Key Vault Name:" -ForegroundColor Cyan
    $targetKeyVaultName = Read-Host "    Enter Key Vault Name"
    if ([string]::IsNullOrWhiteSpace($targetKeyVaultName)) {
        Write-Host "ERROR: Key Vault Name cannot be empty." -ForegroundColor Red
        exit 1
    }

    Write-Host "  Restoring key into Key Vault '$targetKeyVaultName'..." -ForegroundColor Cyan
    $restoredKey = Restore-AzKeyVaultKey -VaultName $targetKeyVaultName -InputFile $keyBlobFilePath
}

# ============================================================================
# SECTION 7: RESULTS & NEXT STEPS
# ============================================================================

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  KEY RESTORED SUCCESSFULLY" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Key Name    : $($restoredKey.Name)" -ForegroundColor White
Write-Host "  Key Id      : $($restoredKey.Id)" -ForegroundColor White
Write-Host "  Key Version : $($restoredKey.Version)" -ForegroundColor White
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Create a new DES with 'Confidential disk encryption with CMK'" -ForegroundColor White
Write-Host "     pointing to: $($restoredKey.Id)" -ForegroundColor Gray
Write-Host "  2. Ensure the DES and Backup Management Service have permissions" -ForegroundColor White
Write-Host "     on the Key Vault / Managed HSM." -ForegroundColor White
Write-Host "  3. Retry the VM restore operation using the new DES." -ForegroundColor White
Write-Host ""

# Cleanup
foreach ($f in @($configFilePath, $keyBlobFilePath)) {
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}
Write-Host "  Temporary files cleaned up." -ForegroundColor Gray
Write-Host ""