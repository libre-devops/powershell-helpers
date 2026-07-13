Set-StrictMode -Version Latest

function ConvertFrom-LdoYaml {
    <#
    .SYNOPSIS
        Parses YAML into objects, preferring the yq binary with a powershell-yaml fallback.

    .DESCRIPTION
        Uses yq (present on GitHub hosted runners and most dev machines) to convert YAML
        to JSON and returns the parsed object; when yq is unavailable, installs and uses
        the powershell-yaml module instead. One code path for CI and local use. Two
        unrelated tools ship as "yq" (mikefarah's Go build and the kislyuk Python jq
        wrapper) with different dialects; the flavour is detected per call.

    .PARAMETER Path
        A YAML file to parse.

    .PARAMETER Content
        YAML content to parse.

    .EXAMPLE
        ConvertFrom-LdoYaml -Path ./custom-detections/identity/rule.yaml

    .OUTPUTS
        System.Object
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Content')][ValidateNotNullOrEmpty()][string]$Content
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path' -and -not (Test-Path $Path)) {
        throw "ConvertFrom-LdoYaml: file not found: $Path"
    }

    if (Get-Command yq -ErrorAction SilentlyContinue) {
        $goFlavour = ((& yq --version 2>&1) -join ' ') -match 'mikefarah'

        $json = if ($PSCmdlet.ParameterSetName -eq 'Path') {
            if ($goFlavour) { & yq eval -o=json '.' $Path } else { & yq '.' $Path }
        }
        else {
            if ($goFlavour) { $Content | & yq eval -o=json '.' - } else { $Content | & yq '.' }
        }
        Assert-LdoLastExitCode -Operation 'yq (yaml to json)'
        return ($json -join "`n") | ConvertFrom-Json -Depth 100
    }

    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Write-LdoLog -Level INFO -Message 'yq not found; installing the powershell-yaml module.'
        Install-Module powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module powershell-yaml -ErrorAction Stop

    $raw = if ($PSCmdlet.ParameterSetName -eq 'Path') { Get-Content -Raw $Path } else { $Content }
    return ConvertFrom-Yaml -Yaml $raw
}

function Test-LdoYamlPlainScalar {
    # Internal: whether a string can be emitted unquoted in YAML without changing meaning.
    param([string]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) { return $false }
    if ($Value -ne $Value.Trim()) { return $false }
    if ($Value -match '[\x00-\x1f]') { return $false }
    # Reserved words and things a YAML parser would retype.
    if ($Value -match '^(?i)(true|false|null|~|yes|no|on|off)$') { return $false }
    if ($Value -match '^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$') { return $false }
    # Leading characters and substrings with YAML syntax meaning.
    if ($Value -match '^[\-?:,\[\]{}#&*!|>''"%@` ]') { return $false }
    if ($Value -match '(:\s)|(:$)|(\s#)') { return $false }
    return $true
}

function Format-LdoYamlScalar {
    # Internal: renders a single-line scalar, quoting only when required.
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    $s = [string]$Value
    if (Test-LdoYamlPlainScalar -Value $s) { return $s }
    $escaped = $s.Replace('\', '\\').Replace('"', '\"')
    return "`"$escaped`""
}

function ConvertTo-LdoYamlNode {
    # Internal: renders a value as either an inline scalar, a block scalar, or nested lines.
    param($Value, [int]$Level, [int]$Depth)

    if ($Depth -le 0) { throw 'ConvertTo-LdoYaml: maximum depth exceeded (is the object cyclic?).' }
    $pad = '  ' * $Level

    # Multiline strings become literal block scalars, the analyst friendly shape for KQL.
    if ($Value -is [string] -and $Value.Contains("`n")) {
        $body = foreach ($line in ($Value.Replace("`r`n", "`n").TrimEnd("`n") -split "`n")) {
            if ($line.Length -gt 0) { "$pad$line" } else { '' }
        }
        return [pscustomobject]@{ Kind = 'block'; Lines = @($body) }
    }

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value.GetType().IsPrimitive -or
        $Value -is [decimal] -or $Value -is [datetime]) {
        return [pscustomobject]@{ Kind = 'inline'; Text = (Format-LdoYamlScalar -Value $Value) }
    }

    # Mappings: hashtables and ordered dictionaries keep their enumeration order; PSCustomObjects
    # keep property order, so [ordered] input round trips deterministically. Entries build with
    # the unary comma append because a single iteration foreach unwraps its only output, which
    # would mangle one key maps.
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $entries = @()
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($k in $Value.Keys) { $entries += , @([string]$k, $Value[$k]) }
        }
        else {
            foreach ($p in $Value.PSObject.Properties) { $entries += , @($p.Name, $p.Value) }
        }
        if ($entries.Count -eq 0) { return [pscustomobject]@{ Kind = 'inline'; Text = '{}' } }

        $lines = foreach ($e in $entries) {
            $key = Format-LdoYamlScalar -Value $e[0]
            $node = ConvertTo-LdoYamlNode -Value $e[1] -Level ($Level + 1) -Depth ($Depth - 1)
            switch ($node.Kind) {
                'inline' { "$pad${key}: $($node.Text)" }
                'block' { @("$pad${key}: |") + $node.Lines }
                'nested' { @("$pad${key}:") + $node.Lines }
            }
        }
        return [pscustomobject]@{ Kind = 'nested'; Lines = @($lines) }
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return [pscustomobject]@{ Kind = 'inline'; Text = '[]' } }
        $childPad = '  ' * ($Level + 1)
        $lines = foreach ($item in $items) {
            $node = ConvertTo-LdoYamlNode -Value $item -Level ($Level + 1) -Depth ($Depth - 1)
            switch ($node.Kind) {
                'inline' { "$pad- $($node.Text)" }
                'block' { @("$pad- |") + $node.Lines }
                'nested' {
                    # Fold the first nested line onto the dash so maps in sequences read naturally.
                    $nested = @($node.Lines)
                    @("$pad- " + $nested[0].Substring($childPad.Length)) + @($nested | Select-Object -Skip 1)
                }
            }
        }
        return [pscustomobject]@{ Kind = 'nested'; Lines = @($lines) }
    }

    return [pscustomobject]@{ Kind = 'inline'; Text = (Format-LdoYamlScalar -Value ([string]$Value)) }
}

function ConvertTo-LdoYaml {
    <#
    .SYNOPSIS
        Renders an object as clean, human first YAML.

    .DESCRIPTION
        A PowerShell native YAML emitter for the estate's analyst facing files: two space
        indentation, literal block scalars for multiline strings (KQL reads as written),
        minimal quoting, deterministic key order (use [ordered] hashtables or
        PSCustomObjects), and inline {} / [] for empty collections. Pair with
        ConvertFrom-LdoYaml for round trips.

    .PARAMETER InputObject
        The object to render (typically an [ordered] hashtable or PSCustomObject).

    .PARAMETER Depth
        Maximum nesting depth. Defaults to 32.

    .EXAMPLE
        [ordered]@{ display_name = 'Rule'; query = "A`n| take 1" } | ConvertTo-LdoYaml

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowNull()]$InputObject,
        [int]$Depth = 32
    )

    process {
        $node = ConvertTo-LdoYamlNode -Value $InputObject -Level 0 -Depth $Depth
        $text = switch ($node.Kind) {
            'inline' { $node.Text }
            'block' { (@('|') + $node.Lines) -join "`n" }
            'nested' { ($node.Lines -join "`n") }
        }
        return "$text`n"
    }
}
