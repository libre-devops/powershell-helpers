Set-StrictMode -Version Latest

# Consumption Logic App workflow tooling: the offline half checks a definition against the
# contract the platform enforces, and the online half asks Azure to validate it without deploying.
#
# The contract these commands encode is not taste, it is what the resource provider rejects:
#
#   * A definition arrives in one of three shapes. The designer's code view gives
#     {"definition": {...}, "parameters": {...}}; an ARM resource GET gives
#     {"properties": {"definition": {...}}, ...}; a template carries the bare definition. A
#     workflow definition has no top-level "definition" or "properties" key of its own, so the
#     unwrap is unambiguous.
#   * A wrapper's "parameters" block holds VALUES. A bare definition's top-level "parameters" is
#     its DECLARATIONS. Reading one as the other is the classic round-trip trap, and it is why
#     Get-LdoLogicAppParameterStatus reports the shape it matched alongside its verdict.
#   * Every parameter the definition DECLARES needs a value by deploy time, or the engine returns
#     InvalidTemplate, "The value for the workflow parameter 'x' ... is not provided". $connections
#     is the exception a deployment tool generates; SecureString and SecureObject should arrive as
#     inputs so the secret never lands in the definition.
#   * A native Workflow dispatch action's TARGET is validated at PUT time (NestedWorkflowNotFound),
#     so a workflow invoking a sibling has to deploy after it. Get-LdoLogicAppDeployOrder derives
#     that ordering from the definitions themselves.

# -------------------------------------------------------------------------------------------------
# Private helpers
# -------------------------------------------------------------------------------------------------

function Test-LdoLogicAppMember {
    <#
    .SYNOPSIS
        Returns true when an object carries the named property.

    .DESCRIPTION
        Set-StrictMode -Version Latest turns a missing-property read into a terminating error, so
        every optional property access in this module goes through this check first.

    .PARAMETER InputObject
        The object to inspect. A null input always returns false.

    .PARAMETER Name
        The property name to look for.

    .EXAMPLE
        if (Test-LdoLogicAppMember -InputObject $doc -Name 'definition') { $doc.definition }

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    if ($null -eq $InputObject) { return $false }
    if ($InputObject -is [hashtable]) { return $InputObject.ContainsKey($Name) }

    # Enumerate the property objects rather than reading .Name off the collection: on a primitive
    # the collection is empty, and StrictMode turns that member access into a terminating error.
    return (@($InputObject.PSObject.Properties | ForEach-Object { $_.Name }) -contains $Name)
}

function ConvertTo-LdoLogicAppTokenSafeJson {
    <#
    .SYNOPSIS
        Blanks Terraform template tokens so a .json.tftpl can be parsed as JSON.

    .DESCRIPTION
        A templatefile source is not valid JSON while it still carries ${token} placeholders.
        Replacing each with a safe literal lets the SHAPE be checked (parameter names,
        declarations, trigger names) without rendering. Logic App workflow expressions use the
        @{...} form, so ${...} is unambiguously a Terraform token here.

        WHERE the token sits decides the substitution, which is why this scans rather than running
        a regex. A token inside a JSON string ("inputs": "${x}") becomes bare text, but one
        standing alone in value position ("interval": ${x}, the shape a number or a jsonencode
        result takes) has to gain quotes or the result is not parseable. The scanner also tracks
        escapes and brace nesting, so a token containing braces is still matched as one unit.

        A token in value position is read back as a string regardless of what it would really
        render to. That is fine for the shape checks this module performs, but it means this is not
        a substitute for rendering when a VALUE matters.

    .PARAMETER Json
        The raw file or string content.

    .EXAMPLE
        ConvertTo-LdoLogicAppTokenSafeJson -Json (Get-Content -Raw ./workflow.json.tftpl)

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Json
    )

    $builder = [System.Text.StringBuilder]::new($Json.Length)
    $inString = $false
    $index = 0

    while ($index -lt $Json.Length) {
        $character = $Json[$index]

        if ($inString) {
            # A backslash escape carries its next character verbatim, so a \" never ends the string.
            if ($character -eq '\' -and $index + 1 -lt $Json.Length) {
                [void]$builder.Append($character).Append($Json[$index + 1])
                $index += 2
                continue
            }
            if ($character -eq '"') {
                $inString = $false
                [void]$builder.Append($character)
                $index++
                continue
            }
        }
        elseif ($character -eq '"') {
            $inString = $true
            [void]$builder.Append($character)
            $index++
            continue
        }

        # $${ is an escaped literal in templatefile: it renders as ${ and is not a token.
        if ($character -eq '$' -and $index + 2 -lt $Json.Length -and $Json[$index + 1] -eq '$' -and $Json[$index + 2] -eq '{') {
            [void]$builder.Append('${')
            $index += 3
            continue
        }

        if ($character -eq '$' -and $index + 1 -lt $Json.Length -and $Json[$index + 1] -eq '{') {
            $depth = 0
            $scan = $index + 1
            while ($scan -lt $Json.Length) {
                if ($Json[$scan] -eq '{') { $depth++ }
                elseif ($Json[$scan] -eq '}') {
                    $depth--
                    if ($depth -eq 0) { break }
                }
                $scan++
            }

            if ($scan -lt $Json.Length) {
                # Inside a string the marker is bare; in value position it needs its own quotes.
                [void]$builder.Append($(if ($inString) { 'LDO_TOKEN' } else { '"LDO_TOKEN"' }))
                $index = $scan + 1
                continue
            }
        }

        [void]$builder.Append($character)
        $index++
    }

    return $builder.ToString()
}

function Resolve-LdoLogicAppDocument {
    <#
    .SYNOPSIS
        Loads a Logic App document from a path or a JSON string.

    .DESCRIPTION
        Accepts either a file path or raw JSON, tolerates unrendered Terraform tokens, and returns
        the parsed object together with the original text (the text matters: sibling dispatch
        detection reads it directly).

    .PARAMETER Path
        Path to a .json or .json.tftpl file.

    .PARAMETER Json
        Raw JSON content.

    .EXAMPLE
        Resolve-LdoLogicAppDocument -Path ./raw/workflow.json

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "Logic App definition file not found: '$Path'."
        }
        $source = (Resolve-Path -LiteralPath $Path).Path
        $text = Get-Content -Raw -LiteralPath $source
    }
    else {
        $source = '<string>'
        $text = $Json
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Logic App definition source '$source' is empty."
    }

    $probe = ConvertTo-LdoLogicAppTokenSafeJson -Json $text
    try {
        $parsed = $probe | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Logic App definition source '$source' is not parseable as JSON: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Source = $source
        Text = $text
        Parsed = $parsed
    }
}

# -------------------------------------------------------------------------------------------------
# Shape detection and unwrapping
# -------------------------------------------------------------------------------------------------

function ConvertFrom-LdoLogicAppExport {
    <#
    .SYNOPSIS
        Unwraps a Logic App export into its definition, wrapper parameter values and connections.

    .DESCRIPTION
        Detects which of the three shapes Azure hands you the document is in and returns the parts
        separated, so callers never have to guess whether a "parameters" block holds values or
        declarations:

          CodeView       {"definition": {...}, "parameters": {...}}          designer code view
          ArmResource    {"properties": {"definition": {...}}, ...}          az rest / Export template
          BareDefinition {"$schema": ..., "triggers": ..., "actions": ...}   a template file

        ParameterValues is populated only for the two wrapped shapes. A bare definition carries no
        values at all, and treating its declarations as values is the trap this command exists to
        remove.

    .PARAMETER Path
        Path to a .json or .json.tftpl file. Unrendered ${tokens} are tolerated.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .EXAMPLE
        ConvertFrom-LdoLogicAppExport -Path ./raw/logic-soc-router.json | Select-Object Shape

    .EXAMPLE
        (ConvertFrom-LdoLogicAppExport -Path ./export.json).ParameterValues.PSObject.Properties.Name

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json
    )

    process {
        $doc = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Resolve-LdoLogicAppDocument -Path $Path
        }
        else {
            Resolve-LdoLogicAppDocument -Json $Json
        }

        $parsed = $doc.Parsed

        if ((Test-LdoLogicAppMember -InputObject $parsed -Name 'properties') -and
            (Test-LdoLogicAppMember -InputObject $parsed.properties -Name 'definition')) {
            $shape = 'ArmResource'
            $definition = $parsed.properties.definition
            $values = if (Test-LdoLogicAppMember -InputObject $parsed.properties -Name 'parameters') { $parsed.properties.parameters } else { $null }
        }
        elseif (Test-LdoLogicAppMember -InputObject $parsed -Name 'definition') {
            $shape = 'CodeView'
            $definition = $parsed.definition
            $values = if (Test-LdoLogicAppMember -InputObject $parsed -Name 'parameters') { $parsed.parameters } else { $null }
        }
        else {
            $shape = 'BareDefinition'
            $definition = $parsed
            $values = $null
        }

        $name = $null
        if (Test-LdoLogicAppMember -InputObject $parsed -Name 'name') { $name = $parsed.name }
        elseif ($doc.Source -ne '<string>') { $name = [System.IO.Path]::GetFileNameWithoutExtension($doc.Source) -replace '\.json$', '' }

        Write-LdoLog -Level DEBUG -Message "Resolved '$($doc.Source)' as shape '$shape'."

        return [pscustomobject]@{
            Source = $doc.Source
            Name = $name
            Shape = $shape
            Definition = $definition
            ParameterValues = $values
            Declarations = if (Test-LdoLogicAppMember -InputObject $definition -Name 'parameters') { $definition.parameters } else { $null }
            Text = $doc.Text
        }
    }
}

# -------------------------------------------------------------------------------------------------
# Offline validation
# -------------------------------------------------------------------------------------------------

function Get-LdoLogicAppParameterStatus {
    <#
    .SYNOPSIS
        Reports whether each parameter a definition declares will have a value at deploy time.

    .DESCRIPTION
        For every declared parameter, works out which of the four sources satisfies it and returns
        one record per parameter. A parameter is satisfied by any of:

          * being $connections, which a deployment tool generates from its connections input,
          * a defaultValue on the declaration itself,
          * a value carried by the pasted wrapper (the two wrapped shapes only, never a bare
            definition, whose top-level parameters block is declarations),
          * a name passed to -SuppliedParameter, standing in for a deployment tool's own
            parameters input.

        SecureString and SecureObject are deliberately never satisfied by the wrapper: a secret
        should arrive as an input so it stays out of the definition, the plan and the state.

        Anything left unsatisfied is rejected by the engine at deploy time with InvalidTemplate,
        "The value for the workflow parameter ... is not provided".

    .PARAMETER Path
        Path to a .json or .json.tftpl file. Unrendered ${tokens} are tolerated.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .PARAMETER SuppliedParameter
        Names supplied out of band, for example through a Terraform module's parameters input.

    .PARAMETER UnsatisfiedOnly
        Return only the parameters that will fail, which is what a gate wants.

    .EXAMPLE
        Get-LdoLogicAppParameterStatus -Path ./templates/handler.json.tftpl -UnsatisfiedOnly

    .EXAMPLE
        Get-LdoLogicAppParameterStatus -Path ./export.json -SuppliedParameter review, tenant_id

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [string[]]$SuppliedParameter = @(),

        [switch]$UnsatisfiedOnly
    )

    process {
        $export = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            ConvertFrom-LdoLogicAppExport -Path $Path
        }
        else {
            ConvertFrom-LdoLogicAppExport -Json $Json
        }

        if ($null -eq $export.Declarations) {
            Write-LdoLog -Level DEBUG -Message "'$($export.Source)' declares no parameters."
            return
        }

        $wrapperNames = @()
        if ($null -ne $export.ParameterValues) {
            $wrapperNames = @($export.ParameterValues.PSObject.Properties.Name)
        }

        foreach ($declaration in $export.Declarations.PSObject.Properties) {
            $name = $declaration.Name
            $type = if (Test-LdoLogicAppMember -InputObject $declaration.Value -Name 'type') { $declaration.Value.type } else { $null }
            $isSecure = $type -in @('SecureString', 'SecureObject')
            $hasDefault = Test-LdoLogicAppMember -InputObject $declaration.Value -Name 'defaultValue'
            $inWrapper = $wrapperNames -contains $name
            $inSupplied = $SuppliedParameter -contains $name

            if ($name -eq '$connections') {
                $satisfied = $true
                $satisfiedBy = 'Generated'
                $reason = 'generated by the deployment tool from its connections input'
            }
            elseif ($inSupplied) {
                $satisfied = $true
                $satisfiedBy = 'SuppliedParameter'
                $reason = 'supplied out of band as a deployment tool input'
            }
            elseif ($hasDefault) {
                $satisfied = $true
                $satisfiedBy = 'DefaultValue'
                $reason = 'the declaration carries a defaultValue'
            }
            elseif ($inWrapper -and -not $isSecure) {
                $satisfied = $true
                $satisfiedBy = 'Wrapper'
                $reason = "the pasted $($export.Shape) wrapper carries a value"
            }
            elseif ($inWrapper -and $isSecure) {
                $satisfied = $false
                $satisfiedBy = 'None'
                $reason = 'secure type: the wrapper value is ignored on purpose, supply it as an input so the secret stays out of the definition'
            }
            elseif ($export.Shape -eq 'BareDefinition') {
                $satisfied = $false
                $satisfiedBy = 'None'
                $reason = 'no defaultValue, and a bare definition has no wrapper to take a value from'
            }
            else {
                $satisfied = $false
                $satisfiedBy = 'None'
                $reason = "no defaultValue, and the $($export.Shape) wrapper carries no value for it"
            }

            $record = [pscustomobject]@{
                Source = $export.Source
                Workflow = $export.Name
                Shape = $export.Shape
                Name = $name
                Type = $type
                IsSecure = $isSecure
                HasDefault = $hasDefault
                InWrapper = $inWrapper
                InSupplied = $inSupplied
                Satisfied = $satisfied
                SatisfiedBy = $satisfiedBy
                Reason = $reason
            }

            if ($UnsatisfiedOnly -and $satisfied) { continue }
            $record
        }
    }
}

function Test-LdoLogicAppDefinition {
    <#
    .SYNOPSIS
        Checks a Logic App definition offline against the contract the platform enforces.

    .DESCRIPTION
        Runs every offline check that corresponds to something Azure actually rejects or that
        deploys cleanly and then bites at run time, with no network access and nothing deployed.

        Errors (the deploy is rejected):
          * a declared parameter with no value from any source,
          * a supplied parameter the definition does not declare,
          * connections wired with no $connections declaration in the definition,
          * a named callback trigger that does not exist in the definition.

        Warnings (it deploys, then surprises you):
          * no triggers block, so nothing can start the workflow,
          * no actions block,
          * a $connections declaration with nothing wired to it.

        Returns a boolean by default so it drops straight into an if. Use -Detailed to get the
        finding objects for a report.

    .PARAMETER Path
        Path to a .json or .json.tftpl file. Unrendered ${tokens} are tolerated.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .PARAMETER SuppliedParameter
        Parameter names supplied out of band, for example through a Terraform module input.

    .PARAMETER ConnectionName
        Connection keys the deployment wires up, used to check the $connections declaration.

    .PARAMETER CallbackTriggerName
        A trigger expected to be callable, checked against the definition's triggers.

    .PARAMETER Detailed
        Return finding objects instead of a boolean.

    .EXAMPLE
        if (-not (Test-LdoLogicAppDefinition -Path ./export.json)) { throw 'invalid' }

    .EXAMPLE
        Get-ChildItem ./templates/*.json.tftpl | Test-LdoLogicAppDefinition -Detailed

    .OUTPUTS
        System.Boolean

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [string[]]$SuppliedParameter = @(),

        [string[]]$ConnectionName = @(),

        [string]$CallbackTriggerName,

        [switch]$Detailed
    )

    process {
        $export = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            ConvertFrom-LdoLogicAppExport -Path $Path
        }
        else {
            ConvertFrom-LdoLogicAppExport -Json $Json
        }

        $findings = [System.Collections.Generic.List[pscustomobject]]::new()
        $addFinding = {
            param([string]$Severity, [string]$Rule, [string]$Message)
            $findings.Add([pscustomobject]@{
                    Source = $export.Source
                    Workflow = $export.Name
                    Shape = $export.Shape
                    Severity = $Severity
                    Rule = $Rule
                    Message = $Message
                })
        }

        $statusArgs = @{ SuppliedParameter = $SuppliedParameter }
        $status = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Get-LdoLogicAppParameterStatus -Path $Path @statusArgs
        }
        else {
            Get-LdoLogicAppParameterStatus -Json $Json @statusArgs
        }

        foreach ($parameter in @($status | Where-Object { -not $_.Satisfied })) {
            & $addFinding 'Error' 'ParameterHasNoValue' `
                "parameter '$($parameter.Name)' ($($parameter.Type)) has no value: $($parameter.Reason)."
        }

        $declaredNames = @()
        if ($null -ne $export.Declarations) { $declaredNames = @($export.Declarations.PSObject.Properties.Name) }

        foreach ($supplied in $SuppliedParameter) {
            if ($declaredNames -notcontains $supplied) {
                & $addFinding 'Error' 'SuppliedParameterNotDeclared' `
                    "parameter '$supplied' is supplied but the definition does not declare it: the definition is the contract, values only fill it."
            }
        }

        if ($ConnectionName.Count -gt 0 -and $declaredNames -notcontains '$connections') {
            & $addFinding 'Error' 'ConnectionsNotDeclared' `
                "$($ConnectionName.Count) connection(s) are wired but the definition declares no `$connections parameter."
        }

        if ($ConnectionName.Count -eq 0 -and $declaredNames -contains '$connections') {
            & $addFinding 'Warning' 'ConnectionsDeclaredButUnwired' `
                'the definition declares $connections but no connections were wired to it.'
        }

        $triggerNames = @()
        if ((Test-LdoLogicAppMember -InputObject $export.Definition -Name 'triggers') -and $null -ne $export.Definition.triggers) {
            $triggerNames = @($export.Definition.triggers.PSObject.Properties.Name)
        }

        if ($triggerNames.Count -eq 0) {
            & $addFinding 'Warning' 'NoTrigger' 'the definition has no triggers, so nothing can start this workflow.'
        }

        if ($PSBoundParameters.ContainsKey('CallbackTriggerName') -and $triggerNames -notcontains $CallbackTriggerName) {
            $known = if ($triggerNames.Count -gt 0) { $triggerNames -join ', ' } else { 'none' }
            & $addFinding 'Error' 'CallbackTriggerNotFound' `
                "callback trigger '$CallbackTriggerName' does not exist in the definition (triggers: $known)."
        }

        $hasActions = $false
        if ((Test-LdoLogicAppMember -InputObject $export.Definition -Name 'actions') -and $null -ne $export.Definition.actions) {
            $hasActions = @($export.Definition.actions.PSObject.Properties.Name).Count -gt 0
        }
        if (-not $hasActions) {
            & $addFinding 'Warning' 'NoActions' 'the definition has no actions, so this workflow does nothing when it runs.'
        }

        $errorCount = @($findings | Where-Object { $_.Severity -eq 'Error' }).Count
        if ($errorCount -gt 0) {
            Write-LdoLog -Level WARN -Message "'$($export.Source)': $errorCount error finding(s)."
        }
        else {
            Write-LdoLog -Level DEBUG -Message "'$($export.Source)': no error findings."
        }

        if ($Detailed) { return $findings.ToArray() }
        return ($errorCount -eq 0)
    }
}

function Assert-LdoLogicAppDefinition {
    <#
    .SYNOPSIS
        Throws when a Logic App definition fails the offline contract checks.

    .DESCRIPTION
        The gate form of Test-LdoLogicAppDefinition. Runs the same checks and throws a single error
        listing every error-severity finding, so a build step fails loudly with the reasons rather
        than a bare false. Warnings are logged, not thrown, unless -TreatWarningsAsErrors is set.

    .PARAMETER Path
        Path to a .json or .json.tftpl file. Unrendered ${tokens} are tolerated.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .PARAMETER SuppliedParameter
        Parameter names supplied out of band, for example through a Terraform module input.

    .PARAMETER ConnectionName
        Connection keys the deployment wires up.

    .PARAMETER CallbackTriggerName
        A trigger expected to be callable.

    .PARAMETER TreatWarningsAsErrors
        Throw on warning-severity findings too.

    .EXAMPLE
        Get-ChildItem ./templates/*.json.tftpl | Assert-LdoLogicAppDefinition

    .OUTPUTS
        None
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [string[]]$SuppliedParameter = @(),

        [string[]]$ConnectionName = @(),

        [string]$CallbackTriggerName,

        [switch]$TreatWarningsAsErrors
    )

    process {
        $forward = @{
            SuppliedParameter = $SuppliedParameter
            ConnectionName = $ConnectionName
            Detailed = $true
        }
        if ($PSBoundParameters.ContainsKey('CallbackTriggerName')) { $forward['CallbackTriggerName'] = $CallbackTriggerName }

        $findings = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Test-LdoLogicAppDefinition -Path $Path @forward
        }
        else {
            Test-LdoLogicAppDefinition -Json $Json @forward
        }

        $source = if ($PSCmdlet.ParameterSetName -eq 'Path') { $Path } else { '<string>' }

        foreach ($warning in @($findings | Where-Object { $_.Severity -eq 'Warning' })) {
            Write-LdoLog -Level WARN -Message "$($warning.Rule): $($warning.Message)"
        }

        $fatal = @($findings | Where-Object {
                $_.Severity -eq 'Error' -or ($TreatWarningsAsErrors -and $_.Severity -eq 'Warning')
            })

        if ($fatal.Count -gt 0) {
            $detail = ($fatal | ForEach-Object { "  [$($_.Severity)] $($_.Rule): $($_.Message)" }) -join [Environment]::NewLine
            throw "Logic App definition '$source' failed validation with $($fatal.Count) finding(s):$([Environment]::NewLine)$detail"
        }

        Write-LdoLog -Level SUCCESS -Message "Logic App definition '$source' passed offline validation."
    }
}

# -------------------------------------------------------------------------------------------------
# Azure-side validation, without deploying
# -------------------------------------------------------------------------------------------------

function Test-LdoLogicAppDeployment {
    <#
    .SYNOPSIS
        Asks Azure to validate a workflow definition without deploying it.

    .DESCRIPTION
        Posts the definition to the Logic Apps validate endpoint
        (Microsoft.Logic/locations/{location}/workflows/{name}/validate), which type-checks the
        whole definition and returns the resource provider's own verdict while creating nothing
        and costing nothing.

        This is the authoritative oracle. The offline checks in this module encode what the
        provider rejects, but only the provider decides, so use this to confirm anything the
        offline pass cannot know: whether a property is accepted on a given api-version, whether
        an expression type-checks, whether a connector action shape is valid.

        Note the endpoint validates the DEFINITION, not the estate around it. A native Workflow
        dispatch action's target is checked at PUT time, so use Get-LdoLogicAppDeployOrder for
        ordering rather than expecting this to catch NestedWorkflowNotFound.

        Requires a signed-in Azure CLI.

    .PARAMETER Path
        Path to a .json file holding the definition, in any of the three shapes.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .PARAMETER ResourceGroupName
        Resource group used to scope the validate call.

    .PARAMETER Location
        Azure region, for example uksouth. Defaults to the resource group's location.

    .PARAMETER Name
        Workflow name used in the validate URL. Defaults to the export's name or the file stem.

    .PARAMETER SubscriptionId
        Subscription to validate against. Defaults to the CLI's current subscription.

    .PARAMETER Detailed
        Return the provider's response object instead of a boolean.

    .EXAMPLE
        Test-LdoLogicAppDeployment -Path ./export.json -ResourceGroupName rg-soc-uks-dev-01

    .EXAMPLE
        Test-LdoLogicAppDeployment -Path ./export.json -ResourceGroupName rg -Detailed

    .OUTPUTS
        System.Boolean

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [string]$Location,

        [string]$Name,

        [string]$SubscriptionId,

        [switch]$Detailed
    )

    process {
        Assert-LdoCommand -Name 'az'

        $export = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            ConvertFrom-LdoLogicAppExport -Path $Path
        }
        else {
            ConvertFrom-LdoLogicAppExport -Json $Json
        }

        if (-not $SubscriptionId) {
            $SubscriptionId = (& az account show --query id -o tsv)
            Assert-LdoLastExitCode -Operation 'az account show'
        }

        if (-not $Location) {
            $Location = (& az group show --name $ResourceGroupName --subscription $SubscriptionId --query location -o tsv)
            Assert-LdoLastExitCode -Operation 'az group show'
        }

        $workflowName = if ($Name) { $Name } elseif ($export.Name) { $export.Name } else { 'ldo-validate-probe' }

        # The endpoint takes a workflow resource body: definition, and the parameter VALUES beside
        # it. A valueless declaration is exactly what it rejects, which is the point of asking.
        $properties = @{ definition = $export.Definition }
        if ($null -ne $export.ParameterValues) { $properties['parameters'] = $export.ParameterValues }

        $body = @{ location = $Location; properties = $properties } | ConvertTo-Json -Depth 100 -Compress

        $bodyFile = New-TemporaryFile
        try {
            Set-Content -LiteralPath $bodyFile.FullName -Value $body -Encoding utf8NoBOM

            $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName" +
            "/providers/Microsoft.Logic/locations/$Location/workflows/$workflowName/validate?api-version=2019-05-01"

            Write-LdoLog -Level INFO -Message "Validating '$workflowName' against the Logic Apps validate endpoint in '$Location'."

            $response = & az rest --method post --url $url --body "@$($bodyFile.FullName)" --headers 'Content-Type=application/json' -o json 2>&1
            $succeeded = ($LASTEXITCODE -eq 0)
        }
        finally {
            Remove-Item -LiteralPath $bodyFile.FullName -Force -ErrorAction SilentlyContinue
        }

        $responseText = ($response | Out-String).Trim()

        if ($succeeded) {
            Write-LdoLog -Level SUCCESS -Message "'$workflowName' passed provider validation."
        }
        else {
            Write-LdoLog -Level ERROR -Message "'$workflowName' failed provider validation: $responseText"
        }

        if ($Detailed) {
            $parsedResponse = $null
            if ($responseText) {
                try { $parsedResponse = $responseText | ConvertFrom-Json -Depth 100 } catch { $parsedResponse = $null }
            }
            return [pscustomobject]@{
                Source = $export.Source
                Workflow = $workflowName
                Location = $Location
                Valid = $succeeded
                Response = $parsedResponse
                RawMessage = $responseText
            }
        }

        return $succeeded
    }
}

# -------------------------------------------------------------------------------------------------
# Export from Azure
# -------------------------------------------------------------------------------------------------

function Export-LdoLogicAppDefinition {
    <#
    .SYNOPSIS
        Exports deployed Consumption Logic App definitions from Azure to disk.

    .DESCRIPTION
        Reads the deployed workflows in a resource group and writes each one out as JSON, in either
        the designer code view shape (definition plus its resolved parameter values, which is what
        pastes back into a deployment tool) or the raw ARM resource shape.

        This is a read-only operation against the management plane.

    .PARAMETER ResourceGroupName
        Resource group holding the workflows.

    .PARAMETER Name
        Optional workflow names to limit the export. All workflows in the group when omitted.

    .PARAMETER OutputPath
        Directory to write into. Created when missing. Files are named after the workflow.

    .PARAMETER Shape
        CodeView (default) writes {"definition": ..., "parameters": ...}; Arm writes the whole
        resource as returned by the management API.

    .PARAMETER SubscriptionId
        Subscription to read from. Defaults to the CLI's current subscription.

    .PARAMETER PassThru
        Emit the exported objects as well as writing the files.

    .EXAMPLE
        Export-LdoLogicAppDefinition -ResourceGroupName rg-soc-uks-dev-01 -OutputPath ./raw

    .EXAMPLE
        Export-LdoLogicAppDefinition -ResourceGroupName rg -Name logic-router -Shape Arm -OutputPath ./raw

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [string[]]$Name = @(),

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [ValidateSet('CodeView', 'Arm')]
        [string]$Shape = 'CodeView',

        [string]$SubscriptionId,

        [switch]$PassThru
    )

    Assert-LdoCommand -Name 'az'

    if (-not $SubscriptionId) {
        $SubscriptionId = (& az account show --query id -o tsv)
        Assert-LdoLastExitCode -Operation 'az account show'
    }

    Write-LdoLog -Level INFO -Message "Listing Logic App workflows in '$ResourceGroupName'."
    $listJson = & az resource list --resource-group $ResourceGroupName --resource-type 'Microsoft.Logic/workflows' --subscription $SubscriptionId -o json
    Assert-LdoLastExitCode -Operation 'az resource list'

    $workflows = @($listJson | ConvertFrom-Json -Depth 100)
    if ($Name.Count -gt 0) {
        $workflows = @($workflows | Where-Object { $Name -contains $_.name })
    }

    if ($workflows.Count -eq 0) {
        Write-LdoLog -Level WARN -Message "No Logic App workflows matched in '$ResourceGroupName'."
        return
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        if ($PSCmdlet.ShouldProcess($OutputPath, 'Create output directory')) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
    }

    foreach ($workflow in $workflows) {
        Write-LdoLog -Level INFO -Message "Exporting '$($workflow.name)'."
        $showJson = & az rest --method get --url "https://management.azure.com$($workflow.id)?api-version=2019-05-01" -o json
        Assert-LdoLastExitCode -Operation "az rest get $($workflow.name)"

        $resource = $showJson | ConvertFrom-Json -Depth 100

        $document = if ($Shape -eq 'Arm') {
            $resource
        }
        else {
            $codeView = [ordered]@{ definition = $resource.properties.definition }
            if (Test-LdoLogicAppMember -InputObject $resource.properties -Name 'parameters') {
                $codeView['parameters'] = $resource.properties.parameters
            }
            [pscustomobject]$codeView
        }

        $file = Join-Path $OutputPath "$($workflow.name).json"
        if ($PSCmdlet.ShouldProcess($file, 'Write Logic App definition')) {
            $document | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
        }

        if ($PassThru) {
            [pscustomobject]@{
                Name = $workflow.name
                Id = $workflow.id
                Shape = $Shape
                Path = $file
            }
        }
    }
}

# -------------------------------------------------------------------------------------------------
# Transforms for lifting a definition between estates
# -------------------------------------------------------------------------------------------------

function Add-LdoLogicAppParameterDefault {
    <#
    .SYNOPSIS
        Back-fills a defaultValue onto every declaration from the wrapper's values.

    .DESCRIPTION
        Makes an export self-sufficient. A deployed definition whose declarations carry no defaults
        cannot be pasted back in on its own, because the values live in the wrapper and a
        deployment tool may own those separately. Copying each wrapper value down onto its
        declaration as a defaultValue means the definition alone is deployable.

        $connections is skipped, because a deployment tool regenerates it from its own connections
        input. SecureString and SecureObject are skipped too: writing a secret into the definition
        as a default is exactly what secure parameters exist to avoid.

        Note the corollary: the output now carries the SOURCE estate's values, so a copy taken
        elsewhere deploys against them unless re-pointed. Use Update-LdoLogicAppReference for that.

    .PARAMETER Path
        Path to a .json file to read.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .PARAMETER OutputPath
        Write the result here instead of returning it.

    .PARAMETER Force
        Overwrite a defaultValue that is already present.

    .EXAMPLE
        Add-LdoLogicAppParameterDefault -Path ./export.json -OutputPath ./template.json

    .EXAMPLE
        Get-ChildItem ./raw/*.json | Add-LdoLogicAppParameterDefault -OutputPath ./portable

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [string]$OutputPath,

        [switch]$Force
    )

    process {
        $export = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            ConvertFrom-LdoLogicAppExport -Path $Path
        }
        else {
            ConvertFrom-LdoLogicAppExport -Json $Json
        }

        if ($export.Shape -eq 'BareDefinition') {
            throw "Cannot back-fill defaults from '$($export.Source)': it is a bare definition, so it carries declarations but no values."
        }
        if ($null -eq $export.Declarations -or $null -eq $export.ParameterValues) {
            Write-LdoLog -Level WARN -Message "'$($export.Source)' has no declarations or no wrapper values; nothing to back-fill."
            return $export.Definition
        }

        $added = 0
        foreach ($declaration in $export.Declarations.PSObject.Properties) {
            $name = $declaration.Name
            if ($name -eq '$connections') { continue }

            $type = if (Test-LdoLogicAppMember -InputObject $declaration.Value -Name 'type') { $declaration.Value.type } else { $null }
            if ($type -in @('SecureString', 'SecureObject')) { continue }

            if ((Test-LdoLogicAppMember -InputObject $declaration.Value -Name 'defaultValue') -and -not $Force) { continue }
            if (-not (Test-LdoLogicAppMember -InputObject $export.ParameterValues -Name $name)) { continue }

            $wrapperEntry = $export.ParameterValues.$name
            if (-not (Test-LdoLogicAppMember -InputObject $wrapperEntry -Name 'value')) { continue }

            $declaration.Value | Add-Member -NotePropertyName 'defaultValue' -NotePropertyValue $wrapperEntry.value -Force
            $added++
        }

        Write-LdoLog -Level INFO -Message "Back-filled $added defaultValue(s) onto '$($export.Source)'."

        if ($OutputPath) {
            if ($PSCmdlet.ShouldProcess($OutputPath, 'Write back-filled definition')) {
                $export.Definition | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
            }
            return
        }

        return $export.Definition
    }
}

function Update-LdoLogicAppReference {
    <#
    .SYNOPSIS
        Rewrites estate-specific references in a definition so it can be lifted elsewhere.

    .DESCRIPTION
        A deployed definition carries absolute ARM ids in its action bodies and connection blocks:
        subscription ids, resource group names, connection resource names, instance URLs. Lifting
        it into another estate means rewriting those, and doing it as literal text over the
        serialised JSON keeps the definition byte-identical everywhere else.

        Replacements are applied in the order given, so put the most specific first: a later, more
        general rule would otherwise rewrite text an earlier one just produced.

    .PARAMETER Path
        Path to a .json file to read.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .PARAMETER Replacement
        Ordered dictionary of literal find/replace pairs. Use [ordered]@{} so the order is kept.

    .PARAMETER OutputPath
        Write the result here instead of returning it.

    .EXAMPLE
        $map = [ordered]@{ '/subscriptions/aaa' = '/subscriptions/bbb'; 'rg-old' = 'rg-new' }
        Update-LdoLogicAppReference -Path ./export.json -Replacement $map -OutputPath ./lifted.json

    .OUTPUTS
        System.String
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Collections.IDictionary]$Replacement,

        [string]$OutputPath
    )

    process {
        $doc = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            Resolve-LdoLogicAppDocument -Path $Path
        }
        else {
            Resolve-LdoLogicAppDocument -Json $Json
        }

        $text = $doc.Text
        foreach ($key in $Replacement.Keys) {
            $before = $text
            $text = $text.Replace([string]$key, [string]$Replacement[$key])
            if ($before -ne $text) {
                Write-LdoLog -Level DEBUG -Message "Rewrote '$key' in '$($doc.Source)'."
            }
        }

        if ($OutputPath) {
            if ($PSCmdlet.ShouldProcess($OutputPath, 'Write rewritten definition')) {
                Set-Content -LiteralPath $OutputPath -Value $text -Encoding utf8NoBOM
            }
            return
        }

        return $text
    }
}

# -------------------------------------------------------------------------------------------------
# Estate-level reads
# -------------------------------------------------------------------------------------------------

function Get-LdoLogicAppConnection {
    <#
    .SYNOPSIS
        Extracts the managed API connections a definition references.

    .DESCRIPTION
        Reads the resolved $connections value out of an export's wrapper and returns one record per
        connection, including whether it authenticates with a managed identity. That is the
        connectionProperties.authentication.type field, which must read ManagedServiceIdentity for
        managed identity auth to be in play, alongside the connection resource's own
        parameterValueType of Alternative.

        Only the wrapped shapes carry connection values; a bare definition declares $connections
        but holds no value for it.

    .PARAMETER Path
        Path to a .json file to read.

    .PARAMETER Json
        Raw JSON content instead of a file.

    .EXAMPLE
        Get-LdoLogicAppConnection -Path ./export.json | Format-Table Api, ManagedIdentityAuth

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [ValidateNotNullOrEmpty()]
        [string]$Json
    )

    process {
        $export = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            ConvertFrom-LdoLogicAppExport -Path $Path
        }
        else {
            ConvertFrom-LdoLogicAppExport -Json $Json
        }

        if ($null -eq $export.ParameterValues -or -not (Test-LdoLogicAppMember -InputObject $export.ParameterValues -Name '$connections')) {
            Write-LdoLog -Level DEBUG -Message "'$($export.Source)' carries no resolved `$connections value."
            return
        }

        $connectionsEntry = $export.ParameterValues.'$connections'
        if (-not (Test-LdoLogicAppMember -InputObject $connectionsEntry -Name 'value')) { return }

        foreach ($connection in $connectionsEntry.value.PSObject.Properties) {
            $detail = $connection.Value
            $authType = $null
            if ((Test-LdoLogicAppMember -InputObject $detail -Name 'connectionProperties') -and
                (Test-LdoLogicAppMember -InputObject $detail.connectionProperties -Name 'authentication') -and
                (Test-LdoLogicAppMember -InputObject $detail.connectionProperties.authentication -Name 'type')) {
                $authType = $detail.connectionProperties.authentication.type
            }

            [pscustomobject]@{
                Source = $export.Source
                Workflow = $export.Name
                Api = $connection.Name
                ConnectionName = if (Test-LdoLogicAppMember -InputObject $detail -Name 'connectionName') { $detail.connectionName } else { $connection.Name }
                ConnectionId = if (Test-LdoLogicAppMember -InputObject $detail -Name 'connectionId') { $detail.connectionId } else { $null }
                ManagedApiId = if (Test-LdoLogicAppMember -InputObject $detail -Name 'id') { $detail.id } else { $null }
                AuthenticationType = $authType
                ManagedIdentityAuth = ($authType -eq 'ManagedServiceIdentity')
            }
        }
    }
}

function Get-LdoLogicAppDeployOrder {
    <#
    .SYNOPSIS
        Works out the order a set of workflows has to deploy in.

    .DESCRIPTION
        ARM validates a native Workflow dispatch action's TARGET when the workflow is written, so a
        workflow that invokes a sibling fails with NestedWorkflowNotFound unless that sibling
        already exists. This derives the ordering from the definitions themselves rather than a
        hand-maintained list: a workflow referencing another by its /workflows/{name} path must
        deploy after it.

        Each workflow is assigned a tier: 0 for leaves that dispatch to nothing in the set, and
        then one higher than the highest tier it depends on. Deploy tier 0 first, then 1, and so
        on. A dependency cycle throws, because no ordering can satisfy it.

    .PARAMETER Path
        Paths to the definition files forming the set.

    .EXAMPLE
        Get-ChildItem ./raw/*.json | Get-LdoLogicAppDeployOrder | Sort-Object Tier

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [Alias('FullName')]
        [string[]]$Path
    )

    begin {
        $collected = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($item in $Path) { $collected.Add($item) }
    }

    end {
        $exports = @{}
        foreach ($file in $collected) {
            $export = ConvertFrom-LdoLogicAppExport -Path $file
            $key = if ($export.Name) { $export.Name } else { [System.IO.Path]::GetFileNameWithoutExtension($file) }
            $exports[$key] = $export
        }

        $names = @($exports.Keys)
        $dependencies = @{}
        foreach ($name in $names) {
            $text = $exports[$name].Text
            $dependencies[$name] = @($names | Where-Object { $_ -ne $name -and $text -match [regex]::Escape("/workflows/$_") })
        }

        $tiers = @{}
        $remaining = [System.Collections.Generic.List[string]]::new()
        foreach ($name in $names) { $remaining.Add($name) }

        $tier = 0
        while ($remaining.Count -gt 0) {
            $ready = @($remaining | Where-Object {
                    $unresolved = @($dependencies[$_] | Where-Object { -not $tiers.ContainsKey($_) })
                    $unresolved.Count -eq 0
                })

            if ($ready.Count -eq 0) {
                throw "Cannot order Logic App deployment: a dispatch cycle exists between $($remaining -join ', ')."
            }

            foreach ($name in $ready) {
                $tiers[$name] = $tier
                [void]$remaining.Remove($name)
            }
            $tier++
        }

        foreach ($name in ($names | Sort-Object { $tiers[$_] }, { $_ })) {
            [pscustomobject]@{
                Workflow = $name
                Tier = $tiers[$name]
                DependsOn = $dependencies[$name]
                Source = $exports[$name].Source
            }
        }
    }
}

function Compare-LdoLogicAppDefinition {
    <#
    .SYNOPSIS
        Compares two Logic App definitions structurally.

    .DESCRIPTION
        Unwraps both sides, walks them recursively and reports the JSON paths that differ. Because
        both are unwrapped first, a designer code view export compares cleanly against an ARM
        resource GET of the same workflow, and a rendered template compares against what is
        actually deployed, which is how drift review becomes a diff rather than archaeology.

    .PARAMETER ReferencePath
        The baseline definition, for example the rendered template.

    .PARAMETER DifferencePath
        The definition to compare against it, for example the deployed export.

    .PARAMETER IncludeParameterValues
        Compare the wrapper parameter values too, not just the definitions.

    .EXAMPLE
        Compare-LdoLogicAppDefinition -ReferencePath ./dist/router.json -DifferencePath ./raw/router.json

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ReferencePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$DifferencePath,

        [switch]$IncludeParameterValues
    )

    $reference = ConvertFrom-LdoLogicAppExport -Path $ReferencePath
    $difference = ConvertFrom-LdoLogicAppExport -Path $DifferencePath

    $differences = [System.Collections.Generic.List[pscustomobject]]::new()

    $compare = {
        param($Left, $Right, [string]$Path)

        $leftNull = ($null -eq $Left)
        $rightNull = ($null -eq $Right)
        if ($leftNull -and $rightNull) { return }

        if ($leftNull -or $rightNull) {
            $differences.Add([pscustomobject]@{
                    Path = $Path
                    Change = if ($leftNull) { 'AddedInDifference' } else { 'MissingInDifference' }
                    Reference = $Left
                    Difference = $Right
                })
            return
        }

        # Test against the concrete type, never [pscustomobject]: that accelerator resolves to
        # PSObject, and a string or an int satisfies -is [pscustomobject] too, which would send the
        # walk recursing into a primitive's (empty) property bag.
        $leftIsObject = $Left -is [System.Management.Automation.PSCustomObject]
        $rightIsObject = $Right -is [System.Management.Automation.PSCustomObject]

        if ($leftIsObject -and $rightIsObject) {
            $keys = @(
                @($Left.PSObject.Properties | ForEach-Object { $_.Name }) +
                @($Right.PSObject.Properties | ForEach-Object { $_.Name })
            ) | Select-Object -Unique | Sort-Object
            foreach ($key in $keys) {
                $leftValue = if (Test-LdoLogicAppMember -InputObject $Left -Name $key) { $Left.$key } else { $null }
                $rightValue = if (Test-LdoLogicAppMember -InputObject $Right -Name $key) { $Right.$key } else { $null }
                & $compare $leftValue $rightValue "$Path.$key"
            }
            return
        }

        $leftIsList = ($Left -is [System.Collections.IEnumerable]) -and ($Left -isnot [string])
        $rightIsList = ($Right -is [System.Collections.IEnumerable]) -and ($Right -isnot [string])

        if ($leftIsList -and $rightIsList) {
            $leftItems = @($Left)
            $rightItems = @($Right)
            $max = [Math]::Max($leftItems.Count, $rightItems.Count)
            for ($i = 0; $i -lt $max; $i++) {
                $leftValue = if ($i -lt $leftItems.Count) { $leftItems[$i] } else { $null }
                $rightValue = if ($i -lt $rightItems.Count) { $rightItems[$i] } else { $null }
                & $compare $leftValue $rightValue "$Path[$i]"
            }
            return
        }

        if ("$Left" -cne "$Right") {
            $differences.Add([pscustomobject]@{
                    Path = $Path
                    Change = 'ValueChanged'
                    Reference = $Left
                    Difference = $Right
                })
        }
    }

    & $compare $reference.Definition $difference.Definition 'definition'

    if ($IncludeParameterValues) {
        & $compare $reference.ParameterValues $difference.ParameterValues 'parameters'
    }

    if ($differences.Count -eq 0) {
        Write-LdoLog -Level SUCCESS -Message "'$ReferencePath' and '$DifferencePath' are structurally identical."
    }
    else {
        Write-LdoLog -Level WARN -Message "$($differences.Count) difference(s) between '$ReferencePath' and '$DifferencePath'."
    }

    return $differences.ToArray()
}

Export-ModuleMember -Function `
    'ConvertFrom-LdoLogicAppExport', `
    'Get-LdoLogicAppParameterStatus', `
    'Test-LdoLogicAppDefinition', `
    'Assert-LdoLogicAppDefinition', `
    'Test-LdoLogicAppDeployment', `
    'Export-LdoLogicAppDefinition', `
    'Add-LdoLogicAppParameterDefault', `
    'Update-LdoLogicAppReference', `
    'Get-LdoLogicAppConnection', `
    'Get-LdoLogicAppDeployOrder', `
    'Compare-LdoLogicAppDefinition'
