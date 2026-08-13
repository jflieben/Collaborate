# Configuration surface for Collaborate.
#
# There are two layers of configuration:
#
#   * INFRA settings (this file, Get-CBConfig) live in Function App application
#     settings. They are endpoints and identifiers written once at deploy time
#     and are not meant to be edited by operators. Nothing here grants M365
#     access: administration uses the managed identity, and anything a user
#     shares uses that user's own delegated token.
#
#   * BEHAVIOUR settings (Settings.ps1, Get-CBSettings) live in a JSON blob in
#     the storage account so the portal can read and edit them live: branding,
#     expiry policy, reminder steps, sharing capability gates, safety limits and
#     every email template.

$script:CBConfigCache = $null

function Get-CBConfig {
    <#
    .SYNOPSIS
        Returns infra configuration (endpoints/identifiers), read once per worker.
    #>
    [CmdletBinding()]
    param([switch]$Refresh)

    if ($script:CBConfigCache -and -not $Refresh) { return $script:CBConfigCache }

    function Get-Setting {
        param([string]$Name, [string]$Default = $null, [switch]$Required)
        $value = [Environment]::GetEnvironmentVariable($Name)
        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($Required) { throw "Required application setting '$Name' is not configured." }
            return $Default
        }
        return $value.Trim()
    }

    $config = [pscustomobject]@{
        # Mail. Sending is authorised by Exchange Online RBAC scoped to this one
        # mailbox, not by a tenant-wide Graph Mail.Send app role.
        SenderUpn              = Get-Setting -Name 'CB_SENDER_UPN' -Required
        ServicedeskEmail       = Get-Setting -Name 'CB_SERVICEDESK_EMAIL' -Default ''

        # State store (Azure Storage, AAD auth via managed identity).
        TableEndpoint          = (Get-Setting -Name 'CB_TABLE_ENDPOINT' -Required).TrimEnd('/')
        BlobEndpoint           = (Get-Setting -Name 'CB_BLOB_ENDPOINT' -Required).TrimEnd('/')
        QueueEndpoint          = (Get-Setting -Name 'CB_QUEUE_ENDPOINT' -Default ((Get-Setting -Name 'CB_TABLE_ENDPOINT' -Required) -replace '\.table\.', '.queue.')).TrimEnd('/')
        ConfigContainer        = Get-Setting -Name 'CB_CONFIG_CONTAINER' -Default 'collaborate-config'
        GuestActionQueue       = 'guestactions'

        # The PUBLIC welcome site lives in its own storage account. The managed
        # identity can write there (so branding stays editable without a
        # redeploy) but that account holds no data, no tokens and no auth.
        PublicBlobEndpoint     = (Get-Setting -Name 'CB_PUBLIC_BLOB_ENDPOINT' -Default '').TrimEnd('/')
        PublicSiteUrl          = (Get-Setting -Name 'CB_PUBLIC_SITE_URL' -Default '').TrimEnd('/')

        # Where the portal itself lives (used in emails that link a guest owner
        # back into the tool).
        PortalUrl              = (Get-Setting -Name 'CB_PORTAL_URL' -Default '').TrimEnd('/')

        # Cloud endpoints (override for sovereign clouds; commercial is the
        # supported target).
        GraphResource          = Get-Setting -Name 'CB_GRAPH_RESOURCE' -Default 'https://graph.microsoft.com'
        StorageResource        = Get-Setting -Name 'CB_STORAGE_RESOURCE' -Default 'https://storage.azure.com'
        LoginResource          = Get-Setting -Name 'CB_LOGIN_HOST' -Default 'https://login.microsoftonline.com'

        # Portal auth. The admin functions validate the delegated bearer token
        # themselves against these, so a disabled or misconfigured Easy Auth
        # becomes a visible 401 rather than a silently open API.
        TenantId               = Get-Setting -Name 'CB_TENANT_ID' -Required
        AdminClientId          = Get-Setting -Name 'CB_ADMIN_CLIENT_ID' -Default ''

        # Object id of the operator who ran the deploy. Grants admin rights ONLY
        # until the setup wizard completes, so the first sign-in works before any
        # app-role assignment has propagated. Ignored afterwards.
        BootstrapAdminOid      = Get-Setting -Name 'CB_BOOTSTRAP_ADMIN_OID' -Default ''

        Version                = Get-Setting -Name 'CB_VERSION' -Default 'dev'

        # Weekly version check: where to read the latest published VERSION and
        # where to point operators for release notes.
        VersionCheckUrl        = Get-Setting -Name 'CB_VERSION_URL' -Default 'https://raw.githubusercontent.com/jflieben/Collaborate/main/VERSION'
        ReleasesUrl            = Get-Setting -Name 'CB_RELEASES_URL' -Default 'https://github.com/jflieben/Collaborate'
    }

    $script:CBConfigCache = $config
    return $config
}

# Table names used by the tool. Kept together so the deploy script and the
# runtime agree on the schema.
$script:CBTables = [pscustomobject]@{
    Guests     = 'Guests'              # one row per guest, partitioned by owner object id (or 'orphaned')
    Activity   = 'ActivityLog'         # chronological audit feed shown in the portal
    Heartbeats = 'FunctionHeartbeats'  # last run/status/error per function, shown on Diagnostics
    Safety     = 'SafetyState'         # storm-guard counters + paused latch (circuit breaker)
}

function Get-CBTableNames { return $script:CBTables }

function Get-CBModuleVersion {
    <#
    .SYNOPSIS
        The version of the CODE that is actually running, read from the module
        manifest on disk.
    .DESCRIPTION
        Get-CBConfig().Version comes from the CB_VERSION app setting, which the
        deploy writes as a separate step from uploading the code. When a zip
        deployment silently fails to land, the setting updates and the code does
        not, and every symptom that follows looks like a logic bug in whatever
        the operator touches next.

        Reporting both makes that unambiguous: if they disagree, the code did not
        deploy, and no amount of debugging the feature will help.
    #>
    [CmdletBinding()] param()
    try {
        $module = Get-Module -Name 'Collaborate' | Select-Object -First 1
        if ($module) { return "$($module.Version)" }
    }
    catch { Write-Warning "Could not read the module version: $($_.Exception.Message)" }
    return 'unknown'
}

$script:CBSettingsBlobName = 'config.json'
function Get-CBSettingsBlobName { return $script:CBSettingsBlobName }

# Partition used for guests nobody owns (pre-existing guests the adoption pass
# could not attribute to anyone). Kept here so the API, the scanner and the
# portal all agree on the sentinel.
$script:CBOrphanPartition = 'orphaned'
function Get-CBOrphanPartition { return $script:CBOrphanPartition }
