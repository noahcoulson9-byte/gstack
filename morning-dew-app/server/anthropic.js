// Minimal Anthropic (Claude) client for the AI Morning Brief. No SDK — one fetch
// to the Messages API using a server-side key, so the key never reaches the
// browser. Mirrors the style of gmail.js / outlook.js.

const MODEL = process.env.ANTHROPIC_MODEL || 'claude-haiku-4-5-20251001';
const BRIEF_TIMEOUT_MS = 25000;

const SYSTEM_PROMPT = `You are Morning Dew, a sharp, warm personal chief-of-staff.
You are given the user's day as JSON: current local time, calendar events, tasks
(some done), weather (temp, condition, rain chance, nudges), and email counts.
Write a short morning brief that helps them actually run the day.

Rules:
- First line: ONE punchy headline, max ~12 words, prefixed with "## " so the app can show it big. No emoji spam (one is fine).
- Then a "**Plan**" with a few time-blocked bullets built from their REAL events and the gaps between them: when to leave for events (factor in rain), where to slot focused work, and which 1-3 things matter most today.
- Use their real event names and times. Be specific and concrete.
- Max ~180 words total. Markdown only (##, **bold**, - bullets). Encouraging, never cheesy, never robotic. Do not mention being an AI or that you were given JSON.
- If the day is light or data is sparse, still give a short, genuinely useful plan.`;

async function generateBrief(context) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return { configured: false };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), BRIEF_TIMEOUT_MS);
  try {
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 800,
        system: SYSTEM_PROMPT,
        messages: [
          { role: 'user', content: `Here is today's context:\n\n${JSON.stringify(context)}\n\nWrite my morning brief.` },
        ],
      }),
    });
    if (!res.ok) {
      const body = await res.text();
      throw new Error(`anthropic ${res.status}: ${body.slice(0, 200)}`);
    }
    const data = await res.json();
    const brief = (data.content || [])
      .filter((b) => b.type === 'text')
      .map((b) => b.text)
      .join('')
      .trim();
    return { configured: true, brief };
  } finally {
    clearTimeout(timer);
  }
}

module.exports = { generateBrief };
