Set-StrictMode -Version Latest

# Remembers each storage account's original network configuration so it can be
# restored after a temporary access rule is removed. Keyed by account name.
$script:LdoStorageStateCache = @{ }

function Assert-LdoStorageExitCode {
    # Internal. Throws when the last native command exited non-zero.
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-LdoStoragePublicIpAddress {
    # Internal. Returns the caller's public IPv4 address.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $ip = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw 'Failed to determine the public IP address.'
    }
    return $ip
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

    .EXAMPLE
        Add-LdoStorageCurrentIpRule -ResourceGroup rg-prod -StorageAccountName saprod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StorageAccountName
    )

    $ip = Get-LdoStoragePublicIpAddress
    Write-LdoLog -Level INFO -Message "Current public IP: $ip"

    if (-not $script:LdoStorageStateCache.ContainsKey($StorageAccountName)) {
        $account = az storage account show -g $ResourceGroup -n $StorageAccountName -o json | ConvertFrom-Json
        Assert-LdoStorageExitCode -Operation "az storage account show ($StorageAccountName)"
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
    Assert-LdoStorageExitCode -Operation "az storage account update ($StorageAccountName)"

    $existing = az storage account network-rule list -g $ResourceGroup -n $StorageAccountName --query "[?ipAddress=='$ip']" -o tsv
    if (-not $existing) {
        az storage account network-rule add -g $ResourceGroup -n $StorageAccountName --ip-address $ip | Out-Null
        Assert-LdoStorageExitCode -Operation "az storage account network-rule add ($StorageAccountName)"
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

    .EXAMPLE
        Remove-LdoStorageCurrentIpRule -ResourceGroup rg-prod -StorageAccountName saprod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StorageAccountName
    )

    $ip = Get-LdoStoragePublicIpAddress

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
    Assert-LdoStorageExitCode -Operation "az storage account update ($StorageAccountName)"

    $script:LdoStorageStateCache.Remove($StorageAccountName) | Out-Null
    Write-LdoLog -Level INFO -Message "Restored network ACLs on $StorageAccountName."
}

Export-ModuleMember -Function `
    Add-LdoStorageCurrentIpRule, `
    Remove-LdoStorageCurrentIpRule
