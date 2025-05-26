# Run 'terraform validate'
function Invoke-TerraformValidate
{
    param (
        [string]$CodePath
    )

    if (-not (Test-Path $CodePath))
    {
        _LogMessage -Level "ERROR" -Message "Terraform code not found: $TemplatePath" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        throw "Terraform code not found: $CodePath"
    }

    _LogMessage -Level "INFO" -Message "Validating Terraform: $CodePath" -InvocationName "$( $MyInvocation.MyCommand.Name )"
    Set-Location $CodePath
    & terraform validate
}

# Run 'terraform validate'
function Invoke-TerraformFmtCheck
{
    param (
        [string]$CodePath
    )

    if (-not (Test-Path $CodePath))
    {
        _LogMessage -Level "ERROR" -Message "Terraform code not found: $TemplatePath" -InvocationName "$( $MyInvocation.MyCommand.Name )"
        throw "Terraform code not found: $CodePath"
    }

    _LogMessage -Level "INFO" -Message "Validating Terraform: $CodePath" -InvocationName "$( $MyInvocation.MyCommand.Name )"
    Set-Location $CodePath
    & terraform fmt -check
}

function Get-TerraformStackFolders
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]  $CodeRoot,

        [Parameter(Mandatory)]
        [string[]]$StacksToRun
    )

    if (-not (Test-Path $CodeRoot))
    {
        _LogMessage -Level 'ERROR' -Message "Code root not found: $CodeRoot" `
                    -InvocationName $MyInvocation.MyCommand.Name
        throw "Code root not found: $CodeRoot"
    }

    $allDirs = Get-ChildItem -Path $CodeRoot -Directory

    if (-not $allDirs)
    {
        _LogMessage -Level 'ERROR' -Message "No stack folders found underneath $CodeRoot" `
                    -InvocationName $MyInvocation.MyCommand.Name
        throw "No stack folders found underneath $CodeRoot"
    }

    $stackLookup = @{ }
    foreach ($dir in $allDirs)
    {
        if ($dir.Name -match '^(?<order>\d+)[-_](?<name>.+)$')
        {
            $stackLookup[$matches.name.ToLower()] = @{
                Path = $dir.FullName
                Order = [int]$matches.order
                IsNumbered = $true
            }
        }
        elseif ($dir.Name -match '^allstackskip[-_](?<rest>.+)$')
        {
            $stackName = $matches.rest -replace '^\d+[-_]', ''
            $stackLookup[$stackName.ToLower()] = @{
                Path = $dir.FullName
                Order = 9999
                IsStackSkip = $true
                IsNumbered = $false
            }
        }
        else
        {
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
            Where-Object  { $_ }
    )

    if ($requested -contains 'all' -and $requested.Count -gt 1)
    {
        _LogMessage -Level 'WARN' `
            -Message "'all' cannot be combined with explicit stack names – ignoring 'all' and using the named stacks only." `
            -InvocationName $MyInvocation.MyCommand.Name

        $requested = $requested | Where-Object { $_.ToLower() -ne 'all' }
    }

    $result = [System.Collections.Generic.List[string]]::new()

    if (($requested.Count -eq 1) -and ($requested[0].ToLower() -eq 'all'))
    {
        _LogMessage -Level 'INFO' -Message 'Running ALL stacks (numeric order)' `
                    -InvocationName $MyInvocation.MyCommand.Name

        $stackLookup.GetEnumerator() |
                Where-Object { $_.Value.IsNumbered -eq $true -and (-not ($_.Value.PSObject.Properties['IsStackSkip'] -and $_.Value.IsStackSkip)) } |
                Sort-Object { $_.Value.Order } |
                ForEach-Object { [void]$result.Add($_.Value.Path) }
    }
    else
    {
        foreach ($stack in $requested)
        {
            $key = $stack.ToLower()
            if (-not $stackLookup.ContainsKey($key))
            {
                _LogMessage -Level 'ERROR' -Message "Stack '$stack' not found under $CodeRoot" `
                            -InvocationName $MyInvocation.MyCommand.Name
                throw "Stack '$stack' not found under $CodeRoot"
            }
            [void]$result.Add($stackLookup[$key].Path)
        }
    }

    _LogMessage -Level 'DEBUG' `
        -Message "Stack execution order → $( $result -join ', ' )" `
        -InvocationName $MyInvocation.MyCommand.Name

    return $result
}



###############################################################################
# Run `terraform init`
###############################################################################
function Invoke-TerraformInit
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodePath,
        [string[]]$InitArgs = @(),
        [bool]$CreateBackendKey = $false,
        [string]$BackendKeyPrefix = $null,
        [string]$BackendKeySuffix = $null,
        [string]$StackFolderName = $null
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location

    try
    {
        if (-not (Test-Path $CodePath))
        {
            _LogMessage -Level 'ERROR' -Message "Terraform code not found: $CodePath" -InvocationName $inv
            throw "Terraform code not found: $CodePath"
        }

        Set-Location $CodePath

        # Determine if a backend key is already specified in InitArgs
        $backendKeyPassed = $InitArgs | Where-Object { $_ -match '^-backend-config=key=' }

        if ($CreateBackendKey -and (-not $backendKeyPassed))
        {
            # Auto-generate backend key
            if ($StackFolderName)
            {
                $folderName = Split-Path -Path $StackFolderName -Leaf
            }
            else
            {
                # Default to the last folder in CodePath if StackFolderName not provided
                $folderName = Split-Path -Path $CodePath -Leaf
            }

            $backendKey = ""
            if ($BackendKeyPrefix)
            {
                $backendKey += "$BackendKeyPrefix-"
            }
            $backendKey += ($folderName -replace '_', '-')
            if ($BackendKeySuffix)
            {
                $backendKey += "-$BackendKeySuffix"
            }
            $backendKey += ".terraform.tfstate"

            _LogMessage -Level 'DEBUG' -Message "Computed backend key name: $backendKey" -InvocationName $inv

            $InitArgs += "-backend-config=key=$backendKey"
        }

        _LogMessage -Level 'INFO' -Message "Running *terraform init ${InitArgs}* in: $CodePath" -InvocationName $inv

        & terraform init @InitArgs
        $code = $LASTEXITCODE
        _LogMessage -Level 'DEBUG' -Message "terraform init exit-code: $code" -InvocationName $inv

        if ($code -ne 0)
        {
            throw "terraform init failed (exit $code)."
        }
    }
    catch
    {
        _LogMessage -Level 'ERROR' -Message $_.Exception.Message -InvocationName $inv
        throw
    }
    finally
    {
        Set-Location $orig
    }
}


###############################################################################
# Run `terraform workspace select -or-create=true <name>`
###############################################################################
function Invoke-TerraformWorkspaceSelect
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CodePath,
        [Parameter(Mandatory)][string]$WorkspaceName
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location

    try
    {
        if (-not (Test-Path $CodePath))
        {
            _LogMessage -Level 'ERROR' -Message "Terraform code not found: $CodePath" -InvocationName $inv
            throw "Terraform code not found: $CodePath"
        }

        _LogMessage -Level 'INFO' -Message "Selecting workspace '$WorkspaceName' (auto-create) in $CodePath" -InvocationName $inv
        Set-Location $CodePath

        & terraform workspace select -or-create=true $WorkspaceName
        $code = $LASTEXITCODE
        _LogMessage -Level 'DEBUG' -Message "terraform workspace select exit-code: $code" -InvocationName $inv

        if ($code -ne 0)
        {
            throw "workspace selection failed (exit $code)."
        }
    }
    catch
    {
        _LogMessage -Level 'ERROR' -Message $_.Exception.Message -InvocationName $inv
        throw
    }
    finally
    {
        Set-Location $orig
    }
}

function Invoke-TerraformPlan
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CodePath,
        [string]  $PlanFile = 'tfplan.plan',
        [string[]]$PlanArgs = @()
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location
    try
    {
        if (-not (Test-Path $CodePath))
        {
            throw "Terraform code not found: $CodePath"
        }

        _LogMessage -Level 'INFO' -Message "terraform plan → $PlanFile" -InvocationName $inv
        Set-Location $CodePath

        $tfArgs = @('plan', '-input=false', '-out', $PlanFile) + $PlanArgs
        & terraform @tfArgs
        if ($LASTEXITCODE)
        {
            throw "terraform plan failed ($LASTEXITCODE)"
        }
    }
    finally
    {
        Set-Location $orig
    }
}

function Invoke-TerraformPlanDestroy
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CodePath,
        [string]  $PlanFile = 'tfplan.plan.destroy',
        [string[]]$PlanArgs = @()
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location
    try
    {
        if (-not (Test-Path $CodePath))
        {
            throw "Terraform code not found: $CodePath"
        }

        _LogMessage -Level 'INFO' -Message "terraform plan -destroy → $PlanFile" -InvocationName $inv
        Set-Location $CodePath

        $tfArgs = @('plan', '-destroy', '-input=false', '-out', $PlanFile) + $PlanArgs
        & terraform @tfArgs
        if ($LASTEXITCODE)
        {
            throw "terraform plan -destroy failed ($LASTEXITCODE)"
        }
    }
    finally
    {
        Set-Location $orig
    }
}

function Invoke-TerraformApply
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CodePath,
        $PlanFile = "tfplan.plan",
        [switch] $SkipApprove,
        [string[]]$ApplyArgs = @()
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location
    try
    {
        if (-not (Test-Path $CodePath))
        {
            throw "Terraform code not found: $CodePath"
        }

        _LogMessage -Level 'INFO' -Message "terraform apply ‹$PlanFile›" -InvocationName $inv
        Set-Location $CodePath

        $cmd = @('apply')
        if (-not $SkipApprove)
        {
            $cmd += '-auto-approve'
        }
        $cmd += @($PlanFile) + $ApplyArgs

        & terraform @cmd
        if ($LASTEXITCODE)
        {
            throw "terraform apply failed ($LASTEXITCODE)"
        }
    }
    finally
    {
        Set-Location $orig
    }
}

function Invoke-TerraformDestroy
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CodePath,
        $PlanFile = "tfplan-destroy.plan",
        [switch] $SkipApprove,
        [string[]]$DestroyArgs = @()
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location
    try
    {
        if (-not (Test-Path $CodePath))
        {
            throw "Terraform code not found: $CodePath"
        }

        _LogMessage -Level 'INFO' -Message "terraform apply (destroy) ‹$PlanFile›" -InvocationName $inv
        Set-Location $CodePath

        $cmd = @('apply')
        if (-not $SkipApprove)
        {
            $cmd += '-auto-approve'
        }
        $cmd += @($PlanFile) + $ApplyArgs

        & terraform @cmd
        if ($LASTEXITCODE)
        {
            throw "terraform apply (destroy) failed ($LASTEXITCODE)"
        }
    }
    finally
    {
        Set-Location $orig
    }
}

function Convert-TerraformPlanToJson
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CodePath,

    # Binary plan created by Invoke-TerraformPlan
        [string] $PlanFile = 'tfplan.plan',

    # Override JSON file name (default = <PlanFile>.json)
        [string] $JsonFile = $null,

    # Only emit the JSON path when caller asks for it
        [switch] $PassThru
    )

    $inv = $MyInvocation.MyCommand.Name
    $orig = Get-Location

    if (-not $JsonFile)
    {
        $JsonFile = "${PlanFile}.json"
    }

    try
    {
        # ── checks ───────────────────────────────────────────────────────────
        if (-not (Test-Path $CodePath))
        {
            _LogMessage -Level 'ERROR' -Message "Terraform code not found: $CodePath" -InvocationName $inv
            throw "Terraform code not found: $CodePath"
        }
        $planPath = Join-Path $CodePath $PlanFile
        if (-not (Test-Path $planPath))
        {
            _LogMessage -Level 'ERROR' -Message "Plan file not found: $planPath" -InvocationName $inv
            throw "Plan file not found: $planPath"
        }

        # ── convert ─────────────────────────────────────────────────────────
        _LogMessage -Level 'INFO' -Message "Converting $PlanFile → $JsonFile" -InvocationName $inv
        Set-Location $CodePath

        $jsonPath = Join-Path $CodePath $JsonFile
        terraform show -json $PlanFile | Out-File -FilePath $jsonPath -Encoding utf8
        $code = $LASTEXITCODE
        _LogMessage -Level 'DEBUG' -Message "terraform show exit-code: $code" -InvocationName $inv
        if ($code -ne 0)
        {
            throw "terraform show failed (exit $code)."
        }

        if (-not (Test-Path $jsonPath))
        {
            throw 'JSON output not created.'
        }

        _LogMessage -Level 'INFO' -Message "JSON plan written to $jsonPath" -InvocationName $inv

        if ($PassThru)
        {
            return $jsonPath
        }   # ← only emit when requested
    }
    catch
    {
        _LogMessage -Level 'ERROR' -Message $_.Exception.Message -InvocationName $inv
        throw
    }
    finally
    {
        Set-Location $orig
    }
}


###############################################################################
# Update the module export list
###############################################################################
Export-ModuleMember -Function `
    Invoke-TerraformValidate, `
          Invoke-TerraformFmtCheck, `
          Get-TerraformStackFolders, `
          Invoke-TerraformInit, `
          Invoke-TerraformWorkspaceSelect, `
          Invoke-TerraformPlan, `
          Invoke-TerraformPlanDestroy, `
          Invoke-TerraformApply, `
          Invoke-TerraformDestroy, `
          Convert-TerraformPlanToJson

