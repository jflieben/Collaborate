Collaborate is meant to make working with external users easier in Entra environments, specifically for the end users of the company owning the tenant.

When the entra portal is locked down and b2b integration is enabled, sharing with a new guest from Sharepoint becomes tricky.

Managing the lifecycle of a guest user is also not easy in Entra as it lacks cleanup, recording invitation reasons, maintaining an internal owner etc.

This should be a lightweight tool that allows internal users to view which guest users they've invited, their current status, to cancel or renew their access (guest users should have an expiration date that it keeps track of on an extensionAttribute). 

The tool should remind guest owners of impending expiration, admins should be able to configure the days in advance (and steps if multiple reminders). 

Optionally, the tool should also allow automated cleanup (with configurable notifications) of inactive guests (based on last successfull signin, or if none, creation date).

All emails should be customizable by the admin. 
The tool should use managed identity to administer guest objects in Entra and to send emails. Emails should not use Mail.Send, but the MI should be registered in exchange during setup and have scoped access to send from a specific shared mailbox only.

Guests should, after signup, not receive the default Microsoft mail, but our customized mail, and the redirect url should also be customizable. I think it would be ideal if we have a logic app that 'answers' the redirect URL, so we can keep that part 'externally accessible' at no risk, while the app stays internal only (ip whitelisting as default, internal routing with private endpoints etc optional)

The tool should have full SSO with Entra, and require this, no other login method should be allowed after the setup wizard is done (which configures SSO, it should also TEST sso before completing).

Inspirational tool that uses similar technologies / authentication: C:\Git\M365AutoRevocate