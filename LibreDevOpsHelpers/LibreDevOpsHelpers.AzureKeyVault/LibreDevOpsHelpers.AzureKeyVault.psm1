if (-not $script:__kvStateCache)
{
    $script:__kvStateCache = @{ }
}

function Set-CurrentIPInKeyVaultAccess
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$KeyVaultName,
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

        # ── cache original state once ────────────────────────────────────
        if (-not $script:__kvStateCache.ContainsKey($KeyVaultName))
        {
            $kv = az keyvault show -g $ResourceGroup -n $KeyVaultName -o json |
                    ConvertFrom-Json

            $script:__kvStateCache[$KeyVaultName] = @{
                publicNetworkAccess = $kv.publicNetworkAccess
                defaultAction = $kv.networkAcls.defaultAction
                bypass = $kv.networkAcls.bypass           # single string
            }
        }

        if ($AddRule)
        {
            # ---------- OPEN ------------------------------------------------
            $origBypass = $script:__kvStateCache[$KeyVaultName].bypass

            # Build update cmd safely
            $update = @(
                'keyvault', 'update',
                '-g', $ResourceGroup, '-n', $KeyVaultName,
                '--public-network-access', 'Enabled',
                '--default-action', 'Deny'
            )
            if ($origBypass)
            {
                $update += @('--bypass', $origBypass)
            }

            az @update | Out-Null

            # Add IP only if absent
            $exists = az keyvault network-rule list `
                        -g $ResourceGroup -n $KeyVaultName `
                        --query "[?ipAddress=='$currentIp']" -o tsv
            if (-not $exists)
            {
                az keyvault network-rule add `
                    -g $ResourceGroup -n $KeyVaultName `
                    --ip-address $currentIp | Out-Null
            }
            _LogMessage -Level "INFO" -Message "Temporary KV rule added for $currentIp to $KeyVaultName" -InvocationName $inv
        }
        else
        {
            # ---------- CLOSE ----------------------------------------------
            az keyvault network-rule remove `
                -g $ResourceGroup -n $KeyVaultName `
                --ip-address $currentIp 2> $null | Out-Null

            $orig = $script:__kvStateCache[$KeyVaultName]

            $restore = @(
                'keyvault', 'update',
                '-g', $ResourceGroup, '-n', $KeyVaultName,
                '--public-network-access', 'Disabled',
                '--default-action', 'Deny'
            )
            if ($orig.bypass)
            {
                $restore += @('--bypass', $orig.bypass)
            }

            az @restore | Out-Null
            _LogMessage -Level "INFO" -Message "Key Vault ACLs restored to $KevaultName." -InvocationName $inv
        }
    }
    catch
    {
        _LogMessage -Level ERROR -Message "An error occurred: $_" -InvocationName $inv
        throw
    }
}

Export-ModuleMember -Function Set-CurrentIPInKeyVaultAccess