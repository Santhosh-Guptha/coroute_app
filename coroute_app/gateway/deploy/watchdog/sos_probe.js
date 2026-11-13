'use strict';
/**
 * Round 8 synthetic SOS probe (HIGH_TRAFFIC_PLAN_v3.57 item 7a), run by the watchdog on vm3 / vm4 against STAGING only.
 *
 * Every WATCH_SOS_PROBE_EVERY_MIN (15) minutes: two dedicated staging test accounts sign in, open a socket each and JOIN
 * the dedicated probe group; account A raises an SOS (clientSentSms: true, so the server never texts anyone) and the
 * time until account B's socket receives that ALERT is measured; A then resolves it as a false alarm.
 * An e-mail goes out when delivery takes longer than WATCH_SOS_PROBE_MAX_MS (1000) or fails (first bad run, then once
 * an hour while it stays bad, and once when it recovers); every result goes to WATCH_SOS_PROBE_STATUS (a JSON file the
 * daily summary reads) and the daily summary has runs, failures, p50 / p95 / max.
 *
 * Never production riders. The probe refuses to run unless:
 *   - the socket URL's host contains "staging" (or equals WATCH_SOS_PROBE_ALLOW_HOST, for a local test gateway);
 *   - the group's name starts with "SOS probe" and its riders are exactly the two probe accounts.
 * A refusal is reported like a failure (mail), so a misconfiguration is noticed.
 *
 * Settings (watchdog.env; the password comes from the secrets file, never the env file in git):
 *   WATCH_SOS_PROBE=1  WATCH_SOS_PROBE_URL=wss://staging.<domain>/ws  WATCH_SOS_PROBE_API=https://staging.<domain>/api
 *   WATCH_SOS_PROBE_GROUP=GRP-XXXXXXXX  WATCH_SOS_PROBE_EMAIL_A=  WATCH_SOS_PROBE_EMAIL_B=  WATCH_SOS_PROBE_PASSWORD=
 *   WATCH_SOS_PROBE_EVERY_MIN=15  WATCH_SOS_PROBE_MAX_MS=1000  WATCH_SOS_PROBE_TIMEOUT_MS=10000
 *   WATCH_SOS_PROBE_STATUS=/var/lib/coroute-watchdog/sos_probe.json
 * One-time setup on staging: deploy/watchdog/README section in gateway/deploy/RUNBOOK.md ("SOS probe").
 */
const fs = require('fs');
const path = require('path');

const PROBE_GROUP_PREFIX = 'SOS probe';

/**
 * A stable device identity per probe account: the ride lock (src/ride_lock.js) lets the same device sign in again while
 * its earlier session is "riding" in the probe group, so a sign-in every 15 minutes is never refused with 423.
 */
function probeDevice(email) {
  const id = `sos-probe-${require('crypto').createHash('sha256').update(String(email).toLowerCase()).digest('hex').slice(0, 24)}`;
  return { id, installId: id, label: 'CoRoute SOS probe', platform: 'probe' };
}

function pct(sorted, p) { if (!sorted.length) return null; return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]; }

function probeConfig(env = process.env) {
  return {
    enabled: env.WATCH_SOS_PROBE === '1',
    url: String(env.WATCH_SOS_PROBE_URL || ''),
    api: String(env.WATCH_SOS_PROBE_API || '').replace(/\/+$/, ''),
    group: String(env.WATCH_SOS_PROBE_GROUP || ''),
    emailA: String(env.WATCH_SOS_PROBE_EMAIL_A || ''),
    emailB: String(env.WATCH_SOS_PROBE_EMAIL_B || ''),
    password: String(env.WATCH_SOS_PROBE_PASSWORD || ''),
    everyMs: Math.max(1, Number(env.WATCH_SOS_PROBE_EVERY_MIN || 15)) * 60000,
    maxMs: Math.max(50, Number(env.WATCH_SOS_PROBE_MAX_MS || 1000)),
    timeoutMs: Math.max(1000, Number(env.WATCH_SOS_PROBE_TIMEOUT_MS || 10000)),
    statusFile: env.WATCH_SOS_PROBE_STATUS || '/var/lib/coroute-watchdog/sos_probe.json',
    allowHost: String(env.WATCH_SOS_PROBE_ALLOW_HOST || ''),
  };
}

/** The staging-only guard on the URL. '' when fine, else why not. */
function hostRefusal(cfg) {
  let host = '';
  try { host = new URL(cfg.url).hostname; } catch { return 'WATCH_SOS_PROBE_URL is not a URL'; }
  try { if (cfg.api && new URL(cfg.api).hostname !== host) return 'WATCH_SOS_PROBE_API must be on the same host as WATCH_SOS_PROBE_URL'; } catch { return 'WATCH_SOS_PROBE_API is not a URL'; }
  if (cfg.allowHost && host === cfg.allowHost) return '';
  if (!/staging/i.test(host)) return `refused: ${host} is not a staging host (the probe never runs against production)`;
  return '';
}

/** The probe-group guard on a SNAPSHOT. '' when fine. */
function groupRefusal(convoy, ids) {
  if (!convoy || typeof convoy !== 'object') return 'no snapshot';
  const name = String(convoy.name || convoy.convoyName || '');
  if (!name.startsWith(PROBE_GROUP_PREFIX)) return `refused: group "${name.slice(0, 40)}" is not a probe group (name must start with "${PROBE_GROUP_PREFIX}")`;
  const riders = Object.keys(convoy.riders || {});
  const extra = riders.filter((r) => !ids.includes(r));
  if (extra.length) return `refused: the probe group has ${extra.length} rider(s) besides the two probe accounts`;
  return '';
}

/**
 * One real probe run over the network (WebSocket from the gateway's own `ws` dependency). Resolves
 * { ok, ms, detail } and never rejects.
 */
async function runProbeOnce(cfg, { WebSocket = require('ws'), fetchImpl = fetch, now = Date.now } = {}) {
  const refusal = hostRefusal(cfg);
  if (refusal) return { ok: false, ms: null, detail: refusal, refused: true };
  if (!cfg.api || !cfg.group || !cfg.emailA || !cfg.emailB || !cfg.password) return { ok: false, ms: null, detail: 'probe settings incomplete', refused: true };
  const socks = [];
  const deadline = now() + cfg.timeoutMs;
  const left = () => Math.max(1, deadline - now());
  try {
    const login = async (email) => {
      const r = await fetchImpl(`${cfg.api}/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'User-Agent': 'coroute-watchdog' }, body: JSON.stringify({ identifier: email, password: cfg.password, device: probeDevice(email) }) });
      const j = await r.json().catch(() => ({}));
      if (r.status !== 200 || !j.token) throw new Error(`sign-in of a probe account failed (HTTP ${r.status})`);
      return { token: j.token, userId: j.user && j.user.userId };
    };
    const [a, b] = await Promise.all([login(cfg.emailA), login(cfg.emailB)]);
    const open = (acct) => new Promise((resolve, reject) => {
      const ws = new WebSocket(cfg.url, ['coroute.v1'], { handshakeTimeout: left() });
      socks.push(ws);
      ws.inbox = []; ws.waiters = [];
      ws.next = (pred) => new Promise((res, rej) => {
        const i = ws.inbox.findIndex(pred);
        if (i >= 0) return res(ws.inbox.splice(i, 1)[0]);
        const tm = setTimeout(() => rej(new Error('timeout')), left());
        ws.waiters.push({ pred, res: (m) => { clearTimeout(tm); res(m); } });
      });
      ws.on('message', (d, bin) => {
        if (bin) return;
        let m; try { m = JSON.parse(d.toString()); } catch { return; }
        m.recvAt = now();
        const w = ws.waiters.findIndex((x) => x.pred(m));
        if (w >= 0) ws.waiters.splice(w, 1)[0].res(m); else if (ws.inbox.length < 200) ws.inbox.push(m);
      });
      ws.on('open', () => { ws.send(JSON.stringify({ type: 'AUTH', token: acct.token })); resolve(ws); });
      ws.on('error', reject);
    });
    const [wa, wb] = await Promise.all([open(a), open(b)]);
    await Promise.all([wa.next((m) => m.type === 'HELLO'), wb.next((m) => m.type === 'HELLO')]);
    for (const w of [wa, wb]) w.send(JSON.stringify({ type: 'JOIN', groupId: cfg.group, caps: ['net1', 'posbatch1'] }));
    const [sa, sb] = await Promise.all([wa.next((m) => m.type === 'SNAPSHOT' || m.type === 'ERROR'), wb.next((m) => m.type === 'SNAPSHOT' || m.type === 'ERROR')]);
    if (sa.type === 'ERROR' || sb.type === 'ERROR') return { ok: false, ms: null, detail: `JOIN refused: ${(sa.type === 'ERROR' ? sa : sb).message || ''}` };
    const g = groupRefusal(sb.convoy, [a.userId, b.userId]);
    if (g) return { ok: false, ms: null, detail: g, refused: true };
    const clientId = `probe-${now()}`;
    const t0 = now();
    wa.send(JSON.stringify({ type: 'SOS', clientId, lat: 17.385, lng: 78.4867, alertType: 'SOS', source: 'MANUAL', clientSentSms: true, probe: true }));
    const got = await wb.next((m) => m.type === 'ALERT' && m.alert && (m.alert.clientId === clientId || (m.alert.userId === a.userId && Number(m.alert.timestamp) >= t0 - 1000)));
    const ms = got.recvAt - t0;
    wa.send(JSON.stringify({ type: 'SOS_RESOLVE', alertId: got.alert.alertId, reason: 'FALSE_ALARM' }));
    await wa.next((m) => m.type === 'ALERT_RESOLVED' && m.alertId === got.alert.alertId).catch(() => {});
    return { ok: ms <= cfg.maxMs, ms, detail: ms <= cfg.maxMs ? `delivered in ${ms} ms` : `slow: ${ms} ms (limit ${cfg.maxMs} ms)` };
  } catch (e) {
    return { ok: false, ms: null, detail: String(e && e.message || e).slice(0, 200) };
  } finally {
    for (const w of socks) { try { w.close(); } catch { /* gone */ } }
  }
}

/** Scheduling, alerting and the summary (pure; the runner is injected, the clock too). */
class SosProbe {
  constructor({ env = process.env, clock = Date.now, runner = null, log = console } = {}) {
    this.cfg = probeConfig(env); this.clock = clock; this.log = log;
    this.runner = runner || (() => runProbeOnce(this.cfg));
    this.state = { lastRunAt: 0, bad: 0, alerted: false, runs: 0, fails: 0, ms: [], last: null };
  }
  due(now = this.clock()) { return this.cfg.enabled && now - this.state.lastRunAt >= this.cfg.everyMs; }

  /** Runs when due. Returns { result, mail: {subject, text} | null } or null when not due. */
  async tick(now = this.clock()) {
    if (!this.due(now)) return null;
    this.state.lastRunAt = now;
    const result = await this.runner().catch((e) => ({ ok: false, ms: null, detail: e.message }));
    const s = this.state;
    s.runs++; s.last = { ...result, at: now };
    if (Number.isFinite(result.ms)) { s.ms.push(result.ms); if (s.ms.length > 200) s.ms.shift(); }
    let mail = null;
    if (!result.ok) {
      s.fails++; s.bad++;
      // First bad run, then once an hour (every 4th run at 15 min) while it stays bad.
      if (s.bad === 1 || s.bad % Math.max(1, Math.round(3600000 / this.cfg.everyMs)) === 0) {
        s.alerted = true;
        mail = { subject: `[CoRoute] SOS PROBE ${result.ms === null ? 'FAILED' : 'SLOW'} on staging`,
          text: `Synthetic SOS on staging: ${result.detail}\nLimit: ${this.cfg.maxMs} ms server to phone. Bad runs in a row: ${s.bad}.\n\nRunbook: gateway/deploy/RUNBOOK.md, "SOS probe". Check /metrics on the staging gateway (event loop lag, ws counters) and the live nodes.\n` };
      }
    } else {
      if (s.alerted) mail = { subject: '[CoRoute] SOS probe RECOVERED', text: `Synthetic SOS on staging ${result.detail} after ${s.bad} bad run(s).\n` };
      s.bad = 0; s.alerted = false;
    }
    this._writeStatus(now);
    return { result, mail };
  }

  _writeStatus(now) {
    const f = this.cfg.statusFile;
    if (!f) return;
    try {
      fs.mkdirSync(path.dirname(f), { recursive: true });
      fs.writeFileSync(f, JSON.stringify({ kind: 'sos_probe', at: now, ...this.summaryNumbers(), last: this.state.last }));
    } catch (e) { this.log.warn?.(`SOS probe status write failed: ${e.message}`); }
  }

  summaryNumbers() {
    const sorted = this.state.ms.slice().sort((x, y) => x - y);
    return { runs: this.state.runs, fails: this.state.fails, p50Ms: pct(sorted, 50), p95Ms: pct(sorted, 95), maxMs: sorted.length ? sorted[sorted.length - 1] : null };
  }

  /** One line for the daily summary; resets the day's counters. */
  summaryLine() {
    if (!this.cfg.enabled) return 'SOS probe: off (WATCH_SOS_PROBE=1 to enable, staging only)';
    const n = this.summaryNumbers();
    const last = this.state.last ? `${this.state.last.ok ? 'ok' : 'BAD'} (${this.state.last.detail})` : 'no run yet';
    const line = `SOS probe: ${n.runs} runs, ${n.fails} failed or slower than ${this.cfg.maxMs} ms; p50 ${n.p50Ms ?? '-'} ms, p95 ${n.p95Ms ?? '-'} ms, max ${n.maxMs ?? '-'} ms; last ${last}`;
    this.state.runs = 0; this.state.fails = 0; this.state.ms = [];
    return line;
  }
}

module.exports = { SosProbe, runProbeOnce, probeConfig, hostRefusal, groupRefusal, probeDevice, PROBE_GROUP_PREFIX };
