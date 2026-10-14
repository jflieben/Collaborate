# Changelog

All notable changes to Collaborate are documented here. The version is the single
source in `VERSION` (stamped into the module manifest, the `CB_VERSION` app
setting, and the portal footer at deploy time).

## 0.7.1
A full review pass: security, lifecycle correctness, performance, deployment
and the portal.

### Security

- **An owner can no longer undo IT.** A guest that was deleted or switched off
  directly in Entra is marked as ended outside Collaborate, and only an
  administrator can bring it back. Before, "Bring them back" restored and
  re-enabled it with the managed identity's rights.
- **Guests that sign in with credentials in this tenant are refused.** Their
  tokens carry no `idp` and the `acct` claim was never requested, so the guest
  check now asks the directory for the caller's `userType` (cached for an hour).
- **Token validation is stricter.** A token without `exp` or `tid` is refused
  instead of skipping the check, the issuer must match exactly, and an anonymous
  caller can no longer force a signing-key download on every request.
- **Claiming an unowned guest needs the same right as inviting.** With an
  inviter group set, anybody outside it could claim a guest and then end their
  access.
- **One person can no longer pause the whole tool.** Resending an invitation
  now counts toward the personal daily limit, and reaching the tenant-wide
  invitation cap refuses further invitations without stopping expiry and
  cleanup. The counters are now updated atomically, so parallel requests cannot
  slip past them.
- **A colleague's share no longer shows its file name in your activity feed.**
  It is filed under the person who shared it, as the collaborator panel
  already did.
- **"Owned only" visibility now holds everywhere.** Asking the owner and the
  claim refusal no longer name them, and asking is limited to 20 a day.
- **Parked mail is no longer overwritten or sent twice.** The colleague who
  was handed a message can report on it, and a second message for the same
  guest goes from the shared mailbox instead of replacing the first.
- **Errors no longer show internals to employees.** They get a reference to
  quote; administrators and Graph's own messages are unchanged.
- **The bootstrap administrator stays dropped** when the settings cannot be
  read, instead of coming back on a storage error.
- The setup wizard's save keeps the published-page hash and logo locked, as
  Configuration does.
- **The welcome page shows the real destination host** next to the button, and
  "and subdomains" entries on shared suffixes (`.sharepoint.com`, `.co.uk`,
  hosting platforms) are refused, so neither can turn it into an open redirect.

### Lifecycle

- **Inactivity cleanup no longer acts without sign-in data.** Without the P1/P2
  licence, or for a guest the sign-in sweep did not return, every guest
  invited long enough ago was treated as never having signed in.
- **Graph's "never" timestamp is no longer a sign-in.** `0001-01-01` slipped
  past its check as `01/01/0001`, which read as 739,000 idle days. Graph and
  Table responses now keep timestamps as the ISO strings they were.
- **Simulation mode no longer moves end dates** on the inactivity path; live,
  the new date is also written onto the account.
- **Adoption never blocks in the run that adopts.** A date already on the
  account that has passed, or leaves no time for reminders, is moved out. New
  dates are spread so a large backlog cannot all expire on one day and trip
  the storm guard, and adoption has a ten-minute budget.
- **A guest is only closed as removed after a direct 404.** The directory
  listing is eventually consistent, and a failed lookup in the poller is no
  longer read as "deleted".
- **Updates follow a handed-over guest** instead of recreating a stub row
  under the previous owner.
- **A refused block or removal is recorded and not retried**, and a removal of
  an account that is already gone counts as done. Neither uses up the storm
  guard's daily count.
- **With no grace period, removal happens the same day** as intended.
- **The activity log is trimmed again.** Retention asked for 5,000 rows in one
  page, which Table storage refuses, and the error was swallowed. Batch deletes
  now check each row's result.
- **New invitations are always checked for acceptance**, rather than waiting
  behind hundreds of old ones that will never be accepted.
- Graph POSTs are no longer retried on a 500 or 504, which could send a mail
  twice. Storage calls retry on 503.

### Performance

- Single-guest actions and queued work read the guest directly instead of
  scanning the Guests table, and the invite search queries only its hits.

### Mail

- Reminders and "access ended" mails link straight to that guest's Extend
  action (`{{guestUrl}}`).

### The portal

- **Links straight to a collaborator.** `#guest/<id>` opens their panel and
  `#guest/<id>/renew` opens it on Extend; every tab has its own address, Back
  works, and the address survives signing in. Reminder mails use this.
- **Find and act on many at once.** A search box over name, email and reason;
  the status counts filter the list when clicked; **Extend selected** and **End
  access for selected** with a confirmation listing the names; **Download as
  CSV** of exactly what is shown.
- **Add to a Team** from a collaborator's panel, next to Share something now.
- **The Activity tab** shows which collaborator each entry is about, renders
  the details as readable lines, and filters what is loaded.
- **Admin tabs keep their edits to themselves.** Saving Configuration no longer
  also saves half-typed email wording or Branding fields; each tab shows when it
  has unsaved changes, and leaving the page asks first.
- **Review and resume asks first**, showing why processing paused and that
  queued work will now go ahead.
- A second share in the same session works (the Share button stayed disabled),
  a slow search answer can no longer offer to invite an address you already
  corrected, and a site's sharing block no longer follows you to Recent or My
  files.
- Opening a tab before the portal finished loading no longer leaves it empty,
  and a passing token hiccup no longer throws you back to sign-in mid-wizard.
- Dutch: about 150 more strings translated, column headers and sentences built
  from parts included, and names, reasons and file names are never translated.
- A Content-Security-Policy, keyboard and screen reader support for the panel
  and wizard, announced notifications, and a card layout on phones.

### Deployment

- **Re-running the deploy works on a locked-down install.** The portal's static
  website setting ran before the firewall was opened and failed, printing the
  storage key. Keys are now masked in every error.
- **Changing `-SenderUpn` actually moves the Exchange scope**, and the fallback
  only accepts a scope limited to exactly that mailbox.
- **The SharePoint host is found without an application Sites permission**,
  from the tenant's initial domain when `/sites/root` is refused.
- Code deployment storage uses the managed identity, so no storage key is left
  in the app settings.
- HTTPS only, TLS 1.2, FTP and basic publishing credentials off; blob public
  access off on the portal and welcome accounts.
- Network re-runs set the allowed addresses exactly, and `-PublicWithSso` lifts
  an earlier lockdown.
- The operator's temporary upload role on the portal account is removed again.
- `Update-Collaborate.ps1` checks it is pointed at the right tenant.
- `Remove-Collaborate.ps1` refuses a resource group that holds anything it did
  not create (`-Force` overrides).
- The installer verifies downloads against the release checksums, and release
  notes pin the installer to that release.
- Unused `TeamMember.ReadWrite.All` removed. Permissions no longer listed are
  reported, and `-PruneUnlistedPermissions` removes them.
- CI stamps the released manifest and pins `actions/checkout`.

## 0.7.0
### "The deployed code is out of date" on a perfectly good deployment

- `VERSION` reached the **CB_VERSION app setting** but never the **module
  manifest**, which nothing had bumped since 0.5.0. Diagnostics compares the two
  precisely to catch a zip that did not land, so with nothing keeping them in
  step it cried wolf on every install from 0.6 onward.
- Both deploy paths now stamp the version into the **staged** manifest before
  zipping, so the code reports the version it is. The working tree is untouched.
- The **Version card no longer contradicts the banner**. "Running 0.7.0" was read
  off an app setting, not off the code, so it claimed "up to date" beside a
  banner saying the opposite. While the two disagree it now says which is which.
- Tests pin all of it: the stamp itself, that both scripts stamp before they zip
  and after CB.Common is loaded, and that the committed manifest matches
  `VERSION` so a local import is honest too.

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



