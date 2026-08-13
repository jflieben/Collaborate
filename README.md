# Collaborate

User friendly Self-service guest (B2B) collaboration for Entra tenants.

When the Entra portal is locked down or if you just want a friendlier, branded experience. 

An employee who just wants to share a file with someone outside the company should
not be able to directly invite them, so the request goes to the service desk. And once a guest does exist, nothing records **why** they exist, **who** owns them, or **when** their access should end, so guest accounts pile up.

Collaborate fixes both halves:

- **Employees invite and manage their own external collaborators** from a small
  branded portal, and can go straight from "I need to share this file" to a guest
  who has access to exactly that file, folder or Team.
- **Every guest has an owner, a reason and an expiry date.** The tool reminds the
  owner before expiry, blocks sign-in when it lapses, deletes after a grace
  period, and can clean up guests who never sign in at all.
- **IT has centralized overview and management** dashboard, overarching view, branding, central mailbox etc.

It authenticates with a **managed identity** only. No client secrets, no
certificates, not even for the on-behalf-of flow.

## Security brief

The entire solution is open source, and you host it in your own Azure environment.
It is automatically locked down, you configure IP whitelisting and/or network integration if desired.

## How access is decided

| Operation | Runs as | Why |
|---|---|---|
| Invite, expire, block, delete a guest | The managed identity | Employees cannot do this themselves in a locked-down tenant; that is the whole point |
| Browse SharePoint/OneDrive, share a file or folder, add someone to a Team | **The signed-in user**, via on-behalf-of | So nobody can ever share something they do not already have rights to |

Sending mail uses **Exchange Online RBAC for Applications** scoped to a single
shared mailbox, so there is no tenant-wide `Mail.Send`.

## Quick start

Prerequisites: **Global Administrator or Privileged Role Administrator** (to grant
permissions to your managed identity and configure SSO), **Exchange Administrator** (to scope the
sender mailbox), and an Entra security group for the Collaborate administrators.

In [Azure Cloud Shell](https://shell.azure.com), PowerShell:

```powershell
iex (irm https://raw.githubusercontent.com/jflieben/Collaborate/main/install.ps1)
```

Or from a local clone:

```powershell
./deploy/Deploy-Collaborate.ps1 `
    -SubscriptionId   <your-subscription-id> `
    -Location         westeurope `
    -SenderUpn        noreply@contoso.com `
    -ServicedeskEmail servicedesk@contoso.com `
    -AdminGroupName   "Collaborate Admins" `
    -AllowedIp        203.0.113.0/24
```

Then open the portal. The setup wizard **verifies single sign-on end to end**
before it lets you finish, and the tool starts in simulation mode: it logs what
it would do and changes nothing until you turn that off.

## Everything is editable in the portal

Branding (company name, two colours, logo), every email, the wording of the page
guests land on, expiry policy, who may invite, which sharing capabilities exist,
and the safety limits. The deploy only seeds initial values. Nothing is frozen at
install time, and administering the tool never means opening the Azure portal or
blob storage.

**One exception: the mailbox mail is sent *from*.**
Permission to send is scoped to that single mailbox in Exchange Online, 
changing the address in the portal would not update the limited send scope.
To change it, re-run the deploy (the input var is -SenderUpn). Installation is
idempotent, leaves everything you have edited in the portal alone, it just updates.
See [operations.md](docs/operations.md#the-two-mail-addresses-and-which-one-you-can-change).

The **service desk email**, which *is* editable, is only a recipient: where
health warnings and the unowned-guest digest are sent to. This can of course be the same address.

## Documentation

- [Architecture](docs/architecture.md) - the two identities, the lifecycle, storage layout, the public page
- [Operations](docs/operations.md) - what runs when, adoption, inactive guests, the health check, retention
- [Sharing](docs/sharing.md) - why the grant runs as the user, and the order things happen in
- [Permissions](docs/permissions.md) - exactly what is granted, to whom, and why
- [The portal](docs/portal.md) - the setup wizard's SSO test, the two audiences, the admin tabs
- [Security](SECURITY.md) - trust boundaries and the deliberate trade-offs
- [CHANGELOG](CHANGELOG.md) for what each version added
- [Operations](docs/operations.md) for what runs on a schedule.

## Licence

See [LICENSE](LICENSE). Commercial (re)use requires prior written consent;
otherwise free to use and modify with attribution.

Built by **[JSolve B.V.](https://jsolve.nl)**.