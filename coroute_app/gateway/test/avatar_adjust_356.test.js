'use strict';
/**
 * 3.56 "Adjust your profile picture" (docs/features_355/profile_photo_adjust.md, src/avatars.js):
 * private original + cropped public picture + crop numbers, owner-only original, re-crop, limits,
 * metadata removed from both, removal (rider and admin) deletes both.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'cropadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const A = require('../src/avatars');

let t;
let admin;
before(async () => { t = await boot(); admin = await t.register('Crop Admin', 'cropadmin@coroute.test'); });
after(async () => { await t.gw.shutdown(); });

function seg(marker, body) { const h = Buffer.alloc(4); h[0] = 0xFF; h[1] = marker; h.writeUInt16BE(body.length + 2, 2); return Buffer.concat([h, body]); }
/** EXIF APP1 with Orientation=6, a camera make and a GPS IFD pointer. */
function exifApp1() {
  const b = Buffer.alloc(64);
  b.write('MM', 0, 'ascii'); b.writeUInt16BE(42, 2); b.writeUInt32BE(8, 4);
  b.writeUInt16BE(3, 8);
  b.writeUInt16BE(0x010F, 10); b.writeUInt16BE(2, 12); b.writeUInt32BE(6, 14); b.writeUInt32BE(50, 18);
  b.writeUInt16BE(0x0112, 22); b.writeUInt16BE(3, 24); b.writeUInt32BE(1, 26); b.writeUInt16BE(6, 30);
  b.writeUInt16BE(0x8825, 34); b.writeUInt16BE(4, 36); b.writeUInt32BE(1, 38); b.writeUInt32BE(56, 42);
  b.writeUInt32BE(0, 46);
  b.write('Canon', 50, 'ascii');
  b.write('GPSLAT', 56, 'ascii');
  return seg(0xE1, Buffer.concat([Buffer.from('Exif\0\0', 'binary'), b]));
}
function jpeg({ w = 1600, h = 1200, exif = true, extra = 0 } = {}) {
  const sof = Buffer.from([8, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  return Buffer.concat([
    Buffer.from([0xFF, 0xD8]),
    seg(0xE0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'binary')),
    ...(exif ? [exifApp1(), seg(0xFE, Buffer.from('home 12.9716,77.5946'))] : []),
    seg(0xDB, Buffer.alloc(65, 1)), seg(0xC0, sof), seg(0xC4, Buffer.alloc(30, 2)),
    seg(0xDA, Buffer.from([3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0])),
    Buffer.alloc(200 + extra, 0x55), Buffer.from([0xFF, 0xD9]),
  ]);
}
async function raw(method, path, buf, token, type = 'image/jpeg') {
  const res = await fetch(t.base + path, { method, headers: { 'Content-Type': type, ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: buf });
  const ct = res.headers.get('content-type') || '';
  return { status: res.status, json: ct.includes('json') ? await res.json() : null, body: ct.includes('json') ? null : Buffer.from(await res.arrayBuffer()), headers: res.headers };
}
const docsOf = (userId) => t.soda.query(A.COLL, { userId }, { limit: 50 });
const profileOf = async (token) => (await t.api('GET', '/me/profile', null, token)).json.profile;
const CROP = 'cx=0.5&cy=0.4&zoom=2&rot=1';

test('crop numbers: clean values only', () => {
  assert.deepEqual(A.normaliseCrop({ cx: '0.5', cy: 0.123456, zoom: 2, rot: 3 }), { cx: 0.5, cy: 0.1235, zoom: 2, rot: 3 });
  assert.deepEqual(A.normaliseCrop('{"cx":0,"cy":1,"zoom":1,"rot":0}'), { cx: 0, cy: 1, zoom: 1, rot: 0 });
  for (const bad of [null, 'x', [], {}, { cx: -0.1, cy: 0, zoom: 1, rot: 0 }, { cx: 0, cy: 1.2, zoom: 1, rot: 0 }, { cx: 0, cy: 0, zoom: 0.5, rot: 0 },
    { cx: 0, cy: 0, zoom: 9, rot: 0 }, { cx: 0, cy: 0, zoom: 1, rot: 4 }, { cx: 0, cy: 0, zoom: 1, rot: 1.5 }, { cx: 'NaN', cy: 0, zoom: 1, rot: 0 },
    { cx: true, cy: 0, zoom: 1, rot: 0 }, { cx: '', cy: 0, zoom: 1, rot: 0 }]) {
    assert.throws(() => A.normaliseCrop(bad), (e) => e.status === 400 && e.code === 'BAD_CROP', JSON.stringify(bad));
  }
});

test('new picture: original (private, no EXIF/GPS) + crop; owner-only original; re-crop keeps the original', async () => {
  const a = await t.register('Crop Rider', 'croprider@coroute.test');
  const b = await t.register('Other Rider', 'cropother@coroute.test');
  assert.equal((await profileOf(a.token)).avatarAdjustable, false);
  assert.equal((await raw('GET', '/me/avatar/original', null, a.token)).status, 404);
  // No original yet: nothing to crop from.
  const early = await raw('POST', `/me/avatar/crop?${CROP}`, jpeg({ w: 512, h: 512, exif: false }), a.token);
  assert.equal(early.status, 409);
  assert.equal(early.json.code, 'NO_ORIGINAL');

  const o = await raw('POST', '/me/avatar/original', jpeg(), a.token);
  assert.equal(o.status, 201, JSON.stringify(o.json));
  assert.match(o.json.originalId, /^avo_[a-f0-9]{24}$/);
  assert.equal(o.json.width, 1600);
  assert.equal(o.json.height, 1200);
  // Pending: not the rider's picture yet, not readable, never through the public route.
  assert.equal((await profileOf(a.token)).avatarUrl, null);
  assert.equal((await raw('GET', '/me/avatar/original', null, a.token)).status, 404);
  assert.equal((await raw('GET', `/avatars/${o.json.originalId}`, null, a.token)).status, 404);

  // Another rider can not use this original, and a made-up id is refused the same way.
  const steal = await raw('POST', `/me/avatar/crop?${CROP}&original=${o.json.originalId}`, jpeg({ w: 512, h: 512, exif: false }), b.token);
  assert.equal(steal.status, 409);
  assert.equal((await raw('POST', `/me/avatar/crop?${CROP}&original=avo_${'0'.repeat(24)}`, jpeg({ w: 512, h: 512 }), a.token)).status, 409);
  assert.equal((await raw('POST', `/me/avatar/crop?${CROP}&original=../x`, jpeg({ w: 512, h: 512 }), a.token)).status, 409);

  const c = await raw('POST', `/me/avatar/crop?${CROP}&original=${o.json.originalId}`, jpeg({ w: 512, h: 512 }), a.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  assert.match(c.json.avatarUrl, /^\/api\/avatars\/av_[a-f0-9]{24}$/);
  assert.deepEqual(c.json.avatarCrop, { cx: 0.5, cy: 0.4, zoom: 2, rot: 1 });
  const p = await profileOf(a.token);
  assert.equal(p.avatarUrl, c.json.avatarUrl);
  assert.equal(p.avatarAdjustable, true);
  assert.deepEqual(p.avatarCrop, { cx: 0.5, cy: 0.4, zoom: 2, rot: 1 });

  // The public cropped picture carries no metadata even when the client left some in.
  const pub = await raw('GET', c.json.avatarUrl.replace('/api', ''), null, b.token);
  assert.equal(pub.status, 200);
  for (const s of ['Canon', 'GPSLAT', '12.9716']) assert.ok(!pub.body.toString('latin1').includes(s), `public picture carries ${s}`);

  // The original: owner only, never cached, no EXIF / GPS / comment; only the orientation stays.
  const mine = await raw('GET', '/me/avatar/original', null, a.token);
  assert.equal(mine.status, 200);
  assert.equal(mine.headers.get('content-type'), 'image/jpeg');
  assert.equal(mine.headers.get('cache-control'), 'no-store');
  assert.deepEqual(JSON.parse(mine.headers.get('x-avatar-crop')), { cx: 0.5, cy: 0.4, zoom: 2, rot: 1 });
  const txt = mine.body.toString('latin1');
  for (const s of ['Canon', 'GPSLAT', '12.9716', '77.5946']) assert.ok(!txt.includes(s), `original carries ${s}`);
  assert.equal(require('../src/review_photos').preparePhoto(mine.body).width, 1600);
  assert.equal((await raw('GET', '/me/avatar/original', null, b.token)).status, 404, "another rider gets their own (none), never A's");
  assert.equal((await raw('GET', '/me/avatar/original', null, null)).status, 401);
  // Admins have no route to a rider's original either.
  assert.equal((await raw('GET', `/avatars/${o.json.originalId}`, null, admin.token)).status, 404);

  // Re-adjust: new crop, same original, new public URL, old public picture gone.
  const c2 = await raw('POST', '/me/avatar/crop?cx=0.3&cy=0.6&zoom=1&rot=0', jpeg({ w: 512, h: 512, exif: false }), a.token);
  assert.equal(c2.status, 201, JSON.stringify(c2.json));
  assert.notEqual(c2.json.avatarUrl, c.json.avatarUrl);
  assert.equal((await raw('GET', c.json.avatarUrl.replace('/api', ''), null, a.token)).status, 404);
  assert.deepEqual((await profileOf(a.token)).avatarCrop, { cx: 0.3, cy: 0.6, zoom: 1, rot: 0 });
  assert.equal((await raw('GET', '/me/avatar/original', null, a.token)).status, 200);
  const docs = await docsOf(a.user.userId);
  assert.equal(docs.length, 2, 'one public picture + one original');
  assert.equal(docs.filter((d) => d.value.kind === 'original' && d.value.pending === false).length, 1);
});

test('limits: crop values, sizes, types; a second original replaces the pending one', async () => {
  const a = await t.register('Limit Rider', 'croplimit@coroute.test');
  assert.equal((await raw('POST', '/me/avatar/original', Buffer.alloc(A.ORIGINAL_MAX_BYTES + 10, 1), a.token)).status, 413);
  assert.equal((await raw('POST', '/me/avatar/original', jpeg({ w: 4000, h: 3000 }), a.token)).status, 415, 'over 2048 px');
  assert.equal((await raw('POST', '/me/avatar/original', Buffer.from('GIF89a not allowed here at all'), a.token)).status, 415);
  assert.equal((await t.api('POST', '/me/avatar/original', { data: 'x' }, a.token)).status, 415);
  const big = await raw('POST', '/me/avatar/original', jpeg({ extra: 1024 * 1024 }), a.token);
  assert.equal(big.status, 201, JSON.stringify(big.json));
  const o2 = await raw('POST', '/me/avatar/original', jpeg({ w: 800, h: 600 }), a.token);
  assert.equal(o2.status, 201);
  assert.equal((await docsOf(a.user.userId)).length, 1, 'the older pending original was removed');

  const id = o2.json.originalId;
  for (const q of ['cx=2&cy=0&zoom=1&rot=0', 'cx=0.5&cy=0.5&zoom=20&rot=0', 'cx=0.5&cy=0.5&zoom=1&rot=7', 'cx=0.5&cy=0.5&zoom=1', 'cx=a&cy=0.5&zoom=1&rot=0']) {
    const r = await raw('POST', `/me/avatar/crop?${q}&original=${id}`, jpeg({ w: 512, h: 512 }), a.token);
    assert.equal(r.status, 400, q);
    assert.equal(r.json.code, 'BAD_CROP');
  }
  assert.equal((await raw('POST', `/me/avatar/crop?${CROP}&original=${id}`, jpeg({ w: 1600, h: 1600 }), a.token)).status, 415, 'the public picture is small');
  assert.equal((await raw('POST', `/me/avatar/crop?${CROP}&original=${id}`, Buffer.alloc(A.MAX_BYTES + 10, 1), a.token)).status, 413);
  assert.equal((await profileOf(a.token)).avatarUrl, null, 'nothing was saved by the refused requests');
  assert.equal((await raw('POST', `/me/avatar/crop?${CROP}&original=${id}`, jpeg({ w: 512, h: 512 }), a.token)).status, 201);
});

test('older apps: a plain upload replaces the picture and drops the original that no longer matches', async () => {
  const a = await t.register('Legacy Rider', 'croplegacy@coroute.test');
  const o = await raw('POST', '/me/avatar/original', jpeg(), a.token);
  await raw('POST', `/me/avatar/crop?${CROP}&original=${o.json.originalId}`, jpeg({ w: 512, h: 512 }), a.token);
  assert.equal((await profileOf(a.token)).avatarAdjustable, true);
  const plain = await raw('POST', '/me/avatar', jpeg({ w: 512, h: 512 }), a.token);
  assert.equal(plain.status, 201);
  const p = await profileOf(a.token);
  assert.equal(p.avatarUrl, plain.json.avatarUrl);
  assert.equal(p.avatarAdjustable, false);
  assert.equal(p.avatarCrop, null);
  assert.equal((await raw('GET', '/me/avatar/original', null, a.token)).status, 404);
  assert.equal((await docsOf(a.user.userId)).length, 1);
});

test('removal deletes both: by the rider, by an admin (audited), and the switch closes the routes', async () => {
  const a = await t.register('Remove Rider', 'cropremove@coroute.test');
  const put = async () => {
    const o = await raw('POST', '/me/avatar/original', jpeg(), a.token);
    return raw('POST', `/me/avatar/crop?${CROP}&original=${o.json.originalId}`, jpeg({ w: 512, h: 512 }), a.token);
  };
  await put();
  assert.equal((await docsOf(a.user.userId)).length, 2);
  assert.equal((await t.api('DELETE', '/me/avatar', null, a.token)).json.removed, true);
  assert.equal((await docsOf(a.user.userId)).length, 0);
  assert.equal((await raw('GET', '/me/avatar/original', null, a.token)).status, 404);
  const p = await profileOf(a.token);
  assert.equal(p.avatarUrl, null);
  assert.equal(p.avatarAdjustable, false);

  await put();
  // A pending upload that was never cropped goes too.
  await raw('POST', '/me/avatar/original', jpeg({ w: 640, h: 480 }), a.token);
  assert.equal((await docsOf(a.user.userId)).length, 3);
  const del = await t.api('DELETE', `/admin/users/${a.user.userId}/avatar`, null, admin.token);
  assert.equal(del.json.removed, true);
  assert.equal((await docsOf(a.user.userId)).length, 0);
  assert.equal((await raw('GET', '/me/avatar/original', null, a.token)).status, 404);

  await put();
  assert.equal((await t.api('PUT', '/admin/features/profilePhotos', { enabled: false, reason: 'test' }, admin.token)).status, 200);
  assert.equal((await raw('POST', '/me/avatar/original', jpeg(), a.token)).status, 403);
  assert.equal((await raw('POST', `/me/avatar/crop?${CROP}`, jpeg({ w: 512, h: 512 }), a.token)).status, 403);
  assert.equal((await raw('GET', '/me/avatar/original', null, a.token)).status, 403);
  await t.api('PUT', '/admin/features/profilePhotos', { enabled: true, reason: 'test' }, admin.token);
});

test('rate limit: picture changes are capped per rider', async () => {
  const a = await t.register('Fast Rider', 'cropfast@coroute.test');
  let limited = 0;
  for (let i = 0; i < 12; i++) {
    const r = await raw('POST', '/me/avatar/original', jpeg({ w: 320, h: 240 }), a.token);
    if (r.status === 429) limited++;
  }
  assert.ok(limited >= 1, 'the upload limiter answered 429');
});
