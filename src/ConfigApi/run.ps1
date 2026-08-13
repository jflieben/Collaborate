using namespace System.Net

# The admin console's read/save endpoint for every behavioural setting:
# branding, expiry policy, invitation rules, sharing gates, safety limits, the
# welcome page and all email templates.
#
# Admins never edit the config blob directly, so this endpoint owns everything
# that has to happen around a save: sanitising, auditing the diff, and
# republishing the public welcome page when anything it renders has changed.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 14)
        })
}

try {
    $caller = Test-CBAdminRequest -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    Initialize-CBTables

    if ($Request.Method -ne 'POST') {
        Send-Json -Status 200 -Object (Get-CBAdminConfigPayload)
        return
    }

    # Normalised first. The worker hands a JSON body over as a HASHTABLE, whose
    # keys are invisible to PSObject.Properties, so the unwrap below used to
    # answer "no settings here" on every real request. The sanitiser then filled
    # in every missing field from the defaults and dutifully stored those.
    $raw = ConvertFrom-CBRequestBody -Body $Request.Body
    if ($raw -and $raw.PSObject.Properties['settings']) { $raw = $raw.settings }
    if (-not $raw) { Send-Json -Status 400 -Object @{ error = 'No settings were supplied.' }; return }

    # A save that carries none of the fields it is supposed to is a bug
    # somewhere, not an instruction to reset the tenant's configuration to the
    # shipped defaults. Refuse it and say so.
    if (-not $raw.PSObject.Properties['branding'] -or -not $raw.PSObject.Properties['expiry']) {
        Send-Json -Status 400 -Object @{ error = 'That did not look like a settings object, so nothing was saved. Reload the page and try again.' }
        return
    }

    # Read straight from the blob, so the diff is against what is actually
    # stored: on Flex Consumption another worker may have saved since this one
    # last looked.
    $before = Get-CBSettings
    $incoming = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw $raw)

    # Fields the client may not set, whatever it sends: setup state is owned by
    # the wizard, and the published hash is owned by the publisher (it is how
    # tampering with the public page is detected).
    $incoming.setupComplete = $before.setupComplete
    $incoming.setupCompletedUtc = $before.setupCompletedUtc
    $incoming.setupCompletedBy = $before.setupCompletedBy
    $incoming.welcome.publishedHash = $before.welcome.publishedHash
    $incoming.welcome.publishedUtc = $before.welcome.publishedUtc
    # The logo is replaced through BrandingApi, which validates the image itself.
    $incoming.branding.logoFile = $before.branding.logoFile
    $incoming.branding.logoContentType = $before.branding.logoContentType
    $incoming.branding.logoUpdatedUtc = $before.branding.logoUpdatedUtc

    $diff = Compare-CBSettings -Old $before -New $incoming

    # Anything the welcome page renders means it has to be rebuilt. Publishing
    # before saving would leave a page describing settings that were never
    # stored, so the hash is folded into the object that then gets saved.
    $republishKeys = @($diff.Keys | Where-Object { $_ -like 'branding.*' -or ($_ -like 'welcome.*' -and $_ -notlike 'welcome.published*') })
    $published = $false
    $publishError = ''
    if ($republishKeys.Count -gt 0 -and (Test-CBPublicSiteConfigured)) {
        try {
            $incoming = Publish-CBWelcomeSite -Settings $incoming -Actor $caller.Upn
            $published = $true
        }
        catch {
            $publishError = $_.Exception.Message
            Write-Warning "Settings saved but the welcome page could not be republished: $publishError"
        }
    }

    $saved = Save-CBSettings -Raw $incoming

    Write-CBSystemActivity -EventName "Configuration changed ($($diff.Count) setting$(if ($diff.Count -ne 1) { 's' }))" `
        -Actor $caller.Upn -Detail $(if ($diff.Count -gt 0) { $diff } else { @{ note = 'saved without changes' } })

    $payload = Get-CBAdminConfigPayload -Settings $saved
    $payload.published = $published
    # So the portal can say "nothing to save" rather than "saved", which is what
    # somebody who believes they just changed something needs to hear.
    $payload.changed = $diff.Count
    if ($publishError) {
        $payload.publishWarning = "Your settings were saved, but the public welcome page could not be updated: $publishError"
    }
    Send-Json -Status 200 -Object $payload
}
catch {
    Write-Error "ConfigApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
