# Check if multiple files exist
function Test-PathExists
{
    param(
        [string[]]$Paths
    )

    foreach ($Path in $Paths)
    {
        if (-not (Test-Path $Path))
        {
            _LogMessage -Level "ERROR" -Message "File not found: $Path" -InvocationName $MyInvocation.MyCommand.Name
        }
        else
        {
            _LogMessage -Level "INFO" -Message "Found file: $Path" -InvocationName $MyInvocation.MyCommand.Name
        }
    }
}

# Check if multiple programs are installed
function Get-InstalledPrograms
{
    param(
        [string[]]$Programs
    )

    foreach ($Program in $Programs)
    {
        $programPath = Get-Command $Program -ErrorAction SilentlyContinue
        if (-not $programPath)
        {
            _LogMessage -Level "ERROR" -Message "Program not found: $Program" -InvocationName $MyInvocation.MyCommand.Name
        }
        else
        {
            _LogMessage -Level "INFO" -Message "Found program: $Program" -InvocationName $MyInvocation.MyCommand.Name
        }
    }
}

# Generate a new password
function New-Password
{
    param (
        [int] $partLength = 5, # Length of each part of the password
        [string] $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+<>,.?/:;~`-=',
        [string] $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
        [string] $lower = 'abcdefghijklmnopqrstuvwxyz',
        [string] $numbers = '0123456789',
        [string] $special = '!@#$%^&*()_+<>,.?/:;~`-='
    )

    # Helper function to generate a random sequence from the alphabet
    function New-RandomSequence
    {
        param (
            [int] $length,
            [string] $alphabet
        )

        $sequence = New-Object char[] $length
        for ($i = 0; $i -lt $length; $i++) {
            $randomIndex = Get-Random -Minimum 0 -Maximum $alphabet.Length
            $sequence[$i] = $alphabet[$randomIndex]
        }

        return $sequence -join ''
    }

    try
    {
        # Ensure each part has at least one character of each type
        $minLength = 4
        if ($partLength -lt $minLength)
        {
            _LogMessage -Level "ERROR" -Message "Each part of the password must be at least $minLength characters to ensure complexity." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            throw "Invalid password part length. Must be at least $minLength."
        }

        _LogMessage -Level "INFO" -Message "Generating password with part length $partLength." -InvocationName "$( $MyInvocation.MyCommand.Name )"

        $part1 = Generate-RandomSequence -length $partLength -alphabet $alphabet
        $part2 = Generate-RandomSequence -length $partLength -alphabet $alphabet
        $part3 = Generate-RandomSequence -length $partLength -alphabet $alphabet

        # Ensuring at least one character from each category in each part
        $part1 = $upper[(Get-Random -Maximum $upper.Length)] + $part1.Substring(1)
        $part2 = $lower[(Get-Random -Maximum $lower.Length)] + $part2.Substring(1)
        $part3 = $numbers[(Get-Random -Maximum $numbers.Length)] + $special[(Get-Random -Maximum $special.Length)] + $part3.Substring(2)

        # Concatenate parts with separators
        $password = "$part1-$part2-$part3"

        _LogMessage -Level "INFO" -Message "Password generated successfully." -InvocationName "$( $MyInvocation.MyCommand.Name )"

        return $password
    }
    catch
    {
        _LogMessage -Level "ERROR" -Message "An error occurred during password generation: $_" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        throw
    }
}

# Check if multiple environment variables exist
function Test-EnvironmentVariablesExist
{
    param(
        [string[]]$EnvVars    # names to check
    )

    $missing = @()

    foreach ($name in $EnvVars)
    {
        if (-not (Get-Item "Env:$name" -ErrorAction SilentlyContinue))
        {
            _LogMessage -Level 'DEBUG' -Message "ENV MISSING: $name" -InvocationName $MyInvocation.MyCommand.Name
            $missing += $name
        }
        else
        {
            _LogMessage -Level 'DEBUG' -Message "ENV FOUND   : $name" -InvocationName $MyInvocation.MyCommand.Name
        }
    }

    if ($missing.Count)
    {
        $msg = "Missing environment variables: $( $missing -join ', ' )"
        _LogMessage -Level 'ERROR' -Message $msg -InvocationName $MyInvocation.MyCommand.Name
        throw $msg
    }
}


# Convert string to boolean
function ConvertTo-Boolean {
    param (
        [string]$value
    )
    try {
        if ([string]::IsNullOrWhiteSpace($value)) {
            _LogMessage -Level "DEBUG" -Message "Input value '$value' is null or whitespace, treating as `$false`." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            return $false
        }
        $valueLower = $value.ToLower()
        if ($valueLower -eq "true") {
            _LogMessage -Level "DEBUG" -Message "Successfully converted '$value' to $true." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            return $true
        }
        elseif ($valueLower -eq "false") {
            _LogMessage -Level "DEBUG" -Message "Successfully converted '$value' to $false." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            return $false
        }
        else {
            _LogMessage -Level "ERROR" -Message "Invalid value '$value' provided for boolean conversion. Expected 'true' or 'false'." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            exit 1
        }
    }
    catch {
        _LogMessage -Level "ERROR" -Message "Error occurred while converting '$value' to boolean: $_" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        exit 1
    }
}


function ConvertTo-Null {
    param (
        [string]$value
    )
    try {
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq "''" -or $value -eq '""') {
            _LogMessage -Level "DEBUG" -Message "Converted input '$value' to null." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            return $null
        } else {
            _LogMessage -Level "DEBUG" -Message "Input '$value' is not null or empty, returning original value." -InvocationName "$( $MyInvocation.MyCommand.Name )"
            return $value
        }
    } catch {
        _LogMessage -Level "ERROR" -Message "Error occurred while converting '$value' to null: $_" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        exit 1
    }
}

function Assert-WhichOs
{
    [CmdletBinding()]
    param(
        [switch]$PassThru    # only emit output when this is present
    )

    _LogMessage -Level 'INFO' -Message 'Detecting operating system…' -InvocationName "$( $MyInvocation.MyCommand.Name )"

    if ($IsLinux)
    {
        $os = 'Linux'
    }
    elseif ($IsWindows)
    {
        $os = 'Windows'
    }
    elseif ($IsMacOS)
    {
        $os = 'macOS'
    }
    else
    {
        _LogMessage -Level 'ERROR' -Message 'Unable to determine operating system.' -InvocationName "$( $MyInvocation.MyCommand.Name )"
        throw 'Unable to determine operating system.'
    }

    _LogMessage -Level 'INFO' -Message "Operating system detected: $os" -InvocationName "$( $MyInvocation.MyCommand.Name )"

    if ($PassThru)
    {
        return $os
    }
}



# Export functions
Export-ModuleMember -Function `
    Test-PathExists, `
     Get-InstalledPrograms, `
     New-RandomSequence, `
     New-Password, `
     Test-EnvironmentVariablesExist, `
     ConvertTo-Boolean, `
     ConvertTo-Null, `
     Convert-AzureResourceId, `
     Assert-WhichOs
