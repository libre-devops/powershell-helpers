Set-StrictMode -Version Latest

function Format-LdoTerraform {
    <#
    .SYNOPSIS
        Runs 'terraform fmt -recursive' against a configuration folder.

    .DESCRIPTION
        Confirms terraform is on PATH, then formats all Terraform files beneath the folder.
        Throws on failure. The original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .EXAMPLE
        Format-LdoTerraform -CodePath ./terraform

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath
    )

    if (-not (Test-Path $CodePath)) {
        throw "Terraform code not found: $CodePath"
    }

    $orig = Get-Location
    try {
        Assert-LdoCommand -Name 'terraform'
        Set-Location $CodePath
        & terraform fmt -recursive
        Assert-LdoLastExitCode -Operation 'terraform fmt -recursive'
        Write-LdoLog -Level INFO -Message 'Terraform files formatted (fmt -recursive).'
    }
    finally {
        Set-Location $orig
    }
}

function Get-LdoTerraformFileContent {
    <#
    .SYNOPSIS
        Reads a Terraform file and returns its raw content.

    .DESCRIPTION
        Returns the full text of a file, throwing when the file does not exist.

    .PARAMETER Filename
        Path to the file to read.

    .EXAMPLE
        Get-LdoTerraformFileContent -Filename ./variables.tf

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Filename)

    if (-not (Test-Path $Filename)) {
        throw "File not found: $Filename"
    }
    return Get-Content -Raw -LiteralPath $Filename
}

function Set-LdoTerraformFileContent {
    <#
    .SYNOPSIS
        Writes content to a Terraform file.

    .DESCRIPTION
        Overwrites the named file with the supplied content.

    .PARAMETER Filename
        Path to the file to write.

    .PARAMETER Content
        Text content to write.

    .EXAMPLE
        Set-LdoTerraformFileContent -Filename ./variables.tf -Content $text

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Filename,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $Content | Set-Content -LiteralPath $Filename -Encoding utf8
}

function Format-LdoTerraformVariables {
    <#
    .SYNOPSIS
        Sorts variable blocks in variables.tf content alphabetically.

    .DESCRIPTION
        Parses variable "name" { ... } blocks from the supplied content and returns them sorted
        by variable name, separated by blank lines.

    .PARAMETER VariablesContent
        Raw content of a variables.tf file.

    .EXAMPLE
        Format-LdoTerraformVariables -VariablesContent (Get-Content ./variables.tf -Raw)

    .OUTPUTS
        System.String
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Operates on Terraform variable blocks.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VariablesContent)

    $pattern = 'variable\s+"[^"]+"\s+\{[\s\S]*?\n\}'
    $blocks = [regex]::Matches($VariablesContent, $pattern) | ForEach-Object { $_.Value }
    $sorted = $blocks | Sort-Object { ([regex]::Match($_, 'variable\s+"([^"]+)"')).Groups[1].Value }
    return ($sorted -join "`n`n")
}

function Format-LdoTerraformOutputs {
    <#
    .SYNOPSIS
        Sorts output blocks in outputs.tf content alphabetically.

    .DESCRIPTION
        Parses output "name" { ... } blocks from the supplied content and returns them sorted by
        output name, separated by blank lines.

    .PARAMETER OutputsContent
        Raw content of an outputs.tf file.

    .EXAMPLE
        Format-LdoTerraformOutputs -OutputsContent (Get-Content ./outputs.tf -Raw)

    .OUTPUTS
        System.String
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Operates on Terraform output blocks.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputsContent)

    $pattern = 'output\s+"[^"]+"\s+\{[\s\S]*?\n\}'
    $blocks = [regex]::Matches($OutputsContent, $pattern) | ForEach-Object { $_.Value }
    $sorted = $blocks | Sort-Object { ([regex]::Match($_, 'output\s+"([^"]+)"')).Groups[1].Value }
    return ($sorted -join "`n`n")
}

function Format-LdoTerraformCode {
    <#
    .SYNOPSIS
        Formats Terraform code and alphabetises variables.tf and outputs.tf.

    .DESCRIPTION
        Runs terraform fmt -recursive, then sorts the variable and output blocks in the named
        files (when present and non-empty) so the declarations are kept in a consistent order.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER VariablesFile
        Variables file name within the folder. Defaults to variables.tf.

    .PARAMETER OutputsFile
        Outputs file name within the folder. Defaults to outputs.tf.

    .EXAMPLE
        Format-LdoTerraformCode -CodePath ./terraform

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$VariablesFile = 'variables.tf',
        [string]$OutputsFile = 'outputs.tf'
    )

    Format-LdoTerraform -CodePath $CodePath

    $varPath = Join-Path $CodePath $VariablesFile
    if (Test-Path $varPath) {
        $varsContent = Get-LdoTerraformFileContent -Filename $varPath
        if (-not [string]::IsNullOrWhiteSpace($varsContent)) {
            $sortedVars = Format-LdoTerraformVariables -VariablesContent $varsContent
            if (-not [string]::IsNullOrWhiteSpace($sortedVars)) {
                Set-LdoTerraformFileContent -Filename $varPath -Content $sortedVars
                Write-LdoLog -Level INFO -Message "Sorted variables in $varPath"
            }
            else {
                Write-LdoLog -Level INFO -Message "No variable blocks found to sort in $varPath; skipping write."
            }
        }
        else {
            Write-LdoLog -Level INFO -Message "File $varPath is empty; skipping variable sort."
        }
    }

    $outPath = Join-Path $CodePath $OutputsFile
    if (Test-Path $outPath) {
        $outContent = Get-LdoTerraformFileContent -Filename $outPath
        if (-not [string]::IsNullOrWhiteSpace($outContent)) {
            $sortedOut = Format-LdoTerraformOutputs -OutputsContent $outContent
            if (-not [string]::IsNullOrWhiteSpace($sortedOut)) {
                Set-LdoTerraformFileContent -Filename $outPath -Content $sortedOut
                Write-LdoLog -Level INFO -Message "Sorted outputs in $outPath"
            }
            else {
                Write-LdoLog -Level INFO -Message "No output blocks found to sort in $outPath; skipping write."
            }
        }
        else {
            Write-LdoLog -Level INFO -Message "File $outPath is empty; skipping output sort."
        }
    }
}

function Update-LdoReadmeWithTerraformDocs {
    <#
    .SYNOPSIS
        Regenerates README.md for a Terraform folder using terraform-docs.

    .DESCRIPTION
        Writes the chosen build file (build.tf or main.tf) into a fenced HCL block at the top of
        the README, then appends the terraform-docs markdown table. Skips silently when
        terraform-docs is not installed or no build file is present. The original working
        directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER ReadmeFile
        README file name within the folder. Defaults to README.md.

    .EXAMPLE
        Update-LdoReadmeWithTerraformDocs -CodePath ./terraform

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'terraform-docs is a tool name.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$ReadmeFile = 'README.md'
    )

    $orig = Get-Location
    try {
        try {
            $td = Get-Command terraform-docs -ErrorAction Stop
            Write-LdoLog -Level INFO -Message "terraform-docs found at '$($td.Source)'"
        }
        catch {
            Write-LdoLog -Level WARN -Message 'terraform-docs not installed; README generation skipped.'
            return
        }

        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }
        Set-Location $CodePath

        $build = @('build.tf', 'main.tf') | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $build) {
            Write-LdoLog -Level WARN -Message 'No build.tf or main.tf found; README not updated.'
            return
        }

        Write-LdoLog -Level INFO -Message "Generating $ReadmeFile from $build and terraform-docs."

        # Generate and verify terraform-docs succeeded before writing, so a failure never
        # leaves a half-written README behind.
        $docs = terraform-docs markdown .
        Assert-LdoLastExitCode -Operation 'terraform-docs markdown'

        $readmeLines = @('```hcl') + (Get-Content -LiteralPath $build) + @('```') + $docs
        $readmeLines | Set-Content -LiteralPath $ReadmeFile -Encoding utf8

        Write-LdoLog -Level SUCCESS -Message "Updated $ReadmeFile."
    }
    finally {
        Set-Location $orig
    }
}

Export-ModuleMember -Function `
    Format-LdoTerraform, `
    Format-LdoTerraformCode, `
    Get-LdoTerraformFileContent, `
    Set-LdoTerraformFileContent, `
    Format-LdoTerraformVariables, `
    Format-LdoTerraformOutputs, `
    Update-LdoReadmeWithTerraformDocs
