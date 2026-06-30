BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Conftest module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoConftest', 'Assert-LdoConftest', 'Invoke-LdoConftest'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-LdoConftest' {
    It 'throws when the plan JSON does not exist' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldoconftest-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            { Invoke-LdoConftest -PlanJsonPath (Join-Path $dir 'nope.json') -PolicyPath $dir } |
                Should -Throw
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'throws when the policy path does not exist' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldoconftest-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        $plan = Join-Path $dir 'plan.json'
        '{"resource_changes":[]}' | Set-Content -LiteralPath $plan
        try {
            { Invoke-LdoConftest -PlanJsonPath $plan -PolicyPath (Join-Path $dir 'missing') } |
                Should -Throw '*Policy path not found*'
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'with the conftest CLI available' -Skip:($null -eq (Get-Command conftest -ErrorAction SilentlyContinue)) {
        BeforeAll {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldoconftest-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path (Join-Path $dir 'policies') | Out-Null
            # A warn-only policy: informational, must not fail the run.
            @'
package libredevops.test.warnonly

import rego.v1

warn contains msg if {
	some rc in input.resource_changes
	rc.type == "azurerm_resource_group"
	not startswith(rc.change.after.name, "rg-")
	msg := sprintf("%s is not rg-", [rc.change.after.name])
}
'@ | Set-Content -LiteralPath (Join-Path $dir 'policies/warnonly.rego')
            # A deny policy: must fail the run.
            @'
package libredevops.test.denyany

import rego.v1

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "azurerm_resource_group"
	msg := sprintf("denied %s", [rc.address])
}
'@ | Set-Content -LiteralPath (Join-Path $dir 'policies/denyany.rego')
            $plan = Join-Path $dir 'plan.json'
            '{"resource_changes":[{"address":"azurerm_resource_group.bad","mode":"managed","type":"azurerm_resource_group","change":{"after":{"name":"badname"}}}]}' |
                Set-Content -LiteralPath $plan
        }
        AfterAll { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'does not throw when only warn rules fire' {
            { Invoke-LdoConftest -PlanJsonPath $plan -PolicyPath (Join-Path $dir 'policies') -Namespace 'libredevops.test.warnonly' } |
                Should -Not -Throw
        }

        It 'throws when only warn rules fire and -FailOnWarn is set' {
            { Invoke-LdoConftest -PlanJsonPath $plan -PolicyPath (Join-Path $dir 'policies') -Namespace 'libredevops.test.warnonly' -FailOnWarn } |
                Should -Throw
        }

        It 'throws when a deny rule fires' {
            { Invoke-LdoConftest -PlanJsonPath $plan -PolicyPath (Join-Path $dir 'policies') -Namespace 'libredevops.test.denyany' } |
                Should -Throw
        }

        It 'does not throw on a deny when -SoftFail is set' {
            { Invoke-LdoConftest -PlanJsonPath $plan -PolicyPath (Join-Path $dir 'policies') -Namespace 'libredevops.test.denyany' -SoftFail } |
                Should -Not -Throw
        }
    }
}
