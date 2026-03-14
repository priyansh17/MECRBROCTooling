================================================================================
  Register-IaaSVM-ToVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Enables backup protection for an Azure IaaS Virtual Machine in a Recovery
Services Vault using the Azure Backup REST API.

Workflow:
  1. Authenticates via Bearer token (Azure PowerShell or CLI).
  2. Checks if the VM is already protected.
  3. Lists available IaaS VM backup policies in the vault.
  4. Enables backup protection by assigning the selected policy to the VM.
  5. Verifies the final protection status.


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

  Section 3 — Policy Selection:
    - Choose from discovered policies, or press Enter for DefaultPolicy


API VERSION USED
----------------
  - 2019-05-13   All operations (protection check, policy listing, enable protection)


EXAMPLES
--------

Example 1 — VM and Vault in the same subscription
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-IaaSVM-ToVault.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     rg-backup-prod
    Vault Name:               rsv-prod-eastus
    VM Subscription ID:       (press Enter — same as vault)
    VM Resource Group:        rg-app-prod
    VM Name:                  vm-webapp-01

  The script checks if vm-webapp-01 is already protected, lists available
  policies (e.g., DefaultPolicy, DailyPolicy-30d), and enables protection
  with the selected policy.


Example 2 — VM and Vault in different regions (cross-region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-IaaSVM-ToVault.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     rg-backup-swedencentral
    Vault Name:               rsv-dr-swedencentral
    VM Subscription ID:       (press Enter — same as vault)
    VM Resource Group:        rg-app-uaenorth
    VM Name:                  vm-erp-01

  In this scenario the VM runs in UAE North (uaenorth) while the
  Recovery Services Vault is in Sweden Central (swedencentral).


Example 3 — VM already protected
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-IaaSVM-ToVault.ps1

  If the target VM is already registered and protected, the script
  displays the existing protection details (policy, last backup time,
  health status) and exits without making changes.


Example 4 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Register-IaaSVM-ToVault.ps1

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings and informational messages
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, status)
  - Red:     Errors

On success, a final summary shows:
  - VM Name, Protection Status, Protection State
  - Health Status, Policy Name, Workload Type
  - Container Name, Source Resource ID
  - Next steps for triggering backups and monitoring


ERROR HANDLING
--------------
Common issues and what the script reports:

  - VM already protected:
      Displays existing protection details and exits without changes.

  - Protection enablement fails:
      Shows HTTP status code and error message. Lists possible causes
      (another vault, insufficient RBAC, VM agent not running, etc.).

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.


PUBLIC DOCUMENTATION
--------------------
  Back up Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms

  Back up Azure VMs with PowerShell (Az module approach):
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-automation

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Recovery Services Vaults REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/recoveryservices/

  Backup Protected Items REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items

================================================================================
