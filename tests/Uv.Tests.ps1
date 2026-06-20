BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Uv module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoUv', 'Test-LdoUv', 'Install-LdoUvPython', 'Get-LdoUvPython',
        'Set-LdoUvPythonPin', 'New-LdoUvVenv', 'Invoke-LdoUvSync', 'Invoke-LdoUvLock',
        'Add-LdoUvPackage', 'Remove-LdoUvPackage', 'Invoke-LdoUvRun',
        'Invoke-LdoUvPipInstall', 'Invoke-LdoUvPipUninstall'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'does not export the internal Invoke-LdoUvCommand helper' {
        Get-Command Invoke-LdoUvCommand -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-LdoUvPipInstall' {
    It 'throws when neither -Package nor -RequirementsFile is supplied' {
        { Invoke-LdoUvPipInstall } | Should -Throw '*Specify -Package*'
    }

    It 'throws when the requirements file does not exist' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-req-" + [guid]::NewGuid() + '.txt')
        { Invoke-LdoUvPipInstall -RequirementsFile $missing } | Should -Throw '*not found*'
    }
}

Describe 'Invoke-LdoUvRun' {
    It 'throws when the project path does not exist' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-proj-" + [guid]::NewGuid())
        { Invoke-LdoUvRun -ProjectPath $missing -- echo hi } | Should -Throw '*not found*'
    }
}

Describe 'Invoke-LdoUvSync' {
    It 'rejects a non-existent project path at parameter binding' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-proj-" + [guid]::NewGuid())
        { Invoke-LdoUvSync -ProjectPath $missing } | Should -Throw
    }
}
