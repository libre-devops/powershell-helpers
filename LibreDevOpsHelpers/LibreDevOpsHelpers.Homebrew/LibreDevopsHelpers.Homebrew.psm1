function Assert-HomebrewPath {
    _LogMessage -Level "INFO" -Message "Ensuring Homebrew is available in the PATH..." -InvocationName "$( $MyInvocation.MyCommand.Name )"

    # Get the output of the shellenv command from Homebrew
    $brewShellEnv = & /home/linuxbrew/.linuxbrew/bin/brew shellenv
    $brewShellEnvString = $brewShellEnv -join "`n"

    # Apply the environment changes using Invoke-Expression
    Invoke-Expression $brewShellEnvString

    # Test if brew is now available in the session
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        _LogMessage -Level "INFO" -Message  "Homebrew is now available in the PATH." -InvocationName "$( $MyInvocation.MyCommand.Name )"
    } else {
        _LogMessage -Level "ERROR" -Message "Homebrew is not available. Something went wrong." -InvocationName "$( $MyInvocation.MyCommand.Name )"
        exit 1
    }
}

Export-ModuleMember -Function Assert-HomebrewPath
