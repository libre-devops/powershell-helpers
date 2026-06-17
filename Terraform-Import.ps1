<#
.SYNOPSIS
    Plans Terraform, converts the plan to JSON, and imports existing Azure resources.

.DESCRIPTION
    Runs terraform plan, converts it to JSON, then resolves and imports existing Azure resources
    into state using the LibreDevOpsHelpers Terraform import helpers. Use -DryRun to log the
    import commands without executing them.

.PARAMETER PlanFile
    Binary plan file name. Defaults to tfplan.plan.

.PARAMETER PlanExtraArgsJson
    Additional terraform plan arguments as a JSON array string.

.PARAMETER CodePath
    Terraform configuration folder. Defaults to the current directory.

.PARAMETER DryRun
    When set, logs the terraform import commands without executing them.

.PARAMETER DeleteGeneratedFiles
    When set, removes the plan, JSON, and manifest files at the end.
#>
param(
    [string]$PlanFile = 'tfplan.plan',
    [string]$PlanExtraArgsJson = '[]',
    [string]$CodePath = (Get-Location).Path,
    [switch]$DryRun,
    [switch]$DeleteGeneratedFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$manifest = Join-Path $scriptDir 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    throw "Module manifest not found: $manifest"
}
Import-Module $manifest -Force -ErrorAction Stop

$extraArgsArray = [string[]](ConvertFrom-Json $PlanExtraArgsJson)
$planFileBase = [IO.Path]::GetFileNameWithoutExtension($PlanFile)
$jsonFile = "$PlanFile.json"

try {
    Write-LdoLog -Level INFO -Message "terraform plan to $PlanFile"
    Invoke-LdoTerraformPlan -CodePath $CodePath -PlanArgs $extraArgsArray -PlanFile $PlanFile

    Write-LdoLog -Level INFO -Message "Converting plan to $jsonFile"
    Convert-LdoTerraformPlanToJson -CodePath $CodePath -PlanFile $PlanFile
}
catch {
    Write-LdoLog -Level ERROR -Message "Terraform plan/show failed: $_"
    throw
}

try {
    Write-LdoLog -Level INFO -Message 'Invoking import helper.'

    $importParams = @{
        PlanJson = $jsonFile
        CodePath = $CodePath
    }
    if ($DryRun) {
        $importParams.DryRun = $true
    }

    Invoke-LdoTerraformImportFromPlan @importParams
}
catch {
    Write-LdoLog -Level ERROR -Message "Invoke-LdoTerraformImportFromPlan failed: $_"
    throw
}
finally {
    if ($DeleteGeneratedFiles) {
        foreach ($f in @(
                $PlanFile,
                $jsonFile,
                'import-map.csv',
                "$planFileBase-destroy.tfplan",
                "$planFileBase-destroy.tfplan.json"
            )) {
            if (Test-Path $f) {
                try {
                    Remove-Item $f -Force -ErrorAction Stop
                    Write-LdoLog -Level DEBUG -Message "Deleted $f"
                }
                catch {
                    Write-LdoLog -Level WARN -Message "Failed to delete $f : $($_.Exception.Message)"
                }
            }
        }
    }
}
