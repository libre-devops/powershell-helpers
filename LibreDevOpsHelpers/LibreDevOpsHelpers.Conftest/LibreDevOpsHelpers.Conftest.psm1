Set-StrictMode -Version Latest

function Install-LdoConftest {
    <#
    .SYNOPSIS
        Installs the Conftest CLI.

    .DESCRIPTION
        Downloads the official Conftest release binary from GitHub. The version defaults to
        'latest' and is resolved at runtime (no hard-pinned version to maintain); a specific
        version can be requested. On Linux and macOS the binary is installed to /usr/local/bin;
        on Windows it is extracted to a per-user directory which is added to the current session's
        PATH.

    .PARAMETER Version
        Conftest version to install: 'latest' (default) or a specific tag like '0.62.0' / 'v0.62.0'.

    .EXAMPLE
        Install-LdoConftest

    .EXAMPLE
        Install-LdoConftest -Version 0.62.0

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Version = 'latest'
    )

    $os = (Get-LdoOperatingSystem).ToLower()

    # Resolve 'latest' to a concrete tag by following the releases/latest redirect (no API token,
    # no rate-limit concern). curl is run through bash because in PowerShell "curl" is an alias.
    if ($Version -eq 'latest') {
        $effectiveUrl = (bash -c "curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/open-policy-agent/conftest/releases/latest").Trim()
        Assert-LdoLastExitCode -Operation 'resolve latest conftest release'
        $tag = ($effectiveUrl.TrimEnd('/') -split '/')[-1]
    }
    else {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    }
    # Conftest release asset names use the version without the leading 'v'.
    $verNum = $tag.TrimStart('v')

    # Conftest asset naming: OS is Linux/Darwin/Windows, arch is x86_64/arm64.
    $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'x86_64' }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-conftest-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        if ($os -eq 'windows') {
            $url = "https://github.com/open-policy-agent/conftest/releases/download/$tag/conftest_${verNum}_Windows_${arch}.zip"
            Write-LdoLog -Level INFO -Message "Downloading Conftest $tag from $url"
            $archive = Join-Path $work 'conftest.zip'
            Invoke-WebRequest -Uri $url -OutFile $archive
            Expand-Archive -Path $archive -DestinationPath $work -Force

            $dir = Join-Path $env:LOCALAPPDATA 'Programs\conftest'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Move-Item -Path (Join-Path $work 'conftest.exe') -Destination (Join-Path $dir 'conftest.exe') -Force
            if (($env:PATH -split ';') -notcontains $dir) {
                $env:PATH = "$dir;$env:PATH"
            }
            Write-LdoLog -Level INFO -Message "Conftest installed to $dir (added to PATH for this session; add it permanently to use it in new shells)."
        }
        else {
            $platform = if ($os -eq 'macos') { 'Darwin' } else { 'Linux' }
            $url = "https://github.com/open-policy-agent/conftest/releases/download/$tag/conftest_${verNum}_${platform}_${arch}.tar.gz"
            Write-LdoLog -Level INFO -Message "Downloading Conftest $tag from $url"
            $archive = Join-Path $work 'conftest.tar.gz'
            Invoke-WebRequest -Uri $url -OutFile $archive
            & tar -xzf $archive -C $work conftest
            Assert-LdoLastExitCode -Operation 'extract conftest'

            $binary = Join-Path $work 'conftest'
            & chmod '+x' $binary
            $dest = '/usr/local/bin/conftest'
            try {
                Move-Item -Path $binary -Destination $dest -Force -ErrorAction Stop
            }
            catch {
                bash -c "sudo mv '$binary' '$dest'"
                Assert-LdoLastExitCode -Operation 'install conftest to /usr/local/bin'
            }
        }
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    Assert-LdoCommand -Name @('conftest')
    Write-LdoLog -Level SUCCESS -Message "Conftest $tag installed."
}

function Assert-LdoConftest {
    <#
    .SYNOPSIS
        Asserts that the Conftest CLI is available on PATH.

    .DESCRIPTION
        Throws a clear error when conftest is not installed, pointing at Install-LdoConftest.

    .EXAMPLE
        Assert-LdoConftest

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (-not (Get-Command conftest -ErrorAction SilentlyContinue)) {
        throw 'Conftest is not installed or not on PATH. Run Install-LdoConftest first.'
    }
}

function Invoke-LdoConftest {
    <#
    .SYNOPSIS
        Runs Conftest policies against a Terraform plan rendered to JSON.

    .DESCRIPTION
        Runs 'conftest test' over a Terraform plan JSON (produced by
        'terraform show -json plan.bin') using the Rego policies under -PolicyPath. Conftest 'deny'
        rules fail the run; 'warn' rules are informational and do not fail unless -FailOnWarn is
        set (the Libre DevOps naming checks are warn rules). Throws on a failing run unless
        -SoftFail is set.

    .PARAMETER PlanJsonPath
        Path to the Terraform plan rendered to JSON.

    .PARAMETER PolicyPath
        Path to the directory of Rego policies.

    .PARAMETER AllNamespaces
        Evaluate every policy namespace. Defaults to true. Ignored when -Namespace is supplied.

    .PARAMETER Namespace
        One or more specific policy namespaces to evaluate (instead of all).

    .PARAMETER FailOnWarn
        When set, 'warn' findings also fail the run. Off by default so naming checks stay
        informational.

    .PARAMETER SoftFail
        When set, a failing run is logged as a warning instead of throwing.

    .PARAMETER ExtraArgs
        Additional arguments passed through to conftest.

    .EXAMPLE
        Invoke-LdoConftest -PlanJsonPath ./plan.json -PolicyPath ./policies

    .EXAMPLE
        Invoke-LdoConftest -PlanJsonPath ./plan.json -PolicyPath ./policies -FailOnWarn

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanJsonPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PolicyPath,
        [bool]$AllNamespaces = $true,
        [string[]]$Namespace = @(),
        [switch]$FailOnWarn,
        [switch]$SoftFail,
        [string[]]$ExtraArgs = @()
    )

    # Validate the provided paths first (deterministic, no external dependency), then assert the
    # CLI is present, so argument errors are reported clearly even when conftest is not installed.
    if (-not (Test-Path $PlanJsonPath)) {
        throw "Plan JSON not found: $PlanJsonPath"
    }
    if (-not (Test-Path $PolicyPath)) {
        throw "Policy path not found: $PolicyPath"
    }

    Assert-LdoConftest

    $conftestArgs = @('test', $PlanJsonPath, '--policy', $PolicyPath)

    # Wrap in @() so a $null (which a splatted empty array binds to) is treated as empty rather
    # than tripping .Count under Set-StrictMode.
    if (@($Namespace).Count -gt 0) {
        foreach ($ns in $Namespace) {
            $conftestArgs += @('--namespace', $ns)
        }
    }
    elseif ($AllNamespaces) {
        $conftestArgs += '--all-namespaces'
    }

    if ($FailOnWarn) {
        $conftestArgs += '--fail-on-warn'
    }

    $conftestArgs += $ExtraArgs

    Write-LdoLog -Level INFO -Message "Executing Conftest: conftest $($conftestArgs -join ' ')"

    # Capture the output so it can be re-shown in the end-of-run findings summary, and print it.
    # Strip ANSI colour codes so the stored text is clean and matches reliably.
    $report = & conftest @conftestArgs 2>&1
    $code = $LASTEXITCODE
    $reportText = (($report | Out-String) -replace '\x1b\[[0-9;]*m', '').TrimEnd()
    Write-Host $reportText

    if ($code -eq 0) {
        # A clean exit can still carry informational warnings (warn rules do not fail by default).
        $hasWarn = $reportText -match '(?m)^WARN '
        Write-LdoLog -Level SUCCESS -Message 'Conftest completed with no failures (warnings, if any, are listed above).'
        if ($hasWarn) {
            Add-LdoFinding -Tool 'conftest' -Target $PlanJsonPath -Status 'WARN' -Summary 'policy warnings (informational)' -Detail $reportText
        }
        else {
            Add-LdoFinding -Tool 'conftest' -Target $PlanJsonPath -Status 'PASS' -Summary 'no policy findings' -Detail $reportText
        }
    }
    elseif ($SoftFail) {
        Write-LdoLog -Level WARN -Message "Conftest reported failures (exit $code); continuing because -SoftFail."
        Add-LdoFinding -Tool 'conftest' -Target $PlanJsonPath -Status 'WARN' -Summary "failures (soft-fail, exit $code)" -Detail $reportText
    }
    else {
        Add-LdoFinding -Tool 'conftest' -Target $PlanJsonPath -Status 'FAIL' -Summary "failures (exit $code)" -Detail $reportText
        throw "Conftest failed (exit $code)."
    }
}

Export-ModuleMember -Function `
    Install-LdoConftest, `
    Assert-LdoConftest, `
    Invoke-LdoConftest
