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

Describe 'AzureKeyVault parameter validation' {
    It 'requires a key vault name' {
        { Add-LdoKeyVaultCurrentIpRule -ResourceGroup rg -KeyVaultName '' } | Should -Throw
    }
}

Describe 'RuleOnly dance option' {
    It 'exposes -RuleOnly on Remove-LdoKeyVaultCurrentIpRule' {
        (Get-Command Remove-LdoKeyVaultCurrentIpRule).Parameters.ContainsKey('RuleOnly') | Should -BeTrue
    }
}

Describe 'SoftFail dance option' {
    It 'exposes -SoftFail on <_>' -ForEach @(
        'Add-LdoKeyVaultCurrentIpRule', 'Remove-LdoKeyVaultCurrentIpRule'
    ) {
        (Get-Command $_).Parameters.ContainsKey('SoftFail') | Should -BeTrue
    }
}
