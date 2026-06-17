Set-StrictMode -Version Latest

function Get-LdoGitHubActionsInput {
    <#
    .SYNOPSIS
        Reads a GitHub Actions action input from the environment.

    .DESCRIPTION
        Resolves an action input by checking the INPUT_<NAME> environment variable, trying both
        the underscore-normalised form (GitHub's standard, dashes converted to underscores) and
        the raw upper-cased form. Returns the default value when neither is set.

    .PARAMETER Name
        The action input name, for example 'my-input'.

    .PARAMETER Default
        Value to return when the input is not set. Defaults to $null.

    .EXAMPLE
        Get-LdoGitHubActionsInput -Name 'terraform-version' -Default 'latest'

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        $Default = $null
    )

    $envVar = "INPUT_$($Name.Replace('-', '_').ToUpper())"
    $value = [System.Environment]::GetEnvironmentVariable($envVar)
    if (-not [string]::IsNullOrEmpty($value)) {
        return $value
    }

    $envVarRaw = "INPUT_$($Name.ToUpper())"
    $valueRaw = [System.Environment]::GetEnvironmentVariable($envVarRaw)
    if (-not [string]::IsNullOrEmpty($valueRaw)) {
        return $valueRaw
    }

    return $Default
}

Export-ModuleMember -Function Get-LdoGitHubActionsInput
