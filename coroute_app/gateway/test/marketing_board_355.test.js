'use strict';
/**
 * 3.56 marketing board (src/board.js, docs/features_355/marketing_board.md): admin posts on the website's
 * "Latest from CoRoute" (home top 3, /updates all). Website only, never pushed into the app.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'boardadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const board = require('../src/board');
const { boot } = require('./_helpers');

const DAY = 86400000;
let env; let A; let rider; let origin;
let photoDir;
before(async () => {
  photoDir = fs.mkdtempSync(path.join(os.tmpdir(), 'board-photos-'));
  process.env.REVIEW_PHOTO_DIR = photoDir;
  require('../src/config').reviewPhotoDir = photoDir;
  env = await boot();
  origin = env.base.replace(/\/api$/, '');
  const r = await env.api('POST', '/auth/register', { name: 'Board Admin', email: 'boardadmin@coroute.test', password: 'Password#123', phone: '+919833300000', vehicleType: 'Motorcycle', vehicleNo: 'KA03ZZ9999', emergencyContact: '+919000000001', emergencyContactName: 'Family' });
  A = r.json.token;
  rider = await env.register('Board Rider', 'board.rider@coroute.test');
});
after(async () => { await env.gw.shutdown(); fs.rmSync(photoDir, { recursive: true, force: true }); });

const post = (body) => env.api('POST', '/admin/board', body, A);
const publicBoard = (q = '') => env.api('GET', `/public/board${q}`);
/** A small JPEG with an EXIF (APP1) segment that carries GPS-like bytes. */
function jpegWithExif() {
  const soi = Buffer.from([0xFF, 0xD8]);
  const exifBody = Buffer.concat([Buffer.from('Exif\0\0', 'binary'), Buffer.from('MM\0*\0\0\0\x08\0\0GPS-SECRET-48.8584N', 'binary')]);
  const app1 = Buffer.concat([Buffer.from([0xFF, 0xE1]), Buffer.from([(exifBody.length + 2) >> 8, (exifBody.length + 2) & 0xFF]), exifBody]);
  const sof = Buffer.from([0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  const sos = Buffer.from([0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0x12, 0x34, 0x56, 0xFF, 0xD9]);
  return Buffer.concat([soi, app1, sof, sos]);
}

test('field rules: lengths, plain text with line breaks, internal links only, kinds, window', () => {
  assert.throws(() => board.cleanPost({ title: 'x'.repeat(81), body: 'b' }), /at most 80/);
  assert.throws(() => board.cleanPost({ title: 't', body: 'b'.repeat(601) }), /at most 600/);
  const c = board.cleanPost({ title: '  New\tthing\u0000 ', body: 'Line one\r\nLine two\n\n\n\nPara\u0007', kind: 'event' });
  assert.equal(c.title, 'New thing');
  assert.equal(c.body, 'Line one\nLine two\n\nPara');
  for (const bad of ['https://evil.example', '//evil.example', '/api/admin/coupons', '/admin', 'javascript:alert(1)', '/plans/../admin', '/%2e%2e/x', ' /x y']) {
    assert.throws(() => board.cleanLink(bad), /page of this website/, bad);
  }
  for (const ok of ['/plans', '/plans?coupon=RIDE10', '/safety#sos', '/updates']) assert.equal(board.cleanLink(ok), ok);
  assert.throws(() => board.cleanPost({ title: 't', body: 'b', kind: 'push' }), /kind must be/);
  assert.throws(() => board.cleanPost({ title: 't', body: 'b', startAt: '2026-12-10', endAt: '2026-12-01' }), /end after it starts/);
  assert.equal(board.cleanPost({ title: 't', body: 'b', endAt: '2026-12-01' }).endAt, Date.parse('2026-12-01T18:30:00Z'), 'India-time dates');
});

test('admin CRUD (MASTER_ADMIN only, audited); public board: published, in window, pinned first, newest first, sanitised, cached 60 s', async () => {
  assert.equal((await env.api('POST', '/admin/board', { title: 'x', body: 'y' }, rider.token)).status, 403);
  assert.equal((await env.api('POST', '/admin/board', { title: 'x', body: 'y' })).status, 401);
  const now = Date.now();
  const a = await post({ title: 'Older update', body: 'Hello', kind: 'update', status: 'published', startAt: now - 3 * DAY });
  assert.equal(a.status, 201, JSON.stringify(a.json));
  const b = await post({ title: 'Newer tip', body: 'Check your tyres.\nEvery ride.', kind: 'safety_tip', status: 'published', startAt: now - DAY, link: '/safety', linkLabel: 'Safety features' });
  const pin = await post({ title: 'Pinned event', body: 'Ride out', kind: 'event', status: 'published', pinned: true, startAt: now - 5 * DAY });
  await post({ title: 'Draft only', body: 'secret', status: 'draft' });
  await post({ title: 'Future', body: 'later', status: 'published', startAt: now + DAY });
  await post({ title: 'Ended', body: 'gone', status: 'published', startAt: now - 9 * DAY, endAt: now - DAY });
  const xss = await post({ title: '<img src=x onerror=alert(1)>', body: '<script>alert(1)</script>', status: 'published', startAt: now - 4 * DAY });
  assert.equal(xss.status, 201, 'stored as plain text (rendered with textContent)');

  const pub = await publicBoard();
  assert.equal(pub.status, 200);
  assert.equal(pub.headers.get('cache-control'), 'public, max-age=60');
  const titles = pub.json.posts.map((p) => p.title);
  assert.deepEqual(titles, ['Pinned event', 'Newer tip', 'Older update', '<img src=x onerror=alert(1)>']);
  const tip = pub.json.posts[1];
  assert.deepEqual(Object.keys(tip).sort(), ['body', 'coupon', 'date', 'endsAt', 'id', 'image', 'kind', 'kindLabel', 'link', 'linkLabel', 'pinned', 'title']);
  assert.equal(tip.body, 'Check your tyres.\nEvery ride.');
  assert.equal(tip.link, '/safety');
  assert.ok(!JSON.stringify(pub.json).includes('boardadmin'), 'no admin identity on the website');
  assert.deepEqual((await publicBoard('?kind=safety_tip')).json.posts.map((p) => p.title), ['Newer tip']);
  assert.equal((await publicBoard('?limit=3')).json.posts.length, 3);

  // Edits: unpublish, archive, delete; audited.
  const e = await env.api('PATCH', `/admin/board/${b.json.post.id}`, { status: 'archived' }, A);
  assert.equal(e.status, 200);
  assert.ok(!(await publicBoard()).json.posts.some((p) => p.title === 'Newer tip'), 'an admin write clears the cache at once');
  const stale = await env.api('PATCH', `/admin/board/${a.json.post.id}`, { title: 'X', baseUpdatedAt: 1 }, A);
  assert.equal(stale.status, 409, 'another admin\'s newer save is not overwritten');
  assert.equal((await env.api('PATCH', `/admin/board/${a.json.post.id}`, { link: 'https://evil.example' }, A)).json.field, 'link');
  assert.equal((await env.api('DELETE', `/admin/board/${pin.json.post.id}`, null, A)).status, 200);
  const audit = await env.api('GET', '/admin/audit?action=board', null, A);
  for (const act of ['board.create', 'board.archive', 'board.delete']) assert.ok(audit.json.entries.some((x) => x.action === act), act);
  const list = await env.api('GET', '/admin/board', null, A);
  assert.ok(list.json.posts.some((p) => p.title === 'Draft only' && p.visibleNow === false));
});

test('offers show a coupon chip only while the coupon is usable and public; "Use on plans" goes to /plans?coupon=', async () => {
  const code = `BRD${crypto.randomBytes(2).toString('hex').toUpperCase()}`;
  assert.equal((await env.api('POST', '/admin/coupons', { code, discountType: 'percentage', discountValue: 20, applicablePlans: ['all'] }, A)).status, 201);
  assert.equal((await post({ title: 'Bad coupon', body: 'x', couponCode: 'NOSUCH99' })).json.field, 'couponCode');
  const p = await post({ title: 'Festive offer', body: '20% off group plans', kind: 'offer', couponCode: code.toLowerCase(), status: 'published', pinned: true });
  assert.equal(p.status, 201, JSON.stringify(p.json));
  const offer = (await publicBoard()).json.posts.find((x) => x.title === 'Festive offer');
  assert.deepEqual([offer.coupon.code, offer.coupon.text, offer.coupon.plansUrl], [code, '20% off', `/plans?coupon=${code}`]);
  await env.api('POST', `/admin/coupons/${code}/pause`, {}, A);
  await env.api('PATCH', `/admin/board/${p.json.post.id}`, { pinned: true }, A); // clears the cache
  const paused = (await publicBoard()).json.posts.find((x) => x.title === 'Festive offer');
  assert.equal(paused.coupon, null, 'a paused coupon is not shown');
  const coupons = await env.api('GET', '/admin/board/coupons', null, A);
  assert.ok(coupons.json.coupons.every((c) => ['ACTIVE', 'SCHEDULED'].includes(c.status)));
});

test('images: JPEG / PNG / WebP up to 2 MB, EXIF removed, served publicly only for a visible post', async () => {
  const up = (buf, type) => fetch(`${env.base}/admin/board/images`, { method: 'POST', headers: { Authorization: `Bearer ${A}`, 'Content-Type': type }, body: buf });
  assert.equal((await up(Buffer.from('GIF89a........'), 'image/gif')).status, 415);
  assert.equal((await up(Buffer.alloc(2 * 1024 * 1024 + 10, 1), 'image/jpeg')).status, 413);
  assert.equal((await fetch(`${env.base}/admin/board/images`, { method: 'POST', headers: { Authorization: `Bearer ${rider.token}`, 'Content-Type': 'image/jpeg' }, body: jpegWithExif() })).status, 403);
  const res = await up(jpegWithExif(), 'image/jpeg');
  assert.equal(res.status, 201);
  const { image } = await res.json();
  const draft = await post({ title: 'With image', body: 'pic', imageId: image.id, status: 'draft' });
  assert.equal(draft.status, 201);
  const url = `${origin}/api/public/board/images/${image.id}`;
  assert.equal((await fetch(url)).status, 404, 'a draft\'s image is not public');
  const adminImg = await fetch(`${env.base}/admin/board/images/${image.id}`, { headers: { Authorization: `Bearer ${A}` } });
  assert.equal(adminImg.status, 200);
  await env.api('PATCH', `/admin/board/${draft.json.post.id}`, { status: 'published' }, A);
  const img = await fetch(url);
  assert.equal(img.status, 200);
  assert.equal(img.headers.get('content-type'), 'image/jpeg');
  assert.equal(img.headers.get('x-content-type-options'), 'nosniff');
  const bytes = Buffer.from(await img.arrayBuffer());
  assert.ok(!bytes.includes(Buffer.from('GPS-SECRET')), 'EXIF removed');
  const pub = (await publicBoard()).json.posts.find((x) => x.title === 'With image');
  assert.equal(pub.image.url, `/api/public/board/images/${image.id}`);
});

test('website: home "Latest from CoRoute" (top 3) and /updates (filter by kind); text only; never in the app', async () => {
  const home = await (await fetch(origin + '/')).text();
  assert.match(home, /<section class="section section--tight bd" id="latest"[^>]*data-board data-board-limit="3" data-board-hide-empty hidden>/);
  assert.match(home, /<script src="\/assets\/board\.js\?v=[0-9a-f]+" defer><\/script>/);
  const res = await fetch(origin + '/updates');
  assert.equal(res.status, 200);
  const html = await res.text();
  assert.ok(html.includes('data-board-filters') && html.includes('data-board-limit="50"'));
  assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), '/updates has no inline script');
  assert.ok((await (await fetch(origin + '/sitemap.xml')).text()).includes('/updates</loc>'));
  const js = fs.readFileSync(path.join(__dirname, '..', 'public', 'assets', 'board.js'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(js), 'text only');
  assert.ok(js.includes("'/plans?coupon=' + encodeURIComponent(c.code)") && js.includes('navigator.clipboard'), 'Copy code and Use on plans');
  // Never pushed into the app: the board module has no push / socket / notification calls.
  const src = fs.readFileSync(path.join(__dirname, '..', 'src', 'board.js'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  assert.ok(!/notifyUsers|sendToUser|broadcast|\.push\.|fcm/i.test(src));
});
