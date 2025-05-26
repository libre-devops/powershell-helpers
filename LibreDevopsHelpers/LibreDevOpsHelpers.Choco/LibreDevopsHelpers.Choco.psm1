function Assert-ChocoPath
{
    [CmdletBinding()]
    param()

    _LogMessage -Level 'INFO' -Message 'Ensuring Chocolatey is available in the PATH…' -InvocationName $MyInvocation.MyCommand.Name

    # Bail out quietly on non-Windows hosts
    if (-not $IsWindows)
    {
        _LogMessage -Level 'WARN' -Message 'Chocolatey check skipped – current OS is not Windows.' -InvocationName $MyInvocation.MyCommand.Name
        return
    }

    # ── 1. Check if "choco" is already on PATH ───────────────────────────────
    $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue

    # ── 2. Fallback to the default install location ──────────────────────────
    if (-not $chocoCmd)
    {
        $defaultExe = 'C:\ProgramData\Chocolatey\bin\choco.exe'
        if (Test-Path $defaultExe)
        {
            $chocoCmd = Get-Command -LiteralPath $defaultExe -CommandType Application

            # Add the directory to the *process* PATH for this session
            $chocoBin = Split-Path $defaultExe -Parent
            if ($env:PATH -notmatch [regex]::Escape($chocoBin))
            {
                _LogMessage -Level 'DEBUG' -Message "Temporarily adding '$chocoBin' to PATH (process scope)." -InvocationName $MyInvocation.MyCommand.Name
                $env:PATH = "$env:PATH;$chocoBin"
            }
        }
    }

    # ── 3. Final verification ────────────────────────────────────────────────
    if ($chocoCmd)
    {
        _LogMessage -Level 'INFO' -Message "Chocolatey found at: $( $chocoCmd.Source )" -InvocationName $MyInvocation.MyCommand.Name
    }
    else
    {
        _LogMessage -Level 'ERROR' -Message 'Chocolatey is not installed or not in PATH.' -InvocationName $MyInvocation.MyCommand.Name
        throw 'Chocolatey executable not found.'
    }
}

Export-ModuleMember -Function Assert-ChocoPath

