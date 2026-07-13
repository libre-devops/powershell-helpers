BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force

    # A minimal plan JSON: two importable detection rules (one keyed by id, one only by display
    # name), an unsupported Graph collection, and a non Graph resource as noise.
    $script:planJson = @'
{
  "resource_changes": [
    {
      "address": "module.d.msgraph_resource.detection_rules[\"12345\"]",
      "mode": "managed",
      "type": "msgraph_resource",
      "change": {
        "actions": ["create"],
        "after": {
          "url": "security/rules/detectionRules",
          "api_version": "beta",
          "body": { "id": "12345", "displayName": "Rule A" }
        }
      }
    },
    {
      "address": "module.d.msgraph_resource.detection_rules[\"named\"]",
      "mode": "managed",
      "type": "msgraph_resource",
      "change": {
        "actions": ["create"],
        "after": {
          "url": "security/rules/detectionRules",
          "api_version": "beta",
          "body": { "displayName": "Rule B" }
        }
      }
    },
    {
      "address": "msgraph_resource.app",
      "mode": "managed",
      "type": "msgraph_resource",
      "change": {
        "actions": ["create"],
        "after": { "url": "applications", "body": { "displayName": "App" } }
      }
    },
    {
      "address": "azurerm_resource_group.rg",
      "mode": "managed",
      "type": "azurerm_resource_group",
      "change": { "actions": ["create"], "after": {} }
    }
  ]
}
'@
}

Describe 'GraphImport module surface' {
    It 'exports the expected commands' -ForEach @(
        'Get-LdoTerraformGraphImportResourceId', 'Invoke-LdoTerraformGraphImportFromPlan'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoTerraformGraphImportResourceId' {

    It 'matches by planned body id first' {
        InModuleScope LibreDevOpsHelpers.Terraform.GraphImport {
            Mock Get-LdoCustomDetectionRule {
                @([pscustomobject]@{ id = '12345'; displayName = 'Rule A' },
                    [pscustomobject]@{ id = '67890'; displayName = 'Rule B' })
            }
            $after = '{"api_version":"beta","body":{"id":"12345","displayName":"Renamed"}}' | ConvertFrom-Json
            Get-LdoTerraformGraphImportResourceId -Url 'security/rules/detectionRules' -After $after |
                Should -Be 'security/rules/detectionRules/12345?api-version=beta'
        }
    }

    It 'falls back to an unambiguous display name' {
        InModuleScope LibreDevOpsHelpers.Terraform.GraphImport {
            Mock Get-LdoCustomDetectionRule {
                @([pscustomobject]@{ id = '67890'; displayName = 'Rule B' })
            }
            $after = '{"body":{"displayName":"Rule B"}}' | ConvertFrom-Json
            Get-LdoTerraformGraphImportResourceId -Url 'security/rules/detectionRules' -After $after |
                Should -Be 'security/rules/detectionRules/67890?api-version=beta'
        }
    }

    It 'refuses an ambiguous display name match' {
        InModuleScope LibreDevOpsHelpers.Terraform.GraphImport {
            Mock Get-LdoCustomDetectionRule {
                @([pscustomobject]@{ id = '1'; displayName = 'Dup' },
                    [pscustomobject]@{ id = '2'; displayName = 'Dup' })
            }
            $after = '{"body":{"displayName":"Dup"}}' | ConvertFrom-Json
            Get-LdoTerraformGraphImportResourceId -Url 'security/rules/detectionRules' -After $after |
                Should -BeNullOrEmpty
        }
    }

    It 'returns null for an unsupported collection url' {
        InModuleScope LibreDevOpsHelpers.Terraform.GraphImport {
            Mock Get-LdoCustomDetectionRule { @() }
            $after = '{"body":{"displayName":"App"}}' | ConvertFrom-Json
            Get-LdoTerraformGraphImportResourceId -Url 'applications' -After $after | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-LdoTerraformGraphImportFromPlan' {

    It 'maps supported creates, writes the manifest, and dry runs without terraform' {
        $planFile = Join-Path $TestDrive 'plan.json'
        Set-Content -Path $planFile -Value $script:planJson
        $manifest = Join-Path $TestDrive 'map.csv'

        InModuleScope LibreDevOpsHelpers.Terraform.GraphImport -Parameters @{ plan = $planFile; manifest = $manifest; dir = $TestDrive } {
            param($plan, $manifest, $dir)
            Mock Get-LdoCustomDetectionRule {
                @([pscustomobject]@{ id = '12345'; displayName = 'Rule A' },
                    [pscustomobject]@{ id = '67890'; displayName = 'Rule B' })
            }
            Invoke-LdoTerraformGraphImportFromPlan -PlanJson $plan -CodePath $dir -DryRun -Manifest $manifest
        }

        $rows = Import-Csv $manifest
        @($rows).Count | Should -Be 2
        $rows[0].Id | Should -Be 'security/rules/detectionRules/12345?api-version=beta'
        $rows[1].Address | Should -Be 'module.d.msgraph_resource.detection_rules["named"]'
        $rows[1].Id | Should -Be 'security/rules/detectionRules/67890?api-version=beta'
    }

    It 'reports nothing to import on an empty plan' {
        $planFile = Join-Path $TestDrive 'empty-plan.json'
        Set-Content -Path $planFile -Value '{"resource_changes": []}'
        { Invoke-LdoTerraformGraphImportFromPlan -PlanJson $planFile -CodePath $TestDrive -DryRun } |
            Should -Not -Throw
    }
}
