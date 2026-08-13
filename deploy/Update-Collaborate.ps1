#Requires -Version 7.0
<#
.SYNOPSIS
    Updates an existing Collaborate deployment: redeploys the function code and
    the portal, stamps the new version, and reconciles every Entra permission
    against deploy/permissions.json.

.DESCRIPTION
    There are no interactive prompts, so this is safe to run from a pipeline or a
    scheduled patch window. It does NOT touch behavioural settings: branding,
    emails, expiry policy and the rest live in the config blob and are owned by
    the administrators using the portal.

    It also re-renders nothing by itself. The welcome page is republished by the
    app whenever branding or copy is saved, and the Watchdog reports if the
    published page ever stops matching what the app wrote.

    Anything that needs Global Administrator (granting permissions, consenting
    delegated scopes) is reported rather than fatal, so an unattended update by a
    less privileged account still ships the code.

.PARAMETER SenderUpn
    Used only to resolve the tenant, so an update cannot be aimed at the wrong one.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$SenderUpn,
    [string]$ResourceGroup = 'rg-collaborate',
    [string]$AppName
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$AllowFail)
    if ($AzArgs -notcontains '--only-show-errors') { $AzArgs += '--only-show-errors' }
    $out = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not $AllowFail) { throw "az $($AzArgs -join ' ') failed:`n$out" }
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
        return Invoke-Az -AzArgs @('rest', '--method', $Method, '--uri', $Uri, '--headers', 'Content-Type=application/json', '--body', "@$tmp") -AllowFail:$AllowFail
    }
    finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

function Get-StableSuffix {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Seed.ToLower()))
    return (([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 8)).ToLower()
}

$moduleVersion = '0.1.0'
try {
    $versionFile = Join-Path $PSScriptRoot '..\VERSION'
    if (Test-Path $versionFile) { $moduleVersion = (Get-Content $versionFile -Raw).Trim() }
}
catch { }

Write-Step 'Preflight'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required.' }
Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$account = az account show | ConvertFrom-Json
$tenantId = $account.tenantId
$senderDomain = ($SenderUpn -split '@')[-1]
Write-Host "Subscription: $SubscriptionId  Tenant: $tenantId  (sender domain $senderDomain)"

$stableSuffix = Get-StableSuffix -Seed $tenantId
if (-not $AppName) { $AppName = "func-collaborate-$stableSuffix" }
$WebStorage = "cbweb$stableSuffix"
Write-Host "Function app: $AppName"

if ($PSCmdlet.ShouldProcess($AppName, "Update Collaborate to $moduleVersion") -eq $false) { return }

# Dot-sourced up here rather than next to the permission step, because the
# function-registration check below needs it too.
. (Join-Path $PSScriptRoot 'CB.Common.ps1')

# --- Function code -----------------------------------------------------------
Write-Step "Deploying function code ($moduleVersion)"
$srcPath = Join-Path $PSScriptRoot '..\src' | Resolve-Path
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "collaborate-$([Guid]::NewGuid().ToString('N')).zip"
$pkgStage = Join-Path ([System.IO.Path]::GetTempPath()) "cbpkg-$([Guid]::NewGuid().ToString('N'))"
Copy-Item -Path $srcPath -Destination $pkgStage -Recurse -Force
Get-ChildItem -Path $pkgStage -Filter 'local.settings.json*' -Recurse -Force | Remove-Item -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $pkgStage '*') -DestinationPath $zipPath -Force
Remove-Item $pkgStage -Recurse -Force -ErrorAction SilentlyContinue

$publish = Publish-CBFunctionCode -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup `
    -AppName $AppName -ZipPath $zipPath -SourcePath $srcPath
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
if (-not $publish.Accepted) { throw "Function code deployment failed: no deployment method was accepted.`n$($publish.Error)" }
$missingFunctions = @($publish.Missing)

# Only stamp the version once the CODE is really there. Writing it after a
# deployment that did not land is what makes a stale app look current, and
# StatusApi compares the two to catch exactly that.
if ($missingFunctions.Count -eq 0) {
    Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'set', '--name', $AppName, '--resource-group', $ResourceGroup, '--settings', "CB_VERSION=$moduleVersion") | Out-Null
}
else {
    Write-Warning "Not stamping CB_VERSION=${moduleVersion}: the code did not fully deploy, and claiming otherwise would hide it."
}

# --- Permissions -------------------------------------------------------------
Write-Step 'Reconciling permissions'
$principalId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'identity', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'principalId', '-o', 'tsv') -AllowFail)
$graphRolesFailed = @()
if ($principalId) { $graphRolesFailed = @(Update-CBPermission -PrincipalId $principalId) }
else { Write-Warning 'Could not read the managed identity; skipping permission reconciliation.' }

$appId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', "[?name=='CB_ADMIN_CLIENT_ID'].value | [0]", '-o', 'tsv') -AllowFail)
$delegatedFailed = @()
if ($appId -and $principalId) {
    $appObjId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv') -AllowFail)
    $spId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $appId, '--query', 'id', '-o', 'tsv') -AllowFail)
    if ($appObjId -and $spId) {
        # Keep the app roles current so a role added in a later release exists.
        Invoke-AzRestJson -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$appObjId" -Body @{ appRoles = @(Get-CBAppRoleDefinition) } -AllowFail | Out-Null
        $null = Set-CBFederatedCredential -AppObjectId $appObjId -PrincipalId $principalId -TenantId $tenantId
        $delegatedFailed = @(Update-CBDelegatedPermission -AppId $appId -AppObjectId $appObjId -ServicePrincipalId $spId)
    }
    else {
        # Skipping this silently is how a newly added scope looks reconciled and
        # is not there: nothing in the output mentions it either way.
        Write-Warning "Could not read the portal app registration ($appId) as this account, so DELEGATED permissions were not reconciled. Anything added in this release (sharing scopes) will not work until an account that can read it runs this again."
        $delegatedFailed = @('delegated permissions were not checked at all')
    }
}
else { Write-Warning 'Could not resolve the portal app registration; skipping delegated permission reconciliation.' }

# --- Public welcome account --------------------------------------------------
# The portal's sign-in screen reads branding from the public account, which is a
# different origin, so the browser needs a CORS rule there. Reconciled on every
# update because an install made before this was added has no rule at all and
# silently shows an unbranded sign-in screen.
Write-Step 'Public site CORS'
$LandStorage = "cbland$stableSuffix"
$landKey = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'keys', 'list', '--account-name', $LandStorage, '--resource-group', $ResourceGroup, '--query', '[0].value', '-o', 'tsv') -AllowFail)
if ($landKey) {
    Invoke-Az -AzArgs @('storage', 'cors', 'clear', '--services', 'b', '--account-name', $LandStorage, '--account-key', $landKey) -AllowFail | Out-Null
    Invoke-Az -AzArgs @('storage', 'cors', 'add', '--services', 'b', '--methods', 'GET', 'HEAD', 'OPTIONS',
        '--origins', '*', '--allowed-headers', '*', '--exposed-headers', '*', '--max-age', '3600',
        '--account-name', $LandStorage, '--account-key', $landKey) -AllowFail | Out-Null
    Write-Host 'Public welcome account allows the portal to read its branding file.'
}
else { Write-Warning "Could not read the key for '$LandStorage'; the sign-in screen may show unbranded." }

# --- Portal ------------------------------------------------------------------
Write-Step 'Redeploying the portal'
$hostName = Get-CBFunctionAppHost -ResourceGroup $ResourceGroup -AppName $AppName

# $appId normally comes from the app setting, read during the permission step.
# If that could not be read, the app registration can still be found by name,
# which is how the deploy locates it too.
if (-not $appId) {
    $webAppName = "Collaborate Portal - $AppName"
    $appId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'list', '--display-name', $webAppName, '--query', '[0].appId', '-o', 'tsv') -AllowFail)
    if ($appId) { Write-Host "Found the portal app registration by name ('$webAppName')." }
}

$webKey = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'keys', 'list', '--account-name', $WebStorage, '--resource-group', $ResourceGroup, '--query', '[0].value', '-o', 'tsv') -AllowFail)
$landUrl = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'config', 'appsettings', 'list', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', "[?name=='CB_PUBLIC_SITE_URL'].value | [0]", '-o', 'tsv') -AllowFail)

# Say WHICH thing is missing. "missing storage key, app id or host name" sent
# somebody looking at three unrelated possibilities at once.
$portalBlockers = @()
if (-not $webKey) {
    $portalBlockers += "the access key for storage account '$WebStorage' could not be read (the account may have shared key access disabled, or you may not have permission to list its keys)"
}
if (-not $appId) {
    $portalBlockers += "the portal app registration could not be found (neither the CB_ADMIN_CLIENT_ID app setting nor an app named 'Collaborate Portal - $AppName')"
}

if ($portalBlockers.Count -eq 0) {
    $webSrc = Join-Path $PSScriptRoot '..\web' | Resolve-Path
    $webStage = Join-Path ([System.IO.Path]::GetTempPath()) "cbweb-$([Guid]::NewGuid().ToString('N'))"
    Copy-Item -Path $webSrc -Destination $webStage -Recurse -Force
    # $landUrl only affects the branding shown before sign-in, so an empty one
    # is a cosmetic loss rather than a reason to abandon the upload. Guarded
    # because calling .TrimEnd() on a null would throw and take the whole step
    # down for a decoration.
    $brandingUrl = ''
    if ($landUrl) { $brandingUrl = "$($landUrl.TrimEnd('/'))/assets/branding.json" }
    else { Write-Warning 'CB_PUBLIC_SITE_URL is not set, so the sign-in screen will show unbranded until setup republishes it.' }

    $authJs = @"
window.CB_AUTH = {
  clientId: "$appId",
  tenantId: "$tenantId",
  apiBase: "https://$hostName/api",
  apiScope: "api://$appId/access_as_user",
  brandingUrl: "$brandingUrl"
};
"@
    Set-Content -Path (Join-Path $webStage 'authConfig.js') -Value $authJs -Encoding UTF8

    # The lockdown from the install is already in place, and this machine is
    # almost certainly not inside it.
    $uploaded = Invoke-CBPortalUpload -Account $WebStorage -ResourceGroup $ResourceGroup -AccountKey $webKey -Source $webStage -SubscriptionId $SubscriptionId
    Remove-Item $webStage -Recurse -Force -ErrorAction SilentlyContinue
    if ($uploaded) {
        Write-Host "Portal redeployed to https://$WebStorage.z6.web.core.windows.net/ (clientId $appId, api https://$hostName/api)."
    }
    else { $portalBlockers += 'the portal files could not be uploaded (see the warnings above)' }
}
else {
    Write-Warning 'The portal was NOT redeployed, so the browser is still running the previous version:'
    foreach ($blocker in $portalBlockers) { Write-Warning "  - $blocker" }
    Write-Warning "Fix the above and re-run, or upload ./web yourself with: az storage blob upload-batch --account-name $WebStorage --destination `$web --source ./web --overwrite"
}

Write-Step 'Done'
Write-Host "Collaborate updated to $moduleVersion." -ForegroundColor Green
if ($missingFunctions.Count -gt 0) { Write-Warning "These functions did not register: $($missingFunctions -join ', '). Calls to them return 404 until they do. Re-run this script." }
if ($graphRolesFailed.Count -gt 0) { Write-Warning "Not granted: $($graphRolesFailed -join ', '). Re-run as Global Administrator or Privileged Role Administrator." }
if ($delegatedFailed.Count -gt 0) { Write-Warning "Delegated permissions not consented: $($delegatedFailed -join ', '). Sharing will not work until they are." }
if ($portalBlockers.Count -gt 0) { Write-Warning 'The portal in the browser is still the previous version; see the warnings above.' }
Write-Host 'Behavioural settings (branding, emails, policy) were not touched: those live in the portal.'
