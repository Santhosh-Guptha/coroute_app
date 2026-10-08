'use strict';
/**
 * Shared helpers for the 3.15 safety network / discovery tests (not a test file itself).
 *
 * Boots a full gateway on MemorySoda with a fake OSRM:
 *   /route  echoes the waypoints as the road geometry (so a convoy created with start, stops and
 *           destination along a line gets exactly that line as its route),
 *   /table  answers from `fake.table.answer(sources, dest)` after `fake.table.delayMs`, fails when
 *           `fake.table.fail`, and counts calls in `fake.table.calls`.
 * Timers of the network and discovery are set to an hour: tests call `network.tick(t)` and
 * `discovery.tick(t)` themselves. Each test should use its own longitude (`lane(k)`) so riders of
 * different tests never meet.
 *
 * Synthetic highway: along a meridian from lat 17.40 to 17.70; the emergency at 17.500.
 */
process.env.NODE_ENV = 'test';
process.env.GEO_ROUTE_URL = 'http://route.test';
process.env.GEO_MIN_INTERVAL_MS = '0';
process.env.NET_TICK_MS = '3600000';
process.env.DISCOVERY_TICK_MS = '3600000';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const E_LAT = 17.5;

function makeFake() {
  const fake = { routeCalls: 0, table: { calls: 0, delayMs: 0, fail: false, answer: null } };
  fake.fetch = async (url) => {
    if (url.includes('/table/v1/driving/')) {
      fake.table.calls++;
      if (fake.table.delayMs) await sleep(fake.table.delayMs);
      if (fake.table.fail) return { ok: false, status: 503, json: async () => ({}) };
      const coords = decodeURIComponent(url.split('/table/v1/driving/')[1].split('?')[0]).split(';').map((c) => c.split(',').map(Number));
      const dest = coords[coords.length - 1];
      const sources = coords.slice(0, -1);
      const ans = fake.table.answer ? fake.table.answer(sources.map(([lng, lat]) => ({ lat, lng })), { lat: dest[1], lng: dest[0] }) : null;
      const rows = sources.map((_, i) => (ans && ans[i] ? ans[i] : { distanceM: null, durationS: null }));
      return { ok: true, json: async () => ({ code: 'Ok', distances: rows.map((r) => [r.distanceM]), durations: rows.map((r) => [r.durationS]) }) };
    }
    if (url.includes('/route/v1/driving/')) {
      fake.routeCalls++;
      const coords = decodeURIComponent(url.split('/route/v1/driving/')[1].split('?')[0]).split(';').map((c) => c.split(',').map(Number));
      return {
        ok: true,
        json: async () => ({ routes: [{ distance: (coords.length - 1) * 1000, duration: (coords.length - 1) * 60, geometry: { coordinates: coords }, legs: coords.slice(1).map(() => ({ distance: 1000, duration: 60 })) }] }),
      };
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  return fake;
}

/** Points along a meridian (lng) from lat a to lat b (either direction), every `step` degrees. */
function line(lng, a, b, step = 0.02) {
  const pts = [];
  const n = Math.round(Math.abs(b - a) / step);
  for (let i = 0; i <= n; i++) pts.push({ lat: +(a + ((b - a) * i) / n).toFixed(6), lng });
  return pts;
}

async function netBoot(opts = {}) {
  const fake = makeFake();
  const t = await boot({ geoFetch: fake.fetch, ...opts });
  const net = t.gw.network;
  let seq = 0;

  /** A rider with a complete safety profile (through AuthService: the HTTP sign-up limiter allows 30 per 15 min). */
  async function rider(tag, extra = {}) {
    seq++;
    return t.gw.auth.register({
      name: `Net ${tag} ${seq}`, email: `net.${tag.toLowerCase().replace(/[^a-z0-9]/g, '')}.${seq}@coroute.test`, password: 'Password#123',
      phone: `+9197${String(10000000 + seq).slice(-8)}`, vehicleType: 'Motorcycle', vehicleNo: `KA01NT${String(1000 + seq).slice(-4)}`,
      emergencyContact: '+919000000002', emergencyContactName: 'Kin Contact', ...extra,
    });
  }

  /** Waits until the room has a route from OSRM (not the straight-line fallback). */
  async function waitRoute(gid) {
    for (let i = 0; i < 200; i++) {
      const room = t.gw.convoys.rooms.get(gid);
      if (room && room.meta.route && !room.meta.route.approximate && room.meta.route.polyline) return room;
      await sleep(10);
    }
    throw new Error('route never arrived');
  }

  /** A convoy whose route is exactly `points` (start, up to 20 stops, destination). No points: no route. */
  async function rideOn(points, { name = 'Ride', lead = null } = {}) {
    const L = lead || await rider(`${name} Lead`);
    const body = { name };
    if (points && points.length >= 2) {
      const mid = points.slice(1, -1);
      assert.ok(mid.length <= 20, 'at most 20 stops');
      body.start = { ...points[0], name: 'Start' };
      body.destination = 'End'; body.destLat = points[points.length - 1].lat; body.destLng = points[points.length - 1].lng;
      body.stops = mid.map((p, i) => ({ name: `P${i}`, lat: p.lat, lng: p.lng, category: 'OTHER' }));
    }
    const res = await t.api('POST', '/convoys', body, L.token);
    assert.equal(res.status, 201, JSON.stringify(res.json));
    const c = res.json;
    const room = points && points.length >= 2 ? await waitRoute(c.groupId) : t.gw.convoys.rooms.get(c.groupId);
    return { c, gid: c.groupId, lead: L, room };
  }

  async function join(ride, tag = 'Member') {
    const u = await rider(tag);
    const r = await t.api('POST', '/convoys/join', { code: ride.c.joinCode }, u.token);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    return u;
  }

  /** Connects and JOINs with the 3.15 capability (net1). */
  async function net1(token, gid) {
    const ws = await t.connect(token);
    await ws.next((m) => m.type === 'HELLO');
    ws.sendJson({ type: 'JOIN', groupId: gid, caps: ['net1'] });
    const snap = await ws.next((m) => m.type === 'SNAPSHOT');
    ws.snapshot = snap.convoy;
    ws.frames = [];
    ws.on('message', (d, bin) => { if (!bin) ws.frames.push(JSON.parse(d.toString())); });
    return ws;
  }

  /** Connects and JOINs like a 3.14 app (no caps). Records every frame. */
  async function oldApp(token, gid) {
    const ws = await t.connect(token);
    await ws.next((m) => m.type === 'HELLO');
    ws.sendJson({ type: 'JOIN', groupId: gid });
    const snap = await ws.next((m) => m.type === 'SNAPSHOT');
    ws.snapshot = snap.convoy;
    ws.frames = [];
    ws.on('message', (d, bin) => { if (!bin) ws.frames.push(JSON.parse(d.toString())); });
    return ws;
  }

  /** Applies one fix as the gateway does for TELEMETRY (emits 'telemetry'). */
  function place(gid, user, lat, lng, heading = 0, speedKmh = 60) {
    const room = t.gw.convoys.rooms.get(gid);
    return t.gw.convoys.patchRider(room, user.user ? user.user.userId : user.userId, { lat, lng, heading, speedKmh });
  }

  /** A short recent path ending at (lat, lng): `n` fixes `stepDeg` apart along `dir` (+1 north / -1 south) on a meridian. */
  function pathTo(gid, user, lat, lng, { n = 5, stepDeg = 0.0015, dir = 1, speed = 60, dLng = 0 } = {}) {
    for (let i = n - 1; i >= 0; i--) place(gid, user, lat - dir * i * stepDeg, lng - i * dLng, dir > 0 ? 0 : 180, speed);
  }

  async function sos(ws, lat, lng, extra = {}) {
    const clientId = `sos-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    ws.sendJson({ type: 'SOS', lat, lng, alertType: 'CRASH', clientId, ...extra });
    const a = await ws.next((m) => m.type === 'ALERT' && !m.duplicate && m.alert.clientId === clientId);
    await settle();
    return a.alert;
  }

  /** Lets deferred network work (setImmediate, promises) run. */
  async function settle(ms = 30) { await sleep(ms); }

  /** Frames of one type a socket received (after its JOIN). */
  const got = (ws, type) => ws.frames.filter((f) => f.type === type);

  async function endRide(ride) {
    await t.api('POST', `/convoys/${ride.gid}/status`, { status: 'ENDED' }, ride.lead.token);
  }

  return { t, fake, net, rider, rideOn, join, net1, oldApp, place, pathTo, sos, settle, got, endRide, waitRoute };
}

module.exports = { netBoot, line, E_LAT, sleep };
