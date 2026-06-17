Set-StrictMode -Version Latest

function Get-LdoAzureDevOpsPatHeader {
    # Internal. Builds a Basic auth header value from a PAT secure string.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring]$Pat)

    $plain = [System.Net.NetworkCredential]::new('', $Pat).Password
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw 'The supplied personal access token is empty.'
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes(":$plain")
    return 'Basic ' + [Convert]::ToBase64String($bytes)
}

function Get-LdoAzureDevOpsToken {
    # Internal. Returns the pipeline access token from the standard environment variables.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $token = $Env:SYSTEM_ACCESSTOKEN
    if ([string]::IsNullOrWhiteSpace($token)) {
        $token = $Env:SYSTEM_ACCESS_TOKEN
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'Pipeline access token not found in SYSTEM_ACCESSTOKEN or SYSTEM_ACCESS_TOKEN.'
    }
    return $token
}

function Get-LdoAzureDevOpsOrgId {
    <#
    .SYNOPSIS
        Returns the Azure DevOps organization id for an organization URL.

    .DESCRIPTION
        Calls the Azure DevOps connectionData REST API using a personal access token and
        returns an object describing the organization, including its instance id.

    .PARAMETER OrganizationUrl
        Organization URL, for example https://dev.azure.com/contoso.

    .PARAMETER Pat
        Personal access token with at least read access, supplied as a secure string.

    .EXAMPLE
        $pat = Read-Host -AsSecureString
        Get-LdoAzureDevOpsOrgId -OrganizationUrl 'https://dev.azure.com/contoso' -Pat $pat

    .OUTPUTS
        PSCustomObject with OrganizationId and OrganizationUrl.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OrganizationUrl,
        [Parameter(Mandatory)][securestring]$Pat
    )

    $authHeader = Get-LdoAzureDevOpsPatHeader -Pat $Pat
    $uri = "$($OrganizationUrl.TrimEnd('/'))/_apis/connectionData?api-version=7.0-preview.1"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = $authHeader } -Method Get -ErrorAction Stop
    }
    catch {
        Write-LdoLog -Level ERROR -Message "Failed to query connectionData for $OrganizationUrl : $_"
        throw
    }

    if (-not $response -or -not $response.instanceId) {
        throw "Failed to obtain the organization id for $OrganizationUrl."
    }

    [pscustomobject]@{
        OrganizationId = [string]$response.instanceId
        OrganizationUrl = $OrganizationUrl
    }
}

function Invoke-LdoAzureDevOpsTokenReplacement {
    <#
    .SYNOPSIS
        Injects the pipeline access token into Terraform module sources.

    .DESCRIPTION
        Scans *.tf files beneath a path for the placeholder
        git::https://__SYSTEM_ACCESS_TOKEN__@ and replaces it with the live pipeline token
        so that private Azure DevOps git module sources can be cloned during a run. Use
        Invoke-LdoAzureDevOpsTokenReplacementRevert afterwards to restore the placeholder.

    .PARAMETER CodePath
        Folder to scan for *.tf files. Defaults to the current working directory.

    .EXAMPLE
        Invoke-LdoAzureDevOpsTokenReplacement -CodePath ./terraform

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateNotNullOrEmpty()][string]$CodePath = (Get-Location).Path
    )

    if (-not (Test-Path $CodePath)) {
        throw "Path not found: $CodePath"
    }

    $orig = Get-Location
    try {
        Set-Location $CodePath
        Write-LdoLog -Level INFO -Message "Scanning Terraform files beneath '$CodePath' for token replacement."

        $tfFiles = Get-ChildItem -Recurse -Filter '*.tf' -File
        if (-not $tfFiles) {
            Write-LdoLog -Level WARN -Message "No *.tf files located under '$CodePath'; nothing to update."
            return
        }

        $placeholder = 'git::https://__SYSTEM_ACCESS_TOKEN__@'
        $token = Get-LdoAzureDevOpsToken
        $replacement = "git::https://$token@"

        foreach ($file in $tfFiles) {
            try {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                if ($content -notmatch [regex]::Escape($placeholder)) {
                    Write-LdoLog -Level DEBUG -Message "Skipping '$($file.FullName)'; placeholder absent."
                    continue
                }
                $updated = $content -replace [regex]::Escape($placeholder), $replacement
                Set-Content -LiteralPath $file.FullName -Value $updated -ErrorAction Stop
                Write-LdoLog -Level INFO -Message "Injected token into '$($file.FullName)'."
            }
            catch {
                Write-LdoLog -Level WARN -Message "Failed processing '$($file.FullName)': $_"
            }
        }

        Write-LdoLog -Level SUCCESS -Message 'Terraform token replacement completed.'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoAzureDevOpsTokenReplacementRevert {
    <#
    .SYNOPSIS
        Restores the token placeholder in Terraform module sources.

    .DESCRIPTION
        Reverses Invoke-LdoAzureDevOpsTokenReplacement by scanning *.tf files beneath a path
        for the live pipeline token in git module sources and replacing it with the
        git::https://__SYSTEM_ACCESS_TOKEN__@ placeholder, so the token is never committed.

    .PARAMETER CodePath
        Folder to scan for *.tf files. Defaults to the current working directory.

    .EXAMPLE
        Invoke-LdoAzureDevOpsTokenReplacementRevert -CodePath ./terraform

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateNotNullOrEmpty()][string]$CodePath = (Get-Location).Path
    )

    if (-not (Test-Path $CodePath)) {
        throw "Path not found: $CodePath"
    }

    $orig = Get-Location
    try {
        Set-Location $CodePath
        Write-LdoLog -Level INFO -Message "Reverting token replacement in *.tf files beneath '$CodePath'."

        $tfFiles = Get-ChildItem -Recurse -Filter '*.tf' -File
        if (-not $tfFiles) {
            Write-LdoLog -Level WARN -Message "No *.tf files located under '$CodePath'; nothing to revert."
            return
        }

        $token = Get-LdoAzureDevOpsToken
        $search = [regex]::Escape("git::https://$token@")
        $replacement = 'git::https://__SYSTEM_ACCESS_TOKEN__@'

        foreach ($file in $tfFiles) {
            try {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
                if ($content -notmatch $search) {
                    Write-LdoLog -Level DEBUG -Message "Skipping '$($file.FullName)'; token not present."
                    continue
                }
                $updated = $content -replace $search, $replacement
                Set-Content -LiteralPath $file.FullName -Value $updated -ErrorAction Stop
                Write-LdoLog -Level INFO -Message "Restored placeholder in '$($file.FullName)'."
            }
            catch {
                Write-LdoLog -Level WARN -Message "Failed processing '$($file.FullName)': $_"
            }
        }

        Write-LdoLog -Level SUCCESS -Message 'Terraform token reversion completed.'
    }
    finally {
        Set-Location $orig
    }
}

Export-ModuleMember -Function `
    Get-LdoAzureDevOpsOrgId, `
    Invoke-LdoAzureDevOpsTokenReplacement, `
    Invoke-LdoAzureDevOpsTokenReplacementRevert
