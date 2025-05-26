# Logger.psm1  (or wherever your helper lives)
function _LogMessage
{
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level,
        [string] $Message,
        [string] $InvocationName
    )

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $prefix = "$timestamp - [$InvocationName]"

    switch ( $Level.ToUpper())
    {
        'DEBUG' {
            # Only shows when $DebugPreference -eq 'Continue'
            Write-Debug "$prefix $Message"
        }
        'INFO' {
            Write-Host  "INFO : $prefix $Message"  -ForegroundColor Green
        }
        'WARN' {
            Write-Warning              "$prefix $Message"
        }
        'ERROR' {
            Write-Error                "$prefix $Message"
        }
    }
}

Export-ModuleMember -Function _LogMessage
