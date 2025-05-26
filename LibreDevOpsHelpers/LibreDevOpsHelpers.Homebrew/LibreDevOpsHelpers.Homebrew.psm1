function Assert-HomebrewPath {
    _LogMessage -Level "INFO" -Message "Ensuring Homebrew is available in the PATH..." -InvocationName $MyInvocation.MyCommand.Name

    # Check if 'brew' is already available in the current session
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        _LogMessage -Level "INFO" -Message "Homebrew is already available in the PATH. Skipping shellenv import." -InvocationName $MyInvocation.MyCommand.Name
        return
    }

    # Get the output of the shellenv command from Homebrew
    $brewShellEnv = & /home/linuxbrew/.linuxbrew/bin/brew shellenv
    if (-not $brewShellEnv) {
        _LogMessage -Level "ERROR" -Message "brew shellenv returned no output. Cannot update environment." -InvocationName $MyInvocation.MyCommand.Name
        exit 1
    }

    # Apply the environment changes using Invoke-Expression
    $brewShellEnvString = $brewShellEnv -join "`n"
    Invoke-Expression $brewShellEnvString

    # Re-check if brew is now available
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        _LogMessage -Level "INFO" -Message "Homebrew is now available in the PATH." -InvocationName $MyInvocation.MyCommand.Name
    }
    else {
        _LogMessage -Level "ERROR" -Message "Homebrew is still not available after applying shellenv." -InvocationName $MyInvocation.MyCommand.Name
        exit 1
    }
}

Export-ModuleMember -Function Assert-HomebrewPath


Export-ModuleMember -Function Assert-HomebrewPath
