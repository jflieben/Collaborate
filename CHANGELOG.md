# Changelog

All notable changes to Collaborate are documented here. The version is the single
source in `VERSION` (stamped into the module manifest, the `CB_VERSION` app
setting, and the portal footer at deploy time).

## 0.7.0
### Dutch

- The whole portal is available in **Dutch**. English stays the source language
  and doubles as the dictionary key, so an untranslated string renders as its
  English sentence, never as a blank or an identifier.
- **Administrators set the default** on Configuration; **anybody can override it
  for themselves** from the picker at the top right, and that choice is stored
  against their account so it follows them to another machine. Before either
  exists, the browser's language decides.
- Email bodies, welcome-page copy and branding are admin-editable free text and
  stay as written.

### A site that blocks sharing no longer hides that once you look past it

- `blockedBanner` was referenced and never defined, so **the picker threw** on
  every listing after somebody pressed "Look anyway".

### Site sharing status was read but never shown

- `siteSettings` came back with **PascalCase** keys while the portal read
  camelCase
- Inside a site that refuses external sharing, the picker now shows a **warning
  above the contents** and **disables every share button**
- A site's settings arriving **after** it was opened now redraw the screen the
  user is on, so clicking faster than the lookup no longer loses the warning.


### Re-running no longer warns about things that are fine

- **The admin group assignment** is checked before it is attempted. Re-posting an
  assignment that already exists fails
- **The portal upload** Open the account for the few seconds the upload takes
  and close it again.
- A failed portal upload is now **fatal in the deploy** and a listed blocker in
  the update.


### Deploy: help choosing the address to allow

- The deploy now lists the addresses **Entra has seen you sign in from**, grouped
  by address with a count and when each was last used, so the allowlist is
  recognised. Ported from M365AutoRevocate's
  `Show-ARSignInIpHint`, over `az rest` rather than the Az PowerShell module,
  which the deploy already requires.
- It now also asks **outside** Cloud Shell.

## 0.6.0
### Two people can share with the same guest

- Sharing with somebody else's collaborator was already allowed.
  What changes is who may read the resulting list: **a document name is itself
  information**
- You see the name, link and role of what **you** shared. Anything a colleague
  shared shows as its kind plus their name and the date, with no document name
  and **no link** (a SharePoint URL contains the file name).
- **Team names are never hidden.** A Team is a named group of people whose
  membership its members can probably see anyway.
- **Administrators see every name**
- Who shared each thing is now shown per item.

### Per-site settings, read from SharePoint

- New delegated scope **`AllSites.Read`** on the SharePoint resource (a second
  resource alongside Graph), used through the same on-behalf-of flow. Graph does
  not expose a site's sharing or lock state; SharePoint does, on the site itself,
  and a user who can open the site can read it.
- Read: `ShareByEmailEnabled` (the site-level external sharing block),
  `ReadOnly` / `WriteLocked` (a locked site), `Classification`.

### Knowing sharing is blocked before you get there

- New app permission **`SharePointTenantSettings.Read.All`** (read-only) for the
  managed identity. With external sharing off tenant-wide the sharing card is
  disabled. The same read gives the allowed/blocked domain lists, so a recipient
  SharePoint would reject is caught early.

### The picker: dead sites, missing buttons, unreadable errors

- **Sites you follow that no longer exist are dropped.** `/me/followedSites`
  keeps returning deleted sites; they are checked in one `$batch` and anything
  that 404s is left out, with a note saying how many. A failed check leaves the
  list alone.
- Opening a site that has gone now says so, instead of a generic failure.
- **Every failure carries technical detail**: a plain sentence for the person,
  and an expandable block with the Graph status, error code and request id plus
  a copy button.

### Share from the collaborator's panel

- **Share something now** / **Share something else** in "What they can reach",
  with the collaborator already chosen: the wizard drops to two steps (What,
  Confirm). Hidden for a guest whose access has ended.

### Unshare, from the same panel

- **Unshare** on anything you shared: `POST /api/guests/{id}/action` with
  `unshare`, running **as you**, delegated, exactly as the grant. 
- Shares now record the drive, item and group ids

### The collaborators table sorts and filters

- **Who**, **Status** and **Last active** sort on click: ascending, descending,
  then back to the default. 
- Sorting by status follows that urgency order rather than the alphabet, which
  would put "active" above "blocked".
- **Who** and **Status** carry a filter in the header


## 0.5.0
Woohoo!

## Unreleased



