# Sharing


## The rule everything else follows from

> **The grant runs as the signed-in user. Always.**

Browsing, sharing a drive item and adding somebody to a Team all go through
`Invoke-CBGraphAsUser`, which exchanges the caller's own token for a Graph token
carrying their delegated rights. Graph then answers as them.

That makes "you can only share what you can already reach": the picker shows what Graph
returned for that person.

The invitation is the opposite. Creating a guest account runs as the **managed
identity**, because in secure tenants employees cannot invite anybody at all. See
[architecture.md](architecture.md#the-two-identities-and-why) for why.

## Order of operations, and why

Sharing with somebody new is three things that can fail, so the order is
chosen as:

1. **Create the guest, and do not send anything.** At this point nobody knows
   whether the item is actually shareable.
2. **Grant the access, as the user.**
3. **Now send one email**, and send the version that matches what happened.

Doing it the other way around, which is the obvious way, sends somebody an
invitation to open a file they then cannot open.

If step 2 fails, the guest created in step 1 **still exists**. It is not rolled
back and not hidden: the API returns the guest's id with `guestCreated: true`,
and the portal offers to retry the share alone.

## The picker's Recent pane

Recent comes from **`/me/insights/used`**

Entries that are not driveItems, such as mail attachments, are dropped rather than rendered
as rows that cannot be opened.

Every row in every pane carries what it is ("Excel workbook"), where it lives
(the site or folder), and when it was last touched, plus a link that opens the
real thing in a new tab.

Insights can be switched off for a tenant, in which case they return 403. That
is caught, the fallback carries the pane alone, and an empty pane **says which
source was unavailable**.

## What a share actually is

`POST /drives/{driveId}/items/{itemId}/invite` with `requireSignIn: true` and
`sendInvitation: false`.

- **`requireSignIn`** makes it a permission tied to that identity, not a
  link anybody could forward. This matters for the lifecycle: when a guest is
  deleted, their access goes with them. An anonymous link would outlive
  everything this tool does.
- **`sendInvitation: false`** because SharePoint's own notification is
  the unbranded mail the tool exists to replace.

The item is read back as the user before anything happens, so the confirmation
names what is really being shared, and the file/folder capability gate is applied
to what the item **is** rather than to what the client said it was.

## Search before share

The recipient step searches every guest in the tenant, annotated with whose they
are. Inviting somebody new is offered only after a search has run and found
nobody, and it then goes through the same verdict as the invite screen. So
sharing with a partner a colleague already works with reuses that account instead
of creating a second one.

An existing guest owned by a colleague can be shared with. Ownership does not
change; the activity is recorded against both the owner and the person sharing.

## Teams

Only Teams you own, and only where guests are accepted:

| Check | Read as | Why |
|---|---|---|
| Do you own this Team | The user, implicitly | The add itself is `POST /groups/{id}/members/$ref` as you. Graph refuses if you do not own it, so there is nothing to double-check |
| Does the tenant allow guests in groups | The managed identity | Tenant configuration, cached per worker |
| Does this Team allow guests | The managed identity | A per-group `Group.Unified.Guest` setting most employees cannot read at all |

Reading the policy as the service is what lets the picker grey out a Team rather than letting somebody discover it by failing.

A guest is added to a Team **after they are invited but before they accept**. The
account exists from the moment the invitation is created, which is what lets
"invite and add to the Team" be one action for the person doing it.

## When SharePoint will not allow it

**Tenant level** `SharePointTenantSettings.Read.All` on the
managed identity reads `/admin/sharepoint/settings`, cached per worker. With
external sharing switched off tenant-wide the sharing card is disabled and says
why, and `Invoke-CBShareRequest` refuses.

The same read gives the allowed/blocked domain lists, so a recipient SharePoint
would reject is refused at the same point rather than after the invitation.

**Site level** comes from SharePoint's own REST API on the site itself, read as
the signed-in user with the delegated `AllSites.Read` scope. Graph does not expose this. 

| Property | Read from | Notes |
|---|---|---|
| `ShareByEmailEnabled` | `/_api/site` as the user | The site-level external sharing block |
| `ReadOnly`, `WriteLocked` | `/_api/site` as the user | A locked site: nothing can be granted |
| `Classification` | `/_api/site` as the user | Shown as-is |

## When SharePoint says no

Sharing can fail for policy reasons, and these errors
reach ordinary employees. `Get-CBShareFailureMessage` translates:

| What Graph said | What the person is told |
|---|---|
| External sharing disabled | Which site forbids it, and that its owner can change that |
| `accessDenied` | That they need permission to share it themselves |
| Blocked domain | That SharePoint's own external sharing rules refuse that domain, separately from Collaborate |
| `itemNotFound` | That it has moved or been deleted since they picked it |

Anything unrecognised is passed through.

## Two people sharing with the same guest

"What they can reach" is a list the viewer is not automatically entitled
to read. **A document name is itself information** -- "Redundancy plan Q3.xlsx"
tells you something whether or not you can open the file. So:

| Who is looking | What they see |
|---|---|
| The person who shared it | Name, link, role, and an **Unshare** button |
| Anybody else, including the owner | "A file shared by somebody else", with who shared it and when. No name, no link, no role |
| An administrator | Every name, no links removed. Still no Unshare on other people's shares |

**Team names are never redacted.** Its
membership is probably visible to its members anyway

The URL is dropped along with the name, because a SharePoint URL contains the
file name.

### Unsharing

`POST /api/guests/{id}/action` with `unshare`, and it runs **as the person**,
delegated. 

Only the person who shared something can un-share it here, **administrators
included**.

A site that has since stopped allowing external people refuses the removal too.
The record is dropped

## Switching it off

`sharing.files`, `sharing.folders` and `sharing.teams` are independent. A
disabled capability is **unreachable**, not hidden: `/api/browse`, `/api/teams`
and `/api/share` all return 403.

Turn all three off and the delegated permissions can be removed from the app
registration entirely; see [permissions.md](permissions.md#tightening).
