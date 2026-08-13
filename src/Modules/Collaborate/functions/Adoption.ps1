# Guests that predate the tool, and guests whose owner has left.
#
# A tenant that installs Collaborate usually already has hundreds of guests
# nobody can account for. Ignoring them would make the tool a policy for new
# collaborations only, which is not what anybody wants; deleting them would be
# unforgivable. So adoption does the one useful, reversible thing: it works out
# who is responsible, records it, and gives each guest an end date.
#
# ADOPTION NEVER BLOCKS OR DELETES ANYBODY. It writes an owner and a date. What
# happens after that date is the ordinary lifecycle, with its reminders and its
# grace period, and the date is always counted from TODAY. Adopting a three-year
# old guest and expiring them the same afternoon would be a spectacular way to
# break a tenant on the first run.
#
# Ownership is looked for in this order:
#
#   1. Entra's own sponsors field, which is exactly this concept and which
#      Collaborate itself writes on every invitation;
#   2. the directory audit log, which records who invited whom, but only for the
#      last 7 to 30 days depending on the licence;
#   3. nobody, which is a real answer. Those land in the orphan partition and in
#      the digest, so somebody can claim or remove them.

function Get-CBGuestSponsor {
    <#
    .SYNOPSIS
        The internal member Entra records as this guest's sponsor, or $null.
    .DESCRIPTION
        A guest can have several sponsors; the first enabled internal member wins.
        A sponsor who has since left is no use as an owner, which is why the
        account has to be checked rather than just read.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GuestId)
    try {
        $r = Invoke-CBGraph -Uri ('/users/' + [Uri]::EscapeDataString($GuestId) + '/sponsors?$select=id,displayName,userPrincipalName,mail,userType,accountEnabled')
        foreach ($s in @($r.value)) {
            if ("$($s.userType)" -eq 'Guest') { continue }
            if ($s.PSObject.Properties['accountEnabled'] -and $s.accountEnabled -eq $false) { continue }
            if (-not $s.id) { continue }
            return $s
        }
    }
    catch { Write-Warning "Could not read sponsors for ${GuestId}: $($_.Exception.Message)" }
    return $null
}

function Find-CBInviterFromAuditLog {
    <#
    .SYNOPSIS
        Who invited this guest, according to the directory audit log.
    .DESCRIPTION
        Only useful for recent guests: Entra keeps directory audits for 7 days on
        a free tenant and 30 with P1 or P2. Worth trying because it is exact when
        it works, and worth nothing when it does not, so a failure here is not an
        error.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GuestId)
    try {
        $filter = "targetResources/any(t:t/id eq '$($GuestId.Replace("'", "''"))')"
        $uri = "/auditLogs/directoryAudits?`$filter=$([Uri]::EscapeDataString($filter))&`$top=20"
        $r = Invoke-CBGraph -Uri $uri
        foreach ($entry in @($r.value)) {
            $activity = "$($entry.activityDisplayName)"
            if ($activity -notmatch 'Invite external user|Add user|Redeem external user invitation') { continue }
            $user = $entry.initiatedBy.user
            if (-not $user -or -not $user.id) { continue }
            # A guest redeeming their own invitation is logged as initiating it,
            # which would make the guest their own owner.
            if ("$($user.id)" -eq $GuestId) { continue }
            return [pscustomobject]@{
                id                = "$($user.id)"
                displayName       = "$($user.displayName)"
                userPrincipalName = "$($user.userPrincipalName)"
            }
        }
    }
    catch { Write-Warning "Could not search the audit log for ${GuestId}: $($_.Exception.Message)" }
    return $null
}

function Resolve-CBAdoptionOwner {
    <#
    .SYNOPSIS
        Works out who should own a guest we do not track yet.
    .OUTPUTS
        @{ OwnerId; OwnerUpn; OwnerDisplayName; Source } - OwnerId empty means
        nobody could be found, which is a real answer and not a failure.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$User, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $guestId = "$($User.id)"

    if ($Settings.adoption.useSponsors) {
        $sponsor = Get-CBGuestSponsor -GuestId $guestId
        if ($sponsor) {
            return @{
                OwnerId = "$($sponsor.id)"
                OwnerUpn = "$(@($sponsor.userPrincipalName, $sponsor.mail) | Where-Object { $_ } | Select-Object -First 1)"
                OwnerDisplayName = "$($sponsor.displayName)"
                Source = 'sponsor'
            }
        }
    }

    if ($Settings.adoption.useAuditLog) {
        $inviter = Find-CBInviterFromAuditLog -GuestId $guestId
        if ($inviter) {
            # The audit log records who they were at the time. Confirm they are
            # still an enabled internal member before making them accountable.
            # (Named $candidate, not $profile: $PROFILE is a PowerShell
            # automatic variable and assigning to it is a trap.)
            $candidate = Get-CBUserProfile -Oid "$($inviter.id)"
            if ($candidate -and "$($candidate.userType)" -eq 'Member' -and $candidate.accountEnabled) {
                return @{
                    OwnerId = "$($candidate.id)"
                    OwnerUpn = "$(@($candidate.userPrincipalName, $candidate.mail) | Where-Object { $_ } | Select-Object -First 1)"
                    OwnerDisplayName = "$($candidate.displayName)"
                    Source = 'audit log'
                }
            }
        }
    }

    return @{ OwnerId = ''; OwnerUpn = ''; OwnerDisplayName = ''; Source = 'nobody' }
}

function Get-CBAdoptionExpiry {
    <#
    .SYNOPSIS
        The end date an adopted guest gets.
    .DESCRIPTION
        If the guest already carries a valid date in the configured attribute,
        that is respected: something (an earlier install, another tool, a manual
        process) already decided, and overwriting it would throw away a real
        decision. Otherwise they get adoption.initialDays counted from today.
    .OUTPUTS
        @{ ExpiresOn; Source }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$User, $Settings, [datetime]$Now = [datetime]::MinValue)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $attribute = "$($Settings.expiry.attribute)"
    $existing = ''
    if ($User.PSObject.Properties['onPremisesExtensionAttributes'] -and $User.onPremisesExtensionAttributes) {
        $existing = "$($User.onPremisesExtensionAttributes.$attribute)".Trim()
    }
    $parsed = ConvertTo-CBDateOnly -Value $existing
    if ($parsed) {
        return @{ ExpiresOn = $parsed.ToString('yyyy-MM-dd'); Source = "the date already on $attribute" }
    }
    return @{
        ExpiresOn = (Get-CBExpiryDateString -Days ([int]$Settings.adoption.initialDays) -From $Now)
        Source    = "$($Settings.adoption.initialDays) days from today"
    }
}

function Invoke-CBGuestAdoptionRecord {
    <#
    .SYNOPSIS
        Adopts one guest: writes the record, and the end date onto the account.
    .OUTPUTS
        @{ Adopted; Orphaned; Reason }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$User, $Settings, [datetime]$Now = [datetime]::MinValue)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $guestId = "$($User.id)"
    $address = "$(@($User.mail, $User.userPrincipalName) | Where-Object { $_ } | Select-Object -First 1)"
    $owner = Resolve-CBAdoptionOwner -User $User -Settings $Settings
    $expiry = Get-CBAdoptionExpiry -User $User -Settings $Settings -Now $Now
    $orphaned = -not $owner.OwnerId

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would adopt $address" -OwnerId $owner.OwnerId -GuestId $guestId `
            -GuestUpn $address -GuestDisplayName "$($User.displayName)" -Simulated `
            -Detail @{ owner = $owner.OwnerDisplayName; via = $owner.Source; expiresOn = $expiry.ExpiresOn; from = $expiry.Source }
        return @{ Adopted = $false; Orphaned = $orphaned; Reason = 'simulation' }
    }

    # Only write the attribute when we are the ones deciding the date. Rewriting
    # a date that was already there would be a no-op at best and a clobbered
    # value at worst.
    if ($expiry.Source -notmatch '^the date already on') {
        try { Set-CBGuestExpiryAttribute -GuestId $guestId -ExpiresOn $expiry.ExpiresOn -Settings $Settings }
        catch { Write-Warning "Could not write the expiry attribute while adopting ${guestId}: $($_.Exception.Message)" }
    }

    # An older guest very often has no externalUserState at all. Reading that as
    # "invited, never replied" put every long-standing collaborator in the
    # pending pile and hid their end date behind the wrong sentence, so it is
    # recorded as unknown and reported as unknown.
    $redemption = Get-CBRedemptionState -ExternalUserState "$($User.externalUserState)" `
        -StateChangedAt "$($User.externalUserStateChangeDateTime)" -Created "$($User.createdDateTime)"
    $redeemed = "$($redemption.At)"
    Save-CBGuestRecord -OwnerId $owner.OwnerId -GuestId $guestId -Replace -Properties @{
        Email            = $address
        DisplayName      = "$($User.displayName)"
        Upn              = "$($User.userPrincipalName)"
        OwnerUpn         = $owner.OwnerUpn
        OwnerDisplayName = $owner.OwnerDisplayName
        Reason           = "Adopted by Collaborate; owner found via $($owner.Source)."
        Source           = 'adopted'
        InvitedAtUtc     = "$($User.createdDateTime)"
        RedeemedAtUtc    = $redeemed
        ExpiresOn        = $expiry.ExpiresOn
        # Only a directory that actually says PendingAcceptance makes a guest
        # pending. Unknown is an ordinary collaborator with a question mark
        # beside them, not somebody the poller should chase forever.
        State            = $(if ($redemption.State -eq 'pending') { 'pending' } else { 'active' })
        InviteState      = "$($redemption.State)"
        RemindersSent    = ''
        SharedItems      = '[]'
        RenewCount       = '0'
        GraceUntil       = ''
        BlockedAtUtc     = ''
        DeletedAtUtc     = ''
        LastSignInUtc    = ''
        AdoptedAtUtc     = [DateTimeOffset]::UtcNow.ToString('o')
    }

    Write-CBActivity -EventName "Adopted $address" -OwnerId $owner.OwnerId -GuestId $guestId `
        -GuestUpn $address -GuestDisplayName "$($User.displayName)" `
        -Detail @{ owner = $(if ($owner.OwnerDisplayName) { $owner.OwnerDisplayName } else { 'nobody' })
        via = $owner.Source; expiresOn = $expiry.ExpiresOn; from = $expiry.Source
    }
    return @{ Adopted = $true; Orphaned = $orphaned; Reason = $owner.Source }
}

function Get-CBGuestDirectory {
    <#
    .SYNOPSIS
        Every guest in the tenant, keyed by object id. One sweep, shared by the
        scanner, adoption and the refresh so a run never enumerates twice.
    .NOTES
        It deliberately does NOT ask for signInActivity. That field needs an
        Entra ID P1 or P2 licence, and asking for it on a tenant without one
        fails the WHOLE query. That would cost us the guest list, the population
        count the storm guard sizes itself against, and the ability to notice a
        guest deleted elsewhere -- a licence check taking out the daily scan.
        Sign-in data is a separate sweep, free to fail on its own.
    #>
    [CmdletBinding()] param([int]$Top = 999)
    $select = 'id,displayName,mail,userPrincipalName,externalUserState,externalUserStateChangeDateTime,accountEnabled,createdDateTime,onPremisesExtensionAttributes'
    $map = @{}
    foreach ($g in @(Invoke-CBGraph -All -Uri "/users?`$filter=$([Uri]::EscapeDataString("userType eq 'Guest'"))&`$select=$select&`$top=$Top")) {
        $map["$($g.id)"] = $g
    }
    return $map
}

function Update-CBGuestDirectoryFacts {
    <#
    .SYNOPSIS
        Brings the tracked records back in line with what Entra says now: whether
        the invitation was ever accepted, when each guest was last active, and
        what they are called.
    .DESCRIPTION
        Facts, not decisions. Nothing here blocks, deletes, expires or mails
        anybody, which is why it runs in simulation mode too: a list that says
        "waiting for them to accept" about somebody who has been signing in for
        three years is wrong in a way that makes the whole tool look
        untrustworthy, and refusing to correct that during an evaluation would
        be a strange thing to be careful about.

        Two rules keep it from stepping on anything:

          * A guest Collaborate itself invited is left in 'pending' for the
            RedemptionPoller to resolve, because that transition also sends the
            welcome and tells the owner. Only adopted rows are healed here, and
            they never had one of our invitations to accept.
          * When sign-in data is unavailable, last-active is left exactly as it
            was rather than blanked. A date somebody can see, with "checked on"
            beside it, beats an empty column that looks like "never".
    .OUTPUTS
        @{ Checked; Updated; SignInAvailable; SignInError }
    #>
    [CmdletBinding()] param($Directory, $SignIn, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if ($null -eq $Directory) { $Directory = Get-CBGuestDirectory }
    if ($null -eq $SignIn) { $SignIn = Get-CBUserSignInActivity }

    Set-CBSignInDataState -Available ([bool]$SignIn.Available) -ErrorText "$($SignIn.Error)"

    $checked = 0
    $updated = 0
    foreach ($row in @(Get-CBAllGuestRow)) {
        $guestId = "$($row.RowKey)"
        if ("$($row.State)".ToLowerInvariant() -eq 'deleted') { continue }
        $user = $Directory["$guestId"]
        # Gone from Entra is the scanner's business, not ours: it closes the row
        # and writes the audit entry. Skipping keeps one owner for that decision.
        if (-not $user) { continue }
        $checked++

        $props = @{}
        $lastSignIn = "$($row.LastSignInUtc)"
        if ($SignIn.Available) {
            $fresh = "$($SignIn.Users["$guestId"].LastSignIn)"
            if ($fresh -ne $lastSignIn) { $props.LastSignInUtc = $fresh }
            $lastSignIn = $fresh
        }

        $redemption = Get-CBRedemptionState -ExternalUserState "$($user.externalUserState)" `
            -StateChangedAt "$($user.externalUserStateChangeDateTime)" `
            -LastSignIn $lastSignIn -Created "$($user.createdDateTime)"

        if ("$($row.InviteState)" -ne "$($redemption.State)") { $props.InviteState = "$($redemption.State)" }

        if ("$($row.Source)" -ne 'collaborate') {
            if ($redemption.State -ne 'pending' -and "$($row.State)".ToLowerInvariant() -eq 'pending') {
                $props.State = 'active'
            }
            if ($redemption.At -and -not "$($row.RedeemedAtUtc)") { $props.RedeemedAtUtc = "$($redemption.At)" }
        }

        $name = "$($user.displayName)"
        if ($name -and $name -ne "$($row.DisplayName)") { $props.DisplayName = $name }

        if ($props.Count -gt 0) {
            Save-CBGuestRecord -OwnerId "$($row.PartitionKey)" -GuestId $guestId -Properties $props
            $updated++
        }
    }

    Write-Host "Directory refresh: checked $checked record(s), updated $updated. Sign-in data $(if ($SignIn.Available) { 'available' } else { 'unavailable' })."
    return @{ Checked = $checked; Updated = $updated; SignInAvailable = [bool]$SignIn.Available; SignInError = "$($SignIn.Error)" }
}

function Invoke-CBGuestAdoption {
    <#
    .SYNOPSIS
        Adopts every guest in the directory that is not tracked yet.
    .PARAMETER Directory
        The guest list the caller already has (the scanner passes its own, so the
        tenant is not enumerated twice in one run).
    .PARAMETER Limit
        Ceiling on how many are adopted in one pass. A first run over an old
        tenant can find thousands; doing them in batches keeps the run inside the
        function timeout and lets an operator watch the first batch before the
        rest follow tomorrow.
    .OUTPUTS
        @{ Adopted; Orphaned; Skipped; Remaining }
    #>
    [CmdletBinding()]
    param($Directory, $Settings, [int]$Limit = 500, [datetime]$Now = [datetime]::MinValue)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if (-not $Settings.adoption.enabled) {
        Write-Host 'Adoption is switched off; guests that predate the tool are left alone.'
        return @{ Adopted = 0; Orphaned = 0; Skipped = 0; Remaining = 0 }
    }

    if ($null -eq $Directory) { $Directory = Get-CBGuestDirectory }

    $tracked = @{}
    foreach ($row in Get-CBAllGuestRow) { $tracked["$($row.RowKey)"] = $true }

    $adopted = 0; $orphaned = 0; $skipped = 0; $seen = 0
    $candidates = @($Directory.Keys | Where-Object { -not $tracked.ContainsKey($_) })
    foreach ($id in $candidates) {
        if ($seen -ge $Limit) { break }
        $seen++
        try {
            $result = Invoke-CBGuestAdoptionRecord -User $Directory[$id] -Settings $Settings -Now $Now
            if ($result.Adopted) { $adopted++ } else { $skipped++ }
            if ($result.Orphaned) { $orphaned++ }
        }
        catch {
            $skipped++
            Write-Warning "Could not adopt ${id}: $($_.Exception.Message)"
        }
    }

    $remaining = [Math]::Max(0, $candidates.Count - $seen)
    Write-Host "Adoption: $adopted adopted ($orphaned with no owner), $skipped skipped, $remaining left for the next run."
    return @{ Adopted = $adopted; Orphaned = $orphaned; Skipped = $skipped; Remaining = $remaining }
}

function Get-CBOrphanRow {
    <#
    .SYNOPSIS
        Guests nobody is accountable for. One partition query.
    #>
    [CmdletBinding()] param()
    $tables = Get-CBTableNames
    $filter = "PartitionKey eq '{0}'" -f (ConvertTo-CBODataKey (Get-CBOrphanPartition))
    return @(Get-CBTableEntities -Table $tables.Guests -Filter $filter)
}

function Send-CBOrphanDigest {
    <#
    .SYNOPSIS
        Tells the service desk about guests nobody owns.
    .DESCRIPTION
        An unowned guest is the one case the tool cannot resolve by itself: it
        will still expire them on schedule, but nobody will be reminded first,
        because there is nobody to remind. That is worth a human's attention.
    .OUTPUTS
        @{ Sent; Count }
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if (-not $Settings.notifications.orphanDigest) { return @{ Sent = $false; Count = 0 } }
    $to = "$($Settings.notifications.servicedeskEmail)"
    if (-not $to) { return @{ Sent = $false; Count = 0 } }

    $orphans = @(Get-CBOrphanRow | Where-Object { "$($_.State)".ToLowerInvariant() -ne 'deleted' })
    if ($orphans.Count -eq 0) { return @{ Sent = $false; Count = 0 } }

    $values = Get-CBMailTokenValue -Settings $Settings
    $values.orphanCount = "$($orphans.Count)"
    # Listed newest first and capped, because a digest nobody can read is a
    # digest nobody acts on.
    $values.orphanList = (@($orphans | Sort-Object -Property @{ Expression = { "$($_.InvitedAtUtc)" } } -Descending |
                Select-Object -First 40 | ForEach-Object { "$($_.Email)" }) -join ', ')
    if ($orphans.Count -gt 40) { $values.orphanList += " and $($orphans.Count - 40) more" }

    $sent = $false
    try { $sent = Send-CBTemplateMail -Key 'orphanDigest' -To $to -Values $values -Settings $Settings }
    catch { Write-Warning "Could not send the unowned-guest digest: $($_.Exception.Message)" }
    Write-CBSystemActivity -EventName "$($orphans.Count) external account(s) have no owner" `
        -Detail @{ count = $orphans.Count; sentTo = $to; sent = $sent }
    return @{ Sent = $sent; Count = $orphans.Count }
}

function Set-CBGuestOwner {
    <#
    .SYNOPSIS
        An administrator making somebody accountable for a guest.
    .DESCRIPTION
        The same movement between partitions as a hand-over, but reachable for
        guests nobody owns, which a hand-over is not: Move-CBGuestOwner requires
        the caller to be the current owner or an admin, and an orphan has no
        current owner to be.
    .OUTPUTS
        @{ Ok; Status; Error; Guest }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$GuestId,
        [Parameter(Mandatory)][string]$NewOwnerId,
        [string]$Reason,
        $Settings,
        # The owner profile, when the caller is assigning many guests at once and
        # has already looked it up.
        $OwnerProfile
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    if (-not $Caller.IsAdmin) { return @{ Ok = $false; Status = 403; Error = 'Only an administrator can assign owners.' } }

    $row = Get-CBGuestRow -GuestId $GuestId
    if (-not $row) { return @{ Ok = $false; Status = 404; Error = 'We do not track that person.' } }

    $owner = if ($OwnerProfile) { $OwnerProfile } else { Get-CBUserProfile -Oid $NewOwnerId }
    if (-not $owner) { return @{ Ok = $false; Status = 404; Error = 'That colleague could not be found.' } }
    if ("$($owner.userType)" -ne 'Member') { return @{ Ok = $false; Status = 400; Error = 'A guest cannot look after another guest.' } }

    $oldPartition = "$($row.PartitionKey)"
    if ($oldPartition -eq $NewOwnerId) {
        $who = if ($NewOwnerId -eq $Caller.Oid) { 'They are already on your list.' } else { "$($owner.displayName) already owns them." }
        return @{ Ok = $false; Status = 409; Error = $who }
    }

    $newUpn = "$(@($owner.userPrincipalName, $owner.mail) | Where-Object { $_ } | Select-Object -First 1)"
    $why = ConvertTo-CBBoundedString -Value $Reason -MaxLength 400 -Default "$($row.Reason)"

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would make $($owner.displayName) responsible for $($row.Email)" -Actor $Caller.Upn `
            -OwnerId $NewOwnerId -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" -Simulated
        return @{ Ok = $true; Status = 200; Simulated = $true; Guest = [ordered]@{ id = $GuestId } }
    }

    $properties = @{}
    foreach ($p in $row.PSObject.Properties) {
        if ($p.Name -in @('PartitionKey', 'RowKey', 'Timestamp', 'odata.etag')) { continue }
        $properties[$p.Name] = "$($p.Value)"
    }
    $properties.OwnerUpn = $newUpn
    $properties.OwnerDisplayName = "$($owner.displayName)"
    $properties.Reason = $why
    $properties.AssignedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $properties.AssignedBy = $Caller.Upn

    # New row first: interrupted halfway, a guest owned twice is a visible
    # problem somebody can fix, and a guest owned by nobody is how they got lost
    # in the first place.
    Save-CBGuestRecord -OwnerId $NewOwnerId -GuestId $GuestId -Properties $properties -Replace
    try { Remove-CBTableEntity -Table (Get-CBTableNames).Guests -PartitionKey $oldPartition -RowKey $GuestId }
    catch { Write-Warning "Assigned the guest but could not remove the old record: $($_.Exception.Message)" }

    if ($Settings.invite.setSponsor) { [void](Add-CBGuestSponsor -GuestId $GuestId -OwnerId $NewOwnerId) }

    if ($newUpn) {
        $values = Get-CBGuestMailValue -Row $row -Settings $Settings
        $values.owner = @{ displayName = "$($owner.displayName)"; email = $newUpn }
        $values.previousOwner = @{ displayName = $(if ($row.OwnerDisplayName) { "$($row.OwnerDisplayName)" } else { 'nobody' }) }
        $values.reason = $why
        try { [void](Send-CBTemplateMail -Key 'ownershipTransferred' -To $newUpn -Values $values -Settings $Settings) }
        catch { Write-Warning "Could not tell $newUpn they are now responsible: $($_.Exception.Message)" }
    }

    Write-CBActivity -EventName "$($owner.displayName) is now responsible for $($row.Email)" -Actor $Caller.Upn `
        -OwnerId $NewOwnerId -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" `
        -Detail @{ from = $(if ($row.OwnerUpn) { "$($row.OwnerUpn)" } else { 'nobody' }); to = $newUpn; reason = $why }

    $fresh = Get-CBGuestRow -GuestId $GuestId
    return @{ Ok = $true; Status = 200; Simulated = $false
        Guest = $(if ($fresh) { Get-CBGuestView -Row $fresh -Settings $Settings -IncludeOwner } else { @{ id = $GuestId } })
    }
}
