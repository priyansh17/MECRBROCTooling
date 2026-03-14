================================================================================
  Restore-CvmEncryptionKey.ps1 - README
================================================================================

DESCRIPTION
-----------
Restores missing encryption keys for Confidential VM (CVM + CMK) backup
restore operations using Azure Backup. When a CVM restore fails because the
encryption key is not present in the target Key Vault or Managed HSM, this
script extracts the key backup data from the failed restore job and restores
it into the appropriate key store.

The script auto-detects whether the key should be restored to an Azure Key
Vault or a Managed HSM by reading the "KeyVaultResourceType" field from the
encryption config blob produced by Azure Backup.

Workflow:
  1. Authenticates via Azure PowerShell (Connect-AzAccount).
  2. Connects to the Recovery Services vault.
  3. Lists recent failed restore jobs and lets the user select one.
  4. Extracts storage account, container, and blob details from the job.
  5. Downloads the encrypted key configuration blob from the staging
     storage account.
  6. Decodes and writes the key backup data to a local blob file.
  7. Auto-detects target type (Key Vault vs Managed HSM) from the config.
  8. Restores the key into the specified Key Vault or Managed HSM.

Each resource (vault, storage account, Key Vault / MHSM) can reside in a
different subscription. The script prompts for a subscription switch at each
stage when needed.


WHERE TO RUN
------------
- PowerShell 7+ (pwsh) is required.
- If launched under Windows PowerShell 5.1, the script automatically detects
  this and re-launches itself under pwsh 7 if available. If pwsh is not
  installed, the script exits with a clear error message.
- If a stale Azure SDK assembly is loaded in the current session (e.g. from
  prior debugging), the script detects the TypeLoadException and re-launches
  in a clean pwsh process automatically.
- Run from any terminal: PowerShell console, Windows Terminal, VS Code
  terminal, or Azure Cloud Shell.
- The script is interactive (uses Read-Host prompts), so it must be run in a
  foreground terminal session — not as part of an automated pipeline.


DEPENDENCIES
------------
Azure PowerShell Module (Az):
  - Az.Accounts  >= 3.0.0
  - Az.RecoveryServices
  - Az.Storage
  - Az.KeyVault

Install all required modules:
  Install-PSResource Az -Scope CurrentUser -TrustRepository

Authenticate before running:
  Connect-AzAccount

Additional system dependency:
  - certutil (built-in Windows tool) — used to decode base64 key data. This
    avoids reliance on .NET static methods that are blocked in PowerShell
    Constrained Language Mode (AppLocker / WDAC environments).


REQUIRED PERMISSIONS (RBAC)
---------------------------
Recovery Services Vault:
  - Backup Operator (or equivalent) — to read backup jobs and job details.

Storage Account:
  - Storage Blob Data Reader (or equivalent) — to download the encryption
    config blob from the staging container.

Key Vault (when KeyVaultResourceType is not managedHSMs):
  - Access Policy: Key Restore permission, OR
  - Azure RBAC role: Key Vault Crypto Officer on the vault.

Managed HSM (when KeyVaultResourceType = "Microsoft.KeyVault/managedHSMs"):
  - MHSM local RBAC role: Managed HSM Crypto Officer or Managed HSM Crypto
    User (must include keys/restore action).
  - Note: Managed HSMs use local RBAC, not standard Azure role assignments.
    An MHSM admin must grant the role:
      az keyvault role assignment create \
        --hsm-name <mhsm-name> \
        --role "Managed HSM Crypto Officer" \
        --assignee <your-object-id> \
        --scope /


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Authentication:
    - Azure login via Connect-AzAccount (automatic if no active session).

  Section 1 — Recovery Services Vault:
    - Subscription ID             (press Enter to keep current)
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 2 — Failed Restore Job Selection:
    - Lookback window in days     (default: 7)
    - Select a failed job by number from the listed jobs.
      Each job shows: Activity ID, VM Name, Start Time, End Time.

  Section 3 — Job Details (automatic):
    - Storage Account Name, Container Name, and Encryption Blob Name are
      extracted automatically from the selected job's properties.

  Section 4 — Download Encryption Config Blob:
    - Subscription ID             (press Enter to keep current)
    - Storage Account Resource Group Name
    - Blob is downloaded to %TEMP%.

  Section 5 — Extract Key Backup Data (automatic):
    - KeyBackupData is extracted from the downloaded JSON config.
    - Base64-decoded to a .blob file using certutil.

  Section 6 — Restore Key to Key Vault or Managed HSM:
    - Subscription ID             (press Enter to keep current)
    - Target type is auto-detected from the config blob:
        KeyVaultResourceType = "Microsoft.KeyVault/managedHSMs" → MHSM
        Otherwise → Key Vault
    - Key Vault Name  OR  Managed HSM Name (depending on detected type).


EXAMPLES
--------

Example 1 — Restore key to Azure Key Vault
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-CvmEncryptionKey.ps1

  Prompts:
    Subscription for Vault:       (press Enter — use current)
    Vault Resource Group:         rg-backup-prod
    Vault Name:                   rsv-prod-eastus
    Lookback days:                7 (press Enter for default)
    Failed job selection:         [1]
    Subscription for Storage:     (press Enter — same subscription)
    Storage Account RG:           rg-storage-prod
    Subscription for Key Vault:   (press Enter — same subscription)
    Key Vault Name:               kv-cvm-prod-eastus

  The script downloads the encryption config blob, extracts KeyBackupData,
  and restores the key into kv-cvm-prod-eastus. On success it displays the
  restored Key Name, Key Id, and Key Version.


Example 2 — Restore key to Managed HSM (cross-subscription)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-CvmEncryptionKey.ps1

  Prompts:
    Subscription for Vault:       aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa
    Vault Resource Group:         rg-backup-dr
    Vault Name:                   rsv-dr-westeurope
    Lookback days:                14
    Failed job selection:         [2]
    Subscription for Storage:     bbbbbbbb-4444-5555-6666-bbbbbbbbbbbb
    Storage Account RG:           rg-staging-westeurope
    Subscription for MHSM:       cccccccc-7777-8888-9999-cccccccccccc
    Managed HSM Name:             mhsm-cvm-prod

  The vault, storage account, and Managed HSM are each in different
  subscriptions. The script auto-detects MHSM from the config blob's
  KeyVaultResourceType = "Microsoft.KeyVault/managedHSMs" and restores
  the key into mhsm-cvm-prod.


Example 3 — Script launched under Windows PowerShell 5.1
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> powershell -File .\Restore-CvmEncryptionKey.ps1

  Output:
    Re-launching script under PowerShell 7...

  The script detects PS 5.1 (which is incompatible with Az module 5.x),
  locates pwsh.exe, and automatically re-launches itself under PowerShell 7.
  No user action required.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers, prompts, and detected target type
  - Yellow:  Warnings, subscription switches, and section headers
  - Green:   Success confirmations (vault found, download complete,
             key restored, subscription switched)
  - Gray:    Detail values (subscription info, storage account, container,
             blob name, key blob file path)
  - White:   Job listings, key details, and next-step instructions
  - Red:     Errors (missing inputs, failed operations, access denied)

On success, the script displays:
  - KEY RESTORED SUCCESSFULLY banner
  - Key Name, Key Id, and Key Version
  - Next Steps:
      1. Create a new DES with "Confidential disk encryption with CMK"
         pointing to the restored Key Id.
      2. Ensure the DES and Backup Management Service have permissions
         on the Key Vault / Managed HSM.
      3. Retry the VM restore operation using the new DES.


TEMPORARY FILES
---------------
The script creates temporary files in %TEMP% during execution:
  - cvmcmkencryption_config_<timestamp>.json  (encryption config blob)
  - keybase64_<timestamp>.txt                 (intermediate base64 file)
  - keyDetails_<timestamp>.blob               (decoded key backup blob)

All temporary files are automatically cleaned up on completion.


ERROR HANDLING
--------------
Common issues and what the script reports:

  - PowerShell 5.1 / stale assembly (TypeLoadException):
      Auto-relaunches under pwsh 7. If pwsh is not installed, shows an
      error with a link to install it (https://aka.ms/install-powershell).

  - Constrained Language Mode:
      The script uses certutil for base64 decoding instead of .NET static
      methods, so it works in AppLocker / WDAC-restricted environments.

  - No active Azure session:
      Automatically runs Connect-AzAccount to authenticate.

  - Vault not found:
      Reports the vault name and resource group, exits.

  - No failed restore jobs:
      Suggests increasing the lookback window.

  - Required job properties missing:
      Shows which properties (Storage Account, Container, Blob) are
      missing from the job details.

  - KeyBackupData missing in config:
      Reports the encryption config does not contain KeyBackupData.

  - certutil decode failure:
      Reports the exit code from certutil.

  - Access denied on Key Vault (403 / Forbidden):
      Advises to add Key Restore permission via access policy or assign
      Key Vault Crypto Officer Azure RBAC role.

  - Access denied on Managed HSM (403 / AccessDenied):
      Explains that MHSM uses local RBAC and provides the exact
      az keyvault role assignment create command to run.


POINTS TO REMEMBER
------------------
  - The target type (Key Vault vs Managed HSM) is auto-detected from the
    config blob's OsDiskEncryptionDetails.KeyVaultResourceType field.
    No manual selection is needed.

  - After restoring the key, you must create a new Disk Encryption Set
    (DES) configured for "Confidential disk encryption with a customer-
    managed key" pointing to the restored key, then retry the VM restore.

  - Ensure the Backup Management Service principal has the Managed HSM Crypto User
    permissions on the Key Vault / Managed HSM before retrying the restore.

  - The script requires PowerShell 7+. If launched under PS 5.1, it auto-
    relaunches under pwsh. Ensure pwsh is installed on the machine.


PUBLIC DOCUMENTATION
--------------------
  Restore Azure VMs with PowerShell:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-automation

  Azure Backup for Confidential VMs:
    https://learn.microsoft.com/en-us/azure/backup/backup-support-matrix-iaas

  Restore-AzKeyVaultKey cmdlet reference:
    https://learn.microsoft.com/en-us/powershell/module/az.keyvault/restore-azkeyvaultkey

  Managed HSM local RBAC:
    https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/built-in-roles

  Install PowerShell 7:
    https://aka.ms/install-powershell

================================================================================
