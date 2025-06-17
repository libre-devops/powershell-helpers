function Invoke-InstallTrivy {
    [CmdletBinding()]
    param()

    $inv = $MyInvocation.MyCommand.Name
    $os = Assert-WhichOs -PassThru

    if ($os.ToLower() -eq 'windows') {
        _LogMessage -Level INFO -Message "Installing Trivy via Chocolatey on Windows…" -InvocationName $inv
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            choco install trivy -y
        }
        else {
            _LogMessage -Level ERROR -Message "Chocolatey not found; cannot install Trivy." -InvocationName $inv
            throw "Cannot install Trivy: Chocolatey missing."
        }
    }
    elseif ($os.ToLower() -eq 'linux' -or $os.ToLower() -eq 'macos') {
        Assert-HomebrewPath
        _LogMessage -Level INFO -Message "Installing Trivy via Homebrew…" -InvocationName $inv
        brew install aquasecurity/trivy/trivy
    }
    else {
        _LogMessage -Level ERROR -Message "Unsupported OS for Trivy install: $os" -InvocationName $inv
        throw "Unsupported OS: $os"
    }

    Get-InstalledPrograms -Programs @('trivy')
}

function Invoke-Trivy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CodePath,
        [string[]] $TrivySkipChecks = @(),
        [switch]  $SoftFail,
        [string[]] $ExtraArgs = @()
    )

    $inv = $MyInvocation.MyCommand.Name

    if (-not (Test-Path $CodePath)) {
        _LogMessage -Level 'ERROR' -Message "Terraform code path not found: $CodePath" -InvocationName $inv
        throw "Code path not found: $CodePath"
    }

    $trivyArgs = @('config', $CodePath, '--no-progress')

    if ($TrivySkipChecks.Count -gt 0) {
        $trivyArgs += '--skip-policy' + ($TrivySkipChecks -join ',')
    }

    $trivyArgs += $ExtraArgs

    _LogMessage -Level 'INFO' -Message "Executing Trivy: trivy $( $trivyArgs -join ' ' )" -InvocationName $inv

    & trivy @trivyArgs
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        _LogMessage -Level 'INFO' -Message 'Trivy completed with no failed checks.' -InvocationName $inv
    }
    elseif ($SoftFail) {
        _LogMessage -Level 'WARN' -Message "Trivy found issues (exit $code) – continuing because -SoftFail." -InvocationName $inv
    }
    else {
        _LogMessage -Level 'ERROR' -Message "Trivy reported failures (exit $code)." -InvocationName $inv
        throw "Trivy failed (exit $code)."
    }
}

Export-ModuleMember -Function `
    Invoke-Trivy, `
    Invoke-InstallTrivy
