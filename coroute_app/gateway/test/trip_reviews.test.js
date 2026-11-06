'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');

const PII_KEYS = ['userId', 'riderId', 'userName', 'userEmail', 'email', 'phone', 'tripId', 'reviewHistory', 'adminNotes', 'suggestions', 'safetyExperience', 'lat', 'lng', 'breadcrumbTrail', 'approvedBy', 'statusReason'];

function assertNoPii(story) {
  for (const k of PII_KEYS) assert.ok(!(k in story), `public story must not carry ${k}`);
  const flat = JSON.stringify(story);
  assert.ok(!flat.includes('@'), 'no e-mail address in a public story');
  assert.ok(!/\+?91\d{8,}/.test(flat), 'no phone number in a public story');
}

test('post-trip reviews: eligibility, one per rider, moderation, public stories', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, gw } = env;

  const admin = await env.register('Admin User', 'admin@coroute.test');
  const alice = await env.register('Alice Rider', 'alice@coroute.test');
  const bob = await env.register('Bob Rider', 'bob@coroute.test');
  const now = Date.now();

  await gw.repo.saveTrip({
    tripId: 'TRIP-ALICE-1', userId: alice.user.userId, tripName: 'Coorg Coffee Loop',
    startLocationName: 'Mysuru', destinationName: 'Madikeri',
    startTimeEpochMs: now - 2 * 86400000, endTimeEpochMs: now - 3600000, totalDistanceKm: 312.4,
    breadcrumbTrail: [{ lat: 12.3, lng: 76.6, speedKmh: 40, heading: 0, timestamp: now - 3600000 }],
  });
  await gw.repo.saveTrip({ tripId: 'TRIP-ALICE-LIVE', userId: alice.user.userId, tripName: 'Still riding', startTimeEpochMs: now - 3600000 });
  await gw.repo.saveTrip({ tripId: 'TRIP-BOB-1', userId: bob.user.userId, tripName: 'Bob Solo', startTimeEpochMs: now - 7200000, endTimeEpochMs: now - 600000, totalDistanceKm: 80 });

  const good = (extra = {}) => ({
    rating: 5,
    writtenFeedback: 'Misty <b>ghat</b> roads and the group stayed together the whole way.',
    safetyExperience: 'Felt safe, the sweep never lost us.',
    suggestions: 'Fuel stop reminders.',
    consentPublish: true,
    consentTripDetails: true,
    consentPhoto: true,
    photos: ['https://coroute.duckdns.org/uploads/coorg1.jpg', '/uploads/coorg2.webp'],
    ...extra,
  });

  await t.test('no approved reviews: the public list is empty (no invented stories)', async () => {
    const res = await api('GET', '/public/community-stories?limit=5');
    assert.equal(res.status, 200);
    assert.equal(res.json.ok, true);
    assert.deepEqual(res.json.stories, []);
    assert.deepEqual(res.json.summary, { count: 0, averageRating: null });
    const legacyApi = await api('GET', '/community-stories');
    assert.equal(legacyApi.status, 200);
    assert.deepEqual(legacyApi.json, []);
    const legacyRoot = await fetch(`${env.origin}/community-stories`);
    assert.equal(legacyRoot.status, 200);
    assert.deepEqual(await legacyRoot.json(), []);
    for (const body of [JSON.stringify(res.json), JSON.stringify(legacyApi.json)]) {
      assert.ok(!body.includes('FB-SEED') && !body.includes('Nilgiris Monsoon') && !body.includes('story-1'));
    }
  });

  await t.test('a rider who did not take part cannot review the trip (403)', async () => {
    const res = await api('POST', '/trips/TRIP-ALICE-1/feedback', good(), bob.token);
    assert.equal(res.status, 403);
    assert.equal(res.json.code, 'NOT_PARTICIPANT');
    const peek = await api('GET', '/trips/TRIP-ALICE-1/feedback', undefined, bob.token);
    assert.equal(peek.status, 403);
    const anon = await api('POST', '/trips/TRIP-ALICE-1/feedback', good());
    assert.equal(anon.status, 401);
  });

  await t.test('a trip that has not ended, or does not exist, cannot be reviewed', async () => {
    const live = await api('POST', '/trips/TRIP-ALICE-LIVE/feedback', good(), alice.token);
    assert.equal(live.status, 409);
    assert.equal(live.json.code, 'TRIP_NOT_COMPLETED');
    const missing = await api('POST', '/trips/TRIP-NOPE-404/feedback', good(), alice.token);
    assert.equal(missing.status, 404);
    const status = await api('GET', '/trips/TRIP-ALICE-LIVE/feedback', undefined, alice.token);
    assert.equal(status.status, 200);
    assert.equal(status.json.canReview, false);
    assert.equal(status.json.code, 'TRIP_NOT_COMPLETED');
    assert.equal(status.json.feedback, null);
  });

  await t.test('input is validated and capped', async () => {
    for (const rating of [0, 6, 3.5, '5', null]) {
      const r = await api('POST', '/trips/TRIP-ALICE-1/feedback', good({ rating }), alice.token);
      assert.equal(r.status, 422, `rating ${rating}`);
      assert.ok(r.json.fields.rating);
    }
    const tooLong = await api('POST', '/trips/TRIP-ALICE-1/feedback', good({ writtenFeedback: 'x'.repeat(1501) }), alice.token);
    assert.equal(tooLong.status, 422);
    const tooMany = await api('POST', '/trips/TRIP-ALICE-1/feedback', good({ photos: Array.from({ length: 6 }, (_, i) => `/uploads/p${i}.jpg`) }), alice.token);
    assert.equal(tooMany.status, 422);
    for (const bad of ['javascript:alert(1)//.jpg', 'http://insecure.example/a.jpg', 'https://x.example/a.gif', 'data:image/png;base64,AAAA', '//evil.example/a.png', '/uploads/../secret.jpg', 'mock_convoy_photo_1.jpg']) {
      const r = await api('POST', '/trips/TRIP-ALICE-1/feedback', good({ photos: [bad] }), alice.token);
      assert.equal(r.status, 422, bad);
    }
  });

  let reviewId;
  await t.test('a new review is pending and never public', async () => {
    const res = await api('POST', '/trips/TRIP-ALICE-1/feedback', good(), alice.token);
    assert.equal(res.status, 201);
    assert.equal(res.json.feedback.status, 'PENDING_REVIEW');
    assert.equal(res.json.feedback.writtenFeedback, 'Misty ghat roads and the group stayed together the whole way.', 'HTML is stripped');
    assert.equal(res.json.feedback.photos.length, 2);
    reviewId = res.json.feedback.feedbackId;
    const pub = await api('GET', '/public/community-stories');
    assert.deepEqual(pub.json.stories, []);
    const mine = await api('GET', '/trips/TRIP-ALICE-1/feedback', undefined, alice.token);
    assert.equal(mine.json.canReview, true);
    assert.equal(mine.json.feedback.status, 'PENDING_REVIEW');
  });

  await t.test('a second submission updates the same review instead of adding another', async () => {
    const res = await api('POST', '/trips/TRIP-ALICE-1/feedback', good({ rating: 4, writtenFeedback: 'Updated: misty ghats, great group.' }), alice.token);
    assert.equal(res.status, 200);
    assert.equal(res.json.updated, true);
    assert.equal(res.json.feedback.feedbackId, reviewId);
    assert.equal(res.json.feedback.rating, 4);
    const list = await api('GET', '/admin/reviews', undefined, admin.token);
    assert.equal(list.status, 200);
    assert.equal(list.json.reviews.filter((r) => r.tripId === 'TRIP-ALICE-1').length, 1);
    const item = list.json.reviews.find((r) => r.feedbackId === reviewId);
    assert.equal(item.reviewHistory.at(-1).action, 'RIDER_UPDATE');
    const notAdmin = await api('GET', '/admin/reviews', undefined, alice.token);
    assert.equal(notAdmin.status, 403);
  });

  await t.test('moderation input is checked: reasons, photo choice, consent', async () => {
    const noReason = await api('PUT', `/admin/reviews/${reviewId}`, { action: 'REJECT' }, admin.token);
    assert.equal(noReason.status, 422);
    const badAction = await api('PUT', `/admin/reviews/${reviewId}`, { action: 'PUBLISH_NOW' }, admin.token);
    assert.equal(badAction.status, 400);
    const foreignPhoto = await api('PUT', `/admin/reviews/${reviewId}`, { action: 'APPROVE', selectedPhotos: ['https://elsewhere.example/x.jpg'] }, admin.token);
    assert.equal(foreignPhoto.status, 422);
    const byRider = await api('PUT', `/admin/reviews/${reviewId}`, { action: 'APPROVE' }, alice.token);
    assert.equal(byRider.status, 403);
    const missing = await api('PUT', '/admin/reviews/FB-DOES-NOT-EXIST', { action: 'APPROVE' }, admin.token);
    assert.equal(missing.status, 404);
  });

  await t.test('request changes, then the rider edits and it is pending again', async () => {
    const rc = await api('PUT', `/admin/reviews/${reviewId}`, { action: 'REQUEST_CHANGES', reason: 'Please remove the plate number.' }, admin.token);
    assert.equal(rc.status, 200);
    assert.equal(rc.json.feedback.status, 'CHANGES_REQUESTED');
    const mine = await api('GET', '/trips/TRIP-ALICE-1/feedback', undefined, alice.token);
    assert.equal(mine.json.feedback.status, 'CHANGES_REQUESTED');
    assert.equal(mine.json.feedback.statusReason, 'Please remove the plate number.');
    assert.ok(!('reviewHistory' in mine.json.feedback), 'the rider does not see the admin audit trail');
    const again = await api('POST', '/trips/TRIP-ALICE-1/feedback', good({ writtenFeedback: 'Misty ghats, a great group and a safe sweep.' }), alice.token);
    assert.equal(again.status, 200);
    assert.equal(again.json.feedback.status, 'PENDING_REVIEW');
    assert.equal(again.json.feedback.statusReason, '');
  });

  await t.test('approved review appears publicly with only selected photos and no personal data', async () => {
    const res = await api('PUT', `/admin/reviews/${reviewId}`, {
      action: 'APPROVE',
      formattedText: 'Misty ghats and a <i>great</i> group.',
      selectedPhotos: ['/uploads/coorg2.webp'],
      adminNotes: 'Nice one',
    }, admin.token);
    assert.equal(res.status, 200, JSON.stringify(res.json));
    assert.equal(res.json.feedback.status, 'APPROVED');
    assert.ok(res.json.feedback.approvedAt > 0);
    assert.equal(res.json.feedback.reviewHistory.at(-1).action, 'APPROVE');
    assert.equal(res.json.feedback.reviewHistory.at(-1).toStatus, 'APPROVED');

    const pub = await api('GET', '/public/community-stories?limit=3');
    assert.equal(pub.status, 200);
    assert.equal(pub.json.stories.length, 1);
    const s = pub.json.stories[0];
    assert.equal(s.feedbackId, reviewId);
    assert.equal(s.tripName, 'Coorg Coffee Loop');
    assert.equal(s.rating, 5);
    assert.equal(s.formattedText, 'Misty ghats and a great group.');
    assert.equal(s.writtenFeedback, s.formattedText);
    assert.deepEqual(s.photos, ['/uploads/coorg2.webp']);
    assert.equal(s.distanceKm, 312);
    assert.equal(s.routeFrom, 'Mysuru');
    assert.equal(s.routeTo, 'Madikeri');
    assert.equal(s.durationDays, 2);
    assert.ok(s.riderLabel && s.anonymousRiderLabel);
    assert.ok(s.approvedAt > 0 && s.submittedAt > 0);
    assertNoPii(s);
    assert.deepEqual(pub.json.summary, { count: 1, averageRating: 5 });

    const legacy = await api('GET', '/community-stories');
    assert.deepEqual(legacy.json, pub.json.stories);
    const root = await (await fetch(`${env.origin}/community-stories`)).json();
    assert.deepEqual(root, pub.json.stories);
  });

  await t.test('without trip-details or photo consent, those parts stay private', async () => {
    const r = await api('POST', '/trips/TRIP-BOB-1/feedback', good({ consentTripDetails: false, consentPhoto: false, rating: 3, writtenFeedback: 'Quiet solo ride, app was steady.' }), bob.token);
    assert.equal(r.status, 201);
    const id = r.json.feedback.feedbackId;
    const photoPick = await api('PUT', `/admin/reviews/${id}`, { action: 'APPROVE', selectedPhotos: ['/uploads/coorg2.webp'] }, admin.token);
    assert.equal(photoPick.status, 422, 'Bob has no photos stored without consent');
    const ok = await api('PUT', `/admin/reviews/${id}`, { action: 'APPROVE' }, admin.token);
    assert.equal(ok.status, 200);
    const pub = await api('GET', '/public/community-stories');
    const s = pub.json.stories.find((x) => x.feedbackId === id);
    assert.equal(s.tripName, 'A CoRoute ride');
    assert.equal(s.distanceKm, null);
    assert.equal(s.routeFrom, null);
    assert.deepEqual(s.photos, []);
    assertNoPii(s);
    assert.equal(pub.json.summary.averageRating, 4);
    // Bob takes it down himself.
    const wd = await api('DELETE', '/trips/TRIP-BOB-1/feedback', undefined, bob.token);
    assert.equal(wd.status, 200);
    assert.equal(wd.json.feedback.status, 'WITHDRAWN');
    const after = await api('GET', '/public/community-stories');
    assert.ok(!after.json.stories.some((x) => x.feedbackId === id));
  });

  await t.test('a review without publication consent cannot be approved', async () => {
    await gw.repo.saveTrip({ tripId: 'TRIP-ALICE-2', userId: alice.user.userId, tripName: 'Private ride', startTimeEpochMs: now - 7200000, endTimeEpochMs: now - 60000 });
    const r = await api('POST', '/trips/TRIP-ALICE-2/feedback', good({ consentPublish: false }), alice.token);
    assert.equal(r.status, 201);
    const res = await api('PUT', `/admin/reviews/${r.json.feedback.feedbackId}`, { action: 'APPROVE' }, admin.token);
    assert.equal(res.status, 409);
    assert.equal(res.json.code, 'CONSENT_REQUIRED');
  });

  await t.test('reject (with reason) and withdraw remove a story from the public list', async () => {
    const rej = await api('PUT', `/admin/feedback/${reviewId}/review`, { action: 'REJECT', reason: 'Shows a private address.' }, admin.token);
    assert.equal(rej.status, 200);
    assert.equal(rej.json.feedback.status, 'REJECTED');
    let pub = await api('GET', '/public/community-stories');
    assert.ok(!pub.json.stories.some((x) => x.feedbackId === reviewId));
    const mine = await api('GET', '/trips/TRIP-ALICE-1/feedback', undefined, alice.token);
    assert.equal(mine.json.feedback.status, 'REJECTED');
    assert.equal(mine.json.feedback.statusReason, 'Shows a private address.');

    const re = await api('PUT', `/admin/reviews/${reviewId}`, { action: 'APPROVE' }, admin.token);
    assert.equal(re.status, 200);
    pub = await api('GET', '/public/community-stories');
    assert.ok(pub.json.stories.some((x) => x.feedbackId === reviewId));
    const wd = await api('PUT', `/admin/reviews/${reviewId}`, { action: 'WITHDRAW', reason: 'Season over.' }, admin.token);
    assert.equal(wd.status, 200);
    assert.equal(wd.json.feedback.status, 'WITHDRAWN');
    pub = await api('GET', '/public/community-stories');
    assert.deepEqual(pub.json.stories, []);
    const hist = wd.json.feedback.reviewHistory.map((h) => h.action);
    assert.deepEqual(hist.slice(-4), ['APPROVE', 'REJECT', 'APPROVE', 'WITHDRAW']);
  });

  await t.test('admin list filters by status and counts every state', async () => {
    const all = await api('GET', '/admin/reviews', undefined, admin.token);
    assert.equal(all.json.summary.total, 3);
    assert.equal(all.json.summary.withdrawn, 2);
    assert.equal(all.json.summary.pending, 1);
    const pending = await api('GET', '/admin/reviews?status=PENDING_REVIEW', undefined, admin.token);
    assert.equal(pending.json.reviews.length, 1);
    assert.equal(pending.json.reviews[0].canPublish, false);
  });

  await t.test('a convoy can be reviewed by its members once it has ended', async () => {
    await gw.repo.createConvoyMeta({
      groupId: 'GRP-REVIEW1', name: 'Konkan Coast Run', tripStatus: 'STARTED', joinCode: '777111',
      startLocationName: 'Goa', destinationName: 'Gokarna', startedAt: now - 86400000,
      members: { [alice.user.userId]: { userId: alice.user.userId, name: 'Alice Rider', role: 'LEAD' } },
    });
    const early = await api('POST', '/trips/GRP-REVIEW1/feedback', good(), alice.token);
    assert.equal(early.status, 409);
    const meta = await gw.repo.getConvoyMeta('GRP-REVIEW1');
    await gw.repo.saveConvoyMeta({ ...meta, tripStatus: 'ENDED', endedAt: now - 1000 });
    const outsider = await api('POST', '/trips/GRP-REVIEW1/feedback', good(), bob.token);
    assert.equal(outsider.status, 403);
    const ok = await api('POST', '/trips/GRP-REVIEW1/feedback', good(), alice.token);
    assert.equal(ok.status, 201);
    assert.equal(ok.json.feedback.tripName, 'Konkan Coast Run');
  });

  await t.test('review writes are rate-limited per rider', async () => {
    await gw.repo.saveTrip({ tripId: 'TRIP-ADMIN-1', userId: admin.user.userId, tripName: 'Admin ride', startTimeEpochMs: now - 7200000, endTimeEpochMs: now - 60000 });
    const codes = [];
    for (let i = 0; i < 13; i++) codes.push((await api('POST', '/trips/TRIP-ADMIN-1/feedback', good({ writtenFeedback: `take ${i}` }), admin.token)).status);
    assert.deepEqual(codes.slice(0, 12), [201, ...Array(11).fill(200)]);
    assert.equal(codes[12], 429);
    const list = await api('GET', '/admin/reviews', undefined, admin.token);
    assert.equal(list.json.reviews.filter((r) => r.tripId === 'TRIP-ADMIN-1').length, 1);
  });

  await t.test('deleting the account removes the rider\'s reviews', async () => {
    const before = (await gw.repo.listTripFeedback(100)).filter((f) => f.userId === bob.user.userId);
    assert.equal(before.length, 1);
    await gw.repo.deleteUserCascade({ userId: bob.user.userId, email: 'bob@coroute.test', name: 'Bob Rider' });
    const after = (await gw.repo.listTripFeedback(100)).filter((f) => f.userId === bob.user.userId);
    assert.equal(after.length, 0);
  });
});
