<#
.SYNOPSIS
    Restores a SAP HANA database to an alternate VM (Alternate Location) using
    Azure Recovery Services Vault REST API.

.DESCRIPTION
    This script performs an Alternate Location restore of a SAP HANA database
    from a Recovery Services Vault to a different target HANA container/VM.

    It uses the Azure Backup REST API with the request body format:
        objectType = "AzureWorkloadSAPHanaRestoreRequest"
        recoveryType = "AlternateLocation"

    Script Flow:
      1. Authenticate (Azure PowerShell or Azure CLI - Bearer token)
      2. List protected SAP HANA items in the vault and select the source DB
      3. List available recovery points and let user select one
      4. Collect target container and database name for alternate restore
      5. Build the REST API request body (AzureWorkloadSAPHanaRestoreRequest)
      6. Trigger the restore via POST and poll for completion

    The script references the armclient-style restore flow:
      POST .../protectionContainers/{container}/protectedItems/{item}/recoveryPoints/{rpId}/restore?api-version=2024-04-01
      Body: { "properties": { "objectType": "AzureWorkloadSAPHanaRestoreRequest", ... } }

    Prerequisites:
      - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
      - Backup Contributor on the Recovery Services Vault
      - Reader on the source and target VMs / resource groups

.NOTES
    Author:    SAP HANA Backup Expert
    Date:      March 12, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/sap-hana-database-restore
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-sap-hana-db
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/restores/trigger
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2024-04-01"   # Azure Backup REST API version for SAP HANA restore

# ============================================================================
# SECTION 1: RECOVERY SERVICES VAULT INFORMATION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SAP HANA Restore to Alternate VM (REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "SECTION 1: Recovery Services Vault Information" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Vault Subscription ID:" -ForegroundColor Cyan
$vaultSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($vaultSubscriptionId)) {
    Write-Host "ERROR: Vault Subscription ID cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
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

$vaultBaseUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName"

# ============================================================================
# SECTION 2: AUTHENTICATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 2: Authentication" -ForegroundColor Yellow
Write-Host "--------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null
$authMethod = $null

# Try Azure PowerShell first
try {
    $azToken = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

    # Az module v12+ returns Token as SecureString; older versions return plain string
    if ($azToken.Token -is [System.Security.SecureString]) {
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($azToken.Token)
        )
        Write-Host "  Token obtained (SecureString - Az module v12+)" -ForegroundColor Gray
    } else {
        $token = $azToken.Token
        Write-Host "  Token obtained (plain string - Az module legacy)" -ForegroundColor Gray
    }

    $authMethod = "Azure PowerShell"
    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    Write-Host "  Azure PowerShell not available, trying Azure CLI..." -ForegroundColor Yellow
    try {
        $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1
        if ($LASTEXITCODE -eq 0) {
            $tokenObject = $azTokenOutput | ConvertFrom-Json
            $token = $tokenObject.accessToken
            $authMethod = "Azure CLI"
            Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
        } else {
            throw "Azure CLI authentication failed"
        }
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to authenticate to Azure." -ForegroundColor Red
        Write-Host "  Please authenticate first:" -ForegroundColor Yellow
        Write-Host "    Option A: Connect-AzAccount   (Azure PowerShell)" -ForegroundColor White
        Write-Host "    Option B: az login             (Azure CLI)" -ForegroundColor White
        Write-Host ""
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Validate token is not empty
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "ERROR: Authentication succeeded but token is empty." -ForegroundColor Red
    Write-Host "  Try: az login, then re-run the script." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Token length: $($token.Length) chars (auth method: $authMethod)" -ForegroundColor Gray

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ============================================================================
# SECTION 3: DISCOVER PROTECTED SAP HANA ITEMS (SOURCE DB)
# ============================================================================

Write-Host ""
Write-Host "SECTION 3: Source SAP HANA Database Selection" -ForegroundColor Yellow
Write-Host "-----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Fetching protected SAP HANA items from vault '$vaultName'..." -ForegroundColor Cyan

$protectedItemsUri = "$vaultBaseUri/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SAPHanaDatabase'"

Write-Host "Protected Items URI:" -ForegroundColor DarkGray
Write-Host "  $protectedItemsUri" -ForegroundColor DarkGray

try {
    $protectedResponse = Invoke-RestMethod -Uri $protectedItemsUri -Method GET -Headers $headers
} catch {
    Write-Host "ERROR: Failed to list protected SAP HANA items." -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if (-not $protectedResponse.value -or $protectedResponse.value.Count -eq 0) {
    Write-Host "ERROR: No protected SAP HANA databases found in vault '$vaultName'." -ForegroundColor Red
    Write-Host "  Ensure the HANA VM is registered and databases are protected." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Found $($protectedResponse.value.Count) protected SAP HANA database(s):" -ForegroundColor Green
Write-Host ""

$index = 1
foreach ($item in $protectedResponse.value) {
    $friendlyName = $item.properties.friendlyName
    $serverName   = $item.properties.serverName
    $protState    = $item.properties.protectionState
    $lastBackup   = $item.properties.lastBackupTime
    $policyName   = $item.properties.policyName

    Write-Host "  [$index] $friendlyName" -ForegroundColor White
    Write-Host "        Server:          $serverName" -ForegroundColor Gray
    Write-Host "        Protection State: $protState" -ForegroundColor Gray
    Write-Host "        Last Backup:     $lastBackup" -ForegroundColor Gray
    Write-Host "        Policy:          $policyName" -ForegroundColor Gray
    Write-Host ""
    $index++
}

Write-Host "Select the source SAP HANA database to restore (enter number 1-$($protectedResponse.value.Count)):" -ForegroundColor Cyan
$dbChoice = Read-Host "  Enter choice"
$dbIndex = [int]$dbChoice - 1

if ($dbIndex -lt 0 -or $dbIndex -ge $protectedResponse.value.Count) {
    Write-Host "ERROR: Invalid selection." -ForegroundColor Red
    exit 1
}

$selectedItem = $protectedResponse.value[$dbIndex]

# Parse container name and protected item name from the resource ID
# Format: .../protectionContainers/{containerName}/protectedItems/{protectedItemName}
if ($selectedItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
    $sourceContainerName   = $matches[1]
    $sourceProtectedItemName = $matches[2]
} else {
    Write-Host "ERROR: Could not parse container/item names from resource ID." -ForegroundColor Red
    exit 1
}

$sourceResourceId = $selectedItem.id

Write-Host ""
Write-Host "  Selected: $($selectedItem.properties.friendlyName)" -ForegroundColor Green
Write-Host "  Container:       $sourceContainerName" -ForegroundColor Gray
Write-Host "  Protected Item:  $sourceProtectedItemName" -ForegroundColor Gray

# ============================================================================
# SECTION 4: RECOVERY POINT SELECTION
# ============================================================================

Write-Host ""
Write-Host "SECTION 4: Recovery Point Selection" -ForegroundColor Yellow
Write-Host "-------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Choose the restore type:" -ForegroundColor Cyan
Write-Host "  [1] Point in Time (Log-based)" -ForegroundColor White
Write-Host "  [2] Full / Differential backup" -ForegroundColor White
$restoreTypeChoice = Read-Host "  Enter choice (1 or 2)"

$isPointInTimeRestore = $false
$recoveryPointId = $null
$rpTimeDisplay = $null
$selectedPointInTime = $null

if ($restoreTypeChoice -eq "1") {
    # ---- Point in Time (Log) restore ----
    $isPointInTimeRestore = $true

    Write-Host ""
    Write-Host "Fetching available log time ranges..." -ForegroundColor Cyan

    $logRpUri = "$vaultBaseUri/backupFabrics/Azure/protectionContainers/$sourceContainerName/protectedItems/$sourceProtectedItemName/recoveryPoints?api-version=2023-02-01&`$filter=restorePointQueryType eq 'Log'"

    Write-Host "  Log RP URI: $logRpUri" -ForegroundColor DarkGray

    try {
        $logRpResponse = Invoke-RestMethod -Uri $logRpUri -Method GET -Headers $headers
    } catch {
        Write-Host "ERROR: Failed to fetch log recovery point time ranges." -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if (-not $logRpResponse.value -or $logRpResponse.value.Count -eq 0) {
        Write-Host "ERROR: No log recovery points found for this database." -ForegroundColor Red
        exit 1
    }

    $timeRanges = $logRpResponse.value[0].properties.timeRanges
    $recoveryPointId = $logRpResponse.value[0].name   # "DefaultRangeRecoveryPoint"

    if (-not $timeRanges -or $timeRanges.Count -eq 0) {
        Write-Host "ERROR: No log time ranges available." -ForegroundColor Red
        exit 1
    }

    Write-Host "  Available log time range(s):" -ForegroundColor Green
    Write-Host ""

    $rangeIdx = 1
    foreach ($range in $timeRanges) {
        $startFormatted = $range.startTime
        $endFormatted   = $range.endTime
        try {
            $startFormatted = ([datetime]::Parse($range.startTime)).ToString("yyyy-MM-dd HH:mm:ss") + " UTC"
            $endFormatted   = ([datetime]::Parse($range.endTime)).ToString("yyyy-MM-dd HH:mm:ss") + " UTC"
        } catch { }

        Write-Host "  [$rangeIdx] From: $startFormatted" -ForegroundColor White
        Write-Host "        To:   $endFormatted" -ForegroundColor White
        Write-Host ""
        $rangeIdx++
    }

    Write-Host "Enter the desired point-in-time for restore (UTC format, e.g. 2026-03-12T14:00:00.000Z):" -ForegroundColor Cyan
    $selectedPointInTime = Read-Host "  Enter point-in-time"

    if ([string]::IsNullOrWhiteSpace($selectedPointInTime)) {
        Write-Host "ERROR: Point-in-time cannot be empty." -ForegroundColor Red
        exit 1
    }

    # Validate the entered time falls within one of the available ranges
    $pitValid = $false
    try {
        $pitDateTime = [datetime]::Parse($selectedPointInTime).ToUniversalTime()
        Write-Host "  Entered point-in-time: $($pitDateTime.ToString("yyyy-MM-dd HH:mm:ss")) UTC" -ForegroundColor Gray 
        foreach ($range in $timeRanges) {
            $rangeStart = [datetime]::Parse($range.startTime).ToUniversalTime()
            $rangeEnd   = [datetime]::Parse($range.endTime).ToUniversalTime()
            if ($pitDateTime -ge $rangeStart -and $pitDateTime -le $rangeEnd) {
                $pitValid = $true
                break
            }
        }
    } catch {
        Write-Host "ERROR: Could not parse the entered time. Use UTC format (e.g. 2026-03-12T14:00:00.000Z)." -ForegroundColor Red
        exit 1
    }

    if (-not $pitValid) {
        Write-Host "WARNING: The entered time does not fall within any available log time range." -ForegroundColor Yellow
        Write-Host "  The restore may fail. Continue anyway? (yes/no):" -ForegroundColor Yellow
        $pitContinue = Read-Host "  Enter choice"
        if ($pitContinue -notin @("yes", "YES", "y", "Y")) {
            Write-Host "Cancelled by user." -ForegroundColor Yellow
            exit 0
        }
    }

    $rpTimeDisplay = $pitDateTime.ToString("yyyy-MM-dd HH:mm:ss") + " UTC"

    Write-Host ""
    Write-Host "  Restore Type:    Point in Time (Log)" -ForegroundColor Green
    Write-Host "  Point-in-Time:   $rpTimeDisplay" -ForegroundColor Green
    Write-Host "  Recovery Point:  $recoveryPointId" -ForegroundColor Green

} else {
    # ---- Full / Differential backup restore ----

    Write-Host ""
    Write-Host "Fetching recovery points..." -ForegroundColor Cyan

    $rpUri = "$vaultBaseUri/backupFabrics/Azure/protectionContainers/$sourceContainerName/protectedItems/$sourceProtectedItemName/recoveryPoints?api-version=$apiVersion"

    Write-Host "  Recovery Points URI: $rpUri" -ForegroundColor DarkGray

    try {
        $rpResponse = Invoke-RestMethod -Uri $rpUri -Method GET -Headers $headers
    } catch {
        Write-Host "ERROR: Failed to list recovery points." -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    if (-not $rpResponse.value -or $rpResponse.value.Count -eq 0) {
        Write-Host "ERROR: No recovery points found for this database." -ForegroundColor Red
        exit 1
    }

    Write-Host "  Found $($rpResponse.value.Count) recovery point(s):" -ForegroundColor Green
    Write-Host ""

    $rpIndex = 1
    foreach ($rp in $rpResponse.value) {
        $rpName = $rp.name
        $rpTime = $rp.properties.recoveryPointTimeInUTC
        $rpType = $rp.properties.type

        # Format the UTC time for readability
        $rpTimeFormatted = $rpTime
        try {
            $rpDateTime = [datetime]::Parse($rpTime)
            $rpTimeFormatted = $rpDateTime.ToString("yyyy-MM-dd HH:mm:ss") + " UTC"
        } catch { }

        Write-Host "  [$rpIndex] RP ID: $rpName" -ForegroundColor White
        Write-Host "        Time (UTC): $rpTimeFormatted" -ForegroundColor Gray
        Write-Host "        Type:       $rpType" -ForegroundColor Gray
        Write-Host ""
        $rpIndex++
    }

    Write-Host "Select a recovery point (enter number 1-$($rpResponse.value.Count)):" -ForegroundColor Cyan
    Write-Host "  (Or enter a Recovery Point ID directly if obtained from Azure Portal):" -ForegroundColor Gray
    $rpChoice = Read-Host "  Enter choice"

    # Check if user entered a number (index) or a full RP ID
    $selectedRP = $null

    if ($rpChoice -match '^\d+$' -and [int]$rpChoice -ge 1 -and [int]$rpChoice -le $rpResponse.value.Count) {
        $selectedRP = $rpResponse.value[[int]$rpChoice - 1]
        $recoveryPointId = $selectedRP.name
    } else {
        # User provided a direct RP ID
        $recoveryPointId = $rpChoice.Trim()
        $selectedRP = $rpResponse.value | Where-Object { $_.name -eq $recoveryPointId }
    }

    if ([string]::IsNullOrWhiteSpace($recoveryPointId)) {
        Write-Host "ERROR: Invalid recovery point selection." -ForegroundColor Red
        exit 1
    }

    $rpTimeDisplay = "(manual RP ID)"
    if ($selectedRP) {
        try {
            $rpDateTime = [datetime]::Parse($selectedRP.properties.recoveryPointTimeInUTC)
            $rpTimeDisplay = $rpDateTime.ToString("yyyy-MM-dd HH:mm:ss") + " UTC"
        } catch {
            $rpTimeDisplay = $selectedRP.properties.recoveryPointTimeInUTC
        }
    }

    Write-Host ""
    Write-Host "  Restore Type:    Full / Differential" -ForegroundColor Green
    Write-Host "  Selected RP:     $recoveryPointId" -ForegroundColor Green
    Write-Host "  RP Time:         $rpTimeDisplay" -ForegroundColor Green
    Write-Host "  RP Type:         $(if ($selectedRP) { $selectedRP.properties.type } else { 'N/A' })" -ForegroundColor Green
}

# ============================================================================
# SECTION 5: TARGET (ALTERNATE) CONTAINER & DATABASE INFO
# ============================================================================

Write-Host ""
Write-Host "SECTION 5: Target (Alternate) Container & Database" -ForegroundColor Yellow
Write-Host "----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "The target container is the HANA VM/container where the DB will be restored." -ForegroundColor Gray
Write-Host ""

# --- Discover registered HANA containers in the vault ---

Write-Host "Fetching registered SAP HANA containers in vault..." -ForegroundColor Cyan

$containersUri = "$vaultBaseUri/backupProtectionContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"

Write-Host containersUri: $containersUri -ForegroundColor Gray

$targetContainerId = $null

try {
    $containersResponse = Invoke-RestMethod -Uri $containersUri -Method GET -Headers $headers

    if ($containersResponse.value -and $containersResponse.value.Count -gt 0) {
        Write-Host "  Found $($containersResponse.value.Count) registered container(s):" -ForegroundColor Green
        Write-Host ""

        $cIndex = 1
        foreach ($c in $containersResponse.value) {
            $cFriendly = $c.properties.friendlyName
            $cType     = $c.properties.containerType
            $cHealth   = $c.properties.healthStatus

            Write-Host "  [$cIndex] $cFriendly" -ForegroundColor White
            Write-Host "        Type:   $cType" -ForegroundColor Gray
            Write-Host "        Health: $cHealth" -ForegroundColor Gray
            Write-Host "        ID:     $($c.id)" -ForegroundColor DarkGray
            Write-Host ""
            $cIndex++
        }

        Write-Host "Select the TARGET container for alternate restore (enter number 1-$($containersResponse.value.Count)):" -ForegroundColor Cyan
        $cChoice = Read-Host "  Enter choice"
        $cIdx = [int]$cChoice - 1

        if ($cIdx -lt 0 -or $cIdx -ge $containersResponse.value.Count) {
            Write-Host "ERROR: Invalid container selection." -ForegroundColor Red
            exit 1
        }

        $targetContainerObj = $containersResponse.value[$cIdx]
        $targetContainerId  = $targetContainerObj.id

        # Extract just the container name from the ID
        if ($targetContainerId -match '/protectionContainers/([^/]+)$') {
            $targetContainerName = $matches[1]
        } else {
            $targetContainerName = $targetContainerObj.name
        }

        Write-Host "  Selected target container: $($targetContainerObj.properties.friendlyName)" -ForegroundColor Green
        Write-Host "  Container ID:  $targetContainerId" -ForegroundColor Gray
    } else {
        Write-Host "  No registered AzureWorkload containers found. You must enter the target container ID manually." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  WARNING: Could not list containers. You can enter the target container ID manually." -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($targetContainerId)) {
    Write-Host ""
    Write-Host "Enter Target Container ID (full resource path):" -ForegroundColor Cyan
    Write-Host "  Example: /subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.RecoveryServices/vaults/{vault}/backupFabrics/Azure/protectionContainers/VMAppContainer;Compute;{rg};{vmName}" -ForegroundColor Gray
    $targetContainerId = Read-Host "  Enter Container ID"
    if ([string]::IsNullOrWhiteSpace($targetContainerId)) {
        Write-Host "ERROR: Target Container ID cannot be empty." -ForegroundColor Red
        exit 1
    }
}

# --- Discover SAP HANA SIDs on the target container ---

Write-Host ""
Write-Host "Fetching SAP HANA SIDs on the target container..." -ForegroundColor Cyan

$sidList = @()
try {
    $itemsFilter = "backupManagementType eq 'AzureWorkload' and workloadItemType eq 'SAPHanaSystem'"
    $itemsUri    = "https://management.azure.com$targetContainerId/items?api-version=2017-07-01&`$filter=$itemsFilter"

    Write-Host "  Items URI: $itemsUri" -ForegroundColor Gray

    $itemsResponse = Invoke-RestMethod -Uri $itemsUri -Method GET -Headers $headers

    if ($itemsResponse.value -and $itemsResponse.value.Count -gt 0) {
        Write-Host "  Found $($itemsResponse.value.Count) SAP HANA SID(s):" -ForegroundColor Green
        Write-Host ""

        $sIndex = 1
        foreach ($item in $itemsResponse.value) {
            $sidFriendlyName = $item.properties.friendlyName
            $sidParentName   = $item.properties.parentName
            $sidServerName   = $item.properties.serverName
            $sidList += $sidFriendlyName

            Write-Host "  [$sIndex] SID: $sidFriendlyName" -ForegroundColor White
            Write-Host "        Parent:  $sidParentName" -ForegroundColor Gray
            Write-Host "        Server:  $sidServerName" -ForegroundColor Gray
            Write-Host ""
            $sIndex++
        }

        if ($sidList.Count -eq 1) {
            Write-Host "  Auto-detected SID: $($sidList[0])" -ForegroundColor Green
        } else {
            Write-Host "  Multiple SIDs detected. Use the appropriate SID when entering the target database name below." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  No SAP HANA SIDs found on the target container." -ForegroundColor Yellow
        Write-Host "  You will need to manually enter the SID in the target database name." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  WARNING: Could not retrieve SID info from target container. You can enter the SID manually." -ForegroundColor Yellow
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor DarkGray
}

$sidHint = if ($sidList.Count -eq 1) { "$($sidList[0])/" } else { "SID/" }

Write-Host ""
Write-Host "Target Database Name (format: SID/databaseName, e.g. $($sidHint)restoretest01):" -ForegroundColor Cyan
$targetDatabaseName = Read-Host "  Enter Target Database Name"
if ([string]::IsNullOrWhiteSpace($targetDatabaseName)) {
    Write-Host "ERROR: Target Database Name cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Overwrite existing DB on target? (Overwrite / Failover / Invalid):" -ForegroundColor Cyan
Write-Host "  Default: Overwrite" -ForegroundColor Gray
$overwriteOption = Read-Host "  Enter option"
if ([string]::IsNullOrWhiteSpace($overwriteOption)) {
    $overwriteOption = "Overwrite"
}

Write-Host ""
Write-Host "Azure Region of the vault (e.g., eastasia, eastus, westeurope):" -ForegroundColor Cyan
$restoreLocation = Read-Host "  Enter region"
if ([string]::IsNullOrWhiteSpace($restoreLocation)) {
    Write-Host "ERROR: Region cannot be empty." -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 6: BUILD REST API REQUEST BODY
# ============================================================================

Write-Host ""
Write-Host "SECTION 6: Building Restore Request Body" -ForegroundColor Yellow
Write-Host "------------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Build the body per the restore type
if ($isPointInTimeRestore) {
    # Point in Time (Log) restore uses AzureWorkloadSAPHanaPointInTimeRestoreRequest
    $restoreBody = @{
        properties = @{
            objectType       = "AzureWorkloadSAPHanaPointInTimeRestoreRequest"
            recoveryType     = "AlternateLocation"
            sourceResourceId = $sourceResourceId
            pointInTime      = $selectedPointInTime
            targetInfo       = @{
                overwriteOption = $overwriteOption
                containerId     = $targetContainerId
                databaseName    = $targetDatabaseName
            }
        }
        location = $restoreLocation
    }
} else {
    # Full / Differential restore uses AzureWorkloadSAPHanaRestoreRequest
    $restoreBody = @{
        properties = @{
            objectType       = "AzureWorkloadSAPHanaRestoreRequest"
            recoveryType     = "AlternateLocation"
            sourceResourceId = $sourceResourceId
            targetInfo       = @{
                overwriteOption = $overwriteOption
                containerId     = $targetContainerId
                databaseName    = $targetDatabaseName
            }
        }
        location = $restoreLocation
    }
}

$restoreBodyJson = $restoreBody | ConvertTo-Json -Depth 10

Write-Host "--- Request Body (in-memory) ---" -ForegroundColor DarkGray
Write-Host $restoreBodyJson -ForegroundColor DarkGray
Write-Host "--------------------------------" -ForegroundColor DarkGray

# ============================================================================
# SECTION 7: SUMMARY & CONFIRMATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 7: Restore Summary" -ForegroundColor Yellow
Write-Host "----------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Source DB:          $($selectedItem.properties.friendlyName)" -ForegroundColor Gray
Write-Host "  Source Container:   $sourceContainerName" -ForegroundColor Gray
Write-Host "  Restore Type:       $(if ($isPointInTimeRestore) { 'Point in Time (Log)' } else { 'Full / Differential' })" -ForegroundColor Gray
Write-Host "  Recovery Point ID:  $recoveryPointId" -ForegroundColor Gray
if ($isPointInTimeRestore) {
    Write-Host "  Point-in-Time:      $rpTimeDisplay" -ForegroundColor Gray
} else {
    Write-Host "  RP Time:            $rpTimeDisplay" -ForegroundColor Gray
}
Write-Host "  Target Container:   $targetContainerId" -ForegroundColor Gray
Write-Host "  Target DB Name:     $targetDatabaseName" -ForegroundColor Gray
Write-Host "  Overwrite Option:   $overwriteOption" -ForegroundColor Gray
Write-Host "  Region:             $restoreLocation" -ForegroundColor Gray
Write-Host ""

Write-Host "WARNING: This will restore the SAP HANA database to the alternate target." -ForegroundColor Yellow
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"

if ($confirm -notin @("yes", "YES", "y", "Y")) {
    Write-Host "Restore operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# SECTION 8: TRIGGER RESTORE OPERATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 8: Triggering Restore" -ForegroundColor Yellow
Write-Host "-------------------------------" -ForegroundColor Yellow
Write-Host ""

# POST .../protectionContainers/{container}/protectedItems/{item}/recoveryPoints/{rpId}/restore?api-version=2024-04-01
$restoreUri = "$vaultBaseUri/backupFabrics/Azure/protectionContainers/$sourceContainerName/protectedItems/$sourceProtectedItemName/recoveryPoints/$recoveryPointId/restore?api-version=$apiVersion"

Write-Host "Restore URI:" -ForegroundColor DarkGray
Write-Host "  $restoreUri" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Triggering restore operation..." -ForegroundColor Cyan

try {
    $restoreResponse = Invoke-WebRequest -Uri $restoreUri -Method POST -Headers $headers -Body $restoreBodyJson -UseBasicParsing

    if ($restoreResponse.StatusCode -eq 202) {
        Write-Host "  Restore operation accepted (HTTP 202)" -ForegroundColor Green
        Write-Host ""

        # Extract tracking URL
        $azureAsyncHeader = $restoreResponse.Headers["Azure-AsyncOperation"]
        $locationHeader   = $restoreResponse.Headers["Location"]
        $trackingUrl = if ($azureAsyncHeader) { $azureAsyncHeader } else { $locationHeader }

        if ($trackingUrl) {
            Write-Host "Polling restore job status..." -ForegroundColor Cyan
            Write-Host ""

            $operationComplete = $false
            $maxRetries = 120     # SAP HANA restores can take longer
            $retryCount = 0

            while (-not $operationComplete -and $retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 15

                try {
                    $statusResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $headers
                    $status = $statusResponse.status

                    Write-Host "  [$retryCount/$maxRetries] Status: $status" -ForegroundColor Yellow

                    if ($status -eq "Succeeded") {
                        $operationComplete = $true
                        Write-Host ""
                        Write-Host "========================================" -ForegroundColor Green
                        Write-Host "  SAP HANA RESTORE STARTED!" -ForegroundColor Green
                        Write-Host "========================================" -ForegroundColor Green
                        Write-Host ""

                        if ($statusResponse.properties.jobId) {
                            Write-Host "  Restore Job ID: $($statusResponse.properties.jobId)" -ForegroundColor Cyan
                        }

                        Write-Host "  Target Container: $targetContainerId" -ForegroundColor Gray
                        Write-Host "  Target DB:        $targetDatabaseName" -ForegroundColor Gray
                        Write-Host ""
                        Write-Host "  Next steps:" -ForegroundColor Yellow
                        Write-Host "    1. Verify the restored DB on the target HANA instance" -ForegroundColor White
                        Write-Host "    2. Check Azure Portal -> Vault -> Backup Jobs for full details" -ForegroundColor White
                        Write-Host "    3. Configure backup protection for the restored DB if needed" -ForegroundColor White

                    } elseif ($status -eq "Failed") {
                        $operationComplete = $true
                        Write-Host ""
                        Write-Host "========================================" -ForegroundColor Red
                        Write-Host "  SAP HANA RESTORE FAILED!" -ForegroundColor Red
                        Write-Host "========================================" -ForegroundColor Red
                        Write-Host ""

                        if ($statusResponse.error) {
                            Write-Host "  Error Code:    $($statusResponse.error.code)" -ForegroundColor Red
                            Write-Host "  Error Message: $($statusResponse.error.message)" -ForegroundColor Red
                        }

                        Write-Host ""
                        Write-Host "  Possible causes:" -ForegroundColor Yellow
                        Write-Host "    1. Target HANA instance is not reachable or not registered" -ForegroundColor White
                        Write-Host "    2. Target database name format is incorrect (use SID/dbName)" -ForegroundColor White
                        Write-Host "    3. Insufficient permissions on target container" -ForegroundColor White
                        Write-Host "    4. Recovery point is expired or invalid" -ForegroundColor White
                        Write-Host "    5. HANA pre-registration script not run on target VM" -ForegroundColor White
                        exit 1

                    } elseif ($status -eq "InProgress") {
                        # Continue polling
                    } else {
                        Write-Host "    Unknown status: $status" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  Warning: Failed to get status - retrying..." -ForegroundColor Yellow
                }

                $retryCount++
            }

            if (-not $operationComplete) {
                Write-Host ""
                Write-Host "  Restore is still in progress after $(($maxRetries * 15) / 60) minutes." -ForegroundColor Yellow
                Write-Host "  Monitor in Azure Portal -> Recovery Services Vault -> '$vaultName' -> Backup Jobs" -ForegroundColor White
            }
        } else {
            Write-Host "  Restore submitted. No tracking URL returned." -ForegroundColor Yellow
            Write-Host "  Monitor in Azure Portal -> Recovery Services Vault -> Backup Jobs" -ForegroundColor White
        }

    } elseif ($restoreResponse.StatusCode -eq 200) {
        Write-Host "  Restore completed immediately (HTTP 200)" -ForegroundColor Green
    } else {
        Write-Host "  Unexpected response: $($restoreResponse.StatusCode)" -ForegroundColor Yellow
        Write-Host "  $($restoreResponse.Content)" -ForegroundColor Gray
    }

} catch {
    $statusCode = $null
    try { $statusCode = $_.Exception.Response.StatusCode.value__ } catch {}

    if ($statusCode -eq 202) {
        Write-Host "  Restore operation accepted (HTTP 202)" -ForegroundColor Green

        # Try to extract tracking URL from exception response headers
        try {
            $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
            $locUrl   = $_.Exception.Response.Headers["Location"]
            $trackUrl = if ($asyncUrl) { $asyncUrl } else { $locUrl }

            if ($trackUrl) {
                Write-Host "  Tracking URL obtained. Polling status..." -ForegroundColor Cyan
                $maxRetries = 120
                $retryCount = 0
                $opComplete = $false

                while (-not $opComplete -and $retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 15
                    try {
                        $opStatus = Invoke-RestMethod -Uri $trackUrl -Method GET -Headers $headers
                        $st = $opStatus.status
                        Write-Host "  [$retryCount/$maxRetries] Status: $st" -ForegroundColor Yellow

                        if ($st -eq "Succeeded") {
                            $opComplete = $true
                            Write-Host ""
                            Write-Host "  SAP HANA RESTORE COMPLETED!" -ForegroundColor Green
                            if ($opStatus.properties.jobId) {
                                Write-Host "  Job ID: $($opStatus.properties.jobId)" -ForegroundColor Cyan
                            }
                        } elseif ($st -eq "Failed") {
                            $opComplete = $true
                            Write-Host "  RESTORE FAILED." -ForegroundColor Red
                            if ($opStatus.error) {
                                Write-Host "  Code:    $($opStatus.error.code)" -ForegroundColor Red
                                Write-Host "  Message: $($opStatus.error.message)" -ForegroundColor Red
                            }
                            exit 1
                        }
                    } catch { }
                    $retryCount++
                }

                if (-not $opComplete) {
                    Write-Host "  Restore still in progress. Check Azure Portal -> Backup Jobs." -ForegroundColor Yellow
                }
            } else {
                Write-Host "  Restore submitted. Monitor in Azure Portal -> Backup Jobs." -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  Restore submitted. Monitor in Azure Portal -> Backup Jobs." -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: Failed to trigger restore operation." -ForegroundColor Red
        Write-Host "  HTTP Status: $statusCode" -ForegroundColor Red
        Write-Host "  Error:       $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""

        # Try to extract error body
        try {
            $errorStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorStream)
            $errorBody = $reader.ReadToEnd()
            $errorJson = $errorBody | ConvertFrom-Json
            Write-Host "  API Error Code:    $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "  API Error Message: $($errorJson.error.message)" -ForegroundColor Red
        } catch { }

        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    1. Invalid recovery point ID" -ForegroundColor White
        Write-Host "    2. Target container not registered in the vault" -ForegroundColor White
        Write-Host "    3. Target database name incorrect (use SID/dbName)" -ForegroundColor White
        Write-Host "    4. HANA pre-registration script not run on target VM" -ForegroundColor White
        Write-Host "    5. Insufficient RBAC permissions" -ForegroundColor White
        Write-Host "    6. Source and target HANA versions incompatible" -ForegroundColor White
        exit 1
    }
}

# ============================================================================
# COMPLETION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SAP HANA Restore Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
