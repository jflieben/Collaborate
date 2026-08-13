using namespace System.Net

# Actions on one external collaborator.
#
# POST /api/guests/{id}/action  { "action": "...", ... }
#
#   claim     take on a guest nobody is accountable for, giving them an end date
#   ask       tell the current owner you would like to work with their guest
#   renew     extend access, bringing back a blocked or recently deleted account
#   cancel    end access now, with the same grace period as a normal expiry
#   transfer  hand the guest to a colleague, who takes over the reminders
#   resend    issue a fresh invitation to somebody who has not accepted
#
# Every action except claim and ask goes through Test-CBGuestAccess first: the
# owner may act, an administrator may act, and anybody else is told the guest
# does not exist. Whether a colleague works with a particular external company is
# not everybody's business, so "not yours" and "not there" give the same answer.

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
    $settings = Get-CBSettings
    if (-not $settings.setupComplete) {
        Send-Json -Status 409 -Object @{ error = 'Collaborate has not been set up yet.' }
        return
    }

    $guestId = "$($Request.Params.id)".Trim()
    if ($guestId -notmatch '^[0-9a-fA-F-]{36}$') {
        Send-Json -Status 400 -Object @{ error = 'That is not a valid account id.' }
        return
    }

    $body = ConvertFrom-CBRequestBody -Body $Request.Body
    $action = "$($body.action)".Trim().ToLowerInvariant()

    switch ($action) {
        'claim' {
            $result = Register-CBExistingGuest -Caller $caller -GuestId $guestId -Settings $settings `
                -Reason "$($body.reason)" -Days $body.days
            if (-not $result.Ok) { Send-Json -Status $result.Status -Object @{ error = $result.Error }; return }
            Send-Json -Status 200 -Object @{
                guest     = $result.Guest
                simulated = [bool]$result.Simulated
                warnings  = @($result.Warnings)
            }
        }
        'ask' {
            $result = Send-CBOwnerEnquiry -Caller $caller -GuestId $guestId -Settings $settings -Message "$($body.message)"
            if (-not $result.Ok) { Send-Json -Status $result.Status -Object @{ error = $result.Error }; return }
            Send-Json -Status 200 -Object @{ message = $result.Message; simulated = [bool]$result.Simulated; outbox = @($result.Outbox | Where-Object { $_ }) }
        }
        'renew' {
            $result = Update-CBGuestExpiry -Caller $caller -GuestId $guestId -Settings $settings `
                -Days $body.days -Reason "$($body.reason)"
            if (-not $result.Ok) { Send-Json -Status $result.Status -Object @{ error = $result.Error }; return }
            Send-Json -Status 200 -Object @{
                guest     = $result.Guest
                simulated = [bool]$result.Simulated
                warnings  = @($result.Warnings)
            }
        }
        'cancel' {
            $result = Stop-CBGuestAccess -Caller $caller -GuestId $guestId -Settings $settings -Reason "$($body.reason)"
            if (-not $result.Ok) { Send-Json -Status $result.Status -Object @{ error = $result.Error }; return }
            Send-Json -Status 200 -Object @{
                guest     = $result.Guest
                message   = "$($result.Message)"
                simulated = [bool]$result.Simulated
            }
        }
        'transfer' {
            $newOwner = "$($body.ownerId)".Trim()
            if ($newOwner -notmatch '^[0-9a-fA-F-]{36}$') {
                Send-Json -Status 400 -Object @{ error = 'Choose the colleague who should take this on.' }
                return
            }
            $result = Move-CBGuestOwner -Caller $caller -GuestId $guestId -NewOwnerId $newOwner -Settings $settings -Reason "$($body.reason)"
            if (-not $result.Ok) { Send-Json -Status $result.Status -Object @{ error = $result.Error }; return }
            Send-Json -Status 200 -Object @{
                guest     = $result.Guest
                message   = "$($result.Message)"
                simulated = [bool]$result.Simulated
            }
        }
        'resend' {
            $result = Update-CBGuestInvitation -Caller $caller -GuestId $guestId -Settings $settings
            if (-not $result.Ok) { Send-Json -Status $result.Status -Object @{ error = $result.Error }; return }
            Send-Json -Status 200 -Object @{ message = "$($result.Message)"; simulated = [bool]$result.Simulated }
        }
        default {
            Send-Json -Status 400 -Object @{ error = "Unknown action '$action'." }
        }
    }
}
catch {
    Write-Error "GuestActionApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
