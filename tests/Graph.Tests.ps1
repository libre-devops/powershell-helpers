BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force

    # Az.Accounts is not installed in CI, so provide a stub for Get-AzAccessToken that
    # the token tests can Mock. Only defined when the real command is absent.
    if (-not (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue)) {
        function global:Get-AzAccessToken { param($ResourceUrl) }
    }

    # Builds an error record that looks like a failed Invoke-RestMethod call with the
    # given HTTP status, so retry behaviour can be tested without real network calls.
    function New-HttpError {
        param([int]$Status)
        $response = [pscustomobject]@{ StatusCode = $Status }
        $ex = [System.Exception]::new("http $Status")
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $response
        return [System.Management.Automation.ErrorRecord]::new($ex, 'http', 'NotSpecified', $null)
    }
}

Describe 'Invoke-LdoWithRetry' {

    It 'returns the script block result on success' {
        Invoke-LdoWithRetry -ScriptBlock { 42 } -OperationName 'ok' | Should -Be 42
    }

    It 'does not retry a non-retryable status (403)' {
        $script:calls = 0
        { Invoke-LdoWithRetry -OperationName 'forbidden' -MaxRetries 4 -ScriptBlock {
                $script:calls++
                throw (New-HttpError -Status 403)
            } } | Should -Throw
        $script:calls | Should -Be 1
    }

    It 'retries a transient status (503) and then succeeds' {
        $script:n = 0
        $result = Invoke-LdoWithRetry -OperationName 'busy' -MaxRetries 5 -InitialDelaySeconds 0 -MaxDelaySeconds 0 -ScriptBlock {
            $script:n++
            if ($script:n -lt 3) { throw (New-HttpError -Status 503) }
            'done'
        }
        $result | Should -Be 'done'
        $script:n | Should -Be 3
    }

    It 'invokes the OnRetry callback before retrying' {
        $script:retries = 0
        $script:attempts = 0
        Invoke-LdoWithRetry -OperationName 'cb' -MaxRetries 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0 `
            -OnRetry { $script:retries++ } -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 2) { throw (New-HttpError -Status 500) }
            'ok'
        } | Should -Be 'ok'
        $script:retries | Should -Be 1
    }

    It 'gives up after MaxRetries on persistent transient errors' {
        $script:tries = 0
        { Invoke-LdoWithRetry -OperationName 'always503' -MaxRetries 3 -InitialDelaySeconds 0 -MaxDelaySeconds 0 -ScriptBlock {
                $script:tries++
                throw (New-HttpError -Status 503)
            } } | Should -Throw
        $script:tries | Should -Be 3
    }
}

Describe 'Get-LdoGraphErrorDetail' {

    It 'parses a Graph error body into code and message' {
        $body = '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}'
        $ex = [System.Exception]::new('generic')
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 403 })
        $record = [System.Management.Automation.ErrorRecord]::new($ex, 'id', 'NotSpecified', $null)
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($body)

        $detail = Get-LdoGraphErrorDetail -ErrorRecord $record
        $detail | Should -Match 'HTTP 403'
        $detail | Should -Match 'Authorization_RequestDenied'
        $detail | Should -Match 'Insufficient privileges'
    }

    It 'reports no HTTP response for a transport error' {
        $record = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('dns fail'), 'id', 'NotSpecified', $null)
        Get-LdoGraphErrorDetail -ErrorRecord $record | Should -Match 'No HTTP response'
    }
}

Describe 'Get-LdoGraphToken and Clear-LdoGraphTokenCache' {

    It 'caches the token and only calls Get-AzAccessToken once' {
        InModuleScope LibreDevOpsHelpers.Graph {
            Mock Get-AzAccessToken {
                [pscustomobject]@{ Token = 'tok-123'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) }
            }
            Clear-LdoGraphTokenCache
            Get-LdoGraphToken -Resource 'https://example.test' | Should -Be 'tok-123'
            Get-LdoGraphToken -Resource 'https://example.test' | Should -Be 'tok-123'
            Should -Invoke Get-AzAccessToken -Times 1 -Exactly
        }
    }

    It 'converts a SecureString token to plaintext' {
        InModuleScope LibreDevOpsHelpers.Graph {
            Mock Get-AzAccessToken {
                $secure = ConvertTo-SecureString 'secret-tok' -AsPlainText -Force
                [pscustomobject]@{ Token = $secure; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) }
            }
            Clear-LdoGraphTokenCache
            Get-LdoGraphToken -Resource 'https://secure.test' | Should -Be 'secret-tok'
        }
    }

    It 're-acquires after the cache is cleared' {
        InModuleScope LibreDevOpsHelpers.Graph {
            Mock Get-AzAccessToken {
                [pscustomobject]@{ Token = 'tok'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) }
            }
            Clear-LdoGraphTokenCache
            Get-LdoGraphToken -Resource 'https://x.test' | Out-Null
            Clear-LdoGraphTokenCache
            Get-LdoGraphToken -Resource 'https://x.test' | Out-Null
            Should -Invoke Get-AzAccessToken -Times 2 -Exactly
        }
    }

    It 'does not reuse a token across an Az context switch' {
        InModuleScope LibreDevOpsHelpers.Graph {
            # Same resource, different tenant: the cache must not hand back the first tenant's token.
            $script:ctxTenant = 'tenant-a'
            Mock Get-AzContext {
                [pscustomobject]@{
                    Tenant  = [pscustomobject]@{ Id = $script:ctxTenant }
                    Account = [pscustomobject]@{ Id = 'acct' }
                }
            }
            Mock Get-AzAccessToken {
                [pscustomobject]@{ Token = "tok-$script:ctxTenant"; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) }
            }
            Clear-LdoGraphTokenCache
            Get-LdoGraphToken -Resource 'https://ctx.test' | Should -Be 'tok-tenant-a'
            $script:ctxTenant = 'tenant-b'
            Get-LdoGraphToken -Resource 'https://ctx.test' | Should -Be 'tok-tenant-b'
            Should -Invoke Get-AzAccessToken -Times 2 -Exactly
        }
    }
}
