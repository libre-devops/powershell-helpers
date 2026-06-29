Set-StrictMode -Version Latest

function Install-LdoTrivy {
    <#
    .SYNOPSIS
        Installs the Trivy CLI.

    .DESCRIPTION
        Installs Trivy via Chocolatey on Windows or Homebrew on Linux and macOS, then verifies
        the trivy command is available.

    .EXAMPLE
        Install-LdoTrivy

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $os = Get-LdoOperatingSystem

    if ($os.ToLower() -eq 'windows') {
        Assert-LdoChocoPath
        Write-LdoLog -Level INFO -Message 'Installing Trivy via Chocolatey on Windows.'
        choco install trivy -y
    }
    else {
        Assert-LdoHomebrewPath
        Write-LdoLog -Level INFO -Message 'Installing Trivy via Homebrew.'
        brew install aquasecurity/trivy/trivy
    }

    Assert-LdoCommand -Name @('trivy')
    Write-LdoLog -Level SUCCESS -Message 'Trivy installed.'
}

function Invoke-LdoTrivy {
    <#
    .SYNOPSIS
        Runs a Trivy configuration scan against a folder.

    .DESCRIPTION
        Runs 'trivy config' over a code path, failing on findings at or above the chosen
        severity. Checks to skip are written to a temporary ignore file. Throws on findings
        unless -SoftFail is set.

    .PARAMETER CodePath
        Folder to scan.

    .PARAMETER TrivySkipChecks
        Check ids to ignore (written to a temporary .trivyignore file).

    .PARAMETER Severity
        Comma-separated severities that fail the scan. Defaults to HIGH,CRITICAL.

    .PARAMETER ExitCode
        Exit code Trivy returns when matching findings are present. Defaults to 1.

    .PARAMETER SoftFail
        When set, findings are logged as a warning instead of throwing.

    .PARAMETER ExtraArgs
        Additional arguments passed through to trivy.

    .EXAMPLE
        Invoke-LdoTrivy -CodePath ./terraform

    .EXAMPLE
        Invoke-LdoTrivy -CodePath ./terraform -Severity 'CRITICAL' -SoftFail

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string[]]$TrivySkipChecks = @(),
        [string]$Severity = 'HIGH,CRITICAL',
        [int]$ExitCode = 1,
        [switch]$SoftFail,
        [string[]]$ExtraArgs = @()
    )

    if (-not (Test-Path $CodePath)) {
        throw "Code path not found: $CodePath"
    }

    # 'trivy config' fails with the chosen exit code only for findings at or above -Severity.
    # --quiet keeps the progress bar and log noise out of the output (the report still prints).
    $trivyArgs = @('config', $CodePath, '--severity', $Severity, '--exit-code', "$ExitCode", '--quiet')

    $ignoreFile = $null
    try {
        if ($TrivySkipChecks.Count -gt 0) {
            # Specific check ids are skipped via a .trivyignore file; trivy no longer takes a
            # --skip-policy flag for this.
            $ignoreFile = New-TemporaryFile
            Set-Content -LiteralPath $ignoreFile -Value ($TrivySkipChecks -join "`n") -Encoding utf8
            $trivyArgs += @('--ignorefile', $ignoreFile.FullName)
        }

        $trivyArgs += $ExtraArgs

        Write-LdoLog -Level INFO -Message "Executing Trivy: trivy $($trivyArgs -join ' ')"

        & trivy @trivyArgs
        $code = $LASTEXITCODE

        if ($code -eq 0) {
            Write-LdoLog -Level SUCCESS -Message "Trivy completed with no findings at or above $Severity."
        }
        elseif ($SoftFail) {
            Write-LdoLog -Level WARN -Message "Trivy found issues (exit $code); continuing because -SoftFail."
        }
        else {
            throw "Trivy failed (exit $code)."
        }
    }
    finally {
        if ($ignoreFile -and (Test-Path $ignoreFile)) {
            Remove-Item $ignoreFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function `
    Invoke-LdoTrivy, `
    Install-LdoTrivy
