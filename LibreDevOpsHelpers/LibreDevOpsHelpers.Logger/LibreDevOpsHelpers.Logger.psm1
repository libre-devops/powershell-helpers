Set-StrictMode -Version Latest

# Canonical level vocabulary, ordered for threshold comparison. Messages below the configured
# minimum are suppressed. TRACE and DEBUG are developer diagnostics; SUCCESS is a presentation
# alias that collapses to INFO severity. Matches the Libre DevOps logging standard.
$script:LdoLogLevels = @{ TRACE = 0; DEBUG = 1; INFO = 2; SUCCESS = 2; WARN = 3; ERROR = 4; FATAL = 5 }

# OpenTelemetry SeverityNumber for each level (SUCCESS collapses to INFO = 9). Emitted as the
# severity_number field so backends can sort and filter by severity without parsing text.
$script:LdoSeverityNumbers = @{ TRACE = 1; DEBUG = 5; INFO = 9; SUCCESS = 9; WARN = 13; ERROR = 17; FATAL = 21 }

# Minimum level and output format. Both can be seeded from the environment so that
# operators can control logging in CI/CD without touching code, and both fall back to
# sensible defaults (INFO floor; OTLP) when unset or invalid.
$script:LdoMinLogLevel = if ($env:LDO_LOG_LEVEL -and $script:LdoLogLevels.ContainsKey($env:LDO_LOG_LEVEL.ToUpperInvariant())) {
    $env:LDO_LOG_LEVEL.ToUpperInvariant()
}
else {
    'INFO'
}

$script:LdoLogFormat = switch -Regex ($env:LDO_LOG_FORMAT) {
    '^(?i)otlpindented$' { 'OtlpIndented'; break }
    '^(?i)jsonindented$' { 'JsonIndented'; break }
    '^(?i)json$' { 'Json'; break }
    '^(?i)text$' { 'Text'; break }
    default { 'Otlp' }  # covers 'otlp', unset, and any unrecognised value
}

# InstrumentationScope name stamped on every OTLP record. This identifies the LOGGER, not the
# service: service.name is a resource attribute and is set separately from LDO_SERVICE_NAME.
$script:LdoOtlpScopeName = 'LibreDevOpsHelpers.Logger'

# Ambient trace context stamped onto every record when set. Seeded from the environment so a
# parent process or CI step can propagate a trace across process boundaries (W3C-style), and
# refreshable at runtime via Set-LdoTraceContext. Empty values are omitted from the record.
$script:LdoTraceContext = @{
    trace_id = if ($env:LDO_TRACE_ID) { $env:LDO_TRACE_ID } else { '' }
    span_id = if ($env:LDO_SPAN_ID) { $env:LDO_SPAN_ID } else { '' }
    correlation_id = if ($env:LDO_CORRELATION_ID) { $env:LDO_CORRELATION_ID } else { '' }
}

function Set-LdoLogLevel {
    <#
    .SYNOPSIS
        Sets the minimum level that Write-LdoLog will emit.

    .DESCRIPTION
        Messages below the configured level are dropped. The default floor is INFO, so TRACE and
        DEBUG are suppressed until you lower the level (and DEBUG additionally requires
        $DebugPreference to be set, since it is routed through Write-Debug). The initial value can
        also be supplied via the LDO_LOG_LEVEL environment variable.

    .PARAMETER Level
        One of TRACE, DEBUG, INFO, WARN, ERROR, FATAL. SUCCESS is treated at the same
        threshold as INFO.

    .EXAMPLE
        Set-LdoLogLevel -Level WARN

        Suppresses TRACE, DEBUG, INFO and SUCCESS messages, leaving only WARN, ERROR and FATAL.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level
    )

    $script:LdoMinLogLevel = $Level
}

function Get-LdoLogLevel {
    <#
    .SYNOPSIS
        Returns the current minimum level that Write-LdoLog will emit.

    .DESCRIPTION
        Returns the threshold set by Set-LdoLogLevel (or seeded from the LDO_LOG_LEVEL
        environment variable). Messages below this level are suppressed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:LdoMinLogLevel
}

function Set-LdoLogFormat {
    <#
    .SYNOPSIS
        Sets the default output format that Write-LdoLog will emit.

    .DESCRIPTION
        Controls how every log message is rendered unless a call overrides it with its
        own -Format. The default is Otlp, the OpenTelemetry wire format: one complete
        OTLP/JSON export request per line, which a collector ingests directly with no
        parser stack. Json emits one compact FLAT object per line instead, which is
        easier to query in a backend that is not OTel-aware, such as Azure Monitor via
        KQL. Text emits a human-readable, coloured line for interactive CLI use. The
        initial value can also be supplied via the LDO_LOG_FORMAT environment variable.

    .PARAMETER Format
        Otlp (default; one complete OTLP/JSON export request per line), OtlpIndented
        (pretty-printed OTLP, local debugging only - not newline-delimited), Json
        (compact flat object, one per line), JsonIndented (pretty-printed, local
        debugging only), or Text.

    .EXAMPLE
        Set-LdoLogFormat -Format Text

        Switches subsequent log output to the human-readable coloured format.

    .EXAMPLE
        Set-LdoLogFormat -Format Json

        Switches subsequent log output to the flat record, for a backend that is not
        OTel-aware and would need a parser stack to read OTLP.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Otlp', 'OtlpIndented', 'Json', 'JsonIndented', 'Text')]
        [string]$Format
    )

    $script:LdoLogFormat = $Format
}

function Get-LdoLogFormat {
    <#
    .SYNOPSIS
        Returns the current default output format.

    .DESCRIPTION
        One of Otlp (the default), OtlpIndented, Json, JsonIndented or Text. See
        Set-LdoLogFormat.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:LdoLogFormat
}

function Set-LdoTraceContext {
    <#
    .SYNOPSIS
        Sets the ambient trace context stamped onto every log record.

    .DESCRIPTION
        Sets the trace_id, span_id and correlation_id that Write-LdoLog adds to each structured
        record while a trace context is active. Only the supplied values are changed; omit a
        parameter to leave it untouched. Pass -Generate to fill any currently-empty value with
        a fresh cryptographically strong identifier (trace_id and correlation_id are 32 hex
        characters, span_id is 16). Call this once at a process entry point to start a trace,
        and call it again with a new -SpanId for each unit of work (for example each Terraform
        stack) so spans nest under the one trace.

    .PARAMETER TraceId
        W3C trace id (32 hex characters).

    .PARAMETER SpanId
        W3C span id (16 hex characters).

    .PARAMETER CorrelationId
        Correlation id tying together all records from a single run.

    .PARAMETER Generate
        Fill any value that is currently empty (and not supplied explicitly) with a freshly
        generated identifier.

    .EXAMPLE
        Set-LdoTraceContext -Generate

        Starts a new trace, generating a trace_id, span_id and correlation_id.

    .EXAMPLE
        Set-LdoTraceContext -SpanId (New-LdoSpanId)

        Starts a new span under the current trace (for example, per Terraform stack).

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$TraceId,
        [string]$SpanId,
        [string]$CorrelationId,
        [switch]$Generate
    )

    if ($PSBoundParameters.ContainsKey('TraceId')) { $script:LdoTraceContext.trace_id = $TraceId }
    if ($PSBoundParameters.ContainsKey('SpanId')) { $script:LdoTraceContext.span_id = $SpanId }
    if ($PSBoundParameters.ContainsKey('CorrelationId')) { $script:LdoTraceContext.correlation_id = $CorrelationId }

    if ($Generate) {
        if (-not $script:LdoTraceContext.trace_id) { $script:LdoTraceContext.trace_id = New-LdoTraceId }
        if (-not $script:LdoTraceContext.span_id) { $script:LdoTraceContext.span_id = New-LdoSpanId }
        if (-not $script:LdoTraceContext.correlation_id) { $script:LdoTraceContext.correlation_id = New-LdoCorrelationId }
    }
}

function Get-LdoTraceContext {
    <#
    .SYNOPSIS
        Returns a copy of the current ambient trace context.

    .DESCRIPTION
        Returns a hashtable with the trace_id, span_id and correlation_id currently stamped
        onto log records. Empty strings mean the corresponding field is not set and is omitted
        from the record.

    .EXAMPLE
        (Get-LdoTraceContext).trace_id

    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        trace_id = $script:LdoTraceContext.trace_id
        span_id = $script:LdoTraceContext.span_id
        correlation_id = $script:LdoTraceContext.correlation_id
    }
}

function Clear-LdoTraceContext {
    <#
    .SYNOPSIS
        Clears the ambient trace context.

    .DESCRIPTION
        Resets trace_id, span_id and correlation_id to empty so subsequent log records carry no
        trace fields.

    .EXAMPLE
        Clear-LdoTraceContext

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $script:LdoTraceContext.trace_id = ''
    $script:LdoTraceContext.span_id = ''
    $script:LdoTraceContext.correlation_id = ''
}

function Write-LdoLog {
    <#
    .SYNOPSIS
        Writes a levelled, timestamped log message to the correct PowerShell stream.

    .DESCRIPTION
        The single logging entry point for all LibreDevOpsHelpers modules. By default each
        message is rendered as one complete OTLP/JSON ExportLogsServiceRequest per line, carrying
        exactly one record: the OpenTelemetry wire format, which the collector-contrib
        otlpjsonfile receiver ingests directly with no parser stack, no severity mapping and no
        timestamp layout to configure. Additional fields can be merged via -Data, and become
        typed OTLP attributes.

        Pass -Format Json (or call Set-LdoLogFormat) for the older flat record: one compact JSON
        object per line carrying a UTC ISO-8601 timestamp, level, severity_number, message,
        service.name, invocation and the ambient trace context. It borrows OTel's vocabulary
        without being OTLP, so an OTLP endpoint will not accept it and ingesting it needs a
        parser stack, typically a filelog receiver with json_parser and severity_parser. It is
        still the better choice for a backend that is not OTel-aware, such as Azure Monitor
        queried with KQL, where a flat object is far easier to work with and OTLP is roughly
        three times the bytes.

        Pass -Format Text for a human-readable coloured line instead.

        service.name defaults to the LDO_SERVICE_NAME environment variable, falling back to the
        invocation name when unset; service.version (LDO_SERVICE_VERSION) and
        deployment.environment (LDO_DEPLOYMENT_ENVIRONMENT) are added when their environment
        variables are set. In Otlp mode these three are resource attributes rather than fields on
        the record, because that is where the OTel data model puts them, and the ambient trace
        context (see Set-LdoTraceContext) becomes traceId and spanId.

        Each level is routed to a stream that never touches the success (output) pipeline, so the
        function is safe to call from inside other functions without corrupting their return
        values:

            TRACE   -> Write-Verbose      (shown when $VerbosePreference is Continue)
            DEBUG   -> Write-Debug         (shown when $DebugPreference is Continue)
            INFO    -> Write-Information   (information stream; coloured Write-Host in Text mode)
            SUCCESS -> Write-Information   (information stream; coloured Write-Host in Text mode)
            WARN    -> Write-Warning
            ERROR   -> Write-Error         (non-terminating; the caller decides whether to throw)
            FATAL   -> Write-Error         (non-terminating; the caller decides whether to exit)

        Messages below the level set by Set-LdoLogLevel are suppressed.

    .PARAMETER Level
        Severity of the message. One of TRACE, DEBUG, INFO, SUCCESS, WARN, ERROR, FATAL.

    .PARAMETER Message
        The text to log. Keep it constant; put variable data in -Data fields, not interpolated
        into the message, so records stay groupable and alertable.

    .PARAMETER InvocationName
        Name of the calling command, used as the JSON "invocation" field and the text
        prefix. Defaults to the immediate caller's command name when not supplied.

    .PARAMETER Data
        Optional hashtable of additional structured properties merged into the record (for
        example resource names or durations). Ignored in Text mode.

    .PARAMETER Format
        Overrides the module default output format for this call only. Otlp (default; one
        complete OTLP/JSON export request per line), OtlpIndented, Json (compact flat object),
        JsonIndented (pretty-printed, for local debugging), or Text.

    .EXAMPLE
        Write-LdoLog -Level INFO -Message 'Starting deployment'

    .EXAMPLE
        Write-LdoLog -Level ERROR -Message "Failed: $($_.Exception.Message)"

    .EXAMPLE
        Write-LdoLog -Level INFO -Message 'Created resource group' -Data @{ resource_group = 'rg-prod' }
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('TRACE', 'DEBUG', 'INFO', 'SUCCESS', 'WARN', 'ERROR', 'FATAL')]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [string]$InvocationName,

        [hashtable]$Data,

        [ValidateSet('Otlp', 'OtlpIndented', 'Json', 'JsonIndented', 'Text')]
        [string]$Format
    )

    if (-not $InvocationName) {
        $caller = (Get-PSCallStack)[1]
        $InvocationName = if ($caller -and $caller.Command) { $caller.Command } else { '<script>' }
    }

    if ($script:LdoLogLevels[$Level] -lt $script:LdoLogLevels[$script:LdoMinLogLevel]) {
        return
    }

    if (-not $Format) {
        $Format = $script:LdoLogFormat
    }

    $now = Get-Date

    if ($Format -eq 'Text') {
        $timestamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
        $line = '{0} [{1}] [{2}] {3}' -f $timestamp, $Level, $InvocationName, $Message
    }
    elseif ($Format -like 'Otlp*') {
        $line = Format-LdoOtlpLogRecord -Level $Level -Message $Message -InvocationName $InvocationName `
            -Timestamp $now -Data $Data -Format $Format
    }
    else {
        # ISO-8601 in UTC ("o" round-trip format) so downstream log systems can parse
        # an unambiguous, timezone-correct timestamp. Field order follows the OTel log model:
        # timestamp, level, severity_number, message, then resource/service attributes.
        # service.name falls back to the invocation name when LDO_SERVICE_NAME is unset, since
        # in many scripts the calling command is the logical service emitting the record.
        $serviceName = if ($env:LDO_SERVICE_NAME) { $env:LDO_SERVICE_NAME } else { $InvocationName }

        $record = [ordered]@{
            timestamp = $now.ToUniversalTime().ToString('o')
            level = $Level
            severity_number = $script:LdoSeverityNumbers[$Level]
            message = $Message
            'service.name' = $serviceName
            invocation = $InvocationName
        }
        if ($env:LDO_SERVICE_VERSION) { $record['service.version'] = $env:LDO_SERVICE_VERSION }
        if ($env:LDO_DEPLOYMENT_ENVIRONMENT) { $record['deployment.environment'] = $env:LDO_DEPLOYMENT_ENVIRONMENT }

        # Stamp the ambient trace context when set, so logs join to a trace. Omitted when empty.
        if ($script:LdoTraceContext.trace_id) { $record['trace_id'] = $script:LdoTraceContext.trace_id }
        if ($script:LdoTraceContext.span_id) { $record['span_id'] = $script:LdoTraceContext.span_id }
        if ($script:LdoTraceContext.correlation_id) { $record['correlation_id'] = $script:LdoTraceContext.correlation_id }

        if ($Data) {
            foreach ($key in $Data.Keys) {
                $record[[string]$key] = $Data[$key]
            }
        }
        # Compact (one object per line) is the default for log ingestion. JsonIndented is an
        # opt-in for local debugging and is not newline-delimited.
        if ($Format -eq 'JsonIndented') {
            $line = $record | ConvertTo-Json -Depth 10
        }
        else {
            $line = $record | ConvertTo-Json -Depth 10 -Compress
        }
    }

    switch ($Level) {
        'TRACE' { Write-Verbose $line }
        'DEBUG' { Write-Debug $line }
        'INFO' { Write-LdoInfoLine -Line $line -Level $Level -Format $Format -Color Cyan }
        'SUCCESS' { Write-LdoInfoLine -Line $line -Level $Level -Format $Format -Color Green }
        'WARN' { Write-Warning $line }
        # Explicitly non-terminating: logging an error or a fatal must never throw on its own,
        # even when the caller has $ErrorActionPreference = 'Stop'. The caller decides whether
        # to throw or exit.
        'ERROR' { Write-Error $line -ErrorAction Continue }
        'FATAL' { Write-Error $line -ErrorAction Continue }
    }
}

function Write-LdoInfoLine {
    # Emits INFO/SUCCESS lines without ever touching the success (output) stream.
    # JSON goes through Write-Information so it lands on the information stream as a
    # tagged, capturable InformationRecord with no ANSI colour to corrupt parsing.
    # Text uses coloured Write-Host for readable interactive CLI output.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line,
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][System.ConsoleColor]$Color
    )

    if ($Format -eq 'Text') {
        Write-Host $Line -ForegroundColor $Color
    }
    else {
        Write-Information -MessageData $Line -Tags $Level -InformationAction Continue
    }
}

function Get-LdoOtlpHexId {
    # Normalises a trace or span id to OTLP's hex encoding, or returns empty.
    #
    # OTLP/JSON encodes traceId and spanId as lowercase hex strings of a fixed width, 32
    # characters for a trace and 16 for a span. This is a deliberate departure from the proto3
    # JSON mapping, which would base64 a bytes field, and it is stated as such in the OTLP
    # specification. A collector rejects the whole payload when the width or the alphabet is
    # wrong, so an id set by hand through LDO_TRACE_ID must not reach the wire unchecked.
    #
    # Returning empty rather than throwing is the point: the field is then omitted and the
    # record is still valid. Logging must never fail the thing it is logging about.
    #
    # Dashes are stripped because a GUID is 16 bytes, which is exactly a trace id, so a run id
    # from a CI system becomes a usable trace id without the caller reformatting it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][ValidateSet(16, 32)][int]$Length
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $candidate = $Value.Trim().Replace('-', '').ToLowerInvariant()

    if ($candidate -match ('^[0-9a-f]{' + $Length + '}$')) {
        return $candidate
    }

    return ''
}

function ConvertTo-LdoOtlpAnyValue {
    # Wraps a PowerShell value in an OTLP AnyValue.
    #
    # OTLP does not carry bare JSON values. Every attribute value is an AnyValue: a single-field
    # object naming its own type, so a backend never has to guess whether 5 was an integer or a
    # string.
    #
    # Two encodings are not the obvious ones and both come from proto3's JSON mapping. Sixty-four
    # bit integers cross the wire as STRINGS, because a JSON number is a double and a double
    # cannot hold the full int64 range without rounding. Doubles stay numbers.
    #
    # Order of the type tests is load-bearing. A [string] is also [IEnumerable], so the string
    # test must come before the enumerable one or every message becomes an array of characters.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Value
    )

    # An AnyValue with no field set is the OTLP representation of an absent value, and is what a
    # null must become. An empty string would assert that the caller reported "", which is a
    # different fact.
    if ($null -eq $Value) {
        return [ordered]@{}
    }

    if ($Value -is [bool]) {
        return [ordered]@{ boolValue = $Value }
    }

    if ($Value -is [string]) {
        return [ordered]@{ stringValue = $Value }
    }

    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long]) {
        return [ordered]@{ intValue = [string][long]$Value }
    }

    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return [ordered]@{ doubleValue = [double]$Value }
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $pairs = [System.Collections.Generic.List[object]]::new()
        foreach ($key in $Value.Keys) {
            $pairs.Add([ordered]@{
                    key = [string]$key
                    value = (ConvertTo-LdoOtlpAnyValue -Value $Value[$key])
                })
        }
        return [ordered]@{ kvlistValue = [ordered]@{ values = $pairs } }
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-LdoOtlpAnyValue -Value $item))
        }
        return [ordered]@{ arrayValue = [ordered]@{ values = $items } }
    }

    return [ordered]@{ stringValue = [string]$Value }
}

function New-LdoOtlpAttribute {
    # Builds one OTLP KeyValue pair.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowNull()]$Value
    )

    return [ordered]@{
        key = $Key
        value = (ConvertTo-LdoOtlpAnyValue -Value $Value)
    }
}

function Format-LdoOtlpLogRecord {
    # Renders one log record as a complete OTLP/JSON ExportLogsServiceRequest.
    #
    # Unlike the Json format this IS the wire format. Every line is a whole, self-contained
    # export request carrying exactly one record, which is what the collector-contrib
    # otlpjsonfile receiver expects, so a collector ingests it with no parser stack, no severity
    # mapping and no timestamp layout to get wrong.
    #
    # One record per line is more envelope per byte than batching many records into one request.
    # It is still the right shape for a logger, because output is written line by line to a host
    # that may truncate or interleave it, and a partial batch is an unparseable document whereas
    # a lost line is just a lost line.
    #
    # Field placement follows the OTel log data model rather than the flat record's convenience.
    # service.* are RESOURCE attributes, because they describe the thing emitting the telemetry.
    # invocation and correlation_id are LOG RECORD attributes, because they describe one event.
    # The message becomes body, not an attribute called message.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][string]$InvocationName,
        [Parameter(Mandatory)][datetime]$Timestamp,
        [hashtable]$Data,
        [Parameter(Mandatory)][string]$Format
    )

    $serviceName = if ($env:LDO_SERVICE_NAME) { $env:LDO_SERVICE_NAME } else { $InvocationName }

    # OTLP timestamps are nanoseconds since the Unix epoch and, being a uint64, cross the wire as
    # a string. DateTime ticks are 100ns units, so the multiply by 100 is the full precision the
    # platform has rather than a rounding. ToUniversalTime first: DateTime subtraction ignores
    # Kind, so subtracting the (UTC) epoch from a local timestamp would silently offset it.
    $nanos = [string]([long](($Timestamp.ToUniversalTime() - [datetime]::UnixEpoch).Ticks) * 100L)

    $resourceAttributes = [System.Collections.Generic.List[object]]::new()
    $resourceAttributes.Add((New-LdoOtlpAttribute -Key 'service.name' -Value $serviceName))
    if ($env:LDO_SERVICE_VERSION) {
        $resourceAttributes.Add((New-LdoOtlpAttribute -Key 'service.version' -Value $env:LDO_SERVICE_VERSION))
    }
    if ($env:LDO_DEPLOYMENT_ENVIRONMENT) {
        $resourceAttributes.Add((New-LdoOtlpAttribute -Key 'deployment.environment' -Value $env:LDO_DEPLOYMENT_ENVIRONMENT))
    }

    $logAttributes = [System.Collections.Generic.List[object]]::new()
    $logAttributes.Add((New-LdoOtlpAttribute -Key 'invocation' -Value $InvocationName))

    # correlation_id stays an attribute even when it also seeds traceId below. The two are not
    # interchangeable: a backend that drops a trace id it does not like would otherwise lose the
    # only field tying one run's records together.
    if ($script:LdoTraceContext.correlation_id) {
        $logAttributes.Add((New-LdoOtlpAttribute -Key 'correlation_id' -Value $script:LdoTraceContext.correlation_id))
    }

    if ($Data) {
        foreach ($key in $Data.Keys) {
            $logAttributes.Add((New-LdoOtlpAttribute -Key ([string]$key) -Value $Data[$key]))
        }
    }

    $logRecord = [ordered]@{
        timeUnixNano = $nanos
        observedTimeUnixNano = $nanos
        severityNumber = $script:LdoSeverityNumbers[$Level]
        severityText = $Level
        body = [ordered]@{ stringValue = $Message }
        attributes = $logAttributes
    }

    # An explicit trace id wins. Failing that the correlation id is used, so a run whose entry
    # point only set a correlation id is still one trace. Either is dropped when it is not a
    # valid id, rather than emitted and rejected.
    $traceId = Get-LdoOtlpHexId -Value $script:LdoTraceContext.trace_id -Length 32
    if (-not $traceId) {
        $traceId = Get-LdoOtlpHexId -Value $script:LdoTraceContext.correlation_id -Length 32
    }
    $spanId = Get-LdoOtlpHexId -Value $script:LdoTraceContext.span_id -Length 16

    if ($traceId) { $logRecord['traceId'] = $traceId }
    if ($spanId) { $logRecord['spanId'] = $spanId }

    $payload = [ordered]@{
        resourceLogs = @(
            [ordered]@{
                resource = [ordered]@{ attributes = $resourceAttributes }
                scopeLogs = @(
                    [ordered]@{
                        scope = [ordered]@{ name = $script:LdoOtlpScopeName }
                        logRecords = @($logRecord)
                    }
                )
            }
        )
    }

    # Depth 20, not the 10 the flat record uses. The envelope alone is 7 levels deep before a
    # single attribute is added, and ConvertTo-Json silently replaces anything past its depth
    # limit with a type name string, producing a well-formed document no collector can read.
    if ($Format -eq 'OtlpIndented') {
        return ($payload | ConvertTo-Json -Depth 20)
    }

    return ($payload | ConvertTo-Json -Depth 20 -Compress)
}

Export-ModuleMember -Function `
    Write-LdoLog, `
    Set-LdoLogLevel, `
    Get-LdoLogLevel, `
    Set-LdoLogFormat, `
    Get-LdoLogFormat, `
    Set-LdoTraceContext, `
    Get-LdoTraceContext, `
    Clear-LdoTraceContext
