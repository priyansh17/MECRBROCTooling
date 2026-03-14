================================================================================
  Register-SQLIaaSVM-ToVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Discovers, registers, and protects SQL Server databases running on Azure IaaS
VMs to a Recovery Services Vault using the Azure Backup REST API. The script
performs end-to-end container discovery, VM registration, SQL workload inquiry,
database protection, and optional auto-protection of SQL instances.


WORKFLOW
--------
  1. Triggers a container refresh to discover VMs with SQL workloads.
  2. Lists protectable containers and locates the target VM.
  3. Registers the VM as a VMAppContainer (skips if already registered).
  4. Inquires SQL workloads inside the VM (discovers instances and databases).
  5. Lists protectable SQL databases and instances.
  6. Checks if the target database is already protected.
  7. Lists available AzureWorkload backup policies.
  8. Enables protection on the selected database OR enables auto-protection
     on the SQL instance (all current and future databases).
  9. Verifies the final protection status.


WHERE TO RUN
------------
- PowerShell 7+ (Windows, macOS, or Linux) or Windows PowerShell 5.1.
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- Supports both non-interactive (all parameters on command line) and interactive
  modes (PowerShell prompts for mandatory parameters).


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A - Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B - Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login

No other modules or packages are required. The script uses only built-in
PowerShell cmdlets (Invoke-RestMethod, Invoke-WebRequest, ConvertTo-Json)
alongside the Azure Backup REST API.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Contributor (or equivalent) on the Recovery Services Vault.
- Reader (or equivalent) on the target Virtual Machine and its Resource Group.
- SQL Server IaaS Agent extension must be installed on the VM.


PARAMETERS
----------
  -VaultSubscriptionId    [Required]  Subscription ID of the vault.
  -VaultResourceGroup     [Required]  Resource group of the vault.
  -VaultName              [Required]  Name of the Recovery Services Vault.
  -VMResourceGroup        [Required]  Resource group of the SQL Server VM.
  -VMName                 [Required]  Name of the Azure VM hosting SQL Server.
  -DatabaseName           [Optional]  SQL database name to protect.
                                      If omitted, discovered DBs are listed
                                      for interactive selection.
  -PolicyName             [Optional]  Backup policy name. If omitted, available
                                      policies are listed for selection.
  -EnableAutoProtection   [Optional]  Switch to enable auto-protection on the
                                      SQL instance instead of a single DB.


API VERSION
-----------
  - 2025-08-01   All operations (discovery, registration, protection, policies)


EXAMPLES
--------

Example 1 - Protect a single database (interactive policy selection)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB"

  The script discovers sql-vm-01, registers it, inquires SQL workloads,
  finds SalesDB, lists available policies for selection, and enables
  protection with the chosen policy.


Example 2 - Protect a single database with a specific policy
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" `
        -PolicyName "HourlyLogBackup"

  Fully non-interactive. Policy is verified via API before use.


Example 3 - Enable auto-protection on the SQL instance
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -EnableAutoProtection `
        -PolicyName "HourlyLogBackup"

  All current and future databases under the SQL instance will be
  automatically protected. -DatabaseName is ignored.


Example 4 - Interactive mode (no DatabaseName, no PolicyName)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01"

  After discovery, the script lists all SQL databases and prompts you
  to pick one. Then lists policies and prompts for selection.


Example 5 - VM already protected
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  If the target database is already protected, the script displays the
  existing protection details (policy, last backup time, health status)
  and exits without making changes.


SMART BEHAVIORS
---------------
  - VM already registered:    Skips registration, continues with inquiry.
  - Database already protected: Shows existing protection details, exits.
  - Multiple SQL instances:   Prompts user to select one (auto-protection).
  - Single SQL instance:      Auto-selects it without prompting.
  - PolicyName not found:     Exits with clear error (verified via API).
  - Case-insensitive DB match: Falls back to case-insensitive search.
  - Container name from API:  Uses discovered name, not manually constructed.


OUTPUT
------
Color-coded console output:
  - Cyan:    Section headers, prompts, progress
  - Yellow:  Warnings and informational messages
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, status)
  - Red:     Errors

On success, a final summary shows:
  - Database Name, Server Name, Parent Instance
  - Protection Status/State, Health Status
  - Last Backup Status/Time, Policy Name
  - Workload Type, Container Name


ERROR HANDLING
--------------
Common issues:
  - 401 Unauthorized:     Wrong subscription/tenant. Run Connect-AzAccount
                          with the correct -Subscription and -Tenant.
  - SecureString token:   Newer Az.Accounts modules return SecureString tokens.
                          The script handles both formats automatically.
  - VM not found:         Lists available VMs and suggests causes.
  - DB not found:         Lists available databases with instance names.
  - Registration fails:   Suggests SQL IaaS Agent extension, VM state, RBAC.
  - Policy not found:     Clear error with 404 detection.


PUBLIC DOCUMENTATION
--------------------
  Back up SQL databases in Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-sql-vm-rest-api

  Protection Containers - Register:
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/register

  Protection Intent - Create or Update (Auto-Protection):
    https://learn.microsoft.com/en-us/rest/api/backup/protection-intent/create-or-update

  Azure Backup REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/

================================================================================
