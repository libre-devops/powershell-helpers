BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'AzureLock module surface' {
    It 'exports the expected commands' -ForEach @(
        'Get-LdoResourceGroupLock', 'Remove-LdoResourceGroupLock', 'Add-LdoResourceGroupLock', 'Get-LdoResourceGroupNamesFromPlan'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoResourceGroupNamesFromPlan' {
    BeforeAll {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldolock-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        # Plan JSON with resource groups in both the root module and a child module, plus an
        # unrelated resource that must be ignored.
        $plan = @'
{
  "planned_values": {
    "root_module": {
      "resources": [
        { "type": "azurerm_resource_group", "values": { "name": "rg-ldo-uks-prd-001" } },
        { "type": "azurerm_storage_account",  "values": { "name": "saldouksprd001" } }
      ],
      "child_modules": [
        {
          "resources": [
            { "type": "azurerm_resource_group", "values": { "name": "rg-ldo-uks-prd-002" } }
          ]
        }
      ]
    }
  }
}
'@
        $script:planPath = Join-Path $dir 'plan.json'
        $plan | Set-Content -LiteralPath $script:planPath
    }
    AfterAll { Remove-Item (Split-Path $script:planPath) -Recurse -Force -ErrorAction SilentlyContinue }

    It 'returns resource group names from root and child modules' {
        $names = Get-LdoResourceGroupNamesFromPlan -PlanJsonPath $script:planPath
        @($names) | Should -Contain 'rg-ldo-uks-prd-001'
        @($names) | Should -Contain 'rg-ldo-uks-prd-002'
    }

    It 'ignores non-resource-group resources' {
        $names = Get-LdoResourceGroupNamesFromPlan -PlanJsonPath $script:planPath
        @($names).Count | Should -Be 2
    }

    It 'throws when the plan JSON is missing' {
        { Get-LdoResourceGroupNamesFromPlan -PlanJsonPath (Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).json") } |
            Should -Throw
    }

    It 'reads resource groups from prior_state (a destroy plan)' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldolockd-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        $destroyPlan = @'
{
  "planned_values": { "root_module": {} },
  "prior_state": {
    "values": {
      "root_module": {
        "resources": [
          { "type": "azurerm_resource_group", "values": { "name": "rg-ldo-uks-prd-009" } }
        ]
      }
    }
  }
}
'@
        $p = Join-Path $dir 'destroy.json'
        $destroyPlan | Set-Content -LiteralPath $p
        try {
            @(Get-LdoResourceGroupNamesFromPlan -PlanJsonPath $p) | Should -Contain 'rg-ldo-uks-prd-009'
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
