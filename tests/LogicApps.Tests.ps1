BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force

    # Keep the suite output clean; these commands log at INFO and WARN by design.
    Set-LdoLogLevel -Level ERROR

    # ---------------------------------------------------------------------------------------------
    # Fixtures. Each is a minimal but REAL shape, so the tests exercise the same code paths a
    # portal export does rather than a convenient simplification.
    # ---------------------------------------------------------------------------------------------

    # Designer code view: definition plus the resolved VALUES beside it.
    $script:CodeView = @'
{
  "definition": {
    "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
      "$connections": { "type": "Object", "defaultValue": {} },
      "ticket_prefix": { "type": "String" },
      "retry_count": { "type": "Int" },
      "category_map": { "type": "Array" }
    },
    "triggers": {
      "manual": { "type": "Request", "kind": "Http" }
    },
    "actions": {
      "Compose": { "type": "Compose", "inputs": "@parameters('ticket_prefix')" }
    }
  },
  "parameters": {
    "ticket_prefix": { "value": "SIR" },
    "retry_count": { "value": 3 },
    "category_map": { "value": [ { "contains": "DDoS", "value": "Denial of Service" } ] },
    "$connections": {
      "type": "Object",
      "value": {
        "servicenow": {
          "id": "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Web/locations/uksouth/managedApis/service-now",
          "connectionId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-int/providers/Microsoft.Web/connections/api-servicenow",
          "connectionName": "api-servicenow",
          "connectionProperties": { "authentication": { "type": "ManagedServiceIdentity" } }
        },
        "azuresentinel": {
          "id": "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Web/locations/uksouth/managedApis/azuresentinel",
          "connectionId": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-int/providers/Microsoft.Web/connections/api-sentinel",
          "connectionName": "api-sentinel",
          "connectionProperties": {}
        }
      }
    }
  }
}
'@

    # The exact failure this module was built for: a declaration the wrapper carries no value for.
    $script:CodeViewMissingValue = $script:CodeView -replace '"ticket_prefix": \{ "value": "SIR" \},', ''

    # ARM resource GET: the definition lives under properties.
    $script:ArmResource = @'
{
  "id": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Logic/workflows/logic-arm",
  "name": "logic-arm",
  "type": "Microsoft.Logic/workflows",
  "location": "uksouth",
  "properties": {
    "definition": {
      "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
      "parameters": { "ticket_prefix": { "type": "String" } },
      "triggers": { "manual": { "type": "Request", "kind": "Http" } },
      "actions": { "Compose": { "type": "Compose", "inputs": "x" } }
    },
    "parameters": { "ticket_prefix": { "value": "SIR" } }
  }
}
'@

    # Bare definition: its top-level "parameters" is DECLARATIONS, never values.
    $script:BareDefinition = @'
{
  "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
  "parameters": { "ticket_prefix": { "type": "String" } },
  "triggers": { "manual": { "type": "Request", "kind": "Http" } },
  "actions": { "Compose": { "type": "Compose", "inputs": "x" } }
}
'@

    $script:SecureCodeView = @'
{
  "definition": {
    "parameters": { "api_secret": { "type": "SecureString" } },
    "triggers": { "manual": { "type": "Request", "kind": "Http" } },
    "actions": { "Compose": { "type": "Compose", "inputs": "x" } }
  },
  "parameters": { "api_secret": { "value": "hunter2" } }
}
'@

    function New-TestFile {
        param([string]$Content, [string]$Name = 'workflow.json')
        $path = Join-Path ([System.IO.Path]::GetTempPath()) "ldo-logicapps-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $file = Join-Path $path $Name
        Set-Content -LiteralPath $file -Value $Content -Encoding utf8NoBOM
        return $file
    }
}

Describe 'LogicApps module surface' {
    It 'exports the expected commands' -ForEach @(
        'ConvertFrom-LdoLogicAppExport', 'Get-LdoLogicAppParameterStatus',
        'Test-LdoLogicAppDefinition', 'Assert-LdoLogicAppDefinition',
        'Test-LdoLogicAppDeployment', 'Export-LdoLogicAppDefinition',
        'Add-LdoLogicAppParameterDefault', 'Update-LdoLogicAppReference',
        'Get-LdoLogicAppConnection', 'Get-LdoLogicAppDeployOrder',
        'Compare-LdoLogicAppDefinition'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'does not export internal helpers' -ForEach @(
        'Test-LdoLogicAppMember', 'Resolve-LdoLogicAppDocument', 'ConvertTo-LdoLogicAppTokenSafeJson'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-LdoLogicAppExport' {
    It 'detects the designer code view shape and separates values from declarations' {
        $result = ConvertFrom-LdoLogicAppExport -Json $script:CodeView
        $result.Shape | Should -Be 'CodeView'
        $result.Declarations.PSObject.Properties.Name | Should -Contain 'ticket_prefix'
        $result.ParameterValues.ticket_prefix.value | Should -Be 'SIR'
    }

    It 'detects the ARM resource shape and unwraps properties.definition' {
        $result = ConvertFrom-LdoLogicAppExport -Json $script:ArmResource
        $result.Shape | Should -Be 'ArmResource'
        $result.Name | Should -Be 'logic-arm'
        $result.ParameterValues.ticket_prefix.value | Should -Be 'SIR'
    }

    It 'detects a bare definition and reports NO parameter values' {
        # The trap this command exists to remove: a bare definition's top-level parameters block
        # is declarations. Reading it as values would silently satisfy every check.
        $result = ConvertFrom-LdoLogicAppExport -Json $script:BareDefinition
        $result.Shape | Should -Be 'BareDefinition'
        $result.ParameterValues | Should -BeNullOrEmpty
        $result.Declarations.PSObject.Properties.Name | Should -Contain 'ticket_prefix'
    }

    It 'parses a template that still carries unrendered Terraform tokens' {
        $tokenised = $script:BareDefinition -replace '"inputs": "x"', '"inputs": "${audit_table_name}"'
        $result = ConvertFrom-LdoLogicAppExport -Json $tokenised
        $result.Shape | Should -Be 'BareDefinition'
        $result.Definition.actions.Compose.inputs | Should -Be 'LDO_TOKEN'
    }

    It 'parses an UNQUOTED token in value position' {
        # Regression: a numeric or jsonencode token is written bare ("interval": ${x}), so blanking
        # it without adding quotes produces JSON that will not parse. Found against the real
        # recurrence triggers in the reference estate's templates.
        $unquoted = $script:BareDefinition -replace '"inputs": "x"', '"interval": ${recurrence_interval}'
        $result = ConvertFrom-LdoLogicAppExport -Json $unquoted
        $result.Definition.actions.Compose.interval | Should -Be 'LDO_TOKEN'
    }

    It 'parses a token embedded mid-string alongside literal text' {
        $embedded = $script:BareDefinition -replace '"inputs": "x"', '"inputs": "prefix ${table_name} suffix"'
        $result = ConvertFrom-LdoLogicAppExport -Json $embedded
        $result.Definition.actions.Compose.inputs | Should -Be 'prefix LDO_TOKEN suffix'
    }

    It 'treats $${ as the escaped literal templatefile renders it to' {
        # Built by concatenation, not -replace: in a replacement string .NET reads $$ as an escaped
        # literal $, which would quietly turn this fixture back into a real token.
        $escaped = $script:BareDefinition.Replace('"inputs": "x"', '"inputs": "$${not_a_token}"')
        $result = ConvertFrom-LdoLogicAppExport -Json $escaped
        $result.Definition.actions.Compose.inputs | Should -Be '${not_a_token}'
    }

    It 'matches a token containing braces as a single unit' {
        $nested = $script:BareDefinition.Replace('"inputs": "x"', '"inputs": ${jsonencode({ a = 1 })}')
        $result = ConvertFrom-LdoLogicAppExport -Json $nested
        $result.Definition.actions.Compose.inputs | Should -Be 'LDO_TOKEN'
    }

    It 'does not mistake a Logic App @{...} expression for a Terraform token' {
        $expression = $script:BareDefinition -replace '"inputs": "x"', '"inputs": "@{triggerBody()?[''id'']}"'
        $result = ConvertFrom-LdoLogicAppExport -Json $expression
        $result.Definition.actions.Compose.inputs | Should -Be "@{triggerBody()?['id']}"
    }

    It 'throws a clear error on content that is not JSON' {
        { ConvertFrom-LdoLogicAppExport -Json 'not json at all' } |
            Should -Throw '*is not parseable as JSON*'
    }

    It 'throws when the file does not exist' {
        { ConvertFrom-LdoLogicAppExport -Path '/no/such/workflow.json' } |
            Should -Throw '*not found*'
    }
}

Describe 'Get-LdoLogicAppParameterStatus' {
    It 'reports a wrapper-carried value as satisfied' {
        $status = Get-LdoLogicAppParameterStatus -Json $script:CodeView | Where-Object Name -EQ 'ticket_prefix'
        $status.Satisfied | Should -BeTrue
        $status.SatisfiedBy | Should -Be 'Wrapper'
    }

    It 'always treats $connections as satisfied because the deployment tool generates it' {
        $status = Get-LdoLogicAppParameterStatus -Json $script:CodeView | Where-Object Name -EQ '$connections'
        $status.Satisfied | Should -BeTrue
        $status.SatisfiedBy | Should -Be 'Generated'
    }

    It 'reports a declaration with no value anywhere as unsatisfied and names it' {
        $unsatisfied = @(Get-LdoLogicAppParameterStatus -Json $script:CodeViewMissingValue -UnsatisfiedOnly)
        $unsatisfied.Count | Should -Be 1
        $unsatisfied[0].Name | Should -Be 'ticket_prefix'
        $unsatisfied[0].Reason | Should -Match 'no defaultValue'
    }

    It 'accepts a defaultValue on the declaration as the value' {
        $withDefault = $script:CodeViewMissingValue -replace '"ticket_prefix": \{ "type": "String" \}', '"ticket_prefix": { "type": "String", "defaultValue": "SIR" }'
        $status = Get-LdoLogicAppParameterStatus -Json $withDefault | Where-Object Name -EQ 'ticket_prefix'
        $status.Satisfied | Should -BeTrue
        $status.SatisfiedBy | Should -Be 'DefaultValue'
    }

    It 'accepts a name supplied out of band by the deployment tool' {
        $status = Get-LdoLogicAppParameterStatus -Json $script:CodeViewMissingValue -SuppliedParameter 'ticket_prefix' |
            Where-Object Name -EQ 'ticket_prefix'
        $status.Satisfied | Should -BeTrue
        $status.SatisfiedBy | Should -Be 'SuppliedParameter'
    }

    It 'refuses to let a wrapper satisfy a SecureString' {
        # A secret in the wrapper would land in the template, the plan and the state, so it has to
        # arrive as an input instead.
        $status = Get-LdoLogicAppParameterStatus -Json $script:SecureCodeView | Where-Object Name -EQ 'api_secret'
        $status.InWrapper | Should -BeTrue
        $status.Satisfied | Should -BeFalse
        $status.Reason | Should -Match 'secure type'
    }

    It 'does not read a bare definition declaration as its own value' {
        $unsatisfied = @(Get-LdoLogicAppParameterStatus -Json $script:BareDefinition -UnsatisfiedOnly)
        $unsatisfied.Name | Should -Be 'ticket_prefix'
        $unsatisfied[0].Reason | Should -Match 'bare definition has no wrapper'
    }
}

Describe 'Test-LdoLogicAppDefinition' {
    It 'returns true for a complete definition' {
        Test-LdoLogicAppDefinition -Json $script:CodeView -ConnectionName 'servicenow' | Should -BeTrue
    }

    It 'returns false when a declared parameter has no value' {
        Test-LdoLogicAppDefinition -Json $script:CodeViewMissingValue -ConnectionName 'servicenow' | Should -BeFalse
    }

    It 'returns finding objects with -Detailed' {
        $findings = @(Test-LdoLogicAppDefinition -Json $script:CodeViewMissingValue -ConnectionName 'servicenow' -Detailed)
        $findings.Where({ $_.Rule -eq 'ParameterHasNoValue' }).Count | Should -Be 1
        $findings[0].Severity | Should -Be 'Error'
    }

    It 'rejects a supplied parameter the definition does not declare' {
        $findings = @(Test-LdoLogicAppDefinition -Json $script:CodeView -SuppliedParameter 'not_declared' -Detailed)
        $findings.Rule | Should -Contain 'SuppliedParameterNotDeclared'
    }

    It 'rejects connections wired to a definition with no $connections declaration' {
        $findings = @(Test-LdoLogicAppDefinition -Json $script:ArmResource -ConnectionName 'servicenow' -Detailed)
        $findings.Rule | Should -Contain 'ConnectionsNotDeclared'
    }

    It 'rejects a callback trigger that does not exist' {
        $findings = @(Test-LdoLogicAppDefinition -Json $script:CodeView -ConnectionName 'servicenow' -CallbackTriggerName 'nope' -Detailed)
        $findings.Rule | Should -Contain 'CallbackTriggerNotFound'
    }

    It 'accepts a callback trigger that does exist' {
        Test-LdoLogicAppDefinition -Json $script:CodeView -ConnectionName 'servicenow' -CallbackTriggerName 'manual' | Should -BeTrue
    }

    It 'warns rather than fails when nothing is wired to a $connections declaration' {
        $findings = @(Test-LdoLogicAppDefinition -Json $script:CodeView -Detailed)
        $warning = $findings | Where-Object Rule -EQ 'ConnectionsDeclaredButUnwired'
        $warning.Severity | Should -Be 'Warning'
        Test-LdoLogicAppDefinition -Json $script:CodeView | Should -BeTrue
    }

    It 'warns when the definition has no trigger' {
        $noTrigger = $script:BareDefinition -replace '"triggers": \{ "manual": \{ "type": "Request", "kind": "Http" \} \},', ''
        $findings = @(Test-LdoLogicAppDefinition -Json $noTrigger -SuppliedParameter 'ticket_prefix' -Detailed)
        $findings.Rule | Should -Contain 'NoTrigger'
    }

    It 'accepts pipeline input from Get-ChildItem' {
        $file = New-TestFile -Content $script:CodeView
        $result = Get-Item $file | Test-LdoLogicAppDefinition -ConnectionName 'servicenow'
        $result | Should -BeTrue
    }
}

Describe 'Assert-LdoLogicAppDefinition' {
    It 'throws naming the offending parameter' {
        { Assert-LdoLogicAppDefinition -Json $script:CodeViewMissingValue -ConnectionName 'servicenow' } |
            Should -Throw '*ticket_prefix*'
    }

    It 'does not throw for a complete definition' {
        { Assert-LdoLogicAppDefinition -Json $script:CodeView -ConnectionName 'servicenow' } | Should -Not -Throw
    }

    It 'throws on warnings when -TreatWarningsAsErrors is set' {
        { Assert-LdoLogicAppDefinition -Json $script:CodeView } | Should -Not -Throw
        { Assert-LdoLogicAppDefinition -Json $script:CodeView -TreatWarningsAsErrors } |
            Should -Throw '*ConnectionsDeclaredButUnwired*'
    }
}

Describe 'Add-LdoLogicAppParameterDefault' {
    It 'copies each wrapper value down onto its declaration' {
        $definition = Add-LdoLogicAppParameterDefault -Json $script:CodeView
        $definition.parameters.ticket_prefix.defaultValue | Should -Be 'SIR'
        $definition.parameters.retry_count.defaultValue | Should -Be 3
        $definition.parameters.category_map.defaultValue[0].value | Should -Be 'Denial of Service'
    }

    It 'makes a stripped export self-sufficient again' {
        # The end-to-end point: a definition that fails on its own, back-filled, then passes.
        $stripped = $script:CodeView -replace '"ticket_prefix": \{ "value": "SIR" \},', ''
        @(Get-LdoLogicAppParameterStatus -Json $stripped -UnsatisfiedOnly).Count | Should -Be 1

        $backfilled = Add-LdoLogicAppParameterDefault -Json $script:CodeView | ConvertTo-Json -Depth 100
        @(Get-LdoLogicAppParameterStatus -Json $backfilled -UnsatisfiedOnly).Count | Should -Be 0
    }

    It 'never writes a secure value into the definition' {
        $definition = Add-LdoLogicAppParameterDefault -Json $script:SecureCodeView
        $definition.parameters.api_secret.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
    }

    It 'leaves $connections alone for the deployment tool to generate' {
        $definition = Add-LdoLogicAppParameterDefault -Json $script:CodeView
        $definition.parameters.'$connections'.defaultValue | Should -BeNullOrEmpty
    }

    It 'throws for a bare definition, which carries no values to back-fill from' {
        { Add-LdoLogicAppParameterDefault -Json $script:BareDefinition } | Should -Throw '*bare definition*'
    }
}

Describe 'Update-LdoLogicAppReference' {
    It 'applies replacements in the order given' {
        $map = [ordered]@{
            '/subscriptions/00000000-0000-0000-0000-000000000000' = '/subscriptions/11111111-1111-1111-1111-111111111111'
            'rg-int' = 'rg-integration'
        }
        $result = Update-LdoLogicAppReference -Json $script:CodeView -Replacement $map
        $result | Should -Match '11111111-1111-1111-1111-111111111111'
        $result | Should -Match 'rg-integration'
        $result | Should -Not -Match '/subscriptions/00000000'
    }

    It 'leaves untouched text byte-identical' {
        $result = Update-LdoLogicAppReference -Json $script:CodeView -Replacement ([ordered]@{ 'nothing-matches-this' = 'x' })
        $result | Should -Be $script:CodeView
    }
}

Describe 'Get-LdoLogicAppConnection' {
    It 'extracts each connection with its resource ids' {
        $connections = @(Get-LdoLogicAppConnection -Json $script:CodeView)
        $connections.Count | Should -Be 2
        ($connections | Where-Object Api -EQ 'servicenow').ConnectionName | Should -Be 'api-servicenow'
    }

    It 'reports managed identity auth only when the authentication type says so' {
        $connections = @(Get-LdoLogicAppConnection -Json $script:CodeView)
        ($connections | Where-Object Api -EQ 'servicenow').ManagedIdentityAuth | Should -BeTrue
        ($connections | Where-Object Api -EQ 'azuresentinel').ManagedIdentityAuth | Should -BeFalse
    }

    It 'returns nothing for a bare definition, which holds no resolved value' {
        @(Get-LdoLogicAppConnection -Json $script:BareDefinition).Count | Should -Be 0
    }
}

Describe 'Get-LdoLogicAppDeployOrder' {
    BeforeAll {
        $script:OrderDir = Join-Path ([System.IO.Path]::GetTempPath()) "ldo-order-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:OrderDir -Force | Out-Null

        $leaf = '{ "definition": { "triggers": {}, "actions": {} }, "parameters": {} }'
        $dispatcher = '{ "definition": { "triggers": {}, "actions": { "Call": { "type": "Workflow", "inputs": { "host": { "workflow": { "id": "/subscriptions/x/resourceGroups/y/providers/Microsoft.Logic/workflows/handler" } } } } } }, "parameters": {} }'
        $router = '{ "definition": { "triggers": {}, "actions": { "Call": { "type": "Workflow", "inputs": { "host": { "workflow": { "id": "/subscriptions/x/resourceGroups/y/providers/Microsoft.Logic/workflows/dispatcher" } } } } } }, "parameters": {} }'

        Set-Content -LiteralPath (Join-Path $script:OrderDir 'handler.json') -Value $leaf -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:OrderDir 'dispatcher.json') -Value $dispatcher -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $script:OrderDir 'router.json') -Value $router -Encoding utf8NoBOM
    }

    It 'puts a leaf first, its caller next, and the caller of that caller last' {
        $order = Get-ChildItem "$script:OrderDir/*.json" | Get-LdoLogicAppDeployOrder
        ($order | Where-Object Workflow -EQ 'handler').Tier | Should -Be 0
        ($order | Where-Object Workflow -EQ 'dispatcher').Tier | Should -Be 1
        ($order | Where-Object Workflow -EQ 'router').Tier | Should -Be 2
    }

    It 'records what each workflow dispatches to' {
        $order = Get-ChildItem "$script:OrderDir/*.json" | Get-LdoLogicAppDeployOrder
        ($order | Where-Object Workflow -EQ 'dispatcher').DependsOn | Should -Contain 'handler'
    }

    It 'throws on a dispatch cycle, which no ordering can satisfy' {
        $cycleDir = Join-Path ([System.IO.Path]::GetTempPath()) "ldo-cycle-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $cycleDir -Force | Out-Null
        $call = '{ "definition": { "actions": { "Call": { "type": "Workflow", "inputs": { "host": { "workflow": { "id": "/providers/Microsoft.Logic/workflows/TARGET" } } } } } }, "parameters": {} }'
        Set-Content -LiteralPath (Join-Path $cycleDir 'alpha.json') -Value $call.Replace('TARGET', 'beta') -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $cycleDir 'beta.json') -Value $call.Replace('TARGET', 'alpha') -Encoding utf8NoBOM

        { Get-ChildItem "$cycleDir/*.json" | Get-LdoLogicAppDeployOrder } | Should -Throw '*cycle*'
    }

    It 'does NOT treat a workflow that merely NAMES a sibling as dispatching to it' {
        # Regression. The dependency used to be derived by searching the definition text for
        # "/workflows/<name>", so a watchdog carrying a list of the workflows it monitors read as a
        # dispatcher and was pushed into a tier that does not exist. Found by running this against a
        # real estate, where it invented a fourth tier for a workflow with no dispatch action at all.
        $watchDir = Join-Path ([System.IO.Path]::GetTempPath()) "ldo-watch-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $watchDir -Force | Out-Null

        $leafJson = '{ "definition": { "triggers": {}, "actions": {} }, "parameters": {} }'
        $watchdog = '{ "definition": { "triggers": {}, "actions": { "Probe": { "type": "Http", "inputs": { "uri": "https://management.azure.com/providers/Microsoft.Logic/workflows/handler/runs" } } } }, "parameters": {} }'
        Set-Content -LiteralPath (Join-Path $watchDir 'handler.json') -Value $leafJson -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $watchDir 'watchdog.json') -Value $watchdog -Encoding utf8NoBOM

        $order = Get-ChildItem "$watchDir/*.json" | Get-LdoLogicAppDeployOrder
        $watch = $order | Where-Object Workflow -EQ 'watchdog'
        $watch.DependsOn | Should -BeNullOrEmpty
        $watch.Tier | Should -Be 0
    }

    It 'finds a dispatch action nested inside a Switch case' {
        # The walk has to descend: a router puts its dispatches inside Switch cases, so anything
        # reading only the top-level actions sees none of them.
        $nestDir = Join-Path ([System.IO.Path]::GetTempPath()) "ldo-nest-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $nestDir -Force | Out-Null

        $nested = '{ "definition": { "actions": { "Route": { "type": "Switch", "cases": { "mde": { "actions": { "Call": { "type": "Workflow", "inputs": { "host": { "workflow": { "id": "/providers/Microsoft.Logic/workflows/handler" } } } } } } } } } }, "parameters": {} }'
        Set-Content -LiteralPath (Join-Path $nestDir 'handler.json') -Value '{ "definition": { "actions": {} }, "parameters": {} }' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $nestDir 'switcher.json') -Value $nested -Encoding utf8NoBOM

        $order = Get-ChildItem "$nestDir/*.json" | Get-LdoLogicAppDeployOrder
        ($order | Where-Object Workflow -EQ 'switcher').DependsOn | Should -Contain 'handler'
    }
}

Describe 'Get-LdoLogicAppConnectionReference' {
    BeforeAll {
        $script:RefWired = @'
{
  "definition": {
    "triggers": {
      "Incident": {
        "type": "ApiConnection",
        "inputs": { "host": { "connection": { "name": "@parameters('$connections')['azuresentinel']['connectionId']" } } }
      }
    },
    "actions": {
      "Outer": {
        "type": "Scope",
        "actions": {
          "Find": {
            "type": "ApiConnection",
            "inputs": { "host": { "connection": { "name": "@parameters('$connections')['servicenow']['connectionId']" } } }
          }
        }
      }
    },
    "parameters": { "$connections": { "type": "Object", "defaultValue": {} } }
  },
  "parameters": {
    "$connections": { "value": { "azuresentinel": { "connectionId": "/a" }, "servicenow": { "connectionId": "/b" } } }
  }
}
'@
    }

    It 'reports a connection referenced by a TRIGGER, not just by actions' {
        # The Sentinel incident trigger reaches for a connection exactly as an action does, so an
        # audit that walks only the actions misses the connection some workflows use most visibly.
        $refs = Get-LdoLogicAppConnectionReference -Json $script:RefWired
        ($refs | Where-Object Name -EQ 'azuresentinel').Actions | Should -Contain 'triggers/Incident'
    }

    It 'reports a connection referenced by a NESTED action, with its full path' {
        $refs = Get-LdoLogicAppConnectionReference -Json $script:RefWired
        ($refs | Where-Object Name -EQ 'servicenow').Actions | Should -Contain 'Outer/Find'
    }

    It 'marks a reference wired when the wrapper supplies that key' {
        # Assert the count first: without it this passes on an empty result, which is exactly how a
        # broken parameter set went unnoticed until it was checked against a real file.
        $refs = @(Get-LdoLogicAppConnectionReference -Json $script:RefWired)
        $refs.Count | Should -Be 2
        @($refs | Where-Object { $_.Wired -ne $true }).Count | Should -Be 0
    }

    It 'marks a reference UNWIRED when the wrapper supplies a different key' {
        # The failure this exists to catch: the definition says one key, the deploy wires another.
        # The workflow saves, deploys, and only fails when it runs.
        $mismatched = $script:RefWired.Replace('"servicenow": { "connectionId": "/b" }', '"service-now": { "connectionId": "/b" }')
        $refs = @(Get-LdoLogicAppConnectionReference -Json $mismatched)
        $snow = $refs | Where-Object Name -EQ 'servicenow'
        $snow | Should -Not -BeNullOrEmpty
        $snow.Wired | Should -Be $false
    }

    It 'leaves Wired as null for a bare definition, where the question is unanswerable' {
        # A bare definition carries no values block, which is not the same as carrying an empty one.
        # Reporting $false here would read as a fault that has not been established.
        $bare = (ConvertFrom-Json $script:RefWired).definition | ConvertTo-Json -Depth 100
        $refs = Get-LdoLogicAppConnectionReference -Json $bare
        $refs.Count | Should -BeGreaterThan 0
        @($refs | Where-Object { $null -ne $_.Wired }).Count | Should -Be 0
    }

    It 'counts each distinct key once per action that uses it' {
        $refs = Get-LdoLogicAppConnectionReference -Json $script:RefWired
        ($refs | Where-Object Name -EQ 'servicenow').ActionCount | Should -Be 1
    }
}

Describe 'Compare-LdoLogicAppDefinition' {
    It 'finds no differences between a file and itself' {
        $file = New-TestFile -Content $script:CodeView
        @(Compare-LdoLogicAppDefinition -ReferencePath $file -DifferencePath $file).Count | Should -Be 0
    }

    It 'compares across shapes, so a code view export diffs cleanly against an ARM GET' {
        $codeView = New-TestFile -Content '{ "definition": { "actions": { "Compose": { "inputs": "x" } } }, "parameters": {} }'
        $arm = New-TestFile -Content '{ "name": "w", "properties": { "definition": { "actions": { "Compose": { "inputs": "x" } } }, "parameters": {} } }'
        @(Compare-LdoLogicAppDefinition -ReferencePath $codeView -DifferencePath $arm).Count | Should -Be 0
    }

    It 'reports a changed value with its JSON path' {
        $left = New-TestFile -Content '{ "definition": { "actions": { "Compose": { "inputs": "before" } } } }'
        $right = New-TestFile -Content '{ "definition": { "actions": { "Compose": { "inputs": "after" } } } }'
        $diff = @(Compare-LdoLogicAppDefinition -ReferencePath $left -DifferencePath $right)
        $diff.Count | Should -Be 1
        $diff[0].Path | Should -Be 'definition.actions.Compose.inputs'
        $diff[0].Change | Should -Be 'ValueChanged'
        $diff[0].Reference | Should -Be 'before'
        $diff[0].Difference | Should -Be 'after'
    }

    It 'reports a key present on only one side' {
        $left = New-TestFile -Content '{ "definition": { "actions": { "A": { "inputs": "x" }, "B": { "inputs": "y" } } } }'
        $right = New-TestFile -Content '{ "definition": { "actions": { "A": { "inputs": "x" } } } }'
        $diff = @(Compare-LdoLogicAppDefinition -ReferencePath $left -DifferencePath $right)
        $diff.Change | Should -Contain 'MissingInDifference'
    }

    It 'walks into arrays by index' {
        $left = New-TestFile -Content '{ "definition": { "parameters": { "m": { "defaultValue": [ "a", "b" ] } } } }'
        $right = New-TestFile -Content '{ "definition": { "parameters": { "m": { "defaultValue": [ "a", "z" ] } } } }'
        $diff = @(Compare-LdoLogicAppDefinition -ReferencePath $left -DifferencePath $right)
        $diff.Count | Should -Be 1
        $diff[0].Path | Should -Be 'definition.parameters.m.defaultValue[1]'
    }
}

Describe 'Test-LdoLogicAppDeployment' {
    It 'posts the definition to the validate endpoint and reports the provider verdict' {
        InModuleScope LibreDevOpsHelpers.LogicApps {
            Mock Assert-LdoCommand {}
            Mock Assert-LdoLastExitCode {}

            # Shadow the CLI inside the module scope so the test never needs az installed.
            function az {
                $script:capturedArgs = $args
                if ($args -contains 'account') { $global:LASTEXITCODE = 0; return '00000000-0000-0000-0000-000000000000' }
                if ($args -contains 'group') { $global:LASTEXITCODE = 0; return 'uksouth' }
                $global:LASTEXITCODE = 0
                return ''
            }

            $json = '{ "definition": { "parameters": {}, "triggers": {}, "actions": {} }, "parameters": {} }'
            $result = Test-LdoLogicAppDeployment -Json $json -ResourceGroupName 'rg-test' -Name 'logic-probe'

            $result | Should -BeTrue
            ($script:capturedArgs -join ' ') | Should -Match 'Microsoft\.Logic/locations/uksouth/workflows/logic-probe/validate'
            ($script:capturedArgs -join ' ') | Should -Match 'api-version=2019-05-01'
        }
    }

    It 'reports false when the provider rejects the definition' {
        InModuleScope LibreDevOpsHelpers.LogicApps {
            Mock Assert-LdoCommand {}
            Mock Assert-LdoLastExitCode {}

            function az {
                if ($args -contains 'account') { $global:LASTEXITCODE = 0; return '00000000-0000-0000-0000-000000000000' }
                if ($args -contains 'group') { $global:LASTEXITCODE = 0; return 'uksouth' }
                $global:LASTEXITCODE = 1
                return '{"error":{"code":"InvalidTemplate","message":"the value for the workflow parameter is not provided"}}'
            }

            $json = '{ "definition": { "parameters": {}, "triggers": {}, "actions": {} }, "parameters": {} }'
            $detail = Test-LdoLogicAppDeployment -Json $json -ResourceGroupName 'rg' -Location 'uksouth' -Name 'w' -Detailed

            $detail.Valid | Should -BeFalse
            $detail.RawMessage | Should -Match 'InvalidTemplate'
        }
    }
}

Describe 'Export-LdoLogicAppDefinition' {
    It 'writes one code view file per workflow' {
        InModuleScope LibreDevOpsHelpers.LogicApps {
            Mock Assert-LdoCommand {}
            Mock Assert-LdoLastExitCode {}

            function az {
                $global:LASTEXITCODE = 0
                if ($args -contains 'account') { return '00000000-0000-0000-0000-000000000000' }
                if ($args -contains 'list') {
                    return '[{"name":"logic-one","id":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Logic/workflows/logic-one"}]'
                }
                return '{"name":"logic-one","properties":{"definition":{"actions":{"Compose":{"inputs":"x"}}},"parameters":{"p":{"value":"v"}}}}'
            }

            $outDir = Join-Path ([System.IO.Path]::GetTempPath()) "ldo-export-$([guid]::NewGuid())"
            $exported = @(Export-LdoLogicAppDefinition -ResourceGroupName 'rg' -OutputPath $outDir -PassThru)

            $exported.Count | Should -Be 1
            Test-Path $exported[0].Path | Should -BeTrue

            # The written file must come back through the unwrapper as a code view export.
            $roundTrip = ConvertFrom-LdoLogicAppExport -Path $exported[0].Path
            $roundTrip.Shape | Should -Be 'CodeView'
            $roundTrip.ParameterValues.p.value | Should -Be 'v'
        }
    }
}
