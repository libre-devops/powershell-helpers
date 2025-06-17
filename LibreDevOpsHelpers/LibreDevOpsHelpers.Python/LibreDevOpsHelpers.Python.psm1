# Create a .venv virtual environment in the current directory
function New-Venv
{
    [CmdletBinding()]
    param(
        [string]$VenvName = ".venv",
        [string]$VenvPath = $( Get-Location ).Path
    )

    $inv = $MyInvocation.MyCommand.Name

    # Determine correct Python executable
    if (Get-Command python3 -ErrorAction SilentlyContinue)
    {
        $pythonCmd = "python3"
    }
    elseif (Get-Command python -ErrorAction SilentlyContinue)
    {
        $pythonCmd = "python"
    }
    else
    {
        _LogMessage -Level ERROR -Message "Python not found" -InvocationName $inv
        return
    }

    # Get Python version
    $pythonVersion = & $pythonCmd --version
    _LogMessage -Level INFO -Message "Python version: $pythonVersion" -InvocationName $inv

    $VirtualEnvPath = Join-Path $VenvPath $VenvName

    if (Test-Path $VirtualEnvPath)
    {
        _LogMessage -Level WARN -Message "Virtual environment $VirtualEnvPath already exists." -InvocationName $inv
        return
    }

    _LogMessage -Level INFO -Message "Running: $pythonCmd -m venv $VirtualEnvPath" -InvocationName $inv
    & $pythonCmd -m venv $VirtualEnvPath
    _LogMessage -Level INFO -Message "Virtual environment '$VenvName' created at '$VirtualEnvPath'" -InvocationName $inv
}

function Initialize-Venv
{
    [CmdletBinding()]
    param(
        [string]$VenvName = '.venv',
        [string]$VenvPath = (Get-Location).Path,
        [switch]$VerifyVenv
    )

    $VirtualEnvPath = Join-Path $VenvPath $VenvName
    if (-not (Test-Path $VirtualEnvPath))
    {
        throw "No virtual environment at '$VirtualEnvPath'"
    }

    if ($IsWindows)
    {
        . (Join-Path $VirtualEnvPath 'Scripts\Activate.ps1')
    }
    else
    {
        $env:VIRTUAL_ENV = $VirtualEnvPath
        $env:PATH = "$VirtualEnvPath/bin:$env:PATH"

        if (-not (Test-Path function:\__origPrompt))
        {
            Set-Item function:\__origPrompt (Get-Command prompt)
        }
        function global:prompt
        {
            "($( Split-Path $env:VIRTUAL_ENV -Leaf )) " + (& __origPrompt)
        }
    }

    if ($VerifyVenv)
    {
        $venvPython = if ($IsWindows)
        {
            Join-Path $VirtualEnvPath 'Scripts/python.exe'
        }
        else
        {
            Join-Path $VirtualEnvPath 'bin/python'
        }
        $prefix = & $venvPython -c 'import sys, pathlib; print(pathlib.Path(sys.prefix).resolve())'
        if ($prefix -ne (Get-Item $VirtualEnvPath).FullName)
        {
            throw "Venv verification failed – expected $VirtualEnvPath, got $prefix"
        }
    }
}

function Use-Venv {
    [CmdletBinding()]
    param(
        [string] $VenvPath = (Get-Location).Path,
        [string] $VenvName = '.venv'
    )

    $inv = $MyInvocation.MyCommand.Name
    $venvRoot = Join-Path $VenvPath $VenvName

    # region ─── CREATE IF NEEDED ──────────────────────────────────────────────
    if (-not (Test-Path $venvRoot)) {
        _LogMessage -Level INFO -Message "Creating venv with: python -m venv $venvRoot" -InvocationName $inv
        try {
            python -m venv $venvRoot
        } catch {
            _LogMessage -Level ERROR -Message "Failed to create venv: $_" -InvocationName $inv
            throw
        }
    }
    # endregion

    # region ─── ACTIVATE ──────────────────────────────────────────────────────
    if ($IsWindows) {
        $activateScript = Join-Path $venvRoot 'Scripts\Activate.ps1'
        if (-not (Test-Path $activateScript)) {
            _LogMessage -Level ERROR -Message "Cannot find $activateScript" -InvocationName $inv
            throw
        }
        _LogMessage -Level INFO -Message "Dot-sourcing $activateScript" -InvocationName $inv
        . $activateScript
    }
    else {
        # Two env-vars = “activated” for PowerShell on Linux/macOS/WSL
        _LogMessage -Level INFO -Message "Setting PATH/VIRTUAL_ENV for POSIX PowerShell" -InvocationName $inv
        $env:VIRTUAL_ENV = (Resolve-Path $venvRoot)
        $env:PATH        = "$env:VIRTUAL_ENV/bin$([IO.Path]::PathSeparator)$env:PATH"

        # Optional cosmetic prompt
        if (-not (Get-Command __origPrompt -ErrorAction SilentlyContinue)) {
            $orig = Get-Command prompt -ErrorAction SilentlyContinue
            if ($orig) { Set-Item function:\__origPrompt $orig }
        }
        function global:prompt {
            "($(Split-Path $env:VIRTUAL_ENV -Leaf)) " + (& { & __origPrompt })
        }
    }

    _LogMessage -Level INFO -Message "Venv '$VenvName' is active." -InvocationName $inv
}



# Deactivate the current virtual environment
function Clear-Venv
{
    [CmdletBinding()]
    param(
        [string]$VenvName = ".venv"
    )

    $inv = $MyInvocation.MyCommand.Name

    if (Get-Command -Name deactivate -CommandType Function -ErrorAction SilentlyContinue)
    {
        _LogMessage -Level INFO -Message "Running: deactivate" -InvocationName $inv
        deactivate
        _LogMessage -Level INFO -Message "Virtual environment '$VenvName' deactivated." -InvocationName $inv
    }
    else
    {
        _LogMessage -Level ERROR -Message "No virtual environment is currently active." -InvocationName $inv
    }
}

# Fully remove a virtual environment
function Remove-Venv
{
    [CmdletBinding()]
    param(
        [string]$VenvName = ".venv",
        [string]$VenvPath = $( Get-Location ).Path
    )

    $inv = $MyInvocation.MyCommand.Name
    $VirtualEnvPath = Join-Path $VenvPath $VenvName

    if (Test-Path $VirtualEnvPath)
    {
        try
        {
            _LogMessage -Level INFO -Message "Running: Remove-Item -Path $VirtualEnvPath -Recurse -Force" -InvocationName $inv
            Remove-Item -Path $VirtualEnvPath -Recurse -Force
            _LogMessage -Level INFO -Message "Virtual environment '$VenvName' fully removed from '$VirtualEnvPath'" -InvocationName $inv
        }
        catch
        {
            _LogMessage -Level ERROR -Message "Failed to remove virtual environment '$VenvName' at '$VirtualEnvPath'" -InvocationName $inv
        }
    }
    else
    {
        _LogMessage -Level ERROR -Message "Virtual environment '$VenvName' not found at '$VirtualEnvPath'" -InvocationName $inv
    }
}

function Invoke-PythonInstallRequirements
{
    [CmdletBinding()]
    param(
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$ProjectPath = $( Get-Location ).Path,
        [string]$RequirementsFile = 'requirements.txt',
        [switch]$Upgrade
    )

    $inv = $MyInvocation.MyCommand.Name

    # Determine correct Python executable
    if (Get-Command python3 -ErrorAction SilentlyContinue)
    {
        $pythonCmd = "python3"
    }
    elseif (Get-Command python -ErrorAction SilentlyContinue)
    {
        $pythonCmd = "python"
    }
    else
    {
        Write-Host "Error: Python not found"
        return
    }

    try
    {
        $reqPath = Join-Path $ProjectPath $RequirementsFile
        if (-not (Test-Path $reqPath))
        {
            throw "Requirements file not found: $reqPath"
        }

        $pyArgs = @('-m', 'pip', 'install', '-r', "$reqPath", '--target', "$ProjectPath/.python_packages/lib/site-packages")
        if ($Upgrade)
        {
            $pyArgs += '--upgrade'
        }

        _LogMessage -Level INFO -Message "$pythonCmd $( $pyArgs -join ' ' )" -InvocationName $inv
        & $pythonCmd @pyArgs
        if ($LASTEXITCODE)
        {
            throw "pip install failed (exit $LASTEXITCODE)."
        }

        _LogMessage -Level INFO -Message 'Dependencies installed OK.' -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $inv
        throw
    }
}

function Remove-PythonPackages
{
    [CmdletBinding()]
    param(
        [string]$ProjectPath = $( Get-Location ).Path
    )

    $packagesPath = Join-Path $ProjectPath ".python_packages"

    if (Test-Path $packagesPath)
    {
        try
        {
            Remove-Item -Path $packagesPath -Recurse -Force
            Write-Host "Python packages directory removed successfully."
        }
        catch
        {
            Write-Host "Error: Failed to remove the Python packages directory."
        }
    }
    else
    {
        Write-Host "Error: Python packages directory not found."
    }
}



#############################################################################
# Run pytest and optionally emit JUnit XML & coverage reports
#############################################################################
function Invoke-PytestRun
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$ProjectPath,

        [string]$PythonExe = 'python',
        [string]$JUnitXmlPath = 'pytest-results.xml', # set '' to skip
        [string]$CoverageXmlPath = 'coverage.xml', # set '' to skip
        [string]$CoverageHtmlDir = 'htmlcov', # set '' to skip
        [string]$CliExtraArgsJson                         # JSON array
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location
    try
    {
        Set-Location $ProjectPath

        # ── Convert extra-args JSON ⇢ array ────────────────────────────────
        $extra = @()
        if ($CliExtraArgsJson)
        {
            try
            {
                $extra = [string[]]($CliExtraArgsJson | ConvertFrom-Json)
            }
            catch
            {
                throw "CliExtraArgsJson is not valid JSON array: $( $_.Exception.Message )"
            }
        }

        # ── Assemble pytest command list ───────────────────────────────────
        $cmd = @('-m', 'pytest')

        if ($JUnitXmlPath)
        {
            $cmd += "--junitxml=$JUnitXmlPath"
        }
        if ($CoverageXmlPath)
        {
            $cmd += @('--cov', '.', "--cov-report", "xml:$CoverageXmlPath")
            if ($CoverageHtmlDir)
            {
                $cmd += "--cov-report", "html:$CoverageHtmlDir"
            }
        }
        if ($extra)
        {
            $cmd += $extra
        }

        _LogMessage -Level INFO -Message "$PythonExe $( $cmd -join ' ' )" -InvocationName $inv
        & $PythonExe @cmd
        $code = $LASTEXITCODE
        _LogMessage -Level DEBUG -Message "pytest exit-code: $code" -InvocationName $inv

        if ($code)
        {
            throw "pytest failed (exit $code)."
        }

        _LogMessage -Level INFO -Message 'pytest completed successfully.' -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $inv
        throw
    }
    finally
    {
        Set-Location $orig
    }
}

#############################################################################
# Export public symbols
#############################################################################
Export-ModuleMember -Function `
    New-Venv, `
          Initialize-Venv, `
          Clear-Venv, `
          Use-Venv, `
          Remove-Venv, `
          Invoke-PythonInstallRequirements, `
          Remove-PythonPackages, `
          Invoke-PytestRun
