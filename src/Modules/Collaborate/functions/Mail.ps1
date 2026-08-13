# Sending mail.
#
# Mail goes out through Graph sendMail from ONE shared mailbox. There is no
# tenant-wide Mail.Send app role: Exchange Online RBAC for Applications
# authorises the managed identity for that single mailbox and nothing else, so
# the worst this tool can do with mail is send from the address it was set up
# with (see docs/permissions.md).

$script:CBLogoCache = $null
$script:CBLogoCacheKey = ''
$script:CBBrandLogoCid = 'collaboratebrandlogo'

function Get-CBInlineLogoAttachment {
    <#
    .SYNOPSIS
        The branding logo as an inline Graph attachment, or $null.
    .DESCRIPTION
        Emails embed the logo rather than linking it: mail clients block remote
        images from external senders by default, and a guest seeing a broken
        image in an invitation is exactly the wrong first impression. Cached per
        worker, keyed on the file name so a new upload is picked up.
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $file = "$($Settings.branding.logoFile)"
    if (-not $file) { return $null }

    if ($script:CBLogoCacheKey -ne $file) {
        $script:CBLogoCache = $null
        try {
            $bytes = Get-CBBlobBytes -Name ("branding/$file")
            if ($bytes) {
                $script:CBLogoCache = @{
                    '@odata.type' = '#microsoft.graph.fileAttachment'
                    name          = $file
                    contentType   = "$($Settings.branding.logoContentType)"
                    contentBytes  = [Convert]::ToBase64String($bytes)
                    isInline      = $true
                    contentId     = $script:CBBrandLogoCid
                }
            }
        }
        catch { Write-Warning "Could not load the branding logo for email: $($_.Exception.Message)" }
        $script:CBLogoCacheKey = $file
    }
    return $script:CBLogoCache
}

function Send-CBMail {
    <#
    .SYNOPSIS
        Sends one HTML message from the configured sender mailbox.
    .PARAMETER Attachments
        Graph attachment objects (used for the inline logo).
    .PARAMETER Force
        Send even in simulation mode. Only the "send a test to me" button uses
        this: an admin asking to see the mail should get the mail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Html,
        $Attachments,
        [switch]$Force,
        $Settings
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    if (-not $To) { Write-Warning 'No recipient; not sending.'; return $false }
    if (-not (Test-CBEmailAddress -Address $To)) { Write-Warning "Refusing to send to an invalid address '$To'."; return $false }

    if ($Settings.dryRun -and -not $Force) {
        Write-Host "[simulation] Would send '$Subject' to $To."
        return $false
    }

    $cfg = Get-CBConfig
    $message = @{
        subject      = $Subject
        body         = @{ contentType = 'HTML'; content = $Html }
        toRecipients = @(@{ emailAddress = @{ address = $To } })
    }
    if ($Attachments) { $message.attachments = @($Attachments) }

    # Kept in the sender mailbox's Sent Items. Mail this tool sends on somebody's
    # behalf is a real message about a real person's access, and "did they ever
    # actually get it" is asked often enough that leaving no copy is the wrong
    # kind of tidy. It also gives an administrator somewhere to look that is not
    # this application.
    Invoke-CBGraph -Method Post -Uri ('/users/' + [Uri]::EscapeDataString($cfg.SenderUpn) + '/sendMail') -Body @{
        message         = $message
        saveToSentItems = $true
    } | Out-Null
    Write-Host "Sent '$Subject' to $To."
    return $true
}

function Send-CBTemplateMail {
    <#
    .SYNOPSIS
        Renders a template from the catalogue and sends it. A template an admin
        has switched off is skipped silently (that is what the switch means).
    .OUTPUTS
        $true when a message was actually sent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)]$Values,
        $Settings,
        [switch]$Force
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $logo = Get-CBInlineLogoAttachment -Settings $Settings
    $cid = if ($logo) { $script:CBBrandLogoCid } else { '' }

    $rendered = Get-CBRenderedEmail -Key $Key -Values $Values -Settings $Settings -LogoCid $cid
    if (-not $rendered.Enabled -and -not $Force) {
        Write-Host "Email template '$Key' is switched off; not sending to $To."
        return $false
    }
    return (Send-CBMail -To $To -Subject $rendered.Subject -Html $rendered.Html `
            -Attachments $(if ($logo) { @($logo) } else { $null }) -Settings $Settings -Force:$Force)
}

function Get-CBMailTokenValue {
    <#
    .SYNOPSIS
        The token bag every real (non-preview) message starts from: branding and
        the service desk address. Callers add the guest, owner and item specifics.
    #>
    [CmdletBinding()] param($Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    $cfg = Get-CBConfig
    return @{
        brand            = @{
            companyName = "$($Settings.branding.companyName)"
            portalUrl   = $cfg.PortalUrl
        }
        servicedeskEmail = "$($Settings.notifications.servicedeskEmail)"
    }
}
