[CmdletBinding()]
param(
    [string]$WorkingDirectory = $PSScriptRoot,
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'

if ($WorkingDirectory) {
    Set-Location -Path $WorkingDirectory
}

# Define module name and path
$moduleName = 'LibreDevOpsHelpers'
$modulePath = Join-Path '.' $moduleName
$psd1Path = Join-Path $modulePath "$moduleName.psd1"

# Resolve the API key: explicit parameter first, then the local env var, then the
# name used by the CI workflow.
if (-not $ApiKey) {
    $ApiKey = $Env:PSGALLERY_TOKEN
}
if (-not $ApiKey) {
    $ApiKey = $Env:NUGET_API_KEY
}
if (-not $ApiKey) {
    throw 'No API key found. Set PSGALLERY_TOKEN or NUGET_API_KEY, or pass -ApiKey.'
}

# Fail early if the manifest is invalid rather than during upload.
Write-Host "Validating manifest: $psd1Path"
Test-ModuleManifest -Path $psd1Path | Out-Null

# Register PowerShell Gallery as a PSResource repository (if not already)
if (-not (Get-PSResourceRepository -Name 'PSGallery' -ErrorAction SilentlyContinue)) {
    Register-PSResourceRepository -Name 'PSGallery' -Uri 'https://www.powershellgallery.com/api/v2' -Trusted
}

Write-Host 'Publishing to PowerShell Gallery...'

$publishSplat = @{
    Path                  = $psd1Path
    Repository            = 'PSGallery'
    ApiKey                = $ApiKey
    SkipDependenciesCheck = $true
}

# Handle the RequiredModules edge case
$manifestData = Import-PowerShellDataFile -Path $psd1Path
if ($manifestData.RequiredModules) {
    $publishSplat.SkipModuleManifestValidate = $true
}

Publish-PSResource @publishSplat

Write-Host "Done publishing $moduleName $($manifestData.ModuleVersion) to PSGallery."
