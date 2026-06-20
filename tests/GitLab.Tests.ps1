BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'GitLab module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoGlab', 'Test-LdoGlab', 'Connect-LdoGlab',
        'Invoke-LdoGlabPipeline', 'Get-LdoGlabPipeline', 'Wait-LdoGlabPipeline',
        'New-LdoGlabMergeRequest', 'New-LdoGlabRelease',
        'Set-LdoGlabCiVariable', 'Get-LdoGlabCiVariable',
        'Get-LdoGitLabCiVariable', 'Set-LdoGitLabCiOutput', 'Write-LdoGitLabCiSection'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'does not export the internal Invoke-LdoGlabCommand helper' {
        Get-Command Invoke-LdoGlabCommand -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Get-LdoGitLabCiVariable' {
    It 'returns the environment value when set' {
        $env:LDO_TEST_CI_VAR = 'from-env'
        try {
            Get-LdoGitLabCiVariable -Name LDO_TEST_CI_VAR -Default 'fallback' | Should -Be 'from-env'
        }
        finally {
            Remove-Item Env:\LDO_TEST_CI_VAR -ErrorAction SilentlyContinue
        }
    }

    It 'returns the default when the variable is unset' {
        Get-LdoGitLabCiVariable -Name LDO_TEST_MISSING_VAR -Default 'fallback' | Should -Be 'fallback'
    }
}

Describe 'Set-LdoGitLabCiOutput' {
    It 'appends a KEY=value line to the dotenv file' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-dotenv-" + [guid]::NewGuid() + '.env')
        try {
            Set-LdoGitLabCiOutput -Name imageTag -Value 'v1.2.3' -Path $path
            Set-LdoGitLabCiOutput -Name region -Value 'uksouth' -Path $path
            $lines = Get-Content $path
            $lines | Should -Contain 'imageTag=v1.2.3'
            $lines | Should -Contain 'region=uksouth'
        }
        finally {
            Remove-Item $path -ErrorAction SilentlyContinue
        }
    }

    It 'rejects an invalid variable name' {
        $path = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-dotenv-" + [guid]::NewGuid() + '.env')
        { Set-LdoGitLabCiOutput -Name '1-bad name' -Value 'x' -Path $path } | Should -Throw
    }
}

Describe 'Write-LdoGitLabCiSection' {
    It 'emits matching section_start and section_end markers around the script block' {
        $out = Write-LdoGitLabCiSection -Name build -Header 'Building' -ScriptBlock { 'ran' } 6>&1
        $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
        $text | Should -Match 'section_start:\d+:build'
        $text | Should -Match 'section_end:\d+:build'
    }

    It 'runs the script block and still closes the section when it throws' {
        $script:closed = $false
        $info = & {
            try { Write-LdoGitLabCiSection -Name failing -ScriptBlock { throw 'boom' } }
            catch { }
        } 6>&1
        (($info | ForEach-Object { $_.ToString() }) -join "`n") | Should -Match 'section_end:\d+:failing'
    }

    It 'adds the collapsed tag when -Collapsed is set' {
        $out = Write-LdoGitLabCiSection -Name setup -Collapsed -ScriptBlock { } 6>&1
        (($out | ForEach-Object { $_.ToString() }) -join "`n") | Should -Match 'section_start:\d+:setup\[collapsed=true\]'
    }
}

Describe 'New-LdoGlabMergeRequest' {
    It 'throws when neither -Title nor -Fill is supplied' {
        { New-LdoGlabMergeRequest -Source feat -Target main } | Should -Throw '*-Title*'
    }
}

Describe 'New-LdoGlabRelease' {
    It 'throws when both -Notes and -NotesFile are supplied' {
        { New-LdoGlabRelease -Tag v1.0.0 -Notes 'x' -NotesFile 'y' } | Should -Throw '*only one*'
    }
}
