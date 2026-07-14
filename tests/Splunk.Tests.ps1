BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Splunk module surface' {
    It 'exports the expected commands' -ForEach @(
        'Send-LdoSplunkHecEvent', 'Invoke-LdoSplunkSearch', 'Test-LdoSplunkConnection'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Send-LdoSplunkHecEvent' {

    It 'wraps events in the HEC envelope and targets /services/collector/event' {
        InModuleScope LibreDevOpsHelpers.Splunk {
            Mock Invoke-LdoWithRetry { & $ScriptBlock }
            Mock Invoke-RestMethod {
                $script:captured = @{ Uri = $Uri; Headers = $Headers; Body = $Body }
                @{ text = 'Success'; code = 0 }
            }
            Send-LdoSplunkHecEvent -Uri 'https://splunk:8088/' -Token 'tok' -Event @{ action = 'login' } -Sourcetype '_json' -Index 'main' | Out-Null

            $script:captured.Uri | Should -Be 'https://splunk:8088/services/collector/event'
            $script:captured.Headers.Authorization | Should -Be 'Splunk tok'
            $body = $script:captured.Body | ConvertFrom-Json
            $body.event.action | Should -Be 'login'
            $body.sourcetype | Should -Be '_json'
            $body.index | Should -Be 'main'
        }
    }

    It 'sends multiple piped events as newline-delimited envelopes' {
        InModuleScope LibreDevOpsHelpers.Splunk {
            Mock Invoke-LdoWithRetry { & $ScriptBlock }
            Mock Invoke-RestMethod { $script:body = $Body; @{ code = 0 } }
            @('a', 'b', 'c') | Send-LdoSplunkHecEvent -Uri 'https://splunk:8088' -Token 't' | Out-Null
            ($script:body -split "`n").Count | Should -Be 3
        }
    }

    It 'rejects an empty event set' {
        # An empty array fails at parameter binding before the body is built; either way, nothing
        # is sent.
        { Send-LdoSplunkHecEvent -Uri 'https://x' -Token 't' -Event @() } | Should -Throw
    }
}

Describe 'Invoke-LdoSplunkSearch' {

    It 'prepends search, sets oneshot json, and returns the results array' {
        InModuleScope LibreDevOpsHelpers.Splunk {
            Mock Invoke-LdoWithRetry { & $ScriptBlock }
            # Invoke-RestMethod parses JSON to PSCustomObjects, so mirror that shape (a hashtable
            # would not expose .results via PSObject.Properties the way the real response does).
            Mock Invoke-RestMethod {
                $script:form = $Body
                [pscustomobject]@{ results = @([pscustomobject]@{ _raw = 'one' }, [pscustomobject]@{ _raw = 'two' }) }
            }
            $rows = Invoke-LdoSplunkSearch -Uri 'https://splunk:8089' -Token 't' -Search 'index=main error' -EarliestTime '-1h'
            @($rows).Count | Should -Be 2
            $script:form.search | Should -Be 'search index=main error'
            $script:form.exec_mode | Should -Be 'oneshot'
            $script:form.output_mode | Should -Be 'json'
            $script:form.earliest_time | Should -Be '-1h'
        }
    }

    It 'does not double-prepend search for a piped or generating query' {
        InModuleScope LibreDevOpsHelpers.Splunk {
            Mock Invoke-LdoWithRetry { & $ScriptBlock }
            Mock Invoke-RestMethod { $script:form = $Body; @{ results = @() } }
            Invoke-LdoSplunkSearch -Uri 'https://splunk:8089' -Token 't' -Search '| tstats count' | Out-Null
            $script:form.search | Should -Be '| tstats count'
        }
    }

    It 'returns an empty array on a shapeless response' {
        InModuleScope LibreDevOpsHelpers.Splunk {
            Mock Invoke-LdoWithRetry { & $ScriptBlock }
            Mock Invoke-RestMethod { [pscustomobject]@{ messages = @() } }
            @(Invoke-LdoSplunkSearch -Uri 'https://splunk:8089' -Token 't' -Search 'index=main').Count | Should -Be 0
        }
    }
}

Describe 'Test-LdoSplunkConnection' {

    It 'returns true on a successful server info call' {
        InModuleScope LibreDevOpsHelpers.Splunk {
            Mock Invoke-RestMethod { @{ generator = @{ version = '9.0' } } }
            Test-LdoSplunkConnection -Uri 'https://splunk:8089' -Token 't' | Should -BeTrue
        }
    }

    It 'returns false when the call throws' {
        InModuleScope LibreDevOpsHelpers.Splunk {
            Mock Invoke-RestMethod { throw '401 Unauthorized' }
            Test-LdoSplunkConnection -Uri 'https://splunk:8089' -Token 't' | Should -BeFalse
        }
    }
}
