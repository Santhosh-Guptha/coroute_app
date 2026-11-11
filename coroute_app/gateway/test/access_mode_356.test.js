'use strict';
/**
 * 3.56 access mode (src/access_mode.js, docs/features_355/access_modes.md): paid / free for everyone /
 * free up to limits, an optional scheduled change in India time, the app capability payload (no
 * prices), live CAPABILITIES_CHANGED, existing paid plans untouched, and the website plans page.
 */
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.MAX_CONVOY_RIDERS = '50';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'access.admin@coroute.test';

const fs = require('fs');
const path = require('path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { MemorySoda } = require('../src/oracle/memory_soda');
const AM = require('../src/access_mode');
const { boot } = require('./_helpers');

const DAY = 86400000;
const COMMUNITY = { source: 'community', category: 'community', seats: 1, canStartTrip: true, canHostGroup: false };
const SMALL = { source: 'membership', category: 'group_small', seats: 6, canStartTrip: true, canHostGroup: true };
const LARGE = { source: 'membership', category: 'group_large', seats: 12, canStartTrip: true, canHostGroup: true };
const settings = (doc, now = Date.now()) => AM.effectiveDoc(doc, now);

/** Every key and string value of a payload, recursively. */
function walk(v, out = { keys: [], strings: [] }) {
  if (Array.isArray(v)) v.forEach((x) => walk(x, out));
  else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) { out.keys.push(k); walk(x, out); }
  else if (typeof v === 'string') out.strings.push(v);
  return out;
}
function assertNoMoney(payload) {
  const { keys, strings } = walk(payload);
  for (const k of keys) assert.doesNotMatch(k, /price|inr|amount|coupon|offer|plan|pay|currency|mode/i, `key ${k} must not reach the app`);
  for (const s of strings) assert.doesNotMatch(s, /₹|price|buy|purchase|upgrade|coupon|discount|payment/i);
}

test('paid mode: hosting needs a group plan (the behaviour before 3.56)', () => {
  const s = settings({ mode: 'paid' });
  const c = AM.capabilitiesFor({ plan: COMMUNITY, settings: s });
  assert.deepEqual([c.gated, c.canHostGroup, c.maxRiders, c.reason], [true, false, 1, 'GROUP_PLAN_REQUIRED']);
  assert.deepEqual(c.groupFeatures, []);
  const p = AM.capabilitiesFor({ plan: SMALL, settings: s });
  assert.deepEqual([p.canHostGroup, p.maxRiders, p.groupFeatures, p.reason], [true, 6, 'all', null]);
});

test('free for everyone: every rider hosts with every group feature; bigger paid plans keep their seats', () => {
  const s = settings({ mode: 'free', free: { maxRiders: 12 } });
  const c = AM.capabilitiesFor({ plan: COMMUNITY, settings: s });
  assert.deepEqual([c.gated, c.canHostGroup, c.maxRiders, c.groupFeatures, c.reason, c.hostedRidesLeft], [false, true, 12, 'all', null, null]);
  assert.equal(AM.capabilitiesFor({ plan: SMALL, settings: s }).maxRiders, 12, 'a smaller paid plan gets the free limit');
  assert.equal(AM.capabilitiesFor({ plan: LARGE, settings: settings({ mode: 'free', free: { maxRiders: 8 } }) }).maxRiders, 12, 'a bigger paid plan keeps its seats');
  assert.equal(AM.capabilitiesFor({ plan: COMMUNITY, settings: settings({ mode: 'free', free: { maxRiders: 20 } }) }).maxRiders, 20);
  // Never above the server ceiling (MAX_CONVOY_RIDERS 50 here).
  assert.equal(AM.capabilitiesFor({ plan: COMMUNITY, settings: settings({ mode: 'free', free: { maxRiders: 400 } }) }).maxRiders, 50);
});

test('free up to limits: riders per ride, rides per month, the free group features; a plan lifts the limits', () => {
  const s = settings({ mode: 'hybrid', hybrid: { maxRiders: 6, maxHostedRidesPerMonth: 8, freeFeatures: ['intercom', 'rideRoles', 'crewRides'] } });
  const c = AM.capabilitiesFor({ plan: COMMUNITY, settings: s, hostedThisMonth: 3 });
  assert.deepEqual([c.gated, c.canHostGroup, c.maxRiders, c.hostedRidesLeft, c.hostedRidesLimit, c.reason, c.freeTier], [true, true, 6, 5, 8, null, true]);
  assert.deepEqual(c.groupFeatures, ['intercom', 'rideRoles', 'crewRides']);
  const out = AM.capabilitiesFor({ plan: COMMUNITY, settings: s, hostedThisMonth: 8 });
  assert.deepEqual([out.canHostGroup, out.maxRiders, out.hostedRidesLeft, out.reason], [false, 1, 0, 'HOSTED_RIDES_LIMIT']);
  const paid = AM.capabilitiesFor({ plan: SMALL, settings: s, hostedThisMonth: 99 });
  assert.deepEqual([paid.canHostGroup, paid.maxRiders, paid.groupFeatures, paid.hostedRidesLeft, paid.reason], [true, 6, 'all', null, null]);
  // The locked-feature check used by the socket, the voice relay and crew ride invites.
  assert.equal(AM.lockedFeature(['intercom'], ['rideRoles']), 'rideRoles');
  assert.equal(AM.lockedFeature(['intercom'], ['intercom']), null);
  assert.equal(AM.lockedFeature(['intercom'], ['sos']), null, 'a feature outside the gatable list is never locked');
  assert.equal(AM.lockedFeature(null, ['rideRoles']), null, 'null = every group feature');
  for (const id of ['sos', 'crashDetection', 'missingRiderCheck', 'buddyPairs', 'rollCall', 'stretchAlert']) assert.ok(!AM.GATABLE_IDS.includes(id), `${id} is never gated`);
});

test('validation: limits, unknown features, schedule in the future, same-mode schedule refused', () => {
  const now = Date.UTC(2026, 10, 11, 6, 0);
  assert.throws(() => AM.validateUpdate({}, { mode: 'cheap' }, now), /paid, free or hybrid/);
  assert.throws(() => AM.validateUpdate({}, { hybrid: { maxRiders: 1 } }, now), /from 2 to 1000/);
  assert.throws(() => AM.validateUpdate({}, { hybrid: { freeFeatures: ['sos'] } }, now), /Unknown group feature/);
  assert.throws(() => AM.validateUpdate({}, { mode: 'free', schedule: { mode: 'paid', atIst: '2026-11-01T00:00' } }, now), /future/);
  assert.throws(() => AM.validateUpdate({}, { mode: 'free', schedule: { mode: 'free', atIst: '2026-12-01T00:00' } }, now), /same as the current/);
  assert.throws(() => AM.validateUpdate({}, { mode: 'free', schedule: { mode: 'paid', atIst: '2026-02-31T00:00' } }, now), /India time/);
  const ok = AM.validateUpdate({}, { mode: 'free', free: { maxRiders: 10 }, schedule: { mode: 'paid', atIst: '2026-12-01T00:00' } }, now);
  assert.deepEqual([ok.mode, ok.free.maxRiders, ok.schedule.mode, ok.schedule.at], ['free', 10, 'paid', Date.UTC(2026, 10, 30, 18, 30)]);
});

test('schedule boundary in India time: 1 Dec 00:00 IST = 30 Nov 18:30 UTC; the month resets at 00:00 IST', () => {
  const at = AM.parseIst('2026-12-01T00:00');
  assert.equal(at, Date.UTC(2026, 10, 30, 18, 30));
  const doc = { mode: 'free', schedule: { at, mode: 'paid' } };
  assert.equal(AM.effectiveDoc(doc, at - 1).mode, 'free', 'one millisecond before: still free');
  assert.equal(AM.effectiveDoc(doc, at).mode, 'paid', 'at the boundary: paid');
  assert.equal(AM.effectiveDoc(doc, at).scheduleApplied, true);
  assert.equal(AM.istMonth(at - 1), '2026-11');
  assert.equal(AM.istMonth(at), '2026-12');
});

test('service: versioned saves with history, the schedule boundary emits a change on time', async () => {
  let now = Date.UTC(2026, 10, 30, 12, 0);
  const am = new AM.AccessMode({ soda: new MemorySoda(), clock: () => now, paymentsEnabled: true, logger: { warn() {} } });
  const events = [];
  am.on('change', (e) => events.push(e));
  await am.refresh();
  assert.equal(am.mode(), 'paid');
  const r = await am.set({ mode: 'free', schedule: { mode: 'hybrid', atIst: '2026-12-01T00:00' } }, { by: 'admin@x', reason: 'Launch week' });
  assert.equal(r.entry.version, 1);
  assert.equal(r.view.version, 1);
  assert.equal(r.view.history[0].reason, 'Launch week');
  assert.equal(r.view.history[0].before.mode, 'paid');
  assert.deepEqual(events.map((e) => e.mode), ['free']);
  await assert.rejects(am.set({ mode: 'paid', expectedVersion: 0 }), /changed the access mode/);
  // A second node with the same database reads the same state.
  const peer = new AM.AccessMode({ soda: am.soda, clock: () => now, paymentsEnabled: true });
  await peer.refresh();
  assert.deepEqual([peer.mode(), peer.version], ['free', 1]);
  // Before the boundary nothing happens; at it, both nodes switch without any write.
  now = Date.UTC(2026, 10, 30, 18, 29, 59);
  assert.equal(am.tick(), false);
  now = Date.UTC(2026, 10, 30, 18, 30);
  assert.equal(am.tick(), true);
  assert.equal(am.mode(), 'hybrid');
  assert.equal(peer.mode(), 'hybrid');
  assert.deepEqual(events.map((e) => [e.mode, e.reason]), [['free', 'admin'], ['hybrid', 'schedule']]);
  assert.equal(am.publicView().mode, 'hybrid');
  // The next save starts from the mode in force (the reached schedule is consumed).
  const r2 = await am.set({ hybrid: { maxRiders: 4 } }, { by: 'admin@x' });
  assert.deepEqual([r2.view.stored.mode, r2.view.stored.schedule, r2.view.version], ['hybrid', null, 2]);
});

test('the app capability payload has no price, plan or mode fields', () => {
  const s = settings({ mode: 'hybrid' });
  for (const plan of [COMMUNITY, SMALL, LARGE]) {
    for (const hosted of [0, 99]) assertNoMoney(AM.appPayload(AM.capabilitiesFor({ plan, settings: s, hostedThisMonth: hosted }), 3));
  }
  assertNoMoney(AM.appPayload(AM.capabilitiesFor({ plan: COMMUNITY, settings: settings({ mode: 'free' }) })));
  assert.deepEqual(Object.keys(AM.appPayload(AM.capabilitiesFor({ plan: COMMUNITY, settings: s }))).sort(),
    ['canHostGroup', 'gated', 'groupFeatures', 'hostedRidesLeft', 'hostedRidesLimit', 'maxRiders', 'reason', 'version']);
});

test('gateway: admin modes drive hosting, limits, features, live refresh and the website', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const repo = env.gw.repo;
  const admin = await env.register('Access Admin', 'access.admin@coroute.test');
  const riders = [];
  for (let i = 0; i < 6; i++) riders.push(await env.register(`Access Rider ${i}`, `access.rider${i}@coroute.test`));
  const [host, a, b, c, paidHost, d] = riders;
  const setMode = async (body, token = admin.token) => env.api('PUT', '/admin/access-mode', body, token);
  const end = async (token, gid) => assert.equal((await env.api('POST', `/convoys/${gid}/status`, { status: 'ENDED' }, token)).status, 200);
  const caps = async (token) => (await env.api('GET', '/me/capabilities', null, token)).json.capabilities;
  const validUntil = Date.now() + 30 * DAY;
  await repo.saveMembership({ membershipId: `mem_${paidHost.user.userId}`, ownerUserId: paidHost.user.userId, category: 'group_small', categoryName: 'Small Group', capacity: 6, status: 'ACTIVE', validFrom: Date.now(), validUntil, members: {} });

  await t.test('only an admin can change the access mode', async () => {
    assert.equal((await setMode({ mode: 'free' }, host.token)).status, 403);
    const view = await env.api('GET', '/admin/access-mode', null, admin.token);
    assert.equal(view.status, 200);
    assert.equal(view.json.effective.mode, 'paid');
    assert.ok(view.json.features.some((f) => f.id === 'intercom'));
  });

  await t.test('paid (default): a rider without a plan starts a solo ride', async () => {
    const cap = await caps(host.token);
    assert.deepEqual([cap.gated, cap.canHostGroup, cap.maxRiders, cap.reason], [true, false, 1, 'GROUP_PLAN_REQUIRED']);
    const r = await env.api('POST', '/convoys', { name: 'Paid solo' }, host.token);
    assert.equal(r.status, 201);
    assert.deepEqual([r.json.capacity, r.json.soloRide], [1, true]);
    await end(host.token, r.json.groupId);
    assert.equal((await env.api('GET', '/public/access')).json.mode, 'paid');
  });

  await t.test('free for everyone: group ride for every rider, apps told at once, checkout hidden, paid plans untouched', async () => {
    const ws = await env.connect(a.token);
    const saved = await setMode({ mode: 'free', free: { maxRiders: 12 }, reason: 'Launch' });
    assert.equal(saved.status, 200, JSON.stringify(saved.json));
    const pushed = await ws.next((m) => m.type === 'CAPABILITIES_CHANGED');
    assert.equal(pushed.version, saved.json.version);
    ws.close();
    const cap = await caps(host.token);
    assert.deepEqual([cap.gated, cap.canHostGroup, cap.maxRiders, cap.groupFeatures, cap.reason], [false, true, 12, 'all', null]);
    assertNoMoney(cap);
    const my = await env.api('GET', '/membership/my', null, host.token);
    assert.equal(my.json.capabilities.canHostGroup, true);
    const r = await env.api('POST', '/convoys', { name: 'Free group' }, host.token);
    assert.deepEqual([r.json.capacity, r.json.soloRide, r.json.groupFeatures], [12, false, 'all']);
    assert.equal((await env.api('POST', '/convoys/join', { code: r.json.joinCode }, a.token)).status, 200);
    await end(host.token, r.json.groupId);
    // Website: free, no checkout; an order is refused; the account page stays.
    const pub = await env.api('GET', '/public/access');
    assert.deepEqual([pub.json.mode, pub.json.checkout, pub.json.free.maxRiders], ['free', false, 12]);
    const order = await env.api('POST', '/membership/order', { category: 'group_large' }, host.token);
    assert.equal(order.status, 409);
    assert.equal(order.json.reason, 'FREE_MODE');
    // The paid plan keeps running exactly as bought (no refund, no change).
    const m = await repo.findMembershipByOwner(paidHost.user.userId);
    assert.deepEqual([m.status, m.validUntil, m.capacity, m.category], ['ACTIVE', validUntil, 6, 'group_small']);
    assert.equal((await caps(paidHost.token)).maxRiders, 12);
    const audit = await repo.listAuditEntries(20);
    assert.ok(audit.some((e) => e.action === 'access_mode.update' && e.details.after.mode === 'free'));
  });

  await t.test('free up to limits: riders per ride, free features only, rides per month, then solo', async () => {
    const saved = await setMode({ mode: 'hybrid', hybrid: { maxRiders: 3, maxHostedRidesPerMonth: 1, freeFeatures: ['intercom'] } });
    assert.equal(saved.status, 200, JSON.stringify(saved.json));
    const cap = await caps(host.token);
    assert.deepEqual([cap.canHostGroup, cap.maxRiders, cap.groupFeatures, cap.hostedRidesLeft, cap.hostedRidesLimit], [true, 3, ['intercom'], 1, 1]);
    const r = await env.api('POST', '/convoys', { name: 'Hybrid ride' }, host.token);
    assert.deepEqual([r.json.capacity, r.json.groupFeatures], [3, ['intercom']]);
    for (const x of [a, b]) assert.equal((await env.api('POST', '/convoys/join', { code: r.json.joinCode }, x.token)).status, 200);
    const full = await env.api('POST', '/convoys/join', { code: r.json.joinCode }, c.token);
    assert.equal(full.status, 409);
    assert.equal(full.json.code, 'CONVOY_FULL');
    // A group feature left out of the free tier is refused (neutral reason code).
    const ws = await env.joinRoom(host.token, r.json.groupId);
    ws.sendJson({ type: 'ROLE_SET', userId: a.user.userId, role: 'LEAD', clientId: 'am1' });
    const err = await ws.next((m) => m.type === 'ERROR');
    assert.deepEqual([err.code, err.reason], [403, 'GROUP_FEATURE_LOCKED']);
    ws.close();
    // The ride counted when the first rider joined: the monthly limit is used up.
    await new Promise((res) => setTimeout(res, 50));
    const after = await caps(host.token);
    assert.deepEqual([after.canHostGroup, after.maxRiders, after.hostedRidesLeft, after.reason], [false, 1, 0, 'HOSTED_RIDES_LIMIT']);
    // The live ride never shrinks.
    assert.equal((await env.gw.convoys.getRoom(r.json.groupId)).meta.capacity, 3);
    await end(host.token, r.json.groupId);
    const next = await env.api('POST', '/convoys', { name: 'Over the limit' }, host.token);
    assert.deepEqual([next.json.capacity, next.json.soloRide], [1, true]);
    await end(host.token, next.json.groupId);
    // A host with a group plan is not limited and has every feature.
    const p = await env.api('POST', '/convoys', { name: 'Plan host' }, paidHost.token);
    assert.deepEqual([p.json.capacity, p.json.groupFeatures], [6, 'all']);
    await end(paidHost.token, p.json.groupId);
    const pub = (await env.api('GET', '/public/access')).json;
    assert.deepEqual([pub.mode, pub.checkout, pub.hybrid.maxRiders, pub.hybrid.maxHostedRidesPerMonth], ['hybrid', true, 3, 1]);
  });

  await t.test('switching to free during a ride lifts its limits at once (seats and features)', async () => {
    const r = await env.api('POST', '/convoys', { name: 'Lift me' }, d.token);
    assert.deepEqual([r.json.capacity, r.json.groupFeatures], [3, ['intercom']]);
    assert.equal((await setMode({ mode: 'free' })).status, 200);
    await new Promise((res) => setTimeout(res, 100));
    const room = await env.gw.convoys.getRoom(r.json.groupId);
    assert.deepEqual([room.meta.capacity, room.meta.groupFeatures], [12, null]);
    await end(d.token, r.json.groupId);
    assert.equal((await setMode({ mode: 'paid' })).status, 200);
  });

  await t.test('website plans page: shows "free right now" and hides checkout in free mode; the account page stays', async () => {
    const js = fs.readFileSync(path.join(__dirname, '../public/assets/plans.js'), 'utf8');
    assert.match(js, /'\/public\/access'/);
    assert.match(js, /CoRoute is free right now/);
    assert.match(js, /co\.hidden = true/, 'the checkout section is hidden');
    assert.match(js, /href', '\/account'/);
    const origin = env.base.replace(/\/api$/, '');
    for (const p of ['/plans', '/account']) assert.equal((await fetch(origin + p)).status, 200, p);
  });
});
