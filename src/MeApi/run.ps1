using namespace System.Net

# The portal's first call: who am I, what may I do, and how should this look.
#
# authLevel is 'anonymous' only in the Functions sense. App Service Easy Auth
# sits in front, and Resolve-CBCaller independently validates the bearer token
# and fails closed, so an unauthenticated caller gets a 401 either way.

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
    $caller = Resolve-CBCaller -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    Initialize-CBTables

    # POST carries this person's own portal preferences and nothing else. It sets
    # no policy, so it needs no role beyond being signed in.
    if ("$($Request.Method)".ToUpperInvariant() -eq 'POST') {
        $body = $Request.Body
        if ($body -is [string]) { $body = $body | ConvertFrom-Json }
        $null = Set-CBUserLanguage -Oid $caller.Oid -Language $body.language
    }

    Send-Json -Status 200 -Object (Get-CBMePayload -Caller $caller)
}
catch {
    Write-Error "MeApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
