# Errors log — Morning Dew autonomous build

## 1. Sandboxed network access blocks live verification of Gmail/iCloud/Open-Meteo

**Context:** This build environment's outbound network goes through a proxy
that only allows specific allowlisted domains. Direct calls to
`api.open-meteo.com`, `oauth2.googleapis.com`, `gmail.googleapis.com`, and any
`icloud.com` URL all return `403 Forbidden` from the local proxy when tested
with `curl`.

**Attempted fix:** None applicable — this is an environment boundary, not a
bug in the app. Per project constraints, the build does not attempt to
bypass network sandboxing.

**Resolution:** Verified everything that *can* be verified without those
domains:
- `server/ics.js`'s parser + RRULE expansion against hand-written synthetic
  `.ics` fixtures (passes — see BUILD_SUMMARY.md for the test transcript).
- The full backend (`server/server.js`) running locally via `bun run
  server/server.js`, hitting `/api/calendar`, `/api/reminders`, `/api/email`
  with no env vars set — all three correctly return `{"configured": false,
  ...}` placeholder payloads instead of hanging or throwing.
- Static file serving (`/`, `/manifest.json`) returns 200 with the expected
  Morning Dew markup.
- The frontend's weather/calendar/reminders/email fetch logic was code-reviewed
  for the failure modes that matter (timeout via `AbortController`,
  try/catch around every fetch, independent per-card error states) since the
  actual live Open-Meteo/Gmail/iCloud calls can't be exercised end-to-end from
  this sandbox.

**Unresolved:** The Gmail OAuth token-refresh call and the live iCloud `.ics`
fetch are untested against the real services — they're written against the
documented API contracts (Google's OAuth2 token endpoint, RFC 5545 .ics
format) but have not made a single real request to either service. When you
add real credentials in the morning, watch the backend's stdout
(`bun run server`) for the first real fetch — if Google or Apple have changed
anything since this was written, the error will surface as the `{"error":
"..."}` field in the relevant `/api/*` response and render as a per-card
error state, never a hang.

## 2. Microsoft Graph (`graph.microsoft.com`) is also sandbox-blocked; `login.microsoftonline.com` is not

**Context:** When wiring up Outlook support (`server/outlook.js`), tested both
Microsoft domains the integration needs directly against the sandbox proxy:

```
curl -sS -o /dev/null -w "%{http_code}\n" https://login.microsoftonline.com/common/oauth2/v2.0/token
# -> 200
curl -sS -o /dev/null -w "%{http_code}\n" https://graph.microsoft.com/v1.0/me
# -> curl: (56) CONNECT tunnel failed, response 403
```

Confirmed via `curl -sS "$HTTPS_PROXY/__agentproxy/status"`, which logged a
fresh `recentRelayFailures` entry: `{"kind": "connect_rejected", "detail":
"gateway answered 403 to CONNECT (policy denial or upstream failure)", "host":
"graph.microsoft.com:443"}`. `login.microsoftonline.com` produced no such
entry and returned a real (non-proxy) `200`.

**Implication:** in this sandbox, an OAuth token refresh against Microsoft's
login endpoint would actually succeed if real `MS_CLIENT_ID`/`MS_CLIENT_SECRET`/
`MS_REFRESH_TOKEN` values were present, but every subsequent Graph API call
(`/me/calendarView`, `/me/todo/lists`, `/me/mailFolders/inbox/messages`) would
fail with the same proxy-level 403 that blocks iCloud and Gmail today. This is
consistent with item 1 below — an environment boundary, not a bug in
`server/outlook.js`. No bypass was attempted.

**Resolution:** Same as item 1 — code-reviewed `server/outlook.js` against the
documented Microsoft Graph API contracts, and verified `server/server.js`'s
merge logic degrades correctly: with no `MS_*` vars set, `/api/calendar`,
`/api/reminders`, and `/api/email` all still return correctly whether iCloud/
Gmail are configured or not (see BUILD_SUMMARY.md). The Outlook-specific
fetch/parse logic itself remains genuinely untested against a live response,
exactly like the iCloud and Gmail paths.

## 3. No errors during local build/serve verification

No crashes, unhandled exceptions, or hangs were observed running the backend
or serving the static frontend locally. Nothing else to log here.
