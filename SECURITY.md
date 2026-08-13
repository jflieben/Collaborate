# Security

Collaborate's managed identity can **invite, disable and delete guest accounts**
across the tenant, and its portal is used by ordinary employees rather than only
administrators. Treat the admin group as **privileged access**: its members can
change what every employee is allowed to do with external identities.

## Trust boundaries

| Boundary | Control |
|---|---|
| Who can sign in | Delegated Entra sign-in (MSAL). The API validates the bearer token itself (RS256 against tenant JWKS, audience, issuer, expiry) **and** refuses guest accounts and foreign tenants, so an invited guest can never open the portal. |
| Who can administer | The `Collaborate.Admin` app role, assigned to a nominated security group. Checked from the token's `roles` claim on every admin call; the API fails closed. |
| Who can invite | Optionally a nominated inviter group, resolved transitively server side. Never trusted from the client. |
| What a user can share | The **user's own delegated token** (on-behalf-of), never the managed identity. Graph enforces the user's real rights on every browse and share call. |
| Runtime credentials | Managed identity only. No secrets, certificates or storage keys at runtime. The on-behalf-of flow uses a federated identity credential that trusts the managed identity, so no client secret exists to leak. |
| Internal portal hosting | A storage account the managed identity has **no** access to, so a runtime compromise cannot rewrite the signed-in page to harvest tokens. |
| Public welcome page hosting | A separate storage account with no authentication, no tokens and no data. The app can rewrite it (so branding stays editable), which is why versioning, soft delete, write logging and a daily hash check are enabled on it. |
| Mail sending | Exchange Online RBAC for Applications scoped to a single sender mailbox. |
| The redirect target on the welcome page | Validated against a host allowlist baked into the page, so it can never become an open redirect. |

## What the tool does to protect you

- **Circuit breaker (storm guard).** Daily caps on blocks, deletes and
  invitations plus a percent-of-guest-population ceiling. A breach pauses all
  processing until an admin reviews and resumes.
- **Simulation mode by default.** A new install performs no destructive action
  until an admin turns simulation off.
- **Grace before deletion.** Expiry blocks sign-in first and deletes only after a
  configurable grace period, so a mistake is recoverable.
- **Defence in depth on every API.** Easy Auth is the platform gate; each
  function independently validates the caller and fails closed.
- **Everything is logged**, including who changed the configuration, with an
  old/new diff.

## What the operator must do

1. **Treat the admin group as privileged.** Use PIM, keep it small.
2. **Start in simulation** and watch the activity log before going live.
3. **Check the safety limits against your tenant size** before enabling automatic cleanup of inactive guests
4. **Review orphaned guests** after the first adoption run: they are the ones
   nobody is accountable for.

## Reporting a vulnerability

Please report security issues privately to the repository owner (jflieben) rather than opening a public issue.
