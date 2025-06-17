function Compress-FunctionAppSource
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$ZipPath,

        [switch]$Overwrite
    )

    $inv = $MyInvocation.MyCommand.Name
    try
    {
        if (Test-Path $ZipPath)
        {
            if ($Overwrite)
            {
                _LogMessage -Level INFO -Message "Overwriting existing ZIP: $ZipPath" -InvocationName $inv
                Remove-Item -Path $ZipPath -Force
            }
            else
            {
                throw "ZipPath already exists: $ZipPath (use -Overwrite)."
            }
        }

        _LogMessage -Level INFO -Message "Creating deployment package → $ZipPath" -InvocationName $inv

        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($SourcePath, $ZipPath)

        if (-not (Test-Path $ZipPath))
        {
            throw 'ZIP creation failed.'
        }

        $sizeMb = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
        _LogMessage -Level INFO -Message "ZIP package size: $sizeMb MB" -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $inv
        throw
    }
}


function Invoke-FunctionAppDeployZip
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$FunctionAppName,
        [Parameter(Mandatory)][string]$ZipPath,
        [switch]$RestartOnFinish,
        [string]$CliExtraArgsJson
    )

    $inv = $MyInvocation.MyCommand.Name
    $deleteTempZip = $false

    try
    {
        # ── If $ZipPath is a folder, compress it into a temporary zip file ──────────────
        if (Test-Path $ZipPath -PathType Container)
        {
            $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName() + ".zip")
            # Compress the folder's contents (all items inside the folder)
            Compress-Archive -Path (Join-Path (Resolve-Path $ZipPath).Path "*") -DestinationPath $tempZip -Force
            _LogMessage -Level INFO -Message "Folder '$ZipPath' compressed to zip archive '$tempZip'." -InvocationName $inv
            $ZipPath = $tempZip
            $deleteTempZip = $true
        }

        # ── Parse extra CLI arguments from JSON, if supplied ───────────────────────────
        $extraArgs = @()
        if ($CliExtraArgsJson)
        {
            try
            {
                $jsonArgs = $CliExtraArgsJson | ConvertFrom-Json
                if ($jsonArgs -isnot [System.Collections.IEnumerable])
                {
                    throw "CliExtraArgsJson must deserialize to an array."
                }
                $extraArgs = [string[]]$jsonArgs
            }
            catch
            {
                _LogMessage -Level ERROR -Message "CliExtraArgsJson invalid: $( $_.Exception.Message )" -InvocationName $inv
                throw
            }
        }

        # ── Build the az CLI command ─────────────────────────────────────────────
        $cli = @(
            'functionapp', 'deployment', 'source', 'config-zip',
            '--resource-group', $ResourceGroup,
            '--name', $FunctionAppName,
            '--src', (Resolve-Path $ZipPath).Path
        )
        if ($extraArgs)
        {
            $cli += $extraArgs
        }

        _LogMessage -Level INFO -Message "az $( $cli -join ' ' )" -InvocationName $inv
        az @cli | Out-Null
        _LogMessage -Level DEBUG -Message "az exit-code: $LASTEXITCODE" -InvocationName $inv

        if ($LASTEXITCODE)
        {
            throw "Deployment failed on $FunctionAppName (exit $LASTEXITCODE)."
        }

        # ── Optionally restart the function app ─────────────────────────────────────
        if ($RestartOnFinish)
        {
            $restart = @(
                'functionapp', 'restart',
                '--resource-group', $ResourceGroup,
                '--name', $FunctionAppName
            )

            _LogMessage -Level INFO -Message "Restarting Function App $FunctionAppName..." -InvocationName $inv
            az @restart | Out-Null
            if ($LASTEXITCODE)
            {
                _LogMessage -Level WARN -Message "Restart on $FunctionAppName returned exit-code $LASTEXITCODE." -InvocationName $inv
            }
        }

        _LogMessage -Level INFO -Message "Deployment completed successfully on $FunctionAppName" -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $inv
        throw
    }
    finally
    {
        # Clean up the temporary zip if we created one
        if ($deleteTempZip -and (Test-Path $ZipPath))
        {
            Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
            _LogMessage -Level INFO -Message "Temporary zip file removed." -InvocationName $inv
        }
    }
}


function Get-FunctionAppDefaultUrl
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$FunctionAppName
    )

    $inv = $MyInvocation.MyCommand.Name
    try
    {
        $hostName = az functionapp show `
                    --resource-group $ResourceGroup `
                    --name $FunctionAppName `
                    --query "defaultHostName" -o tsv

        if (-not $hostName)
        {
            throw 'Unable to retrieve default host name.'
        }

        $url = "https://$hostName"
        _LogMessage -Level INFO -Message "Function App default URL: $url" -InvocationName $inv
        return $url
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $inv
        throw
    }
}

function Invoke-FunctionAppSetSettings
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$FunctionAppName,

    # Either a JSON string **or** a path to a *.json* file
        [Parameter(Mandatory)][string]$SettingsJsonOrPath
    )

    $inv = $MyInvocation.MyCommand.Name
    try
    {
        # ── Resolve JSON ----------------------------------------------------
        if (Test-Path $SettingsJsonOrPath -PathType Leaf)
        {
            $json = Get-Content $SettingsJsonOrPath -Raw
            _LogMessage -Level DEBUG -Message "Using JSON from file: $SettingsJsonOrPath" -InvocationName $inv
        }
        else
        {
            $json = $SettingsJsonOrPath
            _LogMessage -Level DEBUG -Message "Using in-memory JSON string."     -InvocationName $inv
        }

        # Validate that it *is* JSON and looks like an object
        try
        {
            $null = $json | ConvertFrom-Json
        }
        catch
        {
            throw "SettingsJsonOrPath does not contain valid JSON. $( $_.Exception.Message )"
        }

        # ── Persist to a temp file -----------------------------------------
        $tmp = New-TemporaryFile
        Set-Content -Path $tmp -Value $json -Encoding UTF8
        _LogMessage -Level INFO -Message "Temp settings file → $tmp" -InvocationName $inv

        # ── az call ---------------------------------------------------------
        $cli = @(
            'functionapp', 'config', 'appsettings', 'set',
            '--resource-group', $ResourceGroup,
            '--name', $FunctionAppName,
            '--settings', "@$tmp"
        )
        _LogMessage -Level INFO -Message "az $( $cli -join ' ' )" -InvocationName $inv
        az @cli | Out-Null
        if ($LASTEXITCODE)
        {
            throw "az returned exit-code $LASTEXITCODE."
        }

        _LogMessage -Level INFO -Message "$FunctionAppName App-settings updated successfully." -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $inv
        throw
    }
    finally
    {
        if (Test-Path $tmp)
        {
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }
}

function Set-CurrentIPInFuncAccess
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$FunctionAppName,
        [Parameter(Mandatory)][bool]  $AddRule,

        [string]$RuleName = 'AllowCurrentIp',
        [int]   $Priority = 1000,
        [string]$Action = 'Allow')

    $inv = $MyInvocation.MyCommand.Name
    try
    {
        if ($AddRule)
        {
            # ── 1. discover caller IP ─────────────────────────────────────
            $currentIp = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
            if (-not $currentIp)
            {
                _LogMessage -Level ERROR -Message 'Failed to obtain public IP.' -InvocationName $inv
                return
            }
            _LogMessage -Level INFO -Message "Current IP: $currentIp" -InvocationName $inv

            # We need this as per https://github.com/Azure/azure-cli/issues/24947
            az functionapp update `
            -g $ResourceGroup -n $FunctionAppName `
            --set publicNetworkAccess=Enabled siteConfig.publicNetworkAccess=Enabled `
            --query "{name:name, publicNetworkAccess:publicNetworkAccess, siteConfig_publicNetworkAccess:siteConfig.publicNetworkAccess}" | Out-Null

            az functionapp config access-restriction set `
                 -g $ResourceGroup -n $FunctionAppName `
                 --default-action $Action `
                 --scm-default-action $Action `
                 --use-same-restrictions-for-scm-site true | Out-Null


            # ── 3. add rule (main site) ──────────────────────────────────
            az functionapp config access-restriction add `
                 -g $ResourceGroup -n $FunctionAppName `
                 --rule-name $RuleName --action $Action `
                 --priority $Priority --ip-address $currentIp | Out-Null



            _LogMessage -Level INFO -Message "Access rule '$RuleName' added for IP $currentIp to $FunctionAppName" -InvocationName $inv
        }
        else
        {
            # ── 1. remove rule(s) if present ─────────────────────────────
            az functionapp config access-restriction remove `
                 -g $ResourceGroup -n $FunctionAppName `
                 --rule-name $RuleName  | Out-Null

            # ── 2. disable restrictions (default-action = Allow) ────────
            az functionapp config access-restriction set `
                 -g $ResourceGroup -n $FunctionAppName `
                 --default-action Deny `
                 --scm-default-action Deny `
                 --use-same-restrictions-for-scm-site true | Out-Null

            az functionapp update `
            -g $ResourceGroup -n $FunctionAppName `
            --set publicNetworkAccess=Disabled siteConfig.publicNetworkAccess=Disabled `
            --query "{name:name, publicNetworkAccess:publicNetworkAccess, siteConfig_publicNetworkAccess:siteConfig.publicNetworkAccess}" | Out-Null

            _LogMessage -Level INFO -Message "Access rule '$RuleName' removed and public access re-enabled in $FunctionAppName" -InvocationName $inv
        }

        _LogMessage -Level INFO -Message "Function-app - $FunctionAppName - access-restriction update complete." -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message "An error occurred: $_" -InvocationName $inv
        throw
    }
}


Export-ModuleMember -Function `
    Compress-FunctionAppSource, `
      Invoke-FunctionAppDeployZip, `
      Get-FunctionAppDefaultUrl, `
      Invoke-FunctionAppSetSettings, `
      Set-CurrentIPInFuncAccess
