// Minimal read-only IMAP client for Gmail, used when you connect a Gmail
// mailbox with an *app password* instead of the OAuth flow in gmail.js.
//
// Why this exists: Gmail's REST API only accepts OAuth, and an unverified
// personal OAuth app has refresh tokens that expire every 7 days — the mail
// feed would silently die weekly. An app password + IMAP has none of that:
// it never expires, needs no Google Cloud project, and is set up entirely
// from a phone (2-Step Verification on -> generate app password).
//
// This speaks just enough of RFC 3501 to log in, select INBOX, run two
// Gmail searches (via the X-GM-RAW extension so the queries match gmail.js
// exactly), and pull Subject/From/Date headers with BODY.PEEK (which does
// NOT mark anything read). It returns the same { urgent, recent } shape as
// gmail.js so server.js can treat both interchangeably.

const tls = require('tls');

// One TLS IMAP connection with a promise-per-command runner. The tricky part
// of IMAP parsing is literals: a server line can end with `{N}` meaning "the
// next N bytes are literal data (which may contain CRLFs) that belong to this
// same response." The reader below tracks that byte count so header blocks are
// captured whole instead of being split on their internal newlines.
class ImapClient {
  constructor(socket) {
    this.sock = socket;
    this.tagCounter = 0;
    this.logical = '';        // current logical line being assembled
    this.pendingLiteral = 0;  // literal bytes still owed to the current line
    this.lines = [];          // completed logical lines for the in-flight command
    this.currentTag = null;
    this.resolve = null;
    this.reject = null;
    this.greetResolve = null; // set while waiting for the server greeting
    socket.on('data', (chunk) => this._onData(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
    socket.on('error', (err) => this._fail(err));
    socket.on('close', () => this._fail(new Error('IMAP connection closed')));
  }

  _fail(err) {
    const rej = this.reject;
    this.reject = null; this.resolve = null;
    if (rej) rej(err);
  }

  _onData(chunk) {
    let i = 0;
    while (i < chunk.length) {
      if (this.pendingLiteral > 0) {
        const take = Math.min(this.pendingLiteral, chunk.length - i);
        this.logical += chunk.toString('utf8', i, i + take);
        i += take;
        this.pendingLiteral -= take;
        continue;
      }
      const nl = chunk.indexOf(0x0a, i); // \n
      if (nl === -1) { this.logical += chunk.toString('utf8', i); break; }
      this.logical += chunk.toString('utf8', i, nl + 1);
      i = nl + 1;
      const lit = this.logical.match(/\{(\d+)\}\r?\n$/);
      if (lit) {
        // Line ends with a literal marker — the bytes that follow continue THIS
        // logical line, so don't finalize it yet.
        this.pendingLiteral = parseInt(lit[1], 10);
      } else {
        this._emitLine(this.logical);
        this.logical = '';
      }
    }
  }

  _emitLine(line) {
    // Before any command is issued, the only thing arriving is the server
    // greeting (`* OK ...`) — hand it to whoever is waiting and discard.
    if (!this.currentTag) {
      const g = this.greetResolve;
      if (g) { this.greetResolve = null; g(); }
      return;
    }
    this.lines.push(line);
    const trimmed = line.replace(/\r?\n$/, '');
    if (trimmed.startsWith(this.currentTag + ' ')) {
      const status = trimmed.slice(this.currentTag.length + 1).split(' ')[0]; // OK | NO | BAD
      const resolve = this.resolve;
      const lines = this.lines;
      this.currentTag = null; this.resolve = null; this.reject = null; this.lines = [];
      if (resolve) resolve({ status, lines });
    }
  }

  // Resolves once the server greeting line has been received.
  waitGreeting() {
    return new Promise((resolve) => { this.greetResolve = resolve; });
  }

  // Sends a tagged command; resolves with { status, lines } at its tagged
  // completion. Commands are run one at a time (awaited) so a single tag/
  // resolver pair is always sufficient.
  command(text) {
    const tag = 'A' + String(++this.tagCounter).padStart(3, '0');
    this.currentTag = tag;
    this.lines = [];
    return new Promise((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
      this.sock.write(tag + ' ' + text + '\r\n');
    });
  }

  close() { try { this.sock.end(); } catch { /* already closed */ } }
}

function quote(s) { return '"' + String(s).replace(/([\\"])/g, '\\$1') + '"'; }

// Unfold RFC 5322 header continuation lines, then read one header's value.
// Normalize CRLF -> LF first: JS `.` doesn't match `\r`, so a `$`-anchored
// pattern would never match against raw CRLF-terminated header lines.
function readHeader(block, name) {
  const unfolded = block.replace(/\r\n/g, '\n').replace(/\n[ \t]+/g, ' ');
  const re = new RegExp('^' + name + ':\\s*(.*)$', 'im');
  const m = unfolded.match(re);
  return m ? m[1].trim() : '';
}

function parseSearchUids(lines) {
  for (const rawLine of lines) {
    const line = rawLine.replace(/[\r\n]+$/, '');
    const m = line.match(/^\* SEARCH\b(.*)/i);
    if (m) {
      return m[1].trim().split(/\s+/).filter(Boolean).map((n) => parseInt(n, 10)).filter(Number.isFinite);
    }
  }
  return [];
}

// One `* n FETCH (...)` logical line -> { id, subject, from, snippet, date }.
function parseFetchLine(line) {
  const uidMatch = line.match(/UID\s+(\d+)/i);
  const id = uidMatch ? uidMatch[1] : null;
  // The header block is the literal after BODY[...] — everything is inlined in
  // `line`, so just read the three headers out of the whole thing.
  const subject = readHeader(line, 'Subject') || '(no subject)';
  const from = readHeader(line, 'From') || 'Unknown sender';
  const rawDate = readHeader(line, 'Date');
  let date = null;
  if (rawDate) { const d = new Date(rawDate); if (!isNaN(d.getTime())) date = d.toISOString(); }
  return { id, subject, from, snippet: '', date };
}

async function searchAndFetch(client, gmailQuery, maxResults) {
  const search = await client.command(`UID SEARCH X-GM-RAW ${quote(gmailQuery)}`);
  if (search.status !== 'OK') return [];
  let uids = parseSearchUids(search.lines);
  if (!uids.length) return [];
  // Highest UIDs are the most recent; keep the newest `maxResults`.
  uids = uids.sort((a, b) => b - a).slice(0, maxResults);
  const fetch = await client.command(
    `UID FETCH ${uids.join(',')} (BODY.PEEK[HEADER.FIELDS (SUBJECT FROM DATE)])`
  );
  if (fetch.status !== 'OK') return [];
  const msgs = fetch.lines
    .filter((l) => /^\* \d+ FETCH /i.test(l))
    .map(parseFetchLine)
    .filter((m) => m.id);
  // Preserve newest-first ordering to match the UID sort above.
  const order = new Map(uids.map((u, i) => [String(u), i]));
  msgs.sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
  return msgs;
}

// Public API — mirrors gmail.js's fetchTriage signature/return shape.
// creds: { user, password, host?, port?, rejectUnauthorized? }
async function fetchTriage(creds, { maxPerSection = 8, deadlineMs = 14000 } = {}) {
  const host = creds.host || 'imap.gmail.com';
  const port = creds.port || 993;
  const rejectUnauthorized = creds.rejectUnauthorized !== false;

  return await new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn, arg) => { if (settled) return; settled = true; clearTimeout(timer); try { client && client.close(); } catch { /* noop */ } fn(arg); };
    const timer = setTimeout(() => finish(reject, new Error('IMAP timed out')), deadlineMs);

    let client = null;
    const socket = tls.connect({ host, port, servername: host, rejectUnauthorized }, async () => {
      try {
        await client.waitGreeting();
        const login = await client.command(`LOGIN ${quote(creds.user)} ${quote(creds.password)}`);
        if (login.status !== 'OK') throw new Error('IMAP login failed (check the app password)');
        const sel = await client.command('SELECT INBOX');
        if (sel.status !== 'OK') throw new Error('could not open INBOX');
        const urgent = await searchAndFetch(client, 'is:important is:unread', maxPerSection);
        const recent = await searchAndFetch(client, 'is:unread newer_than:1d', maxPerSection);
        try { await client.command('LOGOUT'); } catch { /* best effort */ }
        finish(resolve, { urgent, recent });
      } catch (err) {
        finish(reject, err);
      }
    });
    socket.on('error', (err) => finish(reject, err));
    client = new ImapClient(socket);
  });
}

module.exports = { fetchTriage, _internal: { parseFetchLine, parseSearchUids, readHeader } };
