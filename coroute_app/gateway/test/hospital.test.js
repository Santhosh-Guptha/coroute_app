'use strict';
/**
 * 3.16 nearest hospital: one Nominatim search per HIGH / CRITICAL alert, after the ALERT went out, never
 * blocking it; EMERGENCY_UPDATE.nearestHospital to the room; cached per 1 km cell; LOW alerts and failures
 * never retried; publicAlert carries it.
 */
process.env.NODE_ENV = 'test';
process.env.GEO_SEARCH_URL = 'http://nominatim.test';
process.env.GEO_MIN_INTERVAL_MS = '0';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const calls = [];
const order = []; // 'ALERT' when the room was told, 'FETCH' when the upstream call started
let fail = false;
async function fakeFetch(url) {
  if (!url.includes('/search?')) return { ok: false, status: 404, json: async () => ({}) };
  calls.push(url); order.push('FETCH');
  await sleep(20);
  if (fail) return { ok: false, status: 503, json: async () => ({}) };
  const u = new URL(url);
  const [w, n, e, s] = u.searchParams.get('viewbox').split(',').map(Number);
  const lat = (n + s) / 2, lon = (w + e) / 2;
  return {
    ok: true, status: 200,
    json: async () => [
      { name: 'Apollo Hospital', lat: String(lat + 0.03), lon: String(lon), type: 'hospital' },
      { name: 'Care Hospital Shamshabad', lat: String(lat + 0.01), lon: String(lon + 0.005), type: 'hospital' },
      { name: 'Far Clinic', lat: String(lat + 0.1), lon: String(lon), type: 'hospital' },
    ],
  };
}

let t, gw;
before(async () => {
  t = await boot({ geoFetch: fakeFetch }); gw = t.gw;
  gw.convoys.on('event', (gid, p) => { if (p.type === 'ALERT') order.push('ALERT'); });
});
after(async () => { await gw.shutdown(); });

let n = 0;
async function ride() {
  n++;
  const lead = await t.register(`Hosp Lead ${n}`, `hosplead${n}@coroute.test`);
  const rider = await t.register(`Hosp Rider ${n}`, `hosprider${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Hosp ${n}` }, lead.token)).json;
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, rider.token)).status, 200);
  const wl = await t.connect(lead.token);
  await wl.next((m) => m.type === 'HELLO');
  wl.sendJson({ type: 'JOIN', groupId: c.groupId, caps: ['net1'] });
  await wl.next((m) => m.type === 'SNAPSHOT');
  wl.frames = [];
  wl.on('message', (d, bin) => { if (!bin) wl.frames.push(JSON.parse(d.toString())); });
  const wr = await t.joinRoom(rider.token, c.groupId);
  return { lead, rider, c, gid: c.groupId, wl, wr, end: () => t.api('POST', `/convoys/${c.groupId}/status`, { status: 'ENDED' }, lead.token) };
}

test('HIGH alert: ALERT first, then one lookup, EMERGENCY_UPDATE.nearestHospital; cached for the next alert in the cell', async () => {
  const R = await ride();
  const before = calls.length;
  R.wr.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'CRASH', clientId: 'h-1' });
  const alertFrame = await R.wl.next((m) => m.type === 'ALERT');
  assert.deepEqual(order.slice(0, 2), ['ALERT', 'FETCH'], 'the ALERT is out before the lookup starts');
  assert.equal(alertFrame.alert.nearestHospital, undefined);
  const up = await R.wl.next((m) => m.type === 'EMERGENCY_UPDATE' && m.nearestHospital, 2000);
  assert.equal(calls.length - before, 1, 'one upstream call');
  assert.match(calls[calls.length - 1], /q=hospital&limit=5&bounded=1&viewbox=/);
  assert.equal(up.alertId, alertFrame.alert.alertId);
  assert.deepEqual(Object.keys(up.nearestHospital).sort(), ['distanceM', 'lat', 'lng', 'name']);
  assert.equal(up.nearestHospital.name, 'Care Hospital Shamshabad', 'the nearest by distance, not the first row');
  assert.ok(up.nearestHospital.distanceM > 1000 && up.nearestHospital.distanceM < 1500, `distance ${up.nearestHospital.distanceM}`);
  // publicAlert / snapshot carry it; stored with the alert.
  const snap = (await t.api('GET', `/convoys/${R.gid}`, undefined, R.lead.token)).json;
  assert.equal(snap.activeAlerts[0].nearestHospital.name, 'Care Hospital Shamshabad');
  assert.equal(snap.activeAlerts[0].hospitalTried, undefined);
  const stored = (await gw.repo.listAlerts(R.gid))[0];
  assert.equal(stored.nearestHospital.name, 'Care Hospital Shamshabad');
  assert.equal(stored.hospitalTried, undefined, 'memory only');
  // The next alert 300 m away (same 1 km cell): no upstream call, same answer.
  R.wl.sendJson({ type: 'SOS', lat: 17.387, lng: 78.488, alertType: 'MEDICAL', clientId: 'h-2' });
  const up2 = await R.wl.next((m) => m.type === 'EMERGENCY_UPDATE' && m.nearestHospital && m.alertId !== alertFrame.alert.alertId, 2000);
  assert.equal(calls.length - before, 1, 'cache hit');
  assert.equal(up2.nearestHospital.name, 'Care Hospital Shamshabad');
  await R.end();
  R.wl.close(); R.wr.close();
});

test('LOW alert: no lookup; upstream failure: alert unaffected, no retry for that alert', async () => {
  const R = await ride();
  const before = calls.length;
  R.wr.sendJson({ type: 'SOS', lat: 18.5, lng: 79.5, alertType: 'MECHANICAL', clientId: 'h-3' });
  const a = await R.wl.next((m) => m.type === 'ALERT');
  assert.equal(a.alert.severity, 'LOW');
  await sleep(80);
  assert.equal(calls.length, before, 'LOW alerts never look up a hospital');
  fail = true;
  R.wr.sendJson({ type: 'SOS', lat: 18.9, lng: 79.9, alertType: 'CRASH', clientId: 'h-4' });
  const b = await R.wl.next((m) => m.type === 'ALERT' && m.alert.alertId !== a.alert.alertId);
  await sleep(120);
  assert.equal(calls.length - before, 1, 'one failed attempt');
  const room = gw.convoys.rooms.get(R.gid);
  const alert = room.alerts.get(b.alert.alertId);
  assert.equal(alert.nearestHospital, undefined);
  assert.equal(alert.resolved, false, 'the alert is untouched');
  assert.equal(R.wl.frames.filter((f) => f.type === 'EMERGENCY_UPDATE' && f.nearestHospital).length, 0);
  // Nothing in this test retries the same alert; a later alert in the cell may try again (the failure is not cached).
  fail = false;
  gw.convoys._lookupHospital(room, alert);
  await sleep(60);
  assert.equal(calls.length - before, 1, 'one lookup per alert');
  await R.end();
  R.wl.close(); R.wr.close();
});

test('nearestHospital: nothing found is cached for 6 hours; disabled search answers null', async () => {
  const geo = gw.geo;
  const before = calls.length;
  const saved = fakeFetch;
  geo.fetch = async (url) => { calls.push(url); return { ok: true, status: 200, json: async () => [] }; };
  assert.equal(await geo.nearestHospital(20.5, 80.5), null);
  assert.equal(await geo.nearestHospital(20.504, 80.504), null);
  assert.equal(calls.length - before, 1, 'the empty answer is cached');
  geo.fetch = saved;
  const config = require('../src/config');
  const url = config.geoSearchUrl;
  config.geoSearchUrl = '';
  try { assert.equal(await geo.nearestHospital(17.385, 78.4867), null); } finally { config.geoSearchUrl = url; }
});
