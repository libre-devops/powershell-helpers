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

    It 'returns exactly one string (the zip path), suppressing the compile pipeline output' {
        # A real configuration script compiles ./<Name>/localhost.mof AND emits the MOF FileInfo to
        # the pipeline; the function must suppress that emission or its return value becomes an
        # array (caught live: Get-LdoMachineConfigPackageHash then failed to bind ZipPath). The
        # stub script and packaging function mimic both behaviours without needing libmi.
        function global:New-GuestConfigurationPackage {
            param($Name, $Configuration, $Type, $Path, $Force)
            $zip = Join-Path $Path "$Name.zip"
            Set-Content -LiteralPath $zip -Value 'stub package'
            [pscustomobject]@{ Name = $Name; Path = $zip }
        }
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "ldomc-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $cfg = Join-Path $work 'Example.ps1'
        Set-Content -LiteralPath $cfg -Value @'
$dir = Join-Path (Get-Location) 'Example'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $dir 'localhost.mof') -Value 'instance of Example'
Get-Item (Join-Path $dir 'localhost.mof')
'@
        try {
            $result = New-LdoMachineConfigPackage -ConfigurationScript $cfg -Name Example -OutputPath $work
            @($result).Count | Should -Be 1
            $result | Should -BeOfType [string]
            $result | Should -BeLike '*Example.zip'
        }
        finally {
            Remove-Item function:global:New-GuestConfigurationPackage -ErrorAction SilentlyContinue
            Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        }
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
