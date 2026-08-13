using namespace System.Net

# The browser reporting what happened to a message it was asked to send.
#
# POST /api/outbox  { "guestId": "...", "ok": true|false, "error": "..." }
#
# When the tenant has chosen for invitations to come from the person rather than
# from the service desk, the message is rendered by the API and sent by the SPA
# with the user's own delegated token, from their own device. See Outbox.ps1 for
# why it is not sent from this side.
#
# This endpoint exists so a failure is never silent. A report of failure sends
# the message from the shared mailbox immediately; anything never reported at all
# is swept up by the daily scan. Both are recorded in the activity log, so
# "invitations are arriving from the wrong address" is a question with an answer.

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

    Initialize-CBTables
    $settings = Get-CBSettings

    $body = ConvertFrom-CBRequestBody -Body $Request.Body
    $guestId = "$($body.guestId)".Trim()
    if ($guestId -notmatch '^[0-9a-fA-F-]{36}$') {
        Send-Json -Status 400 -Object @{ error = 'That is not a valid account id.' }
        return
    }

    $result = Complete-CBOutboxMessage -Caller $caller -GuestId $guestId -Settings $settings `
        -Ok ([bool](ConvertTo-CBBool -Value $body.ok -Default $false)) -ErrorText "$($body.error)"
    if (-not $result.Ok) { Send-Json -Status $result.Status -Object @{ error = $result.Error }; return }

    Write-CBHeartbeatSampled -Name 'OutboxApi'
    Send-Json -Status 200 -Object @{ message = "$($result.Message)"; fellBack = [bool]$result.FellBack }
}
catch {
    Write-Error "OutboxApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
