# Permissions

Everything Collaborate needs is declared in
[`deploy/permissions.json`](../deploy/permissions.json). Both the deploy and the
update reconcile against that file.

There are three separate (automated) grants.

## 1. Application permissions, held by the managed identity

These cover administration: the things employees cannot do themselves in a
locked-down tenant.

| Permission | Why |
|---|---|
| `User.Invite.All` | Create the B2B invitation |
| `User.ReadWrite.All` | Read guests, write the expiry date to the extension attribute, block sign-in, set the sponsor |
| `User.DeleteRestore.All` | Delete once the grace period lapses; restore a guest renewed in time |
| `Directory.Read.All` | Resolve the inviter group, verified domains, guest search, the owner people picker |
| `AuditLog.Read.All` | `signInActivity` for the last-active column and inactive-guest cleanup, and invitation events when adopting guests that predate the tool |

**Directory role: Guest Inviter.** `User.Invite.All` alone is not enough in a
tenant that restricts guest invitations to administrative roles. The deploy assigns the role to the managed
identity.

## 2. Delegated permissions, held by the portal app registration

Every one of these carries a real user's rights, so Graph enforces what that
person can already do. They divide by **where the token is used**.

Used through the on-behalf-of flow, from the Function App:

| Permission | Why |
|---|---|
| `User.Read` | Identify the signed-in user on the delegated path |
| `Sites.Read.All` | Find the SharePoint sites that user can already see, and their recent items |
| `Files.ReadWrite.All` | Browse their files and grant a guest access to one, as them |
| `TeamMember.ReadWrite.All` | Add a guest to a Team they own, as them |
| `GroupMember.ReadWrite.All` | The group membership behind that Team add |
| `Team.ReadBasic.All` | Read a Team's web address, so the guest gets a link straight into the Team. |

Used **only in the browser**, by the portal itself:

| Permission | Why |
|---|---|
| `Mail.Send` | Send an invitation from the inviter's own mailbox.|


The alternative, an **application** `Mail.Send` on the managed identity, would
let a guest management tool send mail as anybody in the tenant. This is why we goe through Exchange RBAC
scoped to one mailbox rather than a Graph app role (section 3).

The deploy consents all of these tenant-wide (an `oauth2PermissionGrant` with
`consentType: AllPrincipals`), so no employee is ever shown a consent prompt, but can only use the application if explicitly assigned.

A user who cannot open a site will not see it in the picker, and a hand-crafted request
against it fails with Graph's own 403.

## 3. The federated identity credential

Not a permission, but the piece that makes the delegated path work without a
secret. The app registration carries a federated identity credential whose
subject is the Function App's managed identity principal id and whose audience is
`api://AzureADTokenExchange`. The app exchanges a managed-identity token for a
client assertion and uses that to sign the on-behalf-of request.

If the Function App is ever recreated, its identity changes and the credential
must be updated. `Update-Collaborate.ps1` detects a mismatched subject and
replaces the credential rather than leaving it to fail confusingly at runtime.

## Mail is not a Graph permission

Collaborate sends from **one shared mailbox**, and that is enforced by Exchange,
not by a Graph app role. The deploy:

1. registers the managed identity in Exchange Online (`New-ServicePrincipal`),
2. creates a management scope that matches only the sender mailbox,
3. assigns the `Application Mail.Send` role to the identity within that scope.

So there is no tenant-wide `Mail.Send`. 

**This is why the sending mailbox is not editable in the portal.** The scope
belongs to Exchange, not to Collaborate, and the app has no rights to grant
itself a second mailbox. The
Configuration tab therefore shows the sender read-only, and
[operations.md](operations.md#the-two-mail-addresses-and-which-one-you-can-change)
gives the command to change it. The **service desk address**, which is editable,
is a recipient.

## What administering the tool requires

| Task | Needs |
|---|---|
| Running the deploy | Owner or Contributor plus User Access Administrator on the subscription |
| Granting the application permissions and the Guest Inviter role | Global Administrator or Privileged Role Administrator |
| Consenting the delegated permissions | Global Administrator or Privileged Role Administrator |
| The Exchange mailbox scoping | Exchange Administrator or Global Administrator|
| Assigning the admin **group** to the Collaborate.Admin role | An Entra ID P1 licence. Without it, assign individual users instead; the deploy falls back to assigning the deploying operator so the portal is never unadministrable |

Anything the deploy could not grant is listed at the end of its output, and
re-running it (or the update) reconciles whatever is still missing.

## Tightening

- Turn off sharing capabilities you do not want in **Configuration**. The portal
  hides them and the API returns 403, so a disabled capability is unreachable
  even by a hand-crafted request. The delegated permissions can then also be
  removed from the app registration.
- Leave inactive-guest cleanup off unless you want it. `AuditLog.Read.All` is
  still worth granting: it is what supplies the last-active column and the
  audit-log fallback when adopting guests that predate the tool. Without it,
  neither works, and nothing else is affected.
- Keep the admin group small and under PIM. Its members can change what every
  employee may do with external identities.
