Set-StrictMode -Version Latest

# Module-scoped minimum level. Messages below this are suppressed. DEBUG also
# respects $DebugPreference, so it stays hidden unless the caller opts in.
$script:LdoLogLevels = @{ DEBUG = 0; INFO = 1; SUCCESS = 1; WARN = 2; ERROR = 3 }

# Minimum level and output format. Both can be seeded from the environment so that
# operators can control logging in CI/CD without touching code, and both fall back to
# sensible defaults (show everything; structured JSON) when unset or invalid.
$script:LdoMinLogLevel = if ($env:LDO_LOG_LEVEL -and $script:LdoLogLevels.ContainsKey($env:LDO_LOG_LEVEL.ToUpperInvariant())) {
    $env:LDO_LOG_LEVEL.ToUpperInvariant()
}
else {
    'DEBUG'
}

$script:LdoLogFormat = switch -Regex ($env:LDO_LOG_FORMAT) {
    '^(?i)jsonindented$' { 'JsonIndented'; break }
    '^(?i)text$' { 'Text'; break }
    default { 'Json' }  # covers 'json', unset, and any unrecognised value
}

function Set-LdoLogLevel {
    <#
    .SYNOPSIS
        Sets the minimum level that Write-LdoLog will emit.

    .DESCRIPTION
        Messages below the configured level are dropped. The default is DEBUG, which
        shows everything (DEBUG still also requires $DebugPreference to be set, as it
        is routed through Write-Debug). The initial value can also be supplied via the
        LDO_LOG_LEVEL environment variable.

    .PARAMETER Level
        One of DEBUG, INFO, WARN, ERROR. SUCCESS is treated at the same threshold as
        INFO.

    .EXAMPLE
        Set-LdoLogLevel -Level WARN

        Suppresses DEBUG, INFO and SUCCESS messages, leaving only WARN and ERROR.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
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

function Write-LdoLog {
    <#
    .SYNOPSIS
        Writes a levelled, timestamped log message to the correct PowerShell stream.

    .DESCRIPTION
        The single logging entry point for all LibreDevOpsHelpers modules. By default
        each message is rendered as one compact JSON object (newline-delimited JSON)
        carrying a UTC ISO-8601 timestamp, level, invocation and message, plus any extra
        properties supplied via -Data. Pass -Format Text (or call Set-LdoLogFormat) for
        a human-readable coloured line instead.

        Each level is routed to a stream that never touches the success (output)
        pipeline, so the function is safe to call from inside other functions without
        corrupting their return values:

            DEBUG   -> Write-Debug        (shown when $DebugPreference is Continue)
            INFO    -> Write-Information  (information stream; coloured Write-Host in Text mode)
            SUCCESS -> Write-Information  (information stream; coloured Write-Host in Text mode)
            WARN    -> Write-Warning
            ERROR   -> Write-Error        (non-terminating; the caller decides whether to throw)

        Messages below the level set by Set-LdoLogLevel are suppressed.

    .PARAMETER Level
        Severity of the message. One of DEBUG, INFO, SUCCESS, WARN, ERROR.

    .PARAMETER Message
        The text to log.

    .PARAMETER InvocationName
        Name of the calling command, used as the JSON "invocation" field and the text
        prefix. Defaults to the immediate caller's command name when not supplied.

    .PARAMETER Data
        Optional hashtable of additional structured properties merged into the JSON
        record (for example correlation IDs or resource names). Ignored in Text mode.

    .PARAMETER Format
        Overrides the module default output format for this call only. Json (compact),
        JsonIndented (pretty-printed, for local debugging), or Text.

    .EXAMPLE
        Write-LdoLog -Level INFO -Message 'Starting deployment'

    .EXAMPLE
        Write-LdoLog -Level ERROR -Message "Failed: $($_.Exception.Message)"

    .EXAMPLE
        Write-LdoLog -Level INFO -Message 'Created resource group' -Data @{ resourceGroup = 'rg-prod'; correlationId = $cid }
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'SUCCESS', 'WARN', 'ERROR')]
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
        # an unambiguous, timezone-correct timestamp.
        $record = [ordered]@{
            timestamp = $now.ToUniversalTime().ToString('o')
            level = $Level
            invocation = $InvocationName
            message = $Message
        }
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
        'DEBUG' { Write-Debug $line }
        'INFO' { Write-LdoInfoLine -Line $line -Level $Level -Format $Format -Color Cyan }
        'SUCCESS' { Write-LdoInfoLine -Line $line -Level $Level -Format $Format -Color Green }
        'WARN' { Write-Warning $line }
        # Explicitly non-terminating: logging an error must never throw on its own,
        # even when the caller has $ErrorActionPreference = 'Stop'. The caller decides
        # whether to throw.
        'ERROR' { Write-Error $line -ErrorAction Continue }
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

Export-ModuleMember -Function Write-LdoLog, Set-LdoLogLevel, Get-LdoLogLevel, Set-LdoLogFormat, Get-LdoLogFormat
