BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'TfLint module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoTfLint', 'Invoke-LdoTfLint'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-LdoTfLint' {
    It 'throws when the code path does not exist' {
        { Invoke-LdoTfLint -CodePath (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())) } |
            Should -Throw
    }

    It 'throws when the config file does not exist' {
        { Invoke-LdoTfLint -CodePath $PSScriptRoot -ConfigFile (Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).hcl") } |
            Should -Throw
    }
}
