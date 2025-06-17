function Invoke-InstallAzureCli
{
    [CmdletBinding()]
    param()
    $inv = $MyInvocation.MyCommand.Name
    $os = Assert-WhichOs -PassThru

    if ($os.ToLower() -eq 'windows')
    {
        Assert-ChocoPath
        _LogMessage -Level INFO -Message "Installing Azure CLI via Chocolatey…" -InvocationName $inv
        choco install azure-cli -y
    }
    else
    {
        Assert-HomebrewPath
        _LogMessage -Level INFO -Message "Installing Azure CLI via Homebrew…" -InvocationName $inv
        brew install azure-cli
    }

    Get-InstalledPrograms -Programs @('az')
}

function Connect-ToAzureCliClientSecret
{
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$SubscriptionId
    )

    _LogMessage -Level 'INFO' -Message 'Azure CLI client-secret login…' -InvocationName $MyInvocation.MyCommand.Name

    az login `
        --service-principal `
        --username $ClientId `
        --password $ClientSecret `
        --tenant   $TenantId `
        --allow-no-subscriptions | Out-Null
    _LogMessage -Level 'DEBUG' -Message "az login exit-code: $LASTEXITCODE" -InvocationName $MyInvocation.MyCommand.Name
    if ($LASTEXITCODE -ne 0)
    {
        _LogMessage -Level 'ERROR' -Message 'az login failed (client-secret).' -InvocationName $MyInvocation.MyCommand.Name
        throw 'az login failed (client-secret).'
    }

    if ($SubscriptionId)
    {
        az account set --subscription $SubscriptionId
        _LogMessage -Level 'DEBUG' -Message "az account set exit-code: $LASTEXITCODE" -InvocationName $MyInvocation.MyCommand.Name
        if ($LASTEXITCODE -ne 0)
        {
            _LogMessage -Level 'ERROR' -Message "Unable to set subscription $SubscriptionId." -InvocationName $MyInvocation.MyCommand.Name
            throw "az account set failed."
        }
    }

    _LogMessage -Level 'INFO' -Message 'Client-secret login OK.' -InvocationName $MyInvocation.MyCommand.Name
}

function Connect-ToAzureCliOidc
{
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$OidcToken,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$SubscriptionId
    )

    _LogMessage -Level 'INFO' -Message 'Azure CLI OIDC login…' -InvocationName $MyInvocation.MyCommand.Name

    az login `
        --service-principal `
        --username $ClientId `
        --tenant   $TenantId `
        --allow-no-subscriptions `
        --federated-token $OidcToken | Out-Null
    _LogMessage -Level 'DEBUG' -Message "az login exit-code: $LASTEXITCODE" -InvocationName $MyInvocation.MyCommand.Name
    if ($LASTEXITCODE -ne 0)
    {
        _LogMessage -Level 'ERROR' -Message 'az login failed (OIDC).' -InvocationName $MyInvocation.MyCommand.Name
        throw 'az login failed (OIDC).'
    }

    if ($SubscriptionId)
    {
        az account set --subscription $SubscriptionId
        _LogMessage -Level 'DEBUG' -Message "az account set exit-code: $LASTEXITCODE" -InvocationName $MyInvocation.MyCommand.Name
        if ($LASTEXITCODE -ne 0)
        {
            _LogMessage -Level 'ERROR' -Message "Unable to set subscription $SubscriptionId." -InvocationName $MyInvocation.MyCommand.Name
            throw "az account set failed."
        }
    }

    _LogMessage -Level 'INFO' -Message 'OIDC login OK.' -InvocationName $MyInvocation.MyCommand.Name
}

function Connect-ToAzureCliDeviceCode {
    param(
        [string]$TenantId,
        [string]$SubscriptionId
    )

    $invocation = $MyInvocation.MyCommand.Name

    try {
        # ── Check if already logged in and with correct tenant/sub ──
        $accountInfo = az account show --output json | ConvertFrom-Json

        if ($accountInfo -and $accountInfo.id) {
            $currentSubId = $accountInfo.id
            $currentTenant = $accountInfo.tenantId

            $isSubMatch = -not $SubscriptionId -or ($SubscriptionId -eq $currentSubId)
            $isTenantMatch = -not $TenantId -or ($TenantId -eq $currentTenant)

            if ($isSubMatch -and $isTenantMatch) {
                _LogMessage -Level 'INFO' -Message "Azure CLI already authenticated with correct subscription and tenant (sub: $currentSubId, tenant: $currentTenant) – skipping login." -InvocationName $invocation
                return
            }

            if (-not $isSubMatch -and $SubscriptionId) {
                _LogMessage -Level 'INFO' -Message "Switching subscription to $SubscriptionId..." -InvocationName $invocation
                az account set --subscription $SubscriptionId
                if ($LASTEXITCODE -ne 0) {
                    _LogMessage -Level 'WARN' -Message "Unable to switch to subscription $SubscriptionId." -InvocationName $invocation
                }
                return
            }
        }

        # ── Perform interactive login ──
        _LogMessage -Level 'INFO' -Message 'Azure CLI device-code login…' -InvocationName $invocation

        if ($TenantId) {
            az login --use-device-code --tenant $TenantId --allow-no-subscriptions
        } else {
            az login --use-device-code --allow-no-subscriptions
        }

        if ($LASTEXITCODE -ne 0) {
            throw 'az login failed (device-code).'
        }

        if ($SubscriptionId) {
            az account set --subscription $SubscriptionId
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to set subscription $SubscriptionId."
            }
        }

        _LogMessage -Level 'INFO' -Message 'Device-code login OK.' -InvocationName $invocation
    }
    catch {
        _LogMessage -Level 'ERROR' -Message "Device-code login failed: $($_.Exception.Message)" -InvocationName $invocation
        throw
    }
}



function Test-AzureCliConnection
{
    try
    {
        # Run az account show to check if Azure CLI is authenticated
        $azureStatus = az account show --query "id" -o tsv

        if ($azureStatus)
        {
            _LogMessage -Level "INFO" -Message "Successfully connected to Azure via Azure-Cli" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        }
        else
        {
            _LogMessage -Level "ERROR" -Message "Not authenticated with Azure CLI" -InvocationName "$( $MyInvocation.MyCommand.Name )"
            exit 1
        }
    }
    catch
    {
        _LogMessage -Level "ERROR" -Message "Azure CLI is not installed or there was an error running the command" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        exit 1
    }
}

function Connect-AzureCli
{
    param(
        [bool]$UseClientSecret,
        [bool]$UseOidc,
        [bool]$UseUserDeviceCode,
        [bool]$UseManagedIdentity
    )

    # ── pick mode ───────────────────────────────────────────────────────────
    $trueCount = @($UseClientSecret, $UseOidc, $UseUserDeviceCode, $UseManagedIdentity | Where-Object { $_ }).Count
    if ($trueCount -ne 1)
    {
        $msg = "Choose exactly one Azure login mode: ClientSecret=$UseClientSecret  Oidc=$UseOidc  Device=$UseUserDeviceCode  MSI=$UseManagedIdentity"
        _LogMessage -Level 'ERROR' -Message $msg -InvocationName $MyInvocation.MyCommand.Name
        throw $msg
    }

    # ── run mode ────────────────────────────────────────────────────────────
    if ($UseClientSecret)
    {

        Test-EnvironmentVariablesExist -EnvVars @(
            'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID'
        )

        Connect-ToAzureCliClientSecret `
            -ClientId       $env:ARM_CLIENT_ID `
            -ClientSecret   $env:ARM_CLIENT_SECRET `
            -TenantId       $env:ARM_TENANT_ID `
            -SubscriptionId $env:ARM_SUBSCRIPTION_ID
    }
    elseif ($UseOidc)
    {

        Test-EnvironmentVariablesExist -EnvVars @(
            'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID', 'ARM_OIDC_TOKEN'
        )

        Connect-ToAzureCliOidc `
            -ClientId       $env:ARM_CLIENT_ID `
            -OidcToken      $env:ARM_OIDC_TOKEN `
            -TenantId       $env:ARM_TENANT_ID `
            -SubscriptionId $env:ARM_SUBSCRIPTION_ID
    }
    elseif ($UseUserDeviceCode)
    {

        if (-not $env:ARM_SUBSCRIPTION_ID)
        {
            _LogMessage -Level 'WARN' -Message 'ARM_SUBSCRIPTION_ID not set – device-code login will not select a subscription automatically.' -InvocationName $MyInvocation.MyCommand.Name
        }

        Connect-ToAzureCliDeviceCode `
            -TenantId       $env:ARM_TENANT_ID `
            -SubscriptionId $env:ARM_SUBSCRIPTION_ID
    }
    else
    {
        # Managed Identity

        Test-EnvironmentVariablesExist -EnvVars @('ARM_SUBSCRIPTION_ID')

        Connect-ToAzureCliManagedIdentity `
            -SubscriptionId         $env:ARM_SUBSCRIPTION_ID `
            -ManagedIdentityObjectId $env:MANAGED_IDENTITY_OBJECT_ID
    }

    # ── final sanity check ──────────────────────────────────────────────────
    Test-AzureCliConnection
}

function Disconnect-AzureCli
{
    param(
        [bool]$IsUserDeviceLogin = $false   # pass $true when the user logged in with az login --device-code
    )

    if ($IsUserDeviceLogin)
    {
        _LogMessage -Level 'INFO' -Message 'Leaving user/device-code Azure-CLI session intact.' -InvocationName $MyInvocation.MyCommand.Name
        return
    }

    try
    {
        _LogMessage -Level 'INFO' -Message 'Attempting Azure-Cli logout to cleanup …' -InvocationName $MyInvocation.MyCommand.Name

        az logout | Out-Null
        $code = $LASTEXITCODE
        _LogMessage -Level 'DEBUG' -Message "az logout exit-code: $code" -InvocationName $MyInvocation.MyCommand.Name

        if ($code -ne 0)
        {
            _LogMessage -Level 'WARN' -Message 'az logout returned non-zero exit code (cached credentials may remain).' -InvocationName $MyInvocation.MyCommand.Name
        }

    }
    catch
    {
        _LogMessage -Level 'ERROR' -Message "Error: Azure-Cli logout failed: $( $_.Exception.Message )" -InvocationName $MyInvocation.MyCommand.Name
        throw
    }
}

# Export functions
Export-ModuleMember -Function `
    Invoke-InstallAzureCli, `
      Connect-ToAzureCliOidc, `
      Test-AzureCliConnection, `
      Connect-ToAzureCliClientSecret, `
      Connect-ToAzureCliManagedIdentity, `
      Connect-ToAzureCliDeviceCode, `
      Connect-AzureCli, `
      Disconnect-AzureCli


