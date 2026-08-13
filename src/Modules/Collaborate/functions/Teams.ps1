# Adding a guest to a Team the signed-in user owns.
#
# The add runs as the user (Invoke-CBGraphAsUser), so Graph enforces that they
# really own the Team. Nothing here decides that for it.
#
# Reading the guest POLICY is different, and uses the managed identity on
# purpose: whether a tenant or a Team accepts guests is configuration, not
# something the user is acting on, and an ordinary employee usually cannot read
# group settings at all. Reading it as the service means the picker can grey out
# a Team with an honest reason instead of letting somebody discover it by failing.

$script:CBTenantGuestPolicy = $null

function Get-CBTenantGuestPolicy {
    <#
    .SYNOPSIS
        Does this tenant allow guests in Microsoft 365 groups at all?
    .DESCRIPTION
        Lives in the 'Group.Unified' directory setting. When that setting has
        never been created the tenant is on Microsoft's defaults, which allow
        guests, so an absent setting reads as allowed. Cached per worker.
    .OUTPUTS
        @{ AllowGuests; Source }
    #>
    [CmdletBinding()] param([switch]$Refresh)
    if ($script:CBTenantGuestPolicy -and -not $Refresh) { return $script:CBTenantGuestPolicy }

    $result = @{ AllowGuests = $true; Source = 'tenant default (no Group.Unified setting configured)' }
    try {
        $settings = @((Invoke-CBGraph -Uri '/groupSettings').value)
        $unified = $settings | Where-Object { "$($_.displayName)" -eq 'Group.Unified' } | Select-Object -First 1
        if ($unified) {
            foreach ($v in @($unified.values)) {
                if ("$($v.name)" -in @('AllowToAddGuests', 'AllowGuestsToAccessGroups')) {
                    if ("$($v.value)".Trim().ToLowerInvariant() -eq 'false') {
                        $result = @{ AllowGuests = $false; Source = "the tenant-wide Group.Unified setting '$($v.name)' is off" }
                        break
                    }
                }
            }
            if ($result.AllowGuests) { $result.Source = 'the tenant-wide Group.Unified setting allows guests' }
        }
    }
    catch {
        # Unknown is treated as allowed, because Graph will refuse the add anyway
        # if it is not. Greying out every Team on a failed policy read would make
        # the feature look broken when it is not.
        Write-Warning "Could not read the tenant guest policy: $($_.Exception.Message). Assuming guests are allowed; Graph decides."
        $result.Source = 'could not be read; Graph will decide at the moment of adding'
    }
    $script:CBTenantGuestPolicy = $result
    return $result
}

function Test-CBGroupAllowsGuest {
    <#
    .SYNOPSIS
        Does this particular group accept guests?
    .DESCRIPTION
        A group may override the tenant with its own 'Group.Unified.Guest'
        setting. The tenant policy wins when it forbids guests outright; an
        absent group setting inherits.
    .OUTPUTS
        @{ Allowed; Reason }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$GroupId, $TenantPolicy)
    if (-not $TenantPolicy) { $TenantPolicy = Get-CBTenantGuestPolicy }
    if (-not $TenantPolicy.AllowGuests) {
        return @{ Allowed = $false; Reason = 'This tenant does not allow guests in Teams or groups.' }
    }
    try {
        $settings = @((Invoke-CBGraph -Uri ('/groups/' + [Uri]::EscapeDataString($GroupId) + '/settings')).value)
        foreach ($s in $settings) {
            if ("$($s.displayName)" -ne 'Group.Unified.Guest') { continue }
            foreach ($v in @($s.values)) {
                if ("$($v.name)" -eq 'AllowToAddGuests' -and "$($v.value)".Trim().ToLowerInvariant() -eq 'false') {
                    return @{ Allowed = $false; Reason = 'This Team has been set not to accept guests.' }
                }
            }
        }
    }
    catch { Write-Warning "Could not read guest settings for group ${GroupId}: $($_.Exception.Message)" }
    return @{ Allowed = $true; Reason = '' }
}

function Get-CBOwnedGroup {
    <#
    .SYNOPSIS
        Every group the signed-in user owns.
    .NOTES
        Deliberately no $select. On the /me/ownedObjects cast collection Graph
        does not reliably honour a $select that includes
        resourceProvisioningOptions: it returns the other fields and silently
        omits that one. Asking for the default representation gets it.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, [int]$Top = 200)
    return @((Invoke-CBGraphAsUser -Caller $Caller -All -Uri ('/me/ownedObjects/microsoft.graph.group?$top=' + $Top)))
}

function Get-CBOwnedTeam {
    <#
    .SYNOPSIS
        The Teams the signed-in user owns, each annotated with whether it accepts
        guests.
    .DESCRIPTION
        Working out which owned groups are Teams is fiddlier than it looks. The
        documented marker is 'Team' in resourceProvisioningOptions, but that
        property is not reliably returned for /me/ownedObjects, and when it comes
        back absent every group fails the test and the user is told they own no
        Teams while owning several.

        So the primary signal is an intersection instead: the groups they own,
        against the Teams they are in (/me/joinedTeams). An owner is always a
        member, so anything in both sets is a Team they own, and neither call
        depends on a property Graph may decline to send.

        resourceProvisioningOptions is kept as the fallback for a tenant where
        joinedTeams is unavailable, and if BOTH signals fail the groups are
        returned unfiltered rather than showing an empty list: adding a guest to
        a Team is adding them to its group, so the worst case is a few extra rows
        and Graph refusing anything that is not really a Team.
    .OUTPUTS
        @{ Teams; OwnedGroups; Detection } - the counts and which signal was used,
        so the portal can explain an empty list instead of just showing one.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, [int]$Top = 200)
    $groups = @()
    try { $groups = @(Get-CBOwnedGroup -Caller $Caller -Top $Top) }
    catch {
        Write-Warning "Could not list owned groups: $($_.Exception.Message)"
        throw
    }

    # Which of them are Teams?
    $teamIds = $null
    $detection = 'joinedTeams'
    try {
        $joined = @((Invoke-CBGraphAsUser -Caller $Caller -Uri '/me/joinedTeams').value)
        $teamIds = @{}
        foreach ($t in $joined) { if ($t.id) { $teamIds["$($t.id)"] = $true } }
    }
    catch {
        Write-Warning "Could not read joined Teams ($($_.Exception.Message)); falling back to resourceProvisioningOptions."
        $teamIds = $null
        $detection = 'resourceProvisioningOptions'
    }

    if ($null -eq $teamIds) {
        # Fallback. Only trust it if at least one group actually carries the
        # property: all of them lacking it means Graph did not send it, not that
        # none of them are Teams.
        $sawProperty = @($groups | Where-Object { $_.PSObject.Properties['resourceProvisioningOptions'] -and $null -ne $_.resourceProvisioningOptions }).Count -gt 0
        if (-not $sawProperty) { $detection = 'none' }
    }

    $tenantPolicy = Get-CBTenantGuestPolicy
    $teams = [System.Collections.Generic.List[object]]::new()
    foreach ($g in $groups) {
        $isTeam = switch ($detection) {
            'joinedTeams' { $teamIds.ContainsKey("$($g.id)") }
            'resourceProvisioningOptions' { (@($g.resourceProvisioningOptions) -contains 'Team') }
            default { $true }   # cannot tell; show it and let Graph decide
        }
        if (-not $isTeam) { continue }

        $allows = Test-CBGroupAllowsGuest -GroupId "$($g.id)" -TenantPolicy $tenantPolicy
        $teams.Add([ordered]@{
                id          = "$($g.id)"
                name        = "$($g.displayName)"
                description = (ConvertTo-CBBoundedString -Value $g.description -MaxLength 200 -Default '')
                visibility  = "$($g.visibility)"
                mail        = "$($g.mail)"
                canShare    = [bool]$allows.Allowed
                shareBlockedReason = "$($allows.Reason)"
            })
    }

    return @{
        Teams       = @($teams | Sort-Object -Property @{ Expression = { "$($_.name)" } })
        OwnedGroups = $groups.Count
        Detection   = $detection
    }
}

function Get-CBTeamSummary {
    <#
    .SYNOPSIS
        The name and web address of one Team, read as the signed-in user.
    .DESCRIPTION
        Used on the sharing path instead of listing every Team the user owns.
        Listing would cost a settings lookup per Team just to validate one of
        them, and it is not the authorisation anyway: adding a member runs as the
        user, so Graph refuses if they do not own it. This call is for the name
        the confirmation shows and the link the guest is sent.
    .OUTPUTS
        @{ Ok; Error; Name; WebUrl }
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$TeamId)
    $name = ''
    try {
        $group = Invoke-CBGraphAsUser -Caller $Caller -Uri ('/groups/' + [Uri]::EscapeDataString($TeamId) + '?$select=id,displayName,resourceProvisioningOptions')
        if (-not $group.id) { return @{ Ok = $false; Error = 'That Team could not be found.'; Name = ''; WebUrl = '' } }
        if (@($group.resourceProvisioningOptions) -notcontains 'Team') {
            return @{ Ok = $false; Error = 'That group is not a Team.'; Name = "$($group.displayName)"; WebUrl = '' }
        }
        $name = "$($group.displayName)"
    }
    catch {
        return @{ Ok = $false; Name = ''; WebUrl = ''
            Error = "You cannot see that Team, so you cannot add anybody to it."
        }
    }

    # The deep link is nicer, but /teams/{id} is not readable by everyone and the
    # generic entry point is on the welcome page's allowlist while a deep link
    # may not be. Either way the guest lands somewhere that works.
    $webUrl = 'https://teams.microsoft.com/'
    try {
        $team = Invoke-CBGraphAsUser -Caller $Caller -Uri ('/teams/' + [Uri]::EscapeDataString($TeamId) + '?$select=webUrl')
        if ($team.webUrl) { $webUrl = "$($team.webUrl)" }
    }
    catch { Write-Warning "Could not read the web address for team ${TeamId}: $($_.Exception.Message)" }

    return @{ Ok = $true; Error = ''; Name = $name; WebUrl = $webUrl }
}

function Add-CBTeamGuest {
    <#
    .SYNOPSIS
        Adds a guest to a Team, as the signed-in user.
    .DESCRIPTION
        Runs as the user so Graph enforces their ownership of the Team. Works
        before the guest has redeemed their invitation: the account exists from
        the moment the invitation is created, which is what lets an invitation
        and a Team add be one action for the person doing it.
    .OUTPUTS
        @{ Ok; Error; AlreadyMember }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$TeamId, [Parameter(Mandatory)][string]$GuestId)
    $cfg = Get-CBConfig
    $body = @{ '@odata.id' = '{0}/v1.0/directoryObjects/{1}' -f $cfg.GraphResource, $GuestId }
    try {
        Invoke-CBGraphAsUser -Caller $Caller -Method Post -Uri ('/groups/' + [Uri]::EscapeDataString($TeamId) + '/members/$ref') -Body $body | Out-Null
        return @{ Ok = $true; Error = ''; AlreadyMember = $false }
    }
    catch {
        $message = "$($_.Exception.Message)"
        # Already a member is a success from the user's point of view: what they
        # asked for is true.
        if ($message -match 'already exist|One or more added object references already exist') {
            return @{ Ok = $true; Error = ''; AlreadyMember = $true }
        }
        return @{ Ok = $false; Error = $message; AlreadyMember = $false }
    }
}
