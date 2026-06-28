# Decisions log — Morning Dew autonomous build

Every ambiguity hit during the overnight build, and the call made, in order.

## 1. New app folder instead of reusing `weather-timer-app/`

The brief says "preserve the existing Liquid Glass dark aesthetic from the
existing Morning Dew app," but the deployed app in this repo is named
"Weather" and lives at `weather-timer-app/` (bookmarked + installed on the
phone at that exact GitHub Pages path — renaming it would break the existing
install). Decision: build Morning Dew as a new app at `morning-dew-app/`,
copying the Liquid Glass CSS language (blurred drifting blobs, frosted glass
cards, gradient greeting text) from `weather-timer-app/index.html` rather than
modifying the original. The two apps can coexist; the original Weather app is
untouched.

## 2. A static-only PWA cannot safely hold Gmail/iCloud secrets

GitHub Pages (the existing deploy target) only serves static files — there is
no server runtime to keep an OAuth client secret or refresh token out of the
browser. Putting `GOOGLE_CLIENT_SECRET` or a CalDAV password in client-side
JS would expose it to anyone who views page source. Decision: split the app
into a static frontend (`public/`) and a small Bun backend (`server/`) that
holds all secrets server-side and exposes plain JSON endpoints
(`/api/calendar`, `/api/reminders`, `/api/email`) to the frontend. Weather
stays a direct client-side fetch since Open-Meteo needs no key and is
CORS-enabled.

**Consequence:** the calendar/reminders/email sections only work when the Bun
backend is actually running somewhere (a laptop, a Pi, a small VPS) — they
cannot run on GitHub Pages alone. See BUILD_SUMMARY.md for exactly what's
deployed vs. what needs the backend running.

## 3. Brisbane coordinates are hardcoded, not geolocated

The original weather app's "perpetual Fetching weather..." hang was traced to
`navigator.geolocation.getCurrentPosition` never resolving when the browser's
permission prompt is dismissed, ignored, or blocked (e.g. a PWA opened from
the home screen with location previously denied silently hangs the promise
indefinitely — no timeout was ever set on the geolocation call). The brief
already gives fixed coordinates (Brisbane, -27.4698/153.0251), so Morning Dew
skips geolocation entirely and fetches that fixed location directly. Combined
with an 8s `AbortController` timeout on every fetch, no card can hang forever
now.

## 4. Apple Reminders: no public no-credential read API exists

Apple does not expose a public .ics export endpoint for Reminders the way it
does for Calendar. The only documented no-paid-API approach: convert (or
mirror) the reminders list into an iCloud **Calendar** and share that calendar
as a public link, then point `REMINDERS_ICS_URL` at it (same mechanism as
`ICLOUD_ICS_URL`, parsed with the same `server/ics.js` parser). This is
documented as a manual one-time setup step in README.md. The backend route
(`/api/reminders`) and full frontend card are built and wired to this env var
now; it just needs the URL.

## 5. RRULE support is intentionally partial

`server/ics.js` expands `FREQ=DAILY|WEEKLY|MONTHLY|YEARLY` with `INTERVAL`,
`COUNT`, `UNTIL`, and `BYDAY` (for weekly recurrence) — this covers the
overwhelming majority of real calendar events (standups, weekly meetings,
monthly bills, birthdays). It does not implement the full RFC 5545 RRULE
grammar (e.g. `BYSETPOS`, `BYMONTHDAY` combined with `BYDAY`, `BYWEEKNO`).
Unsupported FREQ values cause that event's recurrence to stop expanding
gracefully rather than throwing — the single non-recurring instance (if any)
still renders, just not bracketing into the future. Tested manually against
synthetic .ics fixtures (see verification in BUILD_SUMMARY.md); no real
iCloud feed was available to test against the full edge-case spread Apple's
export can produce, since the build has no credentials to fetch one.

## 6. Multiple iCloud calendars merged into one feed

Noah provided 7 public calendar share links at once, all separate calendars,
none of them a reminders feed. Decision: extend `ICLOUD_ICS_URL` to accept a
comma-separated list of links instead of just one. `server/server.js`'s
`handleIcsFeed` now fetches every URL in the list independently via
`Promise.allSettled`, merges all resulting events into one sorted "Next 48
hours" list, and — if some feeds fail and others succeed — shows the events
that *did* load plus a small inline note about which feed numbers failed,
rather than discarding everything on a single bad link. Verified the 403s
returned when testing against the real links are this sandbox's network
policy blocking `icloud.com` outbound (confirmed via the proxy status
endpoint), not a bug in the merge logic — see ERRORS.md.

## 7. Backend deploy target

The brief says "deploy it." A Bun server needs a host that runs a persistent
process (GitHub Pages does not). Decision: keep the frontend on the same
GitHub Pages deploy path as the rest of this repo's apps (static, free,
already configured), and document the backend as self-hosted (`bun run
server`) on whatever machine is left running — a laptop, a home server, or a
small always-on VPS. This is the same boundary every "open-source weekend
project with secrets" app hits without standing up cloud infra credentials
the build doesn't have. No cloud account access or credentials were available
in this sandboxed build environment to provision a hosted backend
autonomously, so self-hosting is the honest, working answer right now —
swapping to a hosted function (Cloudflare Worker, Fly.io, etc.) later is a
deploy-target change, not a code rewrite, since `server/server.js` and its
two helper modules have no GitHub-Pages-specific assumptions baked in.

## 8. Outlook merges into the existing Calendar/Reminders/Email cards, not new sections

Noah's instruction was to "add all the things I asked for including outlook
reminders calendar etc." The original brief's three data sections (Calendar,
Reminders, Email) are provider-agnostic by name — there's no reason a user
would want a separate "Outlook Calendar" card sitting next to "Calendar."
Decision: `server/outlook.js` (new) mirrors `gmail.js`'s shape, and
`server/server.js` merges Outlook's calendar events / Microsoft To Do tasks /
mail triage into the exact same `/api/calendar`, `/api/reminders`, and
`/api/email` endpoints that already serve iCloud `.ics` and Gmail data — same
pattern as decision 6's multi-iCloud-calendar merge, generalized to mixed
provider types. Every event/message object now carries a `source` field
(`iCloud` / `Outlook` / `Gmail`) rendered as a small tag in the UI, since a
single card can now show rows from more than one provider. One provider
failing (e.g. missing credentials, a 403, a timeout) never hides data that
loaded fine from another — each source is fetched via `Promise.allSettled`-
style isolation and errors are appended as a note rather than replacing the
list.

## 9. Microsoft To Do is the Outlook equivalent of Reminders

Microsoft Graph has no API named "Reminders." The closest equivalent —
matching Apple Reminders' "a list of things to do, some with due dates" shape
— is Microsoft To Do (`/me/todo/lists` + `/me/todo/lists/{id}/tasks`), which
is also what Outlook's own "Tasks" pane surfaces. Decision: `fetchTasks()` in
`server/outlook.js` pulls all of a user's To Do lists, fetches each list's
non-completed tasks in parallel via `Promise.allSettled` (one bad list is
skipped, not fatal to the rest — same isolation pattern as everywhere else in
this app), and feeds the merged result into `/api/reminders` alongside
whatever iCloud reminders-as-calendar feed is configured.

## 10. No further `AskUserQuestion` calls for this expansion, per explicit instruction

Noah's message asked to "add all the things I asked for... and to not to need
to ask me any questions so I can let you run in the background untill
finished." This explicitly supersedes the `AskUserQuestion` pattern used
earlier in the build (decision-adjacent: the multi-calendar-link
disambiguation). For the entire Outlook integration — env var naming
(`MS_CLIENT_ID`/`MS_CLIENT_SECRET`/`MS_REFRESH_TOKEN`/`MS_TENANT_ID`, chosen
to mirror `GOOGLE_*`'s naming convention), the To Do-as-Reminders mapping
(decision 9), and the merge-into-existing-cards architecture (decision 8) —
every ambiguity was resolved unilaterally and logged here rather than asked
about, exactly as instructed.

## 11. Microsoft Graph confirmed sandbox-blocked; login endpoint is not

Tested directly (see ERRORS.md item 2): `login.microsoftonline.com` (the
OAuth token endpoint) returns a real `200` through the sandbox proxy, but
`graph.microsoft.com` (every actual data endpoint — calendar, tasks, mail)
returns the same `403 connect_rejected` already seen for `icloud.com` and
Google's APIs. This means `outlook.js`'s token-refresh call is the one piece
of this entire app's external-network surface that could theoretically be
exercised live in this sandbox if real Microsoft credentials existed — but
since none do, and the Graph calls that would follow are blocked anyway, no
live Outlook request of any kind was attempted. Code review against the
documented Graph API contract is the verification ceiling here, same as for
the Gmail and iCloud paths.

## 12. Frontend moved out of `public/` to the app root — GitHub Pages can't serve a nested folder

Noah reported the deployed URL (`/morning-dew-app/`) was rendering a styled
`README.md` instead of the app. Root cause: GitHub Pages' "deploy from a
branch" mode only supports two source folders — repo root or `/docs` — it
cannot be pointed at an arbitrary nested path like `morning-dew-app/public/`.
This repo serves Pages from its root, so every app is reachable at
`/<repo>/<app-folder>/` only because that app folder's `index.html` sits
directly inside it (confirmed against `weather-timer-app/`, which has no
`public/` subfolder). Morning Dew's frontend was nested one level deeper at
`morning-dew-app/public/index.html`, so the URL `morning-dew-app/` resolved
to a directory with no `index.html` in it. GitHub Pages defaults to Jekyll
processing, and Jekyll's fallback for an index-less directory is to render
that directory's `README.md` as the page — exactly what the screenshot showed.

Decision: move `index.html`, `manifest.json`, `sw.js`, `offline.html`, and
`icons/` up to `morning-dew-app/` directly, removing `public/` entirely. All
three files' internal paths (`manifest.json`'s `start_url`/`scope`/icon
`src`, `sw.js`'s `ASSETS` cache list, `index.html`'s `<link>`/`register()`
calls) were already relative, so no path edits were needed beyond the move
itself.

This puts the frontend files in the same directory as `.env`, `server/`
source, and the markdown docs for the first time. `server/server.js`'s
`serveStatic()` previously trusted `PUBLIC_DIR` to be a dedicated,
secrets-free directory and only filtered by MIME-type extension — adequate
when `public/` held nothing else, not adequate once it's the app root.
Replaced that with an explicit allowlist (`index.html`, `manifest.json`,
`sw.js`, `offline.html`, plus the `icons/` prefix) so `.env`, `server/*.js`,
and `*.md` files 404 regardless of what's on disk in that directory —
verified by curling each of those paths against a locally running backend
(see BUILD_SUMMARY.md). `sw.js`'s `CACHE_NAME` was bumped to `v2` so already
installed PWA clients pick up the corrected file layout instead of serving a
stale cached copy of the old structure.
