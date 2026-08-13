# Behavioural settings: everything an administrator can change, stored as a JSON
# blob (config.json) so edits take effect without a redeploy.
#
# Admins never touch this blob. They edit it in the portal; this file defines the
# shape, the shipped defaults, and the sanitiser that both the read and the save
# path run, so a hand-crafted request cannot store a value the UI would refuse.
#
# The sanitiser is pure (no Graph, no storage), which is what makes the whole
# validation surface unit testable.

function Get-CBDefaultSettings {
    <#
    .SYNOPSIS
        The settings a brand-new install starts with, before the setup wizard has
        run. Deliberately cautious: simulation on, sharing off, cleanup off.
    #>
    [CmdletBinding()] param()

    $servicedesk = "$([Environment]::GetEnvironmentVariable('CB_SERVICEDESK_EMAIL'))".Trim()
    $company = "$([Environment]::GetEnvironmentVariable('CB_COMPANY_NAME'))".Trim()
    if (-not $company) { $company = 'Collaborate' }

    return [ordered]@{
        setupComplete     = $false
        setupCompletedUtc = ''
        setupCompletedBy  = ''

        # Simulation: read everything, change nothing. A new install starts here
        # so the first scan of a real tenant can never act on anybody.
        dryRun            = $true

        branding          = [ordered]@{
            companyName     = $company
            portalTitle     = 'External collaborators'
            portalSubtitle  = 'Invite and manage the people you work with outside the company'
            primaryColor    = '#0f5c8c'
            accentColor     = '#b8501f'
            logoFile        = ''
            logoContentType = ''
            logoUpdatedUtc  = ''
        }

        expiry            = [ordered]@{
            # How long access lasts, and the bounds a user may choose within.
            defaultDays   = 90
            maxDays       = 365
            renewDays     = 90
            # After expiry the account is blocked, not deleted, for this long.
            graceDays     = 14
            # Where the expiry date is written on the guest object itself, so it
            # survives this tool and can drive dynamic groups or Conditional Access.
            attribute     = 'extensionAttribute15'
            # Days before expiry at which the owner is reminded.
            reminderDays  = @(30, 7, 1)
            allowSelfRenew = $true
            # 0 = unlimited renewals.
            maxRenewals   = 0
        }

        invite            = [ordered]@{
            # Empty = every internal member may invite. Set a group to restrict it.
            inviterGroupId           = ''
            inviterGroupName         = ''
            requireReason            = $true
            # Empty allow list = any domain except the blocked ones.
            allowedDomains           = @()
            blockedDomains           = @()
            allowCoOwnership         = $true
            # 'all' lets an employee find any existing guest when sharing (and see
            # who owns them, so they ask rather than duplicate). 'owned' limits the
            # search to their own guests.
            guestDirectoryVisibility = 'all'
            # Also record the inviter as the guest's native Entra sponsor.
            setSponsor               = $true
        }

        sharing           = [ordered]@{
            files       = $true
            folders     = $true
            teams       = $true
            defaultRole = 'read'
            allowWrite  = $true
        }

        # Guests that predate the tool, or whose owner has left. Adoption gives
        # them an owner and an end date so they stop being invisible.
        adoption          = [ordered]@{
            enabled     = $true
            # Entra's own sponsor field first, then the invitation audit log.
            # Neither is guaranteed, which is what the orphan partition is for.
            useSponsors = $true
            useAuditLog = $true
            # An adopted guest's end date is counted from TODAY, never from when
            # they were created. Adopting a three-year-old guest and expiring
            # them the same afternoon would be a spectacular way to break a
            # tenant on the first run.
            initialDays = 90
        }

        inactivity        = [ordered]@{
            enabled       = $false
            thresholdDays = 180
            # notify = tell the owner only; block = also end their access; delete
            # = the same, and let the grace period remove them. Nothing here
            # deletes in one step.
            action        = 'notify'
            # Only warn the owner once per guest, however many times the scan runs.
            notifyOnce    = $true
        }

        welcome           = [ordered]@{
            headline          = 'You are in.'
            message           = 'Your invitation has been accepted. You can now work with us on the items that have been shared with you.'
            buttonLabel       = 'Open what was shared with you'
            autoRedirect      = $false
            extraAllowedHosts = @()
            publishedHash     = ''
            publishedUtc      = ''
        }

        safety            = (Get-CBDefaultSafetySettings)

        notifications     = [ordered]@{
            servicedeskEmail   = $servicedesk
            notifyOwnerOnRedeem = $true
            orphanDigest       = $true
            versionCheckNotify = $true
        }

        logRetentionDays  = 365
        emails            = (Get-CBEmailDefaults)
    }
}

function Get-CBDefaultSafetySettings {
    <#
    .SYNOPSIS
        Circuit-breaker defaults. Per-action daily caps plus a percent-of-guest
        population ceiling. 0 for a cap means "no numeric cap" (the percent
        ceiling still applies).
    #>
    [CmdletBinding()] param()
    return [ordered]@{
        enabled            = $true
        dailyCapInvite     = 100
        dailyCapBlock      = 100
        dailyCapDelete     = 50
        percentCeiling     = 20
        perUserDailyInvites = 10
    }
}

function ConvertTo-CBSanitisedSafetySettings {
    [CmdletBinding()] param([AllowNull()]$Raw)
    $def = Get-CBDefaultSafetySettings
    return [ordered]@{
        enabled             = ConvertTo-CBBool -Value $Raw.enabled -Default $true
        dailyCapInvite      = ConvertTo-CBInt -Value $Raw.dailyCapInvite      -Default $def.dailyCapInvite      -Min 0 -Max 1000000
        dailyCapBlock       = ConvertTo-CBInt -Value $Raw.dailyCapBlock       -Default $def.dailyCapBlock       -Min 0 -Max 1000000
        dailyCapDelete      = ConvertTo-CBInt -Value $Raw.dailyCapDelete      -Default $def.dailyCapDelete      -Min 0 -Max 1000000
        percentCeiling      = ConvertTo-CBInt -Value $Raw.percentCeiling      -Default $def.percentCeiling      -Min 0 -Max 100
        perUserDailyInvites = ConvertTo-CBInt -Value $Raw.perUserDailyInvites -Default $def.perUserDailyInvites -Min 0 -Max 10000
    }
}

function ConvertTo-CBReminderDays {
    <#
    .SYNOPSIS
        Normalises the reminder steps: whole days between 1 and MaxDays, unique,
        in descending order (furthest-out reminder first), capped at 5 steps so a
        pasted list cannot mail somebody every day for a year.
    .PARAMETER MaxDays
        The longest access the policy allows. A reminder further out than that
        could never fire, so it is dropped here rather than sitting in the config
        looking configured.
    #>
    [CmdletBinding()] param([AllowNull()]$Value, [int[]]$Default = @(30, 7, 1), [int]$MaxDays = 365)
    if ($MaxDays -lt 1) { $MaxDays = 1 }
    $days = [System.Collections.Generic.List[int]]::new()
    foreach ($item in @($Value)) {
        $n = 0
        if (-not [int]::TryParse("$item", [ref]$n)) { continue }
        if ($n -lt 1 -or $n -gt $MaxDays) { continue }
        if (-not $days.Contains($n)) { $days.Add($n) }
    }
    if ($days.Count -eq 0) {
        $fallback = @($Default | Where-Object { $_ -ge 1 -and $_ -le $MaxDays })
        if ($fallback.Count -eq 0) { $fallback = @($MaxDays) }
        return , ([int[]]$fallback)
    }
    return , ([int[]]@($days | Sort-Object -Descending | Select-Object -First 5))
}

function Test-CBExpiryAttributeName {
    <#
    .SYNOPSIS
        Only extensionAttribute1..15 are writable on a cloud-only user, so only
        those are accepted.
    #>
    [CmdletBinding()] param([string]$Name)
    return ("$Name".Trim() -match '^extensionAttribute(1[0-5]|[1-9])$')
}

function ConvertTo-CBSanitisedSettings {
    <#
    .SYNOPSIS
        Validates and normalises a raw settings object. Every value is clamped,
        every list is bounded, every colour is a real colour, and every email
        template is checked against the catalogue. Returns an ordered hashtable
        that is safe to persist and safe to act on.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Raw)

    $def = Get-CBDefaultSettings

    # --- Branding ------------------------------------------------------------
    $b = $Raw.branding
    $branding = [ordered]@{
        companyName     = ConvertTo-CBBoundedString -Value $b.companyName    -MaxLength 80  -Default $def.branding.companyName
        portalTitle     = ConvertTo-CBBoundedString -Value $b.portalTitle    -MaxLength 60  -Default $def.branding.portalTitle
        portalSubtitle  = ConvertTo-CBBoundedString -Value $b.portalSubtitle -MaxLength 160 -Default $def.branding.portalSubtitle
        primaryColor    = ConvertTo-CBHexColor -Value $b.primaryColor -Default $def.branding.primaryColor
        accentColor     = ConvertTo-CBHexColor -Value $b.accentColor  -Default $def.branding.accentColor
        # The logo file name is generated by the upload path, never accepted from
        # a client verbatim: a caller-controlled name would let a request point
        # the public page at an arbitrary blob.
        logoFile        = ConvertTo-CBBoundedString -Value $b.logoFile -MaxLength 80 -Default ''
        logoContentType = ConvertTo-CBBoundedString -Value $b.logoContentType -MaxLength 40 -Default ''
        logoUpdatedUtc  = ConvertTo-CBBoundedString -Value $b.logoUpdatedUtc -MaxLength 40 -Default ''
    }
    if ($branding.logoFile -notmatch '^[a-z0-9][a-z0-9._-]{0,79}$') { $branding.logoFile = '' }
    if ($branding.logoContentType -notin @('image/png', 'image/jpeg')) { $branding.logoContentType = '' }
    if (-not $branding.logoFile) { $branding.logoContentType = ''; $branding.logoUpdatedUtc = '' }

    # --- Expiry --------------------------------------------------------------
    $e = $Raw.expiry
    $maxDays = ConvertTo-CBInt -Value $e.maxDays -Default $def.expiry.maxDays -Min 1 -Max 3650
    $expiry = [ordered]@{
        defaultDays    = ConvertTo-CBInt -Value $e.defaultDays -Default $def.expiry.defaultDays -Min 1 -Max $maxDays
        maxDays        = $maxDays
        renewDays      = ConvertTo-CBInt -Value $e.renewDays -Default $def.expiry.renewDays -Min 1 -Max $maxDays
        graceDays      = ConvertTo-CBInt -Value $e.graceDays -Default $def.expiry.graceDays -Min 0 -Max 365
        attribute      = "$($e.attribute)".Trim()
        reminderDays   = (ConvertTo-CBReminderDays -Value $e.reminderDays -Default $def.expiry.reminderDays -MaxDays $maxDays)
        allowSelfRenew = ConvertTo-CBBool -Value $e.allowSelfRenew -Default $true
        maxRenewals    = ConvertTo-CBInt -Value $e.maxRenewals -Default $def.expiry.maxRenewals -Min 0 -Max 1000
    }
    if (-not (Test-CBExpiryAttributeName -Name $expiry.attribute)) { $expiry.attribute = $def.expiry.attribute }

    # --- Invitation ----------------------------------------------------------
    $i = $Raw.invite
    $visibility = "$($i.guestDirectoryVisibility)".Trim().ToLowerInvariant()
    if ($visibility -notin @('all', 'owned')) { $visibility = $def.invite.guestDirectoryVisibility }
    $invite = [ordered]@{
        inviterGroupId           = ConvertTo-CBBoundedString -Value $i.inviterGroupId -MaxLength 40 -Default ''
        inviterGroupName         = ConvertTo-CBBoundedString -Value $i.inviterGroupName -MaxLength 200 -Default ''
        requireReason            = ConvertTo-CBBool -Value $i.requireReason -Default $true
        allowedDomains           = (ConvertTo-CBDomainList -Value $i.allowedDomains)
        blockedDomains           = (ConvertTo-CBDomainList -Value $i.blockedDomains)
        allowCoOwnership         = ConvertTo-CBBool -Value $i.allowCoOwnership -Default $true
        guestDirectoryVisibility = $visibility
        setSponsor               = ConvertTo-CBBool -Value $i.setSponsor -Default $true
    }
    # An id that is not a GUID is meaningless and would fail every membership
    # check, so drop the pair rather than silently restricting everybody.
    if ($invite.inviterGroupId -notmatch '^[0-9a-fA-F-]{36}$') { $invite.inviterGroupId = ''; $invite.inviterGroupName = '' }

    # --- Sharing -------------------------------------------------------------
    $s = $Raw.sharing
    $role = "$($s.defaultRole)".Trim().ToLowerInvariant()
    if ($role -notin @('read', 'write')) { $role = $def.sharing.defaultRole }
    $sharing = [ordered]@{
        files       = ConvertTo-CBBool -Value $s.files   -Default $true
        folders     = ConvertTo-CBBool -Value $s.folders -Default $true
        teams       = ConvertTo-CBBool -Value $s.teams   -Default $true
        allowWrite  = ConvertTo-CBBool -Value $s.allowWrite -Default $true
        defaultRole = $role
    }
    # Offering 'write' as the default while write sharing is switched off would
    # be a contradiction the UI could not honour.
    if (-not $sharing.allowWrite) { $sharing.defaultRole = 'read' }

    # --- Adoption ------------------------------------------------------------
    $a = $Raw.adoption
    $adoption = [ordered]@{
        enabled     = ConvertTo-CBBool -Value $a.enabled -Default $true
        useSponsors = ConvertTo-CBBool -Value $a.useSponsors -Default $true
        useAuditLog = ConvertTo-CBBool -Value $a.useAuditLog -Default $true
        # A 7-day floor: adopting a guest and giving them less than a week before
        # the first reminder fires is not a runway, it is an ambush.
        initialDays = ConvertTo-CBInt -Value $a.initialDays -Default $def.adoption.initialDays -Min 7 -Max $maxDays
    }

    # --- Inactivity ----------------------------------------------------------
    $n = $Raw.inactivity
    $action = "$($n.action)".Trim().ToLowerInvariant()
    if ($action -notin @('notify', 'block', 'delete')) { $action = $def.inactivity.action }
    $inactivity = [ordered]@{
        enabled       = ConvertTo-CBBool -Value $n.enabled -Default $false
        # 30-day floor: anything shorter would act on people who are simply on
        # leave, and sign-in data itself lags.
        thresholdDays = ConvertTo-CBInt -Value $n.thresholdDays -Default $def.inactivity.thresholdDays -Min 30 -Max 3650
        action        = $action
        notifyOnce    = ConvertTo-CBBool -Value $n.notifyOnce -Default $true
    }

    # --- Welcome page --------------------------------------------------------
    $w = $Raw.welcome
    $welcome = [ordered]@{
        headline          = ConvertTo-CBBoundedString -Value $w.headline -MaxLength 80 -Default $def.welcome.headline
        message           = ConvertTo-CBBoundedString -Value $w.message -MaxLength 600 -Default $def.welcome.message -AllowNewLines
        buttonLabel       = ConvertTo-CBBoundedString -Value $w.buttonLabel -MaxLength 60 -Default $def.welcome.buttonLabel
        autoRedirect      = ConvertTo-CBBool -Value $w.autoRedirect -Default $false
        extraAllowedHosts = (ConvertTo-CBHostList -Value $w.extraAllowedHosts)
        publishedHash     = ConvertTo-CBBoundedString -Value $w.publishedHash -MaxLength 64 -Default ''
        publishedUtc      = ConvertTo-CBBoundedString -Value $w.publishedUtc -MaxLength 40 -Default ''
    }

    # --- Notifications -------------------------------------------------------
    $notif = $Raw.notifications
    $servicedesk = ConvertTo-CBBoundedString -Value $notif.servicedeskEmail -MaxLength 200 -Default $def.notifications.servicedeskEmail
    if (-not (Test-CBEmailAddress -Address $servicedesk)) { $servicedesk = '' }
    $notifications = [ordered]@{
        servicedeskEmail    = $servicedesk
        notifyOwnerOnRedeem = ConvertTo-CBBool -Value $notif.notifyOwnerOnRedeem -Default $true
        orphanDigest        = ConvertTo-CBBool -Value $notif.orphanDigest -Default $true
        versionCheckNotify  = ConvertTo-CBBool -Value $notif.versionCheckNotify -Default $true
    }

    return [ordered]@{
        setupComplete     = ConvertTo-CBBool -Value $Raw.setupComplete -Default $false
        setupCompletedUtc = ConvertTo-CBBoundedString -Value $Raw.setupCompletedUtc -MaxLength 40 -Default ''
        setupCompletedBy  = ConvertTo-CBBoundedString -Value $Raw.setupCompletedBy -MaxLength 200 -Default ''
        dryRun            = ConvertTo-CBBool -Value $Raw.dryRun -Default $true
        branding          = $branding
        expiry            = $expiry
        invite            = $invite
        sharing           = $sharing
        adoption          = $adoption
        inactivity        = $inactivity
        welcome           = $welcome
        safety            = (ConvertTo-CBSanitisedSafetySettings -Raw $Raw.safety)
        notifications     = $notifications
        logRetentionDays  = ConvertTo-CBInt -Value $Raw.logRetentionDays -Default 365 -Min 7 -Max 3650
        emails            = (ConvertTo-CBSanitisedEmails -Raw $Raw.emails)
    }
}

function Get-CBSettingsWarning {
    <#
    .SYNOPSIS
        Advisory findings about a settings object: things that are legal but
        probably not what the admin meant. The portal shows these next to the
        field; nothing here blocks a save.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Settings)
    $warnings = [System.Collections.Generic.List[object]]::new()

    foreach ($pair in @(
            @{ field = 'branding.primaryColor'; colour = "$($Settings.branding.primaryColor)"; what = 'the header band' },
            @{ field = 'branding.accentColor';  colour = "$($Settings.branding.accentColor)";  what = 'buttons' }
        )) {
        $best = [Math]::Max(
            (Get-CBContrastRatio -Foreground '#ffffff' -Background $pair.colour),
            (Get-CBContrastRatio -Foreground '#1b1b1b' -Background $pair.colour))
        if ($best -lt 4.5) {
            $warnings.Add(@{
                field   = $pair.field
                message = "Text on $($pair.what) will be hard to read (contrast $best:1, WCAG AA wants 4.5:1). Pick a darker or lighter colour."
            })
        }
    }

    # A brand colour does two opposite jobs: it is painted BEHIND things (the
    # header band, where the text on top is chosen for contrast), and it is used
    # AS text for links, the active tab and the wizard steps. The second needs
    # the colour to be readable on the page's own background, and a colour light
    # enough to sit behind a logo with dark lettering is far too light for that.
    # The portal derives a darker one, and an administrator who picked a colour
    # and got a slightly different one should be told why rather than left to
    # wonder.
    $pageBackground = '#f3f2f1'
    if ((Get-CBContrastRatio -Foreground "$($Settings.branding.primaryColor)" -Background $pageBackground) -lt 4.5 -and
        (Get-CBContrastRatio -Foreground "$($Settings.branding.accentColor)" -Background $pageBackground) -lt 4.5) {
        $warnings.Add(@{
                field   = 'branding.primaryColor'
                message = 'Neither colour is dark enough to read as text on the page, so links and tabs use a darkened version rather than your exact colour. Make the main or accent colour darker if you want them on brand.'
            })
    }

    if ($Settings.expiry.graceDays -eq 0) {
        $warnings.Add(@{ field = 'expiry.graceDays'; message = 'With no grace period, guests are deleted the moment they expire and cannot be restored. Consider at least a few days.' })
    }
    if (-not $Settings.safety.enabled) {
        $warnings.Add(@{ field = 'safety.enabled'; message = 'The storm guard is off, so nothing limits how many guests can be blocked or deleted in one day.' })
    }
    if ($Settings.inactivity.enabled -and $Settings.inactivity.action -eq 'delete' -and $Settings.dryRun -eq $false) {
        $warnings.Add(@{ field = 'inactivity.action'; message = 'Inactive guests will be deleted automatically. Watch the activity log for a few cycles before relying on this.' })
    }
    if ($Settings.sharing.files -or $Settings.sharing.folders -or $Settings.sharing.teams) {
        if (-not $Settings.notifications.servicedeskEmail) {
            $warnings.Add(@{ field = 'notifications.servicedeskEmail'; message = 'No service desk address is set, so nobody is told about unowned guests or health problems.' })
        }
    }
    return @($warnings)
}

# --- Storage -----------------------------------------------------------------

function Get-CBSettings {
    <#
    .SYNOPSIS
        The current settings, read from the blob and always sanitised.
    .DESCRIPTION
        There is deliberately NO CACHE here. There used to be one, per worker for
        60 seconds, and it was wrong: the app runs on several instances, a save
        invalidates only the worker that handled it, and every other worker then
        served stale settings. The visible symptom was turning simulation mode
        off, watching the banner stay, refreshing, and finding the setting back
        on. The invisible symptom was worse: an invitation created against a
        policy the administrator had already changed.

        Caching would only be worth having in a loop, and there is no such loop:
        every background job reads the settings once and passes them down through
        -Settings. So this is one blob GET per request, against several calls to
        Graph and to table storage in the same request.
    .NOTES
        A MISSING blob means a brand-new install and yields the shipped defaults.
        A FAILED read throws, because silently presenting the defaults would show
        an operator a configuration nobody chose, and would look exactly like
        their settings had reverted.
    #>
    [CmdletBinding()] param()
    $text = Get-CBBlobText -Name (Get-CBSettingsBlobName)
    $raw = $null
    if ($text) {
        try { $raw = $text | ConvertFrom-Json }
        catch { throw "The settings blob exists but is not valid JSON, so Collaborate will not guess at its configuration: $($_.Exception.Message)" }
    }
    if (-not $raw) { $raw = [pscustomobject](Get-CBDefaultSettings) }
    return [pscustomobject](ConvertTo-CBSanitisedSettings -Raw $raw)
}

function Save-CBSettings {
    <#
    .SYNOPSIS
        Sanitises and stores settings, keeping the previous version for a manual
        rollback (storage blob versioning keeps the full history; this is the
        one-file copy an operator can restore without the portal).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Raw)
    $clean = ConvertTo-CBSanitisedSettings -Raw $Raw
    try {
        $current = Get-CBBlobText -Name (Get-CBSettingsBlobName)
        if ($current) { Set-CBBlobText -Name 'config.previous.json' -Content $current }
    }
    catch { Write-Warning "Could not back up the current settings: $($_.Exception.Message)" }
    Set-CBBlobText -Name (Get-CBSettingsBlobName) -Content ($clean | ConvertTo-Json -Depth 12)
    return [pscustomobject]$clean
}

function Test-CBSettingsBlobExists {
    [CmdletBinding()] param()
    try { return ($null -ne (Get-CBBlobText -Name (Get-CBSettingsBlobName))) }
    catch { return $false }
}

function Test-CBSetupComplete {
    <#
    .SYNOPSIS
        Has the setup wizard finished? Until it has, the deploying operator keeps
        bootstrap admin rights (see Auth.ps1) and the portal shows the wizard.
        Never throws: a storage failure reads as "not complete", which is the
        safe direction (the wizard is re-runnable, and it re-tests SSO).
    #>
    [CmdletBinding()] param()
    try { return [bool](Get-CBSettings).setupComplete }
    catch { return $false }
}

function Compare-CBSettings {
    <#
    .SYNOPSIS
        Flattens two sanitised settings objects and returns only the changed
        leaves as path -> { old, new }. Every save is audited with this, so the
        activity log shows what actually changed rather than "settings saved".
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Old, [Parameter(Mandatory)]$New)

    # JSON round-trip normalises ordered hashtables and pscustomobjects into one
    # uniform object tree, so a single flattening walk covers both.
    $oldObj = $Old | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $newObj = $New | ConvertTo-Json -Depth 12 | ConvertFrom-Json

    function Get-FlatMap {
        param($Node, [string]$Prefix, [hashtable]$Map)
        foreach ($p in $Node.PSObject.Properties) {
            $path = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
            if ($p.Value -is [System.Management.Automation.PSCustomObject]) { Get-FlatMap -Node $p.Value -Prefix $path -Map $Map }
            elseif ($p.Value -is [System.Array]) { $Map[$path] = (@($p.Value) -join ', ') }
            else { $Map[$path] = "$($p.Value)" }
        }
    }
    $o = @{}; $n = @{}
    Get-FlatMap -Node $oldObj -Prefix '' -Map $o
    Get-FlatMap -Node $newObj -Prefix '' -Map $n

    $changes = [ordered]@{}
    foreach ($key in (@($o.Keys) + @($n.Keys) | Select-Object -Unique | Sort-Object)) {
        if ($o[$key] -ne $n[$key]) {
            # Email bodies are long; record that they changed, not the diff.
            if ($key -match '^emails\..*\.html$') { $changes[$key] = @{ old = '(previous body)'; new = '(new body)' } }
            else { $changes[$key] = @{ old = $o[$key]; new = $n[$key] } }
        }
    }
    return $changes
}
