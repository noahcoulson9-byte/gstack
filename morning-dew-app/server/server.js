// Morning Dew backend — serves the static PWA and proxies the data sources
// that need server-side secrets or server-side fetch (no CORS from a browser):
// iCloud calendar/reminders .ics feeds, Outlook/Microsoft 365 (Graph API), and
// the Gmail API. Calendar and Reminders can each be backed by either or both of
// iCloud + Outlook; Email can be backed by either or both of Gmail + Outlook.
// Every source is fetched independently — one bad/unconfigured source never
// hides data that loaded fine from another source.
//
// Weather is NOT proxied here — Open-Meteo is CORS-enabled and keyless, so the
// frontend fetches it directly (see index.html).
//
// Run: bun run server/server.js   (reads env vars, see ../.env.example)

const path = require('path');
const fs = require('fs');
const { eventsInWindow } = require('./ics');
const { fetchTriage } = require('./gmail');
const outlook = require('./outlook');

const PORT = process.env.PORT || 8787;
// Frontend files live directly in the app root (GitHub Pages serves this repo
// from its root, and falls back to rendering README.md as HTML for any
// directory that has no index.html directly inside it — so the frontend
// can't be nested in a public/ subfolder). The app root is also where .env,
// server/, and the markdown docs live, so serveStatic() below allowlists
// exactly the files/prefixes the frontend needs rather than trusting
// PUBLIC_DIR as a dedicated secrets-free directory.
const PUBLIC_DIR = path.join(__dirname, '..');
const FETCH_TIMEOUT_MS = 8000;

async function fetchWithTimeout(url, ms) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

// Wraps any promise (e.g. outlook.js's plain fetch calls) with the same
// FETCH_TIMEOUT_MS guarantee fetchWithTimeout gives ics/gmail calls, so no
// Outlook-backed card can hang forever either.
function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms)),
  ]);
}

// Allows the frontend to be hosted on a different origin than the backend
// (e.g. GitHub Pages frontend + Render-hosted backend) — these are read-only
// GET endpoints with no cookies/auth, so a wildcard origin carries no
// meaningful risk.
function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
}

function getMsCreds() {
  const clientId = process.env.MS_CLIENT_ID;
  const clientSecret = process.env.MS_CLIENT_SECRET;
  const refreshToken = process.env.MS_REFRESH_TOKEN;
  const tenantId = process.env.MS_TENANT_ID;
  if (!clientId || !clientSecret || !refreshToken) return null;
  return { clientId, clientSecret, refreshToken, tenantId };
}

// envVarName may hold one URL or several comma-separated URLs (e.g. several
// iCloud calendars merged into one feed). Each URL is fetched independently —
// one bad/slow calendar doesn't drop the others, it just adds a per-feed note.
async function fetchIcsEvents(envVarName) {
  const raw = process.env[envVarName];
  if (!raw) return { events: [], errors: [], configured: false };
  const urls = raw.split(',').map((u) => u.trim()).filter(Boolean);
  const now = new Date();
  const windowEnd = new Date(now.getTime() + 48 * 3600 * 1000);

  const results = await Promise.allSettled(
    urls.map(async (url) => {
      const res = await fetchWithTimeout(url, FETCH_TIMEOUT_MS);
      if (!res.ok) throw new Error(`fetch failed: ${res.status}`);
      const text = await res.text();
      return eventsInWindow(text, now, windowEnd).map((ev) => ({ ...ev, source: 'iCloud' }));
    })
  );

  const events = [];
  const errors = [];
  results.forEach((r, i) => {
    if (r.status === 'fulfilled') events.push(...r.value);
    else errors.push(`iCloud feed ${i + 1}: ${String(r.reason.message || r.reason)}`);
  });
  return { events, errors, configured: true };
}

// Shared by /api/calendar and /api/reminders — both can merge an iCloud .ics
// feed with Outlook (calendarView for calendar, To Do tasks for reminders).
async function handleCalendarLike(envVarName, label, outlookFetcher) {
  const icsResult = await fetchIcsEvents(envVarName);
  const msCreds = getMsCreds();

  const events = [...icsResult.events];
  const errors = [...icsResult.errors];
  let anyConfigured = icsResult.configured;

  if (msCreds) {
    anyConfigured = true;
    try {
      const accessToken = await withTimeout(outlook.getAccessToken(msCreds), FETCH_TIMEOUT_MS, 'Outlook token refresh');
      const msEvents = await withTimeout(outlookFetcher(accessToken), FETCH_TIMEOUT_MS, `Outlook ${label}`);
      events.push(...msEvents);
    } catch (err) {
      errors.push(`Outlook: ${String(err.message || err)}`);
    }
  }

  events.sort((a, b) => new Date(a.start) - new Date(b.start));

  const payload = { configured: anyConfigured, label, events };
  if (errors.length) payload.error = errors.join('; ');
  return json(payload);
}

function handleCalendar() {
  const now = new Date();
  const windowEnd = new Date(now.getTime() + 48 * 3600 * 1000);
  return handleCalendarLike('ICLOUD_ICS_URL', 'Calendar', (token) => outlook.fetchCalendarEvents(token, now, windowEnd));
}

function handleReminders() {
  return handleCalendarLike('REMINDERS_ICS_URL', 'Reminders', (token) => outlook.fetchTasks(token));
}

async function handleEmail() {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const refreshToken = process.env.GOOGLE_REFRESH_TOKEN;
  const msCreds = getMsCreds();

  const urgent = [];
  const recent = [];
  const errors = [];
  let anyConfigured = false;

  if (clientId && clientSecret && refreshToken) {
    anyConfigured = true;
    try {
      const { urgent: gUrgent, recent: gRecent } = await withTimeout(
        fetchTriage({ clientId, clientSecret, refreshToken }),
        FETCH_TIMEOUT_MS,
        'Gmail'
      );
      urgent.push(...gUrgent.map((m) => ({ ...m, source: 'Gmail' })));
      recent.push(...gRecent.map((m) => ({ ...m, source: 'Gmail' })));
    } catch (err) {
      errors.push(`Gmail: ${String(err.message || err)}`);
    }
  }

  if (msCreds) {
    anyConfigured = true;
    try {
      const accessToken = await withTimeout(outlook.getAccessToken(msCreds), FETCH_TIMEOUT_MS, 'Outlook token refresh');
      const { urgent: oUrgent, recent: oRecent } = await withTimeout(outlook.fetchMail(accessToken), FETCH_TIMEOUT_MS, 'Outlook Mail');
      urgent.push(...oUrgent);
      recent.push(...oRecent);
    } catch (err) {
      errors.push(`Outlook: ${String(err.message || err)}`);
    }
  }

  if (!anyConfigured) {
    return json({ configured: false, urgent: [], recent: [] });
  }
  const payload = { configured: true, urgent, recent };
  if (errors.length) payload.error = errors.join('; ');
  return json(payload);
}

const MIME = {
  '.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json',
  '.png': 'image/png', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json',
};

// Explicit allowlist: PUBLIC_DIR is the app root, which also holds .env,
// server/ source, and markdown docs — only these exact files and the icons/
// prefix are servable, everything else 404s regardless of what's on disk.
const STATIC_FILES = new Set(['/index.html', '/manifest.json', '/sw.js', '/offline.html']);

function serveStatic(pathname) {
  const rel = pathname === '/' ? '/index.html' : pathname;
  if (!STATIC_FILES.has(rel) && !rel.startsWith('/icons/')) {
    return new Response('Not found', { status: 404 });
  }
  const filePath = path.join(PUBLIC_DIR, rel);
  if (!filePath.startsWith(PUBLIC_DIR) || !fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    return new Response('Not found', { status: 404 });
  }
  const ext = path.extname(filePath);
  const body = fs.readFileSync(filePath);
  return new Response(body, { headers: { 'Content-Type': MIME[ext] || 'application/octet-stream' } });
}

Bun.serve({
  port: PORT,
  async fetch(req) {
    const { pathname } = new URL(req.url);
    if (pathname === '/api/calendar') return handleCalendar();
    if (pathname === '/api/reminders') return handleReminders();
    if (pathname === '/api/email') return handleEmail();
    return serveStatic(pathname);
  },
});

console.log(`Morning Dew backend listening on http://localhost:${PORT}`);
