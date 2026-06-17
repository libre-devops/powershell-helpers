BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force

    # Az.Accounts is not installed in CI; stub the cmdlets these tests Mock.
    foreach ($name in 'Get-AzContext', 'Connect-AzAccount', 'Set-AzContext', 'Disconnect-AzAccount') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$name" -Value { param() }
        }
    }
}

Describe 'Test-LdoAzurePowerShellConnection' {
    It 'returns false when there is no context' {
        InModuleScope LibreDevOpsHelpers.AzurePowerShell {
            Mock Get-AzContext { $null }
            Test-LdoAzurePowerShellConnection | Should -BeFalse
        }
    }

    It 'returns true when a context with a subscription exists' {
        InModuleScope LibreDevOpsHelpers.AzurePowerShell {
            Mock Get-AzContext {
                [pscustomobject]@{
                    Account      = [pscustomobject]@{ Id = 'sp@test' }
                    Subscription = [pscustomobject]@{ Name = 'Test Sub' }
                }
            }
            Test-LdoAzurePowerShellConnection | Should -BeTrue
        }
    }
}

Describe 'ConvertTo-LdoSecureString' {
    It 'produces a SecureString of the right length' {
        InModuleScope LibreDevOpsHelpers.AzurePowerShell {
            $secure = ConvertTo-LdoSecureString -PlainText 'hunter2'
            $secure | Should -BeOfType [System.Security.SecureString]
            $secure.Length | Should -Be 7
        }
    }
}

Describe 'Connect-LdoAzurePowerShell' {
    It 'rejects an invalid method' {
        { Connect-LdoAzurePowerShell -Method 'Nope' } | Should -Throw
    }
}
