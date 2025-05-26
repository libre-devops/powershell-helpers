function Get-GitHubActionsInput
{
    param(
        [string]$name,
        $default = $null
    )
    # Try underscore format (GitHub standard)
    $envVar = "INPUT_$($name.Replace('-', '_').ToUpper() )"
    $value = [System.Environment]::GetEnvironmentVariable($envVar)
    if (![string]::IsNullOrEmpty($value))
    {
        return $value
    }
    # Fallback: try dash format (what your env has)
    $envVarDash = "INPUT_$($name.ToUpper() )"
    $valueDash = [System.Environment]::GetEnvironmentVariable($envVarDash)
    if (![string]::IsNullOrEmpty($valueDash))
    {
        return $valueDash
    }
    return $default
}

Export-ModuleMember -Function Get-GitHubActionsInput