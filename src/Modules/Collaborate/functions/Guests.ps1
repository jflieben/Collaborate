# Guests: the record, the state machine, the search verdict and the invitation.
#
# Three ideas hold this file together.
#
#   1. EVERY GUEST HAS AN OWNER, A REASON AND AN END DATE. That is the whole
#      point of the tool, so the invitation transaction below refuses to create
#      a guest without all three, and writes the end date onto the guest object
#      itself (an extensionAttribute) as well as into our table.
#
#   2. SEARCH BEFORE INVITE, ALWAYS. Resolve-CBGuestVerdict answers "what is this
#      address, really?" before anybody sees an invitation form. The API enforces
#      the same answer on create, so a hand-crafted request cannot produce the
#      duplicate the UI refused to make.
#
#   3. THE PURE PART IS SEPARATE FROM THE GRAPH PART. Everything that decides a
#      date, a state or a verdict is a pure function with no network call, which
#      is what makes the interesting logic unit testable without a tenant.
#
# Ownership is the table's PartitionKey, so "my collaborators" is one partition
# query and a guest nobody owns lives in the 'orphaned' partition.

# --- Pure: dates ------------------------------------------------------------

function ConvertTo-CBDateOnly {
    <#
    .SYNOPSIS
        Parses a stored date ('yyyy-MM-dd' or a full ISO timestamp) to a UTC date,
        or $null. Invariant culture on purpose: the host's locale must never
        change what a stored date means.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse($Value.Trim(), [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.Date
    }
    return $null
}

function ConvertTo-CBUtcMoment {
    <#
    .SYNOPSIS
        Normalises a point in time to UTC, defaulting to now.
    .DESCRIPTION
        Every date in this file is a UTC calendar date, so a caller who hands in a
        local DateTime must not silently shift the answer by a day. PowerShell's
        [datetime] cast of an ISO string with a Z produces a LOCAL value, which is
        exactly how that mistake gets made. A Local value is converted; Utc and
        Unspecified are taken at face value, because guessing that an unspecified
        value means local would be a different wrong answer.
    #>
    [CmdletBinding()] param([datetime]$Value = [datetime]::MinValue)
    if ($Value -eq [datetime]::MinValue) { return [DateTime]::UtcNow }
    if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
    return $Value
}

function Get-CBExpiryDateString {
    <#
    .SYNOPSIS
        The end date this many days from now, as 'yyyy-MM-dd'.
    .DESCRIPTION
        Whole days on the UTC calendar, never hours: an end date a person can read
        on the guest object and reason about. Access lasts to the END of this day,
        which is what Get-CBGuestDaysLeft and Get-CBEffectiveGuestState assume.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][int]$Days, [datetime]$From = [datetime]::MinValue)
    return (ConvertTo-CBUtcMoment -Value $From).Date.AddDays($Days).ToString('yyyy-MM-dd')
}

function Format-CBFriendlyDate {
    <#
    .SYNOPSIS
        A stored date as '9 November 2026', for email and the portal. Returns the
        input unchanged if it is not a date, so a template never shows a blank
        where a date should be.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Value)
    $d = ConvertTo-CBDateOnly -Value $Value
    if (-not $d) { return "$Value" }
    return $d.ToString('d MMMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-CBGuestDaysLeft {
    <#
    .SYNOPSIS
        Whole days until access ends. 0 means "ends today", negative means it
        already has.
    #>
    [CmdletBinding()] param([AllowNull()][string]$ExpiresOn, [datetime]$Now = [datetime]::MinValue)
    $d = ConvertTo-CBDateOnly -Value $ExpiresOn
    if (-not $d) { return 0 }
    return [int]($d - (ConvertTo-CBUtcMoment -Value $Now).Date).TotalDays
}

# --- Pure: the state machine ------------------------------------------------

function Get-CBRedemptionState {
    <#
    .SYNOPSIS
        Has this guest ever accepted their invitation? accepted, pending, or
        honestly unknown.
    .DESCRIPTION
        Entra's externalUserState is 'PendingAcceptance' or 'Accepted' -- or
        NOTHING AT ALL. An empty value is completely normal for accounts created
        before the field existed, for guests who arrived by something other than
        an invitation, and for long-standing guests whose state Entra has since
        cleared.

        Reading an absent value as "pending" is what made every older guest show
        up as though they had been invited yesterday and never replied. It was
        also the more expensive half of that bug: 'pending' replaces the status
        line with "waiting for them to accept", so their end date -- the thing
        the tool exists to show -- disappeared from the list as well.

        A successful sign-in settles it, because nobody signs in to an
        invitation they never accepted. Failing that, unknown stays unknown: the
        portal states what it knows and says so when it does not know, rather
        than picking the more convenient of two guesses and printing it as fact.
    .OUTPUTS
        @{ State; At } - State is accepted, pending or unknown. At is when they
        accepted, when that can be established, and empty otherwise.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ExternalUserState,
        [AllowNull()][string]$StateChangedAt,
        [AllowNull()][string]$LastSignIn,
        [AllowNull()][string]$Created
    )
    $raw = "$ExternalUserState".Trim().ToLowerInvariant()
    if ($raw -eq 'accepted') {
        $at = @($StateChangedAt, $LastSignIn, $Created) | Where-Object { ConvertTo-CBDateOnly -Value $_ } | Select-Object -First 1
        return @{ State = 'accepted'; At = "$at" }
    }
    if ($raw -eq 'pendingacceptance') { return @{ State = 'pending'; At = '' } }
    if (ConvertTo-CBDateOnly -Value $LastSignIn) { return @{ State = 'accepted'; At = "$LastSignIn" } }
    return @{ State = 'unknown'; At = '' }
}

function Get-CBRedemptionLabel {
    <#
    .SYNOPSIS
        The acceptance state as a sentence, for the portal and for email.
    #>
    [CmdletBinding()] param([string]$State, [string]$At, [string]$InvitedAt)
    switch ("$State".ToLowerInvariant()) {
        'accepted' {
            if (ConvertTo-CBDateOnly -Value $At) { return "Accepted $(Format-CBFriendlyDate -Value $At)" }
            return 'Accepted'
        }
        'pending' {
            if (ConvertTo-CBDateOnly -Value $InvitedAt) { return "Invited $(Format-CBFriendlyDate -Value $InvitedAt), not accepted yet" }
            return 'Not accepted yet'
        }
        default { return 'Entra does not record whether they accepted' }
    }
}

function Get-CBEffectiveGuestState {
    <#
    .SYNOPSIS
        What state a guest is really in, from the stored state plus the calendar.
    .DESCRIPTION
        Only 'blocked' and 'deleted' are stored decisions: something was done to
        the account and the row records it. Everything else is derived, so a row
        can never disagree with its own end date just because a scan has not run
        yet.

            deleted   the account has been removed (row kept for the audit window)
            blocked   sign-in is off; still restorable during the grace period
            expired   the end date has passed but the scanner has not acted yet
            pending   invited, not yet accepted
            expiring  inside the reminder window
            active    everything is fine

        There is deliberately no 'unknown' state. Whether somebody accepted is a
        separate fact from whether their access is live, and conflating the two
        is what put long-standing guests in the pending pile. A guest whose
        acceptance cannot be established is treated as accepted for the purposes
        of the lifecycle -- their access is real and it still has to end on time
        -- and the doubt is reported next to them instead.
    .PARAMETER InviteState
        accepted, pending or unknown, as recorded on the row. Empty means the row
        predates the field, in which case RedeemedAt decides as it always did.
    #>
    [CmdletBinding()]
    param(
        [string]$StoredState,
        [string]$ExpiresOn,
        [string]$RedeemedAt,
        [int[]]$ReminderDays = @(30, 7, 1),
        [datetime]$Now = [datetime]::MinValue,
        [string]$InviteState
    )
    $stored = "$StoredState".Trim().ToLowerInvariant()
    if ($stored -eq 'deleted') { return 'deleted' }
    if ($stored -eq 'blocked') { return 'blocked' }

    $Now = ConvertTo-CBUtcMoment -Value $Now
    $daysLeft = Get-CBGuestDaysLeft -ExpiresOn $ExpiresOn -Now $Now
    $hasExpiry = [bool](ConvertTo-CBDateOnly -Value $ExpiresOn)

    if ($hasExpiry -and $daysLeft -lt 0) { return 'expired' }

    $invite = "$InviteState".Trim().ToLowerInvariant()
    $waiting = if ($invite) { $invite -eq 'pending' } else { -not $RedeemedAt }
    if ($waiting) { return 'pending' }

    $window = 0
    foreach ($d in @($ReminderDays)) { if ([int]$d -gt $window) { $window = [int]$d } }
    if ($hasExpiry -and $daysLeft -le $window) { return 'expiring' }
    return 'active'
}

function Get-CBGuestStateLabel {
    <#
    .SYNOPSIS
        The state as a sentence an employee understands. The portal shows this
        rather than the state name, because "expiring" on its own tells nobody
        when.
    #>
    [CmdletBinding()] param([string]$State, [int]$DaysLeft = 0, [string]$ExpiresOn)
    $on = Format-CBFriendlyDate -Value $ExpiresOn
    switch ("$State") {
        'pending' { return 'Invited, waiting for them to accept' }
        'active' { return "Active until $on" }
        'expiring' {
            if ($DaysLeft -le 0) { return "Ends today ($on)" }
            if ($DaysLeft -eq 1) { return "Ends tomorrow ($on)" }
            return "Ends in $DaysLeft days ($on)"
        }
        'expired' { return "Ended on $on" }
        'blocked' { return "Access switched off (ended $on)" }
        'deleted' { return 'Removed' }
        default { return "$State" }
    }
}

# --- Pure: who may be invited ------------------------------------------------

function Test-CBInviteAddress {
    <#
    .SYNOPSIS
        May this address be invited at all, on syntax and domain rules alone?
    .DESCRIPTION
        Runs before anything is looked up, so an obvious refusal costs no Graph
        call. Domain matching is exact: an admin who blocks 'partner.com' has not
        asked to block 'mail.partner.com', and guessing on their behalf would be
        the kind of surprise that gets a tool switched off.
    .PARAMETER TenantDomain
        The tenant's own verified domains. Somebody there is a colleague, not a
        guest, and inviting them would create a confusing duplicate identity.
    .OUTPUTS
        @{ Allowed; Reason; Domain }
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Email,
        $Settings,
        [string[]]$TenantDomain = @()
    )
    $address = "$Email".Trim()
    if (-not (Test-CBEmailAddress -Address $address) -or -not $address) {
        return @{ Allowed = $false; Reason = 'That does not look like an email address.'; Domain = '' }
    }
    $domain = ($address -split '@')[-1].ToLowerInvariant()

    foreach ($own in @($TenantDomain)) {
        if ("$own".Trim().ToLowerInvariant() -eq $domain) {
            return @{ Allowed = $false; Domain = $domain
                Reason = "$address is one of our own addresses, so they are a colleague rather than an external collaborator."
            }
        }
    }

    if (-not $Settings) { $Settings = Get-CBSettings }
    $blocked = @($Settings.invite.blockedDomains)
    if ($blocked -contains $domain) {
        return @{ Allowed = $false; Domain = $domain
            Reason = "Addresses at $domain cannot be invited. Ask an administrator if you think that is wrong."
        }
    }
    $allowed = @($Settings.invite.allowedDomains)
    if ($allowed.Count -gt 0 -and $allowed -notcontains $domain) {
        return @{ Allowed = $false; Domain = $domain
            Reason = "Only people at these domains can be invited: $($allowed -join ', ')."
        }
    }
    return @{ Allowed = $true; Reason = ''; Domain = $domain }
}

function Get-CBRequestedExpiry {
    <#
    .SYNOPSIS
        Turns a requested number of days into an end date the policy allows.
        Nothing a client sends can produce access longer than expiry.maxDays.
    .OUTPUTS
        @{ Days; ExpiresOn; Clamped }
    #>
    [CmdletBinding()] param([AllowNull()]$Days, $Settings, [datetime]$Now = [datetime]::MinValue)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $requested = ConvertTo-CBInt -Value $Days -Default ([int]$Settings.expiry.defaultDays) -Min 1 -Max 3650
    $max = [int]$Settings.expiry.maxDays
    $final = [Math]::Min($requested, $max)
    return @{
        Days      = $final
        ExpiresOn = (Get-CBExpiryDateString -Days $final -From $Now)
        Clamped   = ($final -ne $requested)
    }
}

# --- Pure: the portal shape --------------------------------------------------

function Get-CBGuestView {
    <#
    .SYNOPSIS
        One stored row as the portal renders it: derived state, days left, a
        readable status line, and the owner.
    .PARAMETER IncludeOwner
        Name the owner. The verdict path withholds this when the tenant has set
        guest visibility to 'owned', so a search still says "somebody already
        works with them" without disclosing who to everybody.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        $Settings,
        [datetime]$Now = [datetime]::MinValue,
        [switch]$IncludeOwner,
        # What the guest can reach. Off for lists: a tenant with a thousand
        # guests and fifty items each would send several megabytes to render a
        # table that shows none of it.
        [switch]$IncludeShared,
        # Who is looking, so the shared-item list can be redacted for them. Two
        # colleagues can share with the same guest, and a document name is
        # itself information.
        $Viewer
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $Now = ConvertTo-CBUtcMoment -Value $Now

    $expiresOn = "$($Row.ExpiresOn)"
    $inviteState = "$($Row.InviteState)"
    $state = Get-CBEffectiveGuestState -StoredState "$($Row.State)" -ExpiresOn $expiresOn `
        -RedeemedAt "$($Row.RedeemedAtUtc)" -ReminderDays @($Settings.expiry.reminderDays) -Now $Now `
        -InviteState $inviteState
    $daysLeft = Get-CBGuestDaysLeft -ExpiresOn $expiresOn -Now $Now

    # Acceptance is reported next to the guest rather than folded into the state,
    # so "we do not know whether they ever accepted" and "their access ends on
    # Friday" can both be true and both be said.
    $redemption = if ($inviteState) { $inviteState }
    elseif ("$($Row.RedeemedAtUtc)") { 'accepted' }
    else { 'pending' }
    $lastSignIn = "$($Row.LastSignInUtc)"

    $view = [ordered]@{
        id          = "$($Row.RowKey)"
        email       = "$($Row.Email)"
        displayName = "$($Row.DisplayName)"
        state       = $state
        statusLabel = (Get-CBGuestStateLabel -State $state -DaysLeft $daysLeft -ExpiresOn $expiresOn)
        expiresOn   = $expiresOn
        expiresOnLabel = (Format-CBFriendlyDate -Value $expiresOn)
        daysLeft    = $daysLeft
        reason      = "$($Row.Reason)"
        source      = $(if ("$($Row.Source)") { "$($Row.Source)" } else { 'collaborate' })
        invitedAt   = "$($Row.InvitedAtUtc)"
        redeemedAt  = "$($Row.RedeemedAtUtc)"
        redemption  = $redemption
        redemptionLabel = (Get-CBRedemptionLabel -State $redemption -At "$($Row.RedeemedAtUtc)" -InvitedAt "$($Row.InvitedAtUtc)")
        lastSignIn  = $lastSignIn
        lastSignInLabel = $(if (ConvertTo-CBDateOnly -Value $lastSignIn) { Format-CBFriendlyDate -Value $lastSignIn } else { '' })
        graceUntil  = "$($Row.GraceUntil)"
        renewCount  = (ConvertTo-CBInt -Value $Row.RenewCount -Default 0 -Min 0)
        orphaned    = ("$($Row.PartitionKey)" -eq (Get-CBOrphanPartition))
    }
    if ($IncludeOwner) {
        $view.owner = [ordered]@{
            id          = "$($Row.PartitionKey)"
            displayName = "$($Row.OwnerDisplayName)"
            email       = "$($Row.OwnerUpn)"
        }
        if ($view.orphaned) { $view.owner.id = ''; $view.owner.displayName = 'nobody'; $view.owner.email = '' }
    }
    if ($IncludeShared) {
        $view.sharedItems = @(Get-CBSharedItemView -Json "$($Row.SharedItems)" -Now $Now `
                -ViewerUpn "$($Viewer.Upn)" -ViewerIsAdmin:([bool]$Viewer.IsAdmin))
    }
    return $view
}

function Get-CBGuestSortKey {
    <#
    .SYNOPSIS
        Orders a list of guests by how much they need somebody's attention, then
        by how soon they end.
    .DESCRIPTION
        Sorting alphabetically would bury the one guest whose access lapses
        tomorrow under thirty who are fine. A list an employee opens once a
        quarter has to put the actionable rows at the top or it may as well not
        exist.
    #>
    [CmdletBinding()] param([string]$State, [int]$DaysLeft = 0)
    $rank = switch ("$State") {
        'blocked' { 0 }
        'expired' { 1 }
        'expiring' { 2 }
        'pending' { 3 }
        'active' { 4 }
        'deleted' { 6 }
        default { 5 }
    }
    # Days are offset so that a large negative (long expired) still sorts after a
    # small one within the same rank, and clamped so the key stays sortable.
    $days = [Math]::Max(0, [Math]::Min(99999, $DaysLeft + 10000))
    return ('{0}:{1:D5}' -f $rank, $days)
}

# --- Storage -----------------------------------------------------------------

function Get-CBGuestPartitionKey {
    [CmdletBinding()] param([AllowNull()][string]$OwnerId)
    if ([string]::IsNullOrWhiteSpace($OwnerId)) { return (Get-CBOrphanPartition) }
    return $OwnerId
}

function Set-CBRowValue {
    <#
    .SYNOPSIS
        Sets a property on a row object whether or not it already has one.
    .DESCRIPTION
        Table storage does not return properties that were never written, so a
        row's shape depends on its history: a guest that has never been blocked
        has no GraceUntil at all. Plain assignment to a missing property on a
        PSCustomObject throws, so anything that updates an in-memory copy of a row
        before passing it on goes through here.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$Name, $Value)
    $Row | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    return $Row
}

function Get-CBOwnerGuestRow {
    <#
    .SYNOPSIS
        Every guest one person owns: a single partition query.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$OwnerId)
    $tables = Get-CBTableNames
    return @(Get-CBTableEntities -Table $tables.Guests -Filter ("PartitionKey eq '{0}'" -f (ConvertTo-CBODataKey $OwnerId)))
}

function Get-CBAllGuestRow {
    <#
    .SYNOPSIS
        Every tracked guest. A few thousand rows is a trivial scan, and loading
        them once is far cheaper than a lookup per guest during the daily sync.
    #>
    [CmdletBinding()] param([string]$Filter)
    $tables = Get-CBTableNames
    return @(Get-CBTableEntities -Table $tables.Guests -Filter $Filter)
}

function Get-CBGuestRow {
    <#
    .SYNOPSIS
        One guest by object id, without knowing who owns them. Cross-partition,
        which is why it is only used on single-guest paths and never in a loop.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GuestId)
    $rows = Get-CBAllGuestRow -Filter ("RowKey eq '{0}'" -f (ConvertTo-CBODataKey $GuestId))
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Save-CBGuestRecord {
    <#
    .SYNOPSIS
        Writes (or merges into) a guest row. MERGE so that a caller updating one
        field cannot silently erase the rest of the record.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$OwnerId,
        [Parameter(Mandatory)][string]$GuestId,
        [Parameter(Mandatory)][hashtable]$Properties,
        [switch]$Replace
    )
    $tables = Get-CBTableNames
    $pk = Get-CBGuestPartitionKey -OwnerId $OwnerId
    $props = @{} + $Properties
    $props.OwnerId = $(if ($pk -eq (Get-CBOrphanPartition)) { '' } else { $pk })
    $props.UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    if ($Replace) { Set-CBTableEntity -Table $tables.Guests -PartitionKey $pk -RowKey $GuestId -Properties $props }
    else { Merge-CBTableEntity -Table $tables.Guests -PartitionKey $pk -RowKey $GuestId -Properties $props }
}

# --- Graph: the directory ----------------------------------------------------

$script:CBGuestSelect = 'id,displayName,mail,userPrincipalName,userType,externalUserState,externalUserStateChangeDateTime,accountEnabled,createdDateTime,onPremisesExtensionAttributes'

function Get-CBDirectoryUser {
    <#
    .SYNOPSIS
        One directory object by id, or $null when it no longer exists.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$UserId)
    try {
        $r = Invoke-CBGraph -Raw -Uri ('/users/' + [Uri]::EscapeDataString($UserId) + '?$select=' + $script:CBGuestSelect)
        if ($r.StatusCode -ge 400 -or -not $r.Body.id) { return $null }
        return $r.Body
    }
    catch { return $null }
}

function Find-CBDirectoryUserByEmail {
    <#
    .SYNOPSIS
        Finds an existing account for an email address, guest or member.
    .DESCRIPTION
        A B2B guest's userPrincipalName is mangled
        (jane_partner.com#EXT#@contoso.onmicrosoft.com), so the address they were
        invited with lives in 'mail' and in 'otherMails'. Both are checked, plus
        userPrincipalName for the case where somebody types a colleague's address.
        Missing any of these would mean inviting a person who already exists,
        which is the exact duplication this tool exists to stop.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Email)
    $address = "$Email".Trim()
    if (-not $address) { return $null }
    $safe = $address.Replace("'", "''")
    $select = '$select=' + $script:CBGuestSelect

    $byMail = [Uri]::EscapeDataString("mail eq '$safe'")
    $byOther = [Uri]::EscapeDataString("otherMails/any(m:m eq '$safe')")
    $byUpn = [Uri]::EscapeDataString("userPrincipalName eq '$safe'")
    $queries = @(
        "/users?`$filter=$byMail&$select&`$top=2",
        # otherMails/any is an advanced query: it needs $count=true as well as the
        # ConsistencyLevel header Invoke-CBGraph always sends.
        "/users?`$count=true&`$filter=$byOther&$select&`$top=2",
        "/users?`$filter=$byUpn&$select&`$top=2"
    )
    foreach ($q in $queries) {
        try {
            $r = Invoke-CBGraph -Uri $q
            $hit = @($r.value) | Select-Object -First 1
            if ($hit -and $hit.id) { return $hit }
        }
        catch { Write-Warning "Directory lookup for '$address' failed on one query shape: $($_.Exception.Message)" }
    }
    return $null
}

function Search-CBGuestDirectory {
    <#
    .SYNOPSIS
        Fuzzy search over the tenant's guests, annotated with who owns each one.
    .DESCRIPTION
        This is the box a user types into before they are allowed to invite
        anybody, so it has to find people rather than require an exact address.
        $search does token matching; if the tenant refuses it for any reason we
        fall back to prefix matching rather than returning nothing, because
        "no results" here leads straight to a duplicate invitation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Search,
        [Parameter(Mandatory)]$Caller,
        $Settings,
        [int]$Top = 15
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $term = "$Search".Trim()
    if ($term.Length -lt 2) { return @() }

    $select = '$select=' + $script:CBGuestSelect
    $guestFilter = [Uri]::EscapeDataString("userType eq 'Guest'")
    $found = @()
    try {
        $expr = '"displayName:{0}" OR "mail:{0}"' -f $term
        $uri = "/users?`$count=true&`$filter=$guestFilter&`$search=$([Uri]::EscapeDataString($expr))&$select&`$top=$Top"
        $found = @((Invoke-CBGraph -Uri $uri).value)
    }
    catch {
        Write-Warning "Token search over guests failed, falling back to prefix matching: $($_.Exception.Message)"
        $safe = $term.Replace("'", "''")
        $filter = "userType eq 'Guest' and (startswith(displayName,'$safe') or startswith(mail,'$safe'))"
        try { $found = @((Invoke-CBGraph -Uri "/users?`$filter=$([Uri]::EscapeDataString($filter))&$select&`$top=$Top").value) }
        catch { Write-Warning "Guest search failed entirely: $($_.Exception.Message)"; return @() }
    }
    if (-not $found -or $found.Count -eq 0) { return @() }

    # Annotate with ownership from our own table. One scan, then an index: the
    # alternative is a table lookup per hit on every keystroke.
    $rows = @{}
    foreach ($row in Get-CBAllGuestRow) { $rows["$($row.RowKey)"] = $row }

    $showOwner = ($Caller.IsAdmin -or "$($Settings.invite.guestDirectoryVisibility)" -eq 'all')
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $found) {
        $row = $rows["$($u.id)"]
        $ownerId = if ($row) { "$($row.PartitionKey)" } else { '' }
        $isMine = ($ownerId -eq $Caller.Oid)
        # With visibility set to 'owned', a user searching before a share only
        # sees their own collaborators; everyone else's are hidden entirely.
        if (-not $showOwner -and -not $isMine) { continue }

        $entry = [ordered]@{
            id          = "$($u.id)"
            displayName = "$($u.displayName)"
            email       = $(if ($u.mail) { "$($u.mail)" } else { "$($u.userPrincipalName)" })
            state       = $(if ($row) { (Get-CBGuestView -Row $row -Settings $Settings).state } else { 'untracked' })
            mine        = $isMine
            tracked     = [bool]$row
            owner       = [ordered]@{ id = ''; displayName = ''; email = '' }
        }
        if ($row -and $ownerId -ne (Get-CBOrphanPartition)) {
            $entry.owner.id = $ownerId
            $entry.owner.displayName = "$($row.OwnerDisplayName)"
            $entry.owner.email = "$($row.OwnerUpn)"
        }
        $results.Add($entry)
    }
    return @($results)
}

# --- The verdict -------------------------------------------------------------

function Resolve-CBGuestVerdict {
    <#
    .SYNOPSIS
        What is this address, and what should the portal offer to do about it?
    .DESCRIPTION
        The single answer both the UI and POST /api/guests act on, so the browser
        and a hand-crafted request cannot reach different conclusions.

            refused    domain or syntax rules say no
            internal   it is a colleague, not an external person
            mine       already yours
            other      a colleague already works with them
            unowned    exists in the directory, nobody is accountable
            notFound   go ahead and invite

        'unowned' covers both a guest that predates Collaborate and one whose
        owner has left, because from the user's point of view they are the same
        problem: somebody has to claim them.
    .OUTPUTS
        @{ Verdict; Message; Guest; Owner; CanInvite; CanClaim; CanAsk }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$Email,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $address = "$Email".Trim()

    # If the verified-domain list cannot be read we carry on with an empty one.
    # That weakens the "this is a colleague" check but does not remove it: the
    # directory lookup below still recognises an internal member by userType.
    $domains = @()
    try { $domains = Get-CBTenantDomains } catch { Write-Warning "Could not read the tenant's verified domains: $($_.Exception.Message)" }
    $check = Test-CBInviteAddress -Email $address -Settings $Settings -TenantDomain $domains
    if (-not $check.Allowed) {
        return @{ Verdict = 'refused'; Message = $check.Reason; CanInvite = $false; CanClaim = $false; CanAsk = $false }
    }

    $existing = Find-CBDirectoryUserByEmail -Email $address
    if (-not $existing) {
        return @{ Verdict = 'notFound'; CanInvite = $true; CanClaim = $false; CanAsk = $false
            Message = "$address is not set up here yet. You can invite them."
        }
    }

    if ("$($existing.userType)" -ne 'Guest') {
        return @{ Verdict = 'internal'; CanInvite = $false; CanClaim = $false; CanAsk = $false
            Guest = [ordered]@{ id = "$($existing.id)"; displayName = "$($existing.displayName)"; email = $address }
            Message = "$($existing.displayName) is a colleague, not an external person. Email them directly instead."
        }
    }

    $row = Get-CBGuestRow -GuestId "$($existing.id)"
    $guest = [ordered]@{
        id          = "$($existing.id)"
        displayName = "$($existing.displayName)"
        email       = $(if ($existing.mail) { "$($existing.mail)" } else { $address })
        state       = 'untracked'
    }

    if (-not $row) {
        return @{ Verdict = 'unowned'; CanInvite = $false; CanClaim = $true; CanAsk = $false; Guest = $guest
            Message = "$($existing.displayName) already exists here but nobody is responsible for them. Claim them and they get an end date like everybody else."
        }
    }

    $showOwner = ($Caller.IsAdmin -or "$($Settings.invite.guestDirectoryVisibility)" -eq 'all')
    $view = Get-CBGuestView -Row $row -Settings $Settings -IncludeOwner
    $guest.state = $view.state
    $guest.statusLabel = $view.statusLabel
    $guest.expiresOn = $view.expiresOn

    if ("$($row.PartitionKey)" -eq (Get-CBOrphanPartition)) {
        return @{ Verdict = 'unowned'; CanInvite = $false; CanClaim = $true; CanAsk = $false; Guest = $guest
            Message = "$($existing.displayName) is set up here but nobody owns them. You can take them on."
        }
    }
    if ("$($row.PartitionKey)" -eq $Caller.Oid) {
        return @{ Verdict = 'mine'; CanInvite = $false; CanClaim = $false; CanAsk = $false; Guest = $guest
            Message = "$($existing.displayName) is already on your list. $($view.statusLabel)."
        }
    }

    $owner = [ordered]@{ id = ''; displayName = 'a colleague'; email = '' }
    if ($showOwner) {
        $owner.id = "$($row.PartitionKey)"
        $owner.displayName = "$($row.OwnerDisplayName)"
        $owner.email = "$($row.OwnerUpn)"
    }
    return @{
        Verdict = 'other'; CanInvite = $false; CanClaim = $false; CanAsk = [bool]$showOwner
        Guest = $guest; Owner = $owner
        Message = "$($existing.displayName) already works with us. $($owner.displayName) looks after them, so there is no need to invite them again."
    }
}

# --- Graph: writing to the guest object --------------------------------------

function Set-CBGuestExpiryAttribute {
    <#
    .SYNOPSIS
        Writes the end date onto the guest object itself.
    .DESCRIPTION
        This is deliberately not only in our table. On the object it survives this
        tool entirely, shows up in the Entra portal, and can drive dynamic groups
        or Conditional Access. If this write fails the invitation is still real,
        so the caller logs it rather than pretending nothing happened.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GuestId, [Parameter(Mandatory)][string]$ExpiresOn, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $attribute = "$($Settings.expiry.attribute)"
    if (-not (Test-CBExpiryAttributeName -Name $attribute)) { throw "Configured expiry attribute '$attribute' is not one of extensionAttribute1..15." }
    $body = @{ onPremisesExtensionAttributes = @{ $attribute = $ExpiresOn } }
    Invoke-CBGraph -Method Patch -Uri ('/users/' + [Uri]::EscapeDataString($GuestId)) -Body $body | Out-Null
}

function Add-CBGuestSponsor {
    <#
    .SYNOPSIS
        Records the owner as the guest's native Entra sponsor, so ownership is
        legible outside this tool. Best effort: not every tenant exposes it, and
        an invitation must not fail over a nicety.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GuestId, [Parameter(Mandatory)][string]$OwnerId)
    $cfg = Get-CBConfig
    $path = '/users/' + [Uri]::EscapeDataString($GuestId) + '/sponsors/$ref'
    foreach ($version in @('v1.0', 'beta')) {
        try {
            $body = @{ '@odata.id' = '{0}/{1}/directoryObjects/{2}' -f $cfg.GraphResource, $version, $OwnerId }
            Invoke-CBGraph -Method Post -Uri $path -ApiVersion $version -Body $body | Out-Null
            return $true
        }
        catch {
            # Already a sponsor is a success, not a failure.
            if ("$($_)" -match 'already exist|One or more added object references already exist') { return $true }
            if ($version -eq 'beta') { Write-Warning "Could not set the sponsor for guest ${GuestId}: $($_.Exception.Message)" }
        }
    }
    return $false
}

# --- The invitation transaction ----------------------------------------------

function New-CBGuestInvitation {
    <#
    .SYNOPSIS
        Invites an external person and records who owns them, why, and until when.
    .DESCRIPTION
        The order matters. Everything that can refuse the request runs before
        anything is created, so a refusal leaves no half-made guest:

            1. the verdict (domain rules, duplicates, colleagues)
            2. may this person invite at all
            3. their own daily limit, then the tenant-wide storm guard
            4. create the invitation, WITHOUT Microsoft's own mail
            5. write the end date onto the object, and the sponsor
            6. write our row
            7. send our branded invitation

        Steps 5 to 7 are past the point of no return: the guest exists. If one of
        them fails it is logged and reported, never silently swallowed, because
        the guest is real either way and somebody has to know.
    .OUTPUTS
        @{ Ok; Status; Error; Guest; Verdict; Simulated; Warnings }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$Email,
        [string]$DisplayName,
        [string]$Reason,
        [AllowNull()]$Days,
        [string]$TargetUrl,
        [string]$TargetLabel,
        # Create the guest but do not send the invitation yet. The sharing flow
        # uses this so the mail can go out AFTER the share has actually worked,
        # rather than promising a guest a file they cannot open.
        [switch]$DeferMail,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $warnings = [System.Collections.Generic.List[string]]::new()
    $address = "$Email".Trim()

    $canInvite = Test-CBCanInvite -Caller $Caller -Settings $Settings
    if (-not $canInvite.Allowed) { return @{ Ok = $false; Status = 403; Error = $canInvite.Reason } }

    if ($Settings.invite.requireReason -and -not "$Reason".Trim()) {
        return @{ Ok = $false; Status = 400; Error = 'Please say why you need to work with this person. It is recorded against the guest so a colleague can understand it later.' }
    }

    $verdict = Resolve-CBGuestVerdict -Caller $Caller -Email $address -Settings $Settings
    if ($verdict.Verdict -ne 'notFound') {
        $status = if ($verdict.Verdict -eq 'refused') { 400 } else { 409 }
        return @{ Ok = $false; Status = $status; Error = $verdict.Message; Verdict = $verdict }
    }

    $quota = Test-CBUserInviteQuota -Oid $Caller.Oid -Settings $Settings
    if (-not $quota.Allowed) { return @{ Ok = $false; Status = 429; Error = $quota.Reason } }

    $expiry = Get-CBRequestedExpiry -Days $Days -Settings $Settings
    if ($expiry.Clamped) { $warnings.Add("Access was shortened to $($expiry.Days) days, which is the longest this tenant allows.") }

    $name = ConvertTo-CBBoundedString -Value $DisplayName -MaxLength 120 -Default $address
    $why = ConvertTo-CBBoundedString -Value $Reason -MaxLength 400 -Default ''

    # Where the guest lands after redeeming. Setup cannot complete without a
    # working public site, so this should never fail; if it somehow does, refuse
    # rather than create a guest whose invitation leads nowhere.
    $redirect = $null
    try { $redirect = Get-CBWelcomeUrl -TargetUrl $TargetUrl -TargetLabel $TargetLabel -Settings $Settings }
    catch {
        Write-Warning "Could not build the welcome URL: $($_.Exception.Message)"
        return @{ Ok = $false; Status = 503; Error = 'The public welcome page is not configured, so an invitation would lead nowhere. An administrator should re-run setup.' }
    }

    # Simulation: everything above has been evaluated for real, so the answer the
    # user gets is honest about whether it WOULD have worked. Nothing below runs.
    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would invite $address" -Actor $Caller.Upn -OwnerId $Caller.Oid `
            -GuestUpn $address -GuestDisplayName $name -Simulated -Detail @{
            reason = $why; expiresOn = $expiry.ExpiresOn; redirect = $redirect
        }
        return @{
            Ok = $true; Status = 200; Simulated = $true; Warnings = @($warnings)
            Guest = [ordered]@{
                id = ''; email = $address; displayName = $name; state = 'pending'
                expiresOn = $expiry.ExpiresOn; expiresOnLabel = (Format-CBFriendlyDate -Value $expiry.ExpiresOn)
                reason = $why
                statusLabel = 'Nothing was sent: simulation mode is on'
            }
        }
    }

    $guard = Test-CBStormGuard -Action 'invite' -Settings $Settings
    if (-not $guard.Allowed) { return @{ Ok = $false; Status = 429; Error = $guard.Reason } }

    # sendInvitationMessage stays false on purpose: the guest gets OUR mail, in
    # the tenant's branding, not Microsoft's default one.
    $invitation = Invoke-CBGraph -Method Post -Uri '/invitations' -Body @{
        invitedUserEmailAddress = $address
        invitedUserDisplayName  = $name
        inviteRedirectUrl       = $redirect
        sendInvitationMessage   = $false
    }
    $guestId = "$($invitation.invitedUser.id)"
    if (-not $guestId) { return @{ Ok = $false; Status = 502; Error = 'Entra accepted the invitation but did not return the new account. Search for the person before trying again.' } }
    [void](Add-CBUserInviteCount -Oid $Caller.Oid)

    try { Set-CBGuestExpiryAttribute -GuestId $guestId -ExpiresOn $expiry.ExpiresOn -Settings $Settings }
    catch {
        Write-Warning "Could not write the expiry attribute for ${guestId}: $($_.Exception.Message)"
        $warnings.Add('The end date could not be written onto the account itself, so it is only recorded here. An administrator should check the Diagnostics tab.')
    }

    if ($Settings.invite.setSponsor) {
        if (-not (Add-CBGuestSponsor -GuestId $guestId -OwnerId $Caller.Oid)) {
            $warnings.Add('The sponsor could not be recorded in Entra. This is cosmetic: ownership is still tracked here.')
        }
    }

    $now = [DateTimeOffset]::UtcNow.ToString('o')
    Save-CBGuestRecord -OwnerId $Caller.Oid -GuestId $guestId -Replace -Properties @{
        Email            = $address
        DisplayName      = $name
        Upn              = "$($invitation.invitedUser.userPrincipalName)"
        OwnerUpn         = $Caller.Upn
        OwnerDisplayName = $Caller.DisplayName
        Reason           = $why
        Source           = 'collaborate'
        InvitedAtUtc     = $now
        RedeemedAtUtc    = ''
        ExpiresOn        = $expiry.ExpiresOn
        State            = 'pending'
        # We created this invitation a second ago, so this is the one case where
        # "not accepted yet" is a fact rather than an inference.
        InviteState      = 'pending'
        RemindersSent    = ''
        SharedItems      = '[]'
        RenewCount       = '0'
        # Written empty rather than omitted so every row has the same shape:
        # Table storage does not return properties that were never set.
        GraceUntil       = ''
        BlockedAtUtc     = ''
        DeletedAtUtc     = ''
        LastSignInUtc    = ''
    }

    $values = Get-CBMailTokenValue -Settings $Settings
    $values.guest = @{ displayName = $name; email = $address }
    $values.owner = @{ displayName = $Caller.DisplayName; email = $Caller.Upn }
    $values.reason = $why
    $values.expiresOn = Format-CBFriendlyDate -Value $expiry.ExpiresOn
    $values.redeemUrl = "$($invitation.inviteRedeemUrl)"
    if ($TargetUrl) { $values.shareUrl = $TargetUrl; $values.shareName = $TargetLabel }

    $templateKey = if ($TargetUrl -and $TargetLabel) { 'invitationWithShare' } else { 'invitation' }
    $outbox = [System.Collections.Generic.List[object]]::new()
    if (-not $DeferMail) {
        try {
            $mail = Submit-CBGuestMail -Key $templateKey -To $address -Values $values -Settings $Settings `
                -Caller $Caller -OwnerId $Caller.Oid -GuestId $guestId
            if ($mail.Handed) { $outbox.Add($mail.Message) }
            elseif (-not $mail.Sent) {
                $warnings.Add("The invitation was created but no email went out (the '$templateKey' message may be switched off). They can still be sent the link.")
            }
        }
        catch {
            Write-Warning "Invitation mail to $address failed: $($_.Exception.Message)"
            $warnings.Add('The account was created but the invitation email could not be sent. An administrator should check the mail configuration.')
        }
    }

    Write-CBActivity -EventName "Invited $address" -Actor $Caller.Upn -OwnerId $Caller.Oid `
        -GuestId $guestId -GuestUpn $address -GuestDisplayName $name -Detail @{
        reason = $why; expiresOn = $expiry.ExpiresOn; days = $expiry.Days
    }

    $row = Get-CBGuestRow -GuestId $guestId
    $view = if ($row) { Get-CBGuestView -Row $row -Settings $Settings } else {
        [ordered]@{ id = $guestId; email = $address; displayName = $name; state = 'pending'; expiresOn = $expiry.ExpiresOn }
    }
    return @{
        Ok = $true; Status = 201; Guest = $view; Warnings = @($warnings); Simulated = $false
        # Messages the caller's browser is being asked to send as itself. Empty
        # unless the tenant has chosen that, which is the default.
        Outbox = @($outbox)
        # Returned so a deferred caller can send the invitation itself once it
        # knows what else it managed to do for this guest.
        RedeemUrl = "$($invitation.inviteRedeemUrl)"
        MailValues = $values
        MailTemplate = $templateKey
    }
}

function Register-CBExistingGuest {
    <#
    .SYNOPSIS
        Claims a guest nobody owns: the caller becomes accountable and the guest
        gets an end date like everybody else.
    .DESCRIPTION
        Only ever applied to guests in the orphan partition or with no row at all.
        Taking one off a colleague is a transfer, which is a different thing and
        needs their involvement.
    .OUTPUTS
        @{ Ok; Status; Error; Guest; Warnings }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$GuestId,
        [string]$Reason,
        [AllowNull()]$Days,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $warnings = [System.Collections.Generic.List[string]]::new()

    $user = Get-CBDirectoryUser -UserId $GuestId
    if (-not $user) { return @{ Ok = $false; Status = 404; Error = 'That account no longer exists.' } }
    if ("$($user.userType)" -ne 'Guest') { return @{ Ok = $false; Status = 400; Error = 'That is a colleague, not an external collaborator.' } }

    $existing = Get-CBGuestRow -GuestId $GuestId
    if ($existing -and "$($existing.PartitionKey)" -ne (Get-CBOrphanPartition)) {
        if ("$($existing.PartitionKey)" -eq $Caller.Oid) { return @{ Ok = $false; Status = 409; Error = 'They are already on your list.' } }
        return @{ Ok = $false; Status = 409; Error = "$($existing.OwnerDisplayName) already looks after them. Ask them to hand the account over." }
    }

    if ($Settings.invite.requireReason -and -not "$Reason".Trim()) {
        return @{ Ok = $false; Status = 400; Error = 'Please say why you work with this person.' }
    }

    $expiry = Get-CBRequestedExpiry -Days $Days -Settings $Settings
    $address = if ($user.mail) { "$($user.mail)" } else { "$($user.userPrincipalName)" }
    $name = "$($user.displayName)"
    $why = ConvertTo-CBBoundedString -Value $Reason -MaxLength 400 -Default ''

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would take ownership of $address" -Actor $Caller.Upn -OwnerId $Caller.Oid `
            -GuestId $GuestId -GuestUpn $address -GuestDisplayName $name -Simulated -Detail @{ reason = $why; expiresOn = $expiry.ExpiresOn }
        return @{ Ok = $true; Status = 200; Simulated = $true; Warnings = @()
            Guest = [ordered]@{ id = $GuestId; email = $address; displayName = $name; state = 'active'
                expiresOn = $expiry.ExpiresOn; statusLabel = 'Nothing was changed: simulation mode is on' }
        }
    }

    try { Set-CBGuestExpiryAttribute -GuestId $GuestId -ExpiresOn $expiry.ExpiresOn -Settings $Settings }
    catch {
        Write-Warning "Could not write the expiry attribute for ${GuestId}: $($_.Exception.Message)"
        $warnings.Add('The end date could not be written onto the account itself, so it is only recorded here.')
    }
    if ($Settings.invite.setSponsor) { [void](Add-CBGuestSponsor -GuestId $GuestId -OwnerId $Caller.Oid) }

    # An adopted guest is already redeemed if Entra says so, so it starts active
    # rather than pending and never waits for an acceptance that happened long ago.
    # An empty externalUserState is not evidence of anything, so it is recorded as
    # unknown rather than being read as "invited and ignored us".
    $redemption = Get-CBRedemptionState -ExternalUserState "$($user.externalUserState)" `
        -StateChangedAt "$($user.externalUserStateChangeDateTime)" `
        -LastSignIn $(if ($existing) { "$($existing.LastSignInUtc)" } else { '' }) -Created "$($user.createdDateTime)"
    $redeemed = "$($redemption.At)"
    if ($existing) {
        # Claiming moves the row between partitions, so the orphan copy has to go.
        try { Remove-CBTableEntity -Table (Get-CBTableNames).Guests -PartitionKey (Get-CBOrphanPartition) -RowKey $GuestId }
        catch { Write-Warning "Could not remove the unowned copy of ${GuestId}: $($_.Exception.Message)" }
        if ($existing.RedeemedAtUtc) { $redeemed = "$($existing.RedeemedAtUtc)" }
    }

    Save-CBGuestRecord -OwnerId $Caller.Oid -GuestId $GuestId -Replace -Properties @{
        Email            = $address
        DisplayName      = $name
        Upn              = "$($user.userPrincipalName)"
        OwnerUpn         = $Caller.Upn
        OwnerDisplayName = $Caller.DisplayName
        Reason           = $why
        Source           = 'adopted'
        InvitedAtUtc     = $(if ($existing -and $existing.InvitedAtUtc) { "$($existing.InvitedAtUtc)" } else { "$($user.createdDateTime)" })
        RedeemedAtUtc    = $redeemed
        ExpiresOn        = $expiry.ExpiresOn
        State            = 'active'
        InviteState      = "$($redemption.State)"
        RemindersSent    = ''
        SharedItems      = $(if ($existing -and $existing.SharedItems) { "$($existing.SharedItems)" } else { '[]' })
        RenewCount       = '0'
        GraceUntil       = ''
        BlockedAtUtc     = ''
        DeletedAtUtc     = ''
        LastSignInUtc    = $(if ($existing) { "$($existing.LastSignInUtc)" } else { '' })
    }

    Write-CBActivity -EventName "Took ownership of $address" -Actor $Caller.Upn -OwnerId $Caller.Oid `
        -GuestId $GuestId -GuestUpn $address -GuestDisplayName $name -Detail @{ reason = $why; expiresOn = $expiry.ExpiresOn }

    $row = Get-CBGuestRow -GuestId $GuestId
    return @{ Ok = $true; Status = 200; Simulated = $false; Warnings = @($warnings)
        Guest = $(if ($row) { Get-CBGuestView -Row $row -Settings $Settings } else { @{ id = $GuestId } })
    }
}

function Send-CBOwnerEnquiry {
    <#
    .SYNOPSIS
        Tells the current owner that a colleague wants to work with their guest.
    .DESCRIPTION
        The alternative to a duplicate invitation. Deliberately just a message:
        it changes nothing, so it needs no approval workflow and cannot be used
        to take somebody's guest away from them.
    .OUTPUTS
        @{ Ok; Status; Error; Sent }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$GuestId,
        [string]$Message,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $row = Get-CBGuestRow -GuestId $GuestId
    if (-not $row) { return @{ Ok = $false; Status = 404; Error = 'We do not track that person.' } }
    $ownerId = "$($row.PartitionKey)"
    if ($ownerId -eq (Get-CBOrphanPartition)) { return @{ Ok = $false; Status = 400; Error = 'Nobody owns them, so there is nobody to ask. Claim them instead.' } }
    if ($ownerId -eq $Caller.Oid) { return @{ Ok = $false; Status = 400; Error = 'They are already yours.' } }
    if (-not $row.OwnerUpn) { return @{ Ok = $false; Status = 400; Error = 'We do not have an address for the owner.' } }

    $values = Get-CBMailTokenValue -Settings $Settings
    $values.guest = @{ displayName = "$($row.DisplayName)"; email = "$($row.Email)" }
    $values.owner = @{ displayName = "$($row.OwnerDisplayName)"; email = "$($row.OwnerUpn)" }
    $values.requester = @{ displayName = $Caller.DisplayName; email = $Caller.Upn }
    $values.message = ConvertTo-CBBoundedString -Value $Message -MaxLength 600 -Default 'No message was added.' -AllowNewLines

    # This one is a person writing to a colleague, so it is the message that
    # benefits most from coming from them rather than from the service desk.
    $mail = Submit-CBGuestMail -Key 'askOwner' -To "$($row.OwnerUpn)" -Values $values -Settings $Settings `
        -Caller $Caller -OwnerId $ownerId -GuestId $GuestId
    Write-CBActivity -EventName "Asked $($row.OwnerDisplayName) about $($row.Email)" -Actor $Caller.Upn -OwnerId $ownerId `
        -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" `
        -Simulated:([bool]$Settings.dryRun) -Detail @{ message = $values.message; sent = $mail.Sent; handed = $mail.Handed }

    if (-not $mail.Sent -and -not $mail.Handed -and -not $Settings.dryRun) {
        return @{ Ok = $false; Status = 502; Error = "The message could not be sent. Contact $($row.OwnerUpn) directly." }
    }
    return @{ Ok = $true; Status = 200; Sent = $mail.Sent; Simulated = [bool]$Settings.dryRun
        Outbox = @($(if ($mail.Handed) { $mail.Message }))
        Message = $(if ($Settings.dryRun) { 'Simulation mode is on, so nothing was actually sent.' } else { "Sent to $($row.OwnerDisplayName)." })
    }
}

# --- Redemption --------------------------------------------------------------

function Get-CBPendingGuestRow {
    <#
    .SYNOPSIS
        Guests we have invited who have not accepted yet. The poller's work list.
    #>
    [CmdletBinding()] param()
    return @(Get-CBAllGuestRow -Filter "State eq 'pending'")
}

function Complete-CBGuestRedemption {
    <#
    .SYNOPSIS
        Marks a guest as having accepted, and tells their owner.
    .OUTPUTS
        @{ Changed; Reason }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $guestId = "$($Row.RowKey)"
    $ownerId = "$($Row.PartitionKey)"

    $user = Get-CBDirectoryUser -UserId $guestId
    if (-not $user) {
        # Invited, then removed elsewhere. Record it and stop polling for them.
        Save-CBGuestRecord -OwnerId $ownerId -GuestId $guestId -Properties @{ State = 'deleted'; DeletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
        Write-CBActivity -EventName "$($Row.Email) no longer exists in Entra" -OwnerId $ownerId -GuestId $guestId `
            -GuestUpn "$($Row.Email)" -GuestDisplayName "$($Row.DisplayName)" -Detail 'The account was removed outside Collaborate, so it is marked as gone here too.'
        return @{ Changed = $true; Reason = 'deleted elsewhere' }
    }
    $redemption = Get-CBRedemptionState -ExternalUserState "$($user.externalUserState)" `
        -StateChangedAt "$($user.externalUserStateChangeDateTime)" `
        -LastSignIn "$($Row.LastSignInUtc)" -Created "$($user.createdDateTime)"

    if ($redemption.State -eq 'pending') { return @{ Changed = $false; Reason = 'still pending' } }

    if ($redemption.State -eq 'unknown') {
        # Entra has stopped saying anything about this invitation. Polling for an
        # answer that will never come would keep the guest in "waiting for them
        # to accept" for the rest of their life, so the doubt is recorded once
        # and the row rejoins the ordinary lifecycle. No mail: nothing happened,
        # we merely stopped pretending we were still waiting.
        Save-CBGuestRecord -OwnerId $ownerId -GuestId $guestId -Properties @{
            State       = 'active'
            InviteState = 'unknown'
            DisplayName = "$($user.displayName)"
        }
        Write-CBActivity -EventName "Entra no longer records whether $($Row.Email) accepted" -OwnerId $ownerId -GuestId $guestId `
            -GuestUpn "$($Row.Email)" -GuestDisplayName "$($user.displayName)" `
            -Detail 'The invitation state is empty, which is normal for older accounts. They are treated as an ordinary collaborator from now on.'
        return @{ Changed = $true; Reason = 'unknown' }
    }

    # Entra's own timestamp beats ours: it says when they actually accepted,
    # where the clock only says when we happened to look.
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $acceptedAt = if (ConvertTo-CBDateOnly -Value "$($redemption.At)") { "$($redemption.At)" } else { $now }
    Save-CBGuestRecord -OwnerId $ownerId -GuestId $guestId -Properties @{
        State         = 'active'
        InviteState   = 'accepted'
        RedeemedAtUtc = $acceptedAt
        DisplayName   = "$($user.displayName)"
    }
    Write-CBActivity -EventName "$($Row.Email) accepted the invitation" -OwnerId $ownerId -GuestId $guestId `
        -GuestUpn "$($Row.Email)" -GuestDisplayName "$($user.displayName)" -Detail @{ expiresOn = "$($Row.ExpiresOn)" }

    $values = Get-CBMailTokenValue -Settings $Settings
    $values.guest = @{ displayName = "$($user.displayName)"; email = "$($Row.Email)" }
    $values.owner = @{ displayName = "$($Row.OwnerDisplayName)"; email = "$($Row.OwnerUpn)" }
    $values.expiresOn = Format-CBFriendlyDate -Value "$($Row.ExpiresOn)"

    # Two different audiences, two different messages, both editable in the
    # portal. The owner's is gated by the notification setting; the guest's is a
    # template switch, because the welcome page has already told them.
    if ($Settings.notifications.notifyOwnerOnRedeem -and $Row.OwnerUpn) {
        try { [void](Send-CBTemplateMail -Key 'guestAccepted' -To "$($Row.OwnerUpn)" -Values $values -Settings $Settings) }
        catch { Write-Warning "Could not tell $($Row.OwnerUpn) that their guest accepted: $($_.Exception.Message)" }
    }
    try { [void](Send-CBTemplateMail -Key 'welcome' -To "$($Row.Email)" -Values $values -Settings $Settings) }
    catch { Write-Warning "Could not send the welcome message to $($Row.Email): $($_.Exception.Message)" }

    return @{ Changed = $true; Reason = 'accepted' }
}
