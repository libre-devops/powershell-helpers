Set-StrictMode -Version Latest

# The Microsoft Graph collections this importer can resolve, keyed by the msgraph_resource url
# (normalised without leading or trailing slashes). Custom detection rules are the first supported
# type; extend the table as more Graph estates move to code.
$script:LdoGraphImportSupportedUrls = @{
    'security/rules/detectionRules' = 'CustomDetectionRules'
}

function Get-LdoTerraformGraphImportResourceId {
    <#
    .SYNOPSIS
        Resolves the msgraph provider import id for a planned msgraph_resource.

    .DESCRIPTION
        The Graph sibling of Get-LdoTerraformImportResourceId. Maps a planned msgraph_resource
        (its url plus planned body) to an existing Graph object and returns the provider's import
        id format: "<url>/<id>?api-version=<version>". Matching prefers the planned body id (the
        client provided rule key), then falls back to the display name; an ambiguous display name
        match is refused rather than guessed. Returns $null when the url is unsupported or nothing
        matches.

    .PARAMETER Url
        The msgraph_resource collection url from the plan, for example security/rules/detectionRules.

    .PARAMETER After
        The planned resource attributes (the change.after object from a plan), carrying body and
        api_version.

    .PARAMETER ApiVersion
        API version used when the planned attributes do not carry one. Defaults to beta.

    .EXAMPLE
        Get-LdoTerraformGraphImportResourceId -Url 'security/rules/detectionRules' -After $after

    .OUTPUTS
        System.String. The import id, or $null when not resolvable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Url,
        [Parameter(Mandatory)][psobject]$After,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'beta'
    )

    $norm = $Url.Trim('/')
    if (-not $script:LdoGraphImportSupportedUrls.ContainsKey($norm)) {
        Write-LdoLog -Level WARN -Message "Unsupported Graph collection url '$norm'; supported: $($script:LdoGraphImportSupportedUrls.Keys -join ', ')."
        return $null
    }

    $ver = if ($After.PSObject.Properties['api_version'] -and $After.api_version) { $After.api_version } else { $ApiVersion }
    $body = if ($After.PSObject.Properties['body']) { $After.body } else { $null }

    $plannedId = if ($body -and $body.PSObject.Properties['id'] -and $body.id) { "$($body.id)" } else { $null }
    $plannedName = if ($body -and $body.PSObject.Properties['displayName'] -and $body.displayName) { "$($body.displayName)" } else { $null }

    $existing = @(Get-LdoCustomDetectionRule -ApiVersion $ver)

    $hit = $null
    if ($plannedId) {
        $hit = $existing | Where-Object { "$($_.id)" -eq $plannedId } | Select-Object -First 1
    }
    if (-not $hit -and $plannedName) {
        $named = @($existing | Where-Object { $_.displayName -eq $plannedName })
        if ($named.Count -gt 1) {
            Write-LdoLog -Level WARN -Message "Display name '$plannedName' matches $($named.Count) rules; refusing an ambiguous import (set the rule id to the server id instead)."
            return $null
        }
        $hit = $named | Select-Object -First 1
    }

    if (-not $hit) {
        Write-LdoLog -Level WARN -Message "No existing rule matches id '$plannedId' or display name '$plannedName'."
        return $null
    }

    return "$norm/$($hit.id)?api-version=$ver"
}

function Invoke-LdoTerraformGraphImportFromPlan {
    <#
    .SYNOPSIS
        Imports existing Microsoft Graph resources into Terraform state from a plan JSON file.

    .DESCRIPTION
        The Graph sibling of Invoke-LdoTerraformImportFromPlan and the second half of the
        brownfield detections as code flow: export existing rules with
        Export-LdoCustomDetectionRule, drop the YAML into the module's custom-detections layout,
        plan, then run this against the plan JSON. Managed msgraph_resource creations whose url is
        a supported Graph collection are matched to live objects (body id first, then display
        name), a manifest CSV is written, and terraform import runs for each (or is only logged
        with -DryRun). Resources that cannot be matched are skipped with a warning, never guessed.

    .PARAMETER PlanJson
        Path to the plan JSON file produced by terraform show -json.

    .PARAMETER CodePath
        Terraform configuration folder to run imports in. Defaults to the current directory.

    .PARAMETER DryRun
        When set, logs the terraform import commands without executing them.

    .PARAMETER Manifest
        Path to write the import manifest CSV. Defaults to ./graph-import-map.csv.

    .EXAMPLE
        Invoke-LdoTerraformGraphImportFromPlan -PlanJson ./tfplan.plan.json -CodePath . -DryRun

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanJson,
        [string]$CodePath = '.',
        [switch]$DryRun,
        [string]$Manifest = './graph-import-map.csv'
    )

    # A dry run never invokes terraform, so the binary is only required when importing for real.
    if (-not $DryRun) {
        Assert-LdoCommand -Name 'terraform'
    }

    if (-not (Test-Path $CodePath -PathType Container)) {
        throw "Terraform code path not found: $CodePath"
    }

    try {
        Write-LdoLog -Level INFO -Message "Reading plan file $PlanJson"
        $plan = Get-Content -LiteralPath $PlanJson -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-LdoLog -Level ERROR -Message "Cannot read or parse plan: $_"
        throw
    }

    $imports = @()

    foreach ($chg in $plan.resource_changes) {
        if ($chg.mode -ne 'managed') { continue }
        if ($chg.type -ne 'msgraph_resource') { continue }
        if ($chg.change.actions -notcontains 'create') { continue }

        $addr = $chg.address
        $after = $chg.change.after
        $url = if ($after.PSObject.Properties['url'] -and $after.url) { "$($after.url)" } else { '' }

        if (-not $script:LdoGraphImportSupportedUrls.ContainsKey($url.Trim('/'))) {
            Write-LdoLog -Level INFO -Message "Skipping ${addr}: url '$url' is not a supported Graph import type."
            continue
        }

        try {
            $id = Get-LdoTerraformGraphImportResourceId -Url $url -After $after
            if (-not $id) {
                Write-LdoLog -Level WARN -Message "No live Graph object for ${addr}; skipping (it will be created on apply)."
                continue
            }
            Write-LdoLog -Level INFO -Message "Mapped ${addr} to ${id}"
            $imports += [pscustomobject]@{ Address = $addr; Id = $id }
        }
        catch {
            Write-LdoLog -Level ERROR -Message "Lookup failed for ${addr}: $_"
        }
    }

    if (-not $imports) {
        Write-LdoLog -Level INFO -Message 'Nothing to import; plan has no importable Graph resources.'
        return
    }

    $imports | Export-Csv -Path $Manifest -NoTypeInformation
    Write-LdoLog -Level INFO -Message "Wrote import manifest for $($imports.Count) resource(s) to $Manifest"

    $failed = 0
    foreach ($import in $imports) {
        if ($DryRun) {
            Write-LdoLog -Level INFO -Message "DRY RUN: terraform -chdir=$CodePath import '$($import.Address)' '$($import.Id)'"
            continue
        }
        Write-LdoLog -Level INFO -Message "Importing $($import.Address)"
        & terraform -chdir=$CodePath import $import.Address $import.Id
        if ($LASTEXITCODE -ne 0) {
            $failed++
            Write-LdoLog -Level ERROR -Message "terraform import failed for $($import.Address) (exit $LASTEXITCODE)."
        }
    }

    if ($failed -gt 0) {
        throw "Graph import: $failed of $($imports.Count) import(s) failed; see the log."
    }

    if (-not $DryRun) {
        Write-LdoLog -Level SUCCESS -Message "Imported $($imports.Count) Graph resource(s); run terraform plan to verify."
    }
}
