using namespace System.Net

# The activity feed.
#
# An employee sees what happened to the guests they own. An administrator sees
# everything, including configuration changes. The slice is decided here from the
# validated token, never from a query parameter, so asking for somebody else's
# history simply returns your own.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 12)
        })
}

try {
    $caller = Resolve-CBCaller -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    Initialize-CBTables

    $top = 50
    if ($Request.Query -and $Request.Query['top']) { $top = ConvertTo-CBInt -Value $Request.Query['top'] -Default 50 -Min 1 -Max 200 }
    $nextPk = if ($Request.Query) { "$($Request.Query['npk'])" } else { '' }
    $nextRk = if ($Request.Query) { "$($Request.Query['nrk'])" } else { '' }

    # Admins may ask for the whole feed; everybody else gets their own slice
    # whether they asked for it or not. "Their own" means guests they own AND
    # things they did themselves, which are different sets: a configuration
    # change has an actor but no owner.
    $wantsAll = $caller.IsAdmin -and $Request.Query -and "$($Request.Query['scope'])" -eq 'all'
    $ownerFilter = if ($wantsAll) { '' } else { $caller.Oid }
    $actorFilter = if ($wantsAll) { '' } else { $caller.Upn }

    $page = Get-CBActivityPage -OwnerId $ownerFilter -Actor $actorFilter -Top $top -NextPartitionKey $nextPk -NextRowKey $nextRk

    $items = @($page.Items | ForEach-Object {
            $summary = $null
            if ($_.Summary) { try { $summary = $_.Summary | ConvertFrom-Json } catch { $summary = @{ detail = "$($_.Summary)" } } }
            [ordered]@{
                timestampUtc = "$($_.TimestampUtc)"
                event        = "$($_.Event)"
                category     = "$($_.Category)"
                actor        = "$($_.Actor)"
                guest        = "$($_.GuestDisplayName)"
                guestEmail   = "$($_.GuestUpn)"
                simulated    = ("$($_.Simulated)" -eq 'True')
                detail       = $summary
            }
        })

    Send-Json -Status 200 -Object @{
        items = $items
        scope = $(if ($wantsAll) { 'all' } else { 'mine' })
        next  = $(if ($page.NextPartitionKey) { @{ npk = $page.NextPartitionKey; nrk = $page.NextRowKey } } else { $null })
    }
}
catch {
    Write-Error "LogsApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
