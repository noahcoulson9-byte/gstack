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
