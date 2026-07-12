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
const imap = require('./imap');
const outlook = require('./outlook');
const anthropic = require('./anthropic');
const caldav = require('./caldav');
const push = require('./push');
const health = require('./health');
const { computeRecovery, computeStrain, sleepHoursToScore } = require('./recovery');

// Process-level safety nets: a stray uncaught exception or unhandled promise
// rejection must NEVER take the whole backend down. Without these, one bad
// code path (or a runtime quirk in a fetch) kills the process and EVERY
// endpoint answers 502 until the host restarts it — which is exactly how the
// AI debriefs once went dark. Log loudly, keep serving.
process.on('uncaughtException', (err) => {
  console.error('[safety-net] uncaughtException:', err && err.stack ? err.stack : err);
});
process.on('unhandledRejection', (reason) => {
  console.error('[safety-net] unhandledRejection:', reason && reason.stack ? reason.stack : reason);
});

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
  // Apple's "Public Calendar" share links come out as webcal:// (and sometimes
  // webcals://), which fetch() can't handle ("URL is invalid"). They're plain
  // HTTPS .ics feeds underneath, so normalize the scheme before fetching.
  const urls = raw
    .split(',')
    .map((u) => u.trim())
    .filter(Boolean)
    .map((u) => u.replace(/^webcals:\/\//i, 'https://').replace(/^webcal:\/\//i, 'https://'));
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

// AI Morning Brief — the client POSTs today's aggregated context (events, tasks,
// weather, email counts); we ask Claude (server-side key) for a time-blocked plan.
// Degrades to { configured:false } when no ANTHROPIC_API_KEY is set so the UI can
// fall back to its computed glance.
async function handleBrief(req) {
  let context = {};
  try { context = await req.json(); } catch { /* empty body is fine */ }
  try {
    const result = await withTimeout(anthropic.generateBrief(context), 95000, 'Brief');
    return json(result);
  } catch (err) {
    return json({ configured: true, error: String(err.message || err) });
  }
}

// ---- Web Push: the morning brief notification ----
function isTodayServer(iso) {
  if (!iso) return false;
  const d = new Date(iso);
  const n = new Date();
  return d.toDateString() === n.toDateString();
}

function handlePushConfig() {
  return json({ configured: push.pushConfigured(), publicKey: process.env.VAPID_PUBLIC || null });
}

async function handlePushSubscribe(req) {
  try {
    const sub = await req.json();
    if (!sub || !sub.endpoint) return json({ ok: false, error: 'invalid subscription' }, 400);
    await push.storeSubscription(sub);
    return json({ ok: true });
  } catch (err) {
    return json({ ok: false, error: String(err.message || err) }, 500);
  }
}

// Triggered by the GitHub Actions cron at ~7am Brisbane. Composes a short morning
// nudge from the day's counts (no AI/location needed) and pushes it; tapping the
// notification opens the app, which writes the full AI brief client-side.
async function handleMorningPush(req) {
  if ((req.headers.get('x-cron-secret') || '') !== (process.env.CRON_SECRET || ' ')) {
    return json({ ok: false, error: 'forbidden' }, 403);
  }
  try {
    const [calR, remR, mailR] = await Promise.all([handleCalendar(), handleReminders(), handleEmail()]);
    const cal = await calR.json();
    const rem = await remR.json();
    const mail = await mailR.json();
    const events = (cal.events || []).filter((e) => isTodayServer(e.start)).length;
    const reminders = (rem.events || []).filter((e) => !e.start || isTodayServer(e.start)).length;
    const urgent = (mail.urgent || []).length;
    const bits = [events ? `${events} event${events > 1 ? 's' : ''}` : 'a clear calendar'];
    if (reminders) bits.push(`${reminders} reminder${reminders > 1 ? 's' : ''}`);
    if (urgent) bits.push(`${urgent} urgent email${urgent > 1 ? 's' : ''}`);
    const body = `Good morning ☀️ ${bits.join(', ')} today. Tap for your plan.`;
    const sent = await push.sendToAll({ title: 'Morning Dew', body });
    return json({ ok: true, sent });
  } catch (err) {
    return json({ ok: false, error: String(err.message || err) }, 500);
  }
}

function handleReminders() {
  return handleCalendarLike('REMINDERS_ICS_URL', 'Reminders', (token) => outlook.fetchTasks(token));
}

// ---- Apple Watch / Bevel readiness (strain, recovery, sleep) ----
// GET is the app's read path (browser-openable diagnostic too). POST is the iOS
// Shortcut's write path, guarded by HEALTH_TOKEN so only your phone can write.
async function handleHealthGet() {
  let data = null;
  try { data = await health.getHealth(); } catch { /* Upstash down → no data */ }
  return json({ configured: health.healthConfigured(), data });
}

// Health Auto Export's REST API automation sends a different shape entirely:
// { data: { metrics: [ { name: 'heart_rate_variability', data: [{ qty, date }, ...] }, ... ] } }
// Normalize it into the same flat {hrv, restingHeartRate, sleepHours, source} shape
// the rest of this handler already expects, picking the most recent data point
// per metric (export windows can include more than one reading per metric).
function latestQty(points, field = 'qty') {
  if (!Array.isArray(points) || points.length === 0) return null;
  const sorted = [...points].sort((a, b) => String(a.date || '').localeCompare(String(b.date || '')));
  return sorted[sorted.length - 1]?.[field] ?? null;
}
// Active Energy and Exercise Time are cumulative samples through the day (not
// point-in-time vitals like HRV/RHR), so they need summing across every point
// in the export window rather than "latest wins". Health Auto Export's own
// automation already scopes that window (e.g. "Last 24 Hours") — re-deriving
// day boundaries from naive date strings here would repeat the timezone bug
// class already fixed in the weather code, so we sum everything sent.
function sumQty(points, field = 'qty') {
  if (!Array.isArray(points) || points.length === 0) return null;
  const sum = points.reduce((a, p) => a + (Number(p?.[field]) || 0), 0);
  return sum;
}
function fromHealthAutoExport(body) {
  const metrics = body?.data?.metrics;
  if (!Array.isArray(metrics)) return null;
  const byName = Object.fromEntries(metrics.map((m) => [m.name, m]));
  const sleepData = byName.sleep_analysis?.data;
  const sleepPoint = Array.isArray(sleepData) && sleepData.length
    ? [...sleepData].sort((a, b) => String(a.date || '').localeCompare(String(b.date || ''))).pop()
    : null;
  return {
    hrv: latestQty(byName.heart_rate_variability?.data),
    restingHeartRate: latestQty(byName.resting_heart_rate?.data),
    sleepHours: sleepPoint ? (sleepPoint.totalSleep ?? sleepPoint.asleep ?? null) : null,
    activeEnergy: sumQty(byName.active_energy?.data),
    exerciseMinutes: sumQty(byName.apple_exercise_time?.data),
    source: 'Health Auto Export',
    // Every metric name this payload actually contained, regardless of whether
    // we recognized it — lets the readiness detail screen show exactly what the
    // automation is sending, instead of guessing why a score stayed blank.
    rawMetricNames: Object.keys(byName),
  };
}

async function handleHealthPost(req) {
  const expected = process.env.HEALTH_TOKEN || '';
  if (!expected) return json({ ok: false, error: 'not configured' }, 503);
  if ((req.headers.get('x-health-token') || '') !== expected) {
    return json({ ok: false, error: 'forbidden' }, 403);
  }
  let body = {};
  try { body = await req.json(); } catch { return json({ ok: false, error: 'invalid json' }, 400); }
  // Accept either bare numbers OR the raw text an iOS Shortcut/Athlytic emits
  // (e.g. "Your Recovery today is 85%."): pull the first number out and clamp
  // the three scores to 0–100 ints. Keeps the Shortcut dead simple — it can map
  // each app action's text straight into the field with no parsing steps.
  const firstNum = (v) => {
    if (v === null || v === undefined) return null;
    const m = String(v).match(/-?\d+(?:\.\d+)?/);
    return m ? Number(m[0]) : null;
  };
  const pct = (v) => {
    const n = firstNum(v);
    return n === null ? null : Math.max(0, Math.min(100, Math.round(n)));
  };

  // Raw Apple Watch metrics, from either an iOS Shortcut (flat fields) or
  // Health Auto Export's REST API automation (nested data.metrics[]).
  const hae = fromHealthAutoExport(body);
  const hrv = firstNum(body.hrv ?? hae?.hrv);
  const rhr = firstNum(body.restingHeartRate ?? body.rhr ?? hae?.restingHeartRate);
  const sleepHours = firstNum(body.sleepHours ?? hae?.sleepHours);
  const activeEnergy = firstNum(body.activeEnergy ?? hae?.activeEnergy);
  const exerciseMinutes = firstNum(body.exerciseMinutes ?? hae?.exerciseMinutes);
  const source = typeof body.source === 'string' ? body.source.slice(0, 40) : (hae ? hae.source : 'Shortcut');

  // A directly-supplied recovery (manual entry / Athlytic) always wins. Otherwise,
  // if raw metrics came in, compute our own recovery (and strain) against the
  // rolling baseline — both share one history fetch/persist round-trip.
  let recovery = pct(body.recovery);
  let computed = false;
  let calibrating = false;
  let strain = pct(body.strain);
  let sleep = pct(body.sleep);
  if (sleep === null && sleepHours != null) sleep = sleepHoursToScore(sleepHours);
  const today = new Date().toISOString().slice(0, 10);

  const hasRawMetrics = hrv !== null || rhr !== null || sleepHours !== null || activeEnergy !== null || exerciseMinutes !== null;
  if (hasRawMetrics && (recovery === null || strain === null)) {
    let history = {};
    try { history = await health.getHistory(); } catch { /* no baseline yet */ }
    const priorDays = Object.keys(history).filter((d) => d !== today).sort().map((d) => history[d]);

    if (recovery === null) {
      const r = computeRecovery({ hrv, rhr, sleepHours }, priorDays);
      if (r) { recovery = r.recovery; computed = true; calibrating = r.calibrating; }
    }
    if (strain === null) {
      const s = computeStrain({ activeEnergy, exerciseMinutes }, priorDays);
      if (s) strain = s.strain;
    }
    // Record today's metrics so tomorrow's baseline includes them.
    try {
      history[today] = { hrv, rhr, sleepHours, recovery, activeEnergy, exerciseMinutes, strain };
      await health.setHistory(history);
    } catch { /* baseline persistence is best-effort */ }
  }

  const data = {
    recovery,
    computed,
    calibrating,
    hrv,
    restingHeartRate: rhr,
    sleepHours,
    activeEnergy,
    exerciseMinutes,
    strain,
    sleep,
    source,
    rawMetricNames: hae?.rawMetricNames || null,
    updatedAt: new Date().toISOString(),
  };
  try {
    await health.storeHealth(data);
    return json({ ok: true, data });
  } catch (err) {
    return json({ ok: false, error: String(err.message || err) }, 500);
  }
}

async function handleNews() {
  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
    let res;
    try {
      res = await fetch('https://feeds.bbci.co.uk/news/rss.xml', {
        signal: controller.signal,
        headers: {
          'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
          'Accept': 'application/rss+xml, application/xml, text/xml, */*',
        },
      });
    } finally {
      clearTimeout(timer);
    }
    if (!res.ok) throw new Error(`BBC RSS ${res.status}`);
    const xml = await res.text();
    const articles = [];
    const itemRe = /<item>([\s\S]*?)<\/item>/g;
    let m;
    const getField = (raw, tag) => {
      const re = new RegExp(`<${tag}[^>]*>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?<\\/${tag}>`);
      const match = raw.match(re);
      return match ? match[1].replace(/\s+/g, ' ').trim() : '';
    };
    const stripTags = (s) => s.replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim();
    while ((m = itemRe.exec(xml)) !== null && articles.length < 20) {
      const raw = m[1];
      const thumb = (raw.match(/<media:thumbnail[^>]+url="([^"]+)"/) || [])[1] || '';
      articles.push({
        title: stripTags(getField(raw, 'title')),
        link: getField(raw, 'link'),
        description: stripTags(getField(raw, 'description')),
        pubDate: getField(raw, 'pubDate'),
        thumbnail: thumb,
      });
    }
    return json({ articles });
  } catch (err) {
    return json({ articles: [], error: String(err.message || err) });
  }
}

// Fetches + merges all configured email sources into one { configured, urgent,
// recent, error } object. `withBody` pulls a plaintext preview per message
// (used by the AI summary; the plain /api/email list skips it to stay fast).
async function gatherEmail({ withBody = false } = {}) {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const refreshToken = process.env.GOOGLE_REFRESH_TOKEN;
  // Gmail via IMAP app password — the phone-friendly, non-expiring path. Gmail
  // shows the 16-char app password in four space-separated groups; users paste
  // it as-is, so strip the spaces here.
  const imapUser = process.env.GMAIL_IMAP_USER;
  const imapPassword = (process.env.GMAIL_IMAP_PASSWORD || '').replace(/\s+/g, '');
  const msCreds = getMsCreds();

  const urgent = [];
  const recent = [];
  const errors = [];
  let anyConfigured = false;

  if (imapUser && imapPassword) {
    anyConfigured = true;
    try {
      const { urgent: iUrgent, recent: iRecent } = await withTimeout(
        imap.fetchTriage(
          {
            user: imapUser,
            password: imapPassword,
            host: process.env.GMAIL_IMAP_HOST || undefined,
            port: process.env.GMAIL_IMAP_PORT ? Number(process.env.GMAIL_IMAP_PORT) : undefined,
          },
          // withBody is an OPTION, not a credential — it used to ride in the
          // creds object where fetchTriage never read it, so the AI summary
          // silently ran on subject lines alone. The internal deadline stays
          // BELOW the outer race so fetchTriage always rejects cleanly first
          // and tears its own socket down.
          { withBody, deadlineMs: withBody ? 18000 : 12000 }
        ),
        withBody ? 22000 : 16000,
        'Gmail IMAP'
      );
      urgent.push(...iUrgent.map((m) => ({ ...m, source: 'Gmail' })));
      recent.push(...iRecent.map((m) => ({ ...m, source: 'Gmail' })));
    } catch (err) {
      errors.push(`Gmail IMAP: ${String(err.message || err)}`);
    }
  }

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

  return { configured: anyConfigured, urgent, recent, error: errors.length ? errors.join('; ') : null };
}

async function handleEmail() {
  const { configured, urgent, recent, error } = await gatherEmail();
  if (!configured) return json({ configured: false, urgent: [], recent: [] });
  const payload = { configured: true, urgent, recent };
  if (error) payload.error = error;
  return json(payload);
}

// AI inbox summary: gather the unread mail (with body previews) and ask Claude
// for highlights, tasks, and dated events. De-dupes urgent+recent by id.
async function handleEmailSummary() {
  const { configured, urgent, recent, error } = await gatherEmail({ withBody: true });
  if (!configured) return json({ configured: false });
  const seen = new Set();
  const emails = [...urgent, ...recent].filter((m) => {
    const key = m.id || (m.subject + m.date);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  try {
    const result = await withTimeout(anthropic.summarizeInbox(emails, new Date().toISOString()), 48000, 'Inbox summary');
    if (error) result.emailError = error;
    return json(result);
  } catch (err) {
    return json({ configured: true, error: String(err.message || err) });
  }
}

// Serves a single-event .ics so the app's "Add to calendar" button opens the
// phone's native Add-to-Calendar sheet (Apple/Google/Outlook — the user picks).
// Query: title, start (ISO or YYYY-MM-DD), end?, location?, notes?.
function icsEscape(s) {
  return String(s || '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
}
const z2 = (n) => String(n).padStart(2, '0');
// A timed value from the summary ("YYYY-MM-DDTHH:MM", the user's wall clock) is
// emitted as a FLOATING local datetime (no Z) so the phone shows it at that
// exact time in the user's own timezone — forcing UTC here would shift a "2pm"
// deadline by the UTC offset. A bare YYYY-MM-DD is an all-day DATE. Full ISO
// strings with an explicit offset fall back to UTC.
function parseWall(v) {
  const m = String(v).match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
  if (!m) return null;
  return { y: +m[1], mo: +m[2], d: +m[3], h: +m[4], mi: +m[5] };
}
function fmtWall(w) { return `${w.y}${z2(w.mo)}${z2(w.d)}T${z2(w.h)}${z2(w.mi)}00`; }
function toIcsDate(v) {
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return { allDay: true, value: v.replace(/-/g, '') };
  const w = parseWall(v);
  if (w) return { allDay: false, value: fmtWall(w), wall: w };
  const d = new Date(v); // has an explicit offset/zone -> normalize to UTC
  if (isNaN(d.getTime())) return null;
  const fmt = (dt) => `${dt.getUTCFullYear()}${z2(dt.getUTCMonth() + 1)}${z2(dt.getUTCDate())}T${z2(dt.getUTCHours())}${z2(dt.getUTCMinutes())}00Z`;
  return { allDay: false, value: fmt(d), utc: true };
}
function addMinutesWall(w, mins) {
  // Arithmetic via a UTC anchor (no zone math), read back as wall clock.
  const t = new Date(Date.UTC(w.y, w.mo - 1, w.d, w.h, w.mi) + mins * 60000);
  return { y: t.getUTCFullYear(), mo: t.getUTCMonth() + 1, d: t.getUTCDate(), h: t.getUTCHours(), mi: t.getUTCMinutes() };
}
function handleIcs(url) {
  const q = url.searchParams;
  const title = q.get('title') || 'Event';
  const start = toIcsDate(q.get('start') || '');
  if (!start) return json({ error: 'bad start date' }, 400);
  const uid = `md-${Date.now()}-${Math.random().toString(36).slice(2, 8)}@morningdew`;
  const now = new Date();
  const stamp = `${now.getUTCFullYear()}${z2(now.getUTCMonth() + 1)}${z2(now.getUTCDate())}T${z2(now.getUTCHours())}${z2(now.getUTCMinutes())}00Z`;
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Morning Dew//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH', 'BEGIN:VEVENT', `UID:${uid}`, `DTSTAMP:${stamp}`];
  if (start.allDay) {
    lines.push(`DTSTART;VALUE=DATE:${start.value}`);
  } else {
    lines.push(`DTSTART:${start.value}`);
    let endVal = null;
    const endParam = q.get('end') ? toIcsDate(q.get('end')) : null;
    if (endParam && !endParam.allDay) {
      endVal = endParam.value;
    } else if (start.wall) {
      const mins = Number(q.get('durationMins')) || 60;
      endVal = fmtWall(addMinutesWall(start.wall, mins));
    }
    if (endVal) lines.push(`DTEND:${endVal}`);
  }
  lines.push(`SUMMARY:${icsEscape(title)}`);
  if (q.get('location')) lines.push(`LOCATION:${icsEscape(q.get('location'))}`);
  if (q.get('notes')) lines.push(`DESCRIPTION:${icsEscape(q.get('notes'))}`);
  lines.push('END:VEVENT', 'END:VCALENDAR');
  return new Response(lines.join('\r\n'), {
    status: 200,
    headers: {
      'Content-Type': 'text/calendar; charset=utf-8',
      // inline (not attachment): iOS then renders the native "Add to Calendar"
      // event preview immediately instead of routing through a download page.
      'Content-Disposition': 'inline; filename="event.ics"',
      'Access-Control-Allow-Origin': '*',
    },
  });
}

// One-tap iCloud add: writes the event straight into the user's iCloud account
// via CalDAV, smart-routed into the calendar whose name matches the task's
// category (fitness → "Health & Fitness", chores → "Tasks", …). Returns
// {configured:false} when ICLOUD_CALDAV_USER/PASSWORD aren't set so the app
// can fall back to the .ics sheet flow. GET lists the discovered calendars as
// a browser-openable diagnostic.
async function handleCalendarAdd(req) {
  if (req.method === 'GET') {
    try { return json(await caldav.listCalendars()); }
    catch (err) { return json({ configured: true, error: String(err.message || err) }, 502); }
  }
  let body;
  try { body = await req.json(); } catch { return json({ error: 'bad JSON body' }, 400); }
  const title = String(body.title || '').slice(0, 200).trim();
  const start = String(body.start || '');
  if (!title) return json({ error: 'missing title' }, 400);
  if (!/^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$/.test(start)) return json({ error: 'bad start date' }, 400);
  try {
    const result = await caldav.addEvent({
      title,
      start,
      durationMins: Math.min(Math.max(Number(body.durationMins) || 60, 5), 24 * 60),
      notes: String(body.notes || '').slice(0, 1000),
      location: String(body.location || '').slice(0, 200),
      category: String(body.category || '').slice(0, 40),
    });
    return json(result);
  } catch (err) {
    return json({ configured: true, error: String(err.message || err) }, 502);
  }
}

const MIME = {
  '.html': 'text/html', '.js': 'application/javascript', '.json': 'application/json',
  '.png': 'image/png', '.ico': 'image/x-icon', '.webmanifest': 'application/manifest+json',
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp', '.svg': 'image/svg+xml',
};

// Explicit allowlist: PUBLIC_DIR is the app root, which also holds .env,
// server/ source, and markdown docs — only these exact files and the icons/
// and assets/ prefixes are servable, everything else 404s regardless of what's
// on disk.
const STATIC_FILES = new Set(['/index.html', '/manifest.json', '/sw.js', '/offline.html']);

function serveStatic(pathname) {
  const rel = pathname === '/' ? '/index.html' : pathname;
  if (!STATIC_FILES.has(rel) && !rel.startsWith('/icons/') && !rel.startsWith('/assets/')) {
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

// CORS preflight — the cross-origin POST /api/brief (JSON content-type) triggers
// an OPTIONS preflight that the simple GETs don't.
function preflight() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'content-type, x-health-token',
      'Access-Control-Max-Age': '86400',
    },
  });
}

Bun.serve({
  port: PORT,
  // Bun-level error hook: if a route handler throws in a way the per-route
  // try/catch didn't cover, answer with a clean JSON 500 instead of dropping
  // the connection (which surfaces to clients as an opaque 502 at the edge).
  error(err) {
    console.error('[safety-net] route error:', err && err.stack ? err.stack : err);
    return json({ error: `server error: ${String((err && err.message) || err).slice(0, 200)}` }, 500);
  },
  async fetch(req) {
    const url = new URL(req.url);
    const { pathname } = url;
    if (req.method === 'OPTIONS') return preflight();
    if (pathname === '/api/calendar') return handleCalendar();
    if (pathname === '/api/reminders') return handleReminders();
    if (pathname === '/api/email') return handleEmail();
    if (pathname === '/api/email-summary') return handleEmailSummary();
    if (pathname === '/api/ics') return handleIcs(url);
    if (pathname === '/api/calendar-add') return handleCalendarAdd(req);
    // POST is the app's normal path; GET is a browser-openable diagnostic that
    // shows the raw brief result (configured flag / brief / Anthropic error).
    if (pathname === '/api/brief') return handleBrief(req);
    if (pathname === '/api/push/config') return handlePushConfig();
    if (pathname === '/api/push/subscribe' && req.method === 'POST') return handlePushSubscribe(req);
    if (pathname === '/api/cron/morning-push' && req.method === 'POST') return handleMorningPush(req);
    if (pathname === '/api/health' && req.method === 'POST') return handleHealthPost(req);
    if (pathname === '/api/health') return handleHealthGet();
    if (pathname === '/api/news') return handleNews();
    return serveStatic(pathname);
  },
});

console.log(`Morning Dew backend listening on http://localhost:${PORT}`);
