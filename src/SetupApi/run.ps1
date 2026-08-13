using namespace System.Net

# The setup wizard.
#
#   GET                  -> current state plus everything the wizard renders from
#   POST { action=save } -> store the wizard's answers without finishing
#   POST { action=test } -> run the SSO self-test and report every check
#   POST { action=complete } -> save, re-run the test, and only finish if it passes
#
# Completing setup permanently drops the deploying operator's bootstrap admin
# rights, so it is deliberately the one action that refuses to proceed on a
# failed check.

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
    $caller = Test-CBAdminRequest -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    Initialize-CBTables

    if ($Request.Method -eq 'GET') {
        $settings = Get-CBSettings
        Send-Json -Status 200 -Object @{
            settings         = $settings
            firstRun         = -not $settings.setupComplete
            hasStoredConfig  = (Test-CBSettingsBlobExists)
            expiryAttributes = @(1..15 | ForEach-Object { "extensionAttribute$_" })
            emailCatalog     = @(Get-CBEmailCatalog)
            warnings         = @(Get-CBSettingsWarning -Settings $settings)
            welcomeUrl       = (Get-CBConfig).PublicSiteUrl
            version          = (Get-CBConfig).Version
        }
        return
    }

    $body = ConvertFrom-CBRequestBody -Body $Request.Body
    $action = "$($body.action)".Trim().ToLowerInvariant()
    if (-not $action) { $action = 'save' }

    # 'test' does not touch stored state: an operator can re-run it as often as
    # they like while fixing whatever it reported.
    if ($action -eq 'test') {
        $settings = if ($body.settings) { [pscustomobject](ConvertTo-CBSanitisedSettings -Raw $body.settings) } else { Get-CBSettings }
        $result = Invoke-CBSetupTest -Caller $caller -Request $Request -Settings $settings
        Send-Json -Status 200 -Object @{ ok = $result.Ok; checks = $result.Checks }
        return
    }

    if (-not $body.settings) {
        Send-Json -Status 400 -Object @{ error = 'No settings were supplied.' }
        return
    }

    $before = Get-CBSettings
    $incoming = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw $body.settings)
    # setupComplete is never taken from the request: it is set by Complete-CBSetup
    # after the test passes, and nothing else may turn it on.
    $incoming.setupComplete = $before.setupComplete
    $incoming.setupCompletedUtc = $before.setupCompletedUtc
    $incoming.setupCompletedBy = $before.setupCompletedBy

    if ($action -eq 'complete') {
        $result = Invoke-CBSetupTest -Caller $caller -Request $Request -Settings $incoming
        if (-not $result.Ok) {
            Send-Json -Status 400 -Object @{
                error  = 'Setup cannot be completed until the checks below pass.'
                ok     = $false
                checks = $result.Checks
            }
            return
        }
        $saved = Complete-CBSetup -Settings $incoming -Caller $caller
        Send-Json -Status 200 -Object @{ ok = $true; checks = $result.Checks; settings = $saved }
        return
    }

    # Plain save: keep the wizard's progress, publish nothing yet.
    $saved = Save-CBSettings -Raw $incoming
    $diff = Compare-CBSettings -Old $before -New $saved
    Write-CBSystemActivity -EventName "Setup progress saved ($($diff.Count) setting$(if ($diff.Count -ne 1) { 's' }))" -Actor $caller.Upn -Detail $diff
    Send-Json -Status 200 -Object @{ ok = $true; settings = $saved }
}
catch {
    Write-Error "SetupApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
