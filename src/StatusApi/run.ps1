using namespace System.Net

# Diagnostics.
#
# The point of this endpoint is that an operator can answer "is it working?"
# without opening Application Insights: every worker records a heartbeat, the
# storm guard exposes its counters, and the published welcome page is checked
# against the hash the app recorded when it last wrote it.

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
    $cfg = Get-CBConfig
    $settings = Get-CBSettings

    $heartbeats = @()
    try {
        $heartbeats = @(Get-CBHeartbeats | ForEach-Object {
                [ordered]@{
                    name           = $_.RowKey
                    lastRunUtc     = "$($_.LastRunUtc)"
                    lastStatus     = "$($_.LastStatus)"
                    lastSuccessUtc = "$($_.LastSuccessUtc)"
                    lastDurationMs = "$($_.LastDurationMs)"
                    lastError      = "$($_.LastError)"
                    lastErrorUtc   = "$($_.LastErrorUtc)"
                }
            } | Sort-Object { $_.name })
    }
    catch { Write-Warning "Could not read heartbeats: $($_.Exception.Message)" }

    $safety = $null
    try { $safety = Get-CBSafetyStatus -Settings $settings } catch { Write-Warning "Could not read safety state: $($_.Exception.Message)" }

    $page = Test-CBWelcomePagePublished -Settings $settings
    $mail = Test-CBMailReady
    $obo = Test-CBOboAvailable -Caller $caller

    # The same checks the nightly watchdog runs, so an operator sees today what
    # would otherwise arrive by email tomorrow morning.
    $findings = @()
    try { $findings = @(Test-CBHealth -Settings $settings) }
    catch { Write-Warning "Health checks could not run: $($_.Exception.Message)" }

    $unowned = 0
    try { $unowned = @(Get-CBOrphanRow | Where-Object { "$($_.State)".ToLowerInvariant() -ne 'deleted' }).Count }
    catch { Write-Warning "Could not count unowned guests: $($_.Exception.Message)" }

    $versionState = $null
    try { $versionState = Get-CBVersionState } catch { }

    # The version the CODE reports, next to the version the app SETTING claims.
    # They are written by different steps of the deployment, so a mismatch means
    # the code did not land even though the deployment reported success.
    $codeVersion = Get-CBModuleVersion

    Send-Json -Status 200 -Object @{
        version     = $cfg.Version
        codeVersion = $codeVersion
        codeStale   = [bool]($codeVersion -ne 'unknown' -and "$($cfg.Version)" -ne 'dev' -and $codeVersion -ne "$($cfg.Version)")
        functions   = @((Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'function.json') } | ForEach-Object { $_.Name } | Sort-Object))
        simulation  = [bool]$settings.dryRun
        setupComplete = [bool]$settings.setupComplete
        heartbeats  = $heartbeats
        safety      = $safety
        health      = [ordered]@{
            problems = @($findings | Where-Object { $_.severity -eq 'error' })
            notes    = @($findings | Where-Object { $_.severity -ne 'error' })
        }
        guests      = [ordered]@{ unowned = $unowned; population = $(if ($safety) { $safety.guestCount } else { 0 }) }
        update      = [ordered]@{
            available = [bool]($versionState -and "$($versionState.UpdateAvailable)".ToLowerInvariant() -eq 'true')
            latest    = $(if ($versionState) { "$($versionState.Latest)" } else { '' })
            checkedUtc = $(if ($versionState) { "$($versionState.CheckedUtc)" } else { '' })
            detail    = $(if ($versionState) { "$($versionState.Error)" } else { 'never checked' })
        }
        queues      = [ordered]@{
            work   = (Get-CBQueueDepth -Name $cfg.GuestActionQueue)
            poison = (Get-CBQueueDepth -Name ($cfg.GuestActionQueue + '-poison'))
        }
        welcomePage = [ordered]@{
            url       = $cfg.PublicSiteUrl
            checked   = [bool]$page.Checked
            intact    = [bool]$page.Match
            detail    = "$($page.Reason)"
            publishedUtc = "$($settings.welcome.publishedUtc)"
        }
        mail        = [ordered]@{ ok = [bool]$mail.Ok; detail = "$($mail.Detail)"; sender = $cfg.SenderUpn }
        delegation  = [ordered]@{ ok = [bool]$obo.Ok; detail = $(if ($obo.Ok) { "Verified as $($obo.UserPrincipalName)." } else { $obo.Error }) }
    }
}
catch {
    Write-Error "StatusApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
