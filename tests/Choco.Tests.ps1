BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Choco module surface' {
    It 'exports Assert-LdoChocoPath' {
        Get-Command Assert-LdoChocoPath -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Assert-LdoChocoPath' {
    It 'skips quietly on non-Windows hosts' -Skip:($IsWindows) {
        { Assert-LdoChocoPath } | Should -Not -Throw
    }
}
