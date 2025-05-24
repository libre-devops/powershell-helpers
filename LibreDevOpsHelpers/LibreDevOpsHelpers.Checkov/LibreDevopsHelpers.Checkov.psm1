function Invoke-InstallCheckov
{
    [CmdletBinding()]
    param()

    $inv = $MyInvocation.MyCommand.Name
    $os = Assert-WhichOs -PassThru

    if ($os.toLower() -eq 'windows')
    {
        # on Windows, install via pip (or pip3/pipx if you prefer)
        _LogMessage -Level INFO -Message "Installing Checkov via pip on Windows…" -InvocationName $inv

        if (Get-Command pipx -ErrorAction SilentlyContinue)
        {
            pipx install checkov
        }
        elseif (Get-Command pip3 -ErrorAction SilentlyContinue)
        {
            pip3 install --upgrade checkov
        }
        elseif (Get-Command pip -ErrorAction SilentlyContinue)
        {
            pip install --upgrade checkov
        }
        else
        {
            _LogMessage -Level ERROR -Message "No pip/pip3/pipx found; cannot install Checkov." -InvocationName $inv
            throw "Cannot install Checkov: pip/pip3/pipx missing."
        }
    }
    elseif ($os.toLower() -eq 'linux' -or 'macos')
    {
        # on *nix, use Homebrew
        Assert-HomebrewPath
        _LogMessage -Level INFO -Message "Installing Checkov via Homebrew…" -InvocationName $inv
        brew install checkov
    }
    else
    {
        _LogMessage -Level ERROR -Message "Unsupported OS for Checkov install: $os" -InvocationName $inv
        throw "Unsupported OS: $os"
    }

    # verify
    Get-InstalledPrograms -Programs @('checkov')
}

function Invoke-Checkov
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CodePath,
        [string]  $PlanJsonFile = 'tfplan.plan.json',

        [string]  $CheckovSkipChecks = '',
        [switch]  $SoftFail,

    # NEW – just like -InitArgs in your Terraform helper:
        [string[]]$ExtraArgs = @()      # any additional CLI flags
    )

    #── find the JSON plan ─────────────────────────────────────────────────
    $planPath = Join-Path $CodePath $PlanJsonFile
    if (-not (Test-Path $planPath))
    {
        _LogMessage -Level 'ERROR' -Message "JSON plan not found: $planPath" `
                    -InvocationName $MyInvocation.MyCommand.Name
        throw "JSON plan not found: $planPath"
    }

    #── build --skip-check … if supplied ──────────────────────────────────
    $skipArgument = @()
    if ( $CheckovSkipChecks.Trim())
    {
        $list = ($CheckovSkipChecks -split ',') |
                ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($list)
        {
            $skipArgument = @('--skip-check', ($list -join ','))
        }
    }

    #── base Checkov arguments ─────────────────────────────────────────────
    $checkovArgs = @(
        '-s'                                         # short output
        '-f', $planPath
        '--repo-root-for-plan-enrichment', $CodePath
        '--download-external-modules', 'false'
    ) + $skipArgument + $ExtraArgs

    if ($SoftFail)
    {
        $checkovArgs += '--soft-fail'
    }

    _LogMessage -Level 'INFO' -Message "Executing Checkov: checkov $( $checkovArgs -join ' ' )" `
                -InvocationName $MyInvocation.MyCommand.Name

    & checkov @checkovArgs
    $code = $LASTEXITCODE

    if ($code -eq 0)
    {
        _LogMessage -Level 'INFO' -Message 'Checkov completed with no failed checks.' `
                    -InvocationName $MyInvocation.MyCommand.Name
    }
    elseif ($SoftFail)
    {
        _LogMessage -Level 'WARN' -Message "Checkov found issues (exit $code) – continuing because -SoftFail." `
                    -InvocationName $MyInvocation.MyCommand.Name
    }
    else
    {
        _LogMessage -Level 'ERROR' -Message "Checkov reported failures (exit $code)." `
                    -InvocationName $MyInvocation.MyCommand.Name
        throw "Checkov failed (exit $code)."
    }
}

Export-ModuleMember -Function `
    Invoke-Checkov, `
     Invoke-InstallCheckov
