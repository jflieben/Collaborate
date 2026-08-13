using namespace System.Net

# Preview and test-send for the email editor.
#
#   { key, settings?, preview: true }  -> render with sample data, return the HTML
#   { key, settings?, preview: false } -> also send it to the signed-in admin
#
# Passing unsaved settings is deliberate: an admin editing a template sees the
# preview update as they type, before committing anything. The test send goes to
# the caller and nowhere else, and it ignores simulation mode, because an admin
# who asked to see the mail should receive the mail.

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

    $body = ConvertFrom-CBRequestBody -Body $Request.Body
    $key = "$($body.key)".Trim()
    if (-not $key) { Send-Json -Status 400 -Object @{ error = 'No template was named.' }; return }

    $entry = Get-CBEmailCatalog | Where-Object { $_.key -eq $key } | Select-Object -First 1
    if (-not $entry) { Send-Json -Status 400 -Object @{ error = "'$key' is not a template Collaborate sends." }; return }

    $settings = if ($body.settings) { [pscustomobject](ConvertTo-CBSanitisedSettings -Raw $body.settings) } else { Get-CBSettings }
    $values = Get-CBSampleTokenValue -Settings $settings -RecipientName $caller.DisplayName -RecipientEmail $caller.Upn

    $tpl = $settings.emails.$key
    $unknown = Get-CBTemplateUnknownToken -Template ("$($tpl.subject) $($tpl.html)") -Allowed $entry.tokens
    $rendered = Get-CBRenderedEmail -Key $key -Values $values -Settings $settings

    $preview = ConvertTo-CBBool -Value $body.preview -Default $true
    $sent = $false
    $sendError = ''
    if (-not $preview) {
        if (-not $caller.Upn) { Send-Json -Status 400 -Object @{ error = 'Your account has no email address to send a test to.' }; return }
        try {
            $sent = Send-CBTemplateMail -Key $key -To $caller.Upn -Values $values -Settings $settings -Force
        }
        catch {
            $sendError = $_.Exception.Message
            Write-Warning "Test send of '$key' failed: $sendError"
        }
        if ($sent) { Write-CBSystemActivity -EventName "Test email sent ($($entry.label))" -Actor $caller.Upn }
    }

    $result = @{
        key           = $key
        subject       = $rendered.Subject
        html          = $rendered.Html
        enabled       = $rendered.Enabled
        unknownTokens = @($unknown)
        sent          = $sent
        sentTo        = $(if ($sent) { $caller.Upn } else { '' })
    }
    if ($sendError) { $result.error = "The preview rendered, but sending failed: $sendError" }
    Send-Json -Status 200 -Object $result
}
catch {
    Write-Error "TestMailApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
