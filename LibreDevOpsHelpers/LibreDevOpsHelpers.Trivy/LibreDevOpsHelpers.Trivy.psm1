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
        severity. Throws on findings unless -SoftFail is set.

        Exceptions are sourced, in order of precedence: an explicit -IgnoreFile; a committed
        ignore file in the code path (.trivyignore.yaml, .trivyignore.yml, or .trivyignore); or
        a temporary file built from -TrivySkipChecks. A committed .trivyignore.yaml is the Libre
        DevOps convention, since it records the id, the affected paths, and a statement (the
        justification) for each waiver. Trivy does not auto-discover .trivyignore.yaml, so the
        resolved path is always passed with --ignorefile.

    .PARAMETER CodePath
        Folder to scan. A .trivyignore.yaml (or .yml / .trivyignore) in this folder is picked
        up automatically.

    .PARAMETER TrivySkipChecks
        Check ids to ignore, written to a temporary ignore file. Used only when neither
        -IgnoreFile nor a committed ignore file is present; otherwise it is logged and ignored.

    .PARAMETER IgnoreFile
        Explicit path to a Trivy ignore file. Overrides the committed-file auto-detection.

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
        [string]$IgnoreFile = '',
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

    $tempIgnore = $null
    try {
        # Resolve the ignore file: explicit -IgnoreFile, then a committed file in the code path,
        # then a temporary file built from -TrivySkipChecks. Trivy does not auto-discover
        # .trivyignore.yaml, so whatever is resolved is passed explicitly with --ignorefile.
        $resolvedIgnore = $null
        if ($IgnoreFile) {
            if (-not (Test-Path $IgnoreFile)) {
                throw "Trivy ignore file not found: $IgnoreFile"
            }
            $resolvedIgnore = (Resolve-Path -LiteralPath $IgnoreFile).Path
        }
        else {
            foreach ($candidate in @('.trivyignore.yaml', '.trivyignore.yml', '.trivyignore')) {
                $candidatePath = Join-Path $CodePath $candidate
                if (Test-Path $candidatePath) {
                    $resolvedIgnore = (Resolve-Path -LiteralPath $candidatePath).Path
                    Write-LdoLog -Level INFO -Message "Using committed Trivy ignore file: $resolvedIgnore"
                    break
                }
            }
        }

        # Wrap in @() so a $null (which a splatted empty array binds to) is treated as empty
        # rather than tripping .Count under Set-StrictMode.
        if (@($TrivySkipChecks).Count -gt 0) {
            if ($resolvedIgnore) {
                Write-LdoLog -Level WARN -Message "Ignoring -TrivySkipChecks because an ignore file is in effect ($resolvedIgnore)."
            }
            else {
                $tempIgnore = New-TemporaryFile
                Set-Content -LiteralPath $tempIgnore -Value ($TrivySkipChecks -join "`n") -Encoding utf8
                $resolvedIgnore = $tempIgnore.FullName
            }
        }

        if ($resolvedIgnore) {
            $trivyArgs += @('--ignorefile', $resolvedIgnore)
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
        if ($tempIgnore -and (Test-Path $tempIgnore)) {
            Remove-Item $tempIgnore -Force -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function `
    Invoke-LdoTrivy, `
    Install-LdoTrivy
