Set-StrictMode -Version Latest

# -------------------------------------------------------------------------------------------------
# Basic Splunk primitives. UNTESTED AGAINST A LIVE SPLUNK INSTANCE: these wrap the two most common,
# well-documented Splunk REST surfaces (the HTTP Event Collector for sending events, and the search
# jobs API for running searches) using only stable, long-standing endpoints. They are deliberately
# small and conservative. Validate against your Splunk deployment before relying on them; treat the
# tokens they take as secrets (pass from a Key Vault data source or an environment variable, never a
# literal in source).
# -------------------------------------------------------------------------------------------------

function Send-LdoSplunkHecEvent {
    <#
    .SYNOPSIS
        Sends one or more events to a Splunk HTTP Event Collector (HEC).

    .DESCRIPTION
        POSTs to the HEC /services/collector/event endpoint with the HEC token in the Authorization
        header (Splunk <token>). Each event is wrapped in the HEC envelope with its optional
        sourcetype, source, index and host. Retries transient failures through the shared retry
        helper. UNTESTED LIVE: verify against your HEC configuration (token, allowed indexes, and
        whether the endpoint is /event or /raw for your data).

    .PARAMETER Uri
        The HEC collector base URI, for example https://splunk.example.com:8088. The
        /services/collector/event path is appended.

    .PARAMETER Token
        The HEC token (a secret). Sent as the Authorization header value "Splunk <token>".

    .PARAMETER Event
        One or more event payloads. A string is sent as the event field; an object is sent as-is.

    .PARAMETER Sourcetype
        Optional HEC sourcetype for every event in the call.

    .PARAMETER Source
        Optional HEC source.

    .PARAMETER Index
        Optional target index.

    .PARAMETER Host
        Optional host field.

    .PARAMETER SkipCertificateCheck
        Skip TLS validation (self-signed lab HEC only; never in production).

    .PARAMETER MaxRetries
        Maximum attempts. Defaults to 5.

    .EXAMPLE
        Send-LdoSplunkHecEvent -Uri 'https://splunk:8088' -Token $t -Event @{ action = 'login'; user = 'alice' } -Sourcetype '_json'

    .OUTPUTS
        System.Object. The HEC response (typically { text = 'Success'; code = 0 }).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Uri,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Token,
        [Parameter(Mandatory, ValueFromPipeline)][ValidateNotNull()][object[]]$Event,
        [string]$Sourcetype,
        [string]$Source,
        [string]$Index,
        [string]$HostName,
        [switch]$SkipCertificateCheck,
        [int]$MaxRetries = 5
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($e in $Event) { $collected.Add($e) }
    }

    end {
        if ($collected.Count -eq 0) { throw 'Send-LdoSplunkHecEvent: no events to send.' }

        # One newline-delimited body of HEC envelopes, the documented batch shape.
        $envelopes = foreach ($e in $collected) {
            $env = [ordered]@{ event = $e }
            if ($Sourcetype) { $env.sourcetype = $Sourcetype }
            if ($Source) { $env.source = $Source }
            if ($Index) { $env.index = $Index }
            if ($HostName) { $env.host = $HostName }
            $env | ConvertTo-Json -Depth 20 -Compress
        }
        $body = ($envelopes -join "`n")

        $endpoint = "$($Uri.TrimEnd('/'))/services/collector/event"
        $headers = @{ Authorization = "Splunk $Token" }
        $rest = @{
            Uri         = $endpoint
            Method      = 'Post'
            Headers     = $headers
            Body        = $body
            ContentType = 'application/json'
        }
        if ($SkipCertificateCheck) { $rest.SkipCertificateCheck = $true }

        Write-LdoLog -Level INFO -Message "Sending $($collected.Count) event(s) to Splunk HEC at $endpoint."
        Invoke-LdoWithRetry -OperationName "Splunk HEC POST $endpoint" -MaxRetries $MaxRetries -ScriptBlock {
            Invoke-RestMethod @rest
        }
    }
}

function Invoke-LdoSplunkSearch {
    <#
    .SYNOPSIS
        Runs a Splunk search (a blocking search job) and returns the results.

    .DESCRIPTION
        Creates a oneshot search job against the Splunk search jobs REST endpoint
        (/services/search/jobs) with output_mode=json, which runs the search and returns the
        results in a single call, and returns the parsed results. Authenticates with a bearer token
        (a Splunk auth token or session key). UNTESTED LIVE: verify the endpoint, the token type your
        deployment expects, and that the search language and app context match your Splunk.

    .PARAMETER Uri
        The Splunk management URI, for example https://splunk.example.com:8089.

    .PARAMETER Token
        The Splunk authentication token (a secret), sent as "Bearer <token>".

    .PARAMETER Search
        The SPL search string. A leading "search" is added when the query does not already begin
        with a generating command.

    .PARAMETER EarliestTime
        Optional earliest time modifier (for example -24h, or an absolute time).

    .PARAMETER LatestTime
        Optional latest time modifier (for example now).

    .PARAMETER MaxCount
        Maximum result rows. Defaults to 100.

    .PARAMETER SkipCertificateCheck
        Skip TLS validation (self-signed lab only).

    .PARAMETER MaxRetries
        Maximum attempts. Defaults to 5.

    .EXAMPLE
        Invoke-LdoSplunkSearch -Uri 'https://splunk:8089' -Token $t -Search 'index=main error' -EarliestTime '-1h'

    .OUTPUTS
        System.Object[]. The search result rows.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Uri,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Token,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Search,
        [string]$EarliestTime,
        [string]$LatestTime,
        [int]$MaxCount = 100,
        [switch]$SkipCertificateCheck,
        [int]$MaxRetries = 5
    )

    # Splunk requires the search to start with a search command; prepend "search" unless the query
    # already starts with a generating or explicit command (| or "search").
    $spl = $Search.TrimStart()
    if (-not ($spl -match '^\s*(search\b|\|)')) { $spl = "search $spl" }

    $form = @{
        search      = $spl
        output_mode = 'json'
        exec_mode   = 'oneshot'
        count       = $MaxCount
    }
    if ($EarliestTime) { $form.earliest_time = $EarliestTime }
    if ($LatestTime) { $form.latest_time = $LatestTime }

    $endpoint = "$($Uri.TrimEnd('/'))/services/search/jobs"
    $rest = @{
        Uri     = $endpoint
        Method  = 'Post'
        Headers = @{ Authorization = "Bearer $Token" }
        Body    = $form
    }
    if ($SkipCertificateCheck) { $rest.SkipCertificateCheck = $true }

    Write-LdoLog -Level INFO -Message "Running Splunk oneshot search against $endpoint."
    $response = Invoke-LdoWithRetry -OperationName "Splunk search POST $endpoint" -MaxRetries $MaxRetries -ScriptBlock {
        Invoke-RestMethod @rest
    }

    # A oneshot json response carries the rows under .results; guard for an empty or shapeless
    # response so callers always get an array.
    if ($response -and $response.PSObject.Properties['results']) {
        return @($response.results)
    }
    return @()
}

function Test-LdoSplunkConnection {
    <#
    .SYNOPSIS
        Checks reachability and authentication against a Splunk management endpoint.

    .DESCRIPTION
        GETs /services/server/info with the supplied token and returns true when the call succeeds.
        A cheap liveness and auth check before running searches. UNTESTED LIVE.

    .PARAMETER Uri
        The Splunk management URI.

    .PARAMETER Token
        The Splunk authentication token (a secret), sent as "Bearer <token>".

    .PARAMETER SkipCertificateCheck
        Skip TLS validation (self-signed lab only).

    .EXAMPLE
        Test-LdoSplunkConnection -Uri 'https://splunk:8089' -Token $t

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Uri,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Token,
        [switch]$SkipCertificateCheck
    )

    $endpoint = "$($Uri.TrimEnd('/'))/services/server/info?output_mode=json"
    $rest = @{
        Uri     = $endpoint
        Method  = 'Get'
        Headers = @{ Authorization = "Bearer $Token" }
    }
    if ($SkipCertificateCheck) { $rest.SkipCertificateCheck = $true }

    try {
        Invoke-RestMethod @rest | Out-Null
        Write-LdoLog -Level SUCCESS -Message "Splunk reachable and authenticated at $Uri."
        return $true
    }
    catch {
        Write-LdoLog -Level ERROR -Message "Splunk connection check failed for ${Uri}: $($_.Exception.Message)"
        return $false
    }
}
