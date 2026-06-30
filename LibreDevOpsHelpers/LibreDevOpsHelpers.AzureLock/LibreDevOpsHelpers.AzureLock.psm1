Set-StrictMode -Version Latest

function Get-LdoResourceGroupLock {
    <#
    .SYNOPSIS
        Lists the management locks on a resource group.

    .DESCRIPTION
        Returns the resource-group-scoped management locks as objects with Name, Level and Notes.
        Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group to inspect.

    .EXAMPLE
        Get-LdoResourceGroupLock -ResourceGroup rg-ldo-uks-prd-001

    .OUTPUTS
        System.Management.Automation.PSObject[]
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup
    )

    $json = az lock list --resource-group $ResourceGroup -o json
    Assert-LdoLastExitCode -Operation "az lock list ($ResourceGroup)"
    $locks = if ([string]::IsNullOrWhiteSpace($json)) { @() } else { @($json | ConvertFrom-Json) }
    return @($locks | ForEach-Object {
            [pscustomobject]@{ Name = $_.name; Level = $_.level; Notes = $_.notes }
        })
}

function Remove-LdoResourceGroupLock {
    <#
    .SYNOPSIS
        Removes management lock(s) from a resource group.

    .DESCRIPTION
        Deletes a named lock, or every resource-group-scoped lock when no name is given. Used by the
        action's lock-dance to take locks off before an apply or destroy so Terraform is not blocked.

    .PARAMETER ResourceGroup
        Resource group whose lock(s) to remove.

    .PARAMETER LockName
        Specific lock name to remove. When omitted, all locks on the resource group are removed.

    .EXAMPLE
        Remove-LdoResourceGroupLock -ResourceGroup rg-ldo-uks-prd-001

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Operational lock-dance helper; mirrors the firewall rule helpers.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [string]$LockName
    )

    $names = if ($LockName) { @($LockName) } else { @((Get-LdoResourceGroupLock -ResourceGroup $ResourceGroup).Name) }
    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        az lock delete --name $name --resource-group $ResourceGroup | Out-Null
        Assert-LdoLastExitCode -Operation "az lock delete ($name on $ResourceGroup)"
        Write-LdoLog -Level INFO -Message "Removed management lock '$name' on resource group '$ResourceGroup'."
    }
}

function Add-LdoResourceGroupLock {
    <#
    .SYNOPSIS
        Creates a management lock on a resource group.

    .DESCRIPTION
        Creates a CanNotDelete or ReadOnly lock at the resource group scope. Used by the action's
        lock-dance to restore a lock after an apply.

    .PARAMETER ResourceGroup
        Resource group to lock.

    .PARAMETER LockName
        Name for the lock.

    .PARAMETER LockLevel
        CanNotDelete or ReadOnly.

    .PARAMETER Notes
        Optional notes recorded on the lock.

    .EXAMPLE
        Add-LdoResourceGroupLock -ResourceGroup rg-ldo-uks-prd-001 -LockName lock-rg-ldo-uks-prd-001 -LockLevel CanNotDelete

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Operational lock-dance helper; mirrors the firewall rule helpers.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LockName,
        [Parameter(Mandatory)][ValidateSet('CanNotDelete', 'ReadOnly')][string]$LockLevel,
        [string]$Notes = ''
    )

    $lockArgs = @('lock', 'create', '--name', $LockName, '--resource-group', $ResourceGroup, '--lock-type', $LockLevel)
    if ($Notes) { $lockArgs += @('--notes', $Notes) }
    az @lockArgs | Out-Null
    Assert-LdoLastExitCode -Operation "az lock create ($LockName on $ResourceGroup)"
    Write-LdoLog -Level INFO -Message "Added '$LockLevel' management lock '$LockName' on resource group '$ResourceGroup'."
}

function Get-LdoResourceGroupNamesFromPlan {
    <#
    .SYNOPSIS
        Returns the azurerm_resource_group names from a Terraform plan rendered to JSON.

    .DESCRIPTION
        Walks planned_values and prior_state (root and all child modules) for azurerm_resource_group
        resources and returns their names. Used by the lock-dance to find which resource groups to
        unlock for a run; prior_state is included so a destroy plan (whose planned_values is empty)
        still yields the groups being torn down.

    .PARAMETER PlanJsonPath
        Path to the plan JSON (terraform show -json).

    .EXAMPLE
        Get-LdoResourceGroupNamesFromPlan -PlanJsonPath ./tfplan.plan.json

    .OUTPUTS
        System.String[]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanJsonPath
    )

    if (-not (Test-Path $PlanJsonPath)) {
        throw "Plan JSON not found: $PlanJsonPath"
    }

    # Parse as nested hashtables so missing keys are handled with ContainsKey (no Set-StrictMode
    # property-navigation errors on, for example, a destroy plan's empty planned_values).
    $plan = Get-Content -Raw -LiteralPath $PlanJsonPath | ConvertFrom-Json -AsHashtable
    $names = [System.Collections.Generic.List[string]]::new()

    $stack = [System.Collections.Generic.Stack[object]]::new()
    # planned_values covers apply (the post-apply state); prior_state covers destroy (planned_values
    # is empty for a destroy plan, but prior_state still lists the groups being removed).
    if ($plan.ContainsKey('planned_values') -and $plan['planned_values'].ContainsKey('root_module')) {
        $stack.Push($plan['planned_values']['root_module'])
    }
    if ($plan.ContainsKey('prior_state') -and $plan['prior_state'].ContainsKey('values') -and $plan['prior_state']['values'].ContainsKey('root_module')) {
        $stack.Push($plan['prior_state']['values']['root_module'])
    }
    while ($stack.Count -gt 0) {
        $module = $stack.Pop()
        if ($null -eq $module) { continue }
        if ($module.ContainsKey('resources')) {
            foreach ($r in @($module['resources'])) {
                if ($r['type'] -eq 'azurerm_resource_group' -and $r.ContainsKey('values') -and $r['values'].ContainsKey('name') -and $r['values']['name']) {
                    $names.Add([string]$r['values']['name'])
                }
            }
        }
        if ($module.ContainsKey('child_modules')) {
            foreach ($c in @($module['child_modules'])) { $stack.Push($c) }
        }
    }

    return @($names | Select-Object -Unique)
}

Export-ModuleMember -Function `
    Get-LdoResourceGroupLock, `
    Remove-LdoResourceGroupLock, `
    Add-LdoResourceGroupLock, `
    Get-LdoResourceGroupNamesFromPlan
