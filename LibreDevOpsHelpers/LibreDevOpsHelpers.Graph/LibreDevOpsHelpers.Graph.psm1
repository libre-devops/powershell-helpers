Set-StrictMode -Version Latest

# Retry, token and request helpers for Microsoft Graph and other Azure REST APIs.
# These assume an active Az context is already established (Connect-AzAccount or a
# managed identity login) before any token is requested.

# Per-resource token cache. Keyed by resource URL so a script can hold tokens for
# more than one audience at once.
$script:LdoGraphTokenCache = @{ }

function Get-LdoHttpStatusFromError {
    # Internal. Returns the numeric HTTP status from an error record, or 0 when the
    # error carries no HTTP response (a transport or DNS failure).
    param($ErrorRecord)

    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) {
        $response = $ErrorRecord.Exception.Response
    }

    if ($response -and $response.PSObject.Properties['StatusCode']) {
        try { return [int]$response.StatusCode } catch { return 0 }
    }
    return 0
}

function Get-LdoRetryAfterSeconds {
    # Internal. Reads the Retry-After header (in seconds) from an error response, or
    # $null when absent. HttpResponseHeaders has no string indexer, so TryGetValues is
    # the supported access path; indexing it directly throws and hides the real error.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Returns a count of seconds; plural reads correctly.')]
    [CmdletBinding()]
    param($ErrorRecord)

    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) {
        $response = $ErrorRecord.Exception.Response
    }
    if (-not $response) { return $null }

    try {
        $values = $null
        if ($response.Headers -and $response.Headers.TryGetValues('Retry-After', [ref]$values)) {
            $first = @($values)[0]
            $seconds = 0
            if ([int]::TryParse($first, [ref]$seconds)) { return [double]$seconds }
        }
    }
    catch {
        Write-Debug "Could not read Retry-After header: $($_.Exception.Message)"
    }
    return $null
}

function Get-LdoGraphErrorDetail {
    <#
    .SYNOPSIS
        Extracts a readable status and message from a failed REST or Graph call.

    .DESCRIPTION
        In PowerShell 7 the useful Graph error body (error.code and error.message) is on
        $_.ErrorDetails.Message, not $_.Exception.Message which only carries the generic
        status line. This returns "HTTP <status> | <code>: <message>" when the body is a
        Graph error object, and falls back gracefully for non-Graph or transport errors.

    .PARAMETER ErrorRecord
        The error record from a failed call, typically $_ inside a catch block.

    .EXAMPLE
        try { Invoke-RestMethod ... } catch { Write-LdoLog -Level ERROR -Message (Get-LdoGraphErrorDetail $_) }

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        $ErrorRecord
    )

    $status = Get-LdoHttpStatusFromError -ErrorRecord $ErrorRecord
    $statusText = if ($status -gt 0) { "HTTP $status" } else { 'No HTTP response' }

    # ErrorDetails can be null; guard before reading .Message so StrictMode does not throw.
    $body = $null
    if ($ErrorRecord.ErrorDetails) { $body = $ErrorRecord.ErrorDetails.Message }
    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json
            if ($parsed.PSObject.Properties['error'] -and $parsed.error) {
                return "$statusText | $($parsed.error.code): $($parsed.error.message)"
            }
        }
        catch {
            Write-Debug 'Error body was not JSON, returning it verbatim.'
        }
        return "$statusText | $body"
    }

    return "$statusText | $($ErrorRecord.Exception.Message)"
}

function Invoke-LdoWithRetry {
    <#
    .SYNOPSIS
        Runs a script block with retries, exponential backoff and Retry-After support.

    .DESCRIPTION
        Retries the script block on transient failures: any error with no HTTP response
        (transport or DNS), or an HTTP status in RetryStatusCodes. Non-retryable errors
        such as 400 or 403 fail immediately rather than looping. Backoff is exponential
        with a cap and small jitter, and honours a server Retry-After header when present.

    .PARAMETER ScriptBlock
        The work to run. Its return value is passed back to the caller on success.

    .PARAMETER OperationName
        A label used in log messages to identify the operation.

    .PARAMETER MaxRetries
        Maximum number of attempts. Defaults to 5.

    .PARAMETER InitialDelaySeconds
        Base delay for the first backoff. Defaults to 2.

    .PARAMETER MaxDelaySeconds
        Upper bound on any single delay. Defaults to 60.

    .PARAMETER RetryStatusCodes
        HTTP status codes that are treated as transient. Defaults to 408, 429, 500, 502,
        503, 504.

    .PARAMETER OnRetry
        Optional script block invoked before each backoff, receiving the error record and
        the attempt number. Useful for side effects such as refreshing a token.

    .EXAMPLE
        Invoke-LdoWithRetry -OperationName 'list users' -ScriptBlock {
            Invoke-RestMethod -Uri $uri -Headers $headers
        }

    .OUTPUTS
        System.Object
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [string]$OperationName = 'operation',

        [ValidateRange(1, 100)]
        [int]$MaxRetries = 5,

        [double]$InitialDelaySeconds = 2,

        [double]$MaxDelaySeconds = 60,

        [int[]]$RetryStatusCodes = @(408, 429, 500, 502, 503, 504),

        [scriptblock]$OnRetry
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $err = $_
            $status = Get-LdoHttpStatusFromError -ErrorRecord $err
            $detail = Get-LdoGraphErrorDetail -ErrorRecord $err

            $hasResponse = $status -gt 0
            $isRetryable = (-not $hasResponse) -or ($RetryStatusCodes -contains $status)

            if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                Write-LdoLog -Level ERROR -Message "'$OperationName' failed on attempt $attempt of $($MaxRetries): $detail"
                throw
            }

            $delay = [math]::Min($MaxDelaySeconds, $InitialDelaySeconds * [math]::Pow(2, $attempt - 1))
            $retryAfter = Get-LdoRetryAfterSeconds -ErrorRecord $err
            if ($null -ne $retryAfter) { $delay = [math]::Min($MaxDelaySeconds, $retryAfter) }
            $delay = $delay + (Get-Random -Minimum 0.0 -Maximum 1.0)

            if ($OnRetry) {
                try { & $OnRetry $err $attempt } catch {
                    Write-Debug "OnRetry callback threw: $($_.Exception.Message)"
                }
            }

            Write-LdoLog -Level WARN -Message "Attempt $attempt of $MaxRetries for '$OperationName' failed, retrying in $([math]::Round($delay, 1))s: $detail"
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-LdoGraphToken {
    <#
    .SYNOPSIS
        Returns a Microsoft Graph (or other resource) access token, cached and refreshed.

    .DESCRIPTION
        Caches the token per resource and reuses it until it is within RefreshMarginMinutes
        of expiry, then transparently re-acquires it. Handles both a plaintext string and a
        SecureString .Token, so it works across Az.Accounts versions (SecureString became
        the default in 5.x). Requires an active Az context.

    .PARAMETER Resource
        The resource URL to request a token for. Defaults to Microsoft Graph.

    .PARAMETER RefreshMarginMinutes
        How long before expiry to refresh proactively. Defaults to 5.

    .PARAMETER Force
        Re-acquire the token even if the cached one is still valid.

    .EXAMPLE
        $token = Get-LdoGraphToken
        Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" }

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Resource = 'https://graph.microsoft.com',
        [int]$RefreshMarginMinutes = 5,
        [switch]$Force
    )

    $now = [datetimeoffset]::UtcNow
    $cached = $script:LdoGraphTokenCache[$Resource]

    if (-not $Force -and $cached -and $now -lt $cached.ExpiresOn.AddMinutes(-1 * $RefreshMarginMinutes)) {
        return $cached.Token
    }

    $action = if ($Force) { 'Force-refreshing' } else { 'Acquiring' }
    Write-LdoLog -Level INFO -Message "$action access token for $Resource"

    $response = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop
    if (-not $response -or -not $response.Token) {
        throw "Token request for '$Resource' returned no token. Is there an active Az context?"
    }

    $raw = $response.Token
    $token = if ($raw -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $raw).Password
    }
    else {
        [string]$raw
    }

    if ([string]::IsNullOrWhiteSpace($token) -or $token -eq 'System.Security.SecureString') {
        throw "Token extraction for '$Resource' produced an empty or unconverted value. Check the Az.Accounts module version."
    }

    $expiresOn = if ($response.ExpiresOn) { [datetimeoffset]$response.ExpiresOn } else { $now.AddMinutes(50) }
    $script:LdoGraphTokenCache[$Resource] = [pscustomobject]@{ Token = $token; ExpiresOn = $expiresOn }

    Write-LdoLog -Level INFO -Message "Token for $Resource ready, expires $($expiresOn.ToString('u'))"
    return $token
}

function Clear-LdoGraphTokenCache {
    <#
    .SYNOPSIS
        Clears the cached access token for one resource, or for all resources.

    .PARAMETER Resource
        The resource URL to clear. When omitted, the entire cache is cleared.

    .EXAMPLE
        Clear-LdoGraphTokenCache

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Resource
    )

    if ($Resource) {
        $script:LdoGraphTokenCache.Remove($Resource) | Out-Null
    }
    else {
        $script:LdoGraphTokenCache = @{ }
    }
}

function Invoke-LdoGraphRequest {
    <#
    .SYNOPSIS
        Invokes a Microsoft Graph request with auth, retries and a 401 token refresh.

    .DESCRIPTION
        Wraps Invoke-RestMethod with a bearer token from Get-LdoGraphToken, retries
        transient failures through Invoke-LdoWithRetry, and on a 401 refreshes the token
        once and retries. The token is read on every attempt, so the refreshed token is
        used without rebuilding the request.

    .PARAMETER Uri
        The full request URI.

    .PARAMETER Method
        The HTTP method. Defaults to Get.

    .PARAMETER Body
        Optional request body. A string is sent as-is; any other object is converted to
        JSON.

    .PARAMETER Headers
        Optional additional headers, merged over the Authorization header.

    .PARAMETER Resource
        The token resource. Defaults to Microsoft Graph.

    .PARAMETER ContentType
        Content type used when a body is sent. Defaults to application/json.

    .PARAMETER MaxRetries
        Maximum attempts per call. Defaults to 5.

    .EXAMPLE
        Invoke-LdoGraphRequest -Uri 'https://graph.microsoft.com/v1.0/me'

    .EXAMPLE
        Invoke-LdoGraphRequest -Method Post -Uri $uri -Body @{ displayName = 'Group' }

    .OUTPUTS
        System.Object
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Body, Headers and ContentType are consumed inside the $invoke script block closure.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Microsoft.PowerShell.Commands.WebRequestMethod]$Method = 'Get',

        $Body,

        [hashtable]$Headers,

        [string]$Resource = 'https://graph.microsoft.com',

        [string]$ContentType = 'application/json',

        [ValidateRange(1, 100)]
        [int]$MaxRetries = 5
    )

    $invoke = {
        $requestHeaders = @{ Authorization = "Bearer $(Get-LdoGraphToken -Resource $Resource)" }
        if ($Headers) {
            foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
        }

        $params = @{
            Method = $Method
            Uri = $Uri
            Headers = $requestHeaders
            ErrorAction = 'Stop'
        }
        if ($null -ne $Body) {
            $params['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
            $params['ContentType'] = $ContentType
        }

        Invoke-RestMethod @params
    }

    try {
        return Invoke-LdoWithRetry -ScriptBlock $invoke -OperationName "Graph $Method $Uri" -MaxRetries $MaxRetries
    }
    catch {
        if ((Get-LdoHttpStatusFromError -ErrorRecord $_) -eq 401) {
            Write-LdoLog -Level WARN -Message "401 from Graph, refreshing token and retrying once: $Uri"
            Get-LdoGraphToken -Resource $Resource -Force | Out-Null
            return Invoke-LdoWithRetry -ScriptBlock $invoke -OperationName "Graph $Method $Uri (post-401)" -MaxRetries $MaxRetries
        }
        throw
    }
}

Export-ModuleMember -Function `
    Invoke-LdoWithRetry, `
    Get-LdoGraphErrorDetail, `
    Get-LdoGraphToken, `
    Clear-LdoGraphTokenCache, `
    Invoke-LdoGraphRequest
