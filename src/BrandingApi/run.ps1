using namespace System.Net

# Logo upload and removal.
#
# The image arrives as base64 in JSON rather than as a raw binary body: it keeps
# the client trivial (FileReader gives base64 directly) and avoids the encoding
# surprises binary bodies bring through the Functions worker.
#
# Nothing about the file is taken on trust. The content type is decided by
# reading the magic bytes, the size is capped, and the stored name is generated
# here, so a caller cannot choose what gets written to the public site.

param($Request, $TriggerMetadata)

function Send-Json {
    param([int]$Status, $Object)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]$Status
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($Object | ConvertTo-Json -Depth 12)
        })
}

try {
    $caller = Test-CBAdminRequest -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    Initialize-CBTables
    $settings = Get-CBSettings

    if ($Request.Method -eq 'DELETE') {
        $settings.branding.logoFile = ''
        $settings.branding.logoContentType = ''
        $settings.branding.logoUpdatedUtc = ''
        $settings = Publish-CBWelcomeSite -Settings $settings -Actor $caller.Upn
        $saved = Save-CBSettings -Raw $settings
        Write-CBSystemActivity -EventName 'Logo removed' -Actor $caller.Upn
        Send-Json -Status 200 -Object @{ ok = $true; logoUrl = ''; settings = $saved }
        return
    }

    $body = ConvertFrom-CBRequestBody -Body $Request.Body
    $content = "$($body.contentBase64)"
    if (-not $content) { Send-Json -Status 400 -Object @{ error = 'No image was supplied.' }; return }
    # Accept a data: URL as-is, since that is what FileReader produces.
    if ($content -match '^data:[^;]+;base64,(.+)$') { $content = $Matches[1] }

    $bytes = $null
    try { $bytes = [Convert]::FromBase64String($content) }
    catch { Send-Json -Status 400 -Object @{ error = 'That file could not be read as an image.' }; return }

    try { $stored = Set-CBBrandingLogo -Bytes $bytes }
    catch { Send-Json -Status 400 -Object @{ error = $_.Exception.Message }; return }

    $settings.branding.logoFile = $stored.FileName
    $settings.branding.logoContentType = $stored.ContentType
    $settings.branding.logoUpdatedUtc = [DateTimeOffset]::UtcNow.ToString('o')

    # The bytes go straight through rather than being read back out of storage:
    # one round trip fewer, and one fewer place for an image to be turned into a
    # string on the way.
    #
    # If the public copy cannot be published, the upload FAILS. Recording the
    # logo anyway is what produced a broken icon in the portal, a wordmark on the
    # welcome page, and no explanation anywhere: the settings said there was a
    # logo and the site had never received one. Settings are not saved, so the
    # tenant keeps whatever logo it had.
    try { $settings = Publish-CBWelcomeSite -Settings $settings -Actor $caller.Upn -LogoBytes $bytes }
    catch {
        Write-Error "Logo upload failed: $($_.Exception.Message)"
        Send-Json -Status 502 -Object @{ error = "$($_.Exception.Message) Nothing was changed, so the logo you had before is still in place." }
        return
    }

    $saved = Save-CBSettings -Raw $settings
    Write-CBSystemActivity -EventName 'Logo updated' -Actor $caller.Upn -Detail @{ file = $stored.FileName; type = $stored.ContentType; bytes = $bytes.Length }

    Send-Json -Status 200 -Object @{ ok = $true; logoUrl = (Get-CBPublicLogoUrl -Settings $saved); settings = $saved }
}
catch {
    Write-Error "BrandingApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
