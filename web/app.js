/* Collaborate portal.

   Delegated Entra sign-in via MSAL, then every call goes to the Function App
   API, which validates the token again and decides what this person may do. The
   client renders what the API tells it: it never decides access itself, so
   hiding a button is a courtesy, not a control.

   Branding is applied at runtime (custom properties + text + logo), which is why
   changing a colour takes effect on the next load rather than on the next
   deployment. Before sign-in there is no token, so the gate reads the small
   public branding file the API republishes alongside the welcome page. */
(function () {
  "use strict";

  var CFG = window.CB_AUTH || {};
  var el = function (id) { return document.getElementById(id); };
  var state = {
    me: null,          // /api/me payload
    config: null,      // admin config payload
    guests: null,      // last /api/guests payload
    guestsShowAll: false, // admin viewing every guest rather than their own
    selected: {},      // guest ids ticked for a bulk assignment
    action: null,      // { guest, key, spec } while the action dialog is open
    share: null,       // { mode, step, target, recipient, newGuest, crumb, pane }
    emailKey: "",      // template being edited
    logNext: null,     // activity log continuation
    wizard: null       // { settings, step }
  };

  /* ---------------- small helpers ---------------- */

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function toast(message, kind) {
    var host = el("toasts");
    if (!host) { return; }
    var t = document.createElement("div");
    t.className = "toast " + (kind || "");
    t.innerHTML = '<div>' + esc(message) + '</div><button class="toast-close" aria-label="Dismiss">&times;</button>';
    host.appendChild(t);
    function close() { t.classList.add("out"); setTimeout(function () { if (t.parentNode) { t.parentNode.removeChild(t); } }, 260); }
    t.querySelector(".toast-close").onclick = close;
    if (kind !== "bad") { setTimeout(close, 6000); }
  }

  function setStatus(id, text, kind) {
    var node = el(id);
    if (!node) { return; }
    node.textContent = text || "";
    node.className = "status" + (kind ? " " + kind : "");
  }

  function fmtDate(iso) {
    if (!iso) { return ""; }
    var d = new Date(iso);
    return isNaN(d.getTime()) ? String(iso) : d.toLocaleString();
  }

  // Booleans from the API should arrive as JSON booleans, but "false" is a
  // truthy string in JavaScript, so a value that ever comes through as text
  // would silently render as ON. This is the one place that decides, and it
  // treats the string forms correctly rather than trusting the type.
  // Only ever emit an https link. These URLs come from Graph rather than from a
  // user, but a href is one of the two places markup turns into behaviour, and
  // an allowlist of one scheme is cheaper than being sure.
  function safeUrl(v) {
    var s = String(v || "");
    return s.slice(0, 8).toLowerCase() === "https://" ? s : "";
  }

  // A failure as two things: a sentence, and the detail support asks for. The
  // detail is collapsed, because an employee mid-task should not have to read a
  // Graph error to understand that a site refused them.
  var errorSeq = 0;
  function errorHtml(e) {
    var detail = (e && e.data && e.data.detail) || "";
    var html = '<p class="status bad">' + esc(e.message || "Something went wrong.") + "</p>";
    if (!detail) { return html; }
    var id = "errDetail" + (++errorSeq);
    var body = detail + "\n\nWhen: " + new Date().toISOString() +
      "\nVersion: " + ((state.me && state.me.version) || "?");
    return html +
      '<details class="tech"><summary>Technical details</summary>' +
      '<pre id="' + id + '">' + esc(body) + "</pre>" +
      '<button type="button" class="btn small ghost" data-copy="' + id + '">Copy for support</button>' +
      "</details>";
  }

  // Wires any copy buttons inside a container that has just been rendered.
  function wireCopyButtons(host) {
    host.querySelectorAll("[data-copy]").forEach(function (b) {
      b.onclick = function () {
        var text = (el(b.dataset.copy) || {}).textContent || "";
        if (navigator.clipboard) {
          navigator.clipboard.writeText(text).then(function () { toast("Copied.", "ok"); },
            function () { toast("Could not copy. Select the text and copy it.", "bad"); });
        } else { toast("Select the text and copy it.", "bad"); }
      };
    });
  }

  function truthy(v) {
    if (typeof v === "string") { return !(v === "" || v.toLowerCase() === "false" || v === "0"); }
    return !!v;
  }

  /* ---------------- branding ---------------- */

  // Mirrors Get-CBReadableTextColor server side, so the portal, the emails and
  // the welcome page all pick the same text colour for a given background.
  function luminance(hex) {
    var h = String(hex || "").replace("#", "");
    if (h.length !== 6) { return 1; }
    var parts = [0, 2, 4].map(function (i) {
      var c = parseInt(h.substr(i, 2), 16) / 255;
      return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2];
  }
  function contrast(a, b) {
    var la = luminance(a), lb = luminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
  }
  function readableOn(bg) { return contrast("#ffffff", bg) >= contrast("#1b1b1b", bg) ? "#ffffff" : "#1b1b1b"; }

  // The page background for the scheme in force, kept in step with :root and its
  // dark-mode override in styles.css.
  function pageBackground() {
    return (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) ? "#1b1a19" : "#f3f2f1";
  }

  function mixToward(hex, target, amount) {
    var a = String(hex || "").replace("#", "");
    var b = String(target).replace("#", "");
    if (a.length !== 6 || b.length !== 6) { return hex; }
    var out = "#";
    for (var i = 0; i < 6; i += 2) {
      var from = parseInt(a.substr(i, 2), 16);
      var to = parseInt(b.substr(i, 2), 16);
      var v = Math.round(from + (to - from) * amount);
      out += ("0" + v.toString(16)).slice(-2);
    }
    return out;
  }

  // A brand colour that is legible AS TEXT on the page.
  //
  // --brand-primary is a SURFACE colour: it paints the top bar and the email
  // header band, and --brand-on-primary is the text that sits on top of it.
  // Links and the active tab are the opposite job -- brand-coloured ink on the
  // page's own background -- and using one value for both meant that any light
  // brand colour made every link almost invisible. A light brand colour is
  // exactly what a logo with dark lettering needs, so this is not a corner case.
  function brandInk(primary, accent) {
    var bg = pageBackground();
    if (primary && contrast(primary, bg) >= 4.5) { return primary; }
    // The accent is the other colour this tenant already chose, and it is the
    // "something happens here" colour, so a link taking it reads as deliberate
    // rather than as a fallback.
    if (accent && contrast(accent, bg) >= 4.5) { return accent; }
    // Neither is readable, so walk the primary toward black (or white in dark
    // mode) until it is. Brand-ish and legible beats brand-exact and unreadable.
    var toward = luminance(bg) > 0.4 ? "#000000" : "#ffffff";
    for (var i = 1; i <= 10; i++) {
      var candidate = mixToward(primary, toward, i / 10);
      if (contrast(candidate, bg) >= 4.5) { return candidate; }
    }
    return toward;
  }

  var lastBranding = null;

  function applyBranding(b) {
    if (!b) { return; }
    lastBranding = b;
    var root = document.documentElement.style;
    if (b.primaryColor) {
      root.setProperty("--brand-primary", b.primaryColor);
      root.setProperty("--brand-on-primary", readableOn(b.primaryColor));
    }
    if (b.accentColor) {
      root.setProperty("--brand-accent", b.accentColor);
      root.setProperty("--brand-on-accent", readableOn(b.accentColor));
    }
    root.setProperty("--brand-ink", brandInk(b.primaryColor, b.accentColor));
    var title = b.portalTitle || b.companyName || "Collaborate";
    document.title = title;
    ["brandTitle", "gateTitle"].forEach(function (id) { if (el(id)) { el(id).textContent = title; } });
    ["brandSubtitle", "gateSubtitle"].forEach(function (id) {
      if (el(id)) { el(id).textContent = b.portalSubtitle || ""; }
    });
    ["brandLogo", "gateLogo"].forEach(function (id) {
      var img = el(id);
      if (!img) { return; }
      if (b.logoUrl) { img.src = b.logoUrl; img.alt = b.companyName || ""; img.hidden = false; }
      else { img.hidden = true; }
    });
  }

  // The readable ink depends on the page background, which changes with the
  // system theme while the page is open.
  if (window.matchMedia) {
    var schemeQuery = window.matchMedia("(prefers-color-scheme: dark)");
    var onScheme = function () { if (lastBranding) { applyBranding(lastBranding); } };
    if (schemeQuery.addEventListener) { schemeQuery.addEventListener("change", onScheme); }
    else if (schemeQuery.addListener) { schemeQuery.addListener(onScheme); }
  }

  // The gate runs before any token exists, so branding comes from the public
  // file. A failure here is cosmetic and must never block sign-in.
  function loadPublicBranding() {
    if (!CFG.brandingUrl || CFG.brandingUrl.indexOf("REPLACE") === 0) { return Promise.resolve(); }
    return fetch(CFG.brandingUrl, { cache: "no-cache" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (b) { if (b) { applyBranding(b); } })
      .catch(function () { });
  }

  /* ---------------- auth ---------------- */

  function fail(message) {
    el("gate").hidden = false;
    el("gateError").hidden = false;
    el("gateError").textContent = message;
    el("signInBtn").hidden = true;
  }

  if (typeof msal === "undefined") {
    loadPublicBranding();
    fail("The sign-in library could not be loaded. Check your network or content filtering, then reload.");
    return;
  }
  if (!CFG.clientId || CFG.clientId.indexOf("REPLACE") === 0) {
    loadPublicBranding();
    fail("Sign-in is not configured yet: authConfig.js still holds placeholders. Finish the deployment step that writes it.");
    return;
  }

  var msalInstance = new msal.PublicClientApplication({
    auth: {
      clientId: CFG.clientId,
      authority: "https://login.microsoftonline.com/" + CFG.tenantId,
      redirectUri: window.location.origin + window.location.pathname
    },
    cache: { cacheLocation: "sessionStorage" }
  });
  var loginRequest = { scopes: [CFG.apiScope] };

  function currentAccount() {
    var acc = msalInstance.getActiveAccount();
    if (acc) { return acc; }
    var all = msalInstance.getAllAccounts();
    return all && all.length ? all[0] : null;
  }

  function getToken() {
    var acc = currentAccount();
    if (!acc) { return Promise.reject(new Error("Not signed in.")); }
    return msalInstance.acquireTokenSilent({ scopes: [CFG.apiScope], account: acc })
      .then(function (r) { return r.accessToken; })
      .catch(function () { return msalInstance.acquireTokenRedirect(loginRequest); });
  }

  /* ---------------- sending as yourself ----------------
     When the tenant has chosen for invitations to come from the person rather
     than from the service desk mailbox, the API renders the message and this
     sends it, with a Graph token acquired HERE, in the browser, on the user's
     own device and network. The alternative was to hand the user's token to the
     Function App and send from there, which Conditional Access sees as a
     sign-in from a datacentre on an unmanaged device -- a policy any careful
     tenant blocks, and should.

     Every outcome is reported back, because the fallback matters more than the
     nicety: a message that this cannot send is sent from the service desk
     instead, immediately if we say so and by tomorrow's sweep if we never do. */

  var GRAPH_SEND_SCOPE = "https://graph.microsoft.com/Mail.Send";

  function getGraphSendToken() {
    var acc = currentAccount();
    if (!acc) { return Promise.reject(new Error("Not signed in.")); }
    return msalInstance.acquireTokenSilent({ scopes: [GRAPH_SEND_SCOPE], account: acc })
      .then(function (r) { return r.accessToken; })
      .catch(function () {
        // A popup rather than a redirect: a redirect here would throw away the
        // page state of somebody who has just finished a wizard, and the guest
        // has already been created by this point.
        return msalInstance.acquireTokenPopup({ scopes: [GRAPH_SEND_SCOPE], account: acc })
          .then(function (r) { return r.accessToken; });
      });
  }

  function sendOneMessage(msg) {
    return getGraphSendToken().then(function (token) {
      return fetch("https://graph.microsoft.com/v1.0/me/sendMail", {
        method: "POST",
        headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
        body: JSON.stringify({
          message: {
            subject: msg.subject,
            body: { contentType: "HTML", content: msg.html },
            toRecipients: [{ emailAddress: { address: msg.to } }]
          },
          // In the sender's own Sent Items, where they would look for it.
          saveToSentItems: true
        })
      }).then(function (res) {
        if (res.ok) { return; }
        return res.json().catch(function () { return {}; }).then(function (data) {
          throw new Error((data.error && data.error.message) || ("Graph returned " + res.status + "."));
        });
      });
    });
  }

  // Returns a promise that always resolves: a message that could not be sent is
  // a line in the result panel, never a failed invitation.
  function sendPendingMail(messages, lines) {
    var list = (messages || []).filter(function (m) { return m && m.to && m.guestId; });
    if (!list.length) { return Promise.resolve(); }
    return list.reduce(function (chain, msg) {
      return chain.then(function () {
        return sendOneMessage(msg)
          .then(function () {
            return api("/outbox", "POST", { guestId: msg.guestId, ok: true });
          })
          .catch(function (e) {
            return api("/outbox", "POST", { guestId: msg.guestId, ok: false, error: e.message })
              .then(function (r) { if (lines && r && r.message) { lines.push(r.message); } })
              .catch(function () {
                if (lines) { lines.push("The message could not be sent from your mailbox. It will be sent from the service desk shortly."); }
              });
          });
      });
    }, Promise.resolve());
  }

  function api(path, method, body) {
    return getToken().then(function (token) {
      return fetch(CFG.apiBase.replace(/\/$/, "") + path, {
        method: method || "GET",
        headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
        body: body ? JSON.stringify(body) : undefined
      }).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (data) {
          if (!res.ok) {
            var err = new Error(data.error || ("The server returned " + res.status + "."));
            err.status = res.status;
            err.data = data;
            throw err;
          }
          return data;
        });
      });
    });
  }

  /* ---------------- views ---------------- */

  function showView(name) {
    document.querySelectorAll(".view").forEach(function (v) { v.hidden = v.id !== "view-" + name; });
    document.querySelectorAll(".tab").forEach(function (t) { t.classList.toggle("active", t.dataset.view === name); });
    if (name === "guests") { loadGuests(); }
    if (name === "config") { loadConfig(); }
    if (name === "branding") { loadConfig().then(renderBranding); }
    if (name === "emails") { loadConfig().then(renderEmails); }
    if (name === "log") { loadLog(true); }
    if (name === "diag") { loadDiagnostics(); }
  }

  // Buttons rendered after boot (inside a verdict card, say) need wiring too, so
  // this runs over a subtree rather than only once over the document.
  function wireViewLinks(root) {
    (root || document).querySelectorAll("[data-view-link]").forEach(function (b) {
      b.onclick = function () { showView(b.dataset.viewLink); };
    });
  }

  function showSoon(title, text) {
    el("soonTitle").textContent = title;
    el("soonText").textContent = text;
    showView("soon");
  }

  function renderBanners(banners) {
    var host = el("banners");
    host.innerHTML = "";
    (banners || []).forEach(function (b) {
      var div = document.createElement("div");
      div.className = "banner " + (b.level === "error" ? "error" : "");
      div.innerHTML = '<div><div class="title">' + esc(b.title) + '</div><div class="small">' + esc(b.message) + '</div></div>';
      if (b.action === "resume") {
        var btn = document.createElement("button");
        btn.className = "btn small";
        btn.textContent = b.actionLabel || "Resume";
        btn.onclick = function () {
          btn.disabled = true;
          api("/resume", "POST", {})
            .then(function () { toast("Processing resumed.", "ok"); return loadMe(); })
            .catch(function (e) { toast(e.message, "bad"); btn.disabled = false; });
        };
        div.appendChild(btn);
      }
      host.appendChild(div);
    });
  }

  // Drawn for these three actions rather than borrowed emoji. A dashed stroke
  // means "outside the company" in all three, which is the one idea the whole
  // tool is about.
  var CHOICE_ICONS = {
    collaborators:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<circle cx="8.5" cy="7.5" r="3.2"/>' +
      '<path d="M2.5 19.5v-.9c0-2.9 2.7-5.1 6-5.1s6 2.2 6 5.1v.9"/>' +
      '<circle cx="17" cy="8.5" r="2.6" stroke-dasharray="2 1.9"/>' +
      '<path d="M12.8 19.5v-.6c0-2.3 2.1-4.1 4.2-4.1s4.2 1.8 4.2 4.1v.6" stroke-dasharray="2 1.9"/>' +
      "</svg>",
    share:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<rect x="2.5" y="3" width="10" height="18" rx="2"/>' +
      '<path d="M5.5 8h4M5.5 11.5h4M5.5 15h2.5"/>' +
      '<path d="M17 2.5v19" stroke-dasharray="1.9 2.2"/>' +
      '<path d="M13 12h8.5"/><path d="M18.8 9.3 21.5 12l-2.7 2.7"/>' +
      "</svg>",
    team:
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      '<rect x="2.5" y="4" width="14" height="14" rx="3"/>' +
      '<circle cx="9.5" cy="9" r="2.2"/>' +
      '<path d="M5.8 15.4c0-2 1.7-3.7 3.7-3.7s3.7 1.7 3.7 3.7"/>' +
      // style, not a fill attribute: a custom property does not resolve in a
      // presentation attribute, and the badge has to knock out the box behind it.
      '<circle cx="17.8" cy="17.8" r="4.2" style="fill:var(--surface)" stroke-dasharray="2 1.9"/>' +
      '<path d="M17.8 15.8v4M15.8 17.8h4"/>' +
      "</svg>"
  };

  function renderHome() {
    var me = state.me;
    var caps = me.capabilities;
    var cards = [
      {
        icon: "collaborators",
        label: "Manage external collaborators",
        hint: "See who you have invited, and invite somebody new.",
        enabled: true,
        go: function () { showView("guests"); }
      },
      {
        icon: "share",
        // Says what this tenant actually allows, rather than promising something
        // the next screen refuses.
        label: "Share a " + shareLabel(),
        hint: "Pick something from SharePoint or your OneDrive and give an outsider access to just that.",
        // SharePoint's own tenant setting counts as much as ours: with it off,
        // every share fails, and finding that out after picking a file and a
        // person is the worst possible moment.
        enabled: (caps.shareFiles || caps.shareFolders) && sharingAllowed().ok,
        disabledHint: sharingAllowed().ok
          ? "An administrator has switched file and folder sharing off."
          : sharingAllowed().note,
        go: function () { startShare("files"); }
      },
      {
        icon: "team",
        label: "Add someone to a Team",
        hint: "Add an external person to a Team you own, if that Team allows guests.",
        enabled: caps.shareTeams,
        disabledHint: "An administrator has switched Teams sharing off.",
        go: function () { startShare("teams"); }
      }
    ];

    el("homeLoading").hidden = true;
    var host = el("homeChoices");
    host.innerHTML = "";
    cards.forEach(function (c) {
      if (!c.enabled && c.disabledHint === undefined) { return; }
      var btn = document.createElement("button");
      btn.className = "choice";
      btn.type = "button";
      if (!c.enabled) { btn.disabled = true; }
      btn.innerHTML = '<span class="icon">' + (CHOICE_ICONS[c.icon] || "") + "</span>" +
        '<span class="label">' + esc(c.label) + "</span>" +
        '<span class="hint">' + esc(c.enabled ? c.hint : c.disabledHint) + "</span>";
      if (c.enabled) { btn.onclick = c.go; }
      host.appendChild(btn);
    });

    if (!me.canInvite.allowed) {
      var note = document.createElement("p");
      note.className = "muted small";
      note.textContent = me.canInvite.reason;
      host.parentNode.appendChild(note);
    }

    // The same rule on the collaborators screen: the invite button is hidden
    // rather than offered and then refused.
    var invite = el("guestsInvite");
    var reason = el("guestsCantInvite");
    if (invite) { invite.hidden = !me.canInvite.allowed; }
    if (reason) {
      reason.hidden = me.canInvite.allowed;
      reason.textContent = me.canInvite.reason || "";
    }
  }

  function renderShell() {
    var me = state.me;
    applyBranding(me.branding);
    el("userName").textContent = me.user.displayName || me.user.email;
    document.querySelectorAll(".admin-only").forEach(function (n) { n.hidden = !me.user.isAdmin; });
    renderBanners(me.banners);
    renderHome();
    el("homeHeading").textContent = "What would you like to do?";
    // The version belongs in the colophon rather than on the Diagnostics tab
    // alone: it is the first thing anybody is asked for when reporting a
    // problem, and most people reporting one are not administrators.
    el("footVersion").textContent = me.version ? "v" + me.version : "";
  }

  function loadMe() {
    return api("/me").then(function (data) {
      state.me = data;
      renderShell();
      if (!data.setupComplete && data.user.isAdmin) { startWizard(); }
      return data;
    }).catch(function (e) {
      // Without /me there is nothing to render, so say so where the cards would
      // have been rather than leaving the spinner turning forever.
      el("homeLoading").innerHTML = '<p class="status bad">Collaborate could not start: ' + esc(e.message) + "</p>" +
        '<p class="small muted">If this persists, an administrator can check the Function App is running.</p>';
      el("homeLoading").hidden = false;
      throw e;
    });
  }

  /* ---------------- external collaborators ---------------- */

  // SharePoint's tenant-wide external sharing setting. Unknown counts as allowed:
  // an unreadable policy must not disable a working feature.
  function sharingAllowed() {
    var p = (state.me && state.me.sharingPolicy) || {};
    if (truthy(p.known) && !truthy(p.allowsExternal)) {
      return { ok: false, note: p.note || "SharePoint does not allow external sharing in this tenant." };
    }
    return { ok: true, note: "" };
  }

  // "file", "folder" or "file or folder", from what the administrator allows.
  function shareLabel() {
    var c = (state.me && state.me.capabilities) || {};
    if (truthy(c.shareFiles) && truthy(c.shareFolders)) { return "file or folder"; }
    if (truthy(c.shareFolders)) { return "folder"; }
    return "file";
  }

  function stateClass(s) {
    if (s === "blocked" || s === "expired") { return "bad"; }
    if (s === "expiring" || s === "pending") { return "warn"; }
    if (s === "active") { return "ok"; }
    return "";
  }

  // Whether the tenant can tell us when a guest was last active. It needs an
  // Entra ID P1 or P2 licence, so the answer comes from the API rather than
  // being guessed from an empty field.
  function signInData() {
    var d = (state.me && state.me.signInData) || {};
    return {
      available: truthy(d.available),
      checkedAtLabel: d.checkedAtLabel || "",
      note: d.note || ""
    };
  }

  function loadGuests() {
    var showAll = !!(state.me.user.isAdmin && el("guestsAll") && el("guestsAll").checked);
    setStatus("guestsStatus", "Loading...");
    state.selected = {};
    return api("/guests" + (showAll ? "?scope=all" : "")).then(function (data) {
      state.guests = data;
      state.guestsShowAll = showAll;
      renderGuests(data, showAll);
      setStatus("guestsStatus", "");
      return data;
    }).catch(function (e) {
      setStatus("guestsStatus", e.message, "bad");
      el("guestTable").innerHTML = "";
    });
  }

  /* --- sorting and filtering, in the browser ---
     The whole tenant's guests are a few thousand rows at most and they are
     already here, so a round trip per keystroke would be slower and no more
     correct: the API decided what this person may see before it sent it. */

  var GUEST_STATES = [
    ["blocked", "switched off"], ["expired", "ended"], ["expiring", "ending soon"],
    ["pending", "waiting to accept"], ["active", "active"], ["deleted", "removed"]
  ];

  // The same order the server sorts by, so sorting the status column ascending
  // means "most in need of attention first" rather than alphabetically, which
  // would put "active" above "blocked" and bury the only rows that matter.
  function stateRank(s) {
    for (var i = 0; i < GUEST_STATES.length; i++) { if (GUEST_STATES[i][0] === s) { return i; } }
    return GUEST_STATES.length;
  }

  function guestFilterState() {
    if (!state.guestFilter) { state.guestFilter = { who: "", states: [] }; }
    return state.guestFilter;
  }

  function applyGuestFilters(items) {
    var f = guestFilterState();
    var unownedOnly = state.guestsShowAll && el("guestsUnowned").checked;
    var term = f.who.trim().toLowerCase();
    return items.filter(function (g) {
      if (f.states.length && f.states.indexOf(g.state) < 0) { return false; }
      if (unownedOnly && !g.orphaned) { return false; }
      if (term) {
        var hay = [g.displayName, g.email, g.reason, g.owner ? g.owner.displayName : ""].join(" ").toLowerCase();
        if (hay.indexOf(term) < 0) { return false; }
      }
      return true;
    });
  }

  function applyGuestSort(items) {
    var s = state.guestSort;
    // No explicit sort means the server's order: attention first, then soonest
    // to end. That is the useful default and it is worth keeping.
    if (!s || !s.key) { return items; }
    var dir = s.dir === "desc" ? -1 : 1;
    var sorted = items.slice();
    sorted.sort(function (a, b) {
      var x, y;
      if (s.key === "who") {
        x = (a.displayName || a.email || "").toLowerCase();
        y = (b.displayName || b.email || "").toLowerCase();
        return dir * x.localeCompare(y);
      }
      if (s.key === "status") {
        x = stateRank(a.state); y = stateRank(b.state);
        if (x !== y) { return dir * (x - y); }
        return dir * ((a.daysLeft || 0) - (b.daysLeft || 0));
      }
      // Last active. Never signed in sorts last whichever way round it is
      // pointing: "no date" is not a very old date, and putting a hundred blanks
      // at the top of a descending sort helps nobody.
      x = a.lastSignIn || ""; y = b.lastSignIn || "";
      if (!x && !y) { return 0; }
      if (!x) { return 1; }
      if (!y) { return -1; }
      return dir * (x < y ? -1 : (x > y ? 1 : 0));
    });
    return sorted;
  }

  function sortIndicator(key) {
    var s = state.guestSort;
    if (!s || s.key !== key) { return '<span class="sort-mark" aria-hidden="true">↕</span>'; }
    return '<span class="sort-mark on" aria-hidden="true">' + (s.dir === "desc" ? "↓" : "↑") + "</span>";
  }

  function headerCell(key, label, filterable) {
    var f = guestFilterState();
    var active = (key === "status" && f.states.length) || (key === "who" && f.who);
    return "<th>" +
      '<button type="button" class="th-sort" data-sort="' + key + '" title="Sort by ' + esc(label) + '">' +
      esc(label) + sortIndicator(key) + "</button>" +
      (filterable
        ? '<button type="button" class="th-filter' + (active ? " on" : "") + '" data-filter="' + key +
        '" title="Filter" aria-label="Filter by ' + esc(label) + '">⋮</button>'
        : "") +
      "</th>";
  }

  function closeHeaderMenu() {
    var open = document.getElementById("thMenu");
    if (open) { open.remove(); }
  }

  function openHeaderMenu(key, anchor) {
    closeHeaderMenu();
    var f = guestFilterState();
    var menu = document.createElement("div");
    menu.id = "thMenu";
    menu.className = "th-menu";

    if (key === "who") {
      menu.innerHTML = '<label class="field"><span>Contains</span>' +
        '<input id="thWho" type="text" value="' + esc(f.who) + '" placeholder="name, address or domain" /></label>' +
        '<div class="row"><button class="btn small primary" id="thApply">Apply</button>' +
        '<button class="btn small ghost" id="thClear">Clear</button></div>';
    } else {
      // Every state, with the ones present in this list counted. Offering a
      // state nobody has would be a filter that always returns nothing.
      var counts = {};
      (state.guests && state.guests.items ? state.guests.items : []).forEach(function (g) {
        counts[g.state] = (counts[g.state] || 0) + 1;
      });
      menu.innerHTML = GUEST_STATES.map(function (p) {
        var checked = f.states.indexOf(p[0]) >= 0;
        return '<label class="checkline small"><input type="checkbox" data-state="' + p[0] + '"' +
          (checked ? " checked" : "") + " /><span>" + esc(p[1]) +
          ' <span class="muted">(' + (counts[p[0]] || 0) + ")</span></span></label>";
      }).join("") +
        '<div class="row"><button class="btn small primary" id="thApply">Apply</button>' +
        '<button class="btn small ghost" id="thClear">Clear</button></div>';
    }

    document.body.appendChild(menu);
    var box = anchor.getBoundingClientRect();
    menu.style.top = (box.bottom + window.scrollY + 4) + "px";
    menu.style.left = Math.max(8, Math.min(box.left + window.scrollX, window.innerWidth - menu.offsetWidth - 8)) + "px";

    if (el("thWho")) {
      el("thWho").focus();
      el("thWho").addEventListener("keydown", function (e) { if (e.key === "Enter") { el("thApply").click(); } });
    }
    el("thApply").onclick = function () {
      if (key === "who") { f.who = el("thWho").value; }
      else {
        f.states = Array.prototype.slice.call(menu.querySelectorAll("[data-state]"))
          .filter(function (c) { return c.checked; })
          .map(function (c) { return c.dataset.state; });
      }
      closeHeaderMenu();
      renderGuests(state.guests, state.guestsShowAll);
    };
    el("thClear").onclick = function () {
      if (key === "who") { f.who = ""; } else { f.states = []; }
      closeHeaderMenu();
      renderGuests(state.guests, state.guestsShowAll);
    };
  }

  document.addEventListener("click", function (e) {
    var menu = document.getElementById("thMenu");
    if (menu && !menu.contains(e.target) && !e.target.closest("[data-filter]")) { closeHeaderMenu(); }
  });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") { closeHeaderMenu(); } });

  function renderGuests(data, showOwner) {
    var all = data.items || [];
    var items = applyGuestSort(applyGuestFilters(all));
    var counts = data.counts || {};

    el("guestsFilters").hidden = !showOwner;
    el("guestsEmpty").hidden = all.length > 0;
    if (all.length && !items.length) {
      el("guestTable").innerHTML = '<p class="muted small">Nothing matches that filter. ' +
        '<button type="button" class="linkish" id="guestsClearFilters">Clear the filters</button></p>';
      el("guestsClearFilters").onclick = function () {
        state.guestFilter = { who: "", states: [] };
        renderGuests(state.guests, state.guestsShowAll);
      };
      renderBulkBar();
      return;
    }
    el("guestsIntro").textContent = showOwner
      ? "Every external account in the tenant, with the colleague who is accountable for each one."
      : "Everybody here is recorded against your name, with a reason and an end date, so nothing stays open forever.";

    // Why there is, or is not, a "Last active" column. An empty column with no
    // explanation reads as "nobody has ever signed in", which would be a lie on
    // a tenant that simply cannot answer the question.
    var seenNote = signInData();
    el("guestsSignInNote").hidden = false;
    el("guestsSignInNote").textContent = seenNote.available
      ? "Last active is read from Entra sign-in data" + (seenNote.checkedAtLabel ? ", last checked " + seenNote.checkedAtLabel : "") + "."
      : seenNote.note;

    // Only the states that need somebody to do something are called out. A row
    // of six zeroes would be noise.
    var interesting = [["blocked", "switched off"], ["expired", "ended"], ["expiring", "ending soon"], ["pending", "waiting to accept"]];
    var pills = interesting.filter(function (p) { return counts[p[0]]; })
      .map(function (p) { return '<span class="pill ' + stateClass(p[0]) + '">' + esc(counts[p[0]]) + " " + esc(p[1]) + "</span>"; });
    pills.unshift('<span class="small muted">' + esc(counts.total || 0) + (counts.total === 1 ? " person" : " people") + "</span>");
    el("guestsCounts").innerHTML = items.length ? pills.join(" ") : "";

    if (!items.length) { el("guestTable").innerHTML = ""; renderBulkBar(); return; }
    var seen = signInData();
    var head = "<tr>" + (showOwner ? '<th><input id="guestsSelAll" type="checkbox" title="Select everything shown" /></th>' : "") +
      headerCell("who", "Who", true) + headerCell("status", "Status", true) +
      (seen.available ? headerCell("active", "Last active", false) : "") +
      "<th>Why</th>" + (showOwner ? "<th>Owner</th>" : "") + "<th></th></tr>";
    var rows = items.map(function (g, index) {
      var owner = "";
      var select = "";
      if (showOwner) {
        select = '<td><input type="checkbox" data-select="' + esc(g.id) + '"' +
          (state.selected[g.id] ? " checked" : "") + " /></td>";
        owner = '<td class="small">' + esc(g.owner && g.owner.displayName ? g.owner.displayName : "nobody") +
          (g.orphaned ? ' <span class="pill warn">unowned</span>' : "") + "</td>";
      }
      // Two facts, one column: when they last used the access, and whether they
      // ever accepted the invitation in the first place. The second is only
      // worth a line when it is not the ordinary "yes, on such a date".
      var active = "";
      if (seen.available) {
        active = '<td class="small">' +
          (g.lastSignInLabel ? esc(g.lastSignInLabel) : '<span class="muted">Never</span>') +
          (g.redemption === "accepted" ? "" : '<br><span class="small muted">' + esc(g.redemptionLabel) + "</span>") +
          "</td>";
      }
      // One way in, instead of four buttons per row. A row of Extend / End now /
      // Hand over / Send again, half of them greyed, made every collaborator
      // look like a form to fill in. What they are and what can be done about
      // them belong on one surface, which is what Open gives.
      return "<tr>" + select +
        "<td><strong>" + esc(g.displayName) + "</strong><br>" +
        '<span class="small muted">' + esc(g.email) + "</span></td>" +
        '<td><span class="pill ' + stateClass(g.state) + '">' + esc(g.state) + "</span><br>" +
        '<span class="small muted">' + esc(g.statusLabel) + "</span></td>" + active +
        '<td class="small">' + esc(g.reason || "") + "</td>" + owner +
        '<td><button class="btn small" data-guest-open="' + index + '">Open</button></td></tr>';
    }).join("");
    el("guestTable").innerHTML = "<table><thead>" + head + "</thead><tbody>" + rows + "</tbody></table>";

    el("guestTable").querySelectorAll("[data-guest-open]").forEach(function (b) {
      b.onclick = function () { openGuest(items[Number(b.dataset.guestOpen)]); };
    });
    el("guestTable").querySelectorAll("[data-sort]").forEach(function (b) {
      b.onclick = function () {
        var key = b.dataset.sort;
        var s = state.guestSort;
        // Third click returns to the server's order rather than leaving you
        // stuck in one of two sorts with no way back to the useful default.
        if (!s || s.key !== key) { state.guestSort = { key: key, dir: "asc" }; }
        else if (s.dir === "asc") { state.guestSort = { key: key, dir: "desc" }; }
        else { state.guestSort = null; }
        renderGuests(state.guests, state.guestsShowAll);
      };
    });
    el("guestTable").querySelectorAll("[data-filter]").forEach(function (b) {
      b.onclick = function (e) { e.stopPropagation(); openHeaderMenu(b.dataset.filter, b); };
    });

    var f = guestFilterState();
    var active = [];
    if (f.who) { active.push('who contains "' + f.who + '"'); }
    if (f.states.length) { active.push("status: " + f.states.join(", ")); }
    if (el("guestsActiveFilters")) {
      el("guestsActiveFilters").textContent = active.length ? "Filtered by " + active.join("; ") : "";
    }
    el("guestTable").querySelectorAll("[data-select]").forEach(function (c) {
      c.onchange = function () {
        if (c.checked) { state.selected[c.dataset.select] = true; } else { delete state.selected[c.dataset.select]; }
        renderBulkBar();
      };
    });
    if (el("guestsSelAll")) {
      el("guestsSelAll").onchange = function () {
        var on = el("guestsSelAll").checked;
        items.forEach(function (g) { if (on) { state.selected[g.id] = true; } else { delete state.selected[g.id]; } });
        renderGuests(state.guests, showOwner);
      };
    }
    renderBulkBar();
  }

  /* --- bulk assignment (administrators) --- */

  function selectedGuestIds() { return Object.keys(state.selected || {}); }

  function renderBulkBar() {
    var ids = selectedGuestIds();
    var bar = el("guestsBulk");
    bar.hidden = !state.guestsShowAll || ids.length === 0;
    if (bar.hidden) { return; }
    el("guestsSelected").textContent = ids.length + (ids.length === 1 ? " collaborator selected" : " collaborators selected");
  }

  // One people picker, used by bulk assignment and by the hand-over dialog.
  //
  // It says what it is doing at every moment. A box that stays empty through
  // 350ms of debounce and a directory round trip looks exactly like a box that
  // is broken, which is how this picker's query went on being refused by Graph
  // without anybody noticing. "Searching..." and a visible error are the cheap
  // way to never be in that position again.
  //
  // includeSelf is asked per search rather than fixed, because whether you can
  // pick yourself depends on the collaborator: taking on an unowned one is the
  // point, handing over one you already own is not.
  function peoplePicker(opts) {
    var input = el(opts.input);
    var host = el(opts.matches);
    var hidden = el(opts.hidden);
    var timer = null;
    var seq = 0;

    input.addEventListener("input", function () {
      hidden.value = "";
      if (timer) { clearTimeout(timer); }
      var term = input.value.trim();
      var mine = ++seq;
      if (term.length < 2) {
        host.innerHTML = term ? '<p class="small muted">Keep typing, at least two letters.</p>' : "";
        return;
      }
      host.innerHTML = '<p class="small muted">Searching the directory...</p>';
      timer = setTimeout(function () {
        var url = "/users?search=" + encodeURIComponent(term) +
          (opts.includeSelf && opts.includeSelf() ? "&includeSelf=1" : "");
        api(url).then(function (data) {
          if (mine !== seq) { return; }   // a later keystroke already replaced this
          host.innerHTML = (data.items || []).map(function (u) {
            return '<button type="button" class="match" data-oid="' + esc(u.id) + '">' +
              "<span><strong>" + esc(u.displayName) + "</strong>" +
              (u.isSelf ? ' <span class="pill">you</span>' : "") + "<br>" +
              '<span class="small muted">' + esc(u.userPrincipalName || u.mail || "") + "</span></span></button>";
          }).join("") ||
            // The API says WHY it is empty: a failed directory search and "no
            // such colleague" look identical otherwise.
            '<p class="small muted">' + esc(data.note || "Nobody found.") + "</p>";
          host.querySelectorAll(".match").forEach(function (b) {
            b.onclick = function () {
              hidden.value = b.dataset.oid;
              input.value = b.querySelector("strong").textContent;
              host.innerHTML = "";
            };
          });
        }).catch(function (e) {
          if (mine !== seq) { return; }
          host.innerHTML = '<p class="small status bad">' + esc(e.message) + "</p>";
        });
      }, 350);
    });
  }

  function wireBulkAssign() {
    // An administrator sorting out unowned accounts is allowed to keep some, so
    // this picker offers them themselves. Assigning one they already own comes
    // back as "they are already on your list" rather than silently doing nothing.
    peoplePicker({
      input: "guestsOwner", matches: "guestsOwnerMatches", hidden: "guestsOwnerId",
      includeSelf: function () { return true; }
    });

    el("guestsClearSel").onclick = function () {
      state.selected = {};
      renderGuests(state.guests, state.guestsShowAll);
    };

    el("guestsAssign").onclick = function () {
      var ids = selectedGuestIds();
      if (!el("guestsOwnerId").value) { setStatus("guestsAssignStatus", "Pick the colleague from the list first.", "bad"); return; }
      el("guestsAssign").disabled = true;
      setStatus("guestsAssignStatus", "Assigning " + ids.length + "...");
      api("/operations", "POST", { action: "assign", ownerId: el("guestsOwnerId").value, guestIds: ids })
        .then(function (data) {
          el("guestsAssign").disabled = false;
          toast(data.simulated ? "Simulation mode is on, so nothing was actually changed." : data.message, "ok");
          (data.failed || []).forEach(function (f) { toast(f.error, "bad"); });
          state.selected = {};
          el("guestsOwner").value = "";
          el("guestsOwnerId").value = "";
          setStatus("guestsAssignStatus", "");
          return loadGuests();
        })
        .catch(function (e) {
          el("guestsAssign").disabled = false;
          setStatus("guestsAssignStatus", e.message, "bad");
        });
    };

    el("guestsUnowned").addEventListener("input", function () { renderGuests(state.guests, state.guestsShowAll); });
  }

  /* ---------------- acting on one collaborator ---------------- */

  // Each action is a title, an explanation of what will actually happen, the
  // fields it needs, and how to describe success. Keeping them in one table
  // means the confirmation always matches what the API is about to do.
  function actionSpec(guest, key) {
    var policy = state.me.policy;
    var specs = {
      renew: {
        title: guest.state === "deleted" ? "Bring them back" : (guest.state === "blocked" ? "Restore access" : "Extend access"),
        explain: guest.state === "deleted"
          ? "Entra keeps removed accounts for 30 days. Restoring returns the same account, so anything shared with them before works again."
          : (guest.state === "blocked"
            ? "Sign-in is switched back on and a new end date is set from today."
            : "A new end date is set from today, not added to the current one."),
        fields: [
          field("actDays", "For how many days from today",
            '<input id="actDays" type="number" min="1" max="' + esc(policy.maxDays) + '" value="' + esc(policy.renewDays || policy.defaultDays) + '" />'),
          field("actReason", "Update the reason (optional)", '<textarea id="actReason" maxlength="400" rows="2"></textarea>')
        ],
        body: function () { return { action: "renew", days: Number(el("actDays").value), reason: el("actReason").value.trim() }; },
        done: "{name} now has access until {until}."
      },
      cancel: {
        title: "End access now",
        explain: "Sign-in is switched off straight away. The account is kept for the grace period, so you can undo this by extending them again.",
        fields: [field("actReason", "Why are you ending it? (optional)", '<textarea id="actReason" maxlength="400" rows="2"></textarea>')],
        body: function () { return { action: "cancel", reason: el("actReason").value.trim() }; },
        done: "Access ended for {name}."
      },
      claim: {
        title: "Take this on",
        explain: "Nobody is accountable for this collaborator at the moment. You become their owner, they get an end date like everybody else, and the reminders come to you.",
        fields: [
          field("actDays", "For how many days from today",
            '<input id="actDays" type="number" min="1" max="' + esc(policy.maxDays) + '" value="' + esc(policy.defaultDays) + '" />'),
          field("actReason", "Why do you work with them?" + (policy.requireReason ? "" : " (optional)"),
            '<textarea id="actReason" maxlength="400" rows="2"></textarea>')
        ],
        body: function () { return { action: "claim", days: Number(el("actDays").value), reason: el("actReason").value.trim() }; },
        done: "{name} is on your list now, until {until}."
      },
      transfer: {
        title: guest.orphaned ? "Make somebody responsible" : "Hand over to a colleague",
        explain: guest.orphaned
          ? "Nobody is accountable for this collaborator, so you can pick yourself here as well as a colleague. Whoever you pick gets the reminders from now on."
          : "They become accountable for this collaborator and get the reminders from now on. You will no longer see them in your list.",
        fields: [
          field("actOwnerSearch", "Which colleague?", '<input id="actOwnerSearch" type="text" autocomplete="off" placeholder="Start typing a name" />') +
          '<div id="actOwnerMatches"></div><input id="actOwnerId" type="hidden" />',
          field("actReason", "Anything they should know? (optional)", '<textarea id="actReason" maxlength="400" rows="2"></textarea>')
        ],
        body: function () { return { action: "transfer", ownerId: el("actOwnerId").value, reason: el("actReason").value.trim() }; },
        done: "Handed over."
      },
      resend: {
        title: "Send the invitation again",
        explain: "A fresh link is issued for the same account, so the end date and anything already shared with them are kept.",
        fields: [],
        body: function () { return { action: "resend" }; },
        done: "A fresh invitation is on its way."
      }
    };
    return specs[key];
  }

  /* --- the drawer: one collaborator, one surface --- */

  function openGuest(guest) {
    state.drawer = { guest: guest, key: null, loading: true };
    el("gdName").textContent = guest.displayName || guest.email;
    el("gdEmail").textContent = guest.email || "";
    el("guestDrawer").hidden = false;
    renderGuestOverview();

    // The list already carries everything except what they can reach, so the
    // drawer opens on what we have and fills that section in when it arrives.
    // Waiting for a round trip before showing anything would make every click
    // feel slow to hide one section.
    api("/guests?id=" + encodeURIComponent(guest.id))
      .then(function (data) {
        if (!state.drawer || state.drawer.guest.id !== guest.id) { return; }   // closed, or moved on
        state.drawer.guest = data.guest || guest;
        state.drawer.loading = false;
        if (!state.drawer.key) { renderGuestOverview(); }
      })
      .catch(function (e) {
        if (!state.drawer || state.drawer.guest.id !== guest.id) { return; }
        state.drawer.loading = false;
        state.drawer.loadError = e.message;
        if (!state.drawer.key) { renderGuestOverview(); }
      });
  }

  function closeGuest() {
    el("guestDrawer").hidden = true;
    state.drawer = null;
  }

  function fact(label, value) {
    if (!value) { return ""; }
    return '<div class="fact"><div class="k">' + esc(label) + '</div><div class="v">' + esc(value) + "</div></div>";
  }

  function renderGuestOverview() {
    var d = state.drawer;
    if (!d) { return; }
    var g = d.guest;
    d.key = null;

    var facts =
      fact(g.state === "pending" ? "Ends" : "Access until", g.expiresOnLabel) +
      fact("Days left", g.daysLeft > 0 ? String(g.daysLeft) : "") +
      fact("Accepted", g.redemptionLabel) +
      (signInData().available ? fact("Last active", g.lastSignInLabel || "Never signed in") : "") +
      fact("Owner", g.owner ? (g.owner.displayName || "nobody") : "") +
      fact("Invited", g.invitedAt ? relativeIso(g.invitedAt) : "") +
      fact("Extended", g.renewCount ? g.renewCount + " time(s)" : "");

    // Actions first. They are why somebody opened this, and putting them under a
    // list that grows with every share meant scrolling past everything a guest
    // can reach to find the button that ends their access.
    var body =
      '<p><span class="pill ' + stateClass(g.state) + '">' + esc(g.state) + "</span> " +
      '<span class="small muted">' + esc(g.statusLabel) + "</span></p>" +
      renderActionSection() +
      (g.reason ? '<h3>Why they are here</h3><p>' + esc(g.reason) + "</p>" : "") +
      "<h3>The details</h3>" + '<div class="facts">' + facts + "</div>" +
      renderAccessSection();

    el("gdBody").innerHTML = body;
    el("gdBody").querySelectorAll("[data-action]").forEach(function (b) {
      b.onclick = function () { renderGuestAction(b.dataset.action); };
    });
    el("gdBody").querySelectorAll("[data-unshare]").forEach(function (b) {
      b.onclick = function () { unshareItem(b.dataset.unshare, b.dataset.what); };
    });
    if (el("gdShare")) {
      el("gdShare").onclick = function () {
        var who = { id: g.id, email: g.email, displayName: g.displayName };
        closeGuest();
        startShare("files", who);
      };
    }
  }

  function unshareItem(itemId, what) {
    if (!state.drawer) { return; }
    var guest = state.drawer.guest;
    var buttons = el("gdBody").querySelectorAll("[data-unshare]");
    buttons.forEach(function (b) { b.disabled = true; });
    api("/guests/" + encodeURIComponent(guest.id) + "/action", "POST", { action: "unshare", itemId: itemId })
      .then(function (data) {
        toast(data.message || (what + " is no longer shared."), "ok");
        // Re-read rather than splice the row out locally: the API is the one
        // that knows whether the record went, and it also drops entries whose
        // access had already been removed elsewhere.
        return api("/guests?id=" + encodeURIComponent(guest.id)).then(function (fresh) {
          if (!state.drawer || state.drawer.guest.id !== guest.id) { return; }
          state.drawer.guest = fresh.guest || guest;
          renderGuestOverview();
        });
      })
      .catch(function (e) {
        buttons.forEach(function (b) { b.disabled = false; });
        var host = el("gdUnshareError");
        if (host) {
          host.innerHTML = errorHtml(e);
          host.hidden = false;
          wireCopyButtons(host);
          host.scrollIntoView({ block: "nearest" });
        }
        else { toast(e.message, "bad"); }
      });
  }

  function relativeIso(iso) {
    var d = new Date(iso);
    return isNaN(d.getTime()) ? "" : d.toLocaleDateString();
  }

  // What this tool granted, and an honest note about what it cannot know. A
  // short list read as "everything they can reach" would be the worst possible
  // basis for deciding somebody is safe to keep.
  function renderAccessSection() {
    var d = state.drawer;
    var items = d.guest.sharedItems;

    if (d.loading) { return '<h3>What they can reach</h3><p class="row small muted"><span class="spinner"></span> Looking...</p>'; }
    if (d.loadError) { return '<h3>What they can reach</h3><p class="status bad">' + esc(d.loadError) + "</p>"; }

    // Sharing from here starts with this person already chosen. Not offered for
    // somebody whose access has ended: the grant would work and be unusable.
    var caps = (state.me && state.me.capabilities) || {};
    var live = ["active", "expiring", "pending"].indexOf(d.guest.state) >= 0;
    var shareButton = (live && (truthy(caps.shareFiles) || truthy(caps.shareFolders)))
      ? '<p style="margin-top:10px"><button class="btn small" id="gdShare">' +
      (items && items.length ? "Share something else" : "Share something now") + "</button></p>"
      : "";

    if (!items || !items.length) {
      return "<h3>What they can reach</h3>" +
        '<p class="small muted">Nothing has been shared with them through Collaborate. Anything shared with them directly in SharePoint or Teams does not appear here.</p>' +
        shareButton;
    }

    var anyRedacted = false;
    var rows = items.map(function (it) {
      if (it.redacted) { anyRedacted = true; }
      var url = safeUrl(it.webUrl);
      var name = url
        ? '<a href="' + esc(url) + '" target="_blank" rel="noopener noreferrer">' + esc(it.name) + " ↗</a>"
        : esc(it.name);
      // Who shared it, always and first: with two colleagues sharing with the
      // same person, that is the fact that makes the rest of the line mean
      // anything.
      var by = it.sharedByYou ? "You" : (it.sharedBy || "somebody else");
      var meta = [by, it.kindLabel, it.roleLabel, it.sharedAtLabel ? "shared " + it.sharedAtLabel : ""]
        .filter(function (m) { return m; }).join(" · ");

      var action = "";
      if (it.canRevoke) {
        action = '<button class="btn small ghost" data-unshare="' + esc(it.id) + '" data-what="' + esc(it.name) + '">Unshare</button>';
      } else if (it.revokeBlockedReason) {
        action = '<span class="small muted" title="' + esc(it.revokeBlockedReason) + '">-</span>';
      }

      return '<div class="access-row"><span class="icon-cell">' + (ICONS[it.icon] || ICONS.file) + "</span>" +
        '<span class="grow"><strong' + (it.redacted ? ' class="muted"' : "") + ">" + name + "</strong><br>" +
        '<span class="small muted">' + esc(meta) + "</span></span>" + action + "</div>";
    }).join("");

    return "<h3>What they can reach</h3>" + '<div id="gdUnshareError" hidden></div>' +
      '<div class="access-list">' + rows + "</div>" +
      (anyRedacted
        ? '<p class="small muted" style="margin-top:8px">Items a colleague shared are not named. Ask whoever shared it.</p>'
        : "") +
      '<p class="small muted" style="margin-top:8px">What Collaborate granted, newest first, up to the last 50. ' +
      "Access given to them directly through SharePoint or Teams is not listed.</p>" +
      shareButton;
  }

  // One obvious next step, the rest quieter, and anything unavailable said in a
  // sentence instead of offered as a button that cannot be pressed.
  function renderActionSection() {
    var actions = (state.drawer.guest.actions || []);
    var available = actions.filter(function (a) { return a.enabled; });
    var blocked = actions.filter(function (a) { return !a.enabled && a.reason; });
    if (!available.length && !blocked.length) { return ""; }

    var buttons = available.map(function (a, i) {
      return '<button class="btn small' + (i === 0 ? " primary" : " ghost") + '" data-action="' + esc(a.key) + '">' +
        esc(a.label) + "</button>";
    }).join("");
    var reasons = blocked.map(function (a) {
      return '<span class="small muted">' + esc(a.label) + ": " + esc(a.reason) + "</span>";
    }).join("");

    return "<h3>What you can do</h3>" +
      '<div class="actions">' + buttons + "</div>" +
      (reasons ? '<div class="actions-blocked">' + reasons + "</div>" : "");
  }

  function renderGuestAction(key) {
    var d = state.drawer;
    var spec = actionSpec(d.guest, key);
    if (!spec) { return; }
    d.key = key;
    d.spec = spec;

    el("gdBody").innerHTML =
      "<h3>" + esc(spec.title) + "</h3>" +
      "<p>" + esc(spec.explain) + "</p>" +
      spec.fields.join("") +
      '<div class="row" style="margin-top:16px">' +
      '<button id="gdConfirm" class="btn primary">' + esc(spec.title) + "</button>" +
      '<button id="gdBack" class="btn ghost">Back</button>' +
      '<span id="actStatus" class="status" role="status"></span></div>';

    el("gdBack").onclick = renderGuestOverview;
    el("gdConfirm").onclick = confirmAction;
    if (key === "transfer") { wireOwnerPicker(); el("actOwnerSearch").focus(); }
    else if (el("actDays")) { el("actDays").focus(); }
  }

  function wireOwnerPicker() {
    peoplePicker({
      input: "actOwnerSearch", matches: "actOwnerMatches", hidden: "actOwnerId",
      // Yourself is only a sensible answer when nobody is accountable yet.
      includeSelf: function () { return !!(state.drawer && state.drawer.guest && state.drawer.guest.orphaned); }
    });
  }

  function confirmAction() {
    var d = state.drawer;
    if (!d || !d.spec) { return; }
    var body = d.spec.body();
    if (d.key === "transfer" && !body.ownerId) {
      setStatus("actStatus", "Pick the colleague from the list first.", "bad");
      return;
    }
    el("gdConfirm").disabled = true;
    setStatus("actStatus", "Working...");
    api("/guests/" + encodeURIComponent(d.guest.id) + "/action", "POST", body)
      .then(function (data) {
        var g = data.guest || {};
        var until = g.expiresOnLabel || g.expiresOn || "";
        var name = g.displayName || d.guest.displayName;
        toast(data.simulated
          ? "Simulation mode is on, so nothing was actually changed."
          : (data.message || d.spec.done.replace("{name}", name).replace("{until}", until)), "ok");
        (data.warnings || []).forEach(function (w) { toast(w, "bad"); });
        closeGuest();
        return loadGuests();
      })
      .catch(function (e) {
        el("gdConfirm").disabled = false;
        setStatus("actStatus", e.message, "bad");
      });
  }

  /* ---------------- invite: search first, always ---------------- */

  function looksLikeEmail(v) { return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(v || "").trim()); }

  function startInvite() {
    clearHomeResult();
    el("invSearch").value = "";
    el("invMatches").innerHTML = "";
    el("invVerdict").innerHTML = "";
    el("invCheck").disabled = true;
    setStatus("invStatus", "");
    showView("invite");
    el("invSearch").focus();
  }

  function renderMatches(items) {
    var host = el("invMatches");
    if (!items || !items.length) { host.innerHTML = ""; return; }
    host.innerHTML = '<p class="small muted matches-title">People we already work with:</p>' +
      items.map(function (g) {
        var who = g.mine ? "yours"
          : (g.owner && g.owner.displayName ? esc(g.owner.displayName) + "&rsquo;s"
            : (g.tracked ? "nobody looks after them" : "not tracked yet"));
        return '<button type="button" class="match" data-email="' + esc(g.email) + '">' +
          "<span><strong>" + esc(g.displayName) + "</strong><br>" +
          '<span class="small muted">' + esc(g.email) + "</span></span>" +
          '<span class="small muted">' + who + "</span></button>";
      }).join("");
    host.querySelectorAll(".match").forEach(function (b) {
      b.onclick = function () {
        el("invSearch").value = b.dataset.email;
        el("invCheck").disabled = false;
        checkAddress();
      };
    });
  }

  var searchTimer = null;
  function scheduleSearch() {
    var value = el("invSearch").value.trim();
    el("invCheck").disabled = !looksLikeEmail(value);
    el("invVerdict").innerHTML = "";
    if (searchTimer) { clearTimeout(searchTimer); }
    if (value.length < 2) { el("invMatches").innerHTML = ""; return; }
    searchTimer = setTimeout(function () {
      api("/guests?search=" + encodeURIComponent(value))
        .then(function (data) { renderMatches(data.items); })
        .catch(function () { el("invMatches").innerHTML = ""; });
    }, 350);
  }

  function verdictHeading(v) {
    return {
      notFound: "Nobody here by that address",
      mine: "Already yours",
      other: "Somebody already works with them",
      unowned: "They exist, but nobody owns them",
      internal: "That is a colleague",
      refused: "That address cannot be invited"
    }[v.verdict] || "Result";
  }

  function checkAddress() {
    var value = el("invSearch").value.trim();
    if (!looksLikeEmail(value)) { setStatus("invStatus", "Enter a full email address to continue.", "bad"); return; }
    setStatus("invStatus", "Checking...");
    el("invCheck").disabled = true;
    api("/guests?email=" + encodeURIComponent(value))
      .then(function (v) { setStatus("invStatus", ""); renderVerdict(v); })
      .catch(function (e) { setStatus("invStatus", e.message, "bad"); })
      .then(function () { el("invCheck").disabled = false; });
  }

  function renderVerdict(v) {
    var policy = state.me.policy;
    var parts = ['<div class="card"><h2>' + esc(verdictHeading(v)) + "</h2><p>" + esc(v.message) + "</p>"];

    if (v.verdict === "notFound" && v.canInvite) {
      parts.push(
        field("invName", "Their name", '<input id="invName" type="text" maxlength="120" placeholder="Jane Rivera" />'),
        field("invReason", "Why do you need to work with them?" + (policy.requireReason ? "" : " (optional)"),
          '<textarea id="invReason" maxlength="400" rows="3"></textarea>'),
        field("invDays", "For how many days", '<input id="invDays" type="number" min="1" max="' + esc(policy.maxDays) +
          '" value="' + esc(policy.defaultDays) + '" />'),
        '<p class="small muted">They will get an email from us, not the default Microsoft one, and their access ends automatically unless you extend it.</p>',
        '<div class="row"><button id="invSend" class="btn primary">Send the invitation</button>' +
        '<button class="btn ghost" data-view-link="guests">Cancel</button>' +
        '<span id="invSendStatus" class="status"></span></div>'
      );
    } else if (v.verdict === "notFound" && v.inviteBlockedReason) {
      parts.push('<p class="status bad">' + esc(v.inviteBlockedReason) + "</p>");
    } else if (v.verdict === "unowned" && v.canClaim) {
      parts.push(
        field("invClaimReason", "Why do you work with them?" + (policy.requireReason ? "" : " (optional)"),
          '<textarea id="invClaimReason" maxlength="400" rows="3"></textarea>'),
        field("invClaimDays", "Keep their access for how many days", '<input id="invClaimDays" type="number" min="1" max="' +
          esc(policy.maxDays) + '" value="' + esc(policy.defaultDays) + '" />'),
        '<div class="row"><button id="invClaim" class="btn primary" data-guest="' + esc(v.guest.id) +
        '">Take them on</button><button class="btn ghost" data-view-link="guests">Cancel</button>' +
        '<span id="invClaimStatus" class="status"></span></div>'
      );
    } else if (v.verdict === "other") {
      if (v.canAsk) {
        parts.push(
          field("invAskMessage", "Send them a note (optional)",
            '<textarea id="invAskMessage" maxlength="600" rows="3" placeholder="Could you share the proposal folder with them?"></textarea>'),
          '<div class="row"><button id="invAsk" class="btn primary" data-guest="' + esc(v.guest.id) + '">Ask ' +
          esc(v.owner && v.owner.displayName ? v.owner.displayName : "the owner") + '</button>' +
          '<button class="btn ghost" data-view-link="guests">Back</button><span id="invAskStatus" class="status"></span></div>'
        );
      } else {
        parts.push('<p><button class="btn" data-view-link="guests">Back</button></p>');
      }
    } else if (v.verdict === "mine") {
      parts.push('<p><button class="btn primary" data-view-link="guests">Open your collaborators</button></p>');
    } else if (v.verdict === "internal") {
      var mail = v.guest && v.guest.email ? v.guest.email : "";
      parts.push('<p><a class="btn" href="mailto:' + encodeURIComponent(mail) + '">Email them directly</a> ' +
        '<button class="btn ghost" data-view-link="guests">Back</button></p>');
    } else {
      parts.push('<p><button class="btn" data-view-link="guests">Back</button></p>');
    }

    parts.push("</div>");
    var host = el("invVerdict");
    host.innerHTML = parts.join("");
    wireViewLinks(host);

    if (el("invSend")) { el("invSend").onclick = sendInvitation; }
    if (el("invClaim")) { el("invClaim").onclick = function () { claimGuest(el("invClaim").dataset.guest); }; }
    if (el("invAsk")) { el("invAsk").onclick = function () { askOwner(el("invAsk").dataset.guest); }; }
  }

  // The result of something that finished, shown on the home screen where the
  // person is about to look anyway. It used to be a toast plus a jump to the
  // collaborators list: the toast faded while they were reading the table, and
  // the table does not say what just happened, only what is true now.
  function showHomeResult(title, lines, level) {
    var host = el("homeResult");
    host.className = "banner " + (level === "warn" ? "" : "done");
    el("homeResultTitle").textContent = title;
    el("homeResultBody").innerHTML = (lines || []).filter(function (l) { return l; })
      .map(function (l) { return "<div>" + esc(l) + "</div>"; }).join("");
    host.hidden = false;
    showView("home");
    host.scrollIntoView({ block: "nearest" });
  }

  function clearHomeResult() { el("homeResult").hidden = true; }

  function finishInvite(data, statusId, doneMessage) {
    var g = data.guest || {};
    var until = g.expiresOnLabel || g.expiresOn || "";
    var headline = data.simulated
      ? "Simulation mode is on, so nothing was actually done."
      : doneMessage.replace("{name}", g.displayName || "They").replace("{until}", until);
    var lines = [];
    if (data.simulated) {
      lines.push((g.displayName || "They") + " would have been set up until " + until + ".");
    }
    else if (g.email) {
      lines.push(g.email + (until ? ", until " + until : ""));
    }
    (data.warnings || []).forEach(function (w) { lines.push(w); });

    setStatus(statusId, "");
    // The list is still refreshed, so it is correct the moment they open it.
    return loadGuests().then(function () {
      return sendPendingMail(data.outbox, lines);
    }).then(function () {
      showHomeResult(headline, lines, (data.warnings || []).length ? "warn" : "done");
    });
  }

  function sendInvitation() {
    var btn = el("invSend");
    btn.disabled = true;
    setStatus("invSendStatus", "Inviting...");
    api("/guests", "POST", {
      email: el("invSearch").value.trim(),
      displayName: el("invName").value.trim(),
      reason: el("invReason").value.trim(),
      days: Number(el("invDays").value)
    }).then(function (data) {
      return finishInvite(data, "invSendStatus", "{name} has been invited. Their access runs until {until}.");
    }).catch(function (e) {
      btn.disabled = false;
      setStatus("invSendStatus", e.message, "bad");
      // A 409 means somebody else created them between the check and the send.
      // Re-running the check replaces the form with the real situation rather
      // than leaving a Send button that can never work.
      if (e.status === 409) { checkAddress(); }
    });
  }

  function claimGuest(guestId) {
    var btn = el("invClaim");
    btn.disabled = true;
    setStatus("invClaimStatus", "Saving...");
    api("/guests/" + encodeURIComponent(guestId) + "/action", "POST", {
      action: "claim",
      reason: el("invClaimReason").value.trim(),
      days: Number(el("invClaimDays").value)
    }).then(function (data) {
      return finishInvite(data, "invClaimStatus", "{name} is now on your list, with access until {until}.");
    }).catch(function (e) {
      btn.disabled = false;
      setStatus("invClaimStatus", e.message, "bad");
    });
  }

  function askOwner(guestId) {
    var btn = el("invAsk");
    btn.disabled = true;
    setStatus("invAskStatus", "Sending...");
    api("/guests/" + encodeURIComponent(guestId) + "/action", "POST", {
      action: "ask",
      message: el("invAskMessage").value.trim()
    }).then(function (data) {
      return sendPendingMail(data.outbox, []).then(function () {
        showHomeResult(data.message || "Message sent.", [], "done");
      });
    }).catch(function (e) {
      btn.disabled = false;
      setStatus("invAskStatus", e.message, "bad");
    });
  }

  function wireGuests() {
    el("guestsInvite").onclick = startInvite;
    el("guestsRefresh").onclick = loadGuests;
    el("homeResultDismiss").onclick = clearHomeResult;
    document.querySelectorAll("[data-drawer-close]").forEach(function (b) { b.onclick = closeGuest; });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !el("guestDrawer").hidden) { closeGuest(); }
    });
    if (el("guestsAll")) { el("guestsAll").onchange = loadGuests; }
    el("invCheck").onclick = checkAddress;
    el("invSearch").addEventListener("input", scheduleSearch);
    el("invSearch").addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !el("invCheck").disabled) { e.preventDefault(); checkAddress(); }
    });
  }

  /* ---------------- sharing ---------------- */

  var ICONS = {
    folder: "📁", site: "🏢", drive: "🗂️", doc: "📄",
    sheet: "📊", slide: "📽️", pdf: "📕", image: "🖼️",
    media: "🎬", zip: "🗜️", code: "🧩", text: "📃",
    file: "📄", team: "👥"
  };

  var SHARE_STEPS = ["What", "Who", "Confirm"];

  // recipient, when given, is a collaborator already chosen elsewhere (the
  // drawer's Share button). The "who" step is then skipped entirely.
  function startShare(mode, recipient) {
    clearHomeResult();
    state.share = {
      mode: mode, step: 0, target: null, recipient: recipient || null, newGuest: null,
      lockedRecipient: !!recipient, crumb: [], pane: mode === "teams" ? "teams" : "recent"
    };
    el("shPerson").value = "";
    el("shMatches").innerHTML = "";
    el("shNewGuest").innerHTML = "";
    el("shMessage").value = "";
    el("shCrumb").innerHTML = "";
    el("shItems").innerHTML = "";
    el("shError").hidden = true;
    el("shError").innerHTML = "";
    state.share.siteId = ""; state.share.siteUrl = "";
    setStatus("shWhoStatus", "");
    setStatus("shStatus", "");
    showView("share");
    renderShareStep();
  }

  function renderShareStep() {
    var s = state.share;
    // With the person already chosen there are two steps, not three, and the
    // indicator should say so rather than showing a step nobody will see.
    var labels = s.lockedRecipient ? ["What", "Confirm"] : SHARE_STEPS;
    var shown = s.lockedRecipient ? (s.step === 0 ? 0 : 1) : s.step;
    el("shSteps").innerHTML = labels.map(function (label, i) {
      return '<span class="step' + (i === shown ? " active" : "") + '">' + (i + 1) + ". " + esc(label) + "</span>";
    }).join(" ");
    el("shPick").hidden = s.step !== 0;
    el("shWho").hidden = s.step !== 1;
    el("shConfirm").hidden = s.step !== 2;
    el("shBack").hidden = s.step === 0;

    if (s.step === 0) {
      el("shPickTitle").textContent = s.mode === "teams" ? "Choose a Team" : "Choose a " + shareLabel();
      el("shPickIntro").textContent = s.mode === "teams"
        ? "Only Teams you own, and only those that accept guests."
        : "You will only see what you can already open yourself." +
        (shareLabel() === "folder" ? " Only folders can be shared here; open one to look inside." : "");
      el("shSearchWrap").hidden = s.mode === "teams";
      if (s.mode === "teams") { loadTeams(); } else { renderPanes(); loadPane(s.pane); }
    } else if (s.step === 1) {
      el("shChosen").textContent = (s.target ? s.target.name : "");
      el("shPerson").focus();
    } else {
      renderShareSummary();
    }
  }

  function renderPanes() {
    var s = state.share;
    var panes = [["recent", "Recent"], ["mydrive", "My files"], ["sites", "Sites"]];
    el("shPanes").innerHTML = panes.map(function (p) {
      return '<button type="button" class="btn small' + (s.pane === p[0] && !s.crumb.length ? " primary" : " ghost") +
        '" data-pane="' + p[0] + '">' + esc(p[1]) + "</button>";
    }).join(" ");
    el("shPanes").querySelectorAll("[data-pane]").forEach(function (b) {
      b.onclick = function () {
        state.share.crumb = [];
        state.share.pane = b.dataset.pane;
        el("shSearch").value = "";
        renderPanes();
        loadPane(b.dataset.pane);
      };
    });
  }

  function renderCrumb() {
    var s = state.share;
    var host = el("shCrumb");
    if (!s.crumb.length) { host.innerHTML = ""; return; }
    host.innerHTML = s.crumb.map(function (c, i) {
      return '<button type="button" class="linkish" data-crumb="' + i + '">' + esc(c.name) + "</button>";
    }).join(" / ");
    host.querySelectorAll("[data-crumb]").forEach(function (b) {
      b.onclick = function () {
        var i = Number(b.dataset.crumb);
        var entry = state.share.crumb[i];
        state.share.crumb = state.share.crumb.slice(0, i);
        openContainer(entry, true);
      };
    });
  }

  function loadPane(pane, extra) {
    var query = "?pane=" + encodeURIComponent(pane);
    Object.keys(extra || {}).forEach(function (k) {
      if (extra[k]) { query += "&" + k + "=" + encodeURIComponent(extra[k]); }
    });
    setStatus("shPickStatus", "Loading...");
    el("shItems").innerHTML = "";
    el("shCrumb").innerHTML = "";
    el("shError").hidden = true;
    return api("/browse" + query).then(function (data) {
      setStatus("shPickStatus", "");
      renderPickItems(data.items || [], data.emptyReason);
    }).catch(function (e) {
      setStatus("shPickStatus", "");
      el("shItems").innerHTML = errorHtml(e) +
        '<p><button type="button" class="btn small ghost" id="shPickBackToSites">Back to the site list</button></p>';
      wireCopyButtons(el("shItems"));
      el("shPickBackToSites").onclick = function () {
        state.share.crumb = [];
        renderPanes();
        loadPane("sites");
      };
    });
  }

  function renderPickItems(items, emptyReason) {
    var host = el("shItems");
    renderCrumb();

    // A site known to refuse external sharing, either because SharePoint said so
    // when the list was built or because it refused a share earlier. Said before
    // anything is picked, rather than after a guest has been created for it.
    var s = state.share;
    var known = s.siteUrl && siteSettingsCache()[s.siteUrl];
    if (known && known.known && !truthy(known.canShareExternally) && s.siteId && !blockedSites()[s.siteId]) {
      blockedSites()[s.siteId] = known.reason || "SharePoint does not allow external sharing here.";
    }
    var blocked = s.siteId && blockedSites()[s.siteId];
    if (blocked) {
      host.innerHTML = '<div class="banner error"><div><div class="title">This site does not allow external sharing</div>' +
        '<div class="small">' + esc(blocked) + " Nothing here can be shared outside the company. " +
        "The person who owns the site can change that in SharePoint.</div>" +
        '<div class="row" style="margin-top:10px"><button type="button" class="btn small" id="shPickLeaveSite">Choose somewhere else</button>' +
        '<button type="button" class="btn small ghost" id="shPickAnyway">Look anyway</button></div></div></div>';
      el("shPickLeaveSite").onclick = function () {
        s.crumb = []; s.siteId = ""; renderPanes(); loadPane("sites");
      };
      el("shPickAnyway").onclick = function () { delete blockedSites()[s.siteId]; renderPickItems(items, emptyReason); };
      return;
    }
    if (!items.length) {
      host.innerHTML = '<p class="muted small">' + esc(emptyReason || "Nothing here.") + "</p>";
      return;
    }
    // A note that applies to a list that is not empty: sites dropped for no
    // longer existing, for instance.
    var note = emptyReason ? '<p class="small muted">' + esc(emptyReason) + "</p>" : "";
    // A folder is both a place to go into and a thing that can be shared, so it
    // gets two separate controls rather than one ambiguous click. The row is a
    // container, never a button, so the controls inside stay real buttons and
    // keyboard navigation works.
    host.innerHTML = note + items.map(function (it, i) {
      var openable = it.kind === "folder" || it.kind === "site" || it.kind === "drive";
      // What it is, where it lives, and when it was last touched. A column of
      // twenty file names is not enough to pick from: half of them are called
      // "Proposal" and the icon is eight pixels of guesswork.
      var facts = [it.category, it.path, it.whenLabel].filter(function (f) { return f; });
      var main = '<button type="button" class="pick-main" data-open="' + i + '"' +
        (openable || it.canShare ? "" : " disabled") + ">" +
        '<span class="icon-cell">' + (ICONS[it.icon] || ICONS.file) + "</span>" +
        "<span><strong>" + esc(it.name) + "</strong>" +
        // Filled in when SharePoint answers for this site, which is after the
        // list is already usable.
        (it.kind === "site" ? '<span data-site-note="' + esc(it.webUrl) + '"></span>' : "") +
        (facts.length ? '<br><span class="small muted">' + esc(facts.join(" · ")) + "</span>" : "") +
        "</span></button>";
      // Opening the real thing in a new tab is how somebody checks they picked
      // the right file. It is a link, not a click on the row, so it never
      // competes with choosing.
      var peek = "";
      var url = safeUrl(it.webUrl);
      if (url) {
        peek = '<a class="pick-peek" href="' + esc(url) + '" target="_blank" rel="noopener noreferrer" ' +
          'title="Open in a new tab">Open ↗</a>';
      }
      // A file used to have no button at all: clicking the row worked, but a
      // folder next to it showing "Share this folder" made that look deliberate.
      var action = "";
      if (it.canShare && openable) {
        action = '<button type="button" class="btn small ghost" data-share="' + i + '">Share this folder</button>';
      } else if (it.canShare) {
        action = '<button type="button" class="btn small ghost" data-share="' + i + '">Share this file</button>';
      } else if (!openable) {
        action = '<span class="small muted">' + esc(it.shareBlockedReason || "not available") + "</span>";
      }
      return '<div class="pick-row">' + main + peek + action + "</div>";
    }).join("");

    loadSiteSettings(items);

    host.querySelectorAll("[data-open]").forEach(function (b) {
      b.onclick = function () {
        var it = items[Number(b.dataset.open)];
        if (it.kind === "folder" || it.kind === "site" || it.kind === "drive") { openContainer(it); }
        else if (it.canShare) { chooseTarget({ kind: "file", driveId: it.driveId, itemId: it.id, name: it.name, webUrl: it.webUrl }); }
      };
    });
    host.querySelectorAll("[data-share]").forEach(function (b) {
      b.onclick = function () {
        var it = items[Number(b.dataset.share)];
        var kind = (it.kind === "folder" || it.kind === "site" || it.kind === "drive") ? "folder" : "file";
        chooseTarget({ kind: kind, driveId: it.driveId, itemId: it.id, name: it.name, webUrl: it.webUrl });
      };
    });
  }

  /* --- what SharePoint says about a site ---
     Read lazily, one request per site, after the list is already on screen. The
     list must never wait for this: a tenant with thirty followed sites would
     take thirty round trips to show anything. */

  function siteSettingsCache() {
    if (!state.siteSettings) { state.siteSettings = {}; }
    return state.siteSettings;
  }

  function loadSiteSettings(items) {
    var cache = siteSettingsCache();
    var pending = items.filter(function (it) {
      return it.kind === "site" && safeUrl(it.webUrl) && !cache[it.webUrl];
    });
    if (!pending.length) { return; }

    // Four at a time. Enough to feel instant on a normal list, few enough that a
    // hundred sites do not open a hundred sockets.
    var next = 0;
    function pump() {
      if (next >= pending.length) { return; }
      var it = pending[next++];
      api("/browse?pane=siteinfo&q=" + encodeURIComponent(it.webUrl))
        .then(function (data) { cache[it.webUrl] = data.siteSettings || { known: false }; })
        .catch(function () { cache[it.webUrl] = { known: false }; })
        .then(function () { annotateSiteRow(it); pump(); });
    }
    for (var i = 0; i < 4; i++) { pump(); }
  }

  function annotateSiteRow(item) {
    var info = siteSettingsCache()[item.webUrl];
    var host = document.querySelector('[data-site-note="' + cssEscape(item.webUrl) + '"]');
    if (!host || !info || !info.known) { return; }
    if (truthy(info.canShareExternally)) { return; }
    host.innerHTML = ' <span class="pill warn">no external sharing</span>';
    host.title = info.reason || "";
  }

  // Attribute selectors need the value escaped; a SharePoint URL is full of
  // characters CSS treats as syntax.
  function cssEscape(v) {
    return String(v).replace(/["\\]/g, "\\$&");
  }

  // Sites that have already refused an external share, for this session.
  // SharePoint's per-site external sharing setting is not readable through the
  // permissions this tool holds, so the earliest we can know is the first
  // refusal. After that, nobody should have to find out twice.
  function blockedSites() {
    if (!state.blockedSites) { state.blockedSites = {}; }
    return state.blockedSites;
  }

  function openContainer(entry, isCrumb) {
    var s = state.share;
    if (entry.kind === "site") { s.siteId = entry.id; s.siteName = entry.name; s.siteUrl = entry.webUrl; }
    if (!isCrumb) { s.crumb.push(entry); }
    var extra = entry.kind === "site"
      ? { siteId: entry.id }
      : { driveId: entry.driveId || entry.id, itemId: entry.kind === "drive" ? "" : entry.id };
    loadPane("children", extra);
  }

  function loadTeams() {
    setStatus("shPickStatus", "Loading your Teams...");
    el("shItems").innerHTML = "";
    el("shPanes").innerHTML = "";
    return api("/teams").then(function (data) {
      setStatus("shPickStatus", data.tenantAllowsGuests ? "" : "This tenant does not allow guests in Teams.", data.tenantAllowsGuests ? "" : "bad");
      var items = data.items || [];
      if (!items.length) {
        // The API distinguishes "you own nothing", "none of them are Teams" and
        // "we could not tell", because those need different things done.
        el("shItems").innerHTML = '<p class="muted small">' +
          esc(data.emptyReason || "You do not own any Teams.") + "</p>";
        return;
      }
      el("shItems").innerHTML = items.map(function (t, i) {
        return '<button type="button" class="match" data-team="' + i + '"' + (t.canShare ? "" : " disabled") + ">" +
          '<span><span class="icon-cell">' + ICONS.team + "</span> <strong>" + esc(t.name) + "</strong>" +
          (t.description ? '<br><span class="small muted">' + esc(t.description) + "</span>" : "") + "</span>" +
          '<span class="small muted">' + esc(t.canShare ? "Add a guest" : t.shareBlockedReason) + "</span></button>";
      }).join("");
      el("shItems").querySelectorAll("[data-team]").forEach(function (b) {
        b.onclick = function () {
          var t = items[Number(b.dataset.team)];
          chooseTarget({ kind: "team", teamId: t.id, name: t.name });
        };
      });
    }).catch(function (e) { setStatus("shPickStatus", e.message, "bad"); });
  }

  function chooseTarget(target) {
    state.share.target = target;
    state.share.step = state.share.lockedRecipient ? 2 : 1;
    renderShareStep();
  }

  /* --- step 2: who, search first --- */

  var sharePersonTimer = null;
  function sharePersonInput() {
    var term = el("shPerson").value.trim();
    el("shNewGuest").innerHTML = "";
    setStatus("shWhoStatus", "");
    if (sharePersonTimer) { clearTimeout(sharePersonTimer); }
    if (term.length < 2) { el("shMatches").innerHTML = ""; return; }
    sharePersonTimer = setTimeout(function () {
      api("/guests?search=" + encodeURIComponent(term)).then(function (data) {
        var items = data.items || [];
        var exact = items.filter(function (g) { return String(g.email).toLowerCase() === term.toLowerCase(); });
        renderSharePersonMatches(items);
        // Only after a search has actually run, and only when nothing here is
        // the person, is inviting somebody new offered at all.
        if (looksLikeEmail(term) && !exact.length) { offerNewRecipient(term); }
      }).catch(function (e) { setStatus("shWhoStatus", e.message, "bad"); });
    }, 350);
  }

  function renderSharePersonMatches(items) {
    var host = el("shMatches");
    if (!items.length) { host.innerHTML = '<p class="small muted">Nobody we already work with matches that.</p>'; return; }
    host.innerHTML = '<p class="small muted matches-title">People we already work with:</p>' +
      items.map(function (g) {
        var who = g.mine ? "yours" : (g.owner && g.owner.displayName ? esc(g.owner.displayName) + "&rsquo;s" : "no owner");
        return '<button type="button" class="match" data-email="' + esc(g.email) + '" data-id="' + esc(g.id) + '"' +
          (g.tracked ? "" : " disabled") + ">" +
          "<span><strong>" + esc(g.displayName) + "</strong><br>" +
          '<span class="small muted">' + esc(g.email) + "</span></span>" +
          '<span class="small muted">' + (g.tracked ? who : "not set up here yet") + "</span></button>";
      }).join("");
    host.querySelectorAll(".match").forEach(function (b) {
      b.onclick = function () {
        state.share.recipient = { id: b.dataset.id, email: b.dataset.email, displayName: b.querySelector("strong").textContent };
        state.share.newGuest = null;
        state.share.step = 2;
        renderShareStep();
      };
    });
  }

  function offerNewRecipient(email) {
    setStatus("shWhoStatus", "Checking " + email + "...");
    api("/guests?email=" + encodeURIComponent(email)).then(function (v) {
      setStatus("shWhoStatus", "");
      var host = el("shNewGuest");
      if (v.verdict === "notFound" && v.canInvite) {
        var policy = state.me.policy;
        host.innerHTML = '<div class="card"><h3>Invite ' + esc(email) + "</h3>" +
          '<p class="small muted">They will be set up as an external collaborator owned by you, with an end date, and given access to this in the same step.</p>' +
          field("shgName", "Their name", '<input id="shgName" type="text" maxlength="120" />') +
          field("shgReason", "Why do you need to work with them?" + (policy.requireReason ? "" : " (optional)"),
            '<textarea id="shgReason" maxlength="400" rows="2"></textarea>') +
          field("shgDays", "For how many days", '<input id="shgDays" type="number" min="1" max="' + esc(policy.maxDays) +
            '" value="' + esc(policy.defaultDays) + '" />') +
          '<button id="shgNext" class="btn primary">Continue</button></div>';
        el("shgNext").onclick = function () {
          state.share.newGuest = {
            email: email,
            displayName: el("shgName").value.trim(),
            reason: el("shgReason").value.trim(),
            days: Number(el("shgDays").value)
          };
          state.share.recipient = { id: "", email: email, displayName: el("shgName").value.trim() || email };
          state.share.step = 2;
          renderShareStep();
        };
      } else if (v.guest && v.guest.id && (v.verdict === "mine" || v.verdict === "other" || v.verdict === "unowned")) {
        // They exist after all. Use that account: this is exactly the duplicate
        // the search step is here to prevent.
        host.innerHTML = '<p class="status">' + esc(v.message) + "</p>";
        state.share.recipient = { id: v.guest.id, email: v.guest.email, displayName: v.guest.displayName };
        state.share.newGuest = null;
        var go = document.createElement("button");
        go.className = "btn primary";
        go.textContent = "Share with " + (v.guest.displayName || v.guest.email);
        go.onclick = function () { state.share.step = 2; renderShareStep(); };
        host.appendChild(go);
      } else {
        host.innerHTML = '<p class="status bad">' + esc(v.inviteBlockedReason || v.message) + "</p>";
      }
    }).catch(function (e) { setStatus("shWhoStatus", e.message, "bad"); });
  }

  /* --- step 3: confirm --- */

  function renderShareSummary() {
    var s = state.share;
    var caps = state.me.capabilities;
    var isTeam = s.target.kind === "team";
    el("shRoleWrap").hidden = isTeam;
    if (!caps.allowWrite) {
      el("shRole").value = "read";
      el("shRole").disabled = true;
    } else {
      el("shRole").value = caps.defaultRole || "read";
    }
    el("shSummary").innerHTML =
      '<p><strong>' + esc(s.target.name) + "</strong>" +
      '<br><span class="small muted">' + esc(isTeam ? "Team" : s.target.kind) + "</span></p>" +
      "<p><strong>" + esc(s.recipient.displayName || s.recipient.email) + "</strong>" +
      '<br><span class="small muted">' + esc(s.recipient.email) +
      (s.newGuest ? " - will be invited now" : " - already works with us") + "</span></p>";
    el("shGo").textContent = isTeam ? "Add to the Team" : "Share";
  }

  function doShare() {
    var s = state.share;
    el("shGo").disabled = true;
    setStatus("shStatus", "Working...");
    var body = {
      target: s.target,
      role: el("shRole").value,
      message: el("shMessage").value.trim()
    };
    if (s.newGuest) { body.newGuest = s.newGuest; } else { body.guestId = s.recipient.id; }
    if (s.siteId) { body.target = Object.assign({}, s.target, { siteId: s.siteId }); }

    el("shError").hidden = true;
    api("/share", "POST", body).then(function (data) {
      var lines = [];
      if (s.target && s.target.name) { lines.push(s.target.name); }
      (data.warnings || []).forEach(function (w) { lines.push(w); });
      return loadGuests()
        .then(function () { return sendPendingMail(data.outbox, lines); })
        .then(function () {
          showHomeResult(data.message || "Shared.", lines, (data.warnings || []).length ? "warn" : "done");
        });
    }).catch(function (e) {
      el("shGo").disabled = false;
      setStatus("shStatus", "");
      el("shError").innerHTML = errorHtml(e);
      el("shError").hidden = false;
      wireCopyButtons(el("shError"));
      // Remember a site that refuses external sharing, so the next visit says so
      // before anything is picked.
      if (e.data && e.data.sitePolicy) {
        var id = e.data.siteId || s.siteId;
        if (id) { blockedSites()[id] = "SharePoint refused a share from here on " + new Date().toLocaleDateString() + "."; }
      }
      // The guest exists but the share did not happen. Offer the share alone,
      // so nobody is tempted to start again and invite the same person twice.
      if (e.data && e.data.guestCreated && e.data.guest && e.data.guest.id) {
        state.share.newGuest = null;
        state.share.recipient = { id: e.data.guest.id, email: e.data.guest.email, displayName: e.data.guest.displayName };
        toast(e.data.guest.displayName + " was set up, but the share itself failed. Press Share to try just the share again.", "bad");
        renderShareSummary();
      }
    });
  }

  function wireShare() {
    el("shBack").onclick = function () {
      var s = state.share;
      // Back from the confirmation returns to the picker when the person was
      // fixed on the way in: there is no "who" step to go back to.
      if (s.step === 2 && s.lockedRecipient) { s.step = 0; renderShareStep(); return; }
      if (s.step > 0) { s.step -= 1; renderShareStep(); }
    };
    el("shGo").onclick = doShare;
    el("shPerson").addEventListener("input", sharePersonInput);
    el("shSearch").addEventListener("input", function () {
      var term = el("shSearch").value.trim();
      if (sharePersonTimer) { clearTimeout(sharePersonTimer); }
      if (term.length < 2) { return; }
      sharePersonTimer = setTimeout(function () {
        state.share.crumb = [];
        loadPane("search", { q: term });
      }, 350);
    });
  }

  /* ---------------- configuration ---------------- */

  function loadConfig(force) {
    if (state.config && !force) { return Promise.resolve(state.config); }
    return api("/config").then(function (data) {
      state.config = data;
      renderConfig();
      return data;
    }).catch(function (e) {
      toast(e.message, "bad");
      throw e;
    });
  }

  function listToText(list) { return (list || []).join(", "); }
  function textToList(text) {
    return String(text || "").split(/[,;\n]/).map(function (s) { return s.trim(); }).filter(Boolean);
  }

  function renderConfig() {
    var s = state.config.settings;

    var attr = el("cfgAttribute");
    if (!attr.options.length) {
      (state.config.expiryAttributes || []).forEach(function (a) {
        var o = document.createElement("option");
        o.value = a; o.textContent = a;
        attr.appendChild(o);
      });
    }

    el("cfgDefaultDays").value = s.expiry.defaultDays;
    el("cfgMaxDays").value = s.expiry.maxDays;
    el("cfgRenewDays").value = s.expiry.renewDays;
    el("cfgGraceDays").value = s.expiry.graceDays;
    el("cfgReminderDays").value = listToText(s.expiry.reminderDays);
    attr.value = s.expiry.attribute;
    el("cfgAllowSelfRenew").checked = truthy(s.expiry.allowSelfRenew);

    el("cfgInviterGroupId").value = s.invite.inviterGroupId || "";
    el("cfgInviterGroupName").value = s.invite.inviterGroupName || "";
    el("cfgAllowedDomains").value = listToText(s.invite.allowedDomains);
    el("cfgBlockedDomains").value = listToText(s.invite.blockedDomains);
    el("cfgVisibility").value = s.invite.guestDirectoryVisibility;
    el("cfgRequireReason").checked = truthy(s.invite.requireReason);
    el("cfgSetSponsor").checked = truthy(s.invite.setSponsor);

    el("cfgShareFiles").checked = truthy(s.sharing.files);
    el("cfgShareFolders").checked = truthy(s.sharing.folders);
    el("cfgShareTeams").checked = truthy(s.sharing.teams);
    el("cfgAllowWrite").checked = truthy(s.sharing.allowWrite);

    el("cfgAdoptionEnabled").checked = truthy(s.adoption.enabled);
    el("cfgAdoptionDays").value = s.adoption.initialDays;
    el("cfgAdoptionSponsors").checked = truthy(s.adoption.useSponsors);
    el("cfgAdoptionAudit").checked = truthy(s.adoption.useAuditLog);

    el("cfgInactivityEnabled").checked = truthy(s.inactivity.enabled);
    el("cfgInactivityDays").value = s.inactivity.thresholdDays;
    // 'delete' is still accepted by the API for configurations written before
    // deletion was routed through the grace period, but it behaves exactly like
    // 'block', so the editor offers only the two options that differ.
    el("cfgInactivityAction").value = s.inactivity.action === "delete" ? "block" : s.inactivity.action;
    el("cfgInactivityOnce").checked = truthy(s.inactivity.notifyOnce);

    el("cfgSafetyEnabled").checked = truthy(s.safety.enabled);
    el("cfgCapInvite").value = s.safety.dailyCapInvite;
    el("cfgCapPerUser").value = s.safety.perUserDailyInvites;
    el("cfgCapBlock").value = s.safety.dailyCapBlock;
    el("cfgCapDelete").value = s.safety.dailyCapDelete;
    el("cfgCeiling").value = s.safety.percentCeiling;

    el("cfgDryRun").value = truthy(s.dryRun) ? "true" : "false";
    el("cfgServicedesk").value = s.notifications.servicedeskEmail || "";

    // The sending mailbox is deliberately not editable here, and saying so where
    // somebody would otherwise go looking is the whole point of showing it.
    var sender = state.config.sender || {};
    el("cfgSender").value = sender.address || "(not configured)";
    el("cfgSenderNote").innerHTML = esc(sender.note || "") +
      (sender.docsUrl ? ' <a href="' + esc(safeUrl(sender.docsUrl)) + '" target="_blank" rel="noopener noreferrer">How to re-run the deployment</a>.' : "");

    renderAdminAccess();
    el("cfgLogRetention").value = s.logRetentionDays;
    el("cfgNotifyRedeem").checked = truthy(s.notifications.notifyOwnerOnRedeem);
    el("cfgOrphanDigest").checked = truthy(s.notifications.orphanDigest);

    renderWarnings(state.config.warnings);
  }

  function renderWarnings(warnings) {
    var host = el("cfgWarnings");
    host.innerHTML = "";
    (warnings || []).forEach(function (w) {
      var d = document.createElement("div");
      d.className = "banner";
      d.innerHTML = '<div class="small">' + esc(w.message) + "</div>";
      host.appendChild(d);
    });
  }

  // Collect the whole settings object from the form. The server sanitises
  // everything again, so this only has to be a faithful read of what the admin
  // typed, not a validator.
  function collectSettings() {
    var s = JSON.parse(JSON.stringify(state.config.settings));

    s.expiry.defaultDays = Number(el("cfgDefaultDays").value);
    s.expiry.maxDays = Number(el("cfgMaxDays").value);
    s.expiry.renewDays = Number(el("cfgRenewDays").value);
    s.expiry.graceDays = Number(el("cfgGraceDays").value);
    s.expiry.reminderDays = textToList(el("cfgReminderDays").value).map(Number);
    s.expiry.attribute = el("cfgAttribute").value;
    s.expiry.allowSelfRenew = el("cfgAllowSelfRenew").checked;

    s.invite.inviterGroupId = el("cfgInviterGroupId").value.trim();
    s.invite.inviterGroupName = el("cfgInviterGroupName").value.trim();
    s.invite.allowedDomains = textToList(el("cfgAllowedDomains").value);
    s.invite.blockedDomains = textToList(el("cfgBlockedDomains").value);
    s.invite.guestDirectoryVisibility = el("cfgVisibility").value;
    s.invite.requireReason = el("cfgRequireReason").checked;
    s.invite.setSponsor = el("cfgSetSponsor").checked;

    s.sharing.files = el("cfgShareFiles").checked;
    s.sharing.folders = el("cfgShareFolders").checked;
    s.sharing.teams = el("cfgShareTeams").checked;
    s.sharing.allowWrite = el("cfgAllowWrite").checked;

    s.adoption.enabled = el("cfgAdoptionEnabled").checked;
    s.adoption.initialDays = Number(el("cfgAdoptionDays").value);
    s.adoption.useSponsors = el("cfgAdoptionSponsors").checked;
    s.adoption.useAuditLog = el("cfgAdoptionAudit").checked;

    s.inactivity.enabled = el("cfgInactivityEnabled").checked;
    s.inactivity.thresholdDays = Number(el("cfgInactivityDays").value);
    s.inactivity.action = el("cfgInactivityAction").value;
    s.inactivity.notifyOnce = el("cfgInactivityOnce").checked;

    s.safety.enabled = el("cfgSafetyEnabled").checked;
    s.safety.dailyCapInvite = Number(el("cfgCapInvite").value);
    s.safety.perUserDailyInvites = Number(el("cfgCapPerUser").value);
    s.safety.dailyCapBlock = Number(el("cfgCapBlock").value);
    s.safety.dailyCapDelete = Number(el("cfgCapDelete").value);
    s.safety.percentCeiling = Number(el("cfgCeiling").value);

    s.dryRun = el("cfgDryRun").value === "true";
    s.notifications.servicedeskEmail = el("cfgServicedesk").value.trim();
    s.logRetentionDays = Number(el("cfgLogRetention").value);
    s.notifications.notifyOwnerOnRedeem = el("cfgNotifyRedeem").checked;
    s.notifications.orphanDigest = el("cfgOrphanDigest").checked;

    return s;
  }

  function saveSettings(settings, statusId, okMessage) {
    setStatus(statusId, "Saving...");
    return api("/config", "POST", { settings: settings }).then(function (data) {
      state.config = data;
      renderConfig();
      // A save that changed nothing is worth saying out loud: somebody who
      // believes they just flipped a switch needs to know it was already that
      // way, not be told "saved" and left wondering why nothing happened.
      setStatus(statusId, data.changed === 0 ? "Nothing to save: that is already how it is set." : (okMessage || "Saved."),
        data.changed === 0 ? "" : "ok");
      if (data.publishWarning) { toast(data.publishWarning, "bad"); }
      return loadMe();
    }).catch(function (e) {
      setStatus(statusId, e.message, "bad");
      throw e;
    });
  }

  /* ---------------- branding editor ---------------- */

  function renderBranding() {
    var s = state.config.settings;
    el("brCompany").value = s.branding.companyName;
    el("brTitle").value = s.branding.portalTitle;
    el("brSubtitle").value = s.branding.portalSubtitle;
    el("brPrimary").value = s.branding.primaryColor;
    el("brPrimaryText").value = s.branding.primaryColor;
    el("brAccent").value = s.branding.accentColor;
    el("brAccentText").value = s.branding.accentColor;

    renderLogoPreview();

    el("wcHeadline").value = s.welcome.headline;
    el("wcMessage").value = s.welcome.message;
    el("wcButton").value = s.welcome.buttonLabel;
    el("wcHosts").value = (s.welcome.extraAllowedHosts || []).join("\n");
    el("wcAuto").checked = truthy(s.welcome.autoRedirect);
    el("wcAllowed").textContent = (state.config.allowedHosts || []).join(", ");

    var link = el("wcLink");
    if (state.config.welcomeUrl && s.welcome.publishedUtc) {
      link.href = state.config.welcomeUrl + "/welcome.html";
      link.textContent = state.config.welcomeUrl + "/welcome.html";
    } else {
      link.removeAttribute("href");
      link.textContent = "not published yet";
    }
  }

  // Nothing on this tab takes effect until Save, the logo included. It used to
  // upload and apply the moment a file was chosen, then re-read every field from
  // the server: an admin who had typed a new company name first watched it
  // revert, and a change they had not asked for went live. One rule now, for the
  // whole tab.
  function renderLogoPreview() {
    var img = el("brLogoPreview");
    var note = el("brLogoPending");
    var pending = state.pendingLogo;

    if (pending === null) {                       // marked for removal
      img.hidden = true;
      note.hidden = false;
      note.className = "status";
      note.textContent = "The logo will be removed when you save.";
      return;
    }
    if (pending) {                                // chosen, not saved
      img.src = pending;
      img.hidden = false;
      note.hidden = false;
      note.className = "status";
      note.textContent = "Preview only. This is uploaded when you save.";
      return;
    }
    var logo = state.me && state.me.branding ? state.me.branding.logoUrl : "";
    if (logo) { img.src = logo; img.hidden = false; } else { img.hidden = true; }
    note.hidden = true;
    note.textContent = "";
  }

  function renderAdminAccess() {
    var a = state.config.adminAccess || {};
    var app = a.app || {};
    var host = el("cfgAdminAccess");

    function linked(label, url) {
      var safe = safeUrl(url);
      return safe
        ? '<a href="' + esc(safe) + '" target="_blank" rel="noopener noreferrer">' + esc(label) + " ↗</a>"
        : esc(label);
    }

    var who = (a.assignments || []).map(function (x) {
      return '<div class="access-row"><span class="icon-cell">' + (x.type === "Group" ? "👥" : "👤") + "</span>" +
        '<span class="grow"><strong>' + linked(x.displayName || x.id, x.portalUrl) + "</strong><br>" +
        '<span class="small muted">' + esc(x.type || "") + " · " + esc(x.id) + "</span></span></div>";
    }).join("");

    host.innerHTML =
      '<div class="facts" style="margin-bottom:14px">' +
      '<div class="fact"><div class="k">Enterprise application</div><div class="v">' +
      linked(app.displayName || "(unknown)", app.portalUrl) + "</div></div>" +
      '<div class="fact"><div class="k">Application (client) id</div><div class="v small">' + esc(app.appId || "") + "</div></div>" +
      "</div>" +
      "<h3 style=\"font-size:14px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em\">Holds " +
      esc(a.role || "the admin role") + "</h3>" +
      (who ? '<div class="access-list">' + who + "</div>" : "") +
      (a.error ? '<p class="status bad small">' + esc(a.error) + "</p>" : "");
  }

  function collectBranding() {
    var s = collectSettings();
    s.branding.companyName = el("brCompany").value.trim();
    s.branding.portalTitle = el("brTitle").value.trim();
    s.branding.portalSubtitle = el("brSubtitle").value.trim();
    s.branding.primaryColor = el("brPrimary").value;
    s.branding.accentColor = el("brAccent").value;
    s.welcome.headline = el("wcHeadline").value.trim();
    s.welcome.message = el("wcMessage").value.trim();
    s.welcome.buttonLabel = el("wcButton").value.trim();
    s.welcome.extraAllowedHosts = textToList(el("wcHosts").value);
    s.welcome.autoRedirect = el("wcAuto").checked;
    return s;
  }

  function wireBrandingEditor() {
    // Live preview of the colours while picking, so the admin sees the result
    // before saving rather than after.
    function syncColour(picker, text, cssVar) {
      picker.addEventListener("input", function () {
        text.value = picker.value;
        document.documentElement.style.setProperty(cssVar, picker.value);
        document.documentElement.style.setProperty(cssVar === "--brand-primary" ? "--brand-on-primary" : "--brand-on-accent", readableOn(picker.value));
        // The link colour is derived from BOTH pickers, so it has to be
        // recomputed whichever one moved, or the preview lies about what the
        // pair will look like together.
        document.documentElement.style.setProperty("--brand-ink", brandInk(el("brPrimary").value, el("brAccent").value));
      });
      text.addEventListener("change", function () {
        if (/^#[0-9a-fA-F]{6}$/.test(text.value.trim())) {
          picker.value = text.value.trim();
          picker.dispatchEvent(new Event("input"));
        } else {
          text.value = picker.value;
        }
      });
    }
    syncColour(el("brPrimary"), el("brPrimaryText"), "--brand-primary");
    syncColour(el("brAccent"), el("brAccentText"), "--brand-accent");

    el("brSave").onclick = function () {
      // The settings the admin has typed are captured BEFORE anything is sent,
      // so a logo upload in the middle can never be the reason a company name
      // goes back to what it was.
      var wanted = collectBranding();
      var logoChanged = state.pendingLogo !== undefined;
      setStatus("brStatus", "Saving...");
      saveLogoIfChanged()
        .then(function (warning) {
          state.pendingLogo = undefined;
          el("brLogoFile").value = "";
          return saveSettings(wanted, "brStatus", "Saved. The portal, your emails and the public page all use this now.")
            .then(function () {
              // A logo change is a change even when no text field moved, so the
              // "nothing to save" line saveSettings writes would be a lie here.
              if (logoChanged) {
                setStatus("brStatus", "Saved. The portal, your emails and the public page all use this now.", "ok");
              }
              if (warning) { toast(warning, "bad"); }
              renderBranding();
            });
        })
        .catch(function (e) { setStatus("brStatus", e.message, "bad"); });
    };

    // Returns a promise resolving to a warning string, or empty. The logo is
    // sent first: the settings save republishes the welcome page, and it should
    // republish with the image the admin is looking at.
    function saveLogoIfChanged() {
      if (state.pendingLogo === undefined) { return Promise.resolve(""); }
      if (state.pendingLogo === null) {
        return api("/branding/logo", "DELETE").then(function () { return ""; });
      }
      return api("/branding/logo", "POST", { contentBase64: state.pendingLogo })
        .then(function (data) { return data.publishWarning || ""; });
    }

    el("brLogoFile").onchange = function () {
      var file = el("brLogoFile").files[0];
      if (!file) { return; }
      if (file.size > 512 * 1024) { setStatus("brStatus", "That image is larger than 512 KB.", "bad"); return; }
      var reader = new FileReader();
      reader.onload = function () {
        state.pendingLogo = String(reader.result);
        setStatus("brStatus", "");
        renderLogoPreview();
      };
      reader.readAsDataURL(file);
    };

    el("brLogoRemove").onclick = function () {
      state.pendingLogo = null;
      el("brLogoFile").value = "";
      setStatus("brStatus", "");
      renderLogoPreview();
    };
  }

  /* ---------------- email editor ---------------- */

  function currentTemplateEntry() {
    return (state.config.emailCatalog || []).filter(function (c) { return c.key === state.emailKey; })[0];
  }

  function renderEmails() {
    var select = el("emKey");
    if (!select.options.length) {
      (state.config.emailCatalog || []).forEach(function (c) {
        var o = document.createElement("option");
        o.value = c.key;
        o.textContent = c.label + " (to the " + c.audience + ")";
        select.appendChild(o);
      });
      state.emailKey = select.value = (state.config.emailCatalog[0] || {}).key || "";
    } else {
      select.value = state.emailKey;
    }
    renderTemplate();
  }

  function renderTemplate() {
    var entry = currentTemplateEntry();
    if (!entry) { return; }
    var tpl = state.config.settings.emails[entry.key];
    el("emDescription").textContent = entry.description;
    el("emEnabled").checked = truthy(tpl.enabled);
    el("emSubject").value = tpl.subject;
    el("emBody").value = tpl.html;
    el("emShell").checked = truthy(tpl.useBrandShell);

    var tokens = el("emTokens");
    tokens.innerHTML = "";
    (entry.tokens || []).forEach(function (t) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "token";
      b.textContent = "{{" + t + "}}";
      b.title = "Insert this into the body";
      b.onclick = function () { insertToken("{{" + t + "}}"); };
      tokens.appendChild(b);
    });

    refreshPreview();
  }

  function insertToken(text) {
    var box = el("emBody");
    var start = box.selectionStart || 0;
    var end = box.selectionEnd || 0;
    box.value = box.value.slice(0, start) + text + box.value.slice(end);
    box.selectionStart = box.selectionEnd = start + text.length;
    box.focus();
    schedulePreview();
  }

  function captureTemplate() {
    var entry = currentTemplateEntry();
    if (!entry) { return null; }
    var s = state.config.settings;
    s.emails[entry.key] = {
      enabled: el("emEnabled").checked,
      subject: el("emSubject").value,
      html: el("emBody").value,
      useBrandShell: el("emShell").checked
    };
    return s;
  }

  var previewTimer = null;
  function schedulePreview() {
    if (previewTimer) { clearTimeout(previewTimer); }
    previewTimer = setTimeout(refreshPreview, 500);
  }

  function refreshPreview() {
    var entry = currentTemplateEntry();
    if (!entry) { return; }
    var settings = captureTemplate();
    api("/config/testmail", "POST", { key: entry.key, settings: settings, preview: true })
      .then(function (data) {
        el("emPreviewSubject").textContent = data.subject;
        el("emPreview").srcdoc = data.html;
        var unknown = el("emUnknown");
        if (data.unknownTokens && data.unknownTokens.length) {
          unknown.hidden = false;
          unknown.textContent = "These placeholders are not available in this message and will come out empty: " +
            data.unknownTokens.map(function (t) { return "{{" + t + "}}"; }).join(", ");
        } else {
          unknown.hidden = true;
        }
      })
      .catch(function (e) { setStatus("emStatus", e.message, "bad"); });
  }

  function wireEmailEditor() {
    el("emKey").onchange = function () { state.emailKey = el("emKey").value; renderTemplate(); };
    ["emSubject", "emBody"].forEach(function (id) { el(id).addEventListener("input", schedulePreview); });
    ["emEnabled", "emShell"].forEach(function (id) { el(id).addEventListener("change", schedulePreview); });

    el("emSave").onclick = function () {
      saveSettings(captureTemplate(), "emStatus", "Emails saved.").then(renderEmails).catch(function () { });
    };

    el("emTest").onclick = function () {
      var entry = currentTemplateEntry();
      setStatus("emStatus", "Sending...");
      api("/config/testmail", "POST", { key: entry.key, settings: captureTemplate(), preview: false })
        .then(function (data) {
          if (data.sent) { setStatus("emStatus", "Sent to " + data.sentTo + ".", "ok"); }
          else { setStatus("emStatus", data.error || "Nothing was sent.", "bad"); }
        })
        .catch(function (e) { setStatus("emStatus", e.message, "bad"); });
    };

    el("emReset").onclick = function () {
      var entry = currentTemplateEntry();
      if (!entry) { return; }
      // Resetting is a save with this template removed: the server fills the gap
      // from the shipped catalogue, so there is only one definition of "default".
      var s = JSON.parse(JSON.stringify(state.config.settings));
      delete s.emails[entry.key];
      saveSettings(s, "emStatus", "Reset to the shipped wording.").then(renderEmails).catch(function () { });
    };
  }

  /* ---------------- activity ---------------- */

  function loadLog(reset) {
    if (reset) { el("logRows").innerHTML = ""; state.logNext = null; }
    var query = "?top=50";
    if (state.me.user.isAdmin && el("logAll") && el("logAll").checked) { query += "&scope=all"; }
    if (state.logNext) { query += "&npk=" + encodeURIComponent(state.logNext.npk) + "&nrk=" + encodeURIComponent(state.logNext.nrk || ""); }
    setStatus("logStatus", "Loading...");
    return api("/logs" + query).then(function (data) {
      var rows = el("logRows");
      (data.items || []).forEach(function (item) {
        var tr = document.createElement("tr");
        var detail = item.detail ? JSON.stringify(item.detail) : "";
        if (detail === "{}") { detail = ""; }
        tr.innerHTML = "<td>" + esc(fmtDate(item.timestampUtc)) + "</td>" +
          "<td>" + esc(item.event) + (item.simulated ? ' <span class="pill warn">simulated</span>' : "") + "</td>" +
          "<td>" + esc(item.actor) + "</td>" +
          '<td class="small muted">' + esc(detail.length > 300 ? detail.slice(0, 300) + "..." : detail) + "</td>";
        rows.appendChild(tr);
      });
      state.logNext = data.next;
      el("logMore").hidden = !data.next;
      setStatus("logStatus", rows.children.length ? "" : "Nothing has happened yet.");
    }).catch(function (e) { setStatus("logStatus", e.message, "bad"); });
  }

  /* ---------------- diagnostics ---------------- */

  function pill(ok, okText, badText) {
    return '<span class="pill ' + (ok ? "ok" : "bad") + '">' + esc(ok ? okText : badText) + "</span>";
  }

  // The API returns -1 for a queue that does not exist yet. That is an absence,
  // not a count, and rendering it verbatim produced "-1 failed" on a perfectly
  // healthy install.
  function queueCount(n) { return (typeof n === "number" && n >= 0) ? n : 0; }

  function renderStaleCodeWarning(d) {
    if (!d.codeStale) { return ""; }
    // Worth shouting about: when the code is stale, every other symptom on this
    // page is a red herring, and people lose hours to it.
    return '<div class="banner error"><div><div class="title">The deployed code is out of date</div>' +
      '<div class="small">This app is configured as version ' + esc(d.version) + " but the code running is " +
      esc(d.codeVersion) + ". A zip deployment reports success as soon as the package uploads, so this happens " +
      "when the package did not actually land. Re-run <strong>deploy/Update-Collaborate.ps1</strong> and check its output for functions that did not register. " +
      "Until this matches, expect endpoints to 404 and settings changes not to take effect.</div>" +
      '<div class="small">Functions the running code provides: ' + esc((d.functions || []).join(", ")) + "</div></div></div>";
  }

  function renderHealthFindings(health, status) {
    var host = el("diagFindings");
    var stale = status ? renderStaleCodeWarning(status) : "";
    var all = (health && health.problems ? health.problems : []).concat(health && health.notes ? health.notes : []);
    if (!all.length && stale) { host.innerHTML = stale; return; }
    if (!all.length) {
      host.innerHTML = '<div class="banner"><div><div class="title">Everything looks normal</div>' +
        '<div class="small">The same checks the nightly health mail runs found nothing to report.</div></div></div>';
      return;
    }
    host.innerHTML = stale + all.map(function (f) {
      return '<div class="banner' + (f.severity === "error" ? " error" : "") + '"><div>' +
        '<div class="title">' + esc(f.title) + "</div>" +
        '<div class="small">' + esc(f.detail) + "</div></div></div>";
    }).join("");
  }

  function runAdminOperation(action, label) {
    setStatus("opStatus", label + "...");
    document.querySelectorAll("#view-diag .btn").forEach(function (b) { b.disabled = true; });
    return api("/operations", "POST", { action: action })
      .then(function (data) {
        setStatus("opStatus", data.message || "Done.", "ok");
        toast(data.message || "Done.", "ok");
        if (action === "healthCheck") { renderHealthFindings({ problems: (data.findings || []).filter(function (f) { return f.severity === "error"; }), notes: (data.findings || []).filter(function (f) { return f.severity !== "error"; }) }); }
        // A refresh is the thing that decides whether last-active can be shown
        // at all, so pick the answer back up rather than making somebody reload
        // the page to see the column they just enabled.
        if (action === "refresh") { return loadMe().then(function () { return data; }); }
        return data;
      })
      .catch(function (e) { setStatus("opStatus", e.message, "bad"); })
      .then(function (r) {
        document.querySelectorAll("#view-diag .btn").forEach(function (b) { b.disabled = false; });
        return r;
      });
  }

  function loadDiagnostics() {
    setStatus("diagStatus", "Loading...");
    return api("/status").then(function (d) {
      renderHealthFindings(d.health, d);
      var summary = el("diagSummary");
      summary.innerHTML =
        '<div class="card"><h3>Mail</h3>' + pill(d.mail.ok, "working", "problem") +
        '<p class="small muted">' + esc(d.mail.detail) + "</p></div>" +
        '<div class="card"><h3>Acting on behalf of users</h3>' + pill(d.delegation.ok, "working", "problem") +
        '<p class="small muted">' + esc(d.delegation.detail) + "</p></div>" +
        '<div class="card"><h3>Public welcome page</h3>' +
        (d.welcomePage.checked ? pill(d.welcomePage.intact, "unchanged since we published it", "changed since we published it")
          : '<span class="pill warn">not checked</span>') +
        '<p class="small muted">' + esc(d.welcomePage.detail || d.welcomePage.url) + "</p></div>" +
        '<div class="card"><h3>Safety</h3>' +
        (d.safety && d.safety.paused ? '<span class="pill bad">paused</span>' : '<span class="pill ok">running</span>') +
        '<p class="small muted">Today: ' + esc((d.safety && d.safety.counts ? d.safety.counts.invite : 0)) + " invited, " +
        esc((d.safety && d.safety.counts ? d.safety.counts.block : 0)) + " blocked, " +
        esc((d.safety && d.safety.counts ? d.safety.counts.delete : 0)) + " deleted.</p></div>" +
        // -1 means the queue does not exist yet, which is not the same as a
        // count and must never be shown as one.
        '<div class="card"><h3>Queue</h3><p class="small muted">' + esc(queueCount(d.queues.work)) + " waiting, " +
        esc(queueCount(d.queues.poison)) + " failed.</p></div>" +
        '<div class="card"><h3>External accounts</h3>' +
        ((d.guests && d.guests.unowned) ? '<span class="pill warn">' + esc(d.guests.unowned) + " with no owner</span>"
          : '<span class="pill ok">all accounted for</span>') +
        '<p class="small muted">' + esc((d.guests ? d.guests.population : 0)) + " guest(s) in the tenant.</p></div>" +
        '<div class="card"><h3>Version</h3>' +
        ((d.update && d.update.available) ? '<span class="pill warn">' + esc(d.update.latest) + " is available</span>"
          : '<span class="pill ok">up to date</span>') +
        '<p class="small muted">Running ' + esc(d.version) + (d.simulation ? " (simulation mode)" : "") +
        (d.update && d.update.detail ? "<br>" + esc(d.update.detail) : "") + "</p></div>";

      var rows = el("diagRows");
      rows.innerHTML = "";
      (d.heartbeats || []).forEach(function (h) {
        var tr = document.createElement("tr");
        tr.innerHTML = "<td>" + esc(h.name) + "</td><td>" + esc(fmtDate(h.lastRunUtc)) + "</td>" +
          "<td>" + (h.lastStatus === "ok" ? '<span class="pill ok">ok</span>' : '<span class="pill bad">failed</span>') + "</td>" +
          "<td>" + esc(h.lastDurationMs) + " ms</td>" +
          '<td class="small">' + esc(h.lastError || "") + "</td>";
        rows.appendChild(tr);
      });
      el("diagEmpty").hidden = (d.heartbeats || []).length > 0;
      setStatus("diagStatus", "");
    }).catch(function (e) { setStatus("diagStatus", e.message, "bad"); });
  }

  /* ---------------- setup wizard ---------------- */

  var WIZARD_STEPS = ["Branding", "How long access lasts", "Who may invite", "Sharing", "Check and finish"];

  function startWizard() {
    api("/setup").then(function (data) {
      state.wizard = { settings: data.settings, step: 0, attributes: data.expiryAttributes };
      el("wizard").hidden = false;
      renderWizard();
    }).catch(function (e) { toast(e.message, "bad"); });
  }

  function renderWizard() {
    var w = state.wizard;
    var s = w.settings;

    el("wizSteps").innerHTML = WIZARD_STEPS.map(function (label, i) {
      return '<span class="step' + (i === w.step ? " active" : "") + '">' + (i + 1) + ". " + esc(label) + "</span>";
    }).join(" ");

    var body = el("wizBody");
    if (w.step === 0) {
      body.innerHTML =
        "<h2>Make it yours</h2>" +
        "<p class=\"muted\">This is what your people and your guests will see. You can change all of it later.</p>" +
        field("wizCompany", "Company name", '<input id="wizCompany" type="text" maxlength="80" value="' + esc(s.branding.companyName) + '" />') +
        field("wizTitle", "Portal title", '<input id="wizTitle" type="text" maxlength="60" value="' + esc(s.branding.portalTitle) + '" />') +
        field("wizPrimary", "Main colour", '<input id="wizPrimary" type="color" value="' + esc(s.branding.primaryColor) + '" />') +
        field("wizAccent", "Accent colour", '<input id="wizAccent" type="color" value="' + esc(s.branding.accentColor) + '" />') +
        '<p class="small muted">The logo is uploaded on the Branding tab once setup is done.</p>';
    } else if (w.step === 1) {
      body.innerHTML =
        "<h2>How long access lasts</h2>" +
        "<p class=\"muted\">Every guest gets an end date. Before it arrives the owner is reminded; after it passes, sign-in is blocked and the account is only removed once the grace period is over.</p>" +
        field("wizDefault", "Default length in days", '<input id="wizDefault" type="number" min="1" max="3650" value="' + esc(s.expiry.defaultDays) + '" />') +
        field("wizMax", "Longest anybody may choose", '<input id="wizMax" type="number" min="1" max="3650" value="' + esc(s.expiry.maxDays) + '" />') +
        field("wizGrace", "Grace period before deletion, in days", '<input id="wizGrace" type="number" min="0" max="365" value="' + esc(s.expiry.graceDays) + '" />') +
        field("wizReminders", "Remind the owner this many days before", '<input id="wizReminders" type="text" value="' + esc((s.expiry.reminderDays || []).join(", ")) + '" />') +
        field("wizAttr", "Store the end date on", '<select id="wizAttr">' + (w.attributes || []).map(function (a) {
          return '<option value="' + esc(a) + '"' + (a === s.expiry.attribute ? " selected" : "") + ">" + esc(a) + "</option>";
        }).join("") + "</select>") +
        '<p class="small muted">The end date is written onto the guest account itself, so it outlives this tool. Pick an attribute nothing else uses: the check on the last step verifies that.</p>';
    } else if (w.step === 2) {
      body.innerHTML =
        "<h2>Who may invite</h2>" +
        "<p class=\"muted\">Leave the group empty and any internal member can invite an external person. Everybody can always manage the guests they already own.</p>" +
        field("wizGroup", "Object id of the group allowed to invite (optional)", '<input id="wizGroup" type="text" value="' + esc(s.invite.inviterGroupId) + '" />') +
        field("wizGroupName", "Group name, shown to anybody who is refused", '<input id="wizGroupName" type="text" value="' + esc(s.invite.inviterGroupName) + '" />') +
        field("wizServicedesk", "Service desk email (where health warnings are sent to)", '<input id="wizServicedesk" type="email" value="' + esc(s.notifications.servicedeskEmail) + '" />') +
        '<p class="small muted">Invitations are sent from the mailbox of whoever creates them, from their own browser. Reminders, expiry notices and digests come from the shared mailbox, because nobody is signed in when those are sent.</p>' +
        '<div class="checkline"><input id="wizReason" type="checkbox"' + (s.invite.requireReason ? " checked" : "") +
        ' /><label for="wizReason">Require a reason for every invitation</label></div>';
    } else if (w.step === 3) {
      body.innerHTML =
        "<h2>Sharing</h2>" +
        "<p class=\"muted\">These run as the person using the portal, never as the service, so nobody can share something they do not already have access to. Switch off anything you do not want offered.</p>" +
        '<div class="checkline"><input id="wizFiles" type="checkbox"' + (s.sharing.files ? " checked" : "") + ' /><label for="wizFiles">Share files</label></div>' +
        '<div class="checkline"><input id="wizFolders" type="checkbox"' + (s.sharing.folders ? " checked" : "") + ' /><label for="wizFolders">Share folders</label></div>' +
        '<div class="checkline"><input id="wizTeams" type="checkbox"' + (s.sharing.teams ? " checked" : "") + ' /><label for="wizTeams">Add guests to Teams</label></div>' +
        '<div class="checkline"><input id="wizWrite" type="checkbox"' + (s.sharing.allowWrite ? " checked" : "") + ' /><label for="wizWrite">Allow edit access, not only view</label></div>' +
        '<p class="small muted">Collaborate starts in simulation mode: it will log what it would do and change nothing until you turn that off in Configuration.</p>';
    } else {
      body.innerHTML = "<h2>Check and finish</h2>" +
        '<p class="muted">Before finishing, Collaborate verifies that single sign-on is genuinely being enforced, that it can act on your behalf, and that the attribute you chose is free.</p>' +
        '<div id="wizChecks"><p class="row"><span class="spinner"></span> Running the checks...</p></div>';
      runWizardChecks();
    }

    el("wizBack").hidden = w.step === 0;
    el("wizNext").textContent = w.step === WIZARD_STEPS.length - 1 ? "Finish setup" : "Next";
    setStatus("wizStatus", "");
  }

  function field(id, label, control) {
    return '<label class="field" for="' + id + '"><span>' + esc(label) + "</span>" + control + "</label>";
  }

  function captureWizardStep() {
    var s = state.wizard.settings;
    var step = state.wizard.step;
    if (step === 0) {
      s.branding.companyName = el("wizCompany").value.trim();
      s.branding.portalTitle = el("wizTitle").value.trim();
      s.branding.primaryColor = el("wizPrimary").value;
      s.branding.accentColor = el("wizAccent").value;
      applyBranding(s.branding);
    } else if (step === 1) {
      s.expiry.defaultDays = Number(el("wizDefault").value);
      s.expiry.maxDays = Number(el("wizMax").value);
      s.expiry.graceDays = Number(el("wizGrace").value);
      s.expiry.reminderDays = textToList(el("wizReminders").value).map(Number);
      s.expiry.attribute = el("wizAttr").value;
    } else if (step === 2) {
      s.invite.inviterGroupId = el("wizGroup").value.trim();
      s.invite.inviterGroupName = el("wizGroupName").value.trim();
      s.notifications.servicedeskEmail = el("wizServicedesk").value.trim();
      s.invite.requireReason = el("wizReason").checked;
    } else if (step === 3) {
      s.sharing.files = el("wizFiles").checked;
      s.sharing.folders = el("wizFolders").checked;
      s.sharing.teams = el("wizTeams").checked;
      s.sharing.allowWrite = el("wizWrite").checked;
    }
    return s;
  }

  function renderChecks(checks) {
    return checks.map(function (c) {
      var mark = c.ok ? "✓" : (c.required ? "✗" : "!");
      var cls = c.ok ? "ok" : (c.required ? "bad" : "warn");
      return '<div class="check"><span class="mark ' + cls + '">' + mark + "</span><div><div><strong>" +
        esc(c.label) + "</strong>" + (c.required ? "" : ' <span class="pill warn">optional</span>') +
        '</div><div class="small muted">' + esc(c.detail) + "</div></div></div>";
    }).join("");
  }

  function runWizardChecks() {
    api("/setup", "POST", { action: "test", settings: state.wizard.settings })
      .then(function (data) {
        el("wizChecks").innerHTML = renderChecks(data.checks);
        el("wizNext").disabled = false;
        if (!data.ok) {
          setStatus("wizStatus", "Fix the items marked with a cross, then try again.", "bad");
        }
      })
      .catch(function (e) {
        el("wizChecks").innerHTML = '<p class="status bad">' + esc(e.message) + "</p>";
      });
  }

  function wireWizard() {
    el("wizBack").onclick = function () {
      captureWizardStep();
      state.wizard.step = Math.max(0, state.wizard.step - 1);
      renderWizard();
    };
    el("wizNext").onclick = function () {
      var settings = captureWizardStep();
      var last = state.wizard.step === WIZARD_STEPS.length - 1;
      el("wizNext").disabled = true;
      setStatus("wizStatus", last ? "Checking and finishing..." : "Saving...");

      api("/setup", "POST", { action: last ? "complete" : "save", settings: settings })
        .then(function (data) {
          el("wizNext").disabled = false;
          if (last) {
            el("wizard").hidden = true;
            toast("Setup is complete. Single sign-on is verified and enforced.", "ok");
            state.config = null;
            return loadMe();
          }
          state.wizard.settings = data.settings;
          state.wizard.step += 1;
          renderWizard();
        })
        .catch(function (e) {
          el("wizNext").disabled = false;
          setStatus("wizStatus", e.message, "bad");
          if (e.data && e.data.checks && el("wizChecks")) {
            el("wizChecks").innerHTML = renderChecks(e.data.checks);
          }
        });
    };
  }

  /* ---------------- boot ---------------- */

  function wire() {
    document.querySelectorAll(".tab").forEach(function (t) {
      t.onclick = function () { showView(t.dataset.view); };
    });
    wireViewLinks(document);
    el("signOutBtn").onclick = function () { msalInstance.logoutRedirect(); };
    el("cfgSave").onclick = function () {
      saveSettings(collectSettings(), "cfgStatus", "Configuration saved.").catch(function () { });
    };
    el("logMore").onclick = function () { loadLog(false); };
    if (el("logAll")) { el("logAll").onchange = function () { loadLog(true); }; }
    el("diagRefresh").onclick = loadDiagnostics;
    el("opRefresh").onclick = function () { runAdminOperation("refresh", "Reading Entra"); };
    el("opAdopt").onclick = function () { runAdminOperation("adopt", "Looking for guests we do not track"); };
    el("opOrphans").onclick = function () { runAdminOperation("orphanDigest", "Checking for unowned accounts"); };
    el("opHealth").onclick = function () { runAdminOperation("healthCheck", "Running the checks"); };
    el("opVersion").onclick = function () { runAdminOperation("versionCheck", "Checking"); };
    wireGuests();
    wireBulkAssign();
    wireShare();
    wireBrandingEditor();
    wireEmailEditor();
    wireWizard();
  }

  function showSignedIn() {
    el("gate").hidden = true;
    el("topbar").hidden = false;
    el("app").hidden = false;
  }

  function showSignedOut() {
    el("gate").hidden = false;
    el("topbar").hidden = true;
    el("app").hidden = true;
    el("signInBtn").onclick = function () { msalInstance.loginRedirect(loginRequest); };
  }

  loadPublicBranding();
  wire();

  msalInstance.initialize()
    .then(function () { return msalInstance.handleRedirectPromise(); })
    .then(function (result) {
      if (result && result.account) { msalInstance.setActiveAccount(result.account); }
      var acc = currentAccount();
      if (!acc) { showSignedOut(); return null; }
      msalInstance.setActiveAccount(acc);
      showSignedIn();
      return loadMe();
    })
    .catch(function (e) {
      var message = (e && e.message) ? e.message : String(e);
      if (/AADSTS/.test(message)) {
        fail("Sign-in was refused: " + message);
      } else if (currentAccount()) {
        // Signed in, but the API did not answer. loadMe has already explained
        // this on the page; a toast as well would only repeat it.
        console.error(e);
      } else {
        showSignedOut();
        toast("Could not sign you in: " + message, "bad");
      }
    });
})();
