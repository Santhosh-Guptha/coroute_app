'use strict';
/**
 * Round 8 compact position frames 'pos2' (src/pos2.js): codec round trips, optional deltas, sizes against the JSON
 * frames, and on a live gateway: the feature in HELLO, P2 in, RU2 out to 'pos2' sockets, old apps unchanged
 * (TELEMETRY in, RIDER_UPDATE / RIDER_UPDATES out), mixed rooms, batches in larger rooms.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.WS_POS_MIN_MS = '0';
process.env.WS_COALESCE_ABOVE = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const P = require('../src/pos2');
const { publicRider } = require('../src/convoys');

let t;
before(async () => { t = await boot(); });
after(async () => { await t.gw.shutdown(); });

// ------------------------------------------------------------------ codec
test('P2 round trip: integers on the wire, values within 1.1 m / 0.2 km/h', () => {
  const now = 1_800_000_000_000;
  const tel = { lat: 17.385044, lng: 78.486671, speedKmh: 63.4, heading: 271.6, batteryLevel: 77, isCharging: true, statusReason: 'FUEL', statusMessage: 'Tank', stoppedSince: now - 42000, fuelEstimate: { usableKm: 120, confirmedAt: now - 60000 }, fatigueLevel: 2 };
  const f = P.encodeP2(tel, 7, now);
  for (const k of ['q', 'a', 'o', 'v', 'h', 'b', 'c', 'ss', 'fl']) assert.ok(Number.isInteger(f[k]), k);
  const st = {};
  const { patch } = P.decodeP2(f, st, now);
  assert.ok(Math.abs(patch.lat - tel.lat) < 1e-5 && Math.abs(patch.lng - tel.lng) < 1e-5);
  assert.ok(Math.abs(patch.speedKmh - tel.speedKmh) <= 0.2);
  assert.equal(patch.heading, 272);
  assert.equal(patch.batteryLevel, 77);
  assert.equal(patch.isCharging, true);
  assert.equal(patch.statusReason, 'FUEL');
  assert.equal(patch.stoppedSince, now - 42000);
  assert.deepEqual(patch.fuelEstimate, { usableKm: 120, confirmedAt: now - 60000 });
  assert.equal(patch.fatigueLevel, 2);
  assert.deepEqual(st, { k: 7, a: f.a, o: f.o }, 'the full fix becomes the delta base');
  // Full-state semantics: what is not in the frame is cleared, like the app's TELEMETRY.
  const bare = P.decodeP2({ t: 'P2', q: 8, a: 1738504, o: 7848667 }, {}, now).patch;
  assert.equal(bare.statusReason, ''); assert.equal(bare.isCharging, false); assert.equal(bare.stoppedSince, 0); assert.equal(bare.fuelEstimate, null);
  assert.equal(bare.batteryLevel, undefined, 'a missing battery stays as it was');
});

test('P2 deltas: applied against the last full fix; a delta without its base is ignored, never misplaced', () => {
  const st = {};
  const key = P.encodeP2({ lat: 17.4, lng: 78.4 }, 10);
  P.decodeP2(key, st);
  const d = P.encodeP2Delta({ lat: 17.40012, lng: 78.39991 }, 11, { q: 10, a: key.a, o: key.o });
  assert.equal(d.a, undefined); assert.equal(d.k, 10);
  const r = P.decodeP2(d, st).patch;
  assert.ok(Math.abs(r.lat - 17.40012) < 1e-6 && Math.abs(r.lng - 78.39991) < 1e-6);
  assert.deepEqual(P.decodeP2({ ...d, k: 9 }, st), { miss: true }, 'wrong base');
  assert.deepEqual(P.decodeP2(d, {}), { miss: true }, 'no base yet (fresh socket)');
  assert.equal(P.decodeP2({ t: 'P2', a: 99999999, o: 1 }, {}), null, 'out of range');
  assert.equal(P.decodeP2({ t: 'P2', a: 1.5, o: 1 }, {}), null, 'not an integer');
  assert.equal(P.decodeP2({ t: 'P2' }, {}), null);
});

test('RU2 entry: telemetry only, merged into the known rider by the app; ~10x smaller than RIDER_UPDATE', () => {
  const ts = Date.now();
  const rider = publicRider({ userId: 'usr_abc123', name: 'Asha Rider', lat: 17.385044, lng: 78.486671, speedKmh: 58.3, heading: 90, batteryLevel: 64, role: 'PACK',
    phone: '+919876543210', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact', vehicleNo: 'TS09AB1234', vehicleModel: 'Classic 350', lastSeenEpochMs: ts - 400 });
  const entry = P.riderEntry(rider, ts);
  const e = JSON.parse(entry);
  assert.equal(e.u, 'usr_abc123');
  assert.equal(e.t, ts - 400, 'last seen in server time (never relative: entries can go out in a later flush)');
  for (const k of ['name', 'phone', 'emergencyContact', 'vehicleNo', 'n', 'p']) assert.equal(e[k], undefined, `${k} never in RU2`);
  const merged = P.applyEntry({ ...rider, lat: 0, lng: 0 }, e, ts);
  assert.equal(merged.name, 'Asha Rider', 'profile kept from the known rider');
  assert.ok(Math.abs(merged.lat - 17.385044) < 1e-5);
  assert.equal(merged.lastSeenEpochMs, ts - 400);
  const legacy = `{"type":"RIDER_UPDATE","rider":${JSON.stringify(rider)},"ts":${ts}}`;
  const compact = P.ru2Frame([entry], ts);
  assert.ok(compact.length * 4 < legacy.length, `RU2 ${compact.length} B vs RIDER_UPDATE ${legacy.length} B`);
  const tel = JSON.stringify({ type: 'TELEMETRY', fuelEstimate: null, lat: 17.385044, lng: 78.486671, speedKmh: 58.3, heading: 90, batteryLevel: 64, isCharging: false, statusReason: '', statusMessage: '', stoppedSince: 0, trackingConfidence: 'gpsFix', isCoasting: false });
  const p2 = JSON.stringify(P.encodeP2({ lat: 17.385044, lng: 78.486671, speedKmh: 58.3, heading: 90, batteryLevel: 64 }, 1234));
  assert.ok(p2.length * 3 < tel.length, `P2 ${p2.length} B vs TELEMETRY ${tel.length} B`);
});

// ------------------------------------------------------------------ live gateway
let n = 0;
async function ride(count) {
  n++;
  const riders = [];
  for (let i = 0; i < count; i++) riders.push(await t.register(`P2 Rider ${n}${i}`, `p2-${n}-${i}@coroute.test`));
  const c = (await t.api('POST', '/convoys', { name: `P2 ride ${n}` }, riders[0].token)).json;
  for (const r of riders.slice(1)) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, r.token)).status, 200);
  return { riders, gid: c.groupId };
}
async function join(token, gid, caps) {
  const ws = await t.connect(token);
  const hello = await ws.next((m) => m.type === 'HELLO');
  ws.features = hello.features;
  ws.sendJson({ type: 'JOIN', groupId: gid, ...(caps ? { caps } : {}) });
  await ws.next((m) => m.type === 'SNAPSHOT');
  return ws;
}
const ru2Of = (ws, uid) => ws.next((m) => m.type === 'RU2' && m.r.some((e) => e.u === uid));

test('HELLO lists pos2; P2 from a new app reaches a pos2 app as RU2 and an old app as RIDER_UPDATE (JSON as before)', async () => {
  const R = await ride(3);
  const [a, b, c] = R.riders;
  const wa = await join(a.token, R.gid, ['net1', 'posbatch1', 'pos2']);
  assert.ok(wa.features.includes('pos2'));
  const wb = await join(b.token, R.gid, ['net1', 'posbatch1', 'pos2']);
  const wc = await join(c.token, R.gid, ['net1', 'posbatch1']); // an older build: no pos2
  wa.send(JSON.stringify(P.encodeP2({ lat: 17.41234, lng: 78.45678, speedKmh: 72, heading: 45, batteryLevel: 81 }, 1)));
  const frame = await ru2Of(wb, a.user.userId);
  const e = frame.r.find((x) => x.u === a.user.userId);
  assert.equal(e.a, 1741234); assert.equal(e.o, 7845678); assert.equal(e.h, 45); assert.equal(e.b, 81);
  assert.ok(Math.abs(e.v * 0.36 - 72) < 0.2);
  const legacy = await wc.next((m) => m.type === 'RIDER_UPDATE' && m.rider.userId === a.user.userId);
  assert.equal(legacy.rider.lat, 17.41234);
  assert.equal(legacy.rider.name, a.user.name, 'old apps keep the full rider JSON');
  assert.equal(wc.inbox.filter((m) => m.type === 'RU2').length, 0, 'never an RU2 to an app without the cap');
  // An old app's TELEMETRY reaches the new app as RU2.
  wc.sendJson({ type: 'TELEMETRY', lat: 17.5, lng: 78.5, speedKmh: 30, heading: 180, batteryLevel: 50 });
  const f2 = await ru2Of(wa, c.user.userId);
  assert.equal(f2.r.find((x) => x.u === c.user.userId).a, 1750000);
  // Deltas against the last full fix.
  wa.send(JSON.stringify(P.encodeP2Delta({ lat: 17.41334, lng: 78.45578, speedKmh: 72, heading: 45, batteryLevel: 81 }, 2, { q: 1, a: 1741234, o: 7845678 })));
  const f3 = await wb.next((m) => m.type === 'RU2' && m.r.some((x) => x.u === a.user.userId && x.a === 1741334));
  assert.equal(f3.r.find((x) => x.u === a.user.userId).o, 7845578);
  // A delta with an unknown base never moves the rider.
  const missBefore = t.gw.hub.stats.pos2Miss;
  wa.send(JSON.stringify({ t: 'P2', q: 3, k: 99, da: 5000, do: 5000, v: 0, h: 0, b: 81 }));
  await sleep(150);
  assert.equal(t.gw.hub.stats.pos2Miss, missBefore + 1);
  const room = t.gw.convoys.rooms.get(R.gid);
  assert.ok(Math.abs(room.riders.get(a.user.userId).lat - 17.41334) < 1e-9);
  // Invalid P2: ERROR 400, nothing applied.
  wa.send(JSON.stringify({ t: 'P2', q: 4, a: 'x', o: 1 }));
  assert.equal((await wa.next((m) => m.type === 'ERROR')).code, 400);
  for (const w of [wa, wb, wc]) w.close();
});

test('mixed caps in a coalesced room: pos2 sockets get one RU2 batch per flush, posbatch1 sockets RIDER_UPDATES', async () => {
  process.env.WS_COALESCE_ABOVE = '20'; // fixed at load; this room stays small: per-rider window path covered above
  const R = await ride(4);
  const ws = [];
  for (let i = 0; i < 4; i++) ws.push(await join(R.riders[i].token, R.gid, i < 2 ? ['posbatch1', 'pos2'] : ['posbatch1']));
  const hub = t.gw.hub;
  // Force the flush path for this room: queue three riders' positions and flush once.
  const room = t.gw.convoys.rooms.get(R.gid);
  for (let i = 1; i < 4; i++) t.gw.convoys.patchRider(room, R.riders[i].user.userId, { lat: 17 + i / 100, lng: 78 + i / 100 }, { emit: false });
  hub.posPending.set(R.gid, new Map());
  for (let i = 1; i < 4; i++) {
    const rider = room.riders.get(R.riders[i].user.userId);
    const pr = publicRider(rider); const ts = Date.now();
    hub.posPending.get(R.gid).set(rider.userId, { msg: `{"type":"RIDER_UPDATE","rider":${JSON.stringify(pr)},"ts":${ts}}`, rj: JSON.stringify(pr), p2: P.riderEntry(pr, ts), ts });
  }
  const frames = hub.stats.pos2Frames;
  hub._flushPositions(R.gid);
  const b0 = await ws[0].next((m) => m.type === 'RU2');
  assert.equal(b0.r.length, 3, 'rider 0 is not in the batch: the shared full RU2 frame');
  const b1 = await ws[1].next((m) => m.type === 'RU2');
  assert.equal(b1.r.length, 2, 'its own position left out');
  const l2 = await ws[2].next((m) => m.type === 'RIDER_UPDATES');
  assert.equal(l2.riders.length, 2);
  assert.ok(hub.stats.pos2Frames >= frames + 2);
  for (const w of ws) w.close();
});

test('ALERT frames are never compacted: an SOS reaches pos2 and old apps as the same ALERT JSON', async () => {
  const R = await ride(3);
  const wa = await join(R.riders[0].token, R.gid, ['net1', 'posbatch1', 'pos2']);
  const wb = await join(R.riders[1].token, R.gid, ['net1', 'posbatch1', 'pos2']);
  const wc = await join(R.riders[2].token, R.gid, ['net1']);
  wa.sendJson({ type: 'SOS', lat: 17.4, lng: 78.4, clientId: 'p2-sos-1' });
  const x = await wb.next((m) => m.type === 'ALERT');
  const y = await wc.next((m) => m.type === 'ALERT');
  assert.equal(x.alert.alertId, y.alert.alertId);
  assert.equal(x.alert.userName, y.alert.userName);
  for (const w of [wa, wb, wc]) w.close();
});
