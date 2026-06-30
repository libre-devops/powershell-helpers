BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Git module surface' {
    It 'exports the expected commands' -ForEach @(
        'Assert-LdoGitRepository', 'Get-LdoGitBranch', 'Get-LdoGitRepositoryUrl', 'Export-LdoGitContextToTfVar'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoGitBranch / Get-LdoGitRepositoryUrl (CI env)' {
    BeforeEach {
        $script:saved = @{
            GITHUB_HEAD_REF       = $env:GITHUB_HEAD_REF
            GITHUB_REF_NAME       = $env:GITHUB_REF_NAME
            BUILD_SOURCEBRANCHNAME = $env:BUILD_SOURCEBRANCHNAME
            GITHUB_SERVER_URL     = $env:GITHUB_SERVER_URL
            GITHUB_REPOSITORY     = $env:GITHUB_REPOSITORY
        }
        $env:GITHUB_HEAD_REF = ''
        $env:GITHUB_REF_NAME = ''
        $env:BUILD_SOURCEBRANCHNAME = ''
        $env:GITHUB_SERVER_URL = ''
        $env:GITHUB_REPOSITORY = ''
    }
    AfterEach {
        foreach ($k in $script:saved.Keys) { Set-Item -Path "Env:$k" -Value $script:saved[$k] }
    }

    It 'prefers GITHUB_REF_NAME for the branch' {
        $env:GITHUB_REF_NAME = 'feature/x'
        Get-LdoGitBranch | Should -Be 'feature/x'
    }

    It 'prefers GITHUB_HEAD_REF over GITHUB_REF_NAME' {
        $env:GITHUB_HEAD_REF = 'pr-source'
        $env:GITHUB_REF_NAME = 'main'
        Get-LdoGitBranch | Should -Be 'pr-source'
    }

    It 'builds the repo URL from the GitHub Actions context' {
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'libre-devops/terraform-azurerm-tags'
        Get-LdoGitRepositoryUrl | Should -Be 'https://github.com/libre-devops/terraform-azurerm-tags'
    }
}

Describe 'Export-LdoGitContextToTfVar' {
    BeforeEach {
        $script:saved = @{
            GITHUB_REF_NAME       = $env:GITHUB_REF_NAME
            GITHUB_SERVER_URL     = $env:GITHUB_SERVER_URL
            GITHUB_REPOSITORY     = $env:GITHUB_REPOSITORY
            TF_VAR_deployed_branch = $env:TF_VAR_deployed_branch
            TF_VAR_deployed_repo   = $env:TF_VAR_deployed_repo
        }
        $env:GITHUB_REF_NAME = 'main'
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'libre-devops/terraform-azurerm-tags'
        $env:TF_VAR_deployed_branch = ''
        $env:TF_VAR_deployed_repo = ''
    }
    AfterEach {
        foreach ($k in $script:saved.Keys) { Set-Item -Path "Env:$k" -Value $script:saved[$k] }
    }

    It 'sets TF_VAR_deployed_branch and TF_VAR_deployed_repo' {
        Export-LdoGitContextToTfVar
        $env:TF_VAR_deployed_branch | Should -Be 'main'
        $env:TF_VAR_deployed_repo   | Should -Be 'https://github.com/libre-devops/terraform-azurerm-tags'
    }
}

Describe 'Assert-LdoGitRepository' {
    It 'throws outside a git repository' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldogit-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            { Assert-LdoGitRepository -Path $dir } | Should -Throw
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
