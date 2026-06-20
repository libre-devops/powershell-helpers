Set-StrictMode -Version Latest

function Invoke-LdoTerraformValidate {
    <#
    .SYNOPSIS
        Runs 'terraform validate' against a Terraform configuration folder.

    .DESCRIPTION
        Changes into the configuration folder, runs terraform validate, and throws when the
        command reports an error. The original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .EXAMPLE
        Invoke-LdoTerraformValidate -CodePath ./terraform

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
        Set-Location $CodePath
        Write-LdoLog -Level INFO -Message "Validating Terraform: $CodePath"
        Assert-LdoCommand -Name 'terraform'
        & terraform validate
        Assert-LdoLastExitCode -Operation 'terraform validate'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoTerraformFmtCheck {
    <#
    .SYNOPSIS
        Runs 'terraform fmt -check' against a Terraform configuration folder.

    .DESCRIPTION
        Changes into the configuration folder, runs terraform fmt -check, and throws when any
        file is not correctly formatted. The original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .EXAMPLE
        Invoke-LdoTerraformFmtCheck -CodePath ./terraform

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
        Set-Location $CodePath
        Write-LdoLog -Level INFO -Message "Checking Terraform formatting: $CodePath"
        Assert-LdoCommand -Name 'terraform'
        & terraform fmt -check -recursive
        Assert-LdoLastExitCode -Operation 'terraform fmt -check'
    }
    finally {
        Set-Location $orig
    }
}

function Get-LdoTerraformStackFolders {
    <#
    .SYNOPSIS
        Resolves an ordered list of Terraform stack folders to run.

    .DESCRIPTION
        Inspects the immediate child folders of a code root and builds a lookup keyed by stack
        name. Folders named like '01-network' are treated as numbered stacks with an execution
        order. Passing 'all' returns every numbered stack in numeric order, otherwise the named
        stacks are returned in the order requested.

    .PARAMETER CodeRoot
        Folder containing the stack subfolders.

    .PARAMETER StacksToRun
        One or more stack names, or the single value 'all'.

    .EXAMPLE
        Get-LdoTerraformStackFolders -CodeRoot ./stacks -StacksToRun all

    .EXAMPLE
        Get-LdoTerraformStackFolders -CodeRoot ./stacks -StacksToRun network,compute

    .OUTPUTS
        System.String. The resolved stack folder paths in execution order.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseSingularNouns', '', Justification = 'Returns multiple stack folders.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodeRoot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$StacksToRun
    )

    if (-not (Test-Path $CodeRoot)) {
        throw "Code root not found: $CodeRoot"
    }

    $allDirs = Get-ChildItem -Path $CodeRoot -Directory
    if (-not $allDirs) {
        throw "No stack folders found underneath $CodeRoot"
    }

    $stackLookup = @{ }
    foreach ($dir in $allDirs) {
        if ($dir.Name -match '^(?<order>\d+)[-_](?<name>.+)$') {
            $stackLookup[$matches.name.ToLower()] = @{
                Path = $dir.FullName
                Order = [int]$matches.order
                IsNumbered = $true
            }
        }
        elseif ($dir.Name -match '^allstackskip[-_](?<rest>.+)$') {
            $stackName = $matches.rest -replace '^\d+[-_]', ''
            $stackLookup[$stackName.ToLower()] = @{
                Path = $dir.FullName
                Order = 9999
                IsStackSkip = $true
                IsNumbered = $false
            }
        }
        else {
            $stackLookup[$dir.Name.ToLower()] = @{
                Path = $dir.FullName
                Order = 9999
                IsNumbered = $false
            }
        }
    }

    $requested = @(
        $StacksToRun |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )

    if ($requested -contains 'all' -and $requested.Count -gt 1) {
        Write-LdoLog -Level WARN -Message "'all' cannot be combined with explicit stack names; ignoring 'all' and using the named stacks only."
        $requested = $requested | Where-Object { $_.ToLower() -ne 'all' }
    }

    $result = [System.Collections.Generic.List[string]]::new()

    if (($requested.Count -eq 1) -and ($requested[0].ToLower() -eq 'all')) {
        Write-LdoLog -Level INFO -Message 'Running ALL stacks in numeric order.'
        $stackLookup.GetEnumerator() |
            Where-Object { $_.Value.IsNumbered -eq $true -and (-not ($_.Value.PSObject.Properties['IsStackSkip'] -and $_.Value.IsStackSkip)) } |
            Sort-Object { $_.Value.Order } |
            ForEach-Object { [void]$result.Add($_.Value.Path) }
    }
    else {
        foreach ($stack in $requested) {
            $key = $stack.ToLower()
            if (-not $stackLookup.ContainsKey($key)) {
                throw "Stack '$stack' not found under $CodeRoot"
            }
            [void]$result.Add($stackLookup[$key].Path)
        }
    }

    Write-LdoLog -Level DEBUG -Message "Stack execution order: $($result -join ', ')"
    return $result.ToArray()
}

function Invoke-LdoTerraformInit {
    <#
    .SYNOPSIS
        Runs 'terraform init', optionally computing a deterministic backend state key.

    .DESCRIPTION
        Runs terraform init in a configuration folder. When -CreateBackendKey is set and no
        backend key is already supplied in -InitArgs, a key of the form
        <repo>-<stack>[-<suffix>].tfstate is computed from the folder layout and appended as a
        -backend-config=key= argument. The original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER InitArgs
        Additional arguments passed through to terraform init.

    .PARAMETER CreateBackendKey
        When set, computes and appends a backend state key unless one is already present.

    .PARAMETER BackendKeyPrefix
        Overrides the auto-detected repository name used as the key prefix.

    .PARAMETER BackendKeySuffix
        Optional suffix appended to the computed backend key.

    .PARAMETER StackFolderName
        Optional fully resolved stack folder path used to compute the stack portion of the key.

    .EXAMPLE
        Invoke-LdoTerraformInit -CodePath ./stacks/01-network -CreateBackendKey

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string[]]$InitArgs = @(),
        [switch]$CreateBackendKey,
        [string]$BackendKeyPrefix,
        [string]$BackendKeySuffix,
        [string]$StackFolderName
    )

    $orig = Get-Location
    try {
        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }

        Set-Location $CodePath

        $backendKeyPassed = $InitArgs | Where-Object { $_ -match '^-backend-config=key=' }

        if ($CreateBackendKey -and (-not $backendKeyPassed)) {
            $codeItem = Get-Item $CodePath

            if ($BackendKeyPrefix) {
                $repoName = $BackendKeyPrefix.ToLower() -replace '\.', '-'
            }
            elseif ($codeItem.Parent -and $codeItem.Parent.Parent) {
                $repoName = $codeItem.Parent.Parent.Name.ToLower() -replace '\.', '-'
            }
            else {
                $repoName = $codeItem.Parent.Name.ToLower() -replace '\.', '-'
            }

            if ($StackFolderName) {
                $stackPath = (Resolve-Path $StackFolderName).ToString()
            }
            else {
                $stackPath = (Resolve-Path $CodePath).ToString()
            }

            if ($codeItem.Parent -and $codeItem.Parent.Parent) {
                $repoRoot = $codeItem.Parent.Parent.FullName
            }
            else {
                $repoRoot = $codeItem.Parent.FullName
            }

            if ($stackPath -like "$repoRoot*") {
                $stackRelative = $stackPath.Substring($repoRoot.Length)
            }
            else {
                $stackRelative = Split-Path -Path $stackPath -Leaf
            }

            $stackRelative = $stackRelative.TrimStart('\', '/')

            $stackNormalized = $stackRelative.ToLower() `
                -replace '[\\\/]+', '-' `
                -replace '[_\.]+', '-' `
                -replace '-{2,}', '-' `
                -replace '^-', ''

            $backendKey = "$repoName-$stackNormalized"
            if ($BackendKeySuffix) { $backendKey += "-$BackendKeySuffix" }
            $backendKey += '.tfstate'

            Write-LdoLog -Level DEBUG -Message "Computed backend key name: $backendKey"
            $InitArgs += "-backend-config=key=$backendKey"
        }

        Assert-LdoCommand -Name 'terraform'

        # Default to a non-interactive init for CI unless the caller already set -input.
        if (-not ($InitArgs | Where-Object { $_ -like '-input=*' })) {
            $InitArgs = @('-input=false') + $InitArgs
        }

        Write-LdoLog -Level INFO -Message "Running terraform init in: $CodePath"
        & terraform init @InitArgs
        Assert-LdoLastExitCode -Operation 'terraform init'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoTerraformWorkspaceSelect {
    <#
    .SYNOPSIS
        Selects a Terraform workspace, creating it if it does not exist.

    .DESCRIPTION
        Runs 'terraform workspace select -or-create=true' in a configuration folder and throws
        on failure. The original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER WorkspaceName
        Name of the workspace to select or create.

    .EXAMPLE
        Invoke-LdoTerraformWorkspaceSelect -CodePath ./terraform -WorkspaceName dev

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WorkspaceName
    )

    $orig = Get-Location
    try {
        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }

        Write-LdoLog -Level INFO -Message "Selecting workspace '$WorkspaceName' (auto-create) in $CodePath"
        Set-Location $CodePath
        Assert-LdoCommand -Name 'terraform'
        & terraform workspace select -or-create=true $WorkspaceName
        Assert-LdoLastExitCode -Operation 'terraform workspace select'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoTerraformPlan {
    <#
    .SYNOPSIS
        Runs 'terraform plan' and writes a binary plan file.

    .DESCRIPTION
        Runs terraform plan with -input=false and -out, then throws on failure. The original
        working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER PlanFile
        Output plan file name. Defaults to tfplan.plan.

    .PARAMETER PlanArgs
        Additional arguments passed through to terraform plan.

    .EXAMPLE
        Invoke-LdoTerraformPlan -CodePath ./terraform -PlanArgs '-var-file=dev.tfvars'

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$PlanFile = 'tfplan.plan',
        [string[]]$PlanArgs = @()
    )

    $orig = Get-Location
    try {
        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }

        Write-LdoLog -Level INFO -Message "terraform plan to $PlanFile"
        Set-Location $CodePath

        Assert-LdoCommand -Name 'terraform'
        $tfArgs = @('plan', '-input=false', '-out', $PlanFile) + $PlanArgs
        & terraform @tfArgs
        Assert-LdoLastExitCode -Operation 'terraform plan'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoTerraformPlanDestroy {
    <#
    .SYNOPSIS
        Runs 'terraform plan -destroy' and writes a binary plan file.

    .DESCRIPTION
        Runs terraform plan -destroy with -input=false and -out, then throws on failure. The
        original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER PlanFile
        Output plan file name. Defaults to tfplan.plan.destroy.

    .PARAMETER PlanArgs
        Additional arguments passed through to terraform plan.

    .EXAMPLE
        Invoke-LdoTerraformPlanDestroy -CodePath ./terraform

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$PlanFile = 'tfplan.plan.destroy',
        [string[]]$PlanArgs = @()
    )

    $orig = Get-Location
    try {
        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }

        Write-LdoLog -Level INFO -Message "terraform plan -destroy to $PlanFile"
        Set-Location $CodePath

        Assert-LdoCommand -Name 'terraform'
        $tfArgs = @('plan', '-destroy', '-input=false', '-out', $PlanFile) + $PlanArgs
        & terraform @tfArgs
        Assert-LdoLastExitCode -Operation 'terraform plan -destroy'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoTerraformApply {
    <#
    .SYNOPSIS
        Applies a saved Terraform plan file.

    .DESCRIPTION
        Runs terraform apply against a saved plan file, auto-approving unless -SkipApprove is
        set, and throws on failure. The original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER PlanFile
        Plan file to apply. Defaults to tfplan.plan.

    .PARAMETER SkipApprove
        When set, does not pass -auto-approve.

    .PARAMETER ApplyArgs
        Additional arguments passed through to terraform apply.

    .EXAMPLE
        Invoke-LdoTerraformApply -CodePath ./terraform -PlanFile tfplan.plan

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$PlanFile = 'tfplan.plan',
        [switch]$SkipApprove,
        [string[]]$ApplyArgs = @()
    )

    $orig = Get-Location
    try {
        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }

        Write-LdoLog -Level INFO -Message "terraform apply $PlanFile"
        Set-Location $CodePath

        $cmd = @('apply')
        if (-not $SkipApprove) {
            $cmd += '-auto-approve'
        }
        $cmd += @($PlanFile) + $ApplyArgs

        Assert-LdoCommand -Name 'terraform'
        & terraform @cmd
        Assert-LdoLastExitCode -Operation 'terraform apply'
    }
    finally {
        Set-Location $orig
    }
}

function Invoke-LdoTerraformDestroy {
    <#
    .SYNOPSIS
        Applies a saved Terraform destroy plan file.

    .DESCRIPTION
        Runs terraform apply against a saved destroy plan file, auto-approving unless
        -SkipApprove is set, and throws on failure. The original working directory is always
        restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER PlanFile
        Destroy plan file to apply. Defaults to tfplan-destroy.plan.

    .PARAMETER SkipApprove
        When set, does not pass -auto-approve.

    .PARAMETER DestroyArgs
        Additional arguments passed through to terraform apply.

    .EXAMPLE
        Invoke-LdoTerraformDestroy -CodePath ./terraform -PlanFile tfplan.plan.destroy

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$PlanFile = 'tfplan-destroy.plan',
        [switch]$SkipApprove,
        [string[]]$DestroyArgs = @()
    )

    $orig = Get-Location
    try {
        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }

        Write-LdoLog -Level INFO -Message "terraform apply (destroy) $PlanFile"
        Set-Location $CodePath

        $cmd = @('apply')
        if (-not $SkipApprove) {
            $cmd += '-auto-approve'
        }
        $cmd += @($PlanFile) + $DestroyArgs

        Assert-LdoCommand -Name 'terraform'
        & terraform @cmd
        Assert-LdoLastExitCode -Operation 'terraform apply (destroy)'
    }
    finally {
        Set-Location $orig
    }
}

function Convert-LdoTerraformPlanToJson {
    <#
    .SYNOPSIS
        Converts a binary Terraform plan file to JSON.

    .DESCRIPTION
        Runs 'terraform show -json' against a saved plan file and writes the output to a JSON
        file alongside it. Throws on failure. The original working directory is always restored.

    .PARAMETER CodePath
        Path to the Terraform configuration folder.

    .PARAMETER PlanFile
        Binary plan file to convert. Defaults to tfplan.plan.

    .PARAMETER JsonFile
        Output JSON file name. Defaults to <PlanFile>.json.

    .PARAMETER PassThru
        When set, returns the path to the JSON file.

    .EXAMPLE
        Convert-LdoTerraformPlanToJson -CodePath ./terraform -PassThru

    .OUTPUTS
        System.String. The JSON file path, when -PassThru is set.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CodePath,
        [string]$PlanFile = 'tfplan.plan',
        [string]$JsonFile,
        [switch]$PassThru
    )

    if (-not $JsonFile) {
        $JsonFile = "$PlanFile.json"
    }

    $orig = Get-Location
    try {
        if (-not (Test-Path $CodePath)) {
            throw "Terraform code not found: $CodePath"
        }
        $planPath = Join-Path $CodePath $PlanFile
        if (-not (Test-Path $planPath)) {
            throw "Plan file not found: $planPath"
        }

        Write-LdoLog -Level INFO -Message "Converting $PlanFile to $JsonFile"
        Set-Location $CodePath

        Assert-LdoCommand -Name 'terraform'
        $jsonPath = Join-Path $CodePath $JsonFile

        # Capture and verify success before writing so a failed 'terraform show' never
        # leaves a corrupt or empty JSON file behind.
        $json = & terraform show -json $PlanFile
        Assert-LdoLastExitCode -Operation 'terraform show -json'
        if (-not $json) {
            throw 'terraform show produced no JSON output.'
        }
        $json | Out-File -FilePath $jsonPath -Encoding utf8

        Write-LdoLog -Level SUCCESS -Message "JSON plan written to $jsonPath"

        if ($PassThru) {
            return $jsonPath
        }
    }
    finally {
        Set-Location $orig
    }
}

Export-ModuleMember -Function `
    Invoke-LdoTerraformValidate, `
    Invoke-LdoTerraformFmtCheck, `
    Get-LdoTerraformStackFolders, `
    Invoke-LdoTerraformInit, `
    Invoke-LdoTerraformWorkspaceSelect, `
    Invoke-LdoTerraformPlan, `
    Invoke-LdoTerraformPlanDestroy, `
    Invoke-LdoTerraformApply, `
    Invoke-LdoTerraformDestroy, `
    Convert-LdoTerraformPlanToJson
