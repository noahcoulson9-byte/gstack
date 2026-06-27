// Minimal Gmail API client using a long-lived OAuth refresh token.
// No googleapis dependency — two small fetch calls (token refresh + messages.list/get).

async function getAccessToken({ clientId, clientSecret, refreshToken }) {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
    }),
  });
  if (!res.ok) throw new Error(`token refresh failed: ${res.status}`);
  const data = await res.json();
  return data.access_token;
}

async function listMessages(accessToken, query, maxResults) {
  const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages?q=${encodeURIComponent(query)}&maxResults=${maxResults}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!res.ok) throw new Error(`messages.list failed: ${res.status}`);
  const data = await res.json();
  return data.messages || [];
}

async function getMessageSummary(accessToken, id) {
  const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}?format=metadata&metadataHeaders=Subject&metadataHeaders=From`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!res.ok) throw new Error(`messages.get failed: ${res.status}`);
  const data = await res.json();
  const headers = (data.payload && data.payload.headers) || [];
  const subject = headers.find((h) => h.name === 'Subject')?.value || '(no subject)';
  const from = headers.find((h) => h.name === 'From')?.value || 'Unknown sender';
  return { id, subject, from, snippet: data.snippet || '' };
}

// Returns { urgent: [...], recent: [...] }. Caller wraps in try/catch + timeout.
async function fetchTriage({ clientId, clientSecret, refreshToken }, { maxPerSection = 8 } = {}) {
  const accessToken = await getAccessToken({ clientId, clientSecret, refreshToken });

  const [urgentIds, recentIds] = await Promise.all([
    listMessages(accessToken, 'is:important is:unread', maxPerSection),
    listMessages(accessToken, 'is:unread newer_than:1d', maxPerSection),
  ]);

  const seen = new Set();
  const fetchAll = (ids) =>
    Promise.all(
      ids
        .filter((m) => !seen.has(m.id) && seen.add(m.id))
        .map((m) => getMessageSummary(accessToken, m.id))
    );

  const [urgent, recent] = await Promise.all([fetchAll(urgentIds), fetchAll(recentIds)]);
  return { urgent, recent };
}

module.exports = { fetchTriage };
