function Test-TenvExists
{
    param(
        [string]$TerraformVersion = 'default'
    )

    try
    {
        $tenvPath = Get-Command tenv -ErrorAction Stop
        _LogMessage -Level "INFO" -Message "Tenv found at: $( $tenvPath.Source )" -InvocationName "$( $MyInvocation.MyCommand.Name )"

        if ($TerraformVersion -ne 'default')
        {
            _LogMessage -Level "INFO" -Message "Desired Terraform version is $TerraformVersion – installing / switching via tenv..." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            tenv tf install $TerraformVersion --verbose
            tenv tf use     $TerraformVersion --verbose
        }
    }
    catch
    {
        _LogMessage -Level "WARNING" -Message "tenv is not installed or not in PATH – skipping version management." -InvocationName "$( $MyInvocation.MyCommand.Name )"
    }
}

Export-ModuleMember -Function Test-TenvExists
