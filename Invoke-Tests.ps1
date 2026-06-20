#Requires -Version 7.2
<#
.SYNOPSIS
    Runs static analysis and the Pester test suite for LibreDevOpsHelpers.

.DESCRIPTION
    Installs PSScriptAnalyzer and Pester if they are missing, runs PSScriptAnalyzer
    against the module source using PSScriptAnalyzerSettings.psd1, then runs every
    test under ./tests. Intended for local use and CI.

.PARAMETER SkipAnalyzer
    Skip the PSScriptAnalyzer pass and run only Pester.

.EXAMPLE
    ./Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipAnalyzer
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Install-IfMissing {
    param([string]$Name, [version]$MinimumVersion)

    $existing = Get-Module -ListAvailable -Name $Name |
        Where-Object { $_.Version -ge $MinimumVersion } |
        Select-Object -First 1

    if (-not $existing) {
        Write-Host "Installing $Name ($MinimumVersion or newer)..."
        Install-Module -Name $Name -MinimumVersion $MinimumVersion -Force -Scope CurrentUser -Repository PSGallery
    }
}

if (-not $SkipAnalyzer) {
    Install-IfMissing -Name 'PSScriptAnalyzer' -MinimumVersion '1.21.0'
    Import-Module PSScriptAnalyzer

    Write-Host 'Running PSScriptAnalyzer...'
    $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
    # Analyze each module file in its own invocation. A single recursive call can make
    # PSScriptAnalyzer build more than one dynamic module in a single dynamic assembly,
    # which throws on some runtimes; per-file invocation avoids that.
    $moduleFiles = Get-ChildItem -Path (Join-Path $root 'LibreDevOpsHelpers') -Recurse -Filter '*.psm1'

    # PSScriptAnalyzer has a long-standing intermittent engine bug that surfaces as a
    # NullReferenceException ("Object reference not set to an instance of an object")
    # from Invoke-ScriptAnalyzer. It is non-deterministic (the same file/commit passes
    # on a re-run) and reproduces even with only the default rule set, so it is not our
    # settings. Normally it is a non-terminating error, but $ErrorActionPreference='Stop'
    # promotes it to a job failure. Retry the affected file a few times before giving up.
    $maxAttempts = 3
    $results = foreach ($file in $moduleFiles) {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings -ErrorAction Stop
                break
            } catch [System.NullReferenceException] {
                if ($attempt -eq $maxAttempts) {
                    throw "PSScriptAnalyzer threw NullReferenceException on '$($file.Name)' after $maxAttempts attempts: $($_.Exception.Message)"
                }
                Write-Warning "PSScriptAnalyzer NullReferenceException on '$($file.Name)' (attempt $attempt/$maxAttempts); retrying..."
                Start-Sleep -Milliseconds 250
            }
        }
    }

    if ($results) {
        $results | Format-Table -AutoSize | Out-String | Write-Host
        $errors = @($results | Where-Object { $_.Severity -eq 'Error' })
        if ($errors.Count -gt 0) {
            throw "PSScriptAnalyzer found $($errors.Count) error(s)."
        }
        Write-Warning "PSScriptAnalyzer found $($results.Count) non-error finding(s)."
    } else {
        Write-Host 'PSScriptAnalyzer: clean.'
    }
}

Install-IfMissing -Name 'Pester' -MinimumVersion '5.5.0'
Import-Module Pester

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root 'tests'
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true

Write-Host 'Running Pester...'
Invoke-Pester -Configuration $config
