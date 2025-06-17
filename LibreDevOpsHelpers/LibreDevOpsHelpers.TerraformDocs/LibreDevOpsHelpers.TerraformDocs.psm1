<#  ───────────────────────── TerraformDocs.psm1 ─────────────────────────── #>

function Format-Terraform
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodePath
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location
    try
    {
        $tf = Get-Command terraform -ErrorAction Stop
        _LogMessage -Level INFO  -Message "terraform found at '$( $tf.Source )'" -InvocationName $inv
        Set-Location $CodePath
        & terraform fmt -recursive
        if ($LASTEXITCODE)
        {
            throw "terraform fmt returned exit code $LASTEXITCODE"
        }
        _LogMessage -Level INFO  -Message 'Terraform files formatted (fmt -recursive).' -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $inv
        throw
    }
    finally
    {
        Set-Location $orig
    }
}

#############################################################################
# Helper – format all *.tf files under the current dir (terraform fmt -recursive)
#############################################################################
function Format-TerraformCode
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodePath,
        [string]$VariablesFile = 'variables.tf',
        [string]$OutputsFile = 'outputs.tf'
    )

    $inv = $MyInvocation.MyCommand.Name

    # ── step 1: terraform fmt ───────────────────────────────────────────
    Format-Terraform -CodePath $CodePath

    # ── step 2: sort variables.tf ───────────────────────────────────────
    $varPath = Join-Path $CodePath $VariablesFile
    if (Test-Path $varPath)
    {
        $varsContent = Read-TerraformFile -Filename $varPath
        if (-not [string]::IsNullOrWhiteSpace($varsContent))
        {
            $sortedVars = Format-TerraformVariables -VariablesContent $varsContent
            if (-not [string]::IsNullOrWhiteSpace($sortedVars))
            {
                Write-TerraformFile -Filename $varPath -Content $sortedVars
                _LogMessage -Level INFO -Message "Sorted variables in $varPath" -InvocationName $inv
            }
            else
            {
                _LogMessage -Level INFO -Message "No variable blocks found to sort in $varPath, skipping write." -InvocationName $inv
            }
        }
        else
        {
            _LogMessage -Level INFO -Message "File $varPath is empty, skipping variable sort." -InvocationName $inv
        }
    }

    # ── step 3: sort outputs.tf ─────────────────────────────────────────
    $outPath = Join-Path $CodePath $OutputsFile
    if (Test-Path $outPath)
    {
        $outContent = Read-TerraformFile -Filename $outPath
        if (-not [string]::IsNullOrWhiteSpace($outContent))
        {
            $sortedOut = Format-TerraformOutputs -OutputsContent $outContent
            if (-not [string]::IsNullOrWhiteSpace($sortedOut))
            {
                Write-TerraformFile -Filename $outPath -Content $sortedOut
                _LogMessage -Level INFO -Message "Sorted outputs in $outPath" -InvocationName $inv
            }
            else
            {
                _LogMessage -Level INFO -Message "No output blocks found to sort in $outPath, skipping write." -InvocationName $inv
            }
        }
        else
        {
            _LogMessage -Level INFO -Message "File $outPath is empty, skipping output sort." -InvocationName $inv
        }
    }
}




#############################################################################
# Safe file-read
#############################################################################
function Read-TerraformFile
{
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Filename)

    if (-not (Test-Path $Filename))
    {
        _LogMessage -Level ERROR -Message "File not found: $Filename" -InvocationName $MyInvocation.MyCommand.Name
        throw "File not found: $Filename"
    }
    try
    {
        return Get-Content -Raw -LiteralPath $Filename
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $MyInvocation.MyCommand.Name; throw
    }
}

#############################################################################
# Safe file-write
#############################################################################
function Write-TerraformFile
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][string]$Content
    )
    try
    {
        $Content | Set-Content -LiteralPath $Filename
    }
    catch
    {
        _LogMessage -Level ERROR -Message $_.Exception.Message -InvocationName $MyInvocation.MyCommand.Name; throw
    }
}

#############################################################################
# Sort variables.tf blocks alphabetically by variable name
#############################################################################
function Format-TerraformVariables
{
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VariablesContent)

    $pattern = 'variable\s+"[^"]+"\s+\{[\s\S]*?\n\}'
    $blocks = [regex]::Matches($VariablesContent, $pattern) | ForEach-Object { $_.Value }
    $sorted = $blocks |
            Sort-Object { ([regex]::Match($_, 'variable\s+"([^"]+)"')).Groups[1].Value }
    return ($sorted -join "`n`n")
}

#############################################################################
# Sort outputs.tf blocks alphabetically by output name
#############################################################################
function Format-TerraformOutputs
{
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputsContent)

    $pattern = 'output\s+"[^"]+"\s+\{[\s\S]*?\n\}'
    $blocks = [regex]::Matches($OutputsContent, $pattern) | ForEach-Object { $_.Value }
    $sorted = $blocks |
            Sort-Object { ([regex]::Match($_, 'output\s+"([^"]+)"')).Groups[1].Value }
    return ($sorted -join "`n`n")
}

#############################################################################
# Generate / refresh README.md using terraform-docs
#############################################################################
function Update-ReadmeWithTerraformDocs
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodePath,
        [string]$ReadmeFile = 'README.md'
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location
    try
    {
        $td = Get-Command terraform-docs -ErrorAction Stop
        _LogMessage -Level INFO -Message "terraform-docs found at '$( $td.Source )'" -InvocationName $inv
    }
    catch
    {
        _LogMessage -Level WARN -Message 'terraform-docs not installed – README generation skipped.' -InvocationName $inv
        return
    }

    Set-Location $CodePath

    # choose build file
    $build = @('build.tf', 'main.tf') | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $build)
    {
        _LogMessage -Level WARN -Message 'No build.tf or main.tf found – README not updated.' -InvocationName $inv
        return
    }

    _LogMessage -Level INFO -Message "Generating README.md from $build and terraform-docs…" -InvocationName $inv

    '```hcl'                | Set-Content  $ReadmeFile
    Get-Content $build      | Add-Content  $ReadmeFile
    '```'                   | Add-Content  $ReadmeFile
    terraform-docs markdown . | Add-Content $ReadmeFile
}
#############################################################################
# Export
#############################################################################
Export-ModuleMember -Function `
    Format-Terraform, `
      Format-TerraformCode, `
      Read-TerraformFile, `
      Write-TerraformFile, `
      Format-TerraformVariables, `
      Format-TerraformOutputs, `
      Update-ReadmeWithTerraformDocs
