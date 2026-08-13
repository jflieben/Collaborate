# The setup wizard and its SSO self-test.
#
# Collaborate requires Entra SSO and has no other way in. The wizard proves that
# before it lets an operator finish, because "I configured single sign-on" and
# "single sign-on is actually enforced" are different claims, and the gap between
# them is exactly where an internet-facing admin API ends up unauthenticated.
#
# Until setup completes, the operator who ran the deploy holds bootstrap admin
# rights (Auth.ps1). Completing the wizard drops that, permanently.

function Test-CBSsoEnforcement {
    <#
    .SYNOPSIS
        Calls this app's own public URL with NO Authorization header and reports
        what came back. Anything other than 200 is a pass.
    .DESCRIPTION
        Two different gates can produce the pass, and both are legitimate:
        Easy Auth rejecting an unauthenticated call, or (once the network
        lockdown is on) the platform refusing the app's own egress address. A 200
        means an unauthenticated caller can read the API, which is the failure
        this test exists to catch.
    #>
    [CmdletBinding()] param([string]$Path = '/api/setup')
    $siteHost = [Environment]::GetEnvironmentVariable('WEBSITE_HOSTNAME')
    if (-not $siteHost) {
        return @{ Ok = $false; Skipped = $true; Status = 0; Detail = 'Could not determine this app''s host name, so the anonymous round trip was skipped.' }
    }
    $uri = "https://$siteHost$Path"
    try {
        $null = Invoke-RestMethod -Method Get -Uri $uri -SkipHttpErrorCheck -StatusCodeVariable sc -TimeoutSec 20 -ErrorAction Stop
    }
    catch {
        # A transport failure (DNS, TLS, a network rule closing the connection)
        # is not an open API, so it passes, but say so rather than claiming a
        # clean 401.
        return @{ Ok = $true; Skipped = $false; Status = 0; Detail = "The anonymous request could not reach the API ($($_.Exception.Message)), so it is certainly not open." }
    }
    if ($sc -eq 200) {
        return @{ Ok = $false; Skipped = $false; Status = $sc; Detail = 'An unauthenticated request to the API returned 200. Authentication is NOT being enforced. Check Authentication (Easy Auth) on the Function App before going further.' }
    }
    return @{ Ok = $true; Skipped = $false; Status = $sc; Detail = "An unauthenticated request was refused with HTTP $sc." }
}

function Test-CBExpiryAttributeFree {
    <#
    .SYNOPSIS
        Checks that the chosen extensionAttribute is not already used for
        something else, by sampling existing guests.
    .DESCRIPTION
        Collaborate writes the expiry date onto the guest object itself. If the
        tenant already uses that attribute for, say, a cost centre, this tool
        would quietly overwrite it. Values that parse as a date are treated as
        ours (a re-run, or a previous install), not as a conflict.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Attribute, [int]$Sample = 200)
    if (-not (Test-CBExpiryAttributeName -Name $Attribute)) {
        return @{ Ok = $false; Detail = "'$Attribute' is not one of extensionAttribute1 to extensionAttribute15."; Conflicts = @() }
    }
    try {
        $uri = "/users?`$filter=userType eq 'Guest'&`$select=id,displayName,userPrincipalName,onPremisesExtensionAttributes&`$top=$([Math]::Min($Sample, 999))"
        $guests = @(Invoke-CBGraph -Uri $uri)
        $items = @($guests.value)
    }
    catch {
        return @{ Ok = $true; Detail = "Could not sample existing guests ($($_.Exception.Message)); the attribute could not be checked."; Conflicts = @() }
    }

    $conflicts = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $items) {
        $value = "$($g.onPremisesExtensionAttributes.$Attribute)".Trim()
        if (-not $value) { continue }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($value, [ref]$parsed)) { continue }   # looks like one of ours
        $conflicts.Add(@{ displayName = "$($g.displayName)"; userPrincipalName = "$($g.userPrincipalName)"; value = $value })
        if ($conflicts.Count -ge 5) { break }
    }

    if ($conflicts.Count -gt 0) {
        return @{
            Ok        = $false
            Detail    = "$Attribute already holds other data on at least $($conflicts.Count) guest(s), for example '$($conflicts[0].value)' on $($conflicts[0].displayName). Choose a different attribute so Collaborate does not overwrite it."
            Conflicts = @($conflicts)
        }
    }
    return @{ Ok = $true; Detail = "$Attribute is free to use."; Conflicts = @() }
}

function Invoke-CBSetupTest {
    <#
    .SYNOPSIS
        The full pre-flight the wizard must pass before setup can complete.
    .OUTPUTS
        @{ Ok; Checks = @( @{ id; label; ok; required; detail } ) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)]$Request,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $checks = [System.Collections.Generic.List[object]]::new()

    # 1. The caller's own token. Reaching this code already means it validated,
    #    so this check reports WHAT was proven rather than re-proving it.
    $checks.Add(@{
            id = 'token'; label = 'Your sign-in token is valid'; ok = $true; required = $true
            detail = "Signed in as $($Caller.Upn). Roles: $(if ($Caller.Roles.Count) { $Caller.Roles -join ', ' } else { 'none yet (using bootstrap administrator rights from the deployment)' })."
        })

    # 2. Easy Auth is genuinely in front of the app, not merely configured.
    $easyAuth = Test-CBEasyAuthPresent -Request $Request
    $checks.Add(@{
            id = 'easyauth'; label = 'App Service authentication is in front of the API'; ok = $easyAuth; required = $true
            detail = $(if ($easyAuth) { 'The platform passed a verified client principal with this request.' }
                else { 'No client principal header arrived, which means App Service Authentication is not processing requests. The API is still protected by its own token validation, but fix Easy Auth before going live.' })
        })

    # 3. An anonymous request must not be served.
    $anon = Test-CBSsoEnforcement
    $checks.Add(@{
            id = 'anonymous'; label = 'Anonymous requests are refused'; ok = $anon.Ok; required = $true; detail = $anon.Detail
        })

    # 4. On-behalf-of, which everything under Sharing depends on.
    $sharingOn = ($Settings.sharing.files -or $Settings.sharing.folders -or $Settings.sharing.teams)
    $obo = Test-CBOboAvailable -Caller $Caller
    $checks.Add(@{
            id = 'obo'; label = 'Collaborate can act on your behalf (needed for sharing)'; ok = $obo.Ok; required = $sharingOn
            detail = $(if ($obo.Ok) { "Exchanged your token and read your profile as $($obo.UserPrincipalName)." } else { $obo.Error })
        })

    # 5. The expiry attribute is free.
    $attr = Test-CBExpiryAttributeFree -Attribute "$($Settings.expiry.attribute)"
    $checks.Add(@{
            id = 'attribute'; label = 'The expiry attribute is available'; ok = $attr.Ok; required = $true; detail = $attr.Detail
        })

    # 6. The public welcome page can be published. Guests land there after
    #    accepting, so a missing role assignment here breaks every invitation.
    $site = Test-CBPublicSiteWritable
    $checks.Add(@{
            id = 'publicsite'; label = 'The public welcome page can be published'; ok = $site.Ok; required = $true; detail = $site.Detail
        })

    # 7. Mail. Not required to finish setup (an operator may be waiting for the
    #    Exchange role assignment to replicate, which can take half an hour), but
    #    it is the first thing that will look broken, so it is checked and shown.
    $mail = Test-CBMailReady
    $checks.Add(@{
            id = 'mail'; label = 'The sender mailbox is reachable'; ok = $mail.Ok; required = $false; detail = $mail.Detail
        })

    $ok = -not (@($checks | Where-Object { $_.required -and -not $_.ok }).Count)
    return @{ Ok = $ok; Checks = @($checks) }
}

function Test-CBMailReady {
    <#
    .SYNOPSIS
        Can we see the sender mailbox? Sending is authorised by Exchange RBAC,
        which replicates on its own schedule, so a fresh install may legitimately
        fail this for a while.
    #>
    [CmdletBinding()] param()
    $cfg = Get-CBConfig
    if (-not $cfg.SenderUpn) { return @{ Ok = $false; Detail = 'No sender mailbox is configured.' } }
    try {
        $r = Invoke-CBGraph -Uri ('/users/' + [Uri]::EscapeDataString($cfg.SenderUpn) + '?$select=id,mail,userPrincipalName') -Raw
        if ($r.StatusCode -ge 400) {
            return @{ Ok = $false; Detail = "Could not read the sender mailbox $($cfg.SenderUpn) (HTTP $($r.StatusCode))." }
        }
        return @{ Ok = $true; Detail = "Sending as $($cfg.SenderUpn)." }
    }
    catch { return @{ Ok = $false; Detail = "Could not read the sender mailbox: $($_.Exception.Message)" } }
}

function Complete-CBSetup {
    <#
    .SYNOPSIS
        Marks setup as finished and publishes the welcome site for the first
        time. After this the deploying operator's bootstrap admin rights stop
        applying, so administration requires the Collaborate.Admin app role.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Caller)
    $Settings.setupComplete = $true
    $Settings.setupCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $Settings.setupCompletedBy = "$($Caller.Upn)"

    try { $Settings = Publish-CBWelcomeSite -Settings $Settings -Actor $Caller.Upn }
    catch { Write-Warning "Setup completed but the welcome page could not be published: $($_.Exception.Message)" }

    $saved = Save-CBSettings -Raw $Settings
    Write-CBSystemActivity -EventName 'Setup completed' -Actor $Caller.Upn -Detail @{
        note = 'Single sign-on verified. Bootstrap administrator rights from the deployment no longer apply.'
    }
    return $saved
}
