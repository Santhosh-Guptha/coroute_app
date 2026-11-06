'use strict';
/**
 * Post-trip reviews against a REAL ride (created, joined and ended through the API), and the
 * convoy "leave" rules the review eligibility relies on:
 *  - the convoy id (cockpit prompt) and the rider's trip record id (trip history) are one review;
 *  - the end time is the convoy's endedAtEpochMs (not the last save time);
 *  - a phone-made trip record naming a convoy proves nothing: the convoy member list decides;
 *  - a rider who left an active ride may review their part; one still riding may not;
 *  - leaving some other convoy never releases the lock on the ride the rider is on now;
 *  - a late "leave" on an ended convoy does not rewrite the member's leftAt.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';

const test = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

test('reviews of a real ride: one review per ride, member list decides, leave keeps locks', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, gw } = env;

  const lead = await env.register('Lead Rider', 'rr-lead@coroute.test');
  const pat = await env.register('Pat Rider', 'rr-pat@coroute.test');
  const quinn = await env.register('Quinn Rider', 'rr-quinn@coroute.test');
  const bob = await env.register('Bob Outsider', 'rr-bob@coroute.test');
  const uid = (u) => u.user.userId;
  const good = (extra = {}) => ({ rating: 4, writtenFeedback: 'Smooth ride, great regroups.', consentPublish: true, consentTripDetails: true, ...extra });

  const created = await api('POST', '/convoys', {
    name: 'Western Ghats Run', start: { lat: 15.4, lng: 73.8, name: 'Panaji' }, destination: 'Gokarna', destLat: 14.55, destLng: 74.32,
  }, lead.token);
  assert.ok(created.json.groupId, JSON.stringify(created.json));
  const gid = created.json.groupId;
  const code = created.json.joinCode;
  for (const u of [pat, quinn]) assert.equal((await api('POST', '/convoys/join', { code }, u.token)).status, 200);
  const recId = (u) => `TRIP-${gid.replace('GRP-', '')}-${uid(u)}`;

  await t.test('while the ride is on, a member cannot review it (convoy id or a phone-made record)', async () => {
    const viaGroup = await api('POST', `/trips/${gid}/feedback`, good(), pat.token);
    assert.equal(viaGroup.status, 409);
    assert.equal(viaGroup.json.code, 'TRIP_NOT_COMPLETED');
    // The app saves a record with an end time; the convoy says Pat is still riding.
    assert.equal((await api('POST', '/trips', { tripId: recId(pat), groupId: gid, tripName: 'Western Ghats Run', startTimeEpochMs: Date.now() - 60000, endTimeEpochMs: Date.now() }, pat.token)).status, 201);
    const viaRecord = await api('POST', `/trips/${recId(pat)}/feedback`, good(), pat.token);
    assert.equal(viaRecord.status, 409);
    assert.equal(viaRecord.json.code, 'TRIP_NOT_COMPLETED');
  });

  await t.test('a rider who left the ride early may review their part', async () => {
    assert.equal((await api('POST', `/convoys/${gid}/leave`, {}, quinn.token)).status, 200);
    const res = await api('POST', `/trips/${gid}/feedback`, good(), quinn.token);
    assert.equal(res.status, 201, JSON.stringify(res.json));
    assert.equal(res.json.feedback.tripId, gid);
  });

  await t.test('an outsider with a fabricated trip record naming the convoy is refused', async () => {
    assert.equal((await api('POST', '/trips', { tripId: recId(bob), groupId: gid, tripName: 'Fake', startTimeEpochMs: Date.now() - 60000, endTimeEpochMs: Date.now() }, bob.token)).status, 201);
    const viaRecord = await api('POST', `/trips/${recId(bob)}/feedback`, good(), bob.token);
    assert.equal(viaRecord.status, 403);
    assert.equal(viaRecord.json.code, 'NOT_PARTICIPANT');
    const viaGroup = await api('POST', `/trips/${gid}/feedback`, good(), bob.token);
    assert.equal(viaGroup.status, 403);
    // A record naming a convoy that does not exist cannot be verified either.
    await api('POST', '/trips', { tripId: 'TRIP-NOPE-bob', groupId: 'GRP-NOPE', startTimeEpochMs: Date.now() - 60000, endTimeEpochMs: Date.now() }, bob.token);
    assert.equal((await api('POST', '/trips/TRIP-NOPE-bob/feedback', good(), bob.token)).status, 403);
  });

  let endedAt;
  await t.test('after the owner ends the ride, both ids lead to the same single review', async () => {
    const end = await api('POST', `/convoys/${gid}/status`, { status: 'ENDED' }, lead.token);
    assert.equal(end.status, 200, JSON.stringify(end.json));
    const meta = await gw.repo.getConvoyMeta(gid);
    endedAt = meta.endedAtEpochMs;
    assert.ok(endedAt > 0);
    // A later unrelated save moves updatedAt; the review must still carry the real end.
    await sleep(15);
    await gw.repo.saveConvoyMeta({ ...meta, note: 'later save' });

    const peek = await api('GET', `/trips/${gid}/feedback`, undefined, pat.token);
    assert.equal(peek.status, 200);
    assert.equal(peek.json.canReview, true);
    assert.equal(peek.json.feedback, null);

    const first = await api('POST', `/trips/${gid}/feedback`, good(), pat.token);
    assert.equal(first.status, 201, JSON.stringify(first.json));
    const stored = await gw.repo.findTripFeedbackFor(gid, uid(pat));
    assert.equal(stored.tripEndedAt, endedAt);

    // Trip history opens the review with the trip record id: same review, no second one.
    const fromHistory = await api('GET', `/trips/${recId(pat)}/feedback`, undefined, pat.token);
    assert.equal(fromHistory.status, 200);
    assert.equal(fromHistory.json.canReview, true);
    assert.equal(fromHistory.json.feedback.feedbackId, first.json.feedback.feedbackId);
    const edit = await api('POST', `/trips/${recId(pat)}/feedback`, good({ rating: 5 }), pat.token);
    assert.equal(edit.status, 200);
    assert.equal(edit.json.updated, true);
    assert.equal(edit.json.feedback.feedbackId, first.json.feedback.feedbackId);
    const mine = (await gw.repo.listTripFeedback(100)).filter((f) => f.userId === uid(pat));
    assert.equal(mine.length, 1);
    assert.equal(mine[0].rating, 5);

    // Withdraw through either id.
    const wd = await api('DELETE', `/trips/${recId(pat)}/feedback`, undefined, pat.token);
    assert.equal(wd.status, 200);
    assert.equal(wd.json.feedback.status, 'WITHDRAWN');
  });

  await t.test('a review stored under the trip record id (older builds) is found from the convoy id', async () => {
    await gw.repo.saveTrip({ tripId: recId(lead), userId: uid(lead), groupId: gid, source: 'server', tripName: 'Western Ghats Run', startTimeEpochMs: endedAt - 3600000, endTimeEpochMs: endedAt, totalDistanceKm: 101 });
    await gw.repo.addTripFeedback({ feedbackId: 'FB-LEGACY-LEAD', tripId: recId(lead), userId: uid(lead), rating: 3, status: 'PENDING_REVIEW', submittedAt: Date.now() - 1000 });
    const peek = await api('GET', `/trips/${gid}/feedback`, undefined, lead.token);
    assert.equal(peek.json.feedback.feedbackId, 'FB-LEGACY-LEAD');
    const upd = await api('POST', `/trips/${gid}/feedback`, good(), lead.token);
    assert.equal(upd.status, 200);
    assert.equal(upd.json.feedback.feedbackId, 'FB-LEGACY-LEAD');
    assert.equal((await gw.repo.listTripFeedback(100)).filter((f) => f.userId === uid(lead)).length, 1);
  });

  await t.test('a late leave on the ended convoy keeps the member record as it was', async () => {
    const before = (await gw.repo.getConvoyMeta(gid)).members[uid(pat)];
    assert.equal((await api('POST', `/convoys/${gid}/leave`, {}, pat.token)).status, 200);
    const after = (await gw.repo.getConvoyMeta(gid)).members[uid(pat)];
    assert.equal(after.leftAt || 0, before.leftAt || 0);
  });

  await t.test('leaving another convoy never releases the lock on the current ride', async () => {
    const other = await api('POST', '/convoys', { name: 'Second Ride', start: { lat: 15.4, lng: 73.8, name: 'Panaji' } }, pat.token);
    assert.ok(other.json.groupId, JSON.stringify(other.json));
    const lock = await gw.repo.getActiveTrip(uid(pat));
    assert.equal(lock.groupId, other.json.groupId);
    assert.equal((await api('POST', `/convoys/${gid}/leave`, {}, pat.token)).status, 200);
    assert.equal((await api('POST', '/convoys/GRP-NOPE/leave', {}, pat.token)).status, 200);
    const still = await gw.repo.getActiveTrip(uid(pat));
    assert.ok(still, 'the lock on the current ride is kept');
    assert.equal(still.groupId, other.json.groupId);
    // Leaving the ride itself does release it.
    assert.equal((await api('POST', `/convoys/${other.json.groupId}/leave`, {}, pat.token)).status, 200);
    assert.equal(await gw.repo.getActiveTrip(uid(pat)), null);
  });
});
