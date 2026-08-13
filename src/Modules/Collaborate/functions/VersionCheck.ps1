# Is this install up to date?
#
# The tool is deployed into somebody else's tenant and then left alone, so it has
# to tell its operators when a newer version exists rather than waiting to be
# asked. It reads the published VERSION file, compares, and shows a banner in the
# portal; emailing is optional because not every operator wants that.
#
# It never updates itself. Running new code in somebody's tenant without them
# asking is not a feature, it is an incident waiting to happen.

function ConvertTo-CBComparableVersion {
    <#
    .SYNOPSIS
        Parses a version string into [version], or $null.
    .DESCRIPTION
        String comparison would call 0.10.0 older than 0.9.0, which is exactly
        the sort of quiet wrongness that leaves an install two years behind.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Value)
    $text = "$Value".Trim().TrimStart('v', 'V')
    if ($text -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    $parsed = $null
    if ([version]::TryParse($text, [ref]$parsed)) { return $parsed }
    return $null
}

function Test-CBNewerVersion {
    <#
    .SYNOPSIS
        Is Latest newer than Current? Unparseable input means "no", because a
        banner nobody can explain is worse than no banner.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Current, [AllowNull()][string]$Latest)
    $a = ConvertTo-CBComparableVersion -Value $Current
    $b = ConvertTo-CBComparableVersion -Value $Latest
    if (-not $a -or -not $b) { return $false }
    return ($b -gt $a)
}

function Get-CBLatestVersion {
    <#
    .SYNOPSIS
        The published version, from the repository's VERSION file.
    .OUTPUTS
        @{ Ok; Version; Error }
    #>
    [CmdletBinding()] param()
    $cfg = Get-CBConfig
    if (-not $cfg.VersionCheckUrl) { return @{ Ok = $false; Version = ''; Error = 'no version check URL is configured' } }
    try {
        $response = Invoke-RestMethod -Method Get -Uri $cfg.VersionCheckUrl -TimeoutSec 20 -ErrorAction Stop
        $text = "$response".Trim()
        if (-not (ConvertTo-CBComparableVersion -Value $text)) {
            return @{ Ok = $false; Version = ''; Error = "the published version file did not contain a version" }
        }
        return @{ Ok = $true; Version = $text; Error = '' }
    }
    catch {
        # An internal-only Function App may simply not be allowed out to the
        # internet, which is a legitimate configuration and not a fault.
        return @{ Ok = $false; Version = ''; Error = $_.Exception.Message }
    }
}

function Get-CBVersionState {
    <#
    .SYNOPSIS
        The result of the last version check, as stored for the portal banner.
    #>
    [CmdletBinding()] param()
    $tables = Get-CBTableNames
    try { return Get-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'version' }
    catch { return $null }
}

function Invoke-CBVersionCheck {
    <#
    .SYNOPSIS
        Checks for a newer version, records the answer, and optionally emails.
    .DESCRIPTION
        The result is stored so the portal can show a banner without making a
        request to GitHub on every page load, and so an operator who never reads
        the email still sees it.
    .OUTPUTS
        @{ Current; Latest; UpdateAvailable; Notified }
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $cfg = Get-CBConfig
    $tables = Get-CBTableNames
    $current = "$($cfg.Version)"

    $latest = Get-CBLatestVersion
    if (-not $latest.Ok) {
        Write-Warning "Version check could not run: $($latest.Error)"
        Set-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'version' -Properties @{
            Current = $current; Latest = ''; UpdateAvailable = 'false'
            CheckedUtc = [DateTimeOffset]::UtcNow.ToString('o'); Error = "$($latest.Error)"
        }
        return @{ Current = $current; Latest = ''; UpdateAvailable = $false; Notified = $false }
    }

    $newer = Test-CBNewerVersion -Current $current -Latest $latest.Version
    $previous = Get-CBVersionState
    Set-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'version' -Properties @{
        Current = $current
        Latest = $latest.Version
        UpdateAvailable = [string]$newer
        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        Error = ''
    }
    if (-not $newer) {
        Write-Host "Collaborate $current is up to date."
        return @{ Current = $current; Latest = $latest.Version; UpdateAvailable = $false; Notified = $false }
    }

    # Only mail on a version we have not already mailed about. Weekly nagging
    # about the same release trains people to ignore it.
    $alreadyToldAbout = if ($previous) { "$($previous.NotifiedVersion)" } else { '' }
    $notified = $false
    $to = "$($Settings.notifications.servicedeskEmail)"
    if ($Settings.notifications.versionCheckNotify -and $to -and $alreadyToldAbout -ne $latest.Version) {
        $values = Get-CBMailTokenValue -Settings $Settings
        $values.currentVersion = $current
        $values.latestVersion = $latest.Version
        $values.releasesUrl = "$($cfg.ReleasesUrl)"
        try { $notified = Send-CBTemplateMail -Key 'versionAvailable' -To $to -Values $values -Settings $Settings -Force }
        catch { Write-Warning "Could not send the update notice: $($_.Exception.Message)" }
        if ($notified) {
            Merge-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'version' -Properties @{ NotifiedVersion = $latest.Version }
        }
    }

    Write-CBSystemActivity -EventName "Collaborate $($latest.Version) is available" -Detail @{
        current = $current; latest = $latest.Version; notified = $notified
    }
    return @{ Current = $current; Latest = $latest.Version; UpdateAvailable = $true; Notified = $notified }
}

function Get-CBVersionBanner {
    <#
    .SYNOPSIS
        The portal banner for an available update, or $null. Admins only: an
        ordinary employee can do nothing about it and does not need telling.
    #>
    [CmdletBinding()] param($Caller)
    if (-not $Caller -or -not $Caller.IsAdmin) { return $null }
    $state = Get-CBVersionState
    if (-not $state -or "$($state.UpdateAvailable)".ToLowerInvariant() -ne 'true') { return $null }
    return [ordered]@{
        id      = 'update'
        level   = 'info'
        title   = "Collaborate $($state.Latest) is available"
        message = "This install is running $($state.Current). Re-run the deployment or Update-Collaborate.ps1 to move to $($state.Latest)."
    }
}
