Set-StrictMode -Version Latest

function Invoke-LdoUvCommand {
    # Internal. Asserts uv is present, runs it with the supplied arguments, and throws a
    # descriptive error on a non-zero exit. Centralises the shell-out so every public uv
    # function logs and error-checks identically.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [string]$Operation
    )

    Assert-LdoCommand -Name 'uv'

    if (-not $Operation) {
        $Operation = "uv $($ArgumentList -join ' ')"
    }

    Write-LdoLog -Level INFO -Message "Running: uv $($ArgumentList -join ' ')"
    & uv @ArgumentList
    Assert-LdoLastExitCode -Operation $Operation
}

function Install-LdoUv {
    <#
    .SYNOPSIS
        Installs the uv Python package manager if it is not already present.

    .DESCRIPTION
        Installs uv via Chocolatey on Windows or Homebrew on other platforms when the uv command
        is not found on PATH. Does nothing when uv is already installed.

    .EXAMPLE
        Install-LdoUv

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Write-LdoLog -Level INFO -Message 'uv already installed.'
        return
    }

    $os = Get-LdoOperatingSystem
    if ($os -eq 'Windows') {
        Assert-LdoChocoPath
        Write-LdoLog -Level INFO -Message 'Installing uv via Chocolatey.'
        choco install uv -y
        Assert-LdoLastExitCode -Operation 'choco install uv'
    }
    else {
        Assert-LdoHomebrewPath
        Write-LdoLog -Level INFO -Message 'Installing uv via Homebrew.'
        brew install uv
        Assert-LdoLastExitCode -Operation 'brew install uv'
    }

    Write-LdoLog -Level SUCCESS -Message 'uv installed.'
}

function Test-LdoUv {
    <#
    .SYNOPSIS
        Tests whether uv is available on PATH.

    .DESCRIPTION
        Returns $true when the uv command is found, otherwise $false.

    .EXAMPLE
        if (-not (Test-LdoUv)) { Install-LdoUv }

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $uvPath = Get-Command uv -ErrorAction SilentlyContinue
    if ($uvPath) {
        Write-LdoLog -Level INFO -Message "uv found at: $($uvPath.Source)"
        return $true
    }

    Write-LdoLog -Level WARN -Message 'uv is not installed or not in PATH.'
    return $false
}

function Install-LdoUvPython {
    <#
    .SYNOPSIS
        Installs a Python version with uv.

    .DESCRIPTION
        Runs 'uv python install' for the requested version (for example 3.12 or 3.12.4, or
        'cpython-3.12'). Throws on failure.

    .PARAMETER Version
        Python version or request string to install.

    .PARAMETER Reinstall
        When set, passes --reinstall to force a fresh install of an already-installed version.

    .EXAMPLE
        Install-LdoUvPython -Version 3.12

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Version,

        [switch]$Reinstall
    )

    $uvArgs = @('python', 'install', $Version)
    if ($Reinstall) {
        $uvArgs += '--reinstall'
    }

    Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation "uv python install $Version"
    Write-LdoLog -Level SUCCESS -Message "Python $Version installed via uv."
}

function Get-LdoUvPython {
    <#
    .SYNOPSIS
        Lists Python versions known to uv.

    .DESCRIPTION
        Runs 'uv python list' and returns its output lines. By default both installed and
        downloadable versions are listed; use -OnlyInstalled to restrict to installed versions.

    .PARAMETER OnlyInstalled
        When set, passes --only-installed so only installed versions are returned.

    .EXAMPLE
        Get-LdoUvPython -OnlyInstalled

    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [switch]$OnlyInstalled
    )

    Assert-LdoCommand -Name 'uv'

    $uvArgs = @('python', 'list')
    if ($OnlyInstalled) {
        $uvArgs += '--only-installed'
    }

    Write-LdoLog -Level INFO -Message "Running: uv $($uvArgs -join ' ')"
    $output = & uv @uvArgs
    Assert-LdoLastExitCode -Operation 'uv python list'

    return $output
}

function Set-LdoUvPythonPin {
    <#
    .SYNOPSIS
        Pins the Python version for the current project or directory.

    .DESCRIPTION
        Runs 'uv python pin' to write the requested version to a .python-version file so uv and
        other tools select it. Throws on failure.

    .PARAMETER Version
        Python version to pin (for example 3.12).

    .EXAMPLE
        Set-LdoUvPythonPin -Version 3.12

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    Invoke-LdoUvCommand -ArgumentList @('python', 'pin', $Version) -Operation "uv python pin $Version"
    Write-LdoLog -Level SUCCESS -Message "Pinned Python $Version."
}

function New-LdoUvVenv {
    <#
    .SYNOPSIS
        Creates a virtual environment with uv.

    .DESCRIPTION
        Runs 'uv venv' to create a virtual environment, optionally targeting a specific Python
        version. Throws on failure.

    .PARAMETER Path
        Path of the environment to create. Defaults to .venv.

    .PARAMETER Version
        Python version to use for the environment (passed as --python). Optional.

    .PARAMETER Seed
        When set, passes --seed so pip (and related) are installed into the environment.

    .PARAMETER Clear
        When set, passes --clear to remove any existing environment at the path first.

    .EXAMPLE
        New-LdoUvVenv -Version 3.12

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Path = '.venv',
        [string]$Version,
        [switch]$Seed,
        [switch]$Clear
    )

    $uvArgs = @('venv', $Path)
    if ($Version) {
        $uvArgs += @('--python', $Version)
    }
    if ($Seed) {
        $uvArgs += '--seed'
    }
    if ($Clear) {
        $uvArgs += '--clear'
    }

    Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation "uv venv $Path"
    Write-LdoLog -Level SUCCESS -Message "Virtual environment created at '$Path'."
}

function Invoke-LdoUvSync {
    <#
    .SYNOPSIS
        Installs project dependencies from pyproject.toml / uv.lock with uv.

    .DESCRIPTION
        Runs 'uv sync' to resolve and install the project's dependencies into its environment.
        The original working directory is always restored when -ProjectPath is used. Throws on
        failure.

    .PARAMETER ProjectPath
        Project folder to sync. Defaults to the current directory.

    .PARAMETER Frozen
        When set, passes --frozen so the existing uv.lock is used without updating it.

    .PARAMETER NoDev
        When set, passes --no-dev to exclude development dependencies.

    .PARAMETER AllExtras
        When set, passes --all-extras to include all optional dependency groups.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to uv sync.

    .EXAMPLE
        Invoke-LdoUvSync -Frozen

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$ProjectPath = (Get-Location).Path,
        [switch]$Frozen,
        [switch]$NoDev,
        [switch]$AllExtras,
        [string[]]$AdditionalArgs = @()
    )

    $uvArgs = @('sync')
    if ($Frozen) {
        $uvArgs += '--frozen'
    }
    if ($NoDev) {
        $uvArgs += '--no-dev'
    }
    if ($AllExtras) {
        $uvArgs += '--all-extras'
    }
    if ($AdditionalArgs) {
        $uvArgs += $AdditionalArgs
    }

    $orig = Get-Location
    try {
        Set-Location $ProjectPath
        Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation 'uv sync'
        Write-LdoLog -Level SUCCESS -Message 'Dependencies synced.'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoUvLock {
    <#
    .SYNOPSIS
        Resolves and writes the uv.lock lockfile.

    .DESCRIPTION
        Runs 'uv lock' to update the project's lockfile. With -Check the command instead verifies
        the lockfile is up to date without modifying it (useful in CI). Throws on failure.

    .PARAMETER Upgrade
        When set, passes --upgrade to allow all dependencies to be upgraded.

    .PARAMETER Check
        When set, passes --check to verify the lockfile is current without writing changes.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to uv lock.

    .EXAMPLE
        Invoke-LdoUvLock -Upgrade

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [switch]$Upgrade,
        [switch]$Check,
        [string[]]$AdditionalArgs = @()
    )

    $uvArgs = @('lock')
    if ($Upgrade) {
        $uvArgs += '--upgrade'
    }
    if ($Check) {
        $uvArgs += '--check'
    }
    if ($AdditionalArgs) {
        $uvArgs += $AdditionalArgs
    }

    Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation 'uv lock'
    Write-LdoLog -Level SUCCESS -Message 'Lockfile resolved.'
}

function Add-LdoUvPackage {
    <#
    .SYNOPSIS
        Adds one or more dependencies to the project with uv.

    .DESCRIPTION
        Runs 'uv add' to add the named packages to pyproject.toml and install them. Throws on
        failure.

    .PARAMETER Package
        One or more package requirements to add (for example requests or 'httpx>=0.27').

    .PARAMETER Dev
        When set, passes --dev to add the packages as development dependencies.

    .PARAMETER Optional
        Name of an optional dependency group to add the packages to (passed as --optional).

    .PARAMETER AdditionalArgs
        Additional arguments passed through to uv add.

    .EXAMPLE
        Add-LdoUvPackage -Package requests, 'httpx>=0.27'

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Package,
        [switch]$Dev,
        [string]$Optional,
        [string[]]$AdditionalArgs = @()
    )

    $uvArgs = @('add')
    if ($Dev) {
        $uvArgs += '--dev'
    }
    if ($Optional) {
        $uvArgs += @('--optional', $Optional)
    }
    $uvArgs += $Package
    if ($AdditionalArgs) {
        $uvArgs += $AdditionalArgs
    }

    Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation "uv add $($Package -join ' ')"
    Write-LdoLog -Level SUCCESS -Message "Added: $($Package -join ', ')."
}

function Remove-LdoUvPackage {
    <#
    .SYNOPSIS
        Removes one or more dependencies from the project with uv.

    .DESCRIPTION
        Runs 'uv remove' to remove the named packages from pyproject.toml and the environment.
        Throws on failure.

    .PARAMETER Package
        One or more package names to remove.

    .PARAMETER Dev
        When set, passes --dev to remove the packages from development dependencies.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to uv remove.

    .EXAMPLE
        Remove-LdoUvPackage -Package requests

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Package,
        [switch]$Dev,
        [string[]]$AdditionalArgs = @()
    )

    $uvArgs = @('remove')
    if ($Dev) {
        $uvArgs += '--dev'
    }
    $uvArgs += $Package
    if ($AdditionalArgs) {
        $uvArgs += $AdditionalArgs
    }

    Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation "uv remove $($Package -join ' ')"
    Write-LdoLog -Level SUCCESS -Message "Removed: $($Package -join ', ')."
}

function Invoke-LdoUvRun {
    <#
    .SYNOPSIS
        Runs a command in the project's environment with uv.

    .DESCRIPTION
        Runs 'uv run' followed by the supplied command and arguments, ensuring the project's
        environment is up to date first. The original working directory is always restored when
        -ProjectPath is used. Throws when the command exits non-zero.

    .PARAMETER Command
        The command and any arguments to run (for example pytest -q). Accepts the remaining
        arguments to the function.

    .PARAMETER ProjectPath
        Project folder to run in. Defaults to the current directory.

    .EXAMPLE
        Invoke-LdoUvRun pytest -q

    .EXAMPLE
        Invoke-LdoUvRun -ProjectPath ./app -- python -m my_module

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$ProjectPath = (Get-Location).Path,

        [Parameter(Mandatory, ValueFromRemainingArguments)]
        [string[]]$Command
    )

    if (-not (Test-Path $ProjectPath -PathType Container)) {
        throw "Project path not found: $ProjectPath"
    }

    $uvArgs = @('run') + $Command

    $orig = Get-Location
    try {
        Set-Location $ProjectPath
        Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation "uv run $($Command -join ' ')"
        Write-LdoLog -Level SUCCESS -Message 'uv run completed.'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoUvPipInstall {
    <#
    .SYNOPSIS
        Installs packages using uv's pip interface.

    .DESCRIPTION
        Runs 'uv pip install' for the named packages and/or a requirements file. Throws on
        failure.

    .PARAMETER Package
        One or more package requirements to install. Optional when -RequirementsFile is supplied.

    .PARAMETER RequirementsFile
        Path to a requirements file to install from (passed as -r). Optional.

    .PARAMETER Upgrade
        When set, passes --upgrade to upgrade already-installed packages.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to uv pip install.

    .EXAMPLE
        Invoke-LdoUvPipInstall -Package requests

    .EXAMPLE
        Invoke-LdoUvPipInstall -RequirementsFile requirements.txt

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Installs multiple packages.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string[]]$Package = @(),
        [string]$RequirementsFile,
        [switch]$Upgrade,
        [string[]]$AdditionalArgs = @()
    )

    if (-not $Package -and -not $RequirementsFile) {
        throw 'Specify -Package, -RequirementsFile, or both.'
    }
    if ($RequirementsFile -and -not (Test-Path $RequirementsFile)) {
        throw "Requirements file not found: $RequirementsFile"
    }

    $uvArgs = @('pip', 'install')
    if ($Upgrade) {
        $uvArgs += '--upgrade'
    }
    if ($RequirementsFile) {
        $uvArgs += @('-r', $RequirementsFile)
    }
    if ($Package) {
        $uvArgs += $Package
    }
    if ($AdditionalArgs) {
        $uvArgs += $AdditionalArgs
    }

    Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation 'uv pip install'
    Write-LdoLog -Level SUCCESS -Message 'Packages installed.'
}

function Invoke-LdoUvPipUninstall {
    <#
    .SYNOPSIS
        Uninstalls packages using uv's pip interface.

    .DESCRIPTION
        Runs 'uv pip uninstall' for the named packages. Throws on failure.

    .PARAMETER Package
        One or more package names to uninstall.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to uv pip uninstall.

    .EXAMPLE
        Invoke-LdoUvPipUninstall -Package requests

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Uninstalls multiple packages.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Package,
        [string[]]$AdditionalArgs = @()
    )

    $uvArgs = @('pip', 'uninstall') + $Package
    if ($AdditionalArgs) {
        $uvArgs += $AdditionalArgs
    }

    Invoke-LdoUvCommand -ArgumentList $uvArgs -Operation "uv pip uninstall $($Package -join ' ')"
    Write-LdoLog -Level SUCCESS -Message "Uninstalled: $($Package -join ', ')."
}

Export-ModuleMember -Function `
    Install-LdoUv, `
    Test-LdoUv, `
    Install-LdoUvPython, `
    Get-LdoUvPython, `
    Set-LdoUvPythonPin, `
    New-LdoUvVenv, `
    Invoke-LdoUvSync, `
    Invoke-LdoUvLock, `
    Add-LdoUvPackage, `
    Remove-LdoUvPackage, `
    Invoke-LdoUvRun, `
    Invoke-LdoUvPipInstall, `
    Invoke-LdoUvPipUninstall
