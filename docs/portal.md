# The portal

A small single-page app hosted as a static website in its own storage account.
No build step, no framework, MSAL bundled locally so content filtering cannot
break sign-in.

Two audiences use it and they see different things. Ordinary employees get three
big buttons. Administrators additionally get the tabs that configure everything.

## Signing in

- Delegated Entra sign-in (MSAL, authorisation code with PKCE). The page holds
  the public client id, tenant id, API base and scope, written into
  `authConfig.js` by the deploy. There is no secret.
- The enterprise app does **not** require assignment by default, so every internal member
  can sign in and manage the guests they own. Administration comes from the
  `Collaborate.Admin` app role that has to be assigned explicitly
- **Guests cannot sign in.** The API refuses a token whose `acct` claim marks the
  caller as a guest, or whose tenant is not this one.
- The API validates every request itself (RS256 against the tenant JWKS,
  audience, issuer, expiry) in addition to App Service Easy Auth.

## First run: the setup wizard

The first administrator to sign in gets a five-step wizard. The last step verifies single sign-on.

| Check | What it proves |
|---|---|
| Your sign-in token is valid | Signature, audience, issuer, expiry and tenant all check out, and it reports which roles you hold |
| App Service authentication is in front of the API | A verified client principal arrived with the request, so the platform gate is really processing traffic|
| Anonymous requests are refused | The app calls its own public URL with no Authorization header and asserts the answer is not 200. A 401 from Easy Auth passes; so does a 403 from the network restrictions |
| Collaborate can act on your behalf | The on-behalf-of exchange works, which everything under Sharing depends on. Only required if sharing is switched on |
| The expiry attribute is available | The chosen `extensionAttribute` is not already holding somebody else's data |
| The public welcome page can be published | The managed identity really can write to the public site, so invitations will not send guests to a page that was never published |
| The sender mailbox is reachable | Advisory: Exchange role assignments (in rare cases) take up to half an hour to replicate |

Setup cannot be completed while a required check fails. Completing it publishes
the welcome page and permanently drops the bootstrap administrator rights the
deploying operator held until then.

## What employees see

Three cards:

1. **Manage external collaborators** - who you have invited, their status and end
   date, and the actions to extend, end or hand over.
2. **Share a file or folder** - browse SharePoint and your OneDrive, pick the
   thing you wanted to share, and give one external person access to it.
3. **Add someone to a Team** - for Teams you own, where the Team allows guests.

Both sharing cards run the same three-step flow: what, who, confirm. The "who"
step searches every guest in the tenant before it will offer to invite anybody,
and inviting somebody new happens inside the same flow, so "share this with a
partner who does not exist here yet" is one screen sequence rather than two
separate. See [sharing.md](sharing.md) for the order things happen in and
why.

### Last active

Each collaborator shows when they last successfully signed in. Beneath it, 
whether they ever accepted the invitation: not accepted yet, or that Entra does
not record the answer either way.

This needs an **Entra ID P1 or P2** licence, which is what supplies
`signInActivity`. Without it the column is not shown at all. The data is
read by the nightly scan; **Diagnostics -> Refresh from Entra** reads it now.

The collaborators list is ordered by what needs attention: blocked first, then
ended, ending soon, waiting to be accepted, and finally the ones that are fine.
Administrators get a toggle for every
external account in the tenant, with the colleague accountable for each and
anything unowned called out.

### Opening a collaborator

Each row has one **Open** button that slides in a panel holding everything about one collaborator on a single
surface:

- their status and the sentence explaining it;
- why they exist, when access ends, how many days are left, whether they ever
  accepted, when they were last active, who owns them;
- **what they can reach** (below);
- the actions. Anything
  unavailable is stated as a sentence with its reason instead.

Choosing an action **replaces the contents of that panel** rather than opening a
second window over the top: the same surface asks for the days or the reason,
confirms, and closes.

### What a collaborator can reach

The panel lists what Collaborate granted: files, folders and Teams, newest
first, with the role, who shared it and when, each linking out to the real thing.

The panel says plainly that **access given directly in SharePoint or Teams is not
listed**, because it was never Collaborate's to see. Only a tool like M365Permissions.com can do that kind of fancy stuff.

### What an owner can do to a guest

| Action | What it does | Offered when |
|---|---|---|
| **Extend** | New end date counted from today, not added to the current one | Always, unless the tenant requires an administrator or the renewal limit is reached |
| **Restore access** | The same action on a blocked guest: sign-in back on, new end date, grace cleared | Their access has ended and grace has not lapsed |
| **Bring them back** | The same action on a deleted guest: restored from the Entra recycle bin with the same object id, so existing shares work again | Within 30 days of removal |
| **End access now** | Sign-in off immediately, with the normal grace period, so it is undoable | Their access has not already ended |
| **Take this on** | You become accountable for a collaborator nobody owns, and they get an end date | Nobody is accountable for them and the account still exists |
| **Hand over** | A colleague becomes accountable and receives the reminders from then on | The account still exists |
| **Send the invitation again** | A fresh redeem link for the same account, keeping the end date and anything already shared | They have not accepted, and their access is still live |

Actions that do not apply are shown greyed out with the reason.

The people picker behind **Hand over** and behind bulk assignment leaves *you*
out.
There are two exceptions:
a collaborator **nobody owns**, and an administrator assigning unowned accounts
in bulk. 

### Search before invite, always

The invite step starts as a search across existing guests, not as a blank form.
Typing shows the people the tenant already works with, each annotated with whose
they are. 

| Verdict | What the portal offers |
|---|---|
| Not found | The invitation form: their name, why, and for how long |
| Already yours | A link straight to your collaborators, with their status |
| Owned by a colleague | Names the owner and offers to send them a message about it |
| Nobody owns them | Offer to claim them, with a reason and an end date |
| They are an internal member | Refuse, with a mailto link |
| The domain is not allowed | Refuse, quoting the rule that applies |

Whether the owner is **named** depends on the guest visibility setting. Set to
"only the ones I own", the verdict still says somebody works with them (so no
duplicate is created) but does not say who; administrators always see the name.

### What an invitation actually does

1. Creates the B2B invitation with `sendInvitationMessage: false`, so Microsoft's
   default mail is suppressed.
2. Writes the end date onto the guest object in the configured
   `extensionAttribute`, and records the inviter as the Entra sponsor.
3. Writes the record here: owner, reason, end date, state.
4. Sends the tenant's own branded invitation, carrying the redeem link.

Steps 2 to 4 happen after the guest exists, so if one of them fails the person is
told exactly what did not happen.

## What administrators see

- **Configuration** - how long access lasts, reminder steps, the grace period
  before deletion, who may invite, domain rules, sharing capabilities, inactive
  guest cleanup, safety limits, simulation mode. It also shows, read-only, the
  **shared mailbox** mail is sent from, the **enterprise application** this runs
  on, and **who holds the administrator role** on it, each linking into Entra.
  Those are managed in Entra rather than here, and are read live rather than
  from a value stamped at install: an admin group recorded on day one and shown
  forever is right until somebody changes it, which is exactly when a person is
  looking it up.
- **Branding** - company name, portal title and subtitle, two colours with
  pickers, and the logo. Applies to the portal itself, to every email, and to the
  public welcome page; saving updates all three. There is a readability warning
  when a chosen colour would make text hard to read, which warns rather than
  blocks. **Nothing here takes effect until Save**, the logo included: choosing a
  file shows a preview and uploads on save.

  The main colour does two jobs with opposite requirements. It is **painted
  behind** the header band, the email header and the welcome page banner, where
  the text on top is picked for contrast automatically. It is also the colour of
  **links and the active tab**, which sit on the page's own background. A colour
  light enough to sit behind a logo with dark lettering is far too light to read
  as a link, so the portal derives a separate ink colour: the main colour if it
  is readable, otherwise the accent, otherwise a darkened version. 
- **Emails** - every message the tool can send, with an on/off switch, subject
  and body editors, a token palette that inserts the placeholders that message
  actually receives, a live preview rendered in the branded shell, a real test
  send to yourself, and reset-to-default per message.
- **Activity** - the audit feed, filtered to your own guests or everything.
- **Diagnostics** - mail, delegation, the published welcome page's integrity, the
  storm guard, queue depths, and every background job's last run and last error.

Everything an administrator can change is changeable here. The Azure portal and
blob storage are not part of any normal administrative task.

## Branding before sign-in

The sign-in screen runs before any token exists, so it cannot ask the API what
the company is called. It reads a small public `assets/branding.json` that the
app republishes alongside the welcome page. After
sign-in the portal re-applies the authoritative values from `/api/me`.

## Gotchas

- Easy Auth must use `unauthenticatedClientAction = AllowAnonymous`, **not**
  `Return401`. A browser CORS preflight carries no Authorization header, so
  `Return401` makes the platform reject the `OPTIONS` before App Service attaches
  the CORS header, and the portal fails with a CORS error despite the origin
  being allow-listed. The API is still not open: every function validates the
  bearer token itself and fails closed.
- The portal's storage account must be reachable from wherever employees browse.
  It is IP-restricted by default, which suits a corporate network; use
  `-PublicWithSso` when people work from home and you rely on Conditional Access
  instead.
- `msal-browser.min.js` is bundled locally rather than loaded from a CDN.
