// Minimal iCalendar (.ics) parser: VEVENT extraction + basic RRULE expansion.
// Supports FREQ=DAILY|WEEKLY|MONTHLY|YEARLY, INTERVAL, COUNT, UNTIL, BYDAY.
// Good enough for "what's coming up in the next 48 hours" — not a full RFC 5545 implementation.

function unfold(text) {
  // RFC 5545 line folding: continuation lines start with a space or tab.
  return text.replace(/\r\n/g, '\n').replace(/\n[ \t]/g, '');
}

function parseDate(value, params) {
  // value like 20260627T070000 or 20260627 (all-day) or with Z suffix (UTC).
  const isAllDay = (params.VALUE === 'DATE') || /^\d{8}$/.test(value);
  if (isAllDay) {
    const y = +value.slice(0, 4), m = +value.slice(4, 6), d = +value.slice(6, 8);
    return { date: new Date(y, m - 1, d), allDay: true };
  }
  const isUtc = value.endsWith('Z');
  const v = value.replace('Z', '');
  const y = +v.slice(0, 4), m = +v.slice(4, 6), d = +v.slice(6, 8);
  const hh = +v.slice(9, 11) || 0, mm = +v.slice(11, 13) || 0, ss = +v.slice(13, 15) || 0;
  // TZID-qualified times are treated as local time (best-effort — full IANA tz
  // database conversion is out of scope for a single-file parser).
  const date = isUtc ? new Date(Date.UTC(y, m - 1, d, hh, mm, ss)) : new Date(y, m - 1, d, hh, mm, ss);
  return { date, allDay: false };
}

function parseLine(line) {
  const colonIdx = line.indexOf(':');
  if (colonIdx === -1) return null;
  const head = line.slice(0, colonIdx);
  const value = line.slice(colonIdx + 1);
  const [name, ...paramParts] = head.split(';');
  const params = {};
  for (const p of paramParts) {
    const [k, v] = p.split('=');
    if (k) params[k] = v;
  }
  return { name: name.toUpperCase(), value, params };
}

function expandRRule(rruleStr, dtstart, windowStart, windowEnd) {
  const parts = {};
  for (const seg of rruleStr.split(';')) {
    const [k, v] = seg.split('=');
    if (k) parts[k] = v;
  }
  const freq = parts.FREQ;
  const interval = parseInt(parts.INTERVAL || '1', 10) || 1;
  const count = parts.COUNT ? parseInt(parts.COUNT, 10) : null;
  const until = parts.UNTIL ? parseDate(parts.UNTIL, {}).date : null;
  const byday = parts.BYDAY ? parts.BYDAY.split(',') : null;
  const dayMap = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

  const occurrences = [];
  let cursor = new Date(dtstart);
  let n = 0;
  const hardCap = 2000; // safety valve against malformed/infinite rules

  while (cursor <= windowEnd && n < hardCap) {
    if (count !== null && occurrences.length >= count) break;
    if (until && cursor > until) break;

    let matches = true;
    if (freq === 'WEEKLY' && byday) {
      matches = byday.some((d) => dayMap[d] === cursor.getDay());
    }
    if (matches && cursor >= windowStart && cursor <= windowEnd) {
      occurrences.push(new Date(cursor));
    }

    n++;
    switch (freq) {
      case 'DAILY':
        cursor = new Date(cursor.getTime() + interval * 86400000);
        break;
      case 'WEEKLY':
        cursor = new Date(cursor.getTime() + (byday ? 1 : interval * 7) * 86400000);
        break;
      case 'MONTHLY':
        cursor = new Date(cursor.getFullYear(), cursor.getMonth() + interval, cursor.getDate(),
          cursor.getHours(), cursor.getMinutes(), cursor.getSeconds());
        break;
      case 'YEARLY':
        cursor = new Date(cursor.getFullYear() + interval, cursor.getMonth(), cursor.getDate(),
          cursor.getHours(), cursor.getMinutes(), cursor.getSeconds());
        break;
      default:
        return occurrences; // unsupported FREQ — bail with whatever we found
    }
    if (cursor.getTime() === dtstart.getTime()) break; // guard against zero progress
  }
  return occurrences;
}

function parseIcs(icsText) {
  const lines = unfold(icsText).split('\n').map((l) => l.trim()).filter(Boolean);
  const events = [];
  let current = null;

  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') {
      current = {};
      continue;
    }
    if (line === 'END:VEVENT') {
      if (current) events.push(current);
      current = null;
      continue;
    }
    if (!current) continue;
    const parsed = parseLine(line);
    if (!parsed) continue;
    const { name, value, params } = parsed;
    if (name === 'SUMMARY') current.summary = value.replace(/\\,/g, ',').replace(/\\n/g, ' ');
    else if (name === 'DTSTART') current.dtstart = parseDate(value, params);
    else if (name === 'DTEND') current.dtend = parseDate(value, params);
    else if (name === 'RRULE') current.rrule = value;
    else if (name === 'LOCATION') current.location = value;
    else if (name === 'UID') current.uid = value;
  }
  return events;
}

// Returns events overlapping [windowStart, windowEnd], with recurring events expanded.
function eventsInWindow(icsText, windowStart, windowEnd) {
  const raw = parseIcs(icsText);
  const out = [];
  for (const ev of raw) {
    if (!ev.dtstart) continue;
    const durationMs = ev.dtend ? (ev.dtend.date.getTime() - ev.dtstart.date.getTime()) : 0;

    if (ev.rrule) {
      const starts = expandRRule(ev.rrule, ev.dtstart.date, windowStart, windowEnd);
      for (const start of starts) {
        out.push({
          summary: ev.summary || '(untitled)',
          start: start.toISOString(),
          end: durationMs ? new Date(start.getTime() + durationMs).toISOString() : null,
          allDay: !!ev.dtstart.allDay,
          location: ev.location || null,
        });
      }
    } else {
      const start = ev.dtstart.date;
      const end = ev.dtend ? ev.dtend.date : null;
      const overlaps = (end ? end : start) >= windowStart && start <= windowEnd;
      if (overlaps) {
        out.push({
          summary: ev.summary || '(untitled)',
          start: start.toISOString(),
          end: end ? end.toISOString() : null,
          allDay: !!ev.dtstart.allDay,
          location: ev.location || null,
        });
      }
    }
  }
  out.sort((a, b) => new Date(a.start) - new Date(b.start));
  return out;
}

module.exports = { parseIcs, eventsInWindow };
