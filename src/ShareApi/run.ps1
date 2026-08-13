using namespace System.Net

# Share a file, folder or Team with an external person, inviting them if needed.
#
# POST /api/share
# {
#   "target":   { "kind": "file"|"folder"|"team", "driveId": "", "itemId": "", "teamId": "" },
#   "guestId":  "<an existing guest>",              // one of these two
#   "newGuest": { "email", "displayName", "reason", "days" },
#   "role":     "read"|"write",
#   "message":  "optional note that goes in the email"
# }
#
# The grant runs as the signed-in user, so nobody can share something they cannot
# already reach. The invitation, if one is needed, runs as the managed identity,
# because employees cannot invite in a locked-down tenant. That split is the
# whole design, and Invoke-CBShareRequest is where the two meet in the right
# order: create the account, grant the access, and only then send the mail.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 10)
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

    $body = ConvertFrom-CBRequestBody -Body $Request.Body
    if (-not $body -or -not $body.target) {
        Send-Json -Status 400 -Object @{ error = 'Nothing to share was chosen.' }
        return
    }

    # Inviting somebody new through this flow needs the same permission as
    # inviting them through the invite screen; sharing is not a side door.
    if (-not "$($body.guestId)".Trim()) {
        $canInvite = Test-CBCanInvite -Caller $caller -Settings $settings
        if (-not $canInvite.Allowed) {
            Send-Json -Status 403 -Object @{ error = $canInvite.Reason }
            return
        }
    }

    $result = Invoke-CBShareRequest -Caller $caller -Settings $settings -Target $body.target `
        -GuestId "$($body.guestId)" -NewGuest $body.newGuest -Role "$($body.role)" -Message "$($body.message)"

    if (-not $result.Ok) {
        Send-Json -Status $result.Status -Object @{
            error        = $result.Error
            # When the guest was created but the share failed, the portal needs
            # to know so it can retry the share alone instead of inviting the
            # same person twice.
            guestCreated = [bool]$result.GuestCreated
            guest        = $result.Guest
            retryable    = [bool]$result.Retryable
            verdict      = $(if ($result.Verdict) { $result.Verdict.Verdict } else { '' })
            owner        = $(if ($result.Verdict) { $result.Verdict.Owner } else { $null })
        }
        return
    }

    Write-CBHeartbeatSampled -Name 'ShareApi'
    Send-Json -Status 200 -Object @{
        guest        = $result.Guest
        shared       = $result.Shared
        guestCreated = [bool]$result.GuestCreated
        simulated    = [bool]$result.Simulated
        message      = "$($result.Message)"
        warnings     = @($result.Warnings)
        outbox       = @($result.Outbox | Where-Object { $_ })
    }
}
catch {
    Write-CBHeartbeatSampled -Name 'ShareApi' -Status error -ErrorMessage $_.Exception.Message
    Write-Error "ShareApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
