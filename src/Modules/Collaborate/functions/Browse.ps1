# Browsing SharePoint and OneDrive, as the signed-in user.
#
# Every call in this file goes through Invoke-CBGraphAsUser, never the managed
# identity. That is the whole point: the picker can only ever show what the
# person using it can already open, so there is no way to reach something through
# Collaborate that you could not reach through SharePoint itself. It also means
# no filtering logic here is load-bearing for security. Graph does that.
#
# The API is a thin, fast projection: every pane returns the same normalised item
# shape, so the browser-side picker stays dumb and one component renders recent
# files, a document library and a search result identically.

$script:CBBrowsePanes = @('recent', 'mydrive', 'sites', 'children', 'search')

function Get-CBBrowsePaneName { return $script:CBBrowsePanes }

function Get-CBItemIcon {
    <#
    .SYNOPSIS
        A coarse icon name from a file name. Deliberately a small fixed set: the
        portal maps these to characters, and an unknown extension falling back to
        'file' is better than a picker full of mystery glyphs.
    #>
    [CmdletBinding()] param([string]$Name)
    $ext = ''
    if ("$Name" -match '\.([a-z0-9]{1,8})$') { $ext = $Matches[1].ToLowerInvariant() }
    switch ($ext) {
        { $_ -in @('doc', 'docx', 'rtf', 'odt') } { return 'doc' }
        { $_ -in @('xls', 'xlsx', 'xlsm', 'csv', 'ods') } { return 'sheet' }
        { $_ -in @('ppt', 'pptx', 'odp') } { return 'slide' }
        { $_ -eq 'pdf' } { return 'pdf' }
        { $_ -in @('png', 'jpg', 'jpeg', 'gif', 'bmp', 'svg', 'webp', 'heic') } { return 'image' }
        { $_ -in @('mp4', 'mov', 'avi', 'mkv', 'wmv', 'mp3', 'wav', 'm4a') } { return 'media' }
        { $_ -in @('zip', '7z', 'rar', 'tar', 'gz') } { return 'zip' }
        { $_ -in @('ps1', 'js', 'ts', 'py', 'cs', 'java', 'json', 'xml', 'yml', 'yaml', 'sql', 'html', 'css') } { return 'code' }
        { $_ -in @('txt', 'md', 'log') } { return 'text' }
        default { return 'file' }
    }
}

function Get-CBItemCategory {
    <#
    .SYNOPSIS
        What a row IS, in words, for the line under its name.
    .DESCRIPTION
        A picker of twenty file names tells you almost nothing: half of them are
        called "Proposal" and the icon is eight pixels of guesswork. Saying
        "Excel workbook" costs one line and removes the guess.
    #>
    [CmdletBinding()] param([string]$Icon, [string]$Kind, [string]$Name)
    switch ("$Kind") {
        'site' { return 'SharePoint site' }
        'drive' { return 'Document library' }
        'folder' { return 'Folder' }
    }
    switch ("$Icon") {
        'doc' { return 'Word document' }
        'sheet' { return 'Excel workbook' }
        'slide' { return 'PowerPoint presentation' }
        'pdf' { return 'PDF' }
        'image' { return 'Image' }
        'media' { return 'Audio or video' }
        'zip' { return 'Archive' }
        'code' { return 'Code file' }
        'text' { return 'Text file' }
    }
    if ("$Name" -match '\.([a-z0-9]{1,8})$') { return "$($Matches[1].ToUpperInvariant()) file" }
    return 'File'
}

function Format-CBRelativeDate {
    <#
    .SYNOPSIS
        'today', 'yesterday', '3 days ago', or a plain date once that stops being
        useful. Empty for anything unparseable, so a caller never renders "ago"
        against nothing.
    .DESCRIPTION
        Relative is the right unit for a picker: nobody browsing for a file to
        share cares that it was the fourth of March, they care that it was last
        week. Past about a month the relative form stops meaning anything and the
        date reads better, which is where it switches.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Value, [datetime]$Now = [datetime]::MinValue)
    $d = ConvertTo-CBDateOnly -Value $Value
    if (-not $d) { return '' }
    $days = [int]((ConvertTo-CBUtcMoment -Value $Now).Date - $d).TotalDays
    if ($days -lt 0) { return 'just now' }      # clock skew between us and Graph
    if ($days -eq 0) { return 'today' }
    if ($days -eq 1) { return 'yesterday' }
    if ($days -lt 31) { return "$days days ago" }
    return (Format-CBFriendlyDate -Value $Value)
}

function Get-CBItemWhenLabel {
    <#
    .SYNOPSIS
        'Opened yesterday' or 'Edited 3 days ago'. The verb matters: a recent
        list is ordered by when somebody LOOKED at something, and calling that
        "edited" would be a quietly wrong statement about a file they only read.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Value, [ValidateSet('used', 'modified')][string]$Kind = 'modified', [datetime]$Now = [datetime]::MinValue)
    $when = Format-CBRelativeDate -Value $Value -Now $Now
    if (-not $when) { return '' }
    $verb = if ($Kind -eq 'used') { 'Opened' } else { 'Edited' }
    return "$verb $when"
}

function Get-CBItemPath {
    <#
    .SYNOPSIS
        The human part of a driveItem's path. Graph gives
        '/drive/root:/Projects/Q3', and only the tail means anything to a person.
    #>
    [CmdletBinding()] param([AllowNull()][string]$RawPath)
    $p = "$RawPath"
    if (-not $p) { return '' }
    $marker = $p.IndexOf('root:')
    if ($marker -ge 0) { $p = $p.Substring($marker + 5) }
    $p = [Uri]::UnescapeDataString($p).TrimStart('/')
    return $p
}

function ConvertTo-CBBrowseItem {
    <#
    .SYNOPSIS
        Normalises one Graph driveItem into the single shape the picker renders.
    .DESCRIPTION
        Pure, so the awkward parts are testable without a tenant. The awkward
        parts are real:

          * items in /me/drive/recent that live somewhere else carry their true
            identity in 'remoteItem', and using the outer id would produce a
            share against a shortcut rather than the file;
          * a 'package' (a OneNote notebook) has neither a file nor a folder
            facet and would otherwise be classified as neither.
    .PARAMETER Kind
        Forces the kind for panes that do not return driveItems (sites, drives).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item, [string]$FallbackDriveId, [string]$Kind)

    # A shortcut to somewhere else: the remote identity is the real one.
    $source = $Item
    if ($Item.PSObject.Properties['remoteItem'] -and $Item.remoteItem) { $source = $Item.remoteItem }

    $driveId = "$($source.parentReference.driveId)"
    if (-not $driveId) { $driveId = "$FallbackDriveId" }

    $isFolder = [bool]($source.PSObject.Properties['folder'] -and $source.folder)
    $isPackage = [bool]($source.PSObject.Properties['package'] -and $source.package)
    $resolved = if ($Kind) { $Kind } elseif ($isFolder -or $isPackage) { 'folder' } else { 'file' }

    $childCount = 0
    if ($isFolder -and $source.folder.PSObject.Properties['childCount']) { $childCount = [int]$source.folder.childCount }

    $icon = $(if ($resolved -eq 'folder') { 'folder' } elseif ($resolved -in @('site', 'drive')) { $resolved } else { Get-CBItemIcon -Name "$($source.name)" })
    return [ordered]@{
        id         = "$($source.id)"
        driveId    = $driveId
        name       = "$($source.name)"
        kind       = $resolved
        icon       = $icon
        category   = (Get-CBItemCategory -Icon $icon -Kind $resolved -Name "$($source.name)")
        path       = (Get-CBItemPath -RawPath "$($source.parentReference.path)")
        webUrl     = "$($source.webUrl)"
        modified   = "$($source.lastModifiedDateTime)"
        whenLabel  = (Get-CBItemWhenLabel -Value "$($source.lastModifiedDateTime)" -Kind 'modified')
        size       = $(if ($source.PSObject.Properties['size']) { [long]$source.size } else { 0 })
        childCount = $childCount
    }
}

function ConvertTo-CBInsightItem {
    <#
    .SYNOPSIS
        Normalises one /me/insights/used entry into the picker's item shape, or
        $null when it is not a file we can share.
    .DESCRIPTION
        Insights answer "what has this person been working on", across OneDrive
        AND SharePoint, which is what somebody means by Recent. They are also
        cheap to normalise: resourceReference.id already carries the drive and
        item id as 'drives/{driveId}/items/{itemId}', so a list of twenty needs
        no follow-up call per row.

        Entries that are not driveItems (mail attachments and the like) are
        dropped rather than rendered as something unopenable.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Insight)
    $ref = $Insight.resourceReference
    $id = "$($ref.id)"
    if ($id -notmatch '^drives/(?<drive>[^/]+)/items/(?<item>.+)$') { return $null }
    $driveId = $Matches['drive']
    $itemId = $Matches['item']

    $vis = $Insight.resourceVisualization
    $name = "$($vis.title)"
    if (-not $name) { $name = $itemId }
    # The title often arrives without its extension, so the icon comes from the
    # declared type instead of a name that has nothing to match on.
    $icon = if ($name -match '\.[a-z0-9]{1,8}$') { Get-CBItemIcon -Name $name } else { Get-CBItemIcon -Name "x.$($vis.type)" }

    return [ordered]@{
        id         = $itemId
        driveId    = $driveId
        name       = $name
        kind       = 'file'
        icon       = $icon
        category   = (Get-CBItemCategory -Icon $icon -Kind 'file' -Name $name)
        # Where it lives matters more in a recent list than anywhere else: the
        # same file name appears in three sites and only the container tells
        # them apart.
        path       = "$($vis.containerDisplayName)"
        webUrl     = "$($ref.webUrl)"
        modified   = "$($Insight.lastUsed.lastAccessedDateTime)"
        # "Opened", not "Edited": insights record when somebody LOOKED at
        # something, and most of a recent list was only read.
        whenLabel  = (Get-CBItemWhenLabel -Value "$($Insight.lastUsed.lastAccessedDateTime)" -Kind 'used')
        size       = 0
        childCount = 0
    }
}

function Get-CBRecentItem {
    <#
    .SYNOPSIS
        What this person has been working on lately, most recent first.
    .DESCRIPTION
        /me/drive/recent alone is not enough, and that was the bug: it is driven
        by OneDrive activity, so somebody who works mainly in SharePoint sites
        sees one or two rows and concludes the picker is broken. It also does not
        reliably honour $top.

        So insights lead, because they are the same list Office.com calls Recent
        and they span every site the person touches, and /me/drive/recent follows
        as a fallback and a top-up. Insights can be switched off tenant-wide, in
        which case they 403 and the fallback carries the pane on its own.

        Recency order is preserved, which means this pane deliberately does NOT
        get the folders-first alphabetical sort the other panes want. A "recent"
        list in alphabetical order is just a list.
    .OUTPUTS
        @{ Items; Reason } - Reason explains an empty list rather than leaving
        the picker to imply the person has never opened a file.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, [int]$Top = 50)
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $problems = [System.Collections.Generic.List[string]]::new()

    function Add-Unique {
        param($Item)
        if (-not $Item -or -not $Item.id) { return }
        $key = "$($Item.driveId)|$($Item.id)"
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $items.Add($Item)
    }

    try {
        $r = Invoke-CBGraphAsUser -Caller $Caller -Uri "/me/insights/used?`$top=$Top"
        foreach ($i in @($r.value)) { Add-Unique -Item (ConvertTo-CBInsightItem -Insight $i) }
    }
    catch {
        Write-Warning "Could not read recent items from insights: $($_.Exception.Message)"
        $problems.Add('Office recent-files data is unavailable (an administrator can switch item insights off for the tenant).')
    }

    try {
        $r = Invoke-CBGraphAsUser -Caller $Caller -Uri "/me/drive/recent?`$top=$Top"
        foreach ($i in @($r.value)) { Add-Unique -Item (ConvertTo-CBBrowseItem -Item $i) }
    }
    catch {
        Write-Warning "Could not read recent items from OneDrive: $($_.Exception.Message)"
        $problems.Add('OneDrive recent files are unavailable.')
    }

    $reason = ''
    if ($items.Count -eq 0) {
        $reason = if ($problems.Count -gt 0) { ($problems -join ' ') + ' Use My files or Sites instead.' }
        else { 'Nothing recent to show. Anything you open in SharePoint or OneDrive appears here afterwards.' }
    }
    return @{ Items = @($items); Reason = $reason }
}

function ConvertTo-CBBrowseSite {
    <#
    .SYNOPSIS
        Normalises a Graph site into the same shape, so the picker's first pane
        needs no special case.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Site)
    return [ordered]@{
        id         = "$($Site.id)"
        driveId    = ''
        name       = $(if ($Site.displayName) { "$($Site.displayName)" } else { "$($Site.name)" })
        kind       = 'site'
        icon       = 'site'
        category   = 'SharePoint site'
        path       = $(try { ([Uri]"$($Site.webUrl)").AbsolutePath } catch { '' })
        webUrl     = "$($Site.webUrl)"
        modified   = "$($Site.lastModifiedDateTime)"
        whenLabel  = (Get-CBItemWhenLabel -Value "$($Site.lastModifiedDateTime)" -Kind 'modified')
        size       = 0
        childCount = 0
    }
}

function Set-CBBrowseShareable {
    <#
    .SYNOPSIS
        Marks which rows the picker will let somebody choose, and why not.
    .DESCRIPTION
        This reflects the ADMINISTRATOR'S capability gates only. It is not, and
        cannot be, a check on whether this user may share this particular item:
        Graph exposes no per-item "can I share this" flag, and asking would cost
        a call per row and still not be authoritative at the moment of sharing.

        That is fine, because the share itself runs as the user. If they cannot
        share it, Graph refuses and the reason is shown verbatim. Nothing here is
        load-bearing for security; it exists so the picker does not offer choices
        the tenant has switched off.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Items, $Settings)
    if (-not $Settings) { $Settings = Get-CBSettings }
    foreach ($item in @($Items)) {
        $allowed = $true
        $reason = ''
        switch ("$($item.kind)") {
            'file' {
                if (-not $Settings.sharing.files) { $allowed = $false; $reason = 'An administrator has switched off sharing individual files.' }
            }
            'folder' {
                if (-not $Settings.sharing.folders) { $allowed = $false; $reason = 'An administrator has switched off sharing folders.' }
            }
            default { $allowed = $false; $reason = 'Open this to choose something inside it.' }
        }
        $item.canShare = $allowed
        $item.shareBlockedReason = $reason
    }
    return @($Items)
}

function Get-CBBrowsePane {
    <#
    .SYNOPSIS
        One pane of the picker, as the signed-in user.
    .PARAMETER Pane
        recent   what they have opened lately, wherever it lives
        mydrive  the root of their own OneDrive
        sites    the SharePoint sites they follow, or a site search
        children the contents of a folder, a site or a document library
        search   type-ahead over their files, or within one drive
    .OUTPUTS
        @{ Items; Pane; Breadcrumb; Next }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Caller,
        [Parameter(Mandatory)][ValidateSet('recent', 'mydrive', 'sites', 'children', 'search')][string]$Pane,
        [string]$DriveId,
        [string]$ItemId,
        [string]$SiteId,
        [string]$Query,
        [switch]$FoldersOnly,
        $Settings,
        [int]$Top = 100
    )
    if (-not $Settings) { $Settings = Get-CBSettings }
    $select = '$select=id,name,webUrl,size,lastModifiedDateTime,folder,file,package,parentReference,remoteItem'
    $items = [System.Collections.Generic.List[object]]::new()
    $emptyReason = ''

    switch ($Pane) {
        'recent' {
            $recent = Get-CBRecentItem -Caller $Caller -Top $Top
            foreach ($i in @($recent.Items)) { $items.Add($i) }
            $emptyReason = "$($recent.Reason)"
        }
        'mydrive' {
            $r = Invoke-CBGraphAsUser -Caller $Caller -Uri "/me/drive/root/children?$select&`$top=$Top"
            foreach ($i in @($r.value)) { $items.Add((ConvertTo-CBBrowseItem -Item $i)) }
        }
        'sites' {
            if ($Query) {
                $r = Invoke-CBGraphAsUser -Caller $Caller -Uri ("/sites?`$search=" + [Uri]::EscapeDataString($Query) + "&`$top=$Top")
                foreach ($s in @($r.value)) { $items.Add((ConvertTo-CBBrowseSite -Site $s)) }
            }
            else {
                # Followed sites first: for most people that is the short list
                # they actually work in, and it needs no search term.
                try {
                    $r = Invoke-CBGraphAsUser -Caller $Caller -Uri "/me/followedSites?`$top=$Top"
                    foreach ($s in @($r.value)) { $items.Add((ConvertTo-CBBrowseSite -Site $s)) }
                }
                catch { Write-Warning "Could not read followed sites: $($_.Exception.Message)" }
            }
        }
        'children' {
            if ($SiteId) {
                # A site is a container of document libraries. With exactly one,
                # step straight into it: making somebody click through a list of
                # one is the kind of thing that makes a picker feel like software.
                $site = ConvertTo-CBGraphPathSegment -Value $SiteId -What 'site id'
                $drives = @((Invoke-CBGraphAsUser -Caller $Caller -Uri ('/sites/' + $site + '/drives?$select=id,name,webUrl')).value)
                if ($drives.Count -eq 1) {
                    $DriveId = "$($drives[0].id)"
                    $ItemId = ''
                }
                else {
                    foreach ($d in $drives) {
                        $items.Add([ordered]@{
                                id = "$($d.id)"; driveId = "$($d.id)"; name = "$($d.name)"; kind = 'drive'; icon = 'drive'
                                category = 'Document library'; path = ''; webUrl = "$($d.webUrl)"; modified = ''
                                whenLabel = ''; size = 0; childCount = 0
                            })
                    }
                }
            }
            if ($items.Count -eq 0) {
                if (-not $DriveId) { throw 'Nothing to open: no drive was given.' }
                $drive = ConvertTo-CBGraphPathSegment -Value $DriveId -What 'drive id'
                $path = if ($ItemId) {
                    '/drives/' + $drive + '/items/' + (ConvertTo-CBGraphPathSegment -Value $ItemId -What 'item id') + '/children'
                }
                else { '/drives/' + $drive + '/root/children' }
                $r = Invoke-CBGraphAsUser -Caller $Caller -Uri "$path`?$select&`$top=$Top"
                foreach ($i in @($r.value)) { $items.Add((ConvertTo-CBBrowseItem -Item $i -FallbackDriveId $DriveId)) }
            }
        }
        'search' {
            if ("$Query".Trim().Length -lt 2) { return [pscustomobject]@{ Items = @(); Pane = $Pane; Breadcrumb = @(); Next = '' } }
            $q = [Uri]::EscapeDataString(("$Query".Replace("'", "''")))
            $path = if ($DriveId) {
                '/drives/' + (ConvertTo-CBGraphPathSegment -Value $DriveId -What 'drive id') + "/root/search(q='$q')"
            }
            else { "/me/drive/search(q='$q')" }
            $r = Invoke-CBGraphAsUser -Caller $Caller -Uri "$path`?`$top=$Top"
            foreach ($i in @($r.value)) { $items.Add((ConvertTo-CBBrowseItem -Item $i -FallbackDriveId $DriveId)) }
        }
    }

    $result = @($items)
    if ($FoldersOnly) {
        $result = @($result | Where-Object { $_.kind -in @('folder', 'site', 'drive') })
        if ($Pane -eq 'recent' -and $result.Count -eq 0 -and -not $emptyReason) {
            $emptyReason = 'None of your recent items are folders. Use My files or Sites to pick one.'
        }
    }
    # Folders before files, then alphabetically. Graph returns storage order,
    # which is nobody's idea of a useful list. Recent is the exception: it is
    # ordered by when you last opened things, and re-sorting it alphabetically
    # would throw away the only thing that makes it "recent".
    if ($Pane -ne 'recent') {
        $result = @($result | Sort-Object -Property @{ Expression = { $(if ($_.kind -eq 'file') { 1 } else { 0 }) } }, @{ Expression = { "$($_.name)" } })
    }
    $result = @(Set-CBBrowseShareable -Items $result -Settings $Settings)

    return [pscustomobject]@{ Items = $result; Pane = $Pane; Breadcrumb = @(); Next = ''; EmptyReason = $emptyReason }
}

function Get-CBDriveItem {
    <#
    .SYNOPSIS
        One drive item, read as the user. Used before sharing so the confirmation
        names what is really being shared rather than what the client claimed.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)]$Caller, [Parameter(Mandatory)][string]$DriveId, [Parameter(Mandatory)][string]$ItemId)
    $uri = '/drives/' + (ConvertTo-CBGraphPathSegment -Value $DriveId -What 'drive id') +
    '/items/' + (ConvertTo-CBGraphPathSegment -Value $ItemId -What 'item id') +
    '?$select=id,name,webUrl,size,lastModifiedDateTime,folder,file,package,parentReference'
    $item = Invoke-CBGraphAsUser -Caller $Caller -Uri $uri
    if (-not $item.id) { return $null }
    return (ConvertTo-CBBrowseItem -Item $item -FallbackDriveId $DriveId)
}
