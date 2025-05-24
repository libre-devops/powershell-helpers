# Define module name and path
$moduleName = "LibreDevOpsHelpers"
$modulePath = ".\LibreDevOpsHelpers"
$psd1Path   = "$modulePath\$moduleName.psd1"

# Azure Artifacts config
$organization = $Env:AZDO_ORG_NAME
$feedName     = $Env:AZDO_FEED_NAME
$repoName     = "AzureArtifacts"
$aadToken     = $Env:AZDO_ARTIFACTS_PAT

# Use NuGet v3 feed URL
$azureUri = "https://pkgs.dev.azure.com/$organization/_packaging/$feedName/nuget/v3/index.json"

# Path for temporary config
$tempNugetConfig = Join-Path $env:TEMP "nuget.config"

# Build temporary NuGet config content
$nugetXml = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="$repoName" value="$azureUri" />
  </packageSources>
  <packageSourceCredentials>
    <$repoName>
      <add key="Username" value="AzureDevOps" />
      <add key="ClearTextPassword" value="$aadToken" />
    </$repoName>
  </packageSourceCredentials>
</configuration>
"@

# Write it out cleanly
Set-Content -Path $tempNugetConfig -Value $nugetXml -Encoding UTF8 -Force

# Remove existing dotnet source if exists
$existingSources = & dotnet nuget list source --configfile $tempNugetConfig
if ($existingSources -match $repoName) {
    & dotnet nuget remove source $repoName --configfile $tempNugetConfig
}

# Add dotnet nuget source for auth
& dotnet nuget add source $azureUri `
    --name $repoName `
    --username 'AzureDevOps' `
    --password $aadToken `
    --store-password-in-clear-text `
    --configfile $tempNugetConfig

# Register PSResource repo if needed
if (-not (Get-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue)) {
    Register-PSResourceRepository -Name $repoName -Uri $azureUri -Trusted
}

Write-Host "Publishing to Azure Artifacts..."

# Build publish splat
$PublishSplat = @{
    Path                  = $psd1Path
    Repository            = $repoName
    SkipDependenciesCheck = $true
}

# Optional validation skip
$ManifestData = Import-PowerShellDataFile -Path $psd1Path
if ($ManifestData.RequiredModules) {
    $PublishSplat.SkipModuleManifestValidate = $true
}

# Force nuget config to be discoverable
$env:NUGET_CONFIG_FILE = $tempNugetConfig

# Publish
Publish-PSResource @PublishSplat

# Cleanup
Unregister-PSResourceRepository -Name $repoName -ErrorAction SilentlyContinue
Remove-Item $tempNugetConfig -Force -ErrorAction SilentlyContinue
Remove-Item Env:NUGET_CONFIG_FILE

Write-Host "✅ Done publishing to Azure Artifacts."
