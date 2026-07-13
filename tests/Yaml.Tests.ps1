BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1') -Force
    $script:yamlReady = [bool](Get-Command yq -ErrorAction SilentlyContinue) -or
    [bool](Get-Module -ListAvailable powershell-yaml)
}

BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Yaml module surface' {
    It 'exports the expected commands' -ForEach @('ConvertTo-LdoYaml', 'ConvertFrom-LdoYaml') {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertTo-LdoYaml' {

    It 'emits deterministic, ordered, analyst readable YAML' {
        $text = ConvertTo-LdoYaml -InputObject ([ordered]@{
                display_name = 'Simple rule'
                status       = 'enabled'
                frequency    = 'PT1H'
                query        = "EmailEvents`n| where Subject == `"x`"`n| project Timestamp, ReportId"
                alert        = [ordered]@{
                    severity = 'low'
                    mitre    = @([ordered]@{ tactic = 'Execution'; techniques = @('T1204') })
                }
            })

        $text | Should -Match '(?m)^display_name: Simple rule$'
        $text | Should -Match '(?m)^query: \|$'
        $text | Should -Match '(?m)^  \| project Timestamp, ReportId$'
        $text | Should -Match '(?m)^    - tactic: Execution$'
        # Key order is preserved: display_name before status before query.
        $text.IndexOf('display_name:') | Should -BeLessThan $text.IndexOf('status:')
        $text.IndexOf('status:') | Should -BeLessThan $text.IndexOf('query:')
    }

    It 'quotes only what YAML would otherwise retype or misparse' {
        $text = ConvertTo-LdoYaml -InputObject ([ordered]@{
                plain     = 'Client IP Address'
                boolish   = 'true'
                numberish = '0123'
                colon     = 'key: value'
                hash      = 'value # comment'
                empty     = ''
                real_bool = $true
                real_null = $null
                number    = 42
            })

        $text | Should -Match '(?m)^plain: Client IP Address$'
        $text | Should -Match '(?m)^boolish: "true"$'
        $text | Should -Match '(?m)^numberish: "0123"$'
        $text | Should -Match '(?m)^colon: "key: value"$'
        $text | Should -Match '(?m)^hash: "value # comment"$'
        $text | Should -Match '(?m)^empty: ""$'
        $text | Should -Match '(?m)^real_bool: true$'
        $text | Should -Match '(?m)^real_null: null$'
        $text | Should -Match '(?m)^number: 42$'
    }

    It 'folds maps in sequences onto the dash' {
        $text = ConvertTo-LdoYaml -InputObject ([ordered]@{
                accounts = @(
                    [ordered]@{ upn_column = 'AccountUpn'; sid_column = 'AccountSid' }
                )
            })
        $text | Should -Match '(?m)^  - upn_column: AccountUpn$'
        $text | Should -Match '(?m)^    sid_column: AccountSid$'
    }

    It 'renders empty collections inline' {
        $text = ConvertTo-LdoYaml -InputObject ([ordered]@{ a = @(); b = [ordered]@{} })
        $text | Should -Match '(?m)^a: \[\]$'
        $text | Should -Match '(?m)^b: \{\}$'
    }

    It 'round trips through ConvertFrom-LdoYaml' -Skip:(-not $yamlReady) {
        $original = [ordered]@{
            display_name = 'Round trip'
            enabled_ish  = 'false'
            count        = 3
            query        = "A`n| where X == 1`n| project Y"
            nested       = [ordered]@{ list = @('one', 'two'); flag = $true }
            mappings     = @([ordered]@{ name_column = 'N'; note = 'a: b' })
        }
        $parsed = ConvertFrom-LdoYaml -Content (ConvertTo-LdoYaml -InputObject $original)

        "$($parsed.display_name)" | Should -Be 'Round trip'
        "$($parsed.enabled_ish)" | Should -Be 'false'
        [int]$parsed.count | Should -Be 3
        "$($parsed.query)" | Should -Match '\| project Y'
        @($parsed.nested.list).Count | Should -Be 2
        "$($parsed.mappings[0].note)" | Should -Be 'a: b'
    }
}
