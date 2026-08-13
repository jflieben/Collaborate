# Blob storage access (managed identity / AAD).
#
# Two accounts are reachable from here and they are deliberately different:
#
#   * The STATE account (Get-CBConfig.BlobEndpoint) holds the config blob and
#     the master copy of the branding logo. It is private and never public.
#   * The PUBLIC account (Get-CBConfig.PublicBlobEndpoint) hosts the welcome page
#     external guests land on after redeeming their invitation. The app can write
#     there so branding stays editable without a redeploy. That account holds no
#     data, no tokens and no authentication, which is what makes the write access
#     acceptable; see SECURITY.md.

function Invoke-CBBlob {
    <#
    .SYNOPSIS
        Low-level Azure Blob REST call with managed-identity (AAD) auth.
    .PARAMETER Path
        Path appended to the endpoint, e.g. "container/blob.json" or
        "container?restype=container".
    .PARAMETER Endpoint
        Blob service endpoint. Defaults to the private state account.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Put', 'Delete', 'Head')][string]$Method = 'Get',
        $Body,
        [string]$Endpoint,
        [hashtable]$ExtraHeaders
    )
    $cfg = Get-CBConfig
    if (-not $Endpoint) { $Endpoint = $cfg.BlobEndpoint }
    $uri = '{0}/{1}' -f $Endpoint.TrimEnd('/'), $Path

    $headers = @{
        Authorization  = "Bearer $(Get-CBStorageToken)"
        'x-ms-version' = '2021-08-06'
        'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
    }
    # Content-Type is a CONTENT header, not a request header, so it goes on the
    # -ContentType parameter rather than into -Headers. Left in the header bag it
    # is applied inconsistently, and a byte[] body with no explicit content type
    # is sent as something the blob then serves as something else.
    $contentType = ''
    if ($ExtraHeaders) {
        $ExtraHeaders.GetEnumerator() | ForEach-Object {
            if ("$($_.Key)" -ieq 'Content-Type') { $contentType = "$($_.Value)" } else { $headers[$_.Key] = $_.Value }
        }
    }

    $params = @{
        Method                  = $Method
        Uri                     = $uri
        Headers                 = $headers
        ErrorAction             = 'Stop'
        StatusCodeVariable      = 'statusCode'
        SkipHttpErrorCheck      = $true
        ResponseHeadersVariable = 'respHeaders'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params.Body = $Body
        if ($contentType) { $params.ContentType = $contentType }
    }
    elseif ($contentType) { $headers['Content-Type'] = $contentType }

    $response = Invoke-RestMethod @params
    return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
}

function Initialize-CBConfigContainer {
    [CmdletBinding()] param()
    $cfg = Get-CBConfig
    $r = Invoke-CBBlob -Method Put -Path ("{0}?restype=container" -f $cfg.ConfigContainer) -ExtraHeaders @{ 'Content-Length' = '0' }
    if ($r.StatusCode -ge 400 -and $r.StatusCode -ne 409) {
        throw "Failed to create config container '$($cfg.ConfigContainer)' (HTTP $($r.StatusCode))."
    }
}

function Get-CBBlobText {
    <#
    .SYNOPSIS
        Returns the text content of a blob in the config container, or $null (404).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-CBConfig
    $r = Invoke-CBBlob -Method Get -Path ('{0}/{1}' -f $cfg.ConfigContainer, $Name)
    if ($r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 400) { throw "Reading blob '$Name' failed (HTTP $($r.StatusCode))." }
    if ($r.Body -is [string]) { return $r.Body }
    return ($r.Body | ConvertTo-Json -Depth 30)   # ConvertFrom auto-parsed JSON; re-serialise to text
}

function Set-CBBlobText {
    <#
    .SYNOPSIS
        Writes (overwrites) a block blob in the config container.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content,
        [string]$ContentType = 'application/json'
    )
    $cfg = Get-CBConfig
    $r = Invoke-CBBlob -Method Put -Path ('{0}/{1}' -f $cfg.ConfigContainer, $Name) -Body $Content -ExtraHeaders @{
        'x-ms-blob-type' = 'BlockBlob'
        'Content-Type'   = $ContentType
    }
    if ($r.StatusCode -ge 400) { throw "Writing blob '$Name' failed (HTTP $($r.StatusCode))." }
}

function Get-CBBlobBytes {
    <#
    .SYNOPSIS
        Returns a blob from the config container as raw bytes, or $null (404).
        Used for the branding logo, whose master copy lives in the private
        account.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Name)
    $cfg = Get-CBConfig
    $uri = '{0}/{1}/{2}' -f $cfg.BlobEndpoint, $cfg.ConfigContainer, $Name
    $headers = @{
        Authorization  = "Bearer $(Get-CBStorageToken)"
        'x-ms-version' = '2021-08-06'
        'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
    }
    $resp = Invoke-WebRequest -Method Get -Uri $uri -Headers $headers -SkipHttpErrorCheck -ErrorAction Stop
    if ($resp.StatusCode -eq 404) { return $null }
    if ($resp.StatusCode -ge 400) { throw "Reading blob '$Name' failed (HTTP $($resp.StatusCode))." }

    # RawContentStream, never .Content. Invoke-WebRequest decides the type of
    # .Content from the response's content type: text-ish gives a STRING, and a
    # string round-tripped through UTF-8 is not the PNG that went in. It still
    # writes, still returns 200, and still renders as a broken image, which is a
    # long way to travel to find out. The stream is the bytes, whatever the
    # header said.
    # The unary comma matters. `return $someByteArray` puts the array into the
    # output stream, which UNROLLS it, and the caller's assignment collects the
    # elements back into an Object[]. It still holds the right numbers, so it
    # looks fine, and then every type check downstream disagrees.
    if ($resp.RawContentStream) {
        $resp.RawContentStream.Position = 0
        return , ([byte[]]$resp.RawContentStream.ToArray())
    }
    if ($resp.Content -is [byte[]]) { return , ([byte[]]$resp.Content) }
    throw "Blob '$Name' came back as $($resp.Content.GetType().Name) rather than bytes; refusing to copy it, because doing so would silently corrupt it."
}

function Set-CBBlobBytes {
    <#
    .SYNOPSIS
        Writes raw bytes to a block blob in the config container.
    #>
    [CmdletBinding()] param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ContentType
    )
    $cfg = Get-CBConfig
    $r = Invoke-CBBlob -Method Put -Path ('{0}/{1}' -f $cfg.ConfigContainer, $Name) -Body $Bytes -ExtraHeaders @{
        'x-ms-blob-type' = 'BlockBlob'
        'Content-Type'   = $ContentType
    }
    if ($r.StatusCode -ge 400) { throw "Writing blob '$Name' failed (HTTP $($r.StatusCode))." }
}

# --- The public welcome site -------------------------------------------------
# Container names are quoted with single quotes throughout because the static
# website container is literally called $web and PowerShell would otherwise try
# to expand it as a variable.

function Test-CBPublicSiteConfigured {
    [CmdletBinding()] param()
    return [bool]((Get-CBConfig).PublicBlobEndpoint)
}

function Publish-CBPublicBlob {
    <#
    .SYNOPSIS
        Writes a blob to the PUBLIC welcome-site account.
    .PARAMETER Container
        '$web' for the page itself, 'assets' for the logo and branding.json.
    .PARAMETER CacheSeconds
        Cache-Control max-age. The page is deliberately short (a branding change
        should show up quickly) and assets slightly longer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Content,
        [Parameter(Mandatory)][string]$ContentType,
        [int]$CacheSeconds = 60
    )
    # First, before anything is looked up or sent. An image handed over as a
    # STRING is a corruption that succeeds: the PUT returns 201, the GET returns
    # 200, and the browser draws a broken image icon.
    #
    # An image handed over as an Object[] of bytes, on the other hand, is fine
    # and extremely common: `return $bytes` and `$x = if (...) { $bytes }` both
    # unroll a byte[] into the output stream, and the assignment collects it back
    # as Object[]. Rejecting that would refuse correct data on a technicality, so
    # it is normalised instead. Only text is refused, because only text is wrong.
    if ($ContentType -like 'image/*') {
        if ($Content -is [string]) {
            throw "Refusing to publish '$Name' as $ContentType from a string. Text that has been through UTF-8 is not an image any more, and the failure would be invisible: the write succeeds and the browser shows a broken icon."
        }
        if ($Content -isnot [byte[]]) {
            try { $Content = [byte[]]$Content }
            catch { throw "Refusing to publish '$Name' as $ContentType from a $($Content.GetType().Name), which does not convert to bytes." }
        }
    }
    $cfg = Get-CBConfig
    if (-not $cfg.PublicBlobEndpoint) {
        throw 'The public welcome site is not configured (CB_PUBLIC_BLOB_ENDPOINT is empty). Re-run the deployment.'
    }
    $r = Invoke-CBBlob -Method Put -Endpoint $cfg.PublicBlobEndpoint -Path ('{0}/{1}' -f $Container, $Name) -Body $Content -ExtraHeaders @{
        'x-ms-blob-type'          = 'BlockBlob'
        'Content-Type'            = $ContentType
        'x-ms-blob-cache-control' = "public, max-age=$CacheSeconds"
    }
    if ($r.StatusCode -ge 400) { throw "Publishing '$Container/$Name' to the public site failed (HTTP $($r.StatusCode))." }
}

function Get-CBPublicBlobLength {
    <#
    .SYNOPSIS
        How many bytes the public site is actually serving for a path, or -1 when
        it cannot be asked.
    .DESCRIPTION
        Used to check that what was published is the size of what was handed over.
        A mangled image and a correct one both answer 200, and the length is the
        cheapest thing that tells them apart.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$Name)
    try {
        # Read it rather than HEAD it. Content-Length on a HEAD response is a
        # content header, and whether it survives into PowerShell's response
        # headers depends on the request; a logo is a few kilobytes and reading
        # it also proves it can be read at all.
        $uri = '{0}/{1}/{2}' -f (Get-CBConfig).PublicBlobEndpoint.TrimEnd('/'), $Container, $Name
        $headers = @{
            Authorization  = "Bearer $(Get-CBStorageToken)"
            'x-ms-version' = '2021-08-06'
            'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
        }
        $resp = Invoke-WebRequest -Method Get -Uri $uri -Headers $headers -SkipHttpErrorCheck -ErrorAction Stop
        if ($resp.StatusCode -eq 404) { return 0 }          # published nothing at all
        if ($resp.StatusCode -ge 400) { return -1 }         # cannot tell
        if ($resp.RawContentStream) { return [int]$resp.RawContentStream.Length }
        return -1
    }
    catch {
        Write-Warning "Could not check the published size of '$Name': $($_.Exception.Message)"
        return -1
    }
}

function Test-CBPublicSiteWritable {
    <#
    .SYNOPSIS
        Proves the managed identity can actually write to the public site, by
        writing and deleting a probe blob.
    .DESCRIPTION
        Worth checking explicitly: the role assignment on that account is the one
        piece of the deployment that can silently be missing, and the symptom
        (guests landing on a page that was never published) would only appear at
        the worst moment.
    #>
    [CmdletBinding()] param()
    $cfg = Get-CBConfig
    if (-not $cfg.PublicBlobEndpoint) { return @{ Ok = $false; Detail = 'No public welcome site is configured.' } }
    $name = 'assets/.write-probe'
    try {
        Publish-CBPublicBlob -Container '$web' -Name $name -Content 'ok' -ContentType 'text/plain' -CacheSeconds 0
        $null = Invoke-CBBlob -Method Delete -Endpoint $cfg.PublicBlobEndpoint -Path ('$web/' + $name)
        return @{ Ok = $true; Detail = 'The welcome site can be published to.' }
    }
    catch {
        return @{ Ok = $false; Detail = "Collaborate cannot write to the public welcome site: $($_.Exception.Message)" }
    }
}

function Get-CBPublicBlobText {
    <#
    .SYNOPSIS
        Reads a blob back from the public account (used by the Watchdog to
        detect tampering with the published welcome page). Returns $null on 404.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$Name)
    $cfg = Get-CBConfig
    if (-not $cfg.PublicBlobEndpoint) { return $null }
    $r = Invoke-CBBlob -Method Get -Endpoint $cfg.PublicBlobEndpoint -Path ('{0}/{1}' -f $Container, $Name)
    if ($r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 400) { throw "Reading '$Container/$Name' from the public site failed (HTTP $($r.StatusCode))." }
    if ($r.Body -is [string]) { return $r.Body }
    return "$($r.Body)"
}

function Get-CBTextHash {
    <#
    .SYNOPSIS
        SHA-256 of a UTF-8 string, uppercase hex. Used to record what the app
        published so drift can be detected later.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($bytes)) -replace '-', '')
}
