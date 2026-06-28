# Morning Dew

A single-screen morning briefing PWA: greeting, live Brisbane weather,
upcoming calendar events, open reminders, and email triage (urgent + new) —
in the same Liquid Glass dark aesthetic as this repo's other apps.

Weather works with zero setup. Calendar, reminders, and email each render a
clearly-labelled placeholder card until you add their credentials — nothing
blocks anything else.

## Architecture

```
morning-dew-app/
├── index.html      # static PWA frontend (deployed to GitHub Pages, at app root —
├── manifest.json   # GitHub Pages only serves repo-root or /docs as a Pages source,
├── sw.js           # and falls back to rendering README.md for any directory with
├── offline.html    # no index.html directly inside it, so these files must live
├── icons/          # at morning-dew-app/ directly, not nested under public/)
├── server/        # Bun backend — holds secrets, proxies calendar/reminders/email
│   ├── server.js  # serves the frontend files above via an explicit allowlist
│   ├── ics.js      # .ics parser + RRULE expansion
│   ├── gmail.js    # Gmail API client (OAuth refresh-token flow)
│   └── outlook.js  # Microsoft Graph client (calendar, tasks, mail)
├── .env.example
├── package.json
├── DECISIONS.md    # ambiguity log from the autonomous build
├── ERRORS.md        # error log from the autonomous build
└── BUILD_SUMMARY.md # what works right now vs. what needs your credentials
```

**Why two pieces?** Weather is keyless and CORS-enabled, so the browser talks
to Open-Meteo directly. Calendar (.ics), reminders (.ics), Gmail, and Outlook
all need either a server-side fetch (no CORS support / no public API) or a
real secret (OAuth client secret, refresh token) that must never reach a
browser. The Bun backend holds those and serves the frontend too.

Calendar and Reminders can each be backed by iCloud, Outlook, or both at once
— set both sets of env vars and both providers' events merge into one sorted
list, tagged with their source. Email works the same way across Gmail and
Outlook.

## Run locally

```bash
cd morning-dew-app
cp .env.example .env       # then fill in whatever credentials you have
bun run server              # serves the app + APIs on http://localhost:8787
```

Open `http://localhost:8787` on your phone (same Wi-Fi) or laptop. Every
section that has no env vars set shows a placeholder card explaining exactly
what to add — nothing crashes or hangs waiting on missing config.

If you just want to preview the static frontend without the backend (weather
only, everything else shows "couldn't reach the service"):

```bash
bun run dev:static   # python3 -m http.server on :8080, no API routes
```

This serves the whole app folder as-is (no allowlist, unlike `server/server.js`)
— fine for a quick local frontend-only preview, but don't expose port 8080
beyond your own machine while using it, since `.env` and `server/` would be
readable too.

## Deploying

The frontend files at this app's root (`index.html`, `manifest.json`, `sw.js`,
`offline.html`, `icons/`) are a standard static PWA — deploy them the same way
as this repo's other apps. For GitHub Pages specifically: Pages can only be
pointed at a repo's root or `/docs`, not at an arbitrary nested folder, so
these files live directly in `morning-dew-app/` (not in a `public/`
subfolder) — that's also why GitHub Pages can find `index.html` here instead
of falling back to rendering `README.md`. Any static host works the same way
(Netlify/Vercel/Cloudflare Pages, pointed at this folder).

The `server/` backend needs a host that keeps a process running — GitHub
Pages can't do this. Run it on whatever machine you leave on overnight (a
laptop, a home server, a small VPS, a Raspberry Pi). Point your phone's
Morning Dew install at that machine's address (or put it behind a tunnel like
Cloudflare Tunnel / Tailscale if you want a stable public URL). Without the
backend running, weather still works; calendar/reminders/email show "couldn't
reach the service" instead of a placeholder (a clear signal to go start it).

## Environment variables

All optional — every missing one degrades to a placeholder, nothing blocks.

| Variable | Used for | How to get it |
|---|---|---|
| `PORT` | Backend listen port | Defaults to `8787` |
| `ICLOUD_ICS_URL` | Upcoming calendar events | See below |
| `REMINDERS_ICS_URL` | Open reminders | See below |
| `GOOGLE_CLIENT_ID` | Gmail triage | See below |
| `GOOGLE_CLIENT_SECRET` | Gmail triage | See below |
| `GOOGLE_REFRESH_TOKEN` | Gmail triage | See below |
| `MS_CLIENT_ID` | Outlook calendar/tasks/mail | See below |
| `MS_CLIENT_SECRET` | Outlook calendar/tasks/mail | See below |
| `MS_REFRESH_TOKEN` | Outlook calendar/tasks/mail | See below |
| `MS_TENANT_ID` | Outlook calendar/tasks/mail | See below (defaults to `common`) |

### Getting `ICLOUD_ICS_URL`

1. On Mac: open Calendar.app → right-click the calendar you want → **Share
   Calendar...** → check **Public Calendar** → click the link icon to copy
   the URL.
2. Or on iCloud.com → Calendar → hover the calendar in the sidebar → click
   **...** → **Public Calendar** → copy the link.
3. The link starts with `webcal://` — change that prefix to `https://` and
   use the result as `ICLOUD_ICS_URL`.

### Getting `REMINDERS_ICS_URL`

Apple doesn't expose a direct public export for Reminders. Workaround: move
(or mirror) the reminders you want surfaced into an iCloud **Calendar**
(create a dedicated one, e.g. "Reminders Feed"), then share that calendar
publicly the same way as above, and use its link here.

### Getting Gmail OAuth credentials

1. Go to the [Google Cloud Console](https://console.cloud.google.com/),
   create a project (or use an existing one), and enable the **Gmail API**.
2. Under **APIs & Services → Credentials**, create an **OAuth client ID** of
   type **Desktop app**. Note the Client ID and Client Secret —
   `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.
3. Go to [Google's OAuth 2.0 Playground](https://developers.google.com/oauthplayground/).
   Click the gear icon → check **Use your own OAuth credentials** → paste
   your Client ID/Secret.
4. In Step 1, find and authorize the scope
   `https://www.googleapis.com/auth/gmail.readonly`.
5. Click **Exchange authorization code for tokens** — copy the **Refresh
   token** shown → `GOOGLE_REFRESH_TOKEN`.

This refresh token doesn't expire under normal use, so you only need to do
this once.

### Getting Outlook / Microsoft 365 OAuth credentials

Covers Outlook Calendar, Outlook Tasks/To Do (used as the Outlook equivalent
of Reminders — Microsoft Graph has no separate "Reminders" API), and Outlook
Mail. All three merge into the existing calendar/reminders/email cards
alongside iCloud and Gmail, so set as many or as few of these as you have.

1. Go to the [Azure Portal](https://portal.azure.com/) → **Azure Active
   Directory** → **App registrations** → **New registration**. Name it
   anything (e.g. "Morning Dew"). For **Supported account types**, pick
   "Accounts in any organizational directory and personal Microsoft
   accounts" unless you specifically want to restrict it to one tenant.
2. Note the **Application (client) ID** → `MS_CLIENT_ID`, and the
   **Directory (tenant) ID** → `MS_TENANT_ID` (or use `common` if you chose
   the multi-tenant + personal accounts option above).
3. **Certificates & secrets** → **New client secret** → copy the value
   immediately (it's only shown once) → `MS_CLIENT_SECRET`.
4. **API permissions** → **Add a permission** → **Microsoft Graph** →
   **Delegated permissions** → add `Calendars.Read`, `Tasks.Read`,
   `Mail.Read`, and `offline_access`. Click **Grant admin consent** if your
   tenant requires it (personal Microsoft accounts don't).
5. **Authentication** → **Add a platform** → **Mobile and desktop
   applications** → check the box for
   `https://login.microsoftonline.com/common/oauth2/nativeclient` (or add it
   as a custom redirect URI), then **Save**.
6. Get a refresh token via the authorization-code flow (Microsoft has no
   hosted "OAuth Playground" the way Google does, so this is a one-time
   manual step):
   - Open this URL in a browser, swapping in your `MS_CLIENT_ID` and tenant
     (`common` or your tenant ID), then sign in and approve:
     ```
     https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize?client_id=<MS_CLIENT_ID>&response_type=code&redirect_uri=https://login.microsoftonline.com/common/oauth2/nativeclient&scope=offline_access%20Calendars.Read%20Tasks.Read%20Mail.Read
     ```
   - After approving, you'll land on a blank `nativeclient` page whose URL
     contains `?code=...` — copy that `code` value.
   - Exchange it for a refresh token:
     ```bash
     curl -X POST https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token \
       -d client_id=<MS_CLIENT_ID> \
       -d client_secret=<MS_CLIENT_SECRET> \
       -d code=<the code you copied> \
       -d grant_type=authorization_code \
       -d redirect_uri=https://login.microsoftonline.com/common/oauth2/nativeclient \
       -d scope="offline_access Calendars.Read Tasks.Read Mail.Read"
     ```
   - The JSON response's `refresh_token` field → `MS_REFRESH_TOKEN`.

This refresh token doesn't expire under normal use either, so this is also a
one-time setup step.

## Notes

- No secrets are ever hardcoded — everything sensitive comes from environment
  variables read server-side only (`server/server.js`), never shipped to the
  browser.
- Every data section fetches independently with its own try/catch and an 8
  second timeout — one slow or failing source never blocks the others.
