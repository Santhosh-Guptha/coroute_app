'use strict';
process.env.NODE_ENV = 'test';
process.env.GEO_ROUTE_URL = 'http://route.test';
process.env.GEO_MIN_INTERVAL_MS = '0';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const WebSocket = require('ws');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { decodePolyline } = require('../src/geo_math');

let gw, base, wsBase, routeCalls = 0, routeDown = false;

// Fake OSRM: echoes the waypoints as the geometry, 1 km per waypoint gap.
async function fakeFetch(url) {
  routeCalls++;
  if (routeDown) return { ok: false, status: 503, json: async () => ({}) };
  const coords = decodeURIComponent(url.split('/route/v1/driving/')[1].split('?')[0]).split(';').map((c) => c.split(',').map(Number));
  return {
    ok: true,
    json: async () => ({ routes: [{ distance: (coords.length - 1) * 1000, duration: (coords.length - 1) * 60, geometry: { coordinates: coords }, legs: coords.slice(1).map(() => ({ distance: 1000, duration: 60 })) }] }),
  };
}

before(async () => {
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} }, geoFetch: fakeFetch });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  base = `http://127.0.0.1:${port}/api`;
  wsBase = `ws://127.0.0.1:${port}/ws`;
});
after(async () => { await gw.shutdown(); });

async function api(method, path, body, token) {
  const res = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}
function wsConnect(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}?token=${token}`);
    ws.inbox = [];
    ws.on('message', (d, bin) => { if (!bin) ws.inbox.push(JSON.parse(d.toString())); });
    ws.wait = async (pred, ms = 2000) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        const i = ws.inbox.findIndex(pred);
        if (i >= 0) return ws.inbox.splice(i, 1)[0];
        await new Promise((r) => setTimeout(r, 10));
      }
      throw new Error('timeout');
    };
    ws.json = (o) => ws.send(JSON.stringify(o));
    ws.once('open', () => resolve(ws));
    ws.once('error', reject);
  });
}

test('trip planned on the map: route through every stop, suggestions, reorder, skip, fallback', async () => {
  const lead = (await api('POST', '/auth/register', { name: 'Lead Lata', email: 'lata@coroute.test', password: 'Password#123', phone: '9999999999', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' })).json;
  const mem = (await api('POST', '/auth/register', { name: 'Member Mani', email: 'mani@coroute.test', password: 'Password#123', phone: '9999999999', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact' })).json;

  const created = await api('POST', '/convoys', {
    name: 'Coast run',
    start: { lat: 17.0, lng: 78.0, name: 'Home' },
    destination: 'Beach', destLat: 17.3, destLng: 78.0,
    stops: [
      { name: 'Fuel', lat: 17.1, lng: 78.0, category: 'fuel', plannedDwellMin: 10 },
      { name: 'Lunch', lat: 17.2, lng: 78.0, category: 'FOOD' },
      { name: 'Broken', lat: 'x', lng: 1 },
    ],
  }, lead.token);
  assert.equal(created.status, 201);
  const gid = created.json.groupId;
  assert.equal(created.json.stopPoints.length, 2, 'invalid stop dropped');
  assert.equal(created.json.stopPoints[0].category, 'FUEL');
  assert.equal(created.json.stopPoints[0].status, 'PLANNED');
  await api('POST', '/convoys/join', { code: created.json.joinCode }, mem.token);

  const wl = await wsConnect(lead.token), wm = await wsConnect(mem.token);
  for (const ws of [wl, wm]) { ws.json({ type: 'JOIN', groupId: gid }); await ws.wait((m) => m.type === 'SNAPSHOT'); }

  // The route was computed at creation: start, both stops, destination.
  let meta = (await gw.convoys.getRoom(gid)).meta;
  for (let i = 0; i < 50 && !meta.route; i++) await new Promise((r) => setTimeout(r, 20));
  assert.equal(meta.route.approximate, false);
  assert.equal(decodePolyline(meta.route.polyline).length, 4);
  assert.equal(meta.route.legs.length, 3);

  // A member's stop is a suggestion: not on the route until the lead accepts it.
  wm.json({ type: 'STOP_SUGGEST', name: 'Tea stall', lat: 17.15, lng: 78.0, category: 'FOOD' });
  const sugg = await wl.wait((m) => m.type === 'STOPS' && m.stopPoints.some((s) => s.status === 'SUGGESTED'));
  const tea = sugg.stopPoints.find((s) => s.name === 'Tea stall');
  assert.equal(tea.suggestedByName, 'Member Mani');
  // A member cannot accept, reorder or change the destination (and is not thrown out for trying).
  wm.json({ type: 'STOP_ACCEPT', stopId: tea.stopId });
  const denied = await wm.wait((m) => m.type === 'ERROR');
  assert.equal(denied.code, 403);
  assert.equal(denied.reason, undefined);
  wm.json({ type: 'STOP_ADD', name: 'Viewpoint', lat: 17.25, lng: 78.0 });
  await wl.wait((m) => m.type === 'STOPS' && m.stopPoints.some((s) => s.name === 'Viewpoint' && s.status === 'SUGGESTED'));

  wl.json({ type: 'STOP_ACCEPT', stopId: tea.stopId });
  const routed = await wl.wait((m) => m.type === 'ROUTE' && m.route && decodePolyline(m.route.polyline).length === 5);
  assert.equal(routed.route.legs.length, 4);

  // Reorder: Lunch first. Then skip Fuel: it drops off the route.
  const stops = (await gw.convoys.getRoom(gid)).meta.stopPoints;
  const id = (n) => stops.find((s) => s.name === n).stopId;
  wl.json({ type: 'STOP_REORDER', order: [id('Lunch'), id('Tea stall'), id('Fuel')] });
  const reordered = await wl.wait((m) => m.type === 'STOPS' && m.stopPoints[0].name === 'Lunch');
  assert.deepEqual(reordered.stopPoints.map((s) => s.orderIndex), [1, 2, 3, 4]);
  wl.json({ type: 'STOP_SKIP', stopId: id('Fuel') });
  await wl.wait((m) => m.type === 'STOPS' && m.stopPoints.find((s) => s.name === 'Fuel').status === 'SKIPPED');
  const afterSkip = await wl.wait((m) => m.type === 'ROUTE' && m.route && decodePolyline(m.route.polyline).length === 4);
  assert.ok(afterSkip.route);
  wl.json({ type: 'STOP_DECLINE', stopId: id('Viewpoint') });
  await wl.wait((m) => m.type === 'STOPS' && !m.stopPoints.some((s) => s.name === 'Viewpoint'));

  // New destination; routing service down: straight-line route, marked approximate.
  routeDown = true;
  wl.json({ type: 'ROUTE_SET', destination: { lat: 17.4, lng: 78.1, name: 'Lighthouse' } });
  const dest = await wm.wait((m) => m.type === 'DESTINATION');
  assert.equal(dest.destinationName, 'Lighthouse');
  const approx = await wm.wait((m) => m.type === 'ROUTE' && m.route && m.route.approximate === true);
  assert.ok(approx.route.distanceM > 40000);

  // The timeline tells the story.
  await gw.timeline.idle();
  const ev = (await api('GET', `/convoys/${gid}/timeline`, null, mem.token)).json.events.map((e) => e.type);
  for (const t of ['STOP_SUGGESTED', 'STOP_ADDED', 'ROUTE_CHANGED', 'STOP_SKIPPED']) assert.ok(ev.includes(t), t);

  // Snapshot carries the route for riders who join later.
  const snap = (await api('GET', `/convoys/${gid}`, null, mem.token)).json;
  assert.equal(snap.route.approximate, true);
  assert.equal(snap.destinationName, 'Lighthouse');
  assert.ok(routeCalls >= 3);
  wl.close(); wm.close();
});
