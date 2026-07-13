BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1') -Force

    # The parser tests need the real Kusto.Language assembly (one small nupkg download, cached
    # under ~/.ldo). The YAML tests need yq or powershell-yaml. Offline machines skip those tests
    # instead of failing them.
    $script:kustoReady = $true
    try { Install-LdoKustoLanguage | Out-Null } catch { $script:kustoReady = $false }

    $script:yamlReady = [bool](Get-Command yq -ErrorAction SilentlyContinue) -or
    [bool](Get-Module -ListAvailable powershell-yaml)
}

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Kql module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoKustoLanguage', 'Test-LdoKqlSyntax', 'Test-LdoDefenderHuntingQuery',
        'ConvertFrom-LdoYaml', 'Test-LdoDetectionRuleFile', 'Invoke-LdoDetectionGate'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-LdoKqlSyntax' -Skip:(-not $kustoReady) {

    It 'passes a valid query' {
        Test-LdoKqlSyntax -Query 'DeviceProcessEvents | where FileName == "x.exe" | project Timestamp, ReportId' |
            Should -BeTrue
    }

    It 'fails a query with a syntax error' {
        Test-LdoKqlSyntax -Query 'DeviceProcessEvents | where | project Timestamp' |
            Should -BeFalse
    }

    It 'emits labelled error diagnostics with -PassThru' {
        $diags = Test-LdoKqlSyntax -Query 'EmailEvents | summarize by' -SourceLabel 'rules/broken.yaml' -PassThru
        @($diags | Where-Object Severity -eq 'Error').Count | Should -BeGreaterThan 0
        @($diags)[0].Source | Should -Be 'rules/broken.yaml'
    }

    It 'parses queries from files and labels them with the path' {
        $file = Join-Path $TestDrive 'good.kql'
        Set-Content -Path $file -Value 'IdentityLogonEvents | project Timestamp, ReportId, AccountUpn'
        Test-LdoKqlSyntax -Path $file | Should -BeTrue
    }
}

Describe 'Test-LdoDefenderHuntingQuery' {

    It 'returns true and sends the query verbatim when the hunting call succeeds' {
        InModuleScope LibreDevOpsHelpers.Kql {
            Mock Invoke-LdoDefenderHuntingQuery { @() }
            Test-LdoDefenderHuntingQuery -Query 'EmailEvents | take 5' | Should -BeTrue
            Should -Invoke Invoke-LdoDefenderHuntingQuery -Times 1 -Exactly -ParameterFilter {
                $Query -eq 'EmailEvents | take 5' -and $Timespan -eq 'PT1H'
            }
        }
    }

    It 'appends take 1 only when -AppendTake is set' {
        InModuleScope LibreDevOpsHelpers.Kql {
            Mock Invoke-LdoDefenderHuntingQuery { @() }
            Test-LdoDefenderHuntingQuery -Query 'EmailEvents' -AppendTake | Should -BeTrue
            Should -Invoke Invoke-LdoDefenderHuntingQuery -Times 1 -Exactly -ParameterFilter {
                $Query.EndsWith('| take 1')
            }
        }
    }

    It 'returns false when the hunting call throws' {
        InModuleScope LibreDevOpsHelpers.Kql {
            Mock Invoke-LdoDefenderHuntingQuery { throw 'BadRequest: query is invalid' }
            Test-LdoDefenderHuntingQuery -Query 'NoSuchTable | take 1' | Should -BeFalse
        }
    }
}

Describe 'ConvertFrom-LdoYaml' -Skip:(-not $yamlReady) {

    It 'parses YAML content' {
        $obj = ConvertFrom-LdoYaml -Content "display_name: test`nfrequency: PT1H"
        "$($obj.display_name)" | Should -Be 'test'
        "$($obj.frequency)" | Should -Be 'PT1H'
    }

    It 'parses a YAML file' {
        $file = Join-Path $TestDrive 'rule.yaml'
        Set-Content -Path $file -Value "query: EmailEvents`nalert:`n  severity: low"
        $obj = ConvertFrom-LdoYaml -Path $file
        "$($obj.query)" | Should -Be 'EmailEvents'
    }

    It 'throws on a missing file' {
        { ConvertFrom-LdoYaml -Path (Join-Path $TestDrive 'nope.yaml') } | Should -Throw '*not found*'
    }
}

Describe 'ConvertTo-LdoCanonicalDetectionRule' {

    It 'normalises sloppy analyst values to the canonical spellings' {
        $rule = '{"status":"Enabled","frequency":"pt1h","alert":{"severity":"Medium","mitre":[{"tactic":"credential access","techniques":["t1110"]},{"tactic":"DefenceEvasion","techniques":[{"technique":"t1562","sub_techniques":["t1562.008"]}]}]}}' |
            ConvertFrom-Json
        $out = ConvertTo-LdoCanonicalDetectionRule -Rule $rule
        $out.status | Should -Be 'enabled'
        $out.frequency | Should -Be 'PT1H'
        $out.alert.severity | Should -Be 'medium'
        $out.alert.mitre[0].tactic | Should -Be 'CredentialAccess'
        $out.alert.mitre[0].techniques[0] | Should -Be 'T1110'
        $out.alert.mitre[1].tactic | Should -Be 'DefenseEvasion'
        $out.alert.mitre[1].techniques[0].technique | Should -Be 'T1562'
        $out.alert.mitre[1].techniques[0].sub_techniques[0] | Should -Be 'T1562.008'
    }

    It 'leaves unknown values untouched for the schema to reject' {
        $rule = '{"status":"Enabled","alert":{"mitre":[{"tactic":"NotATactic"}]}}' | ConvertFrom-Json
        (ConvertTo-LdoCanonicalDetectionRule -Rule $rule).alert.mitre[0].tactic | Should -Be 'NotATactic'
    }
}

Describe 'Test-LdoDetectionRuleFile' -Skip:(-not ($yamlReady -and $kustoReady)) {

    BeforeEach {
        $script:good = Join-Path $TestDrive 'good-rule.yaml'
        Set-Content -Path $script:good -Value @'
display_name: Fixture rule
frequency: PT1H
query: |
  EmailEvents
  | project Timestamp, ReportId, RecipientEmailAddress
alert:
  severity: low
'@
    }

    It 'passes a well formed rule offline' {
        Test-LdoDetectionRuleFile -Path $script:good | Should -BeTrue
    }

    It 'fails a rule with no query attribute' {
        $file = Join-Path $TestDrive 'no-query.yaml'
        Set-Content -Path $file -Value "display_name: nope`nfrequency: PT1H"
        Test-LdoDetectionRuleFile -Path $file | Should -BeFalse
    }

    It 'fails a rule whose query has a syntax error' {
        $file = Join-Path $TestDrive 'bad-kql.yaml'
        Set-Content -Path $file -Value "display_name: bad`nquery: 'EmailEvents | where |'"
        Test-LdoDetectionRuleFile -Path $file | Should -BeFalse
    }

    It 'runs the remote validation only with -Remote' {
        InModuleScope LibreDevOpsHelpers.Kql -Parameters @{ good = $script:good } {
            param($good)
            Mock Test-LdoDefenderHuntingQuery { $true }
            Test-LdoDetectionRuleFile -Path $good | Should -BeTrue
            Should -Invoke Test-LdoDefenderHuntingQuery -Times 0 -Exactly
            Test-LdoDetectionRuleFile -Path $good -Remote | Should -BeTrue
            Should -Invoke Test-LdoDefenderHuntingQuery -Times 1 -Exactly
        }
    }

    It 'throws when the schema file is missing' {
        { Test-LdoDetectionRuleFile -Path $script:good -SchemaPath (Join-Path $TestDrive 'nope.json') } |
            Should -Throw '*schema file not found*'
    }
}

Describe 'Invoke-LdoDetectionGate' -Skip:(-not ($yamlReady -and $kustoReady)) {

    BeforeEach {
        Clear-LdoFinding
        $script:dir = Join-Path $TestDrive ("gate-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Join-Path $script:dir 'identity') | Out-Null
        Set-Content -Path (Join-Path $script:dir 'identity' 'good.yaml') -Value @'
display_name: Good rule
query: |
  IdentityLogonEvents
  | project Timestamp, ReportId, AccountUpn
alert:
  severity: low
'@
    }

    It 'passes a directory of clean rules' {
        { Invoke-LdoDetectionGate -Path $script:dir } | Should -Not -Throw
    }

    It 'throws naming the failure count when a rule is broken' {
        Set-Content -Path (Join-Path $script:dir 'identity' 'bad.yaml') -Value "display_name: bad`nquery: 'x | where |'"
        { Invoke-LdoDetectionGate -Path $script:dir } | Should -Throw '*1 of 2*'
    }

    It 'continues on failure with -SoftFail' {
        Set-Content -Path (Join-Path $script:dir 'identity' 'bad.yaml') -Value "display_name: bad`nquery: 'x | where |'"
        { Invoke-LdoDetectionGate -Path $script:dir -SoftFail } | Should -Not -Throw
    }

    It 'warns and returns when the directory has no YAML files' {
        $empty = Join-Path $TestDrive ("empty-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $empty | Out-Null
        { Invoke-LdoDetectionGate -Path $empty } | Should -Not -Throw
    }
}

Describe 'Get-LdoCustomDetectionRule' {

    It 'follows nextLink paging and filters by display name' {
        InModuleScope LibreDevOpsHelpers.Kql {
            $script:page = 0
            Mock Invoke-LdoGraphRequest {
                $script:page++
                if ($script:page -eq 1) {
                    ('{"value":[{"id":"1","displayName":"A"}],"@odata.nextLink":"https://graph.microsoft.com/beta/next"}' | ConvertFrom-Json)
                }
                else {
                    ('{"value":[{"id":"2","displayName":"B"}]}' | ConvertFrom-Json)
                }
            }
            $all = Get-LdoCustomDetectionRule
            @($all).Count | Should -Be 2
            Should -Invoke Invoke-LdoGraphRequest -Times 2 -Exactly

            $script:page = 0
            @(Get-LdoCustomDetectionRule -DisplayName 'B').id | Should -Be '2'
        }
    }
}

Describe 'Export-LdoCustomDetectionRule' -Skip:(-not $yamlReady) {

    BeforeEach {
        $script:fixture = @'
{"value":[
  {"id":"111","displayName":"New Shape Rule","description":"d","status":"enabled",
   "schedule":{"frequency":"PT1H"},
   "queryCondition":{"queryText":"EmailEvents\n| project Timestamp, ReportId, RecipientEmailAddress"},
   "detectionAction":{
     "alertTemplate":{"title":"t","severity":"medium",
       "tactics":[{"tactic":"CredentialAccess","techniques":[{"technique":"T1110","subTechniques":["T1110.003"]}]}],
       "customDetails":{"Count":"FailedCount"},
       "entityMappings":{"accounts":[{"upnColumn":"AccountUpn","aadUserIdColumn":"AccountObjectId"}]}},
     "automatedActions":{"isolateDevices":[{"deviceIdColumn":"DeviceId","isolationType":"full"}]}}},
  {"id":"222","displayName":"Legacy Rule!","isEnabled":false,
   "schedule":{"period":"12H"},
   "queryCondition":{"queryText":"DeviceEvents | project Timestamp, ReportId, DeviceId"},
   "detectionAction":{
     "alertTemplate":{"severity":"low","category":"Malware","mitreTechniques":["T1059"],
       "impactedAssets":[{"@odata.type":"#microsoft.graph.security.impactedDeviceAsset","identifier":"deviceId"}]},
     "organizationalScope":{"scopeType":"deviceGroup","scopeNames":["Workstations"]}}}
]}
'@
    }

    It 'exports rules into the analyst layout with ids, snake case and TODO notes' {
        $out = Join-Path $TestDrive ("exp-" + [guid]::NewGuid())
        InModuleScope LibreDevOpsHelpers.Kql -Parameters @{ out = $out; fixture = $script:fixture } {
            param($out, $fixture)
            Mock Invoke-LdoGraphRequest { $fixture | ConvertFrom-Json }
            $files = Export-LdoCustomDetectionRule -OutDir $out
            @($files).Count | Should -Be 2
        }

        $newShape = Join-Path $out 'credential-access' 'new-shape-rule.yaml'
        $legacy = Join-Path $out 'uncategorised' 'legacy-rule.yaml'
        Test-Path $newShape | Should -BeTrue
        Test-Path $legacy | Should -BeTrue

        $parsed = ConvertFrom-LdoYaml -Path $newShape
        "$($parsed.id)" | Should -Be '111'
        "$($parsed.frequency)" | Should -Be 'PT1H'
        "$($parsed.alert.mitre[0].techniques[0].sub_techniques[0])" | Should -Be 'T1110.003'
        "$($parsed.alert.entity_mappings.accounts[0].aad_user_id_column)" | Should -Be 'AccountObjectId'
        "$($parsed.automated_actions.isolate_devices[0].isolation_type)" | Should -Be 'full'
        (Get-Content -Raw $newShape) | Should -Match 'allow_automated_actions = true'

        $legacyParsed = ConvertFrom-LdoYaml -Path $legacy
        "$($legacyParsed.status)" | Should -Be 'disabled'
        "$($legacyParsed.frequency)" | Should -Be 'PT12H'
        @($legacyParsed.device_groups)[0] | Should -Be 'Workstations'
        $legacyRaw = Get-Content -Raw $legacy
        $legacyRaw | Should -Match "TODO\(export\): legacy category 'Malware'"
        $legacyRaw | Should -Match 'TODO\(export\): legacy impactedAssets'
    }

    It 'exports the same spec as JSON when asked' {
        $out = Join-Path $TestDrive ("expj-" + [guid]::NewGuid())
        InModuleScope LibreDevOpsHelpers.Kql -Parameters @{ out = $out; fixture = $script:fixture } {
            param($out, $fixture)
            Mock Invoke-LdoGraphRequest { $fixture | ConvertFrom-Json }
            Export-LdoCustomDetectionRule -OutDir $out -Format Json | Out-Null
        }
        $json = Get-Content -Raw (Join-Path $out 'credential-access' 'new-shape-rule.json') | ConvertFrom-Json
        "$($json.id)" | Should -Be '111'
        "$($json.alert.entity_mappings.accounts[0].upn_column)" | Should -Be 'AccountUpn'
    }
}
