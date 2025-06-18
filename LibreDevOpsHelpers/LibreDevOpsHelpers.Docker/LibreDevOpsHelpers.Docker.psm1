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
    param(
        [Parameter(Mandatory)]
        [string] $DockerfilePath,          # e.g. containers/ubuntu/Dockerfile

        [string] $ContextPath = '.',       # build context

        [Parameter(Mandatory)]
        [string] $ImageName                # FULL repo/name:tag
    )

    # resolve paths …
    $fullDockerfilePath = Resolve-Path -Path $DockerfilePath -EA Stop
    $fullContextPath    = Resolve-Path -Path $ContextPath    -EA Stop
    # (sanity-checks unchanged)

    Write-Host "⏳ Building '$ImageName' from Dockerfile: $fullDockerfilePath"
    Write-Host "    context: $fullContextPath"

    docker build `
        -f $fullDockerfilePath `
        -t $ImageName `
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
    Assert-DockerExists, `
    Build-DockerImage, `
    Push-DockerImage
