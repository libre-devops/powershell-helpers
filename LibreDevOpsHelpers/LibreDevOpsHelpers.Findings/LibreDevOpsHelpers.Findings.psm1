Set-StrictMode -Version Latest

# Module-scoped store of findings recorded during a run. Invoke-LdoTfLint / Invoke-LdoTrivy /
# Invoke-LdoConftest add to it; Show-LdoFindingsSummary prints them neatly at the end so the
# results are not lost in verbose structured logging.
$script:LdoFindings = [System.Collections.Generic.List[psobject]]::new()

function Add-LdoFinding {
    <#
    .SYNOPSIS
        Records a tool finding for the end-of-run summary.

    .PARAMETER Tool
        Name of the tool that produced the result (for example tflint, trivy, conftest).

    .PARAMETER Target
        What was checked (for example the stack folder or plan file).

    .PARAMETER Status
        PASS, WARN, or FAIL.

    .PARAMETER Summary
        Short one-line summary, for example "no findings" or "2 findings".

    .PARAMETER Detail
        The captured tool output to show under the summary.

    .EXAMPLE
        Add-LdoFinding -Tool trivy -Target ./examples/minimal -Status PASS -Summary 'no HIGH/CRITICAL'

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Tool,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [string]$Summary = '',
        [string]$Detail = ''
    )

    $script:LdoFindings.Add([pscustomobject]@{
            Tool    = $Tool
            Target  = $Target
            Status  = $Status
            Summary = $Summary
            Detail  = $Detail
        })
}

function Get-LdoFinding {
    <#
    .SYNOPSIS
        Returns the findings recorded so far.

    .EXAMPLE
        Get-LdoFinding

    .OUTPUTS
        System.Management.Automation.PSObject[]
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param()

    return $script:LdoFindings.ToArray()
}

function Clear-LdoFinding {
    <#
    .SYNOPSIS
        Clears the recorded findings (call at the start of a run).

    .EXAMPLE
        Clear-LdoFinding

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $script:LdoFindings.Clear()
}

function Show-LdoFindingsSummary {
    <#
    .SYNOPSIS
        Prints a neat summary of the recorded findings.

    .DESCRIPTION
        Writes a status table (one row per recorded finding) followed by the captured detail for
        any WARN or FAIL result, so scan/lint/policy findings are easy to read without scrolling
        through verbose logs. Uses Write-Host so it is readable whatever the log format. Does
        nothing when no findings were recorded.

    .PARAMETER Title
        Heading for the summary block. Defaults to 'FINDINGS SUMMARY'.

    .PARAMETER IncludeDetail
        Also print the captured detail for PASS results, not just WARN/FAIL.

    .EXAMPLE
        Show-LdoFindingsSummary

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Title = 'FINDINGS SUMMARY',
        [switch]$IncludeDetail
    )

    $findings = $script:LdoFindings
    if ($findings.Count -eq 0) {
        return
    }

    $colour = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    $width = 72
    $bar = '=' * $width

    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host (" {0}" -f $Title) -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan

    foreach ($f in $findings) {
        $line = "{0,-9} {1,-6} {2}" -f $f.Tool, $f.Status, $f.Target
        $fg = if ($colour.ContainsKey($f.Status)) { $colour[$f.Status] } else { 'Gray' }
        Write-Host $line -ForegroundColor $fg
        if ($f.Summary) {
            Write-Host ("          {0}" -f $f.Summary) -ForegroundColor DarkGray
        }
    }

    # Detail for anything that is not a clean pass (or everything, with -IncludeDetail).
    foreach ($f in $findings) {
        $showDetail = $f.Detail -and ($IncludeDetail -or $f.Status -ne 'PASS')
        if ($showDetail) {
            Write-Host ''
            Write-Host ("-- [{0}] {1} ({2}) " -f $f.Tool, $f.Target, $f.Status).PadRight($width, '-') -ForegroundColor Cyan
            foreach ($detailLine in ($f.Detail -split "`r?`n")) {
                Write-Host $detailLine
            }
        }
    }

    Write-Host $bar -ForegroundColor Cyan
    Write-Host ''
}

Export-ModuleMember -Function `
    Add-LdoFinding, `
    Get-LdoFinding, `
    Clear-LdoFinding, `
    Show-LdoFindingsSummary
