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

Describe 'AzureStorage parameter validation' {
    It 'requires a storage account name' {
        { Add-LdoStorageCurrentIpRule -ResourceGroup rg -StorageAccountName '' } | Should -Throw
    }
}
