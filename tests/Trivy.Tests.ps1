BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Trivy module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoTrivy', 'Invoke-LdoTrivy'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-LdoTrivy' {
    It 'throws when the code path does not exist' {
        { Invoke-LdoTrivy -CodePath (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())) } |
            Should -Throw
    }
}
