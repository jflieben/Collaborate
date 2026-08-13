# Function heartbeats.
#
# Every worker function records its last run, status, duration and (on failure)
# the error into the FunctionHeartbeats table. The Diagnostics tab reads this, so
# an operator can see at a glance whether the timers and processors are healthy
# without opening Application Insights.

function Write-CBHeartbeat {
    <#
    .SYNOPSIS
        Records a run result for a function. Never throws: diagnostics must not
        break the function being diagnosed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('ok', 'error')][string]$Status,
        [long]$DurationMs = 0,
        [string]$ErrorMessage
    )
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $props = @{
        LastRunUtc     = $now
        LastStatus     = $Status
        LastDurationMs = [string]$DurationMs
    }
    if ($Status -eq 'ok') { $props.LastSuccessUtc = $now }
    else { $props.LastError = "$ErrorMessage"; $props.LastErrorUtc = $now }

    try {
        $tables = Get-CBTableNames
        # MERGE preserves LastSuccessUtc when writing an error and vice versa.
        Merge-CBTableEntity -Table $tables.Heartbeats -PartitionKey 'fn' -RowKey $Name -Properties $props
    }
    catch { Write-Warning "Could not write heartbeat for ${Name}: $($_.Exception.Message)" }
}

$script:CBHeartbeatLast = @{}

function Write-CBHeartbeatSampled {
    <#
    .SYNOPSIS
        Like Write-CBHeartbeat but rate-limited per worker: a healthy heartbeat
        writes at most once per interval. For chatty HTTP endpoints (the browse
        picker fires on every keystroke) this avoids a table write per request.
        Errors are never sampled: they always write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('ok', 'error')][string]$Status = 'ok',
        [int]$MinIntervalSeconds = 30,
        [string]$ErrorMessage
    )
    if ($Status -eq 'ok') {
        $last = $script:CBHeartbeatLast[$Name]
        if ($last -and ([DateTimeOffset]::UtcNow - $last).TotalSeconds -lt $MinIntervalSeconds) { return }
        $script:CBHeartbeatLast[$Name] = [DateTimeOffset]::UtcNow
    }
    Write-CBHeartbeat -Name $Name -Status $Status -ErrorMessage $ErrorMessage
}

function Invoke-CBFunctionRun {
    <#
    .SYNOPSIS
        Runs a function body and records a heartbeat with the outcome. Failures
        are rethrown so the Functions runtime still registers them (retries,
        poison queue, App Insights).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Script
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "${Name}: run starting."
    try {
        & $Script
        Write-CBHeartbeat -Name $Name -Status ok -DurationMs $sw.ElapsedMilliseconds
        Write-Host "${Name}: run finished ok in $($sw.ElapsedMilliseconds)ms."
    }
    catch {
        Write-CBHeartbeat -Name $Name -Status error -DurationMs $sw.ElapsedMilliseconds -ErrorMessage $_.Exception.Message
        Write-Host "${Name}: run FAILED after $($sw.ElapsedMilliseconds)ms: $($_.Exception.Message)"
        throw
    }
}

function Get-CBHeartbeats {
    [CmdletBinding()] param()
    $tables = Get-CBTableNames
    return @(Get-CBTableEntities -Table $tables.Heartbeats -Filter "PartitionKey eq 'fn'")
}
