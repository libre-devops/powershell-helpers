Set-StrictMode -Version Latest

function Invoke-LdoPackerInit {
    <#
    .SYNOPSIS
        Runs 'packer init' against a template.

    .DESCRIPTION
        Initialises a Packer template, downloading required plugins. Throws on failure.

    .PARAMETER TemplatePath
        Path to the Packer template file or folder.

    .EXAMPLE
        Invoke-LdoPackerInit -TemplatePath ./image.pkr.hcl

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TemplatePath)

    if (-not (Test-Path $TemplatePath)) {
        throw "Packer template file not found: $TemplatePath"
    }

    Write-LdoLog -Level INFO -Message "Initializing Packer template: $TemplatePath"
    & packer init $TemplatePath
    Assert-LdoLastExitCode -Operation 'packer init'
}

function Invoke-LdoPackerValidate {
    <#
    .SYNOPSIS
        Runs 'packer validate' against a template.

    .DESCRIPTION
        Validates a Packer template. Throws on failure.

    .PARAMETER TemplatePath
        Path to the Packer template file or folder.

    .EXAMPLE
        Invoke-LdoPackerValidate -TemplatePath ./image.pkr.hcl

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TemplatePath)

    if (-not (Test-Path $TemplatePath)) {
        throw "Packer template file not found: $TemplatePath"
    }

    Write-LdoLog -Level INFO -Message "Validating Packer template: $TemplatePath"
    & packer validate $TemplatePath
    Assert-LdoLastExitCode -Operation 'packer validate'
}

function Invoke-LdoPackerBuild {
    <#
    .SYNOPSIS
        Runs 'packer build' against a template.

    .DESCRIPTION
        Builds an image from a Packer template. Throws on failure.

    .PARAMETER TemplatePath
        Path to the Packer template file or folder.

    .EXAMPLE
        Invoke-LdoPackerBuild -TemplatePath ./image.pkr.hcl

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TemplatePath)

    if (-not (Test-Path $TemplatePath)) {
        throw "Packer template file not found: $TemplatePath"
    }

    Write-LdoLog -Level INFO -Message "Building image with Packer template: $TemplatePath"
    & packer build $TemplatePath
    Assert-LdoLastExitCode -Operation 'packer build'
}

function Invoke-LdoPackerWorkflow {
    <#
    .SYNOPSIS
        Runs the full Packer init, validate, and build workflow.

    .DESCRIPTION
        Runs packer init, then validate, then build against a template, stopping and throwing at
        the first failing step.

    .PARAMETER TemplatePath
        Path to the Packer template file or folder.

    .EXAMPLE
        Invoke-LdoPackerWorkflow -TemplatePath ./image.pkr.hcl

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TemplatePath)

    Write-LdoLog -Level INFO -Message 'Starting Packer workflow.'
    Invoke-LdoPackerInit -TemplatePath $TemplatePath
    Invoke-LdoPackerValidate -TemplatePath $TemplatePath
    Invoke-LdoPackerBuild -TemplatePath $TemplatePath
    Write-LdoLog -Level SUCCESS -Message 'Packer workflow completed successfully.'
}

Export-ModuleMember -Function `
    Invoke-LdoPackerInit, `
    Invoke-LdoPackerValidate, `
    Invoke-LdoPackerBuild, `
    Invoke-LdoPackerWorkflow
