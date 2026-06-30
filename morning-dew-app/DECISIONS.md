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

**Superseded by decision 14** — Noah asked for live location after living
with the Brisbane-only behavior for a while. Geolocation is back, but with
the timeout this decision was originally about: `getCurrentPosition` is now
raced against an 8s manual timer (`GEO_TIMEOUT_MS`) in addition to its own
`timeout` option, since iOS Safari doesn't always honor the option alone.
Brisbane is now the fallback when geolocation fails/times out/is denied,
not the only behavior.

## 14. Live geolocation with Brisbane as the timeout/denial fallback

Implemented in `index.html`'s `loadWeather()`: tries `getCurrentPosition()`
first (wrapped in the hard 8s race described in decision 3's update); on
success, fetches Open-Meteo for the device's real coordinates and kicks off
a best-effort reverse-geocode (BigDataCloud's free, keyless,
CORS-enabled `reverse-geocode-client` endpoint) to label the card with the
actual suburb/city instead of "Current location". On any failure (denied,
no support, timeout), falls back to the original fixed Brisbane coordinates
and labels the card "Brisbane, QLD (location unavailable)" so it's obvious
which mode is active. The reverse-geocode call is decorative only — if it
fails, the temperature/etc. already loaded from the real coordinates are
unaffected, only the text label stays generic.

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

## 13. Backend deploy target upgraded to Render, with a configurable frontend→backend origin

Noah asked to "set up server or tell me how to get server running" and,
given the choice between a free cloud host, his own always-on machine, or a
Raspberry Pi/home server, picked the free cloud host and accepted the
known cold-start tradeoff. Decision: added `Dockerfile` (thin `oven/bun:1`
wrapper running `server/server.js`, no code changes needed since it already
reads `process.env.PORT`) and a repo-root `render.yaml` Blueprint
(`rootDir: morning-dew-app`) so Render's dashboard can build and run the
backend with one "Apply" click instead of manual service configuration.
Added `morning-dew-app/.dockerignore` excluding `.env` and `*.md` — without
it, `Dockerfile`'s `COPY . .` would have baked the real iCloud calendar share
links currently in `.env` into the built image. `render.yaml` leaves every
secret as `sync: false` (filled in via the Render dashboard post-deploy,
never committed).

This surfaced a real architectural gap: the GitHub-Pages-hosted frontend and
a Render-hosted backend are different origins, but `index.html` was calling
`/api/calendar` etc. as same-origin relative paths (which only worked when
`bun run server` served both the frontend and the API from one process).
Fixed two ways: (1) `server/server.js`'s `json()` helper now sets
`Access-Control-Allow-Origin: *` — these are read-only GET endpoints with no
cookies or auth, so a wildcard origin adds no real risk; (2) `index.html`
gained a "Server" button (next to "Refresh weather") that prompts for a
backend base URL and persists it in `localStorage`, with all three
`/api/*` fetches routed through an `apiUrl()` helper that prefixes that base
(or none, for same-origin self-hosting — the original behavior is preserved
when the field is left blank). This makes the frontend deploy-target-agnostic:
GitHub Pages + Render, GitHub Pages + self-hosted-with-tunnel, or one box
running everything all work without code changes, just a different value in
that one prompt.

## 14. Full-screen debrief uses a hash route (`#/debrief`), not a true path route

Task 1 asked for "proper client-side routing (e.g. a new route like
/debrief)". A true path route (`/debrief`) requires the host to rewrite
unknown paths back to `index.html` (a 404.html trick on GitHub Pages, or a
catch-all rewrite on Render). This app's exact hosting base path is
ambiguous from what's in this repo: there's no `CNAME`, and the README
notes Pages "can only be pointed at a repo's root or /docs," yet
`morning-dew-app/` is itself nested inside the `gstack` monorepo. Getting
the rewrite path wrong would 404 a deep link or hard reload.

Decision: used `#/debrief` (a hash route) instead. `history.pushState`/
`popstate` work identically to a true path route — same back-button
support, same "feels like a new page" navigation — but a hash route never
touches the server, so it works correctly regardless of which base path
this app ends up served from, with zero server-side rewrite config. Reload
on `#/debrief` is handled by a bootstrap-time check
(`if (location.hash === '#/debrief') openDebrief();`) so deep links survive
a hard refresh.

## 15. AI brief restructured to JSON with graceful fallback to the legacy flat string

Task 2 asked for the AI overview to be split into short, distinct,
expandable sections instead of one markdown blob, and noted that if the
single-blob format is "actually a prompt-structuring problem," the
generation prompt should be adjusted to output structured fields instead
of free text. It is — there's no reliable way to carve a flat markdown
string back into named sections client-side. Changed `server/anthropic.js`'s
`SYSTEM_PROMPT` to require a single fenced `\`\`\`json` block:
`{headline, opener, sections: [{key, title, summary, detail}], tomorrow}`,
with `inbox`/`headsup` sections omitted when not applicable and `tomorrow`
set to JSON `null` when there's nothing to flag for the next day.

`generateBrief()` parses that fence and returns `{configured: true,
structured: true, brief: <object>}`. If the model's response doesn't parse
as JSON or is missing a `sections` array (a non-deterministic LLM API
response — a boundary worth validating, not over-engineering), it degrades
to `{configured: true, structured: false, brief: <raw text>}`, preserving
the old flat-markdown contract as a fallback rather than erroring the whole
brief. The client (`index.html`'s `debriefBodyHtml()`) branches on
`overview.briefStructured` to render either the new progressive-disclosure
section cards or the legacy single markdown card, so a malformed model
response degrades the UI instead of breaking it. `cachedBrief()` now
persists and returns `{brief, structured}` so a same-day cached brief
restores with the correct rendering path after a reload.

Also decided: "tomorrow" data needs no new backend endpoint or HAE field.
`fetchIcsEvents()` in `server.js` already windows both `/api/calendar` and
`/api/reminders` 48 hours out, so `overview.calendar`/`overview.reminders`
already contain tomorrow's events — `briefContext()` filters them
client-side with a new `isTomorrow()` helper (mirroring the existing
`isToday()`). Email has no per-item date, so rather than building an
unavailable date-filtered email signal, the same `email.urgentItems` list
is handed to the model as `tomorrow.possiblyRelevantEmail` and the prompt
instructs it to judge tomorrow-relevance from subject/sender context.

## 16. Home screen redesigned to a dark glassmorphic, no-scroll layout with a bottom nav

User shared a Pinterest reference (dark task-manager UI, blue accent,
colored left-accent-bar cards, day-picker strip, avatar, floating pill
bottom nav) and asked for the home screen to match it. Two mockup rounds
were built and screenshotted standalone (not against the real app) before
any real-app edit, per the workflow the user required. Final approved
round added: the Outlook-style inbox restored to its existing production
look, an Apple-Calendar-style daily timeline, the original 3-ring
recovery/sleep/strain triad preserved, and a rainbow/aurora glow behind
the hero card. The user then asked for one more pass on the real app:
shrink Readiness and Schedule, make Outlook reachable without scrolling,
and add bottom-nav buttons for quick access — explicitly **no scrolling on
the home screen at all**.

**Dual-accent-token split.** `--accent: #ffb22e` (gold) stays untouched
because the full-screen `#/debrief` page depends on it for its section
titles, CTA button, and arrow glyphs, and the user never asked for that
page's look to change. A new `--home-accent: #3D7BFF` token was introduced
and only the home-screen-specific rules that read `var(--accent)`
(`.nd-greet-line .accent`, `.nd-hero::after`, `.nd-hero-label`,
`.nd-hero-cta`) were repointed to it. The generic `--text`/`--muted`/
`--glass-*` tokens were repointed globally to a near-black palette since
they're shared-but-generic and `.debrief-page` has its own independent
hardcoded background — verified via screenshot that `#/debrief` still
renders with its original gold accent and layout after the change.

**Apple-Calendar day view lives in the tap-through detail overlay, not on
the home card.** The "make the calendar look like Apple Calendar, daily
layout with all hours" request and the later "no scrolling on home, make
the calendar smaller" request looked contradictory until re-reading the
app: tapping any home card already opens a full detail overlay via
`data-detail="X"` → `openDetail(type)` → a per-card `*DetailHtml()`
builder. The expansive day view (`dayTimelineHtml()`, a 24-hour grid with
hour rule lines, time-positioned event blocks, greedy column-packing for
overlapping events, and a live "now" line that the overlay auto-scrolls to
on open) was built inside `scheduleDetailHtml()` (via the existing
`scheduleListHtml()` call site), while the home page's `.nd-cal` card kept
its existing compact "next event" design, just dark-restyled and shrunk.
This satisfies both requests at once instead of trading one off against
the other.

**Outlook-style inbox needed no rewrite.** `renderInboxCard()` already
matched the "Outlook style" ask (logo header, avatar-circle rows, urgent
badge) — only CSS restyling (dark palette, smaller padding, colored
left-borders) was needed to fit the no-scroll budget, no markup or JS
changes.

**Decorative, non-interactive day-picker strip.** `fetchIcsEvents()` only
windows 48 hours out, so there's no per-day event index for the rest of
the week without a backend change (out of scope for a visual pass). The
strip (`renderDayStrip()`, called from `renderHome()`) renders today ± 2
days with today highlighted solid blue; the other four cells are inert
(no click handler, no data filtering) — an honest "this is the date
strip, not a date picker" rather than a half-wired feature that looks
interactive but does nothing.

**Bottom nav reuses existing ids and handlers instead of duplicating
them.** `#settingsBtn` (→ `openServerSetting()`, already wired) and
`#pageRefreshBtn` (→ the existing refresh handler with its `.spinning`
animation) moved into the new `<nav class="nd-bottom-nav">` markup with
their ids unchanged, so zero JS changes were needed for those two — only
`updateServerBtnLabel()`'s `getElementById('settingsBtn')` lookup, which
sets `title`/`aria-label` (not innerHTML), needed re-verifying it still
worked after the gear emoji was swapped for an inline SVG. Two new
buttons were added with fresh handlers: `#navHealth` and `#navInbox` both
call the existing `openDetail('health' | 'inbox')` — direct access
instead of `scrollIntoView`, since the home page no longer scrolls at all.
`#navHome` calls `history.back()` when a detail overlay or the debrief
page is open (consistent with how the existing back button/Escape/swipe
gesture already close those), otherwise does nothing (there's nothing to
navigate to — home is the only base view).

**Found and fixed a pre-existing bug while building the nav.** The global
`button { border: none; cursor: pointer; }` reset never set
`background: none`, so any button without its own explicit background
fell back to the browser's default button face (light gray), which
silently masked the muted-gray bottom-nav icons against the new dark
background (confirmed via a cropped screenshot — three of five nav icons
were invisible until this was added). Every other button in the app
already set its own background explicitly, so this had no visible effect
before now, but it's a correctness fix to the shared reset, not a
nav-specific workaround.

**Verification:** syntax-checked the extracted inline `<script>` with
`node --check` (clean). Screenshotted the real app at a 390×844 viewport —
confirmed `main.home`'s `scrollHeight` (809px) fits inside the viewport's
`innerHeight` (844px), i.e. genuinely no scroll. Screenshotted the bottom
nav cropped before/after the button-background fix. Injected mock
calendar events via `page.evaluate()` (no live backend in this sandbox) to
confirm the day-timeline renders hour lines, side-by-side columns for
overlapping events, the all-day chip, and the auto-scroll-to-now position
correctly. Confirmed no edits touched `server/` or the debrief page's own
styling/logic.
