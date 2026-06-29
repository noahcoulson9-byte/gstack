// Apple Watch / Bevel readiness snapshot (strain, recovery, sleep). An iOS
// Shortcut POSTs today's values (guarded by HEALTH_TOKEN); the app GETs them to
// draw the readiness rings. Persists in Upstash Redis (REST) so the latest
// snapshot survives Render's ephemeral filesystem and backend restarts.
// Degrades to not-configured when HEALTH_TOKEN / Upstash env vars aren't set.

const HEALTH_KEY = 'morningdew:health';

function healthConfigured() {
  return !!process.env.HEALTH_TOKEN;
}

// Minimal Upstash REST call (same shape as push.js). Kept self-contained so the
// readiness store doesn't couple to the push module's lifecycle.
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

async function storeHealth(data) {
  await redis(['SET', HEALTH_KEY, JSON.stringify(data)]);
}

async function getHealth() {
  const raw = await redis(['GET', HEALTH_KEY]);
  if (!raw) return null;
  try { return JSON.parse(raw); } catch { return null; }
}

module.exports = { healthConfigured, storeHealth, getHealth };
