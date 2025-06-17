<#
.SYNOPSIS
    Automate Docker build & optional push to a registry.

.DESCRIPTION
    'Run-Docker.ps1' builds a Docker image from a specified Dockerfile (possibly
    living in a subfolder) and optionally pushes it (with multiple tags) to your registry.

.PARAMETERS
    DockerFileName    – Name of the Dockerfile (e.g. “Dockerfile” or “Dockerfile.alpine”).
    DockerImageName   – Base image name (e.g. “base-images/azdo-agent-containers”).
    RegistryUrl       – e.g. “ghcr.io”.
    RegistryUsername  – Your registry user.
    RegistryPassword  – Your registry password (will be piped in securely).
    ImageOrg          – Optional override for your org; defaults to RegistryUsername.
    WorkingDirectory  – Where this PowerShell script runs (default = current folder).
    BuildContext      – Docker build context (defaults to same as WorkingDirectory).
    DebugMode         – “true”/“false”; toggles `$DebugPreference`.
    PushDockerImage   – “true”/“false”; whether to push after build.
    AdditionalTags    – Array of extra tags (default = latest + yyyy-MM).

.EXAMPLE
    .\Run-Docker.ps1 `
      -WorkingDirectory $PWD `
      -BuildContext       "$PWD/containers/alpine" `
      -DockerFileName     "Dockerfile" `
      -RegistryUrl        "ghcr.io" `
      -RegistryUsername   $Env:GHCR_USER `
      -RegistryPassword   $Env:GHCR_TOKEN `
      -AdditionalTags     @("latest", (Get-Date -Format "yyyy.MM.dd"))

.NOTES
    - Ensure Docker is installed and in PATH.
    - Credentials should come from environment variables or a secret store.
    - Tested on Windows, Linux, macOS hosts.

#>

param (
    [string]   $DockerFileName    = "Dockerfile",
    [string]   $DockerImageName   = "base-images/azdo-agent-containers",
    [string]   $RegistryUrl       = "ghcr.io",
    [string]   $RegistryUsername,
    [string]   $RegistryPassword,
    [string]   $ImageOrg,
    [string]   $WorkingDirectory  = (Get-Location).Path,
    [string]   $BuildContext      = (Get-Location).Path,
    [string]   $DebugMode         = "false",
    [string]   $PushDockerImage   = "true",
    [string[]] $AdditionalTags    = @("latest", (Get-Date -Format "yyyy-MM"))
)

function Convert-ToBoolean {
    param($value)
    switch ($value.ToLower()) {
        "true"  { return $true }
        "false" { return $false }
        default {
            Write-Error "Invalid boolean: $value"; exit 1
        }
    }
}

function Check-DockerExists {
    try {
        $d = Get-Command docker -ErrorAction Stop
        Write-Host "✔ Docker found: $($d.Source)"
    } catch {
        Write-Error "Docker not found in PATH. Aborting."; exit 1
    }
}

function Build-DockerImage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $DockerfilePath,      # e.g. "containers/ubuntu/Dockerfile"
        [string] $ContextPath = '.'     # e.g. ".", or override to repo root
    )

    # resolve full paths
    $fullDockerfilePath = Resolve-Path -Path $DockerfilePath -ErrorAction Stop
    $fullContextPath    = Resolve-Path -Path $ContextPath    -ErrorAction Stop

    if (-not (Test-Path $fullDockerfilePath)) {
        Write-Error "Dockerfile not found at $fullDockerfilePath"; return $false
    }
    if (-not (Test-Path $fullContextPath)) {
        Write-Error "Build context not found at $fullContextPath"; return $false
    }

    Write-Host "⏳ Building '$DockerImageName' from Dockerfile: $fullDockerfilePath"
    Write-Host "    context: $fullContextPath"

    docker build `
        -f $fullDockerfilePath `
        -t $DockerImageName `
        $fullContextPath | Out-Host

    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker build failed (exit $LASTEXITCODE)"; return $false
    }
    return $true
}


function Push-DockerImage {
    param([string[]] $FullTagNames)

    Write-Host "🔐 Logging in to $RegistryUrl"
    $RegistryPassword | docker login $RegistryUrl -u $RegistryUsername --password-stdin
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker login failed (exit $LASTEXITCODE)"; return $false
    }

    foreach ($tag in $FullTagNames) {
        Write-Host "📤 Pushing $tag"
        docker push $tag | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Error "docker push failed for $tag (exit $LASTEXITCODE)"
        }
    }

    Write-Host "🚪 Logging out"
    docker logout $RegistryUrl | Out-Host
    return $true
}

### Main

# switch to working folder
Set-Location $WorkingDirectory

# build full image name
if (-not $ImageOrg) { $ImageOrg = $RegistryUsername }
$DockerImageName = "{0}/{1}/{2}" -f $RegistryUrl, $ImageOrg, $DockerImageName

# convert booleans
$DebugMode       = Convert-ToBoolean $DebugMode
$PushDockerImage = Convert-ToBoolean $PushDockerImage
if ($DebugMode) { $DebugPreference = "Continue" }

# build
Check-DockerExists
if (-not (Build-DockerImage -ContextPath $BuildContext -DockerFile $DockerFileName)) {
    Write-Error "Build failed"; exit 1
}

# tag extras
foreach ($tag in $AdditionalTags) {
    $fullTag = "{0}:{1}" -f $DockerImageName, $tag
    Write-Host "🏷 Tagging: $fullTag"
    docker tag $DockerImageName $fullTag
}

# push if requested
if ($PushDockerImage) {
    $tagsToPush = $AdditionalTags | ForEach-Object { "{0}:{1}" -f $DockerImageName, $_ }
    if (-not (Push-DockerImage -FullTagNames $tagsToPush)) {
        Write-Error "Push failed"; exit 1
    }
}

Write-Host "✅ All done." -ForegroundColor Green
