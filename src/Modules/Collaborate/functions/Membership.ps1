# Who is allowed to do what, beyond the app roles in the token.
#
# Admin rights come from the Collaborate.Admin app role and are read straight
# from the validated token. Permission to INVITE is different: it can be
# restricted to a nominated group, which has to be resolved against Entra. That
# check happens here, server side, on every request that needs it. The client is
# told the answer so it can hide what a user cannot do, but the client's opinion
# is never trusted.

$script:CBInviterCache = @{}

function Test-CBGroupMember {
    <#
    .SYNOPSIS
        Is this user a member of this group, including through nested groups?
        Cached per worker for a few minutes.
    .NOTES
        Fails CLOSED. If Entra cannot be asked, the answer is "no": the fallback
        for a restricted tenant must not be "everybody may invite".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Oid,
        [Parameter(Mandatory)][string]$GroupId,
        [int]$CacheSeconds = 300
    )
    $key = "$Oid|$GroupId"
    $cached = $script:CBInviterCache[$key]
    if ($cached -and ([DateTimeOffset]::UtcNow - $cached.At).TotalSeconds -lt $CacheSeconds) {
        return $cached.Result
    }

    $result = $false
    try {
        $response = Invoke-CBGraph -Method Post -Uri ('/users/' + [Uri]::EscapeDataString($Oid) + '/checkMemberGroups') -Body @{ groupIds = @($GroupId) }
        $result = (@($response.value) -contains $GroupId)
    }
    catch {
        Write-Warning "Could not check group membership for $Oid in ${GroupId}: $($_.Exception.Message)"
        $result = $false
    }
    $script:CBInviterCache[$key] = @{ Result = $result; At = [DateTimeOffset]::UtcNow }
    return $result
}

function Test-CBCanInvite {
    <#
    .SYNOPSIS
        May this caller invite new guests?
    .DESCRIPTION
        Administrators always may. Otherwise: everybody may, unless an inviter
        group is configured, in which case only its members may.
    .OUTPUTS
        @{ Allowed; Reason }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if ($Caller.IsAdmin) { return @{ Allowed = $true; Reason = '' } }

    $groupId = "$($Settings.invite.inviterGroupId)"
    if (-not $groupId) { return @{ Allowed = $true; Reason = '' } }

    if (Test-CBGroupMember -Oid $Caller.Oid -GroupId $groupId) {
        return @{ Allowed = $true; Reason = '' }
    }
    $groupName = if ($Settings.invite.inviterGroupName) { "$($Settings.invite.inviterGroupName)" } else { 'the approved group' }
    return @{
        Allowed = $false
        Reason  = "Inviting external people is limited to members of $groupName. You can still see and manage the collaborators you already own."
    }
}

function Get-CBUserProfile {
    <#
    .SYNOPSIS
        A directory profile by object id, for naming an owner in the portal and in
        email. Returns $null when the object no longer exists (a departed owner),
        which callers treat as an orphaned guest rather than an error.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Oid)
    try {
        $r = Invoke-CBGraph -Raw -Uri ('/users/' + [Uri]::EscapeDataString($Oid) + '?$select=id,displayName,userPrincipalName,mail,accountEnabled,userType')
        if ($r.StatusCode -eq 404 -or -not $r.Body.id) { return $null }
        if ($r.StatusCode -ge 400) { return $null }
        return $r.Body
    }
    catch { return $null }
}

function Search-CBInternalUser {
    <#
    .SYNOPSIS
        People picker over internal members, used when handing a guest to a
        colleague. Guests are excluded: a guest can never own a guest.
    .DESCRIPTION
        $search is the primary query because it is what a person expects from a
        people picker: it matches anywhere in the name rather than only at the
        start, so "smith" finds "Jane Smith", and it copes with the name being
        typed in either order.

        It is an ADVANCED query, which needs $count=true as well as the
        ConsistencyLevel header Invoke-CBGraph always sends. Missing that is what
        made the picker return nothing at all: the old query combined
        userType, accountEnabled and three startswith clauses without $count, so
        Graph refused it, and the refusal was swallowed into an empty list that
        looked exactly like "no such colleague".

        accountEnabled is filtered in memory rather than in the query. It is one
        more clause that can make a combination unsupported, and the result set
        is at most a handful of rows.
    .OUTPUTS
        @{ Items; Error } - Error is set when the directory could not be searched
        at all, so the caller can say so instead of showing an empty list.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Search, [int]$Top = 10)
    $term = "$Search".Trim()
    if ($term.Length -lt 2) { return @{ Items = @(); Error = '' } }

    $select = '$select=id,displayName,userPrincipalName,mail,accountEnabled'
    $memberFilter = [Uri]::EscapeDataString("userType eq 'Member'")
    $found = $null
    $failure = ''

    try {
        $expr = '"displayName:{0}" OR "mail:{0}" OR "userPrincipalName:{0}"' -f $term
        $uri = "/users?`$count=true&`$filter=$memberFilter&`$search=$([Uri]::EscapeDataString($expr))&$select&`$top=$Top"
        $found = @((Invoke-CBGraph -Uri $uri).value)
    }
    catch {
        Write-Warning "Token search over members failed, falling back to prefix matching: $($_.Exception.Message)"
        $failure = "$($_.Exception.Message)"
        $safe = $term.Replace("'", "''")
        $filter = "userType eq 'Member' and (startswith(displayName,'$safe') or startswith(userPrincipalName,'$safe') or startswith(mail,'$safe'))"
        try {
            $uri = "/users?`$count=true&`$filter=$([Uri]::EscapeDataString($filter))&$select&`$top=$Top"
            $found = @((Invoke-CBGraph -Uri $uri).value)
            $failure = ''
        }
        catch {
            Write-Warning "Member search failed entirely: $($_.Exception.Message)"
            return @{ Items = @(); Error = "The directory could not be searched: $($_.Exception.Message)" }
        }
    }

    $items = @(@($found) | Where-Object { $_.id -and $_.accountEnabled -ne $false } | ForEach-Object {
            [ordered]@{ id = "$($_.id)"; displayName = "$($_.displayName)"; userPrincipalName = "$($_.userPrincipalName)"; mail = "$($_.mail)" }
        })
    return @{ Items = $items; Error = $failure }
}
