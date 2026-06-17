BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureDevOps module surface' {
    It 'exports the expected commands' -ForEach @(
        'Get-LdoAzureDevOpsOrgId',
        'Invoke-LdoAzureDevOpsTokenReplacement',
        'Invoke-LdoAzureDevOpsTokenReplacementRevert'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoAzureDevOpsOrgId' {
    It 'returns an object with the instance id and url' {
        InModuleScope LibreDevOpsHelpers.AzureDevOps {
            Mock Invoke-RestMethod { [pscustomobject]@{ instanceId = 'abc-123' } }
            $pat = ConvertTo-SecureString 'fake-pat' -AsPlainText -Force
            $result = Get-LdoAzureDevOpsOrgId -OrganizationUrl 'https://dev.azure.com/contoso/' -Pat $pat
            $result.OrganizationId | Should -Be 'abc-123'
            $result.OrganizationUrl | Should -Be 'https://dev.azure.com/contoso/'
        }
    }

    It 'throws when the response has no instance id' {
        InModuleScope LibreDevOpsHelpers.AzureDevOps {
            Mock Invoke-RestMethod { [pscustomobject]@{ } }
            $pat = ConvertTo-SecureString 'fake-pat' -AsPlainText -Force
            { Get-LdoAzureDevOpsOrgId -OrganizationUrl 'https://dev.azure.com/contoso' -Pat $pat } | Should -Throw
        }
    }
}

Describe 'Invoke-LdoAzureDevOpsTokenReplacement' {
    BeforeAll {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-ado-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $work | Out-Null
        $tf = Join-Path $work 'main.tf'
        Set-Content -Path $tf -Value 'source = "git::https://__SYSTEM_ACCESS_TOKEN__@dev.azure.com/contoso/_git/modules"'
    }
    AfterAll {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
        $Env:SYSTEM_ACCESSTOKEN = $null
    }

    It 'throws when the path does not exist' {
        { Invoke-LdoAzureDevOpsTokenReplacement -CodePath (Join-Path $work 'nope') } | Should -Throw
    }

    It 'replaces the placeholder then reverts it' {
        $Env:SYSTEM_ACCESSTOKEN = 'tok123'
        Invoke-LdoAzureDevOpsTokenReplacement -CodePath $work
        (Get-Content $tf -Raw) | Should -Match 'git::https://tok123@'

        Invoke-LdoAzureDevOpsTokenReplacementRevert -CodePath $work
        (Get-Content $tf -Raw) | Should -Match 'git::https://__SYSTEM_ACCESS_TOKEN__@'
    }

    It 'throws when no pipeline token is set' {
        $Env:SYSTEM_ACCESSTOKEN = $null
        $Env:SYSTEM_ACCESS_TOKEN = $null
        { Invoke-LdoAzureDevOpsTokenReplacement -CodePath $work } | Should -Throw
    }
}
