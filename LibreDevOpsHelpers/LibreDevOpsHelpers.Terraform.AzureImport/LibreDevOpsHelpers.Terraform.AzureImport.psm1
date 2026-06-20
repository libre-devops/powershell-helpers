Set-StrictMode -Version Latest

$script:LdoSubscriptionIdCache = $null

function Get-LdoTerraformImportResourceId {
    <#
    .SYNOPSIS
        Resolves the ARM resource id for a Terraform resource from its planned attributes.

    .DESCRIPTION
        Maps common azurerm_* resource types to their ARM id using the planned 'after'
        attributes, falling back to 'az resource list' and finally Azure Resource Graph. The
        subscription id is resolved once via 'az account show' and cached for the session.
        Returns $null when no id can be resolved. Requires the Azure CLI to be signed in.

    .PARAMETER TfType
        The Terraform resource type, for example azurerm_resource_group.

    .PARAMETER After
        The planned resource attributes (the change.after object from a plan).

    .PARAMETER SubscriptionId
        Subscription id to use. Defaults to the signed-in subscription (cached).

    .EXAMPLE
        Get-LdoTerraformImportResourceId -TfType azurerm_resource_group -After $after

    .OUTPUTS
        System.String. The ARM resource id, or $null when not resolvable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TfType,
        [Parameter(Mandatory)][psobject]$After,
        [string]$SubscriptionId
    )

    try {
        # Read name defensively: under StrictMode a missing property throws, and some resources
        # (for example NSG associations) carry no 'name' in their planned attributes.
        $afterName = if ($After.PSObject.Properties['name']) { $After.name } else { '<unnamed>' }
        Write-LdoLog -Level INFO -Message "Resolving ARM id for $TfType/$afterName"

        if (-not $SubscriptionId) {
            if (-not $script:LdoSubscriptionIdCache) {
                Assert-LdoCommand -Name 'az'
                $sub = & az account show --query id -o tsv
                Assert-LdoLastExitCode -Operation 'az account show'
                if ([string]::IsNullOrWhiteSpace($sub)) {
                    throw 'Could not resolve the Azure subscription id; is the Azure CLI signed in?'
                }
                $script:LdoSubscriptionIdCache = $sub.Trim()
            }
            $SubscriptionId = $script:LdoSubscriptionIdCache
        }

        $TypeMap = @{
            azurerm_resource_group = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.name)" }
            azurerm_storage_account = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Storage/storageAccounts/$($After.name)" }
            azurerm_storage_container = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Storage/storageAccounts/$($After.storage_account_name)/blobServices/default/containers/$($After.name)" }
            azurerm_virtual_network = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Network/virtualNetworks/$($After.name)" }
            azurerm_subnet = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Network/virtualNetworks/$($After.virtual_network_name)/subnets/$($After.name)" }
            azurerm_user_assigned_identity = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$($After.name)" }
            azurerm_network_security_group = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Network/networkSecurityGroups/$($After.name)" }
            azurerm_network_security_rule = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Network/networkSecurityGroups/$($After.network_security_group_name)/securityRules/$($After.name)" }
            azurerm_subnet_network_security_group_association = { $After.subnet_id }
            azurerm_key_vault = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.KeyVault/vaults/$($After.name)" }
            azurerm_private_endpoint = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Network/privateEndpoints/$($After.name)" }
            azurerm_databricks_workspace = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Databricks/workspaces/$($After.name)" }
            azurerm_windows_function_app = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Web/sites/$($After.name)" }
            azurerm_service_plan = { "/subscriptions/$SubscriptionId/resourceGroups/$($After.resource_group_name)/providers/Microsoft.Web/serverfarms/$($After.name)" }
        }
        if ($TypeMap.ContainsKey($TfType)) {
            return (& $TypeMap[$TfType])
        }

        $azType = if ($TfType -eq 'azurerm_subnet_network_security_group_association') {
            'Microsoft.Network/virtualNetworks/subnets'
        }
        else {
            $TfType -replace '^azurerm_', '' -replace '_', '/'
        }

        # Scope lookups by resource group when the plan provides one, so a same-named resource in
        # another group or subscription can't be matched and imported into state by mistake.
        $rg = if ($After.PSObject.Properties['resource_group_name']) { $After.resource_group_name } else { $null }

        Assert-LdoCommand -Name 'az'
        $listArgs = @('resource', 'list', '--name', $After.name, '--resource-type', $azType, '--query', '[0].id', '-o', 'tsv')
        if ($rg) { $listArgs += @('--resource-group', $rg) }
        Write-LdoLog -Level INFO -Message "az $($listArgs -join ' ')"
        $id = & az @listArgs
        if ($LASTEXITCODE -eq 0 -and $id) {
            return $id.Trim()
        }

        $clauses = @("name =~ '$($After.name)'", "subscriptionId =~ '$SubscriptionId'")
        if ($rg) { $clauses += "resourceGroup =~ '$rg'" }
        $kusto = 'Resources | where ' + ($clauses -join ' and ') + ' | take 1 | project id'
        Write-LdoLog -Level INFO -Message "az graph query (fallback) for $($After.name)"
        $graphId = & az graph query -q $kusto --first 1 --output tsv
        if ($LASTEXITCODE -eq 0 -and $graphId) {
            return $graphId.Trim()
        }
        return $null
    }
    catch {
        Write-LdoLog -Level ERROR -Message "ARM id lookup failed for ${TfType}: $_"
        return $null
    }
}

function Invoke-LdoTerraformImportFromPlan {
    <#
    .SYNOPSIS
        Imports existing Azure resources into Terraform state from a plan JSON file.

    .DESCRIPTION
        Reads a terraform show -json plan, finds managed resources scheduled for creation,
        resolves their ARM ids, confirms they exist in Azure, writes an import manifest CSV, and
        runs terraform import for each (parent resources first). Use -DryRun to log the import
        commands without executing them. Requires the Azure CLI to be signed in.

    .PARAMETER PlanJson
        Path to the plan JSON file produced by terraform show -json.

    .PARAMETER CodePath
        Terraform configuration folder to run imports in. Defaults to the current directory.

    .PARAMETER DryRun
        When set, logs the terraform import commands without executing them.

    .PARAMETER Manifest
        Path to write the import manifest CSV. Defaults to ./import-map.csv.

    .EXAMPLE
        Invoke-LdoTerraformImportFromPlan -PlanJson ./tfplan.plan.json -CodePath ./terraform -DryRun

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanJson,
        [string]$CodePath = '.',
        [switch]$DryRun,
        [string]$Manifest = './import-map.csv'
    )

    Assert-LdoCommand -Name 'az', 'terraform'

    if (-not (Test-Path $CodePath -PathType Container)) {
        throw "Terraform code path not found: $CodePath"
    }

    # Fail loudly once if the Azure CLI is not signed in, rather than silently skipping every
    # resource when id resolution returns nothing.
    & az account show -o none 2>$null
    Assert-LdoLastExitCode -Operation 'az account show (is the Azure CLI signed in?)'

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
        if ($chg.mode -ne 'managed') {
            continue
        }
        if ($chg.change.actions -notcontains 'create') {
            continue
        }

        $addr = $chg.address
        $after = $chg.change.after
        $type = $chg.type

        if ($type -eq 'azurerm_subnet_network_security_group_association') {
            if (-not $after.name -and ($addr -match '\["([^"]+)"\]')) {
                $after | Add-Member name $matches[1]
            }
            $sub = $plan.resource_changes |
                Where-Object {
                    $_.type -eq 'azurerm_subnet' -and
                    $_.change.after.name -eq $after.name
                } | Select-Object -First 1
            if ($sub) {
                foreach ($p in 'resource_group_name', 'virtual_network_name') {
                    if (-not $after.$p) {
                        $after | Add-Member $p $sub.change.after.$p
                    }
                }
                if (-not $after.subnet_id) {
                    $sid = Get-LdoTerraformImportResourceId -TfType 'azurerm_subnet' -After $sub.change.after
                    if ($sid) {
                        $after | Add-Member subnet_id $sid
                    }
                }
            }
        }

        try {
            $id = Get-LdoTerraformImportResourceId -TfType $type -After $after
            if (-not $id) {
                Write-LdoLog -Level WARN -Message "No ARM id for ${addr} (${type}); skipping."
                continue
            }

            Write-LdoLog -Level INFO -Message "Mapped ${addr} to ${id}"

            if ($type -ne 'azurerm_subnet_network_security_group_association') {
                $confirmId = az resource show --ids $id --query id -o tsv 2>$null
                if (-not $confirmId) {
                    Write-LdoLog -Level WARN -Message "Azure reports ${addr} not found; skipping."
                    continue
                }
                Write-LdoLog -Level INFO -Message "Confirmed existing resource for ${addr}"
            }

            $imports += [pscustomobject]@{ Address = $addr; Id = $id }
        }
        catch {
            Write-LdoLog -Level ERROR -Message "Lookup/import prep failed for ${addr}: $_"
        }
    }

    if (-not $imports) {
        Write-LdoLog -Level INFO -Message 'Nothing to import; plan has no importable Azure resources.'
        return
    }

    $imports = $imports | Sort-Object { (($_.Id -split '/').Count) }

    try {
        $imports | Export-Csv $Manifest -NoTypeInformation
        Write-LdoLog -Level INFO -Message "Wrote manifest to $Manifest"
    }
    catch {
        Write-LdoLog -Level ERROR -Message "Failed to write manifest: $_"
    }

    if ($DryRun) {
        foreach ($i in $imports) {
            Write-LdoLog -Level INFO -Message "[DRY-RUN] terraform import $($i.Address) $($i.Id)"
        }
        Write-LdoLog -Level SUCCESS -Message "[DRY-RUN] $($imports.Count) resource(s) would be imported."
        return
    }

    $importedCount = 0
    $failedCount = 0
    foreach ($i in $imports) {
        Push-Location $CodePath
        try {
            Write-LdoLog -Level INFO -Message "Importing $($i.Address)"
            # Address and id are passed as discrete arguments; resource addresses containing
            # brackets/quotes (e.g. foo["key"]) are safe as single array elements and need no
            # stop-parsing token.
            $output = & terraform import $i.Address $i.Id 2>&1
            $output | ForEach-Object { Write-LdoLog -Level INFO -Message "terraform: $_" }
            Assert-LdoLastExitCode -Operation "terraform import $($i.Address)"
            Write-LdoLog -Level SUCCESS -Message "Imported $($i.Address)"
            $importedCount++
        }
        catch {
            Write-LdoLog -Level ERROR -Message "terraform import failed for $($i.Address): $_"
            $failedCount++
        }
        finally {
            Pop-Location
        }
    }

    if ($failedCount -gt 0) {
        throw "$failedCount of $($imports.Count) import(s) failed; see the log for details."
    }
    Write-LdoLog -Level SUCCESS -Message "Imported $importedCount resource(s)."
}

Export-ModuleMember -Function `
    Get-LdoTerraformImportResourceId, `
    Invoke-LdoTerraformImportFromPlan
