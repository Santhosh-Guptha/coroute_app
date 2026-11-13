#!/usr/bin/env node
'use strict';
/**
 * WebSocket load test: N riders in M convoys send positions at --hz, plus random SOS presses.
 * Measures position fan-out latency (sender -> every peer, p50/p95/p99), SOS delivery latency (sender ->
 * every other member of the group), gateway CPU / memory / event-loop lag (local mode) and DB calls.
 *
 * LOCAL (default): forks an in-memory gateway (MemorySoda, NODE_ENV=test) and seeds the riders inside it.
 *   node tool/load/ws_load.js --riders 2000 --group-size 8 --hz 1 --seconds 60
 *   WS_POS_MIN_MS=0 node tool/load/ws_load.js ...        (any gateway env var is passed to the forked gateway)
 * STAGING (never production): seed accounts on vm4 first (tool/load/seed_staging.js), copy tokens.json, then
 *   node tool/load/ws_load.js --target wss://staging.coroute.devmonks.space/ws --tokens tokens.json --seconds 60
 *
 * Options: --riders N (local) --group-size G (local) --hz F (positions per rider per second; the app sends 0.4)
 *   --seconds S --sos-per-min K (whole fleet, default 6) --ramp R (sockets opened per second, default 250)
 *   --binary (24-byte binary telemetry frames instead of JSON) --caps a,b (JOIN caps; default net1,pubride1,posbatch1)
 *   --json (print only the JSON summary) --label text --out file.jsonl
 *   --via ws://127.0.0.1:8080/ws (local mode: connect through a local Caddy; --port-file f writes the gateway port
 *   first and --wait-via S waits S seconds for you to start Caddy against it)
 * Only MIT/Apache dependencies: `ws` (MIT, already a gateway dependency).
 */
const { fork } = require('child_process');
const path = require('path');
const fs = require('fs');

const argv = process.argv.slice(2);
const has = (k) => argv.includes(`--${k}`);
const arg = (k, d) => { const i = argv.indexOf(`--${k}`); return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d; };
const num = (k, d) => { const v = Number(arg(k, d)); return Number.isFinite(v) ? v : d; };

// ------------------------------------------------------------------ forked in-memory gateway (local mode)
if (has('server')) {
  process.env.NODE_ENV = 'test';
  process.env.TIMELINE_TICK_MS = process.env.TIMELINE_TICK_MS || '3600000';
  const { performance, monitorEventLoopDelay } = require('perf_hooks');
  (async () => {
    const { createApp } = require('../../src/app');
    const { MemorySoda } = require('../../src/oracle/memory_soda');
    const { countingSoda } = require('./_db_counter');
    const quiet = { info() {}, warn() {}, error() {} };
    const counted = countingSoda(new MemorySoda());
    const gw = await createApp({ soda: counted.soda, logger: quiet, emergencyFetch: async () => { throw new Error('offline'); } });
    await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
    const h = monitorEventLoopDelay({ resolution: 1 }); h.enable();
    let mark = { cpu: process.cpuUsage(), at: process.hrtime.bigint(), elu: performance.eventLoopUtilization(), stats: { ...gw.hub.stats } };
    const mem = () => { const m = process.memoryUsage(); return { rssMb: m.rss / 1048576, heapUsedMb: m.heapUsed / 1048576, externalMb: (m.external + m.arrayBuffers) / 1048576 }; };
    process.send({ port: gw.server.address().port });
    process.on('message', async (m) => {
      try {
        if (m.cmd === 'seed') {
          const { seedRiders } = require('./_seed');
          const out = await seedRiders(gw, { riders: m.riders, groupSize: m.groupSize });
          if (global.gc) global.gc();
          return process.send({ seeded: out, mem: mem() });
        }
        if (m.cmd === 'mem') { if (global.gc) global.gc(); return process.send({ mem: mem(), sockets: gw.hub.wss.clients.size }); }
        if (m.cmd === 'mark') {
          h.reset(); counted.reset();
          mark = { cpu: process.cpuUsage(), at: process.hrtime.bigint(), elu: performance.eventLoopUtilization(), stats: { ...gw.hub.stats } };
          return process.send({ marked: true });
        }
        if (m.cmd === 'stats') {
          const cpu = process.cpuUsage(mark.cpu);
          const wallUs = Number(process.hrtime.bigint() - mark.at) / 1000;
          const elu = performance.eventLoopUtilization(mark.elu);
          const s = gw.hub.stats; const b = mark.stats;
          const d = {}; for (const k of Object.keys(s)) d[k] = s[k] - (b[k] || 0);
          return process.send({ stats: {
            cpuPct: (100 * (cpu.user + cpu.system)) / wallUs, wallS: wallUs / 1e6, elu: elu.utilization,
            lagMs: { p50: h.percentile(50) / 1e6, p99: h.percentile(99) / 1e6, max: h.max / 1e6 },
            hub: d, mem: mem(), db: counted.top(12), dbTotal: counted.total(), gateReads: gw.gate.reads,
          } });
        }
        if (m.cmd === 'exit') { await gw.shutdown().catch(() => {}); process.exit(0); }
      } catch (e) { process.send({ error: e.message }); }
    });
  })().catch((e) => { console.error(e); process.exit(1); });
  return;
}

// ------------------------------------------------------------------ driver
const WebSocket = require('ws');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const quietOut = has('json');
const say = (...a) => { if (!quietOut) console.log(...a); };

const HZ = num('hz', 1), SECONDS = num('seconds', 30), SOS_PER_MIN = num('sos-per-min', 6), RAMP = Math.max(1, num('ramp', 250));
const CAPS = String(arg('caps', 'net1,pubride1,posbatch1')).split(',').filter(Boolean);
const BINARY = has('binary');

function pct(arr, p) { if (!arr.length) return null; const i = Math.min(arr.length - 1, Math.floor((p / 100) * arr.length)); return arr[i]; }
function summary(arr) { const a = arr.slice().sort((x, y) => x - y); return { n: a.length, p50: pct(a, 50), p95: pct(a, 95), p99: pct(a, 99), max: a.length ? a[a.length - 1] : null }; }

function encodeBinaryTelemetry(lat, lng, seq) {
  const b = Buffer.alloc(24);
  b[0] = 0x10; b.writeUInt32BE(0, 1); b.writeInt32BE(Math.round(lat * 1e6), 5); b.writeInt32BE(Math.round(lng * 1e6), 9);
  b.writeUInt16BE(500, 13); b.writeUInt16BE(900, 15); b.writeUInt8(70, 17); b.writeUInt8(0, 18); b.writeUInt8(0, 19); b.writeUInt32BE(seq >>> 0, 20);
  return b;
}

(async () => {
  const target = arg('target', '');
  let srv = null; let ask = null; let wsUrl; let riders; let local = !target;
  if (local) {
    const RIDERS = num('riders', 200); const GROUP = Math.max(2, Math.min(num('group-size', 8), RIDERS));
    const env = { ...process.env, MAX_CONVOY_RIDERS: String(Math.max(GROUP, 50)) };
    srv = fork(__filename, ['--server'], { env, execArgv: ['--expose-gc', ...(process.env.LOAD_NODE_FLAGS ? process.env.LOAD_NODE_FLAGS.split(' ') : [])] });
    ask = (m, key) => new Promise((resolve, reject) => {
      const f = (x) => { if (x.error) { srv.off('message', f); reject(new Error(x.error)); } else if (key in x) { srv.off('message', f); resolve(x); } };
      srv.on('message', f); srv.send(m);
    });
    const { port } = await new Promise((r) => srv.once('message', r));
    // --via ws://127.0.0.1:8080/ws: seed the local gateway but connect through a local Caddy in front of it.
    wsUrl = arg('via', '') || `ws://127.0.0.1:${port}/ws`;
    if (has('print-port')) console.error(`gateway port ${port}`);
    if (arg('port-file', '')) fs.writeFileSync(arg('port-file', ''), String(port));
    if (num('wait-via', 0) > 0) await sleep(num('wait-via', 0) * 1000);
    const t0 = Date.now();
    const base = await ask({ cmd: 'mem' }, 'mem');
    const seeded = await ask({ cmd: 'seed', riders: RIDERS, groupSize: GROUP }, 'seeded');
    riders = seeded.seeded;
    riders.memSeeded = seeded.mem;
    say(`setup: ${RIDERS} riders in ${new Set(riders.map((r) => r.groupId)).size} groups of up to ${GROUP} seeded in ${Date.now() - t0} ms (gateway heap ${base.mem.heapUsedMb.toFixed(0)} -> ${seeded.mem.heapUsedMb.toFixed(0)} MB)`);
  } else {
    if (/coroute\.devmonks\.space\/|coroute\.duckdns\.org/.test(target) && !/staging/.test(target) && !has('i-know-this-is-production')) {
      console.error('Refusing to load-test production. Use the staging host (vm4).'); process.exit(2);
    }
    wsUrl = target;
    riders = JSON.parse(fs.readFileSync(arg('tokens', 'tokens.json'), 'utf8')).riders;
    say(`target ${target}: ${riders.length} riders from ${arg('tokens', 'tokens.json')}`);
  }
  const groups = new Map();
  riders.forEach((r, i) => { r.i = i; if (!groups.has(r.groupId)) groups.set(r.groupId, []); groups.get(r.groupId).push(r); });

  // Per sender: position key -> client send time (latest 16), to measure sender -> peer latency.
  const sentAt = riders.map(() => new Map());
  const posLat = []; const srvLat = []; const sosLat = [];
  let recvPos = 0, recvFrames = 0, batches = 0, errors = 0, closed = 0, bytesIn = 0;
  const sosPending = new Map(); // alert clientId -> { t, groupId, from, seen:Set }
  const keyOf = (lat, lng) => `${Number(lat).toFixed(5)},${Number(lng).toFixed(5)}`;
  const onRider = (rider, now) => {
    if (!rider || !rider.userId) return;
    recvPos++;
    const idx = riderIndex.get(rider.userId);
    if (idx !== undefined) { const t = sentAt[idx].get(keyOf(rider.lat, rider.lng)); if (t) posLat.push(now - t); }
    if (rider.lastSeenEpochMs && local) srvLat.push(now - rider.lastSeenEpochMs);
  };
  const riderIndex = new Map(riders.map((r, i) => [r.userId, i]));

  // ---- connect (ramped) and JOIN
  const tConn = Date.now();
  const socks = new Array(riders.length);
  let joined = 0;
  const connectOne = (r) => new Promise((resolve) => {
    const ws = new WebSocket(wsUrl, ['coroute.v1'], { perMessageDeflate: has('client-deflate') });
    ws.r = r; socks[r.i] = ws;
    let done = false; const finish = (ok) => { if (!done) { done = true; resolve(ok); } };
    ws.on('open', () => ws.send(JSON.stringify({ type: 'AUTH', token: r.token })));
    ws.on('message', (data, bin) => {
      const now = Date.now();
      bytesIn += data.length || 0;
      if (bin) return;
      recvFrames++;
      let m; try { m = JSON.parse(data.toString()); } catch { return; }
      switch (m.type) {
        case 'HELLO': ws.send(JSON.stringify({ type: 'JOIN', groupId: r.groupId, caps: CAPS })); break;
        case 'SNAPSHOT': joined++; finish(true); break;
        case 'RIDER_UPDATE': onRider(m.rider, now); break;
        case 'RIDER_UPDATES': batches++; for (const x of (m.riders || [])) onRider(x, now); break;
        case 'ALERT': {
          const a = m.alert || {};
          const p = sosPending.get(a.clientId || '') || [...sosPending.values()].find((x) => x.alertId === a.alertId);
          if (p && a.userId !== r.userId && !p.seen.has(r.userId)) { p.seen.add(r.userId); sosLat.push(now - p.t); }
          if (p && a.userId === r.userId && !p.alertId) p.alertId = a.alertId;
          break;
        }
        case 'ERROR': errors++; if (!done && m.code !== 429) finish(false); break;
        default:
      }
    });
    ws.on('error', () => finish(false));
    ws.on('close', () => { closed++; finish(false); });
  });
  const pending = [];
  for (let i = 0; i < riders.length; i++) {
    pending.push(connectOne(riders[i]));
    if ((i + 1) % RAMP === 0) await sleep(1000);
  }
  const okCount = (await Promise.all(pending)).filter(Boolean).length;
  const connectS = (Date.now() - tConn) / 1000;
  say(`sockets: ${okCount}/${riders.length} joined in ${connectS.toFixed(1)} s`);
  let memPerSocket = null;
  if (local) {
    await sleep(500);
    const m = (await ask({ cmd: 'mem' }, 'mem')).mem;
    const n = Math.max(1, okCount);
    memPerSocket = { heapKb: +((m.heapUsedMb - riders.memSeeded.heapUsedMb) * 1024 / n).toFixed(1),
      rssKb: +((m.rssMb - riders.memSeeded.rssMb) * 1024 / n).toFixed(1), heapUsedMbJoined: Math.round(m.heapUsedMb), rssMbJoined: Math.round(m.rssMb) };
  }

  // ---- steady state
  await sleep(500);
  if (local) await ask({ cmd: 'mark' }, 'marked');
  posLat.length = 0; srvLat.length = 0; recvPos = 0; recvFrames = 0; batches = 0; bytesIn = 0;
  const period = 1000 / HZ; let sentPos = 0; const seq = riders.map(() => 0);
  const ticks = [];
  for (const ws of socks) {
    if (!ws || ws.readyState !== WebSocket.OPEN) continue;
    const i = ws.r.i;
    const start = setTimeout(() => {
      ws.tick = setInterval(() => {
        if (ws.readyState !== WebSocket.OPEN) return;
        const s = ++seq[i];
        const lat = 12.9 + (i % 500) * 1e-3; const lng = 77.5 + ((s % 997) * 1e-5);
        const t = Date.now();
        const mp = sentAt[i]; mp.set(keyOf(lat, lng), t); if (mp.size > 16) mp.delete(mp.keys().next().value);
        if (BINARY) ws.send(encodeBinaryTelemetry(lat, lng, s));
        else ws.send(JSON.stringify({ type: 'TELEMETRY', lat, lng, speedKmh: 50, heading: 90, batteryLevel: 70 }));
        sentPos++;
      }, period);
    }, Math.random() * period);
    ticks.push(start);
  }
  // Random SOS presses from riders of groups with at least 2 live members; each resolved 3 s later.
  const sosTimer = SOS_PER_MIN > 0 ? setInterval(() => {
    const live = socks.filter((w) => w && w.readyState === WebSocket.OPEN && groups.get(w.r.groupId).length > 1 && !w.sosBusy);
    if (!live.length) return;
    const ws = live[Math.floor(Math.random() * live.length)];
    ws.sosBusy = true;
    const clientId = `load-sos-${ws.r.i}-${Date.now()}`;
    const p = { t: Date.now(), groupId: ws.r.groupId, from: ws.r.userId, seen: new Set(), alertId: null, clientId };
    sosPending.set(clientId, p);
    ws.send(JSON.stringify({ type: 'SOS', clientId, lat: 12.9, lng: 77.5, severity: 'HIGH', kind: 'SOS', message: 'load test' }));
    setTimeout(() => { if (p.alertId && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'SOS_RESOLVE', alertId: p.alertId, reason: 'FALSE_ALARM' })); }, 3000);
  }, 60000 / SOS_PER_MIN) : null;

  await sleep(SECONDS * 1000);
  for (const ws of socks) if (ws && ws.tick) clearInterval(ws.tick);
  ticks.forEach(clearTimeout);
  if (sosTimer) clearInterval(sosTimer);
  await sleep(2000);
  const st = local ? (await ask({ cmd: 'stats' }, 'stats')).stats : null;
  const sosExpected = [...sosPending.values()].reduce((n, p) => n + (groups.get(p.groupId).length - 1), 0);
  const result = {
    label: arg('label', ''), mode: local ? 'local' : 'remote', riders: riders.length, joined: okCount, groups: groups.size,
    groupSize: Math.round(riders.length / groups.size), hz: HZ, seconds: SECONDS, binary: BINARY, caps: CAPS,
    connectSeconds: +connectS.toFixed(1),
    positionsSentPerSec: Math.round(sentPos / SECONDS), positionsReceivedPerSec: Math.round(recvPos / SECONDS),
    framesReceivedPerSec: Math.round(recvFrames / SECONDS), batchFramesPerSec: Math.round(batches / SECONDS),
    kbInPerSec: Math.round(bytesIn / 1024 / SECONDS),
    fanoutLatencyMs: summary(posLat), serverToPeerMs: local ? summary(srvLat) : undefined,
    sos: { pressed: sosPending.size, deliveries: sosLat.length, expected: sosExpected, latencyMs: summary(sosLat) },
    errors, closedSockets: closed,
  };
  if (st) {
    result.gateway = {
      cpuPctOfOneCore: +st.cpuPct.toFixed(1), eventLoopUtilization: +st.elu.toFixed(3),
      eventLoopLagMs: { p50: +st.lagMs.p50.toFixed(1), p99: +st.lagMs.p99.toFixed(1), max: +st.lagMs.max.toFixed(1) },
      rssMb: Math.round(st.mem.rssMb), heapUsedMb: Math.round(st.mem.heapUsedMb), externalMb: Math.round(st.mem.externalMb),
      memPerSocket,
      hub: st.hub, dbCallsPerSec: +(st.dbTotal / st.wallS).toFixed(1), dbTop: st.db,
    };
  }
  if (quietOut) console.log(JSON.stringify(result));
  else console.log(JSON.stringify(result, null, 1));
  const out = arg('out', '');
  if (out) fs.appendFileSync(out, JSON.stringify(result) + '\n');
  for (const ws of socks) if (ws) try { ws.terminate(); } catch { /* gone */ }
  if (srv) { srv.send({ cmd: 'exit' }); await sleep(500); }
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
