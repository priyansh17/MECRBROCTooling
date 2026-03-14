================================================================================
  Stop-IaaSVM-Protection.ps1 - README
================================================================================

DESCRIPTION
-----------
Stops backup protection for an Azure IaaS Virtual Machine in a Recovery
Services Vault using the Azure Backup REST API, while retaining all existing
backup data (recovery points).

After stop-protection-with-retain-data:
  - No new backups will be taken for the VM.
  - All existing recovery points are preserved and can be used for restore.
  - The VM remains listed in the vault as a stopped-protection item.
  - Protection can be resumed later by re-associating a backup policy.

Workflow:
  1. Authenticates to Azure (Bearer Token via Az PowerShell or CLI).
  2. Queries the vault for all protected IaaS VMs and locates the target VM.
  3. Displays current protection details (policy, last backup, health).
  4. Checks if protection is already stopped — exits early if so.
  5. Prompts for user confirmation before proceeding.
  6. Submits a PUT request with an empty policyId to remove the policy
     association (stop protection, retain data).
  7. Tracks the asynchronous operation to completion.
  8. Verifies the updated protection state is "ProtectionStopped".


WHERE TO RUN
------------
- Windows PowerShell 5.1 or PowerShell 7+ (Windows, macOS, or Linux).
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- The script is interactive (uses Read-Host prompts), so it must be run in a
  foreground terminal session — not as part of an automated pipeline.


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A — Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B — Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login

No other modules or packages are required. The script uses only built-in
PowerShell cmdlets (Invoke-RestMethod, Invoke-WebRequest, ConvertTo-Json)
alongside the Azure REST API.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Contributor (or equivalent) on the Recovery Services Vault.
- Reader (or equivalent) on the target Virtual Machine and its Resource Group.


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Section 1 — Vault Information:
    - Vault Subscription ID
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 2 — VM Information:
    - VM Resource Group Name
    - Virtual Machine Name
    - VM Subscription ID (press Enter if same as vault)

  Confirmation:
    - "yes" to proceed with stop-protection, any other value to cancel


API VERSIONS USED
-----------------
  - 2019-05-13   Protected item queries, stop-protection PUT request


REST API DETAILS
----------------
The script uses the "Stop protection but retain existing data" approach
documented by Microsoft. It sends a PUT request to update the protected item
with an empty policyId:

  PUT https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/
      {resourceGroupName}/providers/Microsoft.RecoveryServices/vaults/{vaultName}/
      backupFabrics/Azure/protectionContainers/{containerName}/protectedItems/
      {protectedItemName}?api-version=2019-05-13

  Request Body:
    {
      "properties": {
        "protectionState" = "ProtectionStopped",
        "sourceResourceId": "/subscriptions/.../Microsoft.Compute/virtualMachines/{vmName}",
      }
    }

Setting policyId to an empty string removes the policy association and stops
future backups while retaining all existing recovery points.


EXAMPLES
--------

Example 1 — Stop protection for a VM (same subscription as vault)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Stop-IaaSVM-Protection.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     rg-backup-prod
    Vault Name:               rsv-prod-eastus
    VM Resource Group:        rg-app-prod
    VM Name:                  vm-webapp-01
    VM Subscription ID:       (press Enter — same as vault)
    Continue? (yes/no):       yes

  The script locates vm-webapp-01 in the vault's protected items, removes
  the policy association, and confirms protection state is "ProtectionStopped".


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings, confirmations, and informational messages
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, URIs)
  - Red:     Errors
  - White:   Data values and next-step instructions

On success, a final summary shows:
  - VM Name, Protection State, Health Status
  - Last Backup Status, Last Backup Time
  - Confirmation that backup data has been RETAINED
  - Next steps (resume protection, delete data, or restore)


ERROR HANDLING
--------------
Common issues and what the script reports:

  - VM not found in protected items:
      Lists all protected VMs in the vault and suggests verifying the
      VM name, resource group, and that the VM is backed up to this vault.

  - No protected IaaS VMs in vault:
      Reports that no IaaS VMs are currently protected in the specified vault.

  - Stop-protection request fails:
      Shows HTTP status code and parsed error details. Lists possible causes
      (VM not protected, insufficient RBAC, incorrect names, vault locked,
      ongoing backup/restore job blocking the operation).

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.

  - Async operation timeout:
      Warns that the operation is taking longer than expected and advises
      checking the Azure Portal for current status.


POINTS TO REMEMBER
------------------
  - This script performs "Stop protection with retain data" — backup data is
    NOT deleted. To delete backup data, use the Azure Portal or the DELETE
    REST API endpoint separately.
  - If soft-delete is enabled on the vault, even a subsequent delete operation
    will retain data for 14 additional days before permanent purging.
  - Protection can be resumed at any time by re-associating a backup policy
    (PUT request with a valid policyId).
  - The script constructs container and protected item names in the format:
      containerName:     iaasvmcontainer;iaasvmcontainerv2;{resourceGroup};{vmName}
      protectedItemName: vm;iaasvmcontainerv2;{resourceGroup};{vmName}
    If the VM is found in the vault, actual names are extracted from the
    response to ensure accuracy.


PUBLIC DOCUMENTATION
--------------------
  Stop protection but retain existing data (REST API):
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms#stop-protection-but-retain-existing-data

  Back up Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms

  Protected Items - Create or Update (REST API Reference):
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Recovery Services Vaults REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/recoveryservices/

  Backup Protected Items REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items

================================================================================
