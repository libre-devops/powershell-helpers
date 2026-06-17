Set-StrictMode -Version Latest

function Assert-LdoFuncExitCode {
    # Internal. Throws when the last native command exited non-zero.
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-LdoFuncPublicIpAddress {
    # Internal. Returns the caller's public IPv4 address.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $ip = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw 'Failed to determine the public IP address.'
    }
    return $ip
}

function Compress-LdoFunctionAppSource {
    <#
    .SYNOPSIS
        Compresses a function app source folder into a deployment zip.

    .PARAMETER SourcePath
        Path to the source folder to package.

    .PARAMETER ZipPath
        Destination path for the zip file.

    .PARAMETER Overwrite
        Overwrite the destination zip if it already exists.

    .EXAMPLE
        Compress-LdoFunctionAppSource -SourcePath ./src -ZipPath ./out.zip -Overwrite

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ZipPath,

        [switch]$Overwrite
    )

    if (Test-Path $ZipPath) {
        if (-not $Overwrite) {
            throw "ZipPath already exists: $ZipPath (use -Overwrite)."
        }
        Write-LdoLog -Level INFO -Message "Overwriting existing zip: $ZipPath"
        Remove-Item -Path $ZipPath -Force
    }

    Write-LdoLog -Level INFO -Message "Creating deployment package: $ZipPath"
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($SourcePath, $ZipPath)

    if (-not (Test-Path $ZipPath)) {
        throw 'Zip creation failed.'
    }

    $sizeMb = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
    Write-LdoLog -Level SUCCESS -Message "Created $ZipPath ($sizeMb MB)."
}

function Invoke-LdoFunctionAppZipDeploy {
    <#
    .SYNOPSIS
        Deploys a zip package (or a folder) to a function app via the Azure CLI.

    .DESCRIPTION
        Deploys the given zip using 'az functionapp deployment source config-zip'. When a
        folder is supplied it is compressed to a temporary zip first and cleaned up after.
        Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the function app.

    .PARAMETER FunctionAppName
        Name of the function app.

    .PARAMETER ZipPath
        Path to a zip file or a source folder.

    .PARAMETER RestartOnFinish
        Restart the function app after a successful deployment.

    .PARAMETER CliExtraArgsJson
        Optional JSON array of extra arguments appended to the az command.

    .EXAMPLE
        Invoke-LdoFunctionAppZipDeploy -ResourceGroup rg -FunctionAppName app -ZipPath ./out.zip

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FunctionAppName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ZipPath,
        [switch]$RestartOnFinish,
        [string]$CliExtraArgsJson
    )

    $tempZip = $null
    try {
        if (Test-Path $ZipPath -PathType Container) {
            $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + '.zip')
            Compress-Archive -Path (Join-Path (Resolve-Path $ZipPath).Path '*') -DestinationPath $tempZip -Force
            Write-LdoLog -Level INFO -Message "Compressed folder '$ZipPath' to '$tempZip'."
            $ZipPath = $tempZip
        }

        $extraArgs = @()
        if ($CliExtraArgsJson) {
            $parsed = $CliExtraArgsJson | ConvertFrom-Json
            if ($parsed -isnot [System.Collections.IEnumerable] -or $parsed -is [string]) {
                throw 'CliExtraArgsJson must be a JSON array.'
            }
            $extraArgs = [string[]]$parsed
        }

        $cli = @('functionapp', 'deployment', 'source', 'config-zip',
            '--resource-group', $ResourceGroup, '--name', $FunctionAppName,
            '--src', (Resolve-Path $ZipPath).Path)
        if ($extraArgs) { $cli += $extraArgs }

        Write-LdoLog -Level INFO -Message "Deploying zip to $FunctionAppName."
        az @cli | Out-Null
        Assert-LdoFuncExitCode -Operation "az functionapp deployment ($FunctionAppName)"

        if ($RestartOnFinish) {
            Write-LdoLog -Level INFO -Message "Restarting function app $FunctionAppName."
            az functionapp restart --resource-group $ResourceGroup --name $FunctionAppName | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-LdoLog -Level WARN -Message "Restart of $FunctionAppName returned exit code $LASTEXITCODE."
            }
        }

        Write-LdoLog -Level SUCCESS -Message "Deployment complete on $FunctionAppName."
    }
    finally {
        if ($tempZip -and (Test-Path $tempZip)) {
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            Write-LdoLog -Level DEBUG -Message 'Removed temporary zip.'
        }
    }
}

function Get-LdoFunctionAppDefaultUrl {
    <#
    .SYNOPSIS
        Returns the default HTTPS URL of a function app.

    .PARAMETER ResourceGroup
        Resource group containing the function app.

    .PARAMETER FunctionAppName
        Name of the function app.

    .EXAMPLE
        Get-LdoFunctionAppDefaultUrl -ResourceGroup rg -FunctionAppName app

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FunctionAppName
    )

    $hostName = az functionapp show --resource-group $ResourceGroup --name $FunctionAppName --query 'defaultHostName' -o tsv
    Assert-LdoFuncExitCode -Operation "az functionapp show ($FunctionAppName)"
    if (-not $hostName) {
        throw "Unable to retrieve the default host name for $FunctionAppName."
    }

    $url = "https://$hostName"
    Write-LdoLog -Level INFO -Message "Function app default URL: $url"
    return $url
}

function Set-LdoFunctionAppSetting {
    <#
    .SYNOPSIS
        Applies application settings to a function app from JSON.

    .DESCRIPTION
        Accepts either a JSON string or a path to a JSON file, validates it, writes it to a
        temporary file and applies it with 'az functionapp config appsettings set'. Requires
        the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the function app.

    .PARAMETER FunctionAppName
        Name of the function app.

    .PARAMETER SettingsJsonOrPath
        A JSON string or a path to a .json file describing the settings.

    .EXAMPLE
        Set-LdoFunctionAppSetting -ResourceGroup rg -FunctionAppName app -SettingsJsonOrPath ./settings.json

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FunctionAppName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SettingsJsonOrPath
    )

    $tempFile = $null
    try {
        if (Test-Path $SettingsJsonOrPath -PathType Leaf) {
            $json = Get-Content $SettingsJsonOrPath -Raw
            Write-LdoLog -Level DEBUG -Message "Using settings JSON from file: $SettingsJsonOrPath"
        }
        else {
            $json = $SettingsJsonOrPath
            Write-LdoLog -Level DEBUG -Message 'Using in-memory settings JSON.'
        }

        try {
            $null = $json | ConvertFrom-Json
        }
        catch {
            throw "SettingsJsonOrPath is not valid JSON: $($_.Exception.Message)"
        }

        $tempFile = New-TemporaryFile
        Set-Content -Path $tempFile -Value $json -Encoding UTF8

        Write-LdoLog -Level INFO -Message "Applying app settings to $FunctionAppName."
        az functionapp config appsettings set --resource-group $ResourceGroup --name $FunctionAppName --settings "@$tempFile" | Out-Null
        Assert-LdoFuncExitCode -Operation "az functionapp config appsettings set ($FunctionAppName)"

        Write-LdoLog -Level SUCCESS -Message "Updated app settings on $FunctionAppName."
    }
    finally {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-LdoFunctionAppCurrentIpRule {
    <#
    .SYNOPSIS
        Grants the caller's public IP access to a function app.

    .DESCRIPTION
        Enables public network access, applies the default action to both the main and SCM
        sites, and adds an access-restriction rule for the caller's current public IP.
        Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the function app.

    .PARAMETER FunctionAppName
        Name of the function app.

    .PARAMETER RuleName
        Name of the access-restriction rule. Defaults to 'AllowCurrentIp'.

    .PARAMETER Priority
        Rule priority (100-65000). Defaults to 1000.

    .PARAMETER Action
        Allow or Deny. Defaults to Allow.

    .EXAMPLE
        Add-LdoFunctionAppCurrentIpRule -ResourceGroup rg -FunctionAppName app

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FunctionAppName,
        [string]$RuleName = 'AllowCurrentIp',
        [ValidateRange(100, 65000)][int]$Priority = 1000,
        [ValidateSet('Allow', 'Deny')][string]$Action = 'Allow'
    )

    $ip = Get-LdoFuncPublicIpAddress
    Write-LdoLog -Level INFO -Message "Current public IP: $ip"

    # See https://github.com/Azure/azure-cli/issues/24947 for why both flags are set.
    az functionapp update -g $ResourceGroup -n $FunctionAppName --set publicNetworkAccess=Enabled siteConfig.publicNetworkAccess=Enabled | Out-Null
    Assert-LdoFuncExitCode -Operation "az functionapp update ($FunctionAppName)"

    az functionapp config access-restriction set -g $ResourceGroup -n $FunctionAppName --default-action $Action --scm-default-action $Action --use-same-restrictions-for-scm-site true | Out-Null
    Assert-LdoFuncExitCode -Operation "az functionapp access-restriction set ($FunctionAppName)"

    az functionapp config access-restriction add -g $ResourceGroup -n $FunctionAppName --rule-name $RuleName --action $Action --priority $Priority --ip-address $ip | Out-Null
    Assert-LdoFuncExitCode -Operation "az functionapp access-restriction add ($FunctionAppName)"

    Write-LdoLog -Level INFO -Message "Added access rule '$RuleName' for $ip on $FunctionAppName."
}

function Remove-LdoFunctionAppCurrentIpRule {
    <#
    .SYNOPSIS
        Removes a function app access-restriction rule and locks the app down.

    .DESCRIPTION
        Removes the named access-restriction rule, sets the default action to Deny on both
        the main and SCM sites, and disables public network access. Requires the Azure CLI to
        be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the function app.

    .PARAMETER FunctionAppName
        Name of the function app.

    .PARAMETER RuleName
        Name of the access-restriction rule to remove. Defaults to 'AllowCurrentIp'.

    .EXAMPLE
        Remove-LdoFunctionAppCurrentIpRule -ResourceGroup rg -FunctionAppName app

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FunctionAppName,
        [string]$RuleName = 'AllowCurrentIp'
    )

    az functionapp config access-restriction remove -g $ResourceGroup -n $FunctionAppName --rule-name $RuleName 2>$null | Out-Null

    az functionapp config access-restriction set -g $ResourceGroup -n $FunctionAppName --default-action Deny --scm-default-action Deny --use-same-restrictions-for-scm-site true | Out-Null
    Assert-LdoFuncExitCode -Operation "az functionapp access-restriction set ($FunctionAppName)"

    az functionapp update -g $ResourceGroup -n $FunctionAppName --set publicNetworkAccess=Disabled siteConfig.publicNetworkAccess=Disabled | Out-Null
    Assert-LdoFuncExitCode -Operation "az functionapp update ($FunctionAppName)"

    Write-LdoLog -Level INFO -Message "Removed access rule '$RuleName' and disabled public access on $FunctionAppName."
}

Export-ModuleMember -Function `
    Compress-LdoFunctionAppSource, `
    Invoke-LdoFunctionAppZipDeploy, `
    Get-LdoFunctionAppDefaultUrl, `
    Set-LdoFunctionAppSetting, `
    Add-LdoFunctionAppCurrentIpRule, `
    Remove-LdoFunctionAppCurrentIpRule
