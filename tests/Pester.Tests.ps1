BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Pester module surface' {
    It 'exports the expected commands' -ForEach @(
        'Test-LdoZeroExitCode', 'Test-LdoCommandOutputMatch',
        'Register-LdoPesterAssertion', 'Invoke-LdoPesterTest'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-LdoZeroExitCode' {
    It 'succeeds when the command exits zero' {
        InModuleScope LibreDevOpsHelpers.Pester {
            Mock Get-LdoCommandResult { [pscustomobject]@{ Output = @('ok'); ExitCode = 0 } }
            (Test-LdoZeroExitCode -ActualValue 'whatever').Succeeded | Should -BeTrue
        }
    }

    It 'fails when the command exits non-zero' {
        InModuleScope LibreDevOpsHelpers.Pester {
            Mock Get-LdoCommandResult { [pscustomobject]@{ Output = @('boom'); ExitCode = 3 } }
            (Test-LdoZeroExitCode -ActualValue 'whatever').Succeeded | Should -BeFalse
        }
    }
}

Describe 'Test-LdoCommandOutputMatch' {
    It 'succeeds when output matches the regex' {
        InModuleScope LibreDevOpsHelpers.Pester {
            Mock Get-LdoCommandResult { [pscustomobject]@{ Output = @('Terraform v1.7.0'); ExitCode = 0 } }
            (Test-LdoCommandOutputMatch -ActualValue 'x' -RegularExpression 'Terraform v').Succeeded | Should -BeTrue
        }
    }
}

Describe 'Invoke-LdoPesterTest' {
    It 'throws when the test file is missing' {
        { Invoke-LdoPesterTest -TestFile 'NoSuchFile' -TestRoot ([System.IO.Path]::GetTempPath()) } | Should -Throw
    }
}
