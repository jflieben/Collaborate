# Microsoft Graph access using the Function App's managed identity.
#
# We deliberately avoid the Microsoft.Graph SDK modules. Tokens come straight
# from the App Service managed-identity endpoint; Graph is called over REST.
#
# This file is the APPLICATION path (administration: invite, expire, block,
# delete). Anything a user shares goes through Obo.ps1 instead, with the user's
# own delegated token, so Graph enforces their real rights.

$script:CBTokenCache = @{}   # resource -> @{ Token = ...; ExpiresOn = [datetimeoffset] }

function Get-CBManagedIdentityToken {
    <#
    .SYNOPSIS
        Acquires an access token for a resource from the managed identity.
    .DESCRIPTION
        Uses the App Service / Functions identity endpoint (IDENTITY_ENDPOINT +
        IDENTITY_HEADER). Tokens are cached in-process until ~5 min before expiry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Resource)

    $cached = $script:CBTokenCache[$Resource]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        return $cached.Token
    }

    $endpoint = [Environment]::GetEnvironmentVariable('IDENTITY_ENDPOINT')
    $header   = [Environment]::GetEnvironmentVariable('IDENTITY_HEADER')
    if ([string]::IsNullOrWhiteSpace($endpoint) -or [string]::IsNullOrWhiteSpace($header)) {
        throw 'Managed identity is not available (IDENTITY_ENDPOINT / IDENTITY_HEADER missing). Ensure a system-assigned identity is enabled on the Function App.'
    }

    $uri = '{0}?resource={1}&api-version=2019-08-01' -f $endpoint, [Uri]::EscapeDataString($Resource)
    try {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $header } -ErrorAction Stop
    }
    catch {
        throw "Failed to acquire a managed-identity token for '$Resource': $($_.Exception.Message)"
    }

    $expiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_on)
    $script:CBTokenCache[$Resource] = @{ Token = $response.access_token; ExpiresOn = $expiresOn }
    return $response.access_token
}

function Get-CBGraphToken {
    [CmdletBinding()] param()
    return Get-CBManagedIdentityToken -Resource (Get-CBConfig).GraphResource
}

function Invoke-CBGraph {
    <#
    .SYNOPSIS
        Calls Microsoft Graph with managed-identity auth, paging and throttling
        handled.
    .PARAMETER Uri
        Absolute Graph URL, or a path relative to the API root (e.g. '/users').
    .PARAMETER AccessToken
        Use this token instead of the managed identity's. This is how the
        on-behalf-of path reuses all the paging/throttling logic below while
        acting as the signed-in user.
    .PARAMETER All
        Follow @odata.nextLink and return the concatenated 'value' collection.
    .PARAMETER Raw
        Return the HTTP response object instead of the parsed body (used to read
        status codes, e.g. distinguishing 404 from 200).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')][string]$Method = 'Get',
        $Body,
        [string]$AccessToken,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'v1.0',
        [switch]$All,
        [switch]$Raw,
        [int]$MaxRetries = 5
    )

    $cfg = Get-CBConfig
    if ($Uri -notmatch '^https?://') {
        $Uri = '{0}/{1}/{2}' -f $cfg.GraphResource, $ApiVersion, $Uri.TrimStart('/')
    }

    $results = [System.Collections.Generic.List[object]]::new()

    while ($true) {
        $token = if ($AccessToken) { $AccessToken } else { Get-CBGraphToken }
        $headers = @{
            Authorization    = "Bearer $token"
            'Content-Type'   = 'application/json'
            ConsistencyLevel = 'eventual'
        }

        $params = @{
            Method                  = $Method
            Uri                     = $Uri
            Headers                 = $headers
            ErrorAction             = 'Stop'
            StatusCodeVariable      = 'statusCode'
            SkipHttpErrorCheck      = $true
            ResponseHeadersVariable = 'respHeaders'
        }
        if ($null -ne $Body) {
            $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        }

        $attempt = 0
        while ($true) {
            $attempt++
            $response = Invoke-RestMethod @params

            # Throttling / transient server errors: honour Retry-After.
            if ($statusCode -in @(429, 503, 504, 500) -and $attempt -le $MaxRetries) {
                $retryAfter = 0
                if ($respHeaders -and $respHeaders['Retry-After']) {
                    [void][int]::TryParse(($respHeaders['Retry-After'] | Select-Object -First 1), [ref]$retryAfter)
                }
                if ($retryAfter -le 0) { $retryAfter = [Math]::Min(60, [Math]::Pow(2, $attempt)) }
                Write-Warning "Graph returned $statusCode for $Method $Uri; retrying in ${retryAfter}s (attempt $attempt/$MaxRetries)."
                Start-Sleep -Seconds $retryAfter
                continue
            }
            break
        }

        if ($Raw) {
            return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
        }

        if ($statusCode -ge 400) {
            throw (New-CBGraphError -StatusCode $statusCode -Response $response -Method $Method -Uri $Uri)
        }

        if ($All -and $response -and ($response.PSObject.Properties.Name -contains 'value')) {
            foreach ($item in $response.value) { $results.Add($item) }
            $next = $response.'@odata.nextLink'
            if ($next) { $Uri = $next; continue }
            return $results
        }

        return $response
    }
}

function New-CBGraphError {
    <#
    .SYNOPSIS
        Builds the exception message for a failed Graph call, surfacing Graph's
        own message first. Users see these (a share can fail because a site
        forbids external sharing), so the readable part must come first and the
        raw payload last.
    #>
    [CmdletBinding()]
    param([int]$StatusCode, $Response, [string]$Method, [string]$Uri)
    $message = ''
    if ($Response -and $Response.PSObject.Properties['error']) {
        $message = "$($Response.error.message)".Trim()
    }
    if (-not $message) {
        $message = if ($Response) { ($Response | ConvertTo-Json -Depth 8 -Compress) } else { '(no body)' }
    }
    # The URL goes to the log, not into the message. These errors are shown to end
    # users (a share can fail because a site forbids external sharing) and a drive
    # item URL in the middle of that sentence helps nobody, while the operator
    # reading Application Insights does want it.
    Write-Warning "Graph $Method $Uri failed with HTTP ${StatusCode}: $message"
    return "Graph $Method returned HTTP ${StatusCode}: $message"
}

function Get-CBGraphErrorCode {
    <#
    .SYNOPSIS
        Best-effort extraction of Graph's error code from a caught exception, so
        callers can branch on 'Request_ResourceNotFound' or 'accessDenied'
        without string-matching whole messages.
    #>
    [CmdletBinding()] param($ErrorRecord)
    $text = "$($ErrorRecord)"
    if ($text -match '"code"\s*:\s*"([^"]+)"') { return $Matches[1] }
    return ''
}

function ConvertTo-CBGraphPathSegment {
    <#
    .SYNOPSIS
        Validates an opaque Graph identifier for use in a URL path segment.
    .DESCRIPTION
        These ids must NOT be percent-encoded. A SharePoint site id is
        'contoso.sharepoint.com,<guid>,<guid>' and a drive id starts 'b!';
        [Uri]::EscapeDataString turns those into %2C and %21, and Graph answers
        404 "Requested site could not be found" for the first and can mis-route
        the second.

        Escaping was there to stop a caller smuggling a path into the URL, so the
        id is VALIDATED instead of escaped. That closes exactly the same door,
        because anything containing / ? # % or a space is refused outright, while
        leaving the identifier intact.
    .PARAMETER What
        Named in the error, so a refusal says which thing was wrong.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [string]$What = 'identifier')
    $id = "$Value".Trim()
    if (-not $id) { throw "No $What was supplied." }
    if ($id.Length -gt 512) { throw "That $What is too long to be real." }
    # The full set Graph uses for site, drive and drive-item ids. Deliberately
    # excludes / ? # % & and whitespace, which are the ones that could change
    # what URL is actually called.
    if ($id -notmatch '^[A-Za-z0-9!,.:@_~=+-]+$') {
        throw "That $What contains characters that Graph identifiers never use."
    }
    return $id
}

function Get-CBTenantDomains {
    <#
    .SYNOPSIS
        The tenant's verified domains, lowercased. Used to refuse "guest"
        invitations for addresses that are actually internal.
    #>
    [CmdletBinding()] param()
    if ($script:CBTenantDomains) { return $script:CBTenantDomains }
    $domains = @(Invoke-CBGraph -Uri '/domains?$select=id,isVerified' -All |
        Where-Object { $_.isVerified } | ForEach-Object { "$($_.id)".ToLowerInvariant() })
    $script:CBTenantDomains = $domains
    return $domains
}

function Get-CBSharePointHosts {
    <#
    .SYNOPSIS
        The tenant's SharePoint and OneDrive host names (e.g. contoso.sharepoint.com
        and contoso-my.sharepoint.com), derived from /sites/root so the tenant name
        never has to be configured. Cached for the life of the worker.
    .DESCRIPTION
        These seed the welcome page's redirect allowlist: a share target is only
        offered to a guest if it points somewhere we recognise as ours.
    #>
    [CmdletBinding()] param()
    if ($script:CBSpoHosts) { return $script:CBSpoHosts }

    $root = Invoke-CBGraph -Uri '/sites/root?$select=webUrl'
    if (-not $root.webUrl) { throw 'Could not resolve /sites/root to determine the SharePoint host.' }
    $rootHost = ([Uri]$root.webUrl).Host                       # contoso.sharepoint.com
    $tenant   = $rootHost.Split('.')[0]                        # contoso
    $suffix   = $rootHost.Substring($tenant.Length)            # .sharepoint.com
    $script:CBSpoHosts = @($rootHost, ('{0}-my{1}' -f $tenant, $suffix))
    return $script:CBSpoHosts
}
