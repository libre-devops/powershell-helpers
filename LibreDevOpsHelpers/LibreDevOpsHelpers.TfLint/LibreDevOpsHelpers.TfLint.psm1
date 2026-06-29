Set-StrictMode -Version Latest

function Install-LdoTfLint {
    <#
    .SYNOPSIS
        Installs the TFLint CLI.

    .DESCRIPTION
        Installs TFLint via Chocolatey on Windows or Homebrew on Linux and macOS, then verifies
        the tflint command is available.

    .EXAMPLE
        Install-LdoTfLint

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $os = Get-LdoOperatingSystem

    if ($os.ToLower() -eq 'windows') {
        Assert-LdoChocoPath
        Write-LdoLog -Level INFO -Message 'Installing TFLint via Chocolatey on Windows.'
        choco install tflint -y
    }
    else {
        Assert-LdoHomebrewPath
        Write-LdoLog -Level INFO -Message 'Installing TFLint via Homebrew.'
        brew install tflint
    }

    Assert-LdoCommand -Name @('tflint')
    Write-LdoLog -Level SUCCESS -Message 'TFLint installed.'
}

function Invoke-LdoTfLint {
    <#
    .SYNOPSIS
        Runs a TFLint lint over a Terraform code path.

    .DESCRIPTION
        Runs 'tflint' against a code path. By default it first runs 'tflint --init' to install
        the plugins declared in the .tflint.hcl configuration, then runs a recursive lint.
        Throws on findings unless -SoftFail is set.

    .PARAMETER CodePath
        Folder to lint. TFLint is invoked with this folder as its working directory.

    .PARAMETER ConfigFile
        Path to a .tflint.hcl configuration file. When omitted, TFLint uses the .tflint.hcl in
        the code path, if present.

    .PARAMETER Recursive
        Lint the code path and all of its subdirectories. Defaults to true.

    .PARAMETER Init
        Run 'tflint --init' before linting to install configured plugins. Defaults to true.

    .PARAMETER SoftFail
        When set, findings are logged as a warning instead of throwing.

    .PARAMETER ExtraArgs
        Additional arguments passed through to tflint.

    .EXAMPLE
        Invoke-LdoTfLint -CodePath ./terraform

    .EXAMPLE
        Invoke-LdoTfLint -CodePath ./terraform -ConfigFile ./.tflint.hcl -SoftFail

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$ConfigFile,
        [bool]$Recursive = $true,
        [bool]$Init = $true,
        [switch]$SoftFail,
        [string[]]$ExtraArgs = @()
    )

    if (-not (Test-Path $CodePath)) {
        throw "Code path not found: $CodePath"
    }

    if ($ConfigFile -and -not (Test-Path $ConfigFile)) {
        throw "TFLint config file not found: $ConfigFile"
    }

    $commonArgs = @("--chdir=$CodePath")
    if ($ConfigFile) {
        $commonArgs += "--config=$((Resolve-Path $ConfigFile).Path)"
    }

    if ($Init) {
        $initArgs = $commonArgs + '--init'
        Write-LdoLog -Level INFO -Message "Initialising TFLint plugins: tflint $($initArgs -join ' ')"
        & tflint @initArgs
        if ($LASTEXITCODE -ne 0) {
            throw "TFLint plugin init failed (exit $LASTEXITCODE)."
        }
    }

    $lintArgs = $commonArgs
    if ($Recursive) {
        $lintArgs += '--recursive'
    }
    $lintArgs += $ExtraArgs

    Write-LdoLog -Level INFO -Message "Executing TFLint: tflint $($lintArgs -join ' ')"

    & tflint @lintArgs
    $code = $LASTEXITCODE

    if ($code -eq 0) {
        Write-LdoLog -Level SUCCESS -Message 'TFLint completed with no findings.'
    }
    elseif ($SoftFail) {
        Write-LdoLog -Level WARN -Message "TFLint found issues (exit $code); continuing because -SoftFail."
    }
    else {
        throw "TFLint failed (exit $code)."
    }
}

Export-ModuleMember -Function `
    Invoke-LdoTfLint, `
    Install-LdoTfLint
