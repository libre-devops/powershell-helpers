BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureStorage module surface' {
    It 'exports the add and remove rule commands' -ForEach @(
        'Add-LdoStorageCurrentIpRule', 'Remove-LdoStorageCurrentIpRule'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoStoragePublicIpAddress' {
    It 'returns the trimmed public IP' {
        InModuleScope LibreDevOpsHelpers.AzureStorage {
            Mock Invoke-RestMethod { "198.51.100.4`n" }
            Get-LdoStoragePublicIpAddress | Should -Be '198.51.100.4'
        }
    }

    It 'throws when no IP is returned' {
        InModuleScope LibreDevOpsHelpers.AzureStorage {
            Mock Invoke-RestMethod { '' }
            { Get-LdoStoragePublicIpAddress } | Should -Throw
        }
    }
}
