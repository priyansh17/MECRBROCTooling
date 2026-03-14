============================================================
  Register-SAPHanaVM-ToVault.ps1 - README
  SAP HANA on Azure Linux VM - Backup Registration & Protection
============================================================

OVERVIEW
--------
This PowerShell script discovers, registers, and configures backup protection
for SAP HANA databases running on Azure Linux VMs using the Azure Backup REST API.

It supports:
  - Discovery of VMs with SAP HANA workloads
  - Registration of the VM as a VMAppContainer with the Recovery Services Vault
  - Inquiry and enumeration of HANA instances and databases on the VM
  - Individual database protection with a selected backup policy
  - Detection of already-registered VMs and already-protected databases


PREREQUISITES
-------------
1. Azure Authentication
   - Azure PowerShell: Run "Connect-AzAccount" before executing the script
   - OR Azure CLI: Run "az login" before executing the script
   - The script will try Azure PowerShell first, then fall back to Azure CLI

2. Required Permissions (RBAC)
   - Backup Contributor role (or equivalent) on the Recovery Services Vault
   - Virtual Machine Contributor or Reader role on the SAP HANA VM
   - If using a custom role, ensure these permissions:
     * Microsoft.RecoveryServices/vaults/backupFabrics/refreshContainers/action
     * Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/read
     * Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/write
     * Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/inquire/action
     * Microsoft.RecoveryServices/vaults/backupProtectableItems/read
     * Microsoft.RecoveryServices/vaults/backupProtectedItems/read
     * Microsoft.RecoveryServices/vaults/backupProtectedItems/write
     * Microsoft.RecoveryServices/vaults/backupPolicies/read

3. SAP HANA Pre-Registration Script
   - The HANA backup pre-registration script MUST be run on the VM before
     executing this registration script.
   - Reference: https://learn.microsoft.com/en-us/azure/backup/tutorial-backup-sap-hana-db#what-the-pre-registration-script-does
   - The pre-registration script:
     * Installs required packages (e.g., compat-sap-c++-7, libatomic)
     * Creates hdbuserstore key for backup communication
     * Assigns necessary HANA DB privileges for backup
     * Sets up SAP HANA plugin
   - Download/run: https://aka.ms/scriptforlinuxhana

4. SAP HANA Instance Must Be Running
   - The HANA instance must be started for discovery to work

5. Recovery Services Vault
   - Must already exist in the target subscription/resource group
   - Must have at least one SAP HANA backup policy configured


PARAMETERS
----------
  -VaultSubscriptionId  [Required] Subscription ID of the Recovery Services Vault
  -VaultResourceGroup   [Required] Resource Group of the Recovery Services Vault
  -VaultName            [Required] Name of the Recovery Services Vault
  -VMResourceGroup      [Required] Resource Group of the SAP HANA VM
  -VMName               [Required] Name of the Azure VM hosting SAP HANA
  -DatabaseName         [Optional] Name of the specific HANA database to protect
                                   (e.g., SYSTEMDB, HXE, or a tenant DB name)
                                   If omitted, the script will list discovered DBs
                                   and prompt for selection.
  -PolicyName           [Optional] Name of the backup policy to assign.
                                   If omitted, available policies are listed for
                                   interactive selection.


USAGE EXAMPLES
--------------

1. Protect a single HANA database (interactive policy selection):

   .\Register-SAPHanaVM-ToVault.ps1 `
       -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
       -VaultResourceGroup "rg-vault" `
       -VaultName "myRecoveryVault" `
       -VMResourceGroup "rg-hana" `
       -VMName "hana-vm-01" `
       -DatabaseName "SYSTEMDB"


2. Protect a single database with a specific policy:

   .\Register-SAPHanaVM-ToVault.ps1 `
       -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
       -VaultResourceGroup "rg-vault" `
       -VaultName "myRecoveryVault" `
       -VMResourceGroup "rg-hana" `
       -VMName "hana-vm-01" `
       -DatabaseName "SYSTEMDB" `
       -PolicyName "HanaDaily30d"


3. Discover databases interactively (no -DatabaseName specified):

   .\Register-SAPHanaVM-ToVault.ps1 `
       -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
       -VaultResourceGroup "rg-vault" `
       -VaultName "myRecoveryVault" `
       -VMResourceGroup "rg-hana" `
       -VMName "hana-vm-01"

   The script will discover all HANA databases and prompt for selection.


4. Run fully interactively (PowerShell will prompt for all mandatory params):

   .\Register-SAPHanaVM-ToVault.ps1


SCRIPT FLOW (8 STEPS)
-----------------------
  Step 1: REFRESH CONTAINERS - Triggers discovery to find VMs with HANA workloads
  Step 2: LIST PROTECTABLE CONTAINERS - Lists VMs discovered with HANA databases
  Step 3: REGISTER VM - Registers the VM as VMAppContainer (skips if already done)
  Step 4: INQUIRE WORKLOADS - Discovers HANA instances and databases inside the VM
  Step 5: LIST PROTECTABLE ITEMS - Lists all HANA databases available for protection
  Step 6: CHECK EXISTING PROTECTION - Verifies if the DB is already protected
  Step 7: LIST POLICIES - Lists SAP HANA backup policies for selection
  Step 8: ENABLE PROTECTION - Enables backup protection on the selected database


API VERSIONS USED
-----------------
  - 2016-12-01  : Discovery, registration, container operations
  - 2019-05-13  : Protection operations, policy listing, protection intent


AUTHENTICATION
--------------
The script supports two authentication methods:

  1. Azure PowerShell (preferred)
     - Run: Connect-AzAccount
     - The script uses: Get-AzAccessToken -ResourceUrl "https://management.azure.com"
     - Supports both old (plain string) and new (SecureString) Az.Accounts versions

  2. Azure CLI (fallback)
     - Run: az login
     - The script uses: az account get-access-token --resource https://management.azure.com


DIFFERENCES FROM SQL SERVER REGISTRATION
------------------------------------------
If you have used Register-SQLIaaSVM-ToVault.ps1, here are the key differences:

  - Workload Type: "SAPHanaDatabase" instead of "SQLDataBase"
  - Instance Type: "SAPHanaSystem" instead of "SQLInstance"
  - Auto-protection: Not supported for SAP HANA (supported for SQL Server only)
  - Pre-registration: Requires Linux pre-registration script instead of SQL IaaS Agent
  - Platform: Linux VMs only (SAP HANA runs on Linux)
  - Container type: VMAppContainer (same as SQL)
  - Discovery inquiry filter: workloadType eq 'SAPHanaDatabase'


TROUBLESHOOTING
---------------
1. "VM not found in protectable containers"
   - Ensure the VM is running and HANA instance is started
   - Verify the pre-registration script has been run
   - Check that the VM resource group and name are correct
   - Wait a few minutes after refresh and try again

2. "No SAP HANA databases found"
   - The pre-registration script may not have been run
   - HANA instance may not be running
   - Inquiry may not have completed - wait and retry

3. "401 Unauthorized"
   - Token may have expired. Re-run Connect-AzAccount or az login
   - Check RBAC permissions on both vault and VM

4. "Registration failed"
   - Verify pre-registration script was executed successfully
   - Check VM is running and reachable
   - Verify HANA instance is started
   - Check firewall/NSG rules allow communication

5. "Policy not found"
   - Ensure a SAP HANA backup policy exists in the vault
   - Policy must be of type "AzureWorkload" with workloadType "SAPHanaDatabase"
   - Create one via Azure Portal > Recovery Services Vault > Backup Policies

RELATED SCRIPTS
---------------
  - Register-SQLIaaSVM-ToVault.ps1     : SQL Server VM registration (same folder)
  - Unregister-SQLIaaSVM-FromVault.ps1  : SQL Server VM unregistration (same folder)
  - Restore-SAPHana-AlternateVM.ps1     : SAP HANA restore to alternate VM (Restore folder)
  - Register-IaaSVM-ToVault.ps1         : IaaS VM registration (parent folder)


REFERENCES
----------
  - SAP HANA backup overview:
    https://learn.microsoft.com/en-us/azure/backup/sap-hana-database-about
  - Tutorial - Back up SAP HANA databases:
    https://learn.microsoft.com/en-us/azure/backup/tutorial-backup-sap-hana-db
  - Pre-registration script:
    https://learn.microsoft.com/en-us/azure/backup/tutorial-backup-sap-hana-db#what-the-pre-registration-script-does
  - SAP HANA backup using PowerShell:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-sap-hana-db-powershell
  - REST API - Protection Containers:
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers
  - REST API - Protectable Items:
    https://learn.microsoft.com/en-us/rest/api/backup/backup-protectable-items
