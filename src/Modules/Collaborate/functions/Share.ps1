# Sharing a file, folder or Team with an external person.
#
# This is the flow the tool exists for: somebody wants to send one document to
# one outsider, and in a locked-down tenant that currently means a service desk
# ticket. Here it is one screen, and it can invite the guest on the way through.
#
# THE GRANT ALWAYS RUNS AS THE SIGNED-IN USER. The managed identity creates the
# guest account (employees cannot), but it never touches the file. That division
# is what makes "you can only share what you can already reach" true by
# construction rather than by a check somebody could forget to write.
#
# Direct per-identity permissions, never anonymous links: access is attached to
# the guest object, so when the lifecycle removes that object the access goes
# with it. An anonymous link would outlive everything this tool does.

function Get-CBShareRole {
    <#
    .SYNOPSIS
        The permission level to grant, clamped to what the tenant allows.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Requested, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $role = "$Requested".Trim().ToLowerInvariant()
    if ($role -notin @('read', 'write')) { $role = "$($Settings.sharing.defaultRole)" }
    if ($role -eq 'write' -and -not $Settings.sharing.allowWrite) { $role = 'read' }
    return $role
}

function Test-CBSharingCapability {
    <#
    .SYNOPSIS
        Is this kind of sharing switched on at all?
    .DESCRIPTION
        The API calls this before doing anything, so a capability an
        administrator disabled is unreachable by a hand-crafted request and not
        merely hidden in the portal.
    .OUTPUTS
        @{ Allowed; Reason }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][ValidateSet('file', 'folder', 'team')][string]$Kind, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    switch ($Kind) {
        'file' { if ($Settings.sharing.files) { return @{ Allowed = $true; Reason = '' } } }
        'folder' { if ($Settings.sharing.folders) { return @{ Allowed = $true; Reason = '' } } }
        'team' { if ($Settings.sharing.teams) { return @{ Allowed = $true; Reason = '' } } }
    }
    $what = switch ($Kind) { 'file' { 'Sharing files' } 'folder' { 'Sharing folders' } 'team' { 'Adding guests to Teams' } }
    return @{ Allowed = $false; Reason = "$what has been switched off by an administrator." }
}

function Get-CBShareFailureMessage {
    <#
    .SYNOPSIS
        Turns a Graph sharing failure into something the person in front of the
        screen can act on.
    .DESCRIPTION
        These errors reach ordinary employees, and "Graph POST returned HTTP 403"
        tells them nothing about what to do. Most sharing failures are a tenant or
        site policy rather than a fault, and saying which one turns a dead end
        into a sentence they can forward to whoever owns the site.
    #>
    [CmdletBinding()] param([string]$Message, [string]$ItemName, [string]$Recipient)
    $text = "$Message"
    # SharePoint says this several different ways depending on whether the block
    # is on the tenant, the site, or the recipient's domain.
    # "One or more users could not be resolved" is what SharePoint returns when a
    # site refuses external people: the address is fine, the site will not have
    # them. Read as an invalid recipient it sends somebody off to check an email
    # address that was never the problem.
    if ($text -match 'externalSharing|sharingDisabled|SharingDenied|invitationSendingDisabled|not enabled for external|external sharing|could not be resolved|blocked by (your |the )?(organization|organisation|tenant|site|policy)|accessDenied.*external') {
        return "External sharing is switched off for the site '$ItemName' lives in, so it cannot be shared outside the company. The person who owns that site can change it."
    }
    if ($text -match 'invalidRequest.*recipient|invalidRecipient|not a valid recipient') {
        return "SharePoint would not accept $Recipient as a recipient. Check the address."
    }
    if ($text -match 'accessDenied|403|Forbidden') {
        return "You do not have permission to share '$ItemName'. Ask somebody who can edit it to share it, or to give you access first."
    }
    if ($text -match 'itemNotFound|404') {
        return "'$ItemName' could not be found any more. It may have been moved or deleted since you picked it."
    }
    if ($text -match 'domain.*not allowed|allowedDomain|blockedDomain') {
        return "The tenant's external sharing rules do not allow $Recipient's domain. An administrator sets that list in SharePoint, separately from Collaborate."
    }
    $trimmed = if ($text.Length -gt 300) { $text.Substring(0, 300) } else { $text }
    return "SharePoint refused the share: $trimmed"
}

$script:CBTenantSharing = $null

function Get-CBTenantSharingPolicy {
    <#
    .SYNOPSIS
        The tenant's external sharing capability and domain lists.
    .DESCRIPTION
        Read with the managed identity from /admin/sharepoint/settings, cached for
        the life of the worker.

        TENANT LEVEL ONLY. SharePoint's per-site setting is not exposed through
        Graph, so a site that blocks external sharing inside a tenant that allows
        it still only reveals itself when a share is attempted.

        Unreadable (permission not granted yet, or Graph having a bad minute) is
        NOT treated as "blocked": the answer is 'unknown' and every caller
        carries on as before.
    .OUTPUTS
        @{ Known; Capability; AllowsExternal; Restriction; AllowedDomains; BlockedDomains; Reason }
    #>
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:CBTenantSharing -and -not $Refresh) { return $script:CBTenantSharing }

    $result = @{
        Known = $false; Capability = ''; AllowsExternal = $true; Restriction = 'none'
        AllowedDomains = @(); BlockedDomains = @(); Reason = ''
    }
    try {
        $s = Invoke-CBGraph -Uri '/admin/sharepoint/settings'
        $capability = "$($s.sharingCapability)"
        $result.Known = [bool]$capability
        $result.Capability = $capability
        # 'disabled' is the only value that stops external sharing outright.
        # existingExternalUserSharingOnly still allows an existing guest, which is
        # a case this tool handles, so it is not treated as a block.
        $result.AllowsExternal = ($capability -ne 'disabled')
        $result.Restriction = "$($s.sharingDomainRestrictionMode)"
        $result.AllowedDomains = @($s.sharingAllowedDomainList)
        $result.BlockedDomains = @($s.sharingBlockedDomainList)
    }
    catch {
        $result.Reason = "$($_.Exception.Message)"
        Write-Warning "Could not read the tenant's SharePoint sharing settings: $($result.Reason). Sharing will behave as before and fail at the point of use if it is blocked."
    }
    $script:CBTenantSharing = $result
    return $result
}

function Test-CBTenantAllowsSharingWith {
    <#
    .SYNOPSIS
        Would the tenant's own SharePoint rules refuse this address outright?
    .DESCRIPTION
        Pure, so the domain-list logic is testable. Only says no when the answer
        is known: an unreadable policy means carry on.
    .OUTPUTS
        @{ Allowed; Reason }
    #>
    [CmdletBinding()] param([AllowNull()][string]$Email, $Policy)
    if (-not $Policy -or -not $Policy.Known) { return @{ Allowed = $true; Reason = '' } }
    if (-not $Policy.AllowsExternal) {
        return @{ Allowed = $false
            Reason = 'External sharing is switched off for the whole tenant in SharePoint, so nothing can be shared outside the company. A SharePoint administrator sets this.'
        }
    }
    $domain = ("$Email" -split '@')[-1]
    if (-not $domain) { return @{ Allowed = $true; Reason = '' } }
    $domain = $domain.Trim().ToLowerInvariant()

    $mode = "$($Policy.Restriction)".ToLowerInvariant()
    if ($mode -eq 'allowlist') {
        $allowed = @($Policy.AllowedDomains | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
        if ($allowed.Count -and $allowed -notcontains $domain) {
            return @{ Allowed = $false; Reason = "SharePoint only allows sharing with an approved list of domains, and $domain is not on it. A SharePoint administrator maintains that list." }
        }
    }
    elseif ($mode -eq 'blocklist') {
        $blocked = @($Policy.BlockedDomains | ForEach-Object { "$_".Trim().ToLowerInvariant() } | Where-Object { $_ })
        if ($blocked -contains $domain) {
            return @{ Allowed = $false; Reason = "SharePoint blocks sharing with $domain. A SharePoint administrator maintains that list." }
        }
    }
    return @{ Allowed = $true; Reason = '' }
}

function Grant-CBItemAccess {
    <#
    .SYNOPSIS
        Gives one external person access to one drive item, as the signed-in user.
    .DESCRIPTION
        requireSignIn keeps this a real permission tied to an identity rather than
        a link anybody could forward. sendInvitation is false because SharePoint's
        own notification is exactly the unbranded mail this tool exists to
        replace; ours goes out afterwards, once we know the grant worked.
    .OUTPUTS
        @{ Ok; Error; WebUrl }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][string]$Email,
        [string]$Role = 'read',
        [string]$ItemName,
        [string]$Message
    )
    $body = @{
        recipients     = @(@{ email = $Email })
        roles          = @($Role)
        requireSignIn  = $true
        sendInvitation = $false
    }
    if ("$Message".Trim()) { $body.message = (ConvertTo-CBBoundedString -Value $Message -MaxLength 500) }

    try {
        $uri = '/drives/' + (ConvertTo-CBGraphPathSegment -Value $DriveId -What 'drive id') +
        '/items/' + (ConvertTo-CBGraphPathSegment -Value $ItemId -What 'item id') + '/invite'
        $response = Invoke-CBGraphAsUser -Caller $Caller -Method Post -Uri $uri -Body $body
        $link = ''
        foreach ($p in @($response.value)) { if ($p.link -and $p.link.webUrl) { $link = "$($p.link.webUrl)"; break } }
        return @{ Ok = $true; Error = ''; WebUrl = $link }
    }
    catch {
        $detail = "$($_.Exception.Message)"
        return @{ Ok = $false; WebUrl = ''
            Error = (Get-CBShareFailureMessage -Message $detail -ItemName $ItemName -Recipient $Email)
            Detail = $detail
            SitePolicy = [bool]($detail -match 'externalSharing|sharingDisabled|SharingDenied|invitationSendingDisabled|external sharing|could not be resolved|blocked by')
        }
    }
}

function Add-CBSharedItemRecord {
    <#
    .SYNOPSIS
        Records what a guest has been given access to, on the guest's own row.
    .DESCRIPTION
        So that an owner reviewing a collaborator can see what they can actually
        reach, and so the activity log is not the only place that knows. Capped at
        50 entries, newest first: this is a summary for a person, not an audit
        trail (the activity log is that, and it is never trimmed by this).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [string]$WebUrl,
        [string]$Role,
        [string]$SharedBy,
        # What the access actually hangs off, so it can be taken away again. A
        # record without these can be listed but never revoked, which is what
        # every row written before this existed looks like.
        [string]$DriveId,
        [string]$ItemId,
        [string]$GroupId
    )
    $existing = @()
    if ($Row.PSObject.Properties['SharedItems'] -and "$($Row.SharedItems)") {
        try { $existing = @("$($Row.SharedItems)" | ConvertFrom-Json) } catch { $existing = @() }
    }
    $entry = [ordered]@{
        # An identifier of our own, so the portal can name one entry without
        # relying on its position in a list that changes, or on a URL that may be
        # empty.
        id       = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        kind     = $Kind
        name     = (ConvertTo-CBBoundedString -Value $Name -MaxLength 200 -Default 'an item')
        webUrl   = "$WebUrl"
        role     = "$Role"
        sharedBy = "$SharedBy"
        driveId  = "$DriveId"
        itemId   = "$ItemId"
        groupId  = "$GroupId"
        sharedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    # Re-sharing the same thing replaces the old entry, including its sharer: the
    # last person to grant it is the one who can take it away.
    $merged = @(@($entry) + @($existing | Where-Object {
                if ("$($_.itemId)" -and "$ItemId") { return "$($_.itemId)" -ne "$ItemId" }
                if ("$($_.groupId)" -and "$GroupId") { return "$($_.groupId)" -ne "$GroupId" }
                return "$($_.webUrl)" -ne "$WebUrl"
            }) | Select-Object -First 50)
    $json = ($merged | ConvertTo-Json -Depth 5 -Compress)
    if ($json -notmatch '^\[') { $json = "[$json]" }   # ConvertTo-Json unwraps a single-element array
    Save-CBGuestRecord -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)" -Properties @{ SharedItems = $json }
    return $merged
}

function Get-CBSharedItemView {
    <#
    .SYNOPSIS
        What a guest can reach, as the portal renders it. Newest first.
    .DESCRIPTION
        Pure, so the awkward parts are testable: rows written by older versions,
        a truncated JSON blob, a missing field.

        This lists what COLLABORATE granted, and the portal says so beside it.
        Anything shared with the guest directly in SharePoint or Teams was never
        ours to see, and implying otherwise would be worse than the gap: somebody
        deciding whether to remove a collaborator would read a short list as
        "this is all they can reach".

        TWO PEOPLE CAN SHARE WITH THE SAME GUEST, and that is a normal thing to
        want. It means this list is not automatically the viewer's to read: a
        document name is itself information ("Redundancy plan Q3.xlsx"), and the
        owner of a guest has no right to it merely because they own the guest.
        So a viewer sees the names and links of what THEY shared, and everything
        else as a count of its kind with who shared it and when.

        Team names are not redacted. A Team is a named group of people inside the
        company, its membership is visible to its members anyway, and knowing an
        external person is in "Project Falcon" is not the same class of
        disclosure as a file name.

        Administrators see every name, because reviewing what an external party
        can reach is the job. They still cannot revoke what they did not grant:
        revocation runs as the person, delegated, and an administrator is not
        automatically able to change a permission on somebody else's file. Doing
        it for them would mean giving the managed identity write access to every
        file in the tenant, which is a far larger thing than the convenience.
    .PARAMETER ViewerUpn
        Who is looking. Empty means nobody in particular, and nothing is named.
    .OUTPUTS
        An array of display-ready entries.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Json,
        [datetime]$Now = [datetime]::MinValue,
        [AllowNull()][string]$ViewerUpn,
        [switch]$ViewerIsAdmin
    )
    if (-not "$Json".Trim()) { return @() }
    $items = @()
    try { $items = @("$Json" | ConvertFrom-Json) }
    catch {
        Write-Warning "A guest's shared-item list could not be read: $($_.Exception.Message)"
        return @()
    }

    $viewer = "$ViewerUpn".Trim()
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($i in @($items)) {
        if (-not $i -or -not "$($i.name)") { continue }
        $kind = "$($i.kind)".Trim().ToLowerInvariant()
        $role = "$($i.role)".Trim().ToLowerInvariant()
        $sharedBy = "$($i.sharedBy)"
        $mine = [bool]($viewer -and $sharedBy -and $viewer -eq $sharedBy)

        # A Team's name is not a disclosure; a document's is. Everything else is
        # named only for the person who shared it, or for an administrator.
        $mayName = $mine -or $ViewerIsAdmin -or ($kind -eq 'team')

        # Only https survives into a link, and only for somebody who may see the
        # name anyway. A URL carries the file name in it, so handing one over
        # would undo the redaction on the line above.
        $url = "$($i.webUrl)"
        if ($url -notmatch '^https://' -or -not $mayName) { $url = '' }

        $kindLabel = switch ($kind) { 'folder' { 'Folder' } 'team' { 'Team' } default { 'File' } }
        # Only the person who granted it can take it away, because taking it away
        # runs as them. An administrator sees why rather than a button that
        # cannot work.
        $canRevoke = $mine -and (("$($i.itemId)" -and "$($i.driveId)") -or "$($i.groupId)")

        $out.Add([ordered]@{
                id        = "$($i.id)"
                kind      = $(if ($kind) { $kind } else { 'file' })
                kindLabel = $kindLabel
                icon      = $(switch ($kind) { 'folder' { 'folder' } 'team' { 'team' } default { Get-CBItemIcon -Name "$($i.name)" } })
                name      = $(if ($mayName) { "$($i.name)" } else { "A $($kindLabel.ToLowerInvariant()) shared by somebody else" })
                redacted  = (-not $mayName)
                webUrl    = $url
                role      = $(if ($mayName) { $role } else { '' })
                roleLabel = $(if (-not $mayName) { '' }
                    else {
                        switch ($kind) {
                            'team' { 'Member' }
                            default { if ($role -eq 'write') { 'Can edit' } elseif ($role -eq 'read') { 'Can view' } else { '' } }
                        }
                    })
                sharedBy  = $sharedBy
                sharedByYou = $mine
                canRevoke = $canRevoke
                revokeBlockedReason = $(if ($canRevoke) { '' }
                    elseif (-not $mine) { "Only $(if ($sharedBy) { $sharedBy } else { 'the person who shared it' }) can take this back." }
                    else { 'This was shared before Collaborate recorded enough to undo it. Remove it in SharePoint or Teams.' })
                sharedAt  = "$($i.sharedAtUtc)"
                sharedAtLabel = (Format-CBRelativeDate -Value "$($i.sharedAtUtc)" -Now $Now)
            })
    }
    return @($out)
}

function Remove-CBSharedAccess {
    <#
    .SYNOPSIS
        Takes back one thing a guest was given, as the person who gave it.
    .DESCRIPTION
        Delegated, for the same reason granting is: the tool has no rights over
        anybody's files and should not acquire any. That is also why only the
        person who shared something can un-share it here. An administrator can
        see everything a guest can reach, but revoking on somebody else's behalf
        would mean the managed identity holding write access to every file in the
        tenant. Reviewing is worth that trade; undoing one share is not.

        For a drive item the permission is found by listing the item's
        permissions and matching the guest, because Graph does not offer "remove
        this person from this item" directly and the permission id was not ours
        to keep. For a Team it is a group membership, which is removed by id.

        The record is dropped whatever Graph said about a permission that is
        already gone: a 404 means the access does not exist, which is the state
        the caller asked for.
    .OUTPUTS
        @{ Ok; Status; Error; Message }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$ItemKey,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }

    $items = @()
    try { $items = @("$($Row.SharedItems)" | ConvertFrom-Json) } catch { $items = @() }
    $entry = $items | Where-Object { "$($_.id)" -eq $ItemKey } | Select-Object -First 1
    if (-not $entry) { return @{ Ok = $false; Status = 404; Error = 'That is no longer in the list.' } }

    if ("$($entry.sharedBy)" -ne "$($Caller.Upn)") {
        return @{ Ok = $false; Status = 403
            Error = "Only $(if ($entry.sharedBy) { $entry.sharedBy } else { 'the person who shared it' }) can take that back, because it is undone with their access, not ours."
        }
    }

    $guestId = "$($Row.RowKey)"
    $email = "$($Row.Email)"
    $name = "$($entry.name)"
    $kind = "$($entry.kind)".ToLowerInvariant()

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would take back access to $name from $email" -Actor $Caller.Upn `
            -OwnerId "$($Row.PartitionKey)" -GuestId $guestId -GuestUpn $email -GuestDisplayName "$($Row.DisplayName)" -Simulated
        return @{ Ok = $true; Status = 200; Message = 'Simulation mode is on, so nothing was actually changed.' }
    }

    try {
        if ($kind -eq 'team') {
            if (-not "$($entry.groupId)") { return @{ Ok = $false; Status = 409; Error = 'This was recorded before Collaborate kept the Team id, so it has to be removed in Teams.' } }
            $group = ConvertTo-CBGraphPathSegment -Value "$($entry.groupId)" -What 'group id'
            $member = ConvertTo-CBGraphPathSegment -Value $guestId -What 'account id'
            Invoke-CBGraphAsUser -Caller $Caller -Method Delete -Uri "/groups/$group/members/$member/`$ref" | Out-Null
        }
        else {
            if (-not "$($entry.driveId)" -or -not "$($entry.itemId)") {
                return @{ Ok = $false; Status = 409; Error = 'This was recorded before Collaborate kept enough to undo it. Remove it in SharePoint instead.' }
            }
            $drive = ConvertTo-CBGraphPathSegment -Value "$($entry.driveId)" -What 'drive id'
            $item = ConvertTo-CBGraphPathSegment -Value "$($entry.itemId)" -What 'item id'
            $permissions = @((Invoke-CBGraphAsUser -Caller $Caller -Uri "/drives/$drive/items/$item/permissions").value)
            $matched = @($permissions | Where-Object { Test-CBPermissionGrantsTo -Permission $_ -GuestId $guestId -Email $email })
            if ($matched.Count -eq 0) {
                # Already gone, or granted some other way. Either way the guest
                # does not hold it through us, so the record is the thing that is
                # wrong.
                Remove-CBSharedItemRecord -Row $Row -ItemKey $ItemKey
                return @{ Ok = $true; Status = 200; Message = "$name was already not shared with $email any more, so it has been taken off the list." }
            }
            foreach ($p in $matched) {
                $permId = ConvertTo-CBGraphPathSegment -Value "$($p.id)" -What 'permission id'
                Invoke-CBGraphAsUser -Caller $Caller -Method Delete -Uri "/drives/$drive/items/$item/permissions/$permId" | Out-Null
            }
        }
    }
    catch {
        $detail = "$($_.Exception.Message)"
        # Gone already, or the site has since stopped allowing external people at
        # all. In both cases SharePoint will not act, and in both cases the guest
        # does not hold the access through us any more, so the record is what is
        # wrong. Kept quiet on purpose: an owner tidying up should not be stuck
        # with a row they cannot remove because somebody changed a site setting.
        $benign = $detail -match 'itemNotFound|404|Resource.*not exist|sharingDisabled|SharingDenied|external sharing|could not be resolved|blocked by'
        if (-not $benign) {
            return @{ Ok = $false; Status = 502; Detail = $detail
                Error = (Get-CBShareFailureMessage -Message $detail -ItemName $name -Recipient $email)
            }
        }
        Remove-CBSharedItemRecord -Row $Row -ItemKey $ItemKey
        Write-CBActivity -EventName "Removed the record of $name for $email without SharePoint acting" -Actor $Caller.Upn `
            -OwnerId "$($Row.PartitionKey)" -GuestId $guestId -GuestUpn $email -GuestDisplayName "$($Row.DisplayName)" `
            -Detail @{ kind = $kind; name = $name; why = $detail }
        return @{ Ok = $true; Status = 200
            Message = "$name has been taken off the list. SharePoint would not confirm the change, which usually means the access was already gone or the site no longer allows external people at all. Check the site itself if you need to be certain."
        }
    }

    Remove-CBSharedItemRecord -Row $Row -ItemKey $ItemKey
    Write-CBActivity -EventName "Took back $($entry.kind) access to $name from $email" -Actor $Caller.Upn `
        -OwnerId "$($Row.PartitionKey)" -GuestId $guestId -GuestUpn $email -GuestDisplayName "$($Row.DisplayName)" `
        -Detail @{ kind = $kind; name = $name }
    return @{ Ok = $true; Status = 200; Message = "$email can no longer reach $name." }
}

function Test-CBPermissionGrantsTo {
    <#
    .SYNOPSIS
        Does this drive-item permission belong to this guest?
    .DESCRIPTION
        Pure, and deliberately generous about where Graph puts the identity:
        grantedToV2 for a single grantee, grantedToIdentitiesV2 for several, and
        the older grantedTo / grantedToIdentities on some drives. Matching on the
        object id where there is one and the address otherwise, because a guest
        invited but not yet redeemed can appear by address alone.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Permission, [string]$GuestId, [string]$Email)
    $identities = @(
        $Permission.grantedToV2, $Permission.grantedTo
    ) + @($Permission.grantedToIdentitiesV2) + @($Permission.grantedToIdentities)

    foreach ($identity in $identities) {
        if (-not $identity) { continue }
        $user = $identity.user
        if (-not $user) { continue }
        if ($GuestId -and "$($user.id)" -eq $GuestId) { return $true }
        if ($Email -and "$($user.email)" -eq $Email) { return $true }
        # SharePoint sometimes carries the address in displayName for a guest
        # that has not redeemed yet, and nowhere else.
        if ($Email -and "$($user.displayName)" -eq $Email) { return $true }
    }
    return $false
}

function Remove-CBSharedItemRecord {
    <#
    .SYNOPSIS
        Drops one entry from a guest's shared-item list.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$ItemKey)
    $items = @()
    try { $items = @("$($Row.SharedItems)" | ConvertFrom-Json) } catch { $items = @() }
    $kept = @($items | Where-Object { "$($_.id)" -ne $ItemKey })
    $json = ($kept | ConvertTo-Json -Depth 5 -Compress)
    if (-not $json) { $json = '[]' }
    if ($json -notmatch '^\[') { $json = "[$json]" }   # ConvertTo-Json unwraps a single-element array
    Save-CBGuestRecord -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)" -Properties @{ SharedItems = $json }
    return @($kept)
}

function Resolve-CBShareRecipient {
    <#
    .SYNOPSIS
        Works out who is being shared with: an existing guest, or a new one.
    .DESCRIPTION
        An existing guest may belong to a colleague. That is deliberate and is the
        point of showing everybody's guests in the search: sharing a file with a
        partner your colleague already works with should not create a second
        account for the same person. Ownership does not change, and the activity
        is recorded against the owner as well as the sharer.
    .OUTPUTS
        @{ Ok; Status; Error; Row; Email; DisplayName; Created; RedeemUrl; Warnings }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [string]$GuestId,
        $NewGuest,
        [string]$TargetUrl,
        [string]$TargetLabel,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }

    if ($GuestId) {
        $row = Get-CBGuestRow -GuestId $GuestId
        if (-not $row) { return @{ Ok = $false; Status = 404; Error = 'That external person is not set up here. Search for them again.' } }
        $state = "$($row.State)".ToLowerInvariant()
        if ($state -in @('blocked', 'deleted')) {
            return @{ Ok = $false; Status = 409
                Error = "$($row.DisplayName)'s access has ended, so sharing with them would not work. Whoever owns them needs to extend it first."
            }
        }
        return @{ Ok = $true; Status = 200; Row = $row; Email = "$($row.Email)"; DisplayName = "$($row.DisplayName)"
            Created = $false; RedeemUrl = ''; Warnings = @()
        }
    }

    if (-not $NewGuest -or -not "$($NewGuest.email)".Trim()) {
        return @{ Ok = $false; Status = 400; Error = 'Choose who you are sharing with, or fill in the details for somebody new.' }
    }

    # A brand new guest: create the account now so it can be granted access
    # immediately, and hold the invitation mail until we know the grant worked.
    $result = New-CBGuestInvitation -Caller $Caller -Settings $Settings -DeferMail `
        -Email "$($NewGuest.email)" -DisplayName "$($NewGuest.displayName)" -Reason "$($NewGuest.reason)" -Days $NewGuest.days `
        -TargetUrl $TargetUrl -TargetLabel $TargetLabel
    if (-not $result.Ok) { return @{ Ok = $false; Status = $result.Status; Error = $result.Error; Verdict = $result.Verdict } }

    if ($result.Simulated) {
        return @{ Ok = $true; Status = 200; Row = $null; Email = "$($NewGuest.email)"; DisplayName = "$($result.Guest.displayName)"
            Created = $true; Simulated = $true; RedeemUrl = ''; Warnings = @($result.Warnings)
        }
    }

    $row = Get-CBGuestRow -GuestId "$($result.Guest.id)"
    if (-not $row) {
        # The account exists in Entra but we cannot read our own record of it, so
        # we cannot record the share against them. Say so rather than carrying on
        # and losing track of a guest that was really created.
        return @{ Ok = $false; Status = 500
            Error = "$($NewGuest.email) was invited, but their record could not be read back, so the share was not attempted. Find them under your collaborators and share again."
        }
    }
    return @{ Ok = $true; Status = 200; Row = $row; Email = "$($result.Guest.email)"; DisplayName = "$($result.Guest.displayName)"
        Created = $true; RedeemUrl = "$($result.RedeemUrl)"; MailValues = $result.MailValues; Warnings = @($result.Warnings)
    }
}

function Invoke-CBShareRequest {
    <#
    .SYNOPSIS
        The whole "share this with them" action: resolve the recipient, invite
        them if they are new, grant the access, and send one branded mail.
    .DESCRIPTION
        The order is the interesting part.

          1. Resolve or create the guest. A new guest is created WITHOUT sending
             the invitation, because at this point we do not yet know whether the
             thing they are being invited to look at will actually be shareable.
          2. Grant the access, as the signed-in user.
          3. Only now send the mail, and send the version that matches what
             actually happened.

        If step 2 fails for a guest created in step 1, the guest still exists and
        is reported back so the portal can offer to retry just the share. Nothing
        is silently rolled back: an Entra account that was created stays created,
        and pretending otherwise would leave an orphan nobody knows about.
    .OUTPUTS
        @{ Ok; Status; Error; Guest; Shared; GuestCreated; Simulated; Warnings; Message }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)]$Target,
        [string]$GuestId,
        $NewGuest,
        [string]$Role,
        [string]$Message,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $warnings = [System.Collections.Generic.List[string]]::new()
    $kind = "$($Target.kind)".Trim().ToLowerInvariant()
    if ($kind -notin @('file', 'folder', 'team')) { return @{ Ok = $false; Status = 400; Error = 'Choose a file, a folder or a Team to share.' } }

    $capability = Test-CBSharingCapability -Kind $kind -Settings $Settings
    if (-not $capability.Allowed) { return @{ Ok = $false; Status = 403; Error = $capability.Reason } }

    # Read the target back as the user before doing anything else. The client
    # says what it picked; this is what it actually is, and whether they can see
    # it at all.
    $targetName = ''
    $targetUrl = ''
    if ($kind -eq 'team') {
        if (-not "$($Target.teamId)") { return @{ Ok = $false; Status = 400; Error = 'No Team was chosen.' } }
        # Ownership is NOT checked here. Adding the member runs as the user, so
        # Graph refuses if they do not own the Team, and listing every Team they
        # own just to validate one would cost a settings lookup per Team.
        $allows = Test-CBGroupAllowsGuest -GroupId "$($Target.teamId)"
        if (-not $allows.Allowed) { return @{ Ok = $false; Status = 409; Error = $allows.Reason } }
        $team = Get-CBTeamSummary -Caller $Caller -TeamId "$($Target.teamId)"
        if (-not $team.Ok) { return @{ Ok = $false; Status = 403; Error = $team.Error } }
        $targetName = "$($team.Name)"
        $targetUrl = "$($team.WebUrl)"
    }
    else {
        if (-not "$($Target.driveId)" -or -not "$($Target.itemId)") { return @{ Ok = $false; Status = 400; Error = 'No file or folder was chosen.' } }
        $item = $null
        try { $item = Get-CBDriveItem -Caller $Caller -DriveId "$($Target.driveId)" -ItemId "$($Target.itemId)" }
        catch { return @{ Ok = $false; Status = 403; Error = (Get-CBShareFailureMessage -Message "$($_.Exception.Message)" -ItemName 'that item' -Recipient '') } }
        if (-not $item) { return @{ Ok = $false; Status = 404; Error = 'That item could not be found any more.' } }
        # The client's claim about file vs folder is not trusted: the capability
        # gate has to be applied to what the item really is.
        if ($item.kind -ne $kind) {
            $realCapability = Test-CBSharingCapability -Kind $item.kind -Settings $Settings
            if (-not $realCapability.Allowed) { return @{ Ok = $false; Status = 403; Error = $realCapability.Reason } }
            $kind = $item.kind
        }
        $targetName = "$($item.name)"
        $targetUrl = "$($item.webUrl)"
    }

    # What SharePoint will refuse anyway, checked before a guest account is
    # created for it. Tenant level only; a site that blocks sharing inside a
    # tenant that allows it is not visible here and shows up at the grant.
    if ($kind -ne 'team') {
        $policy = Get-CBTenantSharingPolicy
        $wanted = if ("$($NewGuest.email)") { "$($NewGuest.email)" } else { '' }
        $allowed = Test-CBTenantAllowsSharingWith -Email $wanted -Policy $policy
        if (-not $allowed.Allowed) {
            return @{ Ok = $false; Status = 409; Error = $allowed.Reason; TenantPolicy = $true }
        }
    }

    # Only a target the welcome page will accept is put into the invitation; an
    # unrecognised host is dropped there rather than turning the page into an
    # open redirect. Get-CBWelcomeUrl enforces the same list.
    $recipient = Resolve-CBShareRecipient -Caller $Caller -Settings $Settings -GuestId $GuestId -NewGuest $NewGuest `
        -TargetUrl $targetUrl -TargetLabel $targetName
    if (-not $recipient.Ok) { return $recipient }
    foreach ($w in @($recipient.Warnings)) { $warnings.Add($w) }

    $role = Get-CBShareRole -Requested $Role -Settings $Settings

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would share $targetName with $($recipient.Email)" -Actor $Caller.Upn `
            -OwnerId $Caller.Oid -GuestUpn "$($recipient.Email)" -GuestDisplayName "$($recipient.DisplayName)" -Simulated `
            -Detail @{ kind = $kind; role = $role; target = $targetUrl }
        return @{ Ok = $true; Status = 200; Simulated = $true; GuestCreated = [bool]$recipient.Created
            Shared = [ordered]@{ kind = $kind; name = $targetName; webUrl = $targetUrl; role = $role }
            Guest = [ordered]@{ displayName = "$($recipient.DisplayName)"; email = "$($recipient.Email)" }
            Warnings = @($warnings)
            Message = 'Simulation mode is on, so nothing was actually shared or sent.'
        }
    }

    # --- Grant the access, as the user -------------------------------------
    $shareOk = $false
    $shareError = ''
    $shareDetail = ''
    $sitePolicy = $false
    if ($kind -eq 'team') {
        $add = Add-CBTeamGuest -Caller $Caller -TeamId "$($Target.teamId)" -GuestId "$($recipient.Row.RowKey)"
        $shareOk = $add.Ok
        $shareError = $add.Error
        $shareDetail = "$($add.Detail)"
        if ($add.AlreadyMember) { $warnings.Add("$($recipient.DisplayName) was already in $targetName.") }
    }
    else {
        $grant = Grant-CBItemAccess -Caller $Caller -DriveId "$($Target.driveId)" -ItemId "$($Target.itemId)" `
            -Email "$($recipient.Email)" -Role $role -ItemName $targetName -Message $Message
        $shareOk = $grant.Ok
        $shareError = $grant.Error
        $shareDetail = "$($grant.Detail)"
        $sitePolicy = [bool]$grant.SitePolicy
    }

    if (-not $shareOk) {
        Write-CBActivity -EventName "Could not share $targetName with $($recipient.Email)" -Actor $Caller.Upn `
            -OwnerId "$($recipient.Row.PartitionKey)" -GuestId "$($recipient.Row.RowKey)" -GuestUpn "$($recipient.Email)" `
            -GuestDisplayName "$($recipient.DisplayName)" -Detail @{ kind = $kind; error = $shareError }

        # A guest created a moment ago still exists. Say so plainly and hand back
        # their id, so the portal can retry the share alone instead of inviting
        # the same person a second time.
        return @{
            Ok = $false; Status = 502; Error = $shareError; Detail = $shareDetail
            GuestCreated = [bool]$recipient.Created
            Guest = [ordered]@{ id = "$($recipient.Row.RowKey)"; displayName = "$($recipient.DisplayName)"; email = "$($recipient.Email)" }
            Warnings = @($warnings)
            Retryable = $true
            # The site refused external sharing outright. The portal remembers
            # that for the session so nobody walks the same site twice.
            SitePolicy = $sitePolicy
            SiteId = "$($Target.siteId)"
        }
    }

    $shared = Add-CBSharedItemRecord -Row $recipient.Row -Kind $kind -Name $targetName -WebUrl $targetUrl -Role $role -SharedBy $Caller.Upn `
        -DriveId $(if ($kind -eq 'team') { '' } else { "$($Target.driveId)" }) `
        -ItemId $(if ($kind -eq 'team') { '' } else { "$($Target.itemId)" }) `
        -GroupId $(if ($kind -eq 'team') { "$($Target.teamId)" } else { '' })

    # --- Now, and only now, tell the guest ---------------------------------
    $values = if ($recipient.MailValues) { $recipient.MailValues } else { Get-CBGuestMailValue -Row $recipient.Row -Settings $Settings }
    $values.shareName = $targetName
    $values.shareUrl = $targetUrl
    $values.shareKind = $kind
    $values.sharedBy = @{ displayName = $Caller.DisplayName; email = $Caller.Upn }
    $values.message = (ConvertTo-CBBoundedString -Value $Message -MaxLength 500 -Default '' -AllowNewLines)

    $mailSent = $false
    $outbox = [System.Collections.Generic.List[object]]::new()
    $mailKey = if ($recipient.Created) { 'invitationWithShare' } else { 'sharedWithGuest' }
    if ($recipient.Created) { $values.redeemUrl = "$($recipient.RedeemUrl)" }
    try {
        $mail = Submit-CBGuestMail -Key $mailKey -To "$($recipient.Email)" -Values $values -Settings $Settings `
            -Caller $Caller -OwnerId "$($recipient.Row.PartitionKey)" -GuestId "$($recipient.Row.RowKey)"
        $mailSent = [bool]$mail.Sent
        if ($mail.Handed) { $outbox.Add($mail.Message) }
    }
    catch { Write-Warning "Mail to $($recipient.Email) failed: $($_.Exception.Message)" }
    if (-not $mailSent -and $outbox.Count -eq 0) {
        $warnings.Add($(if ($recipient.Created) { 'The access was granted but the invitation email could not be sent. They will not know until somebody tells them.' }
                else { "The access was granted but no email went out, so $($recipient.DisplayName) has not been told." }))
    }

    Write-CBActivity -EventName "Shared $targetName with $($recipient.Email)" -Actor $Caller.Upn `
        -OwnerId "$($recipient.Row.PartitionKey)" -GuestId "$($recipient.Row.RowKey)" -GuestUpn "$($recipient.Email)" `
        -GuestDisplayName "$($recipient.DisplayName)" `
        -Detail @{ kind = $kind; name = $targetName; role = $role; url = $targetUrl; invited = [bool]$recipient.Created; mailed = $mailSent }

    $verb = if ($kind -eq 'team') { "added to $targetName" } else { "given $role access to $targetName" }
    return @{
        Ok = $true; Status = 200; Simulated = $false
        GuestCreated = [bool]$recipient.Created
        Guest = [ordered]@{ id = "$($recipient.Row.RowKey)"; displayName = "$($recipient.DisplayName)"; email = "$($recipient.Email)" }
        Shared = [ordered]@{ kind = $kind; name = $targetName; webUrl = $targetUrl; role = $role }
        SharedItems = @($shared)
        Warnings = @($warnings)
        Outbox = @($outbox)
        Message = "$($recipient.DisplayName) has been $verb."
    }
}
