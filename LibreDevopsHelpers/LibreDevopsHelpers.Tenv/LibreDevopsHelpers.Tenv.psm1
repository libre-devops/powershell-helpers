function Invoke-InstallTenv {
    [CmdletBinding()]
    param()

    $inv = $MyInvocation.MyCommand.Name
    $os = Assert-WhichOs -PassThru

    if (-not (Get-Command tenv -ErrorAction SilentlyContinue)) {
        if ($os -eq 'windows') {
            Assert-ChocoPath
            _LogMessage -Level INFO -Message "Installing tenv via Chocolatey…" -InvocationName $inv
            choco install tenv -y
        }
        else {
            Assert-HomebrewPath
            _LogMessage -Level INFO -Message "Installing tenv via Homebrew…" -InvocationName $inv
            brew install tenv
        }
    }
    else {
        _LogMessage -Level INFO -Message "tenv already installed." -InvocationName $inv
    }
}


function Test-TenvExists
{
    try
    {
        $tenvPath = Get-Command tenv -ErrorAction Stop
        _LogMessage -Level "INFO" -Message "Tenv found at: $( $tenvPath.Source )" -InvocationName "$( $MyInvocation.MyCommand.Name )"
    }
    catch
    {
        _LogMessage -Level "WARNING" -Message "tenv is not installed or not in PATH – skipping version management." -InvocationName "$( $MyInvocation.MyCommand.Name )"
    }
}

function Invoke-TenvTfInstall {
    [CmdletBinding()]
    param(
        [string]$TerraformVersion = 'latest',
        [string[]]$TenvArgs = @()
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location

    try {
        $tenvPath = Get-Command tenv -ErrorAction Stop
        _LogMessage -Level INFO -Message "Tenv found at: $($tenvPath.Source)" -InvocationName $inv

        # If it's neither 'latest' nor 'latest-1', treat as a constraint
        if ($TerraformVersion -notin @('latest','latest-1')) {
            _LogMessage -Level INFO -Message "Desired Terraform version is $TerraformVersion – installing / switching via tenv..." -InvocationName $inv

            $escapedConstraint = [regex]::Escape($TerraformVersion)
            $version = tenv tf list-remote `
                | Select-String "^${escapedConstraint}\." `
                | Select-Object -Last 1 `
                | ForEach-Object { $_.ToString().Trim() }

            $cleanVersion = $version -replace '\s*\(installed\)\s*',''
            if ([string]::IsNullOrWhiteSpace($cleanVersion)) {
                _LogMessage -Level ERROR -Message "No matching version found for constraint '$TerraformVersion'." -InvocationName $inv
                throw "No matching Terraform version for '$TerraformVersion'"
            }

            _LogMessage -Level INFO -Message "Installing Terraform version $cleanVersion." -InvocationName $inv
            tenv tf install $cleanVersion
            tenv tf use     $cleanVersion
        }
        elseif ($TerraformVersion -eq 'latest') {
            _LogMessage -Level INFO -Message "Installing latest Terraform via tenv…" -InvocationName $inv
            tenv tf install latest $TenvArgs
            tenv tf use     latest $TenvArgs
        }
        else {  # must be 'latest-1'
            _LogMessage -Level INFO -Message "Installing previous minor Terraform release via tenv…" -InvocationName $inv

            # get the latest stable release
            $all = tenv tf list-remote | Select-String '^\d+\.\d+\.\d+$' | ForEach-Object { $_.ToString().Trim() }
            $latest = $all[-1]
            if ($latest -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
                throw "Unexpected version format: $latest"
            }
            $major, $minor, $patch = $matches[1], $matches[2], $matches[3]

            $previous = $all |
                    Where-Object { $_ -match "^\Q$major\E\.\Q$($minor-1)\E\.\d+$" } |
                    Select-Object -Last 1

            if (-not $previous) {
                _LogMessage -Level ERROR -Message "No previous minor release found." -InvocationName $inv
                throw "Cannot install previous minor Terraform version"
            }

            _LogMessage -Level INFO -Message "Installing Terraform version $previous." -InvocationName $inv
            tenv tf install $previous $TenvArgs
            tenv tf use     $previous $TenvArgs
        }
    }
    catch {
        _LogMessage -Level ERROR -Message "Error in Invoke-TenvTfInstall: $($_.Exception.Message)" -InvocationName $inv
        throw
    }
    finally {
        Set-Location $orig
    }
}


Export-ModuleMember -Function `
    Test-TenvExists, `
     Invoke-TenvTfInstall, `
     Invoke-InstallTenv
