BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Tenv module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoTenv', 'Test-LdoTenv', 'Invoke-LdoTenvTerraformInstall'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-LdoTenv' {
    It 'returns true when tenv is found' {
        InModuleScope LibreDevOpsHelpers.Tenv {
            Mock Get-Command { [pscustomobject]@{ Source = '/usr/bin/tenv' } } -ParameterFilter { $Name -eq 'tenv' }
            Test-LdoTenv | Should -BeTrue
        }
    }

    It 'returns false when tenv is absent' {
        InModuleScope LibreDevOpsHelpers.Tenv {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'tenv' }
            Test-LdoTenv | Should -BeFalse
        }
    }
}
