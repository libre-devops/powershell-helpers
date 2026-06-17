Set-StrictMode -Version Latest

# Remembers each Key Vault's original network configuration so it can be restored
# after a temporary access rule is removed. Keyed by vault name.
$script:LdoKeyVaultStateCache = @{ }

function Assert-LdoKvExitCode {
    # Internal. Throws when the last native command exited non-zero.
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-LdoPublicIpAddress {
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

function Add-LdoKeyVaultCurrentIpRule {
    <#
    .SYNOPSIS
        Temporarily grants the caller's public IP access to a Key Vault.

    .DESCRIPTION
        Caches the vault's current network configuration on first use, enables public
        network access with a default Deny action (preserving any existing bypass), and
        adds a network rule for the caller's current public IP. Use
        Remove-LdoKeyVaultCurrentIpRule to revert.

        Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the Key Vault.

    .PARAMETER KeyVaultName
        Name of the Key Vault.

    .EXAMPLE
        Add-LdoKeyVaultCurrentIpRule -ResourceGroup rg-prod -KeyVaultName kv-prod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$KeyVaultName
    )

    $ip = Get-LdoPublicIpAddress

    if (-not $script:LdoKeyVaultStateCache.ContainsKey($KeyVaultName)) {
        $vault = az keyvault show -g $ResourceGroup -n $KeyVaultName -o json | ConvertFrom-Json
        Assert-LdoKvExitCode -Operation "az keyvault show ($KeyVaultName)"
        $script:LdoKeyVaultStateCache[$KeyVaultName] = @{
            PublicNetworkAccess = $vault.publicNetworkAccess
            DefaultAction = $vault.networkAcls.defaultAction
            Bypass = $vault.networkAcls.bypass
        }
    }

    $cached = $script:LdoKeyVaultStateCache[$KeyVaultName]
    $update = @('keyvault', 'update', '-g', $ResourceGroup, '-n', $KeyVaultName,
        '--public-network-access', 'Enabled', '--default-action', 'Deny')
    if ($cached.Bypass) { $update += @('--bypass', $cached.Bypass) }
    az @update | Out-Null
    Assert-LdoKvExitCode -Operation "az keyvault update ($KeyVaultName)"

    $existing = az keyvault network-rule list -g $ResourceGroup -n $KeyVaultName --query "[?ipAddress=='$ip']" -o tsv
    if (-not $existing) {
        az keyvault network-rule add -g $ResourceGroup -n $KeyVaultName --ip-address $ip | Out-Null
        Assert-LdoKvExitCode -Operation "az keyvault network-rule add ($KeyVaultName)"
    }

    Write-LdoLog -Level INFO -Message "Added temporary Key Vault rule for $ip on $KeyVaultName."
}

function Remove-LdoKeyVaultCurrentIpRule {
    <#
    .SYNOPSIS
        Removes the caller's temporary Key Vault access rule and restores prior settings.

    .DESCRIPTION
        Removes the network rule for the caller's current public IP and restores the vault's
        network configuration captured by Add-LdoKeyVaultCurrentIpRule. If no cached state
        exists, the vault is left with public network access disabled and a default Deny.

        Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the Key Vault.

    .PARAMETER KeyVaultName
        Name of the Key Vault.

    .EXAMPLE
        Remove-LdoKeyVaultCurrentIpRule -ResourceGroup rg-prod -KeyVaultName kv-prod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$KeyVaultName
    )

    $ip = Get-LdoPublicIpAddress

    az keyvault network-rule remove -g $ResourceGroup -n $KeyVaultName --ip-address $ip 2>$null | Out-Null

    if ($script:LdoKeyVaultStateCache.ContainsKey($KeyVaultName)) {
        $cached = $script:LdoKeyVaultStateCache[$KeyVaultName]
        $publicAccess = if ($cached.PublicNetworkAccess) { $cached.PublicNetworkAccess } else { 'Disabled' }
        $defaultAction = if ($cached.DefaultAction) { $cached.DefaultAction } else { 'Deny' }
    }
    else {
        $publicAccess = 'Disabled'
        $defaultAction = 'Deny'
        $cached = @{ Bypass = $null }
    }

    $restore = @('keyvault', 'update', '-g', $ResourceGroup, '-n', $KeyVaultName,
        '--public-network-access', $publicAccess, '--default-action', $defaultAction)
    if ($cached.Bypass) { $restore += @('--bypass', $cached.Bypass) }
    az @restore | Out-Null
    Assert-LdoKvExitCode -Operation "az keyvault update ($KeyVaultName)"

    $script:LdoKeyVaultStateCache.Remove($KeyVaultName) | Out-Null
    Write-LdoLog -Level INFO -Message "Removed temporary rule and restored network ACLs on $KeyVaultName."
}

Export-ModuleMember -Function `
    Add-LdoKeyVaultCurrentIpRule, `
    Remove-LdoKeyVaultCurrentIpRule
