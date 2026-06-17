Set-StrictMode -Version Latest

function Get-LdoCommandResult {
    # Internal. Runs a command string and returns its captured output and exit code.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Command)

    $global:LASTEXITCODE = 0
    $output = & ([scriptblock]::Create($Command)) 2>&1
    return [pscustomobject]@{
        Output = @($output | ForEach-Object { $_.ToString() })
        ExitCode = $LASTEXITCODE
    }
}

function Test-LdoZeroExitCode {
    <#
    .SYNOPSIS
        Pester operator backing test: asserts a command returns exit code zero.

    .DESCRIPTION
        Runs the command and reports success when its exit code is zero. Returns the
        Succeeded/FailureMessage object expected by Pester custom Should operators. Register it
        with Register-LdoPesterAssertion to use it as 'Should -ReturnZeroExitCode'.

    .PARAMETER ActualValue
        The command string to run.

    .PARAMETER Negate
        When set, inverts the result.

    .PARAMETER Because
        Reason text, kept for Pester signature parity.

    .EXAMPLE
        Test-LdoZeroExitCode -ActualValue 'terraform version'

    .OUTPUTS
        PSCustomObject with Succeeded and FailureMessage.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSReviewUnusedParameter', 'Because', Justification = 'Required for Pester Should operator signature parity.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ActualValue,
        [switch]$Negate,
        [string]$Because
    )

    $failureMessage = $null
    try {
        $result = Get-LdoCommandResult -Command $ActualValue
        $succeeded = ($result.ExitCode -eq 0)
        if ($Negate) {
            $succeeded = -not $succeeded
        }

        if (-not $succeeded) {
            $indented = $result.Output | ForEach-Object { "    $_" } | Out-String
            $failureMessage = "Command '$ActualValue' returned exit code $($result.ExitCode). Output:`n$indented"
        }
    }
    catch {
        $succeeded = $false
        $failureMessage = "Exception thrown while executing '$ActualValue': $($_.Exception.Message)"
    }

    [pscustomobject]@{
        Succeeded = $succeeded
        FailureMessage = $failureMessage
    }
}

function Test-LdoCommandOutputMatch {
    <#
    .SYNOPSIS
        Pester operator backing test: asserts a command's output matches a regex.

    .DESCRIPTION
        Runs the command and reports success when its combined output matches the supplied
        regular expression (case sensitive). Returns the Succeeded/FailureMessage object expected
        by Pester custom Should operators. Register it with Register-LdoPesterAssertion to use it
        as 'Should -MatchCommandOutput'.

    .PARAMETER ActualValue
        The command string to run.

    .PARAMETER RegularExpression
        Regular expression to match against the command output.

    .PARAMETER Negate
        When set, inverts the result.

    .EXAMPLE
        Test-LdoCommandOutputMatch -ActualValue 'terraform version' -RegularExpression 'Terraform v'

    .OUTPUTS
        PSCustomObject with Succeeded and FailureMessage.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ActualValue,
        [Parameter(Mandatory)][string]$RegularExpression,
        [switch]$Negate
    )

    $failureMessage = $null
    try {
        $output = (Get-LdoCommandResult -Command $ActualValue).Output -join "`n"
        $succeeded = ($output -cmatch $RegularExpression)
        if ($Negate) {
            $succeeded = -not $succeeded
        }

        if (-not $succeeded) {
            $notText = if ($Negate) { 'not ' } else { '' }
            $failureMessage = "Expected '$ActualValue' output to ${notText}match regex '$RegularExpression'."
        }
    }
    catch {
        $succeeded = $false
        $failureMessage = "Exception thrown while executing '$ActualValue': $($_.Exception.Message)"
    }

    [pscustomobject]@{
        Succeeded = $succeeded
        FailureMessage = $failureMessage
    }
}

function Register-LdoPesterAssertion {
    <#
    .SYNOPSIS
        Registers the Libre DevOps custom Pester Should operators.

    .DESCRIPTION
        Adds two custom Should operators backed by this module: -ReturnZeroExitCode and
        -MatchCommandOutput. Existing operators with the same name are left in place.

    .EXAMPLE
        Register-LdoPesterAssertion

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (-not (Get-Module Pester)) {
        Import-Module Pester -ErrorAction Stop
    }

    $existing = Get-ShouldOperator | Select-Object -ExpandProperty Name

    if ($existing -notcontains 'ReturnZeroExitCode') {
        Add-ShouldOperator -Name ReturnZeroExitCode -InternalName Test-LdoZeroExitCode -Test ${function:Test-LdoZeroExitCode}
        Write-LdoLog -Level INFO -Message 'Registered Should operator: ReturnZeroExitCode.'
    }
    if ($existing -notcontains 'MatchCommandOutput') {
        Add-ShouldOperator -Name MatchCommandOutput -InternalName Test-LdoCommandOutputMatch -Test ${function:Test-LdoCommandOutputMatch}
        Write-LdoLog -Level INFO -Message 'Registered Should operator: MatchCommandOutput.'
    }
}

function Invoke-LdoPesterTest {
    <#
    .SYNOPSIS
        Runs a single Pester test file and throws when any test fails.

    .DESCRIPTION
        Resolves <TestRoot>/<TestFile>.Tests.ps1, runs it with Pester, and throws when no tests
        run or any test fails. An optional test name filter can be supplied.

    .PARAMETER TestFile
        Test file base name, without the .Tests.ps1 suffix.

    .PARAMETER TestName
        Optional full test name filter.

    .PARAMETER TestRoot
        Folder containing the test files. Defaults to ./tests under the current directory.

    .EXAMPLE
        Invoke-LdoPesterTest -TestFile Logger

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TestFile,
        [string]$TestName,
        [string]$TestRoot = (Join-Path (Get-Location).Path 'tests')
    )

    $testPath = Join-Path $TestRoot "$TestFile.Tests.ps1"
    if (-not (Test-Path $testPath)) {
        throw "Unable to find test file '$TestFile' at '$testPath'."
    }

    Write-LdoLog -Level INFO -Message "Running Pester tests in $testPath"

    if (-not (Get-Module Pester)) {
        Import-Module Pester -ErrorAction Stop
    }

    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $testPath
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    if ($TestName) {
        $configuration.Filter.FullName = $TestName
    }

    $results = Invoke-Pester -Configuration $configuration

    if (-not ($results.FailedCount -eq 0 -and $results.TotalCount -gt 0)) {
        throw 'Test run has failed.'
    }

    Write-LdoLog -Level SUCCESS -Message "All $($results.PassedCount) tests passed."
}

Export-ModuleMember -Function `
    Test-LdoZeroExitCode, `
    Test-LdoCommandOutputMatch, `
    Register-LdoPesterAssertion, `
    Invoke-LdoPesterTest
