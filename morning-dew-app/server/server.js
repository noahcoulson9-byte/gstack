// Morning Dew backend — serves the static PWA and proxies the data sources
// that need server-side secrets or server-side fetch (no CORS from a browser):
// iCloud calendar/reminders .ics feeds, and the Gmail API.
//
// Weather is NOT proxied here — Open-Meteo is CORS-enabled and keyless, so the
// frontend fetches it directly (see public/index.html).
//
// Run: bun run server/server.js   (reads env vars, see ../.env.example)

const path = require('path');
const fs = require('fs');
const { eventsInWindow } = require('./ics');
const { fetchTriage } = require('./gmail');

const PORT = process.env.PORT || 8787;
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
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

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function handleIcsFeed(envVarName, label) {
  const url = process.env[envVarName];
  if (!url) {
    return json({ configured: false, label, events: [] });
  }
  try {
    const res = await fetchWithTimeout(url, FETCH_TIMEOUT_MS);
    if (!res.ok) throw new Error(`fetch failed: ${res.status}`);
    const text = await res.text();
    const now = new Date();
    const windowEnd = new Date(now.getTime() + 48 * 3600 * 1000);
    const events = eventsInWindow(text, now, windowEnd);
    return json({ configured: true, label, events });
  } catch (err) {
    return json({ configured: true, label, events: [], error: String(err.message || err) }, 200);
  }
}

async function handleEmail() {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const refreshToken = process.env.GOOGLE_REFRESH_TOKEN;
  if (!clientId || !clientSecret || !refreshToken) {
    return json({ configured: false, urgent: [], recent: [] });
  }
  try {
    const { urgent, recent } = await fetchTriage({ clientId, clientSecret, refreshToken });
    return json({ configured: true, urgent, recent });
  } catch (err) {
    return json({ configured: true, urgent: [], recent: [], error: String(err.message || err) }, 200);
  }
}

const MIME = {
  '.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json',
  '.png': 'image/png', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json',
};

function serveStatic(pathname) {
  const rel = pathname === '/' ? '/index.html' : pathname;
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
    if (pathname === '/api/calendar') return handleIcsFeed('ICLOUD_ICS_URL', 'Calendar');
    if (pathname === '/api/reminders') return handleIcsFeed('REMINDERS_ICS_URL', 'Reminders');
    if (pathname === '/api/email') return handleEmail();
    return serveStatic(pathname);
  },
});

console.log(`Morning Dew backend listening on http://localhost:${PORT}`);
