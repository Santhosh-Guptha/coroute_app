'use strict';
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true'; // Enable monetization gating for this test suite
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

test('Membership, Monetization, Ownership & Trip Management Suite', async (t) => {
  const env = await boot();
  t.after(() => { env.gw.shutdown(); });

  let adminUser, adminToken;
  let ownerUser, ownerToken;
  let headUser, headToken;
  let riderA, riderAToken;
  let riderB, riderBToken;
  let riderC, riderCToken;

  await t.test('setup users: admin, owner, head, riders', async () => {
    const adm = await env.register('Admin', 'admin@coroute.test');
    adminUser = adm.user;
    adminToken = adm.token;

    const own = await env.register('Trip Owner', 'owner@coroute.test');
    ownerUser = own.user;
    ownerToken = own.token;

    const hd = await env.register('Trip Head', 'head@coroute.test');
    headUser = hd.user;
    headToken = hd.token;

    const ra = await env.register('Rider A', 'ra@coroute.test');
    riderA = ra.user;
    riderAToken = ra.token;

    const rb = await env.register('Rider B', 'rb@coroute.test');
    riderB = rb.user;
    riderBToken = rb.token;

    const rc = await env.register('Rider C', 'rc@coroute.test');
    riderC = rc.user;
    riderCToken = rc.token;
  });

  // =========================================================================
  // 1. Catalog & Initial Values
  // =========================================================================

  await t.test('GET /api/membership/catalog returns initial categories: ₹9, ₹49, ₹99', async () => {
    const res = await env.api('GET', '/membership/catalog');
    assert.equal(res.status, 200);
    assert.ok(res.json.categories);

    const ind = res.json.categories.individual;
    assert.equal(ind.monthlyPriceInr, 9);
    assert.equal(ind.capacity, 1);
    assert.equal(ind.entitlements.ptt, false);
    assert.equal(ind.entitlements.convoy, false);

    const sm = res.json.categories.group_small;
    assert.equal(sm.monthlyPriceInr, 49);
    assert.equal(sm.capacity, 6);
    assert.equal(sm.entitlements.ptt, true);
    assert.equal(sm.entitlements.convoy, true);

    const lg = res.json.categories.group_large;
    assert.equal(lg.monthlyPriceInr, 99);
    assert.equal(lg.capacity, 12);
    assert.equal(lg.entitlements.ptt, true);
    assert.equal(lg.entitlements.convoy, true);
  });

  // =========================================================================
  // 2. Membership Purchase & Permanent Ownership
  // =========================================================================

  await t.test('POST /api/membership/purchase requires payment or valid offer', async () => {
    // Attempting to purchase without payment or offer returns 402
    const failRes = await env.api('POST', '/membership/purchase', { category: 'group_small' }, ownerToken);
    assert.equal(failRes.status, 402);
    assert.equal(failRes.json.reason, 'PAYMENT_REQUIRED');
    assert.equal(failRes.json.amountInr, 49);

    // Invalid category returns 400
    const invalidRes = await env.api('POST', '/membership/purchase', { category: 'non_existent_tier' }, ownerToken);
    assert.equal(invalidRes.status, 400);
    assert.equal(invalidRes.json.reason, 'INVALID_CATEGORY');
  });

  await t.test('POST /api/membership/purchase activates with introductory 100% offer RIDERFREE', async () => {
    const res = await env.api('POST', '/membership/purchase', {
      category: 'group_small',
      offerCode: 'RIDERFREE',
    }, ownerToken);

    assert.equal(res.status, 201);
    assert.equal(res.json.membership.ownerUserId, ownerUser.userId);
    assert.equal(res.json.membership.category, 'group_small');
    assert.equal(res.json.membership.capacity, 6);
    assert.equal(res.json.membership.status, 'ACTIVE');
    assert.ok(res.json.membership.validUntil > Date.now() + 25 * 86400000);
  });

  await t.test('GET /api/membership/my reflects owned membership and group entitlements', async () => {
    const res = await env.api('GET', '/membership/my', null, ownerToken);
    assert.equal(res.status, 200);
    assert.ok(res.json.owned);
    assert.equal(res.json.owned.ownerUserId, ownerUser.userId);
    assert.equal(res.json.effectiveEntitlements.ptt, true);
    assert.equal(res.json.effectiveEntitlements.convoy, true);
  });

  // =========================================================================
  // 3. Member Invitations & Seat Capacity Rules
  // =========================================================================

  await t.test('POST /api/membership/members/invite: owner invites group participants', async () => {
    // Non-owner cannot invite
    const failRes = await env.api('POST', '/membership/members/invite', { email: 'ra@coroute.test' }, riderAToken);
    assert.equal(failRes.status, 403);

    // Owner cannot invite themselves
    const selfRes = await env.api('POST', '/membership/members/invite', { email: 'owner@coroute.test' }, ownerToken);
    assert.equal(selfRes.status, 400);
    assert.equal(selfRes.json.reason, 'OWNER_CANNOT_INVITE_SELF');

    // Owner invites Head, Rider A, Rider B
    const invHead = await env.api('POST', '/membership/members/invite', { email: 'head@coroute.test' }, ownerToken);
    assert.equal(invHead.status, 200);

    const invA = await env.api('POST', '/membership/members/invite', { email: 'ra@coroute.test' }, ownerToken);
    assert.equal(invA.status, 200);

    const invB = await env.api('POST', '/membership/members/invite', { email: 'rb@coroute.test' }, ownerToken);
    assert.equal(invB.status, 200);

    // Duplicate invite rejected
    const dupRes = await env.api('POST', '/membership/members/invite', { email: 'ra@coroute.test' }, ownerToken);
    assert.equal(dupRes.status, 409);
    assert.equal(dupRes.json.reason, 'ALREADY_MEMBER');
  });

  await t.test('Group seat capacity enforcement: cannot exceed purchased capacity of 6', async () => {
    // Currently owner (1) + head (1) + rider A (1) + rider B (1) = 4 seats used
    // Invite Rider C (5th seat)
    const invC = await env.api('POST', '/membership/members/invite', { email: 'rc@coroute.test' }, ownerToken);
    assert.equal(invC.status, 200);

    // Register Rider D and invite (6th seat -> fills capacity of 6!)
    const rd = await env.register('Rider D', 'rd@coroute.test');
    const invD = await env.api('POST', '/membership/members/invite', { email: 'rd@coroute.test' }, ownerToken);
    assert.equal(invD.status, 200);
    assert.equal(invD.json.remainingSeats, 0);

    // Register Rider E and try to invite (7th seat -> MUST BE BLOCKED!)
    const re = await env.register('Rider E', 're@coroute.test');
    const invE = await env.api('POST', '/membership/members/invite', { email: 're@coroute.test' }, ownerToken);
    assert.equal(invE.status, 409);
    assert.equal(invE.json.reason, 'MEMBERSHIP_CAPACITY_EXCEEDED');
  });

  await t.test('POST /api/membership/members/respond: invited rider accepts invitation', async () => {
    const ownerMem = (await env.api('GET', '/membership/my', null, ownerToken)).json.owned;

    // Head accepts invitation
    const acceptHead = await env.api('POST', '/membership/members/respond', {
      membershipId: ownerMem.membershipId,
      action: 'ACCEPT',
    }, headToken);
    assert.equal(acceptHead.status, 200);
    assert.equal(acceptHead.json.action, 'ACCEPT');

    // Rider A accepts invitation
    const acceptA = await env.api('POST', '/membership/members/respond', {
      membershipId: ownerMem.membershipId,
      action: 'ACCEPT',
    }, riderAToken);
    assert.equal(acceptA.status, 200);

    // Rider A now sees participating membership and inherited group entitlements
    const myA = await env.api('GET', '/membership/my', null, riderAToken);
    assert.equal(myA.status, 200);
    assert.equal(myA.json.participating.length, 1);
    assert.equal(myA.json.effectiveEntitlements.ptt, true);
    assert.equal(myA.json.effectiveEntitlements.convoy, true);
  });

  // =========================================================================
  // 4. Trip Governance & Two-Role Model (Trip Owner vs Trip Head)
  // =========================================================================

  let activeGroupId = '';
  let activeJoinCode = '';

  await t.test('Owner creates convoy: assigned Trip Owner & Trip Head; active trip locked', async () => {
    const res = await env.api('POST', '/convoys', { name: 'Weekend Himalayas Ride' }, ownerToken);
    assert.equal(res.status, 201);
    activeGroupId = res.json.groupId;
    activeJoinCode = res.json.joinCode;

    // Verify active trip registry
    const lock = await env.gw.repo.getActiveTrip(ownerUser.userId);
    assert.ok(lock);
    assert.equal(lock.groupId, activeGroupId);
    assert.equal(lock.role, 'OWNER');
  });

  await t.test('Single Active Trip Concurrency Lock: Owner cannot create second trip simultaneously', async () => {
    const conflictRes = await env.api('POST', '/convoys', { name: 'Second Ride Attempt' }, ownerToken);
    assert.equal(conflictRes.status, 409);
    assert.equal(conflictRes.json.reason, 'ACTIVE_TRIP_CONFLICT');
  });

  await t.test('Invited members join active trip; active trip locked for participants', async () => {
    // Head joins
    const joinHead = await env.api('POST', '/convoys/join', { code: activeJoinCode }, headToken);
    assert.equal(joinHead.status, 200);

    // Rider A joins
    const joinA = await env.api('POST', '/convoys/join', { code: activeJoinCode }, riderAToken);
    assert.equal(joinA.status, 200);

    // Verify locks
    const lockHead = await env.gw.repo.getActiveTrip(headUser.userId);
    assert.equal(lockHead.groupId, activeGroupId);

    const lockA = await env.gw.repo.getActiveTrip(riderA.userId);
    assert.equal(lockA.groupId, activeGroupId);
  });

  await t.test('Single Active Trip Concurrency Lock: Participant cannot join another trip simultaneously', async () => {
    // Create an independent trip by admin
    // Give admin an active membership first
    await env.gw.repo.saveMembership({
      membershipId: 'mem_admin',
      ownerUserId: adminUser.userId,
      category: 'group_small',
      capacity: 6,
      status: 'ACTIVE',
      validUntil: Date.now() + 30 * 86400000,
    });
    const adminTrip = (await env.api('POST', '/convoys', { name: 'Admin Route' }, adminToken)).json;

    // Rider A (already in activeGroupId) attempts to join adminTrip -> MUST BE BLOCKED!
    const conflictJoin = await env.api('POST', '/convoys/join', { code: adminTrip.joinCode }, riderAToken);
    assert.equal(conflictJoin.status, 409);
    assert.equal(conflictJoin.json.reason, 'ACTIVE_TRIP_CONFLICT');

    // Clean up admin trip
    await env.api('POST', `/convoys/${adminTrip.groupId}/status`, { status: 'ENDED' }, adminToken);
  });

  await t.test('Two-Role Model: Trip Owner assigns Trip Head; Trip Head is operational leader', async () => {
    // Non-owner cannot assign Trip Head
    const failAssign = await env.api('POST', `/convoys/${activeGroupId}/trip-head`, {
      targetUserId: riderA.userId,
    }, riderAToken);
    assert.equal(failAssign.status, 403);
    assert.equal(failAssign.json.reason, 'OWNER_ONLY');

    // Trip Owner assigns Trip Head to headUser
    const assignRes = await env.api('POST', `/convoys/${activeGroupId}/trip-head`, {
      targetUserId: headUser.userId,
    }, ownerToken);
    assert.equal(assignRes.status, 200);

    // Room now shows headUser with role LEAD
    const room = await env.gw.convoys.getRoom(activeGroupId);
    assert.equal(room.meta.tripHeadUserId, headUser.userId);
    assert.equal(room.riders.get(headUser.userId).role, 'LEAD');
  });

  await t.test('Two-Role Model: Trip Head CANNOT remove participants; Trip Owner CAN', async () => {
    // Trip Head attempts to remove Rider A -> MUST FAIL with 403 OWNER_ONLY
    const failRemove = await env.api('DELETE', `/convoys/${activeGroupId}/riders/${riderA.userId}`, null, headToken);
    assert.equal(failRemove.status, 403);
    assert.equal(failRemove.json.reason, 'OWNER_ONLY');

    // Rider A is still in the convoy
    const roomBefore = await env.gw.convoys.getRoom(activeGroupId);
    assert.ok(roomBefore.riders.has(riderA.userId));

    // Trip Owner removes Rider A -> SUCCEEDS
    const successRemove = await env.api('DELETE', `/convoys/${activeGroupId}/riders/${riderA.userId}`, null, ownerToken);
    assert.equal(successRemove.status, 200);

    // Rider A is gone from the convoy and their active trip lock is released
    const roomAfter = await env.gw.convoys.getRoom(activeGroupId);
    assert.ok(!roomAfter.riders.has(riderA.userId));

    const lockA = await env.gw.repo.getActiveTrip(riderA.userId);
    assert.equal(lockA, null);
  });

  await t.test('Two-Role Model: Trip Owner cannot remove themselves (must end trip)', async () => {
    const failSelf = await env.api('DELETE', `/convoys/${activeGroupId}/riders/${ownerUser.userId}`, null, ownerToken);
    assert.equal(failSelf.status, 400);
    assert.equal(failSelf.json.reason, 'CANNOT_REMOVE_OWNER');
  });

  // =========================================================================
  // 5. Safety-First Mid-Trip Expiry Continuity
  // =========================================================================

  await t.test('Mid-trip expiry: active trip continues uninterrupted, but new trip is blocked after end', async () => {
    // Simulate membership expiration mid-ride
    const ownerMem = await env.gw.repo.findMembershipByOwner(ownerUser.userId);
    ownerMem.validUntil = Date.now() - 1000; // Expired 1 second ago
    await env.gw.repo.saveMembership(ownerMem);

    // Active trip room is still completely alive and operational
    const room = await env.gw.convoys.getRoom(activeGroupId);
    assert.equal(room.meta.tripStatus, 'STARTED');
    assert.ok(room.riders.has(ownerUser.userId));
    assert.ok(room.riders.has(headUser.userId));

    // Operational functions (e.g. status updates) work unhindered
    const statusRes = await env.api('POST', `/convoys/${activeGroupId}/status`, { status: 'PAUSED' }, headToken);
    assert.equal(statusRes.status, 200);

    // End the trip
    const endRes = await env.api('POST', `/convoys/${activeGroupId}/status`, { status: 'ENDED' }, ownerToken);
    assert.equal(endRes.status, 200);

    // Active trip locks are completely cleared
    const lockOwner = await env.gw.repo.getActiveTrip(ownerUser.userId);
    assert.equal(lockOwner, null);
    const lockHead = await env.gw.repo.getActiveTrip(headUser.userId);
    assert.equal(lockHead, null);

    // Owner now attempts to create a NEW trip with expired membership -> BLOCKED with 402!
    const newTripRes = await env.api('POST', '/convoys', { name: 'Expired Owner Trip' }, ownerToken);
    assert.equal(newTripRes.status, 402);
    assert.equal(newTripRes.json.reason, 'MEMBERSHIP_EXPIRED');
  });

  // =========================================================================
  // 6. Platform Admin Catalog Configuration & Aggregate Analytics
  // =========================================================================

  await t.test('Platform Admin updates membership catalog dynamically', async () => {
    const catalog = await env.gw.repo.getMembershipCatalog();
    catalog.individual.monthlyPriceInr = 12; // Update pricing

    const updateRes = await env.api('PUT', '/admin/membership/catalog', { catalog }, adminToken);
    assert.equal(updateRes.status, 200);

    const checkRes = await env.api('GET', '/membership/catalog');
    assert.equal(checkRes.json.categories.individual.monthlyPriceInr, 12);
  });

  await t.test('Platform Admin views privacy-safe aggregate analytics (zero raw GPS)', async () => {
    const res = await env.api('GET', '/admin/membership/analytics', null, adminToken);
    assert.equal(res.status, 200);
    assert.ok(res.json.activeMemberships);
    assert.ok(res.json.seatUtilization);
    assert.ok(res.json.financialMetrics);
    assert.ok(res.json.concurrency);

    // Ensure zero raw GPS coordinates leak into admin analytics
    const jsonStr = JSON.stringify(res.json);
    assert.ok(!jsonStr.includes('lat'));
    assert.ok(!jsonStr.includes('lng'));
    assert.ok(!jsonStr.includes('routeBreadcrumbs'));
  });
});

