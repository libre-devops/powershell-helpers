Set-StrictMode -Version Latest

# Remembers each storage account's original network configuration so it can be
# restored after a temporary access rule is removed. Keyed by account name.
$script:LdoStorageStateCache = @{ }

# Probes a storage account for the dance. Returns $true when the account exists. When it does
# not: with -SoftFail logs a WARN and returns $false (first run, the stack creates the account;
# the next run finds it and dances normally); without -SoftFail throws. Failures OTHER than
# absence always throw, so auth or network problems never masquerade as a first run.
function Test-LdoStorageDanceTarget {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$StorageAccountName,
        [switch]$SoftFail
    )

    $probe = az storage account show -g $ResourceGroup -n $StorageAccountName -o none 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }

    $text = ($probe | Out-String)
    if ($text -notmatch '(?i)notfound|could not be found|does not exist|was not found') {
        throw "az storage account show ($StorageAccountName) failed for a reason other than absence: $text"
    }

    if (-not $SoftFail) {
        throw "Storage account $StorageAccountName was not found in $ResourceGroup. Pass -SoftFail when the stack itself creates the account (first run)."
    }

    Write-LdoLog -Level WARN -Message "Storage account $StorageAccountName does not exist, so cannot append the runner IP; skipping (-SoftFail). The next run will find it and dance normally."
    return $false
}

function Add-LdoStorageCurrentIpRule {
    <#
    .SYNOPSIS
        Temporarily grants the caller's public IP access to a storage account.

    .DESCRIPTION
        Caches the account's current network configuration on first use, enables public
        network access with a default Deny action (preserving any existing bypass), and adds
        a network rule for the caller's current public IP. Existing IP and VNet rules are
        left untouched. Use Remove-LdoStorageCurrentIpRule to revert.

        Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the storage account.

    .PARAMETER StorageAccountName
        Name of the storage account.

    .PARAMETER SoftFail
        Skip (with a warning) instead of failing when the account does not exist yet, for stacks
        that create the account themselves on the first run. Absence is the only condition
        softened: any other failure still throws.

    .EXAMPLE
        Add-LdoStorageCurrentIpRule -ResourceGroup rg-prod -StorageAccountName saprod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StorageAccountName,
        [switch]$SoftFail
    )

    if (-not (Test-LdoStorageDanceTarget -ResourceGroup $ResourceGroup -StorageAccountName $StorageAccountName -SoftFail:$SoftFail)) { return }

    $ip = Get-LdoPublicIpAddress
    Write-LdoLog -Level INFO -Message "Current public IP: $ip"

    if (-not $script:LdoStorageStateCache.ContainsKey($StorageAccountName)) {
        $account = az storage account show -g $ResourceGroup -n $StorageAccountName -o json | ConvertFrom-Json
        Assert-LdoLastExitCode -Operation "az storage account show ($StorageAccountName)"
        $script:LdoStorageStateCache[$StorageAccountName] = @{
            PublicNetworkAccess = $account.publicNetworkAccess
            DefaultAction = $account.networkRuleSet.defaultAction
            Bypass = $account.networkRuleSet.bypass
        }
        Write-LdoLog -Level DEBUG -Message "Captured original network state for $StorageAccountName."
    }

    $cached = $script:LdoStorageStateCache[$StorageAccountName]
    $update = @('storage', 'account', 'update', '-g', $ResourceGroup, '-n', $StorageAccountName,
        '--public-network-access', 'Enabled', '--default-action', 'Deny')
    if ($cached.Bypass) { $update += @('--bypass', $cached.Bypass) }
    az @update | Out-Null
    Assert-LdoLastExitCode -Operation "az storage account update ($StorageAccountName)"

    $existing = az storage account network-rule list -g $ResourceGroup -n $StorageAccountName --query "[?ipAddress=='$ip']" -o tsv
    if (-not $existing) {
        az storage account network-rule add -g $ResourceGroup -n $StorageAccountName --ip-address $ip | Out-Null
        Assert-LdoLastExitCode -Operation "az storage account network-rule add ($StorageAccountName)"
        Write-LdoLog -Level INFO -Message "Added temporary storage rule for $ip on $StorageAccountName."
    }
    else {
        Write-LdoLog -Level INFO -Message "Storage rule for $ip already present on $StorageAccountName; skipping add."
    }
}

function Remove-LdoStorageCurrentIpRule {
    <#
    .SYNOPSIS
        Removes the caller's temporary storage account access rule and restores settings.

    .DESCRIPTION
        Removes the network rule for the caller's current public IP and restores the
        account's network configuration captured by Add-LdoStorageCurrentIpRule. If no
        cached state exists, the account is left with public network access disabled and a
        default Deny.

        Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the storage account.

    .PARAMETER StorageAccountName
        Name of the storage account.

    .PARAMETER SoftFail
        Skip (with a warning) instead of failing when the account does not exist, for teardown
        paths where the stack (account included) may already be destroyed. Absence is the only
        condition softened: any other failure still throws.

    .EXAMPLE
        Remove-LdoStorageCurrentIpRule -ResourceGroup rg-prod -StorageAccountName saprod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StorageAccountName,
        [switch]$SoftFail
    )

    if (-not (Test-LdoStorageDanceTarget -ResourceGroup $ResourceGroup -StorageAccountName $StorageAccountName -SoftFail:$SoftFail)) { return }

    $ip = Get-LdoPublicIpAddress

    az storage account network-rule remove -g $ResourceGroup -n $StorageAccountName --ip-address $ip 2>$null | Out-Null
    Write-LdoLog -Level INFO -Message "Removed temporary storage rule for $ip from $StorageAccountName."

    if ($script:LdoStorageStateCache.ContainsKey($StorageAccountName)) {
        $cached = $script:LdoStorageStateCache[$StorageAccountName]
        $publicAccess = if ($cached.PublicNetworkAccess) { $cached.PublicNetworkAccess } else { 'Disabled' }
        $defaultAction = if ($cached.DefaultAction) { $cached.DefaultAction } else { 'Deny' }
    }
    else {
        $publicAccess = 'Disabled'
        $defaultAction = 'Deny'
        $cached = @{ Bypass = $null }
    }

    $restore = @('storage', 'account', 'update', '-g', $ResourceGroup, '-n', $StorageAccountName,
        '--public-network-access', $publicAccess, '--default-action', $defaultAction)
    if ($cached.Bypass) { $restore += @('--bypass', $cached.Bypass) }
    az @restore | Out-Null
    Assert-LdoLastExitCode -Operation "az storage account update ($StorageAccountName)"

    $script:LdoStorageStateCache.Remove($StorageAccountName) | Out-Null
    Write-LdoLog -Level INFO -Message "Restored network ACLs on $StorageAccountName."
}

Export-ModuleMember -Function `
    Add-LdoStorageCurrentIpRule, `
    Remove-LdoStorageCurrentIpRule
