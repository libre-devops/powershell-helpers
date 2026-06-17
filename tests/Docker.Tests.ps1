BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Docker module surface' {
    It 'exports the expected commands' -ForEach @(
        'Assert-LdoDockerExists', 'Build-LdoDockerImage', 'Push-LdoDockerImage'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Assert-LdoDockerExists' {
    It 'throws when docker is not found' {
        InModuleScope LibreDevOpsHelpers.Docker {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'docker' }
            { Assert-LdoDockerExists } | Should -Throw
        }
    }
}

Describe 'Build-LdoDockerImage' {
    It 'throws when the Dockerfile cannot be resolved' {
        { Build-LdoDockerImage -DockerfilePath (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())) -ImageName 'repo/app:1.0.0' } |
            Should -Throw
    }
}
