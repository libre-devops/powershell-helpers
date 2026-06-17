<#
.SYNOPSIS
    Formats Terraform, sorts variables and outputs, regenerates the README, and optionally tags a release.

.DESCRIPTION
    Uses the LibreDevOpsHelpers Terraform and TerraformDocs helpers to format code, alphabetise
    variable and output blocks, and regenerate the README with terraform-docs. Optionally commits
    and pushes a git tag.

.PARAMETER VariablesInFile
    Variables file to read. Defaults to ./variables.tf.

.PARAMETER VariablesOutFile
    Variables file to write. Defaults to ./variables.tf.

.PARAMETER OutputsInFile
    Outputs file to read. Defaults to ./outputs.tf.

.PARAMETER OutputsOutFile
    Outputs file to write. Defaults to ./outputs.tf.

.PARAMETER GitTag
    Git tag to create when -GitRelease is set. Defaults to 1.0.0.

.PARAMETER GitCommitMessage
    Commit message to use when -GitRelease is set.

.PARAMETER SortInputs
    Sort variable blocks. Defaults to true.

.PARAMETER SortOutputs
    Sort output blocks. Defaults to true.

.PARAMETER GitRelease
    Commit, push, and tag the repository. Defaults to false.

.PARAMETER FormatTerraform
    Run terraform fmt. Defaults to true.

.PARAMETER GenerateNewReadme
    Regenerate the README with terraform-docs. Defaults to true.
#>
param(
    [string]$VariablesInFile = './variables.tf',
    [string]$VariablesOutFile = './variables.tf',
    [string]$OutputsInFile = './outputs.tf',
    [string]$OutputsOutFile = './outputs.tf',
    [string]$GitTag = '1.0.0',
    [string]$GitCommitMessage = 'Update code',
    [bool]$SortInputs = $true,
    [bool]$SortOutputs = $true,
    [bool]$GitRelease = $false,
    [bool]$FormatTerraform = $true,
    [bool]$GenerateNewReadme = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$manifest = Join-Path $scriptDir 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "Module manifest not found: $manifest"
}
Import-Module $manifest -Force -ErrorAction Stop

function Invoke-GitRelease {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$CommitMessage
    )

    $gitPath = Get-Command git -ErrorAction Stop
    Write-LdoLog -Level INFO -Message "git found at: $($gitPath.Source)"

    git add --all
    if ($LASTEXITCODE -ne 0) { throw "git add failed (exit $LASTEXITCODE)." }
    git commit -m $CommitMessage
    if ($LASTEXITCODE -ne 0) { throw "git commit failed (exit $LASTEXITCODE)." }
    git push
    if ($LASTEXITCODE -ne 0) { throw "git push failed (exit $LASTEXITCODE)." }
    git tag $Tag --force
    if ($LASTEXITCODE -ne 0) { throw "git tag failed (exit $LASTEXITCODE)." }
    git push --tags --force
    if ($LASTEXITCODE -ne 0) { throw "git push --tags failed (exit $LASTEXITCODE)." }

    Write-LdoLog -Level SUCCESS -Message "Released tag $Tag."
}

if ($FormatTerraform) {
    Format-LdoTerraform -CodePath (Get-Location).Path
}

if ($SortInputs) {
    $variablesContent = Get-LdoTerraformFileContent -Filename $VariablesInFile
    if (-not [string]::IsNullOrWhiteSpace($variablesContent)) {
        $sorted = Format-LdoTerraformVariables -VariablesContent $variablesContent
        if (-not [string]::IsNullOrWhiteSpace($sorted)) {
            Set-LdoTerraformFileContent -Filename $VariablesOutFile -Content $sorted
            Write-LdoLog -Level SUCCESS -Message "Sorted Terraform variables written to $VariablesOutFile"
        }
    }
}

if ($SortOutputs) {
    $outputsContent = Get-LdoTerraformFileContent -Filename $OutputsInFile
    if (-not [string]::IsNullOrWhiteSpace($outputsContent)) {
        $sorted = Format-LdoTerraformOutputs -OutputsContent $outputsContent
        if (-not [string]::IsNullOrWhiteSpace($sorted)) {
            Set-LdoTerraformFileContent -Filename $OutputsOutFile -Content $sorted
            Write-LdoLog -Level SUCCESS -Message "Sorted Terraform outputs written to $OutputsOutFile"
        }
    }
}

if ($GenerateNewReadme) {
    Update-LdoReadmeWithTerraformDocs -CodePath (Get-Location).Path
}

if ($GitRelease) {
    Invoke-GitRelease -Tag $GitTag -CommitMessage $GitCommitMessage
}

Write-LdoLog -Level SUCCESS -Message 'Terraform release script completed.'
