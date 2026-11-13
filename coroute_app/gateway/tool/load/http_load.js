#!/usr/bin/env node
'use strict';
/**
 * HTTP load test with keep-alive connections (no dependencies; autocannon is not installed in the gateway and
 * this keeps the tool MIT-clean and offline). Reports requests/s, latency p50/p95/p99 and status codes per path.
 *
 * LOCAL (default): forks an in-memory gateway (MemorySoda) from --gateway-dir (default: this repo's gateway).
 *   node tool/load/http_load.js --connections 50 --seconds 15
 * STAGING (never production):
 *   node tool/load/http_load.js --target https://staging.coroute.devmonks.space --connections 20 --seconds 30
 *
 * Options: --paths "/api/health,/api/meta" (default: health, meta, public access, status, home page, a static
 *   asset, a shed-able public read) --connections C --seconds S --rps R (cap, total; 0 = as fast as possible)
 *   --header "If-None-Match: ..." --json --label text --out file.jsonl
 */
const http = require('http');
const https = require('https');
const path = require('path');
const fs = require('fs');
const { fork } = require('child_process');

const argv = process.argv.slice(2);
const has = (k) => argv.includes(`--${k}`);
const arg = (k, d) => { const i = argv.indexOf(`--${k}`); return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d; };
const num = (k, d) => { const v = Number(arg(k, d)); return Number.isFinite(v) ? v : d; };

if (has('server')) {
  process.env.NODE_ENV = 'test';
  process.env.TIMELINE_TICK_MS = '3600000';
  const dir = arg('gateway-dir', path.join(__dirname, '..', '..'));
  (async () => {
    const { createApp } = require(path.join(dir, 'src', 'app'));
    const { MemorySoda } = require(path.join(dir, 'src', 'oracle', 'memory_soda'));
    const quiet = { info() {}, warn() {}, error() {} };
    const gw = await createApp({ soda: new MemorySoda(), logger: quiet });
    await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
    let cpu0 = process.cpuUsage(); let t0 = process.hrtime.bigint();
    process.send({ port: gw.server.address().port });
    process.on('message', async (m) => {
      if (m === 'mark') { cpu0 = process.cpuUsage(); t0 = process.hrtime.bigint(); return process.send({ marked: true }); }
      if (m === 'stats') {
        const c = process.cpuUsage(cpu0); const wall = Number(process.hrtime.bigint() - t0) / 1000;
        return process.send({ cpuPct: (100 * (c.user + c.system)) / wall, rssMb: process.memoryUsage().rss / 1048576 });
      }
      if (m === 'exit') { await gw.shutdown().catch(() => {}); process.exit(0); }
    });
  })().catch((e) => { console.error(e); process.exit(1); });
  return;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function pct(a, p) { if (!a.length) return null; return a[Math.min(a.length - 1, Math.floor((p / 100) * a.length))]; }

(async () => {
  const target = arg('target', '');
  let srv = null; let ask = null; let base;
  if (!target) {
    srv = fork(__filename, ['--server', '--gateway-dir', arg('gateway-dir', path.join(__dirname, '..', '..'))], { env: { ...process.env } });
    ask = (m, k) => new Promise((r) => { const f = (x) => { if (k in x) { srv.off('message', f); r(x); } }; srv.on('message', f); srv.send(m); });
    const { port } = await new Promise((r) => srv.once('message', r));
    base = `http://127.0.0.1:${port}`;
  } else {
    if (/\/\/(coroute\.devmonks\.space|coroute\.duckdns\.org)/.test(target) && !has('i-know-this-is-production')) {
      console.error('Refusing to load-test production. Use the staging host (vm4).'); process.exit(2);
    }
    base = target.replace(/\/+$/, '');
  }
  const paths = String(arg('paths', '/api/health,/api/meta,/api/public/access,/status,/,/assets/site.css,/api/community-stats')).split(',').filter(Boolean);
  const C = Math.max(1, num('connections', 50)); const SECONDS = num('seconds', 15); const RPS = num('rps', 0);
  const extraHeaders = {};
  for (let i = 0; i < argv.length; i++) if (argv[i] === '--header') { const [k, ...v] = argv[i + 1].split(':'); extraHeaders[k.trim()] = v.join(':').trim(); }
  const u = new URL(base);
  const mod = u.protocol === 'https:' ? https : http;
  const agent = new mod.Agent({ keepAlive: true, maxSockets: C, keepAliveMsecs: 30000 });
  const per = new Map(paths.map((p) => [p, { lat: [], codes: {}, bytes: 0, errors: 0 }]));
  let stop = false; let sent = 0;
  const one = (p) => new Promise((resolve) => {
    const t0 = process.hrtime.bigint();
    const req = mod.request({ hostname: u.hostname, port: u.port || (u.protocol === 'https:' ? 443 : 80), path: p, method: 'GET', agent,
      headers: { 'Accept-Encoding': 'gzip', 'User-Agent': 'coroute-http-load', ...extraHeaders } }, (res) => {
      let n = 0;
      res.on('data', (d) => { n += d.length; });
      res.on('end', () => {
        const s = per.get(p); s.lat.push(Number(process.hrtime.bigint() - t0) / 1e6); s.codes[res.statusCode] = (s.codes[res.statusCode] || 0) + 1; s.bytes += n;
        resolve();
      });
    });
    req.on('error', () => { per.get(p).errors++; resolve(); });
    req.setTimeout(10000, () => req.destroy(new Error('timeout')));
    req.end();
  });
  // warm-up
  for (const p of paths) await one(p);
  for (const s of per.values()) { s.lat = []; s.codes = {}; s.bytes = 0; s.errors = 0; }
  if (ask) await ask('mark', 'marked');
  const t0 = Date.now();
  const worker = async (w) => {
    let i = w;
    while (!stop) {
      if (RPS > 0) { const due = t0 + (sent / RPS) * 1000; const wait = due - Date.now(); if (wait > 0) await sleep(wait); }
      sent++;
      await one(paths[i++ % paths.length]);
    }
  };
  const workers = Array.from({ length: C }, (_, w) => worker(w));
  await sleep(SECONDS * 1000);
  stop = true;
  await Promise.all(workers);
  const wall = (Date.now() - t0) / 1000;
  const st = ask ? await ask('stats', 'cpuPct') : null;
  const out = { label: arg('label', ''), target: target || 'local', connections: C, seconds: SECONDS, totalRps: 0, perPath: {} };
  for (const [p, s] of per) {
    const a = s.lat.sort((x, y) => x - y);
    out.totalRps += a.length / wall;
    out.perPath[p] = { rps: Math.round(a.length / wall), p50: +(pct(a, 50) || 0).toFixed(1), p95: +(pct(a, 95) || 0).toFixed(1), p99: +(pct(a, 99) || 0).toFixed(1), codes: s.codes, errors: s.errors, avgBytes: a.length ? Math.round(s.bytes / a.length) : 0 };
  }
  out.totalRps = Math.round(out.totalRps);
  if (st) out.gateway = { cpuPctOfOneCore: +st.cpuPct.toFixed(1), rssMb: Math.round(st.rssMb) };
  console.log(has('json') ? JSON.stringify(out) : JSON.stringify(out, null, 1));
  if (arg('out', '')) fs.appendFileSync(arg('out', ''), JSON.stringify(out) + '\n');
  agent.destroy();
  if (srv) { srv.send('exit'); await sleep(300); }
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
