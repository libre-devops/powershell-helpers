Set-StrictMode -Version Latest

function Assert-LdoChocoPath {
    <#
    .SYNOPSIS
        Ensures the Chocolatey CLI is available on PATH.

    .DESCRIPTION
        Confirms choco is on PATH. If it is not, the default install location is checked and, if
        present, added to the process PATH for the current session. Throws when Chocolatey cannot
        be located. On non-Windows hosts the check is skipped with a warning.

    .EXAMPLE
        Assert-LdoChocoPath

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Write-LdoLog -Level INFO -Message 'Ensuring Chocolatey is available on PATH.'

    if (-not $IsWindows) {
        Write-LdoLog -Level WARN -Message 'Chocolatey check skipped; current OS is not Windows.'
        return
    }

    $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue

    if (-not $chocoCmd) {
        $defaultExe = 'C:\ProgramData\Chocolatey\bin\choco.exe'
        if (Test-Path $defaultExe) {
            $chocoCmd = Get-Command -LiteralPath $defaultExe -CommandType Application
            $chocoBin = Split-Path $defaultExe -Parent
            if ($env:PATH -notmatch [regex]::Escape($chocoBin)) {
                Write-LdoLog -Level DEBUG -Message "Temporarily adding '$chocoBin' to PATH (process scope)."
                $env:PATH = "$env:PATH;$chocoBin"
            }
        }
    }

    if (-not $chocoCmd) {
        throw 'Chocolatey executable not found.'
    }

    Write-LdoLog -Level INFO -Message "Chocolatey found at: $($chocoCmd.Source)"
}

Export-ModuleMember -Function Assert-LdoChocoPath
