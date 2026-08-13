# The daily sweep: decide what is owed for every guest, and queue it.
#
# This function DECIDES and never acts. Everything it finds becomes one queue
# message per guest, handled by GuestActionProcessor. Two reasons:
#
#   * one guest failing (a stale object, a Graph hiccup) must not stop the rest
#     of the run, and a queue gives per-item retries and a poison queue for free;
#   * the storm guard can then refuse work item by item, pausing the tool partway
#     through instead of after it has already acted on everybody.
#
# It runs early morning UTC so that reminders arrive before the working day in
# most of Europe, and well before the daily counters it shares with the rest of
# the tool are anywhere near their caps.

param($Timer)

Invoke-CBFunctionRun -Name 'GuestScanner' -Script {
    Initialize-CBTables
    $settings = Get-CBSettings
    if (-not $settings.setupComplete) {
        Write-Host 'Setup is not complete; not scanning.'
        return
    }
    if (Test-CBPaused) {
        # Queueing work while paused would build a backlog that all lands at once
        # the moment somebody resumes, which is the opposite of what a pause is
        # for. The next run picks everything up.
        Write-Host 'Processing is paused by the storm guard; not scanning. Resume from the portal to continue.'
        return
    }

    # The directory list serves two purposes: it sizes the guest population for
    # the storm guard's percent ceiling, and it tells us which tracked guests no
    # longer exist. Adoption of guests we do not track yet is a separate pass.
    $directory = @{}
    $population = 0
    try {
        $directory = Get-CBGuestDirectory
        $population = $directory.Count
        Set-CBGuestCount -Count $population
        Write-Host "The tenant has $population guest account(s)."
    }
    catch {
        # Without the directory we cannot tell "deleted elsewhere" from "Graph is
        # having a bad minute", and deleting a row on that basis would lose the
        # audit trail. So we carry on with dates only and skip that check.
        Write-Warning "Could not list the tenant's guests: $($_.Exception.Message). Continuing on the recorded dates alone."
        $directory = $null
    }

    # Adopt anything we do not track yet, BEFORE evaluating, so a guest adopted
    # today is already carrying an end date when the sweep reaches them. Adoption
    # never blocks or deletes: it records an owner and a date, and the ordinary
    # lifecycle takes it from there.
    $adoption = @{ Adopted = 0; Orphaned = 0; Remaining = 0 }
    if ($null -ne $directory) {
        try { $adoption = Invoke-CBGuestAdoption -Directory $directory -Settings $settings }
        catch { Write-Warning "Adoption pass failed: $($_.Exception.Message)" }
    }

    # Sign-in activity is fetched every run, not just when the inactivity policy
    # is on: "when was this person last active" is the question owners ask about
    # a collaborator they have half forgotten, and it is worth one extra sweep a
    # day. On a tenant without the licence the sweep fails on its own and says
    # so, and everything else carries on.
    #
    # Then reconcile the records with the directory: acceptance, last active and
    # display names. Before the lifecycle runs, so today's decisions are made on
    # today's facts rather than yesterday's. Both are skipped when the directory
    # could not be listed: there is nothing to reconcile against, and the sweep
    # would be spent for nothing.
    $signIn = @{ Available = $false; Users = @{}; Error = '' }
    $refresh = @{ Checked = 0; Updated = 0 }
    if ($null -ne $directory) {
        $signIn = Get-CBUserSignInActivity
        if ($signIn.Available) { Write-Host "Sign-in activity read for $($signIn.Users.Count) guest(s)." }
        try { $refresh = Update-CBGuestDirectoryFacts -Directory $directory -SignIn $signIn -Settings $settings }
        catch { Write-Warning "Could not refresh the guest records from Entra: $($_.Exception.Message)" }
    }

    # Anything a browser was asked to send and never confirmed. A guest who
    # never received their invitation because somebody closed a tab is the one
    # failure the send-as-the-inviter option must not be able to cause.
    $outbox = @{ Swept = 0; Sent = 0 }
    try { $outbox = Invoke-CBOutboxSweep -Settings $settings }
    catch { Write-Warning "Could not sweep unsent messages: $($_.Exception.Message)" }

    $rows = @(Get-CBAllGuestRow)
    Write-Host "$($rows.Count) tracked guest record(s)."

    $now = [DateTime]::UtcNow
    $queued = @{ remind = 0; block = 0; delete = 0 }
    $gone = 0
    $untracked = 0
    $failed = 0
    $idle = 0

    foreach ($row in $rows) {
        try {
            $guestId = "$($row.RowKey)"
            $state = "$($row.State)".ToLowerInvariant()

            if ($null -ne $directory -and -not $directory.ContainsKey($guestId)) {
                if ($state -eq 'deleted') { continue }
                # Removed by somebody else, or by us on a previous run whose row
                # write did not land. Recorded, not deleted: the row is the audit
                # trail for a guest that once existed.
                Save-CBGuestRecord -OwnerId "$($row.PartitionKey)" -GuestId $guestId -Properties @{
                    State        = 'deleted'
                    DeletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                }
                Write-CBActivity -EventName "$($row.Email) no longer exists in Entra" -OwnerId "$($row.PartitionKey)" `
                    -GuestId $guestId -GuestUpn "$($row.Email)" -GuestDisplayName "$($row.DisplayName)" `
                    -Detail 'The account was removed outside Collaborate, so the record is closed here too.'
                $gone++
                continue
            }

            $decision = Get-CBLifecycleAction -Row $row -Settings $settings -Now $now
            if ($decision.Action -ne 'none') {
                Send-CBGuestActionMessage -Action $decision.Action -Row $row -Step ([int]$decision.Step) -Reason "$($decision.Reason)"
                $queued[$decision.Action] = [int]$queued[$decision.Action] + 1
                continue
            }

            # Inactivity is only considered when the ordinary lifecycle has
            # nothing to say, so a guest about to expire anyway is never also
            # chased for being idle.
            if ($settings.inactivity.enabled) {
                $stale = Get-CBInactivityDecision -Row $row -Settings $settings -Now $now -SignIn $signIn.Users["$guestId"]
                if ($stale.Action -eq 'notify') {
                    [void](Invoke-CBInactivityNotice -Row $row -Decision $stale -Settings $settings)
                    $idle++
                }
                elseif ($stale.Action -eq 'block') {
                    # Routed through the same queue and the same storm guard as
                    # an ordinary expiry. The row's end date is brought forward
                    # so the block decision holds when the processor re-checks it.
                    Save-CBGuestRecord -OwnerId "$($row.PartitionKey)" -GuestId $guestId -Properties @{
                        ExpiresOn = (Get-CBExpiryDateString -Days -1 -From $now)
                        Reason    = "$($row.Reason) (ended for inactivity: $($stale.Reason))"
                    }
                    Send-CBGuestActionMessage -Action 'block' -Row $row -Reason "inactive: $($stale.Reason)"
                    $queued.block = [int]$queued.block + 1
                    $idle++
                }
            }
        }
        catch {
            $failed++
            Write-Warning "Could not evaluate $($row.Email): $($_.Exception.Message)"
        }
    }

    if ($null -ne $directory) {
        $tracked = @{}
        foreach ($row in $rows) { $tracked["$($row.RowKey)"] = $true }
        foreach ($id in $directory.Keys) { if (-not $tracked.ContainsKey($id)) { $untracked++ } }
    }

    # Guests nobody is accountable for will still expire on schedule, but nobody
    # will be reminded first, because there is nobody to remind. That is worth a
    # human's attention, so the service desk gets a digest.
    $orphans = @{ Sent = $false; Count = 0 }
    try { $orphans = Send-CBOrphanDigest -Settings $settings }
    catch { Write-Warning "Could not send the unowned-guest digest: $($_.Exception.Message)" }

    $summary = "queued $($queued.remind) reminder(s), $($queued.block) end(s) of access, $($queued.delete) removal(s); " +
    "adopted $($adoption.Adopted); refreshed $($refresh.Updated); $idle idle; $gone gone from Entra; $untracked not tracked yet; $failed could not be evaluated."
    Write-Host "GuestScanner: $summary"
    Write-CBSystemActivity -EventName 'Daily guest scan' -Detail @{
        tracked    = $rows.Count
        population = $population
        refreshed  = $refresh.Updated
        signInData = $(if ($signIn.Available) { 'available' } else { 'unavailable' })
        unsentSwept = $outbox.Swept
        reminders  = $queued.remind
        blocks     = $queued.block
        deletions  = $queued.delete
        adopted    = $adoption.Adopted
        adoptionRemaining = $adoption.Remaining
        inactive   = $idle
        unowned    = $orphans.Count
        goneFromEntra = $gone
        untracked  = $untracked
        failed     = $failed
        simulation = [bool]$settings.dryRun
    }

    if ($failed -gt 0 -and $failed -eq $rows.Count -and $rows.Count -gt 0) {
        throw "None of the $failed tracked guest(s) could be evaluated, so the scan achieved nothing."
    }
}
