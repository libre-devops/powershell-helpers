Set-StrictMode -Version Latest

function Install-LdoGuestConfigurationModule {
    <#
    .SYNOPSIS
        Installs the PowerShell modules needed to author and build machine configuration packages.

    .DESCRIPTION
        Installs the GuestConfiguration module (which produces the .zip package and, elsewhere, the
        policy JSON) plus the DSC resource modules used by the Libre DevOps hardening packages:
        PSDscResources (Registry and Script resources for Windows) and, on Linux, nxtools (nxFile,
        nxFileLine, nxScript, nxFileSystemObject for PSDSC v3). The correct PSDesiredStateConfiguration
        is installed per platform: 2.0.7 (stable) for Windows content, 3.0.0 (prerelease) for Linux
        content, matching the machine configuration authoring guidance. The GuestConfiguration module
        only builds on Ubuntu 18+, though the packages it produces run on any supported OS.

    .PARAMETER GuestConfigurationVersion
        GuestConfiguration module version to install. Defaults to the latest available.

    .PARAMETER IncludeLinuxResources
        Also install nxtools and the PSDesiredStateConfiguration 3.0.0 prerelease for building Linux
        (PSDSC v3) packages. Defaults to true on Linux, false on Windows.

    .EXAMPLE
        Install-LdoGuestConfigurationModule

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$GuestConfigurationVersion,
        [Nullable[bool]]$IncludeLinuxResources
    )

    $onLinux = (Get-LdoOperatingSystem).ToLower() -eq 'linux'
    if ($null -eq $IncludeLinuxResources) { $IncludeLinuxResources = $onLinux }

    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

    $gcParams = @{ Name = 'GuestConfiguration'; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true }
    if ($GuestConfigurationVersion) { $gcParams.RequiredVersion = $GuestConfigurationVersion }
    Write-LdoLog -Level INFO -Message 'Installing the GuestConfiguration module from PSGallery.'
    Install-Module @gcParams

    Write-LdoLog -Level INFO -Message 'Installing PSDscResources (Registry and Script resources).'
    Install-Module -Name 'PSDscResources' -Scope CurrentUser -Force -AllowClobber

    if ($IncludeLinuxResources) {
        Write-LdoLog -Level INFO -Message 'Installing nxtools and PSDesiredStateConfiguration 3.0.0 prerelease for Linux content.'
        Install-Module -Name 'nxtools' -Scope CurrentUser -Force -AllowClobber
        Install-Module -Name 'PSDesiredStateConfiguration' -RequiredVersion '3.0.0' -AllowPrerelease -Scope CurrentUser -Force -AllowClobber
    }
    else {
        Write-LdoLog -Level INFO -Message 'Installing PSDesiredStateConfiguration 2.0.7 for Windows content.'
        Install-Module -Name 'PSDesiredStateConfiguration' -RequiredVersion '2.0.7' -Scope CurrentUser -Force -AllowClobber
    }

    Write-LdoLog -Level SUCCESS -Message 'Machine configuration authoring modules installed.'
}

function New-LdoMachineConfigPackage {
    <#
    .SYNOPSIS
        Compiles a DSC configuration and builds a machine configuration package (.zip).

    .DESCRIPTION
        Dot sources the DSC configuration script (which must define a Configuration named -Name and
        invoke it on its last line), which compiles localhost.mof into a folder named after the
        configuration. The MOF is renamed to <Name>.mof and handed to New-GuestConfigurationPackage
        to produce the .zip. Use -Type AuditAndSet (the default) so an assignment can enforce with
        ApplyAndAutoCorrect; Audit builds an audit only package. Returns the full path to the .zip.

    .PARAMETER ConfigurationScript
        Path to the .ps1 that defines and invokes the Configuration.

    .PARAMETER Name
        The configuration and package name. Must match the Configuration keyword name in the script.

    .PARAMETER Type
        Audit or AuditAndSet. AuditAndSet is required for ApplyAndAutoCorrect enforcement.

    .PARAMETER OutputPath
        Working and output directory. Defaults to a fresh temp directory. The .zip lands here.

    .PARAMETER FrequencyMinutes
        Optional evaluation frequency baked into the package.

    .PARAMETER FilesToInclude
        Optional additional files to include in the package (third party content).

    .EXAMPLE
        New-LdoMachineConfigPackage -ConfigurationScript ./configurations/iis-hardening/IISHardening.ps1 -Name IISHardening -Type AuditAndSet

    .OUTPUTS
        System.String. The full path to the built .zip package.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigurationScript,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [ValidateSet('Audit', 'AuditAndSet')][string]$Type = 'AuditAndSet',
        [string]$OutputPath,
        [int]$FrequencyMinutes = 0,
        [string[]]$FilesToInclude = @()
    )

    if (-not (Test-Path $ConfigurationScript)) {
        throw "Configuration script not found: $ConfigurationScript"
    }
    if (-not (Get-Command 'New-GuestConfigurationPackage' -ErrorAction SilentlyContinue)) {
        throw 'The GuestConfiguration module is not available. Run Install-LdoGuestConfigurationModule first.'
    }

    $scriptFull = (Resolve-Path $ConfigurationScript).Path
    if (-not $OutputPath) {
        $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-mc-" + [guid]::NewGuid())
    }
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

    Push-Location $OutputPath
    try {
        # Dot sourcing runs the script, which invokes the Configuration and compiles the MOF into
        # ./<Name>/localhost.mof relative to the current directory.
        Write-LdoLog -Level INFO -Message "Compiling DSC configuration '$Name' from $scriptFull"
        . $scriptFull

        $mofDir = Join-Path $OutputPath $Name
        $mof = Join-Path $mofDir 'localhost.mof'
        if (-not (Test-Path $mof)) {
            throw "Expected compiled MOF not found at $mof. Ensure the Configuration is named '$Name' and the script invokes it on its last line."
        }

        $namedMof = Join-Path $mofDir "$Name.mof"
        Rename-Item -Path $mof -NewName "$Name.mof" -Force

        $params = @{
            Name          = $Name
            Configuration = $namedMof
            Type          = $Type
            Path          = $OutputPath
            Force         = $true
        }
        if ($FrequencyMinutes -gt 0) { $params.FrequencyMinutes = $FrequencyMinutes }
        if (@($FilesToInclude).Count -gt 0) { $params.FilesToInclude = $FilesToInclude }

        Write-LdoLog -Level INFO -Message "Building machine configuration package '$Name' (Type $Type)."
        $pkg = New-GuestConfigurationPackage @params

        $zip = if ($pkg -and $pkg.Path) { $pkg.Path } else { Join-Path $OutputPath "$Name.zip" }
        if (-not (Test-Path $zip)) {
            throw "Package build did not produce a .zip at $zip."
        }
        Write-LdoLog -Level SUCCESS -Message "Built machine configuration package: $zip"
        return $zip
    }
    finally {
        Pop-Location
    }
}

function Test-LdoMachineConfigPackage {
    <#
    .SYNOPSIS
        Validates a built machine configuration package with Test-GuestConfigurationPackage.

    .DESCRIPTION
        Runs the GuestConfiguration module's package test against a built .zip and returns the
        result object. Throws when the module is not available.

    .PARAMETER ZipPath
        Path to the built .zip package.

    .PARAMETER Parameter
        Optional hashtable of configuration parameters to test with.

    .EXAMPLE
        Test-LdoMachineConfigPackage -ZipPath ./IISHardening.zip

    .OUTPUTS
        The Test-GuestConfigurationPackage result object.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ZipPath,
        [hashtable]$Parameter
    )

    if (-not (Test-Path $ZipPath)) { throw "Package not found: $ZipPath" }
    if (-not (Get-Command 'Test-GuestConfigurationPackage' -ErrorAction SilentlyContinue)) {
        throw 'The GuestConfiguration module is not available. Run Install-LdoGuestConfigurationModule first.'
    }

    $params = @{ Path = $ZipPath }
    if ($Parameter) { $params.Parameter = $Parameter }
    Write-LdoLog -Level INFO -Message "Validating machine configuration package: $ZipPath"
    Test-GuestConfigurationPackage @params
}

function Get-LdoMachineConfigPackageHash {
    <#
    .SYNOPSIS
        Returns the UPPERCASE SHA256 of a package .zip (the content_hash the module expects).

    .DESCRIPTION
        Get-FileHash already returns an uppercase hex digest, which is exactly the form the per
        machine assignment content_hash requires. Returned as a plain string.

    .PARAMETER ZipPath
        Path to the .zip package.

    .EXAMPLE
        Get-LdoMachineConfigPackageHash -ZipPath ./IISHardening.zip

    .OUTPUTS
        System.String. The uppercase SHA256 hex digest.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ZipPath
    )

    if (-not (Test-Path $ZipPath)) { throw "Package not found: $ZipPath" }
    (Get-FileHash -Algorithm SHA256 -Path $ZipPath).Hash
}

function Publish-LdoMachineConfigPackage {
    <#
    .SYNOPSIS
        Uploads a machine configuration package to a storage blob and returns its URI and hash.

    .DESCRIPTION
        Uploads the .zip to a storage account container with the Azure CLI (auth-mode login, so the
        signed in identity needs Storage Blob Data Contributor), then returns a hashtable with
        ContentUri and ContentHash ready to feed into machine_configuration_assignments. When
        -SasExpiryHours is supplied a user delegation SAS is appended to ContentUri so a machine can
        download the package without a data-plane role; otherwise the plain blob URL is returned
        (the machine's identity must have read access, or the container must allow anonymous read).

    .PARAMETER ZipPath
        Path to the built .zip package.

    .PARAMETER StorageAccountName
        Target storage account name.

    .PARAMETER ContainerName
        Target container. Must already exist.

    .PARAMETER BlobName
        Blob name. Defaults to the .zip file name.

    .PARAMETER SasExpiryHours
        When set, append a user delegation SAS valid for this many hours to the returned ContentUri.

    .EXAMPLE
        Publish-LdoMachineConfigPackage -ZipPath ./IISHardening.zip -StorageAccountName ldopkgs -ContainerName packages -SasExpiryHours 4

    .OUTPUTS
        System.Collections.Hashtable with keys ContentUri, ContentHash, BlobName.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ZipPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StorageAccountName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ContainerName,
        [string]$BlobName,
        [int]$SasExpiryHours = 0
    )

    if (-not (Test-Path $ZipPath)) { throw "Package not found: $ZipPath" }
    Assert-LdoCommand -Name @('az')

    if (-not $BlobName) { $BlobName = Split-Path $ZipPath -Leaf }

    Write-LdoLog -Level INFO -Message "Uploading $BlobName to $StorageAccountName/$ContainerName"
    az storage blob upload `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name $BlobName `
        --file $ZipPath `
        --auth-mode login `
        --overwrite true `
        --only-show-errors | Out-Null
    Assert-LdoLastExitCode -Operation "upload $BlobName to $StorageAccountName/$ContainerName"

    $uri = (az storage blob url `
            --account-name $StorageAccountName `
            --container-name $ContainerName `
            --name $BlobName `
            --auth-mode login `
            --only-show-errors -o tsv).Trim()
    Assert-LdoLastExitCode -Operation "resolve blob url for $BlobName"

    if ($SasExpiryHours -gt 0) {
        # A user delegation SAS (az generates one with --auth-mode login --as-user) so no account
        # key is needed. The expiry is computed with the fixed helper timestamp form.
        $expiry = (Get-Date).ToUniversalTime().AddHours($SasExpiryHours).ToString('yyyy-MM-ddTHH:mmZ')
        $sas = (az storage blob generate-sas `
                --account-name $StorageAccountName `
                --container-name $ContainerName `
                --name $BlobName `
                --permissions r `
                --expiry $expiry `
                --auth-mode login `
                --as-user `
                --full-uri `
                --only-show-errors -o tsv).Trim()
        Assert-LdoLastExitCode -Operation "generate SAS for $BlobName"
        $uri = $sas
    }

    $hash = Get-LdoMachineConfigPackageHash -ZipPath $ZipPath
    Write-LdoLog -Level SUCCESS -Message "Published $BlobName (hash $hash)."

    @{ ContentUri = $uri; ContentHash = $hash; BlobName = $BlobName }
}

Export-ModuleMember -Function `
    Install-LdoGuestConfigurationModule, `
    New-LdoMachineConfigPackage, `
    Test-LdoMachineConfigPackage, `
    Get-LdoMachineConfigPackageHash, `
    Publish-LdoMachineConfigPackage
