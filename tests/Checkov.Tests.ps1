BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Checkov module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoCheckov', 'Invoke-LdoCheckov'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-LdoCheckov' {
    It 'throws when the JSON plan is missing' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-ckv-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            { Invoke-LdoCheckov -CodePath $dir } | Should -Throw
        }
        finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
