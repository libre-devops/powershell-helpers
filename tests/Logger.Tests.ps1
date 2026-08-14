BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Write-LdoLog (streams and defaults)' {

    It 'is exported from the module' {
        Get-Command Write-LdoLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'defaults to Otlp with no -Format and no LDO_LOG_FORMAT' {
        # The default is the wire format, so a collector reads the output of any
        # LibreDevOpsHelpers command with no configuration on either side.
        Get-LdoLogFormat | Should -Be 'Otlp'

        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' 3>&1
        $record = (($warning.Message | ConvertFrom-Json).resourceLogs[0].scopeLogs[0].logRecords)[0]
        $record.body.stringValue | Should -Be 'careful'
        $record.severityText     | Should -Be 'WARN'
    }

    It 'routes ERROR to the error stream without terminating' {
        $err = Write-LdoLog -Level ERROR -Message 'broke' -InvocationName 'test' 2>&1
        (($err.ToString() | ConvertFrom-Json).resourceLogs[0].scopeLogs[0].logRecords)[0].body.stringValue |
            Should -Be 'broke'
    }

    It 'derives the invocation name from the caller when not supplied' {
        function Invoke-Caller { Write-LdoLog -Level WARN -Message 'auto' -Format Json 3>&1 }
        $warning = Invoke-Caller
        ($warning.Message | ConvertFrom-Json).invocation | Should -Be 'Invoke-Caller'
    }

    It 'routes INFO to the information stream, not the success stream' {
        $output = Write-LdoLog -Level INFO -Message 'hello' -InvocationName 'test' 6>$null
        $output | Should -BeNullOrEmpty
    }

    It 'writes INFO as a structured record on the information stream' {
        $info = Write-LdoLog -Level INFO -Message 'hello' -InvocationName 'test' 6>&1
        (($info.MessageData | ConvertFrom-Json).resourceLogs[0].scopeLogs[0].logRecords)[0].body.stringValue |
            Should -Be 'hello'
    }

    It 'emits one compact line by default' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        $warning.Message | Should -Not -Match "`n"
    }
}

Describe 'Write-LdoLog (Json format)' {

    # Json is no longer the default, but it is unchanged and still supported: it is the
    # better shape for a backend that is not OTel-aware, such as Azure Monitor via KQL.

    It 'emits a single parseable JSON object with the expected fields' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' -Format Json 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.level | Should -Be 'WARN'
        $obj.invocation | Should -Be 'test'
        $obj.message | Should -Be 'careful'
    }

    It 'stamps a UTC ISO-8601 timestamp' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' -Format Json 3>&1
        # Inspect the raw JSON: ConvertFrom-Json would coerce the string to a DateTime
        # and drop the literal UTC marker we want to assert on.
        $warning.Message | Should -Match '"timestamp":"\d{4}-\d{2}-\d{2}T[\d:.]+Z"'
    }

    It 'merges -Data properties into the record' {
        $warning = Write-LdoLog -Level WARN -Message 'm' -InvocationName 'test' -Data @{ resourceGroup = 'rg-prod' } -Format Json 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.resourceGroup | Should -Be 'rg-prod'
    }

    It 'emits compact single-line JSON' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' -Format Json 3>&1
        $warning.Message | Should -Not -Match "`n"
    }

    It 'is flat, with no OTLP envelope' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' -Format Json 3>&1
        ($warning.Message | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'resourceLogs'
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
            Set-LdoLogFormat -Format Otlp
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
        $warning = Write-LdoLog -Level WARN -Message 'shown' -InvocationName 'test' -Format Json 3>&1
        ($warning.Message | ConvertFrom-Json).message | Should -Be 'shown'
    }

    It 'Get-LdoLogLevel returns the configured level' {
        Set-LdoLogLevel -Level WARN
        Get-LdoLogLevel | Should -Be 'WARN'
    }
}

Describe 'Write-LdoLog (Json OpenTelemetry-flavoured fields)' {

    It 'emits severity_number and falls back service.name to the invocation name' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' -Format Json 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.severity_number | Should -Be 13
        $obj.'service.name'  | Should -Be 'test'
    }

    It 'honours LDO_SERVICE_NAME for service.name' {
        $env:LDO_SERVICE_NAME = 'terraform-azure'
        try {
            $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' -Format Json 3>&1
            ($warning.Message | ConvertFrom-Json).'service.name' | Should -Be 'terraform-azure'
        }
        finally {
            Remove-Item Env:LDO_SERVICE_NAME -ErrorAction SilentlyContinue
        }
    }

    It 'maps SUCCESS to INFO severity (9)' {
        $info = Write-LdoLog -Level SUCCESS -Message 'done' -InvocationName 'test' -Format Json 6>&1
        ($info.MessageData | ConvertFrom-Json).severity_number | Should -Be 9
    }
}

Describe 'Write-LdoLog (TRACE and FATAL levels)' {

    AfterEach { Set-LdoLogLevel -Level INFO }

    It 'routes FATAL to the error stream with severity_number 21' {
        $err = Write-LdoLog -Level FATAL -Message 'down' -InvocationName 'test' -Format Json 2>&1
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

Describe 'Write-LdoLog (Otlp format)' {

    BeforeAll {
        # Every level lands on a different stream, so merge them all and pick whichever
        # property carries the text. Information exposes MessageData, Warning/Verbose/Debug
        # expose Message, and an ErrorRecord only renders through ToString().
        function global:Get-LdoOtlpLine {
            param(
                [string]$Level = 'WARN',
                [string]$Message = 'x',
                [string]$InvocationName = 'test',
                [hashtable]$Data,
                [string]$Format = 'Otlp'
            )

            $splat = @{ Level = $Level; Message = $Message; InvocationName = $InvocationName; Format = $Format }
            if ($Data) { $splat['Data'] = $Data }

            # TRACE and DEBUG route to Write-Verbose and Write-Debug, and a function inside a
            # module does NOT pick up a $VerbosePreference set in the caller's scope. The
            # common parameters do cross that boundary, so use those.
            if ($Level -eq 'TRACE') { $splat['Verbose'] = $true }
            if ($Level -eq 'DEBUG') { $splat['Debug'] = $true }

            $out = Write-LdoLog @splat 2>&1 3>&1 4>&1 5>&1 6>&1

            $text = $out.MessageData
            if (-not $text) { $text = $out.Message }
            if (-not $text) { $text = "$out" }
            return "$text"
        }

        function global:Get-LdoOtlpRecord {
            param([string]$Line)
            (($Line | ConvertFrom-Json).resourceLogs[0].scopeLogs[0].logRecords)[0]
        }

        function global:Get-LdoOtlpAttributeValue {
            param($Attributes, [string]$Key)
            $match = @($Attributes | Where-Object { $_.key -eq $Key })
            if ($match.Count -eq 0) { return $null }
            return $match[0].value
        }

        # TRACE and DEBUG are below the default INFO floor and would be suppressed.
        Set-LdoLogLevel -Level TRACE
    }

    AfterAll {
        Set-LdoLogLevel -Level INFO
        Clear-LdoTraceContext
    }

    It 'emits one complete ExportLogsServiceRequest per line' {
        $line = Get-LdoOtlpLine
        { $line | ConvertFrom-Json } | Should -Not -Throw
        $line | Should -Not -Match "`n"

        $doc = $line | ConvertFrom-Json
        @($doc.resourceLogs).Count                            | Should -Be 1
        @($doc.resourceLogs[0].scopeLogs).Count               | Should -Be 1
        @($doc.resourceLogs[0].scopeLogs[0].logRecords).Count | Should -Be 1
    }

    It 'names the instrumentation scope after the logger, not the service' {
        # scope identifies the library emitting the record. service.name is a resource
        # attribute, and conflating the two is the usual way this gets built wrong.
        $doc = Get-LdoOtlpLine | ConvertFrom-Json
        $doc.resourceLogs[0].scopeLogs[0].scope.name | Should -Be 'LibreDevOpsHelpers.Logger'
    }

    It 'puts service identity on the RESOURCE and never on the record' {
        $env:LDO_SERVICE_NAME = 'terraform-azure'
        $env:LDO_SERVICE_VERSION = '9.9.9'
        $env:LDO_DEPLOYMENT_ENVIRONMENT = 'prd'
        try {
            $doc = Get-LdoOtlpLine | ConvertFrom-Json
            $resource = $doc.resourceLogs[0].resource

            (Get-LdoOtlpAttributeValue -Attributes $resource.attributes -Key 'service.name').stringValue | Should -Be 'terraform-azure'
            (Get-LdoOtlpAttributeValue -Attributes $resource.attributes -Key 'service.version').stringValue | Should -Be '9.9.9'
            (Get-LdoOtlpAttributeValue -Attributes $resource.attributes -Key 'deployment.environment').stringValue | Should -Be 'prd'

            $record = $doc.resourceLogs[0].scopeLogs[0].logRecords[0]
            Get-LdoOtlpAttributeValue -Attributes $record.attributes -Key 'service.name' | Should -BeNullOrEmpty
        }
        finally {
            Remove-Item Env:LDO_SERVICE_NAME, Env:LDO_SERVICE_VERSION, Env:LDO_DEPLOYMENT_ENVIRONMENT -ErrorAction SilentlyContinue
        }
    }

    It 'falls back service.name to the invocation name' {
        $doc = Get-LdoOtlpLine -InvocationName 'Invoke-LdoTerraformPlan' | ConvertFrom-Json
        (Get-LdoOtlpAttributeValue -Attributes $doc.resourceLogs[0].resource.attributes -Key 'service.name').stringValue |
            Should -Be 'Invoke-LdoTerraformPlan'
    }

    It 'puts the message in body, not in an attribute called message' {
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine -Message 'Starting deployment')
        $record.body.stringValue | Should -Be 'Starting deployment'
        Get-LdoOtlpAttributeValue -Attributes $record.attributes -Key 'message' | Should -BeNullOrEmpty
    }

    It 'keeps invocation as a log record attribute' {
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine -InvocationName 'Invoke-LdoTrivy')
        (Get-LdoOtlpAttributeValue -Attributes $record.attributes -Key 'invocation').stringValue | Should -Be 'Invoke-LdoTrivy'
    }

    It 'accepts an empty message' {
        (Get-LdoOtlpRecord -Line (Get-LdoOtlpLine -Message '')).body.stringValue | Should -Be ''
    }
}

Describe 'Write-LdoLog (Otlp wire encoding)' {

    # These assertions are on the RAW line on purpose. ConvertFrom-Json coerces types on the
    # way in, so a parsed value cannot tell you whether the wire carried a string or a number,
    # and that distinction is the whole difference between valid and invalid OTLP here.

    BeforeAll { Set-LdoLogLevel -Level TRACE }
    AfterAll { Set-LdoLogLevel -Level INFO }

    It 'encodes timestamps as nanosecond STRINGS, not numbers' {
        $line = Get-LdoOtlpLine
        $line | Should -Match '"timeUnixNano":"\d{19}"'
        $line | Should -Match '"observedTimeUnixNano":"\d{19}"'
    }

    It 'emits timeUnixNano and observedTimeUnixNano as the same instant' {
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine)
        $record.observedTimeUnixNano | Should -Be $record.timeUnixNano
    }

    It 'stamps the nanosecond timestamp in UTC' {
        # DateTime subtraction ignores Kind, so a local timestamp minus the UTC epoch would
        # silently offset every record by the machine's UTC offset. Anything but a passing
        # assertion here means logs land in the wrong place on a non-UTC host.
        $before = [long](([datetime]::UtcNow.AddSeconds(-5) - [datetime]::UnixEpoch).Ticks) * 100L
        $after = [long](([datetime]::UtcNow.AddSeconds(5) - [datetime]::UnixEpoch).Ticks) * 100L
        $actual = [long](Get-LdoOtlpRecord -Line (Get-LdoOtlpLine)).timeUnixNano

        $actual | Should -BeGreaterThan $before
        $actual | Should -BeLessThan $after
    }

    It 'encodes severityNumber as an INTEGER, not the proto3 enum name' {
        # Stock proto3 JSON would write SEVERITY_NUMBER_WARN. OTLP's JSON encoding overrides
        # that and requires the integer.
        $line = Get-LdoOtlpLine -Level WARN
        $line | Should -Match '"severityNumber":13'
        $line | Should -Not -Match 'SEVERITY_NUMBER'
    }

    It 'maps every level to its OTel severity number and keeps its own name' -TestCases @(
        @{ Level = 'TRACE'; Number = 1 }
        @{ Level = 'DEBUG'; Number = 5 }
        @{ Level = 'INFO'; Number = 9 }
        @{ Level = 'SUCCESS'; Number = 9 }
        @{ Level = 'WARN'; Number = 13 }
        @{ Level = 'ERROR'; Number = 17 }
        @{ Level = 'FATAL'; Number = 21 }
    ) {
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine -Level $Level)
        $record.severityNumber | Should -Be $Number
        $record.severityText | Should -Be $Level
    }

    It 'encodes an integer attribute as intValue, as a STRING' {
        # A JSON number is a double, and a double cannot hold the full int64 range without
        # rounding, which is why proto3 maps 64-bit integers to strings.
        Get-LdoOtlpLine -Data @{ count = 3 } | Should -Match '"key":"count","value":\{"intValue":"3"\}'
    }

    It 'encodes a boolean attribute as boolValue, unquoted' {
        Get-LdoOtlpLine -Data @{ ok = $true } | Should -Match '"key":"ok","value":\{"boolValue":true\}'
    }

    It 'encodes a double as doubleValue, still a number' {
        Get-LdoOtlpLine -Data @{ ratio = 0.25 } | Should -Match '"key":"ratio","value":\{"doubleValue":0\.25\}'
    }

    It 'encodes a string attribute as stringValue' {
        Get-LdoOtlpLine -Data @{ stack = 'core' } | Should -Match '"key":"stack","value":\{"stringValue":"core"\}'
    }

    It 'treats a string as a string and not as a character sequence' {
        # A [string] is also [IEnumerable]. Test the types in the wrong order and every
        # string attribute becomes an array of single-character values.
        Get-LdoOtlpLine -Data @{ stack = 'core' } | Should -Not -Match '"stringValue":"c"'
    }

    It 'encodes a null attribute as an empty AnyValue, not an empty string' {
        # An unset AnyValue means "no value". "" would assert the caller reported an empty
        # string, which is a different fact.
        Get-LdoOtlpLine -Data @{ nothing = $null } | Should -Match '"key":"nothing","value":\{\}'
    }

    It 'encodes a string array as arrayValue' {
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine -Data @{ hosts = @('a', 'b') })
        $value = Get-LdoOtlpAttributeValue -Attributes $record.attributes -Key 'hosts'
        @($value.arrayValue.values).Count       | Should -Be 2
        $value.arrayValue.values[0].stringValue | Should -Be 'a'
    }

    It 'keeps a ONE element array an array' {
        # An attribute that is an object for one item and an array for two is what makes a
        # backend reject the document with a field type conflict.
        Get-LdoOtlpLine -Data @{ hosts = @('only') } | Should -Match '"key":"hosts","value":\{"arrayValue":\{"values":\['
    }

    It 'encodes an empty array as an empty arrayValue' {
        Get-LdoOtlpLine -Data @{ hosts = @() } | Should -Match '"key":"hosts","value":\{"arrayValue":\{"values":\[\]\}\}'
    }

    It 'encodes a hashtable as kvlistValue' {
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine -Data @{ device = @{ id = 'dev-a' } })
        $value = Get-LdoOtlpAttributeValue -Attributes $record.attributes -Key 'device'
        $value.kvlistValue.values[0].key               | Should -Be 'id'
        $value.kvlistValue.values[0].value.stringValue | Should -Be 'dev-a'
    }

    It 'survives the envelope depth plus a nested list of dictionaries' {
        # ConvertTo-Json past its -Depth does not fail, it substitutes the TYPE NAME as a
        # string, producing a well-formed document no collector can read. The envelope alone
        # is 7 levels before any attribute, so this is the case that catches too small a depth.
        $line = Get-LdoOtlpLine -Data @{ members = @(@{ id = 'dev-a'; tags = @('linux', 'prd') }) }
        $line | Should -Not -Match 'System\.Collections'

        $value = Get-LdoOtlpAttributeValue -Attributes (Get-LdoOtlpRecord -Line $line).attributes -Key 'members'
        $tags = @($value.arrayValue.values[0].kvlistValue.values | Where-Object { $_.key -eq 'tags' })[0]
        $tags.value.arrayValue.values[1].stringValue | Should -Be 'prd'
    }
}

Describe 'Write-LdoLog (Otlp trace context)' {

    AfterEach { Clear-LdoTraceContext }

    It 'carries the generated trace and span ids as hex' {
        Set-LdoTraceContext -Generate
        $ctx = Get-LdoTraceContext
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine)

        $record.traceId | Should -Be $ctx.trace_id
        $record.spanId  | Should -Be $ctx.span_id
    }

    It 'derives traceId from the correlation id when no trace id is set' {
        # A GUID is 16 bytes, which is exactly a trace id, so a CI run id becomes a usable
        # trace id and a whole run is one trace without the caller doing anything.
        Set-LdoTraceContext -CorrelationId 'A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D'
        (Get-LdoOtlpRecord -Line (Get-LdoOtlpLine)).traceId | Should -Be 'a1b2c3d4e5f64a5b8c9d0e1f2a3b4c5d'
    }

    It 'prefers an explicit trace id over the correlation id' {
        Set-LdoTraceContext -TraceId '4bf92f3577b34da6a3ce929d0e0e4736' -CorrelationId 'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d'
        (Get-LdoOtlpRecord -Line (Get-LdoOtlpLine)).traceId | Should -Be '4bf92f3577b34da6a3ce929d0e0e4736'
    }

    It 'keeps correlation_id as an attribute even once it seeds traceId' {
        # A backend that drops a trace id it does not like must not thereby lose the only
        # field tying one run's records together.
        Set-LdoTraceContext -CorrelationId 'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d'
        $record = Get-LdoOtlpRecord -Line (Get-LdoOtlpLine)
        (Get-LdoOtlpAttributeValue -Attributes $record.attributes -Key 'correlation_id').stringValue |
            Should -Be 'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d'
    }

    It 'drops an invalid trace id rather than emitting it' -TestCases @(
        @{ TraceId = 'not-hex-at-all' }
        @{ TraceId = 'deadbeef' }
        @{ TraceId = '4bf92f3577b34da6a3ce929d0e0e4736ff' }
    ) {
        # An invalid id makes a collector reject the WHOLE payload, so the only safe thing is
        # to omit the field and keep the record valid.
        Set-LdoTraceContext -TraceId $TraceId -CorrelationId ''
        Get-LdoOtlpLine | Should -Not -Match '"traceId"'
    }

    It 'drops an invalid span id rather than emitting it' -TestCases @(
        @{ SpanId = 'zzzzzzzzzzzzzzzz' }
        @{ SpanId = '00f067aa0ba902' }
    ) {
        Set-LdoTraceContext -SpanId $SpanId
        Get-LdoOtlpLine | Should -Not -Match '"spanId"'
    }

    It 'omits both ids entirely when there is no trace context' {
        Clear-LdoTraceContext
        $line = Get-LdoOtlpLine
        $line | Should -Not -Match '"traceId"'
        $line | Should -Not -Match '"spanId"'
    }
}

Describe 'Write-LdoLog (Otlp format selection)' {

    AfterAll {
        Set-LdoLogFormat -Format Otlp
        Set-LdoLogLevel -Level INFO
    }

    It 'OtlpIndented pretty-prints across multiple lines but stays valid OTLP' {
        $line = Get-LdoOtlpLine -Format OtlpIndented
        $line | Should -Match "`n"
        (Get-LdoOtlpRecord -Line $line).body.stringValue | Should -Be 'x'
    }

    It 'honours Set-LdoLogFormat -Format Json as an override of the default' {
        Set-LdoLogFormat -Format Json
        try {
            Get-LdoLogFormat | Should -Be 'Json'
            $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' 3>&1
            ($warning.Message | ConvertFrom-Json).message | Should -Be 'careful'
        }
        finally {
            Set-LdoLogFormat -Format Otlp
        }
    }

    It 'resolves the format name from LDO_LOG_FORMAT' -TestCases @(
        @{ Value = 'otlp'; Expected = 'Otlp' }
        @{ Value = 'OTLP'; Expected = 'Otlp' }
        @{ Value = 'otlpindented'; Expected = 'OtlpIndented' }
        @{ Value = 'json'; Expected = 'Json' }
        @{ Value = 'text'; Expected = 'Text' }
        @{ Value = 'nonsense'; Expected = 'Otlp' }
        @{ Value = ''; Expected = 'Otlp' }
    ) {
        # Resolution happens once when the module loads, so this has to re-import.
        $saved = $env:LDO_LOG_FORMAT
        try {
            $env:LDO_LOG_FORMAT = $Value
            Import-Module (Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1') -Force
            Get-LdoLogFormat | Should -Be $Expected
        }
        finally {
            if ($null -eq $saved) { Remove-Item Env:LDO_LOG_FORMAT -ErrorAction SilentlyContinue }
            else { $env:LDO_LOG_FORMAT = $saved }
            Import-Module (Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1') -Force
        }
    }

    It 'leaves the flat Json record untouched' {
        # Otlp is an ADDITION. Anything already reading the flat records must see exactly
        # what it saw before.
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' -Format Json 3>&1
        $obj = $warning.Message | ConvertFrom-Json

        $obj.level           | Should -Be 'WARN'
        $obj.severity_number | Should -Be 13
        $obj.message         | Should -Be 'careful'
        $obj.'service.name'  | Should -Be 'test'
        $obj.PSObject.Properties.Name | Should -Not -Contain 'resourceLogs'
    }

    It 'still suppresses a level below the floor in Otlp mode' {
        Set-LdoLogLevel -Level ERROR
        try {
            $warning = Write-LdoLog -Level WARN -Message 'hidden' -InvocationName 'test' -Format Otlp 3>&1
            $warning | Should -BeNullOrEmpty
        }
        finally {
            Set-LdoLogLevel -Level INFO
        }
    }
}

Describe 'Get-LdoOtlpHexId' {

    It 'accepts an id of the right width' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            Get-LdoOtlpHexId -Value '4bf92f3577b34da6a3ce929d0e0e4736' -Length 32 |
                Should -Be '4bf92f3577b34da6a3ce929d0e0e4736'
        }
    }

    It 'lowercases and strips dashes so a GUID becomes a trace id' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            Get-LdoOtlpHexId -Value '  A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D  ' -Length 32 |
                Should -Be 'a1b2c3d4e5f64a5b8c9d0e1f2a3b4c5d'
        }
    }

    It 'returns empty for the wrong width or a non-hex character' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            Get-LdoOtlpHexId -Value 'deadbeef' -Length 32 | Should -BeNullOrEmpty
            Get-LdoOtlpHexId -Value '4bf92f3577b34da6a3ce929d0e0e473g' -Length 32 | Should -BeNullOrEmpty
        }
    }

    It 'returns empty rather than throwing on blank input' {
        # Called on every record, so this path is hot and must never throw.
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            { Get-LdoOtlpHexId -Value '' -Length 32 } | Should -Not -Throw
            Get-LdoOtlpHexId -Value '   ' -Length 16 | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-LdoOtlpAnyValue' {

    It 'distinguishes a bool from an int' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            (ConvertTo-LdoOtlpAnyValue -Value $true).Keys | Should -Be 'boolValue'
            (ConvertTo-LdoOtlpAnyValue -Value 1).Keys     | Should -Be 'intValue'
        }
    }

    It 'widens every integer type to an intValue string' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            foreach ($value in [byte]1, [int16]2, [int]3, [long]4) {
                $result = ConvertTo-LdoOtlpAnyValue -Value $value
                $result.Keys        | Should -Be 'intValue'
                $result['intValue'] | Should -BeOfType [string]
            }
        }
    }

    It 'keeps floating point types as doubleValue numbers' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            foreach ($value in [single]1.5, [double]1.5, [decimal]1.5) {
                $result = ConvertTo-LdoOtlpAnyValue -Value $value
                $result.Keys          | Should -Be 'doubleValue'
                $result['doubleValue'] | Should -Be 1.5
            }
        }
    }

    It 'falls back to stringValue for a type it does not model' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            $result = ConvertTo-LdoOtlpAnyValue -Value ([guid]'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d')
            $result.Keys           | Should -Be 'stringValue'
            $result['stringValue'] | Should -Be 'a1b2c3d4-e5f6-4a5b-8c9d-0e1f2a3b4c5d'
        }
    }

    It 'recurses through a dictionary inside an array' {
        InModuleScope -ModuleName LibreDevOpsHelpers.Logger {
            $result = ConvertTo-LdoOtlpAnyValue -Value @(@{ id = 'dev-a' })
            $result['arrayValue']['values'][0]['kvlistValue']['values'][0]['key'] | Should -Be 'id'
        }
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
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' -Format Json 3>&1
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
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' -Format Json 3>&1
        ($warning.Message | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'trace_id'
    }
}
