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
    # A 404 here is almost always a site or library they cannot open rather than
    # a fault, and "Graph Get returned HTTP 404" helps nobody.
    if ($detail -match 'HTTP 404|itemNotFound|could not be found') {
        Send-Json -Status 404 -Object @{ error = 'That site or folder could not be opened. It may have been removed, or you may not have access to it.' }
        return
    }
    if ($detail -match 'HTTP 403|accessDenied|Forbidden') {
        Send-Json -Status 403 -Object @{ error = 'You do not have access to that. Only things you can already open appear here.' }
        return
    }
    # An on-behalf-of failure is a setup problem with an actionable message, and
    # the user should see it rather than a generic 500.
    Send-Json -Status 502 -Object @{ error = $detail }
}
