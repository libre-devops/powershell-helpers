BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Python module surface' {
    It 'exports the expected commands' -ForEach @(
        'New-LdoVenv', 'Initialize-LdoVenv', 'Use-LdoVenv', 'Clear-LdoVenv',
        'Remove-LdoVenv', 'Invoke-LdoPythonInstallRequirements',
        'Remove-LdoPythonPackages', 'Invoke-LdoPytestRun'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Initialize-LdoVenv' {
    It 'throws when no virtual environment exists' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-venv-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            { Initialize-LdoVenv -VenvPath $dir } | Should -Throw
        }
        finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Remove-LdoVenv' {
    It 'removes an existing venv folder' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-venv-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $dir '.venv') -Force | Out-Null
        try {
            Remove-LdoVenv -VenvPath $dir
            Test-Path (Join-Path $dir '.venv') | Should -BeFalse
        }
        finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
