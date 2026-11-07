'use strict';
/**
 * 3.55 safety & stability review: regression tests for the defects found in the release review
 * (docs/SAFETY_SCENARIO_REVIEW_v3.55.md).
 *
 *  1. The riding lead (a non-owner since 3.55) leaves the ride: the owner takes the lead back, so the
 *     ride is never left without a LEAD.
 *  2. Automatic roles never move the sweeper role onto a rider who is dropping behind the sweeper
 *     (BEHIND_SWEEPER must fire for them, not be closed as SWEEPER_CHANGED).
 *  3. "Fixed?" on a saved road report counts once per rider.
 *  4. A membership left by an earlier account with the same userId never hides the plan the new
 *     account just got (it is retired), and its seats never block an admin grant.
 *  5. The unattended orphan-plan purge removes nothing when a large share of owners looks missing.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'review.admin@coroute.test';

const { test, before, after, mock } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

const T0 = Date.UTC(2026, 10, 7, 6, 0, 0);
let t, gw, now = T0;
before(async () => { mock.timers.enable({ apis: ['Date'], now: T0 }); t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); mock.timers.reset(); });
const advance = (ms) => { now += ms; mock.timers.setTime(now); };

let n = 0;
async function ride(body = {}) {
  n++;
  const lead = await t.register(`Owner ${n}`, `revowner${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Review ${n}`, ...body }, lead.token)).json;
  const members = [];
  for (const tag of ['Asha', 'Kiran', 'Arjun']) {
    n++;
    const u = await t.register(`${tag} ${n}`, `rev${n}@coroute.test`);
    assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, u.token)).status, 200);
    members.push(u);
  }
  await sleep(30);
  return { lead, c, gid: c.groupId, room: gw.convoys.rooms.get(c.groupId), members };
}
const uid = (u) => u.user.userId;
const role = (R, u) => R.room.riders.get(uid(u))?.role;
const leads = (R) => [...R.room.riders.values()].filter((r) => r.role === 'LEAD').map((r) => r.userId);
const events = async (gid, type) => (await gw.repo.listEvents(gid, { limit: 1000 })).filter((e) => e.type === type);
async function fix(room, u, lat, lng, speedKmh = 50) {
  gw.convoys.patchRider(room, uid(u), { lat, lng, speedKmh }, { emit: false });
  await gw.timeline.idle();
}
const asOwner = (R) => ({ userId: uid(R.lead), name: 'Owner', role: 'RIDER' });

test('the riding lead leaves: the owner takes the lead back and the riders are told (never a ride without a lead)', async () => {
  const R = await ride();
  const [asha, kiran] = R.members;
  await gw.convoys.setRole(R.gid, asOwner(R), uid(asha), 'SWEEPER');
  await gw.convoys.setRole(R.gid, asOwner(R), uid(kiran), 'LEAD');
  assert.deepEqual(leads(R), [uid(kiran)]);
  assert.equal(role(R, R.lead), 'PACK');

  const wa = await t.joinRoom(asha.token, R.gid);
  assert.equal((await t.api('POST', `/convoys/${R.gid}/leave`, {}, kiran.token)).status, 200);
  const change = await wa.next((m) => m.type === 'ROLE_CHANGE');
  assert.deepEqual(change.changes.map((c) => [c.userId, c.from, c.to]), [[uid(R.lead), 'PACK', 'LEAD']]);
  assert.deepEqual(leads(R), [uid(R.lead)], 'exactly one lead again: the owner');
  assert.equal(role(R, asha), 'SWEEPER', 'the sweeper is untouched');
  // The incident notify list has a lead to call again.
  assert.ok(gw.timeline._leadsAndSweeper(R.room, uid(asha)).includes(uid(R.lead)));

  // A non-lead leaving changes nothing.
  const [, , arjun] = R.members;
  assert.equal((await t.api('POST', `/convoys/${R.gid}/leave`, {}, arjun.token)).status, 200);
  assert.deepEqual(leads(R), [uid(R.lead)]);
  wa.close();
  await t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);
});

test('automatic roles keep the sweeper while a rider drops behind them: BEHIND_SWEEPER opens for that rider', async () => {
  const R = await ride({ start: { lat: 17.0, lng: 78.0, name: 'Start' }, destination: 'End', destLat: 17.3, destLng: 78.0 });
  assert.ok(R.room.meta.route && R.room.meta.route.polyline, 'a straight route exists');
  const [asha, kiran, arjun] = R.members;
  await gw.convoys.setRole(R.gid, asOwner(R), uid(asha), 'SWEEPER');
  await gw.convoys.setAutoRoles(R.gid, asOwner(R), true);
  // Asha sweeps at 17.110; Arjun has fallen ~1.1 km behind her (a flat tyre, riding slowly).
  for (let i = 0; i < 12; i++) {
    advance(10000);
    await fix(R.room, R.lead, 17.120, 78.0);
    await fix(R.room, kiran, 17.115, 78.0);
    await fix(R.room, asha, 17.110, 78.0);
    await fix(R.room, arjun, 17.100, 78.0, 20);
  }
  assert.equal(role(R, asha), 'SWEEPER', 'the sweeper keeps the role');
  assert.notEqual(role(R, arjun), 'SWEEPER', 'the rider who dropped back is not made the sweeper');
  const behind = await events(R.gid, 'BEHIND_SWEEPER');
  assert.equal(behind.length, 1, 'the dropped rider is reported behind the sweeper');
  assert.equal(behind[0].userId, uid(arjun));
  assert.equal(behind[0].open, true);
  assert.equal(behind[0].data.sweeperId, uid(asha));
  assert.deepEqual(leads(R), [uid(R.lead)], 'the front rider (the owner) still leads');

  // Arjun catches up and Asha drops to the back within the BEHIND distance: roles may follow the order.
  for (let i = 0; i < 20; i++) {
    advance(10000);
    await fix(R.room, R.lead, 17.200, 78.0);
    await fix(R.room, kiran, 17.198, 78.0);
    await fix(R.room, arjun, 17.196, 78.0);
    await fix(R.room, asha, 17.1945, 78.0); // ~170 m behind Arjun (>150 m gap, <300 m BEHIND)
  }
  assert.equal(role(R, asha), 'SWEEPER');
  assert.equal((await events(R.gid, 'BEHIND_SWEEPER'))[0].open, false, 'closed once Arjun is back ahead');
  await t.api('POST', `/convoys/${R.gid}/status`, { status: 'ENDED' }, R.lead.token);
});

test('"Fixed?" on a saved road report counts once per rider', async () => {
  const a = await t.register('Clear A', 'clear.a@coroute.test');
  const b = await t.register('Clear B', 'clear.b@coroute.test');
  const { roadRecordOf } = require('../src/road_and_places');
  const saved = await gw.repo.saveRoadHazard(roadRecordOf({ hazardId: 'rh_review1', lat: 17.4, lng: 78.5, classification: 'POTHOLE', severity: 'HIGH' }, Date.now()), { reporterKey: 'k1' });
  assert.equal(saved.reports, 1);
  const near = async (tok) => (await t.api('GET', '/road-hazards/near?lat=17.4&lng=78.5', null, tok)).json.hazards.map((h) => h.hazardId);
  for (let i = 0; i < 3; i++) {
    const r = await t.api('POST', '/road-hazards/rh_review1/clear', {}, a.token);
    assert.equal(r.status, 200);
    assert.equal(r.json.removed, false, 'one rider tapping again never removes it');
  }
  assert.ok((await near(b.token)).includes('rh_review1'), 'still warned to everyone');
  const r = await t.api('POST', '/road-hazards/rh_review1/clear', {}, b.token);
  assert.equal(r.json.removed, true, 'a second rider confirms: removed');
  assert.ok(!(await near(a.token)).includes('rh_review1'));
  const stored = (await gw.soda.findOne('road_hazards', { hazardId: 'rh_review1' })).value;
  assert.ok(!JSON.stringify(stored).includes(uid(a)) && !JSON.stringify(stored).includes(uid(b)), 'no rider id stored');
});

test('a plan left by an earlier account with the same userId never hides the plan the rider gets now', async () => {
  const admin = await t.register('Review Admin', 'review.admin@coroute.test');
  const host = await t.register('Ravi Host', 'ravi.host@coroute.test');
  const hostId = uid(host);
  const t0 = Date.now();
  // Left over from an erased account that had this userId: 300 days left, 9 members in it.
  const members = {};
  for (let i = 0; i < 9; i++) members[`usr_old${i}`] = { userId: `usr_old${i}`, status: 'ACCEPTED' };
  await gw.repo.saveMembership({
    membershipId: 'mem_previous_account', ownerUserId: hostId, category: 'group_large', categoryName: 'Large Group', capacity: 12,
    status: 'ACTIVE', validFrom: t0 - 90 * 86400000, validUntil: t0 + 300 * 86400000, createdAt: t0 - 90 * 86400000, members,
  });
  let mine = await t.api('GET', '/membership/my', null, host.token);
  assert.equal(mine.json.plan.category === 'group_large', false, 'the leftover is not this rider\'s plan');

  // The admin gives Small Group (6 seats) for 30 days: the 9 seats of the leftover do not block it,
  // and the plan shows at once (the leftover ran longer and used to be found first).
  const r = await t.api('PATCH', `/admin/users/${hostId}/config`, { plan: { tier: 'group_small', days: 30 } }, admin.token);
  assert.equal(r.status, 200, JSON.stringify(r.json));
  mine = await t.api('GET', '/membership/my', null, host.token);
  assert.equal(mine.json.plan.category, 'group_small', JSON.stringify(mine.json.plan));
  const old = await gw.repo.findMembershipById('mem_previous_account');
  assert.equal(old.status, 'EXPIRED');
  assert.equal(old.statusReason, 'PREVIOUS_ACCOUNT');
  const current = await gw.repo.findMembershipByOwner(hostId);
  assert.notEqual(current.membershipId, 'mem_previous_account');
  assert.deepEqual(Object.keys(current.members || {}), [], 'the new plan starts with no leftover members');
});

test('the unattended orphan-plan purge removes nothing when many owners look missing (bad read, partial restore)', async () => {
  const t0 = Date.now();
  for (let i = 0; i < 12; i++) {
    await gw.repo.saveMembership({ membershipId: `mem_ghost${i}`, ownerUserId: `usr_ghost${i}`, category: 'group_small', status: 'ACTIVE', validUntil: t0 + 86400000, createdAt: t0, members: {} });
  }
  const out = await gw.repo.purgeOrphanMemberships();
  assert.equal(out.orphanMembershipsRemoved, 0);
  assert.ok(out.orphanPurgeSkipped >= 12);
  assert.ok(await gw.repo.findMembershipById('mem_ghost0'), 'kept for an admin to look at');
});
