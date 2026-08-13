using namespace System.Net

# External collaborators: list them, look one up, and create an invitation.
#
# GET  /api/guests                 the guests you own (admins may ask for all)
# GET  /api/guests?email=someone   the verdict for one exact address
# GET  /api/guests?search=term     fuzzy search over the tenant's guests
# POST /api/guests                 invite somebody new
#
# The verdict endpoint is what the portal calls before it will show an invitation
# form, but POST re-runs exactly the same check. That is the point: the browser's
# copy of the rule is a courtesy, and the API's copy is the control. A request
# crafted by hand gets the same 409 with the owner's name.

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
        Send-Json -Status 409 -Object @{ error = 'Collaborate has not been set up yet. An administrator needs to finish the setup wizard first.' }
        return
    }

    $query = $Request.Query
    $method = "$($Request.Method)".ToUpperInvariant()

    # ---------- POST: invite somebody new ----------
    if ($method -eq 'POST') {
        $body = ConvertFrom-CBRequestBody -Body $Request.Body
        if (-not $body) { Send-Json -Status 400 -Object @{ error = 'Nothing was sent.' }; return }

        $result = New-CBGuestInvitation -Caller $caller -Settings $settings `
            -Email "$($body.email)" -DisplayName "$($body.displayName)" -Reason "$($body.reason)" -Days $body.days

        if (-not $result.Ok) {
            Send-Json -Status $result.Status -Object @{
                error   = $result.Error
                verdict = $(if ($result.Verdict) { $result.Verdict.Verdict } else { '' })
                guest   = $(if ($result.Verdict) { $result.Verdict.Guest } else { $null })
                owner   = $(if ($result.Verdict) { $result.Verdict.Owner } else { $null })
            }
            return
        }
        Write-CBHeartbeatSampled -Name 'GuestsApi'
        Send-Json -Status $result.Status -Object @{
            guest     = $result.Guest
            simulated = [bool]$result.Simulated
            warnings  = @($result.Warnings)
            # Messages the caller's own browser is asked to send as itself, when
            # the tenant has chosen that. Empty by default.
            outbox    = @($result.Outbox | Where-Object { $_ })
        }
        return
    }

    # ---------- GET ?email= : the verdict for one address ----------
    $email = if ($query) { "$($query['email'])".Trim() } else { '' }
    if ($email) {
        $verdict = Resolve-CBGuestVerdict -Caller $caller -Email $email -Settings $settings
        $canInvite = Test-CBCanInvite -Caller $caller -Settings $settings
        Send-Json -Status 200 -Object @{
            email    = $email
            verdict  = $verdict.Verdict
            message  = $verdict.Message
            guest    = $verdict.Guest
            owner    = $verdict.Owner
            # A user who may not invite at all is told here rather than after
            # they have filled in the form.
            canInvite = ([bool]$verdict.CanInvite -and [bool]$canInvite.Allowed)
            canClaim  = [bool]$verdict.CanClaim
            canAsk    = [bool]$verdict.CanAsk
            inviteBlockedReason = $(if ($verdict.CanInvite -and -not $canInvite.Allowed) { $canInvite.Reason } else { '' })
        }
        return
    }

    # ---------- GET ?id= : one collaborator, in full ----------
    # Fetched on demand rather than folded into the list, because this is the
    # only place the shared-item list is shown and a thousand guests carrying
    # fifty items each would be megabytes nobody reads.
    $wantedId = if ($query) { "$($query['id'])".Trim() } else { '' }
    if ($wantedId) {
        if ($wantedId -notmatch '^[0-9a-fA-F-]{36}$') {
            Send-Json -Status 400 -Object @{ error = 'That is not a valid account id.' }
            return
        }
        $access = Test-CBGuestAccess -Caller $caller -GuestId $wantedId
        if (-not $access.Ok) { Send-Json -Status $access.Status -Object @{ error = $access.Error }; return }
        $view = Get-CBGuestView -Row $access.Row -Settings $settings -IncludeOwner -IncludeShared -Viewer $caller
        $view.actions = @(Get-CBGuestActionOption -Row $access.Row -Caller $caller -Settings $settings -State $view.state)
        Write-CBHeartbeatSampled -Name 'GuestsApi'
        Send-Json -Status 200 -Object @{ guest = $view }
        return
    }

    # ---------- GET ?search= : fuzzy directory search ----------
    $search = if ($query) { "$($query['search'])".Trim() } else { '' }
    if ($search) {
        $hits = @(Search-CBGuestDirectory -Search $search -Caller $caller -Settings $settings)
        Write-CBHeartbeatSampled -Name 'GuestsApi'
        Send-Json -Status 200 -Object @{ items = @($hits); scope = "$($settings.invite.guestDirectoryVisibility)" }
        return
    }

    # ---------- GET : the list ----------
    # Admins may ask for every guest; anybody else gets their own partition
    # whether they asked for it or not.
    $wantsAll = $caller.IsAdmin -and $query -and "$($query['scope'])" -eq 'all'
    $rows = if ($wantsAll) { Get-CBAllGuestRow } else { Get-CBOwnerGuestRow -OwnerId $caller.Oid }

    $now = [DateTime]::UtcNow
    $items = @($rows | ForEach-Object {
            $view = Get-CBGuestView -Row $_ -Settings $settings -Now $now -IncludeOwner:$wantsAll
            $view.sortKey = Get-CBGuestSortKey -State $view.state -DaysLeft $view.daysLeft
            # What this caller may do with this guest, decided here so a greyed-out
            # button and the API's refusal always agree.
            $view.actions = @(Get-CBGuestActionOption -Row $_ -Caller $caller -Settings $settings -State $view.state)
            $view
        } | Sort-Object -Property { $_.sortKey })

    $counts = [ordered]@{ total = 0; pending = 0; active = 0; expiring = 0; expired = 0; blocked = 0; deleted = 0 }
    foreach ($i in $items) { if ($counts.Contains($i.state)) { $counts[$i.state] = [int]$counts[$i.state] + 1 } }
    # Rows for accounts that no longer exist are kept for the audit trail but are
    # not people you work with, so they do not count towards the headline number.
    $counts.total = $items.Count - [int]$counts.deleted

    $canInvite = Test-CBCanInvite -Caller $caller -Settings $settings
    Write-CBHeartbeatSampled -Name 'GuestsApi'
    Send-Json -Status 200 -Object @{
        items     = $items
        counts    = $counts
        scope     = $(if ($wantsAll) { 'all' } else { 'mine' })
        canInvite = [ordered]@{ allowed = [bool]$canInvite.Allowed; reason = "$($canInvite.Reason)" }
        simulation = [bool]$settings.dryRun
    }
}
catch {
    Write-CBHeartbeatSampled -Name 'GuestsApi' -Status error -ErrorMessage $_.Exception.Message
    Write-Error "GuestsApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
