BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'MachineConfig module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoGuestConfigurationModule',
        'New-LdoMachineConfigPackage',
        'Test-LdoMachineConfigPackage',
        'Get-LdoMachineConfigPackageHash',
        'Publish-LdoMachineConfigPackage'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoMachineConfigPackageHash' {
    It 'throws when the file does not exist' {
        { Get-LdoMachineConfigPackageHash -ZipPath (Join-Path ([System.IO.Path]::GetTempPath()) "nope-$([guid]::NewGuid()).zip") } |
            Should -Throw '*not found*'
    }

    It 'returns the uppercase SHA256 of a file (the content_hash form)' {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "ldomc-$([guid]::NewGuid()).bin"
        Set-Content -LiteralPath $f -Value 'hello machine configuration' -NoNewline
        try {
            $hash = Get-LdoMachineConfigPackageHash -ZipPath $f
            $hash | Should -Be (Get-FileHash -Algorithm SHA256 -Path $f).Hash
            $hash | Should -MatchExactly '^[A-F0-9]{64}$'
        }
        finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'New-LdoMachineConfigPackage' {
    It 'throws when the configuration script does not exist' {
        { New-LdoMachineConfigPackage -ConfigurationScript (Join-Path ([System.IO.Path]::GetTempPath()) "no-$([guid]::NewGuid()).ps1") -Name Example } |
            Should -Throw '*not found*'
    }

    It 'throws when the GuestConfiguration module is unavailable' -Skip:([bool](Get-Command New-GuestConfigurationPackage -ErrorAction SilentlyContinue)) {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "cfg-$([guid]::NewGuid()).ps1"
        Set-Content -LiteralPath $f -Value 'Configuration Example {}'
        try {
            { New-LdoMachineConfigPackage -ConfigurationScript $f -Name Example } |
                Should -Throw '*GuestConfiguration*'
        }
        finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-LdoMachineConfigPackage' {
    It 'throws when the package does not exist' {
        { Test-LdoMachineConfigPackage -ZipPath (Join-Path ([System.IO.Path]::GetTempPath()) "no-$([guid]::NewGuid()).zip") } |
            Should -Throw '*not found*'
    }
}

Describe 'Publish-LdoMachineConfigPackage' {
    It 'throws when the package does not exist' {
        { Publish-LdoMachineConfigPackage -ZipPath (Join-Path ([System.IO.Path]::GetTempPath()) "no-$([guid]::NewGuid()).zip") -StorageAccountName sa -ContainerName packages } |
            Should -Throw '*not found*'
    }
}
