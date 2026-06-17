<#
.SYNOPSIS
    Builds a Docker image and optionally pushes it to a registry.

.DESCRIPTION
    Builds a Docker image from a Dockerfile (optionally in a subfolder), applies additional tags,
    and optionally pushes them to a registry. Uses the LibreDevOpsHelpers Docker helpers.

.PARAMETER DockerFileName
    Name of the Dockerfile, for example Dockerfile or Dockerfile.alpine.

.PARAMETER DockerImageName
    Base image name, for example base-images/azdo-agent-containers.

.PARAMETER RegistryUrl
    Registry host, for example ghcr.io.

.PARAMETER RegistryUsername
    Registry username.

.PARAMETER RegistryPassword
    Registry password or token. Supplied as a string for pipeline use and converted to a secure
    string before being passed to the registry.

.PARAMETER ImageOrg
    Optional organisation override. Defaults to RegistryUsername.

.PARAMETER WorkingDirectory
    Folder this script runs in. Defaults to the current directory.

.PARAMETER BuildContext
    Docker build context. Defaults to the current directory.

.PARAMETER DebugMode
    'true' or 'false'. Toggles DebugPreference.

.PARAMETER PushDockerImage
    'true' or 'false'. Whether to push after build.

.PARAMETER AdditionalTags
    Extra tags to apply and push. Defaults to latest and the current year-month.

.EXAMPLE
    ./Run-Docker.ps1 -BuildContext "$PWD/containers/alpine" -RegistryUrl ghcr.io `
        -RegistryUsername $Env:GHCR_USER -RegistryPassword $Env:GHCR_TOKEN
#>
param(
    [string]   $DockerFileName = 'Dockerfile',
    [string]   $DockerImageName = 'base-images/azdo-agent-containers',
    [string]   $RegistryUrl = 'ghcr.io',
    [string]   $RegistryUsername,
    [string]   $RegistryPassword,
    [string]   $ImageOrg,
    [string]   $WorkingDirectory = (Get-Location).Path,
    [string]   $BuildContext = (Get-Location).Path,
    [string]   $DebugMode = 'false',
    [string]   $PushDockerImage = 'true',
    [string[]] $AdditionalTags = @('latest', (Get-Date -Format 'yyyy-MM'))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$manifest = Join-Path $scriptDir 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "Module manifest not found: $manifest"
}
Import-Module $manifest -Force -ErrorAction Stop

Set-Location $WorkingDirectory

if (-not $ImageOrg) { $ImageOrg = $RegistryUsername }
$fullImageName = '{0}/{1}/{2}' -f $RegistryUrl, $ImageOrg, $DockerImageName

$debug = ConvertTo-LdoBoolean -Value $DebugMode
$push = ConvertTo-LdoBoolean -Value $PushDockerImage
if ($debug) { $DebugPreference = 'Continue' }

Assert-LdoDockerExists

$dockerfilePath = Join-Path $BuildContext $DockerFileName
Build-LdoDockerImage -DockerfilePath $dockerfilePath -ContextPath $BuildContext -ImageName $fullImageName

$tagsToPush = @()
foreach ($tag in $AdditionalTags) {
    $fullTag = '{0}:{1}' -f $fullImageName, $tag
    Write-LdoLog -Level INFO -Message "Tagging: $fullTag"
    docker tag $fullImageName $fullTag
    if ($LASTEXITCODE -ne 0) {
        throw "docker tag failed for $fullTag (exit $LASTEXITCODE)."
    }
    $tagsToPush += $fullTag
}

if ($push) {
    $securePassword = ConvertTo-SecureString $RegistryPassword -AsPlainText -Force
    Push-LdoDockerImage -FullTagNames $tagsToPush -RegistryUrl $RegistryUrl `
        -RegistryUsername $RegistryUsername -RegistryPassword $securePassword
}

Write-LdoLog -Level SUCCESS -Message 'All done.'
