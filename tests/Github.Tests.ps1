BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Github module surface' {
    It 'exports Get-LdoGitHubActionsInput' {
        Get-Command Get-LdoGitHubActionsInput -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoGitHubActionsInput' {
    AfterEach {
        $env:INPUT_MY_INPUT = $null
        $env:INPUT_MYINPUT = $null
    }

    It 'reads the underscore-normalised input variable' {
        $env:INPUT_MY_INPUT = 'from-underscore'
        Get-LdoGitHubActionsInput -Name 'my-input' | Should -Be 'from-underscore'
    }

    It 'returns the default when the input is not set' {
        Get-LdoGitHubActionsInput -Name 'absent-input' -Default 'fallback' | Should -Be 'fallback'
    }
}
