# Weekly retention, early on Sunday morning.
#
# The activity log is an audit trail, so it is trimmed on a schedule the admin
# sets rather than never (an unbounded table is a cost and a privacy problem) and
# rather than aggressively (an audit trail that has forgotten the thing you are
# investigating is not one).
#
# Records for guests that were removed age out on the same schedule, because
# they ARE the audit trail as far as "who did we once work with" is concerned.

param($Timer)

Invoke-CBFunctionRun -Name 'ActivityLogCleanup' -Script {
    Initialize-CBTables
    $settings = Get-CBSettings

    $result = Remove-CBExpiredActivity -Settings $settings
    Write-Host "Retention ($($settings.logRetentionDays) days): removed $($result.Entries) log entr(ies) and $($result.Guests) aged guest record(s)."
}
