Set-StrictMode -Version Latest

# Module-scoped minimum level. Messages below this are suppressed. DEBUG also
# respects $DebugPreference, so it stays hidden unless the caller opts in.
$script:LdoLogLevels = @{ DEBUG = 0; INFO = 1; SUCCESS = 1; WARN = 2; ERROR = 3 }
$script:LdoMinLogLevel = 'DEBUG'

function Set-LdoLogLevel {
    <#
    .SYNOPSIS
        Sets the minimum level that Write-LdoLog will emit.

    .DESCRIPTION
        Messages below the configured level are dropped. The default is DEBUG, which
        shows everything (DEBUG still also requires $DebugPreference to be set, as it
        is routed through Write-Debug).

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

function Write-LdoLog {
    <#
    .SYNOPSIS
        Writes a levelled, timestamped log message to the correct PowerShell stream.

    .DESCRIPTION
        The single logging entry point for all LibreDevOpsHelpers modules. Each level
        is routed to a stream that never touches the success (output) pipeline, so the
        function is safe to call from inside other functions without corrupting their
        return values.

            DEBUG   -> Write-Debug    (shown when $DebugPreference is Continue)
            INFO    -> Write-Host      (information stream, cyan)
            SUCCESS -> Write-Host      (information stream, green)
            WARN    -> Write-Warning
            ERROR   -> Write-Error     (non-terminating; the caller decides whether to throw)

        Messages below the level set by Set-LdoLogLevel are suppressed.

    .PARAMETER Level
        Severity of the message. One of DEBUG, INFO, SUCCESS, WARN, ERROR.

    .PARAMETER Message
        The text to log.

    .PARAMETER InvocationName
        Name of the calling command, used as a prefix. Defaults to the immediate
        caller's command name when not supplied.

    .EXAMPLE
        Write-LdoLog -Level INFO -Message 'Starting deployment'

    .EXAMPLE
        Write-LdoLog -Level ERROR -Message "Failed: $($_.Exception.Message)"
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

        [string]$InvocationName
    )

    if (-not $InvocationName) {
        $caller = (Get-PSCallStack)[1]
        $InvocationName = if ($caller -and $caller.Command) { $caller.Command } else { '<script>' }
    }

    if ($script:LdoLogLevels[$Level] -lt $script:LdoLogLevels[$script:LdoMinLogLevel]) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "{0} [{1}] [{2}] {3}" -f $timestamp, $Level, $InvocationName, $Message

    switch ($Level) {
        'DEBUG' { Write-Debug   $line }
        'INFO' { Write-Host    $line -ForegroundColor Cyan }
        'SUCCESS' { Write-Host    $line -ForegroundColor Green }
        'WARN' { Write-Warning $line }
        # Explicitly non-terminating: logging an error must never throw on its own,
        # even when the caller has $ErrorActionPreference = 'Stop'. The caller decides
        # whether to throw.
        'ERROR' { Write-Error   $line -ErrorAction Continue }
    }
}

# Transition shim. Modules not yet migrated still call _LogMessage; it forwards to
# Write-LdoLog so the repo keeps working during the module-by-module upgrade. Removed
# once every module has been migrated.
function _LogMessage {
    [CmdletBinding()]
    param(
        [string]$Level,
        [string]$Message,
        [string]$InvocationName
    )

    $mapped = switch ($Level.ToUpper()) {
        'DEBUG' { 'DEBUG' }
        'INFO' { 'INFO' }
        'WARN' { 'WARN' }
        'ERROR' { 'ERROR' }
        default { 'INFO' }
    }

    if (-not $InvocationName) { $InvocationName = (Get-PSCallStack)[1].Command }
    Write-LdoLog -Level $mapped -Message $Message -InvocationName $InvocationName
}

Export-ModuleMember -Function Write-LdoLog, Set-LdoLogLevel, _LogMessage
