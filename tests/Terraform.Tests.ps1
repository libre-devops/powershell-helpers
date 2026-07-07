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

Describe 'Test-LdoTerraformPlanChangesResource' {
    BeforeAll {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldoplan-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null

        function Write-PlanFixture([string]$name, [object]$resourceChanges) {
            $path = Join-Path $dir $name
            @{ format_version = '1.2'; resource_changes = $resourceChanges } |
                ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path
            $path
        }

        $createPlan = Write-PlanFixture 'create.json' @(
            @{ type = 'azurerm_key_vault'; change = @{ actions = @('create'); before = $null; after = @{ name = 'kv-target' } } }
        )
        $updatePlan = Write-PlanFixture 'update.json' @(
            @{ type = 'azurerm_key_vault'; change = @{ actions = @('update'); before = @{ name = 'kv-target' }; after = @{ name = 'kv-target' } } }
        )
        $deletePlan = Write-PlanFixture 'delete.json' @(
            @{ type = 'azurerm_key_vault'; change = @{ actions = @('delete'); before = @{ name = 'kv-target' }; after = $null } }
        )
        $noopPlan = Write-PlanFixture 'noop.json' @(
            @{ type = 'azurerm_key_vault'; change = @{ actions = @('no-op'); before = @{ name = 'kv-target' }; after = @{ name = 'kv-target' } } }
        )
        $otherPlan = Write-PlanFixture 'other.json' @(
            @{ type = 'azurerm_key_vault'; change = @{ actions = @('update'); before = @{ name = 'kv-other' }; after = @{ name = 'kv-other' } } }
        )
        $emptyPlan = Join-Path $dir 'empty.json'
        '{"format_version": "1.2"}' | Set-Content -LiteralPath $emptyPlan
    }
    AfterAll { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'matches a created resource by after.name' {
        Test-LdoTerraformPlanChangesResource -PlanJsonPath $createPlan -ResourceType azurerm_key_vault -ResourceName kv-target | Should -BeTrue
    }

    It 'matches an updated resource' {
        Test-LdoTerraformPlanChangesResource -PlanJsonPath $updatePlan -ResourceType azurerm_key_vault -ResourceName kv-target | Should -BeTrue
    }

    It 'matches a deleted resource by before.name' {
        Test-LdoTerraformPlanChangesResource -PlanJsonPath $deletePlan -ResourceType azurerm_key_vault -ResourceName kv-target | Should -BeTrue
    }

    It 'ignores a no-op change' {
        Test-LdoTerraformPlanChangesResource -PlanJsonPath $noopPlan -ResourceType azurerm_key_vault -ResourceName kv-target | Should -BeFalse
    }

    It 'ignores a different resource name' {
        Test-LdoTerraformPlanChangesResource -PlanJsonPath $otherPlan -ResourceType azurerm_key_vault -ResourceName kv-target | Should -BeFalse
    }

    It 'ignores a different resource type' {
        Test-LdoTerraformPlanChangesResource -PlanJsonPath $updatePlan -ResourceType azurerm_storage_account -ResourceName kv-target | Should -BeFalse
    }

    It 'returns false for a plan without resource_changes' {
        Test-LdoTerraformPlanChangesResource -PlanJsonPath $emptyPlan -ResourceType azurerm_key_vault -ResourceName kv-target | Should -BeFalse
    }

    It 'throws for a missing plan file' {
        { Test-LdoTerraformPlanChangesResource -PlanJsonPath (Join-Path $dir 'absent.json') -ResourceType azurerm_key_vault -ResourceName kv-target } | Should -Throw
    }
}
