param(
    [string]$PlanFile = "tfplan.plan",
    [string]$PlanExtraArgsJson = '[]',
    [string]$CodePath = (Get-Location).Path,

    [switch]$WhatIf,
    [switch]$DeleteGeneratedFiles
)

#───────────────────────────────────────────────────────────────────────────────
#  0.  Import helper modules
#───────────────────────────────────────────────────────────────────────────────
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$modules = @("Logger", "Terraform.AzureImport", "Terraform")
foreach ($m in $modules)
{
    $psm1 = "$scriptDir\LibreDevOpsHelpers.$m\LibreDevOpsHelpers.$m.psm1"
    if (-not (Test-Path -LiteralPath $psm1))
    {
        Write-Host "ERROR: [$( $MyInvocation.MyCommand.Name )] Module not found: $psm1" -ForegroundColor Red
        exit 1
    }
    Import-Module $psm1 -Force -ErrorAction Stop
}

#───────────────────────────────────────────────────────────────────────────────
#  1.  Prepare common variables
#───────────────────────────────────────────────────────────────────────────────
$extraArgsArray = ConvertFrom-Json $PlanExtraArgsJson
$PlanFileBase = [IO.Path]::GetFileNameWithoutExtension($PlanFile)
$JsonFile = "$PlanFile.json"

#───────────────────────────────────────────────────────────────────────────────
#  2.  terraform plan  →  JSON
#───────────────────────────────────────────────────────────────────────────────
try
{
    _LogMessage INFO "terraform plan → $PlanFile" -InvocationName $MyInvocation.MyCommand.Name
    Invoke-TerraformPlan -CodePath $CodePath -PlanArgs $extraArgsArray -PlanFile $PlanFile

    _LogMessage INFO "Converting plan → $JsonFile" -InvocationName $MyInvocation.MyCommand.Name
    Convert-TerraformPlanToJson -CodePath $CodePath -PlanFile $PlanFile
}
catch
{
    _LogMessage ERROR "Terraform plan/show failed: $_" -InvocationName $MyInvocation.MyCommand.Name
    throw
}

#───────────────────────────────────────────────────────────────────────────────
#  3.  Import helper (-WhatIf only if caller asked for it)
#───────────────────────────────────────────────────────────────────────────────
try
{
    _LogMessage INFO "Invoking import helper" -InvocationName $MyInvocation.MyCommand.Name

    $importParams = @{
        PlanJson = $JsonFile
        CodePath = $CodePath
    }
    if ($WhatIf)
    {
        $importParams.WhatIf = $true
    }

    Invoke-TerraformImportFromPlan @importParams
}
catch
{
    _LogMessage ERROR "Invoke-TerraformImportFromPlan failed: $_" -InvocationName $MyInvocation.MyCommand.Name
    throw
}
finally
{
    if ($DeleteGeneratedFiles)
    {
        foreach ($f in @(
            $PlanFile,
            $JsonFile,
            "import-map.csv",
            "${PlanFileBase}-destroy.tfplan",
            "${PlanFileBase}-destroy.tfplan.json"
        ))
        {
            if (Test-Path $f)
            {
                try
                {
                    Remove-Item $f -Force -ErrorAction Stop
                    _LogMessage DEBUG "Deleted $f" -InvocationName $MyInvocation.MyCommand.Name
                }
                catch
                {
                    _LogMessage WARN "Failed to delete $f – $( $_.Exception.Message )" `
                                    -InvocationName $MyInvocation.MyCommand.Name
                }
            }
        }
    }
}
