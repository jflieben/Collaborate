# Pester tests for Collaborate's pure logic. No Azure, no Graph, no tenant.
# Run: Invoke-Pester ./tests
#
# What is worth testing here is everything that decides whether something is
# safe: the settings sanitiser, the welcome page's redirect allowlist, the email
# renderer's encoding, and the expiry maths. Anything that needs a network call
# is verified in the live smoke test instead.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\Collaborate\Collaborate.psd1'
    Import-Module $modulePath -Force
}

Describe 'Test-CBEmailAddress' {
    It 'accepts a normal address' { Test-CBEmailAddress -Address 'a@contoso.com' | Should -BeTrue }
    It 'accepts empty (means unset)' { Test-CBEmailAddress -Address '' | Should -BeTrue }
    It 'rejects a bare word' { Test-CBEmailAddress -Address 'nope' | Should -BeFalse }
    It 'rejects a missing TLD' { Test-CBEmailAddress -Address 'a@b' | Should -BeFalse }
    It 'rejects an embedded space' { Test-CBEmailAddress -Address 'a b@c.com' | Should -BeFalse }
}

Describe 'ConvertTo-CBHexColor' {
    It 'keeps a valid colour, lowercased' { ConvertTo-CBHexColor -Value '#AB12CD' -Default '#000000' | Should -Be '#ab12cd' }
    It 'expands three-digit shorthand' { ConvertTo-CBHexColor -Value '#abc' -Default '#000000' | Should -Be '#aabbcc' }
    It 'falls back when the value is not a colour' { ConvertTo-CBHexColor -Value 'rebeccapurple' -Default '#0f5c8c' | Should -Be '#0f5c8c' }
    It 'falls back on an empty value' { ConvertTo-CBHexColor -Value '' -Default '#0f5c8c' | Should -Be '#0f5c8c' }
}

Describe 'Contrast helpers' {
    It 'computes a known contrast ratio' { Get-CBContrastRatio -Foreground '#ffffff' -Background '#000000' | Should -Be 21 }
    It 'picks white text on a dark background' { Get-CBReadableTextColor -Background '#0f5c8c' | Should -Be '#ffffff' }
    It 'picks dark text on a light background' { Get-CBReadableTextColor -Background '#f5e6b3' | Should -Be '#1b1b1b' }
}

Describe 'ConvertTo-CBDomainList' {
    It 'normalises, de-duplicates and drops rubbish' {
        (ConvertTo-CBDomainList -Value @('@Partner.COM', 'partner.com', 'not a domain', 'user@vendor.io', '')) -join ',' |
            Should -Be 'partner.com,vendor.io'
    }
    It 'returns an empty array for no input' { (ConvertTo-CBDomainList -Value $null).Count | Should -Be 0 }
}

Describe 'ConvertTo-CBHostList' {
    # Array results are compared as a joined string: Should -Be on two arrays
    # also compares their types, and a String[] never equals an Object[] even
    # when every element matches.
    It 'accepts a bare host and a URL' {
        (ConvertTo-CBHostList -Value @('intranet.contoso.com', 'https://docs.contoso.com/x')) -join ',' |
            Should -Be 'intranet.contoso.com,docs.contoso.com'
    }
    It 'keeps a leading dot, meaning subdomains' {
        (ConvertTo-CBHostList -Value @('.partners.contoso.com')) -join ',' | Should -Be '.partners.contoso.com'
    }
    It 'drops anything that is not a host' { (ConvertTo-CBHostList -Value @('nope', 'a b c')).Count | Should -Be 0 }
}

Describe 'Test-CBUrlAllowed (the welcome page cannot become an open redirect)' {
    BeforeAll { $allowed = @('contoso.sharepoint.com', 'teams.microsoft.com', '.partners.contoso.com') }

    It 'allows an exact host over https' { Test-CBUrlAllowed -Url 'https://contoso.sharepoint.com/sites/x' -AllowedHosts $allowed | Should -BeTrue }
    It 'allows a subdomain of a dotted entry' { Test-CBUrlAllowed -Url 'https://eu.partners.contoso.com/x' -AllowedHosts $allowed | Should -BeTrue }
    It 'allows the dotted entry itself' { Test-CBUrlAllowed -Url 'https://partners.contoso.com/x' -AllowedHosts $allowed | Should -BeTrue }
    It 'refuses an unrelated host' { Test-CBUrlAllowed -Url 'https://evil.example/x' -AllowedHosts $allowed | Should -BeFalse }
    It 'refuses plain http' { Test-CBUrlAllowed -Url 'http://contoso.sharepoint.com/x' -AllowedHosts $allowed | Should -BeFalse }
    It 'refuses a protocol-relative URL' { Test-CBUrlAllowed -Url '//evil.example/x' -AllowedHosts $allowed | Should -BeFalse }
    It 'refuses a javascript URL' { Test-CBUrlAllowed -Url 'javascript:alert(1)' -AllowedHosts $allowed | Should -BeFalse }
    It 'refuses a lookalike host that merely ends with an allowed name' {
        Test-CBUrlAllowed -Url 'https://evilcontoso.sharepoint.com/x' -AllowedHosts $allowed | Should -BeFalse
    }
    It 'refuses a host that only ends with a dotted entry without the dot' {
        Test-CBUrlAllowed -Url 'https://notpartners.contoso.com/x' -AllowedHosts @('.partners.contoso.com') | Should -BeFalse
    }
    It 'refuses an empty target' { Test-CBUrlAllowed -Url '' -AllowedHosts $allowed | Should -BeFalse }
    It 'refuses everything when the allowlist is empty' { Test-CBUrlAllowed -Url 'https://contoso.sharepoint.com/x' -AllowedHosts @() | Should -BeFalse }
}

Describe 'ConvertTo-CBSafeHtml' {
    It 'removes a script element and its content' {
        ConvertTo-CBSafeHtml -Html '<p>hi</p><script>steal()</script>' | Should -Be '<p>hi</p>'
    }
    It 'removes inline event handlers' {
        ConvertTo-CBSafeHtml -Html '<p onclick="steal()">hi</p>' | Should -Be '<p>hi</p>'
    }
    It 'neutralises a javascript: link' {
        ConvertTo-CBSafeHtml -Html '<a href="javascript:steal()">x</a>' | Should -Be '<a href="#">x</a>'
    }
    It 'leaves ordinary markup alone' {
        $html = '<p>Hello <strong>you</strong> <a href="https://contoso.com">link</a></p>'
        ConvertTo-CBSafeHtml -Html $html | Should -Be $html
    }
    It 'removes an iframe' { ConvertTo-CBSafeHtml -Html '<iframe src="https://x"></iframe>ok' | Should -Be 'ok' }
}

Describe 'ConvertTo-CBSanitisedSettings' {
    It 'produces a complete object from nothing' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{})
        $s.branding | Should -Not -BeNullOrEmpty
        $s.expiry | Should -Not -BeNullOrEmpty
        $s.safety | Should -Not -BeNullOrEmpty
        $s.emails | Should -Not -BeNullOrEmpty
    }
    It 'starts a new install in simulation mode' {
        (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{})).dryRun | Should -BeTrue
    }
    It 'honours simulation being turned off explicitly' {
        (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ dryRun = $false })).dryRun | Should -BeFalse
    }
    It 'clamps the default length to the maximum' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ expiry = [pscustomobject]@{ defaultDays = 900; maxDays = 60 } })
        $s.expiry.defaultDays | Should -Be 60
    }
    It 'rejects an expiry attribute outside 1..15' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ expiry = [pscustomobject]@{ attribute = 'extensionAttribute16' } })
        $s.expiry.attribute | Should -Be 'extensionAttribute15'
    }
    It 'accepts a valid expiry attribute' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ expiry = [pscustomobject]@{ attribute = 'extensionAttribute3' } })
        $s.expiry.attribute | Should -Be 'extensionAttribute3'
    }
    It 'drops an inviter group id that is not a GUID, and its name with it' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ invite = [pscustomobject]@{ inviterGroupId = 'not-a-guid'; inviterGroupName = 'Some Group' } })
        $s.invite.inviterGroupId | Should -Be ''
        $s.invite.inviterGroupName | Should -Be ''
    }
    It 'keeps a real inviter group id' {
        $id = [Guid]::NewGuid().ToString()
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ invite = [pscustomobject]@{ inviterGroupId = $id; inviterGroupName = 'Inviters' } })
        $s.invite.inviterGroupId | Should -Be $id
    }
    It 'forces the default share role to read when edit access is switched off' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ sharing = [pscustomobject]@{ allowWrite = $false; defaultRole = 'write' } })
        $s.sharing.defaultRole | Should -Be 'read'
    }
    It 'enforces a 30-day floor on the inactivity threshold' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ inactivity = [pscustomobject]@{ thresholdDays = 1 } })
        $s.inactivity.thresholdDays | Should -Be 30
    }
    It 'blanks an invalid service desk address' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ notifications = [pscustomobject]@{ servicedeskEmail = 'nope' } })
        $s.notifications.servicedeskEmail | Should -Be ''
    }
    It 'clamps the log retention into 7..3650' {
        (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ logRetentionDays = 2 })).logRetentionDays | Should -Be 7
        (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ logRetentionDays = 99999 })).logRetentionDays | Should -Be 3650
    }
    It 'refuses a logo file name it did not generate' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ branding = [pscustomobject]@{ logoFile = '../../evil.svg'; logoContentType = 'image/svg+xml' } })
        $s.branding.logoFile | Should -Be ''
        $s.branding.logoContentType | Should -Be ''
    }
    It 'refuses a logo content type outside png and jpeg' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ branding = [pscustomobject]@{ logoFile = 'logo-ab12cd34.png'; logoContentType = 'image/svg+xml' } })
        $s.branding.logoContentType | Should -Be ''
    }
    It 'survives a full round trip through JSON unchanged' {
        $first = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))
        $second = ConvertTo-CBSanitisedSettings -Raw ($first | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
        ($second | ConvertTo-Json -Depth 12) | Should -Be ($first | ConvertTo-Json -Depth 12)
    }
}

Describe 'Functions that return a list' {
    # PowerShell unrolls a returned array, so 'return , @($x)' is the usual way
    # to keep a ONE-element array from collapsing into a scalar. It has a trap:
    # around an EMPTY array it produces a one-element array containing the empty
    # array. A caller writing @(f) then sees Count 1 for "nothing", which has
    # already caused a healthy deployment to report a missing function and would
    # have had the watchdog email about one problem on a healthy install.
    #
    # These assert both ends for the list-returning helpers that can be empty,
    # under BOTH ways a caller consumes them.
    BeforeAll {
        # A settings object with nothing to complain about. The shipped defaults
        # alone are NOT that: with no service desk address configured they warn,
        # correctly, that nobody can be told about anything.
        function New-QuietSettings {
            param([hashtable]$Change = @{})
            $raw = Get-CBDefaultSettings
            $raw.notifications.servicedeskEmail = 'servicedesk@contoso.com'
            foreach ($k in $Change.Keys) {
                $parts = $k -split '\.'
                $node = $raw
                for ($i = 0; $i -lt $parts.Count - 1; $i++) { $node = $node[$parts[$i]] }
                $node[$parts[-1]] = $Change[$k]
            }
            return [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        }
    }
    It 'reports nothing as nothing, wrapped or not' {
        $clean = New-QuietSettings
        $warnings = Get-CBSettingsWarning -Settings $clean
        @($warnings).Count | Should -Be 0 -Because 'a fully configured install has nothing to warn about'
        @(Get-CBSettingsWarning -Settings $clean).Count | Should -Be 0
    }
    It 'keeps a single result a list rather than collapsing it to a scalar' {
        $one = New-QuietSettings -Change @{ 'expiry.graceDays' = 0 }
        @(Get-CBSettingsWarning -Settings $one).Count | Should -Be 1
        # It has to serialise as a JSON array, because the portal iterates it.
        (@{ warnings = @(Get-CBSettingsWarning -Settings $one) } | ConvertTo-Json -Depth 5 -Compress) |
            Should -BeLike '*"warnings":[[]*'
    }
    It 'returns an empty token list as empty under either style' {
        $none = Get-CBTemplateUnknownToken -Template 'no tokens at all' -Allowed @('a')
        @($none).Count | Should -Be 0
        @(Get-CBTemplateUnknownToken -Template 'no tokens at all' -Allowed @('a')).Count | Should -Be 0
    }
    It 'returns a single unknown token as a one-item list' {
        @(Get-CBTemplateUnknownToken -Template '{{nope}}' -Allowed @('a')).Count | Should -Be 1
    }
}

Describe 'HTTP routes' {
    BeforeAll {
        $functionRoot = Join-Path $PSScriptRoot '..\src'
        $httpBindings = @(Get-ChildItem -Path $functionRoot -Directory | ForEach-Object {
                $manifest = Join-Path $_.FullName 'function.json'
                if (-not (Test-Path $manifest)) { return }
                $json = Get-Content $manifest -Raw | ConvertFrom-Json
                foreach ($b in @($json.bindings)) {
                    if ("$($b.type)" -ne 'httpTrigger') { continue }
                    [pscustomobject]@{ Function = $_.Name; Route = "$($b.route)" }
                }
            })
    }
    It 'never routes a function under a path the Functions host reserves' {
        # The host owns /admin for its own management API. A function routed
        # there registers normally, appears in every function listing, and then
        # answers 404 to every request. That looks exactly like a failed
        # deployment, which is a long way from the cause, so it is worth failing
        # a build over rather than discovering it in a tenant.
        foreach ($binding in $httpBindings) {
            $first = ("$($binding.Route)" -split '/')[0]
            $first | Should -Not -BeIn @('admin', 'runtime') `
                -Because "'$($binding.Function)' is routed at '$($binding.Route)', and the host reserves that prefix"
        }
    }
    It 'gives every HTTP function a route' {
        foreach ($binding in $httpBindings) {
            $binding.Route | Should -Not -BeNullOrEmpty -Because "$($binding.Function) would otherwise answer on its function name"
        }
    }
    It 'never gives two functions the same route' {
        $dupes = @($httpBindings | Group-Object Route | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
        $dupes -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-CBRequestBody' {
    # The Functions PowerShell worker hands a JSON body over as a HASHTABLE.
    # A hashtable's keys are NOT PSObject properties, so code written against a
    # PSCustomObject reads every field as null. Combined with a sanitiser that
    # fills gaps from the defaults, that made every configuration save store the
    # shipped defaults instead of what was typed.
    It 'turns a hashtable body into something PSObject.Properties can see' {
        $body = @{ settings = @{ dryRun = $false; branding = @{ companyName = 'lieben' } } }
        $body.PSObject.Properties['settings'] | Should -BeNullOrEmpty -Because 'this is the trap being guarded against'

        $parsed = ConvertFrom-CBRequestBody -Body $body
        $parsed.PSObject.Properties['settings'] | Should -Not -BeNullOrEmpty
        $parsed.settings.dryRun | Should -BeFalse
        $parsed.settings.branding.companyName | Should -Be 'lieben'
    }
    It 'parses a string body' {
        $parsed = ConvertFrom-CBRequestBody -Body '{"settings":{"dryRun":false}}'
        $parsed.settings.dryRun | Should -BeFalse
    }
    It 'passes a PSCustomObject through untouched' {
        $obj = '{"a":1}' | ConvertFrom-Json
        (ConvertFrom-CBRequestBody -Body $obj).a | Should -Be 1
    }
    It 'treats nothing as nothing rather than inventing an object' {
        ConvertFrom-CBRequestBody -Body $null | Should -BeNullOrEmpty
        ConvertFrom-CBRequestBody -Body '   ' | Should -BeNullOrEmpty
    }
    It 'refuses a body that is not JSON instead of silently continuing' {
        { ConvertFrom-CBRequestBody -Body 'not json at all' } | Should -Throw -ExpectedMessage '*not valid JSON*'
    }
    It 'survives the depth of a real settings object, emails and all' {
        $settings = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))
        $settings.dryRun = $false
        # A hashtable exactly as the worker would present it.
        $body = @{ settings = $settings }
        $parsed = ConvertFrom-CBRequestBody -Body $body
        $parsed.settings.dryRun | Should -BeFalse
        $parsed.settings.emails.invitation.subject | Should -Be $settings.emails.invitation.subject
        @($parsed.settings.expiry.reminderDays).Count | Should -Be 3
    }
}

Describe 'Settings persistence' {
    It 'survives the exact round trip a save and a read perform' {
        # Turning simulation off appeared not to stick. It was a stale per-worker
        # cache, but the value itself passes through four transformations on the
        # way: sanitise, serialise, the re-serialise Get-CBBlobText does after
        # Invoke-RestMethod has already parsed the response, and sanitise again.
        # A boolean surviving all four is worth asserting rather than assuming.
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))
        $s.dryRun = $false
        $s.expiry.defaultDays = 45
        $stored = ($s | ConvertTo-Json -Depth 12)
        $reserialised = ($stored | ConvertFrom-Json | ConvertTo-Json -Depth 30)
        $final = ConvertTo-CBSanitisedSettings -Raw ($reserialised | ConvertFrom-Json)
        $final.dryRun | Should -BeFalse -Because 'an administrator who turns simulation off must find it off'
        $final.expiry.defaultDays | Should -Be 45
        ($final.expiry.reminderDays -join ',') | Should -Be ($s.expiry.reminderDays -join ',')
        $final.emails.Keys.Count | Should -Be $s.emails.Keys.Count
    }
    It 'reads an explicit false as false rather than falling back to the default' {
        ConvertTo-CBBool -Value $false -Default $true | Should -BeFalse
        ConvertTo-CBBool -Value 'false' -Default $true | Should -BeFalse
        # Only a genuinely absent value takes the default.
        ConvertTo-CBBool -Value $null -Default $true | Should -BeTrue
    }
    It 'does not cache, because a save on one worker cannot reach the others' {
        # Get-CBSettings used to hold a 60-second per-worker cache that only the
        # saving worker invalidated. Every other instance then served settings
        # the administrator had already changed.
        (Get-Command Get-CBSettings).Parameters.Keys | Should -Not -Contain 'Fresh'
        (Get-Command Get-CBSettings).Parameters.Keys | Should -Not -Contain 'Cached'
    }
}

Describe 'ConvertTo-CBReminderDays' {
    It 'sorts descending and de-duplicates' { (ConvertTo-CBReminderDays -Value @(1, 7, 30, 7)) -join ',' | Should -Be '30,7,1' }
    It 'drops values outside the allowed lifetime' { (ConvertTo-CBReminderDays -Value @(90, 7) -MaxDays 30) -join ',' | Should -Be '7' }
    It 'drops non-numeric entries' { (ConvertTo-CBReminderDays -Value @('x', 5)) -join ',' | Should -Be '5' }
    It 'caps the number of steps at five' { (ConvertTo-CBReminderDays -Value @(1, 2, 3, 4, 5, 6, 7)).Count | Should -Be 5 }
    It 'falls back to the default when nothing is usable' { (ConvertTo-CBReminderDays -Value @('a', 'b')) -join ',' | Should -Be '30,7,1' }
    It 'trims the fallback to fit a short maximum' { (ConvertTo-CBReminderDays -Value @() -MaxDays 5) -join ',' | Should -Be '1' }
}

Describe 'ConvertTo-CBSanitisedSafetySettings' {
    It 'defaults a non-numeric cap' { (ConvertTo-CBSanitisedSafetySettings -Raw ([pscustomobject]@{ dailyCapDelete = 'x' })).dailyCapDelete | Should -Be 50 }
    It 'clamps a negative cap to zero' { (ConvertTo-CBSanitisedSafetySettings -Raw ([pscustomobject]@{ dailyCapBlock = -3 })).dailyCapBlock | Should -Be 0 }
    It 'clamps a percentage over 100' { (ConvertTo-CBSanitisedSafetySettings -Raw ([pscustomobject]@{ percentCeiling = 500 })).percentCeiling | Should -Be 100 }
    It 'defaults to enabled when the flag is absent' { (ConvertTo-CBSanitisedSafetySettings -Raw ([pscustomobject]@{})).enabled | Should -BeTrue }
    It 'honours being switched off' { (ConvertTo-CBSanitisedSafetySettings -Raw ([pscustomobject]@{ enabled = $false })).enabled | Should -BeFalse }
}

Describe 'Get-CBSettingsWarning' {
    It 'warns about an unreadable brand colour' {
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ branding = [pscustomobject]@{ primaryColor = '#7f7f7f'; accentColor = '#808080' } }))
        $warnings = Get-CBSettingsWarning -Settings $s
        @($warnings | Where-Object { $_.field -like 'branding.*' }).Count | Should -BeGreaterThan 0
    }
    It 'warns when deletion has no grace period' {
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ expiry = [pscustomobject]@{ graceDays = 0 } }))
        @(Get-CBSettingsWarning -Settings $s | Where-Object { $_.field -eq 'expiry.graceDays' }).Count | Should -Be 1
    }
    It 'says nothing about colours that are readable' {
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ branding = [pscustomobject]@{ primaryColor = '#0f5c8c'; accentColor = '#b8501f' } }))
        @(Get-CBSettingsWarning -Settings $s | Where-Object { $_.field -like 'branding.*' }).Count | Should -Be 0
    }
    It 'accepts a light header colour, and says links will not be that colour' {
        # A logo with dark lettering needs a light band behind it, so a white
        # main colour is a legitimate choice rather than a mistake: text ON it is
        # readable. What is not readable is that same colour used AS a link, and
        # the portal derives a darker one instead. Saying so is the difference
        # between a considered design and one that looks broken.
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{
                    branding = [pscustomobject]@{ primaryColor = '#ffffff'; accentColor = '#003765' }
                }))
        $warnings = @(Get-CBSettingsWarning -Settings $s | Where-Object { $_.field -like 'branding.*' })
        $warnings.Count | Should -Be 0 -Because 'white with a dark accent is readable everywhere it matters'
    }
    It 'warns when neither colour can carry a link' {
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{
                    branding = [pscustomobject]@{ primaryColor = '#ffffff'; accentColor = '#ffe9a8' }
                }))
        @(Get-CBSettingsWarning -Settings $s | Where-Object { $_.message -like '*links and tabs*' }).Count | Should -Be 1
    }
}

Describe 'Email templates' {
    It 'gives every catalogue entry a default' {
        foreach ($entry in Get-CBEmailCatalog) {
            $default = Get-CBEmailDefault -Key $entry.key
            $default.subject | Should -Not -BeNullOrEmpty
            $default.html | Should -Not -BeNullOrEmpty
        }
    }
    It 'only uses tokens it declares' {
        foreach ($entry in Get-CBEmailCatalog) {
            $unknown = Get-CBTemplateUnknownToken -Template ($entry.subject + ' ' + $entry.body) -Allowed $entry.tokens
            $unknown | Should -BeNullOrEmpty -Because "the shipped '$($entry.key)' template must not reference a token it never receives"
        }
    }
    It 'restores a missing template from the catalogue' {
        $emails = ConvertTo-CBSanitisedEmails -Raw ([pscustomobject]@{})
        $emails['invitation'].subject | Should -Be (Get-CBEmailDefault -Key 'invitation').subject
    }
    It 'drops a template key that is not in the catalogue' {
        $emails = ConvertTo-CBSanitisedEmails -Raw ([pscustomobject]@{ notARealTemplate = [pscustomobject]@{ subject = 'x'; html = 'y' } })
        $emails.Keys | Should -Not -Contain 'notARealTemplate'
    }
    It 'strips script out of an admin-authored body on save' {
        $emails = ConvertTo-CBSanitisedEmails -Raw ([pscustomobject]@{ invitation = [pscustomobject]@{ subject = 'Hi'; html = '<p>ok</p><script>bad()</script>' } })
        $emails['invitation'].html | Should -Not -Match 'script'
    }
    It 'falls back to the default body when the admin empties it' {
        $emails = ConvertTo-CBSanitisedEmails -Raw ([pscustomobject]@{ invitation = [pscustomobject]@{ subject = 'Hi'; html = '   ' } })
        $emails['invitation'].html | Should -Be (Get-CBEmailDefault -Key 'invitation').html
    }
    It 'can preview every token it offers an administrator' {
        # The token palette in the portal is rendered from the catalogue, and the
        # preview is rendered from the sample bag. A token in one and not the
        # other means an admin inserts a placeholder, sees it come out blank in
        # the preview, and reasonably concludes the tool is broken.
        $sample = Get-CBSampleTokenValue -Settings ([pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))))
        $missing = @()
        foreach ($entry in Get-CBEmailCatalog) {
            foreach ($token in $entry.tokens) {
                if ($null -eq (Get-CBTokenValue -Bag $sample -Path $token)) { $missing += "$($entry.key) -> $token" }
            }
        }
        $missing -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'Expand-CBTemplate' {
    BeforeAll {
        $values = @{
            guest = @{ displayName = 'Jane <script>alert(1)</script> Rivera'; email = 'jane@partner.example' }
            brand = @{ companyName = 'Contoso & Co' }
        }
    }
    It 'substitutes a nested token' {
        Expand-CBTemplate -Template 'Hello {{guest.email}}' -Values $values | Should -Be 'Hello jane@partner.example'
    }
    It 'HTML-encodes the value, so external input cannot inject markup' {
        $out = Expand-CBTemplate -Template '{{guest.displayName}}' -Values $values
        $out | Should -Not -Match '<script>'
        $out | Should -Match '&lt;script&gt;'
    }
    It 'encodes an ampersand' {
        Expand-CBTemplate -Template '{{brand.companyName}}' -Values $values | Should -Be 'Contoso &amp; Co'
    }
    It 'renders an unknown token as empty rather than leaving the placeholder' {
        Expand-CBTemplate -Template 'x{{nope.nothing}}y' -Values $values | Should -Be 'xy'
    }
    It 'leaves a raw substitution unencoded for plain-text use' {
        Expand-CBTemplate -Template '{{brand.companyName}}' -Values $values -Raw | Should -Be 'Contoso & Co'
    }
    It 'tolerates whitespace inside the braces' {
        Expand-CBTemplate -Template '{{ guest.email }}' -Values $values | Should -Be 'jane@partner.example'
    }
}

Describe 'HTML tokens' {
    It 'encodes every token by default, including one that looks like markup' {
        Expand-CBTemplate -Template '{{problemList}}' -Values @{ problemList = '<ul><li>x</li></ul>' } |
            Should -Be '&lt;ul&gt;&lt;li&gt;x&lt;/li&gt;&lt;/ul&gt;'
    }
    It 'passes through only the tokens a template declares as markup' {
        $values = @{ problemList = '<ul><li>x</li></ul>'; guest = @{ displayName = '<b>Jane</b>' } }
        $out = Expand-CBTemplate -Template '{{problemList}}|{{guest.displayName}}' -Values $values -HtmlToken @('problemList')
        $out | Should -Be '<ul><li>x</li></ul>|&lt;b&gt;Jane&lt;/b&gt;'
    }
    It 'only the watchdog alert declares any, and only for the list it builds' {
        # If this ever grows, the new entry needs the same scrutiny: whatever
        # produces the value must encode everything it puts inside the markup.
        $declaring = @(Get-CBEmailCatalog | Where-Object { $_.PSObject.Properties['htmlTokens'] } |
                ForEach-Object { "$($_.key):$(@($_.htmlTokens) -join ',')" })
        ($declaring -join ' ') | Should -Be 'watchdogAlert:problemList'
    }
    It 'declares every markup token as a token of that template too' {
        foreach ($entry in Get-CBEmailCatalog) {
            if (-not $entry.PSObject.Properties['htmlTokens']) { continue }
            foreach ($t in @($entry.htmlTokens)) {
                $entry.tokens | Should -Contain $t -Because "'$t' is offered as markup but is not in $($entry.key)'s token list"
            }
        }
    }
}

Describe 'Get-CBBrandShell' {
    BeforeAll { $branding = [pscustomobject]@{ companyName = 'Contoso'; primaryColor = '#0f5c8c'; accentColor = '#b8501f' } }
    It 'turns the button class into an inline branded style' {
        $html = Get-CBBrandShell -BodyHtml '<a class="cb-button" href="https://x">Go</a>' -Branding $branding
        $html | Should -Match 'background:#b8501f'
        $html | Should -Not -Match 'class="cb-button"'
    }
    It 'uses the inline logo when a content id is supplied' {
        (Get-CBBrandShell -BodyHtml '<p>x</p>' -Branding $branding -LogoCid 'thelogo') | Should -Match 'cid:thelogo'
    }
    It 'falls back to a wordmark without a logo' {
        (Get-CBBrandShell -BodyHtml '<p>x</p>' -Branding $branding) | Should -Match 'Contoso'
    }
    It 'encodes the company name' {
        $b = [pscustomobject]@{ companyName = 'A<b>C'; primaryColor = '#0f5c8c'; accentColor = '#b8501f' }
        (Get-CBBrandShell -BodyHtml '<p>x</p>' -Branding $b) | Should -Match 'A&lt;b&gt;C'
    }
}

Describe 'Get-CBWelcomePageHtml' {
    BeforeAll {
        $branding = [pscustomobject]@{ companyName = 'Contoso'; primaryColor = '#0f5c8c'; accentColor = '#b8501f' }
        $welcome = [pscustomobject]@{ headline = 'You are in.'; message = 'Welcome aboard.'; buttonLabel = 'Open it'; autoRedirect = $false }
        $html = Get-CBWelcomePageHtml -Branding $branding -Welcome $welcome -AllowedHosts @('contoso.sharepoint.com', 'teams.microsoft.com') -LogoUrl 'assets/logo-ab12cd34.png'
    }
    It 'carries a restrictive content security policy' {
        $html | Should -Match "default-src 'none'"
        $html | Should -Match "form-action 'none'"
    }
    It 'embeds the allowlist so the page can validate the redirect itself' {
        $html | Should -Match 'contoso\.sharepoint\.com'
        $html | Should -Match 'teams\.microsoft\.com'
    }
    It 'references the logo relatively, so img-src self holds' {
        $html | Should -Match 'src="assets/logo-ab12cd34.png"'
        $html | Should -Not -Match 'src="https://'
    }
    It 'renders the administrator copy' {
        $html | Should -Match 'You are in\.'
        $html | Should -Match 'Welcome aboard\.'
        $html | Should -Match 'Open it'
    }
    It 'encodes the copy so an administrator cannot inject markup by accident' {
        $w = [pscustomobject]@{ headline = '<img src=x onerror=alert(1)>'; message = 'x'; buttonLabel = 'x'; autoRedirect = $false }
        $out = Get-CBWelcomePageHtml -Branding $branding -Welcome $w -AllowedHosts @('contoso.sharepoint.com')
        $out | Should -Not -Match '<img src=x'
        $out | Should -Match '&lt;img'
    }
    It 'does not auto-redirect unless that was asked for' {
        $html | Should -Match 'AUTO_REDIRECT = false'
        $w = [pscustomobject]@{ headline = 'x'; message = 'x'; buttonLabel = 'x'; autoRedirect = $true }
        (Get-CBWelcomePageHtml -Branding $branding -Welcome $w -AllowedHosts @('contoso.sharepoint.com')) | Should -Match 'AUTO_REDIRECT = true'
    }
    It 'emits the allowlist as a JSON array even with a single entry' {
        $out = Get-CBWelcomePageHtml -Branding $branding -Welcome $welcome -AllowedHosts @('contoso.sharepoint.com')
        $out | Should -Match 'ALLOWED = \["contoso.sharepoint.com"\]'
    }
    It 'attributes the tool without fetching anything from outside' {
        # A link is a navigation, not a request, so it does not weaken
        # default-src 'none'. Anything that LOADS from another host would, and
        # would also make the page phone home for a guest who opens it.
        $html | Should -Match 'jsolve\.nl'
        $html | Should -Not -Match 'src="http'
        $html | Should -Not -Match '@import'
    }
}

Describe 'Publishing a logo' {
    BeforeAll {
        # A one-pixel PNG, so the magic-byte check has something real to accept.
        $png = [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + [byte[]]@(1..40)
    }
    It 'refuses to publish an image that arrived as text' {
        # The failure this replaces succeeded at every step: the PUT returned
        # 201, the GET returned 200, and the browser drew a broken image. A
        # string that has been through UTF-8 is not a PNG any more, and the only
        # place that can still be noticed is before it is sent.
        { Publish-CBPublicBlob -Container '$web' -Name 'assets/logo.png' -Content 'PNG-as-text' -ContentType 'image/png' } |
            Should -Throw '*from a string*'
    }
    It 'accepts bytes that PowerShell has unrolled into an object array' {
        # `return $bytes` and `$x = if (...) { $bytes }` both put the array
        # through the output stream, and the assignment collects it back as
        # Object[]. The data is perfectly good, so refusing it on the type alone
        # rejected a correct image and left the settings pointing at an asset the
        # site had never received.
        $unrolled = @($png)                                  # exactly what a caller ends up holding
        $unrolled -is [byte[]] | Should -BeFalse -Because 'this is the shape the trap produces'
        # It gets past the type check and fails later on configuration, which is
        # as far as an offline test can follow it. What matters is that it is not
        # refused for being the wrong type.
        $err = ''
        try { Publish-CBPublicBlob -Container '$web' -Name 'assets/logo.png' -Content $unrolled -ContentType 'image/png' }
        catch { $err = "$($_.Exception.Message)" }
        $err | Should -Not -BeLike '*Refusing to publish*'
    }
    It 'accepts a real image by its magic bytes and generates the stored name' {
        # Named by us, never by the caller: the name ends up in a public URL.
        Mock -CommandName Set-CBBlobBytes -MockWith { } -ModuleName Collaborate
        $stored = Set-CBBrandingLogo -Bytes $png
        $stored.ContentType | Should -Be 'image/png'
        $stored.FileName | Should -Match '^logo-[0-9a-f]{8}\.png$'
    }
    It 'refuses anything that is not a PNG or JPEG, whatever it is called' {
        { Set-CBBrandingLogo -Bytes ([byte[]]@(0x3C, 0x73, 0x76, 0x67, 0x20, 0x2F, 0x3E, 0x0A)) } | Should -Throw '*PNG or JPEG*'
    }
}

Describe 'Get-CBBrandingManifest' {
    It 'publishes only display values' {
        $manifest = Get-CBBrandingManifest -Branding ([pscustomobject]@{
                companyName = 'Contoso'; portalTitle = 'External collaborators'; portalSubtitle = 'sub'
                primaryColor = '#0f5c8c'; accentColor = '#b8501f'
            }) -LogoUrl 'https://site/assets/logo.png' | ConvertFrom-Json
        $manifest.companyName | Should -Be 'Contoso'
        $manifest.logoUrl | Should -Be 'https://site/assets/logo.png'
        $manifest.PSObject.Properties.Name | Should -Not -Contain 'servicedeskEmail'
    }
}

Describe 'Compare-CBSettings' {
    It 'reports only what changed' {
        $a = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{}))
        $b = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{ expiry = [pscustomobject]@{ graceDays = 30 } }))
        $diff = Compare-CBSettings -Old $a -New $b
        $diff.Keys | Should -Contain 'expiry.graceDays'
        $diff['expiry.graceDays'].new | Should -Be '30'
        $diff.Keys | Should -Not -Contain 'expiry.defaultDays'
    }
    It 'reports nothing for an identical object' {
        $a = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{}))
        (Compare-CBSettings -Old $a -New $a).Count | Should -Be 0
    }
    It 'does not spill an email body into the audit log' {
        $a = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]@{}))
        $raw = $a | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        $raw.emails.invitation.html = '<p>completely different wording</p>'
        $b = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw $raw)
        $diff = Compare-CBSettings -Old $a -New $b
        $diff['emails.invitation.html'].new | Should -Be '(new body)'
    }
}

Describe 'Test-CBExpiryAttributeName' {
    It 'accepts the valid range' {
        Test-CBExpiryAttributeName -Name 'extensionAttribute1' | Should -BeTrue
        Test-CBExpiryAttributeName -Name 'extensionAttribute15' | Should -BeTrue
    }
    It 'rejects out of range and rubbish' {
        Test-CBExpiryAttributeName -Name 'extensionAttribute0' | Should -BeFalse
        Test-CBExpiryAttributeName -Name 'extensionAttribute16' | Should -BeFalse
        Test-CBExpiryAttributeName -Name 'department' | Should -BeFalse
    }
}

Describe 'ConvertTo-CBBoundedString' {
    It 'trims and caps' { ConvertTo-CBBoundedString -Value '  hello world  ' -MaxLength 5 | Should -Be 'hello' }
    It 'falls back when empty' { ConvertTo-CBBoundedString -Value '   ' -Default 'fallback' | Should -Be 'fallback' }
    It 'collapses newlines by default' { ConvertTo-CBBoundedString -Value "a`r`nb" | Should -Be 'a b' }
    It 'keeps newlines when asked' { ConvertTo-CBBoundedString -Value "a`nb" -AllowNewLines | Should -Be "a`nb" }
}

# ---------------------------------------------------------------------------
# Guest lifecycle: dates, the state machine and the invitation rules.
# ---------------------------------------------------------------------------

Describe 'ConvertTo-CBDateOnly' {
    It 'parses a stored date' { (ConvertTo-CBDateOnly -Value '2026-11-09').ToString('yyyy-MM-dd') | Should -Be '2026-11-09' }
    It 'parses a full ISO timestamp down to the date' {
        (ConvertTo-CBDateOnly -Value '2026-11-09T22:15:00Z').ToString('yyyy-MM-dd') | Should -Be '2026-11-09'
    }
    It 'returns nothing for an empty or unparseable value' {
        ConvertTo-CBDateOnly -Value '' | Should -BeNullOrEmpty
        ConvertTo-CBDateOnly -Value 'soon' | Should -BeNullOrEmpty
    }
}

Describe 'Get-CBExpiryDateString' {
    It 'adds whole days on the calendar' {
        Get-CBExpiryDateString -Days 30 -From ([datetime]'2026-01-15T00:00:00Z') | Should -Be '2026-02-14'
    }
    It 'rolls over a month end correctly' {
        Get-CBExpiryDateString -Days 1 -From ([datetime]'2026-01-31T00:00:00Z') | Should -Be '2026-02-01'
    }
    It 'handles a leap day' {
        Get-CBExpiryDateString -Days 1 -From ([datetime]'2028-02-28T00:00:00Z') | Should -Be '2028-02-29'
    }
    It 'ignores the time of day, so two invitations on the same day expire together' {
        $early = Get-CBExpiryDateString -Days 90 -From ([datetime]'2026-03-29T00:30:00Z')
        $late = Get-CBExpiryDateString -Days 90 -From ([datetime]'2026-03-29T23:30:00Z')
        $early | Should -Be $late
    }
}

Describe 'Get-CBGuestDaysLeft' {
    BeforeAll { $now = [datetime]'2026-06-01T12:00:00Z' }
    It 'counts whole days ahead' { Get-CBGuestDaysLeft -ExpiresOn '2026-06-08' -Now $now | Should -Be 7 }
    It 'is zero on the last day' { Get-CBGuestDaysLeft -ExpiresOn '2026-06-01' -Now $now | Should -Be 0 }
    It 'goes negative once it has passed' { Get-CBGuestDaysLeft -ExpiresOn '2026-05-30' -Now $now | Should -Be -2 }
    It 'is zero when there is no date at all' { Get-CBGuestDaysLeft -ExpiresOn '' -Now $now | Should -Be 0 }
}

Describe 'Get-CBEffectiveGuestState' {
    BeforeAll {
        $now = [datetime]'2026-06-01T12:00:00Z'
        $redeemed = '2026-01-01T00:00:00Z'
    }
    It 'is pending until the invitation is accepted' {
        Get-CBEffectiveGuestState -StoredState 'pending' -ExpiresOn '2026-12-01' -RedeemedAt '' -Now $now | Should -Be 'pending'
    }
    It 'is active well before the end date' {
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-12-01' -RedeemedAt $redeemed -ReminderDays @(30, 7, 1) -Now $now |
            Should -Be 'active'
    }
    It 'is expiring inside the widest reminder window' {
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-06-20' -RedeemedAt $redeemed -ReminderDays @(30, 7, 1) -Now $now |
            Should -Be 'expiring'
    }
    It 'follows the configured reminder window rather than a fixed one' {
        # The same guest is merely active when the tenant only reminds a day out.
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-06-20' -RedeemedAt $redeemed -ReminderDays @(1) -Now $now |
            Should -Be 'active'
    }
    It 'is expired the day after the end date' {
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-05-31' -RedeemedAt $redeemed -Now $now | Should -Be 'expired'
    }
    It 'has not expired yet on the end date itself' {
        # Access runs to the END of the expiry date, so the last day still counts.
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-06-01' -RedeemedAt $redeemed -ReminderDays @(30, 7, 1) -Now $now |
            Should -Be 'expiring'
    }
    It 'treats a local time for "now" as the same instant, not a different day' {
        # [datetime]'...Z' casts to LOCAL in PowerShell, which would otherwise
        # shift the date by one either side of midnight.
        $utc = [datetime]::new(2026, 6, 1, 23, 30, 0, [DateTimeKind]::Utc)
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-06-01' -RedeemedAt $redeemed -Now $utc.ToLocalTime() |
            Should -Be (Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-06-01' -RedeemedAt $redeemed -Now $utc)
    }
    It 'reports an unaccepted invitation that ran out as expired, not pending' {
        Get-CBEffectiveGuestState -StoredState 'pending' -ExpiresOn '2026-05-01' -RedeemedAt '' -Now $now | Should -Be 'expired'
    }
    It 'lets a stored decision win over the calendar' {
        Get-CBEffectiveGuestState -StoredState 'blocked' -ExpiresOn '2026-12-01' -RedeemedAt $redeemed -Now $now | Should -Be 'blocked'
        Get-CBEffectiveGuestState -StoredState 'deleted' -ExpiresOn '2026-12-01' -RedeemedAt $redeemed -Now $now | Should -Be 'deleted'
    }
    It 'does not call a guest pending just because nobody knows whether they accepted' {
        # The bug this replaces: an older guest has no externalUserState, which
        # was read as "invited, never replied". They then showed as pending, and
        # the status line said "waiting for them to accept" INSTEAD of their end
        # date, so the one fact the tool exists to show went missing.
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-12-01' -RedeemedAt '' -InviteState 'unknown' -Now $now |
            Should -Be 'active'
    }
    It 'still waits on an invitation the directory says is outstanding' {
        Get-CBEffectiveGuestState -StoredState 'pending' -ExpiresOn '2026-12-01' -RedeemedAt '' -InviteState 'pending' -Now $now |
            Should -Be 'pending'
    }
    It 'falls back to the acceptance date for rows written before the field existed' {
        Get-CBEffectiveGuestState -StoredState 'pending' -ExpiresOn '2026-12-01' -RedeemedAt '' -InviteState '' -Now $now | Should -Be 'pending'
        Get-CBEffectiveGuestState -StoredState 'active' -ExpiresOn '2026-12-01' -RedeemedAt $redeemed -InviteState '' -Now $now | Should -Be 'active'
    }
}

Describe 'Get-CBRedemptionState' {
    It 'believes the directory when it says accepted, and records when' {
        $r = Get-CBRedemptionState -ExternalUserState 'Accepted' -StateChangedAt '2024-03-04T10:00:00Z' -Created '2024-01-01T00:00:00Z'
        $r.State | Should -Be 'accepted'
        $r.At | Should -Be '2024-03-04T10:00:00Z'
    }
    It 'falls back to the creation date when Entra does not say when they accepted' {
        (Get-CBRedemptionState -ExternalUserState 'Accepted' -Created '2024-01-01T00:00:00Z').At | Should -Be '2024-01-01T00:00:00Z'
    }
    It 'believes the directory when it says the invitation is outstanding' {
        (Get-CBRedemptionState -ExternalUserState 'PendingAcceptance' -Created '2026-05-30T00:00:00Z').State | Should -Be 'pending'
    }
    It 'says unknown rather than pending when the directory says nothing' {
        $r = Get-CBRedemptionState -ExternalUserState '' -Created '2019-01-01T00:00:00Z'
        $r.State | Should -Be 'unknown'
        $r.At | Should -Be ''
    }
    It 'settles an unknown state with a successful sign-in' {
        # Nobody signs in to an invitation they never accepted.
        $r = Get-CBRedemptionState -ExternalUserState '' -LastSignIn '2026-05-20T08:00:00Z' -Created '2019-01-01T00:00:00Z'
        $r.State | Should -Be 'accepted'
        $r.At | Should -Be '2026-05-20T08:00:00Z'
    }
    It 'does not let a sign-in override a directory that says pending' {
        (Get-CBRedemptionState -ExternalUserState 'PendingAcceptance' -LastSignIn '2026-05-20T08:00:00Z').State | Should -Be 'pending'
    }
    It 'ignores the zero date some tenants return' {
        (Get-CBRedemptionState -ExternalUserState 'Accepted' -StateChangedAt '' -Created '').At | Should -Be ''
    }
}

Describe 'Get-CBRedemptionLabel' {
    It 'names the day they accepted' {
        Get-CBRedemptionLabel -State 'accepted' -At '2024-03-04T10:00:00Z' | Should -Be 'Accepted 4 March 2024'
    }
    It 'says when they were invited if they have not accepted' {
        Get-CBRedemptionLabel -State 'pending' -InvitedAt '2026-05-30' | Should -Be 'Invited 30 May 2026, not accepted yet'
    }
    It 'admits it does not know rather than implying they ignored us' {
        Get-CBRedemptionLabel -State 'unknown' -InvitedAt '2019-01-01' | Should -Not -Match 'not accepted'
        Get-CBRedemptionLabel -State 'unknown' | Should -Match 'does not record'
    }
}

Describe 'Get-CBGuestStateLabel' {
    It 'says when access ends rather than just naming the state' {
        Get-CBGuestStateLabel -State 'expiring' -DaysLeft 5 -ExpiresOn '2026-06-06' | Should -Be 'Ends in 5 days (6 June 2026)'
    }
    It 'reads naturally on the last two days' {
        Get-CBGuestStateLabel -State 'expiring' -DaysLeft 1 -ExpiresOn '2026-06-02' | Should -Match '^Ends tomorrow'
        Get-CBGuestStateLabel -State 'expiring' -DaysLeft 0 -ExpiresOn '2026-06-01' | Should -Match '^Ends today'
    }
    It 'does not mention a date for a pending invitation' {
        Get-CBGuestStateLabel -State 'pending' -ExpiresOn '2026-06-06' | Should -Not -Match '2026'
    }
}

Describe 'Test-CBInviteAddress' {
    BeforeAll { $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))) }

    It 'accepts an ordinary external address' {
        (Test-CBInviteAddress -Email 'jane@partner.com' -Settings $settings).Allowed | Should -BeTrue
    }
    It 'rejects something that is not an address' {
        (Test-CBInviteAddress -Email 'jane' -Settings $settings).Allowed | Should -BeFalse
    }
    It 'refuses one of our own domains, because that is a colleague' {
        $result = Test-CBInviteAddress -Email 'bob@contoso.com' -Settings $settings -TenantDomain @('contoso.com', 'contoso.onmicrosoft.com')
        $result.Allowed | Should -BeFalse
        $result.Reason | Should -Match 'colleague'
    }
    It 'refuses a blocked domain' {
        $raw = Get-CBDefaultSettings
        $raw.invite.blockedDomains = @('gmail.com')
        $blocked = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBInviteAddress -Email 'someone@gmail.com' -Settings $blocked).Allowed | Should -BeFalse
        (Test-CBInviteAddress -Email 'someone@partner.com' -Settings $blocked).Allowed | Should -BeTrue
    }
    It 'refuses anything outside an allow list once one is set' {
        $raw = Get-CBDefaultSettings
        $raw.invite.allowedDomains = @('partner.com')
        $allow = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBInviteAddress -Email 'jane@partner.com' -Settings $allow).Allowed | Should -BeTrue
        (Test-CBInviteAddress -Email 'jane@vendor.com' -Settings $allow).Allowed | Should -BeFalse
    }
    It 'matches domains exactly, so blocking a domain does not silently block its subdomains' {
        $raw = Get-CBDefaultSettings
        $raw.invite.blockedDomains = @('partner.com')
        $blocked = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBInviteAddress -Email 'jane@mail.partner.com' -Settings $blocked).Allowed | Should -BeTrue
    }
}

Describe 'Get-CBRequestedExpiry' {
    BeforeAll {
        $raw = Get-CBDefaultSettings
        $raw.expiry.defaultDays = 90
        $raw.expiry.maxDays = 180
        $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        $from = [datetime]'2026-01-01T00:00:00Z'
    }
    It 'uses the default when nothing is asked for' {
        (Get-CBRequestedExpiry -Days $null -Settings $settings -Now $from).Days | Should -Be 90
    }
    It 'honours a shorter request' {
        (Get-CBRequestedExpiry -Days 7 -Settings $settings -Now $from).ExpiresOn | Should -Be '2026-01-08'
    }
    It 'clamps a request beyond the policy maximum and says so' {
        $result = Get-CBRequestedExpiry -Days 9999 -Settings $settings -Now $from
        $result.Days | Should -Be 180
        $result.Clamped | Should -BeTrue
    }
    It 'clamps a nonsense request rather than trusting it' {
        (Get-CBRequestedExpiry -Days -5 -Settings $settings -Now $from).Days | Should -Be 1
        (Get-CBRequestedExpiry -Days 'lots' -Settings $settings -Now $from).Days | Should -Be 90
    }
}

Describe 'Get-CBGuestView' {
    BeforeAll {
        $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings)))
        $now = [datetime]'2026-06-01T12:00:00Z'
        $row = [pscustomobject]@{
            PartitionKey     = 'owner-oid'
            RowKey           = 'guest-oid'
            Email            = 'jane@partner.com'
            DisplayName      = 'Jane Rivera'
            Reason           = 'Q3 proposal'
            State            = 'active'
            ExpiresOn        = '2026-09-01'
            RedeemedAtUtc    = '2026-05-01T00:00:00Z'
            OwnerUpn         = 'alex@contoso.com'
            OwnerDisplayName = 'Alex Chen'
        }
    }
    It 'derives the state and the days left' {
        $view = Get-CBGuestView -Row $row -Settings $settings -Now $now
        $view.state | Should -Be 'active'
        $view.daysLeft | Should -Be 92
        $view.expiresOnLabel | Should -Be '1 September 2026'
    }
    It 'withholds the owner unless asked' {
        (Get-CBGuestView -Row $row -Settings $settings -Now $now).Contains('owner') | Should -BeFalse
        (Get-CBGuestView -Row $row -Settings $settings -Now $now -IncludeOwner).owner.displayName | Should -Be 'Alex Chen'
    }
    It 'reports a guest in the orphan partition as unowned' {
        $orphan = $row.PSObject.Copy()
        $orphan.PartitionKey = Get-CBOrphanPartition
        $view = Get-CBGuestView -Row $orphan -Settings $settings -Now $now -IncludeOwner
        $view.orphaned | Should -BeTrue
        $view.owner.displayName | Should -Be 'nobody'
    }
}

# ---------------------------------------------------------------------------
# The lifecycle: what the tool decides to do to somebody's account, unasked.
# This is the highest-consequence logic in the codebase, so it is the most
# heavily tested.
# ---------------------------------------------------------------------------

Describe 'Get-CBDueReminderStep' {
    It 'is silent well before the first step' {
        (Get-CBDueReminderStep -DaysLeft 60 -ReminderDays @(30, 7, 1) -RemindersSent '').Due | Should -Be 0
    }
    It 'fires the widest step when it is reached' {
        (Get-CBDueReminderStep -DaysLeft 30 -ReminderDays @(30, 7, 1) -RemindersSent '').Due | Should -Be 30
    }
    It 'stays silent on the following days once a step is spent' {
        (Get-CBDueReminderStep -DaysLeft 20 -ReminderDays @(30, 7, 1) -RemindersSent '30').Due | Should -Be 0
    }
    It 'fires the next step at its own mark' {
        (Get-CBDueReminderStep -DaysLeft 7 -ReminderDays @(30, 7, 1) -RemindersSent '30').Due | Should -Be 7
    }
    It 'consumes every step already passed, so a short invitation does not mail daily' {
        # Invited for five days: the 30 and 7 day marks are both already behind
        # them. One reminder goes out, and both marks are spent.
        $due = Get-CBDueReminderStep -DaysLeft 5 -ReminderDays @(30, 7, 1) -RemindersSent ''
        $due.Due | Should -Be 7
        ($due.Consumed | Sort-Object) -join ',' | Should -Be '7,30'
    }
    It 'says nothing more once every reached step is spent' {
        (Get-CBDueReminderStep -DaysLeft 4 -ReminderDays @(30, 7, 1) -RemindersSent '30,7').Due | Should -Be 0
    }
    It 'still fires the last step on the final day' {
        (Get-CBDueReminderStep -DaysLeft 1 -ReminderDays @(30, 7, 1) -RemindersSent '30,7').Due | Should -Be 1
        (Get-CBDueReminderStep -DaysLeft 0 -ReminderDays @(30, 7, 1) -RemindersSent '30,7').Due | Should -Be 1
    }
    It 'does not remind about access that has already ended' {
        (Get-CBDueReminderStep -DaysLeft -1 -ReminderDays @(30, 7, 1) -RemindersSent '').Due | Should -Be 0
    }
    It 'never repeats a step, however often it is asked' {
        $sent = ''
        $fired = 0
        foreach ($day in 40..0) {
            $due = Get-CBDueReminderStep -DaysLeft $day -ReminderDays @(30, 7, 1) -RemindersSent $sent
            if ($due.Due -gt 0) { $fired++; $sent = Add-CBReminderSent -Existing $sent -Steps $due.Consumed }
        }
        $fired | Should -Be 3 -Because 'three configured steps must produce exactly three reminders over a whole lifetime'
    }
}

Describe 'Add-CBReminderSent' {
    It 'merges and de-duplicates, widest first' {
        Add-CBReminderSent -Existing '30' -Steps @(7, 30) | Should -Be '30,7'
    }
    It 'copes with an empty history' { Add-CBReminderSent -Existing '' -Steps @(1) | Should -Be '1' }
    It 'ignores rubbish in the stored value' {
        (ConvertTo-CBReminderSet -Value '30, ,seven,7') -join ',' | Should -Be '30,7'
    }
}

Describe 'Get-CBLifecycleAction' {
    BeforeAll {
        $raw = Get-CBDefaultSettings
        $raw.expiry.reminderDays = @(30, 7, 1)
        $raw.expiry.graceDays = 14
        $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        $now = [datetime]::new(2026, 6, 1, 12, 0, 0, [DateTimeKind]::Utc)
        function Make {
            param($State = 'active', $ExpiresOn = '2026-12-01', $Redeemed = '2026-01-01T00:00:00Z', $Sent = '', $Grace = '')
            [pscustomobject]@{
                PartitionKey = 'owner-1'; RowKey = 'guest-1'; Email = 'jane@partner.com'; DisplayName = 'Jane'
                State = $State; ExpiresOn = $ExpiresOn; RedeemedAtUtc = $Redeemed; RemindersSent = $Sent; GraceUntil = $Grace
            }
        }
    }

    It 'does nothing for a guest well inside their access' {
        (Get-CBLifecycleAction -Row (Make) -Settings $settings -Now $now).Action | Should -Be 'none'
    }
    It 'reminds when a step is reached' {
        $d = Get-CBLifecycleAction -Row (Make -ExpiresOn '2026-06-08') -Settings $settings -Now $now
        $d.Action | Should -Be 'remind'
        $d.Step | Should -Be 7
        $d.DaysLeft | Should -Be 7
    }
    It 'ends access the day after the end date, with a grace period' {
        $d = Get-CBLifecycleAction -Row (Make -ExpiresOn '2026-05-31') -Settings $settings -Now $now
        $d.Action | Should -Be 'block'
        $d.GraceUntil | Should -Be '2026-06-15'
    }
    It 'does not end access on the end date itself' {
        (Get-CBLifecycleAction -Row (Make -ExpiresOn '2026-06-01' -Sent '30,7,1') -Settings $settings -Now $now).Action |
            Should -Be 'none'
    }
    It 'leaves a blocked guest alone while the grace period runs' {
        (Get-CBLifecycleAction -Row (Make -State 'blocked' -ExpiresOn '2026-05-20' -Grace '2026-06-03') -Settings $settings -Now $now).Action |
            Should -Be 'none'
    }
    It 'removes a blocked guest once the grace period has lapsed' {
        (Get-CBLifecycleAction -Row (Make -State 'blocked' -ExpiresOn '2026-05-01' -Grace '2026-05-31') -Settings $settings -Now $now).Action |
            Should -Be 'delete'
    }
    It 'does not remove on the last day of grace' {
        (Get-CBLifecycleAction -Row (Make -State 'blocked' -ExpiresOn '2026-05-01' -Grace '2026-06-01') -Settings $settings -Now $now).Action |
            Should -Be 'none'
    }
    It 'refuses to act on a blocked row with no grace date recorded' {
        # Safer to need a human than to delete on the strength of a missing field.
        (Get-CBLifecycleAction -Row (Make -State 'blocked' -ExpiresOn '2026-01-01' -Grace '') -Settings $settings -Now $now).Action |
            Should -Be 'none'
    }
    It 'never acts twice on a deleted row' {
        (Get-CBLifecycleAction -Row (Make -State 'deleted' -ExpiresOn '2026-01-01') -Settings $settings -Now $now).Action |
            Should -Be 'none'
    }
    It 'leaves a row with no end date alone rather than guessing' {
        (Get-CBLifecycleAction -Row (Make -ExpiresOn '') -Settings $settings -Now $now).Action | Should -Be 'none'
    }
    It 'ends access for an invitation that was never accepted' {
        (Get-CBLifecycleAction -Row (Make -State 'pending' -ExpiresOn '2026-05-01' -Redeemed '') -Settings $settings -Now $now).Action |
            Should -Be 'block'
    }
    It 'reminds the owner about an invitation nobody has accepted yet' {
        (Get-CBLifecycleAction -Row (Make -State 'pending' -ExpiresOn '2026-06-08' -Redeemed '') -Settings $settings -Now $now).Action |
            Should -Be 'remind'
    }
    It 'walks a whole lifetime without ever repeating itself' {
        # 100 simulated days over one guest: three reminders, one block, one
        # delete, and nothing else, whatever order the scanner runs in.
        $row = Make -ExpiresOn '2026-06-20' -Sent ''
        $tally = @{ remind = 0; block = 0; delete = 0; none = 0 }
        foreach ($offset in 0..99) {
            $day = $now.AddDays($offset)
            $d = Get-CBLifecycleAction -Row $row -Settings $settings -Now $day
            $tally[$d.Action] = [int]$tally[$d.Action] + 1
            switch ($d.Action) {
                'remind' { $row.RemindersSent = Add-CBReminderSent -Existing $row.RemindersSent -Steps $d.Consumed }
                'block' { $row.State = 'blocked'; $row.GraceUntil = $d.GraceUntil }
                'delete' { $row.State = 'deleted' }
            }
        }
        "$($tally.remind)/$($tally.block)/$($tally.delete)" | Should -Be '3/1/1'
    }
}

Describe 'Test-CBRenewAllowed' {
    BeforeAll {
        $owner = @{ Oid = 'owner-1'; Upn = 'alex@contoso.com'; IsAdmin = $false }
        $admin = @{ Oid = 'admin-1'; Upn = 'root@contoso.com'; IsAdmin = $true }
        $row = [pscustomobject]@{ RenewCount = '3' }
    }
    It 'lets an owner extend by default' {
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings)))
        (Test-CBRenewAllowed -Row $row -Caller $owner -Settings $s -Days $null).Allowed | Should -BeTrue
    }
    It 'refuses an owner when self-service extension is switched off, but not an admin' {
        $raw = Get-CBDefaultSettings; $raw.expiry.allowSelfRenew = $false
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBRenewAllowed -Row $row -Caller $owner -Settings $s -Days $null).Allowed | Should -BeFalse
        (Test-CBRenewAllowed -Row $row -Caller $admin -Settings $s -Days $null).Allowed | Should -BeTrue
    }
    It 'enforces the renewal limit for an owner and exempts an admin' {
        $raw = Get-CBDefaultSettings; $raw.expiry.maxRenewals = 3
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBRenewAllowed -Row $row -Caller $owner -Settings $s -Days $null).Allowed | Should -BeFalse
        (Test-CBRenewAllowed -Row $row -Caller $admin -Settings $s -Days $null).Allowed | Should -BeTrue
    }
    It 'clamps the requested length to the policy maximum' {
        $raw = Get-CBDefaultSettings; $raw.expiry.maxDays = 60
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBRenewAllowed -Row $row -Caller $owner -Settings $s -Days 9999).Days | Should -Be 60
    }
}

Describe 'Get-CBRenewedExpiry' {
    It 'counts from today, not from the old end date' {
        $from = [datetime]::new(2026, 6, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings)))
        Get-CBRenewedExpiry -Days 30 -Settings $s -Now $from | Should -Be '2026-07-01'
    }
    It 'cannot exceed the policy maximum' {
        $raw = Get-CBDefaultSettings; $raw.expiry.maxDays = 10
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        $from = [datetime]::new(2026, 6, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Get-CBRenewedExpiry -Days 3650 -Settings $s -Now $from | Should -Be '2026-06-11'
    }
}

Describe 'Get-CBGuestActionOption' {
    BeforeAll {
        $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings)))
        $caller = @{ Oid = 'owner-1'; Upn = 'alex@contoso.com'; IsAdmin = $false }
        function Opt { param($Options, $Key) return ($Options | Where-Object { $_.key -eq $Key }) }
    }
    It 'offers resend only while an invitation is outstanding' {
        $pending = [pscustomobject]@{ RedeemedAtUtc = ''; RenewCount = '0' }
        $active = [pscustomobject]@{ RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
        (Opt (Get-CBGuestActionOption -Row $pending -Caller $caller -Settings $settings -State 'pending') 'resend').enabled | Should -BeTrue
        Opt (Get-CBGuestActionOption -Row $active -Caller $caller -Settings $settings -State 'active') 'resend' | Should -BeNullOrEmpty
    }
    It 'will not end access that has already ended' {
        $row = [pscustomobject]@{ RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
        (Opt (Get-CBGuestActionOption -Row $row -Caller $caller -Settings $settings -State 'blocked') 'cancel').enabled | Should -BeFalse
    }
    It 'renames extending to restoring once access has ended' {
        $row = [pscustomobject]@{ RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
        (Opt (Get-CBGuestActionOption -Row $row -Caller $caller -Settings $settings -State 'blocked') 'renew').label | Should -Be 'Restore access'
        (Opt (Get-CBGuestActionOption -Row $row -Caller $caller -Settings $settings -State 'deleted') 'renew').label | Should -Be 'Bring them back'
    }
    It 'gives a reason whenever it disables something' {
        $row = [pscustomobject]@{ RedeemedAtUtc = ''; RenewCount = '0' }
        foreach ($o in (Get-CBGuestActionOption -Row $row -Caller $caller -Settings $settings -State 'deleted')) {
            if (-not $o.enabled) { $o.reason | Should -Not -BeNullOrEmpty -Because "'$($o.key)' is offered as disabled, so it must say why" }
        }
    }
    It 'offers to take on a collaborator nobody is accountable for, and only then' {
        $unowned = [pscustomobject]@{ PartitionKey = (Get-CBOrphanPartition); RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
        $owned = [pscustomobject]@{ PartitionKey = 'owner-9'; RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
        (Opt (Get-CBGuestActionOption -Row $unowned -Caller $caller -Settings $settings -State 'active') 'claim').enabled | Should -BeTrue
        Opt (Get-CBGuestActionOption -Row $owned -Caller $caller -Settings $settings -State 'active') 'claim' | Should -BeNullOrEmpty
    }
    It 'does not offer to take on an account that has been removed' {
        # Claiming reads the account from the directory, so offering it for a
        # deleted one would only produce "that account no longer exists".
        $gone = [pscustomobject]@{ PartitionKey = (Get-CBOrphanPartition); RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
        Opt (Get-CBGuestActionOption -Row $gone -Caller $caller -Settings $settings -State 'deleted') 'claim' | Should -BeNullOrEmpty
    }
}

Describe 'Every offered action is actually implemented' {
    # A button whose key nothing handles does nothing at all when pressed: the
    # API answers "unknown action" or, worse, the portal has no spec for it and
    # the click is silently swallowed. Both ends are checked against the one
    # function that decides what to offer.
    BeforeAll {
        $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings)))
        $caller = @{ Oid = 'owner-1'; Upn = 'alex@contoso.com'; IsAdmin = $true }
        $rows = @(
            [pscustomobject]@{ PartitionKey = 'owner-1'; RedeemedAtUtc = ''; RenewCount = '0' }
            [pscustomobject]@{ PartitionKey = 'owner-1'; RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
            [pscustomobject]@{ PartitionKey = (Get-CBOrphanPartition); RedeemedAtUtc = '2026-01-01T00:00:00Z'; RenewCount = '0' }
        )
        $states = @('pending', 'active', 'expiring', 'blocked', 'deleted')
        $keys = @(foreach ($row in $rows) {
                foreach ($state in $states) {
                    (Get-CBGuestActionOption -Row $row -Caller $caller -Settings $settings -State $state).key
                }
            }) | Sort-Object -Unique
        $apiSource = Get-Content (Join-Path $PSScriptRoot '..\src\GuestActionApi\run.ps1') -Raw
        $portalSource = Get-Content (Join-Path $PSScriptRoot '..\web\app.js') -Raw
    }
    It 'has an API branch for every action key' {
        foreach ($key in $keys) {
            $apiSource | Should -Match "'$key'\s*\{" -Because "GuestActionApi must handle '$key'"
        }
    }
    It 'has a portal dialog for every action key' {
        foreach ($key in $keys) {
            $portalSource | Should -Match "(?m)^\s+$key\s*:\s*\{" -Because "actionSpec must describe '$key'"
        }
    }
}

# ---------------------------------------------------------------------------
# Sharing. The security property here is structural (the grant runs as the
# signed-in user), so what is worth testing is the normalisation that decides
# WHICH item gets shared, and the capability gates.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Adoption, inactivity, the health check and the version check.
# ---------------------------------------------------------------------------

Describe 'Get-CBAdoptionExpiry' {
    BeforeAll {
        $raw = Get-CBDefaultSettings
        $raw.expiry.attribute = 'extensionAttribute15'
        $raw.adoption.initialDays = 60
        $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        $now = [datetime]::new(2026, 6, 1, 0, 0, 0, [DateTimeKind]::Utc)
    }
    It 'counts from today, never from when the account was created' {
        # A guest created in 2021 must not be adopted and expired the same
        # afternoon. This is the single most consequential decision in adoption.
        $user = [pscustomobject]@{ id = 'g1'; createdDateTime = '2021-03-01T00:00:00Z' }
        (Get-CBAdoptionExpiry -User $user -Settings $settings -Now $now).ExpiresOn | Should -Be '2026-07-31'
    }
    It 'respects a date already on the account rather than overwriting it' {
        $user = [pscustomobject]@{
            id = 'g1'
            onPremisesExtensionAttributes = [pscustomobject]@{ extensionAttribute15 = '2027-01-15' }
        }
        $result = Get-CBAdoptionExpiry -User $user -Settings $settings -Now $now
        $result.ExpiresOn | Should -Be '2027-01-15'
        $result.Source | Should -Match 'already on'
    }
    It 'ignores rubbish in the attribute and decides for itself' {
        $user = [pscustomobject]@{
            id = 'g1'
            onPremisesExtensionAttributes = [pscustomobject]@{ extensionAttribute15 = 'cost centre 42' }
        }
        (Get-CBAdoptionExpiry -User $user -Settings $settings -Now $now).ExpiresOn | Should -Be '2026-07-31'
    }
    It 'reads whichever attribute is configured, not a fixed one' {
        $raw2 = Get-CBDefaultSettings
        $raw2.expiry.attribute = 'extensionAttribute3'
        $s2 = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw2))
        $user = [pscustomobject]@{
            id = 'g1'
            onPremisesExtensionAttributes = [pscustomobject]@{ extensionAttribute3 = '2027-02-02'; extensionAttribute15 = '2030-01-01' }
        }
        (Get-CBAdoptionExpiry -User $user -Settings $s2 -Now $now).ExpiresOn | Should -Be '2027-02-02'
    }
}

Describe 'Get-CBInactiveDays' {
    BeforeAll { $now = [datetime]::new(2026, 6, 1, 0, 0, 0, [DateTimeKind]::Utc) }
    It 'measures from the last sign-in when there is one' {
        Get-CBInactiveDays -LastSignIn '2026-03-03T00:00:00Z' -Created '2020-01-01T00:00:00Z' -Now $now | Should -Be 90
    }
    It 'falls back to the creation date when they have never signed in' {
        Get-CBInactiveDays -LastSignIn '' -Created '2026-05-02T00:00:00Z' -Now $now | Should -Be 30
    }
    It 'returns -1 when neither is known, so callers can tell unknown from idle' {
        Get-CBInactiveDays -LastSignIn '' -Created '' -Now $now | Should -Be -1
    }
}

Describe 'Get-CBInactivityDecision' {
    BeforeAll {
        $raw = Get-CBDefaultSettings
        $raw.inactivity.enabled = $true
        $raw.inactivity.thresholdDays = 180
        $raw.inactivity.action = 'notify'
        $on = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        $off = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings)))
        $now = [datetime]::new(2026, 6, 1, 0, 0, 0, [DateTimeKind]::Utc)
        function Idle {
            param($LastSignIn = '2025-01-01T00:00:00Z', $State = 'active', $Notified = '', $Invited = '2024-01-01T00:00:00Z')
            [pscustomobject]@{
                PartitionKey = 'o1'; RowKey = 'g1'; Email = 'jane@partner.com'; DisplayName = 'Jane'
                State = $State; LastSignInUtc = $LastSignIn; InvitedAtUtc = $Invited; InactivityNotifiedUtc = $Notified
            }
        }
    }
    It 'does nothing at all while the policy is off' {
        (Get-CBInactivityDecision -Row (Idle) -Settings $off -Now $now).Action | Should -Be 'none'
    }
    It 'notices a guest well past the threshold' {
        $d = Get-CBInactivityDecision -Row (Idle) -Settings $on -Now $now
        $d.Action | Should -Be 'notify'
        $d.Days | Should -Be 516
    }
    It 'leaves a recently active guest alone' {
        (Get-CBInactivityDecision -Row (Idle -LastSignIn '2026-05-01T00:00:00Z') -Settings $on -Now $now).Action | Should -Be 'none'
    }
    It 'does nothing when there is no sign-in data at all' {
        # A tenant without the licence for sign-in data must not have its guests
        # treated as never having signed in.
        (Get-CBInactivityDecision -Row (Idle -LastSignIn '' -Invited '') -Settings $on -Now $now).Action | Should -Be 'none'
    }
    It 'counts from the invitation when they have genuinely never signed in' {
        $d = Get-CBInactivityDecision -Row (Idle -LastSignIn '' -Invited '2024-06-01T00:00:00Z') -Settings $on -Now $now
        $d.Action | Should -Be 'notify'
        $d.Reason | Should -Match 'never signed in'
    }
    It 'only warns once about the same guest' {
        (Get-CBInactivityDecision -Row (Idle -Notified '2026-04-01T00:00:00Z') -Settings $on -Now $now).Action | Should -Be 'none'
    }
    It 'warns again each time when the administrator asks for that' {
        $raw2 = Get-CBDefaultSettings
        $raw2.inactivity.enabled = $true
        $raw2.inactivity.notifyOnce = $false
        $repeat = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw2))
        (Get-CBInactivityDecision -Row (Idle -Notified '2026-04-01T00:00:00Z') -Settings $repeat -Now $now).Action | Should -Be 'notify'
    }
    It 'leaves a guest alone once their access has already ended' {
        (Get-CBInactivityDecision -Row (Idle -State 'blocked') -Settings $on -Now $now).Action | Should -Be 'none'
        (Get-CBInactivityDecision -Row (Idle -State 'deleted') -Settings $on -Now $now).Action | Should -Be 'none'
    }
    It 'ends access rather than deleting, even on the strongest setting' {
        foreach ($setting in @('block', 'delete')) {
            $raw2 = Get-CBDefaultSettings
            $raw2.inactivity.enabled = $true
            $raw2.inactivity.action = $setting
            $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw2))
            (Get-CBInactivityDecision -Row (Idle) -Settings $s -Now $now).Action |
                Should -Be 'block' -Because 'nothing in the tool deletes in one step; the grace period always applies'
        }
    }
}

Describe 'Test-CBNewerVersion' {
    It 'compares numerically, not as text' {
        # '0.10.0' -lt '0.9.0' as strings, which would leave an install two years
        # behind without ever showing a banner.
        Test-CBNewerVersion -Current '0.9.0' -Latest '0.10.0' | Should -BeTrue
        Test-CBNewerVersion -Current '0.10.0' -Latest '0.9.0' | Should -BeFalse
    }
    It 'is false for the same version' { Test-CBNewerVersion -Current '1.2.3' -Latest '1.2.3' | Should -BeFalse }
    It 'tolerates a leading v' { Test-CBNewerVersion -Current '1.0.0' -Latest 'v1.1.0' | Should -BeTrue }
    It 'says no rather than guessing when either side is not a version' {
        Test-CBNewerVersion -Current '1.0.0' -Latest '<html>404</html>' | Should -BeFalse
        Test-CBNewerVersion -Current '' -Latest '1.0.0' | Should -BeFalse
    }
}

Describe 'Get-CBExpectedFunction' {
    It 'watches only the scheduled jobs, where silence is the symptom' {
        $names = @(Get-CBExpectedFunction | ForEach-Object { $_.Name })
        $names | Should -Contain 'GuestScanner'
        $names | Should -Contain 'RedemptionPoller'
        # Nobody opening the portal for a day is not a fault.
        $names | Should -Not -Contain 'MeApi'
        $names | Should -Not -Contain 'GuestsApi'
    }
    It 'gives every watched job a staleness limit and a description' {
        foreach ($f in Get-CBExpectedFunction) {
            $f.MaxAgeHours | Should -BeGreaterThan 0
            $f.What | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Adoption and inactivity settings' {
    It 'keeps adoption on by default, because guests that predate the tool are the problem' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))
        $s.adoption.enabled | Should -BeTrue
    }
    It 'keeps inactivity cleanup off by default, because it acts on people unprompted' {
        $s = ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))
        $s.inactivity.enabled | Should -BeFalse
    }
    It 'enforces a floor on the adoption runway' {
        $raw = Get-CBDefaultSettings; $raw.adoption.initialDays = 1
        (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw)).adoption.initialDays | Should -Be 7
    }
    It 'never lets an adopted guest outlive the policy maximum' {
        $raw = Get-CBDefaultSettings
        $raw.expiry.maxDays = 30
        $raw.adoption.initialDays = 3650
        (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw)).adoption.initialDays | Should -Be 30
    }
}

Describe 'The sending mailbox is not a setting' {
    # The managed identity is authorised for ONE mailbox, through an Exchange
    # management scope built at deploy time. A portal-editable sender would
    # therefore be a field that silently stops all mail the moment somebody
    # changed it, which is why the sender lives in an app setting and the portal
    # only ever displays it.
    It 'is nowhere in the settings an administrator can save' {
        $json = (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))) | ConvertTo-Json -Depth 20
        $json | Should -Not -Match '"sender[A-Za-z]*"'
    }
    It 'is read from the app setting, and the service desk address is only ever a recipient' {
        $mail = Get-Content (Join-Path $PSScriptRoot '..\src\Modules\Collaborate\functions\Mail.ps1') -Raw
        $mail | Should -Match '\$cfg\.SenderUpn'
        $mail | Should -Not -Match 'servicedeskEmail.*sendMail'
    }
}

Describe 'Sending as the inviter' {
    It 'has no setting for who a message comes from' {
        # Deliberately not configurable. A message somebody caused by pressing a
        # button comes from that person; the shared mailbox is the fallback and
        # the sender for everything nobody is present for. Offering a choice
        # between "correct" and "also correct but less personal" is not a
        # decision worth a field, and a tenant that picked the wrong one would
        # only find out from a guest.
        $json = (ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))) | ConvertTo-Json -Depth 20
        $json | Should -Not -Match '"sendAs"'
    }
    It 'parks the recipe, not the rendered message' {
        # Storing the rendered HTML would replay a copy made before an admin
        # edited the template, and would put a few KB of markup in every row.
        $json = ConvertTo-CBPendingMail -Key 'invitation' -To 'jane@partner.com' -Values @{ guest = @{ displayName = 'Jane' } }
        $json | Should -Not -Match '<html'
        $back = ConvertFrom-CBPendingMail -Json $json
        $back.key | Should -Be 'invitation'
        $back.to | Should -Be 'jane@partner.com'
        $back.values.guest.displayName | Should -Be 'Jane'
    }
    It 'treats an unreadable or empty parked message as nothing parked' {
        ConvertFrom-CBPendingMail -Json '' | Should -BeNullOrEmpty
        ConvertFrom-CBPendingMail -Json 'not json at all' | Should -BeNullOrEmpty
        ConvertFrom-CBPendingMail -Json '{"to":"x@y.com"}' | Should -BeNullOrEmpty
    }
    It 'round-trips values through JSON in a shape the renderer can still read' {
        # The fallback send re-renders from the parked recipe, which comes back
        # as PSCustomObjects rather than the hashtables it went in as.
        $back = ConvertFrom-CBPendingMail -Json (ConvertTo-CBPendingMail -Key 'invitation' -To 'a@b.com' -Values @{
                guest = @{ displayName = 'Jane Rivera' }; expiresOn = '9 November 2026'
            })
        Expand-CBTemplate -Template 'Hello {{guest.displayName}}, until {{expiresOn}}.' -Values $back.values |
            Should -Be 'Hello Jane Rivera, until 9 November 2026.'
    }
}

Describe 'Delegated scopes' {
    It 'asks for exactly the scopes the deployment consents' {
        # A scope requested at runtime but not consented at deploy time fails with
        # AADSTS65001 the first time somebody tries to share, and the cause is
        # nowhere near the symptom. permissions.json is the single source both the
        # deploy and the update reconcile against, so the runtime list must match
        # it exactly rather than approximately.
        $permissions = Get-Content (Join-Path $PSScriptRoot '..\deploy\permissions.json') -Raw | ConvertFrom-Json
        # Scopes marked usedBy 'browser' are consented on the app registration
        # but requested by the SPA with the user's own token, never by the
        # on-behalf-of flow. Asking for one here would send that mail from a
        # datacentre IP, which is the thing the split exists to avoid.
        $declared = @($permissions.delegatedScopes | Where-Object { "$($_.usedBy)" -ne 'browser' } | ForEach-Object { $_.value }) | Sort-Object
        $requested = @(Get-CBOboScope | ForEach-Object { ($_ -split '/')[-1] }) | Sort-Object
        ($requested -join ',') | Should -Be ($declared -join ',')
    }
    It 'never asks for Mail.Send on the server side' {
        # The whole point of sending from the browser. If this ever appears in
        # the OBO scope list, mail is going out from the Function App's IP on a
        # token the user never saw issued.
        Get-CBOboScope | Should -Not -Contain 'https://graph.microsoft.com/Mail.Send'
    }
    It 'requests every scope against Microsoft Graph' {
        foreach ($scope in Get-CBOboScope) { $scope | Should -BeLike 'https://graph.microsoft.com/*' }
    }
}

Describe 'ConvertTo-CBGraphPathSegment' {
    It 'leaves a SharePoint site id exactly alone, commas and all' {
        # Percent-encoding the commas gives 404 "Requested site could not be
        # found", which is what broke opening a site from the picker.
        $siteId = 'contoso.sharepoint.com,ecb5c1be-10e6-4250-9ac1-8e7a835aec2e,f461c255-82f1-4bd9-8135-717b93e5bd59'
        ConvertTo-CBGraphPathSegment -Value $siteId -What 'site id' | Should -Be $siteId
    }
    It 'leaves the b! prefix on a drive id alone' {
        # EscapeDataString turns 'b!' into 'b%21'. Every SharePoint drive id
        # starts that way, so escaping would have broken file browsing next.
        ConvertTo-CBGraphPathSegment -Value 'b!aBc-123_x' -What 'drive id' | Should -Be 'b!aBc-123_x'
    }
    It 'refuses anything that could change which URL is called' {
        foreach ($bad in @('../../users', 'a/b', 'x?y', 'a#b', 'a%2Fb', 'has space', 'a&b')) {
            { ConvertTo-CBGraphPathSegment -Value $bad -What 'site id' } |
                Should -Throw -Because "'$bad' could redirect the request somewhere else"
        }
    }
    It 'refuses an empty or absurdly long id' {
        { ConvertTo-CBGraphPathSegment -Value '' -What 'site id' } | Should -Throw
        { ConvertTo-CBGraphPathSegment -Value ('a' * 600) -What 'site id' } | Should -Throw
    }
    It 'names the thing that was wrong' {
        { ConvertTo-CBGraphPathSegment -Value 'a/b' -What 'drive id' } | Should -Throw -ExpectedMessage '*drive id*'
    }
}

Describe 'ConvertTo-CBBrowseItem' {
    It 'normalises an ordinary file' {
        $item = ConvertTo-CBBrowseItem -Item ([pscustomobject]@{
                id = 'i1'; name = 'Q3 Proposal.docx'; webUrl = 'https://contoso.sharepoint.com/x'
                size = 1234; lastModifiedDateTime = '2026-06-01T10:00:00Z'
                file = [pscustomobject]@{ mimeType = 'application/vnd' }
                parentReference = [pscustomobject]@{ driveId = 'd1'; path = '/drive/root:/Projects' }
            })
        $item.kind | Should -Be 'file'
        $item.driveId | Should -Be 'd1'
        $item.icon | Should -Be 'doc'
        $item.path | Should -Be 'Projects'
    }
    It 'follows remoteItem, so a shortcut shares the real file and not the shortcut' {
        # /me/drive/recent returns items that live in someone else's drive with
        # their true identity in remoteItem. Using the outer id would grant
        # access to the pointer instead of the document.
        $item = ConvertTo-CBBrowseItem -Item ([pscustomobject]@{
                id = 'shortcut'; name = 'wrong'
                parentReference = [pscustomobject]@{ driveId = 'mydrive' }
                remoteItem = [pscustomobject]@{
                    id = 'real'; name = 'Shared Budget.xlsx'; webUrl = 'https://contoso.sharepoint.com/b'
                    file = [pscustomobject]@{}
                    parentReference = [pscustomobject]@{ driveId = 'theirdrive'; path = '/drive/root:/Finance' }
                }
            })
        $item.id | Should -Be 'real'
        $item.driveId | Should -Be 'theirdrive'
        $item.name | Should -Be 'Shared Budget.xlsx'
        $item.icon | Should -Be 'sheet'
    }
    It 'treats a folder as a folder and counts its children' {
        $item = ConvertTo-CBBrowseItem -Item ([pscustomobject]@{
                id = 'f1'; name = 'Projects'
                folder = [pscustomobject]@{ childCount = 7 }
                parentReference = [pscustomobject]@{ driveId = 'd1' }
            })
        $item.kind | Should -Be 'folder'
        $item.icon | Should -Be 'folder'
        $item.childCount | Should -Be 7
    }
    It 'treats a package (a OneNote notebook) as a folder rather than as neither' {
        $item = ConvertTo-CBBrowseItem -Item ([pscustomobject]@{
                id = 'p1'; name = 'Team Notebook'
                package = [pscustomobject]@{ type = 'oneNote' }
                parentReference = [pscustomobject]@{ driveId = 'd1' }
            })
        $item.kind | Should -Be 'folder'
    }
    It 'falls back to the drive it was asked about when the item does not say' {
        $item = ConvertTo-CBBrowseItem -Item ([pscustomobject]@{ id = 'x'; name = 'a.txt'; file = [pscustomobject]@{} }) -FallbackDriveId 'd9'
        $item.driveId | Should -Be 'd9'
    }
}

Describe 'Format-CBRelativeDate and Get-CBItemWhenLabel' {
    BeforeAll { $now = [datetime]::new(2026, 8, 12, 12, 0, 0, [DateTimeKind]::Utc) }
    It 'reads naturally close to today' {
        Format-CBRelativeDate -Value '2026-08-12T09:00:00Z' -Now $now | Should -Be 'today'
        Format-CBRelativeDate -Value '2026-08-11T09:00:00Z' -Now $now | Should -Be 'yesterday'
        Format-CBRelativeDate -Value '2026-08-05T09:00:00Z' -Now $now | Should -Be '7 days ago'
    }
    It 'gives up on relative once it stops meaning anything' {
        Format-CBRelativeDate -Value '2026-01-04T09:00:00Z' -Now $now | Should -Be '4 January 2026'
    }
    It 'copes with a clock ahead of ours rather than saying "-1 days ago"' {
        Format-CBRelativeDate -Value '2026-08-13T09:00:00Z' -Now $now | Should -Be 'just now'
    }
    It 'says nothing at all when there is no date' {
        Format-CBRelativeDate -Value '' -Now $now | Should -Be ''
        Get-CBItemWhenLabel -Value '' -Kind 'used' -Now $now | Should -Be ''
    }
    It 'uses the verb that matches where the date came from' {
        # A recent list is ordered by when somebody LOOKED at something. Calling
        # that "edited" is a quietly wrong statement about a file they only read.
        Get-CBItemWhenLabel -Value '2026-08-11T09:00:00Z' -Kind 'used' -Now $now | Should -Be 'Opened yesterday'
        Get-CBItemWhenLabel -Value '2026-08-11T09:00:00Z' -Kind 'modified' -Now $now | Should -Be 'Edited yesterday'
    }
}

Describe 'Get-CBSharedItemView' {
    BeforeAll {
        $now = [datetime]::new(2026, 8, 12, 12, 0, 0, [DateTimeKind]::Utc)
        $json = @'
[{"kind":"file","name":"Q3 Proposal.docx","webUrl":"https://contoso.sharepoint.com/q3.docx","role":"write","sharedBy":"alex@contoso.com","sharedAtUtc":"2026-08-11T09:00:00Z"},
 {"kind":"team","name":"Project Falcon","webUrl":"https://teams.microsoft.com/l/team/1","role":"","sharedBy":"alex@contoso.com","sharedAtUtc":"2026-07-01T09:00:00Z"}]
'@
    }
    It 'says what each thing is and what they can do with it' {
        $items = Get-CBSharedItemView -Json $json -Now $now
        $items.Count | Should -Be 2
        $items[0].kindLabel | Should -Be 'File'
        $items[0].roleLabel | Should -Be 'Can edit'
        $items[0].sharedAtLabel | Should -Be 'yesterday'
        $items[1].kindLabel | Should -Be 'Team'
        $items[1].roleLabel | Should -Be 'Member'
    }
    It 'only turns an https address into a link' {
        # These come from Graph rather than from a person, but a URL is one of
        # the two places markup turns into behaviour.
        $odd = '[{"kind":"file","name":"x","webUrl":"javascript:alert(1)","role":"read"}]'
        # Wrapped in @(): a single-item return unrolls, which is the convention
        # documented in Sanitise.ps1 and the reason callers always wrap.
        @(Get-CBSharedItemView -Json $odd -Now $now)[0].webUrl | Should -Be ''
    }
    It 'survives a row written by an older version, or no row at all' {
        Get-CBSharedItemView -Json '' -Now $now | Should -HaveCount 0
        Get-CBSharedItemView -Json 'not json' -Now $now | Should -HaveCount 0
        @(Get-CBSharedItemView -Json '[{"name":"only a name"}]' -Now $now)[0].kindLabel | Should -Be 'File'
    }
    It 'drops an entry with nothing to show' {
        Get-CBSharedItemView -Json '[{"kind":"file"},null]' -Now $now | Should -HaveCount 0
    }
}

Describe 'Get-CBItemCategory' {
    It 'names the container kinds' {
        Get-CBItemCategory -Kind 'site' -Icon 'site' -Name 'Marketing' | Should -Be 'SharePoint site'
        Get-CBItemCategory -Kind 'drive' -Icon 'drive' -Name 'Documents' | Should -Be 'Document library'
        Get-CBItemCategory -Kind 'folder' -Icon 'folder' -Name 'Q3' | Should -Be 'Folder'
    }
    It 'names the common office types in words' {
        Get-CBItemCategory -Kind 'file' -Icon 'sheet' -Name 'a.xlsx' | Should -Be 'Excel workbook'
        Get-CBItemCategory -Kind 'file' -Icon 'slide' -Name 'a.pptx' | Should -Be 'PowerPoint presentation'
    }
    It 'falls back to the extension rather than to nothing' {
        Get-CBItemCategory -Kind 'file' -Icon 'file' -Name 'archive.dwg' | Should -Be 'DWG file'
        Get-CBItemCategory -Kind 'file' -Icon 'file' -Name 'noextension' | Should -Be 'File'
    }
}

Describe 'ConvertTo-CBInsightItem' {
    BeforeAll {
        function New-Insight {
            param([string]$Ref = 'drives/b!AbC-123/items/01XYZ', [string]$Title = 'Q3 Proposal.docx', [string]$Type = 'docx')
            return [pscustomobject]@{
                resourceReference     = [pscustomobject]@{ id = $Ref; webUrl = 'https://contoso.sharepoint.com/q3.docx'; type = 'microsoft.graph.driveItem' }
                resourceVisualization = [pscustomobject]@{ title = $Title; type = $Type; containerDisplayName = 'Marketing' }
                lastUsed              = [pscustomobject]@{ lastAccessedDateTime = '2026-08-01T09:00:00Z' }
            }
        }
    }
    It 'takes the drive and item id straight out of the reference' {
        # No follow-up call per row: the reference already carries both, which is
        # what makes a twenty-row recent list one request instead of twenty-one.
        $item = ConvertTo-CBInsightItem -Insight (New-Insight)
        $item.driveId | Should -Be 'b!AbC-123'
        $item.id | Should -Be '01XYZ'
        $item.kind | Should -Be 'file'
    }
    It 'shows where it lives, which is what tells two files of the same name apart' {
        (ConvertTo-CBInsightItem -Insight (New-Insight)).path | Should -Be 'Marketing'
    }
    It 'gets the icon from the declared type when the title has no extension' {
        (ConvertTo-CBInsightItem -Insight (New-Insight -Title 'Q3 Proposal' -Type 'xlsx')).icon | Should -Be 'sheet'
    }
    It 'drops anything that is not a drive item' {
        # Insights also cover mail attachments and the like. Rendering one as a
        # file would offer somebody a row that cannot be shared.
        ConvertTo-CBInsightItem -Insight (New-Insight -Ref 'https://contoso.sharepoint.com/somewhere') | Should -BeNullOrEmpty
        ConvertTo-CBInsightItem -Insight (New-Insight -Ref '') | Should -BeNullOrEmpty
    }
}

Describe 'Get-CBItemIcon' {
    It 'maps the common office types' {
        Get-CBItemIcon -Name 'a.docx' | Should -Be 'doc'
        Get-CBItemIcon -Name 'a.XLSX' | Should -Be 'sheet'
        Get-CBItemIcon -Name 'a.pptx' | Should -Be 'slide'
        Get-CBItemIcon -Name 'a.pdf' | Should -Be 'pdf'
    }
    It 'falls back for anything unknown or extensionless' {
        Get-CBItemIcon -Name 'a.wibble' | Should -Be 'file'
        Get-CBItemIcon -Name 'README' | Should -Be 'file'
    }
}

Describe 'Get-CBItemPath' {
    It 'strips the Graph prefix and decodes' {
        Get-CBItemPath -RawPath '/drive/root:/Projects/Q3%20Plans' | Should -Be 'Projects/Q3 Plans'
    }
    It 'is empty at the root' { Get-CBItemPath -RawPath '/drive/root:' | Should -Be '' }
    It 'copes with nothing' { Get-CBItemPath -RawPath '' | Should -Be '' }
}

Describe 'Test-CBSharingCapability' {
    It 'follows the administrator switches' {
        $raw = Get-CBDefaultSettings
        $raw.sharing.files = $true; $raw.sharing.folders = $false; $raw.sharing.teams = $false
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBSharingCapability -Kind 'file' -Settings $s).Allowed | Should -BeTrue
        (Test-CBSharingCapability -Kind 'folder' -Settings $s).Allowed | Should -BeFalse
        (Test-CBSharingCapability -Kind 'team' -Settings $s).Allowed | Should -BeFalse
    }
    It 'says which capability was switched off' {
        $raw = Get-CBDefaultSettings; $raw.sharing.teams = $false
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        (Test-CBSharingCapability -Kind 'team' -Settings $s).Reason | Should -Match 'Adding guests to Teams'
    }
}

Describe 'Get-CBShareRole' {
    BeforeAll { $settings = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject](Get-CBDefaultSettings))) }
    It 'honours a valid request' { Get-CBShareRole -Requested 'write' -Settings $settings | Should -Be 'write' }
    It 'falls back to the configured default for rubbish' {
        Get-CBShareRole -Requested 'owner' -Settings $settings | Should -Be "$($settings.sharing.defaultRole)"
    }
    It 'downgrades to read when edit access is switched off' {
        $raw = Get-CBDefaultSettings; $raw.sharing.allowWrite = $false
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        Get-CBShareRole -Requested 'write' -Settings $s | Should -Be 'read'
    }
}

Describe 'Set-CBBrowseShareable' {
    It 'marks only what the administrator allows, and says why not' {
        $raw = Get-CBDefaultSettings; $raw.sharing.folders = $false
        $s = [pscustomobject](ConvertTo-CBSanitisedSettings -Raw ([pscustomobject]$raw))
        $items = @(
            [ordered]@{ kind = 'file'; name = 'a.docx' },
            [ordered]@{ kind = 'folder'; name = 'Projects' },
            [ordered]@{ kind = 'site'; name = 'Marketing' }
        )
        $marked = Set-CBBrowseShareable -Items $items -Settings $s
        $marked[0].canShare | Should -BeTrue
        $marked[1].canShare | Should -BeFalse
        $marked[1].shareBlockedReason | Should -Match 'folders'
        $marked[2].canShare | Should -BeFalse -Because 'a site is a container, not something to share directly'
    }
}

Describe 'Get-CBShareFailureMessage' {
    It 'explains a site with external sharing switched off' {
        Get-CBShareFailureMessage -Message 'externalSharing is disabled' -ItemName 'Budget.xlsx' -Recipient 'j@p.com' |
            Should -Match 'External sharing is switched off'
    }
    It 'explains a plain permission refusal without leaking Graph jargon' {
        $m = Get-CBShareFailureMessage -Message 'Graph POST returned HTTP 403: accessDenied' -ItemName 'Budget.xlsx' -Recipient 'j@p.com'
        $m | Should -Match 'do not have permission'
        $m | Should -Not -Match 'accessDenied'
    }
    It 'passes an unrecognised failure through rather than inventing a cause' {
        Get-CBShareFailureMessage -Message 'something entirely new' -ItemName 'x' -Recipient 'y' |
            Should -Match 'something entirely new'
    }
}

Describe 'Set-CBRowValue' {
    It 'adds a property the stored row never had' {
        # Table storage omits properties that were never written, so a guest who
        # has never been blocked comes back with no GraceUntil at all. Plain
        # assignment throws on that, which would break the very first block.
        $row = [pscustomobject]@{ RowKey = 'g1'; Email = 'jane@partner.com' }
        { $row.GraceUntil = '2026-06-15' } | Should -Throw
        (Set-CBRowValue -Row $row -Name 'GraceUntil' -Value '2026-06-15').GraceUntil | Should -Be '2026-06-15'
    }
    It 'overwrites one that is already there' {
        $row = [pscustomobject]@{ GraceUntil = 'old' }
        (Set-CBRowValue -Row $row -Name 'GraceUntil' -Value 'new').GraceUntil | Should -Be 'new'
    }
}

Describe 'Get-CBGraceUntilString' {
    It 'is today when no grace is configured' {
        $from = [datetime]::new(2026, 6, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Get-CBGraceUntilString -GraceDays 0 -From $from | Should -Be '2026-06-01'
    }
    It 'never goes backwards on a negative value' {
        $from = [datetime]::new(2026, 6, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Get-CBGraceUntilString -GraceDays -5 -From $from | Should -Be '2026-06-01'
    }
}

Describe 'Get-CBGuestSortKey' {
    It 'puts what needs attention first' {
        $keys = @(
            @{ n = 'active'; k = (Get-CBGuestSortKey -State 'active' -DaysLeft 200) },
            @{ n = 'blocked'; k = (Get-CBGuestSortKey -State 'blocked' -DaysLeft -3) },
            @{ n = 'expiring'; k = (Get-CBGuestSortKey -State 'expiring' -DaysLeft 5) },
            @{ n = 'pending'; k = (Get-CBGuestSortKey -State 'pending' -DaysLeft 80) },
            @{ n = 'deleted'; k = (Get-CBGuestSortKey -State 'deleted' -DaysLeft -50) }
        )
        (($keys | Sort-Object { $_.k }).n) -join ',' | Should -Be 'blocked,expiring,pending,active,deleted'
    }
    It 'puts the soonest to end first within one state' {
        $soon = Get-CBGuestSortKey -State 'expiring' -DaysLeft 2
        $later = Get-CBGuestSortKey -State 'expiring' -DaysLeft 20
        $soon | Should -BeLessThan $later
    }
}
