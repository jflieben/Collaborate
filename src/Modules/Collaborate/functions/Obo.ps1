# On-behalf-of: acting as the signed-in user.
#
# Everything a user SHARES runs as that user, never as the managed identity, so
# Graph enforces their real rights and nobody can hand out access to something
# they do not already have. Administration (inviting, expiring, blocking,
# deleting) is the opposite and uses the managed identity, because employees
# cannot do those things themselves in a locked-down tenant.
#
# The on-behalf-of flow normally needs a client secret or certificate on the app
# registration. It does not here: the app registration carries a FEDERATED
# IDENTITY CREDENTIAL that trusts this Function App's managed identity, so we
# exchange an identity token for a client assertion. There is no secret to store,
# rotate or leak.
#
#   managed identity  --token for api://AzureADTokenExchange-->  client assertion
#   client assertion + the user's token  --OBO-->  a Graph token for that user

$script:CBOboCache = @{}
$script:CBTokenExchangeAudience = 'api://AzureADTokenExchange'

# The delegated scopes the portal ever asks for. Admin-consented at deploy time,
# so a user is never prompted. Kept in one place so the deploy, the docs and the
# runtime cannot disagree.
$script:CBOboScopes = @(
    'https://graph.microsoft.com/Files.ReadWrite.All',
    'https://graph.microsoft.com/Sites.Read.All',
    'https://graph.microsoft.com/TeamMember.ReadWrite.All',
    'https://graph.microsoft.com/GroupMember.ReadWrite.All',
    'https://graph.microsoft.com/Team.ReadBasic.All',
    'https://graph.microsoft.com/User.Read'
)

function Get-CBOboScope { return $script:CBOboScopes }

function Get-CBClientAssertion {
    <#
    .SYNOPSIS
        A client assertion proving we are the app registration, obtained from the
        managed identity via the federated credential.
    #>
    [CmdletBinding()] param()
    return Get-CBManagedIdentityToken -Resource $script:CBTokenExchangeAudience
}

function Get-CBOboToken {
    <#
    .SYNOPSIS
        Exchanges a validated user token for a Graph token carrying that user's
        delegated permissions. Cached per user until shortly before expiry.
    .PARAMETER UserToken
        The bearer token the caller presented. It MUST already have been
        validated (Resolve-CBCaller); this function does not re-check it.
    .PARAMETER Scopes
        Defaults to the full portal scope set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserToken,
        [Parameter(Mandatory)][string]$Oid,
        [string[]]$Scopes
    )
    if (-not $Scopes) { $Scopes = $script:CBOboScopes }
    $scopeText = ($Scopes -join ' ')
    $cacheKey = "$Oid|$scopeText"

    $cached = $script:CBOboCache[$cacheKey]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
        return $cached.Token
    }

    $cfg = Get-CBConfig
    if (-not $cfg.AdminClientId) { throw 'The portal application id is not configured; cannot act on your behalf.' }

    $body = @{
        client_id             = $cfg.AdminClientId
        grant_type            = 'urn:ietf:params:oauth:grant-type:jwt-bearer'
        assertion             = $UserToken
        scope                 = $scopeText
        requested_token_use   = 'on_behalf_of'
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = (Get-CBClientAssertion)
    }
    $uri = '{0}/{1}/oauth2/v2.0/token' -f $cfg.LoginResource.TrimEnd('/'), $cfg.TenantId

    $response = Invoke-RestMethod -Method Post -Uri $uri -Body $body `
        -ContentType 'application/x-www-form-urlencoded' `
        -SkipHttpErrorCheck -StatusCodeVariable sc -ErrorAction Stop

    if ($sc -ge 400 -or -not $response.access_token) {
        throw (Get-CBOboErrorMessage -Response $response -StatusCode $sc)
    }

    $expiresIn = 3600
    if ($response.expires_in) { [void][int]::TryParse("$($response.expires_in)", [ref]$expiresIn) }
    $script:CBOboCache[$cacheKey] = @{
        Token     = $response.access_token
        ExpiresOn = [DateTimeOffset]::UtcNow.AddSeconds($expiresIn)
    }
    return $response.access_token
}

function Get-CBOboErrorMessage {
    <#
    .SYNOPSIS
        Turns an Entra token-endpoint failure into something an operator can act
        on. These errors are almost always a setup problem (consent not granted,
        the federated credential missing, Conditional Access), and the generic
        text tells nobody anything.
    #>
    [CmdletBinding()] param($Response, [int]$StatusCode)
    $detail = "$($Response.error_description)"
    $code = "$($Response.error)"

    if ($detail -match 'AADSTS65001') {
        return 'Collaborate is not yet consented to act on your behalf. An administrator needs to grant admin consent for the delegated Microsoft Graph permissions on the portal app registration (the deployment does this; re-run it or grant consent in Entra).'
    }
    if ($detail -match 'AADSTS70021|AADSTS700213|no matching federated identity record') {
        return 'The federated identity credential that lets Collaborate act on your behalf is missing or does not match this managed identity. Re-run the deployment to recreate it.'
    }
    if ($detail -match 'AADSTS50013|AADSTS500131|Assertion') {
        return 'Your sign-in token was not accepted for the on-behalf-of exchange. Sign out and back in, then try again.'
    }
    if ($detail -match 'AADSTS53003|AADSTS50076|AADSTS50079') {
        return 'A Conditional Access policy blocked this action. You may need to sign in again with multi-factor authentication, or the policy needs to allow Collaborate.'
    }
    $trimmed = if ($detail.Length -gt 300) { $detail.Substring(0, 300) } else { $detail }
    return "Could not act on your behalf (HTTP $StatusCode, $code): $trimmed"
}

function Invoke-CBGraphAsUser {
    <#
    .SYNOPSIS
        Calls Graph as the signed-in user. This is the only entry point the
        sharing features use, so the "never the managed identity" rule is
        enforced in one place rather than trusted at every call site.
    .PARAMETER Caller
        The object returned by Resolve-CBCaller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get', 'Post', 'Patch', 'Put', 'Delete')][string]$Method = 'Get',
        $Body,
        [ValidateSet('v1.0', 'beta')][string]$ApiVersion = 'v1.0',
        [switch]$All,
        [switch]$Raw
    )
    if (-not $Caller -or -not $Caller.Token) { throw 'No signed-in user context; refusing to act.' }
    $token = Get-CBOboToken -UserToken $Caller.Token -Oid $Caller.Oid
    return Invoke-CBGraph -Uri $Uri -Method $Method -Body $Body -AccessToken $token -ApiVersion $ApiVersion -All:$All -Raw:$Raw
}

function Test-CBOboAvailable {
    <#
    .SYNOPSIS
        Probes the on-behalf-of path for a caller and reports whether it works.
        The setup wizard runs this, and the Diagnostics tab shows the result, so
        a broken sharing setup is visible before a user hits it.
    .OUTPUTS
        @{ Ok; Error; UserPrincipalName }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller)
    try {
        $me = Invoke-CBGraphAsUser -Caller $Caller -Uri '/me?$select=id,userPrincipalName,displayName'
        return @{ Ok = $true; Error = ''; UserPrincipalName = "$($me.userPrincipalName)" }
    }
    catch {
        return @{ Ok = $false; Error = $_.Exception.Message; UserPrincipalName = '' }
    }
}
