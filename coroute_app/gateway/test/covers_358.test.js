'use strict';
/**
 * v3.58 profile cover photo (src/covers.js, social_routes.js): the avatar pipeline for a wide picture. Private
 * original (owner only) + public cover, EXIF / GPS stripped, size caps, blocked riders get 404, removal by the
 * rider and by an admin, account erase removes every stored cover.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'coveradmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const CV = require('../src/covers');

let t; let admin;
before(async () => { t = await boot(); admin = await t.register('Cover Admin', 'coveradmin@coroute.test'); });
after(async () => { await t.gw.shutdown(); });

function seg(marker, body) { const h = Buffer.alloc(4); h[0] = 0xFF; h[1] = marker; h.writeUInt16BE(body.length + 2, 2); return Buffer.concat([h, body]); }
function jpeg({ w = 1600, h = 600, extra = 0 } = {}) {
  const sof = Buffer.from([8, h >> 8, h & 255, w >> 8, w & 255, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  return Buffer.concat([
    Buffer.from([0xFF, 0xD8]),
    seg(0xE0, Buffer.from('JFIF\0\x01\x01\0\0\x01\0\x01\0\0', 'binary')),
    seg(0xE1, Buffer.concat([Buffer.from('Exif\0\0', 'binary'), Buffer.from('MM\0*\0\0\0\x08GPS-COVER-SECRET', 'binary')])),
    seg(0xFE, Buffer.from('home 12.9716,77.5946')),
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
const profileOf = async (token) => (await t.api('GET', '/me/profile', null, token)).json.profile;
const docsOf = (userId) => t.soda.query(CV.COLL, { userId }, { limit: 50 });

test('new cover with a private original; public cover served without EXIF; original owner only', async () => {
  const a = await t.register('Cover Rider', 'cover.rider@coroute.test');
  const b = await t.register('Cover Other', 'cover.other@coroute.test');
  assert.equal((await profileOf(a.token)).coverUrl, null);
  assert.equal((await raw('POST', '/me/cover', jpeg())).status, 401);

  const o = await raw('POST', '/me/cover/original', jpeg({ w: 2000, h: 1500 }), a.token);
  assert.equal(o.status, 201, JSON.stringify(o.json));
  assert.match(o.json.originalId, /^cvo_[a-f0-9]{24}$/);
  const c = await raw('POST', `/me/cover?original=${o.json.originalId}&cx=0.5&cy=0.4&zoom=1.5&rot=0`, jpeg(), a.token);
  assert.equal(c.status, 201, JSON.stringify(c.json));
  assert.match(c.json.coverUrl, /^\/api\/covers\/cv_[a-f0-9]{24}$/);
  assert.equal(c.json.coverAdjustable, true);
  assert.deepEqual(c.json.coverCrop, { cx: 0.5, cy: 0.4, zoom: 1.5, rot: 0 });

  const p = await profileOf(a.token);
  assert.equal(p.coverUrl, c.json.coverUrl);
  assert.equal(p.coverAdjustable, true);

  const pic = await raw('GET', c.json.coverUrl.replace('/api', ''), null, b.token);
  assert.equal(pic.status, 200);
  assert.equal(pic.body.includes(Buffer.from('GPS-COVER-SECRET')), false, 'EXIF removed');
  assert.equal(pic.body.includes(Buffer.from('12.9716')), false, 'comments removed');

  const mine = await raw('GET', '/me/cover/original', null, a.token);
  assert.equal(mine.status, 200);
  assert.equal(mine.body.includes(Buffer.from('GPS-COVER-SECRET')), false);
  assert.equal((await raw('GET', '/me/cover/original', null, b.token)).status, 404, 'another rider has no original (never the owner one)');
  assert.equal((await raw('GET', `/covers/${o.json.originalId}`, null, b.token)).status, 404, 'originals are never public');
  // Someone else's original cannot be used.
  assert.equal((await raw('POST', `/me/cover?original=${o.json.originalId}`, jpeg(), b.token)).status, 409);

  // The rider's own profile card carries the cover; a non-friend gets only the small card (no cover).
  const own = await t.api('GET', `/users/${encodeURIComponent(p.username)}/profile`, null, a.token);
  assert.equal(own.json.profile.coverUrl, c.json.coverUrl);
  const viewed = await t.api('GET', `/users/${encodeURIComponent(p.username)}/profile`, null, b.token);
  assert.equal(viewed.json.profile.coverUrl, undefined, 'non-friends do not see the cover');
});

test('replacing removes the old cover; caps; blocked riders get 404; rider and admin removal; erase', async () => {
  const a = await t.register('Cover Two', 'cover.two@coroute.test');
  const b = await t.register('Cover Blocked', 'cover.blocked@coroute.test');
  assert.equal((await raw('POST', '/me/cover', Buffer.from('<svg/>'), a.token, 'image/svg+xml')).status, 415);
  assert.equal((await raw('POST', '/me/cover', jpeg({ w: 4000, h: 1000 }), a.token)).status, 415, 'over 2048 px');
  assert.equal((await raw('POST', '/me/cover', jpeg({ extra: 2 * 1024 * 1024 }), a.token)).status, 413, 'over 2 MB');

  const first = await raw('POST', '/me/cover', jpeg(), a.token);
  assert.equal(first.status, 201);
  assert.equal(first.json.coverAdjustable, false, 'a plain upload keeps no original');
  const second = await raw('POST', '/me/cover', jpeg(), a.token);
  assert.notEqual(second.json.coverUrl, first.json.coverUrl);
  const me = await t.api('GET', '/me', null, a.token);
  const uid = me.json.user ? me.json.user.userId : me.json.userId;
  assert.equal((await docsOf(uid)).length, 1, 'the replaced cover is gone');
  assert.equal((await raw('GET', first.json.coverUrl.replace('/api', ''), null, b.token)).status, 404);

  const bName = (await profileOf(b.token)).username;
  assert.equal((await t.api('POST', '/blocks', { username: bName }, a.token)).status, 200);
  assert.equal((await raw('GET', second.json.coverUrl.replace('/api', ''), null, b.token)).status, 404, 'blocked: not served');

  // Admin moderation.
  const adminDel = await t.api('DELETE', `/admin/users/${uid}/cover`, null, admin.token);
  assert.equal(adminDel.status, 200);
  assert.equal(adminDel.json.removed, true);
  assert.equal((await profileOf(a.token)).coverUrl, null);
  assert.equal((await docsOf(uid)).length, 0);
  assert.equal((await t.api('DELETE', `/admin/users/${uid}/cover`, null, a.token)).status, 403);

  // Rider removal + erase.
  await raw('POST', '/me/cover', jpeg(), a.token);
  assert.equal((await t.api('DELETE', '/me/cover', null, a.token)).json.removed, true);
  await raw('POST', '/me/cover', jpeg(), a.token);
  await CV.forgetCovers(t.soda, uid);
  assert.equal((await docsOf(uid)).length, 0);
});
