# Changelog

All notable changes to Collaborate are documented here. The version is the single
source in `VERSION` (stamped into the module manifest, the `CB_VERSION` app
setting, and the portal footer at deploy time).

## 0.6.4
### Every question is asked before the work starts

- The deploy takes minutes, all typed input now happens in the first half minute

### The portal upload was not a firewall problem

- 
  **shared-key access being switched off** (commonly by an Azure Policy)
- The upload now runs **as the operator** (`--auth-mode login`) first, falling
  back to the account key. The deploy grants itself Storage Blob Data Contributor
  on that account.
- When both fail it prints `allowSharedKeyAccess` and `publicNetworkAccess`

### Re-running no longer warns about things that are fine

- **The admin group assignment** is checked before it is attempted. Re-posting an
  assignment that already exists fails
- **The portal upload** Open the account for the few seconds the upload takes
  and close it again.
- A failed portal upload is now **fatal in the deploy** and a listed blocker in
  the update.
- Site settings carry SharePoint's **raw answer** alongside the conclusion, so a
  wrong verdict can be checked against the source.

## 0.6.2
### A delegated scope on a second resource could be reconciled and still missing

- `requiredResourceAccess` was patched **once per resource**, reading the
  application back between writes. Graph does not promise that read sees the
  write, so the second resource could patch a list that no longer contained the
  first, and which one survived depended on hashtable ordering. Built once and
  patched once now.
- `Update-Collaborate.ps1` **skipped delegated reconciliation silently** when it
  could not read the app registration. It now says so and reports it as a
  failure.

## 0.6.1
### Deploy: help choosing the address to allow

- The deploy now lists the addresses **Entra has seen you sign in from**, grouped
  by address with a count and when each was last used, so the allowlist is
  recognised. Ported from M365AutoRevocate's
  `Show-ARSignInIpHint`, over `az rest` rather than the Az PowerShell module,
  which the deploy already requires.
- It now also asks **outside** Cloud Shell, not only inside it.

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



