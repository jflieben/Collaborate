# Sending a message as the person who caused it, instead of as the service desk.
#
# By default every message leaves from ONE shared mailbox. The deploy authorises
# the managed identity for that mailbox through Exchange RBAC and nothing else,
# so the worst this tool can do with mail is send from the address it was set up
# with. That is the right default, but it means a guest hears from
# "servicedesk@" about somebody they have never met.
#
# The alternative is to send it from the employee, and this deliberately does NOT
# use the on-behalf-of flow, even though the app already has one for sharing:
#
#   * a delegated Mail.Send used from the Function App sends from a datacentre
#     IP, on a token the user never saw issued. Conditional Access evaluates
#     that as a sign-in from an unfamiliar location on an unmanaged device --
#     which is exactly what a locked-down tenant blocks, and SHOULD block. The
#     tool would work until somebody tightened a policy, then fail at the worst
#     moment for a reason nobody would connect to this;
#   * an application Mail.Send on the managed identity would let a guest
#     management tool send mail as anybody in the tenant. Nobody should grant
#     that, and no amount of internal discipline makes it reasonable to ask.
#
# So the message is rendered here and handed to the browser that asked for it,
# and the SPA sends it with its own delegated token, from the user's own device,
# in a session the tenant already trusts. Nothing about the user's credentials
# ever reaches this code.
#
# WHAT MUST NOT HAPPEN is a guest who never gets their invitation because
# somebody closed a tab. So the recipe -- the template key and its token values,
# never the rendered HTML -- is parked on the guest's own record, and:
#
#   * the browser reports back, and success clears it;
#   * a failure the browser reports sends it from the shared mailbox at once;
#   * anything still parked after a few minutes is swept up by the daily scan
#     and sent from the shared mailbox too.
#
# The fallback is the point. "It came from the person who invited them" is a
# nicety. "It arrived" is the product.

$script:CBPendingMailSweepMinutes = 15

function ConvertTo-CBPendingMail {
    <#
    .SYNOPSIS
        The parked recipe as a compact JSON string, and back again.
    .DESCRIPTION
        The RECIPE is stored, not the rendered message: a template key and the
        token values it was rendered from. That keeps the row small, and it means
        the fallback send picks up an administrator's later edit to the template
        rather than replaying a copy made before it.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)]$Values)
    return (@{ key = $Key; to = $To; values = $Values } | ConvertTo-Json -Depth 12 -Compress)
}

function ConvertFrom-CBPendingMail {
    [CmdletBinding()] param([AllowNull()][string]$Json)
    if (-not "$Json".Trim()) { return $null }
    try {
        $parsed = $Json | ConvertFrom-Json
        if (-not $parsed.key -or -not $parsed.to) { return $null }
        return $parsed
    }
    catch {
        Write-Warning "A parked message could not be read back: $($_.Exception.Message)"
        return $null
    }
}

function Get-CBOutboxMessage {
    <#
    .SYNOPSIS
        Renders one message for the browser to send.
    .OUTPUTS
        @{ guestId; to; subject; html } or $null when the template is switched
        off, which is what the switch means.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$To, [Parameter(Mandatory)]$Values, [string]$GuestId, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    # No inline logo: the browser sends through /me/sendMail without attachment
    # plumbing, so the shell falls back to the logo the mail client can fetch or
    # to the wordmark. A branded header that always renders beats an inline
    # image that only renders down one of two paths.
    $rendered = Get-CBRenderedEmail -Key $Key -Values $Values -Settings $Settings -LogoCid ''
    if (-not $rendered.Enabled) {
        Write-Host "Email template '$Key' is switched off; nothing handed to the browser."
        return $null
    }
    return [ordered]@{ guestId = "$GuestId"; to = "$To"; subject = "$($rendered.Subject)"; html = "$($rendered.Html)" }
}

function Submit-CBGuestMail {
    <#
    .SYNOPSIS
        Sends an interactive message the way the tenant has asked for: from the
        service desk mailbox now, or handed to the caller's browser to send as
        themselves.
    .DESCRIPTION
        The single decision point. Every interactive message goes through here so
        the choice is made once, and so a caller cannot accidentally send half
        the flow one way and half the other.

        There is no setting. A message somebody caused by pressing a button goes
        from that person, and the shared mailbox is the fallback rather than an
        alternative: leaving it configurable meant offering an administrator a
        choice between "correct" and "also correct but less personal", which is
        not a decision worth a field.

        Scheduled mail does NOT come through here and never can: reminders,
        expiry notices and digests happen when nobody is signed in, so there is
        no browser to hand them to. Those always leave from the shared mailbox,
        which is also the honest answer -- they are the tool speaking, not a
        person.
    .OUTPUTS
        @{ Sent; Handed; Message } - Sent means it has gone. Handed means it is
        parked and the browser has been asked to send it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)]$Values,
        $Caller,
        [string]$OwnerId,
        [string]$GuestId,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }

    # No caller means nobody is there to send it: a timer, a queue worker, or an
    # endpoint acting without a signed-in person. That is the shared mailbox's
    # job and always was.
    $viaPerson = $Caller -and $Caller.Upn -and $GuestId
    if (-not $viaPerson) {
        return @{ Sent = [bool](Send-CBTemplateMail -Key $Key -To $To -Values $Values -Settings $Settings); Handed = $false; Message = $null }
    }

    if ($Settings.dryRun) {
        Write-Host "[simulation] Would ask $($Caller.Upn)'s browser to send '$Key' to $To."
        return @{ Sent = $false; Handed = $false; Message = $null }
    }

    $message = Get-CBOutboxMessage -Key $Key -To $To -Values $Values -GuestId $GuestId -Settings $Settings
    if (-not $message) { return @{ Sent = $false; Handed = $false; Message = $null } }

    Save-CBGuestRecord -OwnerId $OwnerId -GuestId $GuestId -Properties @{
        PendingMailJson  = (ConvertTo-CBPendingMail -Key $Key -To $To -Values $Values)
        PendingMailSince = [DateTimeOffset]::UtcNow.ToString('o')
    }
    return @{ Sent = $false; Handed = $true; Message = $message }
}

function Clear-CBPendingMail {
    [CmdletBinding()] param([Parameter(Mandatory)][AllowEmptyString()][string]$OwnerId, [Parameter(Mandatory)][string]$GuestId)
    Save-CBGuestRecord -OwnerId $OwnerId -GuestId $GuestId -Properties @{ PendingMailJson = ''; PendingMailSince = '' }
}

function Send-CBPendingMailFromServicedesk {
    <#
    .SYNOPSIS
        Sends a parked message from the shared mailbox and clears it, whatever
        the outcome.
    .DESCRIPTION
        Clearing even on failure is deliberate, and the same reasoning as
        reminders: a mailbox that is refusing mail must not turn one message into
        a permanent retry that the sweep re-attempts every single day. The
        failure is recorded where somebody will see it.
    .OUTPUTS
        @{ Sent; Reason }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Row, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $pending = ConvertFrom-CBPendingMail -Json "$($Row.PendingMailJson)"
    if (-not $pending) {
        Clear-CBPendingMail -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)"
        return @{ Sent = $false; Reason = 'nothing parked' }
    }

    $sent = $false
    $reason = ''
    try { $sent = [bool](Send-CBTemplateMail -Key "$($pending.key)" -To "$($pending.to)" -Values $pending.values -Settings $Settings) }
    catch {
        $reason = "$($_.Exception.Message)"
        Write-Warning "Fallback send of '$($pending.key)' to $($pending.to) failed: $reason"
    }
    Clear-CBPendingMail -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)"

    Write-CBActivity -EventName $(if ($sent) { "Sent $($pending.to) their message from the service desk instead" }
        else { "Could not send $($pending.to) their message" }) `
        -OwnerId "$($Row.PartitionKey)" -GuestId "$($Row.RowKey)" -GuestUpn "$($Row.Email)" -GuestDisplayName "$($Row.DisplayName)" `
        -Detail @{ template = "$($pending.key)"; sent = $sent; error = $reason
        why = 'The message was meant to be sent by the person who created it, and their browser did not manage it.'
    }
    return @{ Sent = $sent; Reason = $reason }
}

function Complete-CBOutboxMessage {
    <#
    .SYNOPSIS
        The browser reporting what happened to a message it was handed.
    .OUTPUTS
        @{ Ok; Status; Error; Message; FellBack }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$GuestId, [bool]$Ok, [string]$ErrorText, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }

    # The same access rule as everything else about a guest: the owner or an
    # administrator. A report about somebody else's guest is not a small lie, it
    # is a way to make their invitation be re-sent from the service desk.
    $access = Test-CBGuestAccess -Caller $Caller -GuestId $GuestId
    if (-not $access.Ok) { return $access }
    $row = $access.Row

    if (-not "$($row.PendingMailJson)") {
        # Already swept, or a duplicate report. Not an error: the outcome the
        # caller wanted is the outcome we are in.
        return @{ Ok = $true; Status = 200; Message = 'Nothing was waiting to be sent.'; FellBack = $false }
    }

    if ($Ok) {
        Clear-CBPendingMail -OwnerId "$($row.PartitionKey)" -GuestId $GuestId
        Write-CBActivity -EventName "$($Caller.DisplayName) sent $($row.Email) their message" -Actor $Caller.Upn `
            -OwnerId "$($row.PartitionKey)" -GuestId $GuestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" `
            -Detail @{ from = $Caller.Upn; via = 'the sender own mailbox' }
        return @{ Ok = $true; Status = 200; Message = 'Sent.'; FellBack = $false }
    }

    Write-Warning "$($Caller.Upn) could not send to $($row.Email): $ErrorText"
    $result = Send-CBPendingMailFromServicedesk -Row $row -Settings $Settings
    return @{
        Ok       = $true
        Status   = 200
        FellBack = $true
        Message  = $(if ($result.Sent) { "That could not be sent from your mailbox, so it went from the service desk instead." }
            else { "That could not be sent from your mailbox, and the service desk could not send it either. $($row.Email) has not been told." })
    }
}

function Invoke-CBOutboxSweep {
    <#
    .SYNOPSIS
        Sends anything still parked after the browser has had long enough, from
        the shared mailbox.
    .DESCRIPTION
        The safety net for a closed tab, a lost connection or a browser that was
        refused a token. A few minutes is long enough for a send that normally
        takes under a second, and short enough that the guest is not left
        waiting.
    .OUTPUTS
        @{ Swept; Sent }
    #>
    [CmdletBinding()] param($Settings, [int]$OlderThanMinutes = 0)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if ($OlderThanMinutes -le 0) { $OlderThanMinutes = $script:CBPendingMailSweepMinutes }
    $cutoff = [DateTimeOffset]::UtcNow.AddMinutes(-$OlderThanMinutes)

    $swept = 0
    $sent = 0
    foreach ($row in @(Get-CBAllGuestRow)) {
        if (-not "$($row.PendingMailJson)") { continue }
        $since = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse("$($row.PendingMailSince)", [ref]$since)) { $since = [DateTimeOffset]::MinValue }
        if ($since -gt $cutoff) { continue }
        $swept++
        $result = Send-CBPendingMailFromServicedesk -Row $row -Settings $Settings
        if ($result.Sent) { $sent++ }
    }
    if ($swept -gt 0) { Write-Host "Outbox sweep: $swept message(s) were never sent by a browser; $sent went from the service desk." }
    return @{ Swept = $swept; Sent = $sent }
}
