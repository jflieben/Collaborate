# The daily health check.
#
# Runs an hour and a half after the scanner, so that a scanner that failed this
# morning is reported this morning rather than tomorrow.
#
# It only emails when something is actually wrong. A daily "all is well" message
# gets filtered within a week, and then the real one is filtered too.

param($Timer)

Invoke-CBFunctionRun -Name 'Watchdog' -Script {
    Initialize-CBTables
    $settings = Get-CBSettings

    $findings = @(Test-CBHealth -Settings $settings)
    if ($findings.Count -eq 0) {
        Write-Host 'Health check: everything looks normal.'
        return
    }

    foreach ($f in $findings) { Write-Host "[$($f.severity)] $($f.title): $($f.detail)" }

    $result = Send-CBHealthAlert -Findings $findings -Settings $settings
    Write-Host "Health check: $($result.Errors) problem(s), $($result.Warnings) note(s), alert sent: $($result.Sent)."

    # Deliberately not rethrown. The watchdog reporting a problem is the watchdog
    # working; marking its own run as failed would then make it report itself
    # every day forever.
}
