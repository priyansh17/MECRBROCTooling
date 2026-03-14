<#
.SYNOPSIS
    Enables backup protection for an Azure IaaS Virtual Machine in a Recovery Services Vault using REST API.

.DESCRIPTION
    This script enables backup protection for an Azure VM (IaaS VM) in a Recovery Services Vault
    using Azure Backup REST API.
    
    The script supports:
    - Cross-subscription scenarios (VM and Vault in different subscriptions)
    - Checking if the VM is already protected
    - Listing and selecting backup policies
    - Enabling protection with the selected policy
    
    The script flow:
    1. Authenticate (Bearer Token - Azure PowerShell or CLI)
    2. Check if the VM is already protected in the vault
    3. List available IaaS VM backup policies
    4. Enable backup protection with the selected policy
    5. Verify the final protection status
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on both the VM and Recovery Services Vault

.NOTES
    Author: AFS Backup Expert
    Date: March 4, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms
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
Write-Host "  Discover & Register IaaS VM to Recovery Services Vault" -ForegroundColor Cyan
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

Write-Host "VM Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
$vmSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($vmSubscriptionId)) {
    $vmSubscriptionId = $vaultSubscriptionId
    Write-Host "  Using vault subscription: $vmSubscriptionId" -ForegroundColor Gray
}

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

# Construct VM Resource ID
$vmResourceId = "/subscriptions/$vmSubscriptionId/resourceGroups/$vmResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

Write-Host ""
Write-Host "VM Resource ID:" -ForegroundColor Gray
Write-Host "  $vmResourceId" -ForegroundColor Gray

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

# Construct container and protected item names using Resource Manager format
$containerName = "iaasvmcontainer;iaasvmcontainerv2;$vmResourceGroup;$vmName"
$protectedItemName = "vm;iaasvmcontainerv2;$vmResourceGroup;$vmName"

Write-Host ""
Write-Host "Backup item identifiers:" -ForegroundColor Gray
Write-Host "  Container Name:      $containerName" -ForegroundColor Gray
Write-Host "  Protected Item Name: $protectedItemName" -ForegroundColor Gray

# ============================================================================
# STEP 1: CHECK IF VM IS ALREADY PROTECTED
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Checking if VM is Already Protected" -ForegroundColor Yellow
Write-Host "---------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$isAlreadyProtected = $false

# Check protection status
$protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersion"

try {
    Write-Host "Checking for existing protection on '$vmName'..." -ForegroundColor Cyan
    $protectedItemResponse = Invoke-RestMethod -Uri $protectedItemUri -Method GET -Headers $headers
    
    if ($protectedItemResponse) {
        $isAlreadyProtected = $true
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  VM IS ALREADY PROTECTED!" -ForegroundColor Green
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
        Write-Host "  Container Name:      $($protectedItemResponse.properties.containerName)" -ForegroundColor White
        Write-Host "  Source Resource ID:  $($protectedItemResponse.properties.sourceResourceId)" -ForegroundColor White
        Write-Host ""
        Write-Host "No further action needed. The VM is already registered and protected." -ForegroundColor Yellow
        Write-Host ""
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 404) {
        Write-Host "  VM is not currently protected - eligible for backup configuration" -ForegroundColor Green
    } else {
        Write-Host "  Could not determine protection status (HTTP $statusCode)" -ForegroundColor Yellow
        Write-Host "  Proceeding with registration..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 2: LIST AVAILABLE BACKUP POLICIES
# ============================================================================

if (-not $isAlreadyProtected) {
    Write-Host ""
    Write-Host "STEP 2: Listing Available Backup Policies" -ForegroundColor Yellow
    Write-Host "-------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    
    $policiesUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureIaasVM'"
    
    $selectedPolicyId = $null
    
    try {
        Write-Host "Querying for IaaS VM backup policies..." -ForegroundColor Cyan
        $policiesResponse = Invoke-RestMethod -Uri $policiesUri -Method GET -Headers $headers
        
        if ($policiesResponse.value -and $policiesResponse.value.Count -gt 0) {
            Write-Host "  Found $($policiesResponse.value.Count) IaaS VM backup policy(ies):" -ForegroundColor Green
            Write-Host ""
            
            $policyIndex = 1
            foreach ($policy in $policiesResponse.value) {
                Write-Host "  [$policyIndex] $($policy.properties.backupManagementType) - $($policy.name)" -ForegroundColor White
                Write-Host "       Schedule: $($policy.properties.schedulePolicy.schedulePolicyType)" -ForegroundColor Gray
                Write-Host "       Retention: $($policy.properties.retentionPolicy.retentionPolicyType)" -ForegroundColor Gray
                Write-Host "       ID: $($policy.id)" -ForegroundColor Gray
                Write-Host ""
                $policyIndex++
            }
            
            Write-Host "Select a backup policy to assign (enter number, or press Enter for DefaultPolicy):" -ForegroundColor Cyan
            $policyChoice = Read-Host "  Policy selection"
            
            if ([string]::IsNullOrWhiteSpace($policyChoice)) {
                # Default: try to find DefaultPolicy
                $defaultPolicy = $policiesResponse.value | Where-Object { $_.name -eq "DefaultPolicy" }
                if ($defaultPolicy) {
                    $selectedPolicyId = $defaultPolicy.id
                    Write-Host "  Using DefaultPolicy" -ForegroundColor Green
                } else {
                    $selectedPolicyId = $policiesResponse.value[0].id
                    Write-Host "  Using first available policy: $($policiesResponse.value[0].name)" -ForegroundColor Green
                }
            } else {
                $policyIdx = [int]$policyChoice - 1
                if ($policyIdx -ge 0 -and $policyIdx -lt $policiesResponse.value.Count) {
                    $selectedPolicyId = $policiesResponse.value[$policyIdx].id
                    Write-Host "  Selected policy: $($policiesResponse.value[$policyIdx].name)" -ForegroundColor Green
                } else {
                    Write-Host "  Invalid selection. Using first available policy." -ForegroundColor Yellow
                    $selectedPolicyId = $policiesResponse.value[0].id
                }
            }
        } else {
            Write-Host "  WARNING: No IaaS VM backup policies found in the vault." -ForegroundColor Yellow
            Write-Host "  A DefaultPolicy is usually created automatically when the vault is created." -ForegroundColor Yellow
            Write-Host "  You may need to create a policy first in the Azure Portal." -ForegroundColor Yellow
            Write-Host ""
            
            # Construct default policy ID
            $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/DefaultPolicy"
            Write-Host "  Using assumed DefaultPolicy ID: $selectedPolicyId" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  WARNING: Failed to list policies: $($_.Exception.Message)" -ForegroundColor Yellow
        $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/DefaultPolicy"
        Write-Host "  Using assumed DefaultPolicy ID: $selectedPolicyId" -ForegroundColor Gray
    }

    # ============================================================================
    # STEP 3: ENABLE PROTECTION (Register VM for Backup)
    # ============================================================================

    Write-Host ""
    Write-Host "STEP 3: Enabling Backup Protection for VM" -ForegroundColor Yellow
    Write-Host "-------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Preparing protection request..." -ForegroundColor Cyan
    Write-Host "  Vault:            $vaultName" -ForegroundColor Gray
    Write-Host "  Virtual Machine:  $vmName" -ForegroundColor Gray
    Write-Host "  Resource Group:   $vmResourceGroup" -ForegroundColor Gray
    Write-Host "  Container Name:   $containerName" -ForegroundColor Gray
    Write-Host "  Protected Item:   $protectedItemName" -ForegroundColor Gray
    Write-Host "  Policy ID:        $selectedPolicyId" -ForegroundColor Gray
    Write-Host ""
    
    # Enable protection URI (PUT operation)
    $enableProtectionUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersion"
    
    # Request body for enabling protection
    $protectionBody = @{
        properties = @{
            protectedItemType = "Microsoft.Compute/virtualMachines"
            sourceResourceId  = $vmResourceId
            policyId          = $selectedPolicyId
        }
    } | ConvertTo-Json -Depth 10
    
    Write-Host "Submitting protection request..." -ForegroundColor Cyan
    
    try {
        $protectionResponse = Invoke-WebRequest -Uri $enableProtectionUri -Method PUT -Headers $headers -Body $protectionBody -UseBasicParsing
        $statusCode = $protectionResponse.StatusCode
        
        if ($statusCode -eq 200) {
            Write-Host "  Protection enabled successfully (200 OK)!" -ForegroundColor Green
            
            $responseBody = $protectionResponse.Content | ConvertFrom-Json
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  VM PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "Protected Item Details:" -ForegroundColor Cyan
            Write-Host "  Friendly Name:       $($responseBody.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Protection State:    $($responseBody.properties.protectionState)" -ForegroundColor White
            Write-Host "  Health Status:       $($responseBody.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Workload Type:       $($responseBody.properties.workloadType)" -ForegroundColor White
            Write-Host "  Policy Name:         $($responseBody.properties.policyName)" -ForegroundColor White
            Write-Host ""
        } elseif ($statusCode -eq 202) {
            Write-Host "  Protection request accepted (202)" -ForegroundColor Green
            
            # Track operation via Azure-AsyncOperation or Location header
            $asyncUrl = $protectionResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $protectionResponse.Headers["Location"]
            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
            
            if ($trackingUrl) {
                Write-Host "  Tracking protection operation..." -ForegroundColor Cyan
                
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
                        
                        if ($opStatus -eq "Succeeded" -or $opStatus -eq "Protected" -or $opStatus -eq "IRPending") {
                            $operationCompleted = $true
                            Write-Host ""
                            Write-Host "========================================" -ForegroundColor Green
                            Write-Host "  VM PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                            Write-Host "========================================" -ForegroundColor Green
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
                            Write-Host "  Waiting for protection to complete... ($retryCount/$maxRetries) [Status: $opStatus]" -ForegroundColor Yellow
                        }
                    } catch {
                        $retryCount++
                        Write-Host "  Polling operation... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    }
                }
                
                if (-not $operationCompleted) {
                    Write-Host ""
                    Write-Host "  Protection operation is taking longer than expected." -ForegroundColor Yellow
                    Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
                    Write-Host ""
                }
            } else {
                Write-Host "  Protection operation is in progress (no tracking URL available)." -ForegroundColor Yellow
                Write-Host "  Please check the Azure Portal to verify completion." -ForegroundColor Yellow
                Write-Host ""
            }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        
        if ($statusCode -eq 202) {
            Write-Host "  Protection request accepted (202)" -ForegroundColor Green
            Write-Host ""
            
            # Try to get tracking URL from headers
            try {
                $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
                $locationUrl = $_.Exception.Response.Headers["Location"]
                $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
                
                if ($trackingUrl) {
                    Write-Host "  Tracking protection operation..." -ForegroundColor Cyan
                    
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
                                Write-Host "========================================" -ForegroundColor Green
                                Write-Host "  VM PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                                Write-Host "========================================" -ForegroundColor Green
                                Write-Host ""
                                
                                if ($opResponse.properties) {
                                    Write-Host "Protected Item Details:" -ForegroundColor Cyan
                                    Write-Host "  Friendly Name:       $($opResponse.properties.friendlyName)" -ForegroundColor White
                                    Write-Host "  Protection State:    $($opResponse.properties.protectionState)" -ForegroundColor White
                                    Write-Host "  Health Status:       $($opResponse.properties.healthStatus)" -ForegroundColor White
                                    Write-Host "  Policy Name:         $($opResponse.properties.policyName)" -ForegroundColor White
                                }
                                Write-Host ""
                            } else {
                                $retryCount++
                                Write-Host "  Waiting for protection... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                            }
                        } catch {
                            $retryCount++
                            Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                        }
                    }
                    
                    if (-not $operationCompleted) {
                        Write-Host ""
                        Write-Host "  Protection is still in progress." -ForegroundColor Yellow
                        Write-Host "  Please check the Azure Portal to verify status." -ForegroundColor Yellow
                        Write-Host ""
                    }
                } else {
                    Write-Host "  Protection operation is in progress." -ForegroundColor Yellow
                    Write-Host "  Please check the Azure Portal to verify completion." -ForegroundColor Yellow
                    Write-Host ""
                }
            } catch {
                Write-Host "  Protection operation submitted. Check Azure Portal for status." -ForegroundColor Yellow
                Write-Host ""
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: Failed to enable VM protection" -ForegroundColor Red
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
            Write-Host "  1. VM is already protected by another vault" -ForegroundColor White
            Write-Host "  2. Insufficient permissions on the VM or vault" -ForegroundColor White
            Write-Host "  3. VM doesn't exist or resource ID is incorrect" -ForegroundColor White
            Write-Host "  4. The backup policy doesn't exist or is invalid" -ForegroundColor White
            Write-Host "  5. VM agent (Azure VM Agent) is not installed or not responding" -ForegroundColor White
            Write-Host "  6. VM is deallocated and discovery hasn't completed" -ForegroundColor White
            Write-Host ""
            exit 1
        }
    }
    
    # ============================================================================
    # POST-REGISTRATION: VERIFY AND DISPLAY SUMMARY
    # ============================================================================
    
    Write-Host ""
    Write-Host "VERIFICATION: Confirming Registration" -ForegroundColor Yellow
    Write-Host "--------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    
    Start-Sleep -Seconds 5
    
    try {
        Write-Host "Verifying protected item status..." -ForegroundColor Cyan
        $verifyResponse = Invoke-RestMethod -Uri $enableProtectionUri -Method GET -Headers $headers
        
        if ($verifyResponse -and $verifyResponse.properties) {
            Write-Host ""
            Write-Host "VM Protection Summary:" -ForegroundColor Cyan
            Write-Host "  VM Name:             $($verifyResponse.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Protection Status:   $($verifyResponse.properties.protectionStatus)" -ForegroundColor White
            Write-Host "  Protection State:    $($verifyResponse.properties.protectionState)" -ForegroundColor White
            Write-Host "  Health Status:       $($verifyResponse.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Last Backup Status:  $($verifyResponse.properties.lastBackupStatus)" -ForegroundColor White
            Write-Host "  Last Backup Time:    $($verifyResponse.properties.lastBackupTime)" -ForegroundColor White
            Write-Host "  Policy Name:         $($verifyResponse.properties.policyName)" -ForegroundColor White
            Write-Host "  Workload Type:       $($verifyResponse.properties.workloadType)" -ForegroundColor White
            Write-Host "  Container Name:      $($verifyResponse.properties.containerName)" -ForegroundColor White
            Write-Host "  Source Resource ID:  $($verifyResponse.properties.sourceResourceId)" -ForegroundColor White
            Write-Host ""
            
            Write-Host "Next Steps:" -ForegroundColor Yellow
            Write-Host "  1. The first backup will trigger according to the policy schedule" -ForegroundColor White
            Write-Host "  2. To trigger an on-demand backup, use the Trigger-Backup script or Azure Portal" -ForegroundColor White
            Write-Host "  3. Monitor backup jobs in the Azure Portal > Recovery Services Vault > Backup Jobs" -ForegroundColor White
            Write-Host ""
        }
    } catch {
        Write-Host "  Could not verify protection immediately." -ForegroundColor Yellow
        Write-Host "  Protection may still be initializing. Check the Azure Portal." -ForegroundColor Yellow
        Write-Host ""
    }
}

Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""
