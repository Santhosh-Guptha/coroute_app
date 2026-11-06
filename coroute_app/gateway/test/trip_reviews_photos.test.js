'use strict';
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'admin@coroute.test';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { boot } = require('./_helpers');
const config = require('../src/config');
const reviews = require('../src/trip_reviews');
const photos = require('../src/review_photos');

// ---------- tiny image fixtures (structurally valid; the gateway never decodes pixels) ----------
function seg(marker, body) {
  const h = Buffer.from([0xFF, marker, 0, 0]);
  h.writeUInt16BE(body.length + 2, 2);
  return Buffer.concat([h, body]);
}
/** EXIF APP1 with Orientation=6, a camera make and a GPS IFD pointer, big-endian. */
function exifApp1() {
  const t = Buffer.alloc(64);
  t.write('MM', 0, 'ascii'); t.writeUInt16BE(42, 2); t.writeUInt32BE(8, 4);
  t.writeUInt16BE(3, 8);
  t.writeUInt16BE(0x010F, 10); t.writeUInt16BE(2, 12); t.writeUInt32BE(6, 14); t.writeUInt32BE(50, 18); // Make -> offset 50
  t.writeUInt16BE(0x0112, 22); t.writeUInt16BE(3, 24); t.writeUInt32BE(1, 26); t.writeUInt16BE(6, 30); // Orientation 6
  t.writeUInt16BE(0x8825, 34); t.writeUInt16BE(4, 36); t.writeUInt32BE(1, 38); t.writeUInt32BE(56, 42); // GPS IFD
  t.writeUInt32BE(0, 46);
  t.write('Canon', 50, 'ascii');
  t.write('GPSLAT', 56, 'ascii');
  return seg(0xE1, Buffer.concat([Buffer.from('Exif\0\0', 'binary'), t]));
}
function jpeg({ exif = true, extra = 0 } = {}) {
  const sof = Buffer.from([8, 0x01, 0xE0, 0x02, 0x80, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]); // 640 x 480
  return Buffer.concat([
    Buffer.from([0xFF, 0xD8]),
    seg(0xE0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'binary')),
    ...(exif ? [exifApp1(), seg(0xED, Buffer.from('Photoshop 3.0\0IPTC-CITY', 'binary')), seg(0xFE, Buffer.from('my phone 9876543210'))] : []),
    seg(0xDB, Buffer.alloc(65, 1)),
    seg(0xC0, sof),
    seg(0xC4, Buffer.alloc(30, 2)),
    seg(0xDA, Buffer.from([3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0])),
    Buffer.alloc(200 + extra, 0x55),
    Buffer.from([0xFF, 0xD9]),
  ]);
}
function pngChunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  return Buffer.concat([len, Buffer.from(type, 'ascii'), data, Buffer.alloc(4)]); // CRC not checked here
}
function png() {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(800, 0); ihdr.writeUInt32BE(600, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    pngChunk('IHDR', ihdr), pngChunk('tEXt', Buffer.from('Location\0Coorg 12.3,76.6')), pngChunk('eXIf', Buffer.from('MM GPS')),
    pngChunk('IDAT', Buffer.alloc(100, 7)), pngChunk('IEND', Buffer.alloc(0)),
  ]);
}
function webpChunk(fourcc, data) {
  const h = Buffer.alloc(8); h.write(fourcc, 0, 'ascii'); h.writeUInt32LE(data.length, 4);
  return Buffer.concat([h, data, data.length % 2 ? Buffer.alloc(1) : Buffer.alloc(0)]);
}
function webp() {
  const vp8x = Buffer.alloc(10); vp8x[0] = 0x08 | 0x04; vp8x.writeUIntLE(1023, 4, 3); vp8x.writeUIntLE(767, 7, 3);
  const body = Buffer.concat([webpChunk('VP8X', vp8x), webpChunk('VP8L', Buffer.alloc(40, 9)), webpChunk('EXIF', Buffer.from('GPSDATA-HERE')), webpChunk('XMP ', Buffer.from('<x:xmpmeta>gps</x:xmpmeta>'))]);
  const h = Buffer.alloc(12); h.write('RIFF', 0, 'ascii'); h.writeUInt32LE(body.length + 4, 4); h.write('WEBP', 8, 'ascii');
  return Buffer.concat([h, body]);
}

test('review photo helpers: magic bytes, metadata stripping, templates, contact details', () => {
  assert.equal(photos.sniff(jpeg()), 'jpeg');
  assert.equal(photos.sniff(png()), 'png');
  assert.equal(photos.sniff(webp()), 'webp');
  assert.equal(photos.sniff(Buffer.from('GIF89a..........')), null);
  assert.equal(photos.sniff(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>')), null);

  const j = photos.preparePhoto(jpeg());
  assert.equal(j.mime, 'image/jpeg');
  assert.deepEqual([j.width, j.height], [640, 480]);
  const js = j.data.toString('latin1');
  for (const s of ['Canon', 'GPSLAT', 'IPTC-CITY', '9876543210']) assert.ok(!js.includes(s), `JPEG still carries ${s}`);
  // Only the orientation is written back, so the photo is not shown sideways.
  const app1 = j.data.indexOf(Buffer.from([0xFF, 0xE1]));
  assert.ok(app1 > 0);
  assert.equal(photos.exifOrientation(j.data.slice(app1 + 4, app1 + 4 + j.data.readUInt16BE(app1 + 2) - 2)), 6);
  assert.equal(j.data.slice(-2).toString('hex'), 'ffd9');
  // A JPEG without EXIF passes through without an added orientation segment.
  assert.equal(photos.preparePhoto(jpeg({ exif: false })).data.indexOf(Buffer.from([0xFF, 0xE1])), -1);

  const p = photos.preparePhoto(png());
  assert.deepEqual([p.width, p.height], [800, 600]);
  assert.ok(!p.data.toString('latin1').includes('Coorg') && !p.data.toString('latin1').includes('eXIf'));
  assert.ok(p.data.toString('latin1').includes('IDAT') && p.data.toString('latin1').includes('IEND'));

  const w = photos.preparePhoto(webp());
  assert.deepEqual([w.width, w.height], [1024, 768]);
  const ws = w.data.toString('latin1');
  assert.ok(!ws.includes('GPSDATA') && !ws.includes('xmpmeta'));
  assert.equal(w.data.readUInt32LE(4), w.data.length - 8, 'RIFF size matches');
  assert.equal(w.data[20] & 0x0C, 0, 'EXIF/XMP flags cleared');

  assert.throws(() => photos.preparePhoto(Buffer.alloc(0)), (e) => e.code === 'NO_PHOTO' && e.status === 400);
  assert.throws(() => photos.preparePhoto(Buffer.from('just some text, not an image at all')), (e) => e.code === 'UNSUPPORTED_PHOTO' && e.status === 415);
  assert.throws(() => photos.preparePhoto(Buffer.alloc(photos.MAX_BYTES + 1, 0xFF)), (e) => e.code === 'PHOTO_TOO_LARGE' && e.status === 413);
  assert.throws(() => photos.preparePhoto(Buffer.concat([Buffer.from([0xFF, 0xD8, 0xFF, 0xE0, 0x40, 0]), Buffer.alloc(10)])), (e) => e.code === 'BAD_PHOTO');

  assert.deepEqual(reviews.TEMPLATE_IDS, ['photo-left', 'photo-top', 'quote-card', 'gallery']);
  assert.equal(reviews.canonicalTemplate('multi-pic-grid'), 'gallery');
  assert.equal(reviews.canonicalTemplate('bogus'), null);
  assert.equal(reviews.resolveTemplate('gallery', 3), 'gallery');
  assert.equal(reviews.resolveTemplate('gallery', 1), 'photo-top');
  assert.equal(reviews.resolveTemplate('photo-left', 0), 'quote-card');
  assert.equal(reviews.resolveTemplate(null, 2), 'gallery');
  assert.equal(reviews.resolveTemplate(undefined, 0), 'quote-card');

  assert.equal(reviews.contactInfoIn('Mail me at rider.one@example.com'), 'email');
  assert.equal(reviews.contactInfoIn('Call +91 98765 43210 for the route'), 'phone');
  assert.equal(reviews.contactInfoIn('Call 98765-43210'), 'phone');
  assert.equal(reviews.contactInfoIn('We rode 1,250 km over 3 days in 2024, top speed 80.'), null);
  assert.equal(reviews.contactInfoIn('Left at 05:30, back on 12.10.2024.'), null);
});

test('review photos: consent, eligibility, type and size, count, visibility rules', async (t) => {
  const env = await boot();
  t.after(() => env.gw.shutdown());
  const { api, gw, base } = env;
  const admin = await env.register('Admin User', 'admin@coroute.test');
  const alice = await env.register('Alice Rider', 'alice@coroute.test');
  const bob = await env.register('Bob Rider', 'bob@coroute.test');
  const now = Date.now();
  await gw.repo.saveTrip({ tripId: 'TRIP-PH-ALICE', userId: alice.user.userId, tripName: 'Coorg loop', startLocationName: 'Mysuru', destinationName: 'Madikeri', startTimeEpochMs: now - 86400000, endTimeEpochMs: now - 3600000, totalDistanceKm: 240 });
  await gw.repo.saveTrip({ tripId: 'TRIP-PH-LIVE', userId: alice.user.userId, tripName: 'Still riding', startTimeEpochMs: now - 3600000 });

  const upload = (tripId, body, token, type = 'image/jpeg') => fetch(`${base}/trips/${tripId}/feedback/photos`, {
    method: 'POST',
    headers: { 'Content-Type': type, ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body,
  }).then(async (r) => ({ status: r.status, json: await r.json().catch(() => ({})) }));
  const getRaw = (url, token) => fetch(url.startsWith('http') ? url : `${env.origin}${url}`, { headers: token ? { Authorization: `Bearer ${token}` } : {} })
    .then(async (r) => ({ status: r.status, type: r.headers.get('content-type'), cache: r.headers.get('cache-control'), body: Buffer.from(await r.arrayBuffer()) }));
  const review = (extra = {}) => ({
    rating: 5,
    writtenFeedback: 'The whole group made it over the ghat together.',
    consentPublish: true,
    consentTripDetails: true,
    consentPhoto: true,
    photos: [],
    ...extra,
  });
  let feedbackId;
  const ids = {};

  await t.test('no review yet, no sign-in, not a participant, not finished', async () => {
    assert.equal((await upload('TRIP-PH-ALICE', jpeg(), null)).status, 401);
    const first = await upload('TRIP-PH-ALICE', jpeg(), alice.token);
    assert.equal(first.status, 409);
    assert.equal(first.json.code, 'REVIEW_REQUIRED');
    const bobs = await upload('TRIP-PH-ALICE', jpeg(), bob.token);
    assert.equal(bobs.status, 403);
    assert.equal(bobs.json.code, 'NOT_PARTICIPANT');
    const live = await upload('TRIP-PH-LIVE', jpeg(), alice.token);
    assert.equal(live.status, 409);
    assert.equal(live.json.code, 'TRIP_NOT_COMPLETED');
  });

  await t.test('without the photo consent box ticked, uploads are refused', async () => {
    const r = await api('POST', '/trips/TRIP-PH-ALICE/feedback', review({ consentPhoto: false }), alice.token);
    assert.equal(r.status, 201);
    assert.equal(r.json.feedback.consentPhoto, false);
    feedbackId = r.json.feedback.feedbackId;
    const up = await upload('TRIP-PH-ALICE', jpeg(), alice.token);
    assert.equal(up.status, 409);
    assert.equal(up.json.code, 'PHOTO_CONSENT_REQUIRED');
    // The photo box only counts together with publication consent.
    const r2 = await api('POST', '/trips/TRIP-PH-ALICE/feedback', review({ consentPublish: false }), alice.token);
    assert.equal(r2.json.feedback.consentPhoto, false);
    assert.equal((await upload('TRIP-PH-ALICE', jpeg(), alice.token)).json.code, 'PHOTO_CONSENT_REQUIRED');
  });

  await t.test('type, size and magic bytes are checked', async () => {
    const r = await api('POST', '/trips/TRIP-PH-ALICE/feedback', review(), alice.token);
    assert.equal(r.status, 200);
    assert.equal(r.json.feedback.consentPhoto, true);
    const text = await upload('TRIP-PH-ALICE', Buffer.from('<?php echo "not an image"; ?> padding padding'), alice.token);
    assert.equal(text.status, 415);
    assert.equal(text.json.code, 'UNSUPPORTED_PHOTO');
    const spoofed = await upload('TRIP-PH-ALICE', Buffer.from('GIF89a fake gif bytes here'), alice.token, 'image/png');
    assert.equal(spoofed.status, 415);
    const asJson = await upload('TRIP-PH-ALICE', JSON.stringify({ data: jpeg().toString('base64') }), alice.token, 'application/json');
    assert.equal(asJson.status, 415);
    const big = await upload('TRIP-PH-ALICE', jpeg({ extra: photos.MAX_BYTES }), alice.token);
    assert.equal(big.status, 413);
    assert.equal(big.json.code, 'PHOTO_TOO_LARGE');
    const empty = await upload('TRIP-PH-ALICE', Buffer.alloc(0), alice.token);
    assert.equal(empty.status, 400);
  });

  await t.test('up to three photos; stored without location metadata, outside public/', async () => {
    const a = await upload('TRIP-PH-ALICE', jpeg(), alice.token);
    assert.equal(a.status, 201, JSON.stringify(a.json));
    ids.jpeg = a.json.photo.id;
    assert.match(ids.jpeg, /^rp_[a-f0-9]{24}$/);
    assert.equal(a.json.photo.mime, 'image/jpeg');
    assert.equal(a.json.feedback.status, 'PENDING_REVIEW');
    assert.equal(a.json.feedback.uploadedPhotos.length, 1);
    const b = await upload('TRIP-PH-ALICE', png(), alice.token, 'application/octet-stream');
    assert.equal(b.status, 201);
    ids.png = b.json.photo.id;
    const c = await upload('TRIP-PH-ALICE', webp(), alice.token, 'image/webp');
    assert.equal(c.status, 201);
    ids.webp = c.json.photo.id;
    const d = await upload('TRIP-PH-ALICE', jpeg(), alice.token);
    assert.equal(d.status, 409);
    assert.equal(d.json.code, 'TOO_MANY_PHOTOS');

    const file = path.join(config.reviewPhotoDir, `${ids.jpeg}.jpg`);
    assert.ok(fs.existsSync(file), 'stored in the configured data folder');
    assert.ok(!path.resolve(config.reviewPhotoDir).startsWith(path.resolve(__dirname, '..', 'public')), 'not under public/');
    const stored = fs.readFileSync(file).toString('latin1');
    assert.ok(!stored.includes('GPSLAT') && !stored.includes('Canon'), 'EXIF removed');
    const statics = await getRaw(`/${ids.jpeg}.jpg`);
    assert.equal(statics.status, 404);

    // The rider sees their own photo; nobody else does through that route.
    const own = await getRaw(`/api/trips/TRIP-PH-ALICE/feedback/photos/${ids.jpeg}`, alice.token);
    assert.equal(own.status, 200);
    assert.equal(own.type, 'image/jpeg');
    assert.match(own.cache, /no-store/);
    assert.equal((await getRaw(`/api/trips/TRIP-PH-ALICE/feedback/photos/${ids.jpeg}`, bob.token)).status, 404);
  });

  const media = (pid) => `/api/public/review-photos/${feedbackId}/${pid}`;
  await t.test('pending: not public; the admin can see every photo', async () => {
    assert.equal((await getRaw(media(ids.jpeg))).status, 404);
    const list = await api('GET', '/admin/reviews', undefined, admin.token);
    assert.deepEqual(list.json.templates.map((x) => x.id), reviews.TEMPLATE_IDS);
    const item = list.json.reviews.find((x) => x.feedbackId === feedbackId);
    assert.equal(item.photoItems.length, 3);
    assert.ok(item.photoItems.every((p) => p.uploaded && p.url.startsWith(`/admin/reviews/${feedbackId}/photos/`)));
    const adminView = await getRaw(`/api${item.photoItems[0].url}`, admin.token);
    assert.equal(adminView.status, 200);
    assert.equal((await getRaw(`/api${item.photoItems[0].url}`, alice.token)).status, 403);
    assert.equal((await getRaw(`/api${item.photoItems[0].url}`)).status, 401);
  });

  await t.test('templates and the excerpt are validated on approval', async () => {
    const bogus = await api('PUT', `/admin/reviews/${feedbackId}`, { action: 'APPROVE', template: 'bogus', selectedPhotos: [ids.jpeg] }, admin.token);
    assert.equal(bogus.status, 422);
    assert.ok(bogus.json.fields.template);
    const thin = await api('PUT', `/admin/reviews/${feedbackId}`, { action: 'APPROVE', template: 'gallery', selectedPhotos: [ids.jpeg] }, admin.token);
    assert.equal(thin.status, 422);
    assert.equal(thin.json.code, 'TEMPLATE_NEEDS_PHOTOS');
    const noPhoto = await api('PUT', `/admin/reviews/${feedbackId}`, { action: 'APPROVE', template: 'photo-top', selectedPhotos: [] }, admin.token);
    assert.equal(noPhoto.json.code, 'TEMPLATE_NEEDS_PHOTOS');
    const phone = await api('PUT', `/admin/reviews/${feedbackId}`, { action: 'APPROVE', template: 'quote-card', formattedText: 'Great ride, call me on 98765 43210' }, admin.token);
    assert.equal(phone.status, 422);
    assert.ok(phone.json.fields.formattedText);
    const mail = await api('PUT', `/admin/reviews/${feedbackId}`, { action: 'EDIT', formattedText: 'Write to alice@coroute.test' }, admin.token);
    assert.equal(mail.status, 422);
    const blank = await api('PUT', `/admin/reviews/${feedbackId}`, { action: 'APPROVE', formattedText: '   ' }, admin.token);
    assert.equal(blank.status, 409);
    assert.equal(blank.json.code, 'NOTHING_TO_PUBLISH');
    const still = await api('GET', '/admin/reviews', undefined, admin.token);
    assert.equal(still.json.reviews.find((x) => x.feedbackId === feedbackId).status, 'PENDING_REVIEW');
  });

  await t.test('approved and selected: public; unselected photos stay private', async () => {
    const ok = await api('PUT', `/admin/reviews/${feedbackId}`, {
      action: 'APPROVE', template: 'gallery', selectedPhotos: [ids.jpeg, ids.webp], formattedText: 'The whole group made it over the ghat together.',
    }, admin.token);
    assert.equal(ok.status, 200, JSON.stringify(ok.json));
    assert.equal(ok.json.feedback.template, 'gallery');
    const pub = await api('GET', '/public/community-stories');
    assert.match(pub.headers.get('cache-control'), /max-age=30/);
    const story = pub.json.stories.find((s) => s.feedbackId === feedbackId);
    assert.equal(story.template, 'gallery');
    assert.deepEqual(story.photos, [media(ids.jpeg), media(ids.webp)]);
    assert.deepEqual(story.photoSizes, [{ width: 640, height: 480 }, { width: 1024, height: 768 }]);
    assert.ok(!JSON.stringify(story).includes('@'));
    const img = await getRaw(story.photos[0]);
    assert.equal(img.status, 200);
    assert.equal(img.type, 'image/jpeg');
    assert.ok(!img.body.toString('latin1').includes('GPSLAT'));
    assert.equal((await getRaw(story.photos[1])).type, 'image/webp');
    assert.equal((await getRaw(media(ids.png))).status, 404, 'not selected by the admin');
    assert.equal((await getRaw(`/api/public/review-photos/FB-NOPE1234/${ids.jpeg}`)).status, 404);
    assert.equal((await getRaw(`/api/public/review-photos/${feedbackId}/..%2F..%2Fsrc%2Fconfig.js`)).status, 404);
  });

  await t.test('a rider edit takes photos off the site until approved again; removed photos are deleted', async () => {
    const r = await api('POST', '/trips/TRIP-PH-ALICE/feedback', review({ photos: [ids.jpeg, ids.webp] }), alice.token);
    assert.equal(r.status, 200);
    assert.equal(r.json.feedback.status, 'PENDING_REVIEW');
    assert.deepEqual(r.json.feedback.uploadedPhotos.map((u) => u.id), [ids.jpeg, ids.webp]);
    assert.equal((await getRaw(media(ids.jpeg))).status, 404);
    assert.ok(!fs.existsSync(path.join(config.reviewPhotoDir, `${ids.png}.png`)), 'dropped photo deleted');
    // Someone else's photo id cannot be claimed.
    const forged = await api('POST', '/trips/TRIP-PH-ALICE/feedback', review({ photos: [ids.jpeg, 'rp_0123456789abcdef01234567'] }), alice.token);
    assert.deepEqual(forged.json.feedback.photos, [ids.jpeg]);
    const ok = await api('PUT', `/admin/reviews/${feedbackId}`, { action: 'APPROVE', template: 'photo-left', selectedPhotos: [ids.jpeg] }, admin.token);
    assert.equal(ok.status, 200);
    assert.equal((await getRaw(media(ids.jpeg))).status, 200);
  });

  await t.test('withdrawn: photos disappear; unticking photo consent removes them', async () => {
    const w = await api('DELETE', '/trips/TRIP-PH-ALICE/feedback', undefined, alice.token);
    assert.equal(w.status, 200);
    assert.equal((await getRaw(media(ids.jpeg))).status, 404);
    const pub = await api('GET', '/public/community-stories');
    assert.ok(!pub.json.stories.some((s) => s.feedbackId === feedbackId));
    assert.equal((await upload('TRIP-PH-ALICE', jpeg(), alice.token)).json.code, 'REVIEW_REQUIRED');
    const r = await api('POST', '/trips/TRIP-PH-ALICE/feedback', review({ consentPhoto: false, photos: [ids.jpeg] }), alice.token);
    assert.equal(r.json.feedback.consentPhoto, false);
    assert.deepEqual(r.json.feedback.uploadedPhotos, []);
    assert.equal((await getRaw(`/api/trips/TRIP-PH-ALICE/feedback/photos/${ids.jpeg}`, alice.token)).status, 404);
  });
});
