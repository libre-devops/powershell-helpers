function Get-AzureDevOpsOrgId
{
    param (
        [string]$OrganizationUrl,
        [string]$Pat
    )

    try
    {
        # Prepare Authorization Header
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))

        # Define the Azure DevOps REST API endpoint for connection data
        $uri = "$OrganizationUrl/_apis/connectionData?api-version=7.0-preview.1"

        # Send GET request to Azure DevOps REST API
        $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = ("Basic {0}" -f $base64AuthInfo) } -Method Get

        # Extract and Output the Azure DevOps Organization ID (instanceId)
        $organizationId = $response.instanceId.Trim("")
        if (-not$response)
        {
            Write-Error "Failed to obtain the organization ID."
            return
        }
        $orgDetails = New-Object PSObject -Property @{
            "OrganizationId" = $organizationId
            "OrganizationUrl" = $OrganizationUrl
            "OrganizationName" = $OrganizationName
        }

        return $orgDetails
    }
    catch
    {
        Write-Error "Error Getting the DevOps organization ID: $_"
        throw $_
    }
}


function Invoke-TerraformAzureDevOpsTokenReplacement
{
    [CmdletBinding()]
    param(
    # Folder to scan for *.tf files.  Defaults to the current working directory.
        [string]$CodePath = (Get-Location).Path
    )

    $invocation = $MyInvocation.MyCommand.Name
    $orig = Get-Location

    try
    {
        if (-not (Test-Path $CodePath))
        {
            _LogMessage -Level 'ERROR' -Message "Path not found: $CodePath" -InvocationName $invocation
            throw "Path not found: $CodePath"
        }

        Set-Location $CodePath
        _LogMessage -Level 'INFO'  -Message "Scanning Terraform files beneath '$CodePath' for token replacement" `
                    -InvocationName $invocation

        $tfFiles = Get-ChildItem -Recurse -Filter '*.tf' -File

        if (-not $tfFiles)
        {
            _LogMessage -Level 'WARN' -Message "No *.tf files located under '$CodePath' – nothing to update." `
                        -InvocationName $invocation
            return
        }

        $placeholder = 'git::https://__SYSTEM_ACCESS_TOKEN__@'
        $token = $Env:SYSTEM_ACCESSTOKEN
        if (-not $token)
        {
            $token = $Env:SYSTEM_ACCESS_TOKEN
        }

        if (-not $token)
        {
            throw "Pipeline access token not found in either SYSTEM_ACCESSTOKEN or SYSTEM_ACCESS_TOKEN."
        }


        if (-not $token)
        {
            _LogMessage -Level 'ERROR' -Message 'Environment variable SYSTEM_ACCESSTOKEN is empty.' `
                        -InvocationName $invocation
            throw 'Environment variable SYSTEM_ACCESSTOKEN is empty.'
        }

        $replacement = "git::https://$token@"

        foreach ($file in $tfFiles)
        {
            try
            {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

                if ($content -notmatch [regex]::Escape($placeholder))
                {
                    _LogMessage -Level 'DEBUG' -Message "Skipping '$( $file.FullName )' – placeholder absent." `
                                -InvocationName $invocation
                    continue
                }

                $updated = $content -replace $placeholder, $replacement
                Set-Content -LiteralPath $file.FullName -Value $updated -ErrorAction Stop

                _LogMessage -Level 'INFO' -Message "Injected token into '$( $file.FullName )'." -InvocationName $invocation
            }
            catch
            {
                _LogMessage -Level 'WARN' -Message "Failed processing '$( $file.FullName )': $_" -InvocationName $invocation
                # Continue with remaining files
            }
        }

        _LogMessage -Level 'INFO' -Message 'Terraform token replacement completed.' -InvocationName $invocation
    }
    finally
    {
        Set-Location $orig
    }
}

function Invoke-TerraformAzureDevOpsTokenReplacementRevert {
    [CmdletBinding()]
    param(
    # Folder to scan for *.tf files.  Defaults to the current working directory.
        [string]$CodePath = (Get-Location).Path
    )

    $invocation = $MyInvocation.MyCommand.Name
    $orig       = Get-Location

    try {
        # -------------------------------------------------------------------
        # 0.  Validation / discovery
        # -------------------------------------------------------------------
        if (-not (Test-Path $CodePath)) {
            _LogMessage -Level 'ERROR' -Message "Path not found: $CodePath" -InvocationName $invocation
            throw "Path not found: $CodePath"
        }

        Set-Location $CodePath
        _LogMessage -Level 'INFO' -Message "Reverting token replacement in *.tf files beneath '$CodePath'…" `
                    -InvocationName $invocation

        $tfFiles = Get-ChildItem -Recurse -Filter '*.tf' -File
        if (-not $tfFiles) {
            _LogMessage -Level 'WARN' -Message "No *.tf files located under '$CodePath' – nothing to revert." `
                        -InvocationName $invocation
            return
        }

        # -------------------------------------------------------------------
        # 1.  Determine token & search / replacement strings
        # -------------------------------------------------------------------
        $token = $Env:SYSTEM_ACCESSTOKEN
        if (-not $token) { $token = $Env:SYSTEM_ACCESS_TOKEN }

        if (-not $token) {
            throw 'Pipeline access token not found in SYSTEM_ACCESSTOKEN or SYSTEM_ACCESS_TOKEN.'
        }

        # String **currently** in the files (needs escaping for regex)
        $search      = [regex]::Escape("git::https://$token@")

        # Placeholder to restore
        $replacement = 'git::https://__SYSTEM_ACCESS_TOKEN__@'

        # -------------------------------------------------------------------
        # 2.  Process files
        # -------------------------------------------------------------------
        foreach ($file in $tfFiles) {
            try {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

                if ($content -notmatch $search) {
                    _LogMessage -Level 'DEBUG' -Message "Skipping '$($file.FullName)' – token not present." `
                                -InvocationName $invocation
                    continue
                }

                $updated = $content -replace $search, $replacement
                Set-Content -LiteralPath $file.FullName -Value $updated -ErrorAction Stop

                _LogMessage -Level 'INFO' -Message "Restored placeholder in '$($file.FullName)'." `
                            -InvocationName $invocation
            }
            catch {
                _LogMessage -Level 'WARN' -Message "Failed processing '$($file.FullName)': $_" `
                            -InvocationName $invocation
                # continue with remaining files
            }
        }

        _LogMessage -Level 'INFO' -Message 'Terraform token reversion completed.' -InvocationName $invocation
    }
    finally {
        Set-Location $orig
    }
}


Export-ModuleMember -Function `
    Get-AzureDevOpsOrgId, `
    Invoke-TerraformAzureDevOpsTokenReplacement, `
    Invoke-TerraformAzureDevOpsTokenReplacementRevert