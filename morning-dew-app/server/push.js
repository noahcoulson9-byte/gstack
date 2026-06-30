// Web Push for the morning brief notification. Subscriptions persist in Upstash
// Redis (REST) because Render's free tier has an ephemeral filesystem — the 7am
// cron fires while the app is asleep, so the subscription must outlive restarts.
// Degrades to no-op when VAPID / Upstash env vars aren't set.

const webpush = require('web-push');

function pushConfigured() {
  return !!(process.env.VAPID_PUBLIC && process.env.VAPID_PRIVATE);
}

let vapidInited = false;
function initVapid() {
  if (vapidInited || !pushConfigured()) return;
  webpush.setVapidDetails(
    process.env.VAPID_SUBJECT || 'mailto:morningdew@example.com',
    process.env.VAPID_PUBLIC,
    process.env.VAPID_PRIVATE
  );
  vapidInited = true;
}

const SUBS_KEY = 'morningdew:pushsubs';

async function redis(cmd) {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  if (!url || !token) throw new Error('Upstash not configured');
  const res = await fetch(url, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(cmd),
  });
  if (!res.ok) throw new Error(`upstash ${res.status}`);
  return (await res.json()).result;
}

async function storeSubscription(sub) {
  await redis(['SADD', SUBS_KEY, JSON.stringify(sub)]);
}
async function listSubscriptions() {
  const arr = (await redis(['SMEMBERS', SUBS_KEY])) || [];
  return arr.map((s) => { try { return JSON.parse(s); } catch { return null; } }).filter(Boolean);
}
async function removeSubscription(raw) {
  await redis(['SREM', SUBS_KEY, raw]);
}

// Sends a notification payload to every stored subscription. Prunes dead ones.
async function sendToAll(payload) {
  initVapid();
  const subs = await listSubscriptions();
  let sent = 0;
  for (const sub of subs) {
    try {
      await webpush.sendNotification(sub, JSON.stringify(payload));
      sent += 1;
    } catch (err) {
      if (err && (err.statusCode === 404 || err.statusCode === 410)) {
        await removeSubscription(JSON.stringify(sub)).catch(() => {});
      }
    }
  }
  return sent;
}

module.exports = { pushConfigured, storeSubscription, sendToAll };
