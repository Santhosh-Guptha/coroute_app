'use strict';
process.env.NODE_ENV = 'test';
process.env.PAYMENTS_ENABLED = 'true';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

test('Public Community Stats & Post-Trip Feedback Review Suite', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());

  let adminUser, adminToken;
  let riderUser, riderToken;

  await t.test('setup admin and test rider', async () => {
    const adm = await env.register('Admin User', 'admin@coroute.test');
    adminUser = adm.user;
    adminToken = adm.token;

    const rdr = await env.register('Rider Alpha', 'rideralpha@coroute.test');
    riderUser = rdr.user;
    riderToken = rdr.token;

    // Seed a couple completed trips in repository
    await env.gw.repo.saveTrip({
      tripId: 'TRIP-TEST-100',
      userId: riderUser.userId,
      tripName: 'Chennai Coastal Run',
      startTimeEpochMs: Date.now() - 3600000 * 5,
      endTimeEpochMs: Date.now(),
      totalDistanceKm: 285.5,
      movingMs: 3600000 * 4.5,
    });

    await env.gw.repo.saveTrip({
      tripId: 'TRIP-TEST-200',
      userId: riderUser.userId,
      tripName: 'Nilgiris Hill Climb',
      startTimeEpochMs: Date.now() - 3600000 * 8,
      endTimeEpochMs: Date.now(),
      totalDistanceKm: 420.0,
      movingMs: 3600000 * 7,
    });
  });

  await t.test('GET /public/community-stats returns privacy-safe aggregated statistics', async () => {
    const res = await env.api('GET', '/public/community-stats');
    assert.equal(res.status, 200);
    const body = res.json;

    assert.equal(body.enabled, true);
    assert.ok(typeof body.totalRiders === 'number' && body.totalRiders >= 2);
    assert.ok(typeof body.totalKilometers === 'number' && body.totalKilometers >= 700);
    assert.ok(Array.isArray(body.longestTrips));
    assert.ok(body.longestTrips.length >= 2);

    // Verify longest trip ordering
    const topTrip = body.longestTrips[0];
    assert.equal(topTrip.rank, 1);
    assert.equal(topTrip.distanceKm, 420);
    assert.equal(topTrip.anonymousRiderLabel, 'Rider #1');
    assert.ok(!topTrip.userId, 'Must not expose userId');
    assert.ok(!topTrip.coordinates, 'Must not expose coordinates');
    assert.ok(!topTrip.userEmail, 'Must not expose email');
  });

  await t.test('Admin can configure community stats visibility toggles', async () => {
    // Rider cannot configure
    const forbidden = await env.api('PUT', '/admin/community-stats/config', { showLongestTrips: false }, riderToken);
    assert.equal(forbidden.status, 403);

    // Admin can configure
    const putRes = await env.api('PUT', '/admin/community-stats/config', {
      showLongestTrips: false,
      showAnonymousLabels: true,
      labelPrefix: 'Pilot',
    }, adminToken);
    assert.equal(putRes.status, 200);
    assert.equal(putRes.json.ok, true);
    assert.equal(putRes.json.config.showLongestTrips, false);
    assert.equal(putRes.json.config.labelPrefix, 'Pilot');

    // Verify config endpoint
    const getRes = await env.api('GET', '/admin/community-stats/config', undefined, adminToken);
    assert.equal(getRes.status, 200);
    assert.equal(getRes.json.config.showLongestTrips, false);

    // Restore showLongestTrips for remaining checks
    await env.api('PUT', '/admin/community-stats/config', { showLongestTrips: true }, adminToken);
  });

  let createdFeedbackId;

  await t.test('Rider submits post-trip feedback with rating, suggestions, and consents', async () => {
    const feedbackPayload = {
      rating: 5,
      writtenFeedback: 'Incredible convoy audio clarity through the mountain passes!',
      suggestions: 'Add more offline elevation markers.',
      consentTripDetails: true,
      consentPhoto: true,
      photoUrl: 'https://coroute.duckdns.org/uploads/group_nilgiris.jpg',
    };

    const res = await env.api('POST', '/trips/TRIP-TEST-200/feedback', feedbackPayload, riderToken);
    assert.equal(res.status, 201);
    assert.equal(res.json.ok, true);
    assert.ok(res.json.feedback.feedbackId);
    assert.equal(res.json.feedback.status, 'PENDING_REVIEW');
    assert.equal(res.json.feedback.rating, 5);
    assert.equal(res.json.feedback.consentTripDetails, true);
    assert.equal(res.json.feedback.consentPhoto, true);
    createdFeedbackId = res.json.feedback.feedbackId;
  });

  await t.test('Admin lists feedback and moderates story review', async () => {
    // List feedback
    const listRes = await env.api('GET', '/admin/feedback', undefined, adminToken);
    assert.equal(listRes.status, 200);
    assert.ok(listRes.json.summary);
    assert.ok(listRes.json.summary.total >= 1);
    assert.ok(listRes.json.summary.pending >= 1);
    assert.ok(listRes.json.summary.withPhotos >= 1);

    // Approve feedback for community stories
    const approveRes = await env.api('PUT', `/admin/feedback/${createdFeedbackId}/review`, {
      action: 'APPROVE',
      adminNotes: 'Stunning hill climb convoy photo approved for website banner',
    }, adminToken);
    assert.equal(approveRes.status, 200);
    assert.equal(approveRes.json.ok, true);
    assert.equal(approveRes.json.feedback.status, 'APPROVED');
    assert.equal(approveRes.json.feedback.reviewHistory.length, 1);
    assert.equal(approveRes.json.feedback.reviewHistory[0].action, 'APPROVE');

    // Non-admin refused
    const nonAdminReview = await env.api('PUT', `/admin/feedback/${createdFeedbackId}/review`, {
      action: 'REJECT',
    }, riderToken);
    assert.equal(nonAdminReview.status, 403);
  });
});
