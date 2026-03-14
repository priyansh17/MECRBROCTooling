<#
.SYNOPSIS
    Restores an Azure IaaS Virtual Machine from a Recovery Services Vault using REST API.

.DESCRIPTION
    This script performs restore operations for Azure VM backups using Azure Backup REST API.
    
    Restore Scenarios Supported:
    - Restore Disks: Restores managed disks + VM config JSON to a staging storage account.
                     User creates a VM from the restored disks afterward.
    - Replace Disks (Original Location): Replaces the current VM's disks with those from a
                     recovery point (in-place restore).
    - Restore as New VM (Alternate Location): Creates a new VM from the recovery point in a
                     specified target resource group, VNet, and subnet.
    
    The script flow:
    1. Authenticate (Bearer Token - Azure PowerShell or CLI)
    2. Verify the VM is a protected backup item in the vault
    3. List available recovery points and let user select one
    4. User selects restore scenario (Restore Disks / Replace Disks / New VM)
    5. Collect scenario-specific inputs (storage account, target RG, VNet, etc.)
    6. Trigger the restore operation and poll for completion
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on Vault, VM, Storage Account, and target resources
    - A staging storage account in the same region as the vault (for Restore Disks / New VM)

.NOTES
    Author: AFS Backup Expert
    Date: March 5, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-restoreazurevms
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-automation
    Reference: https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request (Bearer token auth header)
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2019-05-13"  # Azure Backup REST API version

# ============================================================================
# RUNTIME INPUT COLLECTION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Azure IaaS VM Restore Script (REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# SECTION 1: RECOVERY SERVICES VAULT INFORMATION
# ============================================================================

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

# ============================================================================
# SECTION 2: SOURCE (BACKED UP) VM INFORMATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 2: Source (Backed Up) VM Information" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Source VM Name:" -ForegroundColor Cyan
$sourceVMName = Read-Host "  Enter VM Name"
if ([string]::IsNullOrWhiteSpace($sourceVMName)) {
    Write-Host "ERROR: Source VM Name cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Source VM Resource Group Name:" -ForegroundColor Cyan
$sourceResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($sourceResourceGroup)) {
    Write-Host "ERROR: Source Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Source VM Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
$sourceSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($sourceSubscriptionId)) {
    $sourceSubscriptionId = $vaultSubscriptionId
    Write-Host "  Using vault subscription: $sourceSubscriptionId" -ForegroundColor Gray
}

# Construct Source VM Resource ID
$sourceResourceId = "/subscriptions/$sourceSubscriptionId/resourceGroups/$sourceResourceGroup/providers/Microsoft.Compute/virtualMachines/$sourceVMName"

# Construct Container and Protected Item Names
$containerName = "iaasvmcontainer;iaasvmcontainerv2;$sourceResourceGroup;$sourceVMName"
$protectedItemName = "vm;iaasvmcontainerv2;$sourceResourceGroup;$sourceVMName"

Write-Host ""
Write-Host "Constructed identifiers:" -ForegroundColor Gray
Write-Host "  Source Resource ID:   $sourceResourceId" -ForegroundColor Gray
Write-Host "  Container Name:       $containerName" -ForegroundColor Gray
Write-Host "  Protected Item Name:  $protectedItemName" -ForegroundColor Gray

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host ""
Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null
$authMethod = $null

# Try Azure PowerShell first
try {
    $tokenResult = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    # Az.Accounts >= 2.13.0 returns SecureString; older versions return plain string
    if ($tokenResult.Token -is [System.Security.SecureString]) {
        $token = $tokenResult.Token | ConvertFrom-SecureString -AsPlainText
    } else {
        $token = $tokenResult.Token
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

# Create common headers
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

# ============================================================================
# VERIFY PROTECTED ITEM EXISTS
# ============================================================================

Write-Host ""
Write-Host "Verifying protected VM in vault..." -ForegroundColor Cyan

$listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureIaasVM'"

try {
    Write-Host "  Searching for protected VMs in vault..." -ForegroundColor Cyan
    $protectedItemsResponse = Invoke-RestMethod -Uri $listProtectedItemsUri -Method GET -Headers $headers
    
    if ($protectedItemsResponse.value -and $protectedItemsResponse.value.Count -gt 0) {
        Write-Host "  Found $($protectedItemsResponse.value.Count) protected VM(s)" -ForegroundColor Green
        Write-Host ""
        
        # Find matching item by friendly name and source resource ID
        $matchingItem = $protectedItemsResponse.value | Where-Object {
            $_.properties.friendlyName -eq $sourceVMName
        }
        
        # Also try matching by sourceResourceId
        if (-not $matchingItem) {
            $matchingItem = $protectedItemsResponse.value | Where-Object {
                $_.properties.sourceResourceId -eq $sourceResourceId
            }
        }
        
        if ($matchingItem) {
            # Handle array
            if ($matchingItem -is [array]) { $matchingItem = $matchingItem[0] }
            
            # Extract actual container and protected item names from the ID
            if ($matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
                $containerName = $matches[1]
                $protectedItemName = $matches[2]
                
                Write-Host "Protected VM verified!" -ForegroundColor Green
                Write-Host "  Friendly Name:       $($matchingItem.properties.friendlyName)" -ForegroundColor Gray
                Write-Host "  Protection State:    $($matchingItem.properties.protectionState)" -ForegroundColor Gray
                Write-Host "  Last Backup Status:  $($matchingItem.properties.lastBackupStatus)" -ForegroundColor Gray
                Write-Host "  Last Backup Time:    $($matchingItem.properties.lastBackupTime)" -ForegroundColor Gray
                Write-Host "  Policy Name:         $($matchingItem.properties.policyName)" -ForegroundColor Gray
                Write-Host "  Container Name:      $containerName" -ForegroundColor Gray
                Write-Host "  Protected Item Name: $protectedItemName" -ForegroundColor Gray
                
                # Update sourceResourceId from the actual item if available
                if ($matchingItem.properties.sourceResourceId) {
                    $sourceResourceId = $matchingItem.properties.sourceResourceId
                }
            } else {
                Write-Host "WARNING: Could not parse container/item names from ID, using constructed names." -ForegroundColor Yellow
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: VM '$sourceVMName' not found in vault protection." -ForegroundColor Red
            Write-Host ""
            Write-Host "Available protected VMs:" -ForegroundColor Yellow
            foreach ($item in $protectedItemsResponse.value) {
                Write-Host "  - $($item.properties.friendlyName) (State: $($item.properties.protectionState))" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "Please verify:" -ForegroundColor Yellow
            Write-Host "  1. VM name is correct" -ForegroundColor White
            Write-Host "  2. VM is backed up to this vault" -ForegroundColor White
            Write-Host "  3. Vault name, subscription, and resource group are correct" -ForegroundColor White
            exit 1
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: No protected VMs found in vault '$vaultName'" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "WARNING: Could not verify protected item (continuing with constructed names)" -ForegroundColor Yellow
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# SECTION 3: RECOVERY POINT SELECTION
# ============================================================================

Write-Host ""
Write-Host "SECTION 3: Recovery Point Selection" -ForegroundColor Yellow
Write-Host "-------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Fetching available recovery points..." -ForegroundColor Cyan

$recoveryPointsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName/recoveryPoints?api-version=$apiVersion"

$selectedRecoveryPoint = $null

try {
    $rpResponse = Invoke-RestMethod -Uri $recoveryPointsUri -Method GET -Headers $headers
    
    if ($rpResponse.value -and $rpResponse.value.Count -gt 0) {
        Write-Host "  Found $($rpResponse.value.Count) recovery point(s)" -ForegroundColor Green
        Write-Host ""
        
        Write-Host "Available Recovery Points:" -ForegroundColor Cyan
        Write-Host ""
        
        $index = 1
        foreach ($rp in $rpResponse.value) {
            $rpName = $rp.name
            $rpTime = $rp.properties.recoveryPointTime
            $rpType = $rp.properties.recoveryPointType
            $rpVMSize = $rp.properties.virtualMachineSize
            $rpIsManaged = $rp.properties.isManagedVirtualMachine
            $rpStorageType = $rp.properties.sourceVMStorageType
            $rpEncrypted = $rp.properties.isSourceVMEncrypted
            
            # Parse recovery point tier details
            $rpTiers = @()
            if ($rp.properties.recoveryPointTierDetails) {
                foreach ($tier in $rp.properties.recoveryPointTierDetails) {
                    $tierName = switch ($tier.type) { 1 { "InstantRP" } 2 { "HardenedRP" } 3 { "ArchivedRP" } default { "Unknown($($tier.type))" } }
                    $tierStatus = switch ($tier.status) { 1 { "Valid" } 2 { "Invalid" } 3 { "Deleted" } 4 { "Disabled" } default { "Unknown($($tier.status))" } }
                    $rpTiers += "$tierName=$tierStatus"
                }
            }
            $rpTierDisplay = if ($rpTiers.Count -gt 0) { $rpTiers -join ", " } else { "N/A" }

            Write-Host "  [$index] Recovery Point: $rpName" -ForegroundColor White
            Write-Host "      Time:         $rpTime" -ForegroundColor Gray
            Write-Host "      Type:         $rpType" -ForegroundColor Gray
            Write-Host "      Tier:         $rpTierDisplay" -ForegroundColor Gray
            Write-Host "      VM Size:      $rpVMSize" -ForegroundColor Gray
            Write-Host "      Managed:      $rpIsManaged" -ForegroundColor Gray
            Write-Host "      Storage Type: $rpStorageType" -ForegroundColor Gray
            Write-Host "      Encrypted:    $rpEncrypted" -ForegroundColor Gray
            Write-Host ""
            $index++
        }
        
        Write-Host "Select Recovery Point (enter number 1-$($rpResponse.value.Count)):" -ForegroundColor Cyan
        $rpChoice = Read-Host "  Enter choice"
        
        $rpIndex = [int]$rpChoice - 1
        
        if ($rpIndex -lt 0 -or $rpIndex -ge $rpResponse.value.Count) {
            Write-Host "ERROR: Invalid selection." -ForegroundColor Red
            exit 1
        }
        
        $selectedRecoveryPoint = $rpResponse.value[$rpIndex]
        $recoveryPointId = $selectedRecoveryPoint.name
        
        # Parse selected RP tier info
        $selectedRpTiers = @()
        if ($selectedRecoveryPoint.properties.recoveryPointTierDetails) {
            foreach ($tier in $selectedRecoveryPoint.properties.recoveryPointTierDetails) {
                $tierName = switch ($tier.type) { 1 { "InstantRP" } 2 { "HardenedRP" } 3 { "ArchivedRP" } default { "Unknown($($tier.type))" } }
                $tierStatus = switch ($tier.status) { 1 { "Valid" } 2 { "Invalid" } 3 { "Deleted" } 4 { "Disabled" } default { "Unknown($($tier.status))" } }
                $selectedRpTiers += "$tierName=$tierStatus"
            }
        }
        $selectedRpTierDisplay = if ($selectedRpTiers.Count -gt 0) { $selectedRpTiers -join ", " } else { "N/A" }

        Write-Host "  Selected Recovery Point: $recoveryPointId" -ForegroundColor Green
        Write-Host "  Recovery Time: $($selectedRecoveryPoint.properties.recoveryPointTime)" -ForegroundColor Green
        Write-Host "  Type: $($selectedRecoveryPoint.properties.recoveryPointType)" -ForegroundColor Green
        Write-Host "  Tier: $selectedRpTierDisplay" -ForegroundColor Green
    } else {
        Write-Host "ERROR: No recovery points found for this VM." -ForegroundColor Red
        Write-Host "       Ensure the VM is backed up and has available recovery points." -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host "ERROR: Failed to fetch recovery points." -ForegroundColor Red
    Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 4: RESTORE SCENARIO SELECTION
# ============================================================================

Write-Host ""
Write-Host "SECTION 4: Restore Scenario Selection" -ForegroundColor Yellow
Write-Host "---------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Select Restore Scenario:" -ForegroundColor Cyan
Write-Host "  1 = Restore Disks (restore managed disks + VM config to a storage account)" -ForegroundColor White
Write-Host "        - You create a VM from restored disks afterward" -ForegroundColor Gray
Write-Host "  2 = Replace Disks / Original Location (replace current VM's disks in-place)" -ForegroundColor White
Write-Host "        - Current VM's disks are swapped with recovery point disks" -ForegroundColor Gray
Write-Host "  3 = Restore as New VM / Alternate Location (create a new VM from backup)" -ForegroundColor White
Write-Host "        - A new VM is created in a target resource group, VNet, and subnet" -ForegroundColor Gray
Write-Host ""
$scenarioChoice = Read-Host "  Enter choice (1, 2, or 3)"

$recoveryType = $null

if ($scenarioChoice -eq "1") {
    $recoveryType = "RestoreDisks"
    Write-Host "  Selected: Restore Disks" -ForegroundColor Green
} elseif ($scenarioChoice -eq "2") {
    $recoveryType = "OriginalLocation"
    Write-Host "  Selected: Replace Disks (Original Location)" -ForegroundColor Green
} elseif ($scenarioChoice -eq "3") {
    $recoveryType = "AlternateLocation"
    Write-Host "  Selected: Restore as New VM (Alternate Location)" -ForegroundColor Green
} else {
    Write-Host "ERROR: Invalid choice. Must be 1, 2, or 3." -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 5: COLLECT SCENARIO-SPECIFIC INPUTS
# ============================================================================

Write-Host ""
Write-Host "SECTION 5: Restore Configuration" -ForegroundColor Yellow
Write-Host "----------------------------------" -ForegroundColor Yellow
Write-Host ""

# --- Common: Staging Storage Account (needed for all scenarios) ---

Write-Host "Staging Storage Account (same region as vault, for VM config/disk staging):" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Storage Account Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
$storageSubscriptionId = Read-Host "    Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($storageSubscriptionId)) {
    $storageSubscriptionId = $vaultSubscriptionId
    Write-Host "    Using vault subscription" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Storage Account Resource Group:" -ForegroundColor Cyan
$storageResourceGroup = Read-Host "    Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($storageResourceGroup)) {
    Write-Host "ERROR: Storage Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  Storage Account Name:" -ForegroundColor Cyan
$storageAccountName = Read-Host "    Enter Storage Account Name"
if ([string]::IsNullOrWhiteSpace($storageAccountName)) {
    Write-Host "ERROR: Storage Account Name cannot be empty." -ForegroundColor Red
    exit 1
}

$storageAccountId = "/subscriptions/$storageSubscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
Write-Host "  Storage Account ID: $storageAccountId" -ForegroundColor Gray

# --- Region ---

Write-Host ""
Write-Host "  Restore Region (e.g., eastus, westus, westeurope):" -ForegroundColor Cyan
$restoreRegion = Read-Host "    Enter Region"
if ([string]::IsNullOrWhiteSpace($restoreRegion)) {
    Write-Host "ERROR: Region cannot be empty." -ForegroundColor Red
    exit 1
}

# --- RestoreDisks: Optional target RG for managed disks ---

$targetResourceGroupId = $null

if ($recoveryType -eq "RestoreDisks") {
    Write-Host ""
    Write-Host "  Target Resource Group for Restored Managed Disks (optional):" -ForegroundColor Cyan
    Write-Host "  (Recommended for better performance. Leave empty to skip.)" -ForegroundColor Gray
    $targetRGForDisks = Read-Host "    Enter Target Resource Group Name"
    
    if (-not [string]::IsNullOrWhiteSpace($targetRGForDisks)) {
        Write-Host ""
        Write-Host "  Subscription for Target RG (press Enter if same as vault):" -ForegroundColor Cyan
        $targetRGSubId = Read-Host "    Enter Subscription ID"
        if ([string]::IsNullOrWhiteSpace($targetRGSubId)) {
            $targetRGSubId = $vaultSubscriptionId
        }
        $targetResourceGroupId = "/subscriptions/$targetRGSubId/resourceGroups/$targetRGForDisks"
        Write-Host "  Target RG ID: $targetResourceGroupId" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "  Datasource (Source VM) Region (e.g., eastus, westus):" -ForegroundColor Cyan
    Write-Host "  (Region where the original VM resides. Needed to detect cross-region restore.)" -ForegroundColor Gray
    $datasourceRegion = Read-Host "    Enter Datasource Region"
    if ([string]::IsNullOrWhiteSpace($datasourceRegion)) {
        Write-Host "ERROR: Datasource Region cannot be empty for Restore Disks." -ForegroundColor Red
        exit 1
    }
}

# --- OriginalLocation: Datasource region must match restore region ---

if ($recoveryType -eq "OriginalLocation") {
    Write-Host ""
    Write-Host "  Datasource (Source VM) Region (e.g., eastus, westus):" -ForegroundColor Cyan
    Write-Host "  (Region where the original VM resides. Must match the restore region for OLR.)" -ForegroundColor Gray
    $datasourceRegion = Read-Host "    Enter Datasource Region"
    if ([string]::IsNullOrWhiteSpace($datasourceRegion)) {
        Write-Host "ERROR: Datasource Region cannot be empty for Original Location restore." -ForegroundColor Red
        exit 1
    }
    if ($restoreRegion.ToLower() -ne $datasourceRegion.ToLower()) {
        Write-Host "" -ForegroundColor Red
        Write-Host "ERROR: Original Location restore requires the restore region to match the datasource region." -ForegroundColor Red
        Write-Host "  Restore Region:    $restoreRegion" -ForegroundColor Red
        Write-Host "  Datasource Region: $datasourceRegion" -ForegroundColor Red
        Write-Host "  OLR (Replace Disks) cannot be performed across regions." -ForegroundColor Red
        exit 1
    }
    Write-Host "  Region match confirmed: $restoreRegion" -ForegroundColor Green
}

# --- AlternateLocation: Target VM, RG, VNet, Subnet ---

$targetVMName = $null
$targetResourceGroupIdALR = $null
$targetVNetId = $null
$targetSubnetId = $null

if ($recoveryType -eq "AlternateLocation") {
    Write-Host ""
    Write-Host "  --- Alternate Location (New VM) Configuration ---" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "  Target VM Name:" -ForegroundColor Cyan
    $targetVMName = Read-Host "    Enter Target VM Name"
    if ([string]::IsNullOrWhiteSpace($targetVMName)) {
        Write-Host "ERROR: Target VM Name cannot be empty." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "  Target Resource Group Name:" -ForegroundColor Cyan
    $targetRGName = Read-Host "    Enter Target Resource Group Name"
    if ([string]::IsNullOrWhiteSpace($targetRGName)) {
        Write-Host "ERROR: Target Resource Group cannot be empty." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "  Target Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
    $targetSubId = Read-Host "    Enter Subscription ID"
    if ([string]::IsNullOrWhiteSpace($targetSubId)) {
        $targetSubId = $vaultSubscriptionId
    }
    
    $targetResourceGroupIdALR = "/subscriptions/$targetSubId/resourceGroups/$targetRGName"
    $targetVirtualMachineId = "/subscriptions/$targetSubId/resourceGroups/$targetRGName/providers/Microsoft.Compute/virtualMachines/$targetVMName"
    
    Write-Host ""
    Write-Host "  Target Virtual Network Name:" -ForegroundColor Cyan
    $targetVNetName = Read-Host "    Enter VNet Name"
    if ([string]::IsNullOrWhiteSpace($targetVNetName)) {
        Write-Host "ERROR: Target VNet Name cannot be empty." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "  Target VNet Resource Group (press Enter if same as Target RG):" -ForegroundColor Cyan
    $targetVNetRG = Read-Host "    Enter VNet Resource Group Name"
    if ([string]::IsNullOrWhiteSpace($targetVNetRG)) {
        $targetVNetRG = $targetRGName
    }
    
    $targetVNetId = "/subscriptions/$targetSubId/resourceGroups/$targetVNetRG/providers/Microsoft.Network/virtualNetworks/$targetVNetName"
    
    Write-Host ""
    Write-Host "  Target Subnet Name:" -ForegroundColor Cyan
    $targetSubnetName = Read-Host "    Enter Subnet Name"
    if ([string]::IsNullOrWhiteSpace($targetSubnetName)) {
        Write-Host "ERROR: Target Subnet Name cannot be empty." -ForegroundColor Red
        exit 1
    }
    
    $targetSubnetId = "$targetVNetId/subnets/$targetSubnetName"
    
    Write-Host ""
    Write-Host "  Datasource (Source VM) Region (e.g., eastus, westus):" -ForegroundColor Cyan
    Write-Host "  (Region where the original VM resides. Needed to detect cross-region restore.)" -ForegroundColor Gray
    $datasourceRegion = Read-Host "    Enter Datasource Region"
    if ([string]::IsNullOrWhiteSpace($datasourceRegion)) {
        Write-Host "ERROR: Datasource Region cannot be empty for Alternate Location restore." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "  Target Configuration:" -ForegroundColor Gray
    Write-Host "    VM Name:     $targetVMName" -ForegroundColor Gray
    Write-Host "    VM ID:       $targetVirtualMachineId" -ForegroundColor Gray
    Write-Host "    Target RG:   $targetResourceGroupIdALR" -ForegroundColor Gray
    Write-Host "    VNet:        $targetVNetId" -ForegroundColor Gray
    Write-Host "    Subnet:      $targetSubnetId" -ForegroundColor Gray
}

# ============================================================================
# SECTION 6: CONSTRUCT RESTORE REQUEST BODY
# ============================================================================

Write-Host ""
Write-Host "SECTION 6: Preparing Restore Request" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Base properties common to all scenarios
$requestProperties = @{
    objectType                 = "IaasVMRestoreRequest"
    recoveryPointId            = $recoveryPointId
    recoveryType               = $recoveryType
    sourceResourceId           = $sourceResourceId
    storageAccountId           = $storageAccountId
    region                     = $restoreRegion
    createNewCloudService      = $false
    originalStorageAccountOption = $false
    encryptionDetails          = @{
        encryptionEnabled = $false
    }
}

# Add scenario-specific properties
switch ($recoveryType) {
    "RestoreDisks" {
        if ($targetResourceGroupId) {
            $requestProperties.targetResourceGroupId = $targetResourceGroupId
        }
        # Cross-region RestoreDisks: if restore region differs from datasource region,
        # Snapshot/Instant RP tier is not available — force HardenedRP tier.
        if ($datasourceRegion -and $restoreRegion.ToLower() -ne $datasourceRegion.ToLower()) {
            Write-Host ""
            Write-Host "  NOTE: Cross-region restore detected." -ForegroundColor Yellow
            Write-Host "    Restore Region:  $restoreRegion" -ForegroundColor Yellow
            Write-Host "    Datasource VM Region:  $datasourceRegion" -ForegroundColor Yellow
            Write-Host "    Snapshot/Instant RP restore across regions is not allowed." -ForegroundColor Yellow
            Write-Host "    Setting preferredRecoveryPointTier = HardenedRP" -ForegroundColor Yellow
            Write-Host ""
            $requestProperties.preferredRecoveryPointTier = "HardenedRP"
        }
    }
    "OriginalLocation" {
        # No additional properties needed beyond base
        # Null out fields that should not be set
        $requestProperties.targetDomainNameId = $null
        $requestProperties.targetResourceGroupId = $null
        $requestProperties.targetVirtualMachineId = $null
        $requestProperties.virtualNetworkId = $null
        $requestProperties.subnetId = $null
        $requestProperties.diskEncryptionSetId = $null
        $requestProperties.affinityGroup = ""
    }
    "AlternateLocation" {
        $requestProperties.targetVirtualMachineId = $targetVirtualMachineId
        $requestProperties.targetResourceGroupId = $targetResourceGroupIdALR
        $requestProperties.virtualNetworkId = $targetVNetId
        $requestProperties.subnetId = $targetSubnetId
        
        # Cross-region ALR: if restore region differs from datasource region,
        # Snapshot/Instant RP tier is not available — force HardenedRP tier.
        if ($datasourceRegion -and $restoreRegion.ToLower() -ne $datasourceRegion.ToLower()) {
            Write-Host ""
            Write-Host "  NOTE: Cross-region restore detected." -ForegroundColor Yellow
            Write-Host "    Restore Region:  $restoreRegion" -ForegroundColor Yellow
            Write-Host "    Datasource VM Region:  $datasourceRegion" -ForegroundColor Yellow
            Write-Host "    Snapshot/Instant RP restore across regions is not allowed." -ForegroundColor Yellow
            Write-Host "    Setting preferredRecoveryPointTier = HardenedRP" -ForegroundColor Yellow
            Write-Host ""
            $requestProperties.preferredRecoveryPointTier = "HardenedRP"
        }
    }
}

$requestBody = @{
    properties = $requestProperties
} | ConvertTo-Json -Depth 10

# Display summary
Write-Host "Restore Request Summary:" -ForegroundColor Cyan
Write-Host "  Recovery Type:     $recoveryType" -ForegroundColor Gray
Write-Host "  Source VM:         $sourceVMName ($sourceResourceGroup)" -ForegroundColor Gray
Write-Host "  Recovery Point:    $recoveryPointId" -ForegroundColor Gray
Write-Host "  RP Time:           $($selectedRecoveryPoint.properties.recoveryPointTime)" -ForegroundColor Gray
Write-Host "  RP Type:           $($selectedRecoveryPoint.properties.recoveryPointType)" -ForegroundColor Gray
Write-Host "  Storage Account:   $storageAccountName" -ForegroundColor Gray
Write-Host "  Region:            $restoreRegion" -ForegroundColor Gray

switch ($recoveryType) {
    "RestoreDisks" {
        if ($targetResourceGroupId) {
            Write-Host "  Target RG (disks): $targetResourceGroupId" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "  After restore completes, create a VM from the restored disks using:" -ForegroundColor Yellow
        Write-Host "    1. The ARM deployment template in the staging storage account" -ForegroundColor White
        Write-Host "    2. Or manually using New-AzVM with the restored managed disks" -ForegroundColor White
    }
    "OriginalLocation" {
        Write-Host "  Action:            Replace disks of '$sourceVMName' in-place" -ForegroundColor Gray
    }
    "AlternateLocation" {
        Write-Host "  Target VM:         $targetVMName" -ForegroundColor Gray
        Write-Host "  Target RG:         $targetRGName" -ForegroundColor Gray
        Write-Host "  Target VNet:       $targetVNetName/$targetSubnetName" -ForegroundColor Gray
    }
}

# ============================================================================
# SECTION 7: TRIGGER RESTORE OPERATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 7: Trigger Restore Operation" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Construct Restore URI
$restoreUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName/recoveryPoints/$recoveryPointId/restore?api-version=$apiVersion"

Write-Host "Ready to trigger restore operation." -ForegroundColor Yellow
Write-Host ""

$warningMsg = switch ($recoveryType) {
    "RestoreDisks"      { "This will restore disks to the staging storage account." }
    "OriginalLocation"  { "This will REPLACE the current disks of VM '$sourceVMName'. The VM will be restarted." }
    "AlternateLocation" { "This will create a new VM '$targetVMName' in resource group '$targetRGName'." }
}

Write-Host "WARNING: $warningMsg" -ForegroundColor Yellow
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"

if ($confirm -ne "yes" -and $confirm -ne "YES" -and $confirm -ne "y" -and $confirm -ne "Y") {
    Write-Host "Restore operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Triggering restore operation..." -ForegroundColor Cyan

try {
    $restoreResponse = Invoke-WebRequest -Uri $restoreUri -Method POST -Headers $headers -Body $requestBody -UseBasicParsing
    
    if ($restoreResponse.StatusCode -eq 202) {
        Write-Host "  Restore operation accepted (HTTP 202)" -ForegroundColor Green
        Write-Host ""
        
        # Extract operation tracking URIs
        $azureAsyncHeader = $restoreResponse.Headers["Azure-AsyncOperation"]
        $locationHeader = $restoreResponse.Headers["Location"]
        $trackingUrl = if ($azureAsyncHeader) { $azureAsyncHeader } else { $locationHeader }
        
        if ($trackingUrl) {
            Write-Host "Tracking restore operation..." -ForegroundColor Cyan
            Write-Host ""
            
            $operationComplete = $false
            $maxRetries = 60  # VM restores can take a while (up to ~10 minutes)
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
                        Write-Host "  RESTORE JOB TRIGGERED SUCCESSFULLY!" -ForegroundColor Green
                        Write-Host "========================================" -ForegroundColor Green
                        Write-Host ""
                        
                        if ($statusResponse.properties.jobId) {
                            $jobId = $statusResponse.properties.jobId
                            Write-Host "  Restore Job ID: $jobId" -ForegroundColor Cyan
                        }
                        
                        Write-Host ""
                        
                        switch ($recoveryType) {
                            "RestoreDisks" {
                                Write-Host "  Restore job to restore disks has been submitted." -ForegroundColor White
                                Write-Host "  Track the restore job in Azure Portal:" -ForegroundColor White
                                Write-Host "    Recovery Services Vault -> '$vaultName' -> Backup Jobs" -ForegroundColor White
                                Write-Host ""
                                Write-Host "  Once the job completes:" -ForegroundColor Yellow
                                Write-Host "    1. Go to storage account '$storageAccountName'" -ForegroundColor White
                                Write-Host "    2. Find the VM config (VMConfig.json) in the blob container" -ForegroundColor White
                                Write-Host "    3. Use the ARM deployment template to create a new VM" -ForegroundColor White
                                Write-Host "       Or attach the restored managed disks manually" -ForegroundColor White
                                if ($targetResourceGroupId) {
                                    Write-Host "    4. Managed disks will be restored to: $targetResourceGroupId" -ForegroundColor White
                                }
                            }
                            "OriginalLocation" {
                                Write-Host "  Restore job to replace disks of VM '$sourceVMName' has been submitted." -ForegroundColor White
                                Write-Host "  Track the restore job in Azure Portal:" -ForegroundColor White
                                Write-Host "    Recovery Services Vault -> '$vaultName' -> Backup Jobs" -ForegroundColor White
                                Write-Host "  Once the job completes, the VM will be running with the restored disks." -ForegroundColor White
                            }
                            "AlternateLocation" {
                                Write-Host "  Restore job to create new VM '$targetVMName' in RG '$targetRGName' has been submitted." -ForegroundColor White
                                Write-Host "  Track the restore job in Azure Portal:" -ForegroundColor White
                                Write-Host "    Recovery Services Vault -> '$vaultName' -> Backup Jobs" -ForegroundColor White
                                Write-Host "  Once the job completes, the new VM will be available in the target resource group." -ForegroundColor White
                            }
                        }
                        
                    } elseif ($status -eq "Failed") {
                        $operationComplete = $true
                        Write-Host ""
                        Write-Host "========================================" -ForegroundColor Red
                        Write-Host "  RESTORE OPERATION FAILED!" -ForegroundColor Red
                        Write-Host "========================================" -ForegroundColor Red
                        Write-Host ""
                        
                        if ($statusResponse.error) {
                            Write-Host "Error Details:" -ForegroundColor Red
                            Write-Host "  Code:    $($statusResponse.error.code)" -ForegroundColor Red
                            Write-Host "  Message: $($statusResponse.error.message)" -ForegroundColor Red
                        }
                        
                        Write-Host ""
                        Write-Host "Possible causes:" -ForegroundColor Yellow
                        Write-Host "  1. Storage account is not in the same region as the vault" -ForegroundColor White
                        Write-Host "  2. Storage account is zone-redundant (not supported for staging)" -ForegroundColor White
                        Write-Host "  3. Insufficient permissions on target resources" -ForegroundColor White
                        Write-Host "  4. Target VNet/Subnet doesn't exist (for Alternate Location)" -ForegroundColor White
                        Write-Host "  5. Target VM name already exists (for Alternate Location)" -ForegroundColor White
                        Write-Host "  6. VM agent issue or disk encryption conflict" -ForegroundColor White
                        exit 1
                        
                    } elseif ($status -eq "InProgress") {
                        # Continue polling
                    } else {
                        Write-Host "    Unknown status: $status" -ForegroundColor Yellow
                    }
                } catch {
                    $retryCount++
                    Write-Host "  Warning: Failed to get operation status - retrying..." -ForegroundColor Yellow
                }
                
                $retryCount++
            }
            
            if (-not $operationComplete) {
                Write-Host ""
                Write-Host "  Restore operation is still in progress after $(($maxRetries * 15) / 60) minutes." -ForegroundColor Yellow
                Write-Host "  Please check the Azure Portal for final status:" -ForegroundColor Yellow
                Write-Host "    Recovery Services Vault -> '$vaultName' -> Backup Jobs" -ForegroundColor White
                Write-Host ""
            }
        } else {
            Write-Host "  Restore operation initiated. No tracking URL returned." -ForegroundColor Yellow
            Write-Host "  Monitor progress in Azure Portal -> Recovery Services Vault -> Backup Jobs" -ForegroundColor White
            Write-Host ""
        }
        
    } elseif ($restoreResponse.StatusCode -eq 200) {
        Write-Host "  Restore triggered and completed immediately (200 OK)" -ForegroundColor Green
        $responseBody = $restoreResponse.Content | ConvertFrom-Json
        if ($responseBody.properties.jobId) {
            Write-Host "  Job ID: $($responseBody.properties.jobId)" -ForegroundColor Cyan
        }
    } else {
        Write-Host "WARNING: Unexpected response code: $($restoreResponse.StatusCode)" -ForegroundColor Yellow
        Write-Host "Response: $($restoreResponse.Content)" -ForegroundColor Gray
    }
    
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        Write-Host "  Restore operation accepted (202)" -ForegroundColor Green
        Write-Host ""
        
        # Try to extract tracking URL from error response headers
        try {
            $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
            $locUrl = $_.Exception.Response.Headers["Location"]
            $trackUrl = if ($asyncUrl) { $asyncUrl } else { $locUrl }
            
            if ($trackUrl) {
                Write-Host "  Tracking restore operation..." -ForegroundColor Cyan
                
                $maxRetries = 60
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
                            Write-Host "========================================" -ForegroundColor Green
                            Write-Host "  RESTORE JOB TRIGGERED SUCCESSFULLY!" -ForegroundColor Green
                            Write-Host "========================================" -ForegroundColor Green
                            Write-Host ""
                            if ($opStatus.properties.jobId) {
                                Write-Host "  Restore Job ID: $($opStatus.properties.jobId)" -ForegroundColor Cyan
                            }
                            Write-Host "  Track the restore job in Azure Portal:" -ForegroundColor White
                            Write-Host "    Recovery Services Vault -> '$vaultName' -> Backup Jobs" -ForegroundColor White
                        } elseif ($st -eq "Failed") {
                            $opComplete = $true
                            Write-Host ""
                            Write-Host "  RESTORE OPERATION FAILED" -ForegroundColor Red
                            if ($opStatus.error) {
                                Write-Host "  Code:    $($opStatus.error.code)" -ForegroundColor Red
                                Write-Host "  Message: $($opStatus.error.message)" -ForegroundColor Red
                            }
                            exit 1
                        }
                    } catch {
                        # Continue polling
                    }
                    $retryCount++
                }
                
                if (-not $opComplete) {
                    Write-Host ""
                    Write-Host "  Restore is still in progress. Check Azure Portal." -ForegroundColor Yellow
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
        Write-Host "  Status Code: $statusCode" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        
        # Try to parse error response
        try {
            $errorStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorStream)
            $errorBody = $reader.ReadToEnd()
            $errorJson = $errorBody | ConvertFrom-Json
            
            Write-Host "Error Details:" -ForegroundColor Red
            Write-Host "  Code:    $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "  Message: $($errorJson.error.message)" -ForegroundColor Red
            Write-Host ""
        } catch {
            # Could not parse error response
        }
        
        Write-Host "Possible causes:" -ForegroundColor Yellow
        Write-Host "  1. Recovery point is invalid or expired" -ForegroundColor White
        Write-Host "  2. Storage account is not in the same region as the vault" -ForegroundColor White
        Write-Host "  3. Storage account is zone-redundant (ZRS not supported for staging)" -ForegroundColor White
        Write-Host "  4. Insufficient RBAC permissions" -ForegroundColor White
        Write-Host "  5. Container or protected item names are incorrect" -ForegroundColor White
        Write-Host "  6. VM is encrypted and key vault permissions are missing" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

# ============================================================================
# COMPLETION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  IaaS VM Restore Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
