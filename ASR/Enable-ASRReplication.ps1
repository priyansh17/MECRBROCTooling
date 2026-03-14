<#
.SYNOPSIS
    Enables Azure Site Recovery (A2A) replication for one or more Azure VMs using the
    Create Protection Intent REST API.

.DESCRIPTION
    This script automates the ASR A2A "Create Protection Intent" workflow:
      - Flexible VM selection: resource group names, location list, VM ARM ID list, or
        any combination. The script resolves, filters, and reports skipped VMs.
      - All VMs must be in the specified source subscription. VMs in other subscriptions
        are reported as "Skipped" (not in subscription).
      - Checks Azure Resource Graph to detect VMs already protected in any vault.
      - Smart resource management: auto-creates or reuses vault, replication policy,
        automation account (with Contributor role on vault), and virtual network in the target region.
      - All resource creations are verified with exponential-backoff retry.
      - Fire-all-then-poll: submits all intents first, then polls enable-replication
        jobs until completed. Token auto-refreshes during polling.
      - Optional IR monitoring: tracks Initial Replication progress until Protected.
      - Exports results to CSV with full status details.

    VM Selection Logic:
      - RG names only              → All VMs in those RGs (within source subscription).
      - RG names + Location list   → All VMs in those RGs filtered to those locations.
      - VM list only               → VMs in the source subscription; others are skipped.
      - VM list + RG names         → VMs from the list in those RGs; others are skipped.
      - VM list + Location list    → VMs from the list in those locations; others skipped.
      - VM list + RG + Location    → VMs matching all three; others are skipped.
      - CSV file                   → Loaded as the VM list, then same filters apply.

    Prerequisites:
      - Az PowerShell module (Az.Accounts, Az.Resources, Az.Compute, Az.Network,
        Az.RecoveryServices, Az.Automation, Az.ResourceGraph)
      - Logged in via Connect-AzAccount
      - Contributor role on the source resource group(s) (to read VMs)
      - Contributor role on the target resource group (to create vault, automation
        account, virtual network, replication policy, and protection intents)

.PARAMETER SubscriptionId
    Source subscription ID containing the VMs. Required.

.PARAMETER VaultName
    Name of the Recovery Services vault. If it exists in the target RG, it is reused.
    If it does not exist, a new vault is created in the target location.

.PARAMETER TargetResourceGroupName
    Resource group name for the vault and recovered VMs (in the target subscription).
    The RG must already exist.

.PARAMETER TargetLocation
    Target / DR region (e.g. "swedencentral"). Required. Used for vault creation (if needed)
    and as the recovery location for replication. VMs already in this location are skipped.

.PARAMETER TargetSubscriptionId
    Target subscription for the vault and recovery resources. Defaults to SubscriptionId.

.PARAMETER SourceResourceGroupNames
    Array of source resource group names (not ARM IDs). VMs are fetched from these RGs
    within the source subscription.
    Example: @("app-rg", "db-rg")

.PARAMETER SourceLocations
    Array of Azure region names to filter VMs by location.
    Example: @("eastus2", "centralus")

.PARAMETER VMResourceIds
    Array of full ARM resource IDs of VMs to protect. VMs not in the source subscription
    are reported as skipped.
    Example: @("/subscriptions/.../providers/Microsoft.Compute/virtualMachines/vm1")

.PARAMETER VMResourceIdsCsvPath
    Path to a CSV file with a column named "VMResourceId" listing VMs to protect.
    Can be combined with -SourceResourceGroupNames and -SourceLocations for filtering.

.PARAMETER RecoveryVirtualNetworkId
    Full ARM ID of the target virtual network. Optional -- if omitted, auto-creates or
    reuses a VNet named "asrscript-target-vnet-<targetlocation>" in the target RG.
    If found but in wrong location, creates a new one with a random suffix.

.PARAMETER RecoverySubnetName
    Subnet name in the target virtual network. Defaults to "default".

.PARAMETER RecoveryAvailabilityType
    One of: Single (default), AvailabilitySet, AvailabilityZone.

.PARAMETER RecoveryAvailabilitySetId
    ARM ID of target availability set. Required when RecoveryAvailabilityType = AvailabilitySet.

.PARAMETER RecoveryAvailabilityZone
    Target availability zone (e.g. "1"). Required when RecoveryAvailabilityType = AvailabilityZone.

.PARAMETER RecoveryProximityPlacementGroupId
    ARM ID of target proximity placement group. Optional.

.PARAMETER CacheStorageAccountId
    ARM ID of the cache (staging) storage account in the source region. Optional.

.PARAMETER RecoveryBootDiagStorageAccountId
    ARM ID of the boot diagnostics storage account in the recovery region. Optional.

.PARAMETER AutoProtectionOfDataDisk
    Enabled or Disabled. Default: Enabled.

.PARAMETER AutomationAccountArmId
    ARM ID of an existing Automation Account for agent auto-updates. Optional.
    If not provided, one named "asrscript-automation-<6-char-random>" is created in the target RG.
    To reuse an existing account on subsequent runs, pass its ARM ID here.

.PARAMETER AutomationAccountLocation
    Azure region for auto-created automation account. Optional. Defaults to TargetLocation.
    Use this if TargetLocation does not support Azure Automation (e.g., northeurope might not).
    Example: -AutomationAccountLocation "westeurope"

.PARAMETER ApiVersion
    REST API version. Default: 2025-08-01.

.PARAMETER MonitorIR
    If set, monitors Initial Replication progress after enable-replication jobs complete.
    Enable-replication job monitoring runs automatically after intent submission (minutes).
    With -MonitorIR: also polls replicationProtectedItems to track IR progress (hours).

.PARAMETER MaxIRPollMinutes
    Maximum minutes to monitor IR progress. Default: 180 (3 hours).
    IR can take hours depending on disk size, so set this accordingly.

.PARAMETER OutputCsvPath
    Path to export results as a CSV file. Includes all columns: VMName, SourceLocation,
    Status, IRStatus, JobId, PolicyId, SkipReason.
    If omitted, no CSV is written.

.PARAMETER DryRun
    If set, runs through the full flow (VM resolution, vault check, policy check,
    request body construction) but does NOT call any mutating APIs. Prints the
    JSON body that would be sent for each VM.

.EXAMPLE
    # Protect all VMs in two resource groups
    .\Enable-ASRReplication.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultName "my-vault" `
        -TargetResourceGroupName "dr-rg" `
        -TargetLocation "swedencentral" `
        -SourceResourceGroupNames @("app-rg", "db-rg")

.EXAMPLE
    # Protect VMs in specific RGs but only in eastus2
    .\Enable-ASRReplication.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultName "my-vault" `
        -TargetResourceGroupName "dr-rg" `
        -TargetLocation "swedencentral" `
        -SourceResourceGroupNames @("app-rg") `
        -SourceLocations @("eastus2")

.EXAMPLE
    # Protect specific VMs with target network (cross-subscription)
    .\Enable-ASRReplication.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultName "my-vault" `
        -TargetResourceGroupName "dr-rg" `
        -TargetLocation "swedencentral" `
        -TargetSubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
        -VMResourceIds @(
            "/subscriptions/xxx/resourceGroups/src-rg/providers/Microsoft.Compute/virtualMachines/vm1",
            "/subscriptions/xxx/resourceGroups/src-rg/providers/Microsoft.Compute/virtualMachines/vm2"
        ) `
        -RecoveryVirtualNetworkId "/subscriptions/yyy/resourceGroups/dr-rg/providers/Microsoft.Network/virtualNetworks/dr-vnet" `
        -RecoverySubnetName "default"

.EXAMPLE
    # From a VM list, only protect those in a specific RG and location (others are skipped)
    .\Enable-ASRReplication.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultName "my-vault" `
        -TargetResourceGroupName "dr-rg" `
        -TargetLocation "swedencentral" `
        -VMResourceIds @(
            "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1",
            "/subscriptions/other-sub/resourceGroups/rg2/providers/Microsoft.Compute/virtualMachines/vm2",
            "/subscriptions/xxx/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm3"
        ) `
        -SourceResourceGroupNames @("rg1") `
        -SourceLocations @("eastus2")

.EXAMPLE
    # Protect VMs from CSV (polls all intents after submission)
    .\Enable-ASRReplication.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultName "my-vault" `
        -TargetResourceGroupName "dr-rg" `
        -TargetLocation "swedencentral" `
        -VMResourceIdsCsvPath ".\vms.csv"

.EXAMPLE
    # Without IR monitoring (polls enable-replication jobs, then exits)
    .\Enable-ASRReplication.ps1 `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultName "my-vault" `
        -TargetResourceGroupName "dr-rg" `
        -TargetLocation "swedencentral" `
        -SourceResourceGroupNames @("app-rg")
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$VaultName,

    [Parameter(Mandatory)]
    [string]$TargetResourceGroupName,

    [Parameter(Mandatory)]
    [string]$TargetLocation,

    [Parameter()]
    [string]$TargetSubscriptionId,

    # ── Source VM selection (at least one of SourceResourceGroupNames or VMResourceIds/CSV must be provided) ──
    [Parameter()]
    [string[]]$SourceResourceGroupNames,

    [Parameter()]
    [string[]]$SourceLocations,

    [Parameter()]
    [string[]]$VMResourceIds,

    [Parameter()]
    [string]$VMResourceIdsCsvPath,

    [Parameter()]
    [string]$RecoveryVirtualNetworkId,

    [Parameter()]
    [string]$RecoverySubnetName,

    [Parameter()]
    [ValidateSet("Single", "AvailabilitySet", "AvailabilityZone")]
    [string]$RecoveryAvailabilityType = "Single",

    [Parameter()]
    [string]$RecoveryAvailabilitySetId,

    [Parameter()]
    [string]$RecoveryAvailabilityZone,

    [Parameter()]
    [string]$RecoveryProximityPlacementGroupId,

    [Parameter()]
    [string]$CacheStorageAccountId,

    [Parameter()]
    [string]$RecoveryBootDiagStorageAccountId,

    [Parameter()]
    [ValidateSet("Enabled", "Disabled")]
    [string]$AutoProtectionOfDataDisk = "Enabled",

    [Parameter()]
    [string]$AutomationAccountArmId,

    [Parameter()]
    [string]$AutomationAccountLocation,

    [Parameter()]
    [string]$ApiVersion = "2025-08-01",

    [Parameter()]
    [switch]$MonitorIR,

    [Parameter()]
    [int]$MaxIRPollMinutes = 180,

    [Parameter()]
    [string]$OutputCsvPath,

    [Parameter()]
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Validate OutputCsvPath parent directory exists upfront (don't wait until end of script)
if ($OutputCsvPath) {
    $csvDir = Split-Path $OutputCsvPath -Parent
    if ($csvDir -and -not (Test-Path $csvDir)) {
        throw "Output CSV directory does not exist: '$csvDir'. Create it first or use a different -OutputCsvPath."
    }
}

#region ── Helpers ──

function Get-DetailedErrorMessage {
    <#
        Extracts the best available error message from an Az cmdlet exception.
        Az SDK wraps HTTP errors and discards the response body from .Message.
        The real detail is in .Exception.Body (parsed) or .ErrorDetails.Message (raw).
    #>
    param([Parameter(Mandatory)]$ErrorRecord)

    # 1. Try .Exception.Body (Azure SDK parsed response — has Code + Message)
    try {
        if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Body) {
            $body = $ErrorRecord.Exception.Body
            if ($body.Message) { return $body.Message }
            if ($body.Code)    { return "$($body.Code): $(($body | ConvertTo-Json -Depth 3 -Compress))" }
        }
    } catch { }

    # 2. Try .ErrorDetails.Message (Invoke-WebRequest / Invoke-RestMethod errors)
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $parsed = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed.error.message) { return $parsed.error.message }
            if ($parsed.Message)       { return $parsed.Message }
            return $ErrorRecord.ErrorDetails.Message
        }
    } catch { }

    # 3. Try InnerException chain
    try {
        $inner = $ErrorRecord.Exception.InnerException
        while ($inner) {
            if ($inner.Message -and $inner.Message -ne $ErrorRecord.Exception.Message) {
                return $inner.Message
            }
            $inner = $inner.InnerException
        }
    } catch { }

    # 4. Fall back to Exception.Message or string representation
    if ($ErrorRecord.Exception) { return $ErrorRecord.Exception.Message }
    return "$ErrorRecord"
}

function Wait-ResourceReady {
    <#
        Exponential-backoff retry loop to verify a resource is accessible after creation.
        Retries: 5s, 10s, 20s, 40s, 80s, 160s... up to MaxSeconds (default 300 = 5 min).
    #>
    param(
        [scriptblock]$CheckScript,   # should return $true when resource is ready
        [string]$ResourceName,
        [int]$MaxSeconds = 300       # 5 minutes default
    )

    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    $delay = 5

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $delay
        try {
            $ready = & $CheckScript
            if ($ready) { return $true }
        }
        catch {
            # Resource not yet available
        }

        $elapsed = [math]::Round(((Get-Date) - $deadline.AddSeconds(-$MaxSeconds)).TotalSeconds, 0)
        Write-Host "    Waiting for $ResourceName (${elapsed}s elapsed, next check in ${delay}s)..." -ForegroundColor DarkGray
        $delay = [Math]::Min($delay * 2, 60)  # cap individual wait at 60s
    }

    throw "$ResourceName was created but not accessible after ${MaxSeconds}s. Check Azure portal."
}

function Get-ArmToken {
    <# Gets a Bearer token for ARM using the current Az context. #>
    $context = Get-AzContext
    if (-not $context) {
        throw "Not logged in. Run Connect-AzAccount first."
    }
    $tokenResult = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    # Az module 12+ returns SecureString; older versions return plain string
    if ($tokenResult.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $tokenResult.Token).Password
    }
    return $tokenResult.Token
}

# Script-scoped token that polling functions can refresh when expired
$script:currentToken      = $null
$script:tokenAcquiredAt   = [datetime]::MinValue

function Get-FreshToken {
    <# Returns a valid ARM token, refreshing if older than 4 minutes (tokens expire ~5 min). #>
    $age = (Get-Date) - $script:tokenAcquiredAt
    if (-not $script:currentToken -or $age.TotalMinutes -gt 4) {
        $script:currentToken    = Get-ArmToken
        $script:tokenAcquiredAt = Get-Date
        Write-Host "  (token refreshed)" -ForegroundColor DarkGray
    }
    return $script:currentToken
}

function Invoke-ArmRequest {
    <# Sends a REST request to ARM and returns the response + async operation URL. #>
    param(
        [string]$Method,
        [string]$Uri,
        [string]$Body,
        [string]$Token
    )

    $headers = @{
        "Authorization" = "Bearer $Token"
        "Content-Type"  = "application/json"
    }

    $params = @{
        Method  = $Method
        Uri     = $Uri
        Headers = $headers
    }
    if ($Body) { $params["Body"] = $Body }

    try {
        $response = Invoke-WebRequest @params -UseBasicParsing
        $content  = $response.Content | ConvertFrom-Json

        $asyncUrl = $null
        if ($response.Headers["Azure-AsyncOperation"]) {
            $asyncUrl = $response.Headers["Azure-AsyncOperation"]
            if ($asyncUrl -is [array]) { $asyncUrl = $asyncUrl[0] }
        }

        return [PSCustomObject]@{
            StatusCode     = $response.StatusCode
            Content        = $content
            AsyncOperation = $asyncUrl
        }
    }
    catch {
        $errMsg = Get-DetailedErrorMessage $_
        $errBody = $null
        if ($_.ErrorDetails) {
            try { $errBody = $_.ErrorDetails.Message } catch {}
        }
        if ($errBody) {
            try { $errBody = ($errBody | ConvertFrom-Json | ConvertTo-Json -Depth 10) } catch {}
        }
        Write-Error "ARM request failed [$Method $Uri]: $errMsg`n$errBody"
        throw
    }
}



function Watch-EnableReplication {
    <#
        Polls ASR replication jobs until all reach a terminal state (Succeeded/Failed/Cancelled).
        The intent PUT returns a jobId; that job tracks the "enable replication" phase (minutes, not hours).
        Returns a hashtable: VMName -> { State, DisplayName, StartTime, EndTime }.
    #>
    param(
        [PSCustomObject[]]$Jobs,   # array of @{ VMName; JobName }
        [string]$VaultUrl,
        [string]$Token,
        [string]$ApiVersion,
        [int]$MaxMinutes = 30
    )

    if ($Jobs.Count -eq 0) { return @{} }

    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    $delay    = 15
    $jobResults = @{}
    $pending = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($j in $Jobs) { $pending.Add($j) }

    Write-Host "`n==============================================================" -ForegroundColor Cyan
    Write-Host "  ENABLE REPLICATION -- JOB MONITORING" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  Tracking $($Jobs.Count) job(s) -- max ${MaxMinutes}m" -ForegroundColor DarkGray
    Write-Host ""

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $delay

        # Refresh token before each poll cycle
        $Token = Get-FreshToken

        $stillPending = [System.Collections.Generic.List[PSCustomObject]]::new()
        $statusLines  = @()

        foreach ($job in $pending) {
            $jobUri = "https://management.azure.com${VaultUrl}/replicationJobs/$($job.JobName)?api-version=$ApiVersion"

            try {
                $jobResponse = Invoke-ArmRequest -Method GET -Uri $jobUri -Token $Token
                $jobProps = if ($jobResponse.Content.PSObject.Properties.Name -contains 'properties') { $jobResponse.Content.properties } else { $null }

                $state       = if ($jobProps -and $jobProps.PSObject.Properties.Name -contains 'state') { $jobProps.state } else { "Unknown" }
                $displayName = if ($jobProps -and $jobProps.PSObject.Properties.Name -contains 'displayName') { $jobProps.displayName } else { $job.VMName }
                $startTime   = if ($jobProps -and $jobProps.PSObject.Properties.Name -contains 'startTime') { $jobProps.startTime } else { $null }
                $endTime     = if ($jobProps -and $jobProps.PSObject.Properties.Name -contains 'endTime') { $jobProps.endTime } else { $null }

                $jobResults[$job.VMName] = @{
                    State       = $state
                    DisplayName = $displayName
                    StartTime   = $startTime
                    EndTime     = $endTime
                }

                if ($state -in @("InProgress", "NotStarted")) {
                    $stillPending.Add($job)
                    $statusLines += "  [~] $($job.VMName): $state"
                }
                elseif ($state -eq "Succeeded") {
                    $statusLines += "  [OK] $($job.VMName): Enable replication succeeded"
                }
                elseif ($state -eq "PartiallySucceeded") {
                    $statusLines += "  [!] $($job.VMName): PartiallySucceeded (completed with warnings)"
                }
                else {
                    $statusLines += "  [X] $($job.VMName): $state"
                }
            }
            catch {
                $safeMsg = Get-DetailedErrorMessage $_
                $statusLines += "  [?] $($job.VMName): poll error -- $safeMsg"
                $stillPending.Add($job)
            }
        }

        $pending = $stillPending

        $timestamp = (Get-Date).ToString("HH:mm:ss")
        Write-Host "  [$timestamp] Job Status:" -ForegroundColor DarkGray
        foreach ($line in $statusLines) {
            $color = if ($line -match "\[OK\]") { "Green" }
                     elseif ($line -match "\[X\]") { "Red" }
                     elseif ($line -match "\[\?\]") { "DarkYellow" }
                     else { "Cyan" }
            Write-Host $line -ForegroundColor $color
        }

        if ($pending.Count -gt 0) {
            Write-Host "  ... $($pending.Count) job(s) still in progress" -ForegroundColor DarkGray
        }
        else {
            Write-Host "`n  All enable-replication jobs have completed." -ForegroundColor Green
        }

        if ($delay -lt 30) { $delay = [Math]::Min($delay + 5, 30) }
    }

    # Mark timed-out jobs
    foreach ($job in $pending) {
        $jobResults[$job.VMName] = @{
            State       = "TimedOut"
            DisplayName = $job.VMName
            StartTime   = $null
            EndTime     = $null
        }
        Write-Host "  [!] $($job.VMName): job monitoring timed out after ${MaxMinutes}m" -ForegroundColor Yellow
    }

    return $jobResults
}

function Watch-InitialReplication {
    <#
        Monitors IR progress for VMs by polling the vault's replicationProtectedItems list.
        Returns a hashtable: VMName -> { Status, Progress, ReplicationHealth }.
    #>
    param(
        [hashtable]$VMMap,  # VMName -> VMResourceId
        [string]$VaultUrl,
        [string]$Token,
        [string]$ApiVersion,
        [int]$MaxMinutes = 180
    )

    if ($VMMap.Count -eq 0) { return @{} }

    # Build reverse lookup: normalized VM ARM ID -> VMName
    $idToName = @{}
    foreach ($kvp in $VMMap.GetEnumerator()) {
        $idToName[$kvp.Value.ToLower()] = $kvp.Key
    }

    $deadline  = (Get-Date).AddMinutes($MaxMinutes)
    $delay     = 30   # seconds between poll cycles
    $irResults = @{}
    $pending   = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $VMMap.Keys) { $pending.Add($k) }

    Write-Host "`n==============================================================" -ForegroundColor Cyan
    Write-Host "  INITIAL REPLICATION MONITORING" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  Tracking $($VMMap.Count) VM(s) -- max ${MaxMinutes}m" -ForegroundColor DarkGray
    Write-Host ""

    $listUri = "https://management.azure.com${VaultUrl}/replicationProtectedItems?api-version=$ApiVersion"

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $delay

        # Refresh token before each poll cycle
        $Token = Get-FreshToken

        # Fetch all protected items (handle pagination via nextLink)
        $allItems = @()
        try {
            $nextUri = $listUri
            while ($nextUri) {
                $listResponse = Invoke-ArmRequest -Method GET -Uri $nextUri -Token $Token
                if ($listResponse.Content.PSObject.Properties.Name -contains 'value') {
                    $allItems += @($listResponse.Content.value)
                }
                $nextUri = if ($listResponse.Content.PSObject.Properties.Name -contains 'nextLink') { $listResponse.Content.nextLink } else { $null }
            }
        }
        catch {
            $safeMsg = Get-DetailedErrorMessage $_
            Write-Warning "  Failed to list protected items: $safeMsg. Retrying..."
            continue
        }

        # Build a lookup by fabricObjectId (VM ARM ID) from providerSpecificDetails
        $itemsByVmId = @{}
        foreach ($item in $allItems) {
            $itemProps = if ($item.PSObject.Properties.Name -contains 'properties') { $item.properties } else { $null }
            if (-not $itemProps) { continue }
            $psd = if ($itemProps.PSObject.Properties.Name -contains 'providerSpecificDetails') { $itemProps.providerSpecificDetails } else { $null }
            if ($psd -and ($psd.PSObject.Properties.Name -contains 'fabricObjectId')) {
                $fid = $psd.fabricObjectId
                if ($fid) { $itemsByVmId[$fid.ToLower()] = $item }
            }
        }

        $stillPending = [System.Collections.Generic.List[string]]::new()
        $statusLines  = @()

        foreach ($vmName in $pending) {
            $vmArmId = $VMMap[$vmName].ToLower()
            if (-not $itemsByVmId.ContainsKey($vmArmId)) {
                # VM not yet visible as a protected item (may still be provisioning)
                $stillPending.Add($vmName)
                $statusLines += "  [.] ${vmName}: waiting to appear as protected item"
                if (-not $irResults.ContainsKey($vmName)) {
                    $irResults[$vmName] = @{ Status = "Provisioning"; Progress = "0%"; ReplicationHealth = "N/A" }
                }
                continue
            }

            $item  = $itemsByVmId[$vmArmId]
            $props = $item.properties

            # Safe property access helper — returns $null if property missing
            $state     = if ($props.PSObject.Properties.Name -contains 'protectionState') { $props.protectionState } else { $null }
            $stateDesc = if ($props.PSObject.Properties.Name -contains 'protectionStateDescription') { $props.protectionStateDescription } else { "Unknown" }
            $health    = if ($props.PSObject.Properties.Name -contains 'replicationHealth') { $props.replicationHealth } else { "N/A" }

            # For A2A, compute aggregate IR progress from managed disks
            $progress = "N/A"
            $a2aDetails = if ($props.PSObject.Properties.Name -contains 'providerSpecificDetails') { $props.providerSpecificDetails } else { $null }
            if ($a2aDetails -and ($a2aDetails.PSObject.Properties.Name -contains 'protectedManagedDisks') -and $a2aDetails.protectedManagedDisks) {
                $disks = @($a2aDetails.protectedManagedDisks)
                if ($disks.Count -gt 0) {
                    $totalPct = 0
                    foreach ($d in $disks) {
                        $pct = 0
                        if ($d.PSObject.Properties.Name -contains 'monitoringPercentageCompletion') {
                            $pct = [int]($d.monitoringPercentageCompletion -as [int])
                        }
                        $totalPct += $pct
                    }
                    $avgPct = [math]::Round($totalPct / $disks.Count, 0)
                    $progress = "${avgPct}%"
                }
            }

            $irResults[$vmName] = @{
                Status            = $stateDesc
                Progress          = $progress
                ReplicationHealth = $health
            }

            if ($state -eq "Protected") {
                $statusLines += "  [OK] ${vmName}: Protected (IR complete)"
            }
            elseif ($state -in @("ProtectionError", "RepairReplication")) {
                $statusLines += "  [X] ${vmName}: $stateDesc (health: $health)"
            }
            else {
                $stillPending.Add($vmName)
                $statusLines += "  [~] ${vmName}: $stateDesc"
            }
        }

        $pending = $stillPending

        # Print status update
        $timestamp = (Get-Date).ToString("HH:mm:ss")
        Write-Host "  [$timestamp] IR Status:" -ForegroundColor DarkGray
        foreach ($line in $statusLines) {
            $color = if ($line -match "\[OK\]") { "Green" }
                     elseif ($line -match "\[X\]") { "Red" }
                     elseif ($line -match "\[\.\]") { "DarkYellow" }
                     else { "Cyan" }
            Write-Host $line -ForegroundColor $color
        }

        if ($pending.Count -gt 0) {
            Write-Host "  ... $($pending.Count) still replicating" -ForegroundColor DarkGray
        }
        else {
            Write-Host "`n  All VMs have completed Initial Replication." -ForegroundColor Green
        }

        # Increase delay over time (30s → 60s)
        if ($delay -lt 60) { $delay = [Math]::Min($delay + 10, 60) }
    }

    # Mark anything still pending as timed-out
    foreach ($vmName in $pending) {
        if ($irResults.ContainsKey($vmName)) {
            $irResults[$vmName].Status = "IR TimedOut ($($irResults[$vmName].Status))"
        }
        else {
            $irResults[$vmName] = @{ Status = "IR TimedOut"; Progress = "N/A"; ReplicationHealth = "N/A" }
        }
        Write-Host "  [!] ${vmName}: IR monitoring timed out after ${MaxMinutes}m" -ForegroundColor Yellow
    }

    return $irResults
}

function Get-VmNameFromId {
    param([string]$ResourceId)
    return ($ResourceId -split "/")[-1]
}

#endregion

#region ── Resolve VM List ──

# Load VMs from CSV if provided
if ($VMResourceIdsCsvPath) {
    if (-not (Test-Path $VMResourceIdsCsvPath)) {
        throw "CSV file not found: $VMResourceIdsCsvPath"
    }
    $csv = Import-Csv $VMResourceIdsCsvPath
    if (-not ($csv | Get-Member -Name "VMResourceId" -ErrorAction SilentlyContinue)) {
        throw "CSV must contain a column named 'VMResourceId'."
    }
    $csvIds = $csv.VMResourceId | Where-Object { $_ -and $_.Trim() }
    if ($VMResourceIds) {
        $VMResourceIds = @($VMResourceIds) + @($csvIds)
    }
    else {
        $VMResourceIds = $csvIds
    }
}

# Validate that at least one source input is provided
if (-not $VMResourceIds -and -not $SourceResourceGroupNames) {
    throw "You must provide at least one of: -VMResourceIds, -VMResourceIdsCsvPath, or -SourceResourceGroupNames."
}

# Normalise location names to lowercase for comparison
$normalizedLocations = @()
if ($SourceLocations) {
    $normalizedLocations = @($SourceLocations | ForEach-Object { $_.ToLower().Replace(" ", "") })
}

# Normalise RG names to lowercase for comparison
$normalizedRgNames = @()
if ($SourceResourceGroupNames) {
    $normalizedRgNames = @($SourceResourceGroupNames | ForEach-Object { $_.ToLower().Trim() })
}

# Helper: extract RG name from a VM resource ID
function Get-RgNameFromVmId {
    param([string]$VmId)
    if ($VmId -match "(?i)/resourceGroups/([^/]+)/") {
        return $Matches[1].ToLower()
    }
    return $null
}

# Helper: extract subscription ID from a VM resource ID
function Get-SubFromVmId {
    param([string]$VmId)
    return ($VmId -split "/")[2].ToLower()
}

# Set Az context to source subscription once
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop 3>$null | Out-Null

# Track skipped VMs for the summary
$skippedVms = [System.Collections.Generic.List[PSCustomObject]]::new()

# ── Case 1: No VM list provided → fetch VMs from RG names ──
if (-not $VMResourceIds) {
    Write-Host "Fetching VMs from $($SourceResourceGroupNames.Count) resource group(s) in subscription $SubscriptionId..." -ForegroundColor DarkGray

    $fetchedVms = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($rgName in $SourceResourceGroupNames) {
        try {
            $vmsInRg = @(Get-AzVM -ResourceGroupName $rgName -ErrorAction Stop 3>$null)
            foreach ($v in $vmsInRg) { $fetchedVms.Add($v) }
            Write-Host "  $rgName -> $($vmsInRg.Count) VM(s)" -ForegroundColor DarkGray
        }
        catch {
            $safeMsg = Get-DetailedErrorMessage $_
            Write-Warning "  Could not list VMs in RG '$rgName': $safeMsg"
        }
    }

    # Filter by location if provided
    if ($normalizedLocations.Count -gt 0) {
        $filtered   = [System.Collections.Generic.List[PSObject]]::new()
        foreach ($v in $fetchedVms) {
            if ($normalizedLocations -contains $v.Location.ToLower().Replace(" ", "")) {
                $filtered.Add($v)
            }
            else {
                $skippedVms.Add([PSCustomObject]@{
                    VMName   = $v.Name
                    VMResourceId = $v.Id
                    Reason   = "Not in location(s): $($SourceLocations -join ', ')"
                })
            }
        }
        $fetchedVms = $filtered
        Write-Host "  After location filter ($($SourceLocations -join ', ')): $($fetchedVms.Count) VM(s)" -ForegroundColor DarkGray
    }

    # Build resolved list with location already known
    $resolvedVms = @($fetchedVms | ForEach-Object {
        [PSCustomObject]@{ VMResourceId = $_.Id; Location = $_.Location }
    })
}
# ── Case 2: VM list provided → filter by subscription, then optionally by RG and/or location ──
else {
    $allVmIds = @($VMResourceIds | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $normalizedSubId = $SubscriptionId.ToLower()

    # Step 1: Filter out VMs not in the source subscription
    $inSubVmIds = [System.Collections.Generic.List[string]]::new()
    foreach ($vmId in $allVmIds) {
        $vmSub = Get-SubFromVmId $vmId
        if ($vmSub -eq $normalizedSubId) {
            $inSubVmIds.Add($vmId)
        }
        else {
            $skippedVms.Add([PSCustomObject]@{
                VMName       = (Get-VmNameFromId $vmId)
                VMResourceId = $vmId
                Reason       = "Not in subscription $SubscriptionId"
            })
        }
    }
    Write-Host "  Subscription filter: $($allVmIds.Count) -> $($inSubVmIds.Count) VM(s)" -ForegroundColor DarkGray

    # Step 2: Filter by RG names if provided
    if ($normalizedRgNames.Count -gt 0) {
        $rgFiltered = [System.Collections.Generic.List[string]]::new()
        foreach ($vmId in $inSubVmIds) {
            $rgName = Get-RgNameFromVmId $vmId
            if ($rgName -and ($normalizedRgNames -contains $rgName)) {
                $rgFiltered.Add($vmId)
            }
            else {
                $skippedVms.Add([PSCustomObject]@{
                    VMName       = (Get-VmNameFromId $vmId)
                    VMResourceId = $vmId
                    Reason       = "Not in RG(s): $($SourceResourceGroupNames -join ', ')"
                })
            }
        }
        $inSubVmIds = $rgFiltered
        Write-Host "  RG filter: -> $($inSubVmIds.Count) VM(s)" -ForegroundColor DarkGray
    }

    # Step 3: Fetch each VM to get its location
    Write-Host "  Resolving VM locations..." -ForegroundColor DarkGray
    $resolvedVms = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($vmId in $inSubVmIds) {
        try {
            $vm = Get-AzVM -ResourceId $vmId -ErrorAction Stop 3>$null
            $resolvedVms.Add([PSCustomObject]@{
                VMResourceId = $vmId
                Location     = $vm.Location
            })
        }
        catch {
            $safeMsg = Get-DetailedErrorMessage $_
            Write-Warning "  Could not fetch VM $vmId -- skipping. Error: $safeMsg"
            $skippedVms.Add([PSCustomObject]@{
                VMName       = (Get-VmNameFromId $vmId)
                VMResourceId = $vmId
                Reason       = "Failed to fetch: $safeMsg"
            })
        }
    }

    # Step 4: Filter by location if provided
    if ($normalizedLocations.Count -gt 0) {
        $locFiltered = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($entry in $resolvedVms) {
            if ($normalizedLocations -contains $entry.Location.ToLower().Replace(" ", "")) {
                $locFiltered.Add($entry)
            }
            else {
                $skippedVms.Add([PSCustomObject]@{
                    VMName       = (Get-VmNameFromId $entry.VMResourceId)
                    VMResourceId = $entry.VMResourceId
                    Reason       = "Not in location(s): $($SourceLocations -join ', ')"
                })
            }
        }
        $resolvedVms = $locFiltered
        Write-Host "  Location filter ($($SourceLocations -join ', ')): -> $($resolvedVms.Count) VM(s)" -ForegroundColor DarkGray
    }
}

if ($resolvedVms.Count -eq 0) {
    Write-Host ""
    if ($skippedVms.Count -gt 0) {
        Write-Host "Skipped VMs:" -ForegroundColor Yellow
        $skippedVms | Format-Table VMName, Reason -AutoSize
    }
    throw "No VMs matched the provided filters. Check your -SubscriptionId, -SourceResourceGroupNames, -SourceLocations, and -VMResourceIds."
}

#endregion

#region ── Target subscription & vault ──

# Default target subscription to source if not provided
if (-not $TargetSubscriptionId) {
    $TargetSubscriptionId = $SubscriptionId
}

# Normalise target location for comparison
$normalizedTargetLocation = $TargetLocation.ToLower().Replace(" ", "")

# Skip VMs that are already in the target location (can't replicate to same location)
$locationOkVms = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($entry in $resolvedVms) {
    $vmLoc = $entry.Location.ToLower().Replace(" ", "")
    if ($vmLoc -eq $normalizedTargetLocation) {
        $skippedVms.Add([PSCustomObject]@{
            VMName       = (Get-VmNameFromId $entry.VMResourceId)
            VMResourceId = $entry.VMResourceId
            Reason       = "VM is already in target location '$TargetLocation'"
        })
        Write-Host "  [X] $(Get-VmNameFromId $entry.VMResourceId) -- already in target location $TargetLocation, skipping" -ForegroundColor Yellow
    }
    else {
        $locationOkVms.Add($entry)
    }
}
$resolvedVms = $locationOkVms

#region ── Check for Already-Protected VMs (Azure Resource Graph) ──

if ($resolvedVms.Count -gt 0) {
    Write-Host "`nChecking if any VMs are already protected by ASR..." -ForegroundColor DarkGray

    # Build the list of VM ARM IDs for the query
    $vmIdList = ($resolvedVms | ForEach-Object { "'$($_.VMResourceId.ToLower())'" }) -join ", "

    $argQuery = @"
recoveryservicesresources
| where type == "microsoft.recoveryservices/vaults/replicationfabrics/replicationprotectioncontainers/replicationprotecteditems"
| where isnotempty(properties.providerSpecificDetails.fabricObjectId)
| extend fabricObjectId = tolower(tostring(properties.providerSpecificDetails.fabricObjectId))
| where fabricObjectId in~ ($vmIdList)
| extend vaultId = tostring(split(id, "/replicationFabrics/")[0])
| extend protectionState = tostring(properties.protectionState)
| project fabricObjectId, vaultId, protectionState
"@

    try {
        $graphResponse = Search-AzGraph -Query $argQuery -First 1000
        # Search-AzGraph returns PSResourceGraphResponse; .Data holds the actual rows
        $protectedItems = @($graphResponse.Data)

        if ($protectedItems.Count -gt 0) {
            # Build lookup: lowercase VM ARM ID → vault info
            # Search-AzGraph returns hashtable-like rows; use indexer for strict mode safety
            $protectedLookup = @{}
            foreach ($item in $protectedItems) {
                $fId   = "$($item.fabricObjectId)".ToLower()
                $vId   = "$($item.vaultId)"
                $pState = "$($item.protectionState)"
                $protectedLookup[$fId] = @{
                    VaultId         = $vId
                    ProtectionState = $pState
                }
            }

            # Filter out already-protected VMs
            $unprotectedVms = [System.Collections.Generic.List[PSCustomObject]]::new()
            foreach ($entry in $resolvedVms) {
                $key = $entry.VMResourceId.ToLower()
                if ($protectedLookup.ContainsKey($key)) {
                    $info = $protectedLookup[$key]
                    $protectingVault = ($info.VaultId -split "/")[-1]
                    $skippedVms.Add([PSCustomObject]@{
                        VMName       = (Get-VmNameFromId $entry.VMResourceId)
                        VMResourceId = $entry.VMResourceId
                        Reason       = "Already protected (state: $($info.ProtectionState)) in vault: $protectingVault"
                    })
                    Write-Host "  [X] $(Get-VmNameFromId $entry.VMResourceId) -- already protected in vault '$protectingVault' ($($info.ProtectionState)), skipping" -ForegroundColor Yellow
                }
                else {
                    $unprotectedVms.Add($entry)
                }
            }
            $resolvedVms = $unprotectedVms
            Write-Host "  $($protectedLookup.Count) VM(s) already protected, $($resolvedVms.Count) remaining" -ForegroundColor DarkGray
        }
        else {
            Write-Host "  [OK] No VMs are currently protected" -ForegroundColor Green
        }
    }
    catch {
        $safeMsg = Get-DetailedErrorMessage $_
        Write-Warning "  Resource Graph query failed: $safeMsg. Skipping pre-check -- will proceed with all VMs."
    }
}

if ($resolvedVms.Count -eq 0) {
    Write-Host ""
    if ($skippedVms.Count -gt 0) {
        Write-Host "Skipped VMs:" -ForegroundColor Yellow
        $skippedVms | Format-Table VMName, Reason -AutoSize
    }
    throw "No VMs remaining after filtering. Nothing to replicate."
}

#endregion

# Build the recovery resource group ARM ID from target RG/subscription
$RecoveryResourceGroupId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName"

#region ── Build Vault URL ──

$vaultUrl = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName" +
            "/providers/Microsoft.RecoveryServices/vaults/$VaultName"

#endregion

# Switch to target subscription to check/create vault
Set-AzContext -SubscriptionId $TargetSubscriptionId -ErrorAction Stop 3>$null | Out-Null

# Verify target resource group exists
$targetRg = Get-AzResourceGroup -Name $TargetResourceGroupName -ErrorAction SilentlyContinue 3>$null
if (-not $targetRg) {
    throw "Target resource group '$TargetResourceGroupName' does not exist in subscription '$TargetSubscriptionId'. Create it first, then re-run the script."
}

# Validate user-provided ARM resource IDs exist before proceeding
# (Avoids silent failures deep in the workflow when the API accepts bad IDs)
$armIdsToValidate = @()
if ($AutomationAccountArmId)            { $armIdsToValidate += @{ Name = "AutomationAccountArmId";            Id = $AutomationAccountArmId } }
if ($RecoveryVirtualNetworkId)          { $armIdsToValidate += @{ Name = "RecoveryVirtualNetworkId";          Id = $RecoveryVirtualNetworkId } }
if ($RecoveryAvailabilitySetId)         { $armIdsToValidate += @{ Name = "RecoveryAvailabilitySetId";         Id = $RecoveryAvailabilitySetId } }
if ($RecoveryProximityPlacementGroupId) { $armIdsToValidate += @{ Name = "RecoveryProximityPlacementGroupId"; Id = $RecoveryProximityPlacementGroupId } }
if ($RecoveryBootDiagStorageAccountId)  { $armIdsToValidate += @{ Name = "RecoveryBootDiagStorageAccountId";  Id = $RecoveryBootDiagStorageAccountId } }
if ($CacheStorageAccountId)             { $armIdsToValidate += @{ Name = "CacheStorageAccountId";             Id = $CacheStorageAccountId } }

foreach ($item in $armIdsToValidate) {
    Write-Host "Validating -$($item.Name)..." -ForegroundColor DarkGray
    $resource = Get-AzResource -ResourceId $item.Id -ErrorAction SilentlyContinue 3>$null
    if (-not $resource) {
        throw "Resource not found for -$($item.Name): '$($item.Id)'. Verify the ARM ID is correct and you have read access."
    }
    Write-Host "  [OK] $($item.Id)" -ForegroundColor Green
}

# Validate subnet exists in VNet and VNet is in target location (if both provided)
if ($RecoveryVirtualNetworkId) {
    Write-Host "Validating provided VNet location and subnet..." -ForegroundColor DarkGray
    try {
        $vnetRg   = ($RecoveryVirtualNetworkId -split "/resourceGroups/")[1] -split "/" | Select-Object -First 1
        $vnetName = ($RecoveryVirtualNetworkId -split "/")[-1]
        $vnet = Get-AzVirtualNetwork -ResourceGroupName $vnetRg -Name $vnetName -ErrorAction Stop 3>$null

        # Check VNet is in target location
        $vnetLocation = $vnet.Location.ToLower().Replace(" ", "")
        if ($vnetLocation -ne $normalizedTargetLocation) {
            throw "VNet '$vnetName' is in '$($vnet.Location)' but target location is '$TargetLocation'. The recovery VNet must be in the target region."
        }
        Write-Host "  [OK] VNet location matches target: $($vnet.Location)" -ForegroundColor Green

        # Check subnet exists
        if ($RecoverySubnetName) {
            $subnetNames = @($vnet.Subnets | ForEach-Object { $_.Name })
            if ($subnetNames -notcontains $RecoverySubnetName) {
                throw "Subnet '$RecoverySubnetName' not found in VNet '$vnetName'. Available subnets: $($subnetNames -join ', ')"
            }
            Write-Host "  [OK] Subnet '$RecoverySubnetName' found" -ForegroundColor Green
        }
    }
    catch {
        $safeMsg = Get-DetailedErrorMessage $_
        if ($safeMsg -match "must be in the target region|Subnet .* not found") { throw }
        Write-Warning "  Could not validate VNet: $safeMsg. Proceeding anyway."
    }
}

Write-Host "`nChecking vault '$VaultName' in RG '$TargetResourceGroupName'..." -ForegroundColor DarkGray
$existingVault = $null
try {
    $existingVault = Get-AzRecoveryServicesVault -ResourceGroupName $TargetResourceGroupName -Name $VaultName -ErrorAction Stop
}
catch {
    # Vault doesn't exist -- will create
}

if ($existingVault) {
    $vaultLocation = $existingVault.Location
    Write-Host "  Vault found in location: $vaultLocation" -ForegroundColor Green

    # If vault location differs from target location, warn but still use TargetLocation
    $normalizedVaultLocation = $vaultLocation.ToLower().Replace(" ", "")
    if ($normalizedVaultLocation -ne $normalizedTargetLocation) {
        Write-Host "  Note: Vault location ($vaultLocation) differs from target location ($TargetLocation)." -ForegroundColor DarkYellow
    }
}
else {
    if ($DryRun) {
        Write-Host "  [DryRun] Vault not found -- WOULD create '$VaultName' in '$TargetResourceGroupName' ($TargetLocation)" -ForegroundColor Magenta
    }
    else {
        Write-Host "  Vault not found -- creating '$VaultName' in '$TargetResourceGroupName' ($TargetLocation)..." -ForegroundColor Cyan
        $existingVault = New-AzRecoveryServicesVault `
            -ResourceGroupName $TargetResourceGroupName `
            -Name $VaultName `
            -Location $TargetLocation `
            -ErrorAction Stop

        Wait-ResourceReady -ResourceName "Vault '$VaultName'" -MaxSeconds 300 -CheckScript {
            $v = Get-AzRecoveryServicesVault -ResourceGroupName $TargetResourceGroupName -Name $VaultName -ErrorAction SilentlyContinue 3>$null
            if ($v) { return $true } else { return $false }
        }
        Write-Host "  [OK] Vault created and verified" -ForegroundColor Green
    }
}

# Recovery location is always the customer-specified target location
$RecoveryLocation = $TargetLocation

#region ── Filter VMs in vault location (if vault location ≠ target location) ──

if ($existingVault) {
    $normalizedVaultLocation = $existingVault.Location.ToLower().Replace(" ", "")
    if ($normalizedVaultLocation -ne $normalizedTargetLocation) {
        # Vault is in a different location than the target -- skip any VMs that are in the vault's location
        $vaultLocFilteredVms = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($entry in $resolvedVms) {
            $vmLoc = $entry.Location.ToLower().Replace(" ", "")
            if ($vmLoc -eq $normalizedVaultLocation) {
                $skippedVms.Add([PSCustomObject]@{
                    VMName       = (Get-VmNameFromId $entry.VMResourceId)
                    VMResourceId = $entry.VMResourceId
                    Reason       = "VM is in vault location '$($existingVault.Location)' (vault location != target location '$TargetLocation')"
                })
                Write-Host "  [X] $(Get-VmNameFromId $entry.VMResourceId) -- in vault location $($existingVault.Location), skipping" -ForegroundColor Yellow
            }
            else {
                $vaultLocFilteredVms.Add($entry)
            }
        }

        if ($vaultLocFilteredVms.Count -lt $resolvedVms.Count) {
            $droppedCount = $resolvedVms.Count - $vaultLocFilteredVms.Count
            Write-Host "  $droppedCount VM(s) skipped (in vault location), $($vaultLocFilteredVms.Count) remaining" -ForegroundColor DarkGray
        }
        $resolvedVms = $vaultLocFilteredVms

        if ($resolvedVms.Count -eq 0) {
            Write-Host ""
            if ($skippedVms.Count -gt 0) {
                Write-Host "Skipped VMs:" -ForegroundColor Yellow
                $skippedVms | Format-Table VMName, Reason -AutoSize
            }
            throw "No VMs remaining after vault-location filtering. Nothing to replicate."
        }
    }
}

#endregion

#region ── Resolve or Create Automation Account ──
# (still on target subscription context from vault section above)

# Automation account names must be unique per subscription (6-50 chars, letters/numbers/hyphens, start with letter)
$randomSuffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$automationAccountName = "asrscript-automation-$randomSuffix"
# Automation accounts are not available in all regions; allow override
$autoAcctLocation = if ($AutomationAccountLocation) { $AutomationAccountLocation } else { $TargetLocation }

$automationAccountPreExisted = $false

if ($AutomationAccountArmId) {
    Write-Host "Using provided automation account: $AutomationAccountArmId" -ForegroundColor DarkGray
    $automationAccountPreExisted = $true
    # Extract account name from ARM ID for role assignment lookup
    $automationAccountName = ($AutomationAccountArmId -split "/")[-1]
}
else {
    if ($DryRun) {
        $AutomationAccountArmId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName"
        Write-Host "  [DryRun] WOULD create automation account '$automationAccountName' in '$TargetResourceGroupName' ($autoAcctLocation)" -ForegroundColor Magenta
    }
    else {
        Write-Host "  Creating automation account '$automationAccountName' in '$TargetResourceGroupName' ($autoAcctLocation)..." -ForegroundColor Cyan
        try {
            New-AzAutomationAccount `
                -ResourceGroupName $TargetResourceGroupName `
                -Name $automationAccountName `
                -Location $autoAcctLocation `
                -ErrorAction Stop | Out-Null

            # Enable system-assigned identity separately (matches ASR test repo pattern)
            Write-Host "  Enabling system-assigned identity..." -ForegroundColor DarkGray
            Set-AzAutomationAccount `
                -ResourceGroupName $TargetResourceGroupName `
                -Name $automationAccountName `
                -AssignSystemIdentity `
                -ErrorAction Stop | Out-Null
        }
        catch {
            $errMsg = Get-DetailedErrorMessage $_
            if (($errMsg -match "not available|not supported|LocationNotAvailable") -and -not $AutomationAccountLocation) {
                throw "Automation account creation failed in '$autoAcctLocation' (region may not support Azure Automation).`nRe-run with -AutomationAccountLocation '<supported-region>' (e.g., 'eastus2', 'westeurope').`nOriginal error: $errMsg"
            }
            throw "Automation account creation failed in '$autoAcctLocation': $errMsg"
        }

        Wait-ResourceReady -ResourceName "Automation account '$automationAccountName'" -MaxSeconds 300 -CheckScript {
            $a = Get-AzAutomationAccount -ResourceGroupName $TargetResourceGroupName -Name $automationAccountName -ErrorAction SilentlyContinue 3>$null
            if ($a) { return $true } else { return $false }
        }
        $AutomationAccountArmId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName"
        Write-Host "  [OK] Automation account created and verified: $AutomationAccountArmId" -ForegroundColor Green

        # Wait for managed identity to propagate in AAD before role assignment
        Write-Host "  Waiting 30s for managed identity AAD propagation..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 30
    }

    # Assign Contributor role on vault so ASR can run auto-update jobs in the automation account
    if (-not $DryRun -and $existingVault) {
        $bothPreExisted = ($automationAccountPreExisted -and $existingVault)
        Write-Host "  Ensuring Contributor role for automation account on vault..." -ForegroundColor DarkGray
        try {
            # Get the automation account's system-assigned identity PrincipalId
            $acctInfo = Get-AzAutomationAccount -ResourceGroupName $TargetResourceGroupName -Name $automationAccountName -ErrorAction Stop
            $principalId = $null
            if ($acctInfo.PSObject.Properties.Name -contains 'Identity') {
                $identity = $acctInfo.Identity
                if ($identity -and $identity.PSObject.Properties.Name -contains 'PrincipalId') {
                    $principalId = $identity.PrincipalId
                }
            }

            if ($principalId) {
                $vaultScope = $vaultUrl  # /subscriptions/.../providers/Microsoft.RecoveryServices/vaults/...
                # Retry up to 3 times with 30s wait -- identity may still be propagating
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    try {
                        $existingRole = Get-AzRoleAssignment -ObjectId $principalId -Scope $vaultScope -RoleDefinitionName "Contributor" -ErrorAction SilentlyContinue 3>$null
                        if (-not $existingRole) {
                            New-AzRoleAssignment -ObjectId $principalId -RoleDefinitionName "Contributor" -Scope $vaultScope -ErrorAction Stop 3>$null | Out-Null
                            Write-Host "  [OK] Contributor role assigned on vault" -ForegroundColor Green
                        }
                        else {
                            Write-Host "  [OK] Contributor role already assigned" -ForegroundColor Green
                        }
                        break
                    }
                    catch {
                        if ($attempt -lt 3) {
                            Write-Host "  Role assignment attempt $attempt failed -- retrying in 30s..." -ForegroundColor DarkYellow
                            Start-Sleep -Seconds 30
                        }
                        else {
                            throw  # re-throw on final attempt
                        }
                    }
                }
            }
            else {
                Write-Warning "  Could not retrieve automation account PrincipalId -- role assignment skipped. ASR auto-update may fail."
            }
        }
        catch {
            $safeMsg = Get-DetailedErrorMessage $_
            $vaultScope = $vaultUrl
            if ($bothPreExisted) {
                # Both resources were pre-existing (likely created by an admin) -- the user
                # running this script may not have Microsoft.Authorization/roleAssignments/write.
                # Treat as non-blocking: the admin should have already configured this.
                Write-Warning "  Role assignment skipped (both vault and automation account already existed)."
                Write-Warning "  If ASR auto-update fails later, ask your admin to assign Contributor role"
                Write-Warning "  for the automation account's managed identity on the vault."
                Write-Host "    (Error was: $safeMsg)" -ForegroundColor DarkGray
            }
            else {
                $pidDisplay = if ($principalId) { $principalId } else { '<PrincipalId>' }
                Write-Warning "  Role assignment failed: $safeMsg"
                Write-Warning "  The automation account's managed identity needs Contributor role on the vault"
                Write-Warning "  for ASR mobility agent auto-update to work. Ask an admin with"
                Write-Warning "  Microsoft.Authorization/roleAssignments/write to run:"
                Write-Warning "    New-AzRoleAssignment -ObjectId '$pidDisplay' -RoleDefinitionName 'Contributor' -Scope '$vaultScope'"
                Write-Warning "  Replication will proceed, but auto-update may fail until this is configured."
            }
        }
    }
}

#endregion

#region ── Resolve or Create Target Virtual Network ──

$targetVnetName   = "asrscript-target-vnet-$($TargetLocation.ToLower().Replace(' ', ''))"
$targetSubnetName = "default"

if ($RecoveryVirtualNetworkId) {
    Write-Host "Using provided target VNet: $RecoveryVirtualNetworkId" -ForegroundColor DarkGray
    if (-not $RecoverySubnetName) {
        $RecoverySubnetName = $targetSubnetName
        Write-Host "  No subnet specified -- defaulting to '$targetSubnetName'" -ForegroundColor DarkGray
    }
}
else {
    Write-Host "Checking for target VNet '$targetVnetName' in '$TargetResourceGroupName'..." -ForegroundColor DarkGray

    $existingVnet = $null
    try {
        $existingVnet = Get-AzVirtualNetwork -ResourceGroupName $TargetResourceGroupName -Name $targetVnetName -ErrorAction Stop
    }
    catch {
        # Doesn't exist
    }

    if ($existingVnet) {
        # Verify VNet is in the target location
        $vnetLoc = $existingVnet.Location.ToLower().Replace(" ", "")
        if ($vnetLoc -ne $normalizedTargetLocation) {
            # VNet exists but in wrong location — create a new one with random suffix
            Write-Host "  VNet '$targetVnetName' found but in '$($existingVnet.Location)' (expected '$TargetLocation')" -ForegroundColor DarkYellow
            $randomSuffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
            $targetVnetName = "asrscript-target-vnet-$randomSuffix"
            Write-Host "  Will create new VNet '$targetVnetName' in target location '$TargetLocation'" -ForegroundColor Cyan
            $existingVnet = $null  # force creation below
        }
        else {
            $RecoveryVirtualNetworkId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName/providers/Microsoft.Network/virtualNetworks/$targetVnetName"
            $RecoverySubnetName = $targetSubnetName
            Write-Host "  [OK] VNet found in target location: $RecoveryVirtualNetworkId" -ForegroundColor Green
        }
    }

    if (-not $existingVnet -and -not $RecoveryVirtualNetworkId) {
        if ($DryRun) {
            $RecoveryVirtualNetworkId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName/providers/Microsoft.Network/virtualNetworks/$targetVnetName"
            $RecoverySubnetName = $targetSubnetName
            Write-Host "  [DryRun] VNet not found -- WOULD create '$targetVnetName' in '$TargetResourceGroupName' ($TargetLocation) with subnet '$targetSubnetName'" -ForegroundColor Magenta
        }
        else {
            Write-Host "  Creating VNet '$targetVnetName' in '$TargetResourceGroupName' ($TargetLocation)..." -ForegroundColor Cyan
            $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $targetSubnetName -AddressPrefix "10.0.0.0/24" -ErrorAction Stop 3>$null
            New-AzVirtualNetwork `
                -ResourceGroupName $TargetResourceGroupName `
                -Name $targetVnetName `
                -Location $TargetLocation `
                -AddressPrefix "10.0.0.0/16" `
                -Subnet $subnetConfig `
                -ErrorAction Stop | Out-Null

            Wait-ResourceReady -ResourceName "VNet '$targetVnetName'" -MaxSeconds 300 -CheckScript {
                $vn = Get-AzVirtualNetwork -ResourceGroupName $TargetResourceGroupName -Name $targetVnetName -ErrorAction SilentlyContinue 3>$null
                if ($vn) { return $true } else { return $false }
            }
            $RecoveryVirtualNetworkId = "/subscriptions/$TargetSubscriptionId/resourceGroups/$TargetResourceGroupName/providers/Microsoft.Network/virtualNetworks/$targetVnetName"
            $RecoverySubnetName = $targetSubnetName
            Write-Host "  [OK] VNet created and verified: $RecoveryVirtualNetworkId" -ForegroundColor Green
        }
    }
}

# Switch back to source subscription (done with all target resource operations)
# But first acquire ARM token while still on target context (vault's subscription)
$token = $null
if (-not $DryRun) {
    Write-Host "`nAcquiring ARM token (target subscription context)..." -ForegroundColor DarkGray
    $token = Get-ArmToken
    $script:currentToken    = $token
    $script:tokenAcquiredAt = Get-Date
    Write-Host "  Token acquired." -ForegroundColor DarkGray
}

Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop 3>$null | Out-Null

#endregion
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host "|   Azure Site Recovery -- Create Protection Intent (A2A)      |" -ForegroundColor Cyan
Write-Host "+--------------------------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "Source subscription : $SubscriptionId" -ForegroundColor White
Write-Host "Target subscription : $TargetSubscriptionId" -ForegroundColor White
Write-Host "Vault               : $VaultName ($RecoveryLocation)" -ForegroundColor White
Write-Host "Target RG           : $TargetResourceGroupName" -ForegroundColor White
Write-Host "Automation account  : $AutomationAccountArmId" -ForegroundColor White
Write-Host "Target VNet         : $RecoveryVirtualNetworkId (subnet: $RecoverySubnetName)" -ForegroundColor White
Write-Host "VMs to protect      : $($resolvedVms.Count)" -ForegroundColor White
Write-Host "Recovery location   : $RecoveryLocation" -ForegroundColor White
Write-Host ""
foreach ($entry in $resolvedVms) {
    Write-Host "  * $(Get-VmNameFromId $entry.VMResourceId)  ($($entry.Location) -> $RecoveryLocation)" -ForegroundColor White
}
if ($skippedVms.Count -gt 0) {
    Write-Host ""
    Write-Host "Skipped VMs ($($skippedVms.Count)):" -ForegroundColor Yellow
    foreach ($s in $skippedVms) {
        Write-Host "  [X] $($s.VMName) -- $($s.Reason)" -ForegroundColor Yellow
    }
}
Write-Host ""

if ($DryRun) {
    Write-Host "  *** DRY RUN MODE -- no changes will be made ***" -ForegroundColor Magenta
    Write-Host ""
}

# Validate availability parameters
if ($RecoveryAvailabilityType -eq "AvailabilitySet" -and -not $RecoveryAvailabilitySetId) {
    throw "-RecoveryAvailabilitySetId is required when -RecoveryAvailabilityType is 'AvailabilitySet'."
}
if ($RecoveryAvailabilityType -eq "AvailabilityZone" -and -not $RecoveryAvailabilityZone) {
    throw "-RecoveryAvailabilityZone is required when -RecoveryAvailabilityType is 'AvailabilityZone'."
}

#endregion

#region ── Resolve or Create Replication Policy ──

$policyName = "asrscript-15-days-retention-asr-replication-policy"
$policyId   = $null
$policyUri  = "https://management.azure.com${vaultUrl}/replicationPolicies/${policyName}?api-version=$ApiVersion"

if ($DryRun) {
    Write-Host "[DryRun] Policy '$policyName' -- would check/create at runtime." -ForegroundColor Magenta
    $policyId = "${vaultUrl}/replicationPolicies/${policyName}"
}
else {
    # Step 1: Check if policy already exists
    Write-Host "Checking for existing policy '$policyName'..." -ForegroundColor DarkGray
    try {
        $policyResponse = Invoke-ArmRequest -Method GET -Uri $policyUri -Token $token
        $policyId = if ($policyResponse.Content.PSObject.Properties.Name -contains 'id') { $policyResponse.Content.id } else { "${vaultUrl}/replicationPolicies/${policyName}" }
        Write-Host "  [OK] Policy found: $policyId" -ForegroundColor Green
    }
    catch {
        # Step 2: Policy doesn't exist -- create it
        Write-Host "  Policy not found -- creating '$policyName'..." -ForegroundColor Cyan

        $policyBody = @{
            properties = @{
                providerSpecificInput = @{
                    instanceType                      = "A2A"
                    recoveryPointHistory              = 21600   # 15 days in minutes
                    crashConsistentFrequencyInMinutes = 5
                    appConsistentFrequencyInMinutes   = 0
                    multiVmSyncStatus                = "Enable"
                }
            }
        } | ConvertTo-Json -Depth 5

        $createResponse = Invoke-ArmRequest -Method PUT -Uri $policyUri -Body $policyBody -Token $token

        # Step 3: Poll until the policy is confirmed created
        $asyncUrl = $createResponse.AsyncOperation
        if ($asyncUrl) {
            Write-Host "  Waiting for policy creation to complete..." -ForegroundColor DarkGray
            $policyDeadline = (Get-Date).AddMinutes(5)
            $pollDelay = 10

            while ((Get-Date) -lt $policyDeadline) {
                Start-Sleep -Seconds $pollDelay
                $token = Get-FreshToken
                try {
                    $asyncResult = Invoke-ArmRequest -Method GET -Uri $asyncUrl -Token $token
                    $asyncStatus = if ($asyncResult.Content.PSObject.Properties.Name -contains 'status') { $asyncResult.Content.status } else { "Unknown" }
                    Write-Host "    Policy status: $asyncStatus" -ForegroundColor DarkGray

                    if ($asyncStatus -eq "Succeeded") { break }
                    if ($asyncStatus -in @("Failed", "Cancelled")) {
                        throw "Policy creation failed with status: $asyncStatus"
                    }
                }
                catch {
                    $catchMsg = Get-DetailedErrorMessage $_
                    if ($catchMsg -match "Policy creation failed") { throw }
                    Write-Warning "    Poll error: $catchMsg. Retrying..."
                }
            }
        }

        # Step 4: Confirm the policy exists and get its ID (exponential backoff)
        $verifyDeadline = (Get-Date).AddSeconds(600)  # 10 min max
        $verifyDelay = 5

        while ((Get-Date) -lt $verifyDeadline) {
            Start-Sleep -Seconds $verifyDelay
            $token = Get-FreshToken
            try {
                $policyGetResponse = Invoke-ArmRequest -Method GET -Uri $policyUri -Token $token
                $policyId = if ($policyGetResponse.Content.PSObject.Properties.Name -contains 'id') { $policyGetResponse.Content.id } else { "${vaultUrl}/replicationPolicies/${policyName}" }
                Write-Host "  [OK] Policy created and confirmed: $policyId" -ForegroundColor Green
                break
            }
            catch {
                $elapsed = [math]::Round(((Get-Date) - $verifyDeadline.AddSeconds(-600)).TotalSeconds, 0)
                Write-Host "    Waiting for policy to be available (${elapsed}s elapsed, next check in ${verifyDelay}s)..." -ForegroundColor DarkGray
                $verifyDelay = [Math]::Min($verifyDelay * 2, 60)
            }
        }

        if (-not $policyId) {
            throw "Policy '$policyName' was not accessible after 10 minutes. Check Azure portal."
        }
    }
}

#endregion

#region ── Process VMs ──

$results    = [System.Collections.Generic.List[PSCustomObject]]::new()

# Detect duplicate VM names across RGs — disambiguate intent names to avoid overwrites
$vmNameCounts = @{}
foreach ($entry in $resolvedVms) {
    $name = Get-VmNameFromId $entry.VMResourceId
    if ($vmNameCounts.ContainsKey($name)) { $vmNameCounts[$name]++ }
    else { $vmNameCounts[$name] = 1 }
}
$duplicateNames = @($vmNameCounts.Keys | Where-Object { $vmNameCounts[$_] -gt 1 })

# Group VMs by source location — ASR does fabric/container setup per source-target pair,
# so submitting different source regions concurrently can cause conflicts.
# Process one source region at a time, wait between groups.
$locationGroups = [ordered]@{}
foreach ($entry in $resolvedVms) {
    $loc = $entry.Location.ToLower().Replace(" ", "")
    if (-not $locationGroups.Contains($loc)) {
        $locationGroups[$loc] = [System.Collections.Generic.List[PSCustomObject]]::new()
    }
    $locationGroups[$loc].Add($entry)
}

$groupIndex   = 0
$totalGroups  = $locationGroups.Count
$globalVmIdx  = 0

foreach ($locKey in $locationGroups.Keys) {
    $groupVms = $locationGroups[$locKey]
    $groupIndex++

    Write-Host "`n==============================================================" -ForegroundColor Cyan
    Write-Host "  SOURCE REGION BATCH [$groupIndex/$totalGroups]: $locKey  ($($groupVms.Count) VM(s))" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan

    $batchVmIdx = 0
    foreach ($vmEntry in $groupVms) {
        $batchVmIdx++
        $globalVmIdx++

        # Wait 10 minutes before VM 2 only (fabric/container setup after first VM)
        if ($batchVmIdx -eq 2 -and -not $DryRun) {
            Write-Host "  Waiting 10 minutes for fabric/container setup..." -ForegroundColor DarkGray
            for ($w = 10; $w -gt 0; $w--) {
                Write-Host "    ${w} minute(s) remaining..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 60
                $token = Get-FreshToken
            }
        }

        $vmId       = $vmEntry.VMResourceId.Trim()
        $vmLocation = $vmEntry.Location
        $vmName     = Get-VmNameFromId $vmId
        # Use RG-vmName for intent name if duplicate VM names exist across RGs
        if ($duplicateNames -contains $vmName) {
            $rgName = Get-RgNameFromVmId $vmId
            $intentName = "$rgName-$vmName"
        }
        else {
            $intentName = $vmName
        }

    Write-Host "`n------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "[$globalVmIdx/$($resolvedVms.Count)] $vmName  (source: $vmLocation)" -ForegroundColor Cyan
    Write-Host "  VM ID: $vmId" -ForegroundColor DarkGray

    # ── Build provider-specific details ──
    $providerDetails = [ordered]@{
        instanceType                       = "A2A"
        fabricObjectId                     = $vmId
        primaryLocation                    = $vmLocation
        recoveryLocation                   = $RecoveryLocation
        recoverySubscriptionId             = $TargetSubscriptionId
        recoveryAvailabilityType           = $RecoveryAvailabilityType
        recoveryResourceGroupId            = $RecoveryResourceGroupId
        autoProtectionOfDataDisk           = $AutoProtectionOfDataDisk
        agentAutoUpdateStatus              = "Enabled"
        automationAccountAuthenticationType = "SystemAssignedIdentity"
        automationAccountArmId             = $AutomationAccountArmId
    }

    # ── Availability set / zone ──
    if ($RecoveryAvailabilityType -eq "AvailabilitySet") {
        $providerDetails["recoveryAvailabilitySetCustomInput"] = [ordered]@{
            resourceType              = "Existing"
            recoveryAvailabilitySetId = $RecoveryAvailabilitySetId
        }
    }
    if ($RecoveryAvailabilityType -eq "AvailabilityZone") {
        $providerDetails["recoveryAvailabilityZone"] = $RecoveryAvailabilityZone
    }

    # ── Virtual network (always set) ──
    $providerDetails["recoveryVirtualNetworkCustomInput"] = [ordered]@{
        resourceType             = "Existing"
        recoveryVirtualNetworkId = $RecoveryVirtualNetworkId
        recoverySubnetName       = $RecoverySubnetName
    }

    # ── Proximity placement group ──
    if ($RecoveryProximityPlacementGroupId) {
        $providerDetails["recoveryProximityPlacementGroupCustomInput"] = [ordered]@{
            resourceType                     = "Existing"
            recoveryProximityPlacementGroupId = $RecoveryProximityPlacementGroupId
        }
    }

    # ── Cache storage account ──
    if ($CacheStorageAccountId) {
        $providerDetails["primaryStagingStorageAccountCustomInput"] = [ordered]@{
            resourceType          = "Existing"
            azureStorageAccountId = $CacheStorageAccountId
        }
    }

    # ── Boot diagnostics storage account ──
    if ($RecoveryBootDiagStorageAccountId) {
        $providerDetails["recoveryBootDiagStorageAccount"] = [ordered]@{
            resourceType          = "Existing"
            azureStorageAccountId = $RecoveryBootDiagStorageAccountId
        }
    }

    # ── Policy: always use the pre-created/existing policy ──
    $providerDetails["protectionProfileCustomInput"] = [ordered]@{
        resourceType        = "Existing"
        protectionProfileId = $policyId
    }
    Write-Host "  Policy: $policyName" -ForegroundColor DarkGray

    # ── Build full request body ──
    $body = @{
        properties = @{
            providerSpecificDetails = $providerDetails
        }
    } | ConvertTo-Json -Depth 10

    # ── Send PUT request (or print in DryRun) ──
    $intentUri = "https://management.azure.com${vaultUrl}/replicationProtectionIntents/${intentName}?api-version=$ApiVersion"

    if ($DryRun) {
        Write-Host "  [DryRun] PUT $intentUri" -ForegroundColor Magenta
        Write-Host "  [DryRun] Request body:" -ForegroundColor Magenta
        Write-Host $body -ForegroundColor DarkGray
        $results.Add([PSCustomObject]@{
            VMName         = $vmName
            SourceLocation = $vmLocation
            VMResourceId   = $vmId
            Status         = "DryRun"
            JobId          = $null
            IntentName     = $intentName
            PolicyId       = $policyId
        })
    }
    else {
        Write-Host "  Sending PUT -> replicationProtectionIntents/$intentName" -ForegroundColor DarkGray

        try {
            $response = Invoke-ArmRequest -Method PUT -Uri $intentUri -Body $body -Token $token

            $respProps = if ($response.Content.PSObject.Properties.Name -contains 'properties') { $response.Content.properties } else { $null }
            $jobId    = if ($respProps -and $respProps.PSObject.Properties.Name -contains 'jobId') { $respProps.jobId } else { $null }
            $jobState = if ($respProps -and $respProps.PSObject.Properties.Name -contains 'jobState') { $respProps.jobState } else { "Accepted" }

            Write-Host "  [OK] Intent accepted -- Job: $jobState" -ForegroundColor Green

            # Extract job name from jobId (full ARM path: .../replicationJobs/guid)
            $jobName = $null
            if ($jobId) {
                $segments = $jobId -split "/"
                $jobName = $segments[-1]
            }

            $results.Add([PSCustomObject]@{
                VMName         = $vmName
                SourceLocation = $vmLocation
                VMResourceId   = $vmId
                Status         = "Accepted"
                JobId          = $jobId
                IntentName     = $intentName
                PolicyId       = $policyId
            })
        }
        catch {
            $catchMsg = Get-DetailedErrorMessage $_
            Write-Host "  [X] FAILED -- $catchMsg" -ForegroundColor Red
            $results.Add([PSCustomObject]@{
                VMName         = $vmName
                SourceLocation = $vmLocation
                VMResourceId   = $vmId
                Status         = "Failed"
                JobId          = $null
                IntentName     = $intentName
                PolicyId       = $null
            })
        }
    }
    }

    # Wait between source region batches (ASR needs time for fabric/container setup)
    if ($groupIndex -lt $totalGroups -and -not $DryRun) {
        $waitMinutes = 10
        Write-Host "`n  Waiting ${waitMinutes} minutes before next source region batch" -ForegroundColor DarkYellow
        Write-Host "  (ASR needs time for fabric/container configuration per source-target pair)" -ForegroundColor DarkGray
        for ($w = $waitMinutes; $w -gt 0; $w--) {
            Write-Host "    ${w} minute(s) remaining..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 60
            $token = Get-FreshToken
        }
        Write-Host "  Proceeding to next batch." -ForegroundColor Green
    }
}

# ── Phase 1: Poll enable-replication jobs ──
# The intent PUT creates a job that tracks the "enable replication" phase.
# This completes in minutes (not hours). After it succeeds, the VM is protected and IR begins.
$enableResults = @{}
$irResults     = @{}

if (-not $DryRun) {
    $jobsToTrack = @($results | Where-Object { $_.Status -eq "Accepted" -and $_.JobId } | ForEach-Object {
        $segments = $_.JobId -split "/"
        [PSCustomObject]@{ VMName = $_.VMName; JobName = $segments[-1] }
    })

    if ($jobsToTrack.Count -gt 0) {
        $enableResults = Watch-EnableReplication `
            -Jobs $jobsToTrack `
            -VaultUrl $vaultUrl `
            -Token $token `
            -ApiVersion $ApiVersion `
            -MaxMinutes 120

        # Update result status based on job outcome
        foreach ($r in $results) {
            if ($enableResults.ContainsKey($r.VMName)) {
                $jobState = $enableResults[$r.VMName].State
                if ($jobState -eq "Succeeded") {
                    $r.Status = "EnableSucceeded"
                }
                elseif ($jobState -eq "PartiallySucceeded") {
                    $r.Status = "EnablePartiallySucceeded"
                }
                elseif ($jobState -eq "Failed") {
                    $r.Status = "EnableFailed"
                }
                elseif ($jobState -eq "TimedOut") {
                    $r.Status = "EnableTimedOut"
                }
            }
        }
    }
}

# ── Phase 2: IR Monitoring (optional) ──
# After enable replication succeeds, IR begins. This phase tracks disk replication progress
# and can take hours. Only runs if -MonitorIR is specified.
$irEligible = @($results | Where-Object { $_.Status -in @("EnableSucceeded", "EnablePartiallySucceeded") })
$irVmMap = @{}
foreach ($r in $irEligible) { $irVmMap[$r.VMName] = $r.VMResourceId }

if ($MonitorIR -and -not $DryRun -and $irVmMap.Count -gt 0) {
    $irResults = Watch-InitialReplication `
        -VMMap $irVmMap `
        -VaultUrl $vaultUrl `
        -Token $token `
        -ApiVersion $ApiVersion `
        -MaxMinutes $MaxIRPollMinutes
}

#endregion

#region ── Summary ──

Write-Host "`n==============================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

$enableSucceeded = @($results | Where-Object { $_.Status -eq "EnableSucceeded" }).Count
$enableFailed    = @($results | Where-Object { $_.Status -eq "EnableFailed" }).Count
$accepted        = @($results | Where-Object { $_.Status -eq "Accepted" }).Count
$failed          = @($results | Where-Object { $_.Status -eq "Failed" }).Count
$dryRunCount     = @($results | Where-Object { $_.Status -eq "DryRun" }).Count

Write-Host "  Processed : $($results.Count)" -ForegroundColor White
if ($DryRun) {
    Write-Host "  DryRun    : $dryRunCount" -ForegroundColor Magenta
}
else {
    $totalFail = $enableFailed + $failed
    Write-Host "  Succeeded : $enableSucceeded" -ForegroundColor Green
    if ($accepted -gt 0) {
        Write-Host "  Accepted  : $accepted  (job not polled -- no jobId)" -ForegroundColor DarkGray
    }
    Write-Host "  Failed    : $totalFail" -ForegroundColor $(if ($totalFail -gt 0) { "Red" } else { "DarkGray" })
}
Write-Host "  Skipped   : $($skippedVms.Count)" -ForegroundColor $(if ($skippedVms.Count -gt 0) { "Yellow" } else { "DarkGray" })
Write-Host "  Policy    : $(if ($policyId) { $policyId } else { 'N/A' })" -ForegroundColor White
Write-Host ""

# Add IR columns and skipped VMs to results for final output
foreach ($r in $results) {
    $ir = if ($irResults.ContainsKey($r.VMName)) { $irResults[$r.VMName] } else { $null }
    $r | Add-Member -NotePropertyName IRStatus            -NotePropertyValue $(if ($ir) { $ir.Status } else { "N/A" }) -Force
    $r | Add-Member -NotePropertyName ReplicationHealth   -NotePropertyValue $(if ($ir) { $ir.ReplicationHealth } else { "N/A" }) -Force
    $r | Add-Member -NotePropertyName SkipReason          -NotePropertyValue $null -Force
}

if ($irResults.Count -gt 0) {
    $results | Format-Table VMName, SourceLocation, Status, IRStatus, ReplicationHealth -AutoSize
}
else {
    $results | Format-Table VMName, SourceLocation, Status, JobId, PolicyId -AutoSize
}

if ($skippedVms.Count -gt 0) {
    Write-Host "Skipped VMs:" -ForegroundColor Yellow
    $skippedVms | Format-Table VMName, Reason -AutoSize
}

# Append skipped VMs into results for pipeline/CSV consumption
foreach ($s in $skippedVms) {
    $results.Add([PSCustomObject]@{
        VMName            = $s.VMName
        SourceLocation    = "N/A"
        VMResourceId      = $s.VMResourceId
        Status            = "Skipped"
        JobId             = $null
        IntentName        = $null
        PolicyId          = $null
        IRStatus          = "N/A"
        ReplicationHealth = "N/A"
        SkipReason        = $s.Reason
    })
}

# ── Export to CSV ──
if ($OutputCsvPath) {
    $csvColumns = @("VMName", "SourceLocation", "VMResourceId", "Status", "IRStatus",
                    "ReplicationHealth", "JobId", "IntentName", "PolicyId", "SkipReason")
    $results | Select-Object $csvColumns | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Results exported to: $OutputCsvPath" -ForegroundColor Green
}

return $results

#endregion
