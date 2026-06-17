Set-StrictMode -Version Latest

function Assert-LdoLastExitCode {
    # Internal. Throws when the most recent native command exited non-zero.
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Operation)

    Write-LdoLog -Level DEBUG -Message "$Operation exit code: $LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) {
        $message = "$Operation failed with exit code $LASTEXITCODE."
        Write-LdoLog -Level ERROR -Message $message
        throw $message
    }
}

function Install-LdoAzureCli {
    <#
    .SYNOPSIS
        Installs the Azure CLI using the platform package manager.

    .DESCRIPTION
        Uses Chocolatey on Windows and Homebrew elsewhere, then verifies that 'az' is on
        PATH.

    .EXAMPLE
        Install-LdoAzureCli

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ((Get-LdoOperatingSystem) -eq 'Windows') {
        Assert-LdoChocoPath
        Write-LdoLog -Level INFO -Message 'Installing Azure CLI via Chocolatey.'
        choco install azure-cli -y
    }
    else {
        Assert-LdoHomebrewPath
        Write-LdoLog -Level INFO -Message 'Installing Azure CLI via Homebrew.'
        brew install azure-cli
    }

    Assert-LdoCommand -Name 'az'
}

function Connect-LdoAzureCliClientSecret {
    <#
    .SYNOPSIS
        Signs in to the Azure CLI with a service principal client secret.

    .DESCRIPTION
        The secret is passed to 'az login' on the command line because the Azure CLI offers
        no stdin or SecureString input for it, so a SecureString parameter would give no
        real protection here.

    .PARAMETER ClientId
        Application (client) ID.

    .PARAMETER ClientSecret
        Client secret value.

    .PARAMETER TenantId
        Entra tenant ID.

    .PARAMETER SubscriptionId
        Optional subscription to select after sign-in.

    .EXAMPLE
        Connect-LdoAzureCliClientSecret -ClientId $id -ClientSecret $secret -TenantId $tid

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'az login accepts the secret only as a command-line argument; SecureString adds no protection.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClientId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClientSecret,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,
        [string]$SubscriptionId
    )

    Write-LdoLog -Level INFO -Message 'Signing in to the Azure CLI with a client secret.'
    az login --service-principal --username $ClientId --password $ClientSecret --tenant $TenantId --allow-no-subscriptions | Out-Null
    Assert-LdoLastExitCode -Operation 'az login (client secret)'

    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId
        Assert-LdoLastExitCode -Operation 'az account set'
    }

    Write-LdoLog -Level SUCCESS -Message 'Client-secret sign-in complete.'
}

function Connect-LdoAzureCliOidc {
    <#
    .SYNOPSIS
        Signs in to the Azure CLI with a workload-identity federated (OIDC) token.

    .PARAMETER ClientId
        Application (client) ID.

    .PARAMETER OidcToken
        The federated token from the OIDC provider.

    .PARAMETER TenantId
        Entra tenant ID.

    .PARAMETER SubscriptionId
        Optional subscription to select after sign-in.

    .EXAMPLE
        Connect-LdoAzureCliOidc -ClientId $id -OidcToken $token -TenantId $tid

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClientId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OidcToken,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TenantId,
        [string]$SubscriptionId
    )

    Write-LdoLog -Level INFO -Message 'Signing in to the Azure CLI with an OIDC federated token.'
    az login --service-principal --username $ClientId --tenant $TenantId --allow-no-subscriptions --federated-token $OidcToken | Out-Null
    Assert-LdoLastExitCode -Operation 'az login (OIDC)'

    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId
        Assert-LdoLastExitCode -Operation 'az account set'
    }

    Write-LdoLog -Level SUCCESS -Message 'OIDC sign-in complete.'
}

function Connect-LdoAzureCliManagedIdentity {
    <#
    .SYNOPSIS
        Signs in to the Azure CLI with a managed identity.

    .PARAMETER SubscriptionId
        Subscription to select after sign-in.

    .PARAMETER ManagedIdentityClientId
        Optional client ID of a user-assigned managed identity. When omitted the
        system-assigned identity is used.

    .EXAMPLE
        Connect-LdoAzureCliManagedIdentity -SubscriptionId $sub

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubscriptionId,
        [string]$ManagedIdentityClientId
    )

    Write-LdoLog -Level INFO -Message 'Signing in to the Azure CLI with a managed identity.'
    if ($ManagedIdentityClientId) {
        az login --identity --username $ManagedIdentityClientId --allow-no-subscriptions | Out-Null
    }
    else {
        az login --identity --allow-no-subscriptions | Out-Null
    }
    Assert-LdoLastExitCode -Operation 'az login (managed identity)'

    az account set --subscription $SubscriptionId
    Assert-LdoLastExitCode -Operation 'az account set'

    Write-LdoLog -Level SUCCESS -Message 'Managed identity sign-in complete.'
}

function Connect-LdoAzureCliDeviceCode {
    <#
    .SYNOPSIS
        Signs in to the Azure CLI interactively using device code flow.

    .DESCRIPTION
        Reuses the existing session when it already matches the requested tenant and
        subscription, otherwise performs an interactive device-code login.

    .PARAMETER TenantId
        Optional tenant to sign in to.

    .PARAMETER SubscriptionId
        Optional subscription to select after sign-in.

    .EXAMPLE
        Connect-LdoAzureCliDeviceCode -TenantId $tid -SubscriptionId $sub

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$TenantId,
        [string]$SubscriptionId
    )

    $account = az account show --output json 2>$null | ConvertFrom-Json
    if ($account -and $account.id) {
        $subMatches = -not $SubscriptionId -or ($SubscriptionId -eq $account.id)
        $tenantMatches = -not $TenantId -or ($TenantId -eq $account.tenantId)

        if ($subMatches -and $tenantMatches) {
            Write-LdoLog -Level INFO -Message "Azure CLI already signed in to subscription $($account.id); skipping login."
            return
        }

        if (-not $subMatches -and $SubscriptionId) {
            Write-LdoLog -Level INFO -Message "Switching Azure CLI to subscription $SubscriptionId."
            az account set --subscription $SubscriptionId
            Assert-LdoLastExitCode -Operation 'az account set'
            return
        }
    }

    Write-LdoLog -Level INFO -Message 'Signing in to the Azure CLI with device code.'
    if ($TenantId) {
        az login --use-device-code --tenant $TenantId --allow-no-subscriptions
    }
    else {
        az login --use-device-code --allow-no-subscriptions
    }
    Assert-LdoLastExitCode -Operation 'az login (device code)'

    if ($SubscriptionId) {
        az account set --subscription $SubscriptionId
        Assert-LdoLastExitCode -Operation 'az account set'
    }

    Write-LdoLog -Level SUCCESS -Message 'Device-code sign-in complete.'
}

function Test-LdoAzureCliConnection {
    <#
    .SYNOPSIS
        Tests whether the Azure CLI has an authenticated account.

    .DESCRIPTION
        Returns $true when 'az account show' reports a subscription id, otherwise $false.
        Does not throw.

    .EXAMPLE
        if (-not (Test-LdoAzureCliConnection)) { throw 'Not signed in' }

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $id = az account show --query 'id' -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $id) {
            Write-LdoLog -Level INFO -Message "Azure CLI signed in to subscription $id."
            return $true
        }
    }
    catch {
        Write-LdoLog -Level DEBUG -Message "az account show failed: $($_.Exception.Message)"
    }

    Write-LdoLog -Level WARN -Message 'Azure CLI is not signed in.'
    return $false
}

function Connect-LdoAzureCli {
    <#
    .SYNOPSIS
        Signs in to the Azure CLI using the selected method and verifies the session.

    .DESCRIPTION
        Dispatches to client-secret, OIDC, device-code or managed-identity sign-in based on
        Method, reading the standard ARM_* environment variables, then verifies an active
        session and throws if none is present.

        Environment variables used:
          ClientSecret    : ARM_CLIENT_ID, ARM_CLIENT_SECRET, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
          Oidc            : ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_OIDC_TOKEN
          DeviceCode      : optional ARM_TENANT_ID, ARM_SUBSCRIPTION_ID
          ManagedIdentity : ARM_SUBSCRIPTION_ID, optional MANAGED_IDENTITY_OBJECT_ID

    .PARAMETER Method
        One of ClientSecret, Oidc, DeviceCode or ManagedIdentity. Defaults to ManagedIdentity.

    .EXAMPLE
        Connect-LdoAzureCli -Method Oidc

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateSet('ClientSecret', 'Oidc', 'DeviceCode', 'ManagedIdentity')]
        [string]$Method = 'ManagedIdentity'
    )

    switch ($Method) {
        'ClientSecret' {
            Assert-LdoEnvironmentVariable -Name 'ARM_CLIENT_ID', 'ARM_CLIENT_SECRET', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID'
            Connect-LdoAzureCliClientSecret `
                -ClientId $env:ARM_CLIENT_ID `
                -ClientSecret $env:ARM_CLIENT_SECRET `
                -TenantId $env:ARM_TENANT_ID `
                -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        'Oidc' {
            Assert-LdoEnvironmentVariable -Name 'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID', 'ARM_OIDC_TOKEN'
            Connect-LdoAzureCliOidc `
                -ClientId $env:ARM_CLIENT_ID `
                -OidcToken $env:ARM_OIDC_TOKEN `
                -TenantId $env:ARM_TENANT_ID `
                -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        'DeviceCode' {
            if (-not $env:ARM_SUBSCRIPTION_ID) {
                Write-LdoLog -Level WARN -Message 'ARM_SUBSCRIPTION_ID not set; device-code login will not select a subscription.'
            }
            Connect-LdoAzureCliDeviceCode -TenantId $env:ARM_TENANT_ID -SubscriptionId $env:ARM_SUBSCRIPTION_ID
        }
        'ManagedIdentity' {
            Assert-LdoEnvironmentVariable -Name 'ARM_SUBSCRIPTION_ID'
            Connect-LdoAzureCliManagedIdentity `
                -SubscriptionId $env:ARM_SUBSCRIPTION_ID `
                -ManagedIdentityClientId $env:MANAGED_IDENTITY_OBJECT_ID
        }
    }

    if (-not (Test-LdoAzureCliConnection)) {
        throw 'Azure CLI sign-in did not produce an authenticated session.'
    }
}

function Disconnect-LdoAzureCli {
    <#
    .SYNOPSIS
        Signs out of the Azure CLI.

    .DESCRIPTION
        Runs 'az logout'. When KeepDeviceLogin is set, an interactive device-code session is
        left intact instead.

    .PARAMETER KeepDeviceLogin
        Leave the current session signed in (use after an interactive device-code login).

    .EXAMPLE
        Disconnect-LdoAzureCli

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [switch]$KeepDeviceLogin
    )

    if ($KeepDeviceLogin) {
        Write-LdoLog -Level INFO -Message 'Leaving the interactive Azure CLI session intact.'
        return
    }

    Write-LdoLog -Level INFO -Message 'Signing out of the Azure CLI.'
    az logout | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-LdoLog -Level WARN -Message "az logout returned exit code $LASTEXITCODE; cached credentials may remain."
    }
}

Export-ModuleMember -Function `
    Install-LdoAzureCli, `
    Connect-LdoAzureCliClientSecret, `
    Connect-LdoAzureCliOidc, `
    Connect-LdoAzureCliManagedIdentity, `
    Connect-LdoAzureCliDeviceCode, `
    Test-LdoAzureCliConnection, `
    Connect-LdoAzureCli, `
    Disconnect-LdoAzureCli
