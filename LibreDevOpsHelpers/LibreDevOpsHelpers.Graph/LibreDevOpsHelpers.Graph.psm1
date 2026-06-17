# Retry, token and request helpers for Microsoft Graph and other Azure REST APIs.
# These assume an active Az context is already established (Connect-AzAccount or a
# Managed Identity login) before any token is requested.

# Per-resource token cache. Keyed by resource URL so a script can hold tokens for
# more than one audience at once.
$script:GraphTokenCache = @{ }

function Get-HttpStatusFromError {
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

function Get-RetryAfterSeconds {
    param($ErrorRecord)

    $response = $null
    if ($ErrorRecord.Exception.PSObject.Properties['Response']) {
        $response = $ErrorRecord.Exception.Response
    }
    if (-not $response) { return $null }

    # HttpResponseHeaders has no string indexer, so TryGetValues is the supported
    # way to read a header. Indexing it directly throws and hides the real error.
    try {
        $values = $null
        if ($response.Headers -and $response.Headers.TryGetValues('Retry-After', [ref]$values)) {
            $first = @($values)[0]
            $seconds = 0
            if ([int]::TryParse($first, [ref]$seconds)) { return [double]$seconds }
        }
    } catch { }
    return $null
}

function Get-GraphErrorDetail {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)

    $status = Get-HttpStatusFromError -ErrorRecord $ErrorRecord
    $statusText = if ($status -gt 0) { "HTTP $status" } else { 'No HTTP response' }

    # In PowerShell 7 the real Graph error body (error.code and error.message) is on
    # $_.ErrorDetails.Message, not $_.Exception.Message which only carries the generic
    # status line.
    $body = $ErrorRecord.ErrorDetails.Message
    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json
            if ($parsed.PSObject.Properties['error'] -and $parsed.error) {
                return "$statusText | $($parsed.error.code): $($parsed.error.message)"
            }
        } catch { }
        return "$statusText | $body"
    }

    return "$statusText | $($ErrorRecord.Exception.Message)"
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = 'operation',
        [int]$MaxRetries = 5,
        [double]$InitialDelaySeconds = 2,
        [double]$MaxDelaySeconds = 60,
        [int[]]$RetryStatusCodes = @(408, 429, 500, 502, 503, 504),
        [scriptblock]$OnRetry
    )

    if ($MaxRetries -lt 1) { $MaxRetries = 1 }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $err = $_
            $status = Get-HttpStatusFromError -ErrorRecord $err
            $detail = Get-GraphErrorDetail -ErrorRecord $err

            # A request with no HTTP response is a transport or DNS failure, which is
            # worth retrying. A request with a response is only retried when the status
            # is in the configured list, so a 400 or 403 fails fast instead of looping.
            $hasResponse = $status -gt 0
            $isRetryable = (-not $hasResponse) -or ($RetryStatusCodes -contains $status)

            if (-not $isRetryable -or $attempt -ge $MaxRetries) {
                _LogMessage -Level ERROR -Message "'$OperationName' failed on attempt $attempt of $($MaxRetries): $detail" -InvocationName $MyInvocation.MyCommand.Name
                throw
            }

            # Exponential backoff with a cap, honouring Retry-After when the server
            # sends it, plus a little jitter to avoid synchronised retries.
            $delay = [math]::Min($MaxDelaySeconds, $InitialDelaySeconds * [math]::Pow(2, $attempt - 1))
            $retryAfter = Get-RetryAfterSeconds -ErrorRecord $err
            if ($null -ne $retryAfter) { $delay = [math]::Min($MaxDelaySeconds, $retryAfter) }
            $delay = $delay + (Get-Random -Minimum 0.0 -Maximum 1.0)

            if ($OnRetry) {
                try { & $OnRetry $err $attempt } catch { }
            }

            _LogMessage -Level WARN -Message "Attempt $attempt of $MaxRetries for '$OperationName' failed, retrying in $([math]::Round($delay, 1))s: $detail" -InvocationName $MyInvocation.MyCommand.Name
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-GraphToken {
    [CmdletBinding()]
    param(
        [string]$Resource = 'https://graph.microsoft.com',
        [int]$RefreshMarginMinutes = 5,
        [switch]$Force
    )

    $now = [datetimeoffset]::UtcNow
    $cached = $script:GraphTokenCache[$Resource]

    if (-not $Force -and $cached -and $now -lt $cached.ExpiresOn.AddMinutes(-1 * $RefreshMarginMinutes)) {
        return $cached.Token
    }

    $action = if ($Force) { 'Force-refreshing' } else { 'Acquiring' }
    _LogMessage -Level INFO -Message "$action access token for $Resource" -InvocationName $MyInvocation.MyCommand.Name

    $response = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop
    if (-not $response -or -not $response.Token) {
        throw "Token request for '$Resource' returned no token. Is there an active Az context?"
    }

    # .Token is a plaintext string on Az.Accounts 2.x and a SecureString from 5.x
    # onward (where -AsSecureString became the default). Handle both so a module
    # upgrade cannot silently turn the token into the literal type name.
    $raw = $response.Token
    $token = if ($raw -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $raw).Password
    } else {
        [string]$raw
    }

    if ([string]::IsNullOrWhiteSpace($token) -or $token -eq 'System.Security.SecureString') {
        throw "Token extraction for '$Resource' produced an empty or unconverted value. Check the Az.Accounts module version."
    }

    $expiresOn = if ($response.ExpiresOn) { [datetimeoffset]$response.ExpiresOn } else { $now.AddMinutes(50) }
    $script:GraphTokenCache[$Resource] = [pscustomobject]@{ Token = $token; ExpiresOn = $expiresOn }

    _LogMessage -Level INFO -Message "Token for $Resource ready, expires $($expiresOn.ToString('u'))" -InvocationName $MyInvocation.MyCommand.Name
    return $token
}

function Clear-GraphTokenCache {
    [CmdletBinding()]
    param([string]$Resource)

    if ($Resource) {
        $script:GraphTokenCache.Remove($Resource) | Out-Null
    } else {
        $script:GraphTokenCache = @{ }
    }
}

function Invoke-GraphRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Microsoft.PowerShell.Commands.WebRequestMethod]$Method = 'Get',
        $Body,
        [hashtable]$Headers,
        [string]$Resource = 'https://graph.microsoft.com',
        [string]$ContentType = 'application/json',
        [int]$MaxRetries = 5
    )

    # The token is read inside the scriptblock on every attempt, so a forced refresh
    # after a 401 is picked up on the retry without rebuilding anything.
    $invoke = {
        $requestHeaders = @{ Authorization = "Bearer $(Get-GraphToken -Resource $Resource)" }
        if ($Headers) {
            foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
        }

        $params = @{
            Method      = $Method
            Uri         = $Uri
            Headers     = $requestHeaders
            ErrorAction = 'Stop'
        }
        if ($null -ne $Body) {
            $params['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
            $params['ContentType'] = $ContentType
        }

        Invoke-RestMethod @params
    }

    try {
        return Invoke-WithRetry -ScriptBlock $invoke -OperationName "Graph $Method $Uri" -MaxRetries $MaxRetries
    }
    catch {
        # 401 is handled once here rather than in the retry list, so a genuine auth
        # failure does not loop: refresh the token and try the request a second time.
        if ((Get-HttpStatusFromError -ErrorRecord $_) -eq 401) {
            _LogMessage -Level WARN -Message "401 from Graph, refreshing token and retrying once: $Uri" -InvocationName $MyInvocation.MyCommand.Name
            Get-GraphToken -Resource $Resource -Force | Out-Null
            return Invoke-WithRetry -ScriptBlock $invoke -OperationName "Graph $Method $Uri (post-401)" -MaxRetries $MaxRetries
        }
        throw
    }
}

Export-ModuleMember -Function `
    Invoke-WithRetry, `
    Get-GraphErrorDetail, `
    Get-GraphToken, `
    Clear-GraphTokenCache, `
    Invoke-GraphRequest
