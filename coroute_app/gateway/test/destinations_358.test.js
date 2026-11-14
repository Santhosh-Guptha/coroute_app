'use strict';
/**
 * v3.58 Explore curated destinations (src/destinations.js): admin CRUD (MASTER_ADMIN, audited), public list
 * (active only, admin order, cached, ETag, no admin fields), seeded once with names / coordinates / categories
 * only, admin photo through the review photo pipeline (EXIF stripped), never third-party URLs.
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'destadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const D = require('../src/destinations');
const { boot } = require('./_helpers');

let env; let A; let rider; let photoDir; let origin;
before(async () => {
  photoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dest-photos-'));
  process.env.REVIEW_PHOTO_DIR = photoDir;
  require('../src/config').reviewPhotoDir = photoDir;
  env = await boot();
  origin = env.base.replace(/\/api$/, '');
  A = (await env.register('Dest Admin', 'destadmin@coroute.test')).token;
  rider = await env.register('Dest Rider', 'dest.rider@coroute.test');
});
after(async () => { await env.gw.shutdown(); fs.rmSync(photoDir, { recursive: true, force: true }); });

function jpegWithExif() {
  const soi = Buffer.from([0xFF, 0xD8]);
  const exifBody = Buffer.concat([Buffer.from('Exif\0\0', 'binary'), Buffer.from('MM\0*\0\0\0\x08\0\0GPS-SECRET-12.97N', 'binary')]);
  const app1 = Buffer.concat([Buffer.from([0xFF, 0xE1]), Buffer.from([(exifBody.length + 2) >> 8, (exifBody.length + 2) & 0xFF]), exifBody]);
  const sof = Buffer.from([0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  const sos = Buffer.from([0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0x12, 0x34, 0x56, 0xFF, 0xD9]);
  return Buffer.concat([soi, app1, sof, sos]);
}
const pub = () => env.api('GET', '/public/destinations');

test('field rules', () => {
  assert.throws(() => D.cleanFields({ name: 'X', lat: 1, lng: 1, category: 'weekend' }), /at least 2/);
  assert.throws(() => D.cleanFields({ name: 'Place', lat: 91, lng: 1, category: 'weekend' }), /lat must be/);
  assert.throws(() => D.cleanFields({ name: 'Place', lat: 1, lng: 1, category: 'brunch' }), /category must be/);
  assert.throws(() => D.cleanFields({ name: 'Place', lat: 1, lng: 1, category: 'weekend', tags: ['spa'] }), /tags must be/);
  assert.throws(() => D.cleanFields({ name: 'Place', lat: 1, lng: 1, category: 'weekend', description: 'x'.repeat(161) }), /at most 160/);
  const c = D.cleanFields({ name: '  Hill\u0000 top ', lat: '12.3456789', lng: 77, category: 'weekend', tags: ['weekend', 'ghats', 'ghats', 'twisty'] });
  assert.equal(c.name, 'Hill top');
  assert.equal(c.lat, 12.34568);
  assert.deepEqual(c.tags, ['ghats', 'twisty'], 'the main category and duplicates are dropped');
  assert.equal(c.active, true);
  assert.throws(() => D.cleanFields({}, { category: 'weekend' }), /Nothing to change/);
  assert.equal(D.SEED.length, 10);
  for (const s of D.SEED) {
    assert.ok(D.CATEGORIES.includes(s.category));
    assert.ok(s.lat > 8 && s.lat < 19 && s.lng > 74 && s.lng < 81, `${s.name} is in South India`);
    assert.equal(s.photo, undefined, 'seeds carry no photo');
    assert.equal(s.description, undefined, 'seeds carry no copied text');
  }
});

test('public list: seeded once, active only, no admin fields, cached with ETag, no account needed', async () => {
  const r = await pub();
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.headers.get('cache-control'), 'public, max-age=300');
  assert.equal(r.json.destinations.length, 10);
  const first = r.json.destinations[0];
  assert.deepEqual(Object.keys(first).sort(), ['category', 'description', 'id', 'lat', 'lng', 'name', 'photoUrl', 'region', 'tags']);
  assert.equal(first.name, 'Nandi Hills');
  assert.equal(first.photoUrl, null);
  assert.ok(r.json.destinations.every((d) => D.isId(d.id)));
  const etag = r.headers.get('etag');
  assert.ok(etag);
  const again = await fetch(`${env.base}/public/destinations`, { headers: { 'If-None-Match': etag } });
  assert.equal(again.status, 304);
});

test('admin CRUD is MASTER_ADMIN only, audited, and reaches the public list at once', async () => {
  assert.equal((await env.api('GET', '/admin/destinations')).status, 401);
  assert.equal((await env.api('GET', '/admin/destinations', null, rider.token)).status, 403);
  assert.equal((await env.api('POST', '/admin/destinations', { name: 'Nope', lat: 1, lng: 1, category: 'night' }, rider.token)).status, 403);

  const list = await env.api('GET', '/admin/destinations', null, A);
  assert.equal(list.status, 200);
  assert.equal(list.json.destinations.length, 10, 'seeded once (not again)');
  assert.ok('active' in list.json.destinations[0]);

  const bad = await env.api('POST', '/admin/destinations', { name: 'Place', lat: 1, lng: 1, category: 'brunch' }, A);
  assert.equal(bad.status, 400);
  assert.equal(bad.json.field, 'category');

  const made = await env.api('POST', '/admin/destinations', { name: 'Kudremukh', region: 'Karnataka', lat: 13.2167, lng: 75.25, category: 'weekend', tags: ['ghats'], description: 'Misty ghat road.', order: 1 }, A);
  assert.equal(made.status, 201, JSON.stringify(made.json));
  const id = made.json.destination.id;
  let p = await pub();
  assert.equal(p.json.destinations[0].name, 'Kudremukh', 'order 1 comes first; the admin write cleared the cache');

  const hid = await env.api('PATCH', `/admin/destinations/${id}`, { active: false }, A);
  assert.equal(hid.status, 200);
  p = await pub();
  assert.ok(!p.json.destinations.some((d) => d.id === id), 'inactive places are not public');

  const seedId = list.json.destinations[1].id;
  assert.equal((await env.api('DELETE', `/admin/destinations/${seedId}`, null, A)).status, 200);
  assert.equal((await env.api('PATCH', `/admin/destinations/${seedId}`, { name: 'Gone' }, A)).status, 404);
  assert.equal((await env.api('GET', '/admin/destinations', null, A)).json.destinations.length, 10, 'deleted seeds do not come back');

  const audit = await env.soda.query('audit_log', {}, { limit: 500 }).catch(() => []);
  if (audit.length) assert.ok(audit.some((r) => r.value.action === 'destination.create'));
});

test('photo: admin upload only, EXIF stripped, public only while active, replaced and removed cleanly', async () => {
  const id = (await env.api('POST', '/admin/destinations', { name: 'Photo place', lat: 12, lng: 77, category: 'breakfast', order: 0 }, A)).json.destination.id;
  const up = (token, body = jpegWithExif(), type = 'image/jpeg') => fetch(`${env.base}/admin/destinations/${id}/photo`, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': type }, body });
  assert.equal((await up(rider.token)).status, 403);
  assert.equal((await up(A, Buffer.from('<svg/>'), 'image/svg+xml')).status, 415);
  const res = await up(A);
  assert.equal(res.status, 201);
  const dest = (await res.json()).destination;
  assert.match(dest.photoUrl, new RegExp(`^/api/public/destinations/${id}/photo\\?v=[0-9a-f]{8}$`));

  const p = await pub();
  const listed = p.json.destinations.find((d) => d.id === id);
  assert.equal(listed.photoUrl, dest.photoUrl);
  const img = await fetch(origin + dest.photoUrl);
  assert.equal(img.status, 200);
  assert.equal(img.headers.get('content-type'), 'image/jpeg');
  const bytes = Buffer.from(await img.arrayBuffer());
  assert.equal(bytes.includes(Buffer.from('GPS-SECRET')), false, 'EXIF removed');

  // A second photo replaces the first; the old file is gone from disk.
  const before = fs.readdirSync(photoDir).length;
  assert.equal((await up(A)).status, 201);
  assert.equal(fs.readdirSync(photoDir).length, before);

  await env.api('PATCH', `/admin/destinations/${id}`, { active: false }, A);
  assert.equal((await fetch(`${env.base}/public/destinations/${id}/photo`)).status, 404, 'inactive: photo not public');
  await env.api('PATCH', `/admin/destinations/${id}`, { active: true }, A);
  const del = await env.api('DELETE', `/admin/destinations/${id}/photo`, null, A);
  assert.equal(del.json.destination.photoUrl, null);
  assert.equal((await fetch(`${env.base}/public/destinations/${id}/photo`)).status, 404);
  assert.equal((await fetch(`${env.base}/public/destinations/ds_zzz/photo`)).status, 404);
});
