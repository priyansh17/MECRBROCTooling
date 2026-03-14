<#
.SYNOPSIS
    Stops protection (with retain data) for SQL databases on an Azure IaaS VM
    and optionally unregisters the VM from a Recovery Services Vault using REST API.

.DESCRIPTION
    This script manages backup protection for SQL Server databases on Azure IaaS VMs
    and supports full container unregistration while PRESERVING recovery points.

    Two operational modes:

    MODE 1: Stop Protection with Retain Data (default, no -Unregister)
    - Lists all protected SQL databases on a VM
    - Stops protection while retaining existing recovery points
    - Optionally prompts to unregister after all DBs are stopped

    MODE 2: Full Unregistration (-Unregister)
    - Stops protection with retain data for ALL active databases
    - Waits for operations to propagate
    - Unregisters the VM container from the vault
    - Recovery points are preserved (stop-with-retain keeps them)
    - All databases on the VM are processed (cannot target individual DBs)
    - The -StopAll behavior is implied; -DatabaseName is ignored

    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on the Recovery Services Vault
    - SQL databases must be in Protected/IRPending/ProtectionStopped state

.PARAMETER VaultSubscriptionId
    The Subscription ID where the Recovery Services Vault is located.

.PARAMETER VaultResourceGroup
    The Resource Group name of the Recovery Services Vault.

.PARAMETER VaultName
    The name of the Recovery Services Vault.

.PARAMETER VMResourceGroup
    The Resource Group name of the SQL Server VM.

.PARAMETER VMName
    The name of the Azure VM hosting SQL Server.

.PARAMETER DatabaseName
    The name of a specific SQL database to stop protection for.
    Only used when -Unregister is NOT specified.
    If omitted, ALL protected databases on the VM will be listed and
    you can choose to stop protection for all or select one.
    Ignored when -Unregister is specified (all DBs must be processed).

.PARAMETER Unregister
    When specified, stops protection for ALL databases with retain data,
    then unregisters the VM container from the vault.
    Recovery points are preserved through the stop-with-retain mechanism.

.PARAMETER StopAll
    When specified without -Unregister, stops protection for ALL protected SQL databases
    on the VM without prompting for individual selection.
    When -Unregister is specified, -StopAll is implied and this switch is ignored.

.EXAMPLE
    # Stop protection for a specific database (retain data, no unregister)
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" -DatabaseName "SalesDB"

.EXAMPLE
    # Unregister the VM (stop protection + unregister, preserves recovery points)
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" -Unregister

.EXAMPLE
    # Stop protection for ALL databases without unregistering
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" -StopAll

.EXAMPLE
    # Interactive mode - lists DBs, prompts for selection, then optionally unregisters
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01"

.NOTES
    Author: Azure Backup Script Generator
    Date: March 12, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/manage-azure-sql-vm-rest-api
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/unregister
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Subscription ID where the Recovery Services Vault is located.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultSubscriptionId,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the Recovery Services Vault.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Recovery Services Vault.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the SQL Server VM.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Azure VM hosting SQL Server.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of a specific SQL database to stop protection for. Ignored when -Unregister is specified.")]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false, HelpMessage = "Unregister the VM container after stopping protection. Processes ALL databases. Recovery points are preserved.")]
    [switch]$Unregister,

    [Parameter(Mandatory = $false, HelpMessage = "Stop protection for ALL protected SQL databases on the VM without prompting. Implied when -Unregister is used.")]
    [switch]$StopAll,

    [Parameter(Mandatory = $false, HelpMessage = "Skip confirmation prompts. Use this for automation/scripting.")]
    [switch]$SkipConfirmation
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2025-08-01"

# ============================================================================
# HELPER FUNCTION: Poll async operation
# ============================================================================

function Wait-ForAsyncOperation {
    param(
        [string]$LocationUrl,
        [hashtable]$Headers,
        [int]$MaxRetries = 20,
        [int]$DelaySeconds = 6,
        [string]$OperationName = "Operation"
    )

    if ([string]::IsNullOrWhiteSpace($LocationUrl)) {
        Write-Host "  No tracking URL available. Waiting ${DelaySeconds}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds ($DelaySeconds * 3)
        return $true
    }

    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySeconds

        try {
            $statusResponse = Invoke-WebRequest -Uri $LocationUrl -Method GET -Headers $Headers -UseBasicParsing
            if ($statusResponse.StatusCode -eq 200 -or $statusResponse.StatusCode -eq 204) {
                Write-Host "  $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        } catch {
            $innerCode = $_.Exception.Response.StatusCode.value__
            if ($innerCode -eq 200 -or $innerCode -eq 204) {
                Write-Host "  $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        }

        $retryCount++
        Write-Host "  Waiting for $OperationName... ($retryCount/$MaxRetries)" -ForegroundColor Yellow
    }

    Write-Host "  WARNING: $OperationName timed out." -ForegroundColor Yellow
    return $false
}

# ============================================================================
# HELPER FUNCTION: Parse error response
# ============================================================================

function Write-ApiError {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = "API call"
    )

    $statusCode = $ErrorRecord.Exception.Response.StatusCode.value__
    Write-Host "  Status Code: $statusCode" -ForegroundColor Red
    Write-Host "  Error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    try {
        $errorStream = $ErrorRecord.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorStream)
        $errorBody = $reader.ReadToEnd()
        $errorJson = $errorBody | ConvertFrom-Json

        if ($errorJson.error) {
            Write-Host "  Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "  Message: $($errorJson.error.message)" -ForegroundColor Red
        }
    } catch { }
}

# ============================================================================
# HELPER FUNCTION: Stop protection with retain data for a single DB
# ============================================================================

function Stop-SQLDatabaseProtection {
    param(
        [object]$ProtectedItem,
        [hashtable]$Headers,
        [string]$ApiVersion
    )

    $dbFriendlyName = $ProtectedItem.properties.friendlyName
    $currentState = $ProtectedItem.properties.protectionState

    # Skip if already stopped
    if ($currentState -eq "ProtectionStopped") {
        Write-Host "    SKIPPED: '$dbFriendlyName' - protection already stopped" -ForegroundColor Yellow
        return $true
    }

    Write-Host "    Stopping protection for '$dbFriendlyName'..." -ForegroundColor Cyan

    # Construct the PUT URI from the protected item ID
    $itemUri = "https://management.azure.com$($ProtectedItem.id)?api-version=$ApiVersion"

    # Request body: set protectionState to ProtectionStopped with empty policyId
    $stopBody = @{
        properties = @{
            protectedItemType = "AzureVmWorkloadSQLDatabase"
            protectionState   = "ProtectionStopped"
            sourceResourceId  = $ProtectedItem.properties.sourceResourceId
            policyId          = ""
        }
    } | ConvertTo-Json -Depth 10

    try {
        $stopResponse = Invoke-WebRequest -Uri $itemUri -Method PUT -Headers $Headers -Body $stopBody -UseBasicParsing
        $statusCode = $stopResponse.StatusCode

        if ($statusCode -eq 200) {
            Write-Host "    SUCCESS: Protection stopped for '$dbFriendlyName' (200 OK)" -ForegroundColor Green
            return $true
        } elseif ($statusCode -eq 202) {
            Write-Host "    Accepted (202). Tracking operation..." -ForegroundColor Green
            $asyncUrl = $stopResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $stopResponse.Headers["Location"]
            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

            if ($trackingUrl) {
                $maxRetries = 20
                $retryCount = 0
                $completed = $false

                while (-not $completed -and $retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 8
                    try {
                        $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $Headers
                        $opStatus = $null
                        if ($opResponse.status) { $opStatus = $opResponse.status }

                        if ($opStatus -eq "Succeeded") {
                            $completed = $true
                            Write-Host "    SUCCESS: Protection stopped for '$dbFriendlyName'" -ForegroundColor Green
                        } else {
                            $retryCount++
                            Write-Host "    Waiting... ($retryCount/$maxRetries) [Status: $opStatus]" -ForegroundColor Yellow
                        }
                    } catch {
                        $retryCount++
                        Write-Host "    Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    }
                }

                if (-not $completed) {
                    Write-Host "    WARNING: Operation timed out for '$dbFriendlyName'. Check Azure Portal." -ForegroundColor Yellow
                }
                return $completed
            }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ($statusCode -eq 202) {
            Write-Host "    Accepted (202). Waiting for completion..." -ForegroundColor Green
            Start-Sleep -Seconds 15
            Write-Host "    Check Azure Portal to confirm." -ForegroundColor Yellow
            return $true
        } else {
            Write-Host "    ERROR: Failed to stop protection for '$dbFriendlyName'" -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Stop Protection"
            return $false
        }
    }

    return $true
}

# ============================================================================
# MAP PARAMETERS
# ============================================================================

$vaultSubscriptionId = $VaultSubscriptionId
$vaultResourceGroup  = $VaultResourceGroup
$vaultName           = $VaultName
$vmResourceGroup     = $VMResourceGroup
$vmName              = $VMName

# ============================================================================
# DISPLAY CONFIGURATION SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SQL Server on Azure IaaS VM - Stop Protection & Unregister" -ForegroundColor Cyan
Write-Host "  (Using Azure Backup REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration Summary:" -ForegroundColor Yellow
Write-Host "  Subscription:        $vaultSubscriptionId" -ForegroundColor Gray
Write-Host "  Vault Resource Group:$vaultResourceGroup" -ForegroundColor Gray
Write-Host "  Vault Name:          $vaultName" -ForegroundColor Gray
Write-Host "  VM Resource Group:   $vmResourceGroup" -ForegroundColor Gray
Write-Host "  VM Name:             $vmName" -ForegroundColor Gray

if ($Unregister) {
    Write-Host "  Mode:                UNREGISTER (stop protection + unregister)" -ForegroundColor Magenta
    Write-Host "  Target Database:     ALL (required for unregistration)" -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        Write-Host "  NOTE: -DatabaseName '$DatabaseName' is ignored when -Unregister is specified" -ForegroundColor Yellow
    }
} else {
    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        Write-Host "  Target Database:     $DatabaseName" -ForegroundColor Gray
    } elseif ($StopAll) {
        Write-Host "  Target Database:     ALL (stop all protected DBs)" -ForegroundColor Yellow
    } else {
        Write-Host "  Target Database:     (will be selected interactively)" -ForegroundColor Gray
    }
}
Write-Host "  Unregister VM:       $(if ($Unregister) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null

try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token)
        )
    } else {
        $token = $tokenResponse.Token
    }

    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    Write-Host "  Azure PowerShell not available, trying Azure CLI..." -ForegroundColor Yellow

    try {
        $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1

        if ($LASTEXITCODE -eq 0) {
            $tokenObject = $azTokenOutput | ConvertFrom-Json
            $token = $tokenObject.accessToken
            Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
        } else {
            throw "Azure CLI authentication failed"
        }
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to authenticate to Azure." -ForegroundColor Red
        Write-Host "  Run 'Connect-AzAccount' or 'az login' first." -ForegroundColor Yellow
        exit 1
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ============================================================================
# STEP 1: LIST ALL PROTECTED SQL DATABASES ON THE VM
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Listing Protected SQL Databases on VM" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$protectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SQLDataBase'"

$allProtectedItems = @()
$vmProtectedDBs = @()
$containerName = $null

try {
    Write-Host "Querying for protected SQL databases..." -ForegroundColor Cyan

    $currentUri = $protectedItemsUri
    while ($currentUri) {
        $itemsResponse = Invoke-RestMethod -Uri $currentUri -Method GET -Headers $headers

        if ($itemsResponse.value) {
            $allProtectedItems += $itemsResponse.value
        }

        $currentUri = $itemsResponse.nextLink
        if ($currentUri) {
            Write-Host "  Fetching next page..." -ForegroundColor Gray
        }
    }

    # Filter to items belonging to our VM (exact match on container name pattern)
    # Container name format: VMAppContainer;Compute;{resourceGroup};{vmName}
    # We match on the exact ";{vmName}" suffix or the full container pattern to avoid
    # matching VMs with similar names (e.g., sql-vm matching sql-vm-01)
    $expectedContainerSuffix = ";$vmName".ToLower()
    $expectedContainerFull = "VMAppContainer;Compute;$vmResourceGroup;$vmName".ToLower()
    $vmProtectedDBs = $allProtectedItems | Where-Object {
        $cn = if ($_.properties.containerName) { $_.properties.containerName.ToLower() } else { "" }
        $itemId = if ($_.id) { $_.id.ToLower() } else { "" }
        # Match: container name ends with ;vmName (exact VM) OR full container pattern in ID
        $cn.EndsWith($expectedContainerSuffix) -or
        $cn -ieq $expectedContainerFull -or
        $itemId.Contains($expectedContainerFull)
    }

    if ($vmProtectedDBs.Count -gt 0) {
        # Extract container name from the first item
        if ($vmProtectedDBs[0].properties.containerName) {
            $containerName = $vmProtectedDBs[0].properties.containerName
        } else {
            # Parse from ID
            $idMatch = $vmProtectedDBs[0].id -match "/protectionContainers/([^/]+)/"
            if ($idMatch) { $containerName = $Matches[1] }
        }

        Write-Host "  Found $($vmProtectedDBs.Count) protected SQL database(s) on VM '$vmName'" -ForegroundColor Green
        Write-Host "  Container: $containerName" -ForegroundColor Gray
        Write-Host ""

        $dbIdx = 1
        foreach ($db in $vmProtectedDBs) {
            $state = $db.properties.protectionState
            $policy = $db.properties.policyName
            $lastBackup = $db.properties.lastBackupTime
            $stateColor = if ($state -eq "ProtectionStopped") { "Yellow" } else { "White" }

            Write-Host "  [$dbIdx] $($db.properties.friendlyName)" -ForegroundColor $stateColor
            Write-Host "       Instance:       $($db.properties.parentName)" -ForegroundColor Gray
            Write-Host "       State:          $state" -ForegroundColor Gray
            Write-Host "       Policy:         $policy" -ForegroundColor Gray
            Write-Host "       Last Backup:    $lastBackup" -ForegroundColor Gray
            Write-Host ""
            $dbIdx++
        }
    } else {
        Write-Host "  No protected SQL databases found on VM '$vmName'." -ForegroundColor Yellow

        if ($Unregister) {
            Write-Host "  Proceeding to unregister..." -ForegroundColor Cyan
        } else {
            Write-Host "  Nothing to do." -ForegroundColor Yellow
            Write-Host ""
        }
    }
} catch {
    Write-Host "ERROR: Failed to list protected items: $($_.Exception.Message)" -ForegroundColor Red
    Write-ApiError -ErrorRecord $_ -Context "List protected items"
    exit 1
}

# ============================================================================
# BRANCH: When -Unregister is specified
#   Step 2: Stop protection with retain data for ALL active DBs
#   Step 3: Wait 30s, then unregister the container
# ============================================================================

if ($Unregister) {
    # ------------------------------------------------------------------
    # Resolve container name if not found from protected items
    # ------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        Write-Host "  Looking up container name for VM '$vmName'..." -ForegroundColor Cyan

        $possibleNames = @(
            "VMAppContainer;Compute;$vmResourceGroup;$vmName"
        )

        foreach ($name in $possibleNames) {
            $checkUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$name`?api-version=$apiVersion"

            try {
                $checkResponse = Invoke-RestMethod -Uri $checkUri -Method GET -Headers $headers
                if ($checkResponse) {
                    $containerName = $checkResponse.name
                    Write-Host "  Found container: $containerName" -ForegroundColor Green
                    break
                }
            } catch { }
        }

        if ([string]::IsNullOrWhiteSpace($containerName)) {
            Write-Host "  ERROR: Could not find registered container for VM '$vmName'." -ForegroundColor Red
            Write-Host "  The VM may not be registered with the vault." -ForegroundColor Yellow
            exit 1
        }
    }

    # ------------------------------------------------------------------
    # Re-query protected items using the discovered container name
    # (initial query may have missed items due to VM name case mismatch)
    # ------------------------------------------------------------------
    if ($vmProtectedDBs.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($containerName)) {
        Write-Host "  Re-querying protected items using container name..." -ForegroundColor Cyan
        try {
            $reQueryUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SQLDataBase'"
            $allItems2 = @()
            $curUri = $reQueryUri
            while ($curUri) {
                $resp2 = Invoke-RestMethod -Uri $curUri -Method GET -Headers $headers
                if ($resp2.value) { $allItems2 += $resp2.value }
                $curUri = $resp2.nextLink
            }
            $containerNameLower = $containerName.ToLower()
            $vmProtectedDBs = $allItems2 | Where-Object {
                ($_.properties.containerName -and $_.properties.containerName.ToLower().Contains($containerNameLower)) -or
                ($_.id -and $_.id.ToLower().Contains($containerNameLower))
            }
            if ($vmProtectedDBs.Count -gt 0) {
                Write-Host "  Found $($vmProtectedDBs.Count) protected database(s) via container name match." -ForegroundColor Green
                Write-Host ""
                foreach ($db in $vmProtectedDBs) {
                    Write-Host "    - $($db.properties.friendlyName) (State: $($db.properties.protectionState))" -ForegroundColor White
                }
                Write-Host ""
            }
        } catch {
            Write-Host "  WARNING: Re-query failed. Proceeding with empty item list." -ForegroundColor Yellow
        }
    }

    # ==================================================================
    # STEP 2: Stop Protection with Retain Data for ALL Active DBs
    # ==================================================================
    Write-Host ""
    Write-Host "STEP 2: Stopping Protection (Retain Data) for All Databases" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    # Count active DBs that need stopping
    $activeDBsForStop = $vmProtectedDBs | Where-Object { $_.properties.protectionState -ne "ProtectionStopped" }
    $alreadyStoppedCount = $vmProtectedDBs.Count - $activeDBsForStop.Count

    if ($activeDBsForStop.Count -gt 0 -and -not $SkipConfirmation) {
        Write-Host "  The following $($activeDBsForStop.Count) database(s) will have protection STOPPED (data retained):" -ForegroundColor Magenta
        foreach ($adb in $activeDBsForStop) {
            Write-Host "    - $($adb.properties.friendlyName) (State: $($adb.properties.protectionState))" -ForegroundColor White
        }
        if ($alreadyStoppedCount -gt 0) {
            Write-Host "  ($alreadyStoppedCount database(s) already stopped - will be skipped)" -ForegroundColor Gray
        }
        Write-Host ""
        $confirmStop = Read-Host '  Proceed with stop protection? [Y/N, default: Y]'
        if ($confirmStop -ieq 'N') {
            Write-Host "  Aborted by user." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    $stopSuccessCount = 0
    $stopFailCount = 0
    $stopSkipCount = 0

    if ($vmProtectedDBs.Count -eq 0) {
        Write-Host "  No protected items to stop. Proceeding to container unregistration." -ForegroundColor Yellow
    } else {
        Write-Host "  Stopping protection for $($vmProtectedDBs.Count) database(s) with retain data..." -ForegroundColor Cyan
        Write-Host ""

        foreach ($db in $vmProtectedDBs) {
            $currentState = $db.properties.protectionState
            if ($currentState -eq "ProtectionStopped") {
                Write-Host "    SKIPPED: '$($db.properties.friendlyName)' - protection already stopped" -ForegroundColor Yellow
                $stopSkipCount++
                continue
            }

            $result = Stop-SQLDatabaseProtection -ProtectedItem $db -Headers $headers -ApiVersion $apiVersion
            if ($result) { $stopSuccessCount++ } else { $stopFailCount++ }
        }

        Write-Host ""
        Write-Host "  Stop Protection Summary: $stopSuccessCount stopped, $stopSkipCount already stopped, $stopFailCount failed" -ForegroundColor Cyan

        if ($stopFailCount -gt 0 -and $stopSuccessCount -eq 0 -and $stopSkipCount -eq 0) {
            Write-Host ""
            Write-Host "  ERROR: All stop operations failed. Cannot proceed with unregistration." -ForegroundColor Red
            exit 1
        }
    }

    # ==================================================================
    # STEP 3: Wait 30s, then Unregister Container
    # ==================================================================
    Write-Host ""
    Write-Host "STEP 3: Unregistering VM Container from Vault" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    if (-not $SkipConfirmation) {
        Write-Host "  Container '$containerName' will be UNREGISTERED from vault '$vaultName'." -ForegroundColor Magenta
        Write-Host "  Recovery points will be retained in the vault." -ForegroundColor Gray
        Write-Host ""
        $confirmUnreg = Read-Host '  Proceed with unregistration? [Y/N, default: Y]'
        if ($confirmUnreg -ieq 'N') {
            Write-Host "  Aborted by user. Protection was stopped but container remains registered." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    Write-Host "  Waiting 30 seconds for stop operations to propagate..." -ForegroundColor Cyan
    Start-Sleep -Seconds 30

    Write-Host "  Unregistering container '$containerName'..." -ForegroundColor Cyan

    $unregisterUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"
    $unregisterSucceeded = $false

    try {
        $unregisterResponse = Invoke-WebRequest -Uri $unregisterUri -Method DELETE -Headers $headers -UseBasicParsing
        $statusCode = $unregisterResponse.StatusCode

        if ($statusCode -eq 200 -or $statusCode -eq 204) {
            Write-Host "  Container unregistered successfully." -ForegroundColor Green
            $unregisterSucceeded = $true
        } elseif ($statusCode -eq 202) {
            Write-Host "  Unregistration accepted (202). Tracking..." -ForegroundColor Green
            $asyncUrl = $unregisterResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $unregisterResponse.Headers["Location"]
            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

            $result = Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 20 -DelaySeconds 8 -OperationName "Container Unregistration"
            $unregisterSucceeded = $result
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ($statusCode -eq 202) {
            Write-Host "  Unregistration accepted (202). Waiting..." -ForegroundColor Green
            Start-Sleep -Seconds 15
            $unregisterSucceeded = $true
        } elseif ($statusCode -eq 204) {
            Write-Host "  Container was already unregistered (204)." -ForegroundColor Green
            $unregisterSucceeded = $true
        } else {
            Write-Host ""
            Write-Host "  ERROR: Failed to unregister container." -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Unregister Container"

            # Check for specific error codes
            $errorMessage = $_.ErrorDetails.Message
            if ($errorMessage -like "*BMSUserErrorContainerHasDatasources*" -or $errorMessage -like "*delete data*") {
                Write-Host ""
                Write-Host "  REASON: The vault still has active datasource references preventing unregistration." -ForegroundColor Yellow
                Write-Host "  Some stop-protection operations may not have fully propagated yet." -ForegroundColor Yellow
                Write-Host "  Wait a few minutes and retry, or check the Azure Portal." -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""

    # ==================================================================
    # FINAL SUMMARY (Unregister flow)
    # ==================================================================
    Write-Host ""
    if ($unregisterSucceeded) {
        Write-Host "  ==========================================================" -ForegroundColor Green
        Write-Host "    VM UNREGISTERED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "  ==========================================================" -ForegroundColor Green
    } else {
        Write-Host "  ==========================================================" -ForegroundColor Yellow
        Write-Host "    UNREGISTRATION MAY NOT HAVE COMPLETED" -ForegroundColor Yellow
        Write-Host "  ==========================================================" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Summary:" -ForegroundColor Yellow
    Write-Host "    Container:              $containerName" -ForegroundColor White
    Write-Host "    DBs stopped:            $stopSuccessCount" -ForegroundColor White
    Write-Host "    DBs already stopped:    $stopSkipCount" -ForegroundColor White
    Write-Host "    DBs failed to stop:     $stopFailCount" -ForegroundColor White
    Write-Host "    Container unregistered: $(if ($unregisterSucceeded) { 'Yes' } else { 'Check Portal' })" -ForegroundColor White
    Write-Host ""
    Write-Host "  Recovery points are PRESERVED (stop-with-retain keeps them intact)." -ForegroundColor Green
    Write-Host ""
    Write-Host "Script completed." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# ============================================================================
# NON-UNREGISTER FLOW: STEP 2 - Stop Protection with Retain Data
# ============================================================================

$successCount = 0
$failCount = 0
$dbsToStop = @()

if ($vmProtectedDBs.Count -gt 0) {
    Write-Host ""
    Write-Host "STEP 2: Stopping Protection (Retain Data)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        # Specific database provided
        $targetDB = $vmProtectedDBs | Where-Object {
            $_.properties.friendlyName -eq $DatabaseName -or
            $_.properties.friendlyName -ieq $DatabaseName
        }

        if ($targetDB) {
            if ($targetDB -is [array]) { $targetDB = $targetDB[0] }
            $dbsToStop = @($targetDB)
        } else {
            Write-Host "  ERROR: Database '$DatabaseName' not found in protected items." -ForegroundColor Red
            Write-Host "  Available databases:" -ForegroundColor Yellow
            foreach ($db in $vmProtectedDBs) {
                Write-Host "    - $($db.properties.friendlyName) (State: $($db.properties.protectionState))" -ForegroundColor White
            }
            exit 1
        }
    } elseif ($StopAll) {
        # Stop all
        $dbsToStop = $vmProtectedDBs
        Write-Host "  -StopAll specified. Stopping protection for all $($dbsToStop.Count) database(s)..." -ForegroundColor Cyan
    } else {
        # Interactive selection
        $activeDBs = $vmProtectedDBs | Where-Object { $_.properties.protectionState -ne "ProtectionStopped" }

        if ($activeDBs.Count -eq 0) {
            Write-Host "  All databases already have protection stopped." -ForegroundColor Green
        } else {
            Write-Host "  Select database(s) to stop protection:" -ForegroundColor Cyan
            Write-Host "    [A] All databases - $($activeDBs.Count) active" -ForegroundColor White

            $idx = 1
            foreach ($db in $activeDBs) {
                Write-Host "    [$idx] $($db.properties.friendlyName) (State: $($db.properties.protectionState))" -ForegroundColor White
                $idx++
            }
            Write-Host ""
            $choice = Read-Host "  Enter number or 'A' for all (default: A)"

            if ([string]::IsNullOrWhiteSpace($choice) -or $choice -ieq 'A') {
                $dbsToStop = $activeDBs
            } else {
                $selIdx = [int]$choice - 1
                if ($selIdx -ge 0 -and $selIdx -lt $activeDBs.Count) {
                    $dbsToStop = @($activeDBs[$selIdx])
                } else {
                    Write-Host "  Invalid selection." -ForegroundColor Red
                    exit 1
                }
            }
        }
    }

    # Execute stop protection for each selected database
    foreach ($db in $dbsToStop) {
        $result = Stop-SQLDatabaseProtection -ProtectedItem $db -Headers $headers -ApiVersion $apiVersion
        if ($result) { $successCount++ } else { $failCount++ }
    }

    Write-Host ""
    Write-Host "  Stop Protection Summary:" -ForegroundColor Cyan
    Write-Host "    Succeeded: $successCount" -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host "    Failed:    $failCount" -ForegroundColor Red
    }
    Write-Host ""
}

# ============================================================================
# CHECK IF ALL DBs ARE NOW STOPPED - PROMPT FOR UNREGISTER
# ============================================================================

$runUnregister = $false

if ($vmProtectedDBs.Count -gt 0) {
    # Re-check: are all databases now in ProtectionStopped state?
    $activeRemaining = $vmProtectedDBs | Where-Object {
        $_.properties.protectionState -ne "ProtectionStopped"
    }

    # Subtract the ones we just successfully stopped
    if ($dbsToStop.Count -gt 0 -and $successCount -eq $dbsToStop.Count) {
        $stillActiveCount = $activeRemaining.Count - $successCount
        if ($stillActiveCount -le 0) { $stillActiveCount = 0 }
    } else {
        $stillActiveCount = $activeRemaining.Count
    }

    if ($stillActiveCount -le 0) {
        Write-Host ""
        Write-Host "  All SQL databases on VM '$vmName' now have protection stopped." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Would you like to also UNREGISTER the VM from the vault?" -ForegroundColor Cyan
        Write-Host "  Recovery points are preserved (stop-with-retain keeps them)." -ForegroundColor Gray
        Write-Host ""
        $unregChoice = Read-Host '  Unregister VM? [Y/N, default: N]'

        if ($unregChoice -ieq 'Y') {
            $runUnregister = $true
            Write-Host "  Proceeding with unregistration..." -ForegroundColor Cyan
        } else {
            Write-Host "  Skipping unregistration." -ForegroundColor Gray
        }
    }
} elseif ($vmProtectedDBs.Count -eq 0) {
    # No protected items found - VM might be registered but all DBs already unprotected
    Write-Host ""
    Write-Host "  No protected databases found on VM '$vmName'." -ForegroundColor Yellow
    Write-Host "  Would you like to UNREGISTER the VM from the vault?" -ForegroundColor Cyan
    Write-Host "  Recovery points are preserved (stop-with-retain keeps them)." -ForegroundColor Gray
    Write-Host ""
    $unregChoice = Read-Host '  Unregister VM? [Y/N, default: N]'

    if ($unregChoice -ieq 'Y') {
        $runUnregister = $true
    }
}

# ============================================================================
# PROMPTED UNREGISTER: Re-invoke with -Unregister flag
# ============================================================================

if ($runUnregister) {
    Write-Host ""
    Write-Host "  Re-running with -Unregister flag..." -ForegroundColor Cyan
    Write-Host ""
    & $PSCommandPath -VaultSubscriptionId $VaultSubscriptionId -VaultResourceGroup $VaultResourceGroup -VaultName $VaultName -VMResourceGroup $VMResourceGroup -VMName $VMName -Unregister
    exit $LASTEXITCODE
}

# ============================================================================
# SUMMARY (non-unregister flow, no prompt taken)
# ============================================================================

Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
if ($vmProtectedDBs.Count -gt 0 -and $dbsToStop.Count -gt 0) {
    Write-Host "  Databases processed:  $($dbsToStop.Count)" -ForegroundColor White
    Write-Host "  Action:               Stop Protection (Retain Data)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Recovery points are RETAINED and accessible from the vault." -ForegroundColor Green
Write-Host "  To fully unregister the VM, re-run with -Unregister or answer 'Y' when prompted." -ForegroundColor Gray
Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""
