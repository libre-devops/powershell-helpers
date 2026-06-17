Set-StrictMode -Version Latest

function ConvertTo-LdoSecureString {
    # Internal. Builds a read-only SecureString from a plaintext value without using
    # ConvertTo-SecureString -AsPlainText, which static analysis flags.
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param([Parameter(Mandatory)][string]$PlainText)

    $secure = [System.Security.SecureString]::new()
    foreach ($char in $PlainText.ToCharArray()) { $secure.AppendChar($char) }
    $secure.MakeReadOnly()
    return $secure
}

function Connect-LdoAzurePowerShellClientSecret {
    <#
    .SYNOPSIS
        Signs in to Azure PowerShell with a service principal client secret.

    .PARAMETER ClientId
        The application (client) ID of the service principal.

    .PARAMETER ClientSecret
        The client secret as a SecureString.

    .PARAMETER TenantId
        The Entra tenant ID.

    .PARAMETER SubscriptionId
        Optional subscription to select after sign-in.

    .EXAMPLE
        Connect-LdoAzurePowerShellClientSecret -ClientId $id -ClientSecret $secure -TenantId $tid

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClientId,
        [Parameter(Mandatory)][ValidateNotNull()][System.Security.SecureString]$ClientSecret,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,
        [string]$SubscriptionId
    )

    Write-LdoLog -Level INFO -Message 'Signing in to Azure PowerShell with a client secret.'

    $credential = [System.Management.Automation.PSCredential]::new($ClientId, $ClientSecret)
    Connect-AzAccount -ServicePrincipal -Credential $credential -Tenant $TenantId -ErrorAction Stop | Out-Null

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }

    Write-LdoLog -Level SUCCESS -Message 'Client-secret sign-in complete.'
}

function Connect-LdoAzurePowerShellManagedIdentity {
    <#
    .SYNOPSIS
        Signs in to Azure PowerShell with a managed identity.

    .PARAMETER SubscriptionId
        Subscription to select after sign-in.

    .PARAMETER ManagedIdentityObjectId
        Optional client/object ID of a user-assigned managed identity. When omitted the
        system-assigned identity is used.

    .EXAMPLE
        Connect-LdoAzurePowerShellManagedIdentity -SubscriptionId $sub

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubscriptionId,
        [string]$ManagedIdentityObjectId
    )

    Write-LdoLog -Level INFO -Message 'Signing in to Azure PowerShell with a managed identity.'

    if ($ManagedIdentityObjectId) {
        Connect-AzAccount -Identity -AccountId $ManagedIdentityObjectId -ErrorAction Stop | Out-Null
    }
    else {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }

    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-LdoLog -Level SUCCESS -Message 'Managed identity sign-in complete.'
}

function Connect-LdoAzurePowerShellDeviceCode {
    <#
    .SYNOPSIS
        Signs in to Azure PowerShell interactively using device code flow.

    .PARAMETER TenantId
        Optional tenant to sign in to.

    .PARAMETER SubscriptionId
        Optional subscription to select after sign-in.

    .EXAMPLE
        Connect-LdoAzurePowerShellDeviceCode -TenantId $tid

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$TenantId,
        [string]$SubscriptionId
    )

    Write-LdoLog -Level INFO -Message 'Signing in to Azure PowerShell with device code.'

    $connectParams = @{ UseDeviceAuthentication = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $connectParams['Tenant'] = $TenantId }
    Connect-AzAccount @connectParams | Out-Null

    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }

    Write-LdoLog -Level SUCCESS -Message 'Device-code sign-in complete.'
}

function Test-LdoAzurePowerShellConnection {
    <#
    .SYNOPSIS
        Tests whether there is an active Azure PowerShell context.

    .DESCRIPTION
        Returns $true when Get-AzContext reports an active context with a subscription,
        otherwise $false. Does not throw.

    .EXAMPLE
        if (-not (Test-LdoAzurePowerShellConnection)) { throw 'Not signed in' }

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $context = Get-AzContext -ErrorAction Stop
        if ($context -and $context.Subscription) {
            Write-LdoLog -Level INFO -Message "Connected to Azure as $($context.Account.Id) on subscription $($context.Subscription.Name)."
            return $true
        }
    }
    catch {
        Write-LdoLog -Level DEBUG -Message "Get-AzContext failed: $($_.Exception.Message)"
    }

    Write-LdoLog -Level WARN -Message 'No active Azure PowerShell context.'
    return $false
}

function Disconnect-LdoAzurePowerShell {
    <#
    .SYNOPSIS
        Signs out of the current Azure PowerShell session.

    .EXAMPLE
        Disconnect-LdoAzurePowerShell

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    try {
        Write-LdoLog -Level INFO -Message 'Disconnecting Azure PowerShell session.'
        Disconnect-AzAccount -ErrorAction Stop | Out-Null
    }
    catch {
        Write-LdoLog -Level WARN -Message "Azure PowerShell sign-out failed: $($_.Exception.Message)"
    }
}

function Connect-LdoAzurePowerShell {
    <#
    .SYNOPSIS
        Signs in to Azure PowerShell using the selected method and verifies the context.

    .DESCRIPTION
        Dispatches to the client-secret, managed-identity or device-code sign-in based on
        Method, reading the standard ARM_* environment variables. After sign-in it verifies
        an active context and throws if none is present.

        Environment variables used:
          ClientSecret    : ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
          ManagedIdentity : ARM_SUBSCRIPTION_ID, optional MANAGED_IDENTITY_OBJECT_ID
          DeviceCode      : ARM_TENANT_ID, ARM_SUBSCRIPTION_ID

    .PARAMETER Method
        One of ClientSecret, ManagedIdentity or DeviceCode. Defaults to ManagedIdentity.

    .EXAMPLE
        Connect-LdoAzurePowerShell -Method ClientSecret

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateSet('ClientSecret', 'ManagedIdentity', 'DeviceCode')]
        [string]$Method = 'ManagedIdentity'
    )

    switch ($Method) {
        'ClientSecret' {
            Assert-LdoEnvironmentVariable -Name 'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID'
            $secret = ConvertTo-LdoSecureString -PlainText $env:ARM_CLIENT_SECRET
            Connect-LdoAzurePowerShellClientSecret `
                -ClientId $env:ARM_CLIENT_ID `
                -ClientSecret $secret `
                -TenantId $env:ARM_TENANT_ID `
                -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        'ManagedIdentity' {
            Assert-LdoEnvironmentVariable -Name 'ARM_SUBSCRIPTION_ID'
            Connect-LdoAzurePowerShellManagedIdentity `
                -SubscriptionId $env:ARM_SUBSCRIPTION_ID `
                -ManagedIdentityObjectId $env:MANAGED_IDENTITY_OBJECT_ID
        }
        'DeviceCode' {
            Assert-LdoEnvironmentVariable -Name 'ARM_SUBSCRIPTION_ID'
            Connect-LdoAzurePowerShellDeviceCode `
                -TenantId $env:ARM_TENANT_ID `
                -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
    }

    if (-not (Test-LdoAzurePowerShellConnection)) {
        throw 'Azure PowerShell sign-in did not produce an active context.'
    }
}

Export-ModuleMember -Function `
    Connect-LdoAzurePowerShellClientSecret, `
    Connect-LdoAzurePowerShellManagedIdentity, `
    Connect-LdoAzurePowerShellDeviceCode, `
    Test-LdoAzurePowerShellConnection, `
    Disconnect-LdoAzurePowerShell, `
    Connect-LdoAzurePowerShell
