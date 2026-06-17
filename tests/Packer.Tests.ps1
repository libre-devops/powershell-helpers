BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Packer module surface' {
    It 'exports the expected commands' -ForEach @(
        'Invoke-LdoPackerInit', 'Invoke-LdoPackerValidate',
        'Invoke-LdoPackerBuild', 'Invoke-LdoPackerWorkflow'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Packer template validation' {
    It 'throws when the template path is missing' -ForEach @(
        'Invoke-LdoPackerInit', 'Invoke-LdoPackerValidate', 'Invoke-LdoPackerBuild', 'Invoke-LdoPackerWorkflow'
    ) {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())
        { & $_ -TemplatePath $missing } | Should -Throw
    }
}
