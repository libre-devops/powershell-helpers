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
# sensible defaults (INFO floor; structured JSON) when unset or invalid.
$script:LdoMinLogLevel = if ($env:LDO_LOG_LEVEL -and $script:LdoLogLevels.ContainsKey($env:LDO_LOG_LEVEL.ToUpperInvariant())) {
    $env:LDO_LOG_LEVEL.ToUpperInvariant()
}
else {
    'INFO'
}

$script:LdoLogFormat = switch -Regex ($env:LDO_LOG_FORMAT) {
    '^(?i)jsonindented$' { 'JsonIndented'; break }
    '^(?i)text$' { 'Text'; break }
    default { 'Json' }  # covers 'json', unset, and any unrecognised value
}

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
        own -Format. The default is Json, which emits one compact JSON object per line
        (newline-delimited JSON) suitable for ingestion by log aggregators such as
        Splunk, Elasticsearch or Azure Monitor. Text emits a human-readable, coloured
        line for interactive CLI use. The initial value can also be supplied via the
        LDO_LOG_FORMAT environment variable.

    .PARAMETER Format
        Json (compact, one object per line), JsonIndented (pretty-printed, for local
        debugging only - not newline-delimited), or Text.

    .EXAMPLE
        Set-LdoLogFormat -Format Text

        Switches subsequent log output to the human-readable coloured format.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Json', 'JsonIndented', 'Text')]
        [string]$Format
    )

    $script:LdoLogFormat = $Format
}

function Get-LdoLogFormat {
    <#
    .SYNOPSIS
        Returns the current default output format (Json or Text).
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
        Sets the trace_id, span_id and correlation_id that Write-LdoLog adds to each JSON
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
        message is rendered as one compact JSON object (newline-delimited JSON) aligned to the
        OpenTelemetry log data model: a UTC ISO-8601 timestamp, level, severity_number, message,
        service.name, and the trace_id / span_id / correlation_id from the ambient trace context
        when set (see Set-LdoTraceContext). The lean "invocation" field is kept as an extra
        attribute. Additional fields can be merged via -Data. Pass -Format Text (or call
        Set-LdoLogFormat) for a human-readable coloured line instead.

        service.name defaults to the LDO_SERVICE_NAME environment variable, falling back to the
        invocation name when unset; service.version (LDO_SERVICE_VERSION) and
        deployment.environment (LDO_DEPLOYMENT_ENVIRONMENT) are added when their environment
        variables are set.

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
        Optional hashtable of additional structured properties merged into the JSON
        record (for example resource names or durations). Ignored in Text mode.

    .PARAMETER Format
        Overrides the module default output format for this call only. Json (compact),
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

        [ValidateSet('Json', 'JsonIndented', 'Text')]
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

Export-ModuleMember -Function `
    Write-LdoLog, `
    Set-LdoLogLevel, `
    Get-LdoLogLevel, `
    Set-LdoLogFormat, `
    Get-LdoLogFormat, `
    Set-LdoTraceContext, `
    Get-LdoTraceContext, `
    Clear-LdoTraceContext
