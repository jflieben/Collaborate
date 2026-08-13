# Durable state in Azure Table storage.
#
# Table storage (not a database) because it is cheap, schemaless and supports
# Azure AD authentication, so the tool keeps its "managed identity only, no
# keys" property. The identity is granted "Storage Table Data Contributor" on
# the state storage account by the deploy script.
#
# Tables (see Get-CBTableNames):
#   Guests             - one row per guest, PartitionKey = owner object id (or 'orphaned')
#   ActivityLog        - chronological audit feed shown in the portal
#   FunctionHeartbeats - per-function last run/status/error
#   SafetyState        - storm-guard counters + paused latch

function Get-CBStorageToken {
    [CmdletBinding()] param()
    return Get-CBManagedIdentityToken -Resource (Get-CBConfig).StorageResource
}

function ConvertTo-CBODataKey {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

function Invoke-CBTable {
    <#
    .SYNOPSIS
        Low-level Azure Table REST call with managed-identity (AAD) auth.
    .PARAMETER Path
        Path appended to the table endpoint, e.g. "Tables" or
        "Guests(PartitionKey='x',RowKey='y')".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Post', 'Put', 'Merge', 'Delete')][string]$Method = 'Get',
        $Body,
        [hashtable]$ExtraHeaders,
        [switch]$Raw
    )

    $cfg = Get-CBConfig
    $uri = '{0}/{1}' -f $cfg.TableEndpoint, $Path

    $headers = @{
        Authorization      = "Bearer $(Get-CBStorageToken)"
        Accept             = 'application/json;odata=nometadata'
        'x-ms-version'     = '2019-12-12'
        'x-ms-date'        = [DateTime]::UtcNow.ToString('R')
        DataServiceVersion = '3.0;NetFx'
    }
    if ($ExtraHeaders) { $ExtraHeaders.GetEnumerator() | ForEach-Object { $headers[$_.Key] = $_.Value } }

    $params = @{
        Method                  = $Method
        Uri                     = $uri
        Headers                 = $headers
        ErrorAction             = 'Stop'
        StatusCodeVariable      = 'statusCode'
        SkipHttpErrorCheck      = $true
        ResponseHeadersVariable = 'respHeaders'
    }
    # Invoke-RestMethod supports custom verbs via -CustomMethod; MERGE needs it.
    if ($Method -eq 'Merge') {
        $params.Remove('Method')
        $params.CustomMethod = 'MERGE'
    }
    if ($null -ne $Body) {
        $headers['Content-Type'] = 'application/json'
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    }

    $response = Invoke-RestMethod @params

    if ($Raw) {
        return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
    }
    if ($statusCode -ge 400 -and $statusCode -ne 404) {
        $detail = if ($response) { ($response | ConvertTo-Json -Depth 8 -Compress) } else { '(no body)' }
        throw "Table $Method $uri failed with HTTP $statusCode`: $detail"
    }
    # Headers are always returned: Table pagination tokens arrive as headers.
    return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
}

$script:CBTablesReady = $false

function Initialize-CBTables {
    <#
    .SYNOPSIS
        Ensures all required tables (and the config container and work queue)
        exist. Safe and cheap to call repeatedly: the REST calls run once per
        worker.
    #>
    [CmdletBinding()] param([switch]$Force)
    if ($script:CBTablesReady -and -not $Force) { return }
    $tables = Get-CBTableNames
    foreach ($name in @($tables.Guests, $tables.Activity, $tables.Heartbeats, $tables.Safety)) {
        $result = Invoke-CBTable -Method Post -Path 'Tables' -Body @{ TableName = $name } -Raw
        if ($result.StatusCode -eq 409) { continue }         # already exists
        if ($result.StatusCode -ge 400) {
            $detail = if ($result.Body) { ($result.Body | ConvertTo-Json -Depth 8 -Compress) } else { '' }
            throw "Failed to create table '$name' (HTTP $($result.StatusCode)): $detail"
        }
        Write-Host "Created table '$name'."
    }
    try { Initialize-CBConfigContainer } catch { Write-Warning "Could not ensure the config container: $($_.Exception.Message)" }
    try { New-CBQueue } catch { Write-Warning "Could not ensure the guest actions queue: $($_.Exception.Message)" }
    # The poison queue is created by the Functions host only when a message
    # actually fails five times. Creating it up front means Diagnostics can
    # report a real count of zero instead of "this queue does not exist", which
    # is not the same thing and reads like a fault when it is the opposite.
    try { New-CBQueue -Name ((Get-CBConfig).GuestActionQueue + '-poison') }
    catch { Write-Warning "Could not ensure the poison queue: $($_.Exception.Message)" }
    $script:CBTablesReady = $true
}

function Set-CBTableEntity {
    <#
    .SYNOPSIS
        Insert-or-replace an entity. Properties are stored as strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][hashtable]$Properties
    )
    $entity = @{ PartitionKey = $PartitionKey; RowKey = $RowKey }
    foreach ($kvp in $Properties.GetEnumerator()) {
        $entity[$kvp.Key] = if ($null -eq $kvp.Value) { '' } else { [string]$kvp.Value }
    }
    $pk = ConvertTo-CBODataKey $PartitionKey
    $rk = ConvertTo-CBODataKey $RowKey
    $path = "$Table(PartitionKey='$pk',RowKey='$rk')"
    # PUT to the entity address is Insert-Or-Replace (upsert). It must NOT carry
    # an If-Match header: that turns it into a conditional update which fails
    # when the entity does not yet exist.
    $null = Invoke-CBTable -Method Put -Path $path -Body $entity
}

function Merge-CBTableEntity {
    <#
    .SYNOPSIS
        Insert-Or-Merge an entity: listed properties are updated, existing
        properties NOT listed are preserved (unlike Set-CBTableEntity, which
        replaces the whole entity). MERGE without If-Match is the upsert form.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][hashtable]$Properties
    )
    $entity = @{ PartitionKey = $PartitionKey; RowKey = $RowKey }
    foreach ($kvp in $Properties.GetEnumerator()) {
        $entity[$kvp.Key] = if ($null -eq $kvp.Value) { '' } else { [string]$kvp.Value }
    }
    $pk = ConvertTo-CBODataKey $PartitionKey
    $rk = ConvertTo-CBODataKey $RowKey
    $path = "$Table(PartitionKey='$pk',RowKey='$rk')"
    $null = Invoke-CBTable -Method Merge -Path $path -Body $entity
}

function Get-CBTableEntity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )
    $pk = ConvertTo-CBODataKey $PartitionKey
    $rk = ConvertTo-CBODataKey $RowKey
    $result = Invoke-CBTable -Method Get -Path "$Table(PartitionKey='$pk',RowKey='$rk')"
    if ($result.StatusCode -eq 404) { return $null }
    return $result.Body
}

function Remove-CBTableEntity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )
    $pk = ConvertTo-CBODataKey $PartitionKey
    $rk = ConvertTo-CBODataKey $RowKey
    $path = "$Table(PartitionKey='$pk',RowKey='$rk')"
    $result = Invoke-CBTable -Method Delete -Path $path -ExtraHeaders @{ 'If-Match' = '*' } -Raw
    if ($result.StatusCode -ge 400 -and $result.StatusCode -ne 404) {
        throw "Failed to delete entity $path (HTTP $($result.StatusCode))."
    }
}

function Get-CBTablePage {
    <#
    .SYNOPSIS
        Returns ONE page of entities plus the continuation token for the next
        page, for callers that paginate (the activity log, the guest list).
    .NOTES
        With a $filter, Table storage may return fewer rows than -Top yet still
        hand back a continuation token; an empty page does not mean the end.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [string]$Filter,
        [int]$Top = 50,
        [string]$NextPartitionKey,
        [string]$NextRowKey
    )
    $parts = @()
    if ($Filter) { $parts += '$filter={0}' -f [Uri]::EscapeDataString($Filter) }
    if ($Top -gt 0) { $parts += ('$top={0}' -f $Top) }
    if ($NextPartitionKey) { $parts += 'NextPartitionKey={0}' -f [Uri]::EscapeDataString($NextPartitionKey) }
    if ($NextRowKey) { $parts += 'NextRowKey={0}' -f [Uri]::EscapeDataString($NextRowKey) }
    $query = if ($parts) { '?' + ($parts -join '&') } else { '' }

    $result = Invoke-CBTable -Method Get -Path "$Table()$query"
    $items = @()
    if ($result.Body -and ($result.Body.PSObject.Properties.Name -contains 'value')) { $items = @($result.Body.value) }
    $nextPk = $null; $nextRk = $null
    if ($result.Headers) {
        if ($result.Headers['x-ms-continuation-NextPartitionKey']) { $nextPk = $result.Headers['x-ms-continuation-NextPartitionKey'] | Select-Object -First 1 }
        if ($result.Headers['x-ms-continuation-NextRowKey'])       { $nextRk = $result.Headers['x-ms-continuation-NextRowKey']       | Select-Object -First 1 }
    }
    return [pscustomobject]@{ Items = $items; NextPartitionKey = $nextPk; NextRowKey = $nextRk }
}

function Get-CBTableEntities {
    <#
    .SYNOPSIS
        Returns all entities in a table (following continuation tokens), or a
        filtered subset via -Filter (OData $filter expression).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [string]$Filter,
        [int]$Top   # 0/unset = all
    )
    $all = [System.Collections.Generic.List[object]]::new()
    $parts = @()
    if ($Filter) { $parts += '$filter={0}' -f [Uri]::EscapeDataString($Filter) }
    if ($Top -gt 0) { $parts += ('$top={0}' -f $Top) }
    $query = if ($parts) { '?' + ($parts -join '&') } else { '' }
    $path = "$Table()$query"

    while ($true) {
        $result = Invoke-CBTable -Method Get -Path $path
        if ($result.StatusCode -eq 404) { break }
        if ($result.Body -and ($result.Body.PSObject.Properties.Name -contains 'value')) {
            foreach ($item in $result.Body.value) { $all.Add($item) }
        }
        if ($Top -gt 0 -and $all.Count -ge $Top) { break }
        # Continuation tokens arrive as response headers; re-query with them.
        $nextPk = $null; $nextRk = $null
        if ($result.Headers) {
            if ($result.Headers['x-ms-continuation-NextPartitionKey']) { $nextPk = $result.Headers['x-ms-continuation-NextPartitionKey'] | Select-Object -First 1 }
            if ($result.Headers['x-ms-continuation-NextRowKey'])       { $nextRk = $result.Headers['x-ms-continuation-NextRowKey']       | Select-Object -First 1 }
        }
        if (-not $nextPk) { break }
        $sep = if ($query) { '&' } else { '?' }
        $cont = 'NextPartitionKey={0}' -f [Uri]::EscapeDataString($nextPk)
        if ($nextRk) { $cont += '&NextRowKey={0}' -f [Uri]::EscapeDataString($nextRk) }
        $path = "$Table()$query$sep$cont"
    }
    return $all
}

function Invoke-CBTableBatchDelete {
    <#
    .SYNOPSIS
        Deletes many entities that share a PartitionKey in one entity-group
        transaction (100 per batch) instead of one HTTP call each. Falls back to
        per-row deletes for any chunk the batch rejects. Returns the count.
    .NOTES
        The Table $batch payload is multipart/mixed and MUST use CRLF line
        endings. The host runs on Linux, so build them explicitly rather than
        relying on the platform newline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string[]]$RowKeys
    )
    if (-not $RowKeys -or $RowKeys.Count -eq 0) { return 0 }
    $cfg = Get-CBConfig
    $pk = ConvertTo-CBODataKey $PartitionKey
    $CRLF = "`r`n"
    $deleted = 0

    for ($i = 0; $i -lt $RowKeys.Count; $i += 100) {
        $end = [Math]::Min($i + 99, $RowKeys.Count - 1)
        $chunk = @($RowKeys[$i..$end])
        $batchId = 'batch_' + [Guid]::NewGuid().ToString()
        $changesetId = 'changeset_' + [Guid]::NewGuid().ToString()

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("--$batchId")
        $lines.Add("Content-Type: multipart/mixed; boundary=$changesetId")
        $lines.Add('')
        foreach ($rk in $chunk) {
            $rke = ConvertTo-CBODataKey $rk
            $url = "$($cfg.TableEndpoint)/$Table(PartitionKey='$pk',RowKey='$rke')"
            $lines.Add("--$changesetId")
            $lines.Add('Content-Type: application/http')
            $lines.Add('Content-Transfer-Encoding: binary')
            $lines.Add('')
            $lines.Add("DELETE $url HTTP/1.1")
            $lines.Add('If-Match: *')
            $lines.Add('Accept: application/json;odata=nometadata')
            $lines.Add('')
        }
        $lines.Add("--$changesetId--")
        $lines.Add("--$batchId--")
        $body = ($lines -join $CRLF) + $CRLF

        $headers = @{
            Authorization  = "Bearer $(Get-CBStorageToken)"
            'x-ms-version' = '2019-12-12'
            'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
            Accept         = 'application/json;odata=nometadata'
        }
        $uri = '{0}/$batch' -f $cfg.TableEndpoint
        try {
            $null = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body `
                -ContentType "multipart/mixed; boundary=$batchId" -SkipHttpErrorCheck -StatusCodeVariable sc -ErrorAction Stop
        }
        catch { $sc = 500 }
        if ($sc -ge 400) {
            Write-Warning "Table batch delete chunk failed (HTTP $sc); falling back to per-row deletes."
            foreach ($rk in $chunk) { try { Remove-CBTableEntity -Table $Table -PartitionKey $PartitionKey -RowKey $rk; $deleted++ } catch { } }
        }
        else { $deleted += $chunk.Count }
    }
    return $deleted
}
