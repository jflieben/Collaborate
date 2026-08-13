using namespace System.Net

# The file picker, projected from SharePoint and OneDrive as the signed-in user.
#
# GET /api/browse?pane=recent|mydrive|sites|children|search
#                 &driveId=&itemId=&siteId=&q=&folders=1
#
# Everything here runs through the on-behalf-of flow, so the picker can only show
# what this person can already open. There is no filtering in this file that a
# determined caller could get around, because there is nothing to get around:
# Graph is answering as them.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 10)
        })
}

try {
    $caller = Resolve-CBCaller -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    $settings = Get-CBSettings
    if (-not $settings.setupComplete) {
        Send-Json -Status 409 -Object @{ error = 'Collaborate has not been set up yet.' }
        return
    }
    # Browsing exists to pick something to share. With both file and folder
    # sharing off there is nothing to pick, so the picker is unreachable rather
    # than merely hidden.
    if (-not $settings.sharing.files -and -not $settings.sharing.folders) {
        Send-Json -Status 403 -Object @{ error = 'Sharing files and folders has been switched off by an administrator.' }
        return
    }

    $query = $Request.Query
    $pane = if ($query) { "$($query['pane'])".Trim().ToLowerInvariant() } else { '' }
    if (-not $pane) { $pane = 'recent' }
    if ((Get-CBBrowsePaneName) -notcontains $pane) {
        Send-Json -Status 400 -Object @{ error = "Unknown pane '$pane'." }
        return
    }

    $foldersOnly = $false
    if ($query -and "$($query['folders'])" -in @('1', 'true')) { $foldersOnly = $true }

    $result = Get-CBBrowsePane -Caller $caller -Settings $settings -Pane $pane -FoldersOnly:$foldersOnly `
        -DriveId "$($query['driveId'])" -ItemId "$($query['itemId'])" -SiteId "$($query['siteId'])" -Query "$($query['q'])"

    Write-CBHeartbeatSampled -Name 'BrowseApi'
    Send-Json -Status 200 -Object @{
        pane         = $result.Pane
        items        = @($result.Items)
        # Why a pane is empty, when it can be explained. "Nothing here" over an
        # empty list is the same message whether the person has never opened a
        # file or the tenant has switched the data source off.
        emptyReason  = "$($result.EmptyReason)"
        # Only the siteinfo pane fills this in.
        siteSettings = $result.SiteSettings
        capabilities = [ordered]@{
            files   = [bool]$settings.sharing.files
            folders = [bool]$settings.sharing.folders
            teams   = [bool]$settings.sharing.teams
        }
    }
}
catch {
    $detail = "$($_.Exception.Message)"
    Write-CBHeartbeatSampled -Name 'BrowseApi' -Status error -ErrorMessage $detail
    Write-Error "BrowseApi failed: $detail"

    # These reach an ordinary employee mid-task, so say what it means for them.
    # The raw text goes back as 'detail' for the expandable section, never as the
    # sentence: "Graph Get returned HTTP 404" helps nobody in the middle of
    # picking a file, and helps support a great deal once it is copied.
    $where = if ($pane -eq 'children' -and "$($query['siteId'])") { 'site' } else { 'folder' }
    if ($detail -match 'HTTP 404|itemNotFound|could not be found') {
        Send-Json -Status 404 -Object @{
            detail = $detail
            error  = $(if ($where -eq 'site') {
                    'That site no longer exists. SharePoint keeps deleted sites in your followed list, so it can still appear here.'
                }
                else { 'That folder could not be opened. It may have been moved or removed since the list was loaded.' })
        }
        return
    }
    if ($detail -match 'HTTP 403|accessDenied|Forbidden') {
        Send-Json -Status 403 -Object @{
            error  = "You do not have access to that $where. Only things you can already open yourself appear here."
            detail = $detail
        }
        return
    }
    Send-Json -Status 502 -Object @{
        error  = "That $where could not be opened. This is not something you did wrong; the details below are what support needs."
        detail = $detail
    }
}
