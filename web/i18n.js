/* Collaborate translations.
 *
 * English is the source language and doubles as the key: t("Sign in") returns
 * the Dutch when Dutch is on, and the key itself otherwise. A missing entry is
 * an English sentence rather than a blank or a raw identifier, which is the
 * failure mode that matters when somebody adds a string and forgets this file.
 *
 * The static shell is translated by sweeping the DOM, so index.html carries no
 * markup for it. An element with no element children is matched on its text; one
 * with only inline children (em, strong, code, a, span, br) is matched on its
 * innerHTML, so a sentence with emphasis in it stays one string for the
 * translator instead of three fragments.
 */
(function (global) {
  "use strict";

  var NL = {
    /* --- shell --- */
    "Invite and manage the people you work with outside the company.": "Nodig mensen buiten het bedrijf uit en beheer ze.",
    "Sign in": "Aanmelden",
    "You will be signed in with your work account.": "U wordt aangemeld met uw werkaccount.",
    "Sign out": "Afmelden",
    "Home": "Start",
    "Collaborators": "Externe gasten",
    "Configuration": "Instellingen",
    "Branding": "Huisstijl",
    "Emails": "E-mails",
    "Activity": "Activiteit",
    "Diagnostics": "Diagnose",
    "Language": "Taal",

    /* --- home --- */
    "What would you like to do?": "Wat wilt u doen?",
    "Everything you set up here is recorded against your name, with an end date, so nothing is left open forever.": "Alles wat u hier regelt staat op uw naam, met een einddatum, zodat niets eindeloos openblijft.",
    "Collaborate is waking up. This takes a few seconds the first time somebody opens it after a quiet period.": "Collaborate wordt opgestart. De eerste keer na een rustige periode duurt dat een paar seconden.",
    "<span class=\"spinner\"></span> Getting things ready...": "<span class=\"spinner\"></span> Bezig met voorbereiden...",
    "Sharing: <strong id=\"shChosen\"></strong>": "Delen: <strong id=\"shChosen\"></strong>",
    "Allowed right now: <span id=\"wcAllowed\" class=\"muted\"></span>": "Nu toegestaan: <span id=\"wcAllowed\" class=\"muted\"></span>",
    "Public page: <a id=\"wcLink\" href=\"#\" target=\"_blank\" rel=\"noopener\">not published yet</a>": "Openbare pagina: <a id=\"wcLink\" href=\"#\" target=\"_blank\" rel=\"noopener\">nog niet gepubliceerd</a>",
    "Click a token to insert it. Use <code>class=\"cb-button\"</code> on a link to make it a branded button.": "Klik op een token om het in te voegen. Gebruik <code>class=\"cb-button\"</code> op een link om er een knop in de huisstijl van te maken.",
    "empty = any domain": "leeg = elk domein",
    "See your collaborators": "Bekijk uw externe gasten",
    "Dismiss": "Sluiten",
    "Manage external collaborators": "Externe gasten beheren",
    "See who you have invited, and invite somebody new.": "Bekijk wie u heeft uitgenodigd en nodig iemand nieuw uit.",
    "Pick something from SharePoint or your OneDrive and give an outsider access to just that.": "Kies iets uit SharePoint of uw OneDrive en geef een externe toegang tot alleen dat.",
    "Add someone to a Team": "Iemand aan een Team toevoegen",
    "Add an external person to a Team you own, if that Team allows guests.": "Voeg een externe toe aan een Team dat u bezit, als dat Team gasten toestaat.",
    "An administrator has switched file and folder sharing off.": "Een beheerder heeft het delen van bestanden en mappen uitgeschakeld.",
    "An administrator has switched Teams sharing off.": "Een beheerder heeft het toevoegen aan Teams uitgeschakeld.",
    "Share a file": "Een bestand delen",
    "Share a folder": "Een map delen",
    "Share a file or folder": "Een bestand of map delen",

    /* --- collaborator list --- */
    "Your external collaborators": "Uw externe gasten",
    "Invite someone new": "Iemand nieuw uitnodigen",
    "Everybody here is recorded against your name, with a reason and an end date, so nothing stays open forever.": "Iedereen hier staat op uw naam, met een reden en een einddatum, zodat niets eindeloos openblijft.",
    "Every external account in the tenant, with the colleague who is accountable for each one.": "Elk extern account in de tenant, met de collega die er verantwoordelijk voor is.",
    "make this colleague responsible": "maak deze collega verantwoordelijk",
    "Assign": "Toewijzen",
    "Clear": "Wissen",
    "Nobody yet. Use <strong>Invite someone new</strong> to get started.": "Nog niemand. Gebruik <strong>Iemand nieuw uitnodigen</strong> om te beginnen.",
    "Refresh": "Vernieuwen",
    "Show every external account, not just mine": "Toon elk extern account, niet alleen die van mij",
    "only those nobody owns": "alleen die zonder eigenaar",
    "Who": "Wie",
    "Status": "Status",
    "Last active": "Laatst actief",
    "Why": "Waarom",
    "Owner": "Eigenaar",
    "Open": "Openen",
    "Never": "Nooit",
    "today": "vandaag",
    "yesterday": "gisteren",
    "just now": "zojuist",
    "nobody": "niemand",
    "unowned": "geen eigenaar",
    "Nothing matches that filter.": "Niets voldoet aan dit filter.",
    "Clear the filters": "Filters wissen",
    "Contains": "Bevat",
    "Apply": "Toepassen",
    "name, address or domain": "naam, adres of domein",
    "Select everything shown": "Alles selecteren wat zichtbaar is",
    "Filter": "Filteren",
    "Sort by {name}": "Sorteren op {name}",
    "Filter by {name}": "Filteren op {name}",
    "{count} collaborator selected": "{count} externe gast geselecteerd",
    "{count} collaborators selected": "{count} externe gasten geselecteerd",

    /* --- states --- */
    "pending": "wacht op acceptatie",
    "active": "actief",
    "expiring": "loopt bijna af",
    "expired": "verlopen",
    "blocked": "geblokkeerd",
    "deleted": "verwijderd",
    "waiting to accept": "wacht op acceptatie",
    "switched off": "uitgezet",
    "ended": "beeindigd",
    "ending soon": "loopt bijna af",
    "removed": "verwijderd",
    "any": "alle",

    /* --- status sentences, built here so they translate --- */
    "Invited, waiting for them to accept": "Uitgenodigd, wacht op acceptatie",
    "Active until {date}": "Actief tot {date}",
    "Ends today ({date})": "Loopt vandaag af ({date})",
    "Ends tomorrow ({date})": "Loopt morgen af ({date})",
    "Ends in {days} days ({date})": "Loopt over {days} dagen af ({date})",
    "Ended on {date}": "Beeindigd op {date}",
    "Access switched off (ended {date})": "Toegang uitgezet (beeindigd {date})",
    "Removed": "Verwijderd",
    "Accepted {date}": "Geaccepteerd op {date}",
    "Invited {date}, not accepted yet": "Uitgenodigd op {date}, nog niet geaccepteerd",
    "Not accepted yet": "Nog niet geaccepteerd",
    "Entra does not record whether they accepted": "Entra legt niet vast of ze hebben geaccepteerd",

    /* --- actions --- */
    "Extend": "Verlengen",
    "Restore access": "Toegang herstellen",
    "Bring them back": "Terughalen",
    "End access now": "Toegang nu beeindigen",
    "Hand over": "Overdragen",
    "Take this on": "Zelf overnemen",
    "Send the invitation again": "Uitnodiging opnieuw versturen",
    "Extend access": "Toegang verlengen",
    "Hand over to a colleague": "Overdragen aan een collega",
    "Make somebody responsible": "Iemand verantwoordelijk maken",
    "For how many days from today": "Voor hoeveel dagen vanaf vandaag",
    "Update the reason (optional)": "Reden bijwerken (optioneel)",
    "Why are you ending it? (optional)": "Waarom beeindigt u dit? (optioneel)",
    "Anything they should know? (optional)": "Nog iets dat ze moeten weten? (optioneel)",
    "Which colleague?": "Welke collega?",
    "Start typing a name": "Begin een naam te typen",

    /* --- invite --- */
    "Who do you want to work with?": "Met wie wilt u samenwerken?",
    "Search first. If they already work with us, we will point you at the colleague who looks after them rather than setting the same person up twice.": "Zoek eerst. Werkt diegene al met ons samen, dan wijzen we u de collega aan die hem of haar beheert, in plaats van dezelfde persoon twee keer aan te maken.",
    "Name or email address": "Naam of e-mailadres",
    "Start typing to see the people we already work with. Enter a full email address to invite somebody new.": "Begin met typen om te zien met wie we al samenwerken. Vul een volledig e-mailadres in om iemand nieuw uit te nodigen.",
    "Continue": "Doorgaan",
    "Cancel": "Annuleren",
    "Their name": "Hun naam",
    "Why do you need to work with them?": "Waarom moet u met deze persoon samenwerken?",
    "For how many days": "Voor hoeveel dagen",
    "They will get an email from us, not the default Microsoft one, and their access ends automatically unless you extend it.": "Ze krijgen een e-mail van ons, niet de standaardmail van Microsoft, en hun toegang stopt automatisch tenzij u die verlengt.",
    "Send the invitation": "Uitnodiging versturen",
    "Why do you work with them?": "Waarom werkt u met deze persoon samen?",
    "Keep their access for how many days": "Hoeveel dagen moet de toegang gelden",
    "Take them on": "Deze overnemen",
    "Email them directly": "Rechtstreeks mailen",
    "Back": "Terug",
    "(optional)": "(optioneel)",

    /* --- share --- */
    "Choose what to share": "Kies wat u wilt delen",
    "You will only see what you can already open yourself.": "U ziet alleen wat u zelf al kunt openen.",
    "Only folders can be shared here; open one to look inside.": "Hier kunnen alleen mappen worden gedeeld; open er een om erin te kijken.",
    "Search": "Zoeken",
    "Type at least two letters": "Typ minimaal twee letters",
    "Who should get access?": "Wie moet toegang krijgen?",
    "Check and share": "Controleren en delen",
    "What may they do?": "Wat mogen ze doen?",
    "View only": "Alleen bekijken",
    "View and edit": "Bekijken en bewerken",
    "Add a note to the email (optional)": "Voeg een bericht toe aan de e-mail (optioneel)",
    "Share": "Delen",
    "Not available yet": "Nog niet beschikbaar",
    "Recent": "Recent",
    "My files": "Mijn bestanden",
    "Sites": "Sites",
    "Choose a Team": "Kies een Team",
    "Choose a file": "Kies een bestand",
    "Choose a folder": "Kies een map",
    "Choose a file or folder": "Kies een bestand of map",
    "Only Teams you own, and only those that accept guests.": "Alleen Teams die u bezit, en alleen die gasten toestaan.",
    "Loading your Teams...": "Uw Teams worden geladen...",
    "Loading...": "Bezig met laden...",
    "Nothing here.": "Hier staat niets.",
    "Share this folder": "Deze map delen",
    "Share this file": "Dit bestand delen",
    "not available": "niet beschikbaar",
    "Nobody found.": "Niemand gevonden.",
    "Searching the directory...": "Bezig met zoeken in de adreslijst...",
    "Keep typing, at least two letters.": "Typ verder, minimaal twee letters.",
    "no external sharing": "extern delen uit",
    "Nothing here can be shared outside the company": "Hier kan niets buiten het bedrijf worden gedeeld",
    "Choose somewhere else": "Kies iets anders",
    "This site does not allow external sharing": "Deze site staat extern delen niet toe",
    "Back to the site list": "Terug naar de lijst met sites",
    "Open in a new tab": "Openen in een nieuw tabblad",
    "you": "u",

    /* --- one collaborator --- */
    "Close": "Sluiten",
    "What you can do": "Wat u kunt doen",
    "Why they are here": "Waarom deze persoon hier staat",
    "The details": "De gegevens",
    "What they can reach": "Waar ze bij kunnen",
    "Access until": "Toegang tot",
    "Ends": "Loopt af",
    "Days left": "Dagen resterend",
    "Accepted": "Geaccepteerd",
    "Invited": "Uitgenodigd",
    "Extended": "Verlengd",
    "Never signed in": "Nooit aangemeld",
    "Looking...": "Bezig met zoeken...",
    "Share something now": "Nu iets delen",
    "Share something else": "Nog iets delen",
    "Unshare": "Delen stoppen",
    "Nothing has been shared with them through Collaborate. Anything shared with them directly in SharePoint or Teams does not appear here.": "Er is via Collaborate niets met deze persoon gedeeld. Wat rechtstreeks in SharePoint of Teams is gedeeld, staat hier niet bij.",
    "Items a colleague shared are not named. Ask whoever shared it.": "Wat een collega heeft gedeeld, wordt niet bij naam genoemd. Vraag het aan degene die het deelde.",
    "What Collaborate granted, newest first, up to the last 50. Access given to them directly through SharePoint or Teams is not listed.": "Wat Collaborate heeft verleend, nieuwste eerst, tot de laatste 50. Toegang die rechtstreeks via SharePoint of Teams is gegeven, staat er niet bij.",
    "Pick the colleague from the list first.": "Kies eerst de collega uit de lijst.",
    "Working...": "Bezig...",
    "File": "Bestand",
    "Folder": "Map",
    "Team": "Team",
    "Can view": "Mag bekijken",
    "Can edit": "Mag bewerken",
    "Member": "Lid",
    "shared {when}": "gedeeld {when}",

    /* --- configuration --- */
    "Save configuration": "Instellingen opslaan",
    "Save and republish": "Opslaan en opnieuw publiceren",
    "Save emails": "E-mails opslaan",
    "Saving...": "Bezig met opslaan...",
    "Saved.": "Opgeslagen.",
    "Nothing to save: that is already how it is set.": "Niets op te slaan: zo staat het al ingesteld.",
    "Copied.": "Gekopieerd.",
    "Technical details": "Technische details",
    "Copy for support": "Kopieren voor support",
    "Something went wrong.": "Er is iets misgegaan.",
    "Default language": "Standaardtaal",
    "The language everybody sees until they choose their own.": "De taal die iedereen ziet totdat ze zelf een keuze maken.",

    /* --- configuration: expiry --- */
    "How long access lasts": "Hoelang toegang geldt",
    "Default length (days)": "Standaardduur (dagen)",
    "Pre-filled when somebody invites a guest.": "Vooraf ingevuld wanneer iemand een gast uitnodigt.",
    "Longest allowed (days)": "Maximaal toegestaan (dagen)",
    "Nobody can choose a date beyond this.": "Niemand kan een datum verder dan dit kiezen.",
    "An extension adds (days)": "Een verlenging voegt toe (dagen)",
    "Grace period before deletion (days)": "Respijtperiode voor verwijdering (dagen)",
    "After expiry, sign-in is blocked first. The account is only deleted once this passes, so a mistake is recoverable.": "Na afloop wordt aanmelden eerst geblokkeerd. Het account wordt pas verwijderd als deze periode voorbij is, zodat een vergissing te herstellen is.",
    "Remind the owner this many days before (comma separated)": "Herinner de eigenaar zoveel dagen vooraf (komma gescheiden)",
    "Up to five reminders.": "Maximaal vijf herinneringen.",
    "Store the expiry date on": "Bewaar de einddatum op",
    "Written on the guest object itself, so it survives this tool and can drive dynamic groups or Conditional Access. It must not be in use for anything else.": "Wordt op het gastaccount zelf gezet, zodat het deze tool overleeft en dynamische groepen of Conditional Access kan aansturen. Het veld mag nergens anders voor in gebruik zijn.",
    "Owners may extend their own guests without asking an administrator": "Eigenaren mogen hun eigen gasten verlengen zonder een beheerder te vragen",

    /* --- configuration: inviting --- */
    "Inviting": "Uitnodigen",
    "Only this group may invite (object id)": "Alleen deze groep mag uitnodigen (object-id)",
    "leave empty to let everybody invite": "laat leeg om iedereen te laten uitnodigen",
    "Leave empty and any internal member can invite. Everybody can always see and manage the guests they already own.": "Laat leeg en elke interne medewerker mag uitnodigen. Iedereen kan altijd de gasten zien en beheren die al van hen zijn.",
    "Group name (shown to people who are refused)": "Groepsnaam (getoond aan wie wordt geweigerd)",
    "Domains that may be invited (comma separated)": "Domeinen die mogen worden uitgenodigd (komma gescheiden)",
    "Domains that may never be invited": "Domeinen die nooit mogen worden uitgenodigd",
    "Who can be found when sharing": "Wie er te vinden is bij delen",
    "Every external person in the tenant (with their owner shown)": "Elke externe in de tenant (met hun eigenaar erbij)",
    "Only the ones I own": "Alleen die van mij",
    "Showing everybody is what stops the same person being invited five times by five colleagues.": "Iedereen tonen voorkomt dat dezelfde persoon vijf keer door vijf collega's wordt uitgenodigd.",
    "Require a reason for every invitation": "Vraag bij elke uitnodiging om een reden",
    "Also record the inviter as the guest's sponsor in Entra": "Leg de uitnodiger ook vast als sponsor van de gast in Entra",

    /* --- configuration: sharing --- */
    "Sharing": "Delen",
    "Sharing always runs as the signed-in user, so nobody can share something they do not already have access to. Switching a capability off hides it and refuses it at the API.": "Delen gebeurt altijd namens de aangemelde gebruiker, dus niemand kan iets delen waar hij zelf geen toegang toe heeft. Een uitgeschakelde mogelijkheid wordt verborgen en door de API geweigerd.",
    "Allow sharing files": "Bestanden delen toestaan",
    "Allow sharing folders": "Mappen delen toestaan",
    "Allow adding guests to Teams": "Gasten aan Teams toevoegen toestaan",
    "Allow granting edit access (not just view)": "Bewerkrechten toestaan (niet alleen lezen)",

    /* --- configuration: adoption --- */
    "Guests that were already here": "Gasten die er al waren",
    "Most tenants already have external accounts nobody can account for. Adoption gives each one an owner and an end date. It never blocks or removes anybody: the ordinary reminders and grace period take it from there.": "De meeste tenants hebben al externe accounts waar niemand verantwoording over kan afleggen. Adoptie geeft ze elk een eigenaar en een einddatum. Er wordt nooit iemand geblokkeerd of verwijderd: de gewone herinneringen en de respijtperiode nemen het daarna over.",
    "Take on guests that Collaborate did not create": "Gasten overnemen die Collaborate niet heeft aangemaakt",
    "Give them this long, from today (days)": "Geef ze zoveel tijd, vanaf vandaag (dagen)",
    "Counted from today, never from when the account was created, so adopting an old guest does not expire them the same afternoon. A date already on the account is respected instead.": "Geteld vanaf vandaag, nooit vanaf het aanmaken van het account, zodat een oude gast niet dezelfde middag verloopt. Een datum die al op het account staat wordt gerespecteerd.",
    "Look for the owner in Entra's sponsors field": "Zoek de eigenaar in het sponsorveld van Entra",
    "Also look in the invitation audit log (only covers the last 7 to 30 days)": "Kijk ook in het auditlogboek met uitnodigingen (dekt alleen de laatste 7 tot 30 dagen)",

    /* --- configuration: inactivity --- */
    "Cleaning up inactive guests": "Opruimen van inactieve gasten",
    "Needs Entra ID P1 or P2 for sign-in data. Where that data is missing, nothing is done: a missing licence must never be read as evidence that somebody never signed in.": "Vereist Entra ID P1 of P2 voor aanmeldgegevens. Ontbreken die gegevens, dan gebeurt er niets: een ontbrekende licentie mag nooit worden gelezen als bewijs dat iemand zich nooit heeft aangemeld.",
    "Act on guests who never sign in": "Actie ondernemen bij gasten die zich nooit aanmelden",
    "Consider inactive after (days)": "Beschouw als inactief na (dagen)",
    "Measured from the last successful sign-in, or from the invitation date if they never signed in.": "Gemeten vanaf de laatste geslaagde aanmelding, of vanaf de uitnodigingsdatum als ze zich nooit hebben aangemeld.",
    "Then": "Dan",
    "Tell the owner only": "Alleen de eigenaar informeren",
    "End their access (removed after the grace period)": "Hun toegang beeindigen (verwijderd na de respijtperiode)",
    "Even the strongest option goes through the grace period, so it is recoverable.": "Ook de zwaarste optie gaat door de respijtperiode heen, dus het is te herstellen.",
    "Only warn the owner once per guest": "Waarschuw de eigenaar maar een keer per gast",

    /* --- configuration: safety --- */
    "Safety limits": "Veiligheidslimieten",
    "If a run would exceed a limit, everything pauses and waits for an administrator, rather than acting on hundreds of people because of one mistake.": "Zou een run een limiet overschrijden, dan pauzeert alles en wacht op een beheerder, in plaats van door een vergissing honderden mensen te raken.",
    "Keep the safety limits on (recommended)": "Houd de veiligheidslimieten aan (aanbevolen)",
    "Invitations per day (whole tenant)": "Uitnodigingen per dag (hele tenant)",
    "Invitations per person per day": "Uitnodigingen per persoon per dag",
    "Sign-in blocks per day": "Aanmeldblokkades per dag",
    "Deletions per day": "Verwijderingen per dag",
    "Never touch more than this % of guests in a day": "Raak nooit meer dan dit % gasten op een dag aan",

    /* --- configuration: general --- */
    "General": "Algemeen",
    "Simulation mode": "Simulatiemodus",
    "On: log everything, change nothing, send nothing": "Aan: alles loggen, niets wijzigen, niets versturen",
    "Off: perform real actions": "Uit: echte acties uitvoeren",
    "Keep this on until you have watched the activity log for a cycle or two.": "Laat dit aan staan tot u het activiteitenlogboek een cyclus of twee heeft bekeken.",
    "Service desk email (recipient)": "E-mailadres servicedesk (ontvanger)",
    "Where health warnings and the unowned-guest digest are sent <em>to</em>. This is not the address they are sent <em>from</em>; changing it is safe and takes effect on the next save.": "Waar gezondheidswaarschuwingen en het overzicht van gasten zonder eigenaar naartoe <em>gaan</em>. Dit is niet het adres waar ze <em>vandaan</em> komen; dit wijzigen is veilig en geldt vanaf de volgende keer opslaan.",
    "Shared mailbox": "Gedeelde postbus",
    "Keep the activity log (days)": "Bewaar het activiteitenlogboek (dagen)",
    "Tell the owner when their guest accepts": "Informeer de eigenaar wanneer hun gast accepteert",
    "Email the service desk about guests nobody owns": "Mail de servicedesk over gasten zonder eigenaar",
    "Who administers this, and where": "Wie dit beheert, en waar",
    "Managed in Entra, not here. Shown so you do not have to go looking for it.": "Beheerd in Entra, niet hier. Hier getoond zodat u er niet naar hoeft te zoeken.",
    "Enterprise application": "Bedrijfstoepassing",
    "Application (client) id": "Toepassings-id (client)",

    /* --- branding --- */
    "Applies to this portal, to every email, and to the public page your guests land on after accepting. Saving updates all three.": "Geldt voor dit portaal, voor elke e-mail en voor de openbare pagina waar uw gasten na acceptatie op uitkomen. Opslaan werkt alle drie bij.",
    "Company name": "Bedrijfsnaam",
    "Portal title": "Titel van het portaal",
    "Portal subtitle": "Ondertitel van het portaal",
    "Main colour": "Hoofdkleur",
    "Header bands, in the portal and in email.": "Kopbalken, in het portaal en in e-mail.",
    "Accent colour": "Accentkleur",
    "Buttons and highlights.": "Knoppen en accenten.",
    "Logo": "Logo",
    "Remove": "Verwijderen",
    "PNG or JPEG, up to 512 KB. Emails embed it, so it shows even when a mail client blocks remote images.": "PNG of JPEG, maximaal 512 KB. E-mails nemen het bestand mee, zodat het ook zichtbaar is als een mailprogramma externe afbeeldingen blokkeert.",
    "Preview only. This is uploaded when you save.": "Alleen een voorbeeld. Dit wordt geupload zodra u opslaat.",
    "The logo will be removed when you save.": "Het logo wordt verwijderd zodra u opslaat.",
    "The page guests land on": "De pagina waar gasten op uitkomen",
    "External people never reach this portal. After they accept an invitation they land on a small public page, which Collaborate republishes whenever you save.": "Externen komen nooit in dit portaal. Nadat ze een uitnodiging accepteren komen ze op een kleine openbare pagina, die Collaborate opnieuw publiceert zodra u opslaat.",
    "Headline": "Kop",
    "Button label": "Tekst op de knop",
    "Message": "Bericht",
    "Extra places a guest may be sent (one per line)": "Extra plekken waar een gast heen mag worden gestuurd (een per regel)",
    "Your SharePoint, OneDrive and Teams addresses are always allowed. Anything not on this list is ignored by the page, which is what stops it being used as an open redirect.": "Uw SharePoint-, OneDrive- en Teams-adressen zijn altijd toegestaan. Alles wat niet op deze lijst staat wordt door de pagina genegeerd, en dat voorkomt dat de pagina als open redirect wordt misbruikt.",
    "Send the guest straight on after a short pause, instead of showing a button": "Stuur de gast na een korte pauze meteen door, in plaats van een knop te tonen",
    "not published yet": "nog niet gepubliceerd",

    /* --- emails --- */
    "Every message Collaborate can send. Edit the wording, see it rendered as you type, and send yourself a real test.": "Elk bericht dat Collaborate kan versturen. Pas de tekst aan, zie hem meteen opgemaakt, en stuur uzelf een echte test.",
    "Send this message": "Dit bericht versturen",
    "Subject": "Onderwerp",
    "Body": "Inhoud",
    "Wrap in the branded header and footer": "In de huisstijl-kop en -voet plaatsen",
    "Send a test to me": "Stuur mij een test",
    "Reset this message to default": "Dit bericht terugzetten naar de standaard",
    "Email preview": "Voorbeeld van de e-mail",

    /* --- diagnostics --- */
    "Everything here also runs on a schedule. These are for when you have just changed a setting and would rather not wait until tomorrow to see whether it worked.": "Alles hier draait ook volgens een schema. Deze knoppen zijn er voor als u net een instelling heeft aangepast en niet tot morgen wilt wachten om te zien of het werkt.",
    "Refresh from Entra (acceptance and last active)": "Vernieuwen vanuit Entra (acceptatie en laatst actief)",
    "Adopt guests we do not track yet": "Gasten overnemen die we nog niet volgen",
    "Send the unowned digest": "Overzicht zonder eigenaar versturen",
    "Run the health check": "Gezondheidscontrole uitvoeren",
    "Check for a newer version": "Controleren op een nieuwere versie",

    "Health": "Gezondheid",
    "Run something now": "Nu iets uitvoeren",
    "Background jobs": "Achtergrondtaken",
    "Job": "Taak",
    "Last run": "Laatste keer",
    "Result": "Resultaat",
    "Took": "Duur",
    "Last error": "Laatste fout",
    "No background job has run yet.": "Er is nog geen achtergrondtaak uitgevoerd.",
    "Next": "Volgende",
    "When": "Wanneer",
    "What": "Wat",
    "Details": "Details",
    "Load more": "Meer laden",
    "Show everything, not just mine": "Toon alles, niet alleen wat van mij is",
    "working": "werkt",
    "problem": "probleem",
    "Never run": "Nooit uitgevoerd",
    "ok": "ok",
    "error": "fout",

    /* --- diagnostics cards --- */
    "Mail": "E-mail",
    "Acting on behalf of users": "Handelen namens gebruikers",
    "Public welcome page": "Openbare welkomstpagina",
    "Safety": "Veiligheid",
    "Queue": "Wachtrij",
    "External accounts": "Externe accounts",
    "Version": "Versie",
    "running": "actief",
    "paused": "gepauzeerd",
    "not checked": "niet gecontroleerd",
    "unchanged since we published it": "ongewijzigd sinds publicatie",
    "changed since we published it": "gewijzigd sinds publicatie",
    "all accounted for": "allemaal toegewezen",
    "up to date": "up-to-date",
    "{n} with no owner": "{n} zonder eigenaar",
    "{n} external account(s) in the tenant.": "{n} extern(e) account(s) in de tenant.",
    "{version} is available": "{version} is beschikbaar",
    "Running {version}": "Draait {version}",
    "Running {version} (simulation mode)": "Draait {version} (simulatiemodus)",
    "Today: {invited} invited, {blocked} blocked, {deleted} deleted.": "Vandaag: {invited} uitgenodigd, {blocked} geblokkeerd, {deleted} verwijderd.",
    "{waiting} waiting, {failed} failed.": "{waiting} in wachtrij, {failed} mislukt.",
    "{ms} ms": "{ms} ms",
    "Everything looks normal": "Alles ziet er normaal uit",
    "The same checks the nightly health mail runs found nothing to report.": "Dezelfde controles als in de nachtelijke gezondheidsmail vonden niets om te melden.",
    "Nothing has happened yet.": "Er is nog niets gebeurd.",

    /* --- banners from the API --- */
    "Simulation mode is on": "Simulatiemodus staat aan",
    "Collaborate is logging what it would do but changing nothing and sending no mail. Turn it off in Configuration when you are ready to go live.": "Collaborate legt vast wat het zou doen, maar wijzigt niets en verstuurt geen e-mail. Zet dit uit bij Instellingen zodra u live wilt.",
    "Processing is paused": "Verwerking is gepauzeerd",
    "Review and resume": "Bekijken en hervatten",
    "Setup is not finished": "De installatie is niet afgerond",
    "An administrator still needs to complete the setup wizard.": "Een beheerder moet de installatiewizard nog afronden.",

    /* --- sharing blocked on a site --- */
    "This site does not allow external sharing": "Deze site staat extern delen niet toe",
    "Nothing here can be shared outside the company. The person who owns the site can change that in SharePoint.": "Niets hier kan buiten het bedrijf worden gedeeld. De eigenaar van de site kan dat in SharePoint wijzigen.",
    "Look anyway": "Toch bekijken",
    "Sharing is blocked on this site": "Delen is geblokkeerd op deze site",
    "You can look around, but nothing here can be shared outside the company.": "U kunt rondkijken, maar niets hier kan buiten het bedrijf worden gedeeld.",
    "sharing is blocked on this site": "delen is geblokkeerd op deze site",
    "This tenant does not allow guests in Teams.": "Deze tenant staat gasten in Teams niet toe.",
    "You do not own any Teams.": "U bent van geen enkel Team eigenaar.",

    /* --- odds and ends --- */
    "Holds {role}": "Heeft {role}",
    "the admin role": "de beheerdersrol",
    "How to re-run the deployment": "De installatie opnieuw uitvoeren",
    "Default language": "Standaardtaal",
    "What everybody sees until they pick a language for themselves, top right. Their own choice always wins and is remembered per person.": "Wat iedereen ziet totdat zij rechtsboven zelf een taal kiezen. Hun eigen keuze wint altijd en wordt per persoon onthouden.",
    "Last active is read from Entra sign-in data.": "Laatst actief komt uit de aanmeldgegevens van Entra.",
    "Last active is read from Entra sign-in data, last checked {when}.": "Laatst actief komt uit de aanmeldgegevens van Entra, laatst gecontroleerd {when}.",

    /* --- prose the API sends, translated where the portal shows it. Email
       bodies and welcome-page copy are admin-editable free text and stay as
       written. --- */
    /* the file and folder picker */
    "SharePoint site": "SharePoint-site",
    "Document library": "Documentbibliotheek",
    "Word document": "Word-document",
    "Excel workbook": "Excel-werkmap",
    "PowerPoint presentation": "PowerPoint-presentatie",
    "Audio or video": "Audio of video",
    "Code file": "Codebestand",
    "Text file": "Tekstbestand",
    "An administrator has switched off sharing individual files.": "Een beheerder heeft het delen van losse bestanden uitgeschakeld.",
    "An administrator has switched off sharing folders.": "Een beheerder heeft het delen van mappen uitgeschakeld.",
    "Open this to choose something inside it.": "Open dit om iets erin te kiezen.",
    "None of your recent items are folders. Use My files or Sites to pick one.": "Geen van uw recente items is een map. Gebruik Mijn bestanden of Sites om er een te kiezen.",
    " Use My files or Sites instead.": " Gebruik in plaats daarvan Mijn bestanden of Sites.",
    "This site is read-only or locked, so nothing in it can be shared.": "Deze site is alleen-lezen of vergrendeld, dus niets erin kan worden gedeeld.",
    "This site does not allow sharing with people outside the company. The person who owns the site can change that in SharePoint.": "Deze site staat delen met mensen buiten het bedrijf niet toe. De eigenaar van de site kan dat in SharePoint wijzigen.",
    "Collaborate is not consented to read SharePoint site settings yet. Re-run the deployment to grant the AllSites.Read permission.": "Collaborate heeft nog geen toestemming om SharePoint-site-instellingen te lezen. Voer de installatie opnieuw uit om de AllSites.Read-machtiging te verlenen.",
    "SharePoint would not answer for this site. It may be locked, archived, or not readable by you.": "SharePoint gaf geen antwoord voor deze site. Mogelijk is die vergrendeld, gearchiveerd of voor u niet leesbaar.",

    /* sharing and Teams */
    "External sharing is switched off for the whole tenant in SharePoint, so nothing can be shared outside the company. A SharePoint administrator sets this.": "Extern delen is in SharePoint voor de hele tenant uitgeschakeld, dus er kan niets buiten het bedrijf worden gedeeld. Een SharePoint-beheerder stelt dit in.",
    "This Team has been set not to accept guests.": "Dit Team is ingesteld om geen gasten toe te laten.",
    "This tenant does not allow guests in Teams or groups.": "Deze tenant staat gasten in Teams of groepen niet toe.",
    "Simulation mode is on, so nothing was actually changed.": "Simulatiemodus staat aan, dus er is niets echt gewijzigd.",
    "Simulation mode is on, so nothing was actually sent.": "Simulatiemodus staat aan, dus er is niets echt verstuurd.",
    "Simulation mode is on, so nothing was actually shared or sent.": "Simulatiemodus staat aan, dus er is niets echt gedeeld of verstuurd.",
    "Nothing was changed: simulation mode is on": "Er is niets gewijzigd: simulatiemodus staat aan",
    "Nothing was sent: simulation mode is on": "Er is niets verstuurd: simulatiemodus staat aan",
    "Nothing was waiting to be sent.": "Er stond niets klaar om te versturen.",
    "Sent.": "Verstuurd.",
    "No message was added.": "Er is geen bericht toegevoegd.",
    "That does not look like an email address.": "Dit lijkt geen e-mailadres.",
    "deleted elsewhere": "elders verwijderd",

    /* acting on behalf of a user */
    "A Conditional Access policy blocked this action. You may need to sign in again with multi-factor authentication, or the policy needs to allow Collaborate.": "Een Conditional Access-beleid heeft deze actie geblokkeerd. Mogelijk moet u opnieuw aanmelden met meervoudige verificatie, of moet het beleid Collaborate toestaan.",
    "Collaborate is not yet consented to act on your behalf. An administrator needs to grant admin consent for the delegated Microsoft Graph permissions on the portal app registration (the deployment does this; re-run it or grant consent in Entra).": "Collaborate heeft nog geen toestemming om namens u te handelen. Een beheerder moet beheerderstoestemming verlenen voor de gedelegeerde Microsoft Graph-machtigingen op de app-registratie van de portal (de installatie doet dit; voer die opnieuw uit of verleen toestemming in Entra).",
    "The federated identity credential that lets Collaborate act on your behalf is missing or does not match this managed identity. Re-run the deployment to recreate it.": "De federated identity credential waarmee Collaborate namens u kan handelen ontbreekt of hoort niet bij deze beheerde identiteit. Voer de installatie opnieuw uit om die opnieuw aan te maken.",
    "Your sign-in token was not accepted for the on-behalf-of exchange. Sign out and back in, then try again.": "Uw aanmeldtoken is niet geaccepteerd voor de on-behalf-of-uitwisseling. Meld u af en weer aan en probeer het opnieuw.",

    /* what you can do with one collaborator */
    "Take this on": "Neem dit over",
    "Restore access": "Toegang herstellen",
    "Bring them back": "Terughalen",
    "Extend": "Verlengen",
    "End access now": "Toegang nu beëindigen",
    "Hand over": "Overdragen",
    "Send the invitation again": "Uitnodiging opnieuw versturen",
    "Their access has already ended.": "Hun toegang is al beëindigd.",
    "They have been removed, so there is nothing to hand over.": "Zij zijn verwijderd, dus er is niets over te dragen.",
    "Extend their access first, then resend.": "Verleng eerst hun toegang en verstuur daarna opnieuw.",
    "Extending access needs an administrator in this tenant.": "Verlengen van toegang vereist een beheerder in deze tenant.",

    /* the setup wizard */
    "Your sign-in token is valid": "Uw aanmeldtoken is geldig",
    "App Service authentication is in front of the API": "App Service-verificatie staat vóór de API",
    "The platform passed a verified client principal with this request.": "Het platform gaf een geverifieerde client principal mee met deze aanvraag.",
    "Anonymous requests are refused": "Anonieme aanvragen worden geweigerd",
    "Collaborate can act on your behalf (needed for sharing)": "Collaborate kan namens u handelen (nodig om te delen)",
    "The expiry attribute is available": "Het einddatumattribuut is beschikbaar",
    "The public welcome page can be published": "De openbare welkomstpagina kan worden gepubliceerd",
    "The sender mailbox is reachable": "De afzendermailbox is bereikbaar",
    "No sender mailbox is configured.": "Er is geen afzendermailbox ingesteld.",
    "No public welcome site is configured.": "Er is geen openbare welkomstsite ingesteld.",
    "The welcome site can be published to.": "Er kan naar de welkomstsite worden gepubliceerd.",
    "Could not determine this app's host name, so the anonymous round trip was skipped.": "De hostnaam van deze app kon niet worden bepaald, dus de anonieme controle is overgeslagen.",
    "An unauthenticated request to the API returned 200. Authentication is NOT being enforced. Check Authentication (Easy Auth) on the Function App before going further.": "Een niet-geverifieerde aanvraag aan de API gaf 200 terug. Verificatie wordt NIET afgedwongen. Controleer Authentication (Easy Auth) op de Function App voordat u verdergaat.",
    "Single sign-on verified. Bootstrap administrator rights from the deployment no longer apply.": "Eenmalige aanmelding geverifieerd. De tijdelijke beheerdersrechten uit de installatie gelden niet meer.",

    /* configuration warnings */
    "The storm guard is off, so nothing limits how many guests can be blocked or deleted in one day.": "De stormbeveiliging staat uit, dus niets beperkt hoeveel gasten er op één dag geblokkeerd of verwijderd kunnen worden.",
    "With no grace period, guests are deleted the moment they expire and cannot be restored. Consider at least a few days.": "Zonder respijtperiode worden gasten verwijderd zodra ze verlopen en kunnen ze niet worden hersteld. Overweeg minstens een paar dagen.",
    "Inactive guests will be deleted automatically. Watch the activity log for a few cycles before relying on this.": "Inactieve gasten worden automatisch verwijderd. Volg het activiteitenlogboek een paar cycli voordat u hierop vertrouwt.",
    "No service desk address is set, so nobody is told about unowned guests or health problems.": "Er is geen servicedeskadres ingesteld, dus niemand wordt geïnformeerd over gasten zonder eigenaar of gezondheidsproblemen.",
    "Neither colour is dark enough to read as text on the page, so links and tabs use a darkened version rather than your exact colour. Make the main or accent colour darker if you want them on brand.": "Geen van beide kleuren is donker genoeg om als tekst leesbaar te zijn, dus links en tabbladen gebruiken een donkerdere variant in plaats van uw exacte kleur. Maak de hoofd- of accentkleur donkerder als u ze in de huisstijl wilt houden.",

    /* health findings */
    "Health data cannot be read": "Gezondheidsgegevens kunnen niet worden gelezen",
    "Everything is paused": "Alles is gepauzeerd",
    "The public welcome page has changed": "De openbare welkomstpagina is gewijzigd",
    "The logo is missing from the public site": "Het logo ontbreekt op de openbare site",
    "Mail is not working": "E-mail werkt niet",
    "No service desk address": "Geen servicedeskadres",
    "Nothing can be reported to anybody, including this message. Set one in Configuration.": "Er kan aan niemand iets worden gemeld, ook dit bericht niet. Stel er een in bij Instellingen.",
    "Simulation mode is still on": "Simulatiemodus staat nog aan",
    "Collaborate is logging what it would do and changing nothing. Guests are not being reminded, blocked or removed.": "Collaborate legt vast wat het zou doen en wijzigt niets. Gasten krijgen geen herinnering en worden niet geblokkeerd of verwijderd.",
    "Setup was never finished": "De installatie is nooit afgerond",
    "The portal is not usable until an administrator completes the setup wizard.": "De portal is pas bruikbaar als een beheerder de installatiewizard afrondt.",
    "The queue is unusually deep. Either a large scan is still draining or the processor is not keeping up.": "De wachtrij is ongewoon lang. Of een grote scan wordt nog verwerkt, of de verwerker loopt achter.",
    "Messages that failed five times are held in the poison queue. Whatever they were meant to do has not happened. The Diagnostics tab shows the count; Application Insights shows why.": "Berichten die vijf keer zijn mislukt staan in de poison-wachtrij. Wat zij moesten doen is niet gebeurd. Het tabblad Diagnose toont het aantal; Application Insights toont waarom.",

    /* the email catalogue */
    "Invitation": "Uitnodiging",
    "Invitation with a shared item": "Uitnodiging met een gedeeld item",
    "Something new was shared": "Er is iets nieuws gedeeld",
    "Welcome (after accepting)": "Welkom (na accepteren)",
    "Your guest accepted": "Uw gast heeft geaccepteerd",
    "Reminder to the owner": "Herinnering aan de eigenaar",
    "Reminder to the guest": "Herinnering aan de gast",
    "Access ended": "Toegang beëindigd",
    "Guest removed": "Gast verwijderd",
    "Inactive guest warning": "Waarschuwing inactieve gast",
    "Ownership transferred": "Eigenaarschap overgedragen",
    "Colleague asks the owner": "Collega vraagt het de eigenaar",
    "Something is wrong": "Er is iets mis",
    "A newer version is available": "Er is een nieuwere versie beschikbaar",
    "Unowned guests digest": "Overzicht gasten zonder eigenaar",

    /* odds and ends */
    "Reminders, expiry notices and digests are sent from here, and so is anything a browser could not send. Invitations come from whoever created them. Permission to send is scoped to this one mailbox in Exchange Online, so changing it means re-running the deployment, which is idempotent and safe against an existing install.": "Herinneringen, verloopberichten en overzichten worden hiervandaan verstuurd, net als alles wat een browser niet kon versturen. Uitnodigingen komen van degene die ze heeft aangemaakt. De verzendmachtiging is in Exchange Online beperkt tot deze ene mailbox, dus wijzigen betekent de installatie opnieuw uitvoeren; die is idempotent en veilig op een bestaande installatie.",
    "The on-behalf-of exchange works.": "De on-behalf-of-uitwisseling werkt.",
    "Set during deployment.": "Ingesteld tijdens de installatie.",
    "Confirm": "Bevestigen"
  };

  /* Sentences the API composes around a date or a count. They cannot be keys as
     they stand, so each is a shape: the captured pieces are translated in turn
     (a date inside "Ends in 3 days (9 November 2026)" is itself a shape) and
     dropped back in. Ordered, first match wins. */
  var MONTHS_NL = {
    January: "januari", February: "februari", March: "maart", April: "april",
    May: "mei", June: "juni", July: "juli", August: "augustus",
    September: "september", October: "oktober", November: "november", December: "december"
  };

  var NL_PATTERNS = [
    [/^(\d{1,2}) (January|February|March|April|May|June|July|August|September|October|November|December) (\d{4})$/,
      function (m) { return m[1] + " " + MONTHS_NL[m[2]] + " " + m[3]; }],
    [/^(\d+) days ago$/, "{1} dagen geleden"],
    [/^Opened (.+)$/, "Geopend {1}"],
    [/^Edited (.+)$/, "Bewerkt {1}"],
    [/^Active until (.+)$/, "Actief tot {1}"],
    [/^Ends today \((.+)\)$/, "Eindigt vandaag ({1})"],
    [/^Ends tomorrow \((.+)\)$/, "Eindigt morgen ({1})"],
    [/^Ends in (\d+) days \((.+)\)$/, "Eindigt over {1} dagen ({2})"],
    [/^Ended on (.+)$/, "Geëindigd op {1}"],
    [/^Access switched off \(ended (.+)\)$/, "Toegang uitgeschakeld (geëindigd {1})"],
    [/^Accepted (.+)$/, "Geaccepteerd {1}"],
    [/^Invited (.+), not accepted yet$/, "Uitgenodigd {1}, nog niet geaccepteerd"],
    [/^Ask (.+)$/, "Vraag het {1}"],
    [/^(\d+) selected$/, "{1} geselecteerd"]
  ];

  var PATTERNS = { nl: NL_PATTERNS };

  var DICTIONARIES = { nl: NL };

  // English first: it is the source language.
  var LANGUAGES = [
    { code: "en", label: "English" },
    { code: "nl", label: "Nederlands" }
  ];

  var current = "en";

  function normalise(s) { return String(s == null ? "" : s).replace(/\s+/g, " ").trim(); }

  function supported(code) {
    var c = String(code || "").toLowerCase().slice(0, 2);
    if (c === "en") { return "en"; }
    return DICTIONARIES[c] ? c : "";
  }

  function setLanguage(code) { current = supported(code) || "en"; return current; }
  function getLanguage() { return current; }

  var depth = 0;   // patterns translate their own captures; two levels is plenty

  function byPattern(key) {
    var list = PATTERNS[current];
    if (!list || depth > 2) { return null; }
    for (var i = 0; i < list.length; i++) {
      var m = key.match(list[i][0]);
      if (!m) { continue; }
      var shape = list[i][1];
      depth++;
      try {
        if (typeof shape === "function") { return shape(m); }
        return shape.replace(/\{(\d+)\}/g, function (whole, n) {
          var part = m[Number(n)];
          return part === undefined ? whole : t(part);
        });
      }
      finally { depth--; }
    }
    return null;
  }

  /* t("Ends in {days} days ({date})", { days: 3, date: "9 mei" }) */
  function t(text, vars) {
    var key = normalise(text);
    var dict = DICTIONARIES[current];
    var out = (dict && dict[key]);
    if (out === undefined) { out = byPattern(key); }
    if (out === null || out === undefined) { out = text; }
    if (vars) {
      out = String(out).replace(/\{(\w+)\}/g, function (whole, name) {
        return Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : whole;
      });
    }
    return out;
  }

  var INLINE = { EM: 1, STRONG: 1, B: 1, I: 1, CODE: 1, SPAN: 1, A: 1, BR: 1 };
  var SKIP_TAG = { SCRIPT: 1, STYLE: 1, TEXTAREA: 1 };

  function translateElement(el) {
    if (!el || SKIP_TAG[el.tagName]) { return; }
    if (el.hasAttribute && el.hasAttribute("data-i18n-skip")) { return; }

    ["placeholder", "title", "aria-label"].forEach(function (attr) {
      var value = el.getAttribute && el.getAttribute(attr);
      if (!value) { return; }
      var translated = t(value);
      if (translated !== value) { el.setAttribute(attr, translated); }
    });

    var children = el.children || [];
    var text = normalise(el.textContent);
    if (!text) { return; }

    if (children.length === 0) {
      var one = t(text);
      if (one !== text) { el.textContent = one; }
      return;
    }

    var inlineOnly = true;
    for (var i = 0; i < children.length; i++) {
      if (!INLINE[children[i].tagName]) { inlineOnly = false; break; }
    }
    if (inlineOnly && children.length <= 4 && text.length < 400) {
      var markup = normalise(el.innerHTML);
      var whole = t(markup);
      if (whole !== markup) { el.innerHTML = whole; return; }
    }
    for (var j = 0; j < children.length; j++) { translateElement(children[j]); }
  }

  /* ---------------- install ----------------

     Rather than wrapping every string in app.js, the three DOM writes it makes
     are patched once: innerHTML, textContent and the attributes people read
     (placeholder, title, aria-label). Every write is therefore translated the
     moment it happens, synchronously, BEFORE the caller wires its handlers, and
     a string added later is covered without anybody remembering this file.

     Only t() with values in it stays explicit in app.js, because "3 of 12
     selected" is not a dictionary key.

     Nothing is patched while English is on, so the source language runs on
     untouched browser primitives.

     Translation is one-way: it edits in place and the dictionary is not
     reversible, so changing language reloads the page. */

  var busy = false;      // re-entrancy: translateElement writes innerHTML itself
  var installed = false;

  function translateDom(root) {
    if (current === "en" || busy) { return; }
    busy = true;
    try { translateElement(root || document.body); } finally { busy = false; }
  }

  var ATTRS = { placeholder: 1, title: 1, "aria-label": 1 };

  function install() {
    if (current === "en" || installed) { return; }
    installed = true;

    var html = Object.getOwnPropertyDescriptor(Element.prototype, "innerHTML");
    Object.defineProperty(Element.prototype, "innerHTML", {
      configurable: true,
      get: html.get,
      set: function (value) {
        html.set.call(this, value);
        if (!busy) { translateDom(this); }
      }
    });

    var text = Object.getOwnPropertyDescriptor(Node.prototype, "textContent");
    Object.defineProperty(Node.prototype, "textContent", {
      configurable: true,
      get: text.get,
      set: function (value) {
        text.set.call(this, (busy || value == null || value === "") ? value : t(value));
      }
    });

    var setAttr = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
      if (!busy && ATTRS[name] && value) { value = t(value); }
      return setAttr.call(this, name, value);
    };

    // The property forms of the same attributes. Assigning el.title does not go
    // through setAttribute.
    ["title", "placeholder"].forEach(function (prop) {
      var host = prop === "title" ? HTMLElement.prototype : HTMLInputElement.prototype;
      var d = Object.getOwnPropertyDescriptor(host, prop);
      if (!d || !d.set) { return; }
      Object.defineProperty(host, prop, {
        configurable: true,
        get: d.get,
        set: function (value) { d.set.call(this, (busy || !value) ? value : t(value)); }
      });
    });
  }

  global.CBI18N = {
    // Exposed so a build check can compare it against what the page actually
    // renders, rather than trusting that both were updated together.
    dictionaries: DICTIONARIES,
    t: t,
    setLanguage: setLanguage,
    getLanguage: getLanguage,
    supported: supported,
    languages: LANGUAGES,
    translateElement: translateElement,
    translateDom: translateDom,
    install: install
  };
})(window);
