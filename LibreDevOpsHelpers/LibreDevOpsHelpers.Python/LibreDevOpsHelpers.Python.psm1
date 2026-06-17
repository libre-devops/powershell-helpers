Set-StrictMode -Version Latest

function Get-LdoPythonCommand {
    # Internal. Returns the name of the available Python executable, preferring python3.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        return 'python3'
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return 'python'
    }
    throw 'Python not found on PATH.'
}

function New-LdoVenv {
    <#
    .SYNOPSIS
        Creates a Python virtual environment.

    .DESCRIPTION
        Creates a venv at <VenvPath>/<VenvName> using the available Python executable. Does
        nothing when the environment already exists.

    .PARAMETER VenvName
        Name of the virtual environment folder. Defaults to .venv.

    .PARAMETER VenvPath
        Parent folder for the environment. Defaults to the current directory.

    .EXAMPLE
        New-LdoVenv

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$VenvName = '.venv',
        [string]$VenvPath = (Get-Location).Path
    )

    $pythonCmd = Get-LdoPythonCommand
    $pythonVersion = & $pythonCmd --version
    Write-LdoLog -Level INFO -Message "Python version: $pythonVersion"

    $virtualEnvPath = Join-Path $VenvPath $VenvName
    if (Test-Path $virtualEnvPath) {
        Write-LdoLog -Level WARN -Message "Virtual environment $virtualEnvPath already exists."
        return
    }

    Write-LdoLog -Level INFO -Message "Running: $pythonCmd -m venv $virtualEnvPath"
    & $pythonCmd -m venv $virtualEnvPath
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create virtual environment (exit $LASTEXITCODE)."
    }
    Write-LdoLog -Level SUCCESS -Message "Virtual environment '$VenvName' created at '$virtualEnvPath'."
}

function Initialize-LdoVenv {
    <#
    .SYNOPSIS
        Activates an existing Python virtual environment in the current session.

    .DESCRIPTION
        Activates the venv at <VenvPath>/<VenvName>. On Windows the Activate.ps1 script is
        dot-sourced; on other platforms VIRTUAL_ENV and PATH are set directly. Throws when the
        environment is missing, or when -VerifyVenv is set and the active interpreter does not
        resolve to the expected location.

    .PARAMETER VenvName
        Name of the virtual environment folder. Defaults to .venv.

    .PARAMETER VenvPath
        Parent folder for the environment. Defaults to the current directory.

    .PARAMETER VerifyVenv
        When set, verifies the active interpreter resolves to the environment.

    .EXAMPLE
        Initialize-LdoVenv -VerifyVenv

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidGlobalFunctions', '', Justification = 'Venv activation must override the global prompt function.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$VenvName = '.venv',
        [string]$VenvPath = (Get-Location).Path,
        [switch]$VerifyVenv
    )

    $virtualEnvPath = Join-Path $VenvPath $VenvName
    if (-not (Test-Path $virtualEnvPath)) {
        throw "No virtual environment at '$virtualEnvPath'"
    }

    if ($IsWindows) {
        . (Join-Path $virtualEnvPath 'Scripts\Activate.ps1')
    }
    else {
        $env:VIRTUAL_ENV = $virtualEnvPath
        $env:PATH = "$virtualEnvPath/bin:$env:PATH"

        if (-not (Test-Path function:\__origPrompt)) {
            Set-Item function:\__origPrompt (Get-Command prompt)
        }
        function global:prompt {
            "($(Split-Path $env:VIRTUAL_ENV -Leaf)) " + (& __origPrompt)
        }
    }

    if ($VerifyVenv) {
        $venvPython = if ($IsWindows) {
            Join-Path $virtualEnvPath 'Scripts/python.exe'
        }
        else {
            Join-Path $virtualEnvPath 'bin/python'
        }
        $prefix = & $venvPython -c 'import sys, pathlib; print(pathlib.Path(sys.prefix).resolve())'
        if ($prefix -ne (Get-Item $virtualEnvPath).FullName) {
            throw "Venv verification failed; expected $virtualEnvPath, got $prefix"
        }
    }

    Write-LdoLog -Level INFO -Message "Virtual environment '$VenvName' activated."
}

function Use-LdoVenv {
    <#
    .SYNOPSIS
        Creates a Python virtual environment if needed and activates it.

    .DESCRIPTION
        Creates the venv at <VenvPath>/<VenvName> when it does not exist, then activates it for
        the current session.

    .PARAMETER VenvPath
        Parent folder for the environment. Defaults to the current directory.

    .PARAMETER VenvName
        Name of the virtual environment folder. Defaults to .venv.

    .EXAMPLE
        Use-LdoVenv

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSAvoidGlobalFunctions', '', Justification = 'Venv activation must override the global prompt function.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$VenvPath = (Get-Location).Path,
        [string]$VenvName = '.venv'
    )

    $venvRoot = Join-Path $VenvPath $VenvName

    if (-not (Test-Path $venvRoot)) {
        $pythonCmd = Get-LdoPythonCommand
        Write-LdoLog -Level INFO -Message "Creating venv with: $pythonCmd -m venv $venvRoot"
        & $pythonCmd -m venv $venvRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create virtual environment (exit $LASTEXITCODE)."
        }
    }

    if ($IsWindows) {
        $activateScript = Join-Path $venvRoot 'Scripts\Activate.ps1'
        if (-not (Test-Path $activateScript)) {
            throw "Cannot find $activateScript"
        }
        Write-LdoLog -Level INFO -Message "Dot-sourcing $activateScript"
        . $activateScript
    }
    else {
        Write-LdoLog -Level INFO -Message 'Setting PATH/VIRTUAL_ENV for POSIX PowerShell.'
        $env:VIRTUAL_ENV = (Resolve-Path $venvRoot)
        $env:PATH = "$env:VIRTUAL_ENV/bin$([IO.Path]::PathSeparator)$env:PATH"

        if (-not (Get-Command __origPrompt -ErrorAction SilentlyContinue)) {
            $orig = Get-Command prompt -ErrorAction SilentlyContinue
            if ($orig) { Set-Item function:\__origPrompt $orig }
        }
        function global:prompt {
            "($(Split-Path $env:VIRTUAL_ENV -Leaf)) " + (& { & __origPrompt })
        }
    }

    Write-LdoLog -Level INFO -Message "Virtual environment '$VenvName' is active."
}

function Clear-LdoVenv {
    <#
    .SYNOPSIS
        Deactivates the currently active Python virtual environment.

    .DESCRIPTION
        Calls the venv deactivate function when one is active, otherwise logs a warning.

    .PARAMETER VenvName
        Name used only for logging. Defaults to .venv.

    .EXAMPLE
        Clear-LdoVenv

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$VenvName = '.venv'
    )

    if (Get-Command -Name deactivate -CommandType Function -ErrorAction SilentlyContinue) {
        Write-LdoLog -Level INFO -Message 'Running: deactivate'
        deactivate
        Write-LdoLog -Level INFO -Message "Virtual environment '$VenvName' deactivated."
    }
    else {
        Write-LdoLog -Level WARN -Message 'No virtual environment is currently active.'
    }
}

function Remove-LdoVenv {
    <#
    .SYNOPSIS
        Removes a Python virtual environment.

    .DESCRIPTION
        Deletes the venv folder at <VenvPath>/<VenvName> when present, otherwise logs a warning.

    .PARAMETER VenvName
        Name of the virtual environment folder. Defaults to .venv.

    .PARAMETER VenvPath
        Parent folder for the environment. Defaults to the current directory.

    .EXAMPLE
        Remove-LdoVenv

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$VenvName = '.venv',
        [string]$VenvPath = (Get-Location).Path
    )

    $virtualEnvPath = Join-Path $VenvPath $VenvName
    if (-not (Test-Path $virtualEnvPath)) {
        Write-LdoLog -Level WARN -Message "Virtual environment '$VenvName' not found at '$virtualEnvPath'."
        return
    }

    Write-LdoLog -Level INFO -Message "Removing $virtualEnvPath"
    Remove-Item -Path $virtualEnvPath -Recurse -Force
    Write-LdoLog -Level SUCCESS -Message "Virtual environment '$VenvName' removed from '$virtualEnvPath'."
}

function Invoke-LdoPythonInstallRequirements {
    <#
    .SYNOPSIS
        Installs Python requirements into a project-local package directory.

    .DESCRIPTION
        Runs pip install -r against the requirements file, targeting
        <ProjectPath>/.python_packages/lib/site-packages (the layout used by Azure Functions
        Python apps). Throws on failure.

    .PARAMETER ProjectPath
        Project folder containing the requirements file. Defaults to the current directory.

    .PARAMETER RequirementsFile
        Requirements file name. Defaults to requirements.txt.

    .PARAMETER Upgrade
        When set, passes --upgrade to pip.

    .EXAMPLE
        Invoke-LdoPythonInstallRequirements -ProjectPath ./app

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Installs multiple requirements.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$ProjectPath = (Get-Location).Path,
        [string]$RequirementsFile = 'requirements.txt',
        [switch]$Upgrade
    )

    $pythonCmd = Get-LdoPythonCommand

    $reqPath = Join-Path $ProjectPath $RequirementsFile
    if (-not (Test-Path $reqPath)) {
        throw "Requirements file not found: $reqPath"
    }

    $pyArgs = @('-m', 'pip', 'install', '-r', "$reqPath", '--target', "$ProjectPath/.python_packages/lib/site-packages")
    if ($Upgrade) {
        $pyArgs += '--upgrade'
    }

    Write-LdoLog -Level INFO -Message "$pythonCmd $($pyArgs -join ' ')"
    & $pythonCmd @pyArgs
    if ($LASTEXITCODE -ne 0) {
        throw "pip install failed (exit $LASTEXITCODE)."
    }

    Write-LdoLog -Level SUCCESS -Message 'Dependencies installed.'
}

function Remove-LdoPythonPackages {
    <#
    .SYNOPSIS
        Removes the project-local .python_packages directory.

    .DESCRIPTION
        Deletes <ProjectPath>/.python_packages when present, otherwise logs a warning.

    .PARAMETER ProjectPath
        Project folder. Defaults to the current directory.

    .EXAMPLE
        Remove-LdoPythonPackages -ProjectPath ./app

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Removes multiple packages.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$ProjectPath = (Get-Location).Path
    )

    $packagesPath = Join-Path $ProjectPath '.python_packages'
    if (-not (Test-Path $packagesPath)) {
        Write-LdoLog -Level WARN -Message "Python packages directory not found: $packagesPath"
        return
    }

    Remove-Item -Path $packagesPath -Recurse -Force
    Write-LdoLog -Level SUCCESS -Message 'Python packages directory removed.'
}

function Invoke-LdoPytestRun {
    <#
    .SYNOPSIS
        Runs pytest, optionally emitting JUnit XML and coverage reports.

    .DESCRIPTION
        Runs pytest in a project folder. JUnit XML, coverage XML, and coverage HTML outputs are
        produced unless their parameters are set to an empty string. Extra CLI arguments can be
        supplied as a JSON array. Throws on test failure. The original working directory is always
        restored.

    .PARAMETER ProjectPath
        Project folder to run pytest in.

    .PARAMETER PythonExe
        Python executable to use. Defaults to python.

    .PARAMETER JUnitXmlPath
        JUnit XML output path. Set to '' to skip. Defaults to pytest-results.xml.

    .PARAMETER CoverageXmlPath
        Coverage XML output path. Set to '' to skip. Defaults to coverage.xml.

    .PARAMETER CoverageHtmlDir
        Coverage HTML output directory. Set to '' to skip. Defaults to htmlcov.

    .PARAMETER CliExtraArgsJson
        Additional pytest arguments as a JSON array string.

    .EXAMPLE
        Invoke-LdoPytestRun -ProjectPath ./app

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$ProjectPath,
        [string]$PythonExe = 'python',
        [string]$JUnitXmlPath = 'pytest-results.xml',
        [string]$CoverageXmlPath = 'coverage.xml',
        [string]$CoverageHtmlDir = 'htmlcov',
        [string]$CliExtraArgsJson
    )

    $orig = Get-Location
    try {
        Set-Location $ProjectPath

        $extra = @()
        if ($CliExtraArgsJson) {
            try {
                $extra = [string[]]($CliExtraArgsJson | ConvertFrom-Json)
            }
            catch {
                throw "CliExtraArgsJson is not a valid JSON array: $($_.Exception.Message)"
            }
        }

        $cmd = @('-m', 'pytest')
        if ($JUnitXmlPath) {
            $cmd += "--junitxml=$JUnitXmlPath"
        }
        if ($CoverageXmlPath) {
            $cmd += @('--cov', '.', '--cov-report', "xml:$CoverageXmlPath")
            if ($CoverageHtmlDir) {
                $cmd += '--cov-report', "html:$CoverageHtmlDir"
            }
        }
        if ($extra) {
            $cmd += $extra
        }

        Write-LdoLog -Level INFO -Message "$PythonExe $($cmd -join ' ')"
        & $PythonExe @cmd
        if ($LASTEXITCODE -ne 0) {
            throw "pytest failed (exit $LASTEXITCODE)."
        }

        Write-LdoLog -Level SUCCESS -Message 'pytest completed successfully.'
    }
    finally {
        Set-Location $orig
    }
}

Export-ModuleMember -Function `
    New-LdoVenv, `
    Initialize-LdoVenv, `
    Use-LdoVenv, `
    Clear-LdoVenv, `
    Remove-LdoVenv, `
    Invoke-LdoPythonInstallRequirements, `
    Remove-LdoPythonPackages, `
    Invoke-LdoPytestRun
