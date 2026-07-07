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

Describe 'RuleOnly dance option' {
    It 'exposes -RuleOnly on Remove-LdoStorageCurrentIpRule' {
        (Get-Command Remove-LdoStorageCurrentIpRule).Parameters.ContainsKey('RuleOnly') | Should -BeTrue
    }
}

Describe 'SoftFail dance option' {
    It 'exposes -SoftFail on <_>' -ForEach @(
        'Add-LdoStorageCurrentIpRule', 'Remove-LdoStorageCurrentIpRule'
    ) {
        (Get-Command $_).Parameters.ContainsKey('SoftFail') | Should -BeTrue
    }
}
