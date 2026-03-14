<#
.SYNOPSIS
    Install dataprotection extension from wheel and test enable-backup with Custom strategy.

.DESCRIPTION
    1. Uninstalls existing dataprotection extension
    2. Installs from local wheel build
    3. Creates a backup vault (LRS, SystemAssigned) in the specified region
    4. Creates an AKS backup policy (30d op-store + 90d vault-store)
    5. Runs az dataprotection enable-backup trigger with Custom strategy

.PARAMETER VaultRegion
    Azure region for backup vault (e.g., westus2, eastasia, eastus2euap)

.PARAMETER ClusterId
    Full ARM resource ID of the AKS cluster to protect

.PARAMETER ResourceGroup
    Resource group for backup vault

.PARAMETER Subscription
    Subscription ID

.PARAMETER WheelPath
    Path to the .whl file (default: auto-detect from dist/)

.PARAMETER Tags
    Hashtable of tags (default: standard test tags)

.EXAMPLE
    .\enable-backup-e2e-aks.ps1 -VaultRegion eastasia -ClusterId "/subscriptions/xxxx/resourceGroups/my-rg/providers/Microsoft.ContainerService/managedClusters/my-cluster" -ResourceGroup "my-rg" -Subscription "xxxx"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VaultRegion,

    [Parameter(Mandatory=$true)]
    [string]$ClusterId,

    [string]$VaultName = "",

    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$true)]
    [string]$Subscription,

    [string]$WheelPath = "",

    [hashtable]$Tags = @{}
)

$ErrorActionPreference = "Stop"
if (-not $VaultName) { $VaultName = "test-vault-$VaultRegion" }
$policyName = "test-policy-30d-90d"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Enable Backup E2E Test Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Vault Region: $VaultRegion"
Write-Host "Cluster:      $ClusterId"
Write-Host "RG:           $ResourceGroup"
Write-Host "Subscription: $Subscription"
Write-Host "Vault:        $vaultName"
Write-Host "Policy:       $policyName"
Write-Host ""

# ---- Step 1: Uninstall and Install Extension ----
Write-Host "[1/5] Installing dataprotection extension from wheel..." -ForegroundColor Yellow

az extension remove -n dataprotection 2>$null
$removed = az extension show -n dataprotection 2>&1
if ($removed -match "not found" -or $removed -match "not installed") {
    Write-Host "  Extension removed successfully"
} else {
    Write-Host "  Warning: Extension may still be present"
}

if (-not $WheelPath) {
    $WheelPath = (Get-ChildItem "$PSScriptRoot\..\src\dataprotection\dist\*.whl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    if (-not $WheelPath) {
        # Try from repo root
        $WheelPath = (Get-ChildItem "$PSScriptRoot\..\..\src\dataprotection\dist\*.whl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }
}

if (-not $WheelPath -or -not (Test-Path $WheelPath)) {
    Write-Host "  ERROR: Wheel file not found. Build it first:" -ForegroundColor Red
    Write-Host "    cd src/dataprotection && python setup.py bdist_wheel"
    exit 1
}

Write-Host "  Wheel: $WheelPath"
az extension add --source $WheelPath --yes 2>$null

$version = az extension show -n dataprotection --query version -o tsv 2>$null
Write-Host "  Installed version: $version" -ForegroundColor Green

# Install k8s-extension if not present
$k8sExt = az extension show -n k8s-extension --query version -o tsv 2>$null
if (-not $k8sExt) {
    Write-Host "  Installing k8s-extension..." -ForegroundColor Yellow
    az extension add -n k8s-extension --yes 2>$null
    Write-Host "  k8s-extension installed" -ForegroundColor Green
} else {
    Write-Host "  k8s-extension already installed (v$k8sExt)"
}

# ---- Step 2: Set Subscription ----
Write-Host ""
Write-Host "[2/5] Setting subscription..." -ForegroundColor Yellow
az account set -s $Subscription 2>$null
$currentSub = az account show --query id -o tsv 2>$null
Write-Host "  Active subscription: $currentSub"

# ---- Step 3: Create Backup Vault ----
Write-Host ""
Write-Host "[3/5] Creating backup vault: $vaultName in $VaultRegion..." -ForegroundColor Yellow

$existingVault = az dataprotection backup-vault show -g $ResourceGroup --vault-name $vaultName --query name -o tsv 2>$null
if ($existingVault -eq $vaultName) {
    Write-Host "  Vault already exists, skipping creation"
} else {
    $tagArgs = ($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "
    az dataprotection backup-vault create `
        -g $ResourceGroup `
        --vault-name $vaultName `
        -l $VaultRegion `
        --storage-settings datastore-type="VaultStore" type="LocallyRedundant" `
        --mi-system-assigned `
        --soft-delete-state On `
        --tags $tagArgs `
        -o none 2>$null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to create vault" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Vault created successfully" -ForegroundColor Green

    # Enable Cross Region Backup via REST API (preview feature, not in CLI yet)
    Write-Host "  Enabling Cross Region Backup settings..." -ForegroundColor Yellow
    $apiVersion = "2025-08-15-preview"
    $vaultResourceId = "/subscriptions/$Subscription/resourceGroups/$ResourceGroup/providers/Microsoft.DataProtection/BackupVaults/$vaultName"
    $vaultUri = "https://management.azure.com${vaultResourceId}?api-version=$apiVersion"

    $armToken = (az account get-access-token --resource "https://management.azure.com" --output json 2>$null | ConvertFrom-Json).accessToken
    $armHeaders = @{ "Authorization" = "Bearer $armToken"; "Content-Type" = "application/json" }

    $existingVaultJson = Invoke-RestMethod -Method GET -Uri $vaultUri -Headers $armHeaders
    $updateBody = @{
        location   = $existingVaultJson.location
        identity   = $existingVaultJson.identity
        properties = @{
            storageSettings            = $existingVaultJson.properties.storageSettings
            isVaultProtectedByResourceGuard = $existingVaultJson.properties.isVaultProtectedByResourceGuard
            securitySettings           = @{
                softDeleteSettings = @{
                    state                   = $existingVaultJson.properties.securitySettings.softDeleteSettings.state
                    retentionDurationInDays = $existingVaultJson.properties.securitySettings.softDeleteSettings.retentionDurationInDays
                }
            }
            crossRegionBackupSettings  = "Enabled"
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Method PUT -Uri $vaultUri -Headers $armHeaders -Body $updateBody | Out-Null
        Write-Host "  Cross Region Backup enabled" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not enable Cross Region Backup (may not be supported in $VaultRegion): $($_.Exception.Message.Substring(0, [Math]::Min(150, $_.Exception.Message.Length)))" -ForegroundColor DarkYellow
    }
}

$vaultId = az dataprotection backup-vault show -g $ResourceGroup --vault-name $vaultName --query id -o tsv 2>$null
Write-Host "  Vault ID: $vaultId"

# ---- Step 4: Create Backup Policy ----
Write-Host ""
Write-Host "[4/5] Creating backup policy: $policyName..." -ForegroundColor Yellow

$existingPolicy = az dataprotection backup-policy show -g $ResourceGroup --vault-name $vaultName -n $policyName --query name -o tsv 2>$null
if ($existingPolicy -eq $policyName) {
    Write-Host "  Policy already exists, skipping creation"
} else {
    $policyJson = @{
        objectType = "BackupPolicy"
        datasourceTypes = @("Microsoft.ContainerService/managedClusters")
        policyRules = @(
            @{
                isDefault = $true
                lifecycles = @(
                    @{
                        deleteAfter = @{ duration = "P30D"; objectType = "AbsoluteDeleteOption" }
                        sourceDataStore = @{ dataStoreType = "OperationalStore"; objectType = "DataStoreInfoBase" }
                        targetDataStoreCopySettings = @(
                            @{
                                copyAfter = @{ objectType = "ImmediateCopyOption" }
                                dataStore = @{ dataStoreType = "VaultStore"; objectType = "DataStoreInfoBase" }
                            }
                        )
                    },
                    @{
                        deleteAfter = @{ duration = "P90D"; objectType = "AbsoluteDeleteOption" }
                        sourceDataStore = @{ dataStoreType = "VaultStore"; objectType = "DataStoreInfoBase" }
                        targetDataStoreCopySettings = @()
                    }
                )
                name = "Default"
                objectType = "AzureRetentionRule"
            },
            @{
                backupParameters = @{ backupType = "Incremental"; objectType = "AzureBackupParams" }
                dataStore = @{ dataStoreType = "OperationalStore"; objectType = "DataStoreInfoBase" }
                name = "BackupDaily"
                objectType = "AzureBackupRule"
                trigger = @{
                    objectType = "ScheduleBasedTriggerContext"
                    schedule = @{
                        repeatingTimeIntervals = @("R/2024-01-01T00:00:00+00:00/P1D")
                        timeZone = "Coordinated Universal Time"
                    }
                    taggingCriteria = @(
                        @{
                            isDefault = $true
                            tagInfo = @{ id = "Default_"; tagName = "Default" }
                            taggingPriority = 99
                        }
                    )
                }
            }
        )
    } | ConvertTo-Json -Depth 20 -Compress

    $policyFile = [System.IO.Path]::GetTempFileName() + ".json"
    $policyJson | Set-Content -Path $policyFile -Encoding utf8

    az dataprotection backup-policy create `
        -g $ResourceGroup `
        --vault-name $vaultName `
        -n $policyName `
        --policy "@$policyFile" `
        -o none 2>$null

    Remove-Item $policyFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to create policy" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Policy created successfully" -ForegroundColor Green
}

$policyId = az dataprotection backup-policy show -g $ResourceGroup --vault-name $vaultName -n $policyName --query id -o tsv 2>$null
Write-Host "  Policy ID: $policyId"

# ---- Step 5: Run Enable Backup ----
Write-Host ""
Write-Host "[5/5] Running enable-backup trigger..." -ForegroundColor Yellow

$configFile = [System.IO.Path]::GetTempFileName() + ".json"
$tagsJson = $Tags | ConvertTo-Json -Compress
$config = @{
    backupVaultId = $vaultId
    backupPolicyId = $policyId
    tags = $Tags
} | ConvertTo-Json -Depth 5

$config | Set-Content -Path $configFile -Encoding utf8
Write-Host "  Config: $configFile"
Write-Host "  Strategy: Custom"
Write-Host ""

az dataprotection enable-backup trigger `
    --datasource-type AzureKubernetesService `
    --datasource-id $ClusterId `
    --backup-strategy Custom `
    --backup-configuration-file "@$configFile"

$exitCode = $LASTEXITCODE
Remove-Item $configFile -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  TEST PASSED" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  TEST FAILED (exit code: $exitCode)" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
}

exit $exitCode
