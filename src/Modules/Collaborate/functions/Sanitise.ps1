# Small pure validators and coercers shared by the settings sanitiser, the email
# renderer and the welcome-page builder.
#
# Everything in this file is deliberately free of Azure and Graph calls so the
# whole validation surface can be unit tested without a tenant. If you add a rule
# that needs the network, it belongs somewhere else.
#
# ---------------------------------------------------------------------------
# RETURNING A LIST, and why there are two conventions
#
# PowerShell unrolls an array on the way out of a function, so a one-element
# list comes back as a scalar and serialises to JSON as a value rather than an
# array. The usual guard is a unary comma, 'return , @($x)'. It has a trap: put
# it around an EMPTY array and you get a one-element array CONTAINING the empty
# array, so a caller writing @(f) sees a count of one for "nothing". That has
# already caused a healthy deployment to report a missing function and would
# have had the watchdog email about a problem on a healthy install.
#
# So which form is correct depends on how the caller consumes it:
#
#   * SANITISERS whose result is assigned straight into the settings object
#     (ConvertTo-CBDomainList, ConvertTo-CBHostList, ConvertTo-CBReminderDays)
#     use 'return , ...'. The caller assigns directly, and the comma is what
#     keeps a single allowed domain an ARRAY in the stored JSON.
#
#   * QUERY functions that hand a list back to a caller (Get-CBSettingsWarning,
#     Test-CBHealth, Get-CBPortalBanner and friends) use 'return @($x)', and
#     every caller wraps the CALL in @(). Both ends then agree for zero, one and
#     many.
#
# Tests under "Functions that return a list" pin both shapes.
# ---------------------------------------------------------------------------

function ConvertTo-CBHtmlEncoded {
    <#
    .SYNOPSIS
        HTML-encodes a value for insertion into markup. Every substituted token in
        an email or on the welcome page goes through this.
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function ConvertTo-CBBoundedString {
    <#
    .SYNOPSIS
        Trims, collapses newlines out of single-line values, and caps length, so
        no admin-entered string can blow up an email header or a page title.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Value, [int]$MaxLength = 200, [string]$Default = '', [switch]$AllowNewLines)
    $s = "$Value"
    if (-not $AllowNewLines) { $s = $s -replace '[\r\n\t]+', ' ' }
    $s = $s.Trim()
    if (-not $s) { return $Default }
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).Trim() }
    return $s
}

function ConvertTo-CBInt {
    <#
    .SYNOPSIS
        Parses an int with a fallback and clamps it into a range. Used for every
        numeric setting, so a typo can never become a dangerous value.
    #>
    [CmdletBinding()]
    param([AllowNull()]$Value, [int]$Default, [int]$Min = [int]::MinValue, [int]$Max = [int]::MaxValue)
    $n = $Default
    if ($null -eq $Value -or -not [int]::TryParse("$Value", [ref]$n)) { $n = $Default }
    if ($n -lt $Min) { $n = $Min }
    if ($n -gt $Max) { $n = $Max }
    return $n
}

function ConvertTo-CBBool {
    [CmdletBinding()]
    param([AllowNull()]$Value, [bool]$Default = $false)
    if ($null -eq $Value -or "$Value" -eq '') { return $Default }
    if ($Value -is [bool]) { return $Value }
    return (@('true', '1', 'yes', 'on') -contains "$Value".Trim().ToLowerInvariant())
}

function Test-CBEmailAddress {
    <#
    .SYNOPSIS
        Syntactic email validation. Empty is treated as valid (means "unset").
    #>
    [CmdletBinding()] param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $true }
    try { $null = [System.Net.Mail.MailAddress]::new($Address.Trim()) }
    catch { return $false }
    return ($Address.Trim() -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
}

function Test-CBDomainName {
    [CmdletBinding()] param([string]$Domain)
    if ([string]::IsNullOrWhiteSpace($Domain)) { return $false }
    return ($Domain.Trim().ToLowerInvariant() -match '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$')
}

function ConvertTo-CBDomainList {
    <#
    .SYNOPSIS
        Normalises an allow/block list: strips a leading @, lowercases, drops
        anything that is not a domain, de-duplicates, and caps the list length.
    #>
    [CmdletBinding()] param([AllowNull()]$Value, [int]$MaxItems = 200)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        $d = "$item".Trim().TrimStart('@').ToLowerInvariant()
        if ($d -match '@') { $d = ($d -split '@')[-1] }
        if (-not (Test-CBDomainName -Domain $d)) { continue }
        if ($out -notcontains $d) { $out.Add($d) }
        if ($out.Count -ge $MaxItems) { break }
    }
    return , $out.ToArray()
}

function Test-CBHexColor {
    [CmdletBinding()] param([string]$Value)
    return ("$Value".Trim() -match '^#[0-9a-fA-F]{6}$')
}

function ConvertTo-CBHexColor {
    <#
    .SYNOPSIS
        Returns a normalised #rrggbb colour, or the fallback when the input is
        not a six-digit hex colour. Three-digit shorthand is expanded.
    #>
    [CmdletBinding()] param([AllowNull()]$Value, [Parameter(Mandatory)][string]$Default)
    $v = "$Value".Trim()
    if ($v -match '^#[0-9a-fA-F]{3}$') {
        # Expand #abc to #aabbcc. The -join has to be parenthesised: it binds
        # looser than +, so without this the array stringifies as "aa bb cc".
        $v = '#' + (($v.Substring(1).ToCharArray() | ForEach-Object { "$_$_" }) -join '')
    }
    if (Test-CBHexColor -Value $v) { return $v.ToLowerInvariant() }
    return $Default
}

function Get-CBRelativeLuminance {
    <#
    .SYNOPSIS
        WCAG relative luminance of an #rrggbb colour (0 = black, 1 = white).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Hex)
    $h = $Hex.TrimStart('#')
    $channels = @(0, 2, 4) | ForEach-Object {
        $c = [Convert]::ToInt32($h.Substring($_, 2), 16) / 255.0
        if ($c -le 0.03928) { $c / 12.92 } else { [Math]::Pow((($c + 0.055) / 1.055), 2.4) }
    }
    return (0.2126 * $channels[0]) + (0.7152 * $channels[1]) + (0.0722 * $channels[2])
}

function Get-CBContrastRatio {
    <#
    .SYNOPSIS
        WCAG contrast ratio between two #rrggbb colours (1.0 to 21.0).
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Foreground, [Parameter(Mandatory)][string]$Background)
    $a = Get-CBRelativeLuminance -Hex $Foreground
    $b = Get-CBRelativeLuminance -Hex $Background
    $light = [Math]::Max($a, $b); $dark = [Math]::Min($a, $b)
    return [Math]::Round((($light + 0.05) / ($dark + 0.05)), 2)
}

function Get-CBReadableTextColor {
    <#
    .SYNOPSIS
        Black or white, whichever is more readable on the given background. Used
        so a branded header band always has legible text whatever colour the
        admin picked.
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Background)
    $onWhite = Get-CBContrastRatio -Foreground '#ffffff' -Background $Background
    $onBlack = Get-CBContrastRatio -Foreground '#1b1b1b' -Background $Background
    return $(if ($onWhite -ge $onBlack) { '#ffffff' } else { '#1b1b1b' })
}

function ConvertTo-CBSafeHtml {
    <#
    .SYNOPSIS
        Removes the actively dangerous constructs from admin-authored HTML: script
        and style-injection elements, inline event handlers, and javascript:/data:
        URLs in href and src.
    .DESCRIPTION
        This is NOT a general-purpose sanitiser and does not need to be: the only
        people who can write here already hold the Collaborate administrator role,
        and the rendered output is delivered by email or served on a page with a
        restrictive CSP. It exists so that a copy-pasted template from the
        internet cannot quietly ship a script tag into every guest's inbox.
    #>
    [CmdletBinding()] param([AllowNull()][string]$Html)
    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $s = $Html
    foreach ($tag in @('script', 'iframe', 'object', 'embed', 'form', 'base', 'meta', 'link')) {
        $s = [regex]::Replace($s, "<\s*$tag\b[^>]*>.*?<\s*/\s*$tag\s*>", '', 'IgnoreCase, Singleline')
        $s = [regex]::Replace($s, "<\s*/?\s*$tag\b[^>]*>", '', 'IgnoreCase, Singleline')
    }
    # Inline event handlers: on<something>= followed by a quoted or bare value.
    $s = [regex]::Replace($s, '\son[a-z]+\s*=\s*"[^"]*"', '', 'IgnoreCase')
    $s = [regex]::Replace($s, "\son[a-z]+\s*=\s*'[^']*'", '', 'IgnoreCase')
    $s = [regex]::Replace($s, '\son[a-z]+\s*=\s*[^\s>]+', '', 'IgnoreCase')
    # Dangerous URL schemes in attributes.
    $s = [regex]::Replace($s, '(href|src|action)\s*=\s*"(\s*(javascript|vbscript|data)\s*:)[^"]*"', '$1="#"', 'IgnoreCase')
    $s = [regex]::Replace($s, "(href|src|action)\s*=\s*'(\s*(javascript|vbscript|data)\s*:)[^']*'", '$1="#"', 'IgnoreCase')
    return $s
}

function Test-CBUrlAllowed {
    <#
    .SYNOPSIS
        Is this URL an https URL whose host is in the allowlist? Used for the
        welcome page's redirect target so it can never become an open redirect,
        and again server side before a target is ever put into an invitation URL.
    .PARAMETER AllowedHosts
        Exact host names. A leading '.' means "this domain and any subdomain".
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Url, [string[]]$AllowedHosts)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $u = $Url.Trim()
    # Protocol-relative and scheme-less inputs are rejected outright rather than
    # coerced: '//evil.com' is a redirect off-site in every browser.
    if ($u -notmatch '^https://') { return $false }
    $parsed = $null
    if (-not [Uri]::TryCreate($u, [UriKind]::Absolute, [ref]$parsed)) { return $false }
    if ($parsed.Scheme -ne 'https') { return $false }
    $targetHost = $parsed.Host.ToLowerInvariant()
    foreach ($allowed in @($AllowedHosts)) {
        $a = "$allowed".Trim().ToLowerInvariant()
        if (-not $a) { continue }
        if ($a.StartsWith('.')) {
            if ($targetHost -eq $a.TrimStart('.') -or $targetHost.EndsWith($a)) { return $true }
        }
        elseif ($targetHost -eq $a) { return $true }
    }
    return $false
}

function ConvertTo-CBHostList {
    <#
    .SYNOPSIS
        Normalises admin-supplied extra hosts for the welcome-page allowlist.
        Accepts bare hosts or full URLs; keeps an optional leading dot (meaning
        "and subdomains") and drops anything that is not a host name.
    #>
    [CmdletBinding()] param([AllowNull()]$Value, [int]$MaxItems = 25)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($Value)) {
        $h = "$item".Trim().ToLowerInvariant()
        if (-not $h) { continue }
        if ($h -match '^[a-z][a-z0-9+.-]*://') { $h = ([Uri]$h).Host }
        $h = ($h -split '/')[0]
        $leadingDot = $h.StartsWith('.')
        $bare = $h.TrimStart('.')
        if (-not (Test-CBDomainName -Domain $bare)) { continue }
        $normalised = if ($leadingDot) { ".$bare" } else { $bare }
        if ($out -notcontains $normalised) { $out.Add($normalised) }
        if ($out.Count -ge $MaxItems) { break }
    }
    return , $out.ToArray()
}
