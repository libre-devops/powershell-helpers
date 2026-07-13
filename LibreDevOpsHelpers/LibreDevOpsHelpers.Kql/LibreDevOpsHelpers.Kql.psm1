Set-StrictMode -Version Latest

function Install-LdoKustoLanguage {
    <#
    .SYNOPSIS
        Ensures the Microsoft Kusto.Language assembly is loaded for offline KQL parsing.

    .DESCRIPTION
        Downloads the Microsoft.Azure.Kusto.Language NuGet package (the same library the
        Azure Sentinel repository uses for KQL validation in CI), caches the
        netstandard2.0 assembly under the user cache directory, and loads it into the
        session. When the type is already loaded, or a cached copy exists, no download
        happens, so repeated calls are cheap and offline friendly.

    .PARAMETER Version
        NuGet package version to install. Defaults to latest.

    .PARAMETER CacheDir
        Directory the assembly is cached in. Defaults to ~/.ldo/kusto-language.

    .EXAMPLE
        Install-LdoKustoLanguage

    .OUTPUTS
        System.String. The path of the loaded assembly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Version = 'latest',
        [string]$CacheDir = (Join-Path $HOME '.ldo' 'kusto-language')
    )

    if ('Kusto.Language.KustoCode' -as [type]) {
        Write-LdoLog -Level DEBUG -Message 'Kusto.Language is already loaded.'
        return $null
    }

    # A cached assembly avoids the network entirely: an exact version match when pinned,
    # or the newest cached copy when the caller asked for latest.
    $cached = $null
    if (Test-Path $CacheDir) {
        $candidates = Get-ChildItem -Path $CacheDir -Recurse -Filter 'Kusto.Language.dll' -File -ErrorAction SilentlyContinue
        if ($Version -ne 'latest') {
            $cached = $candidates | Where-Object { $_.Directory.Name -eq $Version } | Select-Object -First 1
        }
        elseif ($candidates) {
            $cached = $candidates | Sort-Object { [version]($_.Directory.Name) } -Descending | Select-Object -First 1
        }
    }

    if (-not $cached) {
        $url = 'https://www.nuget.org/api/v2/package/Microsoft.Azure.Kusto.Language'
        if ($Version -ne 'latest') { $url = "$url/$Version" }

        $work = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-kusto-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $work | Out-Null
        try {
            # Expand-Archive insists on a .zip extension, so the nupkg is saved as one.
            $zip = Join-Path $work 'kusto-language.zip'
            Write-LdoLog -Level INFO -Message "Downloading Microsoft.Azure.Kusto.Language ($Version) from nuget.org."
            Invoke-WebRequest -Uri $url -OutFile $zip -MaximumRedirection 5 | Out-Null
            Expand-Archive -Path $zip -DestinationPath (Join-Path $work 'pkg') -Force

            $nuspec = Get-ChildItem -Path (Join-Path $work 'pkg') -Filter '*.nuspec' -File | Select-Object -First 1
            $resolved = ([xml](Get-Content -Raw $nuspec.FullName)).package.metadata.version

            $dll = Join-Path $work 'pkg' 'lib' 'netstandard2.0' 'Kusto.Language.dll'
            if (-not (Test-Path $dll)) { throw 'Kusto.Language.dll (netstandard2.0) not found in the package.' }

            $dest = Join-Path $CacheDir $resolved
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -Path $dll -Destination $dest -Force
            $cached = Get-Item (Join-Path $dest 'Kusto.Language.dll')
            Write-LdoLog -Level SUCCESS -Message "Cached Kusto.Language $resolved at $dest."
        }
        finally {
            Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Add-Type -Path $cached.FullName
    Write-LdoLog -Level INFO -Message "Loaded Kusto.Language from $($cached.FullName)."
    return $cached.FullName
}

function Test-LdoKqlSyntax {
    <#
    .SYNOPSIS
        Parses KQL offline with Kusto.Language and reports syntax errors.

    .DESCRIPTION
        Runs each query (or each file's content) through the Kusto.Language parser, the
        library behind the product's own editors, entirely offline: no tenant, no
        credentials. Error diagnostics are logged with their source label and character
        position and make the result false; warnings are logged and do not. This is the
        fast local rung of the detection validation ladder; semantic validation against
        real tables happens remotely (Test-LdoHuntingQuery) or in the Terraform graph.

    .PARAMETER Query
        One or more KQL queries to parse.

    .PARAMETER Path
        One or more files, each containing a single KQL query.

    .PARAMETER SourceLabel
        Label used in log messages for queries passed as strings. File paths label
        themselves.

    .PARAMETER PassThru
        Emit the diagnostic objects (Source, Severity, Code, Position, Message) instead
        of a boolean.

    .EXAMPLE
        Test-LdoKqlSyntax -Query 'DeviceProcessEvents | project Timestamp, ReportId'

    .EXAMPLE
        Test-LdoKqlSyntax -Path ./queries/rule.kql -PassThru

    .OUTPUTS
        System.Boolean by default; diagnostic objects with -PassThru.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Query')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Query', ValueFromPipeline)]
        [ValidateNotNullOrEmpty()][string[]]$Query,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()][string[]]$Path,

        [string]$SourceLabel = 'query',
        [switch]$PassThru
    )

    begin {
        Install-LdoKustoLanguage | Out-Null
        $all = [System.Collections.Generic.List[object]]::new()
        $errorCount = 0
        $sources = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            foreach ($p in $Path) {
                if (-not (Test-Path $p)) { throw "Test-LdoKqlSyntax: file not found: $p" }
                $sources.Add([pscustomobject]@{ Label = $p; Text = (Get-Content -Raw $p) })
            }
        }
        else {
            $i = 0
            foreach ($q in $Query) {
                $label = if ($Query.Count -gt 1) { "$SourceLabel[$i]" } else { $SourceLabel }
                $sources.Add([pscustomobject]@{ Label = $label; Text = $q })
                $i++
            }
        }
    }

    end {
        foreach ($s in $sources) {
            $code = [Kusto.Language.KustoCode]::Parse($s.Text)
            foreach ($d in @($code.GetDiagnostics())) {
                $item = [pscustomobject]@{
                    Source   = $s.Label
                    Severity = "$($d.Severity)"
                    Code     = $d.Code
                    Position = $d.Start
                    Message  = $d.Message
                }
                $all.Add($item)
                if ($item.Severity -eq 'Error') {
                    $errorCount++
                    Write-LdoLog -Level ERROR -Message "KQL syntax: $($s.Label): $($d.Message) ($($d.Code) at position $($d.Start))"
                }
                else {
                    Write-LdoLog -Level WARN -Message "KQL $($item.Severity.ToLower()): $($s.Label): $($d.Message) ($($d.Code) at position $($d.Start))"
                }
            }
        }

        if ($errorCount -eq 0) {
            Write-LdoLog -Level INFO -Message "KQL syntax: $($sources.Count) quer$(if ($sources.Count -eq 1) { 'y' } else { 'ies' }) parsed clean."
        }

        if ($PassThru) { return $all }
        return ($errorCount -eq 0)
    }
}

function Test-LdoDefenderHuntingQuery {
    <#
    .SYNOPSIS
        Validates a KQL query against the tenant's real advanced hunting schema.

    .DESCRIPTION
        Executes the query through Invoke-LdoDefenderHuntingQuery and reports pass or
        fail: a 400 from the service means the query references tables or columns the
        tenant's schema does not have (or is otherwise invalid), which offline parsing
        cannot know. The query runs verbatim by default; -AppendTake adds a trailing
        "| take 1" for queries that tolerate it (deliberately opt in, because appending
        an operator can interact badly with a query that already ends in one).

    .PARAMETER Query
        The KQL query to validate.

    .PARAMETER Timespan
        ISO 8601 lookback for the validation run. Defaults to PT1H: validation needs
        schema soundness, not data, so the scanned window stays minimal.

    .PARAMETER ApiVersion
        Graph API version. Defaults to v1.0.

    .PARAMETER AppendTake
        Append a trailing "| take 1" to the query before running it.

    .PARAMETER SourceLabel
        Label used in log messages.

    .EXAMPLE
        Test-LdoDefenderHuntingQuery -Query $kql -SourceLabel 'rules/identity/burst.yaml'

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Query,
        [string]$Timespan = 'PT1H',
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'v1.0',
        [switch]$AppendTake,
        [string]$SourceLabel = 'query'
    )

    $effective = if ($AppendTake) { "$Query`n| take 1" } else { $Query }

    try {
        Invoke-LdoDefenderHuntingQuery -Query $effective -Timespan $Timespan -ApiVersion $ApiVersion | Out-Null
        Write-LdoLog -Level SUCCESS -Message "Hunting validation: $SourceLabel ran clean against the tenant schema."
        return $true
    }
    catch {
        $detail = try { Get-LdoGraphErrorDetail -ErrorRecord $_ } catch { $_.Exception.Message }
        Write-LdoLog -Level ERROR -Message "Hunting validation: $SourceLabel failed: $detail"
        return $false
    }
}

function ConvertFrom-LdoYaml {
    <#
    .SYNOPSIS
        Parses YAML into objects, preferring the yq binary with a powershell-yaml fallback.

    .DESCRIPTION
        Uses yq (present on GitHub hosted runners and most dev machines) to convert YAML
        to JSON and returns the parsed object; when yq is unavailable, installs and uses
        the powershell-yaml module instead. One code path for CI and local use.

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
        # Two unrelated tools ship as "yq": mikefarah's Go build (GitHub runners) wants
        # `yq eval -o=json`, while the kislyuk Python jq-wrapper wants plain `yq .` and emits
        # JSON by default. Detect the flavour once per call and speak the right dialect.
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

function Test-LdoDetectionRuleFile {
    <#
    .SYNOPSIS
        Validates one detection rule YAML file: parse, optional JSON Schema, KQL syntax,
        optional remote hunting run.

    .DESCRIPTION
        The per-file gate behind Invoke-LdoDetectionGate. The file must parse as YAML;
        when a schema is supplied it must satisfy it (Test-Json); its query must parse
        as KQL offline; and with -Remote it must also run clean against the tenant's
        advanced hunting schema. Every failure is logged with the file named; the result
        is a single boolean.

    .PARAMETER Path
        The rule YAML file.

    .PARAMETER SchemaPath
        Optional JSON Schema file (for example the terraform module's
        schema/custom-detection.schema.json).

    .PARAMETER Remote
        Also run the query against the tenant via runHuntingQuery
        (needs ThreatHunting.Read.All).

    .PARAMETER Timespan
        Lookback for the remote run. Defaults to PT1H.

    .PARAMETER HuntingApiVersion
        Graph API version for the remote run. Defaults to v1.0.

    .PARAMETER AppendTake
        Append "| take 1" to the remote validation query (opt in).

    .EXAMPLE
        Test-LdoDetectionRuleFile -Path ./custom-detections/identity/burst.yaml -SchemaPath ./schema/custom-detection.schema.json

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [string]$SchemaPath,
        [switch]$Remote,
        [string]$Timespan = 'PT1H',
        [ValidateSet('v1.0', 'beta')][string]$HuntingApiVersion = 'v1.0',
        [switch]$AppendTake
    )

    if (-not (Test-Path $Path)) { throw "Test-LdoDetectionRuleFile: file not found: $Path" }
    if ($SchemaPath -and -not (Test-Path $SchemaPath)) { throw "Test-LdoDetectionRuleFile: schema file not found: $SchemaPath" }

    $ok = $true

    try {
        $rule = ConvertFrom-LdoYaml -Path $Path
    }
    catch {
        Write-LdoLog -Level ERROR -Message "Detection rule: ${Path}: not parseable as YAML: $($_.Exception.Message)"
        return $false
    }

    if ($SchemaPath) {
        $json = $rule | ConvertTo-Json -Depth 100
        $schemaErrors = @()
        $valid = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
        if (-not $valid) {
            $ok = $false
            foreach ($e in $schemaErrors) {
                Write-LdoLog -Level ERROR -Message "Detection rule: ${Path}: schema violation: $($e.Exception.Message)"
            }
        }
    }

    # Property access under StrictMode must tolerate both hashtables (powershell-yaml)
    # and PSCustomObjects (yq path), and a missing query key.
    $query = $null
    if ($rule -is [System.Collections.IDictionary]) {
        if ($rule.Contains('query')) { $query = $rule['query'] }
    }
    elseif ($rule -and $rule.PSObject.Properties['query']) {
        $query = $rule.PSObject.Properties['query'].Value
    }

    if (-not $query) {
        Write-LdoLog -Level ERROR -Message "Detection rule: ${Path}: no query attribute found."
        return $false
    }

    if (-not (Test-LdoKqlSyntax -Query $query -SourceLabel $Path)) {
        $ok = $false
    }
    elseif ($Remote) {
        if (-not (Test-LdoDefenderHuntingQuery -Query $query -Timespan $Timespan -ApiVersion $HuntingApiVersion -AppendTake:$AppendTake -SourceLabel $Path)) {
            $ok = $false
        }
    }

    return $ok
}

function Invoke-LdoDetectionGate {
    <#
    .SYNOPSIS
        Gates a directory of detection rule YAML files: schema, KQL syntax, and
        optionally the tenant's real hunting schema.

    .DESCRIPTION
        Walks every *.yaml / *.yml under the path (the analyst authored
        custom-detections/<category>/ layout), runs Test-LdoDetectionRuleFile on each,
        records a finding per file, and throws when any file fails, so CI blocks the
        change. This is the pull request rung of the detection validation ladder; the
        Terraform module repeats the field validation at plan and the remote validation
        in graph at apply.

    .PARAMETER Path
        Directory containing the rule files.

    .PARAMETER SchemaPath
        Optional JSON Schema applied to every file.

    .PARAMETER Remote
        Also run each query against the tenant via runHuntingQuery
        (needs ThreatHunting.Read.All).

    .PARAMETER Timespan
        Lookback for remote runs. Defaults to PT1H.

    .PARAMETER HuntingApiVersion
        Graph API version for remote runs. Defaults to v1.0.

    .PARAMETER AppendTake
        Append "| take 1" to remote validation queries (opt in).

    .PARAMETER SoftFail
        Log failures as warnings instead of throwing.

    .EXAMPLE
        Invoke-LdoDetectionGate -Path ./custom-detections -SchemaPath ./schema/custom-detection.schema.json

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [string]$SchemaPath,
        [switch]$Remote,
        [string]$Timespan = 'PT1H',
        [ValidateSet('v1.0', 'beta')][string]$HuntingApiVersion = 'v1.0',
        [switch]$AppendTake,
        [switch]$SoftFail
    )

    if (-not (Test-Path $Path)) { throw "Invoke-LdoDetectionGate: path not found: $Path" }

    $files = @(Get-ChildItem -Path $Path -Recurse -File | Where-Object { $_.Extension -in '.yaml', '.yml' } | Sort-Object FullName)
    if ($files.Count -eq 0) {
        Write-LdoLog -Level WARN -Message "Detection gate: no YAML rule files under $Path; nothing to validate."
        return
    }

    $failed = 0
    foreach ($f in $files) {
        $pass = Test-LdoDetectionRuleFile -Path $f.FullName -SchemaPath $SchemaPath -Remote:$Remote `
            -Timespan $Timespan -HuntingApiVersion $HuntingApiVersion -AppendTake:$AppendTake
        $status = if ($pass) { 'PASS' } else { $failed++; 'FAIL' }
        Add-LdoFinding -Tool 'detection-gate' -Target $f.FullName -Status $status `
            -Summary $(if ($pass) { 'schema + KQL clean' } else { 'validation failed (see log)' })
    }

    if ($failed -gt 0) {
        $message = "Detection gate: $failed of $($files.Count) rule file(s) failed validation."
        if ($SoftFail) {
            Write-LdoLog -Level WARN -Message "$message Continuing because SoftFail is set."
            return
        }
        throw $message
    }

    Write-LdoLog -Level SUCCESS -Message "Detection gate: all $($files.Count) rule file(s) passed."
}
