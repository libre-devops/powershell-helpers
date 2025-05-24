# ─── CONFIG ─────────────────────────────────────────────────────────────────────
$moduleName    = "LibreDevOpsHelpers"
$moduleVersion = "0.1.0"  # Sync with your .psd1 version
$moduleFolder  = "$moduleName"  # assumes ./LibreDevOpsHelpers exists
$nuspecPath    = "$moduleName.nuspec"
$outputDir     = Join-Path $env:TEMP "$moduleName-out"
$nugetExePath  = ".\nuget.exe"

$organization  = $env:AZDO_ORG_NAME
$feedName      = $env:AZDO_FEED_NAME
$aadToken      = $env:AZDO_ARTIFACTS_PAT
$repoName      = "AzureArtifacts"
$nugetConfigPath = Join-Path $env:TEMP "nuget.config"
$nugetPushUri  = "https://pkgs.dev.azure.com/$organization/_packaging/$feedName/nuget/v3/index.json"

if (-not $organization -or -not $feedName -or -not $aadToken) {
    throw "❌ Missing AZDO_ORG_NAME, AZDO_FEED_NAME, or AZDO_ARTIFACTS_PAT environment variables."
}

# ─── CLEANUP PREVIOUS ───────────────────────────────────────────────────────────
Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outputDir
Remove-Item -Force -ErrorAction SilentlyContinue $nuspecPath
Remove-Item -Force -ErrorAction SilentlyContinue $nugetConfigPath

# ─── DOWNLOAD NUGET.EXE IF MISSING ──────────────────────────────────────────────
if (-not (Test-Path $nugetExePath)) {
    Write-Host "📥 Downloading nuget.exe..."
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" `
                      -OutFile $nugetExePath
}

# ─── GENERATE .NUSPEC ───────────────────────────────────────────────────────────
Write-Host "📦 Creating .nuspec..."
$nuspecContent = @"
<?xml version="1.0"?>
<package>
  <metadata>
    <id>$moduleName</id>
    <version>$moduleVersion</version>
    <authors>Libre DevOps</authors>
    <owners>Libre DevOps</owners>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <description>Helper functions for Libre DevOps projects</description>
  </metadata>
  <files>
    <file src="$moduleFolder\**\*" target="tools\$moduleName" />
  </files>
</package>
"@
Set-Content -Path $nuspecPath -Value $nuspecContent -Encoding UTF8 -Force

# ─── PACK MODULE ────────────────────────────────────────────────────────────────
Write-Host "📦 Running nuget pack..."
& $nugetExePath pack $nuspecPath -OutputDirectory $outputDir -BasePath "." | Write-Host

$nupkg = Get-ChildItem -Path $outputDir -Filter "*.nupkg" | Select-Object -First 1
if (-not $nupkg) {
    throw "❌ .nupkg not created. Check module folder path and nuspec format."
}
Write-Host "📦 Created package: $($nupkg.FullName)"

# ─── CREATE TEMP NUGET.CONFIG ───────────────────────────────────────────────────
Write-Host "🔐 Creating temporary nuget.config..."
$nugetXml = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="$repoName" value="$nugetPushUri" />
  </packageSources>
  <packageSourceCredentials>
    <$repoName>
      <add key="Username" value="AzureDevOps" />
      <add key="ClearTextPassword" value="$aadToken" />
    </$repoName>
  </packageSourceCredentials>
</configuration>
"@
Set-Content -Path $nugetConfigPath -Value $nugetXml -Encoding UTF8 -Force

# ─── REGISTER SOURCE (DOTNET) ───────────────────────────────────────────────────
$existingSources = & dotnet nuget list source --configfile $nugetConfigPath
if ($existingSources -match $repoName) {
    & dotnet nuget remove source $repoName --configfile $nugetConfigPath | Out-Null
}
& dotnet nuget add source $nugetPushUri `
    --name $repoName `
    --username AzureDevOps `
    --password $aadToken `
    --store-password-in-clear-text `
    --configfile $nugetConfigPath | Out-Null

# ─── PUSH PACKAGE ───────────────────────────────────────────────────────────────
Write-Host "🚀 Pushing to Azure Artifacts..."
& dotnet nuget push $nupkg.FullName `
  --source $nugetPushUri `
  --api-key AzureDevOps `
  --configfile $nugetConfigPath `
  --skip-duplicate


# ─── CLEANUP ─────────────────────────────────────────────────────────────────────
Write-Host "🧹 Cleaning up..."
Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $outputDir
Remove-Item -Force -ErrorAction SilentlyContinue $nuspecPath
Remove-Item -Force -ErrorAction SilentlyContinue $nugetConfigPath

Write-Host "✅ Successfully published $moduleName to Azure Artifacts."
