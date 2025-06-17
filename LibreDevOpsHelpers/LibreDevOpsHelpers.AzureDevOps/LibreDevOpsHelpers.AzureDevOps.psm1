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

Export-ModuleMember -Function `
    Get-AzureDevOpsOrgId