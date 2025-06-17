# Define module name and path
$moduleName = "LibreDevOpsHelpers"
$modulePath = ".\LibreDevOpsHelpers"
$psd1Path   = "$modulePath\$moduleName.psd1"

# Get API key from environment
$nugetToken = $Env:NUGET_API_KEY

# Register PowerShell Gallery as a PSResource repository (if not already)
if (-not (Get-PSResourceRepository -Name "PSGallery" -ErrorAction SilentlyContinue)) {
    Register-PSResourceRepository -Name "PSGallery" -Uri "https://www.powershellgallery.com/api/v2" -Trusted
}

Write-Host "Publishing to PowerShell Gallery..."

# Build splat for Publish-PSResource
$PublishSplat = @{
    Path                 = $psd1Path
    Repository           = "PSGallery"
    ApiKey               = $nugetToken
    SkipDependenciesCheck = $true
}

# Optional: handle RequiredModules edge case
$ManifestData = Import-PowerShellDataFile -Path $psd1Path
if ($ManifestData.RequiredModules) {
    $PublishSplat.SkipModuleManifestValidate = $true
}

Publish-PSResource @PublishSplat

Write-Host "Done publishing to PSGallery."
