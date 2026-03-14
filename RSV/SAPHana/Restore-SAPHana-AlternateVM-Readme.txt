================================================================================
  Restore-SAPHana-AlternateVM.ps1 - README
================================================================================

DESCRIPTION
-----------
Restores a SAP HANA database to an alternate VM (Alternate Location) from an
Azure Recovery Services Vault using the Azure Backup REST API.

The script supports two restore types:

  1. Point in Time (Log-based) restore:
       objectType:   AzureWorkloadSAPHanaPointInTimeRestoreRequest
       recoveryType: AlternateLocation

  2. Full / Differential backup restore:
       objectType:   AzureWorkloadSAPHanaRestoreRequest
       recoveryType: AlternateLocation

This is equivalent to the armclient-style restore:
  armclient POST ".../protectionContainers/{container}/protectedItems/{item}/recoveryPoints/{rpId}/restore?api-version=2024-04-01" @body.json


WORKFLOW
--------
  1. Prompts for Recovery Services Vault details (subscription, RG, vault name).
  2. Authenticates using Azure PowerShell (Connect-AzAccount) or Azure CLI (az login).
  3. Lists all protected SAP HANA databases in the vault — user selects the source DB.
  4. Asks the user to choose the restore type:
       [1] Point in Time (Log-based) — fetches available log time ranges and
           prompts for a specific UTC timestamp within those ranges.
       [2] Full / Differential — lists available recovery points and lets the
           user select one by number or enter an RP ID directly.
  5. Lists registered HANA containers in the vault — user selects the target container.
  6. Discovers SAP HANA SIDs on the target container via the workload items API
     and displays them to help with the target database name entry.
  7. Collects target database name (SID/dbName format) and overwrite option.
  8. Builds the restore request JSON body in memory (no file is written to disk).
  9. Triggers the restore via POST and polls for job completion.


WHERE TO RUN
------------
- Windows PowerShell 5.1 or PowerShell 7+ (Windows, macOS, or Linux).
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- The script is interactive (uses Read-Host), so it must run in a foreground
  terminal session — not as part of an automated pipeline.


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A — Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B — Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login

No other modules or packages are required. The script uses built-in
PowerShell cmdlets (Invoke-RestMethod, Invoke-WebRequest, ConvertTo-Json)
alongside the Azure Backup REST API.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Contributor (or equivalent) on the Recovery Services Vault.
- Reader (or equivalent) on the source VM / resource group.
- Backup Operator (or equivalent) on the target VM / container.


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Section 1 — Vault Information:
    - Vault Subscription ID
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 3 — Source DB Selection:
    - Choose from listed protected SAP HANA databases in the vault

  Section 4 — Recovery Point Selection:
    - Choose restore type: Point in Time (Log) or Full / Differential
    - If Point in Time: view available log time ranges and enter a UTC timestamp
    - If Full / Diff: choose from listed recovery points, or enter an RP ID directly

  Section 5 — Target Container & Database:
    - Choose from listed registered containers in the vault (or enter manually)
    - SID discovery: the script queries the target container for SAP HANA SIDs
      and displays them to assist with the database name entry
    - Target Database Name (format: SID/databaseName)
    - Overwrite Option (Overwrite / Failover)
    - Azure Region (e.g., eastasia, eastus)


REST API BODY FORMAT
--------------------
The script builds a JSON body in memory (not saved to disk). The format
depends on the chosen restore type:

  Full / Differential restore:
  {
    "properties": {
      "objectType": "AzureWorkloadSAPHanaRestoreRequest",
      "recoveryType": "AlternateLocation",
      "sourceResourceId": "/subscriptions/.../protectionContainers/.../protectedItems/...",
      "targetInfo": {
        "overwriteOption": "Overwrite",
        "containerId": "/subscriptions/.../protectionContainers/VMAppContainer;...",
        "databaseName": "ARV/restoretest01"
      }
    },
    "location": "eastasia"
  }

  Point in Time (Log) restore:
  {
    "properties": {
      "objectType": "AzureWorkloadSAPHanaPointInTimeRestoreRequest",
      "recoveryType": "AlternateLocation",
      "sourceResourceId": "/subscriptions/.../protectionContainers/.../protectedItems/...",
      "pointInTime": "2026-03-12T14:00:00.000Z",
      "targetInfo": {
        "overwriteOption": "Overwrite",
        "containerId": "/subscriptions/.../protectionContainers/VMAppContainer;...",
        "databaseName": "ARV/restoretest01"
      }
    },
    "location": "eastasia"
  }


API VERSIONS USED
-----------------
  - 2024-04-01   SAP HANA backup restore trigger, protected items, containers
  - 2023-02-01   Log recovery point time ranges (restorePointQueryType eq 'Log')
  - 2017-07-01   Workload items / SID discovery on target container


EXAMPLES
--------

Example 1 — Point in Time (Log) restore to alternate container
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SAPHana-AlternateVM.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     haaryRG
    Vault Name:               hanatier2vault
    Source DB:                 [1] arv/arv  (select from list)
    Restore Type:             1  (Point in Time)
    Available log ranges:
      [1] From: 2026-02-25 07:26:17 UTC  To: 2026-03-12 06:01:56 UTC
      [2] From: 2026-03-12 12:01:14 UTC  To: 2026-03-12 16:01:56 UTC
    Point-in-Time:            2026-03-12T14:00:00.000Z
    Target Container:         [1] hanatest15  (select from list)
    Discovered SID:           ARV  (auto-detected)
    Target DB Name:           ARV/restoretest01
    Overwrite Option:         Overwrite
    Region:                   eastasia

  The script triggers the point-in-time restore and polls until completion.


Example 2 — Full / Differential backup restore to alternate container
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SAPHana-AlternateVM.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     haaryRG
    Vault Name:               hanatier2vault
    Source DB:                 [1] arv/arv  (select from list)
    Restore Type:             2  (Full / Differential)
    Recovery Point:           [1] 298829324177234  (2026-03-12 14:30:15 UTC, Full)
    Target Container:         [1] hanatest15  (select from list)
    Discovered SID:           ARV  (auto-detected)
    Target DB Name:           ARV/restoretest01
    Overwrite Option:         Overwrite
    Region:                   eastasia

  The script triggers the restore and polls until completion.


Example 3 — Using a known Recovery Point ID from Azure Portal
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  In Section 4, choose option [2] (Full / Differential), then instead of
  selecting from the list, enter the RP ID directly:
    Select a recovery point: 298829324177234

  This is useful when you obtain the RP ID from the Azure Portal developer
  console (F12 → Network → find the RP path on the Restore page).


Example 4 — Equivalent armclient command
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  The script generates the same call as:

  armclient POST "/subscriptions/{subId}/resourceGroups/{rg}/providers/
    Microsoft.RecoveryServices/vaults/{vault}/backupFabrics/Azure/
    protectionContainers/{sourceContainer}/protectedItems/{sourceItem}/
    recoveryPoints/{rpId}/restore?api-version=2024-04-01"
    @body.json -verbose

  For point-in-time restores, {rpId} is "DefaultRangeRecoveryPoint".


OUTPUT
------
- Color-coded console output (Cyan, Yellow, Green, Red, Gray).
- The restore request body is kept in memory only (no JSON file is saved).
- Final status showing restore success/failure and next steps.


ERROR HANDLING
--------------
  - Target container not registered:
      Lists available containers and suggests running the HANA
      pre-registration script on the target VM.

  - Invalid recovery point:
      Suggests checking the RP ID from Azure Portal.

  - Point-in-time outside available range:
      Warns the user and asks for confirmation before proceeding.

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.

  - Target DB name format incorrect:
      Must be SID/databaseName (e.g., ARV/restoretest01).

  - SID discovery failure:
      If the SID cannot be auto-detected, the user can enter it manually.

  - Source and target HANA versions incompatible:
      Restore may fail — ensure HANA versions are compatible.


PUBLIC DOCUMENTATION
--------------------
  Restore SAP HANA databases on Azure VMs:
    https://learn.microsoft.com/en-us/azure/backup/sap-hana-database-restore

  Back up SAP HANA databases on Azure VMs:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-sap-hana-db

  SAP HANA backup with PowerShell:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-sap-hana-db-powershell

  Azure Backup REST API — Restores — Trigger:
    https://learn.microsoft.com/en-us/rest/api/backup/restores/trigger

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Recovery Services Vaults REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/recoveryservices/

================================================================================
