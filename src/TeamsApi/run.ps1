using namespace System.Net

# The Teams the signed-in user owns.
#
# GET /api/teams
#
# Ownership comes from Graph answering as the user, so this list cannot include a
# Team they do not own. Whether each one accepts guests is read with the managed
# identity, because that is tenant and group configuration rather than something
# the user is acting on, and most employees cannot read group settings at all.
# The result is a picker that can say "this Team does not accept guests" instead
# of letting somebody find out by failing.
#
# Adding somebody happens on POST /api/share, so there is one place that invites,
# grants access and sends the mail in the right order.

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

    $settings = Get-CBSettings
    if (-not $settings.setupComplete) {
        Send-Json -Status 409 -Object @{ error = 'Collaborate has not been set up yet.' }
        return
    }
    $capability = Test-CBSharingCapability -Kind 'team' -Settings $settings
    if (-not $capability.Allowed) {
        Send-Json -Status 403 -Object @{ error = $capability.Reason }
        return
    }

    $owned = Get-CBOwnedTeam -Caller $caller
    $policy = Get-CBTenantGuestPolicy

    # An empty list has three quite different causes, and telling them apart is
    # the difference between "fine" and "something is wrong". Saying which one it
    # is here saves somebody who owns six Teams from being told they own none.
    $emptyReason = ''
    if (@($owned.Teams).Count -eq 0) {
        if ($owned.OwnedGroups -eq 0) {
            $emptyReason = 'You do not own any groups or Teams, so there is nothing to add a guest to.'
        }
        elseif ($owned.Detection -eq 'none') {
            $emptyReason = "You own $($owned.OwnedGroups) group(s), but Collaborate could not work out which of them are Teams. An administrator should check that the Team.ReadBasic.All delegated permission is consented."
        }
        else {
            $emptyReason = "You own $($owned.OwnedGroups) group(s), but none of them are Teams."
        }
    }

    Write-CBHeartbeatSampled -Name 'TeamsApi'
    Send-Json -Status 200 -Object @{
        items       = @($owned.Teams)
        ownedGroups = $owned.OwnedGroups
        emptyReason = $emptyReason
        tenantAllowsGuests = [bool]$policy.AllowGuests
        tenantPolicyNote   = "$($policy.Source)"
    }
}
catch {
    Write-CBHeartbeatSampled -Name 'TeamsApi' -Status error -ErrorMessage $_.Exception.Message
    Write-Error "TeamsApi failed: $($_.Exception.Message)"
    Send-Json -Status 502 -Object @{ error = $_.Exception.Message }
}
