# What the portal needs to render itself.
#
# The client is deliberately thin: it asks the API who the user is, what they may
# do, and what warnings to show, then renders that. Any rule that decides access
# is evaluated here (and again on the endpoint that performs the action), never
# in the browser.

function Get-CBPortalBanner {
    <#
    .SYNOPSIS
        Site-wide notices shown on every view: simulation mode, a storm-guard
        pause, setup not finished. Ordered most urgent first.
    #>
    [CmdletBinding()] param($Settings, $Caller)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $banners = [System.Collections.Generic.List[object]]::new()

    $safety = $null
    try { $safety = Get-CBSafetyStatus -Settings $Settings } catch { }
    if ($safety -and $safety.paused) {
        $banners.Add([ordered]@{
                id       = 'paused'
                level    = 'error'
                title    = 'Processing is paused'
                message  = "$($safety.pausedReason)"
                action   = $(if ($Caller -and $Caller.IsAdmin) { 'resume' } else { '' })
                actionLabel = 'Review and resume'
            })
    }

    if ($Settings.dryRun) {
        $banners.Add([ordered]@{
                id      = 'simulation'
                level   = 'warning'
                title   = 'Simulation mode is on'
                message = 'Collaborate is logging what it would do but changing nothing and sending no mail. Turn it off in Configuration when you are ready to go live.'
            })
    }

    if (-not $Settings.setupComplete) {
        $banners.Add([ordered]@{
                id      = 'setup'
                level   = 'warning'
                title   = 'Setup is not finished'
                message = 'An administrator still needs to complete the setup wizard.'
            })
    }

    # Least urgent, and admins only: an ordinary employee can do nothing about a
    # new release and does not need telling.
    try {
        $update = Get-CBVersionBanner -Caller $Caller
        if ($update) { $banners.Add($update) }
    }
    catch { Write-Warning "Could not read the version state: $($_.Exception.Message)" }

    return @($banners)
}

function Get-CBMePayload {
    <#
    .SYNOPSIS
        The single call the portal makes on load: identity, rights, capabilities,
        live branding and any banners.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $cfg = Get-CBConfig
    $canInvite = Test-CBCanInvite -Caller $Caller -Settings $Settings

    return [ordered]@{
        user          = [ordered]@{
            id          = $Caller.Oid
            displayName = $Caller.DisplayName
            email       = $Caller.Upn
            isAdmin     = [bool]$Caller.IsAdmin
        }
        canInvite     = [ordered]@{ allowed = [bool]$canInvite.Allowed; reason = "$($canInvite.Reason)" }
        capabilities  = [ordered]@{
            shareFiles   = [bool]$Settings.sharing.files
            shareFolders = [bool]$Settings.sharing.folders
            shareTeams   = [bool]$Settings.sharing.teams
            allowWrite   = [bool]$Settings.sharing.allowWrite
            defaultRole  = "$($Settings.sharing.defaultRole)"
        }
        policy        = [ordered]@{
            defaultDays    = [int]$Settings.expiry.defaultDays
            maxDays        = [int]$Settings.expiry.maxDays
            renewDays      = [int]$Settings.expiry.renewDays
            graceDays      = [int]$Settings.expiry.graceDays
            allowSelfRenew = [bool]$Settings.expiry.allowSelfRenew
            requireReason  = [bool]$Settings.invite.requireReason
        }
        branding      = [ordered]@{
            companyName    = "$($Settings.branding.companyName)"
            portalTitle    = "$($Settings.branding.portalTitle)"
            portalSubtitle = "$($Settings.branding.portalSubtitle)"
            primaryColor   = "$($Settings.branding.primaryColor)"
            accentColor    = "$($Settings.branding.accentColor)"
            logoUrl        = (Get-CBPublicLogoUrl -Settings $Settings)
        }
        # Whether the portal can show a "last active" column at all. It needs
        # Entra ID P1 or P2, so the answer is a property of the tenant rather
        # than of the user, and the client is told rather than left to work out
        # why a column is empty.
        signInData    = (Get-CBSignInDataPayload)
        # Tenant-wide SharePoint sharing. Shown so nobody walks the whole picker
        # to be refused at the end. Per-site blocks are not readable through
        # Graph and still only surface when a share is attempted.
        sharingPolicy = (Get-CBSharingPolicyPayload -Settings $Settings)
        setupComplete = [bool]$Settings.setupComplete
        simulation    = [bool]$Settings.dryRun
        banners       = @(Get-CBPortalBanner -Settings $Settings -Caller $Caller)
        version       = $cfg.Version
        portalUrl     = $cfg.PortalUrl
    }
}

function Get-CBAdminAccessPayload {
    <#
    .SYNOPSIS
        Which enterprise application this runs on, and who holds the
        Collaborate.Admin role on it. Read-only, for reference.
    .DESCRIPTION
        Read live from Entra rather than from something stamped at deploy time.
        An admin group recorded at install and shown forever is worse than not
        showing one: it is right on day one and quietly wrong the first time
        somebody assigns the role to a different group, which is exactly when a
        person is looking this up.

        Every failure is caught and reported as a note. This is reference
        information on a page that must still load without it.
    .OUTPUTS
        @{ app; role; assignments; error }
    #>
    [CmdletBinding()] param()
    $cfg = Get-CBConfig
    $empty = [ordered]@{
        app = [ordered]@{ appId = "$($cfg.AdminClientId)"; objectId = ''; displayName = ''; portalUrl = '' }
        role = 'Collaborate.Admin'
        assignments = @()
        error = ''
    }
    if (-not $cfg.AdminClientId) {
        $empty.error = 'No portal application is configured (CB_ADMIN_CLIENT_ID).'
        return $empty
    }

    try {
        $appId = ConvertTo-CBGraphPathSegment -Value $cfg.AdminClientId -What 'application id'
        $sp = Invoke-CBGraph -Uri ("/servicePrincipals(appId='$appId')?`$select=id,displayName,appId,appRoles")
        if (-not $sp.id) {
            $empty.error = 'The portal application could not be found in this tenant.'
            return $empty
        }
        $empty.app.objectId = "$($sp.id)"
        $empty.app.displayName = "$($sp.displayName)"
        $empty.app.portalUrl = "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/$($sp.id)/appId/$($sp.appId)"

        # The role id is looked up rather than hard-coded: it is generated per
        # app registration, so a constant would work on one install and silently
        # match nothing on the next.
        $roleId = ''
        foreach ($r in @($sp.appRoles)) { if ("$($r.value)" -eq 'Collaborate.Admin') { $roleId = "$($r.id)"; break } }

        $assigned = @((Invoke-CBGraph -Uri ("/servicePrincipals/$($sp.id)/appRoleAssignedTo?`$select=principalId,principalDisplayName,principalType,appRoleId&`$top=100")).value)
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($a in $assigned) {
            if ($roleId -and "$($a.appRoleId)" -ne $roleId) { continue }
            $type = "$($a.principalType)"
            $out.Add([ordered]@{
                    id          = "$($a.principalId)"
                    displayName = "$($a.principalDisplayName)"
                    type        = $type
                    portalUrl   = $(if ($type -eq 'Group') {
                            "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupDetailsMenuBlade/~/Overview/groupId/$($a.principalId)"
                        }
                        else { "https://entra.microsoft.com/#view/Microsoft_AAD_IAM/UserDetailsMenuBlade/~/overview/userId/$($a.principalId)" })
                })
        }
        $empty.assignments = @($out)
        if ($out.Count -eq 0) {
            $empty.error = 'Nobody holds the administrator role on this application yet. Assign a group to Collaborate.Admin in Entra, or re-run the deployment with -AdminGroupName.'
        }
        return $empty
    }
    catch {
        Write-Warning "Could not read the administrator assignments: $($_.Exception.Message)"
        $empty.error = "The administrator assignments could not be read: $($_.Exception.Message)"
        return $empty
    }
}

function Get-CBSharingPolicyPayload {
    <#
    .SYNOPSIS
        What SharePoint's tenant settings mean for the sharing cards.
    .OUTPUTS
        @{ known; allowsExternal; capability; note }
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    if (-not $Settings.sharing.files -and -not $Settings.sharing.folders) {
        return [ordered]@{ known = $false; allowsExternal = $true; capability = ''; note = '' }
    }
    $policy = @{ Known = $false; AllowsExternal = $true; Capability = '' }
    try { $policy = Get-CBTenantSharingPolicy } catch { Write-Warning "Could not read the sharing policy: $($_.Exception.Message)" }
    return [ordered]@{
        known          = [bool]$policy.Known
        allowsExternal = [bool]$policy.AllowsExternal
        capability     = "$($policy.Capability)"
        note           = $(if ($policy.Known -and -not $policy.AllowsExternal) {
                'External sharing is switched off for the whole tenant in SharePoint, so files and folders cannot be shared outside the company. A SharePoint administrator sets this.'
            }
            else { '' })
    }
}

function Get-CBSignInDataPayload {
    <#
    .SYNOPSIS
        What the portal should say about last-active data: whether it is
        available, when it was last read, and one sentence for when it is not.
    #>
    [CmdletBinding()] param()
    $state = @{ Available = $false; CheckedAt = ''; Error = '' }
    try { $state = Get-CBSignInDataState } catch { Write-Warning "Could not read the sign-in data state: $($_.Exception.Message)" }

    $note = ''
    if (-not $state.Available) {
        $note = if (-not $state.CheckedAt) {
            'Last-active data has not been read yet. It appears after the first daily scan, or when an administrator refreshes from Entra.'
        }
        else {
            'Entra is not supplying sign-in times for this tenant. That needs an Entra ID P1 or P2 licence.'
        }
    }
    return [ordered]@{
        available = [bool]$state.Available
        checkedAt = "$($state.CheckedAt)"
        checkedAtLabel = $(if ($state.CheckedAt) { Format-CBFriendlyDate -Value $state.CheckedAt } else { '' })
        note      = $note
    }
}

function Get-CBPublicLogoUrl {
    <#
    .SYNOPSIS
        Absolute URL of the logo on the public site, or empty when none is set.
        The portal shows the same image as the welcome page and the emails, so a
        change is visible everywhere at once.
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $cfg = Get-CBConfig
    if (-not $Settings.branding.logoFile -or -not $cfg.PublicSiteUrl) { return '' }
    return ('{0}/assets/{1}' -f $cfg.PublicSiteUrl.TrimEnd('/'), $Settings.branding.logoFile)
}

function Get-CBAdminConfigPayload {
    <#
    .SYNOPSIS
        Everything the admin console edits, plus the catalogues it renders its
        editors from, so the UI can never offer a setting or a token the runtime
        does not know about.
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $cfg = Get-CBConfig

    $catalog = @(Get-CBEmailCatalog | ForEach-Object {
            $unknown = @(Get-CBTemplateUnknownToken -Template ("$($Settings.emails.$($_.key).subject) $($Settings.emails.$($_.key).html)") -Allowed $_.tokens)
            [ordered]@{
                key           = $_.key
                label         = $_.label
                audience      = $_.audience
                description   = $_.description
                tokens        = @($_.tokens)
                unknownTokens = @($unknown)
            }
        })

    return [ordered]@{
        settings      = $Settings
        emailCatalog  = $catalog
        warnings      = @(Get-CBSettingsWarning -Settings $Settings)
        welcomeUrl    = $cfg.PublicSiteUrl
        allowedHosts  = (Get-CBWelcomeAllowedHost -Settings $Settings)
        expiryAttributes = @(1..15 | ForEach-Object { "extensionAttribute$_" })
        version       = $cfg.Version
        # The mailbox everything is SENT FROM, which is not a setting and cannot
        # become one: the managed identity is authorised for this one mailbox
        # through an Exchange management scope created at deploy time. Shown so
        # nobody mistakes the service desk address (a recipient) for it, and so
        # the way to change it is in front of whoever wants to.
        sender        = [ordered]@{
            address  = $cfg.SenderUpn
            editable = $false
            note     = 'Reminders, expiry notices and digests are sent from here, and so is anything a browser could not send. Invitations come from whoever created them. Permission to send is scoped to this one mailbox in Exchange Online, so changing it means re-running the deployment, which is idempotent and safe against an existing install.'
            docsUrl  = $cfg.ReleasesUrl
        }
        # Who administers this install, read live from Entra rather than from a
        # value stamped at deploy time that would quietly go stale.
        adminAccess   = (Get-CBAdminAccessPayload)
    }
}
