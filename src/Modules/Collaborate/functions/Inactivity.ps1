# Guests who never actually use the access they were given.
#
# This is the optional half of the cleanup story. Expiry deals with access that
# has run its course; this deals with access that was never used at all, which is
# the more common kind of sprawl: somebody was invited for a project that never
# started, and the account sits there for four years.
#
# It is OFF by default and it is the most cautious thing in the codebase:
#
#   * the threshold has a 30-day floor, because sign-in data lags and because
#     anything shorter acts on people who are simply on leave;
#   * "never signed in" falls back to the creation date, so a guest invited
#     yesterday is never inactive;
#   * missing sign-in data means NO ACTION, not "assume they never signed in".
#     signInActivity needs an Entra ID P1 or P2 licence and does not always come
#     back; treating an absent field as evidence of absence would delete people
#     for having the wrong licence;
#   * the strongest configured action is still "end their access", which goes
#     through the ordinary grace period. Nothing here deletes in one step.

function Get-CBUserSignInActivity {
    <#
    .SYNOPSIS
        Last sign-in timestamps for every guest, keyed by object id, with whether
        the tenant can supply them at all.
    .DESCRIPTION
        signInActivity needs AuditLog.Read.All plus an Entra ID P1 or P2 licence,
        so it is fetched in one sweep rather than per guest, and separately from
        the guest list, which must survive a tenant that cannot answer.

        The preference order is the last SUCCESSFUL sign-in, then the last
        interactive one, then the last non-interactive one. Non-interactive is
        included because a guest opening a shared file through a token refresh is
        still somebody using the access they were given, and calling that "never
        active" would be the more misleading answer.

        Availability is reported rather than inferred. An empty map on a tenant
        without the licence and an empty map because nobody has ever signed in
        look identical, and the difference is exactly what the portal needs to
        say. Callers must treat "no entry" as unknown, never as "never".
    .OUTPUTS
        @{ Available; Users; Error }
    #>
    [CmdletBinding()] param([int]$Top = 999)
    $map = @{}
    try {
        $filter = [Uri]::EscapeDataString("userType eq 'Guest'")
        $uri = "/users?`$filter=$filter&`$select=id,signInActivity,createdDateTime&`$top=$Top"
        foreach ($u in @(Invoke-CBGraph -All -Uri $uri)) {
            $last = ''
            if ($u.PSObject.Properties['signInActivity'] -and $u.signInActivity) {
                $last = @(
                    "$($u.signInActivity.lastSuccessfulSignInDateTime)",
                    "$($u.signInActivity.lastSignInDateTime)",
                    "$($u.signInActivity.lastNonInteractiveSignInDateTime)"
                ) | Where-Object { $_ -and $_ -ne '0001-01-01T00:00:00Z' } | Select-Object -First 1
            }
            $map["$($u.id)"] = @{ LastSignIn = "$last"; Created = "$($u.createdDateTime)" }
        }
    }
    catch {
        # A tenant without the licence returns an error for the whole query, so
        # this is a normal outcome rather than a fault. Nothing is acted on, and
        # the portal explains the empty column instead of implying "never".
        $why = "$($_.Exception.Message)"
        Write-Warning "Could not read sign-in activity: $why. This needs Entra ID P1 or P2; last-active will be left as it was and inactivity cleanup will do nothing."
        return @{ Available = $false; Users = @{}; Error = $why }
    }
    return @{ Available = $true; Users = $map; Error = '' }
}

# Whether this tenant can answer for sign-in activity at all is a tenant-level
# fact, so it lives with the other tenant-level meta rows rather than being
# rediscovered by every request that wants to render a column.

function Set-CBSignInDataState {
    [CmdletBinding()] param([bool]$Available, [string]$ErrorText)
    $tables = Get-CBTableNames
    Set-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'signInData' -Properties @{
        Available = $(if ($Available) { 'true' } else { 'false' })
        Error     = ConvertTo-CBBoundedString -Value $ErrorText -MaxLength 400 -Default ''
        Utc       = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Get-CBSignInDataState {
    <#
    .OUTPUTS
        @{ Available; CheckedAt; Error } - Available is false until something has
        actually looked, so the portal says "not checked yet" rather than
        claiming the tenant lacks a licence it may well have.
    #>
    [CmdletBinding()] param()
    $tables = Get-CBTableNames
    $e = $null
    try { $e = Get-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'signInData' } catch { }
    if (-not $e) { return @{ Available = $false; CheckedAt = ''; Error = '' } }
    return @{
        Available = ("$($e.Available)" -eq 'true')
        CheckedAt = "$($e.Utc)"
        Error     = "$($e.Error)"
    }
}

function Get-CBInactiveDays {
    <#
    .SYNOPSIS
        How long a guest has been idle, or -1 when that cannot be known.
    .DESCRIPTION
        Measured from the last successful sign-in, or from when the account was
        created if they have never signed in at all. -1 means neither is known,
        and every caller treats that as "do nothing".
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$LastSignIn, [AllowNull()][string]$Created, [datetime]$Now = [datetime]::MinValue)
    $Now = ConvertTo-CBUtcMoment -Value $Now
    $reference = ConvertTo-CBDateOnly -Value $LastSignIn
    if (-not $reference) { $reference = ConvertTo-CBDateOnly -Value $Created }
    if (-not $reference) { return -1 }
    return [int]($Now.Date - $reference).TotalDays
}

function Get-CBInactivityDecision {
    <#
    .SYNOPSIS
        What, if anything, the inactivity policy says about one guest today.
    .DESCRIPTION
        Pure. Runs only when the ordinary lifecycle has nothing to say, so a
        guest about to expire is never also chased for being idle.
    .OUTPUTS
        @{ Action; Days; Reason } where Action is none, notify or block.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row, $Settings, [datetime]$Now = [datetime]::MinValue, [hashtable]$SignIn)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $none = @{ Action = 'none'; Days = 0; Reason = '' }
    if (-not $Settings.inactivity.enabled) { return $none }

    $state = "$($Row.State)".ToLowerInvariant()
    if ($state -in @('blocked', 'deleted')) { return $none }

    $lastSignIn = "$($Row.LastSignInUtc)"
    $created = "$($Row.InvitedAtUtc)"
    if ($SignIn) {
        if ($SignIn.LastSignIn) { $lastSignIn = "$($SignIn.LastSignIn)" }
        if (-not $created) { $created = "$($SignIn.Created)" }
    }

    $days = Get-CBInactiveDays -LastSignIn $lastSignIn -Created $created -Now $Now
    # Unknown is not the same as never. A tenant without the licence for sign-in
    # data must not have its guests treated as idle.
    if ($days -lt 0) { return $none }
    if ($days -lt [int]$Settings.inactivity.thresholdDays) { return $none }

    $what = if ($lastSignIn) { "has not signed in for $days days" } else { "has never signed in, $days days after being invited" }

    if ("$($Settings.inactivity.action)" -eq 'notify') {
        # Notifying repeatedly about the same idle guest is nagging, not
        # information, so it happens once unless an admin says otherwise.
        if ($Settings.inactivity.notifyOnce -and "$($Row.InactivityNotifiedUtc)") { return $none }
        return @{ Action = 'notify'; Days = $days; Reason = $what }
    }
    return @{ Action = 'block'; Days = $days; Reason = $what }
}

function Invoke-CBInactivityNotice {
    <#
    .SYNOPSIS
        Tells the owner that a guest of theirs has gone idle, once.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Decision, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $sent = $false
    if ($Row.OwnerUpn) {
        $values = Get-CBGuestMailValue -Row $Row -Settings $Settings
        $values.inactiveDays = "$($Decision.Days)"
        $values.lastSignIn = $(if ("$($Row.LastSignInUtc)") { Format-CBFriendlyDate -Value "$($Row.LastSignInUtc)" } else { 'never' })
        try { $sent = Send-CBTemplateMail -Key 'inactivityWarning' -To "$($Row.OwnerUpn)" -Values $values -Settings $Settings }
        catch { Write-Warning "Could not send the inactivity warning to $($Row.OwnerUpn): $($_.Exception.Message)" }
    }

    # Marked as told even if the mail failed, for the same reason reminders are:
    # a broken mailbox must not turn one notice into a daily one.
    if (-not $Settings.dryRun) {
        Save-CBGuestRecord -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)" -Properties @{
            InactivityNotifiedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    Write-CBActivity -EventName "$($Row.Email) $($Decision.Reason)" -OwnerId "$($Row.PartitionKey)" `
        -GuestId "$($Row.RowKey)" -GuestUpn "$($Row.Email)" -GuestDisplayName "$($Row.DisplayName)" `
        -Simulated:([bool]$Settings.dryRun) -Detail @{ inactiveDays = $Decision.Days; sentTo = "$($Row.OwnerUpn)"; sent = $sent }
    return $sent
}
