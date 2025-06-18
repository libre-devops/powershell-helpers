function Assert-DockerExists {
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

Export-ModuleMember -Function `
    Check-DockerExists, `
    Build-DockerImage, `
    Push-DockerImage
