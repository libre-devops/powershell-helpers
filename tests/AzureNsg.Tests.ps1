BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureNsg module surface' {
    It 'exports the add and remove rule commands' -ForEach @(
        'Add-LdoNsgCurrentIpRule', 'Remove-LdoNsgRule'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Add-LdoNsgCurrentIpRule parameter validation' {
    It 'rejects an invalid direction' {
        { Add-LdoNsgCurrentIpRule -ResourceGroup rg -NsgName nsg -RuleName r -Priority 200 -Direction 'Sideways' -Access Allow } |
            Should -Throw
    }
    It 'rejects an invalid access' {
        { Add-LdoNsgCurrentIpRule -ResourceGroup rg -NsgName nsg -RuleName r -Priority 200 -Direction Inbound -Access 'Maybe' } |
            Should -Throw
    }
    It 'rejects an out-of-range priority' {
        { Add-LdoNsgCurrentIpRule -ResourceGroup rg -NsgName nsg -RuleName r -Priority 5 -Direction Inbound -Access Allow } |
            Should -Throw
    }
}
