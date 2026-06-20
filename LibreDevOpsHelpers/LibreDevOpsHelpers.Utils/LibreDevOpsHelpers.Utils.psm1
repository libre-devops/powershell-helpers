Set-StrictMode -Version Latest

function Get-LdoSecureRandomInt {
    # Internal. Returns a cryptographically strong integer in [0, Maximum).
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][int]$Maximum)

    return [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($Maximum)
}

function Test-LdoPath {
    <#
    .SYNOPSIS
        Tests that one or more paths exist.

    .DESCRIPTION
        Returns $true only when every supplied path exists. Missing paths are logged as
        warnings, found paths as debug. Useful as a precondition guard.

    .PARAMETER Path
        One or more paths to test.

    .EXAMPLE
        if (-not (Test-LdoPath -Path './main.tf', './variables.tf')) { throw 'Missing files' }

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path
    )

    $allExist = $true
    foreach ($item in $Path) {
        if (Test-Path -Path $item) {
            Write-LdoLog -Level DEBUG -Message "Found path: $item"
        }
        else {
            Write-LdoLog -Level WARN -Message "Path not found: $item"
            $allExist = $false
        }
    }

    return $allExist
}

function Assert-LdoCommand {
    <#
    .SYNOPSIS
        Asserts that one or more commands are available on PATH.

    .DESCRIPTION
        Throws when any of the named commands cannot be resolved. Use before shelling out
        to an external CLI so the failure is clear rather than a cryptic execution error.

    .PARAMETER Name
        One or more command or executable names to check.

    .EXAMPLE
        Assert-LdoCommand -Name 'az', 'terraform'

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name
    )

    $missing = @()
    foreach ($command in $Name) {
        if (Get-Command -Name $command -ErrorAction SilentlyContinue) {
            Write-LdoLog -Level DEBUG -Message "Found command: $command"
        }
        else {
            $missing += $command
        }
    }

    if ($missing.Count -gt 0) {
        $message = "Required command(s) not found on PATH: $($missing -join ', ')"
        Write-LdoLog -Level ERROR -Message $message
        throw $message
    }
}

function Assert-LdoEnvironmentVariable {
    <#
    .SYNOPSIS
        Asserts that one or more environment variables are set.

    .DESCRIPTION
        Throws when any named environment variable is missing or empty. Values are never
        logged.

    .PARAMETER Name
        One or more environment variable names to check.

    .EXAMPLE
        Assert-LdoEnvironmentVariable -Name 'ARM_CLIENT_ID', 'ARM_TENANT_ID'

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name
    )

    $missing = @()
    foreach ($variable in $Name) {
        $value = [System.Environment]::GetEnvironmentVariable($variable)
        if ([string]::IsNullOrWhiteSpace($value)) {
            $missing += $variable
        }
        else {
            Write-LdoLog -Level DEBUG -Message "Environment variable present: $variable"
        }
    }

    if ($missing.Count -gt 0) {
        $message = "Missing environment variable(s): $($missing -join ', ')"
        Write-LdoLog -Level ERROR -Message $message
        throw $message
    }
}

function New-LdoRandomSequence {
    <#
    .SYNOPSIS
        Generates a random character sequence from an alphabet.

    .DESCRIPTION
        Uses a cryptographically strong random number generator to pick characters from
        the supplied alphabet.

    .PARAMETER Length
        Number of characters to generate.

    .PARAMETER Alphabet
        The set of characters to draw from.

    .EXAMPLE
        New-LdoRandomSequence -Length 16 -Alphabet 'abcdef0123456789'

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 4096)]
        [int]$Length,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Alphabet
    )

    $builder = [System.Text.StringBuilder]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) {
        $null = $builder.Append($Alphabet[(Get-LdoSecureRandomInt -Maximum $Alphabet.Length)])
    }
    return $builder.ToString()
}

function New-LdoPassword {
    <#
    .SYNOPSIS
        Generates a strong random password.

    .DESCRIPTION
        Produces a password of the requested length using a cryptographically strong
        random number generator, guaranteeing at least one uppercase, lowercase, digit and
        special character. The final order is shuffled so the guaranteed characters are not
        positionally predictable.

    .PARAMETER Length
        Total password length. Minimum 8. Defaults to 24.

    .PARAMETER AsSecureString
        Return the password as a SecureString instead of plaintext.

    .EXAMPLE
        New-LdoPassword -Length 32

    .EXAMPLE
        $secret = New-LdoPassword -AsSecureString

    .OUTPUTS
        System.String or System.Security.SecureString
    #>
    [CmdletBinding()]
    [OutputType([string], [System.Security.SecureString])]
    param(
        [ValidateRange(8, 256)]
        [int]$Length = 24,

        [switch]$AsSecureString
    )

    $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    $lower = 'abcdefghijklmnopqrstuvwxyz'
    $digit = '0123456789'
    $special = '!@#$%^&*()-_=+[]{}'
    $all = $upper + $lower + $digit + $special

    $chars = [System.Collections.Generic.List[char]]::new()
    $chars.Add($upper[(Get-LdoSecureRandomInt -Maximum $upper.Length)])
    $chars.Add($lower[(Get-LdoSecureRandomInt -Maximum $lower.Length)])
    $chars.Add($digit[(Get-LdoSecureRandomInt -Maximum $digit.Length)])
    $chars.Add($special[(Get-LdoSecureRandomInt -Maximum $special.Length)])

    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars.Add($all[(Get-LdoSecureRandomInt -Maximum $all.Length)])
    }

    # Fisher-Yates shuffle so the guaranteed characters are not always at the front.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = Get-LdoSecureRandomInt -Maximum ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    Write-LdoLog -Level DEBUG -Message "Generated a password of length $Length."

    if ($AsSecureString) {
        # Build the SecureString character by character so the password is never held
        # in an interned plaintext string.
        $secure = [System.Security.SecureString]::new()
        foreach ($char in $chars) { $secure.AppendChar($char) }
        $secure.MakeReadOnly()
        return $secure
    }

    return (-join $chars)
}

function ConvertTo-LdoBoolean {
    <#
    .SYNOPSIS
        Converts a string to a boolean safely.

    .DESCRIPTION
        Accepts true/false, 1/0, yes/no and y/n (case-insensitive). Empty or whitespace
        becomes $false. Anything else throws, so a malformed value never silently maps to
        the wrong boolean (unlike a plain [bool] cast where any non-empty string is $true).

    .PARAMETER Value
        The string to convert.

    .EXAMPLE
        ConvertTo-LdoBoolean -Value $env:ENABLE_FEATURE

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in 'true', '1', 'yes', 'y' } { return $true }
        { $_ -in 'false', '0', 'no', 'n' } { return $false }
        default {
            $message = "Cannot convert '$Value' to a boolean. Expected true/false, 1/0, yes/no."
            Write-LdoLog -Level ERROR -Message $message
            throw $message
        }
    }
}

function ConvertTo-LdoNull {
    <#
    .SYNOPSIS
        Normalises empty or quote-only strings to $null.

    .DESCRIPTION
        Returns $null when the value is null, whitespace, or just a pair of empty quotes
        ('' or ""). Otherwise returns the value unchanged. Handy for cleaning values passed
        through shells and pipelines.

    .PARAMETER Value
        The value to normalise.

    .EXAMPLE
        ConvertTo-LdoNull -Value $env:OPTIONAL_SETTING

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq "''" -or $Value -eq '""') {
        return $null
    }
    return $Value
}

function Get-LdoOperatingSystem {
    <#
    .SYNOPSIS
        Returns the current operating system family.

    .DESCRIPTION
        Returns one of 'Linux', 'Windows' or 'macOS'. Throws if the platform cannot be
        determined.

    .EXAMPLE
        switch (Get-LdoOperatingSystem) { 'Linux' { ... } 'Windows' { ... } }

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $os = if ($IsLinux) { 'Linux' }
    elseif ($IsWindows) { 'Windows' }
    elseif ($IsMacOS) { 'macOS' }
    else { $null }

    if (-not $os) {
        $message = 'Unable to determine the operating system.'
        Write-LdoLog -Level ERROR -Message $message
        throw $message
    }

    Write-LdoLog -Level DEBUG -Message "Operating system detected: $os"
    return $os
}

function Assert-LdoLastExitCode {
    <#
    .SYNOPSIS
        Throws when the last native command exited non-zero.

    .DESCRIPTION
        Checks $LASTEXITCODE and throws a descriptive error naming the operation when it is not
        zero. Call immediately after invoking an external CLI so failures surface clearly.

    .PARAMETER Operation
        Description of the command that ran, used in the error message.

    .EXAMPLE
        az group create --name rg --location uksouth
        Assert-LdoLastExitCode -Operation 'az group create'

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Operation
    )

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-LdoPublicIpAddress {
    <#
    .SYNOPSIS
        Returns the caller's public IPv4 address.

    .DESCRIPTION
        Queries a public IP echo service and returns the trimmed address. Throws when no address
        can be determined.

    .PARAMETER Uri
        The IP echo endpoint. Defaults to https://checkip.amazonaws.com.

    .PARAMETER TimeoutSec
        Maximum seconds to wait for the endpoint. Defaults to 15.

    .EXAMPLE
        $ip = Get-LdoPublicIpAddress

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateNotNullOrEmpty()][string]$Uri = 'https://checkip.amazonaws.com',
        [ValidateRange(1, 300)][int]$TimeoutSec = 15
    )

    $ip = (Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec -ErrorAction Stop).Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) {
        throw 'Failed to determine the public IP address.'
    }

    # Validate the response really is an IP; an error page or captive portal would otherwise
    # be returned to the caller as if it were an address.
    $parsed = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) {
        throw "Public IP endpoint '$Uri' returned an unexpected value: '$ip'"
    }

    return $ip
}

Export-ModuleMember -Function `
    Test-LdoPath, `
    Assert-LdoCommand, `
    Assert-LdoEnvironmentVariable, `
    New-LdoRandomSequence, `
    New-LdoPassword, `
    ConvertTo-LdoBoolean, `
    ConvertTo-LdoNull, `
    Get-LdoOperatingSystem, `
    Assert-LdoLastExitCode, `
    Get-LdoPublicIpAddress
