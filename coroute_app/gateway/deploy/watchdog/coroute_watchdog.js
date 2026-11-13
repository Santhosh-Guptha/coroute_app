#!/usr/bin/env node
'use strict';
/**
 * CoRoute uptime watchdog (v3.56), meant for vm3 (other tenancy, so it still sees a tenancy-1 outage).
 * No dependencies beyond Node (nodemailer from the standby gateway install is used for e-mail when present).
 *
 * Every WATCH_INTERVAL_S (30) seconds each target is checked:
 *   http   GET <url>, expects 2xx (and JSON "status":"HEALTHY" for /api/health) within 8 s
 *   ws     WebSocket upgrade on <url>, expects "101 Switching Protocols" (no token needed: the socket is closed at once)
 * A target that fails WATCH_FAILS (3) checks in a row raises ONE alert e-mail; its first good check after that sends a
 * recovery e-mail. A daily summary goes out at WATCH_SUMMARY_HOUR_UTC (03 UTC = 08:30 IST) with uptime per target,
 * the last backup result (/var/lib/coroute-backup/last.json) and the last restore drill.
 *
 * Optional automatic DR promotion (OFF by default): WATCH_AUTO_PROMOTE=1 runs WATCH_PROMOTE_CMD once when every
 * target in WATCH_PROMOTE_WHEN (default: public,vm1,vm2) has been down for WATCH_PROMOTE_AFTER_MIN (15) minutes.
 * The owner decides; the default is a mail asking a human to run deploy/dr/promote_vm3.sh.
 *
 * Config: /etc/coroute/watchdog.env (see watchdog.example.env); SMTP_* / MAIL_FROM / ALERT_TO as in gateway.env.
 * Targets: WATCH_TARGETS="name|kind|url[|servername]" separated by spaces, e.g.
 *   public|http|https://coroute.devmonks.space/api/health  public-ws|ws|wss://coroute.devmonks.space/ws
 *   vm1|http|https://<vm1-public-ip>/api/health/live|coroute.duckdns.org
 * (the 4th field is the TLS name to check when the URL uses an IP address).
 *
 * Round 8: the synthetic SOS probe on STAGING (deploy/watchdog/sos_probe.js, WATCH_SOS_PROBE=1): every 15 min a test
 * SOS between two dedicated staging accounts; mail when delivery > 1 s or failed; result in the daily summary.
 */
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

function loadEnvFile(file, env = process.env) {
  if (!file || !fs.existsSync(file)) return env;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = /^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*)\s*$/.exec(line);
    if (!m || line.trim().startsWith('#')) continue;
    let v = m[2];
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (env[m[1]] === undefined) env[m[1]] = v;
  }
  return env;
}

function parseTargets(spec) {
  return String(spec || '').split(/\s+/).filter(Boolean).map((t) => {
    const [name, kind, url, servername] = t.split('|');
    if (!name || !['http', 'ws'].includes(kind) || !/^(https?|wss?):\/\//.test(url || '')) throw new Error(`bad WATCH_TARGETS entry: ${t}`);
    return { name, kind, url, servername: servername || null };
  });
}

/** One check. Resolves { ok, ms, detail } and never rejects. */
function check(target, { timeoutMs = 8000 } = {}) {
  const t0 = Date.now();
  return new Promise((resolve) => {
    let done = false;
    const finish = (ok, detail) => { if (!done) { done = true; resolve({ ok, ms: Date.now() - t0, detail: String(detail).slice(0, 200) }); } };
    let u;
    try { u = new URL(target.url.replace(/^ws/, 'http')); } catch (e) { return finish(false, e.message); }
    const mod = u.protocol === 'https:' ? https : http;
    const headers = { 'User-Agent': 'coroute-watchdog', ...(target.servername ? { Host: target.servername } : {}) };
    if (target.kind === 'ws') Object.assign(headers, { Connection: 'Upgrade', Upgrade: 'websocket', 'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': crypto.randomBytes(16).toString('base64'), 'Sec-WebSocket-Protocol': 'coroute.v1' });
    const req = mod.request({ hostname: u.hostname, port: u.port || (u.protocol === 'https:' ? 443 : 80), path: u.pathname + u.search, method: 'GET', headers,
      ...(target.servername ? { servername: target.servername } : {}), timeout: timeoutMs, agent: false });
    req.on('upgrade', (res, socket) => { socket.destroy(); finish(res.statusCode === 101, `upgrade ${res.statusCode}`); });
    req.on('response', (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d) => { if (body.length < 4096) body += d; });
      res.on('end', () => {
        if (target.kind === 'ws') return finish(false, `no upgrade (HTTP ${res.statusCode})`);
        if (res.statusCode < 200 || res.statusCode >= 300) return finish(false, `HTTP ${res.statusCode} ${body.slice(0, 80)}`);
        if (/\/api\/health$/.test(u.pathname) && !/"status"\s*:\s*"HEALTHY"/.test(body)) return finish(false, `not HEALTHY: ${body.slice(0, 80)}`);
        finish(true, `HTTP ${res.statusCode}`);
      });
    });
    req.on('timeout', () => { req.destroy(new Error(`timeout ${timeoutMs} ms`)); });
    req.on('error', (e) => finish(false, e.message));
    req.end();
  });
}

class Watchdog {
  constructor({ targets, env = process.env, mailer = null, clock = Date.now, stateFile = null, log = console, runPromote = null, probe = null }) {
    this.targets = targets; this.env = env; this.clock = clock; this.log = log; this.stateFile = stateFile;
    /** Round 8 SOS probe (sos_probe.js SosProbe) or null. */
    this.probe = probe;
    this.failsToAlert = Math.max(1, Number(env.WATCH_FAILS || 3));
    this.mailer = mailer; this.runPromote = runPromote;
    this.state = this._load() || { targets: {}, day: null, promoted: false };
    for (const t of targets) this.state.targets[t.name] = this.state.targets[t.name] || { fails: 0, down: false, downSince: 0, checks: 0, okChecks: 0, lastDetail: '' };
  }
  _load() { try { return this.stateFile ? JSON.parse(fs.readFileSync(this.stateFile, 'utf8')) : null; } catch { return null; } }
  _save() { if (!this.stateFile) return; try { fs.mkdirSync(path.dirname(this.stateFile), { recursive: true }); fs.writeFileSync(this.stateFile, JSON.stringify(this.state)); } catch (e) { this.log.warn?.(`state save failed: ${e.message}`); } }

  async mail(subject, text) {
    if (!this.mailer) { this.log.info?.(`[mail skipped] ${subject}`); return false; }
    try { await this.mailer(subject, text); return true; } catch (e) { this.log.warn?.(`mail failed: ${e.message}`); return false; }
  }

  /** One round over every target. Returns the list of events (ALERT / RECOVERED / PROMOTE). */
  async round(checker = check) {
    const events = [];
    const results = await Promise.all(this.targets.map((t) => checker(t)));
    const now = this.clock();
    this.targets.forEach((t, i) => {
      const r = results[i]; const s = this.state.targets[t.name];
      s.checks++; s.lastDetail = r.detail; s.lastMs = r.ms;
      if (r.ok) {
        s.okChecks++;
        if (s.down) events.push({ type: 'RECOVERED', target: t.name, downMin: Math.round((now - s.downSince) / 60000), detail: r.detail });
        s.fails = 0; s.down = false; s.downSince = 0;
      } else {
        s.fails++;
        if (s.fails === 1) s.firstFailAt = now;
        if (!s.down && s.fails >= this.failsToAlert) { s.down = true; s.downSince = s.firstFailAt || now; events.push({ type: 'ALERT', target: t.name, fails: s.fails, detail: r.detail }); }
      }
    });
    for (const e of events) {
      if (e.type === 'ALERT') await this.mail(`[CoRoute] DOWN: ${e.target}`, `${e.target} failed ${e.fails} checks in a row.\nLast error: ${e.detail}\n\nRunbook: gateway/deploy/RUNBOOK.md, "DR and failover". Promotion of vm3 is manual unless WATCH_AUTO_PROMOTE=1.\n`);
      if (e.type === 'RECOVERED') await this.mail(`[CoRoute] RECOVERED: ${e.target}`, `${e.target} is answering again after about ${e.downMin} min.\n${e.detail}\n`);
    }
    await this._maybePromote(now, events);
    await this._maybeProbe(now, events);
    await this._maybeSummary(now);
    this._save();
    return events;
  }

  async _maybePromote(now, events) {
    const env = this.env;
    if (env.WATCH_AUTO_PROMOTE !== '1' || this.state.promoted || !this.runPromote) return;
    const need = String(env.WATCH_PROMOTE_WHEN || 'public,vm1,vm2').split(',').map((x) => x.trim()).filter(Boolean);
    const afterMs = Math.max(5, Number(env.WATCH_PROMOTE_AFTER_MIN || 15)) * 60000;
    const all = need.length && need.every((n) => { const s = this.state.targets[n]; return s && s.down && now - s.downSince >= afterMs; });
    if (!all) return;
    this.state.promoted = true;
    events.push({ type: 'PROMOTE' });
    const out = await this.runPromote().catch((e) => `failed: ${e.message}`);
    await this.mail('[CoRoute] DR: vm3 promoted automatically', `Every one of ${need.join(', ')} was down for ${Math.round(afterMs / 60000)} min. Ran the promote command.\n${out}\n`);
  }

  /** Round 8: the staging SOS probe when it is due (its own 15 min schedule, independent of the 30 s checks). */
  async _maybeProbe(now, events) {
    if (!this.probe) return;
    const r = await this.probe.tick(now).catch((e) => ({ result: { ok: false, detail: e.message }, mail: null }));
    if (!r) return;
    events.push({ type: 'SOS_PROBE', ok: r.result.ok, ms: r.result.ms ?? null, detail: r.result.detail });
    if (r.mail) await this.mail(r.mail.subject, r.mail.text);
  }

  async _maybeSummary(now) {
    const hour = Number(this.env.WATCH_SUMMARY_HOUR_UTC ?? 3);
    const d = new Date(now);
    const day = d.toISOString().slice(0, 10);
    if (d.getUTCHours() !== hour || this.state.day === day) return;
    this.state.day = day;
    const lines = Object.entries(this.state.targets).map(([n, s]) => `${n.padEnd(12)} ${s.checks ? ((100 * s.okChecks) / s.checks).toFixed(2) : '-'}% up (${s.okChecks}/${s.checks} checks)${s.down ? '  DOWN NOW' : ''}  last ${s.lastMs ?? '-'} ms`);
    const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return null; } };
    const backup = readJson(this.env.WATCH_BACKUP_STATUS || '/var/lib/coroute-backup/last.json');
    const drillR = readJson(this.env.WATCH_DRILL_STATUS || '/var/lib/coroute-backup/last-drill.json');
    if (this.probe) lines.push('', this.probe.summaryLine());
    const text = `${lines.join('\n')}\n\nLast backup: ${backup ? JSON.stringify(backup) : 'no status file'}\nLast restore drill: ${drillR ? JSON.stringify(drillR) : 'no status file'}\n`;
    await this.mail(`[CoRoute] daily summary ${day}`, text);
    for (const s of Object.values(this.state.targets)) { s.checks = 0; s.okChecks = 0; }
  }
}

function smtpMailer(env) {
  if (!env.SMTP_HOST || !env.ALERT_TO) return null;
  let nodemailer;
  for (const p of [env.WATCH_NODEMAILER, '/opt/coroute/gateway/node_modules/nodemailer', 'nodemailer'].filter(Boolean)) {
    try { nodemailer = require(p); break; } catch { /* next */ }
  }
  if (!nodemailer) return null;
  const port = Number(env.SMTP_PORT || 587);
  const t = nodemailer.createTransport({ host: env.SMTP_HOST, port, secure: port === 465, auth: env.SMTP_USER ? { user: env.SMTP_USER, pass: env.SMTP_PASS || env.SMTP_PASSWORD } : undefined });
  return (subject, text) => t.sendMail({ from: env.MAIL_FROM || env.SMTP_USER, to: env.ALERT_TO, subject, text: `${text}\n-- coroute-watchdog on ${require('os').hostname()}` });
}

async function main() {
  const env = loadEnvFile(process.env.WATCH_ENV_FILE || '/etc/coroute/watchdog.env');
  loadEnvFile(env.WATCH_SMTP_ENV_FILE || '/run/coroute/secrets.env', env); // SMTP password from the standby's secrets
  const targets = parseTargets(env.WATCH_TARGETS);
  if (!targets.length) throw new Error('WATCH_TARGETS is empty (see watchdog.example.env)');
  const runPromote = env.WATCH_PROMOTE_CMD ? () => new Promise((resolve, reject) => {
    execFile('/bin/sh', ['-c', env.WATCH_PROMOTE_CMD], { timeout: 600000 }, (e, so, se) => (e ? reject(new Error(`${e.message} ${se}`)) : resolve(String(so).slice(-2000))));
  }) : null;
  const { SosProbe } = require('./sos_probe');
  const probe = env.WATCH_SOS_PROBE === '1' ? new SosProbe({ env }) : null;
  const wd = new Watchdog({ targets, env, mailer: smtpMailer(env), stateFile: env.WATCH_STATE_FILE || '/var/lib/coroute-watchdog/state.json', runPromote, probe,
    log: { info: (m) => console.log(new Date().toISOString(), m), warn: (m) => console.warn(new Date().toISOString(), m) } });
  const every = Math.max(10, Number(env.WATCH_INTERVAL_S || 30)) * 1000;
  console.log(`${new Date().toISOString()} watchdog: ${targets.map((t) => t.name).join(', ')} every ${every / 1000}s; mail ${wd.mailer ? 'on' : 'OFF (set SMTP_HOST, ALERT_TO)'}; auto-promote ${env.WATCH_AUTO_PROMOTE === '1' ? 'ON' : 'off'}`);
  const tick = async () => {
    const ev = await wd.round().catch((e) => { console.warn('round failed', e.message); return []; });
    for (const e of ev) console.log(new Date().toISOString(), JSON.stringify(e));
  };
  await tick();
  setInterval(tick, every);
}

module.exports = { Watchdog, check, parseTargets, loadEnvFile };

if (require.main === module) main().catch((e) => { console.error(e.message); process.exit(1); });
