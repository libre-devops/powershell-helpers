# Define module name and path
$moduleName = "LibreDevOpsHelpers"
$modulePath = ".\LibreDevOpsHelpers"
$psd1Path   = "$modulePath\$moduleName.psd1"

# GitHub Packages settings
$githubOwner = $env:GITHUB_REPOSITORY_OWNER  # e.g. "libre-devops"
$githubToken = $env:GITHUB_TOKEN
$repoName    = "GitHubPackages"
$githubUri   = "https://nuget.pkg.github.com/$githubOwner/index.json"

# Register GitHub repository (if not already)
if (-not (Get-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue)) {
    Register-PSResourceRepository -Name $repoName -Uri $githubUri
}

Write-Host "Publishing to GitHub Packages..."

# Build splat for Publish-PSResource
$PublishSplat = @{
    Path                 = $psd1Path
    Repository           = $repoName
    ApiKey               = $githubToken
    SkipDependenciesCheck = $true
}

# Optional: Skip module validation if RequiredModules are present
$ManifestData = Import-PowerShellDataFile -Path $psd1Path
if ($ManifestData.RequiredModules) {
    $PublishSplat.SkipModuleManifestValidate = $true
}

Publish-PSResource @PublishSplat

# Clean up if needed
Write-Host "Unregistering GitHubPackages repository..."
Unregister-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue

Write-Host "Done publishing to GitHub Packages."
