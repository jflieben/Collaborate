# Carries out one piece of lifecycle work.
#
# The scanner queues a suggestion; this decides whether it is still the right
# thing to do and, if so, does it. One guest per message, so a failure retries
# that guest alone and eventually lands in the poison queue where the Diagnostics
# tab shows it, instead of taking a whole run down.
#
# The queue uses the same storage account as the rest of the tool's state and is
# triggered with the managed identity (AzureWebJobsStorage__accountName), so
# there is no connection string here either.

param($QueueItem, $TriggerMetadata)

# How long held work waits when the storm guard has paused everything. Long
# enough that a paused tool is not re-reading the same messages every minute,
# short enough that resuming does not feel broken.
$PAUSE_HOLD_SECONDS = 900

Invoke-CBFunctionRun -Name 'GuestActionProcessor' -Script {
    Initialize-CBTables

    $message = $QueueItem
    if ($message -is [string]) {
        try { $message = $message | ConvertFrom-Json }
        catch { throw "The queue message is not valid JSON, so it can never be processed: $($_.Exception.Message)" }
    }
    if (-not $message -or -not $message.action) { throw 'The queue message names no action.' }
    Write-Host "Handling '$($message.action)' for guest $($message.guestId) (queued $($message.enqueuedUtc))."

    $settings = Get-CBSettings

    # Paused: hold the work rather than dropping or performing it. Re-queueing
    # with a visibility delay keeps the message out of the poison queue, which is
    # what would otherwise happen after five failed dequeues during a long pause.
    if (Test-CBPaused) {
        Write-Host "Processing is paused; holding this action for $PAUSE_HOLD_SECONDS seconds."
        Send-CBQueueMessage -Content ($message | ConvertTo-Json -Compress) -VisibilityTimeoutSeconds $PAUSE_HOLD_SECONDS
        return
    }

    $result = Invoke-CBQueuedGuestAction -Message $message -Settings $settings
    if ($result.Handled) {
        Write-Host "Done: $($result.Outcome)."
        return
    }
    if ($result.Retry) {
        # The storm guard refused mid-run and tripped the pause. The work is
        # still owed, so it is held rather than lost: an admin who reviews and
        # resumes gets the same guest acted on, not a gap.
        Write-Host "Held: $($result.Outcome)"
        Send-CBQueueMessage -Content ($message | ConvertTo-Json -Compress) -VisibilityTimeoutSeconds $PAUSE_HOLD_SECONDS
        return
    }
    Write-Host "Nothing done: $($result.Outcome)."
}
