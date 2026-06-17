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
        Runs 'trivy config' over a code path, optionally skipping named policies and soft-failing.
        Throws on findings unless -SoftFail is set.

    .PARAMETER CodePath
        Folder to scan.

    .PARAMETER TrivySkipChecks
        Policy ids to skip.

    .PARAMETER SoftFail
        When set, findings are logged as a warning instead of throwing.

    .PARAMETER ExtraArgs
        Additional arguments passed through to trivy.

    .EXAMPLE
        Invoke-LdoTrivy -CodePath ./terraform -SoftFail

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string[]]$TrivySkipChecks = @(),
        [switch]$SoftFail,
        [string[]]$ExtraArgs = @()
    )

    if (-not (Test-Path $CodePath)) {
        throw "Code path not found: $CodePath"
    }

    $trivyArgs = @('config', $CodePath, '--no-progress')

    if ($TrivySkipChecks.Count -gt 0) {
        $trivyArgs += @('--skip-policy', ($TrivySkipChecks -join ','))
    }

    $trivyArgs += $ExtraArgs

    Write-LdoLog -Level INFO -Message "Executing Trivy: trivy $($trivyArgs -join ' ')"

    & trivy @trivyArgs
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Write-LdoLog -Level SUCCESS -Message 'Trivy completed with no failed checks.'
    }
    elseif ($SoftFail) {
        Write-LdoLog -Level WARN -Message "Trivy found issues (exit $code); continuing because -SoftFail."
    }
    else {
        throw "Trivy failed (exit $code)."
    }
}

Export-ModuleMember -Function `
    Invoke-LdoTrivy, `
    Install-LdoTrivy
