'use strict';
/**
 * LOCAL load test for one large convoy (never point it at production):
 *   node scripts/load_convoy_ws.js [--riders 100] [--group-size 100] [--seconds 30] [--hz 1] [--no-coalesce]
 *   Realistic mix example: --riders 300 --group-size 6 --hz 0.67 (groups of 6, one update every 1.5 s)
 *
 * Forks an in-memory gateway (MemorySoda, NODE_ENV=test), registers N riders, puts them all in one
 * convoy over HTTP, opens N real WebSockets and sends TELEMETRY at --hz per rider. Reports gateway
 * CPU and memory, positions in/out per second, delivery latency (server receive -> peer receive),
 * coalesced/dropped counts, then an SOS storm (dedupe) and a PTT floor race (one talker).
 */
const { fork } = require('child_process');
const path = require('path');

const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? Number(process.argv[i + 1]) : d; };

if (process.argv.includes('--server')) {
  process.env.NODE_ENV = 'test';
  process.env.TIMELINE_TICK_MS = '3600000';
  (async () => {
    const { createApp } = require('../src/app');
    const { MemorySoda } = require('../src/oracle/memory_soda');
    const quiet = { info() {}, warn() {}, error() {} };
    const gw = await createApp({ soda: new MemorySoda(), logger: quiet, emergencyFetch: async () => { throw new Error('offline'); } });
    await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
    process.send({ port: gw.server.address().port });
    let last = { cpu: process.cpuUsage(), at: process.hrtime.bigint() };
    process.on('message', (m) => {
      if (m === 'mark') { last = { cpu: process.cpuUsage(), at: process.hrtime.bigint(), stats: { ...gw.hub.stats } }; return process.send({ marked: true }); }
      if (m === 'stats') {
        const cpu = process.cpuUsage(last.cpu);
        const wallUs = Number(process.hrtime.bigint() - last.at) / 1000;
        const s = gw.hub.stats, b = last.stats || {};
        const d = (k) => s[k] - (b[k] || 0);
        process.send({ cpuPct: (100 * (cpu.user + cpu.system)) / wallUs, rssMb: process.memoryUsage().rss / 1048576, wallS: wallUs / 1e6,
          posIn: d('posIn'), posOut: d('posOut'), posDropped: d('posDropped'), posCoalesced: d('posCoalesced'), slowKicked: d('slowKicked') });
      }
      if (m === 'exit') gw.shutdown().finally(() => process.exit(0));
    });
  })().catch((e) => { console.error(e); process.exit(1); });
  return;
}

const RIDERS = arg('riders', 100), SECONDS = arg('seconds', 30), HZ = arg('hz', 1);
const GROUP = Math.max(2, Math.min(arg('group-size', RIDERS), RIDERS));
const NGROUPS = Math.ceil(RIDERS / GROUP);
const groupIndex = (i) => Math.floor(i / GROUP);
const WebSocket = require('ws');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const env = { ...process.env, MAX_CONVOY_RIDERS: String(GROUP) };
  if (process.argv.includes('--no-coalesce')) env.WS_COALESCE_ABOVE = '100000';
  const srv = fork(path.join(__dirname, 'load_convoy_ws.js'), ['--server'], { env });
  const ask = (m, key) => new Promise((r) => { const f = (x) => { if (key in x) { srv.off('message', f); r(x); } }; srv.on('message', f); srv.send(m); });
  const { port } = await new Promise((r) => srv.once('message', r));
  const base = `http://127.0.0.1:${port}/api`;
  const api = async (method, p, body, token, ip) => {
    const res = await fetch(base + p, { method, headers: { 'Content-Type': 'application/json', 'X-Forwarded-For': ip || '10.0.0.1', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: res.status, json: await res.json().catch(() => ({})) };
  };
  const t0 = Date.now();
  const users = [];
  for (let i = 0; i < RIDERS; i++) {
    const r = await api('POST', '/auth/register', { name: `Load${i}`, email: `load${i}@load.test`, password: 'Password#123', phone: `+9190000${String(10000 + i).slice(-5)}`, vehicleType: 'Motorcycle', vehicleNo: `KA01LD${String(1000 + i).slice(-4)}`, emergencyContact: '+919000000001', emergencyContactName: 'ICE' }, null, `10.1.${i >> 8}.${i & 255}`);
    if (r.status !== 201) throw new Error(`register ${i}: ${r.status} ${JSON.stringify(r.json)}`);
    users.push(r.json);
  }
  const convoys = [];
  for (let g = 0; g < NGROUPS; g++) {
    const leader = g * GROUP;
    const cr = await api('POST', '/convoys', { name: `Load convoy ${g}` }, users[leader].token, `10.4.${g >> 8}.${g & 255}`);
    if (cr.status !== 200 && cr.status !== 201) throw new Error(`create ${g}: ${cr.status} ${JSON.stringify(cr.json)}`);
    convoys.push(cr.json);
  }
  const c = convoys[0];
  for (let i = 0; i < RIDERS; i++) {
    if (i % GROUP === 0) continue; // group leader created it
    const j = await api('POST', '/convoys/join', { code: convoys[groupIndex(i)].joinCode }, users[i].token, `10.2.${i >> 8}.${i & 255}`);
    if (j.status !== 200) throw new Error(`join ${i}: ${j.status} ${JSON.stringify(j.json)}`);
  }
  console.log(`setup: ${RIDERS} riders in ${NGROUPS} group(s) of up to ${GROUP}, registered and joined in ${Date.now() - t0} ms`);

  const lat = []; let recv = 0, alerts = 0, voiceStarts = 0, busy = 0;
  const socks = await Promise.all(users.map((u, ui) => new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${u.token}`);
    ws.on('message', (data, bin) => {
      if (bin) { if (data[0] === 0x01) voiceStarts++; return; }
      const m = JSON.parse(data.toString());
      if (m.type === 'RIDER_UPDATE' && m.rider && m.rider.lastSeenEpochMs) { recv++; lat.push(Date.now() - m.rider.lastSeenEpochMs); }
      else if (m.type === 'ALERT' && !m.duplicate) alerts++;
      else if (m.type === 'VOICE_BUSY') busy++;
      else if (m.type === 'SNAPSHOT') ws.joined();
    });
    ws.once('open', () => { ws.joined = resolve.bind(null, ws); ws.send(JSON.stringify({ type: 'JOIN', groupId: convoys[groupIndex(ui)].groupId })); });
    ws.once('error', reject);
  })));
  console.log(`sockets: ${socks.length} joined`);
  await sleep(500);
  lat.length = 0; recv = 0;
  await ask('mark', 'marked');
  const period = 1000 / HZ;
  const timers = socks.map((ws, i) => setTimeout(() => {
    ws.tick = setInterval(() => ws.send(JSON.stringify({ type: 'TELEMETRY', lat: 12.9 + i / 1e4 + Math.random() / 1e5, lng: 77.6 + Math.random() / 1e5, speedKmh: 50, heading: 90, batteryLevel: 70 })), period);
  }, Math.random() * period));
  await sleep(SECONDS * 1000);
  for (const ws of socks) clearInterval(ws.tick);
  timers.forEach(clearTimeout);
  await sleep(1500);
  const st = await ask('stats', 'cpuPct');
  lat.sort((a, b) => a - b);
  const pct = (p) => lat.length ? lat[Math.min(lat.length - 1, Math.floor((p / 100) * lat.length))] : NaN;
  console.log(JSON.stringify({
    riders: RIDERS, groups: NGROUPS, groupSize: GROUP, hz: HZ, seconds: SECONDS, coalescing: !process.argv.includes('--no-coalesce'),
    gatewayCpuPct: +st.cpuPct.toFixed(1), gatewayRssMb: +st.rssMb.toFixed(0),
    positionsInPerSec: +(st.posIn / SECONDS).toFixed(0), sendsOutPerSec: +(st.posOut / SECONDS).toFixed(0),
    receivedPerSec: +(recv / SECONDS).toFixed(0), coalesced: st.posCoalesced, droppedSlow: st.posDropped, slowKicked: st.slowKicked,
    latencyMs: { p50: pct(50), p95: pct(95), p99: pct(99), max: lat[lat.length - 1] },
  }, null, 1));

  // SOS storm: 20 riders press SOS 5 times each (new clientId every press) -> one ALERT per rider per peer.
  alerts = 0;
  const g0 = Math.min(GROUP, RIDERS), stormers = Math.min(20, g0);
  for (let i = 0; i < stormers; i++) for (let k = 0; k < 5; k++) socks[i].send(JSON.stringify({ type: 'SOS', lat: 12.9, lng: 77.6, clientId: `storm-${i}-${k}` }));
  await sleep(2500);
  console.log(`SOS storm (group 0): ${stormers * 5} presses by ${stormers} riders -> ${alerts / g0} distinct alerts seen per rider (storm guard: at most 2 per rider = ${stormers * 2})`);

  // PTT race: 5 riders start talking at once -> one talker, the rest VOICE_BUSY.
  const encodeVoice = (kind, header) => { const h = Buffer.from(JSON.stringify(header)); const b = Buffer.alloc(3 + h.length); b[0] = kind; b.writeUInt16BE(h.length, 1); h.copy(b, 3); return b; };
  voiceStarts = 0; busy = 0;
  for (const ws of socks.slice(0, g0).slice(-Math.min(5, g0 - 1))) ws.send(encodeVoice(0x01, { sampleRate: 16000 }));
  await sleep(800);
  console.log(`PTT race (group 0): ${Math.min(5, g0 - 1)} simultaneous talkers -> ${busy} VOICE_BUSY, START relayed to ${voiceStarts} peers (one stream = ${g0 - 1})`);

  // Member limit: one rider over the server cap is refused.
  const extra = await api('POST', '/auth/register', { name: 'LoadExtra', email: 'loadextra@load.test', password: 'Password#123', phone: '+919000099999', vehicleType: 'Motorcycle', vehicleNo: 'KA01LX9999', emergencyContact: '+919000000001', emergencyContactName: 'ICE' }, null, '10.3.0.1');
  const over = await api('POST', '/convoys/join', { code: c.joinCode }, extra.json.token, '10.3.0.1');
  console.log(`member limit: extra rider joining full group 0 (cap ${GROUP}) -> ${over.status} ${over.json.reason || over.json.code || ''}`);
  for (const ws of socks) ws.close();
  srv.send('exit');
  await sleep(300);
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
