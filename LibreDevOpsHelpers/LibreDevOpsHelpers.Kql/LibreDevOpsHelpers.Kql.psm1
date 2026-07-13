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

function ConvertTo-LdoCanonicalDetectionRule {
    <#
    .SYNOPSIS
        Normalises analyst supplied detection rule values to their canonical Graph spellings.

    .DESCRIPTION
        Mirrors the value normalisation the terraform-msgraph-xdr-custom-detection-rules module
        applies at plan time, so the CI schema gate and Terraform never disagree: keys stay strict,
        values are forgiving. status, severity and isolation_type lowercase; frequency and
        technique ids uppercase; tactics resolve case and separator insensitively to the canonical
        ATT&CK spelling (including the British DefenceEvasion to the API's DefenseEvasion). Values
        that match nothing are left untouched for the schema to reject with the canonical list.

    .PARAMETER Rule
        The parsed rule (a PSCustomObject tree, for example from ConvertFrom-Json). Mutated in
        place and returned.

    .OUTPUTS
        System.Object. The normalised rule.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]$Rule
    )

    $tactics = @{
        collection = 'Collection'; commandandcontrol = 'CommandAndControl'
        credentialaccess = 'CredentialAccess'; defenceevasion = 'DefenseEvasion'
        defenseevasion = 'DefenseEvasion'; discovery = 'Discovery'; execution = 'Execution'
        exfiltration = 'Exfiltration'; impact = 'Impact'; initialaccess = 'InitialAccess'
        lateralmovement = 'LateralMovement'; persistence = 'Persistence'
        privilegeescalation = 'PrivilegeEscalation'; reconnaissance = 'Reconnaissance'
        resourcedevelopment = 'ResourceDevelopment'
    }

    if ($Rule.PSObject.Properties['status'] -and $Rule.status -is [string]) {
        $Rule.status = $Rule.status.ToLowerInvariant()
    }
    if ($Rule.PSObject.Properties['frequency'] -and $Rule.frequency -is [string]) {
        $Rule.frequency = $Rule.frequency.ToUpperInvariant()
    }

    $alert = if ($Rule.PSObject.Properties['alert']) { $Rule.alert } else { $null }
    if ($alert -and $alert -is [pscustomobject]) {
        if ($alert.PSObject.Properties['severity'] -and $alert.severity -is [string]) {
            $alert.severity = $alert.severity.ToLowerInvariant()
        }
        if ($alert.PSObject.Properties['mitre'] -and $alert.mitre) {
            foreach ($m in @($alert.mitre)) {
                if ($m -isnot [pscustomobject]) { continue }
                if ($m.PSObject.Properties['tactic'] -and $m.tactic -is [string]) {
                    $keyed = ($m.tactic -replace '[ _-]', '').ToLowerInvariant()
                    if ($tactics.ContainsKey($keyed)) { $m.tactic = $tactics[$keyed] }
                }
                if ($m.PSObject.Properties['techniques'] -and $m.techniques) {
                    $m.techniques = @(foreach ($t in @($m.techniques)) {
                            if ($t -is [string]) { $t.ToUpperInvariant() }
                            else {
                                if ($t.PSObject.Properties['technique'] -and $t.technique -is [string]) {
                                    $t.technique = $t.technique.ToUpperInvariant()
                                }
                                if ($t.PSObject.Properties['sub_techniques'] -and $t.sub_techniques) {
                                    $t.sub_techniques = @(foreach ($st in @($t.sub_techniques)) {
                                            if ($st -is [string]) { $st.ToUpperInvariant() } else { $st }
                                        })
                                }
                                $t
                            }
                        })
                }
            }
        }
    }

    $actions = if ($Rule.PSObject.Properties['automated_actions']) { $Rule.automated_actions } else { $null }
    if ($actions -and $actions.PSObject.Properties['isolate_devices'] -and $actions.isolate_devices) {
        foreach ($a in @($actions.isolate_devices)) {
            if ($a -and $a.PSObject.Properties['isolation_type'] -and $a.isolation_type -is [string]) {
                $a.isolation_type = $a.isolation_type.ToLowerInvariant()
            }
        }
    }

    return $Rule
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
        # Round trip through JSON for a uniform PSCustomObject tree, then normalise values the same
        # way the Terraform module does, so this gate and the plan never disagree about case.
        $canonical = ($rule | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $canonical = ConvertTo-LdoCanonicalDetectionRule -Rule $canonical
        $json = $canonical | ConvertTo-Json -Depth 100
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

function Get-LdoCustomDetectionRule {
    <#
    .SYNOPSIS
        Lists or gets Microsoft Defender XDR custom detection rules through Microsoft Graph.

    .DESCRIPTION
        Wraps security/rules/detectionRules with the module's Graph auth and retry stack,
        following @odata.nextLink paging. On a 403 the log explains the two unlocks: app only
        callers need CustomDetection.Read.All or ReadWrite.All, and local Azure CLI callers need
        the tenant to admin consent the delegated CustomDetection permissions to the Azure CLI
        application (appId 04b07795-8ddb-461a-bbee-02f9e1bf7b46), since the CLI cannot request
        arbitrary Graph scopes itself.

    .PARAMETER Id
        Get a single rule by its id.

    .PARAMETER DisplayName
        Filter the listing to rules with this exact display name (client side).

    .PARAMETER ApiVersion
        Graph API version. Custom detection rules are beta only today, so beta is the default.

    .PARAMETER MaxRetries
        Maximum attempts per call. Defaults to 5.

    .EXAMPLE
        Get-LdoCustomDetectionRule

    .EXAMPLE
        Get-LdoCustomDetectionRule -DisplayName 'Mass file download by a single user'

    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$Id,
        [string]$DisplayName,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'beta',
        [int]$MaxRetries = 5
    )

    $base = "https://graph.microsoft.com/$ApiVersion/security/rules/detectionRules"

    try {
        if ($Id) {
            return @(Invoke-LdoGraphRequest -Uri "$base/$Id" -MaxRetries $MaxRetries)
        }

        $all = @()
        $uri = $base
        while ($uri) {
            $resp = Invoke-LdoGraphRequest -Uri $uri -MaxRetries $MaxRetries
            $all += @($resp.value)
            $uri = if ($resp.PSObject.Properties['@odata.nextLink']) { $resp.'@odata.nextLink' } else { $null }
        }
    }
    catch {
        if ("$_" -match '(?i)forbidden|missing application scopes|authorization') {
            Write-LdoLog -Level ERROR -Message ('Graph refused the detection rules call. App only callers need CustomDetection.Read.All or CustomDetection.ReadWrite.All. For local Azure CLI use, the tenant must admin consent the delegated CustomDetection permissions to the Azure CLI application (appId 04b07795-8ddb-461a-bbee-02f9e1bf7b46); the CLI cannot request those scopes itself.')
        }
        throw
    }

    if ($DisplayName) {
        $all = @($all | Where-Object { $_.displayName -eq $DisplayName })
    }

    Write-LdoLog -Level INFO -Message "Fetched $($all.Count) custom detection rule(s)."
    return $all
}

function Export-LdoCustomDetectionRule {
    <#
    .SYNOPSIS
        Exports Defender XDR custom detection rules into the analyst YAML layout of
        terraform-msgraph-xdr-custom-detection-rules.

    .DESCRIPTION
        The brownfield half of detections as code: every rule in the tenant becomes one YAML file
        under <OutDir>/<category>/, where the category folder is the kebab case of the rule's
        first ATT&CK tactic (uncategorised when it has none). Graph camelCase converts to the
        module's snake_case authoring schema; the SERVER ASSIGNED rule id is kept in the file on
        purpose, because the Terraform module uses the id as the rule key, so terraform import
        addresses and every later plan line up (new rules authored by hand should omit id).
        Legacy shape rules (category, mitreTechniques, impactedAssets, responseActions, schedule
        period strings) are converted best endeavours, with anything unconvertible emitted as a
        TODO comment inside the file rather than silently dropped.

    .PARAMETER OutDir
        Root of the custom-detections layout to write into (created if missing).

    .PARAMETER Id
        Export a single rule by id.

    .PARAMETER DisplayName
        Export only rules with this exact display name.

    .PARAMETER ApiVersion
        Graph API version. Defaults to beta.

    .PARAMETER Force
        Overwrite files that already exist.

    .PARAMETER Format
        Yaml (default) writes the analyst YAML files with provenance and TODO comments; Json
        writes the same snake_case spec as .json (comments cannot travel in JSON, so export notes
        go to the log). JSON files are a conversion convenience and are not picked up by the
        Terraform module, which reads .yaml/.yml only.

    .EXAMPLE
        Export-LdoCustomDetectionRule -OutDir ./custom-detections

    .EXAMPLE
        Export-LdoCustomDetectionRule -OutDir ./exported -Format Json

    .OUTPUTS
        System.IO.FileInfo[]
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutDir,
        [string]$Id,
        [string]$DisplayName,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'beta',
        [switch]$Force,
        [ValidateSet('Yaml', 'Json')][string]$Format = 'Yaml'
    )

    $rules = Get-LdoCustomDetectionRule -Id $Id -DisplayName $DisplayName -ApiVersion $ApiVersion
    if (-not $rules) {
        Write-LdoLog -Level WARN -Message 'No custom detection rules to export.'
        return @()
    }

    $legacyPeriodMap = @{ '0' = 'PT0S'; '1H' = 'PT1H'; '3H' = 'PT3H'; '12H' = 'PT12H'; '24H' = 'PT24H' }
    $tactics = @(
        'Reconnaissance', 'ResourceDevelopment', 'InitialAccess', 'Execution', 'Persistence',
        'PrivilegeEscalation', 'DefenseEvasion', 'CredentialAccess', 'Discovery', 'LateralMovement',
        'Collection', 'CommandAndControl', 'Exfiltration', 'Impact'
    )
    $groupNames = @{
        accounts = 'accounts'; amazonResources = 'amazon_resources'; azureResources = 'azure_resources'
        cloudApplications = 'cloud_applications'; dns = 'dns'; files = 'files'
        googleCloudResources = 'google_cloud_resources'; hosts = 'hosts'; ips = 'ips'
        mailClusters = 'mail_clusters'; mailMessages = 'mail_messages'; mailboxes = 'mailboxes'
        oAuthApplications = 'oauth_applications'; processes = 'processes'
        registryValues = 'registry_values'; securityGroups = 'security_groups'; urls = 'urls'
    }
    $actionNames = @{
        allowFiles = 'allow_files'; blockFiles = 'block_files'
        collectInvestigationPackages = 'collect_investigation_packages'; disableUsers = 'disable_users'
        forceUserPasswordResets = 'force_user_password_resets'; hardDeleteEmails = 'hard_delete_emails'
        initiateInvestigations = 'initiate_investigations'; isolateDevices = 'isolate_devices'
        markUsersAsCompromised = 'mark_users_as_compromised'
        moveEmailsToDeletedItems = 'move_emails_to_deleted_items'; moveEmailsToInbox = 'move_emails_to_inbox'
        moveEmailsToJunk = 'move_emails_to_junk'; restrictAppExecutions = 'restrict_app_executions'
        runAntivirusScans = 'run_antivirus_scans'; softDeleteEmails = 'soft_delete_emails'
        stopAndQuarantineFiles = 'stop_and_quarantine_files'
    }

    function ConvertTo-SnakeKey {
        param([string]$Name)
        if ($Name -eq 'oAuthAppIdColumn') { return 'oauth_app_id_column' }
        return ([regex]::Replace($Name, '(?<=[a-z0-9])([A-Z])', '_$1')).ToLowerInvariant()
    }

    function ConvertTo-SnakeItems {
        param($Items)
        $converted = @(foreach ($it in @($Items)) {
                $out = [ordered]@{}
                foreach ($p in $it.PSObject.Properties) {
                    if ($p.Name.StartsWith('@') -or $null -eq $p.Value -or "$($p.Value)" -eq '') { continue }
                    $out[(ConvertTo-SnakeKey -Name $p.Name)] = $p.Value
                }
                if ($out.Count -gt 0) { $out }
            })
        # The unary comma keeps single item results as arrays through the function return, so
        # mapping groups always emit as YAML sequences, never collapsed to a lone map.
        return , $converted
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $written = @()

    foreach ($rule in $rules) {
        $todos = @()
        $template = $rule.detectionAction.alertTemplate

        $spec = [ordered]@{}
        $spec.id = "$($rule.id)"
        $spec.display_name = $rule.displayName
        if ($rule.PSObject.Properties['description'] -and $rule.description) { $spec.description = $rule.description }

        $spec.status = if ($rule.PSObject.Properties['status'] -and $rule.status) { "$($rule.status)" }
        elseif ($rule.PSObject.Properties['isEnabled'] -and -not $rule.isEnabled) { 'disabled' } else { 'enabled' }

        $freq = if ($rule.schedule.PSObject.Properties['frequency'] -and $rule.schedule.frequency) { "$($rule.schedule.frequency)" } else { $null }
        if (-not $freq) {
            $period = if ($rule.schedule.PSObject.Properties['period']) { "$($rule.schedule.period)" } else { '' }
            $freq = $legacyPeriodMap[$period]
            if (-not $freq) {
                $freq = 'PT24H'
                $todos += "legacy schedule period '$period' has no mapping; defaulted to PT24H, review."
            }
        }
        $spec.frequency = $freq
        $spec.query = $rule.queryCondition.queryText

        $alert = [ordered]@{}
        if ($template.PSObject.Properties['title'] -and $template.title) { $alert.title = $template.title }
        if ($template.PSObject.Properties['description'] -and $template.description) { $alert.description = $template.description }
        $alert.severity = "$($template.severity)"
        if ($template.PSObject.Properties['recommendedActions'] -and $template.recommendedActions) {
            $alert.recommended_actions = $template.recommendedActions
        }

        $mitre = @()
        if ($template.PSObject.Properties['tactics'] -and $template.tactics) {
            foreach ($t in @($template.tactics)) {
                $entry = [ordered]@{ tactic = "$($t.tactic)" }
                if ($t.PSObject.Properties['techniques'] -and $t.techniques) {
                    $entry.techniques = @(foreach ($q in @($t.techniques)) {
                            if ($q.PSObject.Properties['subTechniques'] -and $q.subTechniques) {
                                [ordered]@{ technique = "$($q.technique)"; sub_techniques = @($q.subTechniques) }
                            }
                            else { "$($q.technique)" }
                        })
                }
                $mitre += , $entry
            }
        }
        elseif ($template.PSObject.Properties['category'] -and $template.category) {
            $legacyTechniques = if ($template.PSObject.Properties['mitreTechniques']) { @($template.mitreTechniques) } else { @() }
            if ($tactics -contains "$($template.category)") {
                $entry = [ordered]@{ tactic = "$($template.category)" }
                if ($legacyTechniques.Count -gt 0) { $entry.techniques = $legacyTechniques }
                $mitre += , $entry
            }
            else {
                $todos += "legacy category '$($template.category)' is not an ATT&CK tactic; techniques not carried: $($legacyTechniques -join ', ')."
            }
        }
        if ($mitre.Count -gt 0) { $alert.mitre = $mitre }

        if ($template.PSObject.Properties['customDetails'] -and $template.customDetails) {
            $details = [ordered]@{}
            foreach ($p in $template.customDetails.PSObject.Properties) {
                if (-not $p.Name.StartsWith('@')) { $details[$p.Name] = $p.Value }
            }
            if ($details.Count -gt 0) { $alert.custom_details = $details }
        }

        if ($template.PSObject.Properties['entityMappings'] -and $template.entityMappings) {
            $mappings = [ordered]@{}
            foreach ($p in $template.entityMappings.PSObject.Properties) {
                if ($p.Name.StartsWith('@') -or $null -eq $p.Value) { continue }
                $snakeGroup = if ($groupNames.ContainsKey($p.Name)) { $groupNames[$p.Name] } else { ConvertTo-SnakeKey -Name $p.Name }
                $items = ConvertTo-SnakeItems -Items $p.Value
                if ($items.Count -gt 0) { $mappings[$snakeGroup] = $items }
            }
            if ($mappings.Count -gt 0) { $alert.entity_mappings = $mappings }
        }
        elseif ($template.PSObject.Properties['impactedAssets'] -and $template.impactedAssets) {
            $todos += "legacy impactedAssets not converted (the module uses entity_mappings); review: $((@($template.impactedAssets) | ForEach-Object { $_.'@odata.type' }) -join ', ')."
        }

        $spec.alert = $alert

        $scope = if ($rule.detectionAction.PSObject.Properties['organizationalScope']) { $rule.detectionAction.organizationalScope } else { $null }
        if ($scope) {
            # Wrapped in @() because an if expression unrolls a single element output to a scalar.
            $groups = @(if ($scope.PSObject.Properties['deviceGroups'] -and $scope.deviceGroups) { $scope.deviceGroups }
                elseif ($scope.PSObject.Properties['scopeNames'] -and $scope.scopeNames) { $scope.scopeNames })
            if ($groups.Count -gt 0) { $spec.device_groups = $groups }
        }

        if ($rule.detectionAction.PSObject.Properties['automatedActions'] -and $rule.detectionAction.automatedActions) {
            $actions = [ordered]@{}
            foreach ($p in $rule.detectionAction.automatedActions.PSObject.Properties) {
                if ($p.Name.StartsWith('@') -or $null -eq $p.Value -or @($p.Value).Count -eq 0) { continue }
                $snakeAction = if ($actionNames.ContainsKey($p.Name)) { $actionNames[$p.Name] } else { ConvertTo-SnakeKey -Name $p.Name }
                $items = ConvertTo-SnakeItems -Items $p.Value
                if ($items.Count -gt 0) { $actions[$snakeAction] = $items }
            }
            if ($actions.Count -gt 0) {
                $spec.automated_actions = $actions
                $todos += 'rule carries automated_actions: the module call needs allow_automated_actions = true.'
            }
        }
        elseif ($rule.detectionAction.PSObject.Properties['responseActions'] -and $rule.detectionAction.responseActions) {
            $todos += 'legacy responseActions not converted (the module uses automated_actions); review the original rule.'
        }

        $category = 'uncategorised'
        if ($mitre.Count -gt 0) {
            $category = ([regex]::Replace("$($mitre[0].tactic)", '(?<=[a-z0-9])([A-Z])', '-$1')).ToLowerInvariant()
        }

        $slug = ($rule.displayName -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
        if (-not $slug) { $slug = "rule-$($rule.id)" }

        $dir = Join-Path $OutDir $category
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $ext = if ($Format -eq 'Json') { 'json' } else { 'yaml' }
        $file = Join-Path $dir "$slug.$ext"

        if ((Test-Path $file) -and -not $Force) {
            Write-LdoLog -Level WARN -Message "Skipping existing file $file (use -Force to overwrite)."
            continue
        }

        if ($Format -eq 'Json') {
            # JSON carries no comments, so export notes go to the log instead of the file.
            foreach ($t in $todos) { Write-LdoLog -Level WARN -Message "Export note for ${file}: $t" }
            Set-Content -Path $file -Value ($spec | ConvertTo-Json -Depth 100)
            Write-LdoLog -Level SUCCESS -Message "Exported '$($rule.displayName)' to $file"
            $written += Get-Item $file
            continue
        }

        $header = @(
            '# yaml-language-server: $schema=https://raw.githubusercontent.com/libre-devops/terraform-msgraph-xdr-custom-detection-rules/main/schema/custom-detection.schema.json'
            '#'
            "# Exported from Microsoft Defender XDR by Export-LdoCustomDetectionRule on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))Z."
            '# The id is the server assigned rule id, kept on purpose: the Terraform module keys rules by'
            '# id, so terraform import addresses and later plans line up. New rules authored by hand'
            '# should omit id. Review this file before committing.'
        )
        foreach ($t in $todos) { $header += "# TODO(export): $t" }

        $yaml = ($header -join "`n") + "`n" + (ConvertTo-LdoYaml -InputObject $spec)
        Set-Content -Path $file -Value $yaml -NoNewline
        Write-LdoLog -Level SUCCESS -Message "Exported '$($rule.displayName)' to $file"
        $written += Get-Item $file
    }

    Write-LdoLog -Level INFO -Message "Exported $($written.Count) of $(@($rules).Count) rule(s) to $OutDir."
    return $written
}
