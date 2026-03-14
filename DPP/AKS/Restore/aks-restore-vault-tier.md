# AKS Restore from Vault Tier

PowerShell script to perform an AKS restore from a vault-tier recovery point. The script supports restoring to **any target region** — including cross-region restore (CRR) to a different region **and** restore back to the vault's own region.

Additionally supports namespace remapping, conflict policies, and PV restore mode selection. The script handles permission setup (trusted access, role assignments), restore configuration, validation, trigger, and job polling.

> **Restore Target Flexibility:**
> - **Cross-Region Restore (CRR):** Restore to a cluster in a different region from the vault (e.g., vault in `centraluseuap`, restore to a cluster in `eastus2euap`).
> - **Vault-Region Restore:** Restore to a cluster in the same region as the vault.
> - The restore location is automatically derived from the target cluster — just point `-TargetClusterId` at any AKS cluster in any region.

> **Note:** You must have **Owner** or **Contributor + User Access Administrator** role on the subscription. The script assigns roles to vault MSI, cluster MSI, and extension MSI identities.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in (`az login`)
- `dataprotection` CLI extension installed
- Backup extension (`azure-aks-backup`) already installed on the target AKS cluster
- A backup vault with at least one vault-tier recovery point for the backup instance

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-SubscriptionId` | Yes | — | Azure Subscription ID |
| `-ResourceGroupName` | Yes | — | Resource group containing the backup vault |
| `-VaultName` | Yes | — | Name of the backup vault |
| `-BackupInstanceName` | Yes | — | Backup instance name in the vault |
| `-TargetClusterId` | Yes | — | ARM Resource ID of the target AKS cluster |
| `-StagingResourceGroupId` | Yes | — | ARM Resource ID of the staging resource group |
| `-StagingStorageAccountId` | Yes | — | ARM Resource ID of the staging storage account |
| `-RecoveryPointId` | No | latest | Recovery point ID (uses latest if omitted) |
| `-NamespaceMappingJson` | No | `{}` | JSON string mapping source to target namespaces |
| `-ConflictPolicy` | No | `Skip` | `Skip` or `Patch` |
| `-PersistentVolumeRestoreMode` | No | `RestoreWithVolumeData` | `RestoreWithVolumeData` or `RestoreWithoutVolumeData` |
| `-PollIntervalSeconds` | No | `30` | Seconds between job status polls |
| `-MaxRetries` | No | `60` | Maximum number of polling retries |
| `-SkipPermissions` | No | `$false` | Skip role assignment and trusted access setup |

## Usage

```powershell
.\aks-restore-vault-tier.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "<vault-resource-group>" `
  -VaultName "<backup-vault-name>" `
  -BackupInstanceName "<backup-instance-name>" `
  -TargetClusterId "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<cluster>" `
  -StagingResourceGroupId "/subscriptions/<sub-id>/resourceGroups/<staging-rg>" `
  -StagingStorageAccountId "/subscriptions/<sub-id>/resourceGroups/<staging-rg>/providers/Microsoft.Storage/storageAccounts/<sa-name>"
```

### Examples

```powershell
# Restore using latest recovery point with namespace remapping
.\aks-restore-vault-tier.ps1 `
  -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -ResourceGroupName "my-rg" `
  -VaultName "my-backup-vault" `
  -BackupInstanceName "my-backup-instance-1" `
  -TargetClusterId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/my-rg/providers/Microsoft.ContainerService/managedClusters/my-aks" `
  -StagingResourceGroupId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/my-rg" `
  -StagingStorageAccountId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/my-rg/providers/Microsoft.Storage/storageAccounts/mystagingsa" `
  -NamespaceMappingJson '{"source-ns":"target-ns"}'

# Restore a specific recovery point, skip permission setup
.\aks-restore-vault-tier.ps1 `
  -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -ResourceGroupName "prod-rg" `
  -VaultName "prod-vault" `
  -BackupInstanceName "prod-instance-1" `
  -TargetClusterId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/prod-rg/providers/Microsoft.ContainerService/managedClusters/prod-aks" `
  -StagingResourceGroupId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/prod-rg" `
  -StagingStorageAccountId "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/prod-rg/providers/Microsoft.Storage/storageAccounts/prodstagingsa" `
  -RecoveryPointId "abc123def456" `
  -SkipPermissions
```

## What It Does

| Step | Action |
|------|--------|
| Pre-check | Verifies `azure-aks-backup` extension is installed and healthy on target cluster |
| 1b | Sets up trusted access binding and role assignments for vault, cluster, and extension MSIs |
| 2 | Lists vault-store recovery points and selects the specified or latest one |
| 3 | Initializes restore configuration via `az dataprotection backup-instance restore initialize-for-item-recovery` |
| 4 | Patches restore criteria with staging resources, namespace mapping, conflict policy, and PV restore mode |
| 5 | Validates the restore request via `validate-for-restore` |
| 6 | Triggers the restore (async with `--no-wait`) |
| 7 | Polls restore job status until completion, failure, or timeout |

## Role Assignments Created

| Identity | Scope | Role |
|----------|-------|------|
| Vault MSI | Target Cluster | Reader |
| Vault MSI | Staging Resource Group | Contributor |
| Vault MSI | Staging Storage Account | Storage Blob Data Contributor |
| Cluster MSI | Staging Resource Group | Contributor |
| Cluster MSI | Staging Storage Account | Storage Account Contributor |
| Cluster MSI | Staging Storage Account | Storage Blob Data Contributor |
| Extension MSI | Staging Storage Account | Storage Account Contributor |
| Extension MSI | Staging Storage Account | Storage Blob Data Contributor |

## Notes

- `-BackupInstanceName` must be the **actual backup instance name** (containing a GUID), not the friendly/display name. You can find this in the backup instance JSON (`name` field) — e.g. `my-rg-my-cluster-53d5313d-1f20-11f1-b37c-f16dc1a59203`. Run `az dataprotection backup-instance list -g <rg> --vault-name <vault> -o json` and look for the `name` property.
- Backup extension must be installed on the target cluster before running
- Script is **idempotent** for permissions — skips role assignments that already exist
- Use `-SkipPermissions` if roles and trusted access are already configured
- Temp files are cleaned up automatically on completion
- The namespace mapping JSON must be a valid JSON object string (use single quotes around it in PowerShell)
