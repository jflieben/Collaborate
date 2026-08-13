#Requires -Version 7.0
<#
.SYNOPSIS
    One-shot onboarding for Collaborate. Provisions everything and wires up the
    managed identity so the tool runs with NO secrets or certificates, including
    the on-behalf-of flow that powers sharing.

.DESCRIPTION
    Creates (idempotently):
      * Resource group
      * Three storage accounts, deliberately asymmetric:
          - cbstate<suffix>  private state (tables, config blob, work queue)
          - cbweb<suffix>    the internal portal, locked to your IP ranges, with
                             NO managed-identity access at all, so a runtime
                             compromise cannot rewrite the signed-in page
          - cbland<suffix>   the public page guests land on after accepting. It
                             holds no data and no authentication, and the app CAN
                             write to it so branding stays editable forever
      * Log Analytics + Application Insights
      * Flex Consumption Function App (PowerShell 7.6) with a system-assigned
        managed identity
      * Storage RBAC for that identity (keyless host storage, state, public site)
      * Graph application permissions and the Guest Inviter directory role, from
        deploy/permissions.json
      * Exchange Online RBAC for Applications: the identity is registered in EXO
        and granted 'Application Mail.Send' scoped to ONE sender mailbox, so
        there is no tenant-wide Mail.Send
      * The portal app registration: SPA redirect, an access_as_user scope, the
        Collaborate.Admin / Collaborate.Inviter app roles, tenant-wide consent for
        the delegated Graph scopes, and a FEDERATED IDENTITY CREDENTIAL trusting
        the managed identity (this is what makes secretless on-behalf-of possible)
      * App Service Easy Auth on the API, verified by reading it back
    Then it zip-deploys the function code, uploads the portal, and locks inbound
    network access down to the ranges you allow.

    Every setting an administrator might later want to change (branding, logo,
    welcome copy, expiry policy, sharing capabilities, inviter group) is only
    SEEDED here. It lives in the config blob and is edited in the portal, so
    nothing is frozen at install time.

.PARAMETER SenderUpn
    Mailbox that Collaborate sends from (e.g. a shared no-reply mailbox). Its
    DOMAIN also determines the target tenant: the script resolves the tenant id
    from it and forces az to sign in there, so you cannot accidentally deploy into
    the wrong tenant.

.PARAMETER AdminGroupName
    Display name of the Entra security group whose members administer Collaborate.
    Its members get the Collaborate.Admin app role.

.PARAMETER AllowedIp
    Public IP addresses or CIDR ranges allowed to reach the portal and its API.
    Because ordinary employees use this tool, this usually needs to be your
    corporate egress ranges rather than one admin address. Everything else is
    blocked. The public welcome site is never restricted.

.PARAMETER PublicWithSso
    Leave the portal and API reachable from any address, relying on Entra sign-in
    and your Conditional Access policies as the only perimeter. Use this when
    people work from home and you do not have fixed egress ranges.

.EXAMPLE
    ./Deploy-Collaborate.ps1 -SubscriptionId <sub> -Location westeurope `
        -SenderUpn noreply@contoso.com -ServicedeskEmail servicedesk@contoso.com `
        -AdminGroupName "Collaborate Admins" -AllowedIp 203.0.113.0/24
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$SenderUpn,
    [Parameter(Mandatory)][string]$ServicedeskEmail,
    [Parameter(Mandatory)][string]$AdminGroupName,

    [string]$ResourceGroup = 'rg-collaborate',
    # Deterministic per-tenant names so re-running is fully idempotent.
    [string]$AppName,
    [string]$CompanyName,
    [string]$InviterGroupName,

    [hashtable]$Tags,

    # Network. By default the portal and API are restricted to the ranges given
    # here (plus your detected address outside Cloud Shell).
    [string[]]$AllowedIp,
    [switch]$PublicWithSso,
    [switch]$SkipNetworkLockdown
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$AllowFail)
    # --only-show-errors keeps stdout clean (no warnings) so scalar queries parse
    # reliably; errors still surface on failure.
    if ($AzArgs -notcontains '--only-show-errors') { $AzArgs += '--only-show-errors' }
    $out = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not $AllowFail) { throw "az $($AzArgs -join ' ') failed:`n$out" }
        # Tolerated failure: return nothing, so truthiness checks do not mistake
        # the error text for a value.
        return $null
    }
    return $out
}

function Get-AzScalar {
    param($Value)
    return ((@($Value) | Where-Object { "$_".Trim() } | Select-Object -Last 1) | ForEach-Object { "$_".Trim() })
}

function Invoke-AzRestJson {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)]$Body,
        [switch]$AllowFail
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("azrest-$([Guid]::NewGuid().ToString('N')).json")
    [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    try {
        return Invoke-Az -AzArgs @('rest', '--method', $Method, '--uri', $Uri,
            '--headers', 'Content-Type=application/json', '--body', "@$tmp") -AllowFail:$AllowFail
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-StableSuffix {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Seed.ToLower()))
    return (([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 8)).ToLower()
}

function Get-TenantIdFromDomain {
    param([Parameter(Mandatory)][string]$Domain)
    $uri = "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration"
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -ErrorAction Stop
        if ($resp.issuer -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    }
    catch { return $null }
    return $null
}

# Single source of truth for the version: the VERSION file at the repo root.
$moduleVersion = '0.1.0'
try {
    $versionFile = Join-Path $PSScriptRoot '..\VERSION'
    if (Test-Path $versionFile) { $moduleVersion = (Get-Content $versionFile -Raw).Trim() }
}
catch { }

# --- Preflight ---------------------------------------------------------------
Write-Step 'Preflight'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install from https://aka.ms/azcli and run "az login".'
}

$senderDomain = ($SenderUpn -split '@')[-1]
$expectedTenantId = Get-TenantIdFromDomain -Domain $senderDomain
if ($expectedTenantId) { Write-Host "Sender domain '$senderDomain' -> tenant $expectedTenantId." }
else { Write-Warning "Could not resolve a tenant for '$senderDomain'; falling back to the current az login context. Verify you are in the right tenant." }

$account = az account show 2>$null | ConvertFrom-Json
if ($expectedTenantId -and (-not $account -or $account.tenantId -ne $expectedTenantId)) {
    Write-Host "Current az context is not tenant $expectedTenantId; signing in to it now..." -ForegroundColor Yellow
    az login --tenant $expectedTenantId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Sign-in to tenant $expectedTenantId failed. Ensure you have access to '$senderDomain'." }
    $account = az account show 2>$null | ConvertFrom-Json
}
if (-not $account) { throw 'Not logged in. Run "az login" first.' }

Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$account = az account show | ConvertFrom-Json
$tenantId = $account.tenantId
if ($expectedTenantId -and $tenantId -ne $expectedTenantId) {
    throw "Subscription $SubscriptionId is in tenant $tenantId, but sender domain '$senderDomain' belongs to tenant $expectedTenantId. Use a subscription in the correct tenant."
}
Write-Host "Subscription: $SubscriptionId  Tenant: $tenantId"

# The operator's own object id: it becomes the bootstrap administrator so the
# very first sign-in works before any app-role assignment has replicated. It
# stops applying the moment the setup wizard completes.
$deployerOid = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv') -AllowFail)
$deployerUpn = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'signed-in-user', 'show', '--query', 'userPrincipalName', '-o', 'tsv') -AllowFail)
if ($deployerOid) { Write-Host "Deploying as  : $deployerUpn ($deployerOid)" }
else { Write-Warning 'Could not determine the signed-in user. You will need the admin group membership to sign in to the portal.' }

# --- Admin group -------------------------------------------------------------
$AdminGroupObjectId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'group', 'show', '--group', $AdminGroupName, '--query', 'id', '-o', 'tsv') -AllowFail)
if (-not $AdminGroupObjectId) {
    Write-Warning "No Entra security group named '$AdminGroupName' was found."
    $answer = Read-Host "Create it now? Its members can configure Collaborate and manage every guest -- treat it as privileged access. [y/N]"
    if ($answer -notmatch '^\s*(y|yes)\s*$') { throw "No Entra security group named '$AdminGroupName' was found. Create it first, then re-run." }
    $nickname = ($AdminGroupName -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($nickname)) { $nickname = 'collaborateadmins' }
    $AdminGroupObjectId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'group', 'create', '--display-name', $AdminGroupName, '--mail-nickname', $nickname, '--is-assignable-to-role', 'true', '--query', 'id', '-o', 'tsv') -AllowFail)
    if ($AdminGroupObjectId) { Write-Host "Created ROLE-ASSIGNABLE security group '$AdminGroupName' ($AdminGroupObjectId)." -ForegroundColor Green }
    else {
        Write-Warning 'Could not create a role-assignable group (needs Privileged Role Admin); creating a normal security group instead.'
        $AdminGroupObjectId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'group', 'create', '--display-name', $AdminGroupName, '--mail-nickname', $nickname, '--query', 'id', '-o', 'tsv'))
        if (-not $AdminGroupObjectId) { throw "Failed to create the security group '$AdminGroupName'." }
    }
    Write-Warning "The new group is EMPTY. Add the people who should administer Collaborate."
}
else { Write-Host "Admin group   : $AdminGroupName ($AdminGroupObjectId)" }

$InviterGroupObjectId = ''
if ($InviterGroupName) {
    $InviterGroupObjectId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'group', 'show', '--group', $InviterGroupName, '--query', 'id', '-o', 'tsv') -AllowFail)
    if ($InviterGroupObjectId) { Write-Host "Inviter group : $InviterGroupName ($InviterGroupObjectId)" }
    else { Write-Warning "No group named '$InviterGroupName' was found; leaving invitations open to every internal member (you can set this in the portal)." }
}

# --- Names -------------------------------------------------------------------
$stableSuffix = Get-StableSuffix -Seed $tenantId
if (-not $AppName) { $AppName = "func-collaborate-$stableSuffix" }
$StateStorage = "cbstate$stableSuffix"
$WebStorage = "cbweb$stableSuffix"
$LandStorage = "cbland$stableSuffix"
foreach ($n in @($StateStorage, $WebStorage, $LandStorage)) { if ($n.Length -gt 24) { throw "Generated storage account name '$n' is too long." } }
if (-not $CompanyName) { $CompanyName = ($senderDomain -split '\.')[0] }

Write-Host "Resource group: $ResourceGroup"
Write-Host "Function app  : $AppName"
Write-Host "Storage       : $StateStorage (state), $WebStorage (portal), $LandStorage (public welcome page)"
Write-Host 'Plan          : Flex Consumption'
if ($Tags -and $Tags.Count) { Write-Host "RG tags       : $(($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" }

if ($PSCmdlet.ShouldProcess($AppName, 'Deploy Collaborate') -eq $false) { return }

# --- Exchange Online sign-in (up front) --------------------------------------
# Connect and verify the sender mailbox NOW, while the other interactive sign-ins
# are happening, so the pop-up does not surprise the admin later. The actual
# scoping happens once the managed identity exists.
Write-Step 'Exchange Online sign-in'
$exoReady = $false
$exoScoped = $false
$mbxSmtp = $null
try {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Write-Host 'Installing ExchangeOnlineManagement (CurrentUser)...'
        Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Write-Host 'Connecting to Exchange Online (a sign-in window may open)...'
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    $mbxSmtp = (Get-Mailbox -Identity $SenderUpn -ErrorAction Stop).PrimarySmtpAddress
    Write-Host "Sender mailbox verified: $mbxSmtp"
    $exoReady = $true
}
catch {
    Write-Warning "Exchange Online connect/verify failed: $($_.Exception.Message)"
    Write-Warning 'Mailbox-scoped mail will be skipped; set it up manually later (docs/permissions.md).'
}

# --- Resource group ----------------------------------------------------------
Write-Step 'Resource group'
$rgArgs = @('group', 'create', '--name', $ResourceGroup, '--location', $Location)
# Only pass --tags when the caller supplied some, so a re-run without -Tags never
# clears tags an inheritance policy put on the group.
if ($Tags -and $Tags.Count) { $rgArgs += @('--tags') + @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) }
Invoke-Az -AzArgs $rgArgs | Out-Null

# --- Storage accounts --------------------------------------------------------
Write-Step 'Storage accounts'

# 1. State: private, no anonymous access, versioned so a bad config save is
#    recoverable.
Invoke-Az -AzArgs @('storage', 'account', 'create', '--name', $StateStorage, '--resource-group', $ResourceGroup, '--location', $Location,
    '--sku', 'Standard_LRS', '--kind', 'StorageV2', '--min-tls-version', 'TLS1_2', '--allow-blob-public-access', 'false') | Out-Null
Invoke-Az -AzArgs @('storage', 'account', 'blob-service-properties', 'update', '--account-name', $StateStorage, '--resource-group', $ResourceGroup, '--enable-versioning', 'true') -AllowFail | Out-Null
$stateId = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StateStorage, '--resource-group', $ResourceGroup, '--query', 'id', '-o', 'tsv'))
$tableEndpoint = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StateStorage, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.table', '-o', 'tsv'))).TrimEnd('/')
$blobEndpoint = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StateStorage, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.blob', '-o', 'tsv'))).TrimEnd('/')
$queueEndpoint = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StateStorage, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.queue', '-o', 'tsv'))).TrimEnd('/')

# 2. Portal: serves the signed-in single-page app. The managed identity gets NO
#    role here, so a runtime compromise cannot rewrite the page that holds admin
#    sessions. Only this script writes to it, with the account key, at admin time.
Invoke-Az -AzArgs @('storage', 'account', 'create', '--name', $WebStorage, '--resource-group', $ResourceGroup, '--location', $Location,
    '--sku', 'Standard_LRS', '--kind', 'StorageV2', '--min-tls-version', 'TLS1_2', '--allow-blob-public-access', 'true') | Out-Null

# 3. Public welcome page: no data, no auth, no tokens. The app CAN write here so
#    branding and copy stay editable in the portal. Versioning and soft delete are
#    on because that write access is the one thing traded away, and this is how a
#    change is caught and undone (the Watchdog also re-hashes the page daily).
Invoke-Az -AzArgs @('storage', 'account', 'create', '--name', $LandStorage, '--resource-group', $ResourceGroup, '--location', $Location,
    '--sku', 'Standard_LRS', '--kind', 'StorageV2', '--min-tls-version', 'TLS1_2', '--allow-blob-public-access', 'true') | Out-Null
Invoke-Az -AzArgs @('storage', 'account', 'blob-service-properties', 'update', '--account-name', $LandStorage, '--resource-group', $ResourceGroup,
    '--enable-versioning', 'true', '--enable-delete-retention', 'true', '--delete-retention-days', '30') -AllowFail | Out-Null
$landId = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $LandStorage, '--resource-group', $ResourceGroup, '--query', 'id', '-o', 'tsv'))

# Static website hosting on both public-facing accounts.
$webKey = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'keys', 'list', '--account-name', $WebStorage, '--resource-group', $ResourceGroup, '--query', '[0].value', '-o', 'tsv'))
$landKey = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'keys', 'list', '--account-name', $LandStorage, '--resource-group', $ResourceGroup, '--query', '[0].value', '-o', 'tsv'))
Invoke-Az -AzArgs @('storage', 'blob', 'service-properties', 'update', '--account-name', $WebStorage, '--account-key', $webKey,
    '--static-website', '--index-document', 'index.html', '--404-document', 'index.html') | Out-Null
Invoke-Az -AzArgs @('storage', 'blob', 'service-properties', 'update', '--account-name', $LandStorage, '--account-key', $landKey,
    '--static-website', '--index-document', 'welcome.html', '--404-document', 'welcome.html') | Out-Null

# CORS on the public account. The portal's sign-in screen runs before any token
# exists, so it reads branding from assets/branding.json on THIS account, which
# is a different origin from the portal. Without a CORS rule the browser refuses
# the read and the gate silently falls back to unbranded defaults.
#
# The origin is '*' deliberately: every file here is already anonymously
# readable by anybody with the URL, so a CORS rule restricts nothing. It only
# tells the browser what it is allowed to do, and pinning it to the portal's
# origin would break the moment somebody puts a custom domain in front.
# Cleared first so re-running does not stack duplicate rules.
Invoke-Az -AzArgs @('storage', 'cors', 'clear', '--services', 'b', '--account-name', $LandStorage, '--account-key', $landKey) -AllowFail | Out-Null
Invoke-Az -AzArgs @('storage', 'cors', 'add', '--services', 'b', '--methods', 'GET', 'HEAD', 'OPTIONS',
    '--origins', '*', '--allowed-headers', '*', '--exposed-headers', '*', '--max-age', '3600',
    '--account-name', $LandStorage, '--account-key', $landKey) -AllowFail | Out-Null

$portalUrl = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $WebStorage, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.web', '-o', 'tsv'))).TrimEnd('/')
$landUrl = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $LandStorage, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.web', '-o', 'tsv'))).TrimEnd('/')
$landBlob = (Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $LandStorage, '--resource-group', $ResourceGroup, '--query', 'primaryEndpoints.blob', '-o', 'tsv'))).TrimEnd('/')
Write-Host "Portal        : $portalUrl"
Write-Host "Welcome page  : $landUrl"

# --- Log Analytics + Application Insights ------------------------------------
Write-Step 'Log Analytics + Application Insights'
Invoke-Az -AzArgs @('extension', 'add', '--name', 'application-insights') -AllowFail | Out-Null
$workspaceId = Get-AzScalar (Invoke-Az -AzArgs @('monitor', 'log-analytics', 'workspace', 'create',
        '--resource-group', $ResourceGroup, '--workspace-name', "log-$AppName", '--location', $Location, '--query', 'id', '-o', 'tsv') -AllowFail)
$aiArgs = @('monitor', 'app-insights', 'component', 'create', '--app', $AppName, '--location', $Location,
    '--resource-group', $ResourceGroup, '--query', 'connectionString', '-o', 'tsv')
if ($workspaceId) { $aiArgs += @('--workspace', $workspaceId) }
else { Write-Warning 'Could not create a Log Analytics workspace; App Insights may create its own managed resource group.' }
$aiConn = Get-AzScalar (Invoke-Az -AzArgs $aiArgs -AllowFail)
if (-not $aiConn) { Write-Warning 'Could not create Application Insights; continuing without it.' }

# Log every data-plane write to the public welcome account. The app is allowed to
# write there, so the control is evidence rather than prevention.
if ($workspaceId) {
    Invoke-Az -AzArgs @('monitor', 'diagnostic-settings', 'create', '--name', 'cb-public-writes',
        '--resource', "$landId/blobServices/default", '--workspace', $workspaceId,
        '--logs', '[{"category":"StorageWrite","enabled":true},{"category":"StorageDelete","enabled":true}]') -AllowFail | Out-Null
}

# --- Function app ------------------------------------------------------------
Write-Step 'Function app (Flex Consumption)'
$appExists = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'name', '-o', 'tsv') -AllowFail)
if ($appExists) { Write-Host "Function app '$AppName' already exists; reusing it." }
else {
    Invoke-Az -AzArgs @('functionapp', 'create', '--name', $AppName, '--resource-group', $ResourceGroup,
        '--storage-account', $StateStorage, '--flexconsumption-location', $Location,
        '--runtime', 'powershell', '--runtime-version', '7.6') | Out-Null
}

# Flex Consumption pins the runtime at create time, so an app created on an older
# version would otherwise stay there. This PATCH is idempotent.
Invoke-AzRestJson -Method PATCH -Uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName`?api-version=2023-12-01" -Body @{
    properties = @{ functionAppConfig = @{ runtime = @{ name = 'powershell'; version = '7.6' } } }
} -AllowFail | Out-Null

Invoke-Az -AzArgs @('functionapp', 'identity', 'assign', '--name', $AppName, '--resource-group', $ResourceGroup) | Out-Null
$principalId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'identity', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'principalId', '-o', 'tsv'))
if (-not $principalId) { throw 'Failed to obtain the managed identity principalId.' }

$identityAppId = $null
for ($i = 0; $i -lt 12 -and -not $identityAppId; $i++) {
    $identityAppId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $principalId, '--query', 'appId', '-o', 'tsv') -AllowFail)
    if (-not $identityAppId) { Write-Host 'Waiting for the managed identity to appear in Entra...'; Start-Sleep -Seconds 10 }
}
if (-not $identityAppId) { throw 'The managed identity service principal did not propagate in time. Re-run the script (it is idempotent).' }
Write-Host "Managed identity principalId: $principalId  appId: $identityAppId"

# --- Storage RBAC ------------------------------------------------------------
Write-Step 'Storage role assignments'
Write-Host 'Waiting 15s for the managed identity to propagate...'
Start-Sleep -Seconds 15
$rbacFailed = $false
foreach ($role in @('Storage Blob Data Owner', 'Storage Queue Data Contributor', 'Storage Table Data Contributor')) {
    Write-Host "Granting '$role' on the state account..."
    Invoke-Az -AzArgs @('role', 'assignment', 'create', '--assignee-object-id', $principalId, '--assignee-principal-type', 'ServicePrincipal',
        '--role', $role, '--scope', $stateId) -AllowFail | Out-Null
    if ($LASTEXITCODE -ne 0) { $rbacFailed = $true; Write-Warning "Could not assign '$role' on the state account." }
}
# The public welcome account, and ONLY this one besides the state account: this
# is what lets an administrator change branding without a redeploy. The portal
# account deliberately gets nothing.
Write-Host "Granting 'Storage Blob Data Contributor' on the public welcome account..."
Invoke-Az -AzArgs @('role', 'assignment', 'create', '--assignee-object-id', $principalId, '--assignee-principal-type', 'ServicePrincipal',
    '--role', 'Storage Blob Data Contributor', '--scope', $landId) -AllowFail | Out-Null
if ($LASTEXITCODE -ne 0) { $rbacFailed = $true; Write-Warning 'Could not grant write access to the public welcome account; branding changes will not reach it.' }

if ($rbacFailed) {
    Write-Warning "One or more storage role assignments FAILED. You need 'Owner' or 'User Access Administrator'. Grant them to principalId $principalId, then re-run."
}

# --- API permissions ---------------------------------------------------------
Write-Step 'API permissions (managed identity)'
. (Join-Path $PSScriptRoot 'CB.Common.ps1')
$graphRolesFailed = @(Update-CBPermission -PrincipalId $principalId)
if ($graphRolesFailed.Count -eq 0) { Write-Host 'API permissions reconciled: all required roles are granted.' -ForegroundColor Green }

# --- Exchange Online: mailbox-scoped mail ------------------------------------
Write-Step 'Exchange Online (mailbox-scoped mail)'
if (-not $exoReady) {
    Write-Warning 'Exchange Online was not connected earlier; skipping mailbox scoping (docs/permissions.md).'
}
else {
    try {
        $exoSp = Get-ServicePrincipal -Identity $identityAppId -ErrorAction SilentlyContinue
        if (-not $exoSp) {
            Write-Host 'Registering the managed identity in Exchange Online...'
            $null = New-ServicePrincipal -AppId $identityAppId -ObjectId $principalId -DisplayName "Collaborate-$AppName" -ErrorAction Stop
        }
        else { Write-Host 'Exchange service principal already present.' }

        # A management scope limited to exactly the sender mailbox. Exchange
        # rejects a new scope whose filter matches an existing one, so the filter
        # carries a tautology that keeps it unique to this deployment while still
        # resolving to the same single mailbox.
        $scopeName = "Collaborate-Sender-$AppName"
        $scope = Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue
        if (-not $scope) {
            $uniqueFilter = "PrimarySmtpAddress -eq '$mbxSmtp' -and Name -ne 'CB-$AppName-none'"
            try {
                Write-Host "Creating management scope '$scopeName'..."
                $scope = New-ManagementScope -Name $scopeName -RecipientRestrictionFilter $uniqueFilter -ErrorAction Stop
            }
            catch {
                Write-Warning "Could not create a unique scope ($($_.Exception.Message)). Falling back to an existing scope covering $mbxSmtp."
                $scope = Get-ManagementScope -ErrorAction SilentlyContinue | Where-Object { $_.RecipientFilter -and $_.RecipientFilter -match [regex]::Escape("$mbxSmtp") } | Select-Object -First 1
                if (-not $scope) { throw "No management scope covers $mbxSmtp and a new one could not be created." }
            }
        }
        else { Write-Host "Management scope '$scopeName' already present." }

        $assignName = "CB-$AppName-MailSend"
        if (-not (Get-ManagementRoleAssignment -Identity $assignName -ErrorAction SilentlyContinue)) {
            Write-Host 'Assigning scoped "Application Mail.Send" role...'
            $null = New-ManagementRoleAssignment -Name $assignName -App $identityAppId -Role 'Application Mail.Send' -CustomResourceScope $scope.Name -ErrorAction Stop
        }
        else { Write-Host 'Role assignment already present.' }

        Write-Host 'Exchange Online scoping complete (allow up to ~30 min to take effect).' -ForegroundColor Green
        $exoScoped = $true
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Exchange Online setup did not complete: $($_.Exception.Message)"
        Write-Warning "Finish it manually: New-ServicePrincipal -AppId $identityAppId -ObjectId $principalId; a mailbox-scoped New-ManagementScope for $SenderUpn; then New-ManagementRoleAssignment -App $identityAppId -Role 'Application Mail.Send' -CustomResourceScope <scope>."
    }
}

# --- Application settings ----------------------------------------------------
Write-Step 'Application settings'
$settings = [System.Collections.Generic.List[string]]::new()
$settings.Add("CB_SENDER_UPN=$SenderUpn")
$settings.Add("CB_SERVICEDESK_EMAIL=$ServicedeskEmail")
$settings.Add("CB_COMPANY_NAME=$CompanyName")
$settings.Add("CB_TENANT_ID=$tenantId")
$settings.Add("CB_VERSION=$moduleVersion")
$settings.Add("CB_TABLE_ENDPOINT=$tableEndpoint")
$settings.Add("CB_BLOB_ENDPOINT=$blobEndpoint")
$settings.Add("CB_QUEUE_ENDPOINT=$queueEndpoint")
$settings.Add('CB_CONFIG_CONTAINER=collaborate-config')
$settings.Add("CB_PUBLIC_BLOB_ENDPOINT=$landBlob")
$settings.Add("CB_PUBLIC_SITE_URL=$landUrl")
$settings.Add("CB_PORTAL_URL=$portalUrl")
if ($deployerOid) { $settings.Add("CB_BOOTSTRAP_ADMIN_OID=$deployerOid") }
# Identity-based host storage (keyless): no connection string anywhere.
$settings.Add("AzureWebJobsStorage__accountName=$StateStorage")
if ($aiConn) { $settings.Add("APPLICATIONINSIGHTS_CONNECTION_STRING=$aiConn") }

Invoke-Az -AzArgs (@('functionapp', 'config', 'appsettings', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--settings') + $settings) | Out-Null
Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'delete', '--name', $AppName, '--resource-group', $ResourceGroup, '--setting-names', 'AzureWebJobsStorage') -AllowFail | Out-Null

# --- Deploy the function code ------------------------------------------------
Write-Step 'Deploy function code'
$srcPath = Join-Path $PSScriptRoot '..\src' | Resolve-Path
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "collaborate-$([Guid]::NewGuid().ToString('N')).zip"
Write-Host "Packaging $srcPath ..."
# Stage a clean copy so a developer's real local.settings.json is NEVER shipped.
$pkgStage = Join-Path ([System.IO.Path]::GetTempPath()) "cbpkg-$([Guid]::NewGuid().ToString('N'))"
Copy-Item -Path $srcPath -Destination $pkgStage -Recurse -Force
Get-ChildItem -Path $pkgStage -Filter 'local.settings.json*' -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $pkgStage '*') -DestinationPath $zipPath -Force
Remove-Item $pkgStage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Waiting 30s for the app to be ready before deploying code...'
Start-Sleep -Seconds 30
# Deploys, syncs the triggers, and verifies that the functions really
# registered, trying the next deployment API when they did not. See
# Publish-CBFunctionCode: an accepted package is not the same as running code.
$publish = Publish-CBFunctionCode -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -AppName $AppName -ZipPath $zipPath -SourcePath $srcPath
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
if (-not $publish.Accepted) { throw "Function code deployment failed: no deployment method was accepted.`nLast error:`n$($publish.Error)" }
$missingFunctions = @($publish.Missing)

$hostName = Get-CBFunctionAppHost -ResourceGroup $ResourceGroup -AppName $AppName

# --- Portal app registration -------------------------------------------------
Write-Step 'Portal app registration'
$authVerified = $false
$appId = ''
$delegatedFailed = @()
$ficOk = $false
$webAppName = "Collaborate Portal - $AppName"
try {
    $appId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'list', '--display-name', $webAppName, '--query', '[0].appId', '-o', 'tsv') -AllowFail)
    if (-not $appId) {
        $appId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'create', '--display-name', $webAppName, '--sign-in-audience', 'AzureADMyOrg', '--query', 'appId', '-o', 'tsv'))
    }
    else { Write-Host "Reusing existing app registration '$webAppName'." }
    $appObjId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv'))

    # Reuse the existing API scope id if one is defined, so re-runs never
    # invalidate tokens by changing it.
    $existingScopeId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'show', '--id', $appId, '--query', "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]", '-o', 'tsv') -AllowFail)
    $scopeGuid = if ($existingScopeId) { $existingScopeId } else { [Guid]::NewGuid().ToString() }

    Invoke-AzRestJson -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$appObjId" -Body @{
        identifierUris = @("api://$appId")
        spa            = @{ redirectUris = @("$portalUrl/", "$portalUrl/index.html") }
        appRoles       = @(Get-CBAppRoleDefinition)
        api            = @{
            oauth2PermissionScopes = @(@{
                    id = $scopeGuid; value = 'access_as_user'; type = 'User'; isEnabled = $true
                    adminConsentDisplayName = 'Use Collaborate'; adminConsentDescription = 'Allows the signed-in user to manage their external collaborators and share with them.'
                    userConsentDisplayName = 'Use Collaborate'; userConsentDescription = 'Allows you to manage your external collaborators and share with them.'
                })
        }
    } | Out-Null

    Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--settings', "CB_ADMIN_CLIENT_ID=$appId") | Out-Null

    # Service principal. Assignment is deliberately NOT required: every internal
    # member may sign in and manage the guests they own. Administration comes from
    # the Collaborate.Admin app role, not from being assigned the app.
    $spId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv') -AllowFail)
    if (-not $spId) { $spId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'create', '--id', $appId, '--query', 'id', '-o', 'tsv')) }
    Invoke-AzRestJson -Method PATCH -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" -Body @{ appRoleAssignmentRequired = $false } | Out-Null

    # Give the admin group the administrator role. Assigning a GROUP to an app
    # role needs Entra ID P1; without it, fall back to assigning the deploying
    # operator directly so somebody can administer the tool either way.
    Write-Step 'Administrator role assignment'
    $adminRoleId = Get-CBAdminAppRoleId

    # Already assigned is the normal case on a re-run, and POSTing it again fails
    # with a conflict. Reporting that as "you need a P1 licence" told an operator
    # to go and fix something that was never broken.
    $current = Invoke-CBGraphJson -Method GET -AllowFail `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo?`$select=principalId,appRoleId&`$top=200"
    $already = @($current.value | Where-Object { "$($_.principalId)" -eq $AdminGroupObjectId -and "$($_.appRoleId)" -eq $adminRoleId })

    if ($already.Count -gt 0) {
        Write-Host "'$AdminGroupName' already has Collaborate.Admin." -ForegroundColor Green
    }
    else {
        $assigned = Invoke-AzRestJson -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
            -Body @{ principalId = $AdminGroupObjectId; resourceId = $spId; appRoleId = $adminRoleId } -AllowFail
        if ($assigned) { Write-Host "Granted Collaborate.Admin to '$AdminGroupName'." -ForegroundColor Green }
        else {
            Write-Warning "Could not assign the admin group to the Collaborate.Admin role. Assigning a group to an app role requires an Entra ID P1 licence; without it, assign individual users in Entra (Enterprise applications > $webAppName > Users and groups)."
            if ($deployerOid -and -not @($current.value | Where-Object { "$($_.principalId)" -eq $deployerOid -and "$($_.appRoleId)" -eq $adminRoleId })) {
                $fallback = Invoke-AzRestJson -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
                    -Body @{ principalId = $deployerOid; resourceId = $spId; appRoleId = $adminRoleId } -AllowFail
                if ($fallback) { Write-Host "Granted Collaborate.Admin to you ($deployerUpn) so the portal is administrable." -ForegroundColor Yellow }
            }
        }
    }

    # The federated identity credential: this is what makes on-behalf-of work
    # without a client secret. Sharing depends on it.
    Write-Step 'Federated identity credential (secretless on-behalf-of)'
    $ficOk = Set-CBFederatedCredential -AppObjectId $appObjId -PrincipalId $principalId -TenantId $tenantId

    # Delegated Graph scopes, consented tenant-wide so no employee is prompted.
    Write-Step 'Delegated permissions (used only on behalf of a signed-in user)'
    $delegatedFailed = @(Update-CBDelegatedPermission -AppId $appId -AppObjectId $appObjId -ServicePrincipalId $spId)
    if ($delegatedFailed.Count -eq 0) { Write-Host 'Delegated permissions consented.' -ForegroundColor Green }

    # --- Easy Auth ------------------------------------------------------------
    # Written directly as authsettingsV2 via ARM and then read back: the
    # 'az functionapp auth' commands have been known to report success while
    # leaving the API unauthenticated.
    Write-Step 'App Service authentication'
    Invoke-Az -AzArgs @('functionapp', 'cors', 'add', '--name', $AppName, '--resource-group', $ResourceGroup, '--allowed-origins', $portalUrl) -AllowFail | Out-Null
    $authUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/config/authsettingsV2?api-version=2023-12-01"
    # unauthenticatedClientAction = AllowAnonymous, NOT Return401: a browser CORS
    # preflight (OPTIONS) carries no Authorization header, so Return401 makes Easy
    # Auth reject the preflight BEFORE App Service attaches the CORS header, and
    # the portal breaks with a CORS error despite the origin being allow-listed.
    # The API is still never open: Easy Auth validates any token that IS present,
    # and every function independently validates the bearer token (RS256 against
    # the tenant JWKS, audience, issuer, expiry, guest refusal) and fails closed.
    Invoke-AzRestJson -Method PUT -Uri $authUri -Body @{
        properties = @{
            platform          = @{ enabled = $true; runtimeVersion = '~1' }
            globalValidation  = @{ requireAuthentication = $true; unauthenticatedClientAction = 'AllowAnonymous' }
            identityProviders = @{
                azureActiveDirectory = @{
                    enabled      = $true
                    registration = @{ clientId = $appId; openIdIssuer = "https://login.microsoftonline.com/$tenantId/v2.0" }
                    validation   = @{ allowedAudiences = @("api://$appId") }
                }
            }
            login             = @{ tokenStore = @{ enabled = $true } }
        }
    } | Out-Null
    $authEnabled = Get-AzScalar (Invoke-Az -AzArgs @('rest', '--method', 'get',
            '--url', "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$AppName/config/authsettingsV2/list?api-version=2023-12-01",
            '--query', 'properties.platform.enabled', '-o', 'tsv') -AllowFail)
    if ("$authEnabled" -ne 'true') {
        throw "Easy Auth verification failed (platform.enabled='$authEnabled'). In-function token validation still protects the API, but fix this before using the portal."
    }
    Write-Host 'App Service authentication verified.' -ForegroundColor Green
    $authVerified = $true

    # --- Upload the portal ----------------------------------------------------
    Write-Step 'Portal upload'
    $webSrc = Join-Path $PSScriptRoot '..\web' | Resolve-Path
    $webStage = Join-Path ([System.IO.Path]::GetTempPath()) "cbweb-$([Guid]::NewGuid().ToString('N'))"
    Copy-Item -Path $webSrc -Destination $webStage -Recurse -Force
    $authJs = @"
window.CB_AUTH = {
  clientId: "$appId",
  tenantId: "$tenantId",
  apiBase: "https://$hostName/api",
  apiScope: "api://$appId/access_as_user",
  brandingUrl: "$landUrl/assets/branding.json"
};
"@
    Set-Content -Path (Join-Path $webStage 'authConfig.js') -Value $authJs -Encoding UTF8

    # A re-run hits the lockdown the last run applied, and the upload comes from
    # wherever the deploy is running rather than from an allowed range.
    $uploaded = Invoke-CBPortalUpload -Account $WebStorage -ResourceGroup $ResourceGroup `
        -AccountKey $webKey -Source $webStage -AlreadyAllowed $AllowedIp
    Remove-Item $webStage -Recurse -Force -ErrorAction SilentlyContinue
    if ($uploaded) { Write-Host 'Portal uploaded.' -ForegroundColor Green }
    else { throw "The portal files could not be uploaded to $WebStorage." }
}
catch {
    Write-Warning "Portal setup did not fully complete: $($_.Exception.Message)"
    Write-Warning 'The Azure resources and the API are deployed; finish the portal wiring by hand (docs/portal.md).'
}

# --- Network access ----------------------------------------------------------
# Applied LAST so nothing earlier in the deploy is affected. The PUBLIC welcome
# site is never restricted: guests have to reach it from anywhere.
$networkLocked = $false
$allowedIps = @()
if ($SkipNetworkLockdown -or $PublicWithSso) {
    Write-Warning 'Network lockdown skipped: the portal and API stay reachable from any address. Entra sign-in (and your Conditional Access policies) are then the only perimeter.'
}
else {
    Write-Step 'Network access restrictions'
    $detectedIp = $null
    if (Test-AzureCloudShell) {
        Write-Host 'Azure Cloud Shell detected: the auto-detected address is an Azure one, not yours, so it will NOT be used.' -ForegroundColor Yellow
        if (-not $AllowedIp -and [Environment]::UserInteractive) {
            Show-CBSignInIpHint
            Write-Host 'Employees use this portal, so allow the ranges they browse from (your corporate egress), not only your own address.'
            $entered = (Read-Host 'IP addresses or CIDR ranges to allow, comma separated (blank = skip lockdown for now)').Trim()
            if ($entered) { $AllowedIp = @($entered -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        }
    }
    else {
        $detectedIp = Get-MyPublicIp
        # Detecting an address is not the same as knowing it is the right one.
        # This portal is used by every employee, not only by whoever ran the
        # deploy, and locking it to the deployer's home address is a failure
        # nobody notices until the first person complains they cannot reach it.
        # So when no range was given, show what Entra has seen and offer the
        # choice while it is still cheap to make.
        # Guarded on an interactive host: an unattended run must keep working, and
        # there it falls back to the detected address exactly as it did before.
        if (-not $AllowedIp -and [Environment]::UserInteractive) {
            if ($detectedIp) { Write-Host "Detected your current address: $detectedIp" }
            Show-CBSignInIpHint
            $entered = (Read-Host "IP addresses or CIDR ranges to allow, comma separated (blank = just $detectedIp)").Trim()
            if ($entered) { $AllowedIp = @($entered -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        }
    }
    $allowedIps = @(@($AllowedIp) + @($detectedIp) | Where-Object { $_ } | Select-Object -Unique)

    if ($allowedIps.Count -eq 0) {
        Write-Warning 'No address to allow, so the lockdown was SKIPPED rather than locking everybody out. Re-run with -AllowedIp <ip/cidr>, or use -PublicWithSso deliberately.'
    }
    else {
        Write-Host "Allowing: $($allowedIps -join ', ')"
        $cidrs = @($allowedIps | ForEach-Object { if ($_ -match '/') { $_ } else { "$_/32" } })
        $storageIps = @($allowedIps | ForEach-Object { $_ -replace '/32$', '' })
        try {
            $existingRules = (Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '-o', 'json') -AllowFail | Out-String | ConvertFrom-Json)
            foreach ($r in @($existingRules.ipSecurityRestrictions)) {
                if ($r.name -like 'CB-*') { Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'remove', '--name', $AppName, '--resource-group', $ResourceGroup, '--rule-name', $r.name) -AllowFail | Out-Null }
            }
            $prio = 100
            foreach ($cidr in $cidrs) {
                Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'add', '--name', $AppName, '--resource-group', $ResourceGroup,
                    '--rule-name', "CB-Allow-$prio", '--action', 'Allow', '--ip-address', $cidr, '--priority', "$prio", '--description', 'Collaborate portal users') | Out-Null
                $prio += 10
            }
            Invoke-Az -AzArgs @('functionapp', 'config', 'access-restriction', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--default-action', 'Deny') -AllowFail | Out-Null
            Invoke-Az -AzArgs @('storage', 'account', 'update', '--name', $WebStorage, '--resource-group', $ResourceGroup, '--default-action', 'Deny', '--bypass', 'AzureServices') | Out-Null
            foreach ($ip in $storageIps) {
                Invoke-Az -AzArgs @('storage', 'account', 'network-rule', 'add', '--account-name', $WebStorage, '--resource-group', $ResourceGroup, '--ip-address', $ip) -AllowFail | Out-Null
            }
            Write-Host 'Portal and API locked to the allowed ranges; the public welcome page stays reachable.' -ForegroundColor Green
            $networkLocked = $true
        }
        catch { Write-Warning "Could not fully apply the network restrictions (finish it in the portal): $($_.Exception.Message)" }
    }
}

# --- Done --------------------------------------------------------------------
Write-Step 'Done'
Write-Host 'Collaborate is deployed.' -ForegroundColor Green
Write-Host ''
Write-Host "Portal        : $portalUrl/" -ForegroundColor Green
Write-Host "Welcome page  : $landUrl/  (published when you finish the setup wizard)"
Write-Host "Function app  : $AppName"
Write-Host ''
if ($networkLocked) { Write-Host "Network       : LOCKED to $($allowedIps -join ', '). The public welcome page is unrestricted." -ForegroundColor Green }
elseif ($PublicWithSso) { Write-Host 'Network       : PUBLIC by choice (-PublicWithSso). Entra sign-in and your Conditional Access policies are the perimeter.' -ForegroundColor Yellow }
else { Write-Host 'Network       : NOT restricted. Re-run with -AllowedIp <ip/cidr> to lock it down.' -ForegroundColor Yellow }
Write-Host ''

$steps = [System.Collections.Generic.List[string]]::new()
if ($missingFunctions.Count -gt 0) {
    $steps.Add("These functions did not register: $($missingFunctions -join ', '). Calls to them return 404. Re-run this script, or run deploy/Update-Collaborate.ps1, to redeploy the code.")
}
if ($graphRolesFailed.Count -gt 0) {
    $steps.Add("Grant the missing application permissions ($($graphRolesFailed -join ', ')) to the '$AppName' managed identity. Needs Global Administrator or Privileged Role Administrator; re-running this script reconciles them.")
}
if ($delegatedFailed.Count -gt 0) {
    $steps.Add("Grant admin consent for the delegated permissions ($($delegatedFailed -join ', ')) on the '$webAppName' app registration. Sharing does not work until this is done.")
}
if (-not $ficOk) {
    $steps.Add('Create the federated identity credential on the portal app registration so Collaborate can act on behalf of users (re-running this script does it).')
}
if (-not $exoScoped) {
    $steps.Add("Finish the Exchange Online mailbox scoping for '$SenderUpn' -- no email is sent until then.")
}
if (-not $authVerified) {
    $steps.Add("Verify Authentication on '$AppName': it must be enabled with the Microsoft provider pointing at the portal app registration.")
}
$steps.Add("Open the portal and finish the setup wizard. It verifies single sign-on end to end before it lets you finish, and publishes the guest welcome page.")
$steps.Add("Collaborate starts in SIMULATION mode: it logs what it would do and changes nothing until you turn that off in Configuration.")

Write-Host 'Next steps:' -ForegroundColor Yellow
for ($i = 0; $i -lt $steps.Count; $i++) { Write-Host "  $($i + 1). $($steps[$i])" }
Write-Host ''
Write-Host "    $portalUrl/" -ForegroundColor Cyan
try { Start-Process "$portalUrl/" } catch { Write-Host "(Open $portalUrl/ in your browser to finish setup.)" }
