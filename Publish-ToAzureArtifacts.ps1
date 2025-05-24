# Define module name and path
$moduleName = "LibreDevOpsHelpers"
$modulePath = ".\LibreDevOpsHelpers"
$psd1Path   = "$modulePath\$moduleName.psd1"

# Azure DevOps feed info
$organization  = $Env:AZDO_ORG_NAME  # e.g. "mydevopsorg"
$project       = $Env:AZDO_PROJECT_NAME  # optional; use if feed is project-scoped
$feedName      = $Env:AZDO_FEED_NAME  # e.g. "PowerShellModules"
$repoName      = "AzureArtifacts"
$aadToken      = $env:AZDO_ARTIFACTS_PAT  # Use a Personal Access Token with Packaging (Read & Write)

# Build URI (use project-scoped if needed)
$azureUri = "https://pkgs.dev.azure.com/$organization/_packaging/$project/nuget/v3/index.json"  # or with project: /$project/_packaging/...

# Register repository
if (-not (Get-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue)) {
    Register-PSResourceRepository -Name $repoName -Uri $azureUri
}

Write-Host "Publishing to Azure Artifacts..."

# Build splat
$PublishSplat = @{
    Path                 = $psd1Path
    Repository           = $repoName
    ApiKey               = $aadToken
    SkipDependenciesCheck = $true
}

# Handle RequiredModules
$ManifestData = Import-PowerShellDataFile -Path $psd1Path
if ($ManifestData.RequiredModules) {
    $PublishSplat.SkipModuleManifestValidate = $true
}

Publish-PSResource @PublishSplat

Write-Host "Unregistering Azure Artifacts repository..."
Unregister-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue

Write-Host "Done publishing to Azure Artifacts."
