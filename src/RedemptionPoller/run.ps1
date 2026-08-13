# Notices when an invited guest has accepted, and tells their owner.
#
# Polling rather than a Graph change-notification subscription, on purpose: a
# subscription needs a public webhook, and the whole point of this deployment is
# that the Function App is reachable only from inside. Every fifteen minutes over
# a handful of pending invitations costs almost nothing.
#
# This runs even in simulation mode. Simulation means "do not change the tenant
# and do not send mail"; noticing that somebody accepted is an observation, and a
# list that says "waiting for them to accept" three weeks after they did would
# make the tool look broken during exactly the period an admin is evaluating it.
# Mail is still suppressed by Send-CBMail while simulation is on.

param($Timer)

$MAX_PER_RUN = 250

Invoke-CBFunctionRun -Name 'RedemptionPoller' -Script {
    Initialize-CBTables
    $settings = Get-CBSettings
    if (-not $settings.setupComplete) {
        Write-Host 'Setup is not complete; nothing to poll yet.'
        return
    }

    $pending = @(Get-CBPendingGuestRow)
    if ($pending.Count -eq 0) {
        Write-Host 'No invitations are waiting to be accepted.'
        return
    }
    Write-Host "$($pending.Count) invitation(s) are waiting to be accepted."

    # Oldest first, so a backlog drains in the order people were invited rather
    # than in whatever order the table happened to return.
    $batch = @($pending | Sort-Object -Property { "$($_.InvitedAtUtc)" } | Select-Object -First $MAX_PER_RUN)
    $accepted = 0
    $gone = 0
    $unknown = 0
    $failed = 0

    foreach ($row in $batch) {
        try {
            $result = Complete-CBGuestRedemption -Row $row -Settings $settings
            if ($result.Changed) {
                switch ("$($result.Reason)") {
                    'accepted' { $accepted++ }
                    'unknown' { $unknown++ }
                    default { $gone++ }
                }
            }
        }
        catch {
            # One unreadable guest must not stop the rest of the batch: the next
            # run picks them up again, and the error is visible in the log.
            $failed++
            Write-Warning "Could not check $($row.Email): $($_.Exception.Message)"
        }
    }

    Write-Host "RedemptionPoller: $accepted accepted, $unknown with an invitation state Entra no longer records, $gone no longer exist, $failed could not be checked, $($pending.Count - $batch.Count) left for the next run."
    if ($failed -gt 0 -and $failed -eq $batch.Count) {
        # Every single check failing is not a guest problem, it is a Graph or
        # permission problem, and the heartbeat should say so.
        throw "None of the $failed pending invitation(s) could be checked. Directory read access may be missing."
    }
}
