Set-StrictMode -Version Latest

function Add-LdoNsgCurrentIpRule {
    <#
    .SYNOPSIS
        Creates or updates a network security group rule for the caller's public IP.

    .DESCRIPTION
        Resolves the caller's current public IP and creates an NSG rule allowing (or denying)
        it. If a rule with the same name already exists it is deleted and recreated, so the
        rule always reflects the current IP. Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the NSG.

    .PARAMETER NsgName
        Name of the network security group.

    .PARAMETER RuleName
        Name of the rule to create or update.

    .PARAMETER Priority
        Rule priority (100-4096). Lower numbers are evaluated first.

    .PARAMETER Direction
        Inbound or Outbound.

    .PARAMETER Access
        Allow or Deny.

    .PARAMETER Protocol
        Protocol to match. Defaults to Tcp.

    .PARAMETER SourcePortRange
        Source port range. Defaults to '*'.

    .PARAMETER DestinationPortRange
        Destination port range. Defaults to '*'.

    .PARAMETER DestinationAddressPrefix
        Destination address prefix. Defaults to 'VirtualNetwork'.

    .EXAMPLE
        Add-LdoNsgCurrentIpRule -ResourceGroup rg -NsgName nsg -RuleName allow-me `
            -Priority 200 -Direction Inbound -Access Allow

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$NsgName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuleName,
        [Parameter(Mandatory)][ValidateRange(100, 4096)][int]$Priority,
        [Parameter(Mandatory)][ValidateSet('Inbound', 'Outbound')][string]$Direction,
        [Parameter(Mandatory)][ValidateSet('Allow', 'Deny')][string]$Access,
        [ValidateSet('Tcp', 'Udp', 'Icmp', 'Esp', 'Ah', '*')][string]$Protocol = 'Tcp',
        [string]$SourcePortRange = '*',
        [string]$DestinationPortRange = '*',
        [string]$DestinationAddressPrefix = 'VirtualNetwork'
    )

    $ip = Get-LdoPublicIpAddress

    $existing = az network nsg rule list --resource-group $ResourceGroup --nsg-name $NsgName --query "[?name=='$RuleName']" -o tsv
    if ($existing) {
        Write-LdoLog -Level INFO -Message "Rule $RuleName already exists on $NsgName; recreating it with the current IP."
        az network nsg rule delete --resource-group $ResourceGroup --nsg-name $NsgName --name $RuleName | Out-Null
        Assert-LdoLastExitCode -Operation "az network nsg rule delete ($RuleName)"
    }

    az network nsg rule create `
        --resource-group $ResourceGroup `
        --nsg-name $NsgName `
        --name $RuleName `
        --access $Access `
        --protocol $Protocol `
        --direction $Direction `
        --priority $Priority `
        --source-address-prefixes $ip `
        --source-port-ranges $SourcePortRange `
        --destination-address-prefixes $DestinationAddressPrefix `
        --destination-port-ranges $DestinationPortRange | Out-Null
    Assert-LdoLastExitCode -Operation "az network nsg rule create ($RuleName)"

    Write-LdoLog -Level INFO -Message "Rule $RuleName set for $ip on $NsgName."
}

function Remove-LdoNsgRule {
    <#
    .SYNOPSIS
        Removes a network security group rule by name if it exists.

    .DESCRIPTION
        Deletes the named NSG rule when present, and does nothing (no error) when it is
        already absent. Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the NSG.

    .PARAMETER NsgName
        Name of the network security group.

    .PARAMETER RuleName
        Name of the rule to remove.

    .EXAMPLE
        Remove-LdoNsgRule -ResourceGroup rg -NsgName nsg -RuleName allow-me

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$NsgName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuleName
    )

    $existing = az network nsg rule list --resource-group $ResourceGroup --nsg-name $NsgName --query "[?name=='$RuleName']" -o tsv
    if (-not $existing) {
        Write-LdoLog -Level INFO -Message "Rule $RuleName does not exist on $NsgName; nothing to remove."
        return
    }

    az network nsg rule delete --resource-group $ResourceGroup --nsg-name $NsgName --name $RuleName | Out-Null
    Assert-LdoLastExitCode -Operation "az network nsg rule delete ($RuleName)"
    Write-LdoLog -Level INFO -Message "Removed rule $RuleName from $NsgName."
}

Export-ModuleMember -Function `
    Add-LdoNsgCurrentIpRule, `
    Remove-LdoNsgRule
