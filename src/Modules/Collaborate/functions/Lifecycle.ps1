# The lifecycle: reminders, expiry, the grace period, deletion, and the actions
# an owner can take.
#
# This is the part of the tool that acts on people's accounts without being
# asked, so three rules apply throughout:
#
#   1. THE DECISION IS PURE AND THE ACT IS SEPARATE. Get-CBLifecycleAction looks
#      at a row and a calendar and says what should happen. Nothing it touches
#      can fail, and it can be tested exhaustively. Performing the action is a
#      different function, behind the storm guard.
#
#   2. NOTHING IS IRREVERSIBLE IN ONE STEP. Expiry blocks sign-in and starts a
#      grace period; only when that lapses is the account deleted. Both parties
#      are told at the block, so a wrong end date is a phone call rather than a
#      restore from a backup that does not exist.
#
#   3. THE ACTION IS RE-EVALUATED AT THE MOMENT IT RUNS. A queued message is a
#      suggestion, not an instruction: the processor re-reads the row and checks
#      the decision still holds. That is what makes a duplicated or delayed
#      message harmless, so no dedup table is needed.

# --- Pure: reminders ---------------------------------------------------------

function ConvertTo-CBReminderSet {
    <#
    .SYNOPSIS
        The reminder steps already sent for a guest, as an int array. Stored as a
        comma-separated string because Table storage holds strings.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Value)
    $out = [System.Collections.Generic.List[int]]::new()
    foreach ($part in ("$Value" -split '[,;\s]+')) {
        $n = 0
        if ([int]::TryParse($part, [ref]$n) -and -not $out.Contains($n)) { $out.Add($n) }
    }
    return @([int[]]$out.ToArray())
}

function Get-CBDueReminderStep {
    <#
    .SYNOPSIS
        Which reminder step, if any, is due for this guest today.
    .DESCRIPTION
        Steps are "days before the end date". The step that is due is the CLOSEST
        unsent step that the guest has already reached, and reaching it consumes
        every wider step at the same time.

        That last part is what stops a catch-up storm. A guest invited for five
        days has already passed the 30-day and 7-day marks the moment they are
        created; without consuming both, they would be mailed about the 30-day
        mark today and the 7-day mark tomorrow, for access that ends on Friday.
    .OUTPUTS
        @{ Due; Consumed } - Due is 0 when nothing is owed.
    #>
    [CmdletBinding()]
    param(
        [int]$DaysLeft,
        [int[]]$ReminderDays = @(30, 7, 1),
        [AllowNull()][string]$RemindersSent
    )
    # Already past the end date: that is an expiry, not a reminder.
    if ($DaysLeft -lt 0) { return @{ Due = 0; Consumed = @() } }

    $reached = @(@($ReminderDays) | Where-Object { [int]$_ -ge $DaysLeft } | ForEach-Object { [int]$_ })
    if ($reached.Count -eq 0) { return @{ Due = 0; Consumed = @() } }

    $sent = @(ConvertTo-CBReminderSet -Value $RemindersSent)
    $unsent = @($reached | Where-Object { $sent -notcontains $_ })
    if ($unsent.Count -eq 0) { return @{ Due = 0; Consumed = @() } }

    return @{
        Due      = ([int](($unsent | Measure-Object -Minimum).Minimum))
        Consumed = @($reached | Sort-Object -Descending)
    }
}

function Add-CBReminderSent {
    <#
    .SYNOPSIS
        Merges newly consumed steps into the stored list, for writing back.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Existing, [int[]]$Steps)
    $all = [System.Collections.Generic.List[int]]::new()
    foreach ($n in (ConvertTo-CBReminderSet -Value $Existing)) { if (-not $all.Contains($n)) { $all.Add($n) } }
    foreach ($n in @($Steps)) { if (-not $all.Contains([int]$n)) { $all.Add([int]$n) } }
    return (($all | Sort-Object -Descending) -join ',')
}

# --- Pure: the decision ------------------------------------------------------

function Get-CBGraceUntilString {
    <#
    .SYNOPSIS
        The last day a blocked guest is kept, as 'yyyy-MM-dd'.
    #>
    [CmdletBinding()] param([int]$GraceDays, [datetime]$From = [datetime]::MinValue)
    return (Get-CBExpiryDateString -Days ([Math]::Max(0, $GraceDays)) -From $From)
}

function Get-CBLifecycleAction {
    <#
    .SYNOPSIS
        What should happen to this guest today?
    .DESCRIPTION
        The whole automated behaviour of the tool, in one testable function. It
        reads a row and a calendar and returns exactly one of:

            none     nothing is owed
            remind   a reminder step has been reached (Step says which)
            block    the end date has passed; switch sign-in off and start grace
            delete   the grace period has lapsed; remove the account

        Deliberately NOT here: anything that needs the network. A guest that no
        longer exists in the directory is handled by the scanner, which is the
        only place that knows.
    .OUTPUTS
        @{ Action; Step; Reason; DaysLeft; GraceUntil }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, $Settings, [datetime]$Now = [datetime]::MinValue)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $Now = ConvertTo-CBUtcMoment -Value $Now

    $none = @{ Action = 'none'; Step = 0; Reason = ''; DaysLeft = 0; GraceUntil = '' }
    $stored = "$($Row.State)".Trim().ToLowerInvariant()
    if ($stored -eq 'deleted') { return $none }

    $daysLeft = Get-CBGuestDaysLeft -ExpiresOn "$($Row.ExpiresOn)" -Now $Now
    $none.DaysLeft = $daysLeft

    if ($stored -eq 'blocked') {
        # Blocked guests are only waiting for the grace period to lapse. A row
        # with no grace date recorded is treated as still inside it: the next
        # human decision is safer than an unexplained deletion.
        $grace = ConvertTo-CBDateOnly -Value "$($Row.GraceUntil)"
        if (-not $grace) { return $none }
        if ($Now.Date -gt $grace) {
            return @{ Action = 'delete'; Step = 0; DaysLeft = $daysLeft; GraceUntil = "$($Row.GraceUntil)"
                Reason = "the grace period ended on $(Format-CBFriendlyDate -Value $Row.GraceUntil)"
            }
        }
        return $none
    }

    # No end date at all means the row predates a policy or was written by hand.
    # Acting on it would be acting on a guess, so it is left alone and shows up
    # as an anomaly rather than as a deletion.
    if (-not (ConvertTo-CBDateOnly -Value "$($Row.ExpiresOn)")) { return $none }

    if ($daysLeft -lt 0) {
        return @{ Action = 'block'; Step = 0; DaysLeft = $daysLeft
            GraceUntil = (Get-CBGraceUntilString -GraceDays ([int]$Settings.expiry.graceDays) -From $Now)
            Reason = "access ended on $(Format-CBFriendlyDate -Value $Row.ExpiresOn)"
        }
    }

    $reminder = Get-CBDueReminderStep -DaysLeft $daysLeft -ReminderDays @($Settings.expiry.reminderDays) -RemindersSent "$($Row.RemindersSent)"
    if ($reminder.Due -gt 0) {
        return @{ Action = 'remind'; Step = [int]$reminder.Due; DaysLeft = $daysLeft; GraceUntil = ''
            Reason = "access ends in $daysLeft day(s)"; Consumed = @($reminder.Consumed)
        }
    }
    return $none
}

function Test-CBRenewAllowed {
    <#
    .SYNOPSIS
        May this caller extend this guest, and by how much?
    .DESCRIPTION
        Separate from the act so the portal can grey out a button for the same
        reason the API would refuse it, from one definition.
    .OUTPUTS
        @{ Allowed; Reason; Days }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Caller, $Settings, [AllowNull()]$Days)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if (-not $Caller.IsAdmin -and -not $Settings.expiry.allowSelfRenew) {
        return @{ Allowed = $false; Reason = 'Extending access needs an administrator in this tenant.'; Days = 0 }
    }
    $max = [int]$Settings.expiry.maxRenewals
    $used = ConvertTo-CBInt -Value $Row.RenewCount -Default 0 -Min 0
    if (-not $Caller.IsAdmin -and $max -gt 0 -and $used -ge $max) {
        return @{ Allowed = $false; Days = 0
            Reason = "This access has already been extended $used time(s), which is the limit. An administrator can extend it further."
        }
    }
    $requested = ConvertTo-CBInt -Value $Days -Default ([int]$Settings.expiry.renewDays) -Min 1 -Max 3650
    return @{ Allowed = $true; Reason = ''; Days = [Math]::Min($requested, [int]$Settings.expiry.maxDays) }
}

function Get-CBRenewedExpiry {
    <#
    .SYNOPSIS
        The new end date when access is extended.
    .DESCRIPTION
        Counted from TODAY, not from the old end date. Extending from an end date
        that passed three weeks ago would hand out access that is already partly
        spent, and extending from a date months away would silently stack.
    #>
    [CmdletBinding()] param([int]$Days, $Settings, [datetime]$Now = [datetime]::MinValue)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $capped = [Math]::Min([Math]::Max(1, $Days), [int]$Settings.expiry.maxDays)
    return (Get-CBExpiryDateString -Days $capped -From $Now)
}

function Get-CBGuestActionOption {
    <#
    .SYNOPSIS
        Which actions are offered for this guest, and why any are not.
    .DESCRIPTION
        One definition, used by the portal to decide what to render and by nobody
        else to decide anything: the API still checks each action for itself. It
        exists so a greyed-out button and the refusal you would get by pressing it
        always give the same reason, which is the difference between a UI that
        explains itself and one that just fails.
    .OUTPUTS
        An array of @{ key; label; enabled; reason }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Caller, $Settings, [string]$State)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if (-not $State) { $State = (Get-CBGuestView -Row $Row -Settings $Settings).state }
    $state = "$State".ToLowerInvariant()
    $redeemed = [bool]"$($Row.RedeemedAtUtc)"
    $options = [System.Collections.Generic.List[object]]::new()

    # Nobody is accountable for this person, so anybody willing may take that on.
    # It is offered first and as its own action rather than as a hand-over to
    # yourself, because those are different things: a hand-over needs somebody to
    # hand to, and this one needs nobody's agreement but your own.
    $unowned = ("$($Row.PartitionKey)" -eq (Get-CBOrphanPartition))
    if ($unowned -and $state -ne 'deleted') {
        $options.Add([ordered]@{ key = 'claim'; label = 'Take this on'; enabled = $true; reason = '' })
    }

    $renew = Test-CBRenewAllowed -Row $Row -Caller $Caller -Settings $Settings -Days $null
    $renewLabel = switch ($state) {
        'blocked' { 'Restore access' }
        'deleted' { 'Bring them back' }
        default { 'Extend' }
    }
    $options.Add([ordered]@{ key = 'renew'; label = $renewLabel; enabled = [bool]$renew.Allowed; reason = "$($renew.Reason)" })

    $canCancel = ($state -notin @('blocked', 'deleted'))
    $options.Add([ordered]@{ key = 'cancel'; label = 'End access now'; enabled = $canCancel
            reason = $(if ($canCancel) { '' } else { 'Their access has already ended.' })
        })

    $canTransfer = ($state -ne 'deleted')
    $options.Add([ordered]@{ key = 'transfer'; label = 'Hand over'; enabled = $canTransfer
            reason = $(if ($canTransfer) { '' } else { 'They have been removed, so there is nothing to hand over.' })
        })

    # Resending only makes sense for somebody who has not accepted and whose
    # access is still live; anything else needs extending first.
    $canResend = (-not $redeemed -and $state -notin @('blocked', 'deleted'))
    if (-not $redeemed) {
        $options.Add([ordered]@{ key = 'resend'; label = 'Send the invitation again'; enabled = $canResend
                reason = $(if ($canResend) { '' } else { 'Extend their access first, then resend.' })
            })
    }
    return @($options)
}

# --- Graph: acting on the account --------------------------------------------

function Set-CBGuestSignIn {
    <#
    .SYNOPSIS
        Switches sign-in on or off for a guest.
    .NOTES
        Disabling the account stops new sign-ins. Tokens already issued remain
        valid until they expire (up to an hour), so we also ask Entra to revoke
        the guest's sessions. That call is best effort: it needs a permission the
        tool does not insist on, and failing it must not stop the block.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GuestId, [Parameter(Mandatory)][bool]$Enabled)
    Invoke-CBGraph -Method Patch -Uri ('/users/' + [Uri]::EscapeDataString($GuestId)) -Body @{ accountEnabled = $Enabled } | Out-Null
    if (-not $Enabled) {
        try { Invoke-CBGraph -Method Post -Uri ('/users/' + [Uri]::EscapeDataString($GuestId) + '/revokeSignInSessions') | Out-Null }
        catch { Write-Warning "Sign-in is disabled for $GuestId but existing sessions could not be revoked: $($_.Exception.Message)" }
    }
}

function Remove-CBGuestAccount {
    <#
    .SYNOPSIS
        Deletes a guest. Entra keeps deleted users recoverable for 30 days, which
        is what Restore-CBDeletedGuest uses.
    #>
    [CmdletBinding(SupportsShouldProcess)] param([Parameter(Mandatory)][string]$GuestId)
    if (-not $PSCmdlet.ShouldProcess($GuestId, 'Delete guest account')) { return }
    Invoke-CBGraph -Method Delete -Uri ('/users/' + [Uri]::EscapeDataString($GuestId)) | Out-Null
}

function Restore-CBDeletedGuest {
    <#
    .SYNOPSIS
        Brings a deleted guest back from the Entra recycle bin.
    .DESCRIPTION
        Available for 30 days after deletion. This is the last safety net under
        the grace period: if the wrong person was removed, they come back with
        the same object id, so every permission that referenced them still works.
    .OUTPUTS
        $true when restored.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GuestId)
    try {
        Invoke-CBGraph -Method Post -Uri ('/directory/deletedItems/' + [Uri]::EscapeDataString($GuestId) + '/restore') | Out-Null
        return $true
    }
    catch {
        Write-Warning "Could not restore ${GuestId} from the recycle bin: $($_.Exception.Message)"
        return $false
    }
}

# --- Performing a lifecycle action -------------------------------------------

function Send-CBGuestActionMessage {
    <#
    .SYNOPSIS
        Queues one piece of lifecycle work. The scanner decides; the processor
        acts, one guest per message, so a single failure never stops a run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('remind', 'block', 'delete')][string]$Action,
        [Parameter(Mandatory)]$Row,
        [int]$Step = 0,
        [string]$Reason,
        [int]$DelaySeconds = 0
    )
    $payload = [ordered]@{
        action      = $Action
        guestId     = "$($Row.RowKey)"
        ownerId     = "$($Row.PartitionKey)"
        step        = $Step
        reason      = "$Reason"
        enqueuedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    Send-CBQueueMessage -Content $payload -VisibilityTimeoutSeconds $DelaySeconds
}

function Get-CBGuestMailValue {
    <#
    .SYNOPSIS
        The token bag for any message about one guest, built from the row so
        every lifecycle mail says the same thing about the same person.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, $Settings, [int]$DaysLeft = 0)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $values = Get-CBMailTokenValue -Settings $Settings
    $values.guest = @{ displayName = "$($Row.DisplayName)"; email = "$($Row.Email)" }
    $values.owner = @{ displayName = "$($Row.OwnerDisplayName)"; email = "$($Row.OwnerUpn)" }
    $values.reason = "$($Row.Reason)"
    $values.expiresOn = Format-CBFriendlyDate -Value "$($Row.ExpiresOn)"
    $values.daysLeft = "$DaysLeft"
    $values.graceDays = "$($Settings.expiry.graceDays)"
    $values.deleteOn = Format-CBFriendlyDate -Value "$($Row.GraceUntil)"
    $values.lastSignIn = Format-CBFriendlyDate -Value "$($Row.LastSignInUtc)"
    return $values
}

function Invoke-CBGuestReminder {
    <#
    .SYNOPSIS
        Sends the reminder for one step and records that the step is spent.
    .DESCRIPTION
        The record is written even when the mail could not be sent, on purpose: a
        broken mailbox must not turn one reminder into a daily one. The failure is
        in the activity log and on the Diagnostics tab, which is where an operator
        looks, rather than in the owner's inbox forty times.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Decision, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $values = Get-CBGuestMailValue -Row $Row -Settings $Settings -DaysLeft ([int]$Decision.DaysLeft)
    $sent = $false
    $delivered = @()

    if ($Row.OwnerUpn) {
        try {
            if (Send-CBTemplateMail -Key 'ownerReminder' -To "$($Row.OwnerUpn)" -Values $values -Settings $Settings) {
                $sent = $true; $delivered += "$($Row.OwnerUpn)"
            }
        }
        catch { Write-Warning "Reminder to $($Row.OwnerUpn) failed: $($_.Exception.Message)" }
    }
    if ($Row.Email) {
        try {
            if (Send-CBTemplateMail -Key 'guestReminder' -To "$($Row.Email)" -Values $values -Settings $Settings) {
                $sent = $true; $delivered += "$($Row.Email)"
            }
        }
        catch { Write-Warning "Reminder to $($Row.Email) failed: $($_.Exception.Message)" }
    }

    # In simulation nothing was sent, so nothing is consumed either: turning
    # simulation off should still produce the reminder the log promised.
    if (-not $Settings.dryRun) {
        $consumed = if ($Decision.Consumed) { @($Decision.Consumed) } else { @([int]$Decision.Step) }
        Save-CBGuestRecord -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)" -Properties @{
            RemindersSent = (Add-CBReminderSent -Existing "$($Row.RemindersSent)" -Steps $consumed)
        }
    }

    Write-CBActivity -EventName "Reminded about $($Row.Email), $($Decision.DaysLeft) day(s) left" `
        -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)" -GuestUpn "$($Row.Email)" `
        -GuestDisplayName "$($Row.DisplayName)" -Simulated:([bool]$Settings.dryRun) `
        -Detail @{ step = [int]$Decision.Step; expiresOn = "$($Row.ExpiresOn)"; sentTo = ($delivered -join ', ') }
    return $sent
}

function Invoke-CBGuestBlock {
    <#
    .SYNOPSIS
        Ends access: sign-in off, grace period started, both parties told.
    .OUTPUTS
        @{ Done; Reason; Retry } - Retry means the work was refused by the storm
        guard and must be held rather than dropped.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Decision, $Settings, [string]$Actor)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $guestId = "$($Row.RowKey)"
    $ownerId = "$($Row.PartitionKey)"
    $graceUntil = if ($Decision.GraceUntil) { "$($Decision.GraceUntil)" } else { Get-CBGraceUntilString -GraceDays ([int]$Settings.expiry.graceDays) }

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would end access for $($Row.Email)" -Actor $Actor -OwnerId $ownerId -GuestId $guestId `
            -GuestUpn "$($Row.Email)" -GuestDisplayName "$($Row.DisplayName)" -Simulated `
            -Detail @{ reason = "$($Decision.Reason)"; deleteOn = $graceUntil }
        return @{ Done = $false; Reason = 'simulation'; Retry = $false }
    }

    $guard = Test-CBStormGuard -Action 'block' -Settings $Settings
    if (-not $guard.Allowed) { return @{ Done = $false; Reason = $guard.Reason; Retry = $true } }

    Set-CBGuestSignIn -GuestId $guestId -Enabled $false
    Save-CBGuestRecord -OwnerId $ownerId -GuestId $guestId -Properties @{
        State        = 'blocked'
        BlockedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        GraceUntil   = $graceUntil
    }

    $updated = Set-CBRowValue -Row ($Row.PSObject.Copy()) -Name 'GraceUntil' -Value $graceUntil
    $values = Get-CBGuestMailValue -Row $updated -Settings $Settings
    if ($Row.OwnerUpn) {
        try { [void](Send-CBTemplateMail -Key 'expiredBlocked' -To "$($Row.OwnerUpn)" -Values $values -Settings $Settings) }
        catch { Write-Warning "Could not tell $($Row.OwnerUpn) that access ended: $($_.Exception.Message)" }
    }

    Write-CBActivity -EventName "Ended access for $($Row.Email)" -Actor $Actor -OwnerId $ownerId -GuestId $guestId `
        -GuestUpn "$($Row.Email)" -GuestDisplayName "$($Row.DisplayName)" `
        -Detail @{ reason = "$($Decision.Reason)"; deleteOn = $graceUntil; restorableUntil = $graceUntil }

    # A zero-day grace means "remove them when they expire", so the deletion is
    # queued now rather than waiting a day for the next scan to notice.
    if ([int]$Settings.expiry.graceDays -le 0) {
        try { Send-CBGuestActionMessage -Action 'delete' -Row $updated -Reason 'no grace period is configured' }
        catch { Write-Warning "Could not queue the immediate deletion for ${guestId}: $($_.Exception.Message)" }
    }
    return @{ Done = $true; Reason = '' }
}

function Invoke-CBGuestDelete {
    <#
    .SYNOPSIS
        Removes a guest whose grace period has lapsed, and tells the owner.
    .OUTPUTS
        @{ Done; Reason; Retry }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Decision, $Settings, [string]$Actor)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $guestId = "$($Row.RowKey)"
    $ownerId = "$($Row.PartitionKey)"

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would remove $($Row.Email)" -Actor $Actor -OwnerId $ownerId -GuestId $guestId `
            -GuestUpn "$($Row.Email)" -GuestDisplayName "$($Row.DisplayName)" -Simulated -Detail @{ reason = "$($Decision.Reason)" }
        return @{ Done = $false; Reason = 'simulation'; Retry = $false }
    }

    $guard = Test-CBStormGuard -Action 'delete' -Settings $Settings
    if (-not $guard.Allowed) { return @{ Done = $false; Reason = $guard.Reason; Retry = $true } }

    Remove-CBGuestAccount -GuestId $guestId -Confirm:$false
    Save-CBGuestRecord -OwnerId $ownerId -GuestId $guestId -Properties @{
        State        = 'deleted'
        DeletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $values = Get-CBGuestMailValue -Row $Row -Settings $Settings
    if ($Row.OwnerUpn) {
        try { [void](Send-CBTemplateMail -Key 'deleted' -To "$($Row.OwnerUpn)" -Values $values -Settings $Settings) }
        catch { Write-Warning "Could not tell $($Row.OwnerUpn) about the removal: $($_.Exception.Message)" }
    }

    Write-CBActivity -EventName "Removed $($Row.Email)" -Actor $Actor -OwnerId $ownerId -GuestId $guestId `
        -GuestUpn "$($Row.Email)" -GuestDisplayName "$($Row.DisplayName)" `
        -Detail @{ reason = "$($Decision.Reason)"; recoverableForDays = 30 }
    return @{ Done = $true; Reason = '' }
}

function Invoke-CBQueuedGuestAction {
    <#
    .SYNOPSIS
        Performs one queued lifecycle action, after checking it is still the
        right thing to do.
    .DESCRIPTION
        The re-check is the point. Between the scan and this moment the owner may
        have extended the access, the guest may have been removed, or the message
        may simply be a duplicate. Acting on the message as written would undo a
        person's decision with a stale instruction, so the row is re-read and the
        decision recomputed; only a decision that still matches is carried out.
    .OUTPUTS
        @{ Handled; Outcome; Retry } - Retry means the caller should hold the
        message rather than let it be consumed.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Message, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $action = "$($Message.action)".Trim().ToLowerInvariant()
    $guestId = "$($Message.guestId)"
    if (-not $guestId) { return @{ Handled = $false; Retry = $false; Outcome = 'the message names no guest' } }

    $row = Get-CBGuestRow -GuestId $guestId
    if (-not $row) { return @{ Handled = $false; Retry = $false; Outcome = 'we no longer track that guest' } }

    $decision = Get-CBLifecycleAction -Row $row -Settings $Settings
    if ($decision.Action -ne $action) {
        Write-Host "Skipping '$action' for $($row.Email): the situation has changed and '$($decision.Action)' is now what is due."
        return @{ Handled = $false; Retry = $false; Outcome = "no longer due (now: $($decision.Action))" }
    }

    switch ($action) {
        'remind' {
            [void](Invoke-CBGuestReminder -Row $row -Decision $decision -Settings $Settings)
            return @{ Handled = $true; Retry = $false; Outcome = "reminded at the $($decision.Step)-day step" }
        }
        'block' {
            $result = Invoke-CBGuestBlock -Row $row -Decision $decision -Settings $Settings
            return @{ Handled = $result.Done; Retry = [bool]$result.Retry
                Outcome = $(if ($result.Done) { 'access ended' } else { $result.Reason })
            }
        }
        'delete' {
            $result = Invoke-CBGuestDelete -Row $row -Decision $decision -Settings $Settings
            return @{ Handled = $result.Done; Retry = [bool]$result.Retry
                Outcome = $(if ($result.Done) { 'removed' } else { $result.Reason })
            }
        }
        default { return @{ Handled = $false; Retry = $false; Outcome = "unknown action '$action'" } }
    }
}

# --- Owner actions -----------------------------------------------------------

function Test-CBGuestAccess {
    <#
    .SYNOPSIS
        May this caller act on this guest? The owner may, and an administrator
        may. Nobody else, whatever they send.
    .OUTPUTS
        @{ Ok; Status; Error; Row }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$GuestId)
    $row = Get-CBGuestRow -GuestId $GuestId
    if (-not $row) { return @{ Ok = $false; Status = 404; Error = 'We do not track that person.' } }
    if ("$($row.PartitionKey)" -ne $Caller.Oid -and -not $Caller.IsAdmin) {
        # Deliberately the same answer as "does not exist": whether a colleague
        # works with a particular external company is not everybody's business.
        return @{ Ok = $false; Status = 404; Error = 'We do not track that person.' }
    }
    return @{ Ok = $true; Status = 200; Row = $row }
}

function Update-CBGuestExpiry {
    <#
    .SYNOPSIS
        Extends access, and brings back a guest who was blocked or deleted while
        still inside the recovery window.
    .DESCRIPTION
        One action rather than three, because from the owner's point of view
        "they still need access" is one thought. What it takes to honour that
        depends on how far the guest has fallen: re-enable a blocked account,
        restore a deleted one from the recycle bin, or simply move the date.
    .OUTPUTS
        @{ Ok; Status; Error; Guest; Warnings; Simulated }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$GuestId, [AllowNull()]$Days, [string]$Reason, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $access = Test-CBGuestAccess -Caller $Caller -GuestId $GuestId
    if (-not $access.Ok) { return $access }
    $row = $access.Row
    $ownerId = "$($row.PartitionKey)"
    $warnings = [System.Collections.Generic.List[string]]::new()

    $allowed = Test-CBRenewAllowed -Row $row -Caller $Caller -Settings $Settings -Days $Days
    if (-not $allowed.Allowed) { return @{ Ok = $false; Status = 403; Error = $allowed.Reason } }

    $state = "$($row.State)".ToLowerInvariant()
    $expiresOn = Get-CBRenewedExpiry -Days $allowed.Days -Settings $Settings

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would extend $($row.Email) to $expiresOn" -Actor $Caller.Upn -OwnerId $ownerId `
            -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" -Simulated `
            -Detail @{ days = $allowed.Days; from = "$($row.ExpiresOn)" }
        return @{ Ok = $true; Status = 200; Simulated = $true; Warnings = @()
            Guest = [ordered]@{ id = $GuestId; displayName = "$($row.DisplayName)"; email = "$($row.Email)"
                expiresOn = $expiresOn; expiresOnLabel = (Format-CBFriendlyDate -Value $expiresOn)
                statusLabel = 'Nothing was changed: simulation mode is on' }
        }
    }

    if ($state -eq 'deleted') {
        if (-not (Restore-CBDeletedGuest -GuestId $GuestId)) {
            return @{ Ok = $false; Status = 410
                Error = 'That account has been removed and could not be brought back. Entra keeps deleted accounts for 30 days; after that they have to be invited afresh.'
            }
        }
        $warnings.Add('The account was restored from the Entra recycle bin. Anything shared with them before should work again.')
    }
    if ($state -in @('blocked', 'deleted')) {
        try { Set-CBGuestSignIn -GuestId $GuestId -Enabled $true }
        catch {
            Write-Warning "Could not re-enable ${GuestId}: $($_.Exception.Message)"
            return @{ Ok = $false; Status = 502; Error = "The end date was not changed because sign-in could not be switched back on: $($_.Exception.Message)" }
        }
    }

    try { Set-CBGuestExpiryAttribute -GuestId $GuestId -ExpiresOn $expiresOn -Settings $Settings }
    catch {
        Write-Warning "Could not write the expiry attribute for ${GuestId}: $($_.Exception.Message)"
        $warnings.Add('The new end date could not be written onto the account itself, so it is only recorded here.')
    }

    Save-CBGuestRecord -OwnerId $ownerId -GuestId $GuestId -Properties @{
        ExpiresOn      = $expiresOn
        State          = $(if ("$($row.RedeemedAtUtc)") { 'active' } else { 'pending' })
        GraceUntil     = ''
        BlockedAtUtc   = ''
        DeletedAtUtc   = ''
        # A fresh window of reminders: the previous ones were about a date that
        # no longer applies.
        RemindersSent  = ''
        RenewCount     = [string]((ConvertTo-CBInt -Value $row.RenewCount -Default 0 -Min 0) + 1)
        LastRenewedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        LastRenewedBy  = $Caller.Upn
        Reason         = $(if ("$Reason".Trim()) { ConvertTo-CBBoundedString -Value $Reason -MaxLength 400 } else { "$($row.Reason)" })
    }

    Write-CBActivity -EventName "Extended $($row.Email) to $expiresOn" -Actor $Caller.Upn -OwnerId $ownerId `
        -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" `
        -Detail @{ days = $allowed.Days; previous = "$($row.ExpiresOn)"; wasState = $state }

    $fresh = Get-CBGuestRow -GuestId $GuestId
    return @{ Ok = $true; Status = 200; Simulated = $false; Warnings = @($warnings)
        Guest = $(if ($fresh) { Get-CBGuestView -Row $fresh -Settings $Settings } else { @{ id = $GuestId } })
    }
}

function Stop-CBGuestAccess {
    <#
    .SYNOPSIS
        Ends access now, at the owner's request, rather than waiting for the end
        date. The grace period still applies, so this is reversible.
    .OUTPUTS
        @{ Ok; Status; Error; Guest; Simulated }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$GuestId, [string]$Reason, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $access = Test-CBGuestAccess -Caller $Caller -GuestId $GuestId
    if (-not $access.Ok) { return $access }
    $row = $access.Row
    $ownerId = "$($row.PartitionKey)"
    $state = "$($row.State)".ToLowerInvariant()
    if ($state -in @('blocked', 'deleted')) {
        return @{ Ok = $false; Status = 409; Error = 'Their access has already ended.' }
    }

    $graceUntil = Get-CBGraceUntilString -GraceDays ([int]$Settings.expiry.graceDays)
    $why = ConvertTo-CBBoundedString -Value $Reason -MaxLength 400 -Default 'ended early by the owner'

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would end access for $($row.Email) now" -Actor $Caller.Upn -OwnerId $ownerId `
            -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" -Simulated -Detail @{ reason = $why }
        return @{ Ok = $true; Status = 200; Simulated = $true
            Guest = [ordered]@{ id = $GuestId; displayName = "$($row.DisplayName)"; statusLabel = 'Nothing was changed: simulation mode is on' }
        }
    }

    # No storm guard here. It exists to stop the TOOL acting on a crowd by
    # itself; one person deliberately ending one collaboration is the opposite of
    # that, and refusing it would leave somebody unable to close off access they
    # know should be closed.
    try { Set-CBGuestSignIn -GuestId $GuestId -Enabled $false }
    catch { return @{ Ok = $false; Status = 502; Error = "Sign-in could not be switched off: $($_.Exception.Message)" } }

    Save-CBGuestRecord -OwnerId $ownerId -GuestId $GuestId -Properties @{
        State        = 'blocked'
        BlockedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        GraceUntil   = $graceUntil
        ExpiresOn    = (Get-CBExpiryDateString -Days 0)
    }
    Write-CBActivity -EventName "Ended access for $($row.Email) early" -Actor $Caller.Upn -OwnerId $ownerId `
        -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" `
        -Detail @{ reason = $why; deleteOn = $graceUntil }

    if ([int]$Settings.expiry.graceDays -le 0) {
        $updated = Set-CBRowValue -Row ($row.PSObject.Copy()) -Name 'GraceUntil' -Value $graceUntil
        try { Send-CBGuestActionMessage -Action 'delete' -Row $updated -Reason 'ended early with no grace period configured' }
        catch { Write-Warning "Could not queue the immediate deletion for ${GuestId}: $($_.Exception.Message)" }
    }

    $fresh = Get-CBGuestRow -GuestId $GuestId
    return @{ Ok = $true; Status = 200; Simulated = $false
        Guest = $(if ($fresh) { Get-CBGuestView -Row $fresh -Settings $Settings } else { @{ id = $GuestId } })
        Message = "Access ended. The account is kept until $(Format-CBFriendlyDate -Value $graceUntil) in case you need to undo this."
    }
}

function Move-CBGuestOwner {
    <#
    .SYNOPSIS
        Hands a guest to a colleague, who becomes accountable for them from then
        on and receives the reminders.
    .DESCRIPTION
        Ownership is the table's PartitionKey, so a transfer is a delete and an
        insert. The new row is written FIRST: if the process dies in between, the
        guest is owned twice rather than not at all, and a duplicate is something
        an administrator can see and fix.
    .OUTPUTS
        @{ Ok; Status; Error; Guest; Simulated }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][string]$GuestId,
        [Parameter(Mandatory)][string]$NewOwnerId,
        [string]$Reason,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $access = Test-CBGuestAccess -Caller $Caller -GuestId $GuestId
    if (-not $access.Ok) { return $access }
    $row = $access.Row
    $oldOwnerId = "$($row.PartitionKey)"
    if ($NewOwnerId -eq $oldOwnerId) { return @{ Ok = $false; Status = 400; Error = 'They already own this collaborator.' } }

    $newOwner = Get-CBUserProfile -Oid $NewOwnerId
    if (-not $newOwner) { return @{ Ok = $false; Status = 404; Error = 'That colleague could not be found.' } }
    if ("$($newOwner.userType)" -ne 'Member') { return @{ Ok = $false; Status = 400; Error = 'A guest cannot look after another guest.' } }
    if (-not $newOwner.accountEnabled) { return @{ Ok = $false; Status = 400; Error = "$($newOwner.displayName)'s account is disabled, so they cannot take this on." } }

    $newUpn = @($newOwner.userPrincipalName, $newOwner.mail) | Where-Object { $_ } | Select-Object -First 1
    $why = ConvertTo-CBBoundedString -Value $Reason -MaxLength 400 -Default "$($row.Reason)"

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would hand $($row.Email) to $($newOwner.displayName)" -Actor $Caller.Upn -OwnerId $oldOwnerId `
            -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" -Simulated -Detail @{ to = "$newUpn"; reason = $why }
        return @{ Ok = $true; Status = 200; Simulated = $true
            Guest = [ordered]@{ id = $GuestId; displayName = "$($row.DisplayName)"; statusLabel = 'Nothing was changed: simulation mode is on' }
        }
    }

    $properties = @{}
    foreach ($p in $row.PSObject.Properties) {
        if ($p.Name -in @('PartitionKey', 'RowKey', 'Timestamp', 'odata.etag')) { continue }
        $properties[$p.Name] = "$($p.Value)"
    }
    $properties.OwnerUpn = "$newUpn"
    $properties.OwnerDisplayName = "$($newOwner.displayName)"
    $properties.Reason = $why
    $properties.TransferredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $properties.TransferredBy = $Caller.Upn

    Save-CBGuestRecord -OwnerId $NewOwnerId -GuestId $GuestId -Properties $properties -Replace
    try { Remove-CBTableEntity -Table (Get-CBTableNames).Guests -PartitionKey $oldOwnerId -RowKey $GuestId }
    catch { Write-Warning "The guest was handed over but the old record could not be removed: $($_.Exception.Message)" }

    if ($Settings.invite.setSponsor) { [void](Add-CBGuestSponsor -GuestId $GuestId -OwnerId $NewOwnerId) }

    if ($newUpn) {
        $values = Get-CBGuestMailValue -Row $row -Settings $Settings
        $values.owner = @{ displayName = "$($newOwner.displayName)"; email = "$newUpn" }
        $values.previousOwner = @{ displayName = "$($row.OwnerDisplayName)" }
        $values.reason = $why
        try { [void](Send-CBTemplateMail -Key 'ownershipTransferred' -To "$newUpn" -Values $values -Settings $Settings) }
        catch { Write-Warning "Could not tell $newUpn about the hand-over: $($_.Exception.Message)" }
    }

    Write-CBActivity -EventName "Handed $($row.Email) to $($newOwner.displayName)" -Actor $Caller.Upn -OwnerId $NewOwnerId `
        -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" `
        -Detail @{ from = "$($row.OwnerUpn)"; to = "$newUpn"; reason = $why }

    $fresh = Get-CBGuestRow -GuestId $GuestId
    return @{ Ok = $true; Status = 200; Simulated = $false
        Guest = $(if ($fresh) { Get-CBGuestView -Row $fresh -Settings $Settings } else { @{ id = $GuestId } })
        Message = "$($newOwner.displayName) now looks after $($row.DisplayName)."
    }
}

function Update-CBGuestInvitation {
    <#
    .SYNOPSIS
        Sends a fresh invitation to a guest who has not accepted yet.
    .DESCRIPTION
        Graph issues a new redeem link for the existing account rather than
        creating a second one, so the object id, the end date and everything
        already shared with them survive.
    .OUTPUTS
        @{ Ok; Status; Error; Simulated; Message }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$GuestId, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $access = Test-CBGuestAccess -Caller $Caller -GuestId $GuestId
    if (-not $access.Ok) { return $access }
    $row = $access.Row
    $ownerId = "$($row.PartitionKey)"

    if ("$($row.RedeemedAtUtc)") { return @{ Ok = $false; Status = 409; Error = 'They have already accepted, so there is nothing to resend.' } }
    if ("$($row.State)".ToLowerInvariant() -in @('blocked', 'deleted')) {
        return @{ Ok = $false; Status = 409; Error = 'Their access has ended. Extend it first, then resend.' }
    }

    if ($Settings.dryRun) {
        Write-CBActivity -EventName "Would resend the invitation to $($row.Email)" -Actor $Caller.Upn -OwnerId $ownerId `
            -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" -Simulated
        return @{ Ok = $true; Status = 200; Simulated = $true; Message = 'Simulation mode is on, so nothing was actually sent.' }
    }

    $guard = Test-CBStormGuard -Action 'invite' -Settings $Settings
    if (-not $guard.Allowed) { return @{ Ok = $false; Status = 429; Error = $guard.Reason } }

    $redirect = Get-CBWelcomeUrl -Settings $Settings
    $invitation = Invoke-CBGraph -Method Post -Uri '/invitations' -Body @{
        invitedUserEmailAddress = "$($row.Email)"
        invitedUserDisplayName  = "$($row.DisplayName)"
        inviteRedirectUrl       = $redirect
        sendInvitationMessage   = $false
    }

    $values = Get-CBGuestMailValue -Row $row -Settings $Settings
    $values.redeemUrl = "$($invitation.inviteRedeemUrl)"
    $sent = $false
    try { $sent = Send-CBTemplateMail -Key 'invitation' -To "$($row.Email)" -Values $values -Settings $Settings }
    catch { Write-Warning "Could not resend the invitation to $($row.Email): $($_.Exception.Message)" }

    Write-CBActivity -EventName "Resent the invitation to $($row.Email)" -Actor $Caller.Upn -OwnerId $ownerId `
        -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" -Detail @{ sent = $sent }

    if (-not $sent) { return @{ Ok = $false; Status = 502; Error = 'A new link was created but the email could not be sent. Check the mail configuration.' } }
    return @{ Ok = $true; Status = 200; Simulated = $false; Message = "A fresh invitation is on its way to $($row.Email)." }
}
