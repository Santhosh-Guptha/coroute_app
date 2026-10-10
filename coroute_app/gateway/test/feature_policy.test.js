 'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'feature-admin@test.example';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { featurePolicy, policyPatch, roomAnalytics } = require('../src/feature_policy');
const { FeatureAnalytics } = require('../src/feature_analytics');
const { GuardianService } = require('../src/guardians');
const { boot } = require('./_helpers');

test('policy validates exact types, bounds and keys without changing defaults', () => {
  for (const patch of [{ guardianMaxHours: 0 }, { guardianMaxHours: 337 }, { guardianMaxHours: '24' },
    { guardianEnabled: 1 }, { emergencyEnabled: false }, { toString: true }, [], null]) assert.throws(() => policyPatch({}, patch));
  assert.equal(policyPatch({}, { guardianMaxHours: 1 }).guardianMaxHours, 1);
  assert.equal(featurePolicy({ guardianMaxHours: Infinity }).guardianMaxHours, 72);
  assert.equal(featurePolicy().guardianEnabled, true);
});

test('operational analytics are bounded allowlisted counts with explicit process scope', () => {
  const a = new FeatureAnalytics(() => 123);
  a.record('guardian', true, 20); a.record('guardian', false, 40); a.record('secret user', true);
  const out = a.snapshot();
  assert.equal(out.scope, 'this_gateway_process'); assert.equal(out.startedAt, 123);
  assert.deepEqual(out.features.find(r => r.feature === 'guardian'), { feature: 'guardian', measured: true,
    requests: 2, succeeded: 1, failed: 1, averageMs: 30, lastAt: 123 });
  assert.ok(!JSON.stringify(out).includes('secret user'));
  assert.equal(out.features.find(r => r.feature === 'voice').measured, false);
});

test('live analytics count fresh opt-in coverage without private values', () => {
  const room = { meta: {}, alerts: new Map(), riders: new Map([
    ['a', { lastSeenEpochMs: 200000, fuelEstimate: { usableKm: 12345, updatedAt: 200000 }, name: 'PRIVATE' }],
    ['b', { lastSeenEpochMs: 80000, fuelEstimate: { usableKm: 10, updatedAt: 200000 } }],
    ['c', { lastSeenEpochMs: 200001 }],
  ]) };
  const out = roomAnalytics(room, 200000);
  assert.equal(out.features.connectivity.fresh, 1); assert.equal(out.features.fuel.sharingFresh, 1);
  assert.ok(!JSON.stringify(out).includes('PRIVATE')); assert.ok(!JSON.stringify(out).includes('12345'));
});

test('lead policy is persistent, live, enforced and cannot be changed by ordinary riders', async () => {
  const t = await boot(); let leadWs, memberWs, adminWs;
  try {
    const lead = await t.register('Policy Lead', 'policy-lead@test.example');
    const member = await t.register('Policy Member', 'policy-member@test.example');
    const admin = await t.register('Feature Admin', 'feature-admin@test.example');
    const ride = (await t.api('POST', '/convoys', { name: 'Policy ride' }, lead.token)).json;
    await t.api('POST', '/convoys/join', { code: ride.joinCode }, member.token);
    leadWs = await t.joinRoom(lead.token, ride.groupId); memberWs = await t.joinRoom(member.token, ride.groupId);
    memberWs.sendJson({ type: 'CONFIG', featurePolicy: { guardianEnabled: false } });
    assert.equal((await memberWs.next(m => m.type === 'ERROR')).code, 403);
    leadWs.sendJson({ type: 'CONFIG', featurePolicy: { guardianRequirePin: true, guardianMaxHours: 6, groupFuelEnabled: false } });
    const changed = await memberWs.next(m => m.type === 'CONFIG');
    assert.equal(changed.featurePolicy.guardianMaxHours, 6);
    const room = await t.gw.convoys.getRoom(ride.groupId);
    const service = new GuardianService({ repo: t.gw.repo, convoys: t.gw.convoys });
    await assert.rejects(service.create(lead.user.userId, ride.groupId, { level: 'LIVE', acknowledged: true }), { status: 400 });
    const grant = await service.create(lead.user.userId, ride.groupId, { level: 'LIVE', acknowledged: true, pin: '1234' });
    assert.ok(grant.expiresAt - grant.createdAt <= 6 * 3600000);
    const oldSeen = room.riders.get(member.user.userId).lastSeenEpochMs;
    t.gw.convoys.patchRider(room, member.user.userId, { fuelEstimate: { usableKm: 50, confirmedAt: Date.now() } });
    assert.equal(room.riders.get(member.user.userId).fuelEstimate, null);
    assert.ok(oldSeen > 0);
    assert.equal((await t.gw.repo.getConvoyMeta(ride.groupId)).featurePolicy.guardianRequirePin, true);
    assert.equal((await t.api('GET', '/admin/feature-analytics', null, member.token)).status, 403);
    adminWs = await t.connect(admin.token); adminWs.sendJson({ type: 'ADMIN_SUBSCRIBE' });
    const fleet = await adminWs.next(m => m.type === 'FLEET');
    assert.ok(fleet.featureAnalytics.features.some(r => r.feature === 'configuration' && r.requests > 0));
    assert.ok(fleet.convoys[0].featureAnalytics.features.connectivity);
    leadWs.sendJson({ type: 'CONFIG', featurePolicy: { guardianEnabled: false } });
    await leadWs.next(m => m.type === 'CONFIG' && m.featurePolicy.guardianEnabled === false);
    await assert.rejects(service.exchange(grant.token, '1234'), { status: 410 });
  } finally { leadWs?.close(); memberWs?.close(); adminWs?.close(); await t.gw.shutdown(); }
});

test('failed configuration save is not published; queued edits merge after recovery', async () => {
  const t = await boot();
  try {
    const lead = await t.register('Save Lead', 'save-lead@test.example');
    const ride = (await t.api('POST', '/convoys', { name: 'Save ride' }, lead.token)).json;
    const manager = t.gw.convoys, room = await manager.getRoom(ride.groupId);
    const save = t.gw.repo.saveConvoyMeta.bind(t.gw.repo);
    t.gw.repo.saveConvoyMeta = async () => { throw new Error('database unavailable'); };
    await assert.rejects(manager.updateConfig(ride.groupId, lead.user, { featurePolicy: { guardianEnabled: false } }));
    assert.equal(featurePolicy(room.meta.featurePolicy).guardianEnabled, true);
    t.gw.repo.saveConvoyMeta = save;
    await Promise.all([
      manager.updateConfig(ride.groupId, lead.user, { featurePolicy: { guardianMaxHours: 24 } }),
      manager.updateConfig(ride.groupId, lead.user, { featurePolicy: { guardianRequirePin: true } }),
    ]);
    const saved = await t.gw.repo.getConvoyMeta(ride.groupId);
    assert.equal(saved.featurePolicy.guardianMaxHours, 24);
    assert.equal(saved.featurePolicy.guardianRequirePin, true);
  } finally { await t.gw.shutdown(); }
});
