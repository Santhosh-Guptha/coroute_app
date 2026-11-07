'use strict';
/**
 * 3.55: what riders leave behind for the riders who come after them.
 *  - Road reports: a group lead's live ROAD_HAZARD is saved without any rider id and served to a
 *    later ride along the same road; nearby reports merge; "Fixed?" clears; expired ones are gone.
 *  - CoRoute rider place reviews: one per rider and place, text rules, photos only after an admin
 *    check, admin hide, moderation is admin-only, account deletion removes them.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.RIDER_PERSIST_INTERVAL_MS = '20';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot, sleep } = require('./_helpers');

let t, gw;
before(async () => { t = await boot(); gw = t.gw; });
after(async () => { await gw.shutdown(); });

let n = 0;
/** A group ride along lng 78.0 from `fromLat` to `toLat` with a lead and one rider. */
async function ride(fromLat, toLat) {
  n++;
  const lead = await t.register(`Lead ${n}`, `roadlead${n}@coroute.test`);
  const c = (await t.api('POST', '/convoys', { name: `Road ${n}`, start: { lat: fromLat, lng: 78.0, name: 'Start' }, destination: 'End', destLat: toLat, destLng: 78.0 }, lead.token)).json;
  n++;
  const rider = await t.register(`Rider ${n}`, `roadrider${n}@coroute.test`);
  assert.equal((await t.api('POST', '/convoys/join', { code: c.joinCode }, rider.token)).status, 200);
  await sleep(20);
  assert.ok(gw.convoys.rooms.get(c.groupId).meta.route?.polyline, 'the ride has a route');
  return { lead, rider, gid: c.groupId };
}

const storedRoad = () => [...(t.soda.collections.get('road_hazards') || new Map()).values()];

async function report(ws, body) {
  ws.sendJson({ type: 'ROAD_HAZARD', heading: 0, severity: 'HIGH', classification: 'POTHOLE', confidence: 0.8, pseudonymousRiderId: 'captain-secret', ...body });
  const ack = await ws.next((m) => m.type === 'ROAD_HAZARD_ACK' || m.type === 'ERROR');
  assert.equal(ack.type, 'ROAD_HAZARD_ACK', JSON.stringify(ack));
  await sleep(30); // saved in the background
  return ack;
}

test('road reports: saved from the lead without rider ids, served to a later ride on the same road, merged, cleared', async () => {
  const A = await ride(17.0, 17.3);
  const wa = await t.joinRoom(A.lead.token, A.gid);
  await report(wa, { hazardId: 'rh_a1', lat: 17.1, lng: 78.0 });

  // Nothing stored names the rider.
  const docs = storedRoad();
  assert.equal(docs.length, 1);
  const json = JSON.stringify(docs);
  for (const needle of [A.lead.user.userId, A.rider.user.userId, 'Lead 1', 'captain-secret', A.gid]) assert.ok(!json.includes(needle), `no ${needle} in saved road reports`);
  assert.equal(docs[0].reports, 1);
  assert.equal(docs[0].classification, 'POTHOLE');

  // A later ride along the same road gets it; a member only.
  const B = await ride(17.05, 17.25);
  const near = await t.api('GET', `/road-hazards/near?groupId=${B.gid}`, null, B.rider.token);
  assert.equal(near.status, 200, JSON.stringify(near.json));
  assert.equal(near.json.hazards.length, 1);
  const h = near.json.hazards[0];
  assert.equal(h.fromHistory, true);
  assert.equal(h.classification, 'POTHOLE');
  assert.equal(h.spokenWarning, 'Caution: pothole 300 meters ahead');
  assert.equal(Object.keys(h).some((k) => /user|rider|reporter/i.test(k)), false, 'no rider fields in the answer');
  assert.equal((await t.api('GET', `/road-hazards/near?groupId=${B.gid}`, null, A.rider.token)).status, 403, 'not a member of ride B');
  // A ride on another road does not get it.
  n++;
  const other = await t.register(`Far ${n}`, `roadfar${n}@coroute.test`);
  const far = (await t.api('POST', '/convoys', { name: 'Far road', start: { lat: 17.0, lng: 78.3, name: 'S' }, destination: 'E', destLat: 17.3, destLng: 78.3 }, other.token)).json;
  assert.deepEqual((await t.api('GET', `/road-hazards/near?groupId=${far.groupId}`, null, other.token)).json.hazards, []);

  // Ride B's lead feels the same pothole 40 m on: one saved report, two riders.
  const wb = await t.joinRoom(B.lead.token, B.gid);
  await report(wb, { hazardId: 'rh_b1', lat: 17.10036, lng: 78.0, severity: 'CRITICAL' });
  assert.equal(storedRoad().length, 1, 'merged within 80 m');
  assert.equal(storedRoad()[0].reports, 2);
  assert.equal(storedRoad()[0].severity, 'CRITICAL');
  // The same lead again does not count twice.
  await report(wb, { hazardId: 'rh_b2', lat: 17.10040, lng: 78.0 });
  assert.equal(storedRoad()[0].reports, 2);
  // A speed breaker at the same spot is a separate report; a rough road 1 km on too.
  await report(wb, { hazardId: 'rh_b3', lat: 17.1002, lng: 78.0, classification: 'SPEED_BREAKER', severity: 'MEDIUM' });
  await report(wb, { hazardId: 'rh_b4', lat: 17.11, lng: 78.0, classification: 'ROUGH_ROAD', severity: 'LOW' });
  const byPoint = await t.api('GET', '/road-hazards/near?lat=17.1&lng=78.0', null, A.rider.token);
  assert.deepEqual(byPoint.json.hazards.map((x) => x.classification).sort(), ['POTHOLE', 'ROUGH_ROAD', 'SPEED_BREAKER']);
  const pothole = byPoint.json.hazards.find((x) => x.classification === 'POTHOLE');
  assert.equal(pothole.corroborationCount, 2);
  assert.equal(byPoint.json.hazards.find((x) => x.classification === 'SPEED_BREAKER').spokenWarning, 'Caution: speed breaker 300 meters ahead');

  // A pack rider cannot broadcast.
  const wr = await t.joinRoom(B.rider.token, B.gid);
  wr.sendJson({ type: 'ROAD_HAZARD', lat: 17.2, lng: 78.0 });
  assert.equal((await wr.next((m) => m.type === 'ERROR')).reason, 'ENTITLEMENT_REQUIRED');

  // "Fixed?": two riders saying so removes a report seen by two.
  const c1 = await t.api('POST', `/road-hazards/${pothole.hazardId}/clear`, {}, A.rider.token);
  assert.equal(c1.status, 200);
  assert.equal(c1.json.removed, false);
  const c2 = await t.api('POST', `/road-hazards/${pothole.hazardId}/clear`, {}, B.rider.token);
  assert.equal(c2.json.removed, true);
  const after = await t.api('GET', `/road-hazards/near?groupId=${B.gid}`, null, B.rider.token);
  assert.ok(!after.json.hazards.some((x) => x.hazardId === pothole.hazardId), 'cleared report is gone');
  assert.equal((await t.api('POST', '/road-hazards/rh_nope/clear', {}, A.rider.token)).status, 404);
  assert.equal((await t.api('POST', '/road-hazards/bad%20id!/clear', {}, A.rider.token)).status, 400);

  // Expired reports are never served.
  await gw.repo.saveRoadHazard({ hazardId: 'rh_old', lat: 17.2, lng: 78.0, heading: 0, severity: 'HIGH', classification: 'POTHOLE', expiresAt: Date.now() - 1000 });
  const later = await t.api('GET', '/road-hazards/near?lat=17.2&lng=78.0', null, A.rider.token);
  assert.ok(!later.json.hazards.some((x) => x.hazardId === 'rh_old'));
  assert.equal((await t.api('GET', '/road-hazards/near', null, A.rider.token)).status, 400);

  for (const w of [wa, wb, wr]) w.close();
});

// ---------- tiny JPEG (structurally valid; the gateway never decodes pixels) ----------
function seg(marker, body) {
  const h = Buffer.from([0xFF, marker, 0, 0]);
  h.writeUInt16BE(body.length + 2, 2);
  return Buffer.concat([h, body]);
}
function jpeg() {
  const sof = Buffer.from([8, 0x01, 0xE0, 0x02, 0x80, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  return Buffer.concat([
    Buffer.from([0xFF, 0xD8]),
    seg(0xE0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'binary')),
    seg(0xDB, Buffer.alloc(65, 1)), seg(0xC0, sof), seg(0xC4, Buffer.alloc(30, 2)),
    seg(0xDA, Buffer.from([3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0])),
    Buffer.alloc(200, 0x55), Buffer.from([0xFF, 0xD9]),
  ]);
}
const upload = (reviewId, body, token, type = 'image/jpeg') => fetch(`${t.base}/places/reviews/${reviewId}/photo`, {
  method: 'POST', headers: { 'Content-Type': type, Authorization: `Bearer ${token}` }, body,
}).then(async (r) => ({ status: r.status, json: await r.json().catch(() => ({})) }));
const getRaw = (path, token) => fetch(`${t.origin}${path}`, { headers: { Authorization: `Bearer ${token}` } }).then((r) => r.status);

test('place reviews: one per rider and place, text rules, photos after an admin check, hide, admin only, deleted with the account', async () => {
  const admin = await t.register('Admin User', 'admin@coroute.test');
  const shanmuk = await t.register('Shanmuk Reddy Kumar', 'shanmuk@coroute.test');
  const asha = await t.register('Asha Rao', 'asha.place@coroute.test');
  const place = { placeId: 'n4242', placeName: 'Sri Sai Dhaba', category: 'food', lat: 17.40001, lng: 78.50001, dwellMin: 25 };

  // Validation.
  const bad = async (body, code) => {
    const r = await t.api('POST', '/places/reviews', { ...place, rating: 4, ...body }, shanmuk.token);
    assert.equal(r.status, 400, JSON.stringify(r.json));
    assert.equal(r.json.code, code);
  };
  await bad({ rating: 0 }, 'BAD_RATING');
  await bad({ rating: 6 }, 'BAD_RATING');
  await bad({ rating: 3.5 }, 'BAD_RATING');
  await bad({ text: 'Menu at www.sri-sai-dhaba.example' }, 'TEXT_LINK');
  await bad({ text: 'Call the owner on 98765 43210 for a table' }, 'TEXT_NUMBER');
  await bad({ text: 'x'.repeat(301) }, 'TEXT_TOO_LONG');
  await bad({ placeId: 'bad id with spaces' }, 'BAD_REQUEST');
  await bad({ lat: 'nowhere' }, 'BAD_REQUEST');

  // Create, then replace (one per rider and place).
  const first = await t.api('POST', '/places/reviews', { ...place, rating: 3, text: 'Good parathas' }, shanmuk.token);
  assert.equal(first.status, 201, JSON.stringify(first.json));
  const id = first.json.review.reviewId;
  assert.match(id, /^pr_[a-f0-9]{24}$/);
  assert.equal(first.json.review.firstName, 'Shanmuk', 'first name only');
  const again = await t.api('POST', '/places/reviews', { ...place, rating: 5, text: 'Great parathas, safe bike parking' }, shanmuk.token);
  assert.equal(again.status, 200);
  assert.equal(again.json.review.reviewId, id);
  assert.equal((await t.api('POST', '/places/reviews', { ...place, rating: 4 }, asha.token)).status, 201);

  let page = (await t.api('GET', `/places/reviews?placeId=${place.placeId}`, null, asha.token)).json;
  assert.deepEqual(page.summary, { count: 2, avg: 4.5 });
  const mineSeen = page.reviews.find((r) => r.reviewId === id);
  assert.equal(mineSeen.text, 'Great parathas, safe bike parking');
  assert.equal(mineSeen.firstName, 'Shanmuk');
  const publicJson = JSON.stringify(page.reviews);
  for (const needle of [shanmuk.user.userId, 'Reddy', 'shanmuk@coroute.test']) assert.ok(!publicJson.includes(needle), `no ${needle} shown to riders`);

  // Map summary for a box.
  const sum = await t.api('GET', '/places/review-summary?s=17.3&w=78.4&n=17.5&e=78.6', null, asha.token);
  assert.equal(sum.status, 200);
  assert.deepEqual(sum.json.places.map((p) => [p.placeId, p.count, p.avg]), [['n4242', 2, 4.5]]);
  assert.equal((await t.api('GET', '/places/review-summary?s=10&w=70&n=20&e=80', null, asha.token)).status, 400, 'box too large');

  // A photo waits for the admin: others neither see it listed nor can load it.
  assert.equal((await upload(id, jpeg(), asha.token)).status, 404, 'only the author adds photos');
  const up = await upload(id, jpeg(), shanmuk.token);
  assert.equal(up.status, 201, JSON.stringify(up.json));
  const photoId = up.json.photo.id;
  const photoPath = `/api/places/reviews/${id}/photo/${photoId}`;
  page = (await t.api('GET', `/places/reviews?placeId=${place.placeId}`, null, asha.token)).json;
  assert.deepEqual(page.reviews.find((r) => r.reviewId === id).photos, []);
  assert.equal(await getRaw(photoPath, asha.token), 404);
  assert.equal(await getRaw(photoPath, shanmuk.token), 200, 'the author sees their own photo');
  const minePage = (await t.api('GET', `/places/reviews?placeId=${place.placeId}`, null, shanmuk.token)).json;
  assert.equal(minePage.mine.photosPending, 1);

  // Moderation is admin only.
  assert.equal((await t.api('GET', '/admin/place-reviews?pending=1', null, asha.token)).status, 403);
  assert.equal((await t.api('PUT', `/admin/place-reviews/${id}`, { action: 'approvePhoto', photoId }, shanmuk.token)).status, 403);
  const pending = await t.api('GET', '/admin/place-reviews?pending=1', null, admin.token);
  assert.equal(pending.status, 200);
  assert.deepEqual(pending.json.reviews.map((r) => r.reviewId), [id]);
  assert.equal((await t.api('PUT', `/admin/place-reviews/${id}`, { action: 'bogus' }, admin.token)).status, 400);

  const ok = await t.api('PUT', `/admin/place-reviews/${id}`, { action: 'approvePhoto', photoId }, admin.token);
  assert.equal(ok.status, 200);
  page = (await t.api('GET', `/places/reviews?placeId=${place.placeId}`, null, asha.token)).json;
  assert.deepEqual(page.reviews.find((r) => r.reviewId === id).photos, [photoPath]);
  assert.equal(await getRaw(photoPath, asha.token), 200);
  assert.deepEqual((await t.api('GET', '/admin/place-reviews?pending=1', null, admin.token)).json.reviews, []);

  // A rejected photo is removed.
  const up2 = await upload(id, jpeg(), shanmuk.token);
  assert.equal((await t.api('PUT', `/admin/place-reviews/${id}`, { action: 'rejectPhoto', photoId: up2.json.photo.id }, admin.token)).status, 200);
  assert.equal(await getRaw(`/api/places/reviews/${id}/photo/${up2.json.photo.id}`, shanmuk.token), 404);

  // Hidden: gone from the place and the map, back when published.
  assert.equal((await t.api('PUT', `/admin/place-reviews/${id}`, { action: 'hide' }, admin.token)).status, 200);
  page = (await t.api('GET', `/places/reviews?placeId=${place.placeId}`, null, asha.token)).json;
  assert.equal(page.reviews.some((r) => r.reviewId === id), false);
  assert.deepEqual(page.summary, { count: 1, avg: 4 });
  assert.equal(await getRaw(photoPath, asha.token), 404, 'photos of a hidden review are not served');
  assert.equal((await t.api('PUT', `/admin/place-reviews/${id}`, { action: 'publish' }, admin.token)).status, 200);
  assert.equal((await t.api('GET', `/places/reviews?placeId=${place.placeId}`, null, asha.token)).json.summary.count, 2);

  // Account deletion removes the rider's reviews.
  assert.equal((await t.api('DELETE', '/me', null, shanmuk.token)).status, 200);
  await sleep(30);
  page = (await t.api('GET', `/places/reviews?placeId=${place.placeId}`, null, asha.token)).json;
  assert.deepEqual(page.summary, { count: 1, avg: 4 });
  const stored = JSON.stringify([...(t.soda.collections.get('place_reviews') || new Map()).values()]);
  assert.ok(!stored.includes(shanmuk.user.userId), 'no review of the deleted rider is kept');
});
