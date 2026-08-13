using namespace System.Net

# Administrator operations that act on many guests, or on the tool itself.
#
# POST /api/operations  { "action": "..." }
#
# The route is 'operations', NOT 'admin': the Functions host reserves /admin for
# its own management API, so a function routed there registers normally, appears
# in every function listing, and then answers 404 for every request. The symptom
# looks exactly like a failed deployment, which is a long way from the cause.
#
#   assign        make one colleague responsible for a list of guests
#   refresh       re-read acceptance and last-active from Entra for every record
#   adopt         run the adoption pass now instead of waiting for tonight
#   orphanDigest  send the unowned-guest digest now
#   healthCheck   run the watchdog now and return what it found
#   versionCheck  check for a newer release now
#
# Every one of these is something a scheduled job also does. They are exposed
# because "wait until tomorrow to see whether the thing you just configured
# works" is a miserable way to set a tool up.

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
    $caller = Test-CBAdminRequest -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    Initialize-CBTables
    $settings = Get-CBSettings

    $body = ConvertFrom-CBRequestBody -Body $Request.Body
    $action = "$($body.action)".Trim().ToLowerInvariant()

    switch ($action) {
        'assign' {
            $ownerId = "$($body.ownerId)".Trim()
            if ($ownerId -notmatch '^[0-9a-fA-F-]{36}$') {
                Send-Json -Status 400 -Object @{ error = 'Choose the colleague who should take these on.' }
                return
            }
            $guestIds = @(@($body.guestIds) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^[0-9a-fA-F-]{36}$' })
            if ($guestIds.Count -eq 0) { Send-Json -Status 400 -Object @{ error = 'No guests were selected.' }; return }
            if ($guestIds.Count -gt 200) { Send-Json -Status 400 -Object @{ error = 'Assign at most 200 at a time.' }; return }

            # Resolve the owner once rather than once per guest: assigning fifty
            # guests should not be fifty identical directory lookups.
            $owner = Get-CBUserProfile -Oid $ownerId
            if (-not $owner) { Send-Json -Status 404 -Object @{ error = 'That colleague could not be found.' }; return }

            $assigned = 0
            $failures = [System.Collections.Generic.List[object]]::new()
            foreach ($guestId in $guestIds) {
                $result = Set-CBGuestOwner -Caller $caller -GuestId $guestId -NewOwnerId $ownerId `
                    -Reason "$($body.reason)" -Settings $settings -OwnerProfile $owner
                if ($result.Ok) { $assigned++ }
                else { $failures.Add(@{ guestId = $guestId; error = "$($result.Error)" }) }
            }
            Send-Json -Status 200 -Object @{
                assigned  = $assigned
                failed    = @($failures)
                owner     = [ordered]@{ id = $ownerId; displayName = "$($owner.displayName)" }
                simulated = [bool]$settings.dryRun
                message   = "$($owner.displayName) is now responsible for $assigned external collaborator(s)."
            }
        }
        'refresh' {
            $result = Update-CBGuestDirectoryFacts -Settings $settings
            $message = "Checked $($result.Checked) record(s) against Entra and updated $($result.Updated)."
            if (-not $result.SignInAvailable) {
                $message += ' Sign-in times are not available for this tenant, which needs an Entra ID P1 or P2 licence, so last-active was left as it was.'
            }
            Send-Json -Status 200 -Object @{
                checked         = $result.Checked
                updated         = $result.Updated
                signInAvailable = [bool]$result.SignInAvailable
                signInError     = "$($result.SignInError)"
                message         = $message
            }
        }
        'adopt' {
            $result = Invoke-CBGuestAdoption -Settings $settings -Limit (ConvertTo-CBInt -Value $body.limit -Default 500 -Min 1 -Max 2000)
            Send-Json -Status 200 -Object @{
                adopted   = $result.Adopted
                unowned   = $result.Orphaned
                skipped   = $result.Skipped
                remaining = $result.Remaining
                simulated = [bool]$settings.dryRun
                message   = "Adopted $($result.Adopted) guest(s); $($result.Orphaned) of them have nobody responsible. $($result.Remaining) left for the next run."
            }
        }
        'orphandigest' {
            $result = Send-CBOrphanDigest -Settings $settings
            Send-Json -Status 200 -Object @{
                count   = $result.Count
                sent    = [bool]$result.Sent
                message = $(if ($result.Count -eq 0) { 'Every external account has somebody responsible for it.' }
                    elseif ($result.Sent) { "Told the service desk about $($result.Count) unowned account(s)." }
                    else { "$($result.Count) account(s) have no owner, but the digest could not be sent. Check the service desk address and the mail configuration." })
            }
        }
        'healthcheck' {
            $findings = @(Test-CBHealth -Settings $settings)
            $alert = @{ Sent = $false }
            if ($findings.Count -gt 0) { $alert = Send-CBHealthAlert -Findings $findings -Settings $settings }
            Send-Json -Status 200 -Object @{
                findings = @($findings)
                alerted  = [bool]$alert.Sent
                message  = $(if ($findings.Count -eq 0) { 'Everything looks normal.' } else { "Found $($findings.Count) thing(s) worth knowing about." })
            }
        }
        'versioncheck' {
            $result = Invoke-CBVersionCheck -Settings $settings
            Send-Json -Status 200 -Object @{
                current         = "$($result.Current)"
                latest          = "$($result.Latest)"
                updateAvailable = [bool]$result.UpdateAvailable
                message         = $(if ($result.UpdateAvailable) { "Collaborate $($result.Latest) is available." }
                    elseif ($result.Latest) { "This install is up to date on $($result.Current)." }
                    else { 'The published version could not be read. This deployment may have no outbound internet access, which is fine.' })
            }
        }
        default {
            Send-Json -Status 400 -Object @{ error = "Unknown action '$action'." }
        }
    }
}
catch {
    Write-Error "AdminApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
