'use strict';
/**
 * 3.55 arrival message (src/guardian_arrival.js + GuardianService + GuardianPush) and the
 * no-signal-ahead notice on guardian links (src/signal_ahead.js).
 */
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('events');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { GuardianService } = require('../src/guardians');
const { GuardianArrival, ARRIVED_KEEP_MS } = require('../src/guardian_arrival');
const { GuardianPush } = require('../src/guardian_push');
const { SignalAhead } = require('../src/signal_ahead');

const T = 1700000000000;

async function setup({ flags = {} } = {}) {
  const soda = new MemorySoda(), repo = new Repo(soda); await repo.migrate();
  await soda.insert('users', { userId: 'me', status: 'ACTIVE' });
  await soda.insert('users', { userId: 'other', status: 'ACTIVE' });
  const meta = await repo.createConvoyMeta({ groupId: 'g', tripStatus: 'STARTED',
    members: { me: { joinedAt: T - 1000, role: 'LEAD' }, other: { joinedAt: T - 1000 } } });
  const room = { groupId: 'g', meta, riders: new Map([
    ['me', { name: 'Me', lat: 17, lng: 78, speedKmh: 30, lastSeenEpochMs: T }],
    ['other', { name: 'Other', lat: 17.1, lng: 78.1, speedKmh: 30, lastSeenEpochMs: T }],
  ]), alerts: new Map() };
  let now = T;
  const convoys = new EventEmitter();
  convoys.rooms = new Map([['g', room]]);
  convoys.getRoom = async () => room;
  convoys.featureFlags = { isOn: (id) => flags[id] !== false };
  convoys._emit = (gid, type, payload) => convoys.emit('event', gid, { type, ...payload });
  convoys.signalAhead = new SignalAhead({ convoys, clock: () => now });
  const service = new GuardianService({ repo, convoys, clock: () => now });
  const arrival = new GuardianArrival({ convoys, repo, clock: () => now, logger: { warn() {} } }).attach();
  const create = (level = 'LIVE') => service.create('me', 'g', { level, acknowledged: true });
  const view = async (grant) => service.snapshot((await service.exchange(grant.token)).credential);
  return { soda, repo, room, meta, convoys, service, arrival, create, view,
    time: (v) => { now = v; }, now: () => now };
}

test('all riders arrived: guardians see "Arrived safely" once, no position, and the link expires', async () => {
  const t = await setup();
  const grant = await t.create();
  assert.ok((await t.view(grant)).position, 'tracking before arrival');
  t.time(T + 60000);
  // The listener attached by GuardianArrival handles the room event; wait for its store.
  await t.arrival.onEvent('g', { type: 'DESTINATION_ARRIVALS', allReachedAt: T + 60000 });
  const out = await t.view(grant);
  assert.equal(out.status, 'ARRIVED');
  assert.equal(out.arrivedAt, T + 60000);
  assert.equal(out.position, undefined, 'no tracking after arrival');
  assert.equal(out.observedAt, undefined);
  assert.equal(out.timeline.filter((e) => e.type === 'ARRIVED').length, 1);
  assert.equal(out.timeline.find((e) => e.type === 'ARRIVED').label, 'Arrived safely');
  assert.ok(out.expiresAt <= T + 60000 + ARRIVED_KEEP_MS);
  // The ride ends later: the arrival time stays the first one (sent once).
  t.time(T + 120000);
  await t.arrival.onEvent('g', { type: 'TRIP_STATUS', tripStatus: 'ENDED' });
  assert.equal((await t.repo.guardianArrival('g', 'me')).startedAt, T + 60000);
  // The rider's own timeline never shows the marker (stored under guardian:<groupId>).
  assert.equal((await t.repo.guardianEvents('g', 0)).filter((e) => e.type === 'ARRIVED').length, 0);
  // Link expiry.
  t.time(T + 60000 + ARRIVED_KEEP_MS);
  await assert.rejects(t.view(grant), { status: 410 });
});

test('normal end of ride sends the arrival; a system end or an open SOS does not', async () => {
  const t = await setup();
  await t.arrival.onEvent('g', { type: 'TRIP_STATUS', tripStatus: 'ENDED', system: true });
  assert.equal(await t.repo.guardianArrival('g', 'me'), null, 'abandoned / emptied ride is not "safe"');
  t.room.alerts.set('a1', { alertId: 'a1', userId: 'other', resolved: false, timestamp: T });
  await t.arrival.onEvent('g', { type: 'TRIP_STATUS', tripStatus: 'ENDED' });
  assert.ok(await t.repo.guardianArrival('g', 'me'));
  assert.equal(await t.repo.guardianArrival('g', 'other'), null, 'a rider with an open SOS never gets "Arrived safely"');
  // DESTINATION_ARRIVALS without everyone arrived is not an arrival.
  const u = await setup();
  await u.arrival.onEvent('g', { type: 'DESTINATION_ARRIVALS', allReachedAt: 0 });
  assert.equal(await u.repo.guardianArrival('g', 'me'), null);
});

test('an emergency after the arrival still shows; switch off writes nothing', async () => {
  const t = await setup();
  const grant = await t.create();
  await t.arrival.onEvent('g', { type: 'DESTINATION_ARRIVALS', allReachedAt: T });
  t.room.alerts.set('a2', { alertId: 'a2', userId: 'me', resolved: false, timestamp: T, lat: 17, lng: 78 });
  const out = await t.view(grant);
  assert.equal(out.status, 'EMERGENCY');
  assert.equal(out.emergency, true);
  const off = await setup({ flags: { arrivalMessage: false } });
  await off.arrival.onEvent('g', { type: 'DESTINATION_ARRIVALS', allReachedAt: T });
  assert.equal(await off.repo.guardianArrival('g', 'me'), null);
});

test('room events reach the module through ConvoyManager "event"', async () => {
  const t = await setup();
  t.convoys.emit('event', 'g', { type: 'DESTINATION_ARRIVALS', allReachedAt: T });
  for (let i = 0; i < 20 && !(await t.repo.guardianArrival('g', 'me')); i++) await new Promise((r) => setImmediate(r));
  assert.ok(await t.repo.guardianArrival('g', 'me'));
});

test('guardian web push says "arrived safely" once, without names', async () => {
  const repo = new Repo(new MemorySoda()); await repo.migrate();
  let now = T;
  const view = { tripStatus: 'STARTED', status: 'RIDING', emergency: false, level: 'LIVE', expiresAt: now + 86400000 };
  const service = { sessionGrant: async () => ({ grantId: 'g1' }), viewGrant: async () => view,
    ticket: async () => ({ credential: 'C'.repeat(32) }) };
  const sends = [];
  const push = new GuardianPush({ repo, service, publicKey: 'k', clock: () => now,
    send: async (sub, payload) => { sends.push(JSON.parse(payload)); } });
  await push.subscribe('cred', { endpoint: 'https://fcm.googleapis.com/x', keys: { p256dh: 'A'.repeat(87), auth: 'B'.repeat(22) } });
  await push.tick(); assert.equal(sends.length, 0);
  Object.assign(view, { status: 'ARRIVED', tripStatus: 'ENDED' });
  await push.tick(); now += 20000; await push.tick();
  assert.equal(sends.length, 1);
  assert.equal(sends[0].title, 'CoRoute: arrived safely');
  assert.ok(!/Me|Other/.test(sends[0].body));
});

test('no-signal ahead: the group and the guardian link get the notice; validated and rate limited', async () => {
  const t = await setup();
  const grant = await t.create();
  const seen = [];
  t.convoys.on('event', (gid, m) => { if (m.type === 'SIGNAL_AHEAD') seen.push(m); });
  const ws = { user: { userId: 'me' }, groupId: 'g' };
  assert.equal(t.convoys.signalAhead.handle(ws, { backAt: T + 10 }), null, 'backAt too soon');
  assert.equal(t.convoys.signalAhead.handle(ws, { backAt: T + 5 * 3600000 }), null, 'backAt too far');
  const n = t.convoys.signalAhead.handle(ws, { backAt: T + 40 * 60000, near: 'Rohtang <b>pass</b>' });
  assert.ok(n);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].near, 'Rohtang b pass /b');
  assert.equal(t.convoys.signalAhead.handle(ws, { backAt: T + 50 * 60000 }), null, 'one notice per cooldown');
  const out = await t.view(grant);
  assert.equal(out.signalAhead.backAt, T + 40 * 60000);
  assert.ok(out.position, 'last position stays visible');
  // EMERGENCY_ONLY links never get routine notices.
  const eo = await t.view(await t.create('EMERGENCY_ONLY'));
  assert.equal(eo.signalAhead, undefined);
  t.convoys.signalAhead.handle(ws, { clear: true });
  assert.equal((await t.view(grant)).signalAhead, undefined);
  assert.equal(seen[seen.length - 1].clear, true);
});
