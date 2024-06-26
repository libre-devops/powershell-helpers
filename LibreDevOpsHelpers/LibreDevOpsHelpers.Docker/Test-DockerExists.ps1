function Test-DockerExists
{
    [CmdletBinding()]
    param ()

    $dockerCommand = Get-Command docker -ErrorAction Stop

    if ($null -ne $dockerCommand)
    {
        Write-Verbose "[$( $MyInvocation.MyCommand.Name )] Success: Docker found at: $( $dockerCommand.Source )"
    }
    else
    {
        throw "[$( $MyInvocation.MyCommand.Name )] Error: Docker is not installed or not in PATH. Exiting."
    }
}
