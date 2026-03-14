# Unregister-SAPHanaVM-FromVault.ps1 — Readme

## Overview

This PowerShell script **stops backup protection (with retain data)** for SAP HANA databases on an Azure Linux VM and optionally **unregisters** the VM container from a Recovery Services Vault — all via the Azure Backup REST API.

Recovery points are **always preserved**; this script never deletes backup data.

---

## Supported SAP HANA Item Types

| Item Type | Description |
|---|---|
| **SAPHanaDatabase** | Individual HANA databases (SYSTEMDB, tenant DBs) |
| **SAPHanaDBInstance** | HANA DB instances (HSR / System Replication scenarios) |

Both types are automatically discovered and processed by the script.

---

## Operational Modes

### Mode 1 — Stop Protection with Retain Data *(default)*

- Lists all protected SAP HANA datasources on the VM.
- Stops protection while **retaining existing recovery points**.
- Supports targeting a single database (`-DatabaseName`) or all (`-StopAll`).
- Interactive selection when neither flag is provided.
- After all datasources are stopped, optionally prompts to unregister.

### Mode 2 — Full Unregistration (`-Unregister`)

- Stops protection (retain data) for **all** active datasources on the VM.
- Waits 30 seconds for operations to propagate.
- Unregisters the `VMAppContainer` from the vault.
- `-StopAll` is implied; `-DatabaseName` is ignored.

---

## Prerequisites

1. **Azure authentication** — run one of:
   - `Connect-AzAccount` (Azure PowerShell)
   - `az login` (Azure CLI)
2. **RBAC permissions** — Backup Contributor (or equivalent) on the Recovery Services Vault.
3. **SAP HANA databases** must be in one of these states: `Protected`, `IRPending`, or `ProtectionStopped`.

---

## Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VaultSubscriptionId` | Yes | Subscription ID of the Recovery Services Vault |
| `-VaultResourceGroup` | Yes | Resource Group of the Recovery Services Vault |
| `-VaultName` | Yes | Name of the Recovery Services Vault |
| `-VMResourceGroup` | Yes | Resource Group of the SAP HANA VM |
| `-VMName` | Yes | Name of the Azure VM hosting SAP HANA |
| `-DatabaseName` | No | Specific HANA database to stop protection for (ignored with `-Unregister`) |
| `-Unregister` | No | Stop protection for all datasources **and** unregister the VM |
| `-StopAll` | No | Stop protection for all datasources without prompting (no unregister) |
| `-SkipConfirmation` | No | Skip interactive confirmation prompts (for automation) |

---

## Usage Examples

### 1. Stop protection for a specific database

```powershell
.\Unregister-SAPHanaVM-FromVault.ps1 `
    -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultResourceGroup  "rg-vault" `
    -VaultName           "myRecoveryVault" `
    -VMResourceGroup     "rg-hana" `
    -VMName              "hana-vm-01" `
    -DatabaseName        "SYSTEMDB"
```

### 2. Stop protection + unregister the VM (full cleanup)

```powershell
.\Unregister-SAPHanaVM-FromVault.ps1 `
    -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultResourceGroup  "rg-vault" `
    -VaultName           "myRecoveryVault" `
    -VMResourceGroup     "rg-hana" `
    -VMName              "hana-vm-01" `
    -Unregister
```

### 3. Stop all datasources without unregistering

```powershell
.\Unregister-SAPHanaVM-FromVault.ps1 `
    -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultResourceGroup  "rg-vault" `
    -VaultName           "myRecoveryVault" `
    -VMResourceGroup     "rg-hana" `
    -VMName              "hana-vm-01" `
    -StopAll
```

### 4. Interactive mode (lists datasources, lets you choose)

```powershell
.\Unregister-SAPHanaVM-FromVault.ps1 `
    -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultResourceGroup  "rg-vault" `
    -VaultName           "myRecoveryVault" `
    -VMResourceGroup     "rg-hana" `
    -VMName              "hana-vm-01"
```

### 5. Automated / non-interactive (skip all prompts)

```powershell
.\Unregister-SAPHanaVM-FromVault.ps1 `
    -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultResourceGroup  "rg-vault" `
    -VaultName           "myRecoveryVault" `
    -VMResourceGroup     "rg-hana" `
    -VMName              "hana-vm-01" `
    -Unregister -SkipConfirmation
```

---

## Script Flow

```
┌─────────────────────────────────────────────┐
│  Authenticate (Az PowerShell or Azure CLI)  │
└──────────────────┬──────────────────────────┘
                   ▼
┌─────────────────────────────────────────────┐
│  STEP 1: Query protected HANA datasources   │
│  (SAPHanaDatabase + SAPHanaDBInstance)       │
│  Filter to target VM by container name      │
└──────────────────┬──────────────────────────┘
                   ▼
          ┌────────┴────────┐
          │  -Unregister?   │
          └───┬─────────┬───┘
           No │         │ Yes
              ▼         ▼
┌──────────────────┐  ┌──────────────────────────┐
│ STEP 2: Stop     │  │ STEP 2: Stop ALL active   │
│ protection for   │  │ datasources (retain data) │
│ selected DB(s)   │  └────────────┬───────────────┘
│ (retain data)    │               ▼
└───────┬──────────┘  ┌──────────────────────────┐
        │             │ STEP 3: Wait 30s, then    │
        ▼             │ DELETE container (unreg)   │
  Prompt to unreg?    └────────────┬───────────────┘
        │                          ▼
        ▼                    Final Summary
  Final Summary
```

---

## Important Notes

- **Recovery points are never deleted** — the script uses "stop protection with retain data" which preserves all existing recovery points in the vault.
- **Unregistration requires all datasources stopped first** — the script handles this automatically when `-Unregister` is specified.
- The script uses REST API version `2025-08-01`.
- If the unregister call fails with `BMSUserErrorContainerHasDatasources`, wait a few minutes for stop operations to propagate and retry.

---

## References

- [Manage SAP HANA database backup](https://learn.microsoft.com/en-us/azure/backup/sap-hana-db-manage)
- [Protected Items REST API](https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update)
- [Unregister Container REST API](https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/unregister)
