'use strict';
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { GuardianService } = require('../src/guardians');
const T = 1700000000000;
async function setup() {
  const soda = new MemorySoda(), repo = new Repo(soda); await repo.migrate();
  const userKey = await soda.insert('users', { userId: 'me', status: 'ACTIVE' });
  let meta = await repo.createConvoyMeta({ groupId: 'g', tripStatus: 'STARTED',
    members: { me: { joinedAt: T - 1000, role: 'LEAD' }, other: { joinedAt: T - 1000 } }, name: 'SECRET GROUP', destinationName: 'SECRET DESTINATION' });
  const room = { meta, riders: new Map([['me', { name: 'Me', lat: 17, lng: 78, speedKmh: 30, lastSeenEpochMs: T,
    phone: 'SECRET PHONE', fuelEstimate: { usableKm: 20 }, medical: 'SECRET MEDICAL' }], ['other', { name: 'SECRET OTHER' }]]), alerts: new Map() };
  let now = T;
  const service = new GuardianService({ repo, convoys: { getRoom: async () => room }, clock: () => now });
  const create = (level = 'LIVE', extra = {}) => service.create('me', 'g', { level, acknowledged: true, ...extra });
  const view = async (grant) => service.snapshot((await service.exchange(grant.token)).credential);
  const save = async (change) => { Object.assign(meta, change); await repo.saveConvoyMeta(meta); };
  return { soda, repo, service, room, meta, userKey, create, view, save, time: (value) => { now = value; } };
}
test('credentials are hashed and observers never enter the rider roster', async () => {
  const t = await setup(), grant = await t.create(), session = await t.service.exchange(grant.token);
  assert.equal(grant.token.length, 32); assert.equal(t.room.riders.size, 2);
  assert.ok((await t.service.snapshot(session.credential)).position);
  const stored = JSON.stringify([...t.soda.collections.values()].map((m) => [...m.values()]));
  assert.ok(!stored.includes(grant.token)); assert.ok(!stored.includes(session.credential));
  const listed = JSON.stringify(await t.service.list('me', 'g'));
  assert.ok(!listed.includes('tokenHash')); assert.ok(!listed.includes(grant.token));
});
test('personal LIVE exposes no peer, contact, fuel, destination or medical fields', async () => {
  const t = await setup(); const out = await t.view(await t.create());
  assert.deepEqual(Object.keys(out.position).sort(), ['lat','lng','observedAt','stale']);
  assert.ok(!JSON.stringify(out).includes('SECRET')); assert.ok(!JSON.stringify(out).includes('fuel'));
});
test('BASIC omits exact location even during own emergency', async () => {
  const t = await setup(); t.room.alerts.set('a', { userId: 'me', lat: 17, lng: 78, timestamp: T, source: 'CRASH_AUTO', medical: 'SECRET' });
  const out = await t.view(await t.create('BASIC'));
  assert.equal(out.emergency, true); assert.equal(out.position, undefined);
  assert.equal(out.alerts[0].position, undefined); assert.equal(out.alerts[0].type, 'POSSIBLE_ACCIDENT');
});
test('emergency-only hides routine identity and unrelated incidents', async () => {
  const t = await setup(); t.room.alerts.set('other', { userId: 'other', timestamp: T, lat: 18, lng: 79 });
  const grant = await t.create('EMERGENCY_ONLY');
  assert.equal((await t.view(grant)).name, undefined);
  t.room.alerts.set('own', { userId: 'me', timestamp: T, lat: 17, lng: 78 });
  const out = await t.view(grant); assert.equal(out.alerts.length, 1); assert.ok(out.alerts[0].position);
  t.room.alerts.get('own').resolved = true;
  assert.equal((await t.view(grant)).name, undefined);
});
test('group scope, impersonation, contacts and unacknowledged access are rejected', async () => {
  const t = await setup();
  for (const extra of [{ subject: 'GROUP' }, { subjectId: 'other' }, { contacts: true }, { acknowledged: false }, { level: 'ADMIN' }, { pin: 'abc' }]) {
    await assert.rejects(t.create('LIVE', extra), { status: 400 });
  }
  await assert.rejects(t.service.create('stranger', 'g', { level: 'LIVE', acknowledged: true }), { status: 403 });
});
test('revocation persists across service instances and rejects existing sessions', async () => {
  const t = await setup(), g = await t.create(), session = await t.service.exchange(g.token);
  await assert.rejects(t.service.revoke('other', g.grantId), { status: 404 });
  await t.service.revoke('me', g.grantId); await t.service.revoke('me', g.grantId);
  const restarted = new GuardianService({ repo: t.repo, convoys: { getRoom: async () => t.room }, clock: () => T });
  await assert.rejects(restarted.exchange(g.token), { status: 410 });
  await assert.rejects(restarted.snapshot(session.credential), { status: 410 });
});
test('leave and rejoin cannot resurrect a personal grant', async () => {
  const t = await setup(), g = await t.create();
  await t.save({ members: { me: { joinedAt: T - 1000, leftAt: T } } });
  await assert.rejects(t.view(g), { status: 410 });
  await t.save({ members: { me: { joinedAt: T + 1 } } });
  await assert.rejects(t.view(g), { status: 410 });
});
test('blocked and deleted accounts fail closed', async () => {
  const t = await setup(), g = await t.create();
  await t.soda.replace('users', t.userKey, { userId: 'me', status: 'BLOCKED' });
  await assert.rejects(t.view(g), { status: 410 });
  await t.soda.remove('users', t.userKey); await assert.rejects(t.view(g), { status: 410 });
});
test('absolute expiration and session expiration use exact boundaries', async () => {
  const t = await setup(), g = await t.create('LIVE', { expiresAt: T + 5000 });
  const s = await t.service.exchange(g.token); assert.equal(s.expiresAt, T + 5000);
  t.time(T + 5000); await assert.rejects(t.view(g), { status: 410 });
  await assert.rejects(t.service.snapshot(s.credential), { status: 410 });
});
test('before start and after end have no position or inferred safe arrival', async () => {
  const t = await setup(), g = await t.create();
  await t.save({ tripStatus: 'PLANNING' }); assert.equal((await t.view(g)).status, 'WAITING_FOR_START');
  await t.save({ tripStatus: 'ENDED', endedAtEpochMs: T });
  const out = await t.view(g); assert.equal(out.status, 'RIDE_ENDED'); assert.equal(out.position, undefined);
  t.time(T + 6 * 3600000); await assert.rejects(t.view(g), { status: 410 });
});
test('invalid/future positions are hidden and old locations remain explicitly stale', async () => {
  const t = await setup(), g = await t.create(), rider = t.room.riders.get('me');
  rider.lastSeenEpochMs = T - 120000;
  assert.equal((await t.view(g)).position.stale, true);
  rider.lastSeenEpochMs = T + 1; assert.equal((await t.view(g)).position, undefined);
  rider.lastSeenEpochMs = T; rider.lat = Infinity;
  assert.equal((await t.view(g)).position, undefined);
});
test('persistence failure issues neither a grant nor a session', async () => {
  const t = await setup(); const save = t.repo.createGuardianGrant;
  t.repo.createGuardianGrant = async () => { throw new Error('storage down'); };
  await assert.rejects(t.create(), /storage down/); t.repo.createGuardianGrant = save;
  const g = await t.create(); t.repo.createGuardianSession = async () => { throw new Error('storage down'); };
  await assert.rejects(t.service.exchange(g.token), /storage down/);
});
test('revocation failure is not acknowledged and read failures do not fall back to cached authorization', async () => {
  const t = await setup(), g = await t.create();
  t.repo.revokeGuardianGrant = async () => { throw new Error('storage down'); };
  await assert.rejects(t.service.revoke('me', g.grantId), /storage down/);
  t.repo.guardianRevoked = async () => { throw new Error('storage down'); };
  await assert.rejects(t.view(g), /storage down/);
});
test('malformed credentials and invalid expiration are rejected', async () => {
  const t = await setup();
  for (const value of [null, '', 'x', {}, 'A'.repeat(33)]) await assert.rejects(t.service.exchange(value), { status: 410 });
  for (const expiresAt of [T, T - 1, Infinity, T + 15 * 86400000, 'tomorrow']) await assert.rejects(t.create('LIVE', { expiresAt }), { status: 400 });
});
test('retention removes expired access records including revocation tombstones', async () => {
  const t = await setup(), g = await t.create('LIVE', { expiresAt: T + 1000 });
  await t.service.exchange(g.token); await t.service.revoke('me', g.grantId);
  assert.equal(await t.repo.purgeGuardianAccess(T + 1001), 3);
  await assert.rejects(t.view(g), { status: 410 });
});

test('group sharing includes only pinned consent and withdrawal removes a rider immediately', async () => {
  const t = await setup();
  await t.soda.insert('users', { userId: 'other', status: 'ACTIVE' });
  await t.service.setConsent('me', 'g', true);
  const g = await t.create('LIVE', { subject: 'GROUP' });
  let out = await t.view(g); assert.equal(out.scope, 'GROUP'); assert.equal(out.riders.length, 1);
  assert.ok(!JSON.stringify(out).includes('SECRET OTHER'));
  await t.service.setConsent('other', 'g', true);
  out = await t.view(g); assert.equal(out.riders.length, 1, 'later consent never broadens an old grant');
  t.time(T + 1); await t.service.setConsent('me', 'g', false);
  assert.equal((await t.view(g)).riders.length, 0);
  t.time(T + 2); await t.service.setConsent('me', 'g', true);
  assert.equal((await t.view(g)).riders.length, 0, 'reconsent requires a new grant');
});
test('group BASIC aggregates without individual data and loss of lead authority ends access', async () => {
  const t = await setup(); await t.service.setConsent('me', 'g', true);
  const g = await t.create('BASIC', { subject: 'GROUP' });
  const out = await t.view(g); assert.equal(out.summary.riding, 1); assert.equal(out.riders, undefined);
  await t.save({ members: { me: { joinedAt: T - 1000, role: 'PACK' } } });
  await assert.rejects(t.view(g), { status: 410 });
});

test('PIN is hashed, never listed, and is required before a session is issued', async () => {
  const t = await setup(), g = await t.create('LIVE', { pin: '458921' });
  await assert.rejects(t.service.exchange(g.token), { code: 'GUARDIAN_PIN_REQUIRED' });
  await assert.rejects(t.service.exchange(g.token, '000000'), { code: 'GUARDIAN_PIN_REQUIRED' });
  const session = await t.service.exchange(g.token, '458921');
  assert.equal((await t.service.snapshot(session.credential)).scope, 'PERSONAL');
  const row = await t.repo.guardianGrant({ grantId: g.grantId });
  assert.ok(!JSON.stringify(row).includes('458921'));
  assert.ok(!JSON.stringify(await t.service.list('me', 'g')).includes('pinHash'));
});


test('convoy deletion clears observer credentials and leaves other rides intact', async () => {
  const t = await setup(), g = await t.create(), session = await t.service.exchange(g.token);
  await t.service.setConsent('me', 'g', true);
  await t.service.pause('me', g.grantId, true);
  await t.repo.saveGuardianSubscription({ subscriptionId: 'sub', grantId: g.grantId, expiresAt: T + 1000 });
  await t.repo.enqueueGuardianJob({ jobId: 'job', grantId: g.grantId, state: 'PENDING' });
  await t.repo.revokeGuardianGrant({ grantId: 'sub', expiresAt: T + 1000 });
  await t.repo.createGuardianGrant({ grantId: 'unrelated', groupId: 'other' });
  await t.repo.deleteConvoyCascade('g');
  await t.repo.deleteConvoyCascade('g');
  assert.equal(await t.repo.guardianGrant({ grantId: g.grantId }), null);
  assert.ok(await t.repo.guardianGrant({ grantId: 'unrelated' }));
  assert.equal(await t.repo.getGuardianSubscription('sub'), null);
  assert.equal(await t.repo.guardianRevoked('sub'), false);
  assert.equal(await t.repo.guardianConsent('g', 'me'), null);
  assert.equal((await t.repo.listGuardianJobs(Infinity)).length, 0);
  await assert.rejects(t.service.snapshot(session.credential), { status: 410 });
});

test('timeline filters scope, duration, planned stops, pauses and private fields', async () => {
  const t = await setup(), g = await t.create(); t.time(T + 3600000);
  const event = (id, type, age, extra = {}) => ({ eventId: id, userId: 'me', type,
    startedAt: T + 3600000 - age, open: true, data: { secret: 'PRIVATE' }, lat: 17, ...extra });
  t.repo.guardianEvents = async () => [
    event('short', 'STOPPED', 899999), event('long', 'STOPPED', 900000),
    event('off-short', 'OFF_ROUTE', 299999), event('off-long', 'OFF_ROUTE', 300000),
    event('peer', 'SOS', 100, { userId: 'other' }), event('bad', 'UNKNOWN', 100),
    event('planned', 'STOP_REACHED', 1800000, { endedAt: T + 3600000 - 1200000 }),
    event('expected', 'STOPPED', 1500000),
  ];
  const view = await t.view(g);
  assert.deepEqual(view.timeline.map(e => e.eventId), ['long', 'off-long', 'planned']);
  assert.ok(!JSON.stringify(view.timeline).includes('PRIVATE'));
  assert.ok(view.timeline.every(e => e.lat === undefined));
  await t.save({ tripStatus: 'PAUSED' });
  assert.deepEqual((await t.view(g)).timeline.map(e => e.eventId), ['planned']);
});

test('emergency-only timeline excludes routine and peer events', async () => {
  const t = await setup(), g = await t.create('EMERGENCY_ONLY');
  t.repo.guardianEvents = async () => ['TRIP_STARTED', 'SOS', 'SOS_RESPONSE'].map((type) =>
    ({ eventId: type, type, userId: 'me', startedAt: T }));
  assert.deepEqual((await t.view(g)).timeline.map(e => e.type), ['SOS', 'SOS_RESPONSE']);
});

test('pause resume preserves expiry and permanent revocation; deleted grants fail closed', async () => {
  const t = await setup(), g = await t.create(), s = await t.service.exchange(g.token);
  await t.service.pause('me', g.grantId, true);
  await assert.rejects(t.service.snapshot(s.credential), { status: 423 });
  await t.service.pause('me', g.grantId, false);
  assert.equal((await t.service.snapshot(s.credential)).expiresAt, s.expiresAt);
  await t.service.revoke('me', g.grantId);
  await t.service.pause('me', g.grantId, false);
  await assert.rejects(t.service.snapshot(s.credential), { status: 410 });
  t.repo.guardianGrant = async () => null;
  await assert.rejects(t.service.snapshot(s.credential), { status: 410 });
});
