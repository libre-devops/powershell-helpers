Set-StrictMode -Version Latest

function Install-LdoTfLint {
    <#
    .SYNOPSIS
        Installs the TFLint CLI.

    .DESCRIPTION
        Installs TFLint with Chocolatey on Windows. On Linux and macOS it downloads the official
        release binary from GitHub: the version defaults to 'latest' and is resolved at runtime
        (no hard-pinned version to maintain), and a specific version can be requested. The earlier
        install script is avoided because it is being retired and discourages unpinned scripts.

    .PARAMETER Version
        TFLint version to install: 'latest' (default) or a specific tag like '0.59.1' / 'v0.59.1'.

    .EXAMPLE
        Install-LdoTfLint

    .EXAMPLE
        Install-LdoTfLint -Version 0.59.1

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
        Write-LdoLog -Level INFO -Message 'Installing TFLint via Chocolatey on Windows.'
        choco install tflint -y
        Assert-LdoCommand -Name @('tflint')
        Write-LdoLog -Level SUCCESS -Message 'TFLint installed.'
        return
    }

    # Resolve 'latest' to a concrete tag by following the releases/latest redirect (no API token,
    # no rate-limit concern). curl is run through bash because in PowerShell "curl" is an alias.
    if ($Version -eq 'latest') {
        $effectiveUrl = (bash -c "curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/terraform-linters/tflint/releases/latest").Trim()
        Assert-LdoLastExitCode -Operation 'resolve latest tflint release'
        $tag = ($effectiveUrl.TrimEnd('/') -split '/')[-1]
    }
    else {
        $tag = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
    }

    $platform = if ($os -eq 'macos') { 'darwin' } else { 'linux' }
    $arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) { 'arm64' } else { 'amd64' }
    $url = "https://github.com/terraform-linters/tflint/releases/download/$tag/tflint_${platform}_${arch}.zip"

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-tflint-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        Write-LdoLog -Level INFO -Message "Downloading TFLint $tag from $url"
        $zip = Join-Path $work 'tflint.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath $work -Force

        $binary = Join-Path $work 'tflint'
        & chmod '+x' $binary
        $dest = '/usr/local/bin/tflint'
        try {
            Move-Item -Path $binary -Destination $dest -Force -ErrorAction Stop
        }
        catch {
            bash -c "sudo mv '$binary' '$dest'"
            Assert-LdoLastExitCode -Operation 'install tflint to /usr/local/bin'
        }
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    Assert-LdoCommand -Name @('tflint')
    Write-LdoLog -Level SUCCESS -Message "TFLint $tag installed."
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
