function Connect-ToAzurePowerShellClientSecret {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$SubscriptionId
    )

    _LogMessage -Level INFO -Message 'Azure PowerShell client-secret login…' -InvocationName $MyInvocation.MyCommand.Name

    $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($ClientId, $secureSecret)

    Connect-AzAccount -ServicePrincipal -Credential $cred -Tenant $TenantId -ErrorAction Stop

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }

    _LogMessage -Level INFO -Message 'Client-secret login OK.' -InvocationName $MyInvocation.MyCommand.Name
}

function Connect-ToAzurePowerShellManagedIdentity {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$ManagedIdentityObjectId
    )

    _LogMessage -Level INFO -Message 'Azure PowerShell Managed Identity login…' -InvocationName $MyInvocation.MyCommand.Name

    if ($ManagedIdentityObjectId) {
        Connect-AzAccount -Identity -AccountId $ManagedIdentityObjectId -ErrorAction Stop
    } else {
        Connect-AzAccount -Identity -ErrorAction Stop
    }

    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    _LogMessage -Level INFO -Message 'Managed Identity login OK.' -InvocationName $MyInvocation.MyCommand.Name
}

function Connect-ToAzurePowerShellDeviceCode {
    param(
        [string]$TenantId,
        [string]$SubscriptionId
    )

    $params = @{}
    if ($TenantId) { $params['Tenant'] = $TenantId }

    Connect-AzAccount @params -UseDeviceAuthentication -ErrorAction Stop

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    }

    _LogMessage -Level INFO -Message 'Device-code login OK.' -InvocationName $MyInvocation.MyCommand.Name
}

function Test-AzurePowerShellConnection {
    try {
        $context = Get-AzContext
        if ($context -and $context.Subscription) {
            _LogMessage -Level "INFO" -Message "Successfully connected to Azure via Az PowerShell" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        } else {
            throw "No active Azure context."
        }
    }
    catch {
        _LogMessage -Level "ERROR" -Message "Not authenticated with Az PowerShell: $_" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        exit 1
    }
}

function Disconnect-AzurePowerShell {
    try {
        _LogMessage -Level INFO -Message 'Disconnecting from Azure PowerShell session…' -InvocationName $MyInvocation.MyCommand.Name
        Disconnect-AzAccount -ErrorAction Stop
    }
    catch {
        _LogMessage -Level ERROR -Message "Azure PowerShell logout failed: $($_.Exception.Message)" -InvocationName $MyInvocation.MyCommand.Name
    }
}

function Connect-AzurePowerShell {
    param(
        [bool]$UseClientSecret,
        [bool]$UseUserDeviceCode,
        [bool]$UseManagedIdentity
    )

    $trueCount = @($UseClientSecret, $UseUserDeviceCode, $UseManagedIdentity | Where-Object { $_ }).Count
    if ($trueCount -ne 1) {
        $msg = "Choose exactly one Azure login mode: ClientSecret=$UseClientSecret  Device=$UseUserDeviceCode  MSI=$UseManagedIdentity"
        _LogMessage -Level 'ERROR' -Message $msg -InvocationName $MyInvocation.MyCommand.Name
        throw $msg
    }

    if ($UseClientSecret) {
        Test-EnvironmentVariablesExist -EnvVars @('ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID')
        Connect-ToAzurePowerShellClientSecret `
            -ClientId       $env:ARM_CLIENT_ID `
            -ClientSecret   $env:ARM_CLIENT_SECRET `
            -TenantId       $env:ARM_TENANT_ID `
            -SubscriptionId $env:ARM_SUBSCRIPTION_ID
    }
    elseif ($UseUserDeviceCode) {
        Connect-ToAzurePowerShellDeviceCode `
            -TenantId       $env:ARM_TENANT_ID `
            -SubscriptionId $env:ARM_SUBSCRIPTION_ID
    }
    else {
        Test-EnvironmentVariablesExist -EnvVars @('ARM_SUBSCRIPTION_ID')
        Connect-ToAzurePowerShellManagedIdentity `
            -SubscriptionId         $env:ARM_SUBSCRIPTION_ID `
            -ManagedIdentityObjectId $env:MANAGED_IDENTITY_OBJECT_ID
    }

    Test-AzurePowerShellConnection
}

Export-ModuleMember -Function `
    Connect-ToAzurePowerShellClientSecret, `
    Connect-ToAzurePowerShellManagedIdentity, `
    Connect-ToAzurePowerShellDeviceCode, `
    Connect-AzurePowerShell, `
    Disconnect-AzurePowerShell, `
    Test-AzurePowerShellConnection
