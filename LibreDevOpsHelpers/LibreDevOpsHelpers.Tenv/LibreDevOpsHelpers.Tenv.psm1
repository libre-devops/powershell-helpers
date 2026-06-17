Set-StrictMode -Version Latest

function Install-LdoTenv {
    <#
    .SYNOPSIS
        Installs the tenv version manager if it is not already present.

    .DESCRIPTION
        Installs tenv via Chocolatey on Windows or Homebrew on other platforms when the tenv
        command is not found on PATH.

    .EXAMPLE
        Install-LdoTenv

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (Get-Command tenv -ErrorAction SilentlyContinue) {
        Write-LdoLog -Level INFO -Message 'tenv already installed.'
        return
    }

    $os = Get-LdoOperatingSystem
    if ($os -eq 'windows') {
        Assert-LdoChocoPath
        Write-LdoLog -Level INFO -Message 'Installing tenv via Chocolatey.'
        choco install tenv -y
    }
    else {
        Assert-LdoHomebrewPath
        Write-LdoLog -Level INFO -Message 'Installing tenv via Homebrew.'
        brew install tenv
    }
}

function Test-LdoTenv {
    <#
    .SYNOPSIS
        Tests whether tenv is available on PATH.

    .DESCRIPTION
        Returns $true when the tenv command is found, otherwise $false.

    .EXAMPLE
        if (Test-LdoTenv) { Invoke-LdoTenvTerraformInstall }

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $tenvPath = Get-Command tenv -ErrorAction SilentlyContinue
    if ($tenvPath) {
        Write-LdoLog -Level INFO -Message "tenv found at: $($tenvPath.Source)"
        return $true
    }

    Write-LdoLog -Level WARN -Message 'tenv is not installed or not in PATH.'
    return $false
}

function Invoke-LdoTenvTerraformInstall {
    <#
    .SYNOPSIS
        Installs and selects a Terraform version via tenv.

    .DESCRIPTION
        Uses tenv to install and select Terraform. 'latest' installs the newest release,
        'latest-1' installs the latest patch of the previous minor release, and any other value
        is treated as a version constraint matched against tenv's remote list.

    .PARAMETER TerraformVersion
        'latest', 'latest-1', or a version constraint such as '1.7'. Defaults to 'latest'.

    .PARAMETER TenvArgs
        Additional arguments passed through to tenv.

    .EXAMPLE
        Invoke-LdoTenvTerraformInstall -TerraformVersion 1.7

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$TerraformVersion = 'latest',
        [string[]]$TenvArgs = @()
    )

    $orig = Get-Location
    try {
        $tenvPath = Get-Command tenv -ErrorAction Stop
        Write-LdoLog -Level INFO -Message "tenv found at: $($tenvPath.Source)"

        if ($TerraformVersion -notin @('latest', 'latest-1')) {
            Write-LdoLog -Level INFO -Message "Desired Terraform version is $TerraformVersion; installing/switching via tenv."

            $escapedConstraint = [regex]::Escape($TerraformVersion)
            $version = tenv tf list-remote |
                Select-String "^${escapedConstraint}\." |
                Select-Object -Last 1 |
                ForEach-Object { $_.ToString().Trim() }

            $cleanVersion = $version -replace '\s*\(installed\)\s*', ''
            if ([string]::IsNullOrWhiteSpace($cleanVersion)) {
                throw "No matching Terraform version for '$TerraformVersion'."
            }

            Write-LdoLog -Level INFO -Message "Installing Terraform version $cleanVersion."
            tenv tf install $cleanVersion
            tenv tf use $cleanVersion
        }
        elseif ($TerraformVersion -eq 'latest') {
            Write-LdoLog -Level INFO -Message 'Installing latest Terraform via tenv.'
            tenv tf install latest $TenvArgs
            tenv tf use latest $TenvArgs
        }
        else {
            Write-LdoLog -Level INFO -Message 'Installing previous minor Terraform release via tenv.'

            $all = tenv tf list-remote | Select-String '^\d+\.\d+\.\d+$' | ForEach-Object { $_.ToString().Trim() }
            if (-not $all) {
                throw 'tenv returned no remote Terraform versions.'
            }
            $latest = $all[-1]
            if ($latest -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
                throw "Unexpected version format: $latest"
            }
            $major, $minor = $matches[1], [int]$matches[2]

            $previous = $all |
                Where-Object { $_ -match "^\Q$major\E\.\Q$($minor - 1)\E\.\d+$" } |
                Select-Object -Last 1

            if (-not $previous) {
                throw 'Cannot install previous minor Terraform version; no previous minor release found.'
            }

            Write-LdoLog -Level INFO -Message "Installing Terraform version $previous."
            tenv tf install $previous $TenvArgs
            tenv tf use $previous $TenvArgs
        }
    }
    finally {
        Set-Location $orig
    }
}

Export-ModuleMember -Function `
    Install-LdoTenv, `
    Test-LdoTenv, `
    Invoke-LdoTenvTerraformInstall
