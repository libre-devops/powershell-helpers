Set-StrictMode -Version Latest

function Assert-LdoDockerExists {
    <#
    .SYNOPSIS
        Ensures the docker CLI is available on PATH.

    .DESCRIPTION
        Throws when the docker command cannot be found, otherwise logs its location.

    .EXAMPLE
        Assert-LdoDockerExists

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Assertion that docker exists.')]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $d = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $d) {
        throw 'Docker not found in PATH.'
    }
    Write-LdoLog -Level INFO -Message "Docker found: $($d.Source)"
}

function Build-LdoDockerImage {
    <#
    .SYNOPSIS
        Builds a Docker image from a Dockerfile.

    .DESCRIPTION
        Runs docker build with the given Dockerfile, build context, and image tag. Throws on
        failure.

    .PARAMETER DockerfilePath
        Path to the Dockerfile.

    .PARAMETER ContextPath
        Build context path. Defaults to the current directory.

    .PARAMETER ImageName
        Full image name including tag, for example myrepo/app:1.0.0.

    .EXAMPLE
        Build-LdoDockerImage -DockerfilePath ./Dockerfile -ImageName myrepo/app:1.0.0

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DockerfilePath,
        [string]$ContextPath = '.',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ImageName
    )

    $fullDockerfilePath = Resolve-Path -Path $DockerfilePath -ErrorAction Stop
    $fullContextPath = Resolve-Path -Path $ContextPath -ErrorAction Stop

    Write-LdoLog -Level INFO -Message "Building '$ImageName' from Dockerfile: $fullDockerfilePath"
    Write-LdoLog -Level INFO -Message "Build context: $fullContextPath"

    docker build -f $fullDockerfilePath -t $ImageName $fullContextPath | Out-Host
    Assert-LdoLastExitCode -Operation 'docker build'
    Write-LdoLog -Level SUCCESS -Message "Built '$ImageName'."
}

function Push-LdoDockerImage {
    <#
    .SYNOPSIS
        Logs in to a registry and pushes one or more image tags.

    .DESCRIPTION
        Logs in to the registry using the supplied credentials via --password-stdin, pushes each
        tag, then logs out. Throws when login fails or when any push fails.

    .PARAMETER FullTagNames
        One or more fully qualified image tags to push.

    .PARAMETER RegistryUrl
        Registry URL to log in to.

    .PARAMETER RegistryUsername
        Registry username.

    .PARAMETER RegistryPassword
        Registry password or token, supplied as a secure string.

    .EXAMPLE
        Push-LdoDockerImage -FullTagNames myrepo/app:1.0.0 -RegistryUrl myregistry.azurecr.io -RegistryUsername user -RegistryPassword $secret

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$FullTagNames,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RegistryUrl,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RegistryUsername,
        [Parameter(Mandatory)][securestring]$RegistryPassword
    )

    $plainPassword = [System.Net.NetworkCredential]::new('', $RegistryPassword).Password

    Write-LdoLog -Level INFO -Message "Logging in to $RegistryUrl"
    $plainPassword | docker login $RegistryUrl -u $RegistryUsername --password-stdin
    Assert-LdoLastExitCode -Operation 'docker login'

    try {
        foreach ($tag in $FullTagNames) {
            Write-LdoLog -Level INFO -Message "Pushing $tag"
            docker push $tag | Out-Host
            Assert-LdoLastExitCode -Operation "docker push ($tag)"
        }
        Write-LdoLog -Level SUCCESS -Message "Pushed $($FullTagNames.Count) tag(s)."
    }
    finally {
        Write-LdoLog -Level INFO -Message 'Logging out'
        docker logout $RegistryUrl | Out-Host
    }
}

Export-ModuleMember -Function `
    Assert-LdoDockerExists, `
    Build-LdoDockerImage, `
    Push-LdoDockerImage
