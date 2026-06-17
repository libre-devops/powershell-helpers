BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureKeyVault module surface' {
    It 'exports the add and remove rule commands' -ForEach @(
        'Add-LdoKeyVaultCurrentIpRule', 'Remove-LdoKeyVaultCurrentIpRule'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoPublicIpAddress' {
    It 'returns the trimmed public IP' {
        InModuleScope LibreDevOpsHelpers.AzureKeyVault {
            Mock Invoke-RestMethod { "203.0.113.7`n" }
            Get-LdoPublicIpAddress | Should -Be '203.0.113.7'
        }
    }

    It 'throws when no IP is returned' {
        InModuleScope LibreDevOpsHelpers.AzureKeyVault {
            Mock Invoke-RestMethod { '   ' }
            { Get-LdoPublicIpAddress } | Should -Throw
        }
    }
}
