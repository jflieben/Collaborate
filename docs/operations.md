# Running it

Collaborate is deployed into a tenant and then largely left alone, so everything
here is about what happens in the background.

## What runs when

All times are UTC.

| Job | When | What it does |
|---|---|---|
| `GuestScanner` | 06:30 daily | Adopts (pre-existing) guests it does not track yet, refreshes acceptance and last-active from Entra, sends anything a browser was asked to send and never confirmed, sizes the guest population, closes records for accounts removed elsewhere, and queues everything that is due today |
| `GuestActionProcessor` | On the queue | Carries out one reminder, one end of access or one removal, after checking it is still the right thing to do |
| `RedemptionPoller` | Every 15 minutes | Notices when a guest accepts, and tells their owner |
| `Watchdog` | 08:00 daily | Runs the health checks and emails the service desk if anything is wrong |
| `VersionChecker` | 09:00 Mondays | Checks whether a newer Collaborate has been published |
| `ActivityLogCleanup` | 03:30 Sundays | Trims the activity log and aged records to the retention you set |

The scanner runs before the working day in most of Europe, so reminders land
before people start. The watchdog runs ninety minutes later, so a scanner that
failed this morning is reported this morning rather than tomorrow.

**The scanner decides and never acts.** Everything it finds becomes queue
messages

## The two mail addresses, and which one you can change

One is a setting
and the other cannot be.

| | What it is | Changing it |
|---|---|---|
| **Shared mailbox** (`CB_SENDER_UPN`) | Sends everything nobody is present for (reminders, expiry, digests), and anything a browser could not send | **Re-run the deployment.** Not editable in the portal |
| **Service desk email** | Where health warnings and the unowned-guest digest are sent **to**, and the `{{servicedeskEmail}}` token in templates | Configuration tab, takes effect on the next save |

The service desk address is only a **recipient**. Changing it is safe: it
redirects who gets told about problems.

The sending mailbox is what the managed identity is authorised for through an Exchange Online management scope (to avoid using Mail.Send) created at
deploy time (see [permissions.md](permissions.md)), so pointing the app at a
different address without also moving that scope would fail since the MI cannot modify anything in Exchange.

**To change the sending mailbox**, re-run the deployment, it is idempotent:

```powershell
iex (irm https://raw.githubusercontent.com/jflieben/Collaborate/main/install.ps1)
```

or, from a local clone:

```powershell
./deploy/Deploy-Collaborate.ps1 -SubscriptionId <sub> -Location westeurope `
    -SenderUpn newsender@contoso.com -ServicedeskEmail servicedesk@contoso.com `
    -AdminGroupName "Collaborate Admins"
```

The deploy is idempotent and safe to run against an existing install: it
reconciles rather than recreates, leaves every setting you have edited in the
portal alone, and re-does the Exchange scoping for the new mailbox. You need to be an
**Exchange Administrator** or **Global Administrator** for that step.

## Keeping the records honest

Alongside the lifecycle, each scan re-reads three facts from Entra for every
tracked collaborator: whether the invitation was ever accepted, when they last
signed in successfully, and what they are currently called. These are facts, not
decisions -- nothing here blocks, deletes or mails anybody -- so it runs in
simulation mode too. **Diagnostics -> Refresh from Entra** does the same thing
on demand.

Sign-in times are a separate Graph sweep from the guest list, deliberately.
`signInActivity` needs an **Entra ID P1 or P2** licence, and asking for it on a
tenant without one fails the entire query. Folded into the main sweep, a missing
licence would cost the guest list, the population count the storm guard sizes
itself against, and the ability to notice a guest deleted elsewhere: a licence
check taking out the nightly scan. Kept separate, it fails alone, the portal
explains why the column is missing, and everything else carries on.

The two facts also cover for each other. A guest whose `externalUserState` Entra
no longer records but who signed in last Tuesday has plainly accepted, and is
reported as accepted.

## Adoption: the guests that were already there

Most tenants install this with hundreds of external accounts nobody can account
for. Adoption gives each an owner and an end date. It looks in this order:

1. **Entra's sponsors field**, which is the original inviter (since ~2026) and which
   Collaborate itself writes on every invitation;
2. **the directory audit log**, which records who invited whom but only covers
   the last 7 days (free) or 30 (P1/P2), so it helps for recent guests only;
3. **nobody**, which is a real answer. Those land in the orphan partition, appear
   in the admin console under "only those nobody owns", and go to the service
   desk in a digest.

**Adoption never blocks or deletes anybody.** It writes an owner and a date, and
the ordinary lifecycle takes it from there.

The date is counted **from today**, never from when the account was created.
A date already sitting on the account is respected.

A first pass is capped at 500 guests, so a large tenant is adopted over several
nights and an operator can watch the first batch before the rest follow.

## Inactive guests

Off by default. It deals with access
that was never used at all, which is the more common kind of sprawl: somebody
invited for a project that never started, four years ago.

- Needs **Entra ID P1 or P2** for sign-in data.
- **Missing sign-in data means no action.** A tenant without the licence must not
  have its guests treated as never having signed in.
- Never signed in falls back to the invitation date, so a guest invited yesterday
  is never idle.
- The threshold has a 30-day floor: anything shorter acts on people who are
  simply on leave.
- The strongest setting still only **ends access**, through the ordinary grace
  period. Nothing here deletes in one step.
- The owner is warned once per guest unless you ask for repeats.

## The health check

The watchdog exists because nothing in Azure will tell you a timer has stopped
firing.

It checks: every scheduled job has run recently and succeeded; nothing is stuck
in the poison queue; the storm guard has not paused everything; the public
welcome page still matches what the app published; mail works; and the
configuration is not silently preventing the tool from doing its job (no service
desk address, simulation still on, setup never finished).

**It only emails when something is wrong.** The alert is sent **even in
simulation mode**

The same checks appear on the Diagnostics tab for visual confirmation

## Retention

The activity log is an audit trail, so it is trimmed on the schedule you set, default 365 days.

Records for guests that were removed age out on the same schedule.

## Updates

`VersionChecker` reads the published `VERSION` file, records the answer, and
shows administrators a banner. It emails the service desk once per version.

**Collaborate never updates itself.**. Re-run the deployment, or
`Update-Collaborate.ps1`, when you are ready.

## When something goes wrong

| Symptom | Where to look |
|---|---|
| Nothing is being reminded or removed | Diagnostics: is the storm guard paused, or is simulation still on? |
| A guest was not acted on | Activity, filtered to them. The processor logs when it skipped work because the situation had changed |
| Work is stuck | Diagnostics shows the poison queue count; Application Insights shows why each message failed |
| Guests have no owner | Diagnostics counts them; the admin console filters to them; select and assign in bulk |
| The public page was altered | The watchdog reports drift. `Update-Collaborate.ps1` re-renders it from source |

Every action the tool takes is in the activity log with who caused it, and every
simulated action is marked as such.
