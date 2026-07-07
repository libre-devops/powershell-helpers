Set-StrictMode -Version Latest

# Remembers each Key Vault's original network configuration so it can be restored
# after a temporary access rule is removed. Keyed by vault name.
$script:LdoKeyVaultStateCache = @{ }

# Remembers vaults whose Add was skipped (-SoftFail, vault absent), so the paired Remove also
# skips instead of "restoring" a locked-down default over network ACLs the run's own apply just
# created. Keyed by vault name.
$script:LdoKeyVaultDanceSkipped = @{ }

# Probes a vault for the dance. Returns $true when the vault exists. When it does not: with
# -SoftFail logs a WARN and returns $false (first run, the stack creates the vault; the next run
# finds it and dances normally); without -SoftFail throws. Failures OTHER than absence always
# throw, so auth or network problems never masquerade as a first run. Soft-deleted vaults get a
# distinct warning: the coming apply RESURRECTS them with their previous network ACLs.
function Test-LdoKeyVaultDanceTarget {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$KeyVaultName,
        [switch]$SoftFail
    )

    $probe = az keyvault show -g $ResourceGroup -n $KeyVaultName -o none 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }

    $text = ($probe | Out-String)
    if ($text -notmatch '(?i)notfound|could not be found|does not exist|was not found') {
        throw "az keyvault show ($KeyVaultName) failed for a reason other than absence: $text"
    }

    if (-not $SoftFail) {
        throw "Key Vault $KeyVaultName was not found in $ResourceGroup. Pass -SoftFail when the stack itself creates the vault (first run)."
    }

    $deleted = az keyvault list-deleted --query "[?name=='$KeyVaultName'].name" -o tsv 2>$null
    if ($deleted) {
        Write-LdoLog -Level WARN -Message "Key Vault $KeyVaultName is SOFT-DELETED: the coming apply will resurrect it with its previous network ACLs (this runner will not be on them). Skipping (-SoftFail)."
    }
    else {
        Write-LdoLog -Level WARN -Message "Key Vault $KeyVaultName does not exist, so cannot append the runner IP; skipping (-SoftFail). The next run will find it and dance normally."
    }
    return $false
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

    .PARAMETER SoftFail
        Skip (with a warning) instead of failing when the vault does not exist yet, for stacks
        that create the vault themselves on the first run. Absence is the only condition
        softened: any other failure still throws.

    .EXAMPLE
        Add-LdoKeyVaultCurrentIpRule -ResourceGroup rg-prod -KeyVaultName kv-prod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$KeyVaultName,
        [switch]$SoftFail
    )

    if (-not (Test-LdoKeyVaultDanceTarget -ResourceGroup $ResourceGroup -KeyVaultName $KeyVaultName -SoftFail:$SoftFail)) {
        $script:LdoKeyVaultDanceSkipped[$KeyVaultName] = $true
        return
    }

    $ip = Get-LdoPublicIpAddress

    if (-not $script:LdoKeyVaultStateCache.ContainsKey($KeyVaultName)) {
        # az keyvault show nests the network configuration under properties (unlike az storage
        # account show, which is flat); the JMESPath shaping also guarantees every key exists
        # (null when unset), which matters under Set-StrictMode.
        $vault = az keyvault show -g $ResourceGroup -n $KeyVaultName -o json --query '{publicNetworkAccess: properties.publicNetworkAccess, defaultAction: properties.networkAcls.defaultAction, bypass: properties.networkAcls.bypass}' | ConvertFrom-Json
        Assert-LdoLastExitCode -Operation "az keyvault show ($KeyVaultName)"
        $script:LdoKeyVaultStateCache[$KeyVaultName] = @{
            PublicNetworkAccess = $vault.publicNetworkAccess
            DefaultAction = $vault.defaultAction
            Bypass = $vault.bypass
        }
    }

    $cached = $script:LdoKeyVaultStateCache[$KeyVaultName]
    $update = @('keyvault', 'update', '-g', $ResourceGroup, '-n', $KeyVaultName,
        '--public-network-access', 'Enabled', '--default-action', 'Deny')
    if ($cached.Bypass) { $update += @('--bypass', $cached.Bypass) }
    az @update | Out-Null
    Assert-LdoLastExitCode -Operation "az keyvault update ($KeyVaultName)"

    $existing = az keyvault network-rule list -g $ResourceGroup -n $KeyVaultName --query "[?ipAddress=='$ip']" -o tsv
    if (-not $existing) {
        az keyvault network-rule add -g $ResourceGroup -n $KeyVaultName --ip-address $ip | Out-Null
        Assert-LdoLastExitCode -Operation "az keyvault network-rule add ($KeyVaultName)"
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

    .PARAMETER SoftFail
        Skip (with a warning) instead of failing when the vault does not exist, for teardown
        paths where the stack (vault included) may already be destroyed. Absence is the only
        condition softened: any other failure still throws.

    .PARAMETER RuleOnly
        Remove only the runner IP rule and leave the vault's network configuration (public
        network access, default action, bypass) untouched. Use when the run's own Terraform
        apply changed the vault, where restoring the pre-run capture would overwrite what
        Terraform just wrote; the terraform-azure engine detects this from the plan.

    .EXAMPLE
        Remove-LdoKeyVaultCurrentIpRule -ResourceGroup rg-prod -KeyVaultName kv-prod

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$KeyVaultName,
        [switch]$SoftFail,
        [switch]$RuleOnly
    )

    if ($script:LdoKeyVaultDanceSkipped.ContainsKey($KeyVaultName)) {
        $script:LdoKeyVaultDanceSkipped.Remove($KeyVaultName) | Out-Null
        Write-LdoLog -Level INFO -Message "Add skipped earlier because $KeyVaultName did not exist; leaving its network configuration exactly as the run applied it."
        return
    }

    if (-not (Test-LdoKeyVaultDanceTarget -ResourceGroup $ResourceGroup -KeyVaultName $KeyVaultName -SoftFail:$SoftFail)) { return }

    $ip = Get-LdoPublicIpAddress

    az keyvault network-rule remove -g $ResourceGroup -n $KeyVaultName --ip-address $ip 2>$null | Out-Null

    if ($RuleOnly) {
        $script:LdoKeyVaultStateCache.Remove($KeyVaultName) | Out-Null
        Write-LdoLog -Level INFO -Message "Removed temporary rule for $ip from $KeyVaultName; network configuration left untouched (-RuleOnly)."
        return
    }

    if ($script:LdoKeyVaultStateCache.ContainsKey($KeyVaultName)) {
        $cached = $script:LdoKeyVaultStateCache[$KeyVaultName]
        # A null captured value means the property was UNSET at capture time, and unset means the
        # platform default: public network access Enabled, and absent network ACLs, which Key
        # Vault treats as Allow (ARM reads an Allow-with-no-rules vault back exactly this way).
        # Restoring an invented lockdown over that clobbers a vault that was open by design.
        $publicAccess = if ($cached.PublicNetworkAccess) { $cached.PublicNetworkAccess } else { 'Enabled' }
        $defaultAction = if ($cached.DefaultAction) { $cached.DefaultAction } else { 'Allow' }
    }
    else {
        # No captured state at all (a standalone Remove that never had a paired Add): fall back
        # to the locked-down posture, the safe side for the dance's designed target, a
        # pre-existing firewalled vault.
        $publicAccess = 'Disabled'
        $defaultAction = 'Deny'
        $cached = @{ Bypass = $null }
    }

    $restore = @('keyvault', 'update', '-g', $ResourceGroup, '-n', $KeyVaultName,
        '--public-network-access', $publicAccess, '--default-action', $defaultAction)
    if ($cached.Bypass) { $restore += @('--bypass', $cached.Bypass) }
    az @restore | Out-Null
    Assert-LdoLastExitCode -Operation "az keyvault update ($KeyVaultName)"

    $script:LdoKeyVaultStateCache.Remove($KeyVaultName) | Out-Null
    Write-LdoLog -Level INFO -Message "Removed temporary rule and restored network ACLs on $KeyVaultName."
}

Export-ModuleMember -Function `
    Add-LdoKeyVaultCurrentIpRule, `
    Remove-LdoKeyVaultCurrentIpRule
