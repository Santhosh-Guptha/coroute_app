'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.TIMELINE_TICK_MS = '3600000'; // ticks are driven by the test

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const gm = require('../src/geo_math');
const { validateChunk, analyseTrack, detectStops } = require('../src/tracks');
const { visibleWindow } = require('../src/timeline');

// ---------------------------------------------------------------- pure units
test('geo_math: distances, polyline round trip, simplify', () => {
  assert.ok(Math.abs(gm.haversine(17, 78, 18, 78) - 111195) < 5); // one degree of latitude
  const google = gm.decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
  assert.deepEqual(google, [{ lat: 38.5, lng: -120.2 }, { lat: 40.7, lng: -120.95 }, { lat: 43.252, lng: -126.453 }]);
  assert.equal(gm.encodePolyline(google), '_p~iF~ps|U_ulLnnqC_mqNvxq`@');
  assert.equal(gm.decodePolyline('@@@'), null);
  const line = [{ lat: 17, lng: 78 }, { lat: 17.1, lng: 78 }];
  const r = gm.distanceToPolyline({ lat: 17.05, lng: 78.001 }, line);
  assert.ok(Math.abs(r.dist - 106) < 3, `dist ${r.dist}`);
  assert.ok(Math.abs(r.along - 5560) < 10, `along ${r.along}`);
  const straight = Array.from({ length: 50 }, (_, i) => ({ lat: 17 + i * 0.001, lng: 78 + (i % 2) * 0.00001 }));
  assert.equal(gm.simplify(straight, 5).length, 2);
});

/** Builds a synthetic track: [{ minutes, kmh }] segments sampled every `stepS` seconds, heading north. */
function synth(plan, { stepS = 5, t0 = 1_800_000_000_000, jitterM = 4 } = {}) {
  const pts = [];
  let km = 0, t = t0, seed = 7;
  const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647 - 0.5; };
  for (const seg of plan) {
    const steps = Math.round((seg.minutes * 60) / stepS);
    for (let i = 0; i < steps; i++) {
      t += stepS * 1000;
      km += (seg.kmh * stepS) / 3600;
      const jit = seg.kmh === 0 ? jitterM : 0;
      pts.push({ ts: t, lat: 17 + km / 111.195 + (rnd() * jit) / 111195, lng: 78.4 + (rnd() * jit) / 106000, v: seg.kmh, acc: 6 });
    }
  }
  return pts;
}

test('stop detection: real stop counted once, slow traffic and short halts ignored', () => {
  const pts = synth([
    { minutes: 10, kmh: 60 },
    { minutes: 18, kmh: 0 },   // fuel stop
    { minutes: 10, kmh: 60 },
    { minutes: 5, kmh: 5 },    // crawling traffic
    { minutes: 1.5, kmh: 0 },  // signal
    { minutes: 10, kmh: 60 },
  ]);
  const stops = detectStops(pts, { minStopMs: 120000 });
  assert.equal(stops.length, 1, JSON.stringify(stops.map((s) => s.durationMs)));
  assert.ok(Math.abs(stops[0].durationMs - 18 * 60000) <= 10000, `stop ${stops[0].durationMs}`);
  const a = analyseTrack(pts, { minStopMs: 120000 });
  const expectedKm = 30 * 1 + 5 * (5 / 60); // 30 min at 60 km/h + 5 min at 5 km/h
  assert.ok(Math.abs(a.distanceM / 1000 - expectedKm) / expectedKm < 0.02, `distance ${a.distanceM}`);
  assert.ok(Math.abs(a.restMs - 18 * 60000) <= 10000);
  assert.ok(a.maxKmh >= 58 && a.maxKmh <= 62, `max ${a.maxKmh}`);
  assert.equal(a.segments.length, 2);
});

test('stop detection: GPS drift while parked stays one stop', () => {
  const pts = synth([{ minutes: 2, kmh: 40 }, { minutes: 30, kmh: 0 }, { minutes: 2, kmh: 40 }], { jitterM: 30 });
  const stops = detectStops(pts, { minStopMs: 120000 });
  assert.equal(stops.length, 1);
  assert.ok(stops[0].durationMs > 29 * 60000);
});

test('track chunk validation rejects bad input', () => {
  const now = 1_800_000_000_000;
  const enc = gm.encodePolyline([{ lat: 17, lng: 78 }, { lat: 17.001, lng: 78 }]);
  const ok = validateChunk({ seq: 1, startTs: now - 60000, enc, t: [0, 5000], v: [30, 31], acc: [5, 5] }, { nowMs: now, tripStartMs: now - 3600000 });
  assert.equal(ok.points.length, 2);
  assert.equal(ok.endTs, now - 55000);
  const bad = [
    { seq: 1, startTs: now + 600000, enc, t: [0, 5000], v: [1, 1], acc: [1, 1] },            // future
    { seq: 1, startTs: now - 60000, enc, t: [0], v: [1, 1], acc: [1, 1] },                   // arrays mismatch
    { seq: 1, startTs: now - 60000, enc, t: [5000, 0], v: [1, 1], acc: [1, 1] },             // time goes back
    { seq: 1, startTs: now - 60000, enc: '@@@', t: [0], v: [1], acc: [1] },                  // broken encoding
    { seq: -1, startTs: now - 60000, enc, t: [0, 5000], v: [1, 1], acc: [1, 1] },            // seq
    { seq: 1, startTs: now - 7200000 * 10, enc, t: [0, 5000], v: [1, 1], acc: [1, 1] },      // before the trip
  ];
  for (const b of bad) assert.throws(() => validateChunk(b, { nowMs: now, tripStartMs: now - 3600000 }));
  const many = Array.from({ length: 121 }, (_, i) => ({ lat: 17 + i * 0.0001, lng: 78 }));
  assert.throws(() => validateChunk({ seq: 2, startTs: now - 60000, enc: gm.encodePolyline(many), t: many.map((_, i) => i), v: many.map(() => 1), acc: many.map(() => 1) }, { nowMs: now }));
});

test('visibility window follows membership', () => {
  const meta = { members: { a: { joinedAt: 100, firstJoinedAt: 50 }, b: { joinedAt: 200, leftAt: 300 } } };
  assert.deepEqual(visibleWindow(meta, { userId: 'a' }), { from: 50, to: Number.MAX_SAFE_INTEGER });
  assert.deepEqual(visibleWindow(meta, { userId: 'b' }), { from: 200, to: 300 });
  assert.equal(visibleWindow(meta, { userId: 'x' }), null);
  assert.ok(visibleWindow(meta, { userId: 'x', role: 'MASTER_ADMIN' }));
});

// ------------------------------------------------------- full group simulation
let gw, base, wsBase;
const T0 = Date.now();
const MIN = 60000;

before(async () => {
  mock.timers.enable({ apis: ['Date'], now: T0 });
  const { createApp } = require('../src/app');
  const { MemorySoda } = require('../src/oracle/memory_soda');
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  base = `http://127.0.0.1:${port}/api`;
  wsBase = `ws://127.0.0.1:${port}/ws`;
});
after(async () => { await gw.shutdown(); mock.timers.reset(); });

async function api(method, path, body, token) {
  const res = await fetch(base + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = {};
  try { json = JSON.parse(text); } catch { json = { text }; }
  return { status: res.status, json, text };
}

async function register(name, email) {
  const r = await api('POST', '/auth/register', { name, email, password: 'Password#123', phone: '9999999999', vehicleType: 'Motorcycle' });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json;
}

function connect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}?token=${token}`);
    ws.inbox = []; ws.waiters = [];
    ws.on('message', (data, isBinary) => {
      if (isBinary) return;
      const item = JSON.parse(data.toString());
      const w = ws.waiters.findIndex((wt) => wt.pred(item));
      if (w >= 0) ws.waiters.splice(w, 1)[0].resolve(item); else ws.inbox.push(item);
    });
    ws.next = (pred, timeout = 2000) => new Promise((res, rej) => {
      const i = ws.inbox.findIndex(pred);
      if (i >= 0) return res(ws.inbox.splice(i, 1)[0]);
      const t = setTimeout(() => rej(new Error('timeout waiting for message')), timeout);
      ws.waiters.push({ pred, resolve: (v) => { clearTimeout(t); res(v); } });
    });
    ws.sendJson = (o) => ws.send(JSON.stringify(o));
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

const latAt = (km) => 17 + km / 111.195;

test('group timeline: every member tracked, isolated per group, exact report', async () => {
  const A = await register('Asha Lead', 'asha@coroute.test');
  const B = await register('Bala', 'bala@coroute.test');
  const C = await register('Chitra', 'chitra@coroute.test');
  const D = await register('Dev Other', 'dev@coroute.test');

  const route = [{ lat: latAt(0), lng: 78.4 }, { lat: latAt(60), lng: 78.4 }];
  const created = await api('POST', '/convoys', {
    name: 'Hyderabad to Kurnool', start: { lat: latAt(0), lng: 78.4, name: 'Gachibowli' },
    destination: 'Kurnool', destLat: latAt(40), destLng: 78.4, routeBreadcrumbs: route,
  }, A.token);
  assert.equal(created.status, 201, created.text);
  const gid = created.json.groupId;
  assert.equal((await api('POST', '/convoys/join', { code: created.json.joinCode }, B.token)).status, 200);
  assert.equal((await api('POST', '/convoys/join', { code: created.json.joinCode }, C.token)).status, 200);
  const other = await api('POST', '/convoys', { name: 'Other group' }, D.token);

  const wsA = await connect(A.token), wsB = await connect(B.token), wsC = await connect(C.token), wsD = await connect(D.token);
  for (const [ws, g] of [[wsA, gid], [wsB, gid], [wsC, gid], [wsD, other.json.groupId]]) {
    ws.sendJson({ type: 'JOIN', groupId: g });
    await ws.next((m) => m.type === 'SNAPSHOT');
  }
  wsA.sendJson({ type: 'STOP_ADD', name: 'Lunch', lat: latAt(30), lng: 78.4, category: 'FOOD' });
  await wsA.next((m) => m.type === 'STOPS');

  // ---- drive the ride: telemetry every 30 s of simulated time ----
  const room = await gw.convoys.getRoom(gid);
  const km = { [A.user.userId]: 0, [B.user.userId]: 0, [C.user.userId]: 0 };
  const speedAt = (uid, m) => {
    if (m >= 50) return 0;
    if (m >= 26) return 1;
    if (uid === B.user.userId) { if (m < 10) return 1; if (m < 16) return 0; if (m < 19) return 2; return 0; }
    if (m < 16) return 1;
    return 0;
  };
  const trackA = [];
  let seed = 3;
  const jitter = () => { seed = (seed * 16807) % 2147483647; return (seed / 2147483647 - 0.5) * 6 / 111195; };
  for (let half = 0; half <= 102; half++) {
    const m = half / 2;
    const t = T0 + m * MIN;
    mock.timers.setTime(t);
    for (const uid of Object.keys(km)) {
      if (uid === C.user.userId && m >= 30 && m < 37) continue; // C in a dead zone
      const lngOff = uid === C.user.userId && m >= 4 && m < 7 ? 0.006 : uid === B.user.userId ? 0.0002 : 0;
      const v = speedAt(uid, m);
      gw.convoys.patchRider(room, uid, { lat: latAt(km[uid]) + (v === 0 ? jitter() : 0), lng: 78.4 + lngOff, speedKmh: v * 60 }, { emit: false });
      await gw.timeline.idle();
    }
    if (m === 35) { await gw.timeline.tick(); await gw.timeline.idle(); }
    if (m === 41) {
      wsC.sendJson({ type: 'SOS', lat: latAt(km[C.user.userId]), lng: 78.4, alertType: 'MECHANICAL' });
      const alert = await wsA.next((x) => x.type === 'ALERT');
      await gw.timeline.idle();
      mock.timers.setTime(t + 20000);
      wsA.sendJson({ type: 'SOS_RESOLVE', alertId: alert.alert.alertId });
      await wsA.next((x) => x.type === 'ALERT_RESOLVED');
      await gw.timeline.idle();
    }
    // A's phone records a fix every 5 s; build them for this 30 s window.
    for (let s = 0; s < 6; s++) {
      const mm = m + s / 12;
      trackA.push({ ts: T0 + mm * MIN, km: km[A.user.userId] + (speedAt(A.user.userId, m) * s) / 12, v: speedAt(A.user.userId, m) * 60 });
    }
    for (const uid of Object.keys(km)) km[uid] += speedAt(uid, m) / 2;
  }

  // ---- A uploads the recorded track (as after the ride, from the phone's queue) ----
  const endT = T0 + 51 * MIN + 30000;
  for (let i = 0, seq = 0; i < trackA.length; i += 120, seq++) {
    mock.timers.setTime(endT + seq * 1100);
    const part = trackA.slice(i, i + 120);
    const startTs = part[0].ts;
    wsA.sendJson({
      type: 'TRACK', seq, startTs,
      enc: gm.encodePolyline(part.map((p) => ({ lat: latAt(p.km) + (p.v === 0 ? jitter() : 0), lng: 78.4 }))),
      t: part.map((p) => Math.round(p.ts - startTs)), v: part.map((p) => p.v), acc: part.map(() => 5),
    });
    const ack = await wsA.next((x) => x.type === 'TRACK_ACK' || x.type === 'ERROR');
    assert.equal(ack.type, 'TRACK_ACK', JSON.stringify(ack));
    assert.equal(ack.seq, seq);
  }
  // Resending a chunk is harmless.
  mock.timers.setTime(endT + 20000);
  const p0 = trackA.slice(0, 120);
  wsA.sendJson({ type: 'TRACK', seq: 0, startTs: p0[0].ts, enc: gm.encodePolyline(p0.map((p) => ({ lat: latAt(p.km), lng: 78.4 }))), t: p0.map((p) => p.ts - p0[0].ts), v: p0.map((p) => p.v), acc: p0.map(() => 5) });
  assert.equal((await wsA.next((x) => x.type === 'TRACK_ACK')).duplicate, true);
  // Another group's member cannot upload into this convoy (socket is bound to their own room).
  wsD.sendJson({ type: 'TRACK', seq: 99, startTs: Date.now() + 3600000, enc: 'abc', t: [0], v: [0], acc: [0] });
  assert.equal((await wsD.next((x) => x.type === 'ERROR')).code, 400);

  // ---- live timeline checks before the trip ends ----
  const live = (await api('GET', `/convoys/${gid}/timeline`, null, B.token)).json.events;
  const find = (type, uid) => live.filter((e) => e.type === type && (!uid || e.userId === uid));
  assert.equal(find('TRIP_STARTED').length, 1);
  assert.equal(find('JOINED').length, 2);
  const bStops = find('STOPPED', B.user.userId);
  assert.equal(bStops.length, 2, JSON.stringify(bStops));
  assert.equal(bStops[0].durationMs, 6 * MIN);
  const sep = find('SEPARATED', B.user.userId);
  assert.equal(sep.length, 1);
  assert.equal(sep[0].open, false);
  assert.ok(sep[0].data.maxDistanceM > 4000, JSON.stringify(sep[0]));
  const off = find('OFF_ROUTE', C.user.userId);
  assert.equal(off.length, 1);
  assert.equal(off[0].durationMs, 3 * MIN);
  const offline = find('OFFLINE', C.user.userId);
  assert.equal(offline.length, 1);
  assert.equal(offline[0].durationMs, 7.5 * MIN);
  const sos = find('SOS', C.user.userId);
  assert.equal(sos.length, 1);
  assert.equal(sos[0].data.resolvedBy, A.user.userId);
  assert.equal(sos[0].durationMs, 20000);
  assert.equal(find('STOP_REACHED').length, 3);
  assert.equal(find('DESTINATION_REACHED').length, 3);
  assert.equal(find('STOP_ADDED').length, 1);
  assert.ok((await gw.convoys.getRoom(gid)).meta.stopPoints[0].isVisited, 'lead reaching the stop marks it visited');

  // Pushed live to the group only.
  assert.ok(wsB.inbox.some((x) => x.type === 'TIMELINE' && x.event.type === 'STOPPED'));
  const leaked = wsD.inbox.filter((x) => (x.type === 'TIMELINE' || x.type === 'TIMELINE_UPDATE') && x.event.groupId !== other.json.groupId);
  assert.deepEqual(leaked, [], 'other group received nothing from this convoy');

  // ---- isolation over REST ----
  for (const p of ['timeline', 'tracks', 'report', 'gpx']) {
    assert.equal((await api('GET', `/convoys/${gid}/${p}`, null, D.token)).status, 403, p);
  }

  // ---- end the trip: report from real tracks ----
  mock.timers.setTime(endT + 60000);
  wsA.sendJson({ type: 'TRIP_STATUS', status: 'ENDED' });
  await wsB.next((x) => x.type === 'REPORT_READY', 3000);
  await gw.timeline.idle();

  const rep = (await api('GET', `/convoys/${gid}/report`, null, C.token)).json.report;
  assert.equal(rep.members.length, 3);
  const ra = rep.members.find((m) => m.userId === A.user.userId);
  assert.equal(ra.trackAvailable, true);
  assert.ok(Math.abs(ra.distanceM - 40000) / 40000 < 0.01, `A distance ${ra.distanceM}`);
  assert.equal(ra.stops, 1);
  assert.ok(Math.abs(ra.restMs - 10 * MIN) <= 15000, `A rest ${ra.restMs}`);
  assert.ok(ra.maxKmh >= 58 && ra.maxKmh <= 62);
  const rb = rep.members.find((m) => m.userId === B.user.userId);
  assert.equal(rb.trackAvailable, false);
  assert.equal(rb.stops, 2);
  assert.ok(rb.separatedMs > 0);
  assert.equal(rep.members.find((m) => m.userId === C.user.userId).sos, 1);
  assert.equal(rep.group.arrived, 3);
  assert.ok(!JSON.stringify(rep).includes('"lat"'), 'report holds no coordinates');

  // A's live stop replaced by the exact one, plus moving stretches.
  const final = (await api('GET', `/convoys/${gid}/timeline`, null, A.token)).json.events;
  const aStops = final.filter((e) => e.type === 'STOPPED' && e.userId === A.user.userId);
  assert.equal(aStops.length, 1);
  assert.equal(aStops[0].confidence, 'confirmed');
  assert.equal(final.filter((e) => e.type === 'MOVING' && e.userId === A.user.userId).length, 2);
  assert.ok(final.some((e) => e.type === 'TRIP_ENDED'));

  // Trip history now holds the real numbers and the phone's estimate cannot overwrite it.
  const trips = (await api('GET', '/trips', null, A.token)).json.trips;
  const ta = trips.find((t) => t.groupId === gid);
  assert.equal(ta.source, 'server');
  assert.ok(Math.abs(ta.totalDistanceKm - 40) < 0.5);
  assert.ok(ta.breadcrumbTrail.length >= 2); // straight road simplifies to its end points
  await api('POST', '/trips', { tripId: ta.tripId, totalDistanceKm: 1 }, A.token);
  assert.equal((await gw.repo.getTrip(ta.tripId)).totalDistanceKm, ta.totalDistanceKm);
  const tr = await api('GET', `/trips/${ta.tripId}/report`, null, A.token);
  assert.equal(tr.status, 200);
  assert.ok(tr.json.events.length > 10);
  assert.equal((await api('GET', `/trips/${ta.tripId}/report`, null, B.token)).status, 404);

  // Replay data and GPX.
  const tracks = (await api('GET', `/convoys/${gid}/tracks?simplify=15`, null, B.token)).json.tracks;
  assert.equal(tracks.length, 1);
  assert.ok(tracks[0].points.length < trackA.length);
  const gpx = await api('GET', `/convoys/${gid}/gpx?userId=${A.user.userId}`, null, C.token);
  assert.equal(gpx.status, 200);
  assert.ok(gpx.text.includes('<trkpt'));

  // ---- B's phone uploads its backlog after the trip ended: the report is rebuilt with B's real track ----
  const bPts = [];
  let bkm = 0;
  for (let s = 0; s <= 51 * 6; s++) { // every 10 s
    const m = s / 6;
    bPts.push({ ts: T0 + m * MIN, lat: latAt(bkm) + (speedAt(B.user.userId, m) === 0 ? jitter() : 0), lng: 78.4002, v: speedAt(B.user.userId, m) * 60 });
    bkm += speedAt(B.user.userId, m) / 6;
  }
  const chunksB = [];
  for (let i = 0, seq = 0; i < bPts.length; i += 120, seq++) {
    const part = bPts.slice(i, i + 120);
    chunksB.push({ seq, startTs: part[0].ts, enc: gm.encodePolyline(part), t: part.map((p) => p.ts - part[0].ts), v: part.map((p) => p.v), acc: part.map(() => 8) });
  }
  const up = await api('POST', `/convoys/${gid}/tracks`, { chunks: chunksB }, B.token);
  assert.equal(up.status, 200, up.text);
  assert.deepEqual(up.json.acked, chunksB.map((c) => c.seq));
  assert.equal((await api('POST', `/convoys/${gid}/tracks`, { chunks: chunksB.slice(0, 1) }, D.token)).status, 403);
  await new Promise((r) => setTimeout(r, 120)); // rebuild debounce (50 ms in tests)
  await gw.timeline.idle();
  const rebuilt = (await api('GET', `/convoys/${gid}/report`, null, A.token)).json.report;
  const rb2 = rebuilt.members.find((m) => m.userId === B.user.userId);
  assert.equal(rb2.trackAvailable, true);
  assert.equal(rb2.stops, 2);
  assert.ok(Math.abs(rb2.distanceM - 40000) / 40000 < 0.015, `B distance ${rb2.distanceM}`);
  assert.equal(rebuilt.members.find((m) => m.userId === A.user.userId).stops, 1, 'rebuild is idempotent for A');
  const afterRebuild = (await api('GET', `/convoys/${gid}/timeline`, null, A.token)).json.events;
  assert.equal(afterRebuild.filter((e) => e.type === 'STOPPED' && e.userId === A.user.userId).length, 1);
  // Past the grace period uploads are refused.
  mock.timers.setTime(Date.now() + 31 * MIN);
  assert.equal((await api('POST', `/convoys/${gid}/tracks`, { chunks: chunksB.slice(0, 1) }, B.token)).status, 410);

  // ---- retention after 91 days: points gone, timeline kept without coordinates ----
  await gw.retention.runOnce(Date.now() + 91 * 86400000);
  assert.equal((await gw.repo.listTrackChunks(gid)).length, 0);
  const kept = await gw.repo.listEvents(gid, { limit: 20000 });
  assert.ok(kept.length > 10);
  assert.ok(kept.every((e) => e.lat === null && e.lng === null));
  assert.ok(kept.some((e) => e.type === 'STOPPED' && e.durationMs > 0));
  const rep2 = (await api('GET', `/convoys/${gid}/report`, null, A.token)).json.report;
  assert.equal(rep2.members.length, 3);

  for (const ws of [wsA, wsB, wsC, wsD]) ws.close();
});
