BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Write-LdoLog (JSON, default format)' {

    It 'is exported from the module' {
        Get-Command Write-LdoLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'emits a single parseable JSON object with the expected fields' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.level | Should -Be 'WARN'
        $obj.invocation | Should -Be 'test'
        $obj.message | Should -Be 'careful'
    }

    It 'stamps a UTC ISO-8601 timestamp' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        # Inspect the raw JSON: ConvertFrom-Json would coerce the string to a DateTime
        # and drop the literal UTC marker we want to assert on.
        $warning.Message | Should -Match '"timestamp":"\d{4}-\d{2}-\d{2}T[\d:.]+Z"'
    }

    It 'merges -Data properties into the record' {
        $warning = Write-LdoLog -Level WARN -Message 'm' -InvocationName 'test' -Data @{ resourceGroup = 'rg-prod' } 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.resourceGroup | Should -Be 'rg-prod'
    }

    It 'routes ERROR to the error stream without terminating' {
        $err = Write-LdoLog -Level ERROR -Message 'broke' -InvocationName 'test' 2>&1
        ($err.ToString() | ConvertFrom-Json).message | Should -Be 'broke'
    }

    It 'derives the invocation name from the caller when not supplied' {
        function Invoke-Caller { Write-LdoLog -Level WARN -Message 'auto' 3>&1 }
        $warning = Invoke-Caller
        ($warning.Message | ConvertFrom-Json).invocation | Should -Be 'Invoke-Caller'
    }

    It 'routes INFO to the information stream, not the success stream' {
        $output = Write-LdoLog -Level INFO -Message 'hello' -InvocationName 'test' 6>$null
        $output | Should -BeNullOrEmpty
    }

    It 'writes INFO as JSON on the information stream' {
        $info = Write-LdoLog -Level INFO -Message 'hello' -InvocationName 'test' 6>&1
        ($info.MessageData | ConvertFrom-Json).message | Should -Be 'hello'
    }

    It 'emits compact single-line JSON by default' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        $warning.Message | Should -Not -Match "`n"
    }
}

Describe 'Write-LdoLog (JsonIndented format)' {

    It 'pretty-prints across multiple lines but stays valid JSON' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' -Format JsonIndented 3>&1
        $warning.Message | Should -Match "`n"
        ($warning.Message | ConvertFrom-Json).message | Should -Be 'careful'
    }
}

Describe 'Write-LdoLog (Text format)' {

    It 'renders a human-readable prefixed line with -Format Text' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'MyCaller' -Format Text 3>&1
        $warning | Should -Match 'careful'
        $warning | Should -Match '\[WARN\]'
        $warning | Should -Match '\[MyCaller\]'
    }

    It 'honours Set-LdoLogFormat as the default' {
        Set-LdoLogFormat -Format Text
        try {
            Get-LdoLogFormat | Should -Be 'Text'
            $warning = Write-LdoLog -Level WARN -Message 'plain' -InvocationName 'test' 3>&1
            $warning | Should -Match '\[WARN\]'
        } finally {
            Set-LdoLogFormat -Format Json
        }
    }
}

Describe 'Set-LdoLogLevel' {

    AfterEach {
        Set-LdoLogLevel -Level DEBUG
    }

    It 'suppresses messages below the configured level' {
        Set-LdoLogLevel -Level ERROR
        $warning = Write-LdoLog -Level WARN -Message 'hidden' -InvocationName 'test' 3>&1
        $warning | Should -BeNullOrEmpty
    }

    It 'still emits messages at or above the configured level' {
        Set-LdoLogLevel -Level WARN
        $warning = Write-LdoLog -Level WARN -Message 'shown' -InvocationName 'test' 3>&1
        ($warning.Message | ConvertFrom-Json).message | Should -Be 'shown'
    }

    It 'Get-LdoLogLevel returns the configured level' {
        Set-LdoLogLevel -Level WARN
        Get-LdoLogLevel | Should -Be 'WARN'
    }
}

Describe 'Write-LdoLog (OpenTelemetry fields)' {

    It 'emits severity_number and falls back service.name to the invocation name' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.severity_number | Should -Be 13
        $obj.'service.name'  | Should -Be 'test'
    }

    It 'honours LDO_SERVICE_NAME for service.name' {
        $env:LDO_SERVICE_NAME = 'terraform-azure'
        try {
            $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
            ($warning.Message | ConvertFrom-Json).'service.name' | Should -Be 'terraform-azure'
        }
        finally {
            Remove-Item Env:LDO_SERVICE_NAME -ErrorAction SilentlyContinue
        }
    }

    It 'maps SUCCESS to INFO severity (9)' {
        $info = Write-LdoLog -Level SUCCESS -Message 'done' -InvocationName 'test' 6>&1
        ($info.MessageData | ConvertFrom-Json).severity_number | Should -Be 9
    }
}

Describe 'Write-LdoLog (TRACE and FATAL levels)' {

    AfterEach { Set-LdoLogLevel -Level INFO }

    It 'routes FATAL to the error stream with severity_number 21' {
        $err = Write-LdoLog -Level FATAL -Message 'down' -InvocationName 'test' 2>&1
        $obj = $err.ToString() | ConvertFrom-Json
        $obj.message         | Should -Be 'down'
        $obj.severity_number | Should -Be 21
    }

    It 'suppresses TRACE below the INFO floor' {
        Set-LdoLogLevel -Level INFO
        $out = Write-LdoLog -Level TRACE -Message 'noise' -InvocationName 'test' 4>&1 3>&1 6>&1
        $out | Should -BeNullOrEmpty
    }

    It 'accepts TRACE as a valid level for Set-LdoLogLevel' {
        { Set-LdoLogLevel -Level TRACE } | Should -Not -Throw
    }
}

Describe 'Trace context' {

    AfterEach { Clear-LdoTraceContext }

    It 'Set-LdoTraceContext -Generate populates all three ids with the right lengths' {
        Set-LdoTraceContext -Generate
        $ctx = Get-LdoTraceContext
        $ctx.trace_id.Length       | Should -Be 32
        $ctx.span_id.Length        | Should -Be 16
        $ctx.correlation_id.Length | Should -Be 32
    }

    It 'stamps trace_id, span_id and correlation_id onto the record' {
        Set-LdoTraceContext -Generate
        $ctx = Get-LdoTraceContext
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.trace_id       | Should -Be $ctx.trace_id
        $obj.span_id        | Should -Be $ctx.span_id
        $obj.correlation_id | Should -Be $ctx.correlation_id
    }

    It 'rotates the span while keeping the trace and correlation id' {
        Set-LdoTraceContext -Generate
        $before = Get-LdoTraceContext
        Set-LdoTraceContext -SpanId (New-LdoSpanId)
        $after = Get-LdoTraceContext
        $after.span_id        | Should -Not -Be $before.span_id
        $after.trace_id       | Should -Be $before.trace_id
        $after.correlation_id | Should -Be $before.correlation_id
    }

    It 'Clear-LdoTraceContext removes the trace fields from records' {
        Set-LdoTraceContext -Generate
        Clear-LdoTraceContext
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        ($warning.Message | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'trace_id'
    }
}
