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

Describe 'Add-LdoStorageCurrentIpRule existing-rule detection' {
    # az storage account network-rule list returns { ipRules: [{ action, ipAddressOrRange }] }. The
    # check used to filter the top level (never matching), so it re-added the rule every time.

    It 'skips the add when the account already allows <_>' -ForEach @('203.0.113.7', '203.0.113.7/32') {
        InModuleScope LibreDevOpsHelpers.AzureStorage -Parameters @{ Existing = $_ } {
            param($Existing)
            Mock Test-LdoStorageDanceTarget { $true }
            Mock Get-LdoPublicIpAddress { '203.0.113.7' }
            Mock Assert-LdoLastExitCode { }
            Mock Write-LdoLog { }
            # The canned az output is closed over, so the mock sees it wherever Pester runs it.
            $show = '{"publicNetworkAccess":"Enabled","networkRuleSet":{"defaultAction":"Deny","bypass":"AzureServices"}}'
            $list = ConvertTo-Json -InputObject @($Existing) -Compress
            $azMock = {
                $joined = $args -join ' '
                if ($joined -like 'storage account show*') { return $show }
                if ($joined -like 'storage account network-rule list*') {
                    # Like the real CLI: the command returns an object, so only the ipRules
                    # projection reaches the addresses; any other query (such as a top-level
                    # filter, the old bug) finds nothing.
                    $query = $args[[array]::IndexOf($args, '--query') + 1]
                    if ($query -eq 'ipRules[].ipAddressOrRange') { return $list }
                    return ''
                }
                return ''
            }.GetNewClosure()
            Mock az $azMock
            Add-LdoStorageCurrentIpRule -ResourceGroup rg -StorageAccountName st
            Should -Invoke az -Times 0 -Exactly -ParameterFilter { ($args -join ' ') -like 'storage account network-rule add*' }
        }
    }

    It 'adds the rule when the account does not allow the address' {
        InModuleScope LibreDevOpsHelpers.AzureStorage -Parameters @{ Existing = '198.51.100.1' } {
            param($Existing)
            Mock Test-LdoStorageDanceTarget { $true }
            Mock Get-LdoPublicIpAddress { '203.0.113.7' }
            Mock Assert-LdoLastExitCode { }
            Mock Write-LdoLog { }
            # The canned az output is closed over, so the mock sees it wherever Pester runs it.
            $show = '{"publicNetworkAccess":"Enabled","networkRuleSet":{"defaultAction":"Deny","bypass":"AzureServices"}}'
            $list = ConvertTo-Json -InputObject @($Existing) -Compress
            $azMock = {
                $joined = $args -join ' '
                if ($joined -like 'storage account show*') { return $show }
                if ($joined -like 'storage account network-rule list*') {
                    # Like the real CLI: the command returns an object, so only the ipRules
                    # projection reaches the addresses; any other query (such as a top-level
                    # filter, the old bug) finds nothing.
                    $query = $args[[array]::IndexOf($args, '--query') + 1]
                    if ($query -eq 'ipRules[].ipAddressOrRange') { return $list }
                    return ''
                }
                return ''
            }.GetNewClosure()
            Mock az $azMock
            Add-LdoStorageCurrentIpRule -ResourceGroup rg -StorageAccountName st
            Should -Invoke az -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -like 'storage account network-rule add*--ip-address 203.0.113.7*' }
        }
    }
}
