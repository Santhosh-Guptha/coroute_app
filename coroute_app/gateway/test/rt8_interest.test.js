'use strict';
/**
 * Round 8 interest management (src/interest.js, Hub._flushInterest): in a room above WS_INTEREST_ABOVE sockets a rider
 * gets its nearest K riders, lead / sweeper / owner and riders in alert at full rate, everyone else at most every
 * WS_INTEREST_FAR_MS; alerts always reach everyone. Small thresholds here so a 8-rider room exercises it.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.WS_COALESCE_ABOVE = '3';
process.env.WS_COALESCE_MS = '100';
process.env.WS_INTEREST_ABOVE = '4';
process.env.WS_INTEREST_NEAR_K = '2';
process.env.WS_INTEREST_FAR_MS = '1500';
process.env.WS_INTEREST_RECOMPUTE_MS = '100';
process.env.WS_ALARMS_PER_10S = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');
const { Interest, interestConfig } = require('../src/interest');

let t;
before(async () => { t = await boot({ emergencyFetch: async () => { throw new Error('offline in tests'); } }); });
after(async () => { await t.gw.shutdown(); });

test('Interest: nearest K by distance, specials, no own fix = everyone', () => {
  const cfg = { ...interestConfig({}), nearK: 2, recomputeMs: 1000 };
  const it = new Interest(cfg);
  const room = {
    meta: { createdByUserId: 'own' },
    riders: new Map([
      ['me', { userId: 'me', lat: 17, lng: 78 }], ['n1', { userId: 'n1', lat: 17.001, lng: 78 }], ['n2', { userId: 'n2', lat: 17, lng: 78.002 }],
      ['f1', { userId: 'f1', lat: 17.5, lng: 78.5 }], ['sw', { userId: 'sw', lat: 18, lng: 79, role: 'SWEEPER' }], ['own', { userId: 'own', lat: 16, lng: 77, role: 'LEAD' }],
      ['nofix', { userId: 'nofix', lat: 0, lng: 0 }],
    ]),
    alerts: new Map([['A1', { alertId: 'A1', userId: 'f1', resolved: false }], ['A2', { alertId: 'A2', userId: 'n1', resolved: true }]]),
  };
  const cache = {};
  assert.deepEqual([...it.near(room, 'me', cache, 0)].sort(), ['n1', 'n2']);
  assert.deepEqual([...it.special(room)].sort(), ['f1', 'own', 'sw']);
  room.riders.get('me').lat = 17.5; room.riders.get('me').lng = 78.5;
  assert.deepEqual([...it.near(room, 'me', cache, 500)].sort(), ['n1', 'n2'], 'cached for recomputeMs');
  assert.ok(it.near(room, 'me', cache, 1500).has('f1'), 'recomputed');
  assert.equal(it.near(room, 'nofix', {}, 0), null, 'unknown own position: everyone at full rate');
  assert.equal(it.active(4), false); assert.equal(new Interest({ ...cfg, above: 4 }).active(5), true);
  assert.equal(new Interest({ ...cfg, enabled: false, above: 4 }).active(50), false);
});

async function bigRide(count) {
  const riders = [];
  for (let i = 0; i < count; i++) riders.push(await t.register(`Int Rider ${i}`, `int8-${i}@coroute.test`));
  const c = (await t.api('POST', '/convoys', { name: 'Interest ride' }, riders[0].token)).json;
  for (const r of riders.slice(1)) assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, r.token)).status, 200);
  const ws = [];
  for (const r of riders) {
    const w = await t.connect(r.token);
    await w.next((m) => m.type === 'HELLO');
    w.sendJson({ type: 'JOIN', groupId: c.groupId, caps: ['net1', 'posbatch1'] });
    await w.next((m) => m.type === 'SNAPSHOT');
    ws.push(w);
  }
  return { riders, ws, gid: c.groupId };
}

const seenIn = (w, uid) => w.inbox.filter((m) => (m.type === 'RIDER_UPDATES' && m.riders.some((r) => r.userId === uid)) || (m.type === 'RIDER_UPDATE' && m.rider && m.rider.userId === uid)).length;

test('a big ride: near riders and the lead at full rate, far riders every WS_INTEREST_FAR_MS; an SOS reaches everyone and lifts its rider to full rate', async () => {
  // 0 = trip owner / LEAD (far), 1 = observer, 2..3 near the observer, 4..7 far away.
  const R = await bigRide(8);
  const spot = (i, s) => {
    if (i === 1) return [17.0, 78.0 + s * 1e-6];
    if (i === 2) return [17.0005, 78.0 + s * 1e-6];
    if (i === 3) return [17.0, 78.0007 + s * 1e-6];
    if (i === 0) return [17.3, 78.3 + s * 1e-6];
    return [17.2 + i / 100, 78.2 + s * 1e-6];
  };
  const send = (s) => R.ws.forEach((w, i) => { const [lat, lng] = spot(i, s); w.sendJson({ type: 'TELEMETRY', lat, lng, speedKmh: 40 }); });
  send(0);
  await sleep(400); // positions known, near sets computed
  const obs = R.ws[1];
  obs.inbox.length = 0;
  const heldBefore = t.gw.hub.stats.interestHeld;
  // 2.6 s of positions every 350 ms (under the 3/s telemetry budget).
  for (let s = 1; s <= 8; s++) { send(s); await sleep(350); }
  await sleep(200);
  const uid = (i) => R.riders[i].user.userId;
  const near2 = seenIn(obs, uid(2)); const near3 = seenIn(obs, uid(3)); const lead = seenIn(obs, uid(0));
  const far = [4, 5, 6, 7].map((i) => seenIn(obs, uid(i)));
  assert.ok(near2 >= 6 && near3 >= 6, `near riders at full rate: ${near2}, ${near3}`);
  assert.ok(lead >= 6, `the lead at full rate: ${lead}`);
  for (const f of far) assert.ok(f >= 1 && f <= 3, `far riders only every 1.5 s: ${far}`);
  assert.ok(t.gw.hub.stats.interestHeld > heldBefore);

  // Far rider 5 raises an SOS: every socket gets the ALERT at once, and rider 5 is now at full rate for everyone.
  R.ws[5].sendJson({ type: 'SOS', lat: 17.25, lng: 78.2, clientId: 'int-sos-1' });
  const alerts = await Promise.all(R.ws.filter((_, i) => i !== 5).map((w) => w.next((m) => m.type === 'ALERT', 2000)));
  assert.equal(new Set(alerts.map((a) => a.alert.alertId)).size, 1, 'one alert, delivered to all 7 others');
  obs.inbox.length = 0;
  for (let s = 9; s <= 14; s++) { send(s); await sleep(350); }
  await sleep(200);
  assert.ok(seenIn(obs, uid(5)) >= 4, `rider in alert at full rate: ${seenIn(obs, uid(5))}`);
  assert.ok(seenIn(obs, uid(6)) <= 3, 'other far riders still reduced');

  // Withheld positions arrive at the next far refresh even when nobody sends again.
  obs.inbox.length = 0;
  send(15);
  await sleep(100);
  await sleep(1700);
  assert.ok(seenIn(obs, uid(7)) >= 1, 'the far rider\'s last position came with the refresh');
  for (const w of R.ws) w.close();
});
