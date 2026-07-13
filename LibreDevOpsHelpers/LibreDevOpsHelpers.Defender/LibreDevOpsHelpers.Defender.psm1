Set-StrictMode -Version Latest

# This module spans four Microsoft Defender surfaces:
#   * Defender for Cloud   - Azure posture via the 'az security' CLI.
#   * Defender for Endpoint / XDR - the Graph Security API plus the Defender for Endpoint
#                            API (api.securitycenter.microsoft.com), via Invoke-LdoGraphRequest.
#   * Defender Antivirus    - the built-in Windows 'Defender' module cmdlets (Windows only).
#   * Defender for Endpoint on Linux - the 'mdatp' CLI (Linux only).

# ---------------------------------------------------------------------------------------------
# Defender for Cloud (az security)
# ---------------------------------------------------------------------------------------------

function Get-LdoDefenderSecureScore {
    <#
    .SYNOPSIS
        Returns a Microsoft Defender for Cloud secure score.

    .DESCRIPTION
        Runs 'az security secure-scores show' and returns the parsed score object. Requires the
        Azure CLI to be signed in.

    .PARAMETER Name
        Secure score control name. Defaults to 'ascScore' (the overall subscription score).

    .EXAMPLE
        (Get-LdoDefenderSecureScore).properties.score.percentage

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Name = 'ascScore'
    )

    Assert-LdoCommand -Name 'az'
    Write-LdoLog -Level INFO -Message "Getting Defender for Cloud secure score '$Name'."
    $json = & az security secure-scores show --name $Name -o json
    Assert-LdoLastExitCode -Operation 'az security secure-scores show'
    return ($json | ConvertFrom-Json)
}

function Get-LdoDefenderRecommendation {
    <#
    .SYNOPSIS
        Returns Microsoft Defender for Cloud security assessments (recommendations).

    .DESCRIPTION
        Runs 'az security assessment list' and returns the assessments, optionally filtered to
        unhealthy ones. Requires the Azure CLI to be signed in.

    .PARAMETER UnhealthyOnly
        When set, returns only assessments with an unhealthy status.

    .EXAMPLE
        Get-LdoDefenderRecommendation -UnhealthyOnly

    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [switch]$UnhealthyOnly
    )

    Assert-LdoCommand -Name 'az'
    Write-LdoLog -Level INFO -Message 'Listing Defender for Cloud assessments.'
    $json = & az security assessment list -o json
    Assert-LdoLastExitCode -Operation 'az security assessment list'

    $items = @($json | ConvertFrom-Json)
    if ($UnhealthyOnly) {
        $items = @($items | Where-Object { $_.status.code -eq 'Unhealthy' })
    }
    return $items
}

function Get-LdoDefenderPlan {
    <#
    .SYNOPSIS
        Returns Microsoft Defender for Cloud plan (pricing) tiers.

    .DESCRIPTION
        Runs 'az security pricing list' (or 'show' for a single plan) and returns the result.
        Requires the Azure CLI to be signed in.

    .PARAMETER Name
        Optional plan name (for example VirtualMachines, StorageAccounts). Lists all when omitted.

    .EXAMPLE
        Get-LdoDefenderPlan -Name StorageAccounts

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Name
    )

    Assert-LdoCommand -Name 'az'
    $azArgs = @('security', 'pricing')
    if ($Name) {
        $azArgs += @('show', '--name', $Name)
    }
    else {
        $azArgs += 'list'
    }
    $azArgs += @('-o', 'json')

    Write-LdoLog -Level INFO -Message "az $($azArgs -join ' ')"
    $json = & az @azArgs
    Assert-LdoLastExitCode -Operation 'az security pricing'
    return ($json | ConvertFrom-Json)
}

function Set-LdoDefenderPlan {
    <#
    .SYNOPSIS
        Sets the tier of a Microsoft Defender for Cloud plan.

    .DESCRIPTION
        Runs 'az security pricing create' to set a plan to Free or Standard. Requires the Azure
        CLI to be signed in with permission to change Defender plans.

    .PARAMETER Name
        Plan name (for example VirtualMachines, StorageAccounts, KeyVaults).

    .PARAMETER Tier
        Free or Standard.

    .EXAMPLE
        Set-LdoDefenderPlan -Name StorageAccounts -Tier Standard

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Free', 'Standard')][string]$Tier
    )

    Assert-LdoCommand -Name 'az'
    Write-LdoLog -Level INFO -Message "Setting Defender plan '$Name' to tier '$Tier'."
    & az security pricing create --name $Name --tier $Tier -o none
    Assert-LdoLastExitCode -Operation "az security pricing create ($Name)"
    Write-LdoLog -Level SUCCESS -Message "Defender plan '$Name' set to '$Tier'."
}

# ---------------------------------------------------------------------------------------------
# Defender for Endpoint / XDR (Graph Security API + Defender for Endpoint API)
# ---------------------------------------------------------------------------------------------

$script:LdoMdeApiResource = 'https://api.securitycenter.microsoft.com'

function Get-LdoDefenderAlert {
    <#
    .SYNOPSIS
        Returns Microsoft Defender XDR alerts from the Graph Security API.

    .DESCRIPTION
        Queries /security/alerts_v2, optionally filtered by severity and status. Requires an Az
        context with Graph permission to read security alerts (SecurityAlert.Read.All).

    .PARAMETER Severity
        Filter by severity: low, medium, high, or informational.

    .PARAMETER Status
        Filter by status: new, inProgress, or resolved.

    .PARAMETER Top
        Maximum number of alerts to return. Defaults to 50.

    .EXAMPLE
        Get-LdoDefenderAlert -Severity high -Status new

    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [ValidateSet('low', 'medium', 'high', 'informational')][string]$Severity,
        [ValidateSet('new', 'inProgress', 'resolved')][string]$Status,
        [ValidateRange(1, 1000)][int]$Top = 50
    )

    $filters = @()
    if ($Severity) { $filters += "severity eq '$Severity'" }
    if ($Status) { $filters += "status eq '$Status'" }

    $uri = "https://graph.microsoft.com/v1.0/security/alerts_v2?`$top=$Top"
    if ($filters) {
        $uri += "&`$filter=" + [uri]::EscapeDataString($filters -join ' and ')
    }

    Write-LdoLog -Level INFO -Message 'Querying Defender XDR alerts.'
    $response = Invoke-LdoGraphRequest -Uri $uri
    return @($response.value)
}

function Invoke-LdoDefenderHuntingQuery {
    <#
    .SYNOPSIS
        Runs an advanced hunting (KQL) query against Microsoft Defender XDR.

    .DESCRIPTION
        Posts the query to /security/runHuntingQuery and returns the result rows. Requires an Az
        context with Graph permission to run hunting queries (ThreatHunting.Read.All).

    .PARAMETER Query
        The KQL hunting query.

    .PARAMETER Timespan
        Optional ISO 8601 lookback (PT1H, P7D, or start/end forms). The service default is
        30 days.

    .PARAMETER ApiVersion
        Graph API version. Defaults to v1.0, where runHuntingQuery is generally available.

    .PARAMETER MaxRetries
        Maximum attempts per call. Defaults to 5.

    .PARAMETER Raw
        Return the full Graph response (schema plus results) instead of just the result rows,
        for callers that need the result schema (for example query validation tooling).

    .EXAMPLE
        Invoke-LdoDefenderHuntingQuery -Query 'DeviceProcessEvents | take 10'

    .EXAMPLE
        Invoke-LdoDefenderHuntingQuery -Query $kql -Timespan 'PT1H' -Raw

    .OUTPUTS
        System.Object[] by default; the full response object with -Raw.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Query,
        [string]$Timespan,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'v1.0',
        [int]$MaxRetries = 5,
        [switch]$Raw
    )

    $body = @{ query = $Query }
    if ($Timespan) { $body.timespan = $Timespan }

    Write-LdoLog -Level INFO -Message 'Running Defender advanced hunting query.'
    $response = Invoke-LdoGraphRequest -Method Post `
        -Uri "https://graph.microsoft.com/$ApiVersion/security/runHuntingQuery" `
        -Body $body -MaxRetries $MaxRetries
    if ($Raw) { return $response }
    return @($response.results)
}

function Invoke-LdoDefenderDeviceIsolation {
    <#
    .SYNOPSIS
        Isolates (or releases) a device in Microsoft Defender for Endpoint.

    .DESCRIPTION
        Calls the Defender for Endpoint API to isolate a machine, or release it from isolation
        with -Release. Requires an Az context with the Machine.Isolate permission on the Defender
        for Endpoint API.

    .PARAMETER DeviceId
        The Defender for Endpoint machine id.

    .PARAMETER Comment
        Reason recorded with the action.

    .PARAMETER IsolationType
        Full or Selective. Ignored when -Release is set.

    .PARAMETER Release
        When set, releases the device from isolation instead of isolating it.

    .EXAMPLE
        Invoke-LdoDefenderDeviceIsolation -DeviceId $id -Comment 'IR-1234 containment'

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DeviceId,
        [string]$Comment = 'Action performed via LibreDevOpsHelpers',
        [ValidateSet('Full', 'Selective')][string]$IsolationType = 'Full',
        [switch]$Release
    )

    $action = if ($Release) { 'unisolate' } else { 'isolate' }
    $body = @{ Comment = $Comment }
    if (-not $Release) { $body['IsolationType'] = $IsolationType }

    Write-LdoLog -Level INFO -Message "Defender for Endpoint $action on device $DeviceId."
    $response = Invoke-LdoGraphRequest -Method Post `
        -Uri "$script:LdoMdeApiResource/api/machines/$DeviceId/$action" `
        -Resource $script:LdoMdeApiResource `
        -Body $body
    Write-LdoLog -Level SUCCESS -Message "Submitted $action for device $DeviceId."
    return $response
}

function Invoke-LdoDefenderAvScan {
    <#
    .SYNOPSIS
        Triggers an antivirus scan on a Microsoft Defender for Endpoint device.

    .DESCRIPTION
        Calls the Defender for Endpoint API to run a Quick or Full antivirus scan on a machine.
        Requires an Az context with the Machine.Scan permission on the Defender for Endpoint API.

    .PARAMETER DeviceId
        The Defender for Endpoint machine id.

    .PARAMETER ScanType
        Quick or Full. Defaults to Quick.

    .PARAMETER Comment
        Reason recorded with the action.

    .EXAMPLE
        Invoke-LdoDefenderAvScan -DeviceId $id -ScanType Full

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DeviceId,
        [ValidateSet('Quick', 'Full')][string]$ScanType = 'Quick',
        [string]$Comment = 'Scan triggered via LibreDevOpsHelpers'
    )

    Write-LdoLog -Level INFO -Message "Defender for Endpoint $ScanType AV scan on device $DeviceId."
    $response = Invoke-LdoGraphRequest -Method Post `
        -Uri "$script:LdoMdeApiResource/api/machines/$DeviceId/runAntiVirusScan" `
        -Resource $script:LdoMdeApiResource `
        -Body @{ Comment = $Comment; ScanType = $ScanType }
    Write-LdoLog -Level SUCCESS -Message "Submitted $ScanType AV scan for device $DeviceId."
    return $response
}

# ---------------------------------------------------------------------------------------------
# Defender Antivirus (Windows, built-in Defender module)
# ---------------------------------------------------------------------------------------------

function Assert-LdoWindowsDefender {
    # Internal. Throws unless running on Windows with the Defender cmdlets available.
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if ((Get-LdoOperatingSystem) -ne 'Windows') {
        throw 'Windows Defender Antivirus cmdlets are only available on Windows.'
    }
    Assert-LdoCommand -Name 'Get-MpComputerStatus'
}

function Get-LdoDefenderAvStatus {
    <#
    .SYNOPSIS
        Returns Windows Defender Antivirus status.

    .DESCRIPTION
        Wraps Get-MpComputerStatus. Windows only.

    .EXAMPLE
        (Get-LdoDefenderAvStatus).RealTimeProtectionEnabled

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    Assert-LdoWindowsDefender
    return Get-MpComputerStatus
}

function Start-LdoDefenderAvScan {
    <#
    .SYNOPSIS
        Starts a Windows Defender Antivirus scan.

    .DESCRIPTION
        Wraps Start-MpScan. Windows only.

    .PARAMETER ScanType
        Quick or Full. Defaults to Quick.

    .EXAMPLE
        Start-LdoDefenderAvScan -ScanType Full

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateSet('Quick', 'Full')][string]$ScanType = 'Quick'
    )

    Assert-LdoWindowsDefender
    Write-LdoLog -Level INFO -Message "Starting Windows Defender $ScanType scan."
    Start-MpScan -ScanType "${ScanType}Scan"
    Write-LdoLog -Level SUCCESS -Message "Windows Defender $ScanType scan started."
}

function Update-LdoDefenderAvSignature {
    <#
    .SYNOPSIS
        Updates Windows Defender Antivirus definitions.

    .DESCRIPTION
        Wraps Update-MpSignature. Windows only.

    .EXAMPLE
        Update-LdoDefenderAvSignature

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    Assert-LdoWindowsDefender
    Write-LdoLog -Level INFO -Message 'Updating Windows Defender signatures.'
    Update-MpSignature
    Write-LdoLog -Level SUCCESS -Message 'Windows Defender signatures updated.'
}

function Add-LdoDefenderAvExclusion {
    <#
    .SYNOPSIS
        Adds one or more path exclusions to Windows Defender Antivirus.

    .DESCRIPTION
        Wraps Add-MpPreference -ExclusionPath. Windows only.

    .PARAMETER Path
        One or more paths to exclude.

    .EXAMPLE
        Add-LdoDefenderAvExclusion -Path 'C:\app', 'C:\cache'

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Path
    )

    Assert-LdoWindowsDefender
    Write-LdoLog -Level INFO -Message "Adding Defender exclusion path(s): $($Path -join ', ')."
    Add-MpPreference -ExclusionPath $Path
    Write-LdoLog -Level SUCCESS -Message 'Defender exclusion(s) added.'
}

# ---------------------------------------------------------------------------------------------
# Defender for Endpoint on Linux (mdatp CLI)
# ---------------------------------------------------------------------------------------------

function Invoke-LdoMdatpCommand {
    # Internal. Asserts mdatp is available on Linux, runs it, throws on non-zero exit, and
    # returns the output.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$Operation
    )

    if ((Get-LdoOperatingSystem) -ne 'Linux') {
        throw 'mdatp (Defender for Endpoint on Linux) is only available on Linux.'
    }
    Assert-LdoCommand -Name 'mdatp'

    if (-not $Operation) {
        $Operation = "mdatp $($ArgumentList -join ' ')"
    }

    Write-LdoLog -Level INFO -Message "Running: mdatp $($ArgumentList -join ' ')"
    $output = & mdatp @ArgumentList
    Assert-LdoLastExitCode -Operation $Operation
    return $output
}

function Get-LdoMdatpHealth {
    <#
    .SYNOPSIS
        Returns Microsoft Defender for Endpoint on Linux health.

    .DESCRIPTION
        Runs 'mdatp health', optionally for a single field. Linux only.

    .PARAMETER Field
        Optional single health field to return (for example healthy, real_time_protection_enabled).

    .EXAMPLE
        Get-LdoMdatpHealth -Field healthy

    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [string]$Field
    )

    $mdatpArgs = @('health')
    if ($Field) { $mdatpArgs += @('--field', $Field) }
    return Invoke-LdoMdatpCommand -ArgumentList $mdatpArgs -Operation 'mdatp health'
}

function Start-LdoMdatpScan {
    <#
    .SYNOPSIS
        Starts a Microsoft Defender for Endpoint on Linux scan.

    .DESCRIPTION
        Runs 'mdatp scan quick' or 'mdatp scan full'. Linux only.

    .PARAMETER ScanType
        Quick or Full. Defaults to Quick.

    .EXAMPLE
        Start-LdoMdatpScan -ScanType Full

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [ValidateSet('Quick', 'Full')][string]$ScanType = 'Quick'
    )

    $null = Invoke-LdoMdatpCommand -ArgumentList @('scan', $ScanType.ToLowerInvariant()) -Operation "mdatp scan $ScanType"
    Write-LdoLog -Level SUCCESS -Message "mdatp $ScanType scan completed."
}

function Update-LdoMdatpDefinition {
    <#
    .SYNOPSIS
        Updates Microsoft Defender for Endpoint on Linux definitions.

    .DESCRIPTION
        Runs 'mdatp definitions update'. Linux only.

    .EXAMPLE
        Update-LdoMdatpDefinition

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $null = Invoke-LdoMdatpCommand -ArgumentList @('definitions', 'update') -Operation 'mdatp definitions update'
    Write-LdoLog -Level SUCCESS -Message 'mdatp definitions updated.'
}

function Add-LdoMdatpExclusion {
    <#
    .SYNOPSIS
        Adds a folder exclusion to Microsoft Defender for Endpoint on Linux.

    .DESCRIPTION
        Runs 'mdatp exclusion folder add --path'. Linux only.

    .PARAMETER Path
        The folder path to exclude.

    .EXAMPLE
        Add-LdoMdatpExclusion -Path /opt/app

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path
    )

    $null = Invoke-LdoMdatpCommand -ArgumentList @('exclusion', 'folder', 'add', '--path', $Path) -Operation 'mdatp exclusion folder add'
    Write-LdoLog -Level SUCCESS -Message "mdatp folder exclusion added: $Path"
}

Export-ModuleMember -Function `
    Get-LdoDefenderSecureScore, `
    Get-LdoDefenderRecommendation, `
    Get-LdoDefenderPlan, `
    Set-LdoDefenderPlan, `
    Get-LdoDefenderAlert, `
    Invoke-LdoDefenderHuntingQuery, `
    Invoke-LdoDefenderDeviceIsolation, `
    Invoke-LdoDefenderAvScan, `
    Get-LdoDefenderAvStatus, `
    Start-LdoDefenderAvScan, `
    Update-LdoDefenderAvSignature, `
    Add-LdoDefenderAvExclusion, `
    Get-LdoMdatpHealth, `
    Start-LdoMdatpScan, `
    Update-LdoMdatpDefinition, `
    Add-LdoMdatpExclusion
