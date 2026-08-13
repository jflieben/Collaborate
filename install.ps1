<#
.SYNOPSIS
    One-line bootstrap installer for Collaborate.

.DESCRIPTION
    Downloads the LATEST published release from GitHub and runs the full
    deployment into your Azure subscription. Designed for Azure Cloud Shell
    (PowerShell), where the Azure CLI is present and you are already signed in:

        iex (irm https://raw.githubusercontent.com/jflieben/Collaborate/main/install.ps1)

    Anything you do not pass is prompted for, so the one-liner is fully
    interactive. To run unattended or pin a version, download it and pass
    parameters instead:

        irm https://raw.githubusercontent.com/jflieben/Collaborate/main/install.ps1 -OutFile install.ps1
        ./install.ps1 -SubscriptionId <sub> -Location westeurope `
            -SenderUpn noreply@contoso.com -ServicedeskEmail servicedesk@contoso.com `
            -AdminGroupName "Collaborate Admins" -AllowedIp 203.0.113.0/24

.PARAMETER Version
    Release to install (e.g. '1.2.0' or 'v1.2.0'). Default: the latest release.

.PARAMETER Repo
    GitHub owner/repo to install from. Set this to install from your own fork.
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$Location,
    [string]$SenderUpn,
    [string]$ServicedeskEmail,
    [string]$AdminGroupName,
    [string]$CompanyName,
    [string]$InviterGroupName,
    [string[]]$AllowedIp,
    [switch]$PublicWithSso,
    [switch]$SkipNetworkLockdown,
    [hashtable]$Tags,
    [string]$ResourceGroup,
    [string]$Version,
    [string]$Repo = 'jflieben/Collaborate'
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7+ is required. Use Azure Cloud Shell (PowerShell) or install PowerShell 7.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) was not found. Run this in Azure Cloud Shell (PowerShell), or install the Azure CLI and run "az login" first.'
}

function Read-Required {
    param([string]$Current, [string]$Prompt)
    $v = $Current
    while ([string]::IsNullOrWhiteSpace($v)) { $v = (Read-Host $Prompt).Trim() }
    return $v
}

Write-Host ''
Write-Host 'Collaborate installer' -ForegroundColor Cyan
Write-Host 'Self-service guest collaboration for locked-down Entra tenants.'
Write-Host ''

# --- Resolve the release -----------------------------------------------------
$apiBase = "https://api.github.com/repos/$Repo/releases"
$releaseUri = if ($Version) { "$apiBase/tags/$(if ($Version.StartsWith('v')) { $Version } else { "v$Version" })" } else { "$apiBase/latest" }
Write-Host "Looking up the release from $Repo ..."
try { $release = Invoke-RestMethod -Uri $releaseUri -Headers @{ 'User-Agent' = 'collaborate-installer' } -ErrorAction Stop }
catch { throw "Could not find that release in $Repo. Check the -Version value, or omit it for the latest." }

$tag = $release.tag_name
Write-Host "Installing $tag" -ForegroundColor Green

$srcAsset = $release.assets | Where-Object { $_.name -like 'Collaborate-src-*.zip' } | Select-Object -First 1
$webAsset = $release.assets | Where-Object { $_.name -like 'Collaborate-web-*.zip' } | Select-Object -First 1
if (-not $srcAsset -or -not $webAsset) { throw "Release $tag does not carry the expected assets." }

$work = Join-Path ([System.IO.Path]::GetTempPath()) "collaborate-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    Write-Host 'Downloading...'
    $srcZip = Join-Path $work 'src.zip'
    $webZip = Join-Path $work 'web.zip'
    Invoke-WebRequest -Uri $srcAsset.browser_download_url -OutFile $srcZip -ErrorAction Stop
    Invoke-WebRequest -Uri $webAsset.browser_download_url -OutFile $webZip -ErrorAction Stop
    Expand-Archive -Path $srcZip -DestinationPath (Join-Path $work 'src') -Force
    Expand-Archive -Path $webZip -DestinationPath (Join-Path $work 'web') -Force

    # The deploy scripts and VERSION come from the repo at the tagged commit, so
    # what runs matches what was released.
    New-Item -ItemType Directory -Path (Join-Path $work 'deploy') -Force | Out-Null
    foreach ($file in @('Deploy-Collaborate.ps1', 'Update-Collaborate.ps1', 'Remove-Collaborate.ps1', 'CB.Common.ps1', 'permissions.json')) {
        Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/$tag/deploy/$file" -OutFile (Join-Path $work "deploy/$file") -ErrorAction Stop
    }
    ($tag.TrimStart('v')) | Out-File (Join-Path $work 'VERSION') -Encoding ascii -NoNewline

    # --- Gather the settings -------------------------------------------------
    Write-Host ''
    $SubscriptionId = Read-Required $SubscriptionId 'Azure subscription id'
    $Location = Read-Required $Location 'Azure region (e.g. westeurope)'
    $SenderUpn = Read-Required $SenderUpn 'Mailbox to send from (e.g. noreply@contoso.com)'
    $ServicedeskEmail = Read-Required $ServicedeskEmail 'Service desk email (health warnings and unowned-guest digests)'
    $AdminGroupName = Read-Required $AdminGroupName 'Entra security group whose members administer Collaborate'
    # The address to allow is NOT asked here. The deploy asks it at the network
    # step, where it can show which addresses Entra has seen you sign in from,
    # and asking twice for the same thing is worse than asking once late.

    $params = @{
        SubscriptionId   = $SubscriptionId
        Location         = $Location
        SenderUpn        = $SenderUpn
        ServicedeskEmail = $ServicedeskEmail
        AdminGroupName   = $AdminGroupName
    }
    if ($CompanyName) { $params.CompanyName = $CompanyName }
    if ($InviterGroupName) { $params.InviterGroupName = $InviterGroupName }
    if ($AllowedIp) { $params.AllowedIp = $AllowedIp }
    if ($PublicWithSso) { $params.PublicWithSso = $true }
    if ($SkipNetworkLockdown) { $params.SkipNetworkLockdown = $true }
    if ($Tags) { $params.Tags = $Tags }
    if ($ResourceGroup) { $params.ResourceGroup = $ResourceGroup }

    Write-Host ''
    & (Join-Path $work 'deploy/Deploy-Collaborate.ps1') @params
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
