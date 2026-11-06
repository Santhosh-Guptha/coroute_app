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
    // Privacy (public_privacy.js): one rider is below the threshold of 10 and reads as 0; distance is rounded
    // down to 100 km; no per-ride list on the public website.
    assert.equal(body.totalRiders, 0);
    assert.ok(typeof body.totalKilometers === 'number' && body.totalKilometers >= 700 && body.totalKilometers % 100 === 0);
    assert.deepEqual(body.longestTrips, []);
    assert.equal(body.lastUpdated % 3600000, 0, 'time to the hour only');

    // The exact figures and the longest trips stay in the admin view.
    const admin = await env.api('GET', '/admin/community-stats/config', undefined, adminToken);
    assert.equal(admin.json.stats.totalRiders, 1); // Rider Alpha; the admin is staff and not counted
    assert.ok(admin.json.stats.longestTrips.length >= 2);

    // Verify longest trip ordering
    const topTrip = admin.json.stats.longestTrips[0];
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

  await t.test('Rider submits post-trip feedback with multiple photos, rating, suggestions, and consents', async () => {
    const feedbackPayload = {
      rating: 5,
      writtenFeedback: 'Incredible convoy audio clarity through the mountain passes!',
      suggestions: 'Add more offline elevation markers.',
      consentTripDetails: true,
      consentPhoto: true,
      photos: ['https://coroute.duckdns.org/uploads/pass1.jpg', 'https://coroute.duckdns.org/uploads/pass2.jpg'],
    };

    const res = await env.api('POST', '/trips/TRIP-TEST-200/feedback', feedbackPayload, riderToken);
    assert.equal(res.status, 201);
    assert.equal(res.json.ok, true);
    assert.ok(res.json.feedback.feedbackId);
    assert.equal(res.json.feedback.status, 'PENDING_REVIEW');
    assert.equal(res.json.feedback.rating, 5);
    assert.equal(res.json.feedback.consentTripDetails, true);
    assert.equal(res.json.feedback.consentPhoto, true);
    assert.equal(res.json.feedback.photos.length, 2);
    assert.equal(res.json.feedback.photoUrl, 'https://coroute.duckdns.org/uploads/pass1.jpg');
    createdFeedbackId = res.json.feedback.feedbackId;
  });

  await t.test('Admin lists feedback, moderates story review with layout template and formatted text, and public community stories returns approved stories', async () => {
    // List feedback
    const listRes = await env.api('GET', '/admin/feedback', undefined, adminToken);
    assert.equal(listRes.status, 200);
    assert.ok(listRes.json.summary);
    assert.ok(listRes.json.summary.total >= 1);
    assert.ok(listRes.json.summary.pending >= 1);
    assert.ok(listRes.json.summary.withPhotos >= 1);

    // Approve feedback with template layout, formatted text, and selected photos
    const approveRes = await env.api('PUT', `/admin/feedback/${createdFeedbackId}/review`, {
      action: 'APPROVE',
      adminNotes: 'Stunning hill climb convoy photo approved for website banner',
      formattedText: 'Edited highlight: Amazing convoy experience through Nilgiris!',
      templateLayout: 'text-left-pic-right',
      selectedPhotos: ['https://coroute.duckdns.org/uploads/pass1.jpg'],
    }, adminToken);
    assert.equal(approveRes.status, 200);
    assert.equal(approveRes.json.ok, true);
    assert.equal(approveRes.json.feedback.status, 'APPROVED');
    assert.equal(approveRes.json.feedback.templateLayout, 'text-left-pic-right');
    assert.equal(approveRes.json.feedback.formattedText, 'Edited highlight: Amazing convoy experience through Nilgiris!');
    assert.equal(approveRes.json.feedback.selectedPhotos.length, 1);
    assert.equal(approveRes.json.feedback.reviewHistory.length, 1);
    assert.equal(approveRes.json.feedback.reviewHistory[0].action, 'APPROVE');

    // Test GET /public/community-stories returns approved stories
    const publicStoriesRes = await env.api('GET', '/public/community-stories');
    assert.equal(publicStoriesRes.status, 200);
    assert.equal(publicStoriesRes.json.ok, true);
    assert.ok(Array.isArray(publicStoriesRes.json.stories));
    assert.ok(publicStoriesRes.json.stories.length >= 1);

    const story = publicStoriesRes.json.stories[0];
    assert.equal(story.feedbackId, createdFeedbackId);
    assert.equal(story.templateLayout, 'text-left-pic-right');
    assert.equal(story.formattedText, 'Edited highlight: Amazing convoy experience through Nilgiris!');
    // Only the photo the admin selected is public.
    assert.deepEqual(story.photos, ['https://coroute.duckdns.org/uploads/pass1.jpg']);
    assert.deepEqual(story.selectedPhotos, ['https://coroute.duckdns.org/uploads/pass1.jpg']);
    for (const k of ['userId', 'userName', 'userEmail', 'email', 'phone', 'tripId', 'reviewHistory', 'adminNotes', 'suggestions']) {
      assert.ok(!(k in story), `public story must not carry ${k}`);
    }
    assert.equal(publicStoriesRes.json.summary.count, publicStoriesRes.json.stories.length);
    assert.equal(story.rating, 5);
    assert.equal(story.distanceKm, 420);
    assert.ok(story.anonymousRiderLabel);

    // Non-admin refused
    const nonAdminReview = await env.api('PUT', `/admin/feedback/${createdFeedbackId}/review`, {
      action: 'REJECT',
    }, riderToken);
    assert.equal(nonAdminReview.status, 403);
  });
});
