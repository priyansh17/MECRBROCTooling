================================================================================
  Restore-IaaSVM-RestAPI.ps1 - README
================================================================================

DESCRIPTION
-----------
Restores an Azure IaaS Virtual Machine from a Recovery Services Vault using
the Azure Backup REST API. The script supports three restore scenarios and
walks through each step interactively.

Restore Scenarios:
  1. Restore Disks — Restores managed disks and VM config JSON to a staging
     storage account. You create a VM from the restored disks afterward.
  2. Replace Disks (Original Location) — Replaces the current VM's disks
     with those from a recovery point (in-place restore). The VM is restarted.
  3. Restore as New VM (Alternate Location) — Creates a new VM from the
     recovery point in a target resource group, VNet, and subnet.

Workflow:
  1. Authenticates via Bearer token (Azure PowerShell or CLI).
  2. Verifies the VM is a protected backup item in the vault.
  3. Lists available recovery points with tier details and lets user select one.
  4. User selects the restore scenario.
  5. Collects scenario-specific inputs (storage account, target RG, VNet, etc.).
  6. Constructs the IaasVMRestoreRequest body.
  7. Triggers the restore operation and polls for completion.

For cross-region Restore Disks and Alternate Location restores where the
restore region differs from the source VM region, the script automatically sets
preferredRecoveryPointTier = HardenedRP (Snapshot/Instant RP is not available
across regions).


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
- Backup Operator (or equivalent) on the Recovery Services Vault.
- Contributor on the staging Storage Account (all scenarios).
- Contributor on the target Resource Group, VNet, and Subnet
  (Alternate Location scenario).
- VM Contributor on the source VM (Original Location / Replace Disks scenario).


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Section 1 — Vault Information:
    - Vault Subscription ID
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 2 — Source (Backed Up) VM:
    - Source VM Name
    - Source VM Resource Group Name
    - Source VM Subscription ID   (press Enter to reuse vault subscription)

  Section 3 — Recovery Point Selection:
    - Lists all recovery points with Time, Type, Tier, VM Size, Managed,
      Storage Type, and Encrypted.
    - User picks a recovery point by number.

  Section 4 — Restore Scenario:
    - 1 = Restore Disks
    - 2 = Replace Disks (Original Location)
    - 3 = Restore as New VM (Alternate Location)

  Section 5 — Scenario-Specific Inputs:
    All scenarios:
      - Storage Account Subscription, Resource Group, and Name
      - Restore Region

    Restore Disks only:
      - Target Resource Group for restored managed disks (optional)
      - Datasource (Source VM) Region (for cross-region detection)

    Alternate Location only:
      - Target VM Name
      - Target Resource Group Name and Subscription
      - Target VNet Name and Resource Group
      - Target Subnet Name
      - Datasource (Source VM) Region (for cross-region detection)


API VERSION USED
----------------
  - 2019-05-13   All operations (protected items, recovery points, restore)


EXAMPLES
--------

Example 1 — Restore Disks
~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-IaaSVM-RestAPI.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     rg-backup-prod
    Vault Name:               rsv-prod-eastus
    Source VM Name:            vm-webapp-01
    Source VM Resource Group:  rg-app-prod
    Source VM Subscription:    (press Enter — same as vault)
    Recovery Point:            [1] (select from list)
    Restore Scenario:         1 (Restore Disks)
    Storage Account RG:       rg-storage-prod
    Storage Account Name:     stgrestore01
    Region:                   eastus
    Target RG for Disks:      rg-restored-disks
    Datasource Region:        eastus

  The script restores managed disks to rg-restored-disks and writes
  the VM config JSON (VMConfig.json) to storage account stgrestore01.
  After completion, create a VM using the ARM template in the blob
  container or attach the managed disks manually.


Example 2 — Replace Disks (Original Location)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-IaaSVM-RestAPI.ps1

  Prompts:
    (vault + source VM details as above)
    Recovery Point:            [3] (select from list)
    Restore Scenario:         2 (Replace Disks)
    Storage Account RG:       rg-storage-prod
    Storage Account Name:     stgrestore01
    Region:                   eastus

  The script replaces the current OS and data disks of vm-webapp-01
  with the disks from the selected recovery point. The VM is restarted.


Example 3 — Restore as New VM (Alternate Location, same region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-IaaSVM-RestAPI.ps1

  Prompts:
    (vault + source VM details as above)
    Recovery Point:            [2] (select from list)
    Restore Scenario:         3 (Alternate Location)
    Storage Account RG:       rg-storage-prod
    Storage Account Name:     stgrestore01
    Region:                   eastus
    Target VM Name:           vm-webapp-01-restored
    Target RG:                rg-restored-vms
    Target Subscription:      (press Enter — same as vault)
    Target VNet:              vnet-prod-eastus
    VNet Resource Group:      (press Enter — same as target RG)
    Target Subnet:            subnet-app
    Datasource Region:        eastus

  A new VM named vm-webapp-01-restored is created in rg-restored-vms
  using the selected recovery point.


Example 4 — Cross-region restore (VM in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-IaaSVM-RestAPI.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     rg-backup-swedencentral
    Vault Name:               rsv-dr-swedencentral
    Source VM Name:            vm-erp-01
    Source VM Resource Group:  rg-app-uaenorth
    Recovery Point:            [1] (select from list)
    Restore Scenario:         3 (Alternate Location)
    Storage Account RG:       rg-storage-swedencentral
    Storage Account Name:     stgrestoreswe01
    Region:                   swedencentral
    Target VM Name:           vm-erp-01-dr
    Target RG:                rg-dr-swedencentral
    Target VNet:              vnet-dr-swedencentral
    Target Subnet:            subnet-app
    Datasource Region:        uaenorth

  The script detects a cross-region restore (uaenorth -> swedencentral)
  and automatically sets preferredRecoveryPointTier = HardenedRP since
  Snapshot/Instant RP is not available across regions. The HardenedRP
  (vault-standard tier) data resides in the vault region swedencentral.


Example 5 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Restore-IaaSVM-RestAPI.ps1

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings, informational messages, and operation status updates
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, recovery point properties)
  - White:   Recovery point listings and next-step instructions
  - Red:     Errors

Recovery point listing shows for each point:
  - Time, Type, Tier (InstantRP/HardenedRP/ArchivedRP with status),
    VM Size, Managed, Storage Type, Encrypted

On success, the script displays:
  - RESTORE JOB TRIGGERED SUCCESSFULLY
  - Restore Job ID
  - Portal navigation path to track the job
  - Scenario-specific next steps

POINTS TO REMEMBER
------------------
    - Storage Account, VNET provided during resotre should be in target region.


ERROR HANDLING
--------------
Common issues and what the script reports:

  - VM not found in vault protection:
      Lists all protected VMs in the vault and suggests verification steps.

  - No recovery points found:
      Advises to ensure the VM is backed up and has available recovery points.

  - Restore operation fails:
      Shows HTTP status code, error code, and message. Lists possible causes
      (wrong region for storage account, ZRS not supported, insufficient RBAC,
      VNet/Subnet doesn't exist, target VM already exists, encryption conflicts).

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.

  - Operation timeout:
      Directs user to check Azure Portal > Recovery Services Vault > Backup Jobs.


PUBLIC DOCUMENTATION
--------------------
  Restore Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-restoreazurevms

  Restore Azure VMs with PowerShell (Az module approach):
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-automation

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Recovery Services - Backup Restores REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/restores

  IaasVMRestoreRequest Object Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/restores/trigger

================================================================================
