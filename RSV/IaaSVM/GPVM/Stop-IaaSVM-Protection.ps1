<#
.SYNOPSIS
    Stops backup protection for an Azure IaaS VM while retaining existing backup data.

.DESCRIPTION
    This script stops backup protection for an Azure IaaS Virtual Machine in a Recovery
    Services Vault using Azure Backup REST API. Existing recovery points are retained.
    
    After stop-protection-with-retain-data:
    - No new backups will be taken for this VM.
    - All existing recovery points are preserved and can be used for restore.
    - The VM remains listed in the vault as a stopped-protection item.
    - Protection can be resumed later by re-associating a backup policy.
    
    The script flow:
    1. Authenticate (Bearer Token - Azure PowerShell or CLI)
    2. Verify the VM is currently protected in the vault
    3. Display current protection details (policy, last backup, health)
    4. Confirm the stop-protection operation with the user
    5. Submit the stop-protection request (PUT with empty policyId)
    6. Track the asynchronous operation to completion
    7. Verify the updated protection state
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - VM must be currently protected in the vault
    - Appropriate RBAC permissions on the Recovery Services Vault

.NOTES
    Author: AFS Backup Expert
    Date: March 13, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms#stop-protection-but-retain-existing-data
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update
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
Write-Host "  Stop Azure IaaS VM Backup Protection (Retain Data)" -ForegroundColor Cyan
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
# SECTION 2: VIRTUAL MACHINE INFORMATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 2: Virtual Machine Information" -ForegroundColor Yellow
Write-Host "---------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "VM Resource Group Name:" -ForegroundColor Cyan
$vmResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($vmResourceGroup)) {
    Write-Host "ERROR: VM Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Virtual Machine Name:" -ForegroundColor Cyan
$vmName = Read-Host "  Enter VM Name"
if ([string]::IsNullOrWhiteSpace($vmName)) {
    Write-Host "ERROR: VM Name cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "VM Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
$vmSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($vmSubscriptionId)) {
    $vmSubscriptionId = $vaultSubscriptionId
    Write-Host "  Using vault subscription: $vmSubscriptionId" -ForegroundColor Gray
}

# Construct VM Resource ID
$vmResourceId = "/subscriptions/$vmSubscriptionId/resourceGroups/$vmResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

# Construct container and protected item names (Resource Manager format)
$containerName = "iaasvmcontainer;iaasvmcontainerv2;$vmResourceGroup;$vmName"
$protectedItemName = "vm;iaasvmcontainerv2;$vmResourceGroup;$vmName"

Write-Host ""
Write-Host "Constructed identifiers:" -ForegroundColor Gray
Write-Host "  VM Resource ID:      $vmResourceId" -ForegroundColor Gray
Write-Host "  Container Name:      $containerName" -ForegroundColor Gray
Write-Host "  Protected Item Name: $protectedItemName" -ForegroundColor Gray

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
# STEP 1: VERIFY VM IS CURRENTLY PROTECTED
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Verifying VM Protection Status" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Searching for protected IaaS VMs in vault..." -ForegroundColor Cyan

$listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureIaasVM'"

$matchingItem = $null

try {
    $protectedItemsResponse = Invoke-RestMethod -Uri $listProtectedItemsUri -Method GET -Headers $headers
    
    if ($protectedItemsResponse.value -and $protectedItemsResponse.value.Count -gt 0) {
        Write-Host "  Found $($protectedItemsResponse.value.Count) protected VM(s)" -ForegroundColor Green
        Write-Host ""
        
        # Find matching item by friendly name and source resource ID
        $matchingItem = $protectedItemsResponse.value | Where-Object {
            $_.properties.friendlyName -eq $vmName -and
            $_.properties.sourceResourceId -eq $vmResourceId
        }
        
        # Also try matching by friendly name and resource group (case-insensitive)
        if (-not $matchingItem) {
            $matchingItem = $protectedItemsResponse.value | Where-Object {
                $_.properties.friendlyName -eq $vmName -and
                $_.properties.containerName -match $vmResourceGroup
            }
        }
        
        if ($matchingItem) {
            # Handle case where multiple matches (shouldn't happen, but be safe)
            if ($matchingItem -is [array]) {
                $matchingItem = $matchingItem[0]
            }
            
            # Extract actual container and protected item names from the ID
            if ($matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
                $containerName = $matches[1]
                $protectedItemName = $matches[2]
            }
            
            Write-Host "Protected VM found:" -ForegroundColor Green
            Write-Host "  VM Name:             $($matchingItem.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Protection State:    $($matchingItem.properties.protectionState)" -ForegroundColor White
            Write-Host "  Protection Status:   $($matchingItem.properties.protectionStatus)" -ForegroundColor White
            Write-Host "  Health Status:       $($matchingItem.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Last Backup Status:  $($matchingItem.properties.lastBackupStatus)" -ForegroundColor White
            Write-Host "  Last Backup Time:    $($matchingItem.properties.lastBackupTime)" -ForegroundColor White
            Write-Host "  Policy Name:         $($matchingItem.properties.policyName)" -ForegroundColor White
            Write-Host "  Workload Type:       $($matchingItem.properties.workloadType)" -ForegroundColor White
            Write-Host "  Container Name:      $containerName" -ForegroundColor Gray
            Write-Host "  Protected Item Name: $protectedItemName" -ForegroundColor Gray
            Write-Host ""
            
            # Check if already stopped
            if ($matchingItem.properties.protectionState -eq "ProtectionStopped") {
                Write-Host "WARNING: Protection is already stopped for this VM." -ForegroundColor Yellow
                Write-Host "  No action needed." -ForegroundColor Yellow
                Write-Host ""
                exit 0
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: VM '$vmName' in resource group '$vmResourceGroup' not found in vault protection." -ForegroundColor Red
            Write-Host ""
            Write-Host "Available protected VMs:" -ForegroundColor Yellow
            foreach ($item in $protectedItemsResponse.value) {
                Write-Host "  - $($item.properties.friendlyName) (RG: $($item.properties.containerName), State: $($item.properties.protectionState))" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "Please verify:" -ForegroundColor Yellow
            Write-Host "  1. VM name is correct" -ForegroundColor White
            Write-Host "  2. VM resource group name is correct" -ForegroundColor White
            Write-Host "  3. VM is backed up to this vault" -ForegroundColor White
            exit 1
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: No protected IaaS VMs found in vault '$vaultName'" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to query protected items." -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# STEP 2: CONFIRM STOP PROTECTION
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Confirm Stop Protection" -ForegroundColor Yellow
Write-Host "---------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "You are about to STOP BACKUP PROTECTION for:" -ForegroundColor Yellow
Write-Host "  Virtual Machine:  $vmName" -ForegroundColor White
Write-Host "  Resource Group:   $vmResourceGroup" -ForegroundColor White
Write-Host "  Vault:            $vaultName" -ForegroundColor White
Write-Host ""
Write-Host "  Action: Stop protection and RETAIN existing backup data." -ForegroundColor Yellow
Write-Host "  - No new backups will be taken." -ForegroundColor Gray
Write-Host "  - Existing recovery points will be preserved." -ForegroundColor Gray
Write-Host "  - Protection can be resumed later." -ForegroundColor Gray
Write-Host ""
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"

if ($confirm -ne "yes" -and $confirm -ne "YES" -and $confirm -ne "y" -and $confirm -ne "Y") {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# STEP 3: STOP PROTECTION (RETAIN DATA)
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Stopping Backup Protection" -ForegroundColor Yellow
Write-Host "------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Construct the protected item URI
# Per the REST API doc, semicolons in container/item names are part of the URL path
$protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersion"

# Request body per doc: protectedItemType + sourceResourceId + policyId empty string
# Setting policyId to "" removes the policy association and stops future backups
$stopProtectionBody = @{
    properties = @{
        protectionState = "ProtectionStopped"
        sourceResourceId  = $vmResourceId
    }
} | ConvertTo-Json -Depth 10

Write-Host "Submitting stop-protection request..." -ForegroundColor Cyan
Write-Host "  URI: $protectedItemUri" -ForegroundColor Gray
Write-Host ""

try {
    $stopResponse = Invoke-WebRequest -Uri $protectedItemUri -Method PUT -Headers $headers -Body $stopProtectionBody -UseBasicParsing
    $statusCode = $stopResponse.StatusCode
    
    if ($statusCode -eq 200) {
        Write-Host "  Stop-protection completed immediately (200 OK)!" -ForegroundColor Green
        
        $responseBody = $stopResponse.Content | ConvertFrom-Json
        
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  PROTECTION STOPPED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Updated Protected Item Details:" -ForegroundColor Cyan
        Write-Host "  VM Name:             $($responseBody.properties.friendlyName)" -ForegroundColor White
        Write-Host "  Protection State:    $($responseBody.properties.protectionState)" -ForegroundColor White
        Write-Host "  Health Status:       $($responseBody.properties.healthStatus)" -ForegroundColor White
        Write-Host "  Last Backup Status:  $($responseBody.properties.lastBackupStatus)" -ForegroundColor White
        Write-Host "  Last Backup Time:    $($responseBody.properties.lastBackupTime)" -ForegroundColor White
        Write-Host ""
        Write-Host "Backup data has been RETAINED." -ForegroundColor Yellow
        Write-Host "  - Existing recovery points are still available for restore." -ForegroundColor Gray
        Write-Host "  - No new backups will be taken." -ForegroundColor Gray
        Write-Host ""
    } elseif ($statusCode -eq 202) {
        Write-Host "  Stop-protection request accepted (202)" -ForegroundColor Green
        
        # Track operation via Azure-AsyncOperation or Location header
        $asyncUrl = $stopResponse.Headers["Azure-AsyncOperation"]
        $locationUrl = $stopResponse.Headers["Location"]
        $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
        
        if ($trackingUrl) {
            Write-Host "  Tracking operation status..." -ForegroundColor Cyan
            
            $maxRetries = 30
            $retryCount = 0
            $operationCompleted = $false
            
            while (-not $operationCompleted -and $retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 10
                
                try {
                    $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $headers
                    
                    $opStatus = $null
                    if ($opResponse.status) {
                        $opStatus = $opResponse.status
                    } elseif ($opResponse.properties.protectionState) {
                        $opStatus = $opResponse.properties.protectionState
                    }
                    
                    if ($opStatus -eq "Succeeded" -or $opStatus -eq "ProtectionStopped") {
                        $operationCompleted = $true
                        Write-Host ""
                        Write-Host "========================================" -ForegroundColor Green
                        Write-Host "  PROTECTION STOPPED SUCCESSFULLY!" -ForegroundColor Green
                        Write-Host "========================================" -ForegroundColor Green
                        Write-Host ""
                        
                        if ($opResponse.properties) {
                            Write-Host "Operation Details:" -ForegroundColor Cyan
                            Write-Host "  Status: $opStatus" -ForegroundColor White
                        }
                        Write-Host ""
                    } else {
                        $retryCount++
                        Write-Host "  Waiting for operation to complete... ($retryCount/$maxRetries) [Status: $opStatus]" -ForegroundColor Yellow
                    }
                } catch {
                    $retryCount++
                    Write-Host "  Polling operation... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                }
            }
            
            if (-not $operationCompleted) {
                Write-Host ""
                Write-Host "  Operation is taking longer than expected." -ForegroundColor Yellow
                Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
                Write-Host ""
            }
        } else {
            Write-Host "  Operation is in progress (no tracking URL available)." -ForegroundColor Yellow
            Write-Host "  Waiting for protection state to update..." -ForegroundColor Cyan
            Start-Sleep -Seconds 15
        }
        
        # Verify the updated status
        Write-Host ""
        Write-Host "Verifying updated protection status..." -ForegroundColor Cyan
        
        try {
            $verifyUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersion"
            $verifyResponse = Invoke-RestMethod -Uri $verifyUri -Method GET -Headers $headers
            
            Write-Host ""
            Write-Host "Updated Protected Item Details:" -ForegroundColor Cyan
            Write-Host "  VM Name:             $($verifyResponse.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Protection State:    $($verifyResponse.properties.protectionState)" -ForegroundColor White
            Write-Host "  Health Status:       $($verifyResponse.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Last Backup Status:  $($verifyResponse.properties.lastBackupStatus)" -ForegroundColor White
            Write-Host "  Last Backup Time:    $($verifyResponse.properties.lastBackupTime)" -ForegroundColor White
            Write-Host ""
            Write-Host "Backup data has been RETAINED." -ForegroundColor Yellow
            Write-Host "  - Existing recovery points are still available for restore." -ForegroundColor Gray
            Write-Host "  - No new backups will be taken." -ForegroundColor Gray
            Write-Host ""
        } catch {
            Write-Host "  Could not verify protection status immediately." -ForegroundColor Yellow
            Write-Host "  Please check the Azure Portal to confirm." -ForegroundColor Yellow
            Write-Host ""
        }
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        Write-Host "  Stop-protection request accepted (202)" -ForegroundColor Green
        Write-Host ""
        
        # Try to get tracking URL from exception response headers
        try {
            $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
            $locationUrl = $_.Exception.Response.Headers["Location"]
            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
            
            if ($trackingUrl) {
                Write-Host "  Tracking operation status..." -ForegroundColor Cyan
                
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
                        
                        if ($opStatus -eq "Succeeded" -or $opStatus -eq "ProtectionStopped") {
                            $operationCompleted = $true
                            Write-Host ""
                            Write-Host "========================================" -ForegroundColor Green
                            Write-Host "  PROTECTION STOPPED SUCCESSFULLY!" -ForegroundColor Green
                            Write-Host "========================================" -ForegroundColor Green
                            Write-Host ""
                        } else {
                            $retryCount++
                            Write-Host "  Waiting for operation... ($retryCount/$maxRetries) [Status: $opStatus]" -ForegroundColor Yellow
                        }
                    } catch {
                        $retryCount++
                        Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    }
                }
                
                if (-not $operationCompleted) {
                    Write-Host ""
                    Write-Host "  Operation is taking longer than expected." -ForegroundColor Yellow
                    Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
                    Write-Host ""
                }
            } else {
                Write-Host "  Operation is in progress." -ForegroundColor Yellow
                Start-Sleep -Seconds 15
            }
        } catch {
            Write-Host "  Operation submitted. Waiting before verification..." -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
        
        # Verify the updated status
        Write-Host ""
        Write-Host "Verifying updated protection status..." -ForegroundColor Cyan
        
        $maxVerifyRetries = 10
        $verifyRetryCount = 0
        $verified = $false
        
        while (-not $verified -and $verifyRetryCount -lt $maxVerifyRetries) {
            try {
                $verifyUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersion"
                $verifyResponse = Invoke-RestMethod -Uri $verifyUri -Method GET -Headers $headers
                
                if ($verifyResponse.properties.protectionState -eq "ProtectionStopped") {
                    $verified = $true
                    
                    Write-Host ""
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host "  PROTECTION STOPPED SUCCESSFULLY!" -ForegroundColor Green
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "Updated Protected Item Details:" -ForegroundColor Cyan
                    Write-Host "  VM Name:             $($verifyResponse.properties.friendlyName)" -ForegroundColor White
                    Write-Host "  Protection State:    $($verifyResponse.properties.protectionState)" -ForegroundColor White
                    Write-Host "  Health Status:       $($verifyResponse.properties.healthStatus)" -ForegroundColor White
                    Write-Host "  Last Backup Status:  $($verifyResponse.properties.lastBackupStatus)" -ForegroundColor White
                    Write-Host "  Last Backup Time:    $($verifyResponse.properties.lastBackupTime)" -ForegroundColor White
                    Write-Host ""
                    Write-Host "Backup data has been RETAINED." -ForegroundColor Yellow
                    Write-Host "  - Existing recovery points are still available for restore." -ForegroundColor Gray
                    Write-Host "  - No new backups will be taken." -ForegroundColor Gray
                    Write-Host ""
                } else {
                    $verifyRetryCount++
                    Write-Host "  Waiting... ($verifyRetryCount/$maxVerifyRetries) [State: $($verifyResponse.properties.protectionState)]" -ForegroundColor Yellow
                    Start-Sleep -Seconds 6
                }
            } catch {
                $verifyRetryCount++
                Write-Host "  Polling verification... ($verifyRetryCount/$maxVerifyRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds 6
            }
        }
        
        if (-not $verified) {
            Write-Host ""
            Write-Host "  Stop-protection submitted but verification timed out." -ForegroundColor Yellow
            Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: Failed to stop protection." -ForegroundColor Red
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
            Write-Host "  Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "  Message: $($errorJson.error.message)" -ForegroundColor Red
            Write-Host ""
        } catch {
            # Could not parse error response
        }
        
        Write-Host "Possible causes:" -ForegroundColor Yellow
        Write-Host "  1. VM is not currently protected in this vault" -ForegroundColor White
        Write-Host "  2. Insufficient RBAC permissions on the vault" -ForegroundColor White
        Write-Host "  3. Container or protected item names are incorrect" -ForegroundColor White
        Write-Host "  4. Vault is in a locked state" -ForegroundColor White
        Write-Host "  5. An ongoing backup or restore job is blocking the operation" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

# ============================================================================
# COMPLETION
# ============================================================================

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. To resume protection: re-assign a backup policy via REST API or Azure Portal" -ForegroundColor White
Write-Host "  2. To delete backup data: use Azure Portal > Vault > Backup Items > Stop backup > Delete data" -ForegroundColor White
Write-Host "  3. To restore from retained data: use the restore REST API or Azure Portal" -ForegroundColor White
Write-Host ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Stop IaaS VM Protection Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
