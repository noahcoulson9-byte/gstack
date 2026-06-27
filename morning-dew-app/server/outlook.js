// Microsoft Graph client (OAuth refresh-token flow) for Outlook Calendar,
// Outlook Tasks (the Microsoft equivalent of Reminders), and Outlook Mail.
// Mirrors the shape of gmail.js so server.js can merge both providers.

async function getAccessToken({ clientId, clientSecret, refreshToken, tenantId }) {
  const tenant = tenantId || 'common';
  const res = await fetch(`https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
      scope: 'offline_access Calendars.Read Tasks.Read Mail.Read',
    }),
  });
  if (!res.ok) throw new Error(`token refresh failed: ${res.status}`);
  const data = await res.json();
  return data.access_token;
}

async function fetchCalendarEvents(accessToken, windowStart, windowEnd) {
  const url = `https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=${windowStart.toISOString()}&endDateTime=${windowEnd.toISOString()}&$orderby=start/dateTime`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}`, Prefer: 'outlook.timezone="UTC"' },
  });
  if (!res.ok) throw new Error(`calendarView failed: ${res.status}`);
  const data = await res.json();
  return (data.value || []).map((ev) => ({
    summary: ev.subject || '(untitled)',
    start: ev.start && ev.start.dateTime ? `${ev.start.dateTime}Z` : null,
    end: ev.end && ev.end.dateTime ? `${ev.end.dateTime}Z` : null,
    allDay: !!ev.isAllDay,
    location: (ev.location && ev.location.displayName) || null,
    source: 'Outlook',
  })).filter((ev) => ev.start);
}

async function fetchTasks(accessToken) {
  const listsRes = await fetch('https://graph.microsoft.com/v1.0/me/todo/lists', {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!listsRes.ok) throw new Error(`todo/lists failed: ${listsRes.status}`);
  const lists = (await listsRes.json()).value || [];

  const perList = await Promise.allSettled(
    lists.map(async (list) => {
      const res = await fetch(
        `https://graph.microsoft.com/v1.0/me/todo/lists/${list.id}/tasks?$filter=status ne 'completed'`,
        { headers: { Authorization: `Bearer ${accessToken}` } }
      );
      if (!res.ok) throw new Error(`tasks for list ${list.id} failed: ${res.status}`);
      const data = await res.json();
      return (data.value || []).map((t) => ({
        summary: t.title || '(untitled)',
        start: t.dueDateTime && t.dueDateTime.dateTime ? `${t.dueDateTime.dateTime}Z` : null,
        allDay: true,
        source: 'Outlook',
      }));
    })
  );

  const tasks = [];
  for (const r of perList) {
    if (r.status === 'fulfilled') tasks.push(...r.value);
    // a single bad list is skipped silently — the caller already wraps this
    // whole function in its own try/catch for the "Outlook tasks" error slot
  }
  return tasks;
}

async function fetchMail(accessToken, { maxPerSection = 8 } = {}) {
  const select = '$select=subject,from,bodyPreview';
  const urgentUrl = `https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$filter=isRead eq false and importance eq 'high'&$top=${maxPerSection}&${select}`;
  const recentUrl = `https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages?$filter=isRead eq false&$orderby=receivedDateTime desc&$top=${maxPerSection}&${select}`;

  const [urgentRes, recentRes] = await Promise.all([
    fetch(urgentUrl, { headers: { Authorization: `Bearer ${accessToken}` } }),
    fetch(recentUrl, { headers: { Authorization: `Bearer ${accessToken}` } }),
  ]);
  if (!urgentRes.ok) throw new Error(`mail (urgent) failed: ${urgentRes.status}`);
  if (!recentRes.ok) throw new Error(`mail (recent) failed: ${recentRes.status}`);

  const toSummary = (m) => ({
    id: m.id,
    subject: m.subject || '(no subject)',
    from: (m.from && m.from.emailAddress && (m.from.emailAddress.name || m.from.emailAddress.address)) || 'Unknown sender',
    snippet: m.bodyPreview || '',
    source: 'Outlook',
  });

  const urgentData = await urgentRes.json();
  const recentData = await recentRes.json();
  return {
    urgent: (urgentData.value || []).map(toSummary),
    recent: (recentData.value || []).map(toSummary),
  };
}

module.exports = { getAccessToken, fetchCalendarEvents, fetchTasks, fetchMail };
