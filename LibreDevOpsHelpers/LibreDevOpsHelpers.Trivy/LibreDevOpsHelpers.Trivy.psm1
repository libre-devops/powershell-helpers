Set-StrictMode -Version Latest

function Install-LdoTrivy {
    <#
    .SYNOPSIS
        Installs the Trivy CLI.

    .DESCRIPTION
        Installs Trivy with Chocolatey on Windows. On Linux and macOS it downloads the official
        release binary from GitHub (the version defaults to 'latest', resolved at runtime), which is
        far more reliable on ephemeral CI runners than the Homebrew tap (a brew install can break the
        pipe mid-download). A specific version can be requested.

    .PARAMETER Version
        Trivy version to install: 'latest' (default) or a specific tag like '0.69.3' / 'v0.69.3'.

    .EXAMPLE
        Install-LdoTrivy

    .EXAMPLE
        Install-LdoTrivy -Version 0.69.3

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Version = 'latest'
    )

    $os = (Get-LdoOperatingSystem).ToLower()

    if ($os -eq 'windows') {
        Assert-LdoChocoPath
        Write-LdoLog -Level INFO -Message 'Installing Trivy via Chocolatey on Windows.'
        choco install trivy -y
        Assert-LdoCommand -Name @('trivy')
        Write-LdoLog -Level SUCCESS -Message 'Trivy installed.'
        return
    }

    # Resolve 'latest' to a concrete tag by following the releases/latest redirect (no API token,
    # no rate-limit concern). curl is run through bash because in PowerShell "curl" is an alias.
    if ($Version -eq 'latest') {
        $effectiveUrl = (bash -c "curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/aquasecurity/trivy/releases/latest").Trim()
        Assert-LdoLastExitCode -Operation 'resolve latest trivy release'
        $tag = ($effectiveUrl.TrimEnd('/') -split '/')[-1]
    }
    else {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    }
    $bareVersion = $tag.TrimStart('v')

    # Trivy assets are named like trivy_0.69.3_Linux-64bit.tar.gz / Linux-ARM64 / macOS-64bit.
    $platform = if ($os -eq 'macos') { 'macOS' } else { 'Linux' }
    $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'ARM64' } else { '64bit' }
    $url = "https://github.com/aquasecurity/trivy/releases/download/$tag/trivy_${bareVersion}_${platform}-${arch}.tar.gz"

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-trivy-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        Write-LdoLog -Level INFO -Message "Downloading Trivy $tag from $url"
        $tar = Join-Path $work 'trivy.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $tar
        & tar -xzf $tar -C $work
        Assert-LdoLastExitCode -Operation 'extract trivy archive'

        $binary = Join-Path $work 'trivy'
        & chmod '+x' $binary
        $dest = '/usr/local/bin/trivy'
        try {
            Move-Item -Path $binary -Destination $dest -Force -ErrorAction Stop
        }
        catch {
            bash -c "sudo mv '$binary' '$dest'"
            Assert-LdoLastExitCode -Operation 'install trivy to /usr/local/bin'
        }
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    Assert-LdoCommand -Name @('trivy')
    Write-LdoLog -Level SUCCESS -Message "Trivy $tag installed."
}

function Invoke-LdoTrivy {
    <#
    .SYNOPSIS
        Runs a Trivy configuration scan against a folder.

    .DESCRIPTION
        Runs 'trivy config' over a code path in two passes: a report pass that lists findings at
        every -DisplaySeverity (so MEDIUM/LOW stay visible) and never fails, then a gate pass that
        throws only on findings at the -Severity levels. Use -SoftFail to warn instead of throw.

        Exceptions are sourced, in order of precedence: an explicit -IgnoreFile; a committed
        ignore file (.trivyignore.yaml, .trivyignore.yml, or .trivyignore) found by walking up
        from the code path to the enclosing git repository root, nearest file first; or a
        temporary file built from -TrivySkipChecks. A committed .trivyignore.yaml is the Libre
        DevOps convention, since it records the id, the affected paths, and a statement (the
        justification) for each waiver, and the walk-up means a repo-root file covers every
        stack folder scanned individually (examples/complete and friends). Trivy does not
        auto-discover .trivyignore.yaml, so the resolved path is always passed with --ignorefile.

        Note on scoping waivers with paths: Trivy reports a finding raised inside a downloaded
        module (.terraform/modules) under the module's source address plus the path relative to
        the scan target, so literal repo-relative paths do not match; use a doublestar glob like
        "**/.terraform/modules/key_vault/main.tf" instead.

    .PARAMETER CodePath
        Folder to scan. A .trivyignore.yaml (or .yml / .trivyignore) in this folder, or in any
        parent up to the git repository root, is picked up automatically (nearest wins). Without
        a git root, only this folder is searched.

    .PARAMETER TrivySkipChecks
        Check ids to ignore, written to a temporary ignore file. Used only when neither
        -IgnoreFile nor a committed ignore file is present; otherwise it is logged and ignored.

    .PARAMETER IgnoreFile
        Explicit path to a Trivy ignore file. Overrides the committed-file auto-detection.

    .PARAMETER Severity
        Comma-separated severities that fail (gate) the scan. Defaults to HIGH,CRITICAL.

    .PARAMETER DisplaySeverity
        Comma-separated severities listed in the report pass, regardless of what gates the build.
        Defaults to CRITICAL,HIGH,MEDIUM,LOW so lower-severity findings stay visible. (Trivy has no
        INFO level; its scale is UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL.)

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
        [string]$DisplaySeverity = 'CRITICAL,HIGH,MEDIUM,LOW',
        [int]$ExitCode = 1,
        [switch]$SoftFail,
        [string[]]$ExtraArgs = @()
    )

    if (-not (Test-Path $CodePath)) {
        throw "Code path not found: $CodePath"
    }

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
            # Find the enclosing git repository root; without one, only the code path itself is
            # searched (never the whole filesystem), so a stray ignore file outside the repo can
            # never silently waive findings.
            $resolvedCodePath = (Resolve-Path -LiteralPath $CodePath).Path
            $boundary = $null
            $probeDir = $resolvedCodePath
            while ($probeDir) {
                if (Test-Path (Join-Path $probeDir '.git')) { $boundary = $probeDir; break }
                $parent = Split-Path -Path $probeDir -Parent
                if (-not $parent -or $parent -eq $probeDir) { break }
                $probeDir = $parent
            }
            if (-not $boundary) { $boundary = $resolvedCodePath }

            # Walk from the code path up to the repo root: the nearest committed ignore file wins,
            # so a repo-root .trivyignore.yaml covers every stack folder (examples/complete and
            # friends) without per-stack copies, and a stack-local file can still override it.
            $searchDir = $resolvedCodePath
            while ($searchDir) {
                foreach ($candidate in @('.trivyignore.yaml', '.trivyignore.yml', '.trivyignore')) {
                    $candidatePath = Join-Path $searchDir $candidate
                    if (Test-Path $candidatePath) {
                        $resolvedIgnore = (Resolve-Path -LiteralPath $candidatePath).Path
                        Write-LdoLog -Level INFO -Message "Using committed Trivy ignore file: $resolvedIgnore"
                        break
                    }
                }
                if ($resolvedIgnore -or $searchDir -eq $boundary) { break }
                $parent = Split-Path -Path $searchDir -Parent
                if (-not $parent -or $parent -eq $searchDir) { break }
                $searchDir = $parent
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

        $baseArgs = @('config', $CodePath)
        if ($resolvedIgnore) {
            $baseArgs += @('--ignorefile', $resolvedIgnore)
        }
        $baseArgs += $ExtraArgs

        # Two passes. The first reports findings at every -DisplaySeverity so MEDIUM/LOW are
        # visible (and never fails: --exit-code 0). The second gates the build, returning a
        # non-zero exit code only for findings at the -Severity levels; its output is discarded
        # because the report above already showed everything. --quiet keeps the progress noise out.
        Write-LdoLog -Level INFO -Message "Trivy report (display $DisplaySeverity): trivy $($baseArgs -join ' ')"
        # Capture the report so it can be re-shown in the end-of-run findings summary, and print it.
        $report = & trivy @baseArgs --severity $DisplaySeverity --exit-code 0 --quiet 2>&1
        $reportText = (($report | Out-String) -replace '\x1b\[[0-9;]*m', '').TrimEnd()
        Write-Host $reportText

        & trivy @baseArgs --severity $Severity --exit-code "$ExitCode" --quiet *> $null
        $code = $LASTEXITCODE

        if ($code -eq 0) {
            Write-LdoLog -Level SUCCESS -Message "Trivy completed with no findings at or above $Severity (lower-severity findings, if any, are listed above)."
            Add-LdoFinding -Tool 'trivy' -Target $CodePath -Status 'PASS' -Summary "no findings at or above $Severity" -Detail $reportText
        }
        elseif ($SoftFail) {
            Write-LdoLog -Level WARN -Message "Trivy found $Severity issues (exit $code); continuing because -SoftFail."
            Add-LdoFinding -Tool 'trivy' -Target $CodePath -Status 'WARN' -Summary "$Severity findings (soft-fail, exit $code)" -Detail $reportText
        }
        else {
            Add-LdoFinding -Tool 'trivy' -Target $CodePath -Status 'FAIL' -Summary "$Severity findings (exit $code)" -Detail $reportText
            throw "Trivy failed on $Severity findings (exit $code)."
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
