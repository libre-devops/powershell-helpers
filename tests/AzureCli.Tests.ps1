BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureCli module surface' {
    It 'exports the managed-identity sign-in (previously missing)' {
        Get-Command Connect-LdoAzureCliManagedIdentity -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'exports the expected commands' -ForEach @(
        'Install-LdoAzureCli', 'Connect-LdoAzureCliClientSecret', 'Connect-LdoAzureCliOidc',
        'Connect-LdoAzureCliDeviceCode', 'Test-LdoAzureCliConnection', 'Connect-LdoAzureCli',
        'Disconnect-LdoAzureCli'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Connect-LdoAzureCli' {
    It 'rejects an invalid method' {
        { Connect-LdoAzureCli -Method 'Nope' } | Should -Throw
    }

    It 'throws for Oidc when the federated token is not set' {
        $saved = $env:ARM_OIDC_TOKEN
        Remove-Item Env:ARM_OIDC_TOKEN -ErrorAction SilentlyContinue
        try {
            { Connect-LdoAzureCli -Method Oidc } | Should -Throw
        } finally {
            if ($null -ne $saved) { $env:ARM_OIDC_TOKEN = $saved }
        }
    }
}
