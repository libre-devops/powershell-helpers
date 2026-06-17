Set-StrictMode -Version Latest

function Assert-LdoHomebrewPath {
    <#
    .SYNOPSIS
        Ensures the Homebrew CLI is available on PATH.

    .DESCRIPTION
        Confirms brew is on PATH. If it is not, the well-known Homebrew install locations are
        checked and the first one found is added to the process PATH for the current session.
        Throws when Homebrew cannot be located.

    .EXAMPLE
        Assert-LdoHomebrewPath

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Write-LdoLog -Level INFO -Message 'Ensuring Homebrew is available on PATH.'

    if (Get-Command brew -ErrorAction SilentlyContinue) {
        Write-LdoLog -Level INFO -Message 'Homebrew is already available on PATH.'
        return
    }

    $candidates = @(
        '/home/linuxbrew/.linuxbrew/bin/brew',
        '/opt/homebrew/bin/brew',
        '/usr/local/bin/brew'
    )

    $brewExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $brewExe) {
        throw 'Homebrew executable not found in any known location.'
    }

    $brewBin = Split-Path $brewExe -Parent
    if ($env:PATH -notmatch [regex]::Escape($brewBin)) {
        Write-LdoLog -Level DEBUG -Message "Temporarily adding '$brewBin' to PATH (process scope)."
        $env:PATH = "${brewBin}:$env:PATH"
    }

    if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
        throw 'Homebrew is still not available after updating PATH.'
    }

    Write-LdoLog -Level INFO -Message "Homebrew found at: $brewExe"
}

Export-ModuleMember -Function Assert-LdoHomebrewPath
