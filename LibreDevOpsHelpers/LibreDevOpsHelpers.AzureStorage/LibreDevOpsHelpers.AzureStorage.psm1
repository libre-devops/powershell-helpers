if (-not $script:__stStateCache)
{
    $script:__stStateCache = @{ }
}

function Set-CurrentIPInStorageAccess
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$StorageAccountName,
        [Parameter(Mandatory)][bool]  $AddRule
    )

    $inv = $MyInvocation.MyCommand.Name
    try
    {
        # ── caller IP ─────────────────────────────────────────────────────
        $currentIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
        if (-not $currentIp)
        {
            _LogMessage -Level ERROR -Message 'Failed to obtain public IP.' -InvocationName $inv
            return
        }
        _LogMessage -Level INFO -Message "Current IP: $currentIp" -InvocationName $inv

        # ── cache original state once per account ────────────────────────
        if (-not $script:__stStateCache.ContainsKey($StorageAccountName))
        {
            $sa = az storage account show -g $ResourceGroup -n $StorageAccountName -o json |
                    ConvertFrom-Json

            $script:__stStateCache[$StorageAccountName] = @{
                publicNetworkAccess = $sa.publicNetworkAccess             # Enabled / Disabled
                defaultAction = $sa.networkRuleSet.defaultAction    # Allow / Deny
                bypass = $sa.networkRuleSet.bypass           # comma-separated string
                # we **never** overwrite ipRules / vnetRules, so no need to copy them
            }
            _LogMessage -Level DEBUG -Message "Captured original SA network-ACL state of $StorageAccountName." -InvocationName $inv
        }

        if ($AddRule)
        {
            $origBypass = $script:__stStateCache[$StorageAccountName].bypass

            # Enable public access + keep existing bypass list
            $update = @(
                'storage', 'account', 'update',
                '-g', $ResourceGroup, '-n', $StorageAccountName,
                '--public-network-access', 'Enabled',
                '--default-action', 'Deny'        # open wide; IP rule will still be added
            )
            if ($origBypass)
            {
                $update += @('--bypass', $origBypass)
            }
            az @update | Out-Null

            # Add IP only if absent
            $exists = az storage account network-rule list `
                        -g $ResourceGroup -n $StorageAccountName `
                        --query "[?ipAddress=='$currentIp']" -o tsv
            if (-not $exists)
            {
                az storage account network-rule add `
                    -g $ResourceGroup -n $StorageAccountName `
                    --ip-address $currentIp | Out-Null
                _LogMessage -Level INFO -Message "Temporary SA rule added for $currentIp to $StorageAccountName" -InvocationName $inv
            }
            else
            {
                _LogMessage -Level INFO -Message "SA rule for $currentIp already exists; skipping add." -InvocationName $inv
            }
        }
        else
        {
            az storage account network-rule remove `
                -g $ResourceGroup -n $StorageAccountName `
                --ip-address $currentIp 2> $null | Out-Null
            _LogMessage -Level INFO -Message "Removed temporary SA rule for $currentIp from $StorageAccountName" -InvocationName $inv

            $orig = $script:__stStateCache[$StorageAccountName]

            $restore = @(
                'storage', 'account', 'update',
                '-g', $ResourceGroup, '-n', $StorageAccountName,
                '--public-network-access', 'Disabled', # final lock-down
                '--default-action', 'Deny'
            )
            if ($orig.bypass)
            {
                $restore += @('--bypass', $orig.bypass)
            }
            az @restore | Out-Null
            _LogMessage -Level INFO -Message "Storage account: $StorageAccountName - locked down; public access disabled." -InvocationName $inv
        }

        _LogMessage -Level INFO -Message 'Storage-account ACL update complete.' -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message "An error occurred: $_" -InvocationName $inv
        throw
    }
}

Export-ModuleMember -Function Set-CurrentIPInStorageAccess
