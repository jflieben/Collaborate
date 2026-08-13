using namespace System.Net

# The internal people picker, used when handing a guest to a colleague.
#
# GET /api/users?search=term[&includeSelf=1]
#
# Guests are excluded by the query itself: a guest can never look after another
# guest, so offering one would only produce an error later. This exposes no more
# than the address book any signed-in employee can already read.
#
# The caller themselves is left out by default, because handing a collaborator
# to yourself is a no-op the transfer would refuse. It is NOT always a no-op:
# when nobody is accountable for a collaborator, taking them on yourself is the
# whole point, and an administrator sorting out unowned accounts will want some
# of them. The caller of this API says which situation it is in; the default is
# the safe one.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 8)
        })
}

try {
    $caller = Resolve-CBCaller -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    $search = if ($Request.Query) { "$($Request.Query['search'])".Trim() } else { '' }
    $includeSelf = $false
    if ($Request.Query) { $includeSelf = ("$($Request.Query['includeSelf'])".Trim().ToLowerInvariant() -in @('1', 'true', 'yes')) }
    if ($search.Length -lt 2) {
        Send-Json -Status 200 -Object @{ items = @(); note = '' }
        return
    }

    $result = Search-CBInternalUser -Search $search -Top 10

    $all = @($result.Items | ForEach-Object {
            $_.isSelf = ("$($_.id)" -eq $caller.Oid)
            $_
        })
    $items = @(if ($includeSelf) { $all } else { $all | Where-Object { -not $_.isSelf } })

    # Somebody searching for their own name is told why they are the one person
    # missing, rather than being left with an empty box.
    $note = ''
    if ($items.Count -eq 0 -and $all.Count -gt 0) { $note = 'That is you. Hand the collaborator to somebody else.' }
    elseif ($items.Count -eq 0 -and $result.Error) { $note = $result.Error }

    Write-CBHeartbeatSampled -Name 'UsersApi'
    Send-Json -Status 200 -Object @{ items = $items; note = $note }
}
catch {
    Write-Error "UsersApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
