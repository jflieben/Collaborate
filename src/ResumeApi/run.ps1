using namespace System.Net

# Clears the storm-guard pause after an administrator has reviewed why it
# tripped. Resuming also resets today's counters, so the work that hit the cap
# can actually proceed rather than tripping again on the next message.

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
    $caller = Test-CBAdminRequest -Request $Request
    if (-not $caller.Ok) { Send-Json -Status $caller.Status -Object @{ error = $caller.Error }; return }

    Initialize-CBTables
    $was = Get-CBPausedEntity
    Clear-CBPaused -Actor $caller.Upn
    Write-Host "Storm guard resumed by $($caller.Upn) (was: $($was.Reason))."

    Send-Json -Status 200 -Object @{
        ok       = $true
        resumedBy = $caller.Upn
        wasPausedFor = "$($was.Reason)"
        safety   = (Get-CBSafetyStatus)
    }
}
catch {
    Write-Error "ResumeApi failed: $($_.Exception.Message)"
    Send-Json -Status 500 -Object @{ error = $_.Exception.Message }
}
