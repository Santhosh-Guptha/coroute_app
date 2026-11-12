'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'plans.admin@coroute.test';

// 3.55: the console assigns real plans (memberships), and data cleanup removes memberships too.
const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const { adminPlanId } = require('../src/admin_plans');
const { belongsToAccount, planFrom } = require('../src/entitlements');

test('adminPlanId maps console values and legacy tiers to the plans riders have', () => {
  assert.equal(adminPlanId('group_small'), 'group_small');
  assert.equal(adminPlanId('proRider'), 'group_small');
  assert.equal(adminPlanId('roadCaptain'), 'group_large');
  assert.equal(adminPlanId('Large Group'), 'group_large');
  assert.equal(adminPlanId('community'), 'community');
  assert.equal(adminPlanId('diamond'), null);
  assert.equal(adminPlanId(''), null);
});

test('a membership left by an earlier account with the same userId is not the new rider\'s plan', () => {
  const now = Date.now();
  const old = { membershipId: 'm1', ownerUserId: 'usr_ravi', category: 'group_small', status: 'ACTIVE', validUntil: now + 9 * 86400000, createdAt: now - 30 * 86400000, capacity: 6 };
  const fresh = { userId: 'usr_ravi', createdAt: now - 3600000 };
  assert.equal(belongsToAccount(old, fresh), false);
  assert.equal(planFrom({ membership: old, userDoc: fresh, now }).source, 'community');
  const owner = { userId: 'usr_ravi', createdAt: now - 60 * 86400000 };
  assert.equal(belongsToAccount(old, owner), true);
  assert.equal(planFrom({ membership: old, userDoc: owner, now }).category, 'group_small');
});

test('admin plan assignment and data cleanup', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, gw } = env;
  const admin = await env.register('Plans Admin', 'plans.admin@coroute.test');
  const host = await env.register('Host Rider', 'host.rider@coroute.test');
  const pal = await env.register('Pal Rider', 'pal.rider@coroute.test');
  const A = admin.token;
  const hostId = host.user.userId;
  const palId = pal.user.userId;

  await t.test('assigning Small Group shows in the rider app and in the riders list', async () => {
    const r = await api('PATCH', `/admin/users/${hostId}/config`, { plan: { tier: 'group_small', days: 30, note: 'club' } }, A);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    const mine = await api('GET', '/membership/my', null, host.token);
    assert.equal(mine.json.plan.category, 'group_small');
    assert.equal(mine.json.plan.seats, 6);
    // Put Pal in the host's plan, then try to give the host a plan with too few seats.
    const m = await gw.repo.findMembershipByOwner(hostId);
    await gw.repo.saveMembership({ ...m, members: { [palId]: { userId: palId, status: 'ACCEPTED' } } });
    const list = await api('GET', '/admin/analytics/riders?tier=group_small&staff=all', null, A);
    assert.ok(list.json.riders.some((x) => x.userId === hostId && x.planName));
  });

  await t.test('a legacy tier with more seats never outranks the plan the admin gave', async () => {
    const u = await gw.repo.findUserById(hostId);
    await gw.repo.updateUser(u.key, { subscriptionTier: 'roadCaptain', subscriptionValidUntil: Date.now() + 20 * 86400000 });
    gw.gate.invalidate(hostId);
    const r = await api('PATCH', `/admin/users/${hostId}/config`, { plan: { tier: 'group_small', days: 5 } }, A);
    assert.equal(r.status, 200, JSON.stringify(r.json));
    assert.equal(r.json.config.plan.tier, 'group_small');
    assert.equal(r.json.config.plan.source, 'membership');
    assert.equal((await gw.repo.findUserById(hostId)).subscriptionTier, 'community', 'the legacy tier was ended');
  });

  await t.test('deleting an account removes its memberships and frees its seat in other plans', async () => {
    assert.ok(await gw.repo.findMembershipByOwner(hostId));
    // Pal also owns a plan; deleting Pal frees Pal's seat in the host's plan.
    await api('PATCH', `/admin/users/${palId}/config`, { plan: { tier: 'group_large', days: 10 } }, A);
    const del = await api('DELETE', `/admin/users/${palId}`, null, A);
    assert.equal(del.status, 200, JSON.stringify(del.json));
    assert.equal(await gw.repo.findMembershipByOwner(palId), null, 'Pal\'s own plan is gone');
    const hostPlan = await gw.repo.findMembershipByOwner(hostId);
    assert.ok(!Object.hasOwn(hostPlan.members || {}, palId), 'Pal left the host\'s plan');

    const me = await api('DELETE', '/me', { currentPassword: 'Password#123' }, host.token);
    assert.equal(me.status, 200, JSON.stringify(me.json));
    const left = await gw.soda.query('memberships', { ownerUserId: hostId }, { limit: 10 });
    assert.equal(left.length, 0, 'the host\'s plan went with the account');
  });

  await t.test('orphan memberships (owner erased before 3.55) are cleaned by reconcile and retention', async () => {
    const now = Date.now();
    await gw.repo.saveMembership({ membershipId: 'mem_orphan', ownerUserId: 'usr_gone', category: 'group_small', status: 'ACTIVE', validUntil: now + 86400000, createdAt: now, members: {} });
    const rec = await api('POST', '/admin/membership/reconcile', {}, A);
    assert.equal(rec.status, 200, JSON.stringify(rec.json));
    assert.equal(rec.json.orphanMembershipsRemoved, 1);
    assert.equal(await gw.repo.findMembershipById('mem_orphan'), null);
    await gw.repo.saveMembership({ membershipId: 'mem_orphan2', ownerUserId: 'usr_gone2', category: 'group_small', status: 'ACTIVE', validUntil: now + 86400000, createdAt: now, members: {} });
    const out = await gw.repo.purgeOrphanMemberships();
    assert.equal(out.orphanMembershipsRemoved, 1);
  });
});
