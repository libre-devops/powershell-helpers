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
    $results = foreach ($file in $moduleFiles) {
        Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings
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
