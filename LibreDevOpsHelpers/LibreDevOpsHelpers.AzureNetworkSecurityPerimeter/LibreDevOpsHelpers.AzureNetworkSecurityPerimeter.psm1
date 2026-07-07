Set-StrictMode -Version Latest

function Confirm-LdoNspCliExtension {
    <#
    .SYNOPSIS
        Ensures the Azure CLI 'nsp' extension (which provides `az network perimeter`) is installed.

    .DESCRIPTION
        The Network Security Perimeter commands live in the preview 'nsp' extension, which base Azure
        CLI does not ship. On a non-interactive runner an auto-install prompt would stall, so this
        installs it explicitly (allowing the preview) when it is not already present.

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $present = az extension list --query "[?name=='nsp'].name" -o tsv 2>$null
    if (-not $present) {
        Write-LdoLog -Level INFO -Message "Installing the Azure CLI 'nsp' extension (required for az network perimeter)."
        az extension add --name nsp --allow-preview true --yes 2>$null | Out-Null
        Assert-LdoLastExitCode -Operation "az extension add nsp"
    }
}


# Probes a perimeter for the dance. Returns $true when it exists. When it does not: with
# -SoftFail logs a WARN and returns $false (first run, the stack creates the perimeter; the next
# run finds it and dances normally); without -SoftFail throws. Failures OTHER than absence
# always throw, so auth or extension problems never masquerade as a first run.
function Test-LdoNspDanceTarget {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$PerimeterName,
        [switch]$SoftFail
    )

    $probe = az network perimeter show -g $ResourceGroup -n $PerimeterName -o none 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }

    $text = ($probe | Out-String)
    if ($text -notmatch '(?i)notfound|could not be found|does not exist|was not found') {
        throw "az network perimeter show ($PerimeterName) failed for a reason other than absence: $text"
    }

    if (-not $SoftFail) {
        throw "Network security perimeter $PerimeterName was not found in $ResourceGroup. Pass -SoftFail when the stack itself creates the perimeter (first run)."
    }

    Write-LdoLog -Level WARN -Message "Network security perimeter $PerimeterName does not exist, so cannot append the runner IP; skipping (-SoftFail). The next run will find it and dance normally."
    return $false
}

function Add-LdoNspCurrentIpRule {
    <#
    .SYNOPSIS
        Adds an inbound access rule for the caller's public IP to a Network Security Perimeter profile.

    .DESCRIPTION
        Resolves the caller's current public IP and creates an inbound access rule on the given NSP
        profile allowing that IP, so a runner can reach a resource's data plane while it is inside an
        Enforced perimeter. If a rule with the same name already exists it is deleted and recreated so
        it always reflects the current IP. This is the NSP counterpart to Add-LdoStorageCurrentIpRule;
        pair it with Remove-LdoNspRule in a finally block. Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the network security perimeter.

    .PARAMETER PerimeterName
        Name of the network security perimeter.

    .PARAMETER ProfileName
        Name of the perimeter profile to attach the rule to.

    .PARAMETER RuleName
        Name of the access rule to create or update. Defaults to ldo-runner-allow.

    .PARAMETER SoftFail
        Skip (with a warning) instead of failing when the perimeter does not exist yet, for
        stacks that create the perimeter themselves on the first run. Absence is the only
        condition softened: any other failure still throws.

    .EXAMPLE
        Add-LdoNspCurrentIpRule -ResourceGroup rg -PerimeterName nsp -ProfileName default

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PerimeterName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProfileName,
        [string]$RuleName = 'ldo-runner-allow',
        [switch]$SoftFail
    )

    Confirm-LdoNspCliExtension

    if (-not (Test-LdoNspDanceTarget -ResourceGroup $ResourceGroup -PerimeterName $PerimeterName -SoftFail:$SoftFail)) { return }

    $ip = Get-LdoPublicIpAddress
    Write-LdoLog -Level INFO -Message "Current public IP: $ip"

    $existing = az network perimeter profile access-rule list --resource-group $ResourceGroup --perimeter-name $PerimeterName --profile-name $ProfileName --query "[?name=='$RuleName']" -o tsv 2>$null
    if ($existing) {
        Write-LdoLog -Level INFO -Message "NSP rule $RuleName already exists on $PerimeterName/$ProfileName; recreating it with the current IP."
        az network perimeter profile access-rule delete --resource-group $ResourceGroup --perimeter-name $PerimeterName --profile-name $ProfileName --name $RuleName --yes | Out-Null
        Assert-LdoLastExitCode -Operation "az network perimeter profile access-rule delete ($RuleName)"
    }

    az network perimeter profile access-rule create `
        --resource-group $ResourceGroup `
        --perimeter-name $PerimeterName `
        --profile-name $ProfileName `
        --name $RuleName `
        --direction Inbound `
        --address-prefixes "$ip/32" | Out-Null
    Assert-LdoLastExitCode -Operation "az network perimeter profile access-rule create ($RuleName)"

    Write-LdoLog -Level INFO -Message "Added temporary NSP inbound rule $RuleName for $ip on $PerimeterName/$ProfileName."
}

function Remove-LdoNspRule {
    <#
    .SYNOPSIS
        Removes a Network Security Perimeter access rule by name if it exists.

    .DESCRIPTION
        Deletes the named access rule from the given NSP profile when present, and does nothing (no
        error) when it is already absent. Requires the Azure CLI to be signed in.

    .PARAMETER ResourceGroup
        Resource group containing the network security perimeter.

    .PARAMETER PerimeterName
        Name of the network security perimeter.

    .PARAMETER ProfileName
        Name of the perimeter profile the rule is on.

    .PARAMETER RuleName
        Name of the access rule to remove.

    .EXAMPLE
        Remove-LdoNspRule -ResourceGroup rg -PerimeterName nsp -ProfileName default -RuleName ldo-runner-allow

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PerimeterName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ProfileName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RuleName
    )

    Confirm-LdoNspCliExtension

    $existing = az network perimeter profile access-rule list --resource-group $ResourceGroup --perimeter-name $PerimeterName --profile-name $ProfileName --query "[?name=='$RuleName']" -o tsv 2>$null
    if (-not $existing) {
        Write-LdoLog -Level INFO -Message "NSP rule $RuleName does not exist on $PerimeterName/$ProfileName; nothing to remove."
        return
    }

    az network perimeter profile access-rule delete --resource-group $ResourceGroup --perimeter-name $PerimeterName --profile-name $ProfileName --name $RuleName --yes | Out-Null
    Assert-LdoLastExitCode -Operation "az network perimeter profile access-rule delete ($RuleName)"
    Write-LdoLog -Level INFO -Message "Removed NSP rule $RuleName from $PerimeterName/$ProfileName."
}

Export-ModuleMember -Function `
    Add-LdoNspCurrentIpRule, `
    Remove-LdoNspRule
