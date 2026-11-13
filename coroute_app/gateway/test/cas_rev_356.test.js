'use strict';
/**
 * Round 6 clean-up (d): review of the atomic compare-and-replace after its precondition became "test every
 * top-level scalar of the observed document" (Oracle compares `_id` in a whole-document test).
 *
 * What scalars alone miss, shown here against MemorySoda (which now applies exactly the emitted JSON Patch):
 *   - a change inside a nested array / object  (coupon holds in the same millisecond, a refund list on an order);
 *   - a top-level key that a competitor ADDED  (the lease hand-back request `wantedBy`);
 *   - a plain replace that touches no scalar.
 * The fix is a scalar revision token (`casRev`) on every document of the compare-and-replace collections, changed
 * by every write. Each race below runs twice: with the token (must be detected) and in the old scalars-only mode
 * (documents the gap the token closes). The emitted REST patches are asserted too.
 */
process.env.NODE_ENV = 'test';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SodaClient, REV_FIELD, CAS_COLLECTIONS, casTests, seedMissingRevs } = require('../src/oracle/soda');
const { MemorySoda } = require('../src/oracle/memory_soda');
const { Repo } = require('../src/oracle/repo');
const { JobLease } = require('../src/job_lease');
const { SessionStore } = require('../src/sessions');

const quiet = { info() {}, warn() {}, error() {} };

/** MemorySoda with a hook that runs once right before the atomic step of the next compare-and-replace. */
class RaceSoda extends MemorySoda {
  constructor({ rev = true } = {}) { super(); if (!rev) this.revCollections = new Set(); this.beforeCas = null; this.casCalls = 0; }
  async _casApply(c, k, patch) {
    this.casCalls++;
    const h = this.beforeCas;
    if (h) { this.beforeCas = null; await h(c, k); }
    return super._casApply(c, k, patch);
  }
}

function restClient(status = 200, bodyOf = null) {
  const calls = [];
  const soda = new SodaClient({ baseUrl: 'https://example.test', user: 'u', password: 'p', maxInFlight: 0,
    fetchImpl: async (url, options) => {
      calls.push({ url, method: options.method, type: options.headers['Content-Type'], body: options.body ? JSON.parse(options.body) : undefined });
      const body = bodyOf ? bodyOf(calls[calls.length - 1], calls.length) : '';
      return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
    } });
  return { soda, calls };
}

// ---------------------------------------------------------------- emitted patches (REST client)

test('REST: a collection without compare-and-replace callers keeps the old patch exactly (no casRev, one request)', async () => {
  const { soda, calls } = restClient();
  const next = { sequence: 2, nested: { a: 1 } };
  assert.equal(await soda.compareAndReplace('jobs', 'k1', { sequence: 1, nested: { a: 0 }, _id: 'x' }, next), true);
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].body, [{ op: 'test', path: '/sequence', value: 1 }, { op: 'replace', path: '', value: { sequence: 2, nested: { a: 1 } } }]);
  assert.equal(next[REV_FIELD], undefined);
  await soda.insert('jobs', { a: 1 }).catch(() => {});
  assert.deepEqual(calls[1].body, { a: 1 }, 'insert is not stamped outside the CAS collections');
});

test('REST: a CAS collection tests /casRev with the scalars and writes a fresh one (also on the caller\'s object)', async () => {
  const { soda, calls } = restClient();
  const observed = { name: 'retention', holder: 'vm1', expiresAt: 100, version: 3, wantedBy: null, [REV_FIELD]: 'r-old', lastRun: { at: 1 } };
  const next = { ...observed, expiresAt: 200, version: 4 };
  assert.equal(await soda.compareAndReplace('leases', 'K 1/a', observed, next), true);
  assert.equal(calls.length, 1, 'one PATCH, nothing else');
  assert.equal(calls[0].url, 'https://example.test/leases/K%201%2Fa');
  assert.equal(calls[0].method, 'PATCH');
  assert.equal(calls[0].type, 'application/json-patch+json');
  const tests = calls[0].body.filter((op) => op.op === 'test');
  assert.deepEqual(tests, [
    { op: 'test', path: '/name', value: 'retention' }, { op: 'test', path: '/holder', value: 'vm1' },
    { op: 'test', path: '/expiresAt', value: 100 }, { op: 'test', path: '/version', value: 3 },
    { op: 'test', path: '/wantedBy', value: null }, { op: 'test', path: `/${REV_FIELD}`, value: 'r-old' },
  ], 'every top-level scalar and the revision; nested values are not tested (the revision covers them)');
  const rep = calls[0].body[calls[0].body.length - 1];
  assert.equal(rep.op, 'replace'); assert.equal(rep.path, '');
  assert.ok(typeof rep.value[REV_FIELD] === 'string' && rep.value[REV_FIELD] !== 'r-old', 'a new revision is written');
  assert.equal(next[REV_FIELD], rep.value[REV_FIELD], 'the caller\'s copy carries the stored revision (chained compare-and-replace)');
  assert.deepEqual({ ...rep.value, [REV_FIELD]: 0 }, { ...next, [REV_FIELD]: 0 });
  // a conflict is a plain false, never retried
  for (const status of [400, 404, 409, 412, 422]) {
    const c = restClient(status);
    assert.equal(await c.soda.compareAndReplace('leases', 'k', { a: 1, [REV_FIELD]: 'r1' }, { a: 2 }), false);
    assert.equal(c.calls.length, 1);
  }
  await assert.rejects(restClient(500).soda.compareAndReplace('leases', 'k', { a: 1, [REV_FIELD]: 'r1' }, { a: 2 }));
});

test('REST: insert, bulk insert and replace stamp a revision in CAS collections; JSON pointer escaping; no scalar = refused', async () => {
  const { soda, calls } = restClient(200, () => ({ items: [{ id: 'K1' }, { id: 'K2' }] }));
  const doc = { code: 'A' };
  await soda.insert('coupons', doc);
  assert.ok(calls[0].body[REV_FIELD]); assert.equal(doc[REV_FIELD], calls[0].body[REV_FIELD]);
  const two = [{ a: 1 }, { a: 2 }];
  await soda.insertMany('mail_log', two);
  assert.ok(calls[1].body.every((d) => d[REV_FIELD])); assert.notEqual(two[0][REV_FIELD], two[1][REV_FIELD]);
  const before = doc[REV_FIELD];
  await soda.replace('coupons', 'K1', doc);
  assert.equal(calls[2].method, 'PUT'); assert.notEqual(calls[2].body[REV_FIELD], before, 'a plain replace changes the revision');
  assert.equal(doc[REV_FIELD], calls[2].body[REV_FIELD]);
  assert.deepEqual(casTests({ 'a/b': 1, 'c~d': 'x', _id: 'no', list: [1] }), [{ op: 'test', path: '/a~1b', value: 1 }, { op: 'test', path: '/c~0d', value: 'x' }]);
  await assert.rejects(soda.compareAndReplace('jobs', 'k', { only: { nested: 1 } }, { a: 1 }), /at least one top-level scalar/);
  for (const c of ['leases', 'auth_sessions', 'coupons', 'subscription_config', 'mail_log']) assert.ok(CAS_COLLECTIONS.includes(c), c);
});

test('REST: a document without a revision is verified, given one (JSON Patch add) and then replaced on that revision', async () => {
  const stored = { name: 'sweep', holder: 'vm2', expiresAt: 5, list: [1, 2] };
  let rev = null;
  const { soda, calls } = restClient(200, (call) => {
    if (call.method === 'GET') return rev ? { ...stored, [REV_FIELD]: rev } : stored;
    if (call.method === 'PATCH' && call.body[0].op === 'add') rev = call.body[0].value;
    return '';
  });
  const next = { ...stored, expiresAt: 9 };
  assert.equal(await soda.compareAndReplace('leases', 'k9', { ...stored }, next), true);
  assert.deepEqual(calls.map((c) => c.method), ['GET', 'PATCH', 'GET', 'PATCH']);
  assert.deepEqual(calls[1].body, [{ op: 'add', path: `/${REV_FIELD}`, value: rev }], 'the seed changes nothing but the revision');
  assert.deepEqual(calls[3].body.filter((op) => op.op === 'test').find((op) => op.path === `/${REV_FIELD}`), { op: 'test', path: `/${REV_FIELD}`, value: rev });
  assert.ok(next[REV_FIELD] && next[REV_FIELD] !== rev);
  // The stored document is not the observed one (a nested change the scalars cannot see): refused before any write.
  const other = restClient(200, () => ({ ...stored, list: [1, 2, 3] }));
  assert.equal(await other.soda.compareAndReplace('leases', 'k9', { ...stored }, { ...stored, expiresAt: 9 }), false);
  assert.deepEqual(other.calls.map((c) => c.method), ['GET']);
  // It already has a revision the caller did not see: somebody wrote since the read.
  const seen = restClient(200, () => ({ ...stored, [REV_FIELD]: 'r7' }));
  assert.equal(await seen.soda.compareAndReplace('leases', 'k9', { ...stored }, { ...stored, expiresAt: 9 }), false);
});

// ---------------------------------------------------------------- races (MemorySoda applies the emitted patch)

for (const rev of [true, false]) {
  const mode = rev ? 'with casRev' : 'scalars only (the gap)';

  test(`job lease: a hand-back request added while the holder renews is ${rev ? 'seen' : 'overwritten'} [${mode}]`, async () => {
    const soda = new RaceSoda({ rev });
    const doc = { name: 'convoy-auto-end', holder: 'vm2#1', node: 'vm2', role: 'web', expiresAt: 1000, version: 1, lastRunAt: 0, lastRunBy: null };
    const key = await soda.insert('leases', doc);
    const held = await soda.get('leases', key);                       // what the holder has in memory
    // The preferred node asks for the lease: two new top-level keys, no existing scalar changes.
    const seenByStandby = await soda.get('leases', key);
    assert.equal(await soda.compareAndReplace('leases', key, seenByStandby, { ...seenByStandby, wantedBy: 'vm1#1', wantedAt: 900 }), true);
    // The holder renews from its in-memory copy.
    const renewed = await soda.compareAndReplace('leases', key, held, { ...held, expiresAt: 4000, version: 2 });
    const now = await soda.get('leases', key);
    if (rev) {
      assert.equal(renewed, false, 'the renew fails, the holder re-reads and finds the request');
      assert.equal(now.wantedBy, 'vm1#1');
    } else {
      assert.equal(renewed, true);
      assert.equal(now.wantedBy, undefined, 'scalars only: the request is silently lost and the job never moves back');
    }
  });

  test(`coupon with one use left: two orders in the same millisecond ${rev ? 'cannot both hold it' : 'both hold it'} [${mode}]`, async (t) => {
    const soda = new RaceSoda({ rev });
    const repo = new Repo(soda);
    await repo.migrate();
    const t0 = 1_800_000_000_000;
    t.mock.method(Date, 'now', () => t0);                              // the same millisecond: updatedAt does not change
    await repo.saveCoupon({ code: 'ONELEFT', discountType: 'percent', discountValue: 10, maxUsageTotal: 1, maxUsagePerUser: 1, validFrom: t0 - 1000, expiresAt: t0 + 86400000, isActive: true });
    const slot = (userId, orderId) => repo.reserveCouponSlot('ONELEFT', { userId, orderId, category: 'group_large', categoryName: 'Group', originalPrice: 199, discountAmount: 20, finalAmount: 179 });
    let second;
    soda.beforeCas = async () => { second = await slot('user-b', 'order_b'); };   // B completes between A's read and A's write
    const first = await slot('user-a', 'order_a');
    const coupon = await repo.findCoupon('ONELEFT');
    const holds = (coupon.holds || []).map((h) => h.orderId).sort();
    assert.equal(second.reserved, true, 'the competitor got its hold');
    if (rev) {
      assert.equal(first.reserved, false, 'the loser re-reads and is refused: the cap holds');
      assert.deepEqual(holds, ['order_b']);
    } else {
      assert.equal(first.reserved, true);
      assert.deepEqual(holds, ['order_a'], 'scalars only: the second write replaced the first hold, two orders believe they hold one use');
    }
  });

  test(`payment order claim: a refund recorded between the read and the claim ${rev ? 'stops the claim' : 'is overwritten'} [${mode}]`, async () => {
    const soda = new RaceSoda({ rev });
    const repo = new Repo(soda);
    await repo.migrate();
    await repo.saveRazorpayOrder({ orderId: 'order_1', userId: 'u1', amount: 19900, status: 'CREATED', refunds: [], createdAt: 1 });
    // The competitor adds an entry to the nested refund list by a read-modify-write that changes no scalar.
    soda.beforeCas = async () => {
      const row = await soda.findOne('subscription_config', { k: 'rzp_order', orderId: 'order_1' });
      await soda.replace('subscription_config', row.key, { ...row.value, refunds: [{ id: 'rfnd_1', amount: 19900 }] });
    };
    const out = await repo.claimRazorpayOrder('order_1', { paymentId: 'pay_1', by: 'verify' });
    const stored = await repo.findRazorpayOrder('order_1');
    if (rev) {
      assert.equal(out.order, null); assert.equal(out.reason, 'REFUNDED');
      assert.equal(stored.status, 'CREATED'); assert.equal(stored.refunds.length, 1);
    } else {
      assert.ok(out.order, 'scalars only: the claim wins');
      assert.equal(stored.refunds.length, 0, 'and the refund record is gone');
    }
  });

  test(`payment order claim: of two settles racing on one order exactly one wins [${mode}]`, async () => {
    const soda = new RaceSoda({ rev });
    const repo = new Repo(soda);
    await repo.migrate();
    await repo.saveRazorpayOrder({ orderId: 'order_2', userId: 'u1', amount: 100, status: 'CREATED', createdAt: 1 });
    let inner;
    soda.beforeCas = async () => { inner = await repo.claimRazorpayOrder('order_2', { paymentId: 'pay_w', by: 'webhook' }); };
    const outer = await repo.claimRazorpayOrder('order_2', { paymentId: 'pay_v', by: 'verify' });
    assert.ok(inner.order, 'the webhook claimed it');
    assert.equal(outer.order, null); assert.equal(outer.reason, 'IN_PROGRESS');
    assert.equal((await repo.findRazorpayOrder('order_2')).settlingBy, 'webhook');
    const many = await Promise.all(Array.from({ length: 12 }, (_, i) => repo.claimRazorpayOrder('order_2b', { by: `n${i}` }).catch(() => null)));
    assert.ok(many.every((m) => m && m.order === null), 'an unknown order is never claimed');
  });

  test(`sessions: a refresh racing a revoke never brings the session back; two racing refreshes both stay signed in [${mode}]`, async () => {
    const soda = new RaceSoda({ rev });
    const sessions = new SessionStore({ soda, logger: quiet });
    await sessions.init();
    const { session, refreshToken } = await sessions.create({ user: { userId: 'u-1' }, kind: 'app', device: { id: 'dev-1', label: 'Phone' } });
    soda.beforeCas = async () => { await sessions.revoke(session.sessionId, 'SIGNED_OUT'); };
    await assert.rejects(sessions.refresh(refreshToken), (e) => e.code === 'SESSION_INVALID' || /sign/i.test(e.message));
    const row = await soda.findOne('auth_sessions', { sessionId: session.sessionId });
    assert.ok(row.value.revokedAt > 0, 'still revoked');
    // Two refreshes of the same token: one rotates, the other finds its token as the previous one (graced).
    const b = await sessions.create({ user: { userId: 'u-2' }, kind: 'app', device: { id: 'dev-2', label: 'Phone' } });
    let innerOut;
    soda.beforeCas = async () => { innerOut = await sessions.refresh(b.refreshToken); };
    const outerOut = await sessions.refresh(b.refreshToken);
    assert.ok(innerOut.refreshToken && outerOut.refreshToken);
    assert.equal((await soda.findOne('auth_sessions', { sessionId: b.session.sessionId })).value.revokedAt, 0);
  });
}

test('job lease end to end: the preferred node gets its job back (request -> hand-back -> take-over), with casRev on every lease write', async () => {
  const soda = new RaceSoda();
  const clock = { t: 1_700_000_000_000 };
  const mk = (role, node) => new JobLease({ soda, role, node, logger: quiet, clock: () => clock.t, ttlMs: 3000, heartbeatMs: 1000, graceMs: 120000, autoTick: false });
  const web = mk('web', 'vm2'); const live = mk('live', 'vm1');
  const runs = [];
  for (const n of [web, live]) n.run('convoy-auto-end', 10000, async () => { runs.push(n.node); }, { prefer: 'live' });
  const step = async (nodes) => { for (const n of nodes) { await n.poll('convoy-auto-end'); await n.idle(); } };
  // Only the web node is up: after the grace period it takes the job the live node should run.
  for (let i = 0; i < 130; i++) { await step([web]); clock.t += 1000; }
  const row = () => soda.findOne('leases', { name: 'convoy-auto-end' });
  assert.match((await row()).value.holder, /vm2/);
  assert.ok((await row()).value[REV_FIELD], 'lease documents carry a revision');
  // The live node comes back and asks; the web node must notice at its next renew and hand the lease back.
  for (let i = 0; i < 12; i++) { await step([live, web]); clock.t += 1000; }
  assert.match((await row()).value.holder, /vm1/, 'the job moved back to the preferred node');
  const before = runs.length;
  for (let i = 0; i < 25; i++) { await step([live, web]); clock.t += 1000; }
  assert.ok(runs.length > before && runs.slice(before).every((n) => n === 'vm1'), 'and runs there only');
  await web.stopAll({ waitMs: 10 }); await live.stopAll({ waitMs: 10 });
});

test('documents written before round 6: compare-and-replace is safe at once, and the seed job gives them a revision in bounded batches', async () => {
  const soda = new RaceSoda();
  // Old documents: put them in without a revision.
  const put = (c, doc) => { const k = `L${++soda.seq}`; soda._coll(c).set(k, structuredClone(doc)); return k; };
  const key = put('coupons', { code: 'OLD', usageCount: 0, holds: [], updatedAt: 5 });
  // A nested-only change by a competitor between the caller's read and its compare-and-replace.
  const observed = await soda.get('coupons', key);
  const competitor = await soda.get('coupons', key);
  assert.equal(await soda.compareAndReplace('coupons', key, competitor, { ...competitor, holds: [{ orderId: 'x' }] }), true);
  assert.equal(await soda.compareAndReplace('coupons', key, observed, { ...observed, holds: [{ orderId: 'y' }] }), false, 'the stale caller is refused');
  assert.deepEqual((await soda.get('coupons', key)).holds, [{ orderId: 'x' }]);
  assert.ok((await soda.get('coupons', key))[REV_FIELD]);
  // Two callers that both observed the old document: exactly one wins.
  const k2 = put('coupons', { code: 'OLD2', usageCount: 0, holds: [], updatedAt: 5 });
  const a = await soda.get('coupons', k2); const b = await soda.get('coupons', k2);
  let innerOk;
  soda.beforeCas = async () => { innerOk = await soda.compareAndReplace('coupons', k2, b, { ...b, holds: [{ orderId: 'b' }] }); };
  const outerOk = await soda.compareAndReplace('coupons', k2, a, { ...a, holds: [{ orderId: 'a' }] });
  assert.equal([innerOk, outerOk].filter(Boolean).length, 1);
  // The seed job: bounded per run, continues on the next run, changes nothing but the revision, idempotent.
  for (let i = 0; i < 250; i++) put('mail_log', { id: `m${i}`, status: 'QUEUED', payload: { n: i } });
  put('trips', { tripId: 't1' });                                       // not a CAS collection: left alone
  const queries = [];
  const q = soda.query.bind(soda);
  soda.query = async (c, f, o) => { queries.push({ c, limit: o && o.limit }); return q(c, f, o); };
  const first = await seedMissingRevs(soda, { batch: 50, max: 120 });
  assert.equal(first, 120, 'never more than max per run');
  assert.ok(queries.every((x) => x.limit <= 50), 'read in small pages');
  let total = first;
  for (let i = 0; i < 10; i++) total += await seedMissingRevs(soda, { batch: 50, max: 120 });
  assert.equal(total, 250);
  assert.equal(await seedMissingRevs(soda, { batch: 50, max: 120 }), 0, 'nothing left');
  const rows = await q('mail_log', {}, { limit: 1000 });
  assert.ok(rows.every((r) => r.value[REV_FIELD] && r.value.status === 'QUEUED' && typeof r.value.payload.n === 'number'));
  assert.equal((await q('trips', {}, { limit: 10 }))[0].value[REV_FIELD], undefined);
});
