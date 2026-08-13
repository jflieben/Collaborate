# Authentication and authorisation for the portal API.
#
# App Service Easy Auth sits in front of these functions and is the primary
# gate. But Easy Auth has failed silently before (a bad az call can leave an API
# open), and an operator could disable it later. So every function ALSO
# validates the caller itself, and fails CLOSED. That turns "Easy Auth
# misconfigured" from silent tenant exposure into a visible 401.
#
# The real check is a full RS256 validation of the delegated bearer token
# (signature against the tenant's JWKS, audience = our API, issuer = our tenant,
# not expired). An attacker cannot forge that even if Easy Auth is off and they
# spoof the X-MS-CLIENT-PRINCIPAL header. The principal header is used only to
# name the caller for the audit log.
#
# Collaborate adds two rules M365AutoRevocate did not need, because this API is
# used by ordinary employees rather than only administrators:
#
#   1. GUESTS ARE REFUSED. The tool exists to manage guests, so a guest must
#      never be able to open it. The 'acct' claim (0 = member of this tenant,
#      1 = guest) and 'tid' are both checked.
#   2. APP-ONLY TOKENS ARE REFUSED. Every operation here is attributable to a
#      human, so a token without an 'scp' claim (i.e. client-credentials) is
#      rejected even if it carries our app roles.

$script:CBJwksCache = $null

function ConvertFrom-CBBase64Url {
    param([Parameter(Mandatory)][string]$Value)
    $s = $Value.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } 1 { $s += '===' } }
    return [Convert]::FromBase64String($s)
}

function Get-CBJwks {
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:CBJwksCache -and -not $Refresh) { return $script:CBJwksCache }
    $cfg = Get-CBConfig
    $uri = '{0}/{1}/discovery/v2.0/keys' -f $cfg.LoginResource.TrimEnd('/'), $cfg.TenantId
    $resp = Invoke-RestMethod -Method Get -Uri $uri -ErrorAction Stop
    $script:CBJwksCache = $resp.keys
    return $script:CBJwksCache
}

function Test-CBJwt {
    <#
    .SYNOPSIS
        Validates a JWT access token (RS256) against the tenant JWKS and the
        expected audience/issuer/tenant. Returns @{ Valid; Error; Claims }.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Token)
    $cfg = Get-CBConfig
    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) { return @{ Valid = $false; Error = 'malformed token' } }

    try {
        $header  = [Text.Encoding]::UTF8.GetString((ConvertFrom-CBBase64Url $parts[0])) | ConvertFrom-Json
        $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-CBBase64Url $parts[1])) | ConvertFrom-Json
    }
    catch { return @{ Valid = $false; Error = 'unparseable token' } }

    if ($header.alg -ne 'RS256') { return @{ Valid = $false; Error = "unexpected alg '$($header.alg)'" } }

    # Audience must be our API (accept both the api:// URI and the bare client id).
    $aud = "$($payload.aud)"
    if (@("api://$($cfg.AdminClientId)", "$($cfg.AdminClientId)") -notcontains $aud) {
        return @{ Valid = $false; Error = "wrong audience '$aud'" }
    }

    # Issuer and tenant must both be ours. Checking 'tid' as well as the issuer
    # string closes the multi-tenant impersonation gap if the app registration is
    # ever switched to a multi-tenant audience.
    $iss = "$($payload.iss)"
    if ($iss -notmatch [regex]::Escape($cfg.TenantId)) { return @{ Valid = $false; Error = "wrong issuer '$iss'" } }
    if ($payload.tid -and "$($payload.tid)" -ne $cfg.TenantId) { return @{ Valid = $false; Error = "token is from tenant '$($payload.tid)'" } }

    # Expiry / not-before (allow 5 min clock skew).
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($payload.exp -and [long]$payload.exp -lt ($now - 300)) { return @{ Valid = $false; Error = 'token expired' } }
    if ($payload.nbf -and [long]$payload.nbf -gt ($now + 300)) { return @{ Valid = $false; Error = 'token not yet valid' } }

    # Signature: find the signing key by kid, verify over header.payload.
    $signed = [Text.Encoding]::ASCII.GetBytes($parts[0] + '.' + $parts[1])
    $sig    = ConvertFrom-CBBase64Url $parts[2]
    $verified = $false
    foreach ($refresh in @($false, $true)) {
        $keys = Get-CBJwks -Refresh:$refresh
        $jwk = $keys | Where-Object { $_.kid -eq $header.kid } | Select-Object -First 1
        if (-not $jwk) { continue }
        try {
            $rsa = [System.Security.Cryptography.RSA]::Create()
            $rp = [System.Security.Cryptography.RSAParameters]::new()
            $rp.Modulus  = ConvertFrom-CBBase64Url $jwk.n
            $rp.Exponent = ConvertFrom-CBBase64Url $jwk.e
            $rsa.ImportParameters($rp)
            $verified = $rsa.VerifyData($signed, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        }
        catch { return @{ Valid = $false; Error = "signature check error: $($_.Exception.Message)" } }
        if ($verified) { break }
        if (-not $refresh) { continue }  # kid found but bad sig: no point retrying
    }
    if (-not $verified) { return @{ Valid = $false; Error = 'signature not verified (unknown key or bad signature)' } }

    return @{ Valid = $true; Claims = $payload }
}

function Get-CBClientPrincipalName {
    <#
    .SYNOPSIS
        Best-effort caller name from the Easy Auth principal header (audit log).
    #>
    [CmdletBinding()] param($Request)
    if (-not $Request.Headers) { return $null }
    foreach ($h in 'x-ms-client-principal-name', 'X-MS-CLIENT-PRINCIPAL-NAME') {
        if ($Request.Headers[$h]) { return $Request.Headers[$h] }
    }
    foreach ($h in 'x-ms-client-principal', 'X-MS-CLIENT-PRINCIPAL') {
        if (-not $Request.Headers[$h]) { continue }
        try {
            $principal = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Request.Headers[$h])) | ConvertFrom-Json
            foreach ($type in 'preferred_username', 'upn', 'unique_name', 'name', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn') {
                $claim = $principal.claims | Where-Object { $_.typ -eq $type } | Select-Object -First 1
                if ($claim.val) { return $claim.val }
            }
        }
        catch { Write-Warning "Could not decode the client principal header: $($_.Exception.Message)" }
    }
    return $null
}

function Test-CBEasyAuthPresent {
    <#
    .SYNOPSIS
        True when App Service Easy Auth processed this request (it injects a
        client principal header). Used by the setup wizard's SSO test to prove
        the platform gate is actually in front of the app, not merely configured.
    #>
    [CmdletBinding()] param($Request)
    return [bool](Get-CBClientPrincipalName -Request $Request)
}

function ConvertFrom-CBRequestBody {
    <#
    .SYNOPSIS
        The JSON body of an HTTP request, normalised to a PSCustomObject.
    .DESCRIPTION
        The Functions PowerShell worker hands $Request.Body as a HASHTABLE when
        the request is JSON, and as a string otherwise. Those two shapes are not
        interchangeable in the way that matters:

            $body.settings                       works on both
            $body.PSObject.Properties['settings'] finds NOTHING on a hashtable

        because a hashtable's keys are not PSObject properties. Code written
        against a PSCustomObject therefore reads every field as $null on a real
        request, and a sanitiser that fills missing fields with defaults
        cheerfully returns the shipped defaults.

        That is exactly what happened: every configuration save stored the
        defaults instead of what the administrator had typed, and because the
        deploy seeds the company name and service desk address, the result looked
        identical to their real settings apart from one flag that would not
        switch off.

        Round-tripping through JSON collapses all three shapes into one, so
        everything downstream can assume a PSCustomObject and the trap cannot be
        stepped on again.
    #>
    [CmdletBinding()] param($Body)
    if ($null -eq $Body) { return $null }

    if ($Body -is [string]) {
        if (-not $Body.Trim()) { return $null }
        try { return ($Body | ConvertFrom-Json) }
        catch { throw "The request body is not valid JSON: $($_.Exception.Message)" }
    }
    if ($Body -is [System.Management.Automation.PSCustomObject]) { return $Body }

    # A hashtable or ordered dictionary from the worker. Depth is generous
    # because the settings object nests as far as the email templates.
    try { return ($Body | ConvertTo-Json -Depth 32 | ConvertFrom-Json) }
    catch {
        Write-Warning "Could not normalise the request body: $($_.Exception.Message)"
        return $Body
    }
}

function Get-CBBearerToken {
    [CmdletBinding()] param($Request)
    if (-not $Request.Headers) { return $null }
    foreach ($h in 'authorization', 'Authorization') {
        $v = $Request.Headers[$h]
        if ($v -and "$v" -match '^\s*Bearer\s+(.+)$') { return $Matches[1].Trim() }
    }
    return $null
}

function Get-CBCallerRole {
    <#
    .SYNOPSIS
        The app roles in a validated token, as a plain string array.
    #>
    [CmdletBinding()] param($Claims)
    if (-not $Claims -or -not $Claims.PSObject.Properties['roles']) { return @() }
    return @($Claims.roles | ForEach-Object { "$_" })
}

function Resolve-CBCaller {
    <#
    .SYNOPSIS
        The gate every function calls first. Validates the caller and returns
        who they are and what they may do. Fails CLOSED.
    .OUTPUTS
        @{ Ok; Status; Error; Oid; Upn; DisplayName; Roles; IsAdmin; Token }
    #>
    [CmdletBinding()] param($Request)
    $cfg = Get-CBConfig
    $principalName = Get-CBClientPrincipalName -Request $Request

    if (-not $cfg.AdminClientId) {
        # Without the client id we cannot validate anything, so we refuse rather
        # than fall back to trusting a spoofable header.
        Write-Warning 'CB_ADMIN_CLIENT_ID is not configured; refusing all API calls until the deploy sets it.'
        return @{ Ok = $false; Status = 503; Error = 'The portal API is not configured yet (no application id). Re-run the deployment.' }
    }

    $token = Get-CBBearerToken -Request $Request
    if (-not $token) {
        return @{ Ok = $false; Status = 401; Error = 'Sign in to continue.'; Upn = $principalName }
    }

    $res = Test-CBJwt -Token $token
    if (-not $res.Valid) {
        Write-Warning "Request rejected: $($res.Error)."
        return @{ Ok = $false; Status = 401; Error = 'Invalid or unauthorised token.'; Upn = $principalName }
    }
    $claims = $res.Claims

    # Delegated only: an app-only token has no 'scp'. Every action here must be
    # attributable to a person.
    $scopes = @("$($claims.scp)" -split '\s+' | Where-Object { $_ })
    if ($scopes.Count -eq 0) {
        Write-Warning 'Request rejected: app-only token presented to a user API.'
        return @{ Ok = $false; Status = 403; Error = 'This API is only available to signed-in users.' }
    }

    # Guests are refused outright: acct=1 means the caller is a guest in this
    # tenant. Belt and braces, we also refuse a token issued by another tenant
    # (Test-CBJwt already checks tid, this catches a token with no tid claim).
    if ($claims.PSObject.Properties['acct'] -and "$($claims.acct)" -eq '1') {
        return @{ Ok = $false; Status = 403; Error = 'Collaborate is only available to internal accounts.' }
    }
    if ($claims.PSObject.Properties['idp'] -and $claims.idp -and "$($claims.idp)" -notmatch [regex]::Escape($cfg.TenantId)) {
        return @{ Ok = $false; Status = 403; Error = 'Collaborate is only available to internal accounts.' }
    }

    $oid = "$($claims.oid)"
    if (-not $oid) {
        return @{ Ok = $false; Status = 403; Error = 'The token does not identify a user.' }
    }

    $upn = @($claims.preferred_username, $claims.upn, $claims.unique_name) | Where-Object { $_ } | Select-Object -First 1
    $name = @($claims.name, $upn, $principalName) | Where-Object { $_ } | Select-Object -First 1
    $roles = Get-CBCallerRole -Claims $claims
    $isAdmin = $roles -contains 'Collaborate.Admin'

    # Bootstrap: before the setup wizard completes, the operator who ran the
    # deploy is an admin even though no app-role assignment has propagated yet.
    # This is ignored the moment setup completes.
    if (-not $isAdmin -and $cfg.BootstrapAdminOid -and $oid -eq $cfg.BootstrapAdminOid) {
        if (-not (Test-CBSetupComplete)) {
            Write-Warning "Granting bootstrap admin rights to the deploying operator ($oid) because setup is not complete."
            $isAdmin = $true
        }
    }

    return @{
        Ok          = $true
        Status      = 200
        Oid         = $oid
        Upn         = "$upn"
        DisplayName = "$name"
        Roles       = $roles
        IsAdmin     = $isAdmin
        Token       = $token
    }
}

function Test-CBAdminRequest {
    <#
    .SYNOPSIS
        Resolve-CBCaller plus a hard requirement for the Collaborate.Admin app
        role. Every admin endpoint starts with this.
    #>
    [CmdletBinding()] param($Request)
    $caller = Resolve-CBCaller -Request $Request
    if (-not $caller.Ok) { return $caller }
    if (-not $caller.IsAdmin) {
        return @{ Ok = $false; Status = 403; Error = 'You need the Collaborate administrator role for this.'; Oid = $caller.Oid; Upn = $caller.Upn }
    }
    return $caller
}
