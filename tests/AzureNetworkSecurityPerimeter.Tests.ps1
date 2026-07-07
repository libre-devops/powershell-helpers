BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureNetworkSecurityPerimeter module surface' {
    It 'exports the perimeter dance commands' -ForEach @(
        'Add-LdoNspCurrentIpRule', 'Remove-LdoNspRule'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'AzureNetworkSecurityPerimeter parameter validation' {
    It 'requires a perimeter name' {
        { Add-LdoNspCurrentIpRule -ResourceGroup rg -PerimeterName '' -ProfileName default } | Should -Throw
    }
}

Describe 'SoftFail dance option' {
    It 'exposes -SoftFail on Add-LdoNspCurrentIpRule' {
        (Get-Command Add-LdoNspCurrentIpRule).Parameters.ContainsKey('SoftFail') | Should -BeTrue
    }
}
