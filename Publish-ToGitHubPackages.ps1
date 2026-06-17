[CmdletBinding()]
param(
    [string]$WorkingDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

if ($WorkingDirectory) {
    Set-Location -Path $WorkingDirectory
}

$moduleName = 'LibreDevOpsHelpers'
$modulePath = Join-Path '.' $moduleName
$psd1Path = Join-Path $modulePath "$moduleName.psd1"

# GitHub Packages settings
$githubOwner = $env:GITHUB_REPOSITORY_OWNER
$githubToken = $env:GITHUB_TOKEN
$repoName = 'GitHubPackages'
$githubUri = "https://nuget.pkg.github.com/$githubOwner/index.json"

if (-not $githubToken) {
    throw 'No GitHub token found. Set GITHUB_TOKEN.'
}

# Fail early if the manifest is invalid rather than during upload.
Write-Host "Validating manifest: $psd1Path"
$version = (Test-ModuleManifest -Path $psd1Path).Version.ToString()

# Register GitHub repository (if not already)
if (-not (Get-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue)) {
    Register-PSResourceRepository -Name $repoName -Uri $githubUri
}

try {
    Write-Host 'Publishing to GitHub Packages...'

    $publishSplat = @{
        Path                  = $psd1Path
        Repository            = $repoName
        ApiKey                = $githubToken
        SkipDependenciesCheck = $true
    }

    $manifestData = Import-PowerShellDataFile -Path $psd1Path
    if ($manifestData.RequiredModules) {
        $publishSplat.SkipModuleManifestValidate = $true
    }

    try {
        Publish-PSResource @publishSplat
        Write-Host "Done publishing $moduleName $version to GitHub Packages."
    }
    catch {
        # Idempotency: the feed returns a conflict if the version already exists. Skip
        # cleanly so a re-run (for example a push that touches a psd1 without a version
        # bump) does not fail the pipeline.
        if ($_.Exception.Message -match '409|already exists|conflict') {
            Write-Host "$moduleName $version is already published to GitHub Packages; nothing to do."
        }
        else {
            throw
        }
    }
}
finally {
    Write-Host 'Unregistering GitHubPackages repository...'
    Unregister-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue
}
