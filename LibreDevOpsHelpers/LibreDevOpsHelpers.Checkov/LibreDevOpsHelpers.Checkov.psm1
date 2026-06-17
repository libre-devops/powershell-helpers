Set-StrictMode -Version Latest

function Install-LdoCheckov {
    <#
    .SYNOPSIS
        Installs the Checkov CLI.

    .DESCRIPTION
        Installs Checkov via pipx, pip3, or pip on Windows, or via Homebrew on Linux and macOS,
        then verifies the checkov command is available.

    .EXAMPLE
        Install-LdoCheckov

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $os = Get-LdoOperatingSystem

    if ($os.ToLower() -eq 'windows') {
        Write-LdoLog -Level INFO -Message 'Installing Checkov via pip on Windows.'

        if (Get-Command pipx -ErrorAction SilentlyContinue) {
            pipx install checkov
        }
        elseif (Get-Command pip3 -ErrorAction SilentlyContinue) {
            pip3 install --upgrade checkov
        }
        elseif (Get-Command pip -ErrorAction SilentlyContinue) {
            pip install --upgrade checkov
        }
        else {
            throw 'Cannot install Checkov: pip/pip3/pipx missing.'
        }
    }
    else {
        Assert-LdoHomebrewPath
        Write-LdoLog -Level INFO -Message 'Installing Checkov via Homebrew.'
        brew install checkov
    }

    Assert-LdoCommand -Name @('checkov')
    Write-LdoLog -Level SUCCESS -Message 'Checkov installed.'
}

function Invoke-LdoCheckov {
    <#
    .SYNOPSIS
        Runs Checkov against a Terraform plan JSON file.

    .DESCRIPTION
        Runs Checkov over a JSON plan with plan enrichment, optionally skipping named checks and
        soft-failing. Throws on findings unless -SoftFail is set.

    .PARAMETER CodePath
        Terraform configuration folder used as the repo root for plan enrichment.

    .PARAMETER PlanJsonFile
        JSON plan file name within CodePath. Defaults to tfplan.plan.json.

    .PARAMETER CheckovSkipChecks
        Comma-separated list of check ids to skip.

    .PARAMETER SoftFail
        When set, findings are logged as a warning instead of throwing.

    .PARAMETER ExtraArgs
        Additional arguments passed through to checkov.

    .EXAMPLE
        Invoke-LdoCheckov -CodePath ./terraform -SoftFail

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$PlanJsonFile = 'tfplan.plan.json',
        [string]$CheckovSkipChecks = '',
        [switch]$SoftFail,
        [string[]]$ExtraArgs = @()
    )

    $planPath = Join-Path $CodePath $PlanJsonFile
    if (-not (Test-Path $planPath)) {
        throw "JSON plan not found: $planPath"
    }

    $skipArgument = @()
    if ($CheckovSkipChecks.Trim()) {
        $list = ($CheckovSkipChecks -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($list) {
            $skipArgument = @('--skip-check', ($list -join ','))
        }
    }

    $checkovArgs = @(
        '-s'
        '-f', $planPath
        '--repo-root-for-plan-enrichment', $CodePath
        '--download-external-modules', 'false'
    ) + $skipArgument + $ExtraArgs

    if ($SoftFail) {
        $checkovArgs += '--soft-fail'
    }

    Write-LdoLog -Level INFO -Message "Executing Checkov: checkov $($checkovArgs -join ' ')"

    & checkov @checkovArgs
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Write-LdoLog -Level SUCCESS -Message 'Checkov completed with no failed checks.'
    }
    elseif ($SoftFail) {
        Write-LdoLog -Level WARN -Message "Checkov found issues (exit $code); continuing because -SoftFail."
    }
    else {
        throw "Checkov failed (exit $code)."
    }
}

Export-ModuleMember -Function `
    Invoke-LdoCheckov, `
    Install-LdoCheckov
