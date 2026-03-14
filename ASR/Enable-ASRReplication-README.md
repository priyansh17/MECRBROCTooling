# Enable-ASRReplication.ps1

Automates Azure Site Recovery (A2A) replication for multiple Azure VMs using the **Create Protection Intent** REST API. The script handles all setup — vault, policy, automation account, virtual network — so you can go from zero to protected with a single command.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **PowerShell** | 5.1+ (Windows PowerShell) or 7+ (PowerShell Core) |
| **Az PowerShell Modules** | `Az.Accounts`, `Az.Compute`, `Az.Resources`, `Az.RecoveryServices`, `Az.Automation`, `Az.Network`, `Az.ResourceGraph` |
| **Azure Login** | Run `Connect-AzAccount` before executing the script |

Install modules if needed:
```powershell
Install-Module Az -Scope CurrentUser -Force
```

---

## Quick Start

### Minimal — protect VMs from specific source regions
```powershell
.\Enable-ASRReplication.ps1 `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultName "my-dr-vault" `
    -TargetResourceGroupName "dr-rg" `
    -TargetLocation "swedencentral" `
    -SourceResourceGroupNames @("app-rg", "db-rg") `
    -SourceLocations @("qatarcentral", "uaenorth")
```

### Dry Run — validate everything without making changes
```powershell
.\Enable-ASRReplication.ps1 `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultName "my-dr-vault" `
    -TargetResourceGroupName "dr-rg" `
    -TargetLocation "swedencentral" `
    -SourceResourceGroupNames @("app-rg") `
    -SourceLocations @("qatarcentral", "uaenorth") `
    -DryRun
```

### Specific VMs with CSV export and IR monitoring
```powershell
.\Enable-ASRReplication.ps1 `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultName "my-dr-vault" `
    -TargetResourceGroupName "dr-rg" `
    -TargetLocation "swedencentral" `
    -VMResourceIds @(
        "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1",
        "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm2"
    ) `
    -MonitorIR `
    -OutputCsvPath ".\replication_results.csv"
```

### Custom VNet with VM list from CSV
```powershell
.\Enable-ASRReplication.ps1 `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VaultName "my-dr-vault" `
    -TargetResourceGroupName "dr-rg" `
    -TargetLocation "swedencentral" `
    -VMResourceIdsCsvPath ".\vm_list.csv" `
    -RecoveryVirtualNetworkId "/subscriptions/xxx/resourceGroups/dr-rg/providers/Microsoft.Network/virtualNetworks/my-vnet" `
    -RecoverySubnetName "default"
```

---

## Parameters

### Required

| Parameter | Description |
|---|---|
| `-SubscriptionId` | Source subscription ID containing the VMs |
| `-VaultName` | Recovery Services vault name (created if it doesn't exist) |
| `-TargetResourceGroupName` | Resource group for vault and recovery resources (must already exist) |
| `-TargetLocation` | Target / DR Azure region (e.g., `swedencentral`) |

### VM Selection (at least one required)

| Parameter | Description |
|---|---|
| `-SourceResourceGroupNames` | Array of RG names. Fetches all VMs in those RGs. Example: `@("rg1", "rg2")` |
| `-SourceLocations` | Filter VMs by location. Example: `@("qatarcentral", "uaenorth")` |
| `-VMResourceIds` | Array of VM ARM IDs to protect |
| `-VMResourceIdsCsvPath` | Path to CSV file with a `VMResourceId` column |

These can be combined — each additional parameter acts as a **filter** that narrows down the VM list:

#### Input Combinations

| Input Given | What Happens |
|---|---|
| `-SourceResourceGroupNames` only | Fetches **all VMs** in those RGs within the source subscription |
| `-SourceResourceGroupNames` + `-SourceLocations` | Fetches all VMs in those RGs, then keeps only VMs in the specified locations |
| `-VMResourceIds` only | Uses exactly those VMs; skips any not in the source subscription |
| `-VMResourceIds` + `-SourceResourceGroupNames` | From the VM list, keeps only VMs whose RG matches the specified RG names |
| `-VMResourceIds` + `-SourceLocations` | From the VM list, keeps only VMs in the specified locations |
| `-VMResourceIds` + `-SourceResourceGroupNames` + `-SourceLocations` | From the VM list, keeps only VMs matching **both** the RG names **and** the locations |
| `-VMResourceIdsCsvPath` | Loads VM ARM IDs from CSV (column: `VMResourceId`), then same rules as `-VMResourceIds` |
| `-VMResourceIdsCsvPath` + any filter | CSV VMs are merged with `-VMResourceIds` (if both given), then filtered by RG/location |

#### Example: filtering in action

```
Input:  -VMResourceIds @(vm1, vm2, vm3, vm4, vm5)
        -SourceResourceGroupNames @("app-rg")
        -SourceLocations @("qatarcentral")

Step 1: Subscription filter → vm5 is in a different subscription → SKIPPED
Step 2: RG filter           → vm3 is in "db-rg" not "app-rg"   → SKIPPED
Step 3: Fetch locations     → vm1=qatarcentral, vm2=uaenorth, vm4=qatarcentral
Step 4: Location filter     → vm2 is in uaenorth not qatarcentral → SKIPPED

Result: vm1 and vm4 are processed. vm2, vm3, vm5 are skipped with reasons.
```

### Target Infrastructure (optional — smart defaults)

| Parameter | Default | Description |
|---|---|---|
| `-TargetSubscriptionId` | Same as source | Target subscription for recovery resources |
| `-RecoveryVirtualNetworkId` | Auto-creates `asrscript-target-vnet-<targetlocation>` | ARM ID of existing VNet. Must be in the target location or the script will fail. |
| `-RecoverySubnetName` | `default` | Subnet in the target VNet |
| `-AutomationAccountArmId` | Auto-creates `asrscript-automation-<6-char-random>` | ARM ID of existing automation account. **Recommended on repeat runs** to reuse the account created on the first run (see output for the ARM ID). |
| `-AutomationAccountLocation` | Same as `-TargetLocation` | Region for auto-created automation account. Use if target region doesn't support Azure Automation (e.g., `-AutomationAccountLocation "swedencentral"`) |
| `-RecoveryAvailabilityType` | `Single` | `Single`, `AvailabilitySet`, or `AvailabilityZone` |
| `-RecoveryAvailabilitySetId` | — | Required when type = `AvailabilitySet` |
| `-RecoveryAvailabilityZone` | — | Required when type = `AvailabilityZone` (e.g., `"1"`) |
| `-RecoveryProximityPlacementGroupId` | — | ARM ID of target PPG |
| `-CacheStorageAccountId` | ASR auto-creates | ARM ID of cache storage in source region |
| `-RecoveryBootDiagStorageAccountId` | ASR auto-creates | ARM ID of boot diagnostics storage in target region |
| `-AutoProtectionOfDataDisk` | `Enabled` | Auto-protect data disks added to VM later |

### Execution Control

| Parameter | Default | Description |
|---|---|---|
| `-MonitorIR` | off | Monitor Initial Replication progress after enable-replication jobs complete |
| `-MaxIRPollMinutes` | `180` | Max time to monitor IR (3 hours default) |
| `-OutputCsvPath` | — | Path to export results CSV |
| `-DryRun` | off | Validate everything without making any changes |
| `-ApiVersion` | `2025-08-01` | ASR REST API version |

---

## What the Script Does

### Execution Flow

```
Phase 1 -- VM Resolution & Filtering (see detailed breakdown below)
  |-- Load VMs from input (ARM IDs / RG names / locations / CSV)
  |-- Filter by subscription, RG, and location
  |-- Fetch each VM's actual location via Get-AzVM
  |-- Skip VMs already in the target location
  '-- Check Azure Resource Graph -- skip VMs already protected in any vault

Phase 2 -- Target Infrastructure Setup
  |-- Vault: check/create in target RG -> verify with exponential backoff
  |-- If vault exists & vault location != target location -> skip VMs in vault location
  |-- Automation Account: check/create -> verify -> assign Contributor role on vault
  |-- Virtual Network: check/create with default subnet -> verify
  |-- Acquire ARM bearer token (auto-refreshes during polling)
  '-- Replication Policy: check/create via REST API -> poll + verify

Phase 3 -- Fire All Intents (batched by source region)
  |-- Group VMs by source location into batches
  |-- For each batch: PUT protection intent for each VM (10-min wait after first VM in batch)
  '-- Wait 10 minutes between batches (ASR fabric/container setup per source-target pair)

Phase 4 -- Poll Enable-Replication Jobs (always, ~minutes)
  '-- Poll each job returned by intent PUT until Succeeded/Failed
      Token auto-refreshes every 4 minutes to avoid expiry

Phase 5 -- IR Monitoring (optional, -MonitorIR, ~hours)
  '-- Poll replicationProtectedItems -> track protectionState + disk progress %
      until all reach Protected or timeout

Phase 6 -- Summary & Export
  |-- Print summary table with counts and per-VM status
  |-- Export CSV if -OutputCsvPath specified
  '-- Return results object for pipeline consumption
```

### Phase 1 — VM Resolution (detailed)

The script applies filters in a **pipeline** — each step narrows the VM list, and every excluded VM is tracked with a reason.

```
┌─────────────────────────────────────────────────────────────────┐
│  INPUT: -VMResourceIds / -SourceResourceGroupNames / CSV        │
└──────────────────────────┬──────────────────────────────────────┘
                           ▼
              ┌────────────────────────┐
              │ 1a. Load VM list       │  RG path: Get-AzVM per RG
              │                        │  VM path: use ARM IDs as-is
              └────────────┬───────────┘
                           ▼
              ┌────────────────────────┐
              │ 1b. Subscription filter│  Skip VMs not in -SubscriptionId
              │     (VM path only)     │  → "Not in subscription <id>"
              └────────────┬───────────┘
                           ▼
              ┌────────────────────────┐
              │ 1c. RG name filter     │  Skip VMs not in -SourceResourceGroupNames
              │     (if specified)     │  → "Not in RG(s): rg1, rg2"
              └────────────┬───────────┘
                           ▼
              ┌────────────────────────┐
              │ 1d. Fetch VM locations │  Get-AzVM to get actual Azure region
              │     (VM path only)     │  → "Failed to fetch: <error>" if VM gone
              └────────────┬───────────┘
                           ▼
              ┌────────────────────────┐
              │ 1e. Location filter    │  Skip VMs not in -SourceLocations
              │     (if specified)     │  → "Not in location(s): eastus2"
              └────────────┬───────────┘
                           ▼
              ┌────────────────────────┐
              │ 1f. Target location    │  Skip VMs already in -TargetLocation
              │     exclusion          │  → "VM is already in target location"
              └────────────┬───────────┘
                           ▼
              ┌────────────────────────┐
              │ 1g. Already-protected  │  Azure Resource Graph query across
              │     check              │  ALL vaults, ALL subscriptions
              │                        │  → "Already protected in vault: X"
              └────────────┬───────────┘
                           ▼
        ═══════════════════════════════════
          Phase 2 starts — vault check/create
        ═══════════════════════════════════
                           ▼
              ┌────────────────────────┐
              │ 1h. Vault location     │  Only if vault ALREADY EXISTS and its
              │     exclusion          │  location ≠ TargetLocation:
              │                        │  Skip VMs in the vault's location
              │                        │  → "VM is in vault location 'eastus'"
              └────────────┬───────────┘
                           ▼
              ┌────────────────────────┐
              │  FINAL VM LIST         │  These VMs proceed to intent creation
              │  (all others skipped   │
              │   with reasons)        │
              └────────────────────────┘
```

**Key behaviours:**
- The **RG path** (only `-SourceResourceGroupNames`, no VM list) fetches VMs via `Get-AzVM -ResourceGroupName`, so locations are already known — steps 1b, 1c, 1d are skipped.
- The **VM path** (VM list given) applies all filters sequentially.
- CSV VMs are merged with `-VMResourceIds` before filtering begins.
- Step **1h** only triggers when the vault pre-exists in a location different from `-TargetLocation`. If the vault is new (just created), it's in `-TargetLocation` and this step is a no-op.
- All skipped VMs appear in the summary table with their skip reason.

### Smart Resource Management

The script follows a **check → reuse → create → verify** pattern for all target resources:

| Resource | Auto-Created Name | Reuse Logic |
|---|---|---|
| **Recovery Services Vault** | *(user-specified `VaultName`)* | If exists in target RG → reuse; otherwise create in target location |
| **Replication Policy** | `asrscript-15-days-retention-asr-replication-policy` | If exists in vault → reuse; otherwise create with settings below |
| **Automation Account** | `asrscript-automation-<6-char-random>` | If `-AutomationAccountArmId` provided → use it; otherwise create a new one with SystemAssignedIdentity + assign **Contributor** role on vault. **Tip:** On the first run, note the automation account ARM ID from the output and pass it via `-AutomationAccountArmId` on subsequent runs to reuse it. Uses `-AutomationAccountLocation` if specified (not all regions support Azure Automation). |
| **Virtual Network** | `asrscript-target-vnet-<targetlocation>` | If exists in target RG and in correct location -> reuse; if in wrong location -> create new with random suffix. VNet must be in the target region for ASR replication. |

**Replication Policy Settings:**
- Recovery point retention: 15 days (21600 minutes)
- Crash-consistent snapshot frequency: 5 minutes
- App-consistent snapshot frequency: disabled (0)
- Multi-VM sync: Enabled

### VM Skip Reasons

VMs are automatically skipped (not an error) when:

| Reason | Example |
|---|---|
| Wrong subscription | VM is in a different subscription than `-SubscriptionId` |
| Wrong resource group | `-SourceResourceGroupNames` specified but VM is in a different RG |
| Wrong location | `-SourceLocations` specified but VM is in a different region |
| Already in target location | VM is in the same region as `-TargetLocation` |
| In vault location | Vault pre-exists in a location ≠ `-TargetLocation`, and VM is in the vault's location |
| Already protected | Azure Resource Graph shows VM is protected in any vault |
| VM not found | ARM ID is invalid or VM was deleted |

Skipped VMs are always reported in the summary with their reason.

---

## Output

### Console Output

The script prints a structured summary:

```
════════════════════════════════════════════════════════════════
  SUMMARY
════════════════════════════════════════════════════════════════

  Processed : 5
  Succeeded : 4
  Failed    : 0
  Skipped   : 1
  Policy    : /subscriptions/.../replicationPolicies/asrscript-15-days-retention-asr-replication-policy

VMName  SourceLocation  Status             JobId     PolicyId
------  --------------  ------             -----     --------
vm1     eastus2         EnableSucceeded    abc-123   /subs/.../policy
vm2     eastus2         EnableSucceeded    def-456   /subs/.../policy
vm3     centralus       EnableSucceeded    ghi-789   /subs/.../policy
vm4     eastus2         EnableSucceeded    jkl-012   /subs/.../policy

Skipped VMs:
VMName  Reason
------  ------
vm5     Already protected (state: Protected) in vault: other-vault
```

### CSV Output (`-OutputCsvPath`)

| Column | Description |
|---|---|
| `VMName` | VM name |
| `SourceLocation` | Source Azure region |
| `VMResourceId` | Full ARM resource ID |
| `Status` | `EnableSucceeded`, `EnablePartiallySucceeded`, `EnableFailed`, `EnableTimedOut`, `Accepted`, `Failed`, `DryRun`, `Skipped` |
| `IRStatus` | Initial Replication state (if `-MonitorIR` used): `Protected`, `EnablingProtection`, etc. |
| `ReplicationHealth` | `Normal`, `Warning`, `Critical` |
| `JobId` | ASR job ID for the intent |
| `IntentName` | Protection intent resource name |
| `PolicyId` | Replication policy ARM ID |
| `SkipReason` | Why the VM was skipped (empty for processed VMs) |

### Pipeline Return Object

The script returns a `List[PSCustomObject]` with all columns above, usable in pipelines:

```powershell
$results = .\Enable-ASRReplication.ps1 -SubscriptionId "..." -VaultName "..." ...
$results | Where-Object Status -eq "Failed" | ForEach-Object { Write-Host "Retry: $($_.VMName)" }
```

---

## DryRun Mode

Use `-DryRun` to validate your inputs without creating any resources. The script will:

1. ✅ Resolve and filter VMs (real API calls to fetch VM info)
2. ✅ Check if vault/automation/VNet exist (read-only)
3. ✅ Check Azure Resource Graph for already-protected VMs
4. ✅ Build the full JSON request body for each VM
5. ❌ **Will NOT** create vault, automation account, VNet, policy, or protection intents

The JSON body for each VM is printed so you can inspect exactly what would be sent.

---

---

## Troubleshooting

| Issue | Resolution |
|---|---|
| `Not logged in. Run Connect-AzAccount first.` | Run `Connect-AzAccount` and ensure you're in the correct tenant |
| `No VMs matched the provided filters` | Check your `-SubscriptionId`, RG names, and location filters |
| `Vault was created but not accessible` | Azure provisioning delay — retry or check Azure portal |
| `Policy creation failed` | Ensure the vault is fully provisioned; check ASR service health |
| `Resource Graph query failed` | Install `Az.ResourceGraph` module: `Install-Module Az.ResourceGraph` |
| Automation account creation fails (region not supported) | Not all Azure regions support Automation. Re-run with `-AutomationAccountLocation "eastus2"` (or any supported region) |
| VMs skipped as "Already protected" | VM is replicated in another vault — disable protection there first if you want to re-protect |

### Automation Account & Role Assignment Permissions

If you see a warning like:

```
Role assignment failed: Operation returned an invalid status code 'BadRequest'
```

This means your account does not have permission to assign the **Contributor** role to the automation account's managed identity on the vault. The script will **continue with replication** — this role is only needed for ASR's [mobility agent auto-update](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-autoupdate) feature, not for the initial replication itself.

**To resolve:**

1. **Option A — Pre-create and pass as input:** Ask your admin to create an automation account with a system-assigned managed identity and grant it Contributor on the vault. Then pass it to the script:
   ```powershell
   -AutomationAccountArmId "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Automation/automationAccounts/<name>"
   ```

2. **Option B — Fix after the run:** Ask an admin with `Microsoft.Authorization/roleAssignments/write` permission to run:
   ```powershell
   New-AzRoleAssignment -ObjectId '<PrincipalId>' -RoleDefinitionName 'Contributor' -Scope '<VaultArmId>'
   ```
   The PrincipalId is shown in the script's warning output.

For more details on auto-update configuration, see: [Manage mobility agent updates](https://learn.microsoft.com/en-us/azure/site-recovery/azure-to-azure-autoupdate)
