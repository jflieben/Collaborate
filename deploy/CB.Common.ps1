# Shared deployment helpers used by BOTH Deploy-Collaborate.ps1 and
# Update-Collaborate.ps1.
#
# Everything Collaborate needs in Entra is reconciled from permissions.json, so a
# new feature that needs another permission is added in ONE place and picked up
# by both the full deploy and the (unattended) update.
#
# Requires the dot-sourcing script to have already defined Invoke-Az (both do)
# and az to be signed in. $PSScriptRoot always resolves to this file's folder, so
# permissions.json is found regardless of who dot-sources it.
#
# The three network helpers at the top are the exception: install.ps1 dot-sources
# this file just for those, before the deploy runs, so they call az directly and
# depend on nothing else here.

function Get-MyPublicIp {
    foreach ($svc in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
        try {
            $ip = "$(Invoke-RestMethod -Method Get -Uri $svc -TimeoutSec 10 -ErrorAction Stop)".Trim()
            if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip }
        }
        catch { }
    }
    return $null
}

function Test-AzureCloudShell {
    # In Cloud Shell the machine's public IP is the container's Azure egress, NOT
    # the admin's, so it must never be auto-allowed.
    return [bool](
        ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*') -or
        ($env:POWERSHELL_DISTRIBUTION_CHANNEL -eq 'CloudShell') -or
        $env:ACC_CLOUD
    )
}

function Show-CBSignInIpHint {
    <#
    .SYNOPSIS
        Shows the addresses the operator has recently signed in from, so they can
        recognise which one to allow.
    .DESCRIPTION
        Guessing a public IP is the step people get wrong, and getting it wrong
        here locks somebody out of the thing they just installed. Entra already
        knows the answer: it recorded the address every time this account signed
        in.

        Distinct addresses, most recent first, rather than the raw log. Five rows
        of the same address answers nothing, and what the operator is trying to
        work out is "which addresses do we come from", which is a set.

        Best effort throughout. Sign-in logs need an Entra ID P1 or P2 licence and
        a role that may read them, and the Azure CLI's own token may not carry the
        scope. None of that is worth failing a deployment over, so every path ends
        in a hint rather than an error.
    #>
    [CmdletBinding()] param([int]$Sample = 25)
    Write-Host 'Looking up the addresses you have recently signed in from...'
    try {
        # az directly rather than Invoke-Az: install.ps1 dot-sources this file to
        # show the hint before the deploy runs, and does not define that helper.
        $me = (& az rest --method GET --url 'https://graph.microsoft.com/v1.0/me' --only-show-errors 2>$null) | Out-String | ConvertFrom-Json
        $upn = "$($me.userPrincipalName)"
        if ($upn) {
            $filter = [Uri]::EscapeDataString("userPrincipalName eq '$($upn.Replace("'", "''"))'")
            $url = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$top=$Sample&`$filter=$filter"
            $resp = (& az rest --method GET --url $url --only-show-errors 2>$null) | Out-String | ConvertFrom-Json
            $rows = @($resp.value | Where-Object { "$($_.ipAddress)" })
            if ($rows.Count) {
                $summary = $rows | Group-Object -Property ipAddress | ForEach-Object {
                    [pscustomobject]@{
                        Address   = $_.Name
                        SignIns   = $_.Count
                        LastSeen  = ("$(($_.Group | Sort-Object createdDateTime -Descending | Select-Object -First 1).createdDateTime)" -split 'T')[0]
                        LastUsedFor = "$(($_.Group | Sort-Object createdDateTime -Descending | Select-Object -First 1).appDisplayName)"
                    }
                } | Sort-Object -Property LastSeen -Descending

                Write-Host ''
                Write-Host 'You have signed in from these addresses:' -ForegroundColor Cyan
                ($summary | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
                Write-Host 'One of these is almost certainly what you want. If your employees sign in through the same' -ForegroundColor Cyan
                Write-Host 'corporate egress, allow that range rather than a single address.' -ForegroundColor Cyan
                Write-Host ''
                return
            }
        }
    }
    catch { }
    Write-Host '(Could not read your sign-in history: it needs an Entra ID P1 or P2 licence and permission to read the'
    Write-Host ' sign-in logs. Find the address from the network your employees use, e.g. https://ifconfig.me.)'
}

function Invoke-CBPortalUpload {
    <#
    .SYNOPSIS
        Uploads the portal to the (locked-down) portal storage account, and puts
        the firewall back as it was.
    .DESCRIPTION
        Two things get in the way of a re-run, and neither is obvious from the
        error the CLI prints:

          * the firewall the previous run applied, which the deploy is outside
            of (in Cloud Shell it always is);
          * shared-key data access being switched off, usually by an Azure Policy
            rather than by anything here. az then returns the SAME "may be
            blocked by network rules" hint, which sends everybody after the
            firewall.

        So the firewall is opened for the duration (simply, not per address: the
        address a storage service sees from Cloud Shell is not reliably the one
        an IP-echo service reports), and the upload is tried with the operator's
        own identity first, falling back to the account key. When both fail, the
        two settings that actually decide it are printed.

        The account holds the portal's static files: no data, no tokens, no
        secrets. The window is the length of one upload and it is announced.
    .OUTPUTS
        $true when the portal was uploaded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Source,
        [string]$AccountKey,
        [string]$SubscriptionId
    )
    $settings = $null
    try {
        $settings = (& az storage account show --name $Account --resource-group $ResourceGroup `
                --query '{defaultAction:networkRuleSet.defaultAction,sharedKey:allowSharedKeyAccess,publicAccess:publicNetworkAccess,id:id}' `
                --only-show-errors 2>$null) | Out-String | ConvertFrom-Json
    }
    catch { }
    $wasDenying = $settings -and "$($settings.defaultAction)" -eq 'Deny'

    # The operator's own identity needs a data-plane role; being Owner does not
    # grant one. Idempotent, and a failure here is not fatal because the key path
    # may still work.
    if ($settings -and $settings.id) {
        $me = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv') -AllowFail)
        if ($me) {
            Invoke-Az -AzArgs @('role', 'assignment', 'create', '--assignee-object-id', $me, '--assignee-principal-type', 'User',
                '--role', 'Storage Blob Data Contributor', '--scope', $settings.id) -AllowFail | Out-Null
        }
    }

    if ($wasDenying) {
        Write-Host "Opening the $Account firewall for the upload..." -ForegroundColor Yellow
        & az storage account update --name $Account --resource-group $ResourceGroup --default-action Allow --only-show-errors 2>$null | Out-Null
        Start-Sleep -Seconds 20
    }

    try {
        $base = @('storage', 'blob', 'upload-batch', '--account-name', $Account, '--destination', '$web', '--source', $Source, '--overwrite')
        # The signed-in identity first: it keeps working when shared-key access is
        # switched off, which is the failure that looks like a firewall problem.
        if ($null -ne (Invoke-Az -AzArgs ($base + @('--auth-mode', 'login')) -AllowFail)) { return $true }
        Write-Host 'Uploading as you did not work; trying the account key...'
        if ($AccountKey -and $null -ne (Invoke-Az -AzArgs ($base + @('--account-key', $AccountKey)) -AllowFail)) { return $true }

        Write-Warning "The portal could not be uploaded to $Account."
        if ($settings) {
            Write-Warning "  allowSharedKeyAccess = $($settings.sharedKey), publicNetworkAccess = $($settings.publicAccess)"
            if ("$($settings.sharedKey)" -eq 'False') {
                Write-Warning '  Shared-key access is switched off (often by an Azure Policy), so the key cannot be used. Uploading as you needs Storage Blob Data Contributor on that account; it was just requested and can take a few minutes to take effect. Re-run then.'
            }
            if ("$($settings.publicAccess)" -eq 'Disabled') {
                Write-Warning '  Public network access is Disabled on the account, so nothing outside a private endpoint can reach it, firewall rules included.'
            }
        }
        return $false
    }
    finally {
        if ($wasDenying) {
            Write-Host "Closing the $Account firewall again..." -ForegroundColor Yellow
            & az storage account update --name $Account --resource-group $ResourceGroup --default-action Deny --bypass AzureServices --only-show-errors 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "The $Account firewall is STILL OPEN. Close it now: az storage account update --name $Account --resource-group $ResourceGroup --default-action Deny --bypass AzureServices"
            }
        }
    }
}

function Get-CBRequirement {
    [CmdletBinding()] param()
    $path = Join-Path $PSScriptRoot 'permissions.json'
    if (-not (Test-Path $path)) { throw "permissions.json not found next to the deploy scripts ($path)." }
    return (Get-Content $path -Raw | ConvertFrom-Json)
}

function Invoke-CBGraphJson {
    <#
    .SYNOPSIS
        'az rest' to Microsoft Graph, parsing the JSON response. A request body is
        written to a temp file and passed as @file: inline multi-line JSON gets
        mangled (especially on Windows) and Graph rejects it. Returns the parsed
        object, or $null on an allowed failure.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [switch]$AllowFail
    )
    if ($null -ne $Body) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cbgraph-$([Guid]::NewGuid().ToString('N')).json")
        [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
        try {
            $out = Invoke-Az -AzArgs @('rest', '--method', $Method, '--uri', $Uri, '--headers', 'Content-Type=application/json', '--body', "@$tmp") -AllowFail:$AllowFail
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    else {
        $out = Invoke-Az -AzArgs @('rest', '--method', $Method, '--uri', $Uri) -AllowFail:$AllowFail
    }
    if (-not $out) { return $null }
    try { return ($out | Out-String | ConvertFrom-Json) } catch { return $null }
}

function Update-CBPermission {
    <#
    .SYNOPSIS
        Reconciles the MANAGED IDENTITY's application permissions (Graph app
        roles) and Entra directory roles against permissions.json, granting
        whatever is missing. Idempotent.
    .DESCRIPTION
        Returns human-readable descriptions of anything it could NOT grant (empty
        = fully reconciled). Granting requires Global Administrator or Privileged
        Role Administrator; failures are reported, not thrown, so an unattended
        update without those rights degrades gracefully.
    .PARAMETER PrincipalId
        Object id of the Function App's system-assigned managed identity.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PrincipalId)

    $req = Get-CBRequirement
    $failed = [System.Collections.Generic.List[string]]::new()

    # One read of what the identity already holds, reused for every check.
    $existing = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" -AllowFail
    $existingList = if ($existing -and $existing.value) { @($existing.value) } else { @() }

    # Resolve each referenced resource service principal once by its well-known appId.
    $spByKey = @{}
    foreach ($key in $req.resources.PSObject.Properties.Name) {
        $meta = $req.resources.$key
        $spByKey[$key] = Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $meta.appId) -AllowFail | Out-String | ConvertFrom-Json
    }

    foreach ($role in $req.appRoles) {
        $resKey = "$($role.resource)"
        $meta = $req.resources.$resKey
        $resName = if ($meta) { $meta.displayName } else { $resKey }
        $label = "$($role.value) ($resName)"
        $sp = $spByKey[$resKey]
        if (-not $sp -or -not $sp.id) {
            Write-Warning "Could not resolve the '$resName' service principal; '$($role.value)' cannot be granted."
            $failed.Add($label); continue
        }
        $appRole = $sp.appRoles | Where-Object { $_.value -eq $role.value -and $_.allowedMemberTypes -contains 'Application' } | Select-Object -First 1
        if (-not $appRole) {
            Write-Warning "App role '$($role.value)' not found on '$resName'; skipping."
            $failed.Add($label); continue
        }
        if ($existingList | Where-Object { $_.appRoleId -eq $appRole.id -and $_.resourceId -eq $sp.id }) {
            Write-Host "Already granted: $label"
            continue
        }
        Write-Host "Granting: $label"
        $grant = Invoke-CBGraphJson -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" `
            -Body @{ principalId = $PrincipalId; resourceId = $sp.id; appRoleId = $appRole.id } -AllowFail
        if (-not $grant) {
            Write-Warning "Could not grant '$label' (needs Global Administrator / Privileged Role Administrator)."
            $failed.Add($label)
        }
    }

    # --- Entra directory roles ------------------------------------------------
    foreach ($dr in @($req.directoryRoles)) {
        $name = if ($dr.displayName) { "$($dr.displayName)" } else { "$($dr.templateId)" }
        $def = $null
        if ($dr.templateId) {
            $enc = [Uri]::EscapeDataString("templateId eq '$($dr.templateId)'")
            $def = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=$enc" -AllowFail
        }
        if ((-not ($def -and $def.value)) -and $dr.displayName) {
            $enc = [Uri]::EscapeDataString("displayName eq '$($dr.displayName)'")
            $def = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=$enc" -AllowFail
        }
        $roleDef = if ($def -and $def.value) { @($def.value)[0] } else { $null }
        if (-not $roleDef) { Write-Warning "Directory role '$name' not found; skipping."; $failed.Add("directory role: $name"); continue }

        $enc = [Uri]::EscapeDataString("principalId eq '$PrincipalId' and roleDefinitionId eq '$($roleDef.id)'")
        $assigned = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=$enc" -AllowFail
        if ($assigned -and $assigned.value -and @($assigned.value).Count -gt 0) {
            Write-Host "Already assigned directory role: $name"; continue
        }
        Write-Host "Assigning directory role: $name"
        $grant = Invoke-CBGraphJson -Method POST -Uri 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments' `
            -Body @{ roleDefinitionId = $roleDef.id; principalId = $PrincipalId; directoryScopeId = '/' } -AllowFail
        if (-not $grant) {
            Write-Warning "Could not assign directory role '$name' (needs Privileged Role Administrator / Global Administrator)."
            $failed.Add("directory role: $name")
        }
    }

    return $failed
}

function Update-CBDelegatedPermission {
    <#
    .SYNOPSIS
        Grants the PORTAL APP REGISTRATION the delegated Graph scopes it needs for
        the on-behalf-of flow, consented for the whole tenant so no employee is
        ever shown a consent prompt.
    .DESCRIPTION
        Two things are written, and both matter:
          * requiredResourceAccess on the application, so the permissions are
            visible and reviewable in the Entra portal like any other app;
          * an oauth2PermissionGrant with consentType AllPrincipals, which is the
            consent itself. Writing the grant directly is deterministic; the
            interactive 'az ad app permission admin-consent' path has a habit of
            reporting success while granting nothing.
        Returns descriptions of anything it could not grant (empty = all good).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$AppObjectId,
        [Parameter(Mandatory)][string]$ServicePrincipalId
    )
    $req = Get-CBRequirement
    $failed = [System.Collections.Generic.List[string]]::new()
    $scopes = @($req.delegatedScopes)
    if ($scopes.Count -eq 0) { return $failed }
    Write-Host "Reconciling delegated permissions for application $AppId..."
    # Named per resource, because "delegated permissions reconciled" does not
    # tell anybody whether the one added in this release is among them.
    foreach ($group in ($scopes | Group-Object -Property resource)) {
        Write-Host "  $($group.Name): $((@($group.Group | ForEach-Object { $_.value })) -join ', ')"
    }

    # Group the wanted scopes per resource, resolving each scope's id.
    $byResource = @{}
    foreach ($s in $scopes) {
        $meta = $req.resources.$("$($s.resource)")
        if (-not $meta) { $failed.Add("$($s.value) (unknown resource '$($s.resource)')"); continue }
        if (-not $byResource.ContainsKey($meta.appId)) {
            $sp = Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $meta.appId) -AllowFail | Out-String | ConvertFrom-Json
            $byResource[$meta.appId] = @{ Sp = $sp; Name = $meta.displayName; Wanted = [System.Collections.Generic.List[object]]::new() }
        }
        $entry = $byResource[$meta.appId]
        if (-not $entry.Sp -or -not $entry.Sp.id) { $failed.Add("$($s.value) ($($entry.Name) could not be resolved)"); continue }
        $scope = $entry.Sp.oauth2PermissionScopes | Where-Object { $_.value -eq $s.value } | Select-Object -First 1
        if (-not $scope) { $failed.Add("$($s.value) (not offered by $($entry.Name))"); continue }
        $entry.Wanted.Add(@{ Value = $s.value; Id = $scope.id })
    }

    # Declare every resource's permissions on the application object in ONE
    # patch. Doing it per resource inside the loop below meant reading the
    # application back between writes, and Graph does not guarantee that read
    # sees the write before it: the second resource could then patch a list that
    # no longer had the first, and which one survived depended on hashtable
    # ordering. That is how a second resource can be reconciled every run and
    # still not be there.
    $active = @($byResource.Keys | Where-Object { $byResource[$_].Wanted.Count -gt 0 })
    if ($active.Count -gt 0) {
        $current = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId`?`$select=requiredResourceAccess" -AllowFail
        $rra = @()
        if ($current -and $current.requiredResourceAccess) {
            $rra = @($current.requiredResourceAccess | Where-Object { $active -notcontains $_.resourceAppId })
        }
        foreach ($appIdKey in $active) {
            $rra += @{
                resourceAppId  = $appIdKey
                resourceAccess = @($byResource[$appIdKey].Wanted | ForEach-Object { @{ id = $_.Id; type = 'Scope' } })
            }
        }
        $patched = Invoke-CBGraphJson -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId" -Body @{ requiredResourceAccess = $rra } -AllowFail
        if ($null -eq $patched) { Write-Verbose "requiredResourceAccess PATCH returned no body (normal for a 204)." }
    }

    foreach ($appIdKey in $byResource.Keys) {
        $entry = $byResource[$appIdKey]
        if ($entry.Wanted.Count -eq 0) { continue }
        $resourceSpId = $entry.Sp.id
        $wantedValues = @($entry.Wanted | ForEach-Object { $_.Value })

        # The consent itself. Merge with anything already granted rather than
        #    replacing it, so a scope added by hand is never silently revoked.
        $enc = [Uri]::EscapeDataString("clientId eq '$ServicePrincipalId' and resourceId eq '$resourceSpId'")
        $existing = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$enc" -AllowFail
        $grant = if ($existing -and $existing.value) { @($existing.value | Where-Object { $_.consentType -eq 'AllPrincipals' })[0] } else { $null }

        if ($grant) {
            $have = @("$($grant.scope)" -split '\s+' | Where-Object { $_ })
            $missing = @($wantedValues | Where-Object { $have -notcontains $_ })
            if ($missing.Count -eq 0) {
                Write-Host "Delegated permissions already consented for $($entry.Name): $($wantedValues -join ', ')"
                continue
            }
            $merged = (@($have + $missing) | Select-Object -Unique) -join ' '
            Write-Host "Adding delegated permission(s) for $($entry.Name): $($missing -join ', ')"
            $updated = Invoke-CBGraphJson -Method PATCH -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" -Body @{ scope = $merged } -AllowFail
            if ($null -eq $updated) {
                # PATCH returns 204 with no body on success, so verify by reading back.
                $check = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" -AllowFail
                if (-not $check -or (@("$($check.scope)" -split '\s+') | Where-Object { $missing -contains $_ }).Count -eq 0) {
                    Write-Warning "Could not add delegated permissions for $($entry.Name) (needs Global Administrator / Privileged Role Administrator)."
                    $missing | ForEach-Object { $failed.Add("$_ (delegated)") }
                }
            }
        }
        else {
            Write-Host "Consenting delegated permissions for $($entry.Name): $($wantedValues -join ', ')"
            $created = Invoke-CBGraphJson -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{
                clientId    = $ServicePrincipalId
                consentType = 'AllPrincipals'
                resourceId  = $resourceSpId
                scope       = ($wantedValues -join ' ')
            } -AllowFail
            if (-not $created) {
                Write-Warning "Could not consent delegated permissions for $($entry.Name) (needs Global Administrator / Privileged Role Administrator). Sharing will not work until this is granted."
                $wantedValues | ForEach-Object { $failed.Add("$_ (delegated)") }
            }
        }
    }

    return $failed
}

function Set-CBFederatedCredential {
    <#
    .SYNOPSIS
        Makes the app registration trust the Function App's managed identity, so
        the on-behalf-of exchange can be signed without any client secret or
        certificate.
    .DESCRIPTION
        The credential's subject is the managed identity's principal id. If the
        Function App is ever recreated its identity changes, so an existing
        credential with a different subject is replaced rather than left behind
        to fail confusingly at runtime.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppObjectId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$TenantId,
        [string]$Name = 'collaborate-managed-identity'
    )
    $issuer = "https://login.microsoftonline.com/$TenantId/v2.0"
    $existing = Invoke-CBGraphJson -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId/federatedIdentityCredentials" -AllowFail
    $current = if ($existing -and $existing.value) { @($existing.value | Where-Object { $_.name -eq $Name })[0] } else { $null }

    if ($current) {
        if ("$($current.subject)" -eq $PrincipalId -and "$($current.issuer)" -eq $issuer) {
            Write-Host 'Federated identity credential already present and correct.'
            return $true
        }
        Write-Host 'Federated identity credential points at a different identity; replacing it.'
        Invoke-CBGraphJson -Method DELETE -Uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId/federatedIdentityCredentials/$($current.id)" -AllowFail | Out-Null
    }

    Write-Host 'Creating the federated identity credential (managed identity -> app registration)...'
    $created = Invoke-CBGraphJson -Method POST -Uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId/federatedIdentityCredentials" -Body @{
        name        = $Name
        issuer      = $issuer
        subject     = $PrincipalId
        audiences   = @('api://AzureADTokenExchange')
        description = 'Lets Collaborate exchange a user token for delegated Graph access without any client secret.'
    } -AllowFail
    if (-not $created) {
        Write-Warning 'Could not create the federated identity credential. Sharing (which acts as the signed-in user) will not work until it exists.'
        return $false
    }
    return $true
}

function Get-CBAppRoleDefinition {
    <#
    .SYNOPSIS
        The app roles the portal exposes. The ids are fixed so re-running the
        deploy never invalidates existing assignments.
    #>
    return @(
        @{
            id                 = 'a3f1c9d2-6b47-4e18-9a52-7c0d3e845b16'
            allowedMemberTypes = @('User')
            value              = 'Collaborate.Admin'
            displayName        = 'Collaborate administrator'
            description        = 'Configure Collaborate, edit branding and emails, and manage every guest in the tenant.'
            isEnabled          = $true
        },
        @{
            id                 = 'c74b2e08-5d91-4a36-8f2b-1e6a9d04c7f5'
            allowedMemberTypes = @('User')
            value              = 'Collaborate.Inviter'
            displayName        = 'Collaborate inviter'
            description        = 'Reserved for future use: invitation rights are governed by the inviter group setting.'
            isEnabled          = $true
        }
    )
}

function Get-CBAdminAppRoleId { return 'a3f1c9d2-6b47-4e18-9a52-7c0d3e845b16' }

function Get-CBFunctionAppHost {
    <#
    .SYNOPSIS
        The Function App's public host name.
    .DESCRIPTION
        'az functionapp show' returns defaultHostName as NULL on Flex
        Consumption (state comes back null too), so the obvious call quietly
        yields nothing on exactly the plan type this tool deploys onto. That is
        what stopped the portal being redeployed, with a warning that named three
        possible causes and not the real one.

        'az functionapp list' does populate it, so that is the fallback, and
        deriving the name is only the last resort: it assumes the public cloud
        and would be wrong in a sovereign one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$AppName)

    $hostName = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup,
            '--query', 'defaultHostName', '-o', 'tsv') -AllowFail)
    if ($hostName) { return $hostName }

    $hostName = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'list', '--resource-group', $ResourceGroup,
            '--query', "[?name=='$AppName'].defaultHostName | [0]", '-o', 'tsv') -AllowFail)
    if ($hostName) { return $hostName }

    Write-Warning "Azure could not report the host name for '$AppName'; assuming the public cloud default."
    return "$AppName.azurewebsites.net"
}

function Publish-CBFunctionCode {
    <#
    .SYNOPSIS
        Deploys the function package and does not report success until the
        functions are actually registered on the app.
    .DESCRIPTION
        A zip deployment reports success as soon as the package is accepted, and
        on Flex Consumption that is not the same thing as the code running. The
        wrong deployment API can return exit code 0 having done nothing, and the
        app then keeps serving the previous package while the app settings update
        around it.

        The symptoms are a 404 on a newly added endpoint and settings changes
        that appear not to take effect, and neither of them points anywhere near
        the deployment, so this verifies instead of trusting the exit code and
        moves on to the next method when the check fails.
    .OUTPUTS
        @{ Ok; Method; Missing; Error }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$SourcePath
    )
    # config-zip is the documented path for Flex Consumption and goes first.
    # one-deploy is kept as the fallback for plan types where it is the better
    # route, but it is not trusted to be the default any more.
    $methods = @(
        @{ Name = 'config-zip'; Cmd = @('functionapp', 'deployment', 'source', 'config-zip', '--name', $AppName, '--resource-group', $ResourceGroup, '--src', $ZipPath) },
        @{ Name = 'one-deploy'; Cmd = @('functionapp', 'deploy', '--name', $AppName, '--resource-group', $ResourceGroup, '--src-path', $ZipPath, '--type', 'zip') }
    )

    $lastError = ''
    $missing = @()
    $anyAccepted = $false
    foreach ($method in $methods) {
        Write-Host "Deploying the function package via $($method.Name)..."
        $accepted = $false
        for ($attempt = 1; $attempt -le 2 -and -not $accepted; $attempt++) {
            $cmd = $method.Cmd
            $out = & az @cmd --only-show-errors 2>&1
            if ($LASTEXITCODE -eq 0) { $accepted = $true }
            else {
                $lastError = ($out | Out-String).Trim()
                Write-Warning "$($method.Name) attempt $attempt failed."
                Start-Sleep -Seconds 15
            }
        }
        if (-not $accepted) { continue }
        $anyAccepted = $true

        Write-Host 'Syncing function triggers with the platform...'
        Invoke-Az -AzArgs @('rest', '--method', 'post',
            '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/syncfunctiontriggers?api-version=2023-12-01") -AllowFail | Out-Null

        $missing = @(Test-DeployedFunction -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -AppName $AppName -SourcePath $SourcePath)
        if ($missing.Count -eq 0) {
            Write-Host "Deployed via $($method.Name), and every function is registered." -ForegroundColor Green
            return @{ Ok = $true; Accepted = $true; Method = $method.Name; Missing = @(); Error = '' }
        }
        Write-Warning "$($method.Name) reported success but $($missing.Count) function(s) are not registered. Trying the next method."
    }

    # Accepted matters separately from verified. A package that was accepted and
    # then failed verification is a problem to report, not a reason to throw and
    # abandon the rest of the update: the permissions, the portal and the CORS
    # rules all still need reconciling, and the caller says what is missing.
    return @{ Ok = $false; Accepted = $anyAccepted; Method = ''; Missing = @($missing); Error = $lastError }
}

function Test-DeployedFunction {
    <#
    .SYNOPSIS
        Confirms every function in the package actually registered on the app,
        and forces a restart plus a re-sync if any did not.
    .DESCRIPTION
        A zip deploy reports success as soon as the package is uploaded. On Flex
        Consumption the host then reloads and re-indexes, and a function added
        since the last deploy can fail to appear. The only symptom is a 404 on
        one endpoint, discovered by a user long after the deployment said it was
        fine, which is the worst possible time to find out.

        So the deploy checks rather than assumes. Registration is not instant,
        hence the wait; a restart is the documented cure when it does not happen.
    .OUTPUTS
        The names that are still missing. Empty means everything registered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AppName,
        [Parameter(Mandatory)][string]$SourcePath
    )
    $expected = @(Get-ChildItem -Path $SourcePath -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'function.json') } |
            ForEach-Object { $_.Name })
    if ($expected.Count -eq 0) { return @() }

    function Get-LiveFunction {
        # az returns 'appname/FunctionName'; only the tail is the function.
        return @(Invoke-Az -AzArgs @('functionapp', 'function', 'list', '--name', $AppName, '--resource-group', $ResourceGroup,
                '--query', '[].name', '-o', 'tsv') -AllowFail |
                ForEach-Object { ("$_".Trim() -split '/')[-1] } | Where-Object { $_ })
    }

    Write-Host "Verifying that all $($expected.Count) function(s) registered..."
    $missing = @()
    foreach ($round in 1, 2) {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $live = Get-LiveFunction
            $missing = @($expected | Where-Object { $live -notcontains $_ })
            if ($missing.Count -eq 0) { break }
            Start-Sleep -Seconds 10
        }
        if ($missing.Count -eq 0) { break }
        if ($round -eq 1) {
            Write-Warning "Not registered yet: $($missing -join ', '). Restarting the app and syncing triggers again."
            Invoke-Az -AzArgs @('functionapp', 'restart', '--name', $AppName, '--resource-group', $ResourceGroup) -AllowFail | Out-Null
            Start-Sleep -Seconds 20
            Invoke-Az -AzArgs @('rest', '--method', 'post',
                '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/syncfunctiontriggers?api-version=2023-12-01") -AllowFail | Out-Null
        }
    }

    if ($missing.Count -eq 0) { Write-Host "All $($expected.Count) function(s) registered." }
    else {
        Write-Warning "These functions did NOT register: $($missing -join ', ')."
        Write-Warning 'Calls to them will return 404. Re-run this script; if they still do not appear, check the deployment logs in the Azure portal (Diagnose and solve problems > Function app down or reporting errors).'
    }
    # NOT ', @($missing)'. Callers wrap this in @(), and a unary comma around an
    # empty array yields a one-element array CONTAINING the empty array, so an
    # everything-is-fine result read back as one missing function.
    return @($missing)
}
