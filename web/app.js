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

  // Framed (clickjacking, or MSAL's silent renewal iframe): render nothing.
  if (window.top !== window.self) {
    document.documentElement.hidden = true;
    return;
  }

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
    wizard: null,      // { settings, step }
    view: "home",      // the view on screen
    emailDrafts: {}    // unsaved template edits, by key; state.config holds the saved ones
  };

  /* ---------------- language ----------------
     Resolution order: what this person chose, then what the administrator set as
     the default, then the browser, then English.

     The chosen language is cached in localStorage so a returning visitor gets
     the right language on the FIRST paint, before /api/me has answered. The
     server's answer is authoritative: when it disagrees with the cache, the page
     reloads once. That is also how switching works, because the DOM sweep edits
     elements in place and cannot be undone. */

  var LANG_KEY = "cb.language";

  function cachedLanguage() {
    try { return window.localStorage.getItem(LANG_KEY) || ""; } catch (e) { return ""; }
  }
  // Returns whether the choice actually stuck. It does not in private mode with
  // storage blocked, and that answer decides whether reloading is safe.
  function cacheLanguage(code) {
    try {
      window.localStorage.setItem(LANG_KEY, code);
      return window.localStorage.getItem(LANG_KEY) === code;
    }
    catch (e) { return false; }
  }

  function applyLanguage() {
    var wanted = CBI18N.supported(cachedLanguage()) ||
      CBI18N.supported(navigator.language || (navigator.languages || [])[0]) || "en";
    CBI18N.setLanguage(wanted);
    document.documentElement.setAttribute("lang", wanted);
    // Patches the DOM writes first, so everything rendered from here on is
    // translated as it is written, then sweeps the shell that is already there.
    CBI18N.install();
    CBI18N.translateDom(document.body);
  }

  // t() is used everywhere below, so it gets a short name.
  function t(text, vars) { return CBI18N.t(text, vars); }

  // Called once /api/me has said what this person should be seeing.
  function reconcileLanguage(me) {
    var wanted = CBI18N.supported(me && me.language) || "en";
    if (wanted === CBI18N.getLanguage()) { renderLanguagePicker(wanted); return; }
    // Only reload if the choice was actually remembered. If it was not, the
    // reloaded page would resolve the same language again and reload again.
    if (!cacheLanguage(wanted)) { renderLanguagePicker(CBI18N.getLanguage()); return; }
    window.location.reload();
  }

  function renderLanguagePicker(active) {
    var pick = el("langPick");
    if (!pick) { return; }
    pick.innerHTML = CBI18N.languages.map(function (l) {
      return '<option value="' + esc(l.code) + '"' + (l.code === active ? " selected" : "") + ">" + esc(l.label) + "</option>";
    }).join("");
    pick.onchange = function () {
      var chosen = pick.value;
      cacheLanguage(chosen);   // best effort; the server copy is what persists
      // Saved against the account so it follows them to another machine. The
      // reload happens either way: a failed save still changes what they see
      // here, it just will not be remembered elsewhere.
      api("/me", "POST", { language: chosen })
        .catch(function () { })
        .then(function () { window.location.reload(); });
    };
  }

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
    if (kind === "bad") { t.setAttribute("role", "alert"); }
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

  function clone(o) { return JSON.parse(JSON.stringify(o)); }

  // Disables a button while the promise it started runs, so a double click
  // cannot send the same request twice.
  function whileBusy(btn, start) {
    if (!btn || btn.disabled) { return Promise.resolve(); }
    btn.disabled = true;
    var p;
    try { p = Promise.resolve(start()); } catch (e) { p = Promise.reject(e); }
    return p.then(function (r) { btn.disabled = false; return r; },
      function (e) { btn.disabled = false; throw e; });
  }

  // Keeps Tab inside a dialog.
  function trapTab(container, e) {
    if (e.key !== "Tab") { return; }
    var nodes = Array.prototype.slice.call(container.querySelectorAll(
      'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'))
      .filter(function (n) { return n.offsetParent !== null; });
    if (!nodes.length) { e.preventDefault(); container.focus(); return; }
    var first = nodes[0], last = nodes[nodes.length - 1];
    if (e.shiftKey && (document.activeElement === first || document.activeElement === container)) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
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

  // The deep link somebody arrived on, kept across the sign-in redirect.
  var HASH_KEY = "cb.returnHash";
  function rememberHash() {
    try { if (window.location.hash) { window.sessionStorage.setItem(HASH_KEY, window.location.hash); } } catch (e) { }
  }
  function restoreHash() {
    var saved = "";
    try { saved = window.sessionStorage.getItem(HASH_KEY) || ""; window.sessionStorage.removeItem(HASH_KEY); } catch (e) { }
    if (saved && !parseHash(window.location.hash).known) {
      window.history.replaceState(null, "", window.location.pathname + window.location.search + saved);
    }
  }

  function signInRedirect() {
    rememberHash();
    return msalInstance.loginRedirect(loginRequest);
  }

  // Only these mean a person has to sign in again. Anything else (a network
  // blip, a timed-out iframe) gets one silent retry and then fails as an error,
  // rather than redirecting away from a half-finished form.
  var INTERACTION_CODES = ["interaction_required", "login_required", "consent_required", "no_tokens_found",
    "refresh_token_expired", "bad_token", "native_account_unavailable", "token_refresh_required"];
  function needsInteraction(e) {
    if (!e) { return false; }
    if (msal.InteractionRequiredAuthError && e instanceof msal.InteractionRequiredAuthError) { return true; }
    return INTERACTION_CODES.indexOf(String(e.errorCode || "")) >= 0;
  }

  function getToken() {
    var acc = currentAccount();
    if (!acc) { return Promise.reject(new Error(t("You are not signed in."))); }
    var request = { scopes: [CFG.apiScope], account: acc };
    return msalInstance.acquireTokenSilent(request)
      .catch(function (e) {
        if (needsInteraction(e)) { throw e; }
        return msalInstance.acquireTokenSilent(request);
      })
      .then(function (r) {
        if (!r || !r.accessToken) { throw new Error(t("Could not get a sign-in token. Reload the page and try again.")); }
        return r.accessToken;
      })
      .catch(function (e) {
        if (!needsInteraction(e)) { throw e; }
        rememberHash();
        // Navigates away; the rejection keeps api() from sending a request
        // without a token in the moment before it does.
        return msalInstance.acquireTokenRedirect({ scopes: [CFG.apiScope], account: acc })
          .then(function () { throw new Error(t("Your session has expired. Signing you in again...")); });
      });
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
    if (!acc) { return Promise.reject(new Error(t("You are not signed in."))); }
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
            var err = new Error(data.error || t("The server returned {status}.", { status: res.status }));
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

  var ADMIN_VIEWS = { config: 1, branding: 1, emails: 1, diag: 1 };
  var HASH_VIEWS = { home: 1, guests: 1, config: 1, branding: 1, emails: 1, log: 1, diag: 1, share: 1, invite: 1 };

  // #guests, #config, ... and #guest/<id> or #guest/<id>/<action>.
  function parseHash(hash) {
    var parts = String(hash || "").replace(/^#\/?/, "").split("/");
    if (parts[0] === "guest" && /^[0-9a-fA-F-]{36}$/.test(parts[1] || "")) {
      return { known: true, view: "guests", guestId: parts[1], action: parts[2] || "" };
    }
    if (HASH_VIEWS[parts[0]]) { return { known: true, view: parts[0], mode: parts[1] || "" }; }
    return { known: false, view: "home" };
  }

  // Pushes a history entry, so Back works. Routing ignores the resulting
  // hashchange because the view is already on screen.
  function setHash(hash, replace) {
    if (window.location.hash === hash) { return; }
    if (replace) { window.history.replaceState(null, "", hash); }
    else { window.location.hash = hash; }
  }

  // keepHash: the caller owns the hash (a deep link to one collaborator).
  function showView(name, keepHash) {
    // Nothing but Home can render before /api/me has answered; the hash keeps
    // the request and route() picks it up once it has.
    if (!state.me && name !== "home") {
      if (HASH_VIEWS[name]) { setHash("#" + name); }
      return;
    }
    if (ADMIN_VIEWS[name] && !(state.me && state.me.user.isAdmin)) { name = "home"; }
    var previous = state.view;
    state.view = name;
    if (previous === "branding" && name !== "branding") { revertBrandPreview(); }
    if (HASH_VIEWS[name] && !keepHash) { setHash("#" + (name === "share" && state.share && state.share.mode === "teams" ? "share/teams" : name)); }
    document.querySelectorAll(".view").forEach(function (v) { v.hidden = v.id !== "view-" + name; });
    document.querySelectorAll(".tab").forEach(function (b) {
      var on = b.dataset.view === name;
      b.classList.toggle("active", on);
      if (on) { b.setAttribute("aria-current", "page"); } else { b.removeAttribute("aria-current"); }
    });
    if (name === "guests") { loadGuests(); }
    if (name === "config" || name === "branding" || name === "emails") { enterAdminTab(name); }
    if (name === "log") { loadLog(true); }
    if (name === "diag") { loadDiagnostics(); }
  }

  // Applies the hash: on first load after /api/me, on hashchange and on Back.
  function route() {
    if (!state.me) { return; }
    var h = parseHash(window.location.hash);
    if (h.guestId) {
      if (state.drawer && state.drawer.guest.id === h.guestId) { return; }
      if (state.view !== "guests") { showView("guests", true); }
      openGuest({ id: h.guestId }, h.action);
      return;
    }
    if (state.drawer) { closeGuest(true); }
    if (h.view === state.view && el("view-" + h.view) && !el("view-" + h.view).hidden) { return; }
    if (h.view === "share") {
      var caps = state.me.capabilities || {};
      if (h.mode === "teams" && truthy(caps.shareTeams)) { startShare("teams"); return; }
      if ((truthy(caps.shareFiles) || truthy(caps.shareFolders)) && sharingAllowed().ok) { startShare("files"); return; }
      showView("home");
      return;
    }
    if (h.view === "invite") {
      if (state.me.canInvite && state.me.canInvite.allowed) { startInvite(); } else { showView("guests"); }
      return;
    }
    showView(h.view);
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
        // A second step: resuming also resets today's safety counters, so it
        // must not be one stray click.
        btn.onclick = function () { confirmResume(div, b); };
        div.appendChild(btn);
      }
      host.appendChild(div);
    });
  }

  function confirmResume(div, b) {
    div.innerHTML = '<div style="flex:1"><div class="title">' + esc(t("Resume processing?")) + "</div>" +
      '<div class="small">' + esc(t("It paused because: {reason}", { reason: b.message || t("no reason was recorded") })) + "</div>" +
      '<div class="small">' + esc(t("Resuming lets everything that is queued go ahead now, and resets today's safety counters. Check the reason above first.")) + "</div>" +
      '<div class="row" style="margin-top:10px">' +
      '<button type="button" class="btn small primary" data-resume-go>' + esc(t("Resume now")) + "</button>" +
      '<button type="button" class="btn small ghost" data-resume-cancel>' + esc(t("Cancel")) + "</button>" +
      '<span class="status" role="status" data-resume-status></span></div></div>';
    var go = div.querySelector("[data-resume-go]");
    go.focus();
    div.querySelector("[data-resume-cancel]").onclick = function () { renderBanners(state.me ? state.me.banners : []); };
    go.onclick = function () {
      whileBusy(go, function () {
        return api("/resume", "POST", {})
          .then(function () { toast(t("Processing resumed."), "ok"); return loadMe(); });
      }).catch(function (e) {
        var st = div.querySelector("[data-resume-status]");
        if (st) { st.className = "status bad"; st.textContent = e.message; }
      });
    };
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
        label: t({ "file": "Share a file", "folder": "Share a folder" }[shareLabel()] || "Share a file or folder"),
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

    // Rendered on every /api/me, so one note, reused.
    var note = el("homeCantInvite");
    if (!note) {
      note = document.createElement("p");
      note.id = "homeCantInvite";
      note.className = "muted small";
      host.parentNode.appendChild(note);
    }
    note.hidden = !!me.canInvite.allowed;
    note.textContent = me.canInvite.allowed ? "" : (me.canInvite.reason || "");

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
      var first = !state.me;
      state.me = data;
      reconcileLanguage(data);
      renderShell();
      if (!data.setupComplete && data.user.isAdmin && first) { startWizard(); }
      // A deep link, or a tab clicked while this was loading.
      if (first) { route(); }
      return data;
    }).catch(function (e) {
      // Without /me there is nothing to render, so say so where the cards would
      // have been rather than leaving the spinner turning forever.
      el("homeLoading").innerHTML = '<p class="status bad">' + esc(t("Collaborate could not start: {error}", { error: e.message })) + "</p>" +
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
    if (!state.me) { return Promise.resolve(); }
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

  // The one wording for a state, in the pill and in the filter alike.
  function stateLabel(s) {
    for (var i = 0; i < GUEST_STATES.length; i++) { if (GUEST_STATES[i][0] === s) { return t(GUEST_STATES[i][1]); } }
    return t(String(s || ""));
  }

  function guestFilterState() {
    if (!state.guestFilter) { state.guestFilter = { who: "", states: [] }; }
    return state.guestFilter;
  }

  function applyGuestFilters(items) {
    var f = guestFilterState();
    var unownedOnly = state.guestsShowAll && el("guestsUnowned").checked;
    var term = f.who.trim().toLowerCase();
    var search = String(state.guestSearch || "").trim().toLowerCase();
    return items.filter(function (g) {
      if (f.states.length && f.states.indexOf(g.state) < 0) { return false; }
      if (unownedOnly && !g.orphaned) { return false; }
      if (term) {
        var hay = [g.displayName, g.email, g.reason, g.owner ? g.owner.displayName : ""].join(" ").toLowerCase();
        if (hay.indexOf(term) < 0) { return false; }
      }
      if (search && [g.displayName, g.email, g.reason].join(" ").toLowerCase().indexOf(search) < 0) { return false; }
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

  // The label is translated here: the sweep cannot match a button whose text
  // shares it with the sort mark.
  function headerCell(key, label, filterable) {
    var f = guestFilterState();
    var active = (key === "status" && f.states.length) || (key === "who" && f.who);
    var s = state.guestSort;
    var sort = (s && s.key === key) ? (s.dir === "desc" ? "descending" : "ascending") : "none";
    var name = t(label);
    return '<th aria-sort="' + sort + '">' +
      '<button type="button" class="th-sort" data-sort="' + key + '" title="' + esc(t("Sort by {name}", { name: name })) + '">' +
      esc(name) + sortIndicator(key) + "</button>" +
      (filterable
        ? '<button type="button" class="th-filter' + (active ? " on" : "") + '" data-filter="' + key +
        '" title="' + esc(t("Filter")) + '" aria-label="' + esc(t("Filter by {name}", { name: name })) + '">⋮</button>'
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
          (checked ? " checked" : "") + " /><span>" + esc(t(p[1])) +
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
    var f = guestFilterState();
    state.guestsVisible = items;

    // A selection only covers rows on screen, so a bulk action never touches
    // somebody the current filter is hiding.
    var visible = {};
    items.forEach(function (g) { visible[g.id] = true; });
    Object.keys(state.selected).forEach(function (id) { if (!visible[id]) { delete state.selected[id]; } });

    var activeFilters = [];
    if (f.who) { activeFilters.push(t("who contains \"{text}\"", { text: f.who })); }
    if (f.states.length) { activeFilters.push(t("status: {states}", { states: f.states.map(stateLabel).join(", ") })); }
    el("guestsUnowned").parentNode.hidden = !showOwner;
    el("guestsFilters").hidden = !showOwner && !activeFilters.length;
    el("guestsActiveFilters").textContent = activeFilters.length ? t("Filtered by {filters}", { filters: activeFilters.join("; ") }) : "";
    el("guestsEmpty").hidden = all.length > 0;
    el("guestsExport").hidden = !all.length;
    el("guestsIntro").textContent = showOwner
      ? "Every external account in the tenant, with the colleague who is accountable for each one."
      : "Everybody here is recorded against your name, with a reason and an end date, so nothing stays open forever.";

    // Why there is, or is not, a "Last active" column. An empty column with no
    // explanation reads as "nobody has ever signed in", which would be a lie on
    // a tenant that simply cannot answer the question.
    var seenNote = signInData();
    el("guestsSignInNote").hidden = false;
    el("guestsSignInNote").textContent = seenNote.available
      ? (seenNote.checkedAtLabel
        ? t("Last active is read from Entra sign-in data, last checked {when}.", { when: t(seenNote.checkedAtLabel) })
        : t("Last active is read from Entra sign-in data."))
      : seenNote.note;

    // Only the states that need somebody to do something are called out. A row
    // of six zeroes would be noise. Each filters to its state; again clears.
    var interesting = [["blocked", "{count} switched off"], ["expired", "{count} ended"],
      ["expiring", "{count} ending soon"], ["pending", "{count} waiting to accept"]];
    var only = f.states.length === 1 ? f.states[0] : "";
    var pills = interesting.filter(function (p) { return counts[p[0]]; })
      .map(function (p) {
        return '<button type="button" class="pill pill-btn ' + stateClass(p[0]) + (only === p[0] ? " on" : "") +
          '" data-pill="' + p[0] + '" aria-pressed="' + (only === p[0] ? "true" : "false") + '">' +
          esc(t(p[1], { count: counts[p[0]] })) + "</button>";
      });
    pills.unshift('<span class="small muted">' +
      esc(t(counts.total === 1 ? "{count} person" : "{count} people", { count: counts.total || 0 })) + "</span>");
    el("guestsCounts").innerHTML = all.length ? pills.join(" ") : "";
    el("guestsCounts").querySelectorAll("[data-pill]").forEach(function (b) {
      b.onclick = function () {
        var s = b.dataset.pill;
        f.states = (f.states.length === 1 && f.states[0] === s) ? [] : [s];
        renderGuests(state.guests, state.guestsShowAll);
        var again = el("guestsCounts").querySelector('[data-pill="' + s + '"]');
        if (again) { again.focus(); }
      };
    });

    if (all.length && !items.length) {
      el("guestTable").innerHTML = '<p class="muted small">' + esc(t("Nothing matches that filter.")) + " " +
        '<button type="button" class="linkish" id="guestsClearFilters">' + esc(t("Clear the filters")) + "</button></p>";
      el("guestsClearFilters").onclick = function () {
        state.guestFilter = { who: "", states: [] };
        state.guestSearch = "";
        el("guestsSearch").value = "";
        renderGuests(state.guests, state.guestsShowAll);
      };
      renderBulkBar();
      return;
    }
    if (!items.length) { el("guestTable").innerHTML = ""; renderBulkBar(); return; }

    var seen = signInData();
    var selCount = items.filter(function (g) { return state.selected[g.id]; }).length;
    var head = "<tr>" +
      '<th class="sel"><input id="guestsSelAll" type="checkbox" title="' + esc(t("Select everything shown")) +
      '" aria-label="' + esc(t("Select everything shown")) + '"' + (selCount === items.length ? " checked" : "") + " /></th>" +
      headerCell("who", "Who", true) + headerCell("status", "Status", true) +
      (seen.available ? headerCell("active", "Last active", false) : "") +
      '<th class="th-plain">' + esc(t("Why")) + "</th>" +
      (showOwner ? '<th class="th-plain">' + esc(t("Owner")) + "</th>" : "") + "<th></th></tr>";
    var rows = items.map(function (g, index) {
      var name = g.displayName || g.email;
      var owner = "";
      if (showOwner) {
        owner = '<td class="small" data-label="' + esc(t("Owner")) + '"><span data-i18n-skip>' +
          esc(g.orphaned ? t("nobody") : (g.owner && g.owner.displayName ? g.owner.displayName : t("nobody"))) + "</span>" +
          (g.orphaned ? ' <span class="pill warn">' + esc(t("unowned")) + "</span>" : "") + "</td>";
      }
      // Two facts, one column: when they last used the access, and whether they
      // ever accepted the invitation in the first place. The second is only
      // worth a line when it is not the ordinary "yes, on such a date".
      var active = "";
      if (seen.available) {
        active = '<td class="small" data-label="' + esc(t("Last active")) + '">' +
          (g.lastSignInLabel ? esc(g.lastSignInLabel) : '<span class="muted">' + esc(t("Never")) + "</span>") +
          (g.redemption === "accepted" ? "" : '<br><span class="small muted">' + esc(g.redemptionLabel) + "</span>") +
          "</td>";
      }
      // One way in, instead of four buttons per row. What they are and what can
      // be done about them belong on one surface, which is what Open gives.
      return "<tr>" +
        '<td class="sel"><input type="checkbox" data-select="' + esc(g.id) + '" aria-label="' +
        esc(t("Select {name}", { name: name })) + '"' + (state.selected[g.id] ? " checked" : "") + " /></td>" +
        '<td data-label="' + esc(t("Who")) + '" data-i18n-skip><strong>' + esc(g.displayName) + "</strong><br>" +
        '<span class="small muted">' + esc(g.email) + "</span></td>" +
        '<td data-label="' + esc(t("Status")) + '"><span class="pill ' + stateClass(g.state) + '">' + esc(stateLabel(g.state)) + "</span><br>" +
        '<span class="small muted">' + esc(g.statusLabel) + "</span></td>" + active +
        '<td class="small" data-label="' + esc(t("Why")) + '" data-i18n-skip>' + esc(g.reason || "") + "</td>" + owner +
        '<td class="open-cell"><button class="btn small" data-guest-open="' + index + '" data-guest-id="' + esc(g.id) + '">' +
        esc(t("Open")) + "</button></td></tr>";
    }).join("");
    el("guestTable").innerHTML = '<table class="guest-table"><thead>' + head + "</thead><tbody>" + rows + "</tbody></table>";
    el("guestsSelAll").indeterminate = selCount > 0 && selCount < items.length;

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
    el("guestTable").querySelectorAll("[data-select]").forEach(function (c) {
      c.onchange = function () {
        if (c.checked) { state.selected[c.dataset.select] = true; } else { delete state.selected[c.dataset.select]; }
        var n = items.filter(function (g) { return state.selected[g.id]; }).length;
        el("guestsSelAll").checked = n === items.length;
        el("guestsSelAll").indeterminate = n > 0 && n < items.length;
        renderBulkBar();
      };
    });
    el("guestsSelAll").onchange = function () {
      // Checked (also from the mixed state) selects every visible row,
      // unchecked clears them.
      var on = el("guestsSelAll").checked;
      items.forEach(function (g) { if (on) { state.selected[g.id] = true; } else { delete state.selected[g.id]; } });
      renderGuests(state.guests, state.guestsShowAll);
      if (el("guestsSelAll")) { el("guestsSelAll").focus(); }
    };
    renderBulkBar();
  }

  /* --- bulk actions on the selected rows --- */

  function selectedGuestIds() { return Object.keys(state.selected || {}); }

  // What the API said this caller may do with this guest, from the list row.
  function actionAvailable(g, key) {
    var a = (g.actions || []).filter(function (x) { return x.key === key; })[0];
    if (a) { return truthy(a.enabled); }
    if (key === "cancel") { return ["blocked", "deleted"].indexOf(g.state) < 0; }
    if (key === "renew") { return g.state !== "deleted"; }
    return false;
  }

  function bulkEligible(key) {
    var byId = {};
    (state.guestsVisible || []).forEach(function (g) { byId[g.id] = g; });
    return selectedGuestIds().map(function (id) { return byId[id]; })
      .filter(function (g) { return g && actionAvailable(g, key); });
  }

  function renderBulkBar() {
    var ids = selectedGuestIds();
    var bar = el("guestsBulk");
    bar.hidden = ids.length === 0;
    // A confirmation drawn for an earlier selection would act on the wrong rows.
    if (!state.bulkRunning) { el("guestsBulkConfirm").innerHTML = ""; }
    if (bar.hidden) { return; }
    el("guestsSelected").textContent = t(ids.length === 1 ? "{count} collaborator selected" : "{count} collaborators selected", { count: ids.length });
    el("guestsAssignRow").hidden = !state.guestsShowAll;
    el("guestsBulkRenew").disabled = state.bulkRunning || !bulkEligible("renew").length;
    el("guestsBulkCancel").disabled = state.bulkRunning || !bulkEligible("cancel").length;
  }

  function openBulk(key) {
    var list = bulkEligible(key);
    if (!list.length) { return; }
    var skipped = selectedGuestIds().length - list.length;
    var policy = (state.me && state.me.policy) || {};
    var renew = key === "renew";
    var host = el("guestsBulkConfirm");
    host.innerHTML = '<div class="bulk-confirm">' +
      "<p><strong>" + esc(t(renew ? "Extend access for {count}" : "End access for {count}", { count: list.length })) + "</strong></p>" +
      '<p class="small">' + esc(renew
        ? t("A new end date is set from today, not added to the current one.")
        : t("Sign-in is switched off straight away. The account is kept for the grace period, so you can undo this by extending them again.")) + "</p>" +
      '<ul class="bulk-names" data-i18n-skip>' + list.map(function (g) {
        return "<li>" + esc(g.displayName || g.email) + ' <span class="small muted">' + esc(g.email) + "</span></li>";
      }).join("") + "</ul>" +
      (skipped ? '<p class="small muted">' + esc(t(renew
        ? "{count} of the selected cannot be extended and are left out."
        : "{count} of the selected have already ended and are left out.", { count: skipped })) + "</p>" : "") +
      (renew ? field("bulkDays", "For how many days from today",
        '<input id="bulkDays" type="number" min="1" max="' + esc(policy.maxDays) + '" value="' + esc(policy.renewDays || policy.defaultDays) + '" />') : "") +
      '<div class="row"><button type="button" class="btn small primary" id="bulkGo">' + esc(t(renew ? "Extend them" : "End their access")) + "</button>" +
      '<button type="button" class="btn small ghost" id="bulkBack">' + esc(t("Cancel")) + "</button></div></div>";
    el("bulkBack").onclick = function () { host.innerHTML = ""; setStatus("guestsBulkStatus", ""); };
    el("bulkGo").onclick = function () {
      var days = renew ? Number(el("bulkDays").value) : 0;
      if (renew && (!(days >= 1) || (policy.maxDays && days > Number(policy.maxDays)))) {
        setStatus("guestsBulkStatus", t("Choose between 1 and {max} days.", { max: policy.maxDays || 1 }), "bad");
        return;
      }
      runBulk(key, list, days);
    };
    (el("bulkDays") || el("bulkGo")).focus();
  }

  // One request at a time: the API applies the safety limits per action, and a
  // burst of parallel calls would only make some of them fail for no reason.
  function runBulk(key, list, days) {
    var ok = 0, failed = [], simulated = false, done = 0;
    state.bulkRunning = true;
    renderBulkBar();
    el("guestsBulkConfirm").querySelectorAll("button, input").forEach(function (n) { n.disabled = true; });
    setStatus("guestsBulkStatus", t("Working... {done} of {total}", { done: 0, total: list.length }));
    return list.reduce(function (chain, g) {
      return chain.then(function () {
        var body = key === "renew" ? { action: "renew", days: days } : { action: "cancel" };
        return api("/guests/" + encodeURIComponent(g.id) + "/action", "POST", body)
          .then(function (data) { ok++; if (data && data.simulated) { simulated = true; } },
            function (e) { failed.push({ name: g.displayName || g.email, error: e.message }); })
          .then(function () {
            done++;
            setStatus("guestsBulkStatus", t("Working... {done} of {total}", { done: done, total: list.length }));
          });
      });
    }, Promise.resolve()).then(function () {
      state.bulkRunning = false;
      state.selected = {};
      setStatus("guestsBulkStatus", "");
      toast(failed.length
        ? t("{ok} done, {failed} failed.", { ok: ok, failed: failed.length })
        : t("All {count} done.", { count: ok }), failed.length ? "bad" : "ok");
      if (simulated) { toast(t("Simulation mode is on, so nothing was actually changed."), "ok"); }
      failed.slice(0, 5).forEach(function (x) { toast(t("{name}: {error}", { name: x.name, error: x.error }), "bad"); });
      if (failed.length > 5) { toast(t("And {count} more failed.", { count: failed.length - 5 }), "bad"); }
      return loadGuests();
    });
  }

  // Comma separated, quoted, with a leading apostrophe on anything a
  // spreadsheet would run as a formula.
  function csvCell(v) {
    var s = String(v == null ? "" : v);
    if (/^[=+\-@\t\r]/.test(s)) { s = "'" + s; }
    return '"' + s.replace(/"/g, '""') + '"';
  }

  // The list as it is on screen: filtered and sorted.
  function exportGuestsCsv() {
    var items = state.guestsVisible || [];
    var me = (state.me && state.me.user) || {};
    var rows = [[t("Name"), t("Email"), t("Status"), t("End date"), t("Owner"), t("Reason"), t("Last active"), t("Invited")]];
    items.forEach(function (g) {
      var owner = g.owner ? (g.orphaned ? "" : g.owner.displayName) : (state.guestsShowAll ? "" : (me.displayName || me.email || ""));
      rows.push([g.displayName, g.email, stateLabel(g.state), g.expiresOn, owner, g.reason, g.lastSignIn, g.invitedAt]);
    });
    // The byte order mark makes Excel read the file as UTF-8.
    var text = "\ufeff" + rows.map(function (r) { return r.map(csvCell).join(","); }).join("\r\n");
    var url = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
    var a = document.createElement("a");
    a.href = url;
    a.download = "collaborators-" + new Date().toISOString().slice(0, 10) + ".csv";
    document.body.appendChild(a);
    a.click();
    a.parentNode.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
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
              "<span><strong data-i18n-skip>" + esc(u.displayName) + "</strong>" +
              (u.isSelf ? ' <span class="pill">' + esc(t("you")) + "</span>" : "") + "<br>" +
              '<span class="small muted" data-i18n-skip>' + esc(u.userPrincipalName || u.mail || "") + "</span></span></button>";
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
      setStatus("guestsAssignStatus", t("Assigning {count}...", { count: ids.length }));
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

    el("guestsBulkRenew").onclick = function () { openBulk("renew"); };
    el("guestsBulkCancel").onclick = function () { openBulk("cancel"); };
    el("guestsExport").onclick = exportGuestsCsv;

    var searchDelay = null;
    el("guestsSearch").addEventListener("input", function () {
      if (searchDelay) { clearTimeout(searchDelay); }
      searchDelay = setTimeout(function () {
        state.guestSearch = el("guestsSearch").value;
        if (state.guests) { renderGuests(state.guests, state.guestsShowAll); }
      }, 200);
    });
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

  // guest is a list row, or just { id } for a deep link. action opens straight
  // on that action once the full record is in (#guest/<id>/renew).
  function openGuest(guest, action) {
    var stub = !guest.state;
    var opener = document.activeElement;
    state.drawer = { guest: guest, key: null, loading: true, stub: stub, opener: opener };
    el("gdName").textContent = guest.displayName || guest.email || "";
    el("gdEmail").textContent = guest.email || "";
    el("guestDrawer").hidden = false;
    setHash("#guest/" + guest.id + (action ? "/" + action : ""));
    if (stub) {
      el("gdBody").innerHTML = '<p class="row small muted"><span class="spinner"></span> ' + esc(t("Loading...")) + "</p>";
    } else {
      renderGuestOverview();
    }
    el("guestDrawer").querySelector(".drawer-panel").focus();

    // The list already carries everything except what they can reach, so the
    // drawer opens on what we have and fills that section in when it arrives.
    // Waiting for a round trip before showing anything would make every click
    // feel slow to hide one section.
    api("/guests?id=" + encodeURIComponent(guest.id))
      .then(function (data) {
        if (!state.drawer || state.drawer.guest.id !== guest.id) { return; }   // closed, or moved on
        var full = data.guest || guest;
        state.drawer.guest = full;
        state.drawer.loading = false;
        state.drawer.stub = false;
        el("gdName").textContent = full.displayName || full.email || "";
        el("gdEmail").textContent = full.email || "";
        if (action && !state.drawer.key && (full.actions || []).some(function (a) { return a.key === action && truthy(a.enabled); })) {
          renderGuestAction(action);
          return;
        }
        if (!state.drawer.key) { renderGuestOverview(); }
      })
      .catch(function (e) {
        if (!state.drawer || state.drawer.guest.id !== guest.id) { return; }
        state.drawer.loading = false;
        state.drawer.loadError = e.message;
        if (state.drawer.stub) {
          el("gdBody").innerHTML = errorHtml(e);
          wireCopyButtons(el("gdBody"));
          return;
        }
        if (!state.drawer.key) { renderGuestOverview(); }
      });
  }

  // fromRoute: the hash already moved on (Back), so leave it alone.
  function closeGuest(fromRoute) {
    var d = state.drawer;
    el("guestDrawer").hidden = true;
    state.drawer = null;
    if (fromRoute !== true && /^#guest\//.test(window.location.hash)) { setHash("#guests", true); }
    if (!d) { return; }
    // Focus goes back to the Open button that opened it, or to that row's
    // button if the list has been redrawn since.
    var back = (d.opener && d.opener !== document.body && document.contains(d.opener)) ? d.opener
      : document.querySelector('[data-guest-id="' + cssEscape(d.guest.id) + '"]');
    if (back && back.focus) { back.focus(); }
  }

  // raw: the value is data (a name), not something to translate.
  function fact(label, value, raw) {
    if (!value) { return ""; }
    return '<div class="fact"><div class="k">' + esc(label) + '</div><div class="v"' + (raw ? " data-i18n-skip" : "") + ">" +
      esc(value) + "</div></div>";
  }

  function renderGuestOverview() {
    var d = state.drawer;
    if (!d) { return; }
    var g = d.guest;
    d.key = null;
    setHash("#guest/" + g.id, true);

    var facts =
      fact(g.state === "pending" ? "Ends" : "Access until", g.expiresOnLabel) +
      fact("Days left", g.daysLeft > 0 ? String(g.daysLeft) : "") +
      fact("Accepted", g.redemptionLabel) +
      (signInData().available ? fact("Last active", g.lastSignInLabel || t("Never signed in")) : "") +
      fact("Owner", g.owner ? (g.orphaned ? t("nobody") : (g.owner.displayName || t("nobody"))) : "", true) +
      fact("Invited", g.invitedAt ? relativeIso(g.invitedAt) : "") +
      fact("Extended", g.renewCount ? t(Number(g.renewCount) === 1 ? "once" : "{count} times", { count: g.renewCount }) : "");

    // Actions first. They are why somebody opened this, and putting them under a
    // list that grows with every share meant scrolling past everything a guest
    // can reach to find the button that ends their access.
    var body =
      '<p><span class="pill ' + stateClass(g.state) + '">' + esc(stateLabel(g.state)) + "</span> " +
      '<span class="small muted">' + esc(g.statusLabel) + "</span></p>" +
      renderActionSection() +
      (g.reason ? "<h3>" + esc(t("Why they are here")) + '</h3><p data-i18n-skip>' + esc(g.reason) + "</p>" : "") +
      "<h3>" + esc(t("The details")) + "</h3>" + '<div class="facts">' + facts + "</div>" +
      renderAccessSection();

    el("gdBody").innerHTML = body;
    el("gdBody").querySelectorAll("[data-action]").forEach(function (b) {
      b.onclick = function () { renderGuestAction(b.dataset.action); };
    });
    el("gdBody").querySelectorAll("[data-unshare]").forEach(function (b) {
      b.onclick = function () { unshareItem(b.dataset.unshare, b.dataset.what); };
    });
    // Both start the share wizard with this person already chosen.
    [["gdShare", "files"], ["gdTeam", "teams"]].forEach(function (pair) {
      var b = el(pair[0]);
      if (!b) { return; }
      b.onclick = function () {
        var who = { id: g.id, email: g.email, displayName: g.displayName };
        closeGuest();
        startShare(pair[1], who);
      };
    });
  }

  function unshareItem(itemId, what) {
    if (!state.drawer) { return; }
    var guest = state.drawer.guest;
    var buttons = el("gdBody").querySelectorAll("[data-unshare]");
    buttons.forEach(function (b) { b.disabled = true; });
    api("/guests/" + encodeURIComponent(guest.id) + "/action", "POST", { action: "unshare", itemId: itemId })
      .then(function (data) {
        toast(data.message || t("{name} is no longer shared.", { name: what }), "ok");
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
    var files = live && (truthy(caps.shareFiles) || truthy(caps.shareFolders)) && sharingAllowed().ok;
    var teams = live && truthy(caps.shareTeams);
    var shareButton = (files || teams)
      ? '<p class="row" style="margin-top:10px">' +
      (files ? '<button class="btn small" id="gdShare">' + esc(t(items && items.length ? "Share something else" : "Share something now")) + "</button>" : "") +
      (teams ? '<button class="btn small" id="gdTeam">' + esc(t("Add to a Team")) + "</button>" : "") + "</p>"
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
      // Each piece translated on its own; the joined line is skipped by the
      // sweep because it carries a colleague's name.
      var by = it.sharedByYou ? t("You") : (it.sharedBy || t("somebody else"));
      var meta = [by, it.kindLabel ? t(it.kindLabel) : "", it.roleLabel ? t(it.roleLabel) : "",
        it.sharedAtLabel ? t("shared {when}", { when: t(it.sharedAtLabel) }) : ""]
        .filter(function (m) { return m; }).join(" · ");

      var action = "";
      if (it.canRevoke) {
        action = '<button class="btn small ghost" data-unshare="' + esc(it.id) + '" data-what="' + esc(it.name) + '">Unshare</button>';
      } else if (it.revokeBlockedReason) {
        action = '<span class="small muted" title="' + esc(it.revokeBlockedReason) + '">-</span>';
      }

      // A redacted name is a kind ("File"), so that one is translated.
      return '<div class="access-row"><span class="icon-cell">' + (ICONS[it.icon] || ICONS.file) + "</span>" +
        '<span class="grow"><strong' + (it.redacted ? ' class="muted"' : " data-i18n-skip") + ">" + name + "</strong><br>" +
        '<span class="small muted" data-i18n-skip>' + esc(meta) + "</span></span>" + action + "</div>";
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
      return '<span class="small muted">' + esc(t("{action}: {reason}", { action: t(a.label), reason: t(a.reason) })) + "</span>";
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
    setHash("#guest/" + d.guest.id + "/" + key, true);

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
          : (data.message || t(d.spec.done, { name: name, until: until ? t(until) : "" })), "ok");
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

  // Whose a guest is, said in a sentence that names nobody inside the sweep.
  function ownerNote(g, untracked) {
    if (g.mine) { return t("yours"); }
    if (g.owner && g.owner.displayName) { return t("owned by {name}", { name: g.owner.displayName }); }
    return g.tracked ? t("nobody looks after them") : t(untracked || "not tracked yet");
  }

  function renderMatches(items) {
    var host = el("invMatches");
    if (!items || !items.length) { host.innerHTML = ""; return; }
    host.innerHTML = '<p class="small muted matches-title">' + esc(t("People we already work with:")) + "</p>" +
      items.map(function (g) {
        return '<button type="button" class="match" data-email="' + esc(g.email) + '" data-i18n-skip>' +
          "<span><strong>" + esc(g.displayName) + "</strong><br>" +
          '<span class="small muted">' + esc(g.email) + "</span></span>" +
          '<span class="small muted">' + esc(ownerNote(g)) + "</span></button>";
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
  var searchSeq = 0;
  function scheduleSearch() {
    var value = el("invSearch").value.trim();
    var mine = ++searchSeq;
    el("invCheck").disabled = !looksLikeEmail(value);
    el("invVerdict").innerHTML = "";
    if (searchTimer) { clearTimeout(searchTimer); }
    if (value.length < 2) { el("invMatches").innerHTML = ""; return; }
    searchTimer = setTimeout(function () {
      api("/guests?search=" + encodeURIComponent(value))
        .then(function (data) { if (mine === searchSeq) { renderMatches(data.items); } })
        .catch(function () { if (mine === searchSeq) { el("invMatches").innerHTML = ""; } });
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
        '<span id="invSendStatus" class="status" role="status"></span></div>'
      );
    } else if ((v.verdict === "notFound" || v.verdict === "unowned") && v.inviteBlockedReason) {
      parts.push('<p class="status bad">' + esc(v.inviteBlockedReason) + "</p>");
    } else if (v.verdict === "unowned" && v.canClaim) {
      parts.push(
        field("invClaimReason", "Why do you work with them?" + (policy.requireReason ? "" : " (optional)"),
          '<textarea id="invClaimReason" maxlength="400" rows="3"></textarea>'),
        field("invClaimDays", "Keep their access for how many days", '<input id="invClaimDays" type="number" min="1" max="' +
          esc(policy.maxDays) + '" value="' + esc(policy.defaultDays) + '" />'),
        '<div class="row"><button id="invClaim" class="btn primary" data-guest="' + esc(v.guest.id) +
        '">Take them on</button><button class="btn ghost" data-view-link="guests">Cancel</button>' +
        '<span id="invClaimStatus" class="status" role="status"></span></div>'
      );
    } else if (v.verdict === "other") {
      if (v.canAsk) {
        parts.push(
          field("invAskMessage", "Send them a note (optional)",
            '<textarea id="invAskMessage" maxlength="600" rows="3" placeholder="Could you share the proposal folder with them?"></textarea>'),
          '<div class="row"><button id="invAsk" class="btn primary" data-guest="' + esc(v.guest.id) + '" data-i18n-skip>' +
          esc(v.owner && v.owner.displayName ? t("Ask {name}", { name: v.owner.displayName }) : t("Ask the owner")) + '</button>' +
          '<button class="btn ghost" data-view-link="guests">Back</button><span id="invAskStatus" class="status" role="status"></span></div>'
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
      .map(function (l) {
        // { text, raw: true } is data (a file name, an address), not a sentence.
        return typeof l === "object" ? "<div data-i18n-skip>" + esc(l.text) + "</div>" : "<div>" + esc(l) + "</div>";
      }).join("");
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
      : t(doneMessage, { name: g.displayName || g.email || "", until: until ? t(until) : "" });
    var lines = [];
    if (data.simulated) {
      lines.push(t("{name} would have been set up until {until}.", { name: g.displayName || g.email || "", until: until ? t(until) : "" }));
    }
    else if (g.email) {
      lines.push(until ? t("{email}, until {until}", { email: g.email, until: t(until) }) : { text: g.email, raw: true });
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
  // drawer's Share or Add to a Team button). The "who" step is then skipped.
  function startShare(mode, recipient) {
    clearHomeResult();
    state.share = {
      mode: mode, step: 0, target: null, recipient: recipient || null, newGuest: null,
      lockedRecipient: !!recipient, crumb: [], pane: mode === "teams" ? "teams" : "recent",
      siteId: "", siteUrl: "", siteName: "", lastLoad: null
    };
    el("shPerson").value = "";
    el("shSearch").value = "";
    el("shMatches").innerHTML = "";
    el("shNewGuest").innerHTML = "";
    el("shMessage").value = "";
    el("shCrumb").innerHTML = "";
    el("shItems").innerHTML = "";
    el("shError").hidden = true;
    el("shError").innerHTML = "";
    el("shGo").disabled = false;
    setStatus("shWhoStatus", "");
    setStatus("shStatus", "");
    showView("share");
    renderShareStep();
  }

  // Back to the top of a pane: the site context goes with the crumb, or a
  // blocked-site banner and a stale siteId would follow into Recent.
  function leaveSite() {
    var s = state.share;
    s.crumb = []; s.siteId = ""; s.siteUrl = ""; s.siteName = "";
  }

  function renderShareStep() {
    var s = state.share;
    // With the person already chosen there are two steps, not three, and the
    // indicator should say so rather than showing a step nobody will see.
    var labels = s.lockedRecipient ? ["What", "Confirm"] : SHARE_STEPS;
    var shown = s.lockedRecipient ? (s.step === 0 ? 0 : 1) : s.step;
    el("shSteps").innerHTML = labels.map(function (label, i) {
      return '<span class="step' + (i === shown ? " active" : "") + '">' + (i + 1) + ". " + esc(t(label)) + "</span>";
    }).join(" ");
    el("shPick").hidden = s.step !== 0;
    el("shWho").hidden = s.step !== 1;
    el("shConfirm").hidden = s.step !== 2;
    el("shBack").hidden = s.step === 0;

    if (s.step === 0) {
      el("shPickTitle").textContent = s.mode === "teams" ? "Choose a Team"
        : ({ "file": "Choose a file", "folder": "Choose a folder" }[shareLabel()] || "Choose a file or folder");
      el("shPickIntro").textContent = s.mode === "teams"
        ? t("Only Teams you own, and only those that accept guests.")
        : (shareLabel() === "folder"
          ? t("You will only see what you can already open yourself. Only folders can be shared here; open one to look inside.")
          : t("You will only see what you can already open yourself."));
      el("shSearchWrap").hidden = s.mode === "teams";
      if (s.mode === "teams") { loadTeams(); }
      else {
        renderPanes();
        // Coming back from a later step re-runs whatever was on screen, so the
        // list and the crumb above it agree.
        if (s.lastLoad) { loadPane(s.lastLoad.pane, s.lastLoad.extra); } else { loadPane(s.pane); }
      }
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
        leaveSite();
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
      return '<button type="button" class="linkish" data-crumb="' + i + '" data-i18n-skip>' + esc(c.name) + "</button>";
    }).join(" / ");
    host.querySelectorAll("[data-crumb]").forEach(function (b) {
      b.onclick = function () {
        var i = Number(b.dataset.crumb);
        var entry = state.share.crumb[i];
        state.share.crumb = state.share.crumb.slice(0, i);
        if (i === 0) { state.share.siteId = ""; state.share.siteUrl = ""; state.share.siteName = ""; }
        openContainer(entry, true);
      };
    });
  }

  // Only the latest request may draw: switching panes quickly would otherwise
  // let a slow earlier answer replace the list that was asked for last.
  var paneSeq = 0;
  function loadPane(pane, extra) {
    var mine = ++paneSeq;
    state.share.lastLoad = { pane: pane, extra: extra || null };
    var query = "?pane=" + encodeURIComponent(pane);
    Object.keys(extra || {}).forEach(function (k) {
      if (extra[k]) { query += "&" + k + "=" + encodeURIComponent(extra[k]); }
    });
    setStatus("shPickStatus", "Loading...");
    el("shItems").innerHTML = "";
    el("shCrumb").innerHTML = "";
    el("shError").hidden = true;
    return api("/browse" + query).then(function (data) {
      if (mine !== paneSeq) { return; }
      setStatus("shPickStatus", "");
      renderPickItems(data.items || [], data.emptyReason);
    }).catch(function (e) {
      if (mine !== paneSeq) { return; }
      setStatus("shPickStatus", "");
      el("shItems").innerHTML = errorHtml(e) +
        '<p><button type="button" class="btn small ghost" id="shPickBackToSites">Back to the site list</button></p>';
      wireCopyButtons(el("shItems"));
      el("shPickBackToSites").onclick = function () {
        leaveSite();
        state.share.pane = "sites";
        renderPanes();
        loadPane("sites");
      };
    });
  }

  function renderPickItems(items, emptyReason) {
    var host = el("shItems");
    renderCrumb();
    // Kept so a site's settings arriving after the user has already opened it
    // can redraw what they are looking at.
    state.share.shown = { items: items, emptyReason: emptyReason };

    // A site known to refuse external sharing, either because SharePoint said so
    // when the list was built or because it refused a share earlier. Said before
    // anything is picked, rather than after a guest has been created for it.
    var s = state.share;
    var known = s.siteUrl && siteSettingsCache()[s.siteUrl];
    if (known && known.known && !truthy(known.canShareExternally) && s.siteId && !blockedSites()[s.siteId]) {
      blockedSites()[s.siteId] = known.reason || "SharePoint does not allow external sharing here.";
    }
    var blocked = s.siteId && blockedSites()[s.siteId];
    if (blocked && !blockedAck()[s.siteId]) {
      host.innerHTML = '<div class="banner error"><div><div class="title">This site does not allow external sharing</div>' +
        '<div class="small"><span>' + esc(blocked) + "</span> <span>" + esc(t("Nothing here can be shared outside the company. The person who owns the site can change that in SharePoint.")) + "</span></div>" +
        '<div class="row" style="margin-top:10px"><button type="button" class="btn small" id="shPickLeaveSite">Choose somewhere else</button>' +
        '<button type="button" class="btn small ghost" id="shPickAnyway">Look anyway</button></div></div></div>';
      el("shPickLeaveSite").onclick = function () {
        leaveSite(); s.pane = "sites"; renderPanes(); loadPane("sites");
      };
      // Looking is allowed; sharing is not. The block is acknowledged rather
      // than dropped, so the list below stays honest about what it can do.
      el("shPickAnyway").onclick = function () { blockedAck()[s.siteId] = true; renderPickItems(items, emptyReason); };
      return;
    }
    // The same block, once the user has said they want to see the contents
    // anyway, or when SharePoint answered only after they had already opened
    // the site. Every share control below is disabled while this is showing.
    var blockedBanner = blocked
      ? '<div class="banner warn"><div><div class="title">Sharing is blocked on this site</div>' +
      '<div class="small"><span>' + esc(blocked) + "</span> <span>" + esc(t("You can look around, but nothing here can be shared outside the company.")) + "</span></div>" +
      '<div class="row" style="margin-top:10px"><button type="button" class="btn small" id="shPickLeaveSite">Choose somewhere else</button></div></div></div>'
      : "";
    if (!items.length) {
      host.innerHTML = blockedBanner + '<p class="muted small">' + esc(emptyReason || "Nothing here.") + "</p>";
      wireLeaveSite();
      return;
    }
    // A note that applies to a list that is not empty: sites dropped for no
    // longer existing, for instance.
    var note = emptyReason ? '<p class="small muted">' + esc(emptyReason) + "</p>" : "";
    // A folder is both a place to go into and a thing that can be shared, so it
    // gets two separate controls rather than one ambiguous click. The row is a
    // container, never a button, so the controls inside stay real buttons and
    // keyboard navigation works.
    host.innerHTML = blockedBanner + note + items.map(function (it, i) {
      var openable = it.kind === "folder" || it.kind === "site" || it.kind === "drive";
      if (blocked) { it = Object.assign({}, it, { canShare: false, shareBlockedReason: t("sharing is blocked on this site") }); }
      // What it is, where it lives, and when it was last touched. A column of
      // twenty file names is not enough to pick from: half of them are called
      // "Proposal" and the icon is eight pixels of guesswork.
      // Translated piece by piece: the joined line holds a path, which is data.
      var facts = [it.category ? t(it.category) : "", it.path, it.whenLabel ? t(it.whenLabel) : ""].filter(function (f) { return f; });
      var main = '<button type="button" class="pick-main" data-open="' + i + '"' +
        (openable || it.canShare ? "" : " disabled") + ">" +
        '<span class="icon-cell">' + (ICONS[it.icon] || ICONS.file) + "</span>" +
        "<span><strong data-i18n-skip>" + esc(it.name) + "</strong>" +
        // Filled in when SharePoint answers for this site, which is after the
        // list is already usable.
        (it.kind === "site" ? '<span data-site-note="' + esc(it.webUrl) + '"></span>' : "") +
        (facts.length ? '<br><span class="small muted" data-i18n-skip>' + esc(facts.join(" · ")) + "</span>" : "") +
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

    wireLeaveSite();
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

  function wireLeaveSite() {
    var b = el("shPickLeaveSite");
    if (!b) { return; }
    b.onclick = function () {
      leaveSite();
      state.share.pane = "sites";
      renderPanes();
      loadPane("sites");
    };
  }

  function siteSettingsCache() {
    if (!state.siteSettings) { state.siteSettings = {}; }
    return state.siteSettings;
  }

  // One site, on demand. Used when somebody opens a site faster than the list
  // sweep reached it, or arrives at one by another route.
  function ensureSiteSettings(item) {
    var cache = siteSettingsCache();
    var url = safeUrl(item.webUrl);
    if (!url || cache[url]) { return Promise.resolve(cache[url]); }
    return api("/browse?pane=siteinfo&q=" + encodeURIComponent(url))
      .then(function (data) { cache[url] = data.siteSettings || { known: false }; })
      .catch(function (e) { cache[url] = { known: false, detail: e.message }; })
      .then(function () {
        annotateSiteRow(item);
        // If they are already inside that site, the warning belongs on the
        // screen they are actually looking at.
        var s = state.share;
        if (s && s.siteUrl === url && s.shown) { renderPickItems(s.shown.items, s.shown.emptyReason); }
      });
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
        .catch(function (e) { cache[it.webUrl] = { known: false, detail: e.message }; })
        .then(function () {
          annotateSiteRow(it);
          var s = state.share;
          if (s && s.siteUrl === it.webUrl && s.shown) { renderPickItems(s.shown.items, s.shown.emptyReason); }
          pump();
        });
    }
    for (var i = 0; i < 4; i++) { pump(); }
  }

  function annotateSiteRow(item) {
    var info = siteSettingsCache()[item.webUrl];
    if (!info) { return; }

    // Not being able to read the settings is worth saying once, above the list,
    // rather than silently showing nothing on every row. Consent not granted is
    // the one an administrator can fix, and it looks like every other failure
    // unless it is named.
    if (!info.known) {
      if (truthy(info.needsConsent) && !state.siteInfoNoted) {
        state.siteInfoNoted = true;
        var top = el("shItems");
        if (top) {
          var note = document.createElement("p");
          note.className = "small status bad";
          note.textContent = info.reason || "Site sharing status is unavailable.";
          top.insertBefore(note, top.firstChild);
        }
      }
      return;
    }

    var host = document.querySelector('[data-site-note="' + cssEscape(item.webUrl) + '"]');
    if (!host) { return; }
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

  // Sites whose block the user has chosen to look past. Kept separate from the
  // block itself so the warning survives, and the share controls stay disabled.
  function blockedAck() {
    if (!state.blockedAck) { state.blockedAck = {}; }
    return state.blockedAck;
  }

  function openContainer(entry, isCrumb) {
    var s = state.share;
    if (entry.kind === "site") {
      s.siteId = entry.id; s.siteName = entry.name; s.siteUrl = entry.webUrl;
      ensureSiteSettings(entry);
    }
    if (!isCrumb) { s.crumb.push(entry); }
    var extra = entry.kind === "site"
      ? { siteId: entry.id }
      : { driveId: entry.driveId || entry.id, itemId: entry.kind === "drive" ? "" : entry.id };
    loadPane("children", extra);
  }

  function loadTeams() {
    var mine = ++paneSeq;
    setStatus("shPickStatus", "Loading your Teams...");
    el("shItems").innerHTML = "";
    el("shPanes").innerHTML = "";
    return api("/teams").then(function (data) {
      if (mine !== paneSeq) { return; }
      setStatus("shPickStatus", data.tenantAllowsGuests ? "" : "This tenant does not allow guests in Teams.", data.tenantAllowsGuests ? "" : "bad");
      var items = data.items || [];
      if (!items.length) {
        // The API distinguishes "you own nothing", "none of them are Teams" and
        // "we could not tell", because those need different things done.
        el("shItems").innerHTML = '<p class="muted small">' +
          esc(data.emptyReason || "You do not own any Teams.") + "</p>";
        return;
      }
      el("shItems").innerHTML = items.map(function (team, i) {
        return '<button type="button" class="match" data-team="' + i + '"' + (team.canShare ? "" : " disabled") + ">" +
          '<span><span class="icon-cell">' + ICONS.team + '</span> <strong data-i18n-skip>' + esc(team.name) + "</strong>" +
          (team.description ? '<br><span class="small muted" data-i18n-skip>' + esc(team.description) + "</span>" : "") + "</span>" +
          '<span class="small muted">' + esc(team.canShare ? t("Add a guest") : t(team.shareBlockedReason || "")) + "</span></button>";
      }).join("");
      el("shItems").querySelectorAll("[data-team]").forEach(function (b) {
        b.onclick = function () {
          var team = items[Number(b.dataset.team)];
          chooseTarget({ kind: "team", teamId: team.id, name: team.name });
        };
      });
    }).catch(function (e) { if (mine === paneSeq) { setStatus("shPickStatus", e.message, "bad"); } });
  }

  function chooseTarget(target) {
    state.share.target = target;
    state.share.step = state.share.lockedRecipient ? 2 : 1;
    renderShareStep();
  }

  /* --- step 2: who, search first --- */

  // Every search and verdict carries the number of the keystroke it answers;
  // only the latest may draw, or a slow answer for "jane@partner.co" could
  // offer to invite that typo after the full address was already found.
  var sharePersonTimer = null;
  var sharePersonSeq = 0;
  function sharePersonInput() {
    var term = el("shPerson").value.trim();
    var mine = ++sharePersonSeq;
    el("shNewGuest").innerHTML = "";
    setStatus("shWhoStatus", "");
    if (sharePersonTimer) { clearTimeout(sharePersonTimer); }
    if (term.length < 2) { el("shMatches").innerHTML = ""; return; }
    sharePersonTimer = setTimeout(function () {
      api("/guests?search=" + encodeURIComponent(term)).then(function (data) {
        if (mine !== sharePersonSeq) { return; }
        var items = data.items || [];
        var exact = items.filter(function (g) { return String(g.email).toLowerCase() === term.toLowerCase(); });
        renderSharePersonMatches(items);
        // Only after a search has actually run, and only when nothing here is
        // the person, is inviting somebody new offered at all.
        if (looksLikeEmail(term) && !exact.length) { offerNewRecipient(term, mine); }
      }).catch(function (e) { if (mine === sharePersonSeq) { setStatus("shWhoStatus", e.message, "bad"); } });
    }, 350);
  }

  function renderSharePersonMatches(items) {
    var host = el("shMatches");
    if (!items.length) { host.innerHTML = '<p class="small muted">' + esc(t("Nobody we already work with matches that.")) + "</p>"; return; }
    host.innerHTML = '<p class="small muted matches-title">' + esc(t("People we already work with:")) + "</p>" +
      items.map(function (g) {
        return '<button type="button" class="match" data-email="' + esc(g.email) + '" data-id="' + esc(g.id) + '"' +
          (g.tracked ? "" : " disabled") + " data-i18n-skip>" +
          "<span><strong>" + esc(g.displayName) + "</strong><br>" +
          '<span class="small muted">' + esc(g.email) + "</span></span>" +
          '<span class="small muted">' + esc(g.tracked ? ownerNote(g) : t("not set up here yet")) + "</span></button>";
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

  function offerNewRecipient(email, seq) {
    setStatus("shWhoStatus", t("Checking {email}...", { email: email }));
    api("/guests?email=" + encodeURIComponent(email)).then(function (v) {
      if (seq !== sharePersonSeq) { return; }
      setStatus("shWhoStatus", "");
      var host = el("shNewGuest");
      if (v.verdict === "notFound" && v.canInvite) {
        var policy = state.me.policy;
        host.innerHTML = '<div class="card"><h3 data-i18n-skip>' + esc(t("Invite {email}", { email: email })) + "</h3>" +
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
        go.setAttribute("data-i18n-skip", "");
        go.textContent = t("Share with {name}", { name: v.guest.displayName || v.guest.email });
        go.onclick = function () { state.share.step = 2; renderShareStep(); };
        host.appendChild(go);
      } else {
        host.innerHTML = '<p class="status bad">' + esc(v.inviteBlockedReason || v.message) + "</p>";
      }
    }).catch(function (e) { if (seq === sharePersonSeq) { setStatus("shWhoStatus", e.message, "bad"); } });
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
      el("shRole").disabled = false;
      el("shRole").value = caps.defaultRole || "read";
    }
    var kind = isTeam ? "Team" : ({ file: "File", folder: "Folder" }[s.target.kind] || s.target.kind);
    el("shSummary").innerHTML =
      '<p><strong data-i18n-skip>' + esc(s.target.name) + "</strong>" +
      '<br><span class="small muted">' + esc(t(kind)) + "</span></p>" +
      '<p data-i18n-skip><strong>' + esc(s.recipient.displayName || s.recipient.email) + "</strong>" +
      '<br><span class="small muted">' +
      esc(t(s.newGuest ? "{email}, will be invited now" : "{email}, already works with us", { email: s.recipient.email })) + "</span></p>";
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
    if (s.siteId && s.target.kind !== "team") { body.target = Object.assign({}, s.target, { siteId: s.siteId }); }

    el("shError").hidden = true;
    api("/share", "POST", body).then(function (data) {
      var lines = [];
      if (s.target && s.target.name) { lines.push({ text: s.target.name, raw: true }); }
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
        if (id) { blockedSites()[id] = t("SharePoint refused a share from here on {date}.", { date: new Date().toLocaleDateString() }); }
      }
      // The guest exists but the share did not happen. Offer the share alone,
      // so nobody is tempted to start again and invite the same person twice.
      if (e.data && e.data.guestCreated && e.data.guest && e.data.guest.id) {
        state.share.newGuest = null;
        state.share.recipient = { id: e.data.guest.id, email: e.data.guest.email, displayName: e.data.guest.displayName };
        toast(t("{name} was set up, but the share itself failed. Press Share to try just the share again.",
          { name: e.data.guest.displayName || e.data.guest.email }), "bad");
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
    var pickSearchTimer = null;
    el("shSearch").addEventListener("input", function () {
      var term = el("shSearch").value.trim();
      if (pickSearchTimer) { clearTimeout(pickSearchTimer); }
      if (term.length < 2) { return; }
      pickSearchTimer = setTimeout(function () {
        // Results span every site, so no site context carries over.
        leaveSite();
        renderPanes();
        loadPane("search", { q: term });
      }, 350);
    });
  }

  /* ---------------- configuration ----------------
     state.config.settings is what the server last saved and is never edited in
     place. Each admin tab lays its own form over a copy of it, so saving one
     tab can never carry another tab's unsaved edits along. Email edits live in
     state.emailDrafts until saved. */

  // The form as it was last drawn from the server, per tab, to tell edits apart.
  var baselines = { config: "", branding: "" };
  var ADMIN_STATUS = { config: "cfgStatus", branding: "brStatus", emails: "emStatus" };

  function enterAdminTab(name) {
    // Fresh from the server, unless this tab holds edits a reload would wipe.
    loadConfig(!isDirty(name)).then(function () {
      if (state.view !== name) { return; }
      if (name === "branding" && isDirty("branding")) { previewBrandColours(); }
      if (name === "emails") { refreshPreview(); }
    }).catch(function (e) { setStatus(ADMIN_STATUS[name], e.message, "bad"); });
  }

  function loadConfig(force) {
    if (state.config && !force) { return Promise.resolve(state.config); }
    return api("/config").then(function (data) {
      state.config = data;
      renderAdminSections();
      return data;
    });
  }

  // Redraws each tab from the saved settings, except a tab holding unsaved
  // edits. saved names the tab that was just saved; it is always redrawn.
  function renderAdminSections(saved) {
    if (saved === "config" || !isDirty("config")) { renderConfig(); } else { renderConfigExtras(); }
    if (saved === "branding" || !isDirty("branding")) { renderBranding(); }
    if (saved === "emails" || !isDirty("emails")) { renderEmails(); }
    updateDirty();
  }

  function isDirty(section) {
    if (!state.config) { return false; }
    if (section === "config") { return !!baselines.config && JSON.stringify(readConfigForm()) !== baselines.config; }
    if (section === "branding") {
      return state.pendingLogo !== undefined || (!!baselines.branding && JSON.stringify(readBrandingForm()) !== baselines.branding);
    }
    if (section === "emails") { return Object.keys(state.emailDrafts).length > 0; }
    return false;
  }

  function anyDirty() { return isDirty("config") || isDirty("branding") || isDirty("emails"); }

  // "Unsaved changes" next to each Save button, and a mark on the tab.
  function updateDirty() {
    [["config", "cfgDirty"], ["branding", "brDirty"], ["emails", "emDirty"]].forEach(function (p) {
      var dirty = isDirty(p[0]);
      el(p[1]).hidden = !dirty;
      var tab = document.querySelector('.tab[data-view="' + p[0] + '"]');
      if (tab) { tab.classList.toggle("dirty", dirty); }
    });
  }

  function listToText(list) { return (list || []).join(", "); }
  function textToList(text) {
    return String(text || "").split(/[,;\n]/).map(function (s) { return s.trim(); }).filter(Boolean);
  }

  // Copies form values over a copy of the saved settings, section by section.
  function overlay(base, form) {
    Object.keys(form).forEach(function (k) {
      var v = form[k];
      if (v && typeof v === "object" && !Array.isArray(v)) {
        if (!base[k] || typeof base[k] !== "object") { base[k] = {}; }
        Object.keys(v).forEach(function (kk) { base[k][kk] = v[kk]; });
      } else { base[k] = v; }
    });
    return base;
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
    el("cfgLogRetention").value = s.logRetentionDays;

    var lang = el("cfgLanguage");
    if (!lang.options.length) {
      lang.innerHTML = CBI18N.languages.map(function (l) {
        return '<option value="' + esc(l.code) + '">' + esc(l.label) + "</option>";
      }).join("");
    }
    lang.value = (s.portal && s.portal.defaultLanguage) || "en";
    el("cfgNotifyRedeem").checked = truthy(s.notifications.notifyOwnerOnRedeem);
    el("cfgOrphanDigest").checked = truthy(s.notifications.orphanDigest);

    renderConfigExtras();
    baselines.config = JSON.stringify(readConfigForm());
  }

  // The read-only parts of the Configuration tab, safe to redraw under edits.
  function renderConfigExtras() {
    // The sending mailbox is deliberately not editable here, and saying so where
    // somebody would otherwise go looking is the whole point of showing it.
    var sender = state.config.sender || {};
    el("cfgSender").value = sender.address || t("(not configured)");
    el("cfgSenderNote").innerHTML = esc(sender.note || "") +
      (sender.docsUrl ? ' <a href="' + esc(safeUrl(sender.docsUrl)) + '" target="_blank" rel="noopener noreferrer">How to re-run the deployment</a>.' : "");
    renderAdminAccess();
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

  // What the Configuration form says, and nothing else. The server sanitises
  // everything again, so this only has to be a faithful read.
  function readConfigForm() {
    return {
      expiry: {
        defaultDays: Number(el("cfgDefaultDays").value),
        maxDays: Number(el("cfgMaxDays").value),
        renewDays: Number(el("cfgRenewDays").value),
        graceDays: Number(el("cfgGraceDays").value),
        reminderDays: textToList(el("cfgReminderDays").value).map(Number),
        attribute: el("cfgAttribute").value,
        allowSelfRenew: el("cfgAllowSelfRenew").checked
      },
      invite: {
        inviterGroupId: el("cfgInviterGroupId").value.trim(),
        inviterGroupName: el("cfgInviterGroupName").value.trim(),
        allowedDomains: textToList(el("cfgAllowedDomains").value),
        blockedDomains: textToList(el("cfgBlockedDomains").value),
        guestDirectoryVisibility: el("cfgVisibility").value,
        requireReason: el("cfgRequireReason").checked,
        setSponsor: el("cfgSetSponsor").checked
      },
      sharing: {
        files: el("cfgShareFiles").checked,
        folders: el("cfgShareFolders").checked,
        teams: el("cfgShareTeams").checked,
        allowWrite: el("cfgAllowWrite").checked
      },
      adoption: {
        enabled: el("cfgAdoptionEnabled").checked,
        initialDays: Number(el("cfgAdoptionDays").value),
        useSponsors: el("cfgAdoptionSponsors").checked,
        useAuditLog: el("cfgAdoptionAudit").checked
      },
      inactivity: {
        enabled: el("cfgInactivityEnabled").checked,
        thresholdDays: Number(el("cfgInactivityDays").value),
        action: el("cfgInactivityAction").value,
        notifyOnce: el("cfgInactivityOnce").checked
      },
      safety: {
        enabled: el("cfgSafetyEnabled").checked,
        dailyCapInvite: Number(el("cfgCapInvite").value),
        perUserDailyInvites: Number(el("cfgCapPerUser").value),
        dailyCapBlock: Number(el("cfgCapBlock").value),
        dailyCapDelete: Number(el("cfgCapDelete").value),
        percentCeiling: Number(el("cfgCeiling").value)
      },
      dryRun: el("cfgDryRun").value === "true",
      notifications: {
        servicedeskEmail: el("cfgServicedesk").value.trim(),
        notifyOwnerOnRedeem: el("cfgNotifyRedeem").checked,
        orphanDigest: el("cfgOrphanDigest").checked
      },
      logRetentionDays: Number(el("cfgLogRetention").value),
      portal: { defaultLanguage: el("cfgLanguage").value }
    };
  }

  // The saved settings with this tab's form on top: branding and email
  // wording go back exactly as they were saved.
  function collectSettings() { return overlay(clone(state.config.settings), readConfigForm()); }

  // onSaved runs once the server has accepted, before anything is redrawn.
  function saveSettings(settings, statusId, okMessage, section, onSaved) {
    setStatus(statusId, "Saving...");
    return api("/config", "POST", { settings: settings }).then(function (data) {
      state.config = data;
      if (onSaved) { onSaved(); }
      renderAdminSections(section);
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
    var welcome = safeUrl(state.config.welcomeUrl);
    if (welcome && s.welcome.publishedUtc) {
      link.href = welcome + "/welcome.html";
      link.textContent = welcome + "/welcome.html";
    } else {
      link.removeAttribute("href");
      link.textContent = t("not published yet");
    }
    baselines.branding = JSON.stringify(readBrandingForm());
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
        '<span class="grow" data-i18n-skip><strong>' + linked(x.displayName || x.id, x.portalUrl) + "</strong><br>" +
        '<span class="small muted">' + esc(x.type || "") + " · " + esc(x.id) + "</span></span></div>";
    }).join("");

    host.innerHTML =
      '<div class="facts" style="margin-bottom:14px">' +
      '<div class="fact"><div class="k">Enterprise application</div><div class="v" data-i18n-skip>' +
      linked(app.displayName || t("(unknown)"), app.portalUrl) + "</div></div>" +
      '<div class="fact"><div class="k">Application (client) id</div><div class="v small">' + esc(app.appId || "") + "</div></div>" +
      "</div>" +
      "<h3 style=\"font-size:14px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em\">" +
      esc(t("Holds {role}", { role: a.role || t("the admin role") })) + "</h3>" +
      (who ? '<div class="access-list">' + who + "</div>" : "") +
      (a.error ? '<p class="status bad small">' + esc(a.error) + "</p>" : "");
  }

  function readBrandingForm() {
    return {
      branding: {
        companyName: el("brCompany").value.trim(),
        portalTitle: el("brTitle").value.trim(),
        portalSubtitle: el("brSubtitle").value.trim(),
        primaryColor: el("brPrimary").value,
        accentColor: el("brAccent").value
      },
      welcome: {
        headline: el("wcHeadline").value.trim(),
        message: el("wcMessage").value.trim(),
        buttonLabel: el("wcButton").value.trim(),
        extraAllowedHosts: textToList(el("wcHosts").value),
        autoRedirect: el("wcAuto").checked
      }
    };
  }

  // The saved settings with only the Branding tab's form on top.
  function collectBranding() { return overlay(clone(state.config.settings), readBrandingForm()); }

  // Live preview of the picked colours on the portal itself, before saving.
  function previewBrandColours() {
    var root = document.documentElement.style;
    var primary = el("brPrimary").value;
    var accent = el("brAccent").value;
    root.setProperty("--brand-primary", primary);
    root.setProperty("--brand-on-primary", readableOn(primary));
    root.setProperty("--brand-accent", accent);
    root.setProperty("--brand-on-accent", readableOn(accent));
    // The link colour is derived from BOTH pickers, so the preview has to
    // recompute it whichever one moved.
    root.setProperty("--brand-ink", brandInk(primary, accent));
  }

  // Leaving the tab without saving puts the saved colours back.
  function revertBrandPreview() {
    var root = document.documentElement.style;
    ["--brand-primary", "--brand-on-primary", "--brand-accent", "--brand-on-accent", "--brand-ink"]
      .forEach(function (p) { root.removeProperty(p); });
    var saved = (state.me && state.me.branding) || lastBranding;
    if (saved) { applyBranding(saved); }
  }

  function wireBrandingEditor() {
    function syncColour(picker, text) {
      picker.addEventListener("input", function () {
        text.value = picker.value;
        previewBrandColours();
      });
      text.addEventListener("change", function () {
        if (/^#[0-9a-fA-F]{6}$/.test(text.value.trim())) {
          picker.value = text.value.trim();
          picker.dispatchEvent(new Event("input", { bubbles: true }));
        } else {
          text.value = picker.value;
        }
      });
    }
    syncColour(el("brPrimary"), el("brPrimaryText"));
    syncColour(el("brAccent"), el("brAccentText"));

    el("brSave").onclick = function () {
      whileBusy(el("brSave"), function () {
        // The settings the admin has typed are captured BEFORE anything is sent,
        // so a logo upload in the middle can never be the reason a company name
        // goes back to what it was.
        var wanted = collectBranding();
        var logoChanged = state.pendingLogo !== undefined;
        setStatus("brStatus", "Saving...");
        return saveLogoIfChanged()
          .then(function (warning) {
            state.pendingLogo = undefined;
            el("brLogoFile").value = "";
            return saveSettings(wanted, "brStatus", "Saved. The portal, your emails and the public page all use this now.", "branding")
              .then(function () {
                // A logo change is a change even when no text field moved, so the
                // "nothing to save" line saveSettings writes would be a lie here.
                if (logoChanged) {
                  setStatus("brStatus", "Saved. The portal, your emails and the public page all use this now.", "ok");
                }
                if (warning) { toast(warning, "bad"); }
                renderBranding();
                updateDirty();
              });
          });
      }).catch(function (e) { setStatus("brStatus", e.message, "bad"); });
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
        updateDirty();
      };
      reader.readAsDataURL(file);
    };

    el("brLogoRemove").onclick = function () {
      state.pendingLogo = null;
      el("brLogoFile").value = "";
      setStatus("brStatus", "");
      renderLogoPreview();
      updateDirty();
    };
  }

  /* ---------------- email editor ---------------- */

  function currentTemplateEntry() {
    return (state.config.emailCatalog || []).filter(function (c) { return c.key === state.emailKey; })[0];
  }

  function savedTemplate(key) { return (state.config.settings.emails || {})[key] || {}; }

  function sameTemplate(a, b) {
    return truthy(a.enabled) === truthy(b.enabled) && String(a.subject || "") === String(b.subject || "") &&
      String(a.html || "") === String(b.html || "") && truthy(a.useBrandShell) === truthy(b.useBrandShell);
  }

  // The saved settings with every unsaved template on top: what the preview,
  // the test send and Save emails work from.
  function emailSettings() {
    var s = clone(state.config.settings);
    if (!s.emails) { s.emails = {}; }
    Object.keys(state.emailDrafts).forEach(function (k) { s.emails[k] = clone(state.emailDrafts[k]); });
    return s;
  }

  var AUDIENCE_LABELS = { guest: "{label} (to the guest)", owner: "{label} (to the owner)", admin: "{label} (to the admin)" };

  function renderEmails() {
    var select = el("emKey");
    if (!select.options.length) {
      (state.config.emailCatalog || []).forEach(function (c) {
        var o = document.createElement("option");
        o.value = c.key;
        o.textContent = t(AUDIENCE_LABELS[c.audience] || "{label}", { label: t(c.label) });
        select.appendChild(o);
      });
      state.emailKey = select.value = ((state.config.emailCatalog || [])[0] || {}).key || "";
    } else {
      select.value = state.emailKey;
    }
    renderTemplate();
  }

  function renderTemplate() {
    var entry = currentTemplateEntry();
    if (!entry) { return; }
    var tpl = state.emailDrafts[entry.key] || savedTemplate(entry.key);
    el("emDescription").textContent = entry.description;
    el("emEnabled").checked = truthy(tpl.enabled);
    el("emSubject").value = tpl.subject || "";
    el("emBody").value = tpl.html || "";
    el("emShell").checked = truthy(tpl.useBrandShell);

    var tokens = el("emTokens");
    tokens.innerHTML = "";
    (entry.tokens || []).forEach(function (tok) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = "token";
      b.setAttribute("data-i18n-skip", "");
      b.textContent = "{{" + tok + "}}";
      b.title = t("Insert this into the body");
      b.onclick = function () { insertToken("{{" + tok + "}}"); };
      tokens.appendChild(b);
    });

    // Only worth a round trip while somebody is looking at it.
    if (state.view === "emails") { refreshPreview(); }
  }

  function insertToken(text) {
    var box = el("emBody");
    var start = box.selectionStart || 0;
    var end = box.selectionEnd || 0;
    box.value = box.value.slice(0, start) + text + box.value.slice(end);
    box.selectionStart = box.selectionEnd = start + text.length;
    box.focus();
    captureTemplate();
    updateDirty();
    schedulePreview();
  }

  // Keeps the template on screen as a draft, or drops the draft when it is
  // back to what is saved.
  function captureTemplate() {
    var entry = currentTemplateEntry();
    if (!entry) { return; }
    var draft = {
      enabled: el("emEnabled").checked,
      subject: el("emSubject").value,
      html: el("emBody").value,
      useBrandShell: el("emShell").checked
    };
    if (sameTemplate(draft, savedTemplate(entry.key))) { delete state.emailDrafts[entry.key]; }
    else { state.emailDrafts[entry.key] = draft; }
  }

  var previewTimer = null;
  var previewSeq = 0;
  function schedulePreview() {
    if (previewTimer) { clearTimeout(previewTimer); }
    previewTimer = setTimeout(refreshPreview, 500);
  }

  function refreshPreview() {
    var entry = currentTemplateEntry();
    if (!entry) { return; }
    captureTemplate();
    var mine = ++previewSeq;
    api("/config/testmail", "POST", { key: entry.key, settings: emailSettings(), preview: true })
      .then(function (data) {
        if (mine !== previewSeq) { return; }
        el("emPreviewSubject").textContent = data.subject;
        el("emPreview").srcdoc = data.html;
        var unknown = el("emUnknown");
        if (data.unknownTokens && data.unknownTokens.length) {
          unknown.hidden = false;
          unknown.textContent = t("These placeholders are not available in this message and will come out empty: {tokens}",
            { tokens: data.unknownTokens.map(function (tok) { return "{{" + tok + "}}"; }).join(", ") });
        } else {
          unknown.hidden = true;
        }
      })
      .catch(function (e) { if (mine === previewSeq) { setStatus("emStatus", e.message, "bad"); } });
  }

  function wireEmailEditor() {
    el("emKey").onchange = function () { captureTemplate(); state.emailKey = el("emKey").value; renderTemplate(); };
    ["emSubject", "emBody"].forEach(function (id) { el(id).addEventListener("input", schedulePreview); });
    ["emEnabled", "emShell"].forEach(function (id) { el(id).addEventListener("change", schedulePreview); });

    el("emSave").onclick = function () {
      captureTemplate();
      whileBusy(el("emSave"), function () {
        return saveSettings(emailSettings(), "emStatus", "Emails saved.", "emails", function () { state.emailDrafts = {}; });
      }).catch(function () { });
    };

    el("emTest").onclick = function () {
      var entry = currentTemplateEntry();
      if (!entry) { return; }
      captureTemplate();
      whileBusy(el("emTest"), function () {
        setStatus("emStatus", "Sending...");
        return api("/config/testmail", "POST", { key: entry.key, settings: emailSettings(), preview: false })
          .then(function (data) {
            if (data.sent) { setStatus("emStatus", t("Sent to {address}.", { address: data.sentTo }), "ok"); }
            else { setStatus("emStatus", data.error || "Nothing was sent.", "bad"); }
          });
      }).catch(function (e) { setStatus("emStatus", e.message, "bad"); });
    };

    el("emReset").onclick = function () {
      var entry = currentTemplateEntry();
      if (!entry) { return; }
      // Resetting is a save with this template removed: the server fills the gap
      // from the shipped catalogue, so there is only one definition of "default".
      // Other templates go back as saved; their drafts stay drafts.
      var s = clone(state.config.settings);
      if (s.emails) { delete s.emails[entry.key]; }
      whileBusy(el("emReset"), function () {
        return saveSettings(s, "emStatus", "Reset to the shipped wording.", "", function () { delete state.emailDrafts[entry.key]; })
          .then(function () { renderTemplate(); updateDirty(); });
      }).catch(function () { });
    };
  }

  // Edits in any admin tab update its "unsaved" mark; leaving the page with
  // one pending asks first.
  function wireDirtyTracking() {
    ["view-config", "view-branding", "view-emails"].forEach(function (id) {
      function onEdit() {
        if (id === "view-emails") { captureTemplate(); }
        updateDirty();
      }
      el(id).addEventListener("input", onEdit);
      el(id).addEventListener("change", onEdit);
    });
    window.addEventListener("beforeunload", function (e) {
      if (!anyDirty()) { return; }
      e.preventDefault();
      e.returnValue = "";
    });
  }

  /* ---------------- activity ---------------- */

  function clip(text) { return text.length > 300 ? text.slice(0, 300) + "..." : text; }

  // A detail object as readable "key: value" lines; nested values stay compact
  // JSON, which is rare and still better than one long line of braces.
  function detailHtml(detail) {
    if (detail == null || detail === "") { return ""; }
    if (typeof detail !== "object") { return "<div>" + esc(clip(String(detail))) + "</div>"; }
    return Object.keys(detail).map(function (k) {
      var v = detail[k];
      if (v == null || v === "") { return ""; }
      var text = typeof v === "object" ? JSON.stringify(v) : String(v);
      var label = k.replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase();
      return '<div><span class="muted">' + esc(label) + ":</span> " + esc(clip(text)) + "</div>";
    }).join("");
  }

  // Filters the rows already loaded; "Load more" fetches further pages.
  function applyLogFilter() {
    var term = String(el("logFilter").value || "").trim().toLowerCase();
    var rows = el("logRows").children;
    var shown = 0;
    for (var i = 0; i < rows.length; i++) {
      var hit = !term || rows[i].textContent.toLowerCase().indexOf(term) >= 0;
      rows[i].hidden = !hit;
      if (hit) { shown++; }
    }
    if (!rows.length) { return; }
    setStatus("logStatus", term && !shown ? t("Nothing loaded so far matches that.") : "");
  }

  var logSeq = 0;
  function loadLog(reset) {
    if (!state.me) { return Promise.resolve(); }
    // One page at a time: a second click on Load more would append the same
    // page twice. A reset supersedes whatever was still loading.
    if (state.logLoading && !reset) { return Promise.resolve(); }
    var mine = ++logSeq;
    if (reset) { el("logRows").innerHTML = ""; state.logNext = null; }
    var query = "?top=50";
    if (state.me.user.isAdmin && el("logAll") && el("logAll").checked) { query += "&scope=all"; }
    if (state.logNext) { query += "&npk=" + encodeURIComponent(state.logNext.npk) + "&nrk=" + encodeURIComponent(state.logNext.nrk || ""); }
    state.logLoading = true;
    el("logMore").disabled = true;
    setStatus("logStatus", "Loading...");
    return api("/logs" + query).then(function (data) {
      if (mine !== logSeq) { return; }
      var rows = el("logRows");
      (data.items || []).forEach(function (item) {
        var tr = document.createElement("tr");
        var guest = item.guest || item.guestEmail
          ? "<strong>" + esc(item.guest || item.guestEmail) + "</strong>" +
          (item.guest && item.guestEmail ? '<br><span class="small muted">' + esc(item.guestEmail) + "</span>" : "")
          : "";
        tr.innerHTML = "<td>" + esc(fmtDate(item.timestampUtc)) + "</td>" +
          "<td>" + esc(item.event) + (item.simulated ? ' <span class="pill warn">' + esc(t("simulated")) + "</span>" : "") +
          (item.category ? '<br><span class="small muted">' + esc(item.category) + "</span>" : "") + "</td>" +
          "<td data-i18n-skip>" + esc(item.actor) + "</td>" +
          '<td class="small" data-i18n-skip>' + guest + "</td>" +
          '<td class="small muted log-detail" data-i18n-skip>' + detailHtml(item.detail) + "</td>";
        rows.appendChild(tr);
      });
      state.logNext = data.next;
      el("logMore").hidden = !data.next;
      setStatus("logStatus", rows.children.length ? "" : "Nothing has happened yet.");
      applyLogFilter();
    }).catch(function (e) {
      if (mine === logSeq) { setStatus("logStatus", e.message, "bad"); }
    }).then(function () {
      if (mine !== logSeq) { return; }
      state.logLoading = false;
      el("logMore").disabled = false;
    });
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
    // The sentence is dictionary markup; only the values are escaped into it.
    return '<div class="banner error"><div><div class="title">' + esc(t("The deployed code is out of date")) + "</div>" +
      '<div class="small">' + t("This app is configured as version {version} but the code running is {code}. A zip deployment reports success as soon as the package uploads, so this happens when the package did not actually land. Re-run <strong>deploy/Update-Collaborate.ps1</strong> and check its output for functions that did not register. Until this matches, expect endpoints to 404 and settings changes not to take effect.",
        { version: esc(d.version), code: esc(d.codeVersion) }) + "</div>" +
      '<div class="small" data-i18n-skip>' + esc(t("Functions the running code provides: {list}", { list: (d.functions || []).join(", ") })) + "</div></div></div>";
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
    setStatus("opStatus", label);
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
        '<p class="small muted">' + esc(t("Today: {invited} invited, {blocked} blocked, {deleted} deleted.", {
          invited: (d.safety && d.safety.counts ? d.safety.counts.invite : 0),
          blocked: (d.safety && d.safety.counts ? d.safety.counts.block : 0),
          deleted: (d.safety && d.safety.counts ? d.safety.counts.delete : 0)
        })) + "</p></div>" +
        // -1 means the queue does not exist yet, which is not the same as a
        // count and must never be shown as one.
        '<div class="card"><h3>' + esc(t("Queue")) + '</h3><p class="small muted">' +
        esc(t("{waiting} waiting, {failed} failed.", { waiting: queueCount(d.queues.work), failed: queueCount(d.queues.poison) })) +
        "</p></div>" +
        '<div class="card"><h3>' + esc(t("External accounts")) + "</h3>" +
        ((d.guests && d.guests.unowned)
          ? '<span class="pill warn">' + esc(t("{n} with no owner", { n: d.guests.unowned })) + "</span>"
          : '<span class="pill ok">' + esc(t("all accounted for")) + "</span>") +
        '<p class="small muted">' + esc(t("{n} external account(s) in the tenant.", { n: (d.guests ? d.guests.population : 0) })) +
        "</p></div>" +
        '<div class="card"><h3>' + esc(t("Version")) + "</h3>" +
        // "Running 0.7.0" is read off an app setting, not off the code. While
        // the two disagree, saying "up to date" next to a banner that says the
        // opposite is the worst of both.
        (truthy(d.codeStale)
          ? '<span class="pill bad">' + esc(t("the deployed code is older")) + "</span>"
          : (d.update && d.update.available)
            ? '<span class="pill warn">' + esc(t("{version} is available", { version: d.update.latest })) + "</span>"
            : '<span class="pill ok">' + esc(t("up to date")) + "</span>") +
        '<p class="small muted">' +
        esc(truthy(d.codeStale)
          ? t("Configured as {version}, but the code running is {code}.", { version: d.version, code: d.codeVersion })
          : d.simulation ? t("Running {version} (simulation mode)", { version: d.version })
            : t("Running {version}", { version: d.version })) +
        (d.update && d.update.detail ? "<br>" + esc(d.update.detail) : "") + "</p></div>";

      var rows = el("diagRows");
      rows.innerHTML = "";
      (d.heartbeats || []).forEach(function (h) {
        var tr = document.createElement("tr");
        tr.innerHTML = "<td>" + esc(h.name) + "</td><td>" + esc(fmtDate(h.lastRunUtc)) + "</td>" +
          "<td>" + (h.lastStatus === "ok" ? '<span class="pill ok">ok</span>' : '<span class="pill bad">failed</span>') + "</td>" +
          "<td>" + esc(t("{ms} ms", { ms: h.lastDurationMs })) + "</td>" +
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
      el("wizard").querySelector(".card").focus();
    }).catch(function (e) { toast(e.message, "bad"); });
  }

  function renderWizard() {
    var w = state.wizard;
    var s = w.settings;

    el("wizSteps").innerHTML = WIZARD_STEPS.map(function (label, i) {
      return '<span class="step' + (i === w.step ? " active" : "") + '">' + (i + 1) + ". " + esc(t(label)) + "</span>";
    }).join(" ");

    var body = el("wizBody");
    if (w.step === 0) {
      body.innerHTML =
        "<h2 id=\"wizHeading\">Make it yours</h2>" +
        "<p class=\"muted\">This is what your people and your guests will see. You can change all of it later.</p>" +
        field("wizCompany", "Company name", '<input id="wizCompany" type="text" maxlength="80" value="' + esc(s.branding.companyName) + '" />') +
        field("wizTitle", "Portal title", '<input id="wizTitle" type="text" maxlength="60" value="' + esc(s.branding.portalTitle) + '" />') +
        field("wizPrimary", "Main colour", '<input id="wizPrimary" type="color" value="' + esc(s.branding.primaryColor) + '" />') +
        field("wizAccent", "Accent colour", '<input id="wizAccent" type="color" value="' + esc(s.branding.accentColor) + '" />') +
        '<p class="small muted">The logo is uploaded on the Branding tab once setup is done.</p>';
    } else if (w.step === 1) {
      body.innerHTML =
        "<h2 id=\"wizHeading\">How long access lasts</h2>" +
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
        "<h2 id=\"wizHeading\">Who may invite</h2>" +
        "<p class=\"muted\">Leave the group empty and any internal member can invite an external person. Everybody can always manage the guests they already own.</p>" +
        field("wizGroup", "Object id of the group allowed to invite (optional)", '<input id="wizGroup" type="text" value="' + esc(s.invite.inviterGroupId) + '" />') +
        field("wizGroupName", "Group name, shown to anybody who is refused", '<input id="wizGroupName" type="text" value="' + esc(s.invite.inviterGroupName) + '" />') +
        field("wizServicedesk", "Service desk email (where health warnings are sent to)", '<input id="wizServicedesk" type="email" value="' + esc(s.notifications.servicedeskEmail) + '" />') +
        '<p class="small muted">Invitations are sent from the mailbox of whoever creates them, from their own browser. Reminders, expiry notices and digests come from the shared mailbox, because nobody is signed in when those are sent.</p>' +
        '<div class="checkline"><input id="wizReason" type="checkbox"' + (s.invite.requireReason ? " checked" : "") +
        ' /><label for="wizReason">Require a reason for every invitation</label></div>';
    } else if (w.step === 3) {
      body.innerHTML =
        "<h2 id=\"wizHeading\">Sharing</h2>" +
        "<p class=\"muted\">These run as the person using the portal, never as the service, so nobody can share something they do not already have access to. Switch off anything you do not want offered.</p>" +
        '<div class="checkline"><input id="wizFiles" type="checkbox"' + (s.sharing.files ? " checked" : "") + ' /><label for="wizFiles">Share files</label></div>' +
        '<div class="checkline"><input id="wizFolders" type="checkbox"' + (s.sharing.folders ? " checked" : "") + ' /><label for="wizFolders">Share folders</label></div>' +
        '<div class="checkline"><input id="wizTeams" type="checkbox"' + (s.sharing.teams ? " checked" : "") + ' /><label for="wizTeams">Add guests to Teams</label></div>' +
        '<div class="checkline"><input id="wizWrite" type="checkbox"' + (s.sharing.allowWrite ? " checked" : "") + ' /><label for="wizWrite">Allow edit access, not only view</label></div>' +
        '<p class="small muted">Collaborate starts in simulation mode: it will log what it would do and change nothing until you turn that off in Configuration.</p>';
    } else {
      body.innerHTML = "<h2 id=\"wizHeading\">Check and finish</h2>" +
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
    document.querySelectorAll(".tab").forEach(function (b) {
      b.onclick = function () { showView(b.dataset.view); };
    });
    wireViewLinks(document);
    el("signOutBtn").onclick = function () { msalInstance.logoutRedirect(); };
    el("cfgSave").onclick = function () {
      whileBusy(el("cfgSave"), function () {
        return saveSettings(collectSettings(), "cfgStatus", "Configuration saved.", "config");
      }).catch(function () { });
    };
    el("logMore").onclick = function () { loadLog(false); };
    if (el("logAll")) { el("logAll").onchange = function () { loadLog(true); }; }
    el("logFilter").addEventListener("input", applyLogFilter);
    el("diagRefresh").onclick = loadDiagnostics;
    el("opRefresh").onclick = function () { runAdminOperation("refresh", "Reading Entra..."); };
    el("opAdopt").onclick = function () { runAdminOperation("adopt", "Looking for guests we do not track..."); };
    el("opOrphans").onclick = function () { runAdminOperation("orphanDigest", "Checking for unowned accounts..."); };
    el("opHealth").onclick = function () { runAdminOperation("healthCheck", "Running the checks..."); };
    el("opVersion").onclick = function () { runAdminOperation("versionCheck", "Checking..."); };
    // Data written into these by textContent must never pass the translator.
    ["gdName", "gdEmail", "userName", "brandTitle", "gateTitle", "shChosen", "emPreviewSubject", "wcAllowed", "wcLink"]
      .forEach(function (id) { if (el(id)) { el(id).setAttribute("data-i18n-skip", ""); } });
    // Tab stays inside the open dialog.
    document.addEventListener("keydown", function (e) {
      if (!el("wizard").hidden) { trapTab(el("wizard").querySelector(".card"), e); }
      else if (!el("guestDrawer").hidden) { trapTab(el("guestDrawer").querySelector(".drawer-panel"), e); }
    });
    window.addEventListener("hashchange", route);
    wireGuests();
    wireBulkAssign();
    wireShare();
    wireBrandingEditor();
    wireEmailEditor();
    wireDirtyTracking();
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
    el("signInBtn").onclick = signInRedirect;
  }

  applyLanguage();
  loadPublicBranding();
  wire();

  msalInstance.initialize()
    .then(function () { return msalInstance.handleRedirectPromise(); })
    .then(function (result) {
      if (result && result.account) { msalInstance.setActiveAccount(result.account); }
      // Back from a sign-in redirect: put the deep link it started from back.
      restoreHash();
      var acc = currentAccount();
      if (!acc) { showSignedOut(); return null; }
      msalInstance.setActiveAccount(acc);
      showSignedIn();
      return loadMe();
    })
    .catch(function (e) {
      var message = (e && e.message) ? e.message : String(e);
      if (/AADSTS/.test(message)) {
        fail(t("Sign-in was refused: {error}", { error: message }));
      } else if (currentAccount()) {
        // Signed in, but the API did not answer. loadMe has already explained
        // this on the page; a toast as well would only repeat it.
        console.error(e);
      } else {
        showSignedOut();
        toast(t("Could not sign you in: {error}", { error: message }), "bad");
      }
    });
})();
