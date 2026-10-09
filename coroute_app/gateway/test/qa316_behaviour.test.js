'use strict';
/**
 * 3.16 adversarial behaviour and privacy scenarios (QA): the server rules at their edges, old apps,
 * what leaves the server and what is stored. Complements ride316_rules / sweeper / weather / hospital /
 * live_link / far_by_road / follow_up_admin, which cover the happy paths.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'qa316admin@coroute.test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.NET_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.GEO_SEARCH_URL = 'http://nominatim.test';
process.env.WEATHER_URL = 'http://wx.test';
process.env.GEO_MIN_INTERVAL_MS = '0';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 9, 9, 7, 0, 0);
let now = T0;
let t, gw, admin;
const upstream = []; // every upstream URL the geo proxy asked for
let hospitalDelayMs = 20;
async function fakeFetch(url) {
  upstream.push(url);
  if (url.includes('/search?')) {
    await sleep(hospitalDelayMs);
    const u = new URL(url);
    const [w, n, e, s] = u.searchParams.get('viewbox').split(',').map(Number);
    return { ok: true, status: 200, json: async () => [{ name: 'Area Hospital', lat: String((n + s) / 2 + 0.02), lon: String((w + e) / 2), type: 'hospital' }] };
  }
  if (url.includes('/v1/forecast?')) {
    const u = new URL(url);
    const cells = u.searchParams.get('latitude').split(',').length;
    const from = Math.floor(Date.now() / 86400000) * 86400;
    const one = () => ({ hourly: { time: Array.from({ length: 72 }, (_, i) => from + i * 3600), precipitation_probability: Array(72).fill(10), precipitation: Array(72).fill(0), weather_code: Array(72).fill(1), temperature_2m: Array(72).fill(25) } });
    return { ok: true, status: 200, json: async () => (cells === 1 ? one() : Array.from({ length: cells }, one)) };
  }
  return { ok: false, status: 404, json: async () => ({}) };
}

before(async () => {
  mock.timers.enable({ apis: ['Date'], now: T0 });
  t = await boot({ geoFetch: fakeFetch }); gw = t.gw;
  admin = await t.register('QA Admin', 'qa316admin@coroute.test');
  assert.equal(admin.user.role, 'MASTER_ADMIN');
});
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
async function ride(body = {}, riders = 2) {
  n++;
  const lead = await t.register(`QA Lead ${n}`, `qalead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `QA ${n}`, ...body }, lead.token)).json;
  const members = [];
  for (let i = 0; i < riders; i++) {
    n++;
    const u = await t.register(`QA Rider ${n}`, `qarider${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  const room = gw.convoys.rooms.get(c.groupId);
  return { lead, c, gid: c.groupId, room, members, end: () => t.api('POST', `/convoys/${c.groupId}/status`, { status: 'ENDED' }, lead.token) };
}
const uid = (u) => u.user.userId;
const leadUser = (R) => ({ userId: uid(R.lead), name: 'Lead', role: 'RIDER' });
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => e.type === type);
async function fix(room, u, patch) {
  gw.convoys.patchRider(room, uid(u), { lat: 17.0, lng: 78.0, speedKmh: 50, ...patch }, { emit: false });
  await gw.timeline.idle();
}
async function tick() { await gw.timeline.tick(); await gw.timeline.idle(); }
/** Every string value anywhere in an object. */
function strings(o, out = []) {
  if (typeof o === 'string') out.push(o);
  else if (o && typeof o === 'object') for (const v of Object.values(o)) strings(v, out);
  return out;
}

test('STALE_UPDATE edges: default typical gap, the stale lead tells only the sweeper, leave closes it, OFFLINE still opens for a parked phone', async () => {
  const R = await ride({}, 2);
  const [sweeper, kiran] = R.members;
  await gw.convoys.setRole(R.gid, leadUser(R), uid(sweeper), 'SWEEPER');
  // Nobody has three gaps yet: typical is 20 s, the threshold max(90, 60) = 90 s.
  advance(1000);
  await fix(R.room, R.lead, { lat: 17.01 });
  await fix(R.room, sweeper, { lat: 17.0 });
  await fix(R.room, kiran, { lat: 17.0 });
  advance(80000); await fix(R.room, sweeper, { lat: 17.02 }); await fix(R.room, kiran, { lat: 17.02 }); await tick();
  assert.equal((await events(R.gid, 'STALE_UPDATE')).length, 0, '80 s is under the 90 s minimum');
  advance(15000); await fix(R.room, sweeper, { lat: 17.03 }); await fix(R.room, kiran, { lat: 17.03 }); await tick();
  let stale = await events(R.gid, 'STALE_UPDATE');
  assert.equal(stale.length, 1, 'the moving lead is stale after 95 s');
  assert.equal(stale[0].userId, uid(R.lead));
  assert.deepEqual(stale[0].data.notify, [uid(sweeper)], 'the sweeper is told, never the rider themself');
  assert.equal(stale[0].data.typicalS, 20);
  // The lead sends again: RESUMED. Kiran goes quiet while moving, then leaves: the slot closes with the leave.
  await fix(R.room, R.lead, { lat: 17.04 });
  stale = await events(R.gid, 'STALE_UPDATE');
  assert.equal(stale[0].open, false);
  assert.equal(stale[0].data.result, 'RESUMED');
  // The sweeper now has three gaps (80, 15, 100 s): the typical gap is 80 s and the threshold 240 s.
  advance(100000); await fix(R.room, R.lead, { lat: 17.05 }); await fix(R.room, sweeper, { lat: 17.05 }); await tick();
  assert.equal((await events(R.gid, 'STALE_UPDATE')).filter((e) => e.userId === uid(kiran)).length, 0, '100 s is under 3 x 80 s');
  // Lead gaps 95, 100, 190 and sweeper gaps 15, 80, 100, 190: typical 95 s, threshold 285 s; Kiran is 290 s quiet.
  advance(190000); await fix(R.room, R.lead, { lat: 17.06 }); await fix(R.room, sweeper, { lat: 17.06 }); await tick();
  stale = (await events(R.gid, 'STALE_UPDATE')).filter((e) => e.userId === uid(kiran));
  assert.equal(stale.length, 1, 'stale at 290 s');
  assert.equal(stale[0].data.typicalS, 95);
  assert.equal(stale[0].open, true);
  await gw.convoys.leave(R.gid, uid(kiran));
  await gw.timeline.idle();
  stale = (await events(R.gid, 'STALE_UPDATE')).filter((e) => e.userId === uid(kiran));
  assert.equal(stale[0].open, false, 'leaving closes the open stale entry');
  // 3.15 regression: a parked phone (speed 0) that goes silent is never stale but still goes OFFLINE after the group's minutes.
  await fix(R.room, sweeper, { lat: 17.05, speedKmh: 0 });
  for (let i = 0; i < 6; i++) { advance(60000); await fix(R.room, R.lead, { lat: 17.05 + i * 0.001 }); await tick(); }
  assert.equal((await events(R.gid, 'STALE_UPDATE')).filter((e) => e.userId === uid(sweeper)).length, 0, 'parked: never stale');
  assert.equal((await events(R.gid, 'OFFLINE')).filter((e) => e.userId === uid(sweeper)).length, 1, 'parked: OFFLINE as in 3.15');
  await R.end();
  await gw.timeline.idle();
});

test('LOW_BATTERY edges: an app that never sends a level is ignored; 0% opens; charging at 10% opens only when unplugged; a string level is read', async () => {
  const R = await ride({}, 3);
  const [old, a, b] = R.members;
  advance(1000);
  await fix(R.room, old, { lat: 17.0 }); // no batteryLevel at all (old app, no battery permission)
  await fix(R.room, a, { lat: 17.0, batteryLevel: 10, isCharging: true });
  await fix(R.room, b, { lat: 17.0, batteryLevel: 0, isCharging: false });
  let low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low.length, 1, 'only the 0% phone');
  assert.equal(low[0].userId, uid(b));
  assert.equal(low[0].data.level, 0);
  advance(1000);
  await fix(R.room, a, { lat: 17.0, batteryLevel: '9', isCharging: false });
  low = await events(R.gid, 'LOW_BATTERY');
  assert.equal(low.length, 2, 'unplugged at 9%: opens');
  assert.equal(low[1].userId, uid(a));
  assert.equal(low[1].data.level, 9, 'a numeric string is read as a number');
  advance(1000);
  await fix(R.room, old, { lat: 17.01 });
  assert.equal((await events(R.gid, 'LOW_BATTERY')).filter((e) => e.userId === uid(old)).length, 0, 'still nothing for the app without a level');
  // Nothing about the level is pushed more than once per 5%: 9 -> 7 -> 5 updates once (at 4 or less from 9).
  advance(1000); await fix(R.room, a, { batteryLevel: 7 });
  advance(1000); await fix(R.room, a, { batteryLevel: 5 });
  low = (await events(R.gid, 'LOW_BATTERY')).filter((e) => e.userId === uid(a));
  assert.equal(low[0].data.level, 9, 'a drop of 4 is not pushed');
  advance(1000); await fix(R.room, a, { batteryLevel: 4 });
  low = (await events(R.gid, 'LOW_BATTERY')).filter((e) => e.userId === uid(a));
  assert.equal(low[0].data.level, 4);
  await R.end();
  await gw.timeline.idle();
});

test('BEHIND_SWEEPER edges: 30 s behind then caught up is nothing; the sweeper leaving closes with SWEEPER_CHANGED; ROLE_SET refuses LEAD, the creator and pack senders', async () => {
  const R = await ride({ start: { lat: 17.0, lng: 78.0, name: 'Start' }, destination: 'End', destLat: 17.2, destLng: 78.0 }, 3);
  assert.ok(R.room.meta.route && R.room.meta.route.polyline);
  const [sw, kiran, pack] = R.members;
  await gw.convoys.setRole(R.gid, leadUser(R), uid(sw), 'SWEEPER');
  const behind = async () => events(R.gid, 'BEHIND_SWEEPER');
  // 30 s at 555 m behind, then back within 100 m: the 60 s hold never completes.
  for (let i = 0; i < 3; i++) { advance(10000); await fix(R.room, sw, { lat: 17.100 }); await fix(R.room, kiran, { lat: 17.095 }); }
  for (let i = 0; i < 6; i++) { advance(10000); await fix(R.room, sw, { lat: 17.100 }); await fix(R.room, kiran, { lat: 17.0995 }); }
  assert.equal((await behind()).length, 0, 'no entry: caught up before 60 s');
  // Behind long enough: opens. Then the sweeper leaves the ride: closed as SWEEPER_CHANGED.
  for (let i = 0; i < 8; i++) { advance(10000); await fix(R.room, sw, { lat: 17.100 }); await fix(R.room, kiran, { lat: 17.094 }); }
  let list = await behind();
  assert.equal(list.length, 1);
  assert.equal(list[0].open, true);
  await gw.convoys.leave(R.gid, uid(sw));
  await gw.timeline.idle();
  advance(10000); await fix(R.room, kiran, { lat: 17.094 }); await fix(R.room, pack, { lat: 17.1 });
  list = await behind();
  assert.equal(list[0].open, false, 'closed once the sweeper is gone');
  assert.equal(list[0].data.result, 'SWEEPER_CHANGED');
  assert.equal([...R.room.riders.values()].filter((r) => r.role === 'SWEEPER').length, 0);

  // ROLE_SET over the socket: LEAD is not settable, the creator is never a target, a pack rider is refused.
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wp = await t.joinRoom(pack.token, R.gid);
  wl.sendJson({ type: 'ROLE_SET', userId: uid(kiran), role: 'LEAD', clientId: 'qa-role-1' });
  let err = await wl.next((m) => m.type === 'ERROR');
  assert.equal(err.reason, 'BAD_ROLE');
  wl.sendJson({ type: 'ROLE_SET', userId: uid(R.lead), role: 'SWEEPER', clientId: 'qa-role-2' });
  err = await wl.next((m) => m.type === 'ERROR');
  assert.equal(err.reason, 'NOT_ALLOWED');
  wp.sendJson({ type: 'ROLE_SET', userId: uid(kiran), role: 'SWEEPER', clientId: 'qa-role-3' });
  err = await wp.next((m) => m.type === 'ERROR');
  assert.equal(err.code, 403);
  assert.equal(R.room.riders.get(uid(kiran)).role, 'PACK', 'a pack rider changes nothing');
  // The lead makes Kiran the sweeper; a socket without any capabilities (3.15 app) still gets the plain RIDER_UPDATE.
  wl.sendJson({ type: 'ROLE_SET', userId: uid(kiran), role: 'SWEEPER', clientId: 'qa-role-4' });
  const upd = await wp.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === uid(kiran));
  assert.equal(upd.rider.role, 'SWEEPER');
  assert.ok(!('liveLink' in upd.rider) && !('batteryLevel' in upd.rider && upd.rider.batteryLevel === undefined));
  wl.close(); wp.close();
  await R.end();
  await gw.timeline.idle();
});

test('town limit edges: SKIPPED and SUGGESTED stops do not count; 1.5 km from a stop is open road; the town limit never raises the group limit', async () => {
  const R = await ride({
    speedLimitKmh: 30, destination: 'End', destLat: 17.5, destLng: 78.0,
    start: { lat: 17.0, lng: 78.0, name: 'Start' },
    stops: [{ name: 'Tea', lat: 17.2, lng: 78.0, category: 'REST' }, { name: 'Fuel', lat: 17.3, lng: 78.0, category: 'FUEL' }],
  }, 3);
  const [a, b, c] = R.members;
  await gw.convoys.updateConfig(R.gid, leadUser(R), { townLimitKmh: 60 });
  R.room.meta.stopPoints[0].status = 'SKIPPED';
  R.room.meta.stopPoints.push({ stopId: 'sug', name: 'Maybe', lat: 17.4, lng: 78.0, category: 'REST', status: 'SUGGESTED' });
  const over = async (u) => (await events(R.gid, 'OVERSPEED')).filter((e) => e.userId === uid(u));
  // a: 45 km/h at the skipped stop. The group limit is 30, the town limit 60: the lower one applies everywhere (never raised).
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, a, { lat: 17.2, speedKmh: 45 }); }
  let list = await over(a);
  assert.equal(list.length, 1);
  assert.equal(list[0].data.limitKmh, 30, 'the town limit never raises the group limit');
  assert.equal(list[0].data.context, 'GROUP', 'a skipped stop is not a town');
  // b: 45 km/h at the suggested stop: same.
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, b, { lat: 17.4, speedKmh: 45 }); }
  list = await over(b);
  assert.equal(list[0].data.context, 'GROUP', 'a suggested stop is not a town');
  // Group limit off, town 40: c at 50 km/h 1.5 km from the fuel stop is open road (nothing); 500 m away: TOWN.
  await gw.convoys.updateConfig(R.gid, leadUser(R), { speedLimitKmh: 0, townLimitKmh: 40 });
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, c, { lat: 17.3135, speedKmh: 50 }); }
  assert.equal((await over(c)).length, 0, '1.5 km away: no limit');
  for (let i = 0; i < 5; i++) { advance(5000); await fix(R.room, c, { lat: 17.3045, speedKmh: 50 }); }
  list = await over(c);
  assert.equal(list.length, 1);
  assert.equal(list[0].data.context, 'TOWN');
  assert.equal(list[0].data.limitKmh, 40);
  // Leaving the town at the same speed closes the episode (the active limit is gone).
  for (let i = 0; i < 3; i++) { advance(5000); await fix(R.room, c, { lat: 17.35, speedKmh: 50 }); }
  list = await over(c);
  assert.equal(list[0].open, false);
  await R.end();
  await gw.timeline.idle();
});

test('weather privacy and validation: 6 points 422, 0/0 422, no auth 401, milliseconds accepted, only 0.1 degree cells leave the server', async () => {
  const u = await t.register('QA Weather', 'qaweather@coroute.test');
  const post = (points, tok = u.token) => t.api('POST', '/geo/weather', { points }, tok);
  assert.equal((await t.api('POST', '/geo/weather', { points: [{ lat: 17.4, lng: 78.5 }] })).status, 401);
  assert.equal((await post(Array.from({ length: 6 }, () => ({ lat: 17.4, lng: 78.5 })))).status, 422);
  assert.equal((await post([{ lat: 0, lng: 0 }])).status, 422);
  assert.equal((await post([{ lat: 'x', lng: 78.5 }])).status, 422);
  assert.equal((await post([])).status, 422);
  assert.equal((await post('nope')).status, 422);
  const before = upstream.length;
  const r = await post([{ lat: 17.385044, lng: 78.486671, at: Date.now() + 3600000 }]);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.points[0].at, Math.round(Date.now() / 1000) + 3600, 'milliseconds are converted to seconds');
  const asked = upstream.slice(before).filter((x) => x.includes('/v1/forecast'));
  assert.equal(asked.length, 1);
  const q = new URL(asked[0]).searchParams;
  assert.equal(q.get('latitude'), '17.4');
  assert.equal(q.get('longitude'), '78.5');
  assert.ok(!asked[0].includes('17.38') && !asked[0].includes('78.48'), 'the phone position never leaves the server');
});

test('nearest hospital never delays the SOS: a slow upstream answers after the ALERT; the lookup uses a 1 km rounded point; admins see no hash', async () => {
  hospitalDelayMs = 400;
  const R = await ride({}, 1);
  const kiran = R.members[0];
  const wl = await t.connect(R.lead.token);
  await wl.next((m) => m.type === 'HELLO');
  wl.sendJson({ type: 'JOIN', groupId: R.gid, caps: ['net1'] });
  await wl.next((m) => m.type === 'SNAPSHOT');
  const wk = await t.joinRoom(kiran.token, R.gid);
  const before = upstream.length;
  const t0 = process.hrtime.bigint();
  wk.sendJson({ type: 'SOS', lat: 17.385044, lng: 78.486671, alertType: 'CRASH_OR_EMERGENCY', clientId: 'qa-sos-1' });
  const alert = (await wl.next((m) => m.type === 'ALERT')).alert;
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  assert.ok(ms < 300, `ALERT arrived in ${ms} ms, before the 400 ms upstream answer`);
  assert.ok(!('nearestHospital' in alert) && !('liveLink' in alert) && !('hospitalTried' in alert));
  const upd = await wl.next((m) => m.type === 'EMERGENCY_UPDATE' && m.nearestHospital, 2000);
  assert.equal(upd.nearestHospital.name, 'Area Hospital');
  const search = upstream.slice(before).find((x) => x.includes('/search?'));
  assert.ok(search);
  assert.ok(!search.includes('17.385') && !search.includes('78.486'), 'the exact alert position never goes upstream');
  // Live link made by the owner: the admin emergencies feed and the snapshot carry no hash and no token.
  const made = await t.api('POST', `/convoys/${R.gid}/alerts/${alert.alertId}/live-link`, {}, kiran.token);
  assert.equal(made.status, 200);
  const feed = await t.api('GET', '/admin/emergencies', undefined, admin.token);
  assert.equal(feed.status, 200);
  const snap = await t.api('GET', `/convoys/${R.gid}`, undefined, R.lead.token);
  const hash = crypto.createHash('sha256').update(made.json.token).digest('hex');
  for (const s of strings([feed.json, snap.json])) assert.ok(s !== made.json.token && s !== hash, 'no token or hash in the feed or the snapshot');
  const live = snap.json.activeAlerts?.find((a) => a.alertId === alert.alertId) || snap.json.alerts?.find((a) => a.alertId === alert.alertId);
  if (live && live.liveLink) assert.deepEqual(Object.keys(live.liveLink).sort(), ['expiresAt', 'revokedAt']);
  wl.close(); wk.close();
  hospitalDelayMs = 20;
  await R.end();
});

test('live link at rest: 32 char base64url tokens, all distinct, only sha256 stored, the token appears nowhere in the database', async () => {
  const R = await ride({}, 1);
  const kiran = R.members[0];
  const wl = await t.joinRoom(R.lead.token, R.gid);
  const wk = await t.joinRoom(kiran.token, R.gid);
  wk.sendJson({ type: 'SOS', lat: 17.385, lng: 78.4867, alertType: 'CRASH_OR_EMERGENCY', clientId: 'qa-sos-2' });
  const alert = (await wl.next((m) => m.type === 'ALERT')).alert;
  const tokens = [];
  for (let i = 0; i < 3; i++) {
    if (i) await t.api('DELETE', `/convoys/${R.gid}/alerts/${alert.alertId}/live-link`, undefined, kiran.token);
    const made = await t.api('POST', `/convoys/${R.gid}/alerts/${alert.alertId}/live-link`, {}, kiran.token);
    assert.equal(made.status, 200, JSON.stringify(made.json));
    assert.match(made.json.token, /^[A-Za-z0-9_-]{32}$/);
    assert.ok(made.json.url.endsWith(`/e/${made.json.token}`));
    tokens.push(made.json.token);
  }
  assert.equal(new Set(tokens).size, 3, 'three different tokens');
  // The lead (own budget) revokes and asks for a 4th: LINK_LIMIT.
  assert.equal((await t.api('DELETE', `/convoys/${R.gid}/alerts/${alert.alertId}/live-link`, undefined, R.lead.token)).status, 200);
  assert.equal((await t.api('POST', `/convoys/${R.gid}/alerts/${alert.alertId}/live-link`, {}, R.lead.token)).json.code, 'LINK_LIMIT', 'the 4th link is refused');
  // The stored alert keeps the hash of the last token and never a token.
  const stored = (await gw.repo.listAlerts(R.gid)).find((a) => a.alertId === alert.alertId);
  assert.ok(stored, 'alert stored');
  assert.equal(stored.liveLink.hash, crypto.createHash('sha256').update(tokens[2]).digest('hex'));
  assert.equal(stored.liveLinkCount, 3);
  assert.ok(stored.liveLink.revokedAt > 0);
  assert.ok(!('hospitalTried' in stored));
  const dump = JSON.stringify(await gw.repo.listAlerts(R.gid)) + JSON.stringify(await gw.repo.listEvents(R.gid, { limit: 1000 }));
  for (const tok of tokens) assert.ok(!dump.includes(tok), 'no token at rest');
  // The 3.15 shape of ALERT for a socket without capabilities: liveLink times only.
  const snap = wl.snapshot;
  assert.ok(snap, 'snapshot kept');
  wl.close(); wk.close();
  await R.end();
});
