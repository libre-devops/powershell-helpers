BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureFunctionApps module surface' {
    It 'exports the expected commands' -ForEach @(
        'Compress-LdoFunctionAppSource', 'Invoke-LdoFunctionAppZipDeploy',
        'Get-LdoFunctionAppDefaultUrl', 'Set-LdoFunctionAppSetting',
        'Add-LdoFunctionAppCurrentIpRule', 'Remove-LdoFunctionAppCurrentIpRule'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Compress-LdoFunctionAppSource' {
    BeforeAll {
        $src = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-src-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src | Out-Null
        Set-Content -Path (Join-Path $src 'host.json') -Value '{}'
        $zip = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-" + [guid]::NewGuid() + ".zip")
    }
    AfterAll {
        Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }

    It 'creates a zip from a source folder' {
        Compress-LdoFunctionAppSource -SourcePath $src -ZipPath $zip
        Test-Path $zip | Should -BeTrue
    }

    It 'throws when the zip exists and -Overwrite is not set' {
        { Compress-LdoFunctionAppSource -SourcePath $src -ZipPath $zip } | Should -Throw
    }

    It 'overwrites when -Overwrite is set' {
        { Compress-LdoFunctionAppSource -SourcePath $src -ZipPath $zip -Overwrite } | Should -Not -Throw
    }

    It 'rejects a source path that does not exist' {
        { Compress-LdoFunctionAppSource -SourcePath (Join-Path $src 'nope') -ZipPath $zip -Overwrite } | Should -Throw
    }
}

Describe 'Add-LdoFunctionAppCurrentIpRule parameter validation' {
    It 'rejects an out-of-range priority' {
        { Add-LdoFunctionAppCurrentIpRule -ResourceGroup rg -FunctionAppName app -Priority 5 } | Should -Throw
    }
    It 'rejects an invalid action' {
        { Add-LdoFunctionAppCurrentIpRule -ResourceGroup rg -FunctionAppName app -Action 'Maybe' } | Should -Throw
    }
}
