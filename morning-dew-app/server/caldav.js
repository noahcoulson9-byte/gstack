// Minimal iCloud CalDAV client for one-tap "add to calendar" — no dependencies,
// plain fetch + Basic auth (Apple ID + app-specific password from
// appleid.apple.com). Discovers the account's calendar list once (cached), and
// SMART-ROUTES each event into the calendar whose name best matches the task's
// AI-assigned category: a walk lands in "Health & Fitness", dishes land in
// "Tasks", uni work lands in "Uni" — falling back to the default calendar when
// nothing matches. Events are written as floating local time (no timezone
// suffix) so 8am means 8am on the user's wall clock, same as /api/ics.

const CALDAV_ROOT = process.env.ICLOUD_CALDAV_URL || 'https://caldav.icloud.com';

function creds() {
  const user = process.env.ICLOUD_CALDAV_USER;
  const pass = (process.env.ICLOUD_CALDAV_PASSWORD || '').replace(/\s+/g, '');
  if (!user || !pass) return null;
  return 'Basic ' + Buffer.from(`${user}:${pass}`).toString('base64');
}

function configured() { return creds() !== null; }

async function dav(url, method, body, extraHeaders = {}, timeoutMs = 15000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      method,
      signal: controller.signal,
      headers: {
        Authorization: creds(),
        'Content-Type': 'application/xml; charset=utf-8',
        ...extraHeaders,
      },
      body,
    });
    const text = await res.text();
    return { status: res.status, text, headers: res.headers };
  } finally {
    clearTimeout(timer);
  }
}

// Tiny XML helpers — CalDAV multistatus responses are namespaced but shallow;
// regex extraction on <D:response> blocks is enough for the four properties we
// read, and avoids an XML dependency in the compiled server.
function xmlBlocks(text, tag) {
  const re = new RegExp(`<(?:[\\w-]+:)?${tag}[\\s>][\\s\\S]*?</(?:[\\w-]+:)?${tag}>`, 'gi');
  return text.match(re) || [];
}
function xmlValue(block, tag) {
  const m = block.match(new RegExp(`<(?:[\\w-]+:)?${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</(?:[\\w-]+:)?${tag}>`, 'i'));
  return m ? m[1].trim() : '';
}
function xmlHref(block, containerTag) {
  const container = xmlValue(block, containerTag);
  const m = container.match(/<(?:[\w-]+:)?href[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?href>/i);
  return m ? m[1].trim() : '';
}
function decodeEntities(s) {
  return s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)));
}

// ---- Discovery (cached ~10 min; iCloud topology doesn't move often) ----
let _cache = { at: 0, calendars: null };
const CACHE_MS = 10 * 60 * 1000;

async function discoverCalendars() {
  if (_cache.calendars && Date.now() - _cache.at < CACHE_MS) return _cache.calendars;

  // 1. Who am I?
  const p1 = await dav(CALDAV_ROOT, 'PROPFIND',
    '<?xml version="1.0"?><propfind xmlns="DAV:"><prop><current-user-principal/></prop></propfind>',
    { Depth: '0' });
  if (p1.status === 401) throw new Error('iCloud rejected the credentials (check the app-specific password)');
  const principal = xmlHref(p1.text, 'current-user-principal');
  if (!principal) throw new Error(`could not discover the iCloud principal (status ${p1.status})`);
  const principalUrl = new URL(principal, CALDAV_ROOT).href;

  // 2. Where do my calendars live?
  const p2 = await dav(principalUrl, 'PROPFIND',
    '<?xml version="1.0"?><propfind xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><prop><C:calendar-home-set/></prop></propfind>',
    { Depth: '0' });
  const home = xmlHref(p2.text, 'calendar-home-set');
  if (!home) throw new Error(`could not discover the calendar home (status ${p2.status})`);
  const homeUrl = new URL(home, principalUrl).href;

  // 3. List the calendars (name + which component types they accept).
  const p3 = await dav(homeUrl, 'PROPFIND',
    '<?xml version="1.0"?><propfind xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><prop><displayname/><resourcetype/><C:supported-calendar-component-set/></prop></propfind>',
    { Depth: '1' });
  const calendars = [];
  for (const block of xmlBlocks(p3.text, 'response')) {
    const hrefM = block.match(/<(?:[\w-]+:)?href[^>]*>([\s\S]*?)<\/(?:[\w-]+:)?href>/i);
    if (!hrefM) continue;
    const href = hrefM[1].trim();
    // A calendar collection declares <calendar/> inside its resourcetype.
    const rtype = xmlValue(block, 'resourcetype');
    if (!/<(?:[\w-]+:)?calendar[\s/>]/i.test(rtype)) continue;
    // Only calendars that accept VEVENTs (skips reminder lists and inbox/outbox).
    const comps = block.match(/comp\s+name="([A-Z]+)"/gi) || [];
    const acceptsEvents = comps.length === 0 || comps.some((c) => /VEVENT/i.test(c));
    if (!acceptsEvents) continue;
    const name = decodeEntities(xmlValue(block, 'displayname'));
    if (!name) continue;
    calendars.push({ name, url: new URL(href, homeUrl).href });
  }
  if (!calendars.length) throw new Error('no event calendars found on the iCloud account');
  _cache = { at: Date.now(), calendars };
  return calendars;
}

// ---- Category → calendar routing ----
// The AI tags each task with a coarse category; we match it against the user's
// REAL calendar names (case-insensitive substring both ways), so "fitness"
// finds "Health & Fitness", "chores" finds "Tasks" or "Home", etc.
const CATEGORY_KEYWORDS = {
  fitness: ['fitness', 'health', 'workout', 'gym', 'exercise', 'training', 'sport', 'run'],
  health: ['health', 'fitness', 'medical', 'wellbeing'],
  chores: ['task', 'chore', 'home', 'house', 'errand', 'to do', 'todo'],
  errands: ['errand', 'task', 'chore', 'to do', 'todo'],
  work: ['work', 'job', 'office', 'business'],
  study: ['uni', 'university', 'study', 'school', 'class', 'course', 'assignment', 'qut'],
  social: ['social', 'friends', 'family', 'personal', 'fun'],
  finance: ['finance', 'money', 'bills', 'budget'],
  event: ['event', 'calendar', 'appointment'],
};

function pickCalendar(calendars, category) {
  const cat = String(category || '').toLowerCase().trim();
  const names = calendars.map((c) => ({ ...c, lc: c.name.toLowerCase() }));
  const keywords = CATEGORY_KEYWORDS[cat] || (cat ? [cat] : []);
  for (const kw of keywords) {
    const hit = names.find((c) => c.lc.includes(kw) || kw.includes(c.lc));
    if (hit) return hit;
  }
  // Sensible defaults when nothing matches: Home > Personal > first calendar.
  return names.find((c) => c.lc === 'home') || names.find((c) => c.lc.includes('personal')) || names[0];
}

// ---- Event writing (floating local wall time, same contract as /api/ics) ----
const z2 = (n) => String(n).padStart(2, '0');
function parseWallDate(v) {
  const m = String(v || '').match(/^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?$/);
  if (!m) return null;
  return { y: +m[1], mo: +m[2], d: +m[3], h: m[4] !== undefined ? +m[4] : null, mi: m[5] !== undefined ? +m[5] : 0 };
}
function fmtWallDate(w) { return `${w.y}${z2(w.mo)}${z2(w.d)}T${z2(w.h)}${z2(w.mi)}00`; }
function addMins(w, mins) {
  const dt = new Date(w.y, w.mo - 1, w.d, w.h, w.mi + mins);
  return { y: dt.getFullYear(), mo: dt.getMonth() + 1, d: dt.getDate(), h: dt.getHours(), mi: dt.getMinutes() };
}
function esc(s) { return String(s || '').replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n'); }

function buildVevent({ uid, title, start, durationMins, notes, location }) {
  const w = parseWallDate(start);
  if (!w) throw new Error('bad start date');
  const now = new Date();
  const stamp = `${now.getUTCFullYear()}${z2(now.getUTCMonth() + 1)}${z2(now.getUTCDate())}T${z2(now.getUTCHours())}${z2(now.getUTCMinutes())}00Z`;
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Morning Dew//EN', 'BEGIN:VEVENT', `UID:${uid}`, `DTSTAMP:${stamp}`];
  if (w.h === null) {
    lines.push(`DTSTART;VALUE=DATE:${w.y}${z2(w.mo)}${z2(w.d)}`);
  } else {
    lines.push(`DTSTART:${fmtWallDate(w)}`);
    lines.push(`DTEND:${fmtWallDate(addMins(w, Number(durationMins) || 60))}`);
  }
  lines.push(`SUMMARY:${esc(title || 'Event')}`);
  if (location) lines.push(`LOCATION:${esc(location)}`);
  if (notes) lines.push(`DESCRIPTION:${esc(notes)}`);
  lines.push('END:VEVENT', 'END:VCALENDAR');
  return lines.join('\r\n');
}

// Adds the event; returns { ok: true, calendar } on success.
async function addEvent({ title, start, durationMins, notes, location, category }) {
  if (!configured()) return { configured: false };
  const calendars = await discoverCalendars();
  const target = pickCalendar(calendars, category);
  const uid = `md-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  const ics = buildVevent({ uid, title, start, durationMins, notes, location });
  const putUrl = target.url.replace(/\/?$/, '/') + uid + '.ics';
  let res = await dav(putUrl, 'PUT', ics, { 'Content-Type': 'text/calendar; charset=utf-8', 'If-None-Match': '*' });
  if (res.status === 403 || res.status === 405) {
    // Read-only / non-writable target (e.g. a subscribed calendar slipped
    // through) — retry once against the default pick.
    const fallback = pickCalendar(calendars, null);
    if (fallback.url !== target.url) {
      const url2 = fallback.url.replace(/\/?$/, '/') + uid + '.ics';
      res = await dav(url2, 'PUT', ics, { 'Content-Type': 'text/calendar; charset=utf-8', 'If-None-Match': '*' });
      if (res.status >= 200 && res.status < 300) return { ok: true, calendar: fallback.name };
    }
  }
  if (res.status >= 200 && res.status < 300) return { ok: true, calendar: target.name };
  throw new Error(`iCloud rejected the event (status ${res.status})`);
}

async function listCalendars() {
  if (!configured()) return { configured: false };
  return { configured: true, calendars: (await discoverCalendars()).map((c) => c.name) };
}

module.exports = {
  configured, addEvent, listCalendars,
  _internal: { xmlBlocks, xmlValue, xmlHref, pickCalendar, buildVevent, parseWallDate, addMins, _cache: () => _cache, _resetCache: () => { _cache = { at: 0, calendars: null }; } },
};
