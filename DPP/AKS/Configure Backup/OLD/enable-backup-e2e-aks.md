# Enable Backup E2E Script

PowerShell script to set up AKS backup end-to-end: installs the CLI extension, creates a backup vault with cross-region backup, creates a vault-tier policy, and runs `az dataprotection enable-backup trigger`.

> **Note:** You must have **Owner** or **Contributor + User Access Administrator** role on the subscription. The command assigns multiple roles across identities (cluster MSI, extension MSI, vault MSI).

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in (`az login`)
- The provided `.whl` file in the same folder as the script

## Usage

```powershell
.\enable-backup-e2e-aks.ps1 `
  -VaultRegion <region> `
  -ClusterId <cluster-arm-id> `
  -VaultName <vault-name> `
  -ResourceGroup <rg> `
  -Subscription <sub-id> `
  -WheelPath .\dataprotection-1.9.0-py3-none-any.whl
```

### Examples

```powershell
# Protect an eastasia cluster
.\enable-backup-e2e-aks.ps1 `
  -VaultRegion eastasia `
  -ClusterId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/my-rg/providers/Microsoft.ContainerService/managedClusters/my-aks-cluster" `
  -VaultName "my-backup-vault" `
  -ResourceGroup "my-rg" `
  -Subscription "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -WheelPath .\dataprotection-1.9.0-py3-none-any.whl

# Protect a westus2 cluster
.\enable-backup-e2e-aks.ps1 `
  -VaultRegion westus2 `
  -ClusterId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/prod-rg/providers/Microsoft.ContainerService/managedClusters/prod-cluster" `
  -VaultName "prod-backup-vault" `
  -ResourceGroup "prod-rg" `
  -Subscription "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -WheelPath .\dataprotection-1.9.0-py3-none-any.whl
```

## What It Does

| Step | Action |
|------|--------|
| 1 | Installs `dataprotection` extension from wheel |
| 2 | Creates backup vault (LRS, SystemAssigned, soft delete on) + enables Cross Region Backup |
| 3 | Creates backup policy (30-day op-store + 90-day vault-store, daily incremental) |
| 4 | Runs `az dataprotection enable-backup trigger --backup-strategy Custom` |

The enable-backup command then internally creates: backup resource group, storage account, blob container, backup extension, role assignments, trusted access binding, and backup instance.

## Notes

- Vault and cluster must be in the **same region**
- Script is **idempotent** for vault and policy — skips creation if they already exist
- If the cluster already has a backup instance, delete it first before re-running
