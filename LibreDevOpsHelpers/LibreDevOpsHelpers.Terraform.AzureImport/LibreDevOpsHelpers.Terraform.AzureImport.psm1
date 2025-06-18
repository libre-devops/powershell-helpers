if (-not $script:SubscriptionIdCache)
{
    $script:SubscriptionIdCache = $null
}

function Get-AzureCliTerraformImportResourceId
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]  $TfType,
        [Parameter(Mandatory)][psobject]$After,
        [string]$SubscriptionId
    )

    try
    {
        _LogMessage INFO "Resolving ARM ID for $TfType/$( $After.name )" `
                   -InvocationName $MyInvocation.MyCommand.Name

        # ── 1. subscription id (cached) ──────────────────────────────────────
        if (-not $SubscriptionId)
        {
            if (-not $script:SubscriptionIdCache)
            {
                _LogMessage INFO 'az account show --query id -o tsv' `
                           -InvocationName $MyInvocation.MyCommand.Name
                $script:SubscriptionIdCache = & az account show --query id -o tsv
            }
            $SubscriptionId = $script:SubscriptionIdCache
        }

        # ── 2. fast-path map ─────────────────────────────────────────────────
        $TypeMap = @{
            azurerm_resource_group                               = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.name )" }
            azurerm_storage_account                              = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Storage/storageAccounts/$( $After.name )" }
            azurerm_storage_container                            = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Storage/storageAccounts/$( $After.storage_account_name )/blobServices/default/containers/$( $After.name )" }
            azurerm_virtual_network                              = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Network/virtualNetworks/$( $After.name )" }
            azurerm_subnet                                       = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Network/virtualNetworks/$( $After.virtual_network_name )/subnets/$( $After.name )" }
            azurerm_user_assigned_identity                       = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$( $After.name )" }
            azurerm_network_security_group                       = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Network/networkSecurityGroups/$( $After.name )" }
            azurerm_network_security_rule                        = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Network/networkSecurityGroups/$( $After.network_security_group_name )/securityRules/$( $After.name )" }
            azurerm_subnet_network_security_group_association    = { $After.subnet_id }
            azurerm_key_vault                                    = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.KeyVault/vaults/$( $After.name )" }
            azurerm_private_endpoint                             = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Network/privateEndpoints/$( $After.name )" }
            azurerm_databricks_workspace                         = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Databricks/workspaces/$( $After.name )" }
            azurerm_windows_function_app                         = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Web/sites/$( $After.name )" }
            azurerm_service_plan                                 = { "/subscriptions/$SubscriptionId/resourceGroups/$( $After.resource_group_name )/providers/Microsoft.Web/serverfarms/$( $After.name )" }
        }
        if ( $TypeMap.ContainsKey($TfType))
        {
            return (& $TypeMap[$TfType])
        }

        # ── 3. generic az resource list ──────────────────────────────────────
        $azType = if ($TfType -eq 'azurerm_subnet_network_security_group_association')
        {
            'Microsoft.Network/virtualNetworks/subnets'
        }
        else
        {
            $TfType -replace '^azurerm_', '' -replace '_', '/'
        }

        $listCmd = "az resource list --name `"$( $After.name )`" --resource-type `"$azType`" --query `[0].id` -o tsv"
        _LogMessage INFO $listCmd -InvocationName $MyInvocation.MyCommand.Name
        $id = & az resource list --name $After.name --resource-type $azType --query '[0].id' -o tsv
        if ($id)
        {
            return $id
        }

        # ── 4. Azure Resource Graph fallback ─────────────────────────────────
        $kusto = "Resources | where name == '$( $After.name )' | take 1 | project id"
        _LogMessage INFO "az graph query -q `"$kusto`" --first 1 --output tsv" `
                   -InvocationName $MyInvocation.MyCommand.Name
        return & az graph query -q $kusto --first 1 --output tsv
    }
    catch
    {
        _LogMessage ERROR "ARM-ID lookup failed for ${TfType}: $_" `
                   -InvocationName $MyInvocation.MyCommand.Name
        return $null
    }
}

# ────────────────────────────────────────────────────────────────────────────────
#  Main entry point
# ────────────────────────────────────────────────────────────────────────────────
function Invoke-TerraformImportFromPlan
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlanJson,
        [string]$CodePath = ".",
        [switch]$WhatIf,
        [string]$Manifest = "./import-map.csv"
    )

    $ErrorActionPreference = 'Stop'

    try
    {
        _LogMessage INFO "Reading plan file $PlanJson" -InvocationName $MyInvocation.MyCommand.Name
        $plan = Get-Content $PlanJson -Raw | ConvertFrom-Json
    }
    catch
    {
        _LogMessage ERROR "Cannot read or parse plan: $_" -InvocationName $MyInvocation.MyCommand.Name
        throw
    }

    $imports = @()

    foreach ($chg in $plan.resource_changes)
    {
        if ($chg.mode -ne 'managed')
        {
            continue
        }
        if ($chg.change.actions -notcontains 'create')
        {
            continue
        }

        $addr = $chg.address
        $after = $chg.change.after
        $type = $chg.type

        # ── fill required props for subnet-NSG assoc. ───────────────────────
        if ($type -eq 'azurerm_subnet_network_security_group_association')
        {
            if (-not $after.name -and ($addr -match '\["([^"]+)"\]'))
            {
                $after | Add-Member name $matches[1]
            }
            $sub = $plan.resource_changes |
                    Where-Object {
                        $_.type -eq 'azurerm_subnet' -and
                                $_.change.after.name -eq $after.name
                    } | Select-Object -First 1
            if ($sub)
            {
                foreach ($p in 'resource_group_name', 'virtual_network_name')
                {
                    if (-not $after.$p)
                    {
                        $after | Add-Member $p $sub.change.after.$p
                    }
                }
                if (-not $after.subnet_id)
                {
                    $sid = Get-AzureCliTerraformImportResourceId `
                           'azurerm_subnet' $sub.change.after
                    if ($sid)
                    {
                        $after | Add-Member subnet_id $sid
                    }
                }
            }
        }

        try
        {
            $id = Get-AzureCliTerraformImportResourceId -TfType $type -After $after
            if (-not $id)
            {
                _LogMessage WARN "⤫  No ARM ID for ${addr} (${type}) — skipping" `
                           -InvocationName $MyInvocation.MyCommand.Name
                continue
            }

            _LogMessage INFO "✓  Mapped ${addr} → ${id}" -InvocationName $MyInvocation.MyCommand.Name

            if ($type -ne 'azurerm_subnet_network_security_group_association')
            {
                $showCmd = "az resource show --ids `"$id`" --query id -o tsv"
                _LogMessage INFO $showCmd -InvocationName $MyInvocation.MyCommand.Name
                if (-not (az resource show --ids $id --query id -o tsv 2> $null))
                {
                    _LogMessage WARN "⤫  Azure says not found — skipping ${addr}" `
                               -InvocationName $MyInvocation.MyCommand.Name
                    continue
                }
                _LogMessage INFO "✓  Confirmed existing resource for ${addr}" `
                           -InvocationName $MyInvocation.MyCommand.Name
            }

            $imports += [pscustomobject]@{ Address = $addr; Id = $id }
        }
        catch
        {
            _LogMessage ERROR "Lookup/import prep failed for ${addr}: $_" `
                       -InvocationName $MyInvocation.MyCommand.Name
        }
    }

    if (-not $imports)
    {
        _LogMessage INFO "Nothing to import – plan has no unmanaged Azure resources." `
                   -InvocationName $MyInvocation.MyCommand.Name
        return
    }

    # ── NEW: sort parent → child (fewer “/” first) ──────────────────────────
    $imports = $imports | Sort-Object { (($_.Id -split '/').Count) }

    try
    {
        $imports | Export-Csv $Manifest -NoTypeInformation
        _LogMessage INFO "Wrote manifest to $Manifest" -InvocationName $MyInvocation.MyCommand.Name
    }
    catch
    {
        _LogMessage ERROR "Failed to write manifest: $_" -InvocationName $MyInvocation.MyCommand.Name
    }

    foreach ($i in $imports)
    {
        $cmdArgs = @('--%', $i.Address, $i.Id)
        if ($WhatIf)
        {
            _LogMessage INFO "[DRY-RUN] terraform import $( $cmdArgs -join ' ' )" `
                       -InvocationName $MyInvocation.MyCommand.Name
            continue
        }

        try
        {
            Push-Location $CodePath
            _LogMessage INFO "Importing $( $i.Address )" -InvocationName $MyInvocation.MyCommand.Name
            & terraform import @cmdArgs 2>&1
            _LogMessage INFO "Imported $( $i.Address )" -InvocationName $MyInvocation.MyCommand.Name
        }
        catch
        {
            _LogMessage ERROR "terraform import failed for $( $i.Address ): $_" `
                       -InvocationName $MyInvocation.MyCommand.Name
        }
        finally
        {
            Pop-Location
        }
    }

    _LogMessage INFO "Completed: $( $imports.Count ) resource(s) processed." `
               -InvocationName $MyInvocation.MyCommand.Name
}

Export-ModuleMember -Function `
    Get-AzureCliTerraformImportResourceId, `
     Invoke-TerraformImportFromPlan
