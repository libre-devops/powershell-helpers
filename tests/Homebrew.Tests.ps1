BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Homebrew module surface' {
    It 'exports Assert-LdoHomebrewPath' {
        Get-Command Assert-LdoHomebrewPath -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Assert-LdoHomebrewPath' {
    It 'returns when brew is already on PATH' {
        InModuleScope LibreDevOpsHelpers.Homebrew {
            Mock Get-Command { [pscustomobject]@{ Source = '/usr/bin/brew' } } -ParameterFilter { $Name -eq 'brew' }
            { Assert-LdoHomebrewPath } | Should -Not -Throw
        }
    }

    It 'throws when brew cannot be located' {
        InModuleScope LibreDevOpsHelpers.Homebrew {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'brew' }
            Mock Test-Path { $false }
            { Assert-LdoHomebrewPath } | Should -Throw
        }
    }
}
