# Email templates: the catalogue, the defaults, and the renderer.
#
# Admins edit every message in the portal. This file is the single source of
# truth for WHICH messages exist, which tokens each one receives, and what the
# shipped default says. The portal renders its editor from the catalogue the API
# returns, so the UI and the runtime cannot drift, and "reset to default" always
# has something to reset to.
#
# Everything here is pure: no Graph, no storage. Sending lives in Mail.ps1.

function Get-CBEmailCatalog {
    <#
    .SYNOPSIS
        Every email the tool can send: key, audience, when it fires, the tokens
        available to it, and the default subject and body.
    .NOTES
        'body' is INNER html: it is wrapped in the branded shell unless the admin
        turns that off for a template. Tokens are written {{like.this}} and are
        HTML-encoded on substitution.
    #>
    [CmdletBinding()] param()

    # Tokens every template gets.
    $common = @('brand.companyName', 'brand.portalUrl', 'servicedeskEmail')

    return @(
        [pscustomobject]@{
            key = 'invitation'; label = 'Invitation'; audience = 'guest'
            description = 'Sent to the external person when they are invited. Replaces the default Microsoft invitation mail, which is suppressed.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'owner.email', 'reason', 'expiresOn', 'redeemUrl')
            subject = '{{owner.displayName}} has invited you to collaborate with {{brand.companyName}}'
            body = @'
<p>Hello {{guest.displayName}},</p>
<p><strong>{{owner.displayName}}</strong> ({{owner.email}}) has invited you to work with {{brand.companyName}}.</p>
<p><em>{{reason}}</em></p>
<p>Use the button below to accept. You can sign in with your own work or personal account: you do not need a new password.</p>
<p><a class="cb-button" href="{{redeemUrl}}">Accept the invitation</a></p>
<p>This access is arranged until <strong>{{expiresOn}}</strong>. {{owner.displayName}} can extend it if you still need it then.</p>
'@
        },
        [pscustomobject]@{
            key = 'invitationWithShare'; label = 'Invitation with a shared item'; audience = 'guest'
            description = 'Used instead of the plain invitation when the guest was invited as part of sharing a file, folder or Team, so the mail can name what they now have access to.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'owner.email', 'reason', 'expiresOn', 'redeemUrl',
                'shareName', 'shareUrl', 'shareKind', 'sharedBy.displayName', 'sharedBy.email', 'message')
            subject = '{{owner.displayName}} shared {{shareName}} with you'
            body = @'
<p>Hello {{guest.displayName}},</p>
<p><strong>{{owner.displayName}}</strong> ({{owner.email}}) has shared the {{shareKind}} <strong>{{shareName}}</strong> with you.</p>
<p><em>{{reason}}</em></p>
<p>First, accept the invitation. You can sign in with your own work or personal account: you do not need a new password.</p>
<p><a class="cb-button" href="{{redeemUrl}}">Accept and open {{shareName}}</a></p>
<p>This access is arranged until <strong>{{expiresOn}}</strong>. {{owner.displayName}} can extend it if you still need it then.</p>
'@
        },
        [pscustomobject]@{
            key = 'sharedWithGuest'; label = 'Something new was shared'; audience = 'guest'
            description = 'Sent to an external person who is already set up here when somebody shares another file, folder or Team with them. They are not invited again, so this is the only notice they get.'
            tokens = $common + @('guest.displayName', 'sharedBy.displayName', 'sharedBy.email', 'shareName', 'shareUrl', 'shareKind', 'message', 'expiresOn')
            subject = '{{sharedBy.displayName}} shared {{shareName}} with you'
            body = @'
<p>Hello {{guest.displayName}},</p>
<p><strong>{{sharedBy.displayName}}</strong> ({{sharedBy.email}}) has shared the {{shareKind}} <strong>{{shareName}}</strong> with you.</p>
<p><em>{{message}}</em></p>
<p><a class="cb-button" href="{{shareUrl}}">Open {{shareName}}</a></p>
<p>Sign in with the same account you used before. Your access runs until <strong>{{expiresOn}}</strong>.</p>
'@
        },
        [pscustomobject]@{
            key = 'welcome'; label = 'Welcome (after accepting)'; audience = 'guest'
            description = 'Sent once the guest has accepted the invitation. Off by default, because the welcome page already confirms it.'
            enabledByDefault = $false
            tokens = $common + @('guest.displayName', 'owner.displayName', 'owner.email', 'expiresOn', 'shareName', 'shareUrl')
            subject = 'You now have access at {{brand.companyName}}'
            body = @'
<p>Hello {{guest.displayName}},</p>
<p>Your access at {{brand.companyName}} is active until <strong>{{expiresOn}}</strong>.</p>
<p>If anything does not work, contact {{owner.displayName}} at {{owner.email}}.</p>
'@
        },
        [pscustomobject]@{
            key = 'guestAccepted'; label = 'Your guest accepted'; audience = 'owner'
            description = 'Sent to the internal owner when their guest redeems the invitation, so they know the access is live. Switched on and off by "Tell the owner when their guest accepts" in Configuration.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'expiresOn')
            subject = '{{guest.displayName}} has accepted your invitation'
            body = @'
<p>Hello {{owner.displayName}},</p>
<p><strong>{{guest.displayName}}</strong> ({{guest.email}}) has accepted your invitation and can now work with us.</p>
<p>Their access runs until <strong>{{expiresOn}}</strong>. You will be reminded before it ends.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Review external collaborators</a></p>
'@
        },
        [pscustomobject]@{
            key = 'ownerReminder'; label = 'Reminder to the owner'; audience = 'owner'
            description = 'Sent to the internal owner before a guest expires, once per reminder step you configure.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'expiresOn', 'daysLeft', 'reason')
            subject = 'Access for {{guest.displayName}} ends in {{daysLeft}} day(s)'
            body = @'
<p>Hello {{owner.displayName}},</p>
<p>The external access you arranged for <strong>{{guest.displayName}}</strong> ({{guest.email}}) ends on <strong>{{expiresOn}}</strong>, in {{daysLeft}} day(s).</p>
<p><em>Original reason: {{reason}}</em></p>
<p>If they still need it, extend it. If they do not, do nothing and the access ends automatically.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Review external collaborators</a></p>
'@
        },
        [pscustomobject]@{
            key = 'guestReminder'; label = 'Reminder to the guest'; audience = 'guest'
            description = 'Optional heads-up to the external person that their access is about to end. Off by default.'
            enabledByDefault = $false
            tokens = $common + @('guest.displayName', 'owner.displayName', 'owner.email', 'expiresOn', 'daysLeft')
            subject = 'Your access to {{brand.companyName}} ends on {{expiresOn}}'
            body = @'
<p>Hello {{guest.displayName}},</p>
<p>Your access to {{brand.companyName}} ends on <strong>{{expiresOn}}</strong>, in {{daysLeft}} day(s).</p>
<p>If you still need it, please ask {{owner.displayName}} ({{owner.email}}) to extend it.</p>
'@
        },
        [pscustomobject]@{
            key = 'expiredBlocked'; label = 'Access ended'; audience = 'owner'
            description = 'Sent to the owner when a guest reaches their expiry date and sign-in is blocked. The account is kept for the grace period, so this is still reversible.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'expiresOn', 'graceDays', 'deleteOn')
            subject = 'Access ended for {{guest.displayName}}'
            body = @'
<p>Hello {{owner.displayName}},</p>
<p>The access you arranged for <strong>{{guest.displayName}}</strong> ({{guest.email}}) reached its end date on {{expiresOn}} and has been switched off.</p>
<p>The account is kept until <strong>{{deleteOn}}</strong> ({{graceDays}} days), so if this was too soon you can restore it yourself in that window.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Restore or review</a></p>
'@
        },
        [pscustomobject]@{
            key = 'deleted'; label = 'Guest removed'; audience = 'owner'
            description = 'Sent to the owner when the grace period lapses and the guest account is deleted.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName')
            subject = '{{guest.displayName}} has been removed'
            body = @'
<p>Hello {{owner.displayName}},</p>
<p><strong>{{guest.displayName}}</strong> ({{guest.email}}) has been removed from {{brand.companyName}} after their access ended and the grace period passed.</p>
<p>If you need to work with them again, invite them afresh.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Invite someone</a></p>
'@
        },
        [pscustomobject]@{
            key = 'inactivityWarning'; label = 'Inactive guest warning'; audience = 'owner'
            description = 'Sent to the owner when a guest has not signed in for longer than the inactivity threshold, before anything is done about it.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'lastSignIn', 'inactiveDays')
            subject = '{{guest.displayName}} has not signed in for {{inactiveDays}} days'
            body = @'
<p>Hello {{owner.displayName}},</p>
<p><strong>{{guest.displayName}}</strong> ({{guest.email}}) has not signed in since {{lastSignIn}}.</p>
<p>If the collaboration is over, you can end their access now. Otherwise no action is needed from you.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Review external collaborators</a></p>
'@
        },
        [pscustomobject]@{
            key = 'ownershipTransferred'; label = 'Ownership transferred'; audience = 'owner'
            description = 'Sent to the colleague who is given ownership of a guest.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'previousOwner.displayName', 'expiresOn', 'reason')
            subject = 'You are now responsible for {{guest.displayName}}'
            body = @'
<p>Hello {{owner.displayName}},</p>
<p>{{previousOwner.displayName}} has handed you the external collaborator <strong>{{guest.displayName}}</strong> ({{guest.email}}).</p>
<p><em>Reason on record: {{reason}}</em></p>
<p>Their access runs until <strong>{{expiresOn}}</strong>. You will get the reminders from now on.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Review external collaborators</a></p>
'@
        },
        [pscustomobject]@{
            key = 'askOwner'; label = 'Colleague asks the owner'; audience = 'owner'
            description = 'Sent when a colleague tries to invite someone who already exists and asks the current owner about them instead of creating a duplicate.'
            tokens = $common + @('guest.displayName', 'guest.email', 'owner.displayName', 'requester.displayName', 'requester.email', 'message')
            subject = '{{requester.displayName}} is asking about {{guest.displayName}}'
            body = @'
<p>Hello {{owner.displayName}},</p>
<p><strong>{{requester.displayName}}</strong> ({{requester.email}}) wants to work with <strong>{{guest.displayName}}</strong> ({{guest.email}}), who is already set up here and is on your list.</p>
<p><em>{{message}}</em></p>
<p>You can share what they need directly, or hand the collaborator over to them.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Open Collaborate</a></p>
'@
        },
        [pscustomobject]@{
            key = 'watchdogAlert'; label = 'Something is wrong'; audience = 'admin'
            description = 'Sent to the service desk by the daily health check when a background job has stopped, work is stuck, the storm guard has paused everything, mail has broken, or the public page has been altered. Sent even in simulation mode, because "do not change the tenant" is not the same as "do not report a fault".'
            tokens = $common + @('problemCount', 'problemList')
            # problemList is a list the watchdog builds, having already encoded
            # every title and detail that goes into it. See Send-CBHealthAlert.
            htmlTokens = @('problemList')
            subject = 'Collaborate: {{problemCount}} problem(s) need attention'
            body = @'
<p>The daily health check on {{brand.companyName}}'s Collaborate found something wrong.</p>
{{problemList}}
<p>Until these are resolved, guests may not be reminded, blocked or removed on schedule.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Open Diagnostics</a></p>
'@
        },
        [pscustomobject]@{
            key = 'versionAvailable'; label = 'A newer version is available'; audience = 'admin'
            description = 'Sent to the service desk when a newer release of Collaborate is published. Sent once per version, never repeatedly. Collaborate never updates itself.'
            tokens = $common + @('currentVersion', 'latestVersion', 'releasesUrl')
            subject = 'Collaborate {{latestVersion}} is available'
            body = @'
<p>This install is running <strong>{{currentVersion}}</strong>. <strong>{{latestVersion}}</strong> has been published.</p>
<p>Nothing has changed here: Collaborate does not update itself. Re-run the deployment or Update-Collaborate.ps1 when you are ready.</p>
<p><a class="cb-button" href="{{releasesUrl}}">Read the release notes</a></p>
'@
        },
        [pscustomobject]@{
            key = 'orphanDigest'; label = 'Unowned guests digest'; audience = 'admin'
            description = 'Sent to the service desk when guests exist that nobody is accountable for, so somebody can claim or remove them.'
            tokens = $common + @('orphanCount', 'orphanList')
            subject = '{{orphanCount}} external account(s) have no owner'
            body = @'
<p>{{orphanCount}} external account(s) in {{brand.companyName}} have nobody responsible for them:</p>
<p>{{orphanList}}</p>
<p>Assign an owner, or remove them.</p>
<p><a class="cb-button" href="{{brand.portalUrl}}">Open Collaborate</a></p>
'@
        }
    )
}

function Get-CBEmailDefault {
    <#
    .SYNOPSIS
        The shipped default for one template key, in the shape it is stored in.
        This is what "reset to default" writes.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Key)
    $entry = Get-CBEmailCatalog | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    if (-not $entry) { return $null }
    $enabled = if ($entry.PSObject.Properties['enabledByDefault']) { [bool]$entry.enabledByDefault } else { $true }
    return [ordered]@{
        enabled       = $enabled
        subject       = $entry.subject
        html          = $entry.body.Trim()
        useBrandShell = $true
    }
}

function Get-CBEmailDefaults {
    [CmdletBinding()] param()
    $out = [ordered]@{}
    foreach ($entry in Get-CBEmailCatalog) { $out[$entry.key] = Get-CBEmailDefault -Key $entry.key }
    return $out
}

function ConvertTo-CBSanitisedEmails {
    <#
    .SYNOPSIS
        Validates stored templates against the catalogue: unknown keys are
        dropped, missing ones fall back to the default, HTML is stripped of
        script/handlers, and everything is length-capped.
    #>
    [CmdletBinding()] param([AllowNull()]$Raw)
    $out = [ordered]@{}
    foreach ($entry in Get-CBEmailCatalog) {
        $default = Get-CBEmailDefault -Key $entry.key
        $incoming = if ($Raw) { $Raw.$($entry.key) } else { $null }
        if (-not $incoming) { $out[$entry.key] = $default; continue }

        $subject = ConvertTo-CBBoundedString -Value $incoming.subject -MaxLength 200 -Default $default.subject
        $html = ConvertTo-CBSafeHtml -Html "$($incoming.html)"
        if ($html.Length -gt 40000) { $html = $html.Substring(0, 40000) }
        if (-not $html.Trim()) { $html = $default.html }

        $out[$entry.key] = [ordered]@{
            enabled       = ConvertTo-CBBool -Value $incoming.enabled -Default ([bool]$default.enabled)
            subject       = $subject
            html          = $html
            useBrandShell = ConvertTo-CBBool -Value $incoming.useBrandShell -Default $true
        }
    }
    return $out
}

function Get-CBTokenValue {
    <#
    .SYNOPSIS
        Looks a dotted token path up in a nested hashtable/object bag.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Bag, [Parameter(Mandatory)][string]$Path)
    $node = $Bag
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node) { return $null }
        if ($node -is [System.Collections.IDictionary]) { $node = $node[$part] }
        elseif ($node.PSObject.Properties[$part]) { $node = $node.PSObject.Properties[$part].Value }
        else { return $null }
    }
    return $node
}

function Expand-CBTemplate {
    <#
    .SYNOPSIS
        Substitutes {{tokens}} in a template string from a value bag.
    .DESCRIPTION
        Values are HTML-encoded, so no token value can inject markup even when it
        came from an external party (a guest's display name is attacker-supplied
        text). Tokens the caller did not supply render as an empty string rather
        than leaving {{token}} visible in somebody's inbox; the editor flags them
        so an admin sees the mistake before it ships.
    .PARAMETER Raw
        Do not HTML-encode anything. Only for building a subject line.
    .PARAMETER HtmlToken
        The few token paths whose value is markup the TOOL built and has already
        encoded the contents of, listed per template in the catalogue as
        'htmlTokens'. Everything else is encoded, and this list is deliberately
        narrow and declared rather than inferred: a token that carries markup is
        an exception, and an exception nobody can see in the catalogue is how
        encoding quietly stops happening.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory)]$Values,
        [switch]$Raw,
        [string[]]$HtmlToken = @()
    )
    if ([string]::IsNullOrEmpty($Template)) { return '' }
    return [regex]::Replace($Template, '\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}', {
            param($m)
            $path = $m.Groups[1].Value
            $value = Get-CBTokenValue -Bag $Values -Path $path
            if ($null -eq $value) { return '' }
            if ($Raw -or ($HtmlToken -contains $path)) { return "$value" }
            return (ConvertTo-CBHtmlEncoded "$value")
        })
}

function Get-CBTemplateUnknownToken {
    <#
    .SYNOPSIS
        Tokens used in a template that the catalogue does not offer for it. The
        editor shows these so an admin never ships a mail with a silently empty
        gap in it.
    #>
    [CmdletBinding()] param([AllowEmptyString()][string]$Template, [string[]]$Allowed)
    $used = [regex]::Matches("$Template", '\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}') | ForEach-Object { $_.Groups[1].Value }
    return @($used | Where-Object { $Allowed -notcontains $_ } | Select-Object -Unique)
}

function Get-CBBrandShell {
    <#
    .SYNOPSIS
        Wraps rendered body HTML in the branded email shell: a header band in the
        primary colour with the logo, the content, and a footer.
    .PARAMETER LogoCid
        Content id of the inline logo attachment. Emails embed the logo rather
        than hotlinking it, because most clients block remote images from
        external senders.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BodyHtml,
        [Parameter(Mandatory)]$Branding,
        [string]$LogoCid
    )
    $primary = ConvertTo-CBHexColor -Value $Branding.primaryColor -Default '#0f5c8c'
    $accent  = ConvertTo-CBHexColor -Value $Branding.accentColor  -Default '#b8501f'
    $onPrimary = Get-CBReadableTextColor -Background $primary
    $onAccent  = Get-CBReadableTextColor -Background $accent
    $company = ConvertTo-CBHtmlEncoded (ConvertTo-CBBoundedString -Value $Branding.companyName -MaxLength 80 -Default 'Collaborate')

    $logo = ''
    if ($LogoCid) {
        $logo = '<img src="cid:' + $LogoCid + '" alt="' + $company + '" style="max-height:40px;max-width:220px;display:block" />'
    }
    else {
        $logo = '<span style="font-size:18px;font-weight:600;color:' + $onPrimary + '">' + $company + '</span>'
    }

    # Buttons are styled by replacing the class the templates use, so an admin
    # writing <a class="cb-button"> gets a branded button without knowing any CSS.
    $buttonStyle = "display:inline-block;padding:10px 18px;background:$accent;color:$onAccent;text-decoration:none;border-radius:4px;font-weight:600"
    $body = $BodyHtml -replace 'class="cb-button"', "style=`"$buttonStyle`""

    return @"
<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#201f1e;max-width:640px">
  <div style="background:$primary;padding:16px 20px;border-radius:6px 6px 0 0">$logo</div>
  <div style="padding:20px;border:1px solid #edebe9;border-top:none;border-radius:0 0 6px 6px">
    $body
    <hr style="border:none;border-top:1px solid #edebe9;margin:20px 0">
    <p style="color:#8a8886;font-size:12px;margin:0">Sent by $company</p>
  </div>
</div>
"@
}

function Get-CBRenderedEmail {
    <#
    .SYNOPSIS
        Renders one template into a ready-to-send subject and HTML body.
    .OUTPUTS
        @{ Enabled; Subject; Html }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)]$Values,
        $Settings,
        [string]$LogoCid
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $tpl = $Settings.emails.$Key
    if (-not $tpl) { $tpl = [pscustomobject](Get-CBEmailDefault -Key $Key) }

    # Which tokens, if any, carry markup the tool built. Declared in the
    # catalogue so the exception is visible next to the template it applies to.
    $entry = Get-CBEmailCatalog | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    $htmlTokens = @()
    if ($entry -and $entry.PSObject.Properties['htmlTokens']) { $htmlTokens = @($entry.htmlTokens) }

    $subject = ConvertTo-CBBoundedString -Value (Expand-CBTemplate -Template "$($tpl.subject)" -Values $Values -Raw) -MaxLength 250 -Default 'Collaborate'
    $body = Expand-CBTemplate -Template "$($tpl.html)" -Values $Values -HtmlToken $htmlTokens
    $html = if (ConvertTo-CBBool -Value $tpl.useBrandShell -Default $true) {
        Get-CBBrandShell -BodyHtml $body -Branding $Settings.branding -LogoCid $LogoCid
    }
    else { $body }

    return @{
        Enabled = (ConvertTo-CBBool -Value $tpl.enabled -Default $true)
        Subject = $subject
        Html    = $html
    }
}

function Get-CBSampleTokenValue {
    <#
    .SYNOPSIS
        Realistic sample values so the portal's preview and the "send a test to
        me" button show something that looks like the real message.
    #>
    [CmdletBinding()] param($Settings, [string]$RecipientName, [string]$RecipientEmail)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $expires = [DateTime]::UtcNow.AddDays(90).ToString('d MMMM yyyy')
    # Rendering a preview must never fail on infrastructure config. This is a
    # display aid, and an admin editing wording deserves to see it even on a
    # half-configured install, which is exactly when they are most likely to be
    # looking at it.
    $portalUrl = 'https://collaborate.example'
    $version = 'dev'
    try {
        $cfg = Get-CBConfig
        if ($cfg.PortalUrl) { $portalUrl = $cfg.PortalUrl }
        $version = "$($cfg.Version)"
    }
    catch { Write-Warning "Preview is using placeholder configuration: $($_.Exception.Message)" }
    return @{
        brand           = @{
            companyName = "$($Settings.branding.companyName)"
            portalUrl   = $portalUrl
        }
        servicedeskEmail = "$($Settings.notifications.servicedeskEmail)"
        guest           = @{ displayName = 'Jane Rivera'; email = 'jane.rivera@partner-example.com'; domain = 'partner-example.com' }
        owner           = @{ displayName = $(if ($RecipientName) { $RecipientName } else { 'Alex Chen' }); email = $(if ($RecipientEmail) { $RecipientEmail } else { 'alex.chen@contoso.com' }) }
        requester       = @{ displayName = 'Sam Okafor'; email = 'sam.okafor@contoso.com' }
        previousOwner   = @{ displayName = 'Alex Chen' }
        reason          = 'Reviewing the Q3 supplier proposal'
        message         = 'Could you share the proposal folder with them, or hand the account over to me?'
        expiresOn       = $expires
        deleteOn        = [DateTime]::UtcNow.AddDays(104).ToString('d MMMM yyyy')
        daysLeft        = '7'
        graceDays       = "$($Settings.expiry.graceDays)"
        lastSignIn      = [DateTime]::UtcNow.AddDays(-120).ToString('d MMMM yyyy')
        inactiveDays    = '120'
        redeemUrl       = 'https://example.invalid/redeem-link'
        shareName       = 'Q3 Supplier Proposal.docx'
        shareKind       = 'file'
        shareUrl        = 'https://example.invalid/shared-item'
        sharedBy        = @{ displayName = 'Alex Chen'; email = 'alex.chen@contoso.com' }
        orphanCount     = '3'
        orphanList      = 'jane.rivera@partner-example.com, li.wei@vendor-example.com, m.dubois@agency-example.com'
        problemCount    = '2'
        problemList     = '<ul><li><strong>Problem: GuestScanner has not run for 51 hours</strong><br>Expected at least every 48 hours.</li>' +
                          '<li><strong>Note: Simulation mode is still on</strong><br>Collaborate is logging what it would do and changing nothing.</li></ul>'
        currentVersion  = $version
        latestVersion   = '1.2.0'
        releasesUrl     = 'https://github.com/jflieben/Collaborate'
    }
}
