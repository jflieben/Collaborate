#Requires -Version 7.0
<#
.SYNOPSIS
    Removes a Collaborate deployment: the resource group, the portal app
    registration, and the Exchange Online mailbox scoping.

.DESCRIPTION
    What this does NOT do, deliberately: it does not touch a single guest
    account. Guests invited through Collaborate are ordinary Entra B2B users and
    stay exactly as they are, with their expiry date still written on them. Only
    the machinery that manages them goes away.

    -KeepData leaves the state storage account behind, so the guest records and
    the activity log survive for audit.

.PARAMETER SenderUpn
    The sender mailbox, used to resolve the tenant and to find the Exchange role
    assignment to remove.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$SenderUpn,
    [string]$ResourceGroup = 'rg-collaborate',
    [string]$AppName,
    [switch]$KeepData
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

function Get-StableSuffix {
    param([Parameter(Mandatory)][string]$Seed)
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Seed.ToLower()))
    return (([System.BitConverter]::ToString($bytes) -replace '-', '').Substring(0, 8)).ToLower()
}

Write-Step 'Preflight'
Invoke-Az -AzArgs @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$account = az account show | ConvertFrom-Json
$tenantId = $account.tenantId

# Pin the tenant from the sender's domain, exactly as the deploy does. Removing
# resources from the wrong tenant would be a very bad afternoon, and the resource
# names are derived from the tenant id, so a mismatch would also target the wrong
# storage accounts.
$senderDomain = ($SenderUpn -split '@')[-1]
try {
    $discovery = Invoke-RestMethod -Method Get -Uri "https://login.microsoftonline.com/$senderDomain/v2.0/.well-known/openid-configuration" -ErrorAction Stop
    if ($discovery.issuer -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $expectedTenantId = $Matches[1]
        if ($expectedTenantId -ne $tenantId) {
            throw "Subscription $SubscriptionId is in tenant $tenantId, but '$senderDomain' belongs to tenant $expectedTenantId. Refusing to remove anything."
        }
    }
}
catch [System.Net.Http.HttpRequestException] {
    Write-Warning "Could not resolve the tenant for '$senderDomain'; continuing with the current az context."
}

$stableSuffix = Get-StableSuffix -Seed $tenantId
if (-not $AppName) { $AppName = "func-collaborate-$stableSuffix" }
$StateStorage = "cbstate$stableSuffix"

Write-Host "Tenant       : $tenantId"
Write-Host "Resource group: $ResourceGroup"
Write-Host "Function app : $AppName"
Write-Host ''
Write-Host 'Guest accounts are NOT touched. They remain in Entra with their expiry attribute intact.' -ForegroundColor Yellow
if ($KeepData) { Write-Host "The state storage account ($StateStorage) will be kept for audit." -ForegroundColor Yellow }

if ($PSCmdlet.ShouldProcess($ResourceGroup, 'Remove Collaborate') -eq $false) { return }

$identityAppId = Get-AzScalar (Invoke-Az -AzArgs @('functionapp', 'identity', 'show', '--name', $AppName, '--resource-group', $ResourceGroup, '--query', 'principalId', '-o', 'tsv') -AllowFail)
if ($identityAppId) {
    $identityAppId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'sp', 'show', '--id', $identityAppId, '--query', 'appId', '-o', 'tsv') -AllowFail)
}

# --- Exchange Online ---------------------------------------------------------
Write-Step 'Exchange Online'
try {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    foreach ($name in @("CB-$AppName-MailSend")) {
        if (Get-ManagementRoleAssignment -Identity $name -ErrorAction SilentlyContinue) {
            Remove-ManagementRoleAssignment -Identity $name -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "Removed role assignment '$name'."
        }
    }
    $scopeName = "Collaborate-Sender-$AppName"
    if (Get-ManagementScope -Identity $scopeName -ErrorAction SilentlyContinue) {
        Remove-ManagementScope -Identity $scopeName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed management scope '$scopeName'."
    }
    if ($identityAppId -and (Get-ServicePrincipal -Identity $identityAppId -ErrorAction SilentlyContinue)) {
        Remove-ServicePrincipal -Identity $identityAppId -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host 'Removed the Exchange service principal.'
    }
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
}
catch { Write-Warning "Exchange Online cleanup was skipped: $($_.Exception.Message)" }

# --- App registration --------------------------------------------------------
Write-Step 'Portal app registration'
$webAppName = "Collaborate Portal - $AppName"
$appId = Get-AzScalar (Invoke-Az -AzArgs @('ad', 'app', 'list', '--display-name', $webAppName, '--query', '[0].appId', '-o', 'tsv') -AllowFail)
if ($appId) {
    Invoke-Az -AzArgs @('ad', 'app', 'delete', '--id', $appId) -AllowFail | Out-Null
    Write-Host "Deleted app registration '$webAppName'."
}
else { Write-Host 'No portal app registration found.' }

# --- Resources ---------------------------------------------------------------
Write-Step 'Azure resources'
if ($KeepData) {
    # Delete everything except the state account, one resource at a time.
    $ids = (Invoke-Az -AzArgs @('resource', 'list', '--resource-group', $ResourceGroup, '--query', '[].id', '-o', 'tsv') -AllowFail)
    $stateId = Get-AzScalar (Invoke-Az -AzArgs @('storage', 'account', 'show', '--name', $StateStorage, '--resource-group', $ResourceGroup, '--query', 'id', '-o', 'tsv') -AllowFail)
    foreach ($id in @($ids)) {
        $id = "$id".Trim()
        if (-not $id -or ($stateId -and $id -eq $stateId)) { continue }
        Invoke-Az -AzArgs @('resource', 'delete', '--ids', $id) -AllowFail | Out-Null
    }
    Write-Host "Removed everything except the state storage account '$StateStorage'."
}
else {
    Invoke-Az -AzArgs @('group', 'delete', '--name', $ResourceGroup, '--yes', '--no-wait') | Out-Null
    Write-Host "Deleting resource group '$ResourceGroup' (running in the background)."
}

Write-Step 'Done'
Write-Host 'Collaborate has been removed.' -ForegroundColor Green
Write-Host 'Guest accounts were not touched. If you want them cleaned up, do that before removing the tool, while it can still tell you who owns what.' -ForegroundColor Yellow
