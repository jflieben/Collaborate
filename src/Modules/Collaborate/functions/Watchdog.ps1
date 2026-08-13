# Noticing when the tool has stopped working.
#
# A scheduled tool that quietly stops is worse than one that fails loudly: guests
# keep their access, nobody is reminded, and the first anybody hears of it is an
# audit. Nothing in Azure will tell you that a timer has not fired. So the
# watchdog runs daily, checks the things that would be invisible otherwise, and
# emails the service desk when any of them look wrong.
#
# It is deliberately not clever. Each check answers one question with one
# sentence, so the email reads like a list a person can act on rather than a
# dashboard they have to interpret.

function Get-CBExpectedFunction {
    <#
    .SYNOPSIS
        The background jobs that must run, and how stale is too stale.
    .DESCRIPTION
        HTTP endpoints are excluded on purpose: nobody calling the portal for a
        day is not a fault. These are the ones that run on a schedule, where
        silence is the symptom.
    #>
    return @(
        [pscustomobject]@{ Name = 'GuestScanner'; MaxAgeHours = 48; What = 'the daily sweep that decides who is reminded, blocked or removed' },
        [pscustomobject]@{ Name = 'RedemptionPoller'; MaxAgeHours = 6; What = 'noticing when a guest accepts their invitation' },
        [pscustomobject]@{ Name = 'Watchdog'; MaxAgeHours = 48; What = 'this health check itself' }
    )
}

function Test-CBHealth {
    <#
    .SYNOPSIS
        Every health check, as a list of findings. Empty means healthy.
    .OUTPUTS
        An array of @{ severity; title; detail } with severity 'error' or 'warning'.
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $cfg = Get-CBConfig
    $findings = [System.Collections.Generic.List[object]]::new()
    $now = [DateTimeOffset]::UtcNow

    # --- Are the scheduled jobs running, and succeeding? --------------------
    $heartbeats = @{}
    try { foreach ($h in Get-CBHeartbeats) { $heartbeats["$($h.RowKey)"] = $h } }
    catch { $findings.Add(@{ severity = 'error'; title = 'Health data cannot be read'; detail = "The heartbeat table could not be read: $($_.Exception.Message)" }) }

    foreach ($expected in Get-CBExpectedFunction) {
        $h = $heartbeats["$($expected.Name)"]
        if (-not $h) {
            # A job that has never run at all is only worth reporting once the
            # install has had a chance to run it.
            if ("$($Settings.setupCompletedUtc)") {
                $completed = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse("$($Settings.setupCompletedUtc)", [ref]$completed) -and
                    ($now - $completed).TotalHours -gt $expected.MaxAgeHours) {
                    $findings.Add(@{ severity = 'error'; title = "$($expected.Name) has never run"
                            detail = "Setup finished more than $($expected.MaxAgeHours) hours ago but $($expected.What) has not run once. Check the Function App is running and that its triggers were synced."
                        })
                }
            }
            continue
        }
        $last = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse("$($h.LastRunUtc)", [ref]$last)) {
            $age = [int]($now - $last).TotalHours
            if ($age -gt $expected.MaxAgeHours) {
                $findings.Add(@{ severity = 'error'; title = "$($expected.Name) has not run for $age hours"
                        detail = "Expected at least every $($expected.MaxAgeHours) hours. This is $($expected.What)."
                    })
            }
        }
        if ("$($h.LastStatus)" -eq 'error') {
            $findings.Add(@{ severity = 'error'; title = "$($expected.Name) failed on its last run"
                    detail = "$($h.LastError)"
                })
        }
    }

    # --- Is anything stuck? -------------------------------------------------
    try {
        $poison = Get-CBQueueDepth -Name ($cfg.GuestActionQueue + '-poison')
        if ($poison -gt 0) {
            $findings.Add(@{ severity = 'error'; title = "$poison piece(s) of work failed permanently"
                    detail = 'Messages that failed five times are held in the poison queue. Whatever they were meant to do has not happened. The Diagnostics tab shows the count; Application Insights shows why.'
                })
        }
        $depth = Get-CBQueueDepth -Name $cfg.GuestActionQueue
        if ($depth -gt 500) {
            $findings.Add(@{ severity = 'warning'; title = "$depth pieces of work are waiting"
                    detail = 'The queue is unusually deep. Either a large scan is still draining or the processor is not keeping up.'
                })
        }
    }
    catch { Write-Warning "Could not read queue depths: $($_.Exception.Message)" }

    # --- Has the storm guard tripped? ---------------------------------------
    try {
        $safety = Get-CBSafetyStatus -Settings $Settings
        if ($safety.paused) {
            $findings.Add(@{ severity = 'error'; title = 'Everything is paused'
                    detail = "The storm guard stopped all processing: $($safety.pausedReason) Nothing will be reminded, blocked or removed until an administrator reviews this and resumes from the portal."
                })
        }
    }
    catch { Write-Warning "Could not read the safety state: $($_.Exception.Message)" }

    # --- Has the public page been tampered with? ----------------------------
    $page = Test-CBWelcomePagePublished -Settings $Settings
    if ($page.Checked -and -not $page.Match) {
        $findings.Add(@{ severity = 'error'; title = 'The public welcome page has changed'
                detail = "$($page.Reason). That page is served to external people with no authentication. Run Update-Collaborate.ps1 to restore it from source, and check the storage account's access logs."
            })
    }

    # --- Is the logo the settings claim actually being served? --------------
    # Settings and the public site can disagree, and when they do the symptom is
    # a broken image in three places at once with no error anywhere. Cheap to
    # check, and it is exactly the sort of thing nobody notices for weeks.
    if ("$($Settings.branding.logoFile)" -and (Test-CBPublicSiteConfigured)) {
        $published = Get-CBPublicBlobLength -Container '$web' -Name ('assets/' + $Settings.branding.logoFile)
        if ($published -eq 0) {
            $findings.Add(@{ severity = 'warning'; title = 'The logo is missing from the public site'
                    detail = "Branding says the logo is '$($Settings.branding.logoFile)' but the welcome site is not serving it, so the portal shows a broken image and the welcome page falls back to text. Upload it again on the Branding tab, or run Update-Collaborate.ps1."
                })
        }
    }

    # --- Can we still send mail? --------------------------------------------
    $mail = Test-CBMailReady
    if (-not $mail.Ok) {
        $findings.Add(@{ severity = 'error'; title = 'Mail is not working'
                detail = "$($mail.Detail) No reminders or invitations can be sent until this is fixed."
            })
    }

    # --- Configuration that stops the tool doing its job ---------------------
    if (-not "$($Settings.notifications.servicedeskEmail)") {
        $findings.Add(@{ severity = 'warning'; title = 'No service desk address'
                detail = 'Nothing can be reported to anybody, including this message. Set one in Configuration.'
            })
    }
    if ($Settings.dryRun) {
        $findings.Add(@{ severity = 'warning'; title = 'Simulation mode is still on'
                detail = 'Collaborate is logging what it would do and changing nothing. Guests are not being reminded, blocked or removed.'
            })
    }
    if (-not $Settings.setupComplete) {
        $findings.Add(@{ severity = 'warning'; title = 'Setup was never finished'
                detail = 'The portal is not usable until an administrator completes the setup wizard.'
            })
    }

    # NOT ', @($findings)'. Every caller wraps this in @(), and a unary comma
    # around an empty array yields a one-element array CONTAINING the empty
    # array. A healthy install would have reported one finding and emailed the
    # service desk about it.
    return @($findings)
}

function Send-CBHealthAlert {
    <#
    .SYNOPSIS
        Emails the service desk about health findings.
    .DESCRIPTION
        Only sends when something is actually wrong. A daily "all is well" email
        gets filtered within a week and then the real one is filtered too.
    .OUTPUTS
        @{ Sent; Errors; Warnings }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Findings, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $errors = @($Findings | Where-Object { $_.severity -eq 'error' })
    $warnings = @($Findings | Where-Object { $_.severity -ne 'error' })
    if ($errors.Count -eq 0) { return @{ Sent = $false; Errors = 0; Warnings = $warnings.Count } }

    $to = "$($Settings.notifications.servicedeskEmail)"
    if (-not $to) {
        Write-Warning "$($errors.Count) health problem(s) found but no service desk address is configured, so nobody can be told."
        return @{ Sent = $false; Errors = $errors.Count; Warnings = $warnings.Count }
    }

    # The list is built here rather than in the template so an admin editing the
    # wording cannot accidentally remove the findings themselves.
    $lines = @($errors + $warnings | ForEach-Object {
            $mark = if ($_.severity -eq 'error') { 'Problem' } else { 'Note' }
            '<li><strong>' + (ConvertTo-CBHtmlEncoded "${mark}: $($_.title)") + '</strong><br>' +
            (ConvertTo-CBHtmlEncoded "$($_.detail)") + '</li>'
        })
    $values = Get-CBMailTokenValue -Settings $Settings
    $values.problemCount = "$($errors.Count)"
    $values.problemList = '<ul>' + ($lines -join '') + '</ul>'

    $sent = $false
    # Forced: a health alert is the one message that must go out even in
    # simulation mode. Simulation means "do not change the tenant", not "do not
    # tell anybody the tool is broken".
    try { $sent = Send-CBTemplateMail -Key 'watchdogAlert' -To $to -Values $values -Settings $Settings -Force }
    catch { Write-Warning "Could not send the health alert: $($_.Exception.Message)" }

    Write-CBSystemActivity -EventName "Health check found $($errors.Count) problem(s)" -Detail @{
        problems = (@($errors | ForEach-Object { "$($_.title)" }) -join '; ')
        notes    = (@($warnings | ForEach-Object { "$($_.title)" }) -join '; ')
        sentTo   = $to
        sent     = $sent
    }
    return @{ Sent = $sent; Errors = $errors.Count; Warnings = $warnings.Count }
}
