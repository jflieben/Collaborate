# Weekly, on Monday morning: is a newer Collaborate available?
#
# The result is stored so the portal can show a banner without calling out to
# GitHub on every page load. Nothing updates itself: running new code in
# somebody's tenant without them asking is not a feature.
#
# A Function App locked down to an IP allowlist may have no outbound internet
# access at all, which is a legitimate configuration. That is why a failed check
# is recorded and shrugged off rather than thrown.

param($Timer)

Invoke-CBFunctionRun -Name 'VersionChecker' -Script {
    Initialize-CBTables
    $settings = Get-CBSettings

    $result = Invoke-CBVersionCheck -Settings $settings
    if ($result.UpdateAvailable) {
        Write-Host "Collaborate $($result.Latest) is available (this install runs $($result.Current)). Service desk notified: $($result.Notified)."
    }
    elseif ($result.Latest) {
        Write-Host "Collaborate $($result.Current) is up to date."
    }
    else {
        Write-Host 'The published version could not be read; nothing to report.'
    }
}
