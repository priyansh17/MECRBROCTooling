<#
.SYNOPSIS
    Discovers, registers, and protects SAP HANA databases on Azure Linux VMs
    to a Recovery Services Vault using REST API.

.DESCRIPTION
    This script discovers SAP HANA databases running on Azure Linux VMs and
    configures backup protection using Azure Backup REST API.

    The script supports:
    - Discovery and registration of VMs with SAP HANA workloads
    - Inquiry of HANA instances and databases within a VM
    - Individual database protection with a chosen policy
    - Detection of already-registered VMs (skips re-registration)
    - Detection of already-protected databases (shows status)
    - Both single-container (Scale-up) and multi-container (Scale-out / MDC) HANA

    Flow:
    1. Refresh containers to discover VMs with SAP HANA workloads
    2. List protectable containers to find the target VM
    3. Register the VM as a VMAppContainer (skip if already registered)
    4. Inquire SAP HANA workloads inside the VM
    5. List protectable items (HANA databases)
    6. Check if the target DB is already protected
    7. List available backup policies for AzureWorkload (SAPHanaDatabase)
    8. Enable protection on the database
    9. Verify and display summary

    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on both the VM and Recovery Services Vault
    - SAP HANA backup pre-registration script run on the VM
      (https://learn.microsoft.com/en-us/azure/backup/tutorial-backup-sap-hana-db#what-the-pre-registration-script-does)

.PARAMETER VaultSubscriptionId
    The Subscription ID where the Recovery Services Vault is located.

.PARAMETER VaultResourceGroup
    The Resource Group name of the Recovery Services Vault.

.PARAMETER VaultName
    The name of the Recovery Services Vault.

.PARAMETER VMResourceGroup
    The Resource Group name of the SAP HANA VM.

.PARAMETER VMName
    The name of the Azure VM hosting SAP HANA.

.PARAMETER DatabaseName
    The name of the SAP HANA database to protect (e.g., SYSTEMDB, or a tenant DB name).
    If not specified, the script will list discovered databases and prompt for selection.

.PARAMETER PolicyName
    The name of the backup policy to assign. If not specified, the script will
    list available policies and prompt for selection.

.EXAMPLE
    # Protect a single HANA database (interactive policy selection)
    .\Register-SAPHanaVM-ToVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-hana" -VMName "hana-vm-01" -DatabaseName "SYSTEMDB"

.EXAMPLE
    # Protect a single database with a specific policy
    .\Register-SAPHanaVM-ToVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-hana" -VMName "hana-vm-01" `
        -DatabaseName "SYSTEMDB" -PolicyName "HanaDaily30d"

.EXAMPLE
    # Run without parameters - PowerShell will prompt for all mandatory inputs
    .\Register-SAPHanaVM-ToVault.ps1

.NOTES
    Author: SAP HANA Backup Expert
    Date: March 12, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-sap-hana-db
    Reference: https://learn.microsoft.com/en-us/azure/backup/tutorial-backup-sap-hana-db
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-sap-hana-db-powershell
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/register
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-intent/create-or-update
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

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the SAP HANA VM.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Azure VM hosting SAP HANA.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the SAP HANA database to protect (e.g. SYSTEMDB). If omitted, discovered databases will be listed for selection.")]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the backup policy to assign. If omitted, available policies will be listed for selection.")]
    [string]$PolicyName
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2016-12-01"             # Azure Backup REST API version for discovery/registration
$apiVersionProtection = "2019-05-13"   # Azure Backup REST API version for protection operations

# ============================================================================
# HELPER FUNCTION: Poll async operation via Location header
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
    } catch {
        # Could not parse error response
    }
}

# ============================================================================
# PARAMETER VALIDATION & DEFAULTS
# ============================================================================

$vaultSubscriptionId  = $VaultSubscriptionId
$vaultResourceGroup   = $VaultResourceGroup
$vaultName            = $VaultName
$vmSubscriptionId     = $VaultSubscriptionId   # VM assumed same subscription as vault
$vmResourceGroup      = $VMResourceGroup
$vmName               = $VMName
$dbName               = $DatabaseName

# Construct VM Resource ID
$vmResourceId = "/subscriptions/$vmSubscriptionId/resourceGroups/$vmResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

# ============================================================================
# DISPLAY CONFIGURATION SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SAP HANA on Azure Linux VM - Backup Protection" -ForegroundColor Cyan
Write-Host "  (Using Azure Backup REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration Summary:" -ForegroundColor Yellow
Write-Host "  Vault Subscription:  $vaultSubscriptionId" -ForegroundColor Gray
Write-Host "  Vault Resource Group:$vaultResourceGroup" -ForegroundColor Gray
Write-Host "  Vault Name:          $vaultName" -ForegroundColor Gray
Write-Host "  VM Resource Group:   $vmResourceGroup" -ForegroundColor Gray
Write-Host "  VM Name:             $vmName" -ForegroundColor Gray
Write-Host "  VM Resource ID:      $vmResourceId" -ForegroundColor Gray
if (-not [string]::IsNullOrWhiteSpace($dbName)) {
    Write-Host "  Database Name:       $dbName" -ForegroundColor Gray
} else {
    Write-Host "  Database Name:       (will be selected after discovery)" -ForegroundColor Gray
}
if (-not [string]::IsNullOrWhiteSpace($PolicyName)) {
    Write-Host "  Policy Name:         $PolicyName" -ForegroundColor Gray
} else {
    Write-Host "  Policy Name:         (will be selected interactively)" -ForegroundColor Gray
}
Write-Host ""

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host ""
Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null
$authMethod = $null

# Try Azure PowerShell first
try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

    # Handle both old (plain string) and new (SecureString) Az.Accounts module versions
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token)
        )
    } else {
        $token = $tokenResponse.Token
    }

    $authMethod = "Azure PowerShell"
    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    # If Azure PowerShell fails, try Azure CLI
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
        Write-Host ""
        Write-Host "Please authenticate using one of these methods:" -ForegroundColor Yellow
        Write-Host "  1. Azure PowerShell: Connect-AzAccount" -ForegroundColor White
        Write-Host "  2. Azure CLI: az login" -ForegroundColor White
        Write-Host ""
        Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Validate token is not empty
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "ERROR: Authentication succeeded but token is empty." -ForegroundColor Red
    Write-Host "  Try: Connect-AzAccount or az login, then re-run." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Token length: $($token.Length) chars (auth method: $authMethod)" -ForegroundColor Gray

# Create common headers
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ============================================================================
# STEP 1: REFRESH CONTAINER DISCOVERY (Discover VMs with HANA workloads)
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Discovering VMs with SAP HANA Workloads" -ForegroundColor Yellow
Write-Host "-------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Triggering refresh to discover SAP HANA workloads in the subscription..." -ForegroundColor Cyan

$refreshUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/refreshContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"

try {
    $refreshResponse = Invoke-WebRequest -Uri $refreshUri -Method POST -Headers $headers -UseBasicParsing
    $statusCode = $refreshResponse.StatusCode

    if ($statusCode -eq 202) {
        Write-Host "  Refresh operation accepted (202)" -ForegroundColor Green
        $locationUrl = $refreshResponse.Headers["Location"]
        Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -OperationName "Discovery" | Out-Null
    } elseif ($statusCode -eq 204) {
        Write-Host "  Discovery completed immediately (204)" -ForegroundColor Green
    } else {
        Write-Host "  Refresh returned status: $statusCode" -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__

    if ($statusCode -eq 202) {
        Write-Host "  Refresh operation accepted (202)" -ForegroundColor Green
        try {
            $locationUrl = $_.Exception.Response.Headers.Location
            Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -OperationName "Discovery" | Out-Null
        } catch {
            Start-Sleep -Seconds 15
        }
    } elseif ($statusCode -eq 204) {
        Write-Host "  Discovery completed (204)" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Refresh returned: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Continuing..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 2: LIST PROTECTABLE CONTAINERS (Find the VM with SAP HANA)
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Listing VMs with SAP HANA Databases" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$protectableContainersUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectableContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"

$matchingContainer = $null
$containerName = $null
$isAlreadyRegistered = $false

try {
    Write-Host "Querying for protectable containers (VMs with HANA)..." -ForegroundColor Cyan
    $containersResponse = Invoke-RestMethod -Uri $protectableContainersUri -Method GET -Headers $headers

    if ($containersResponse.value -and $containersResponse.value.Count -gt 0) {
        Write-Host "  Found $($containersResponse.value.Count) protectable container(s)" -ForegroundColor Green
        Write-Host ""

        # Find the matching VM
        $matchingContainer = $containersResponse.value | Where-Object {
            $_.properties.friendlyName -eq $vmName
        }

        # Also try matching by containerId (ARM resource ID)
        if (-not $matchingContainer) {
            $matchingContainer = $containersResponse.value | Where-Object {
                $_.properties.containerId -eq $vmResourceId
            }
        }

        if ($matchingContainer) {
            if ($matchingContainer -is [array]) { $matchingContainer = $matchingContainer[0] }

            $containerName = $matchingContainer.name
            Write-Host "  Target VM found:" -ForegroundColor Green
            Write-Host "    Friendly Name:   $($matchingContainer.properties.friendlyName)" -ForegroundColor Gray
            Write-Host "    Container Name:  $containerName" -ForegroundColor Gray
            Write-Host "    Container Type:  $($matchingContainer.properties.protectableContainerType)" -ForegroundColor Gray
            Write-Host "    Health Status:   $($matchingContainer.properties.healthStatus)" -ForegroundColor Gray
            Write-Host "    Container ID:    $($matchingContainer.properties.containerId)" -ForegroundColor Gray
        } else {
            Write-Host "  WARNING: VM '$vmName' not found in protectable containers." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Available VMs with AzureWorkload:" -ForegroundColor Yellow
            foreach ($c in $containersResponse.value) {
                Write-Host "    - $($c.properties.friendlyName) (Type: $($c.properties.protectableContainerType))" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "  Constructing container name manually..." -ForegroundColor Yellow
            $containerName = "VMAppContainer;Compute;$vmResourceGroup;$vmName"
            Write-Host "    Container Name: $containerName" -ForegroundColor Gray
        }
    } else {
        Write-Host "  No protectable containers found." -ForegroundColor Yellow
        Write-Host "  Constructing container name manually..." -ForegroundColor Yellow
        $containerName = "VMAppContainer;Compute;$vmResourceGroup;$vmName"
        Write-Host "    Container Name: $containerName" -ForegroundColor Gray
    }
} catch {
    Write-Host "  WARNING: Failed to list protectable containers: $($_.Exception.Message)" -ForegroundColor Yellow
    $containerName = "VMAppContainer;Compute;$vmResourceGroup;$vmName"
    Write-Host "    Container Name: $containerName" -ForegroundColor Gray
}

# ============================================================================
# STEP 3: REGISTER VM WITH RECOVERY SERVICES VAULT (Skip if already registered)
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Registering HANA VM with Recovery Services Vault" -ForegroundColor Yellow
Write-Host "----------------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

# First check if already registered by querying the container
$containerCheckUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

try {
    Write-Host "Checking if VM is already registered..." -ForegroundColor Cyan
    $containerCheckResponse = Invoke-RestMethod -Uri $containerCheckUri -Method GET -Headers $headers

    if ($containerCheckResponse -and $containerCheckResponse.properties.registrationStatus -eq "Registered") {
        $isAlreadyRegistered = $true
        Write-Host ""
        Write-Host "  VM is ALREADY REGISTERED with the vault. Skipping registration." -ForegroundColor Green
        Write-Host "    Registration Status: $($containerCheckResponse.properties.registrationStatus)" -ForegroundColor Gray
        Write-Host "    Health Status:       $($containerCheckResponse.properties.healthStatus)" -ForegroundColor Gray
        Write-Host "    Friendly Name:       $($containerCheckResponse.properties.friendlyName)" -ForegroundColor Gray

        # Update container name from actual response
        if ($containerCheckResponse.name) {
            $containerName = $containerCheckResponse.name
        }
    } else {
        Write-Host "  VM found but registration status: $($containerCheckResponse.properties.registrationStatus)" -ForegroundColor Yellow
        Write-Host "  Proceeding with registration..." -ForegroundColor Yellow
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 404) {
        Write-Host "  VM is not registered. Proceeding with registration..." -ForegroundColor Cyan
    } else {
        Write-Host "  Could not check registration status (HTTP $statusCode). Proceeding..." -ForegroundColor Yellow
    }
}

if (-not $isAlreadyRegistered) {
    Write-Host ""
    Write-Host "Registering VM as VMAppContainer (SAP HANA workload)..." -ForegroundColor Cyan

    $registerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

    # Construct sourceResourceId from the protectable containers response or manually
    $sourceResId = $vmResourceId
    if ($matchingContainer -and $matchingContainer.id) {
        $sourceResId = $matchingContainer.id
    }

    Write-Host "  Source Resource ID for registration: $sourceResId" -ForegroundColor Gray
    Write-Host " Register URI: $registerUri" -ForegroundColor Gray

    $registerBody = @{
        properties = @{
            backupManagementType = "AzureWorkload"
            containerType        = "VMAppContainer"
            friendlyName         = $vmName
            sourceResourceId     = $sourceResId
            workloadType         = "SAPHanaDatabase"
        }
    } | ConvertTo-Json -Depth 10

    try {
        $registerResponse = Invoke-WebRequest -Uri $registerUri -Method PUT -Headers $headers -Body $registerBody -UseBasicParsing
        $statusCode = $registerResponse.StatusCode

        if ($statusCode -eq 200) {
            Write-Host "  Registration completed (200 OK)" -ForegroundColor Green
            $regBody = $registerResponse.Content | ConvertFrom-Json
            Write-Host "    Registration Status: $($regBody.properties.registrationStatus)" -ForegroundColor Gray
        } elseif ($statusCode -eq 202) {
            Write-Host "  Registration accepted (202). Tracking operation..." -ForegroundColor Green
            $locationUrl = $registerResponse.Headers["Location"]
            Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 30 -DelaySeconds 10 -OperationName "Registration" | Out-Null
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ($statusCode -eq 202) {
            Write-Host "  Registration accepted (202)." -ForegroundColor Green
            try {
                $locationUrl = $_.Exception.Response.Headers.Location
                Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 30 -DelaySeconds 10 -OperationName "Registration" | Out-Null
            } catch {
                Start-Sleep -Seconds 30
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: Failed to register HANA VM with vault." -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Container Registration"
            Write-Host ""
            Write-Host "Possible causes:" -ForegroundColor Yellow
            Write-Host "  1. VM doesn't exist or resource ID is incorrect" -ForegroundColor White
            Write-Host "  2. Insufficient permissions on the VM or vault" -ForegroundColor White
            Write-Host "  3. SAP HANA backup pre-registration script has not been run on the VM" -ForegroundColor White
            Write-Host "     Run: https://aka.ms/scriptforlinuxhana" -ForegroundColor White
            Write-Host "  4. VM is deallocated or stopped" -ForegroundColor White
            Write-Host "  5. HANA instance is not running on the VM" -ForegroundColor White
            Write-Host ""
            exit 1
        }
    }

    # Verify registration
    Write-Host ""
    Write-Host "Verifying registration..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5

    try {
        $verifyRegResponse = Invoke-RestMethod -Uri $containerCheckUri -Method GET -Headers $headers
        if ($verifyRegResponse.properties.registrationStatus -eq "Registered") {
            Write-Host "  Registration verified: $($verifyRegResponse.properties.registrationStatus)" -ForegroundColor Green
        } else {
            Write-Host "  Registration status: $($verifyRegResponse.properties.registrationStatus)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Could not verify registration immediately. Continuing..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 4: INQUIRE SAP HANA WORKLOADS INSIDE THE VM
# ============================================================================

Write-Host ""
Write-Host "STEP 4: Discovering SAP HANA Databases Inside VM" -ForegroundColor Yellow
Write-Host "--------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Inquiring SAP HANA workloads inside '$vmName'..." -ForegroundColor Cyan

$inquireUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/inquire?api-version=$apiVersion&`$filter=workloadType eq 'SAPHanaDatabase'"

try {
    $inquireResponse = Invoke-WebRequest -Uri $inquireUri -Method POST -Headers $headers -UseBasicParsing
    $statusCode = $inquireResponse.StatusCode

    if ($statusCode -eq 202) {
        Write-Host "  Inquiry accepted (202). Tracking..." -ForegroundColor Green
        $locationUrl = $inquireResponse.Headers["Location"]
        Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 20 -DelaySeconds 8 -OperationName "SAP HANA workload inquiry" | Out-Null
    } elseif ($statusCode -eq 200 -or $statusCode -eq 204) {
        Write-Host "  Inquiry completed ($statusCode)" -ForegroundColor Green
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__

    if ($statusCode -eq 202) {
        Write-Host "  Inquiry accepted (202)." -ForegroundColor Green
        try {
            $locationUrl = $_.Exception.Response.Headers.Location
            Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 20 -DelaySeconds 8 -OperationName "SAP HANA workload inquiry" | Out-Null
        } catch {
            Start-Sleep -Seconds 20
        }
    } else {
        Write-Host "  WARNING: Inquiry returned: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Continuing with protectable items query..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 5: LIST PROTECTABLE ITEMS (SAP HANA Databases)
# ============================================================================

Write-Host ""
Write-Host "STEP 5: Listing Protectable SAP HANA Databases" -ForegroundColor Yellow
Write-Host "-------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$protectableItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectableItems?api-version=$apiVersionProtection&`$filter=backupManagementType eq 'AzureWorkload'"

$allProtectableItems = @()
$matchingDB = $null

try {
    Write-Host "Querying for protectable SAP HANA items..." -ForegroundColor Cyan

    $currentUri = $protectableItemsUri
    while ($currentUri) {
        $itemsResponse = Invoke-RestMethod -Uri $currentUri -Method GET -Headers $headers

        if ($itemsResponse.value) {
            $allProtectableItems += $itemsResponse.value
        }

        $currentUri = $itemsResponse.nextLink
        if ($currentUri) {
            Write-Host "  Fetching next page of results..." -ForegroundColor Gray
        }
    }

    if ($allProtectableItems.Count -gt 0) {
        # Filter items belonging to our VM
        $vmItems = $allProtectableItems | Where-Object {
            $_.properties.serverName -like "*$vmName*" -or
            $_.id -like "*$vmName*"
        }

        # Separate HANA databases and HANA instances (system)
        $hanaDatabases = $vmItems | Where-Object {
            $_.properties.protectableItemType -eq "SAPHanaDatabase"
        }
        $hanaInstances = $vmItems | Where-Object {
            $_.properties.protectableItemType -eq "SAPHanaSystem" -or
            $_.properties.protectableItemType -eq "HanaHSRContainer" -or
            $_.properties.protectableItemType -eq "SAPHanaInstance"
        }

        Write-Host "  Found $($hanaDatabases.Count) HANA database(s) and $($hanaInstances.Count) HANA instance(s) on VM '$vmName'" -ForegroundColor Green
        Write-Host ""

        # Show HANA instances
        if ($hanaInstances.Count -gt 0) {
            Write-Host "  SAP HANA Instances:" -ForegroundColor Cyan
            foreach ($inst in $hanaInstances) {
                Write-Host "    - $($inst.properties.friendlyName) (Server: $($inst.properties.serverName))" -ForegroundColor White
            }
            Write-Host ""
        }

        # Show HANA databases
        if ($hanaDatabases.Count -gt 0) {
            Write-Host "  SAP HANA Databases:" -ForegroundColor Cyan
            foreach ($db in $hanaDatabases) {
                $state = $db.properties.protectionState
                if (-not $state) { $state = "NotProtected" }
                Write-Host "    - $($db.properties.friendlyName) (Instance: $($db.properties.parentName), State: $state)" -ForegroundColor White
            }
            Write-Host ""
        }

        # If DatabaseName was not provided, prompt user to select from discovered list
        if ([string]::IsNullOrWhiteSpace($dbName)) {
            if ($hanaDatabases.Count -eq 0) {
                Write-Host "  ERROR: No SAP HANA databases found on VM '$vmName'." -ForegroundColor Red
                Write-Host "  Cannot proceed without a database to protect." -ForegroundColor Yellow
                exit 1
            }

            Write-Host "  No -DatabaseName specified. Select a database to protect:" -ForegroundColor Cyan
            Write-Host ""
            $dbIdx = 1
            foreach ($db in $hanaDatabases) {
                $state = $db.properties.protectionState
                if (-not $state) { $state = "NotProtected" }
                Write-Host "    [$dbIdx] $($db.properties.friendlyName) (Instance: $($db.properties.parentName), State: $state)" -ForegroundColor White
                $dbIdx++
            }
            Write-Host ""
            $dbChoice = Read-Host "  Enter number (default: 1)"
            if ([string]::IsNullOrWhiteSpace($dbChoice)) { $dbChoice = "1" }
            $dbSelectedIdx = [int]$dbChoice - 1
            if ($dbSelectedIdx -ge 0 -and $dbSelectedIdx -lt $hanaDatabases.Count) {
                $matchingDB = $hanaDatabases[$dbSelectedIdx]
            } else {
                Write-Host "  Invalid selection. Using first database." -ForegroundColor Yellow
                $matchingDB = $hanaDatabases[0]
            }
            if ($matchingDB -is [array]) { $matchingDB = $matchingDB[0] }
            $dbName = $matchingDB.properties.friendlyName

            Write-Host ""
            Write-Host "  Selected database: $dbName" -ForegroundColor Green
            Write-Host "    Parent Instance: $($matchingDB.properties.parentName)" -ForegroundColor Gray
            Write-Host "    Server Name:     $($matchingDB.properties.serverName)" -ForegroundColor Gray
            Write-Host "    Protection State:$($matchingDB.properties.protectionState)" -ForegroundColor Gray
            Write-Host "    Item Name:       $($matchingDB.name)" -ForegroundColor Gray
        } else {
            # DatabaseName was provided - find it in the list
            $matchingDB = $hanaDatabases | Where-Object {
                $_.properties.friendlyName -eq $dbName
            }

            if (-not $matchingDB) {
                # Try case-insensitive match
                $matchingDB = $hanaDatabases | Where-Object {
                    $_.properties.friendlyName -ieq $dbName
                }
            }

            if ($matchingDB) {
                if ($matchingDB -is [array]) { $matchingDB = $matchingDB[0] }

                Write-Host "  Target database found:" -ForegroundColor Green
                Write-Host "    Friendly Name:   $($matchingDB.properties.friendlyName)" -ForegroundColor Gray
                Write-Host "    Parent Instance: $($matchingDB.properties.parentName)" -ForegroundColor Gray
                Write-Host "    Server Name:     $($matchingDB.properties.serverName)" -ForegroundColor Gray
                Write-Host "    Protection State:$($matchingDB.properties.protectionState)" -ForegroundColor Gray
                Write-Host "    Item Name:       $($matchingDB.name)" -ForegroundColor Gray
            } else {
                Write-Host "  WARNING: Database '$dbName' not found in protectable items." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Available HANA databases on this VM:" -ForegroundColor Yellow
                foreach ($db in $hanaDatabases) {
                    Write-Host "    - $($db.properties.friendlyName)" -ForegroundColor White
                }
                Write-Host ""
                Write-Host "  This could mean:" -ForegroundColor Yellow
                Write-Host "    1. Database name is incorrect" -ForegroundColor White
                Write-Host "    2. Database is already protected" -ForegroundColor White
                Write-Host "    3. Inquiry hasn't completed yet" -ForegroundColor White
                Write-Host "    4. Pre-registration script hasn't been run on the VM" -ForegroundColor White
                Write-Host ""
                exit 1
            }
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: No protectable SAP HANA items discovered." -ForegroundColor Red
        Write-Host "  Ensure the pre-registration script has been run on the VM:" -ForegroundColor Yellow
        Write-Host "    https://aka.ms/scriptforlinuxhana" -ForegroundColor White
        Write-Host "  Also verify the HANA instance is running and the VM is started." -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to list protectable items: $($_.Exception.Message)" -ForegroundColor Red
    Write-ApiError -ErrorRecord $_ -Context "List protectable items"
    exit 1
}

# ============================================================================
# STEP 6: CHECK IF DATABASE IS ALREADY PROTECTED
# ============================================================================

Write-Host ""
Write-Host "STEP 6: Checking Existing Protection Status" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$isAlreadyProtected = $false

if ($matchingDB) {
    # Extract container and protected item name from the protectable item ID
    $dbItemId = $matchingDB.id
    $dbItemName = $matchingDB.name

    # Parse container name from the ID path
    $idParts = $dbItemId -split "/protectableItems/"
    $containerPath = $idParts[0]
    $containerFromId = ($containerPath -split "/protectionContainers/")[1]
    if (-not [string]::IsNullOrWhiteSpace($containerFromId)) {
        $containerName = $containerFromId
    }

    # Protected item name uses the database item name
    $protectedItemName = $dbItemName

    # Construct the protected item URI to check
    $protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersionProtection"

    try {
        Write-Host "Checking if database '$dbName' is already protected..." -ForegroundColor Cyan
        $protectedItemResponse = Invoke-RestMethod -Uri $protectedItemUri -Method GET -Headers $headers

        if ($protectedItemResponse -and $protectedItemResponse.properties) {
            $isAlreadyProtected = $true
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  DATABASE IS ALREADY PROTECTED!" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "Protected Item Details:" -ForegroundColor Cyan
            Write-Host "  Friendly Name:       $($protectedItemResponse.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Protection Status:   $($protectedItemResponse.properties.protectionStatus)" -ForegroundColor White
            Write-Host "  Protection State:    $($protectedItemResponse.properties.protectionState)" -ForegroundColor White
            Write-Host "  Health Status:       $($protectedItemResponse.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Last Backup Status:  $($protectedItemResponse.properties.lastBackupStatus)" -ForegroundColor White
            Write-Host "  Last Backup Time:    $($protectedItemResponse.properties.lastBackupTime)" -ForegroundColor White
            Write-Host "  Policy Name:         $($protectedItemResponse.properties.policyName)" -ForegroundColor White
            Write-Host "  Workload Type:       $($protectedItemResponse.properties.workloadType)" -ForegroundColor White
            Write-Host "  Server Name:         $($protectedItemResponse.properties.serverName)" -ForegroundColor White
            Write-Host "  Parent Name:         $($protectedItemResponse.properties.parentName)" -ForegroundColor White
            Write-Host ""
            Write-Host "No further action needed. The database is already protected." -ForegroundColor Yellow
            Write-Host ""
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Host "  Database is not currently protected - eligible for backup configuration" -ForegroundColor Green
        } else {
            Write-Host "  Could not determine protection status (HTTP $statusCode)" -ForegroundColor Yellow
            Write-Host "  Proceeding with protection setup..." -ForegroundColor Yellow
        }
    }
}

# ============================================================================
# STEP 7: LIST AVAILABLE BACKUP POLICIES
# ============================================================================

if (-not $isAlreadyProtected) {
    Write-Host ""
    Write-Host "STEP 7: Listing Available Backup Policies" -ForegroundColor Yellow
    Write-Host "--------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $policiesUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies?api-version=$apiVersionProtection&`$filter=backupManagementType eq 'AzureWorkload'"

    $selectedPolicyId = $null
    $selectedPolicyName = $null

    # If PolicyName was provided via parameter, use it directly
    if (-not [string]::IsNullOrWhiteSpace($PolicyName)) {
        Write-Host "Using policy specified via -PolicyName parameter: $PolicyName" -ForegroundColor Cyan

        # Verify the policy exists
        $policyCheckUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$PolicyName`?api-version=$apiVersionProtection"

        try {
            $policyCheckResponse = Invoke-RestMethod -Uri $policyCheckUri -Method GET -Headers $headers
            $selectedPolicyId = $policyCheckResponse.id
            $selectedPolicyName = $policyCheckResponse.name
            Write-Host "  Policy verified: $selectedPolicyName" -ForegroundColor Green
            Write-Host "    Management Type: $($policyCheckResponse.properties.backupManagementType)" -ForegroundColor Gray
            Write-Host "    Workload Type:   $($policyCheckResponse.properties.workloadType)" -ForegroundColor Gray
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 404) {
                Write-Host "  ERROR: Policy '$PolicyName' not found in vault '$vaultName'." -ForegroundColor Red
                Write-Host "  Please check the policy name and try again." -ForegroundColor Yellow
                exit 1
            } else {
                Write-Host "  WARNING: Could not verify policy (HTTP $statusCode). Using provided name." -ForegroundColor Yellow
                $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$PolicyName"
                $selectedPolicyName = $PolicyName
            }
        }
    } else {
        # No PolicyName parameter - list policies and prompt for selection
        try {
            Write-Host "Querying for SAP HANA backup policies (AzureWorkload)..." -ForegroundColor Cyan
            $policiesResponse = Invoke-RestMethod -Uri $policiesUri -Method GET -Headers $headers

            # Filter to HANA-compatible policies (workloadType = SAPHanaDatabase or generic AzureWorkload)
            $hanaPolicies = $policiesResponse.value | Where-Object {
                $_.properties.workloadType -eq "SAPHanaDatabase" -or
                $_.properties.workloadType -eq "AzureWorkload"
            }

            if ($hanaPolicies -and $hanaPolicies.Count -gt 0) {
                Write-Host "  Found $($hanaPolicies.Count) SAP HANA backup policy(ies):" -ForegroundColor Green
                Write-Host ""

                $policyIndex = 1
                foreach ($policy in $hanaPolicies) {
                    Write-Host "  [$policyIndex] $($policy.name)" -ForegroundColor White
                    Write-Host "       Management Type: $($policy.properties.backupManagementType)" -ForegroundColor Gray
                    Write-Host "       Workload Type:   $($policy.properties.workloadType)" -ForegroundColor Gray

                    if ($policy.properties.subProtectionPolicy) {
                        foreach ($subPolicy in $policy.properties.subProtectionPolicy) {
                            Write-Host "       Sub-Policy:      $($subPolicy.policyType) - Schedule: $($subPolicy.schedulePolicy.schedulePolicyType)" -ForegroundColor Gray
                        }
                    }
                    Write-Host "       ID: $($policy.id)" -ForegroundColor DarkGray
                    Write-Host ""
                    $policyIndex++
                }

                Write-Host "Select a backup policy (enter number, default: 1):" -ForegroundColor Cyan
                $policyChoice = Read-Host "  Policy selection"

                if ([string]::IsNullOrWhiteSpace($policyChoice)) {
                    $selectedPolicyId = $hanaPolicies[0].id
                    $selectedPolicyName = $hanaPolicies[0].name
                    Write-Host "  Using first available policy: $selectedPolicyName" -ForegroundColor Green
                } else {
                    $policyIdx = [int]$policyChoice - 1
                    if ($policyIdx -ge 0 -and $policyIdx -lt $hanaPolicies.Count) {
                        $selectedPolicyId = $hanaPolicies[$policyIdx].id
                        $selectedPolicyName = $hanaPolicies[$policyIdx].name
                        Write-Host "  Selected policy: $selectedPolicyName" -ForegroundColor Green
                    } else {
                        Write-Host "  Invalid selection. Using first available policy." -ForegroundColor Yellow
                        $selectedPolicyId = $hanaPolicies[0].id
                        $selectedPolicyName = $hanaPolicies[0].name
                    }
                }
            } else {
                Write-Host "  WARNING: No SAP HANA backup policies found in the vault." -ForegroundColor Yellow
                Write-Host "  You must create a HANA backup policy first in the Azure Portal." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Alternatively, enter a policy name to construct the ID:" -ForegroundColor Yellow
                $manualPolicyName = Read-Host "  Enter Policy Name"
                if ([string]::IsNullOrWhiteSpace($manualPolicyName)) {
                    Write-Host "ERROR: A backup policy is required. Use -PolicyName parameter or create a policy first." -ForegroundColor Red
                    exit 1
                }
                $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$manualPolicyName"
                $selectedPolicyName = $manualPolicyName
                Write-Host "  Using policy ID: $selectedPolicyId" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  WARNING: Failed to list policies: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Enter a policy name manually:" -ForegroundColor Yellow
            $manualPolicyName = Read-Host "  Enter Policy Name"
            if ([string]::IsNullOrWhiteSpace($manualPolicyName)) {
                Write-Host "ERROR: A backup policy is required. Use -PolicyName parameter or create a policy first." -ForegroundColor Red
                exit 1
            }
            $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$manualPolicyName"
            $selectedPolicyName = $manualPolicyName
        }
    }

    # ============================================================================
    # STEP 8: ENABLE DATABASE PROTECTION
    # ============================================================================

    if ($matchingDB) {
        Write-Host ""
        Write-Host "STEP 8: Enabling Backup Protection for SAP HANA Database" -ForegroundColor Yellow
        Write-Host "----------------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""

        Write-Host "Preparing protection request..." -ForegroundColor Cyan
        Write-Host "  Vault:              $vaultName" -ForegroundColor Gray
        Write-Host "  Virtual Machine:    $vmName" -ForegroundColor Gray
        Write-Host "  Database:           $dbName" -ForegroundColor Gray
        Write-Host "  Container Name:     $containerName" -ForegroundColor Gray
        Write-Host "  Protected Item:     $protectedItemName" -ForegroundColor Gray
        Write-Host "  Policy:             $selectedPolicyName" -ForegroundColor Gray
        Write-Host ""

        # Enable protection URI (PUT)
        $enableProtectionUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersionProtection"

        $protectionBody = @{
            properties = @{
                backupManagementType = "AzureWorkload"
                workloadType         = "SAPHanaDatabase"
                policyId             = $selectedPolicyId
            }
        } | ConvertTo-Json -Depth 10

        Write-Host "Submitting protection request..." -ForegroundColor Cyan

        try {
            $protectionResponse = Invoke-WebRequest -Uri $enableProtectionUri -Method PUT -Headers $headers -Body $protectionBody -UseBasicParsing
            $statusCode = $protectionResponse.StatusCode

            if ($statusCode -eq 200) {
                $responseBody = $protectionResponse.Content | ConvertFrom-Json
                Write-Host ""
                Write-Host "==========================================================" -ForegroundColor Green
                Write-Host "  SAP HANA DATABASE PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                Write-Host "==========================================================" -ForegroundColor Green
                Write-Host ""
                Write-Host "Protected Item Details:" -ForegroundColor Cyan
                Write-Host "  Friendly Name:       $($responseBody.properties.friendlyName)" -ForegroundColor White
                Write-Host "  Protection State:    $($responseBody.properties.protectionState)" -ForegroundColor White
                Write-Host "  Health Status:       $($responseBody.properties.healthStatus)" -ForegroundColor White
                Write-Host "  Workload Type:       $($responseBody.properties.workloadType)" -ForegroundColor White
                Write-Host "  Policy Name:         $($responseBody.properties.policyName)" -ForegroundColor White
                Write-Host ""
            } elseif ($statusCode -eq 202) {
                Write-Host "  Protection request accepted (202). Tracking..." -ForegroundColor Green

                $asyncUrl = $protectionResponse.Headers["Azure-AsyncOperation"]
                $locationUrl = $protectionResponse.Headers["Location"]
                $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

                if ($trackingUrl) {
                    $maxRetries = 30
                    $retryCount = 0
                    $operationCompleted = $false

                    while (-not $operationCompleted -and $retryCount -lt $maxRetries) {
                        Start-Sleep -Seconds 10

                        try {
                            $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $headers

                            $opStatus = $null
                            if ($opResponse.status) { $opStatus = $opResponse.status }
                            elseif ($opResponse.properties.protectionState) { $opStatus = $opResponse.properties.protectionState }

                            if ($opStatus -eq "Succeeded" -or $opStatus -eq "Protected" -or $opStatus -eq "IRPending") {
                                $operationCompleted = $true
                                Write-Host ""
                                Write-Host "==========================================================" -ForegroundColor Green
                                Write-Host "  SAP HANA DATABASE PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                                Write-Host "==========================================================" -ForegroundColor Green
                                Write-Host ""

                                if ($opResponse.properties) {
                                    Write-Host "Protected Item Details:" -ForegroundColor Cyan
                                    Write-Host "  Friendly Name:       $($opResponse.properties.friendlyName)" -ForegroundColor White
                                    Write-Host "  Protection State:    $($opResponse.properties.protectionState)" -ForegroundColor White
                                    Write-Host "  Health Status:       $($opResponse.properties.healthStatus)" -ForegroundColor White
                                    Write-Host "  Workload Type:       $($opResponse.properties.workloadType)" -ForegroundColor White
                                    Write-Host "  Policy Name:         $($opResponse.properties.policyName)" -ForegroundColor White
                                }
                                Write-Host ""
                            } else {
                                $retryCount++
                                Write-Host "  Waiting for protection... ($retryCount/$maxRetries) [Status: $opStatus]" -ForegroundColor Yellow
                            }
                        } catch {
                            $retryCount++
                            Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                        }
                    }

                    if (-not $operationCompleted) {
                        Write-Host ""
                        Write-Host "  Protection operation is taking longer than expected." -ForegroundColor Yellow
                        Write-Host "  Please check the Azure Portal to verify status." -ForegroundColor Yellow
                        Write-Host ""
                    }
                } else {
                    Write-Host "  Protection in progress (no tracking URL). Check Azure Portal." -ForegroundColor Yellow
                }
            }
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__

            if ($statusCode -eq 202) {
                Write-Host "  Protection request accepted (202)." -ForegroundColor Green

                try {
                    $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
                    $locationUrl = $_.Exception.Response.Headers["Location"]
                    $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

                    if ($trackingUrl) {
                        $maxRetries = 30
                        $retryCount = 0
                        $operationCompleted = $false

                        while (-not $operationCompleted -and $retryCount -lt $maxRetries) {
                            Start-Sleep -Seconds 10

                            try {
                                $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $headers

                                $opStatus = $null
                                if ($opResponse.status) { $opStatus = $opResponse.status }
                                elseif ($opResponse.properties.protectionState) { $opStatus = $opResponse.properties.protectionState }

                                if ($opStatus -eq "Succeeded" -or $opStatus -eq "Protected" -or $opStatus -eq "IRPending") {
                                    $operationCompleted = $true
                                    Write-Host ""
                                    Write-Host "==========================================================" -ForegroundColor Green
                                    Write-Host "  SAP HANA DATABASE PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                                    Write-Host "==========================================================" -ForegroundColor Green
                                    Write-Host ""
                                } else {
                                    $retryCount++
                                    Write-Host "  Waiting... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                                }
                            } catch {
                                $retryCount++
                                Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                            }
                        }
                    } else {
                        Write-Host "  Protection submitted. Check Azure Portal for status." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  Protection submitted. Check Azure Portal." -ForegroundColor Yellow
                }
            } else {
                Write-Host ""
                Write-Host "ERROR: Failed to enable SAP HANA database protection." -ForegroundColor Red
                Write-ApiError -ErrorRecord $_ -Context "Enable Protection"
                Write-Host ""
                Write-Host "Possible causes:" -ForegroundColor Yellow
                Write-Host "  1. Database is already protected by another vault" -ForegroundColor White
                Write-Host "  2. Insufficient permissions on the VM or vault" -ForegroundColor White
                Write-Host "  3. The backup policy is invalid or doesn't support HANA workloads" -ForegroundColor White
                Write-Host "  4. Pre-registration script has not been run on the VM" -ForegroundColor White
                Write-Host "  5. VM is deallocated" -ForegroundColor White
                Write-Host "  6. HANA instance is not running" -ForegroundColor White
                Write-Host ""
                exit 1
            }
        }

        # ============================================================================
        # POST-PROTECTION: VERIFY AND DISPLAY SUMMARY
        # ============================================================================

        Write-Host ""
        Write-Host "VERIFICATION: Confirming Protection" -ForegroundColor Yellow
        Write-Host "-------------------------------------" -ForegroundColor Yellow
        Write-Host ""

        Start-Sleep -Seconds 5

        try {
            Write-Host "Verifying protected item status..." -ForegroundColor Cyan
            $verifyResponse = Invoke-RestMethod -Uri $enableProtectionUri -Method GET -Headers $headers

            if ($verifyResponse -and $verifyResponse.properties) {
                Write-Host ""
                Write-Host "SAP HANA Database Protection Summary:" -ForegroundColor Cyan
                Write-Host "  Database Name:       $($verifyResponse.properties.friendlyName)" -ForegroundColor White
                Write-Host "  Server Name:         $($verifyResponse.properties.serverName)" -ForegroundColor White
                Write-Host "  Parent Instance:     $($verifyResponse.properties.parentName)" -ForegroundColor White
                Write-Host "  Protection Status:   $($verifyResponse.properties.protectionStatus)" -ForegroundColor White
                Write-Host "  Protection State:    $($verifyResponse.properties.protectionState)" -ForegroundColor White
                Write-Host "  Health Status:       $($verifyResponse.properties.healthStatus)" -ForegroundColor White
                Write-Host "  Last Backup Status:  $($verifyResponse.properties.lastBackupStatus)" -ForegroundColor White
                Write-Host "  Last Backup Time:    $($verifyResponse.properties.lastBackupTime)" -ForegroundColor White
                Write-Host "  Policy Name:         $($verifyResponse.properties.policyName)" -ForegroundColor White
                Write-Host "  Workload Type:       $($verifyResponse.properties.workloadType)" -ForegroundColor White
                Write-Host "  Container Name:      $($verifyResponse.properties.containerName)" -ForegroundColor White
                Write-Host ""
            }
        } catch {
            Write-Host "  Could not verify protection immediately." -ForegroundColor Yellow
            Write-Host "  Protection may still be initializing. Check the Azure Portal." -ForegroundColor Yellow
            Write-Host ""
        }
    }

    # ============================================================================
    # NEXT STEPS
    # ============================================================================

    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. The first backup will trigger according to the policy schedule" -ForegroundColor White
    Write-Host "  2. To trigger an on-demand backup, use the Azure Portal or REST API" -ForegroundColor White
    Write-Host "  3. Monitor backup jobs: Azure Portal > Recovery Services Vault > Backup Jobs" -ForegroundColor White
    Write-Host "  4. To protect additional databases, run this script again with a different -DatabaseName" -ForegroundColor White
    Write-Host ""
}

Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""
