# Storm guard / circuit breaker.
#
# A tool that blocks and deletes accounts on a schedule must not turn one
# mistake (a mis-set expiry attribute, a first inactivity sweep in an old tenant,
# a clock or timezone slip) into thousands of irreversible deletions. This module
# caps how many guests the tool will act on per action per day and, on breach,
# PAUSES all processing until an admin reviews and explicitly resumes.
#
# Invitations are capped too, for a different reason: they are the one action
# ordinary employees can trigger, so the cap is also the anti-abuse limit.
#
# State lives in the SafetyState table:
#   flag  / paused           -> the circuit-breaker latch (Paused/Reason/Utc)
#   count / <action>|<date>  -> actions taken today, per action
#   count / user|<oid>|<date> -> invitations sent today, per employee
#   meta  / guestCount       -> last known guest population (percent ceiling)
#
# The counter increment is read-modify-write, so under heavy queue concurrency it
# can undercount by a few; the numeric cap has headroom and the percent ceiling is
# a second backstop, so a small race never defeats the guard.

$script:CBSafetyActions = @('invite', 'block', 'delete')

function Get-CBSafetyActions { return $script:CBSafetyActions }

function Get-CBPausedEntity {
    [CmdletBinding()] param()
    $tables = Get-CBTableNames
    return Get-CBTableEntity -Table $tables.Safety -PartitionKey 'flag' -RowKey 'paused'
}

function Test-CBPaused {
    [CmdletBinding()] param()
    $e = Get-CBPausedEntity
    return [bool]($e -and "$($e.Paused)".ToLowerInvariant() -eq 'true')
}

function Set-CBPaused {
    <#
    .SYNOPSIS
        Latches the circuit breaker. Idempotent: does not overwrite an existing
        pause reason (the first trip is the interesting one).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Reason, [string]$Action)
    $tables = Get-CBTableNames
    if (Test-CBPaused) { return }
    Set-CBTableEntity -Table $tables.Safety -PartitionKey 'flag' -RowKey 'paused' -Properties @{
        Paused = 'true'
        Reason = $Reason
        Action = $Action
        Utc    = [DateTimeOffset]::UtcNow.ToString('o')
    }
    Write-CBSystemActivity -EventName 'PAUSED by the storm guard' -Detail $Reason
    Write-Warning "STORM GUARD TRIPPED: $Reason. All processing is paused until an admin resumes from the portal."
}

function Clear-CBPaused {
    <#
    .SYNOPSIS
        Resumes processing: clears the latch AND resets today's counters so the
        run that tripped it can proceed. Records who resumed.
    #>
    [CmdletBinding()] param([string]$Actor)
    $tables = Get-CBTableNames
    try { Remove-CBTableEntity -Table $tables.Safety -PartitionKey 'flag' -RowKey 'paused' } catch { }
    $today = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
    foreach ($a in $script:CBSafetyActions) {
        try { Remove-CBTableEntity -Table $tables.Safety -PartitionKey 'count' -RowKey ("$a|$today") } catch { }
    }
    Write-CBSystemActivity -EventName 'Resumed (storm guard cleared)' -Actor $Actor -Detail 'Daily action counters reset; processing resumes.'
}

function Get-CBSafetyCount {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Key, [string]$Date)
    if (-not $Date) { $Date = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd') }
    $tables = Get-CBTableNames
    $e = Get-CBTableEntity -Table $tables.Safety -PartitionKey 'count' -RowKey ("$Key|$Date")
    $n = 0
    if ($e -and $e.PSObject.Properties['Count']) { [void][int]::TryParse("$($e.Count)", [ref]$n) }
    return $n
}

function Add-CBSafetyCount {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Key)
    $tables = Get-CBTableNames
    $today = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
    $current = Get-CBSafetyCount -Key $Key -Date $today
    Merge-CBTableEntity -Table $tables.Safety -PartitionKey 'count' -RowKey ("$Key|$today") -Properties @{
        Count      = [string]($current + 1)
        Key        = $Key
        Date       = $today
        UpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    return ($current + 1)
}

function Set-CBGuestCount {
    [CmdletBinding()] param([Parameter(Mandatory)][int]$Count)
    $tables = Get-CBTableNames
    Set-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'guestCount' -Properties @{
        Count = [string]$Count
        Utc   = [DateTimeOffset]::UtcNow.ToString('o')
    }
}

function Get-CBGuestCount {
    [CmdletBinding()] param()
    $tables = Get-CBTableNames
    $e = Get-CBTableEntity -Table $tables.Safety -PartitionKey 'meta' -RowKey 'guestCount'
    $n = 0
    if ($e -and $e.PSObject.Properties['Count']) { [void][int]::TryParse("$($e.Count)", [ref]$n) }
    return $n
}

function Test-CBStormGuard {
    <#
    .SYNOPSIS
        The gate every destructive action passes through. Returns whether this
        action is allowed and, as a side effect, counts allowed actions and trips
        the breaker (pauses) when a cap or the percent ceiling is reached.
    .OUTPUTS
        [pscustomobject] @{ Allowed = [bool]; Reason = [string]; Paused = [bool] }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('invite', 'block', 'delete')][string]$Action,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $safety = $Settings.safety
    if (-not $safety -or -not $safety.enabled) {
        return [pscustomobject]@{ Allowed = $true; Reason = 'storm guard disabled'; Paused = $false }
    }

    if (Test-CBPaused) {
        return [pscustomobject]@{ Allowed = $false; Reason = 'processing is paused (storm guard); resume from the portal'; Paused = $true }
    }

    $cap = switch ($Action) {
        'invite' { [int]$safety.dailyCapInvite }
        'block'  { [int]$safety.dailyCapBlock }
        default  { [int]$safety.dailyCapDelete }
    }
    $ceiling = [int]$safety.percentCeiling
    $count   = Get-CBSafetyCount -Key $Action
    $wouldBe = $count + 1

    $trip = $null
    if ($cap -gt 0 -and $wouldBe -gt $cap) {
        $trip = "daily cap for '$Action' reached ($cap). $count action(s) already taken today; refusing further to avoid a mass action."
    }
    elseif ($Action -ne 'invite') {
        # Percent ceiling: a backstop against acting on a large slice of the guest
        # population in one day. Ignored for tiny counts so it never nuisance-trips
        # a small tenant, and not applied to invitations (creating guests is not
        # destructive, and its own cap already bounds it).
        $population = Get-CBGuestCount
        if ($ceiling -gt 0 -and $population -gt 0 -and $wouldBe -ge 10) {
            $pct = ($wouldBe / [double]$population) * 100.0
            if ($pct -gt $ceiling) {
                $trip = "percent ceiling for '$Action' reached (>$ceiling% of $population guests). $count action(s) today; refusing further to avoid a mass action."
            }
        }
    }

    if ($trip) {
        Set-CBPaused -Reason $trip -Action $Action
        return [pscustomobject]@{ Allowed = $false; Reason = $trip; Paused = $true }
    }

    [void](Add-CBSafetyCount -Key $Action)
    return [pscustomobject]@{ Allowed = $true; Reason = ''; Paused = $false }
}

function Test-CBUserInviteQuota {
    <#
    .SYNOPSIS
        Per-employee daily invitation limit. Separate from the tenant-wide storm
        guard: this one is about one account being used (or misused) to invite a
        crowd, and it must never pause the whole tool.
    .OUTPUTS
        [pscustomobject] @{ Allowed; Used; Limit; Reason }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Oid, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $limit = [int]$Settings.safety.perUserDailyInvites
    $used = Get-CBSafetyCount -Key ("user|$Oid")
    if ($limit -gt 0 -and $used -ge $limit) {
        return [pscustomobject]@{
            Allowed = $false; Used = $used; Limit = $limit
            Reason  = "You have invited $used guest(s) today, which is the daily limit ($limit). Try again tomorrow, or ask an administrator to raise the limit."
        }
    }
    return [pscustomobject]@{ Allowed = $true; Used = $used; Limit = $limit; Reason = '' }
}

function Add-CBUserInviteCount {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Oid)
    return (Add-CBSafetyCount -Key ("user|$Oid"))
}

function Get-CBSafetyStatus {
    <#
    .SYNOPSIS
        Snapshot for the Diagnostics tab: paused state plus today's counters.
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $paused = Get-CBPausedEntity
    $today = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')
    return [pscustomobject]@{
        paused       = [bool]($paused -and "$($paused.Paused)".ToLowerInvariant() -eq 'true')
        pausedReason = if ($paused) { $paused.Reason } else { $null }
        pausedSince  = if ($paused) { $paused.Utc } else { $null }
        counts       = [ordered]@{
            invite = Get-CBSafetyCount -Key 'invite' -Date $today
            block  = Get-CBSafetyCount -Key 'block'  -Date $today
            delete = Get-CBSafetyCount -Key 'delete' -Date $today
        }
        caps         = [ordered]@{
            invite = [int]$Settings.safety.dailyCapInvite
            block  = [int]$Settings.safety.dailyCapBlock
            delete = [int]$Settings.safety.dailyCapDelete
        }
        guestCount   = Get-CBGuestCount
    }
}
