# The activity log: what the tool did, to whom, on whose instruction.
#
# Rows live in the ActivityLog table with RowKey = (max ticks - now) so ascending
# RowKey order is newest-first, which is what the portal wants and what makes a
# "latest N" query a cheap $top with no sorting.
#
# Two audiences read this feed and they see different slices:
#   * an employee sees entries about the guests they own;
#   * an admin sees everything, including configuration changes.
# The slice is enforced by the API, not here (Actor/Subject are recorded on every
# row so either filter is a simple predicate).

function Write-CBActivity {
    <#
    .SYNOPSIS
        Appends an entry to the activity log. Never throws: failing to write an
        audit row must not fail the operation being audited (it is logged as a
        warning instead, and the Watchdog notices a silent log).
    .PARAMETER EventName
        Short human sentence, e.g. "Invited jane@partner.com". Named EventName
        rather than Event because $Event is a PowerShell automatic variable.
    .PARAMETER Actor
        Who caused it (a UPN), or empty for the tool itself.
    .PARAMETER OwnerId
        Object id of the internal owner this entry belongs to, so an employee can
        be shown their own history. Empty for system-wide events.
    .PARAMETER Detail
        Structured detail serialised into the expandable Details field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventName,
        [string]$Actor,
        [string]$OwnerId,
        [string]$GuestId,
        [string]$GuestUpn,
        [string]$GuestDisplayName,
        [string]$Category = 'guest',
        [switch]$Simulated,
        $Detail
    )
    $tables = Get-CBTableNames
    $rowKey = ('{0:D19}' -f ([DateTime]::MaxValue.Ticks - [DateTime]::UtcNow.Ticks))
    $summary = if ($null -ne $Detail) {
        if ($Detail -is [string]) { @{ detail = $Detail } | ConvertTo-Json -Compress }
        else { $Detail | ConvertTo-Json -Depth 10 -Compress }
    }
    else { '{}' }

    try {
        Set-CBTableEntity -Table $tables.Activity -PartitionKey 'log' -RowKey $rowKey -Properties @{
            TimestampUtc     = [DateTimeOffset]::UtcNow.ToString('o')
            Event            = $EventName
            Category         = $Category
            Actor            = if ($Actor) { $Actor } else { '(system)' }
            OwnerId          = $OwnerId
            GuestId          = $GuestId
            GuestUpn         = $GuestUpn
            GuestDisplayName = $GuestDisplayName
            Simulated        = [string]([bool]$Simulated)
            Summary          = $summary
        }
    }
    catch { Write-Warning "Failed to write activity log entry '$EventName': $($_.Exception.Message)" }
}

function Write-CBSystemActivity {
    <#
    .SYNOPSIS
        An activity entry for the tool's own housekeeping (config saves, publish,
        pause/resume, scans) rather than an action on a specific guest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventName,
        [string]$Actor,
        $Detail
    )
    Write-CBActivity -EventName $EventName -Actor $Actor -Category 'system' -Detail $Detail
}

function Remove-CBExpiredActivity {
    <#
    .SYNOPSIS
        Trims the activity log to the configured retention, and clears out guest
        records for accounts that were removed long enough ago.
    .DESCRIPTION
        The RowKey is (max ticks - timestamp), so entries older than a cut-off all
        sort AFTER the RowKey of that cut-off. That turns "delete everything older
        than N days" into one range query on the key rather than a full scan with
        a date comparison per row.

        Deleted guest rows are kept for the same period as the log, because they
        ARE the log as far as "who did we once work with" is concerned. Only once
        both have aged out does the record of a guest disappear entirely.
    .OUTPUTS
        @{ Entries; Guests }
    #>
    [CmdletBinding()] param($Settings, [int]$MaxDeletes = 5000)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $tables = Get-CBTableNames
    $days = ConvertTo-CBInt -Value $Settings.logRetentionDays -Default 365 -Min 7 -Max 3650
    $cutoff = [DateTime]::UtcNow.AddDays(-$days)
    $cutoffKey = ('{0:D19}' -f ([DateTime]::MaxValue.Ticks - $cutoff.Ticks))

    $entries = 0
    try {
        $filter = "PartitionKey eq 'log' and RowKey gt '$cutoffKey'"
        $old = @(Get-CBTableEntities -Table $tables.Activity -Filter $filter -Top $MaxDeletes)
        if ($old.Count -gt 0) {
            $entries = Invoke-CBTableBatchDelete -Table $tables.Activity -PartitionKey 'log' -RowKeys @($old | ForEach-Object { "$($_.RowKey)" })
        }
    }
    catch { Write-Warning "Could not trim the activity log: $($_.Exception.Message)" }

    $guests = 0
    try {
        foreach ($row in @(Get-CBAllGuestRow -Filter "State eq 'deleted'")) {
            $when = ConvertTo-CBDateOnly -Value "$($row.DeletedAtUtc)"
            if (-not $when -or $when -gt $cutoff.Date) { continue }
            try { Remove-CBTableEntity -Table $tables.Guests -PartitionKey "$($row.PartitionKey)" -RowKey "$($row.RowKey)"; $guests++ }
            catch { Write-Warning "Could not remove the aged record for $($row.Email): $($_.Exception.Message)" }
        }
    }
    catch { Write-Warning "Could not trim removed guest records: $($_.Exception.Message)" }

    if ($entries -gt 0 -or $guests -gt 0) {
        Write-CBSystemActivity -EventName 'Trimmed old records' -Detail @{
            retentionDays = $days; logEntries = $entries; removedGuestRecords = $guests
        }
    }
    return @{ Entries = $entries; Guests = $guests }
}

function Get-CBActivityPage {
    <#
    .SYNOPSIS
        One page of the activity feed, newest first.
    .PARAMETER OwnerId
        When set, restricts the feed to one person. Admins call without it to see
        everything.
    .PARAMETER Actor
        The same person's address. "My activity" means entries about guests I own
        OR things I did, and those are not the same set: a configuration change,
        a resumed queue or an adoption run is recorded against the ACTOR with no
        owner at all. Filtering on the owner alone hid an administrator's own
        actions from them until they ticked "show everything", which made the
        feed look broken.
    #>
    [CmdletBinding()]
    param(
        [string]$OwnerId,
        [string]$Actor,
        [int]$Top = 50,
        [string]$NextPartitionKey,
        [string]$NextRowKey
    )
    $tables = Get-CBTableNames
    $filter = "PartitionKey eq 'log'"
    if ($OwnerId) {
        $clauses = @("OwnerId eq '{0}'" -f (ConvertTo-CBODataKey $OwnerId))
        if ($Actor) { $clauses += "Actor eq '{0}'" -f (ConvertTo-CBODataKey $Actor) }
        $filter += ' and (' + ($clauses -join ' or ') + ')'
    }
    return Get-CBTablePage -Table $tables.Activity -Filter $filter -Top $Top `
        -NextPartitionKey $NextPartitionKey -NextRowKey $NextRowKey
}
