param(
    [Parameter()]
    [string]$ModuleFolder = (Join-Path -Path (Get-Location) -ChildPath 'LibreDevOpsHelpers'),

    [Parameter()]
    [string]$FeedName = $env:AZDO_FEED_NAME,

    [Parameter()]
    [string]$ModulFolder = "LibreDevOpsHelpers",

    [Parameter()]
    [string]$ModuleName = "LibreDevOpsHelpers",

    [Parameter()]
    [string]$Scope = "CurrentUser"

)

# ─── ENVIRONMENT VALIDATION ─────────────────────────────────────────────────────
$orgRaw = $env:AZDO_ORG_SERVICE_URL
$project = $env:AZDO_PROJECT_NAME
$token = $env:AZDO_ARTIFACTS_PAT ?? $env:SYSTEM_ACCESSTOKEN


if (-not $orgRaw)
{
    throw 'AZDO_ORG_SERVICE_URL / System.CollectionUri is required.'
}
if (-not $project)
{
    throw 'AZDO_PROJECT_NAME / System.TeamProject is required.'
}
if (-not $FeedName)
{
    throw 'AZDO_FEED_NAME is required.'
}
if (-not $token)
{
    throw 'A PAT or System.AccessToken is required.'
}


# Normalise organisation name
$orgName = if ($orgRaw -match '^https?://')
{
    # Convert URI → take the first path segment after the authority
    ([uri]$orgRaw).Segments[1].TrimEnd('/')
}
else
{
    $orgRaw
}

if (-not (Test-Path $ModuleFolder))
{
    throw "Module folder '$ModuleFolder' not found."
}

$ErrorActionPreference = 'Stop'

$org = $orgName
$feed = $FeedName
# ─── Build the credential object correctly ─────────────────────────────────────
$securePassword = ConvertTo-SecureString $token -AsPlainText -Force
$credential = [pscredential]::new('AzureDevOps', $securePassword)

# ─── Build the feed URL that PowerShellGet 2.x accepts ─────────────────────────
$feedUri = "https://pkgs.dev.azure.com/$org/$project/_packaging/$feed/nuget/v3/index.json"

Write-Host "Adding VSS_NUGET_EXTERNAL_FEED_ENDPOINTS to the current user's environment variables"
$EndpointCredentials = @"
{
    "endpointCredentials": [
        {
            "endpoint": "$feedUri",
            "password": "$token"
        }
    ]
}
"@
[System.Environment]::SetEnvironmentVariable('VSS_NUGET_EXTERNAL_FEED_ENDPOINTS', $EndpointCredentials, [System.EnvironmentVariableTarget]::User)



if (Get-PSResourceRepository -ErrorAction SilentlyContinue | Where-Object Name -eq $feed)
{
    Unregister-PSResourceRepository -Name $feed -ErrorAction Stop
}

try
{
    Register-PSResourceRepository `
        -Name $feed `
        -Uri $feedUri `
        -Trusted
}
catch
{
    Write-Error "❌ Failed to register repository '$feed' : $_"
    exit 1
}

try
{
    Install-PSResource `
    $ModuleName `
    -Credential $credential `
    -TrustRepository `
    -Reinstall `
    -Scope $Scope

    _LogMessage -Level "INFO" -Message "Module installed 😊" -InvocationName $MyInvocation.InvocationName
}
catch
{
    Write-Error "❌ Failed to Install Module '$feed' : $_"
    exit 1
}

