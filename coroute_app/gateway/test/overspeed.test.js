'use strict';
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const { test, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { buildTripReport } = require('../src/report');

const T0 = Date.UTC(2026, 9, 5, 4, 0, 0);
let gw;
after(async () => { if (gw) await gw.shutdown(); mock.timers.reset(); });

test('group speed limit: spikes ignored, each episode logged per rider, announced once', async () => {
  mock.timers.enable({ apis: ['Date'], now: T0 });
  gw = await createApp({ soda: new MemorySoda(), logger: { info() {}, warn() {}, error() {} } });
  const a = await gw.auth.register({ name: 'Arun', email: 'arun@coroute.test', password: 'Password#123', phone: '9999999999' });
  const b = await gw.auth.register({ name: 'Bindu', email: 'bindu@coroute.test', password: 'Password#123', phone: '9999999999' });
  const ua = { userId: a.user.userId, name: 'Arun', role: 'RIDER' };
  const ub = { userId: b.user.userId, name: 'Bindu', role: 'RIDER' };
  const snap = await gw.convoys.createConvoy(ua, { name: 'Speed test', speedLimitKmh: 80 });
  assert.equal(snap.speedLimitKmh, 80);
  await gw.convoys.joinByCode(ub, snap.joinCode);
  const room = await gw.convoys.getRoom(snap.groupId);

  let t = T0, lat = 17.0;
  const step = async (u, kmh, secs = 5) => {
    t += secs * 1000; lat += 0.0003;
    mock.timers.setTime(t);
    gw.convoys.patchRider(room, u.userId, { lat, lng: 78.0, speedKmh: kmh }, { emit: false });
    await gw.timeline.idle();
  };
  const over = async () => (await gw.repo.listEvents(snap.groupId, { limit: 500 })).filter((e) => e.type === 'OVERSPEED');

  // One GPS spike, then back to normal: nothing logged.
  await step(ua, 70); await step(ua, 120); await step(ua, 70); await step(ua, 70);
  assert.equal((await over()).length, 0, 'a single spike is not an episode');

  // Within the tolerance (80 + 2) is not over the limit.
  await step(ua, 82); await step(ua, 82); await step(ua, 82);
  assert.equal((await over()).length, 0);

  // Arun holds 95-104 km/h for 30 s: one open episode, announced.
  for (const v of [95, 98, 104, 97, 96, 95]) await step(ua, v);
  let list = await over();
  assert.equal(list.length, 1);
  assert.equal(list[0].open, true);
  assert.equal(list[0].userId, ua.userId);
  assert.equal(list[0].data.limitKmh, 80);
  assert.equal(list[0].data.notify, true);
  assert.equal(list[0].startedAt, T0 + 40000, 'starts at the first fix over the limit');

  // Slows to 70 for 25 s: closed with its duration and top speed.
  for (let i = 0; i < 5; i++) await step(ua, 70);
  list = await over();
  assert.equal(list[0].open, false);
  assert.equal(list[0].data.maxKmh, 104);
  assert.equal(list[0].endedAt, T0 + 70000, 'ends when the rider first came back under the limit');
  assert.equal(list[0].durationMs, 30000);

  // Speeds again 2 min later: logged, but not announced a second time.
  await step(ua, 70, 120);
  for (const v of [90, 92, 91, 90]) await step(ua, v);
  list = await over();
  assert.equal(list.length, 2);
  assert.equal(list[1].data.notify, false);
  assert.equal(list[1].data.count, 2);

  // Bindu is a different rider: her first episode is announced.
  for (const v of [100, 100, 100, 100]) await step(ub, v);
  list = await over();
  const bindu = list.filter((e) => e.userId === ub.userId);
  assert.equal(bindu.length, 1);
  assert.equal(bindu[0].data.notify, true);

  // Arun slows and parks: the tick ends the open episode without new fixes.
  await step(ua, 30);
  t += 30000; mock.timers.setTime(t);
  await gw.timeline.tick(); await gw.timeline.idle();
  assert.equal((await over()).filter((e) => e.userId === ua.userId && e.open).length, 0);

  // After a quiet 10+ minutes Arun's next episode is announced again.
  await step(ua, 60, 660);
  for (const v of [99, 99, 99, 99]) await step(ua, v);
  list = (await over()).filter((e) => e.userId === ua.userId);
  assert.equal(list.length, 3);
  assert.equal(list[2].data.notify, true);

  // The lead switches the limit off: open episodes end.
  await gw.convoys.updateConfig(snap.groupId, ua, { speedLimitKmh: 0 });
  await step(ua, 99); await step(ub, 99);
  assert.equal((await over()).filter((e) => e.open).length, 0);

  // Report: per rider count, time over and top speed.
  const events = await gw.repo.listEvents(snap.groupId, { limit: 500 });
  const meta = (await gw.convoys.getRoom(snap.groupId)).meta;
  const { report } = buildTripReport({ meta: { ...meta, speedLimitKmh: 80 }, tracksByUser: new Map(), events });
  const ra = report.members.find((m) => m.userId === ua.userId);
  assert.equal(ra.overspeedCount, 3);
  assert.equal(ra.overspeedMaxKmh, 104);
  assert.ok(ra.overspeedMs >= 30000);
  assert.equal(report.group.overspeedCount, 4);
  assert.equal(report.group.speedLimitKmh, 80);
});

test('speed limit setting is clamped and lead-only', async () => {
  const c = await gw.auth.register({ name: 'Chitra', email: 'chitra@coroute.test', password: 'Password#123', phone: '9999999999' });
  const d = await gw.auth.register({ name: 'Dev', email: 'dev@coroute.test', password: 'Password#123', phone: '9999999999' });
  const uc = { userId: c.user.userId, name: 'Chitra', role: 'RIDER' };
  const ud = { userId: d.user.userId, name: 'Dev', role: 'RIDER' };
  const snap = await gw.convoys.createConvoy(uc, { name: 'Clamp', speedLimitKmh: 5 });
  assert.equal(snap.speedLimitKmh, 20);
  await gw.convoys.joinByCode(ud, snap.joinCode);
  await assert.rejects(gw.convoys.updateConfig(snap.groupId, ud, { speedLimitKmh: 60 }));
  await gw.convoys.updateConfig(snap.groupId, uc, { speedLimitKmh: 999 });
  assert.equal((await gw.convoys.getRoom(snap.groupId)).meta.speedLimitKmh, 200);
});
