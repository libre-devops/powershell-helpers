###############################################################################
# Assertion helper – “Should ReturnZeroExitCode”
###############################################################################
function ShouldReturnZeroExitCode {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $ActualValue,
        [switch] $Negate,
        [string]  $Because   # kept for Pester signature parity
    )

    $inv = $MyInvocation.MyCommand.Name
    _LogMessage -Level 'DEBUG' -Message "Checking exit-code for: $ActualValue" -InvocationName $inv

    try {
        $result = Get-CommandResult -Command $ActualValue -ValidateExitCode:$false
        $succeeded = ($result.ExitCode -eq 0)
        if ($Negate) { $succeeded = -not $succeeded }

        if (-not $succeeded) {
            $indented = $result.Output | ForEach-Object { "    $_" } | Out-String
            $failureMessage = "Command '`"$ActualValue`"' returned exit-code $($result.ExitCode). Output:`n$indented"
        }
    }
    catch {
        _LogMessage -Level 'ERROR' -Message $_.Exception.Message -InvocationName $inv
        $succeeded       = $false
        $failureMessage  = "Exception thrown while executing '$ActualValue' – $($_.Exception.Message)"
    }

    [PSCustomObject]@{
        Succeeded      = $succeeded
        FailureMessage = $failureMessage
    }
}

###############################################################################
# Assertion helper – “Should MatchCommandOutput”
###############################################################################
function ShouldMatchCommandOutput {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $ActualValue,
        [Parameter(Mandatory)][string] $RegularExpression,
        [switch] $Negate
    )

    $inv = $MyInvocation.MyCommand.Name
    _LogMessage -Level 'DEBUG' -Message "Matching output for: $ActualValue  (regex = $RegularExpression)" -InvocationName $inv

    try {
        $output    = (Get-CommandResult -Command $ActualValue -ValidateExitCode:$false).Output -join "`n"
        $succeeded = ($output -cmatch $RegularExpression)
        if ($Negate) { $succeeded = -not $succeeded }

        if (-not $succeeded) {
            $notText   = if ($Negate) { 'not ' } else { '' }
            $failureMessage = "Expected '`"$ActualValue`"' output to ${notText}match regex '`"$RegularExpression`"', but it did${notText}."
        }
    }
    catch {
        _LogMessage -Level 'ERROR' -Message $_.Exception.Message -InvocationName $inv
        $succeeded       = $false
        $failureMessage  = "Exception thrown while executing '$ActualValue' – $($_.Exception.Message)"
    }

    [PSCustomObject]@{
        Succeeded      = $succeeded
        FailureMessage = $failureMessage
    }
}

###############################################################################
# Register the helpers as custom Pester operators (if Pester is loaded)
###############################################################################
if (Get-Command -Name Add-ShouldOperator -ErrorAction SilentlyContinue) {
    Add-ShouldOperator -Name ReturnZeroExitCode  -InternalName ShouldReturnZeroExitCode  -Test ${function:ShouldReturnZeroExitCode}
    Add-ShouldOperator -Name MatchCommandOutput  -InternalName ShouldMatchCommandOutput  -Test ${function:ShouldMatchCommandOutput}
    _LogMessage -Level 'DEBUG' -Message 'Custom Pester assertion operators registered.' -InvocationName 'ModuleInit'
}

###############################################################################
# Helper – run a single Pester file (mirrors your logging / error style)
###############################################################################
function Invoke-PesterTests {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string] $TestFile,   # without *.Tests.ps1
        [string] $TestName
    )

    $inv       = $MyInvocation.MyCommand.Name
    $testPath  = Join-Path -Path (Join-Path $PSScriptRoot '..\Tests') -ChildPath "${TestFile}.Tests.ps1"

    if (-not (Test-Path $testPath)) {
        $msg = "Unable to find test file '$TestFile' at '$testPath'."
        _LogMessage -Level 'ERROR' -Message $msg -InvocationName $inv
        throw $msg
    }

    _LogMessage -Level 'INFO' -Message "Running Pester tests in $testPath" -InvocationName $inv

    if (-not (Get-Module Pester)) { Import-Module Pester }

    $configuration = [PesterConfiguration]@{
        Run    = @{ Path = $testPath; PassThru = $true }
        Output = @{ Verbosity = 'Normal' }
    }
    if ($TestName) { $config.Filter.FullName = $TestName }

    # Fail hard on silent errors inside the tests
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    $results = Invoke-Pester -Configuration $config
    $ErrorActionPreference = $oldPref

    if (-not ($results.FailedCount -eq 0 -and $results.TotalCount -gt 0)) {
        _LogMessage -Level 'ERROR' -Message 'One or more tests failed.' -InvocationName $inv
        $results | Format-List | Out-String | _LogMessage -Level 'DEBUG' -InvocationName $inv
        throw 'Test run has failed.'
    }

    _LogMessage -Level 'INFO' -Message "All $($results.PassedCount) tests passed." -InvocationName $inv
}

###############################################################################
# Public surface
###############################################################################
Export-ModuleMember -Function `
    ShouldReturnZeroExitCode, `
    ShouldMatchCommandOutput, `
    Invoke-PesterTests
