'use strict';
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { GuardianPush, subscriptionOf } = require('../src/guardian_push');
const { GuardianError } = require('../src/guardians');
const { Repo } = require('../src/oracle/repo');
const { MemorySoda } = require('../src/oracle/memory_soda');
const subscription = { endpoint: 'https://fcm.googleapis.com/test', keys: { p256dh: 'A'.repeat(87), auth: 'B'.repeat(22) } };
async function setup() {
  const repo = new Repo(new MemorySoda()); await repo.migrate();
  let now = 1700000000000, revoked = false, fail = false;
  const view = { tripStatus: 'STARTED', emergency: false, level: 'LIVE', expiresAt: now + 86400000 };
  const service = { sessionGrant: async () => ({ grantId: 'g' }),
    viewGrant: async () => { if (revoked) throw new GuardianError(); return view; },
    ticket: async () => ({ credential: 'C'.repeat(32) }) };
  const sends = [];
  const push = new GuardianPush({ repo, service, publicKey: 'public', clock: () => now,
    send: async (sub, payload, options) => { if (fail) throw new Error('network down'); sends.push({ sub, payload: JSON.parse(payload), options }); } });
  const sub = await push.subscribe('credential', subscription);
  return { push, repo, view, sends, sub, time: (n) => { now += n; }, revoke: () => { revoked = true; }, fail: (v) => { fail = v; } };
}
test('subscription endpoint allowlist prevents arbitrary requests and malformed keys', () => {
  assert.deepEqual(subscriptionOf(subscription), subscription);
  for (const endpoint of ['http://fcm.googleapis.com/x', 'https://localhost/x', 'https://fcm.googleapis.com.evil.example/x', 'https://fcm.googleapis.com:8443/x', 'https://user@fcm.googleapis.com/x']) {
    assert.throws(() => subscriptionOf({ ...subscription, endpoint }), { status: 400 });
  }
  assert.throws(() => subscriptionOf({ ...subscription, keys: {} }), { status: 400 });
});
test('routine unchanged state is quiet; emergency delivery is generic and deduplicated', async () => {
  const t = await setup(); await t.push.tick(); assert.equal(t.sends.length, 0);
  t.view.emergency = true; t.view.alerts = [{ type: 'HELP_REQUESTED', reportedAt: 123 }];
  await t.push.tick(); await t.push.tick(); assert.equal(t.sends.length, 1);
  assert.equal(t.sends[0].options.urgency, 'high'); assert.ok(!t.sends[0].payload.body.includes('123'));
  assert.match(t.sends[0].payload.url, /^\/watch#ticket=/);
});
test('transient failures retry durably but an obsolete emergency is discarded', async () => {
  const t = await setup(); t.fail(true); t.view.emergency = true;
  await t.push.tick(); assert.equal((await t.repo.listGuardianJobs(Infinity))[0].attempts, 1);
  t.view.emergency = false; t.fail(false); t.time(60000); await t.push.tick();
  assert.equal(t.sends.length, 1, 'only the current resolved state is delivered');
  assert.equal(t.sends[0].options.urgency, 'normal');
});
test('revocation and browser opt-out prevent queued delivery', async () => {
  const t = await setup(); t.fail(true); t.view.emergency = true; await t.push.tick();
  await t.push.unsubscribe('credential', t.sub.subscriptionId);
  t.fail(false); t.time(60000); await t.push.tick(); assert.equal(t.sends.length, 0);
  await assert.rejects(t.push.subscribe('credential', subscription), { status: 409 });
  const other = await setup(); other.view.emergency = true; other.revoke(); await other.push.tick();
  assert.equal(other.sends.length, 0);
});
test('repeated trip state cycles have distinct delivery revisions', async () => {
  const t = await setup();
  for (const state of ['PAUSED', 'STARTED', 'PAUSED']) { t.view.tripStatus = state; await t.push.tick(); }
  assert.equal(t.sends.length, 3); assert.equal(new Set(t.sends.map((v) => v.payload.tag)).size, 3);
});


test('changed preferences invalidate jobs queued for an older subscription revision', async () => {
  const t = await setup(); t.fail(true); t.view.emergency = true; await t.push.tick();
  await t.push.subscribe('credential', subscription, { emergencies: false, trip: false });
  t.fail(false); t.time(60000); await t.push.tick(); assert.equal(t.sends.length, 0);
});

test('unsubscribe while preparing a delivery cancels it before sending', async () => {
  const t = await setup();
  t.push.service.ticket = async () => { await t.push.unsubscribe('credential', t.sub.subscriptionId); return { credential: 'X'.repeat(32) }; };
  t.view.emergency = true; await t.push.tick(); assert.equal(t.sends.length, 0);
});

test('invalid preferences rejected and permanently gone push endpoint removed', async () => {
  const t = await setup();
  for (const preferences of [null, [], { trip: 'true' }, { location: true }]) {
    await assert.rejects(t.push.subscribe('credential', subscription, preferences), { status: 400 });
  }
  t.push.send = async () => { throw Object.assign(new Error('gone'), { statusCode: 410 }); };
  t.view.emergency = true; await t.push.tick();
  assert.equal(await t.repo.getGuardianSubscription(t.sub.subscriptionId), null);
});

test('shutdown prevents delivery and concurrent ticks share one worker', async () => {
  const t = await setup(); t.view.emergency = true;
  await Promise.all([t.push.tick(), t.push.tick()]); assert.equal(t.sends.length, 1);
  t.push.stop(); t.view.emergency = false; await t.push.tick(); assert.equal(t.sends.length, 1);
});


test('two worker instances atomically claim one delivery', async () => {
  const t = await setup();
  const second = new GuardianPush({ repo: new Repo(t.repo.soda), service: t.push.service,
    send: t.push.send, clock: t.push.clock, publicKey: 'public' });
  t.view.emergency = true;
  await Promise.all([t.push.tick(), second.tick()]);
  assert.equal(t.sends.length, 1);
});

test('expired worker lease is recoverable and old worker cannot finish the new claim', async () => {
  const t = await setup(), now = t.push.clock();
  await t.repo.enqueueGuardianJob({ jobId: 'lease-test', state: 'PENDING', nextAttemptAt: now });
  const first = await t.repo.claimGuardianJob('lease-test', 'one', now); assert.ok(first);
  assert.equal(await t.repo.claimGuardianJob('lease-test', 'two', now + 119999), null);
  const second = await t.repo.claimGuardianJob('lease-test', 'two', now + 120000); assert.ok(second);
  assert.equal(await t.repo.finishGuardianJob({ ...first, state: 'SENT' }, 'one'), false);
  assert.equal(await t.repo.finishGuardianJob({ ...second, state: 'SENT' }, 'two'), true);
});

test('stale cursor cannot restore old preferences or a deleted subscription', async () => {
  const t = await setup();
  const old = await t.repo.getGuardianSubscription(t.sub.subscriptionId);
  await t.push.subscribe('credential', subscription, { emergencies: false, trip: false });
  assert.equal(await t.repo.advanceGuardianSubscription(old, { emergency: true }), false);
  assert.equal((await t.repo.getGuardianSubscription(t.sub.subscriptionId)).preferences.emergencies, false);
  await t.push.unsubscribe('credential', t.sub.subscriptionId);
  assert.equal(await t.repo.advanceGuardianSubscription(old, { emergency: true }), false);
  assert.equal(await t.repo.getGuardianSubscription(t.sub.subscriptionId), null);
});
