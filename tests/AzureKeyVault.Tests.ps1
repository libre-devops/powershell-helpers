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

Describe 'Add-LdoKeyVaultCurrentIpRule existing-rule detection' {
    # az keyvault network-rule list returns { ipRules: [{ value }] }, and the vault stores a single
    # address as a /32. The check used to filter the top level (never matching), so it re-added the
    # rule every time; az only deduplicated it.

    It 'skips the add when the vault already allows <_>' -ForEach @('203.0.113.7/32', '203.0.113.7') {
        InModuleScope LibreDevOpsHelpers.AzureKeyVault -Parameters @{ Existing = $_ } {
            param($Existing)
            Mock Test-LdoKeyVaultDanceTarget { $true }
            Mock Get-LdoPublicIpAddress { '203.0.113.7' }
            Mock Assert-LdoLastExitCode { }
            Mock Write-LdoLog { }
            # The canned az output is closed over, so the mock sees it wherever Pester runs it.
            $show = '{"publicNetworkAccess":"Enabled","defaultAction":"Deny","bypass":"AzureServices"}'
            $list = ConvertTo-Json -InputObject @($Existing) -Compress
            $azMock = {
                $joined = $args -join ' '
                if ($joined -like 'keyvault show*') { return $show }
                if ($joined -like 'keyvault network-rule list*') {
                    # Like the real CLI: the command returns an object, so only the ipRules
                    # projection reaches the addresses; any other query (such as a top-level
                    # filter, the old bug) finds nothing.
                    $query = $args[[array]::IndexOf($args, '--query') + 1]
                    if ($query -eq 'ipRules[].value') { return $list }
                    return ''
                }
                return ''
            }.GetNewClosure()
            Mock az $azMock
            Add-LdoKeyVaultCurrentIpRule -ResourceGroup rg -KeyVaultName kv
            Should -Invoke az -Times 0 -Exactly -ParameterFilter { ($args -join ' ') -like 'keyvault network-rule add*' }
        }
    }

    It 'adds the rule when the vault does not allow the address' {
        InModuleScope LibreDevOpsHelpers.AzureKeyVault -Parameters @{ Existing = '198.51.100.1/32' } {
            param($Existing)
            Mock Test-LdoKeyVaultDanceTarget { $true }
            Mock Get-LdoPublicIpAddress { '203.0.113.7' }
            Mock Assert-LdoLastExitCode { }
            Mock Write-LdoLog { }
            # The canned az output is closed over, so the mock sees it wherever Pester runs it.
            $show = '{"publicNetworkAccess":"Enabled","defaultAction":"Deny","bypass":"AzureServices"}'
            $list = ConvertTo-Json -InputObject @($Existing) -Compress
            $azMock = {
                $joined = $args -join ' '
                if ($joined -like 'keyvault show*') { return $show }
                if ($joined -like 'keyvault network-rule list*') {
                    # Like the real CLI: the command returns an object, so only the ipRules
                    # projection reaches the addresses; any other query (such as a top-level
                    # filter, the old bug) finds nothing.
                    $query = $args[[array]::IndexOf($args, '--query') + 1]
                    if ($query -eq 'ipRules[].value') { return $list }
                    return ''
                }
                return ''
            }.GetNewClosure()
            Mock az $azMock
            Add-LdoKeyVaultCurrentIpRule -ResourceGroup rg -KeyVaultName kv
            Should -Invoke az -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -like 'keyvault network-rule add*--ip-address 203.0.113.7*' }
        }
    }
}
