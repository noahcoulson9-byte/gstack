# Build summary — Morning Dew

Built overnight, autonomously, per the brief. Here's the state you'll wake up
to.

## What works right now, no setup needed

- **Greeting header** — "Good morning/afternoon/evening, Noah" + today's date,
  computed client-side, same Liquid Glass aesthetic as the Weather app
  (drifting blurred gradient blobs, frosted glass cards, gradient name text).
- **Live Brisbane weather** — temp, feels-like, humidity, wind (km/h),
  precipitation, via Open-Meteo's auto-selected best-resolution model, fixed
  coordinates (-27.4698, 153.0251) so there's no geolocation prompt to hang
  on. Has a working Refresh button, an 8-second timeout, and a distinct error
  state if the network call fails or times out — it can no longer hang on
  "Fetching weather..." forever (root cause + fix in DECISIONS.md item 3).
- **Calendar, reminders, and email cards** — fully built UI + backend
  endpoints. Calendar now has 7 real iCloud calendar links in `.env`
  (merged into one "Next 48 hours" feed, see DECISIONS.md item 6); the rest
  still render correct "not configured yet" placeholder cards since no
  credentials exist for them. They do not block, error, or hang; each is
  independent of the others and of weather.
- **Outlook / Microsoft 365** — added as a second provider for Calendar,
  Reminders (via Microsoft To Do), and Email, merging into the same three
  cards alongside iCloud and Gmail rather than new sections. Fully coded
  (`server/outlook.js` Graph API client, `server/server.js` merge logic,
  frontend source tags) but has no credentials yet — see the table below.
- **PWA install** — manifest, service worker (network-first, never caches
  `/api/*` so live data is always fresh), offline fallback page, "Add to Home
  Screen" ready on iOS.

## What's stubbed pending credentials

| Feature | Stub behavior now | What unlocks it |
|---|---|---|
| Upcoming calendar events (Outlook side) | Merges with the working iCloud feed; shows nothing extra until set | Set `MS_CLIENT_ID`, `MS_CLIENT_SECRET`, `MS_REFRESH_TOKEN` |
| Reminders | Placeholder card: "No reminders feed connected yet" | Set `REMINDERS_ICS_URL` (see README for the iCloud workaround — Apple has no direct public Reminders export) and/or the `MS_*` vars (Outlook side, via Microsoft To Do) |
| Urgent emails | Placeholder card: "No email source connected yet" | Set `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`/`GOOGLE_REFRESH_TOKEN` (Gmail) and/or `MS_CLIENT_ID`/`MS_CLIENT_SECRET`/`MS_REFRESH_TOKEN` (Outlook) |
| New emails | Same placeholder as above (one connection of either provider powers both) | Same vars as above |

All integrations are **fully coded** (`server/ics.js` RRULE-aware parser,
`server/gmail.js` OAuth + Gmail API client, `server/outlook.js` Graph API
client covering calendar/tasks/mail, full frontend rendering logic with
per-source tags) — they just have nothing to talk to without credentials.
Nothing needs to be built later; only env vars need to be filled in.

## What you need to do when you wake up

1. `cd morning-dew-app && cp .env.example .env`
2. Fill in whichever of these you want live (skip any you don't care about —
   each one is independent):
   - `ICLOUD_ICS_URL` — your iCloud calendar's public share link (`webcal://`
     → `https://`). Steps in README.md.
   - `REMINDERS_ICS_URL` — a reminders list mirrored into a shared iCloud
     calendar (Apple has no direct API for this). Steps in README.md.
   - `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GOOGLE_REFRESH_TOKEN` —
     from Google Cloud Console + OAuth Playground. Steps in README.md.
   - `MS_CLIENT_ID` / `MS_CLIENT_SECRET` / `MS_REFRESH_TOKEN` / `MS_TENANT_ID`
     — Outlook/Microsoft 365 (calendar, reminders via To Do, mail). From an
     Azure App registration + a manual one-time OAuth code exchange. Full
     walkthrough in README.md.
3. Run the backend somewhere that stays on: `bun run server` (from
   `morning-dew-app/`). This is the one piece that can't live on GitHub Pages
   — see DECISIONS.md item 6 for why, and item 2 for the split architecture.
4. Point your phone's installed Morning Dew app at wherever you ran the
   server (same Wi-Fi IP, or a tunnel like Tailscale/Cloudflare Tunnel for a
   stable address).

Weather works the moment you open the app — no action needed for that part.

## Verification performed during the build

- `server/ics.js` parser + RRULE weekly expansion tested against hand-written
  synthetic `.ics` fixtures — correct event ordering, correct recurrence
  expansion across a 7-day window, correctly excludes events outside the
  query window. (Full transcript in this session; logic documented in
  ERRORS.md item 1.)
- `server/server.js` started locally via `bun run server/server.js` with no
  `.env` set — `/api/calendar`, `/api/reminders`, `/api/email` all returned
  the expected `{"configured": false, ...}` placeholder JSON instead of
  erroring or hanging.
- Re-ran with fake `MS_CLIENT_ID`/`MS_CLIENT_SECRET`/`MS_REFRESH_TOKEN` set
  (alongside the real iCloud links already in `.env`) to confirm the Outlook
  merge path actually triggers and fails in isolation rather than crashing
  the whole response: `/api/calendar` came back `configured: true` with
  separate iCloud-feed and Outlook error notes side by side; `/api/reminders`
  and `/api/email` each came back `configured: true` with just the Outlook
  error note (no Gmail/REMINDERS_ICS_URL set). No hang, no 500, no thrown
  exception in the server log.
- Static file serving verified (`/`, `/manifest.json` return 200 with
  expected Morning Dew markup).
- Gmail OAuth refresh, live iCloud `.ics` fetch, and live Outlook/Graph calls
  are **not** tested against the real services — this sandbox's network
  proxy blocks `oauth2.googleapis.com`, `gmail.googleapis.com`,
  `graph.microsoft.com`, and `icloud.com` outbound (see ERRORS.md items 1-2).
  Notably, `login.microsoftonline.com` (the Microsoft OAuth token endpoint)
  is NOT blocked — only the actual Graph data endpoints are — so a real
  Outlook token refresh could succeed in this sandbox even though the
  subsequent calendar/tasks/mail calls would still fail here. All three
  providers are written against their documented API contracts; first real
  run will surface any drift as a per-card error state, never a hang.

## Deployment

The static frontend (`morning-dew-app/index.html` + its sibling
`manifest.json`/`sw.js`/`offline.html`/`icons/`) deploys the same way as this
repo's other apps — pushed to `main`, served via the same GitHub Pages
configuration already pointed at this repo's root, reachable at the
`/morning-dew-app/` path once GitHub Pages rebuilds (a minute or two after
push, same as every other app in this repo). These files live directly in
`morning-dew-app/`, not in a `public/` subfolder — GitHub Pages can only be
configured to serve a repo's root or `/docs`, and falls back to rendering
`README.md` as the page for any directory with no `index.html` directly
inside it. An earlier version of this app nested the frontend under
`public/`, which is exactly why the deployed URL was showing a rendered
`README.md` instead of the app; see DECISIONS.md for the fix.

The backend (`morning-dew-app/server/`) is **not** deployed anywhere — GitHub
Pages can't run a persistent process, and no cloud account/credentials were
available in this build environment to provision one autonomously. It's
ready to run the moment you start it on any machine you control (laptop,
home server, small VPS). See README.md "Deploying" for options.
