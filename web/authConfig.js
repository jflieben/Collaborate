/* This file is OVERWRITTEN by the deploy script with your tenant's real values.
   The placeholders below let the page load (and show a "not configured yet"
   message) before deployment. There is no secret here: delegated sign-in uses a
   public client id and PKCE. */
window.CB_AUTH = {
  clientId: "REPLACE_CLIENT_ID",
  tenantId: "REPLACE_TENANT_ID",
  apiBase: "REPLACE_API_BASE",       // e.g. https://func-collaborate-12345.azurewebsites.net/api
  apiScope: "REPLACE_API_SCOPE",     // e.g. api://<clientId>/access_as_user
  brandingUrl: "REPLACE_BRANDING_URL" // public branding.json, read before sign-in so the gate is branded too
};
