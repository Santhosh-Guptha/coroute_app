'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { MemorySoda } = require('../src/oracle/memory_soda');

let gw, base, soda;

before(async () => {
  soda = new MemorySoda();
  gw = await createApp({ soda, logger: { info() {}, warn() {}, error() {} } });
  await new Promise((r) => gw.server.listen(0, '127.0.0.1', r));
  const { port } = gw.server.address();
  base = `http://127.0.0.1:${port}/api`;
});

after(async () => {
  if (gw) await gw.shutdown();
});

async function api(method, path, body, token) {
  const res = await fetch(base + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, json };
}

test('admin management: groups, retention, user hold/block/delete, active convoy protection', async () => {
  // 1. Register admin and riders
  const admin = (await api('POST', '/auth/register', {
    name: 'Root Admin', email: 'admin@coroute.test', password: 'Password#123',
    phone: '+919876543210', vehicleType: 'Motorcycle',
  })).json;

  const rider1 = (await api('POST', '/auth/register', {
    name: 'Active Rider', email: 'rider1@coroute.test', password: 'Password#123',
    phone: '+919876543211', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  })).json;

  const rider2 = (await api('POST', '/auth/register', {
    name: 'Idle Rider', email: 'rider2@coroute.test', password: 'Password#123',
    phone: '+919876543212', vehicleType: 'Motorcycle', vehicleNo: 'TS09AB1234', emergencyContact: '+919000000001', emergencyContactName: 'Family Contact',
  })).json;

  // 2. Rider 1 creates a convoy and rides in it
  const convoyRes = await api('POST', '/convoys', { name: 'Active Mountain Convoy' }, rider1.token);
  const convoy = convoyRes.json;
  assert.ok(convoy.groupId);

  // 3. Admin checks /admin/groups
  const groupsRes = await api('GET', '/admin/groups', null, admin.token);
  assert.equal(groupsRes.status, 200);
  assert.ok(Array.isArray(groupsRes.json.active));
  assert.equal(groupsRes.json.active.length, 1);
  assert.equal(groupsRes.json.active[0].groupId, convoy.groupId);
  assert.ok(Array.isArray(groupsRes.json.completed));
  assert.ok(Array.isArray(groupsRes.json.approachingRetention));

  // 4. Admin checks /admin/users - rider1 must have activeGroup, rider2 must not
  const usersRes = await api('GET', '/admin/users', null, admin.token);
  assert.equal(usersRes.status, 200);
  const u1 = usersRes.json.users.find((u) => u.userId === rider1.user.userId);
  const u2 = usersRes.json.users.find((u) => u.userId === rider2.user.userId);
  assert.ok(u1);
  assert.ok(u2);
  assert.equal(u1.isInActiveConvoy, true);
  assert.equal(u1.activeGroup?.groupId, convoy.groupId);
  assert.equal(u2.isInActiveConvoy, false);

  // 5. RESTRICTION: Admin attempts to hold or block Rider 1 while active -> MUST BE REJECTED!
  const blockActiveRes = await api('PATCH', `/admin/users/${rider1.user.userId}/status`, { status: 'BLOCKED', reason: 'Violation' }, admin.token);
  assert.equal(blockActiveRes.status, 400);
  assert.equal(blockActiveRes.json.code, 'USER_IN_ACTIVE_CONVOY');

  const holdActiveRes = await api('PATCH', `/admin/users/${rider1.user.userId}/status`, { status: 'ON_HOLD', reason: 'Review' }, admin.token);
  assert.equal(holdActiveRes.status, 400);
  assert.equal(holdActiveRes.json.code, 'USER_IN_ACTIVE_CONVOY');

  // 6. Admin can hold or block Rider 2 (idle)
  const holdIdleRes = await api('PATCH', `/admin/users/${rider2.user.userId}/status`, { status: 'ON_HOLD', reason: 'Pending verification' }, admin.token);
  assert.equal(holdIdleRes.status, 200);
  assert.equal(holdIdleRes.json.user.status, 'ON_HOLD');

  // Rider 2 cannot log in while on hold
  const loginHeldRes = await api('POST', '/auth/login', { identifier: 'rider2@coroute.test', password: 'Password#123' });
  assert.equal(loginHeldRes.status, 403);
  assert.equal(loginHeldRes.json.code, 'ACCOUNT_ON_HOLD');

  // Un-hold Rider 2
  const unholdRes = await api('PATCH', `/admin/users/${rider2.user.userId}/status`, { status: 'ACTIVE' }, admin.token);
  assert.equal(unholdRes.status, 200);
  assert.equal(unholdRes.json.user.status, 'ACTIVE');

  // Block Rider 2
  const blockIdleRes = await api('PATCH', `/admin/users/${rider2.user.userId}/status`, { status: 'BLOCKED', reason: 'Terms violation' }, admin.token);
  assert.equal(blockIdleRes.status, 200);
  assert.equal(blockIdleRes.json.user.status, 'BLOCKED');

  const loginBlockedRes = await api('POST', '/auth/login', { identifier: 'rider2@coroute.test', password: 'Password#123' });
  assert.equal(loginBlockedRes.status, 403);
  assert.equal(loginBlockedRes.json.code, 'ACCOUNT_BLOCKED');

  // 7. Admin checks /admin/users/:userId/details for Rider 1
  const detailsRes = await api('GET', `/admin/users/${rider1.user.userId}/details`, null, admin.token);
  assert.equal(detailsRes.status, 200);
  assert.equal(detailsRes.json.user.userId, rider1.user.userId);
  assert.equal(detailsRes.json.isInActiveConvoy, true);
  assert.equal(detailsRes.json.activeGroup?.groupId, convoy.groupId);
  assert.ok(Array.isArray(detailsRes.json.groups));

  // 8. Admin immediate deletion of the convoy
  const deleteConvoyRes = await api('DELETE', `/admin/convoys/${convoy.groupId}`, null, admin.token);
  assert.equal(deleteConvoyRes.status, 200);
  assert.equal(deleteConvoyRes.json.ok, true);

  // Group is gone from active groups
  const groupsAfter = await api('GET', '/admin/groups', null, admin.token);
  assert.equal(groupsAfter.json.active.some((g) => g.groupId === convoy.groupId), false);

  // Rider 1 is no longer in active convoy, so admin can now hold Rider 1
  const holdNow = await api('PATCH', `/admin/users/${rider1.user.userId}/status`, { status: 'ON_HOLD' }, admin.token);
  assert.equal(holdNow.status, 200);
  assert.equal(holdNow.json.user.status, 'ON_HOLD');

  // 9. Admin delete user
  const deleteUserRes = await api('DELETE', `/admin/users/${rider2.user.userId}`, null, admin.token);
  assert.equal(deleteUserRes.status, 200);
  assert.equal(deleteUserRes.json.ok, true);

  const userAfter = await api('GET', `/admin/users/${rider2.user.userId}/details`, null, admin.token);
  assert.equal(userAfter.status, 404);
});
