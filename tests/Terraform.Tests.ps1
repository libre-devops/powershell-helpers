BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Terraform module surface' {
    It 'exports the expected commands' -ForEach @(
        'Invoke-LdoTerraformValidate', 'Invoke-LdoTerraformFmtCheck',
        'Get-LdoTerraformStackFolders', 'Invoke-LdoTerraformInit',
        'Invoke-LdoTerraformWorkspaceSelect', 'Invoke-LdoTerraformPlan',
        'Invoke-LdoTerraformPlanDestroy', 'Invoke-LdoTerraformApply',
        'Invoke-LdoTerraformDestroy', 'Convert-LdoTerraformPlanToJson'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-LdoTerraformValidate' {
    It 'throws when the code path does not exist' {
        { Invoke-LdoTerraformValidate -CodePath (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())) } |
            Should -Throw
    }
}

Describe 'Get-LdoTerraformStackFolders' {
    BeforeAll {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-stacks-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($n in '02-compute', '01-network', 'shared') {
            New-Item -ItemType Directory -Path (Join-Path $root $n) | Out-Null
        }
    }
    AfterAll { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns all numbered stacks in numeric order' {
        $result = Get-LdoTerraformStackFolders -CodeRoot $root -StacksToRun all
        ($result | ForEach-Object { Split-Path $_ -Leaf }) | Should -Be @('01-network', '02-compute')
    }

    It 'returns named stacks in the requested order' {
        $result = Get-LdoTerraformStackFolders -CodeRoot $root -StacksToRun compute, network
        ($result | ForEach-Object { Split-Path $_ -Leaf }) | Should -Be @('02-compute', '01-network')
    }

    It 'throws for an unknown stack' {
        { Get-LdoTerraformStackFolders -CodeRoot $root -StacksToRun nope } | Should -Throw
    }

    It 'throws for a missing code root' {
        { Get-LdoTerraformStackFolders -CodeRoot (Join-Path $root 'absent') -StacksToRun all } | Should -Throw
    }
}
