'use strict';
/**
 * 3.55 marketing studio: admin-only template CRUD, schema validation, coupon binding and placeholders
 * (never an internal coupon id), uploaded images (type / size checks), duplicate / archive, audit
 * entries and the admin switch marketingStudio.
 */
process.env.NODE_ENV = 'test';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'mktadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { boot } = require('./_helpers');
const mk = require('../src/marketing_templates');

let t, admin, rider;
before(async () => {
  t = await boot();
  admin = await t.register('Mira Admin', 'mktadmin@coroute.test');
  rider = await t.register('Ravi Rider', 'mktrider@coroute.test');
});
after(async () => { await t.gw.shutdown(); });

const DAY = 86400000;
const api = (m, p, b, tok = admin.token) => t.api(m, p, b, tok);

function template(extra = {}) {
  return {
    version: 1,
    name: 'Festive offer',
    size: { preset: 'instagram_post' },
    background: { kind: 'gradient', colors: ['#0B0F14', '#123A40'], angle: 135, pattern: 'topo' },
    caption: 'Ride together for less: {discount} with code {code}. {link}',
    layers: [
      { id: 'title', type: 'text', text: 'Festive ride offer', x: 0.5, y: 0.2, w: 0.85, h: 0.15, size: 96, weight: 800, color: '#FFFFFF', shadow: { color: '#00000099', blur: 18, dx: 0, dy: 6 } },
      { id: 'coupon', type: 'coupon', x: 0.5, y: 0.6, w: 0.8, h: 0.3 },
      { id: 'badge', type: 'shape', shape: 'burst', label: 'LIMITED', x: 0.8, y: 0.1, w: 0.2, h: 0.2 },
      { id: 'logo', type: 'logo', x: 0.5, y: 0.92, w: 0.3, h: 0.06 },
      { id: 'qr', type: 'qr', x: 0.88, y: 0.88, w: 0.16, h: 0.16 },
    ],
    ...extra,
  };
}

function pngChunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  return Buffer.concat([len, Buffer.from(type, 'ascii'), data, Buffer.alloc(4)]);
}
function png() {
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(800, 0); ihdr.writeUInt32BE(600, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    pngChunk('IHDR', ihdr), pngChunk('tEXt', Buffer.from('Location\0Coorg 12.3,76.6')),
    pngChunk('IDAT', Buffer.alloc(100, 7)), pngChunk('IEND', Buffer.alloc(0)),
  ]);
}
async function upload(bytes, type = 'image/png', token = admin.token) {
  const res = await fetch(`${t.base}/admin/marketing/images`, { method: 'POST', headers: { 'Content-Type': type, Authorization: `Bearer ${token}` }, body: bytes });
  return { status: res.status, json: await res.json().catch(() => ({})) };
}

async function makeCoupon(code, extra = {}) {
  const r = await api('POST', '/admin/coupons', {
    code, name: `${code} name`, internalNotes: 'secret marketing note', discountType: 'percentage', discountValue: 40, maxDiscountCap: 60,
    maxUsageTotal: 100, applicableTiers: ['group_small'], validFrom: Date.now() - DAY, expiresAt: Date.UTC(2030, 10, 30, 12), ...extra,
  });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return r.json.coupon;
}

test('non-admins get 403 on every marketing route; no token gets 401', async () => {
  const paths = [
    ['GET', '/admin/marketing/templates'], ['POST', '/admin/marketing/templates'], ['GET', '/admin/marketing/templates/mt_000000000000000000000000'],
    ['PUT', '/admin/marketing/templates/mt_000000000000000000000000'], ['PATCH', '/admin/marketing/templates/mt_000000000000000000000000/status'],
    ['POST', '/admin/marketing/templates/mt_000000000000000000000000/duplicate'], ['DELETE', '/admin/marketing/templates/mt_000000000000000000000000'],
    ['GET', '/admin/marketing/coupons'], ['GET', '/admin/marketing/images'], ['GET', '/admin/marketing/images/rp_000000000000000000000000'],
    ['DELETE', '/admin/marketing/images/rp_000000000000000000000000'],
  ];
  for (const [m, p] of paths) {
    const r = await t.api(m, p, m === 'GET' ? undefined : template(), rider.token);
    assert.equal(r.status, 403, `${m} ${p}`);
  }
  assert.equal((await upload(png(), 'image/png', rider.token)).status, 403, 'rider upload');
  assert.equal((await t.api('GET', '/admin/marketing/templates')).status, 401);
});

test('schema validation: limits, colours, layer types, sizes', async () => {
  const bad = async (body, re) => {
    const r = await api('POST', '/admin/marketing/templates', body);
    assert.equal(r.status, 400, JSON.stringify(r.json));
    if (re) assert.match(`${r.json.path || ''} ${r.json.error}`, re);
    return r;
  };
  await bad({ ...template(), name: '' }, /name/);
  await bad({ ...template(), name: 'x'.repeat(81) }, /name/);
  await bad({ ...template(), version: 2 }, /version/);
  await bad({ ...template(), size: { preset: 'custom', width: 50, height: 1000 } }, /size.width/);
  await bad({ ...template(), size: { preset: 'custom', width: 1000, height: 9000 } }, /size.height/);
  await bad({ ...template(), size: { preset: 'poster' } }, /size.preset/);
  await bad({ ...template(), background: { kind: 'gradient', colors: ['#000000'] } }, /background.colors/);
  await bad({ ...template(), background: { kind: 'solid', color: 'red' } }, /background.color/);
  await bad({ ...template(), background: { kind: 'image', imageId: '../../etc/passwd' } }, /background.imageId/);
  await bad({ ...template(), layers: [{ id: 'a', type: 'video' }] }, /layers\[0\].type/);
  await bad({ ...template(), layers: [{ id: 'a b', type: 'text' }] }, /layers\[0\].id/);
  await bad({ ...template(), layers: [{ id: 'a', type: 'text' }, { id: 'a', type: 'text' }] }, /used twice/);
  await bad({ ...template(), layers: [{ id: 'a', type: 'text', text: 'x'.repeat(501) }] }, /text/);
  await bad({ ...template(), layers: [{ id: 'a', type: 'text', color: '#12345' }] }, /color/);
  await bad({ ...template(), layers: [{ id: 'a', type: 'text', size: 9999 }] }, /size/);
  await bad({ ...template(), layers: [{ id: 'a', type: 'text', x: 'left' }] }, /x/);
  await bad({ ...template(), layers: [{ id: 'a', type: 'image', imageId: 'rp_000000000000000000000000' }] }, /not uploaded|image/);
  const many = Array.from({ length: 41 }, (_, i) => ({ id: `t${i}`, type: 'text', text: 'Hi' }));
  const r = await bad({ ...template(), layers: many });
  assert.equal(r.json.code, 'TOO_MANY_LAYERS');
  // 40 layers is fine; unknown keys are dropped; colours are normalised.
  const ok = await api('POST', '/admin/marketing/templates', { ...template(), layers: many.slice(0, 40).map((l) => ({ ...l, color: '#ff00aa', script: '<x>' })), evil: true });
  assert.equal(ok.status, 201, JSON.stringify(ok.json));
  assert.equal(ok.json.template.layers.length, 40);
  assert.equal(ok.json.template.layers[0].color, '#FF00AA');
  assert.equal(ok.json.template.layers[0].script, undefined);
  assert.equal(ok.json.template.evil, undefined);
  assert.match(ok.json.template.id, /^mt_[a-f0-9]{24}$/);
  // Presets fix the pixel size.
  const story = await api('POST', '/admin/marketing/templates', { ...template(), size: { preset: 'instagram_story', width: 10, height: 10 } });
  assert.deepEqual(story.json.template.size, { preset: 'instagram_story', width: 1080, height: 1920 });
  // Pure helper, same rules.
  assert.throws(() => mk.cleanTemplate({ ...template(), layers: [{ id: 'q', type: 'qr', data: 'x'.repeat(301) }] }), mk.TemplateError);
});

test('coupon binding: only active coupons; placeholders filled; never internal ids or notes', async () => {
  await makeCoupon('FEST40');
  await makeCoupon('OLDOFF', { validFrom: Date.now() - 10 * DAY, expiresAt: Date.now() - DAY });
  await makeCoupon('PAUSE10', { discountType: 'fixed', discountValue: 10 });
  assert.equal((await api('POST', '/admin/coupons/PAUSE10/pause', {})).status, 200);

  const list = await api('GET', '/admin/marketing/coupons');
  assert.equal(list.status, 200);
  const codes = list.json.coupons.map((c) => c.code);
  assert.ok(codes.includes('FEST40'));
  assert.ok(!codes.includes('OLDOFF'), 'expired coupon is not offered');
  assert.ok(!codes.includes('PAUSE10'), 'paused coupon is not offered');
  const raw = JSON.stringify(list.json);
  for (const leak of ['"key"', 'usages', 'allowedUserIds', 'internalNotes', 'secret marketing note', '"_id"']) assert.ok(!raw.includes(leak), `no ${leak}`);
  const fest = list.json.coupons.find((c) => c.code === 'FEST40');
  const { plan, ...rest } = fest.placeholders;
  // 3.56: {link} / the QR open the website plans page with the code filled in.
  assert.deepEqual(rest, { code: 'FEST40', discount: '40% off', validUntil: '30 Nov 2030', name: 'FEST40 name', cap: 'up to ₹60', link: `${t.base.replace(/\/api$/, '')}/plans?coupon=FEST40` });
  assert.equal(mk.couponLink('https://coroute.devmonks.space/', 'fest40'), 'https://coroute.devmonks.space/plans?coupon=FEST40');
  assert.equal(mk.couponLink('https://coroute.devmonks.space', '<x>'), 'https://coroute.devmonks.space/plans');
  assert.match(plan, /^Small Group.* plan$/, 'the plan label comes from the plan catalog');

  for (const code of ['OLDOFF', 'PAUSE10']) {
    const r = await api('POST', '/admin/marketing/templates', template({ couponCode: code }));
    assert.equal(r.status, 400, code);
    assert.equal(r.json.code, 'COUPON_NOT_ACTIVE');
  }
  assert.equal((await api('POST', '/admin/marketing/templates', template({ couponCode: 'NOPE99' }))).json.code, 'COUPON_NOT_FOUND');

  const created = await api('POST', '/admin/marketing/templates', template({ couponCode: 'fest40' }));
  assert.equal(created.status, 201, JSON.stringify(created.json));
  const tpl = created.json.template;
  assert.equal(tpl.couponCode, 'FEST40');
  assert.equal(tpl.coupon.placeholders.discount, '40% off');
  assert.equal(tpl.coupon.warning, null);
  assert.ok(!JSON.stringify(tpl).includes('secret marketing note'));
  assert.equal(tpl.coupon.key, undefined);

  // The coupon changes: the template's view follows (nothing copied into the template).
  assert.equal((await api('PATCH', '/admin/coupons/FEST40', { discountValue: 55 })).status, 200);
  let got = await api('GET', `/admin/marketing/templates/${tpl.id}`);
  assert.equal(got.json.template.coupon.placeholders.discount, '55% off');
  assert.equal(mk.substitute('Grab {discount} with {code} till {validUntil} on {plan}. {unknown}', got.json.template.coupon.placeholders),
    `Grab 55% off with FEST40 till 30 Nov 2030 on ${plan}. {unknown}`);

  // Paused after binding: still bound (saving unchanged works) but the view warns.
  assert.equal((await api('POST', '/admin/coupons/FEST40/pause', {})).status, 200);
  got = await api('GET', `/admin/marketing/templates/${tpl.id}`);
  assert.equal(got.json.template.coupon.bindable, false);
  assert.match(got.json.template.coupon.warning, /paused/);
  const resave = await api('PUT', `/admin/marketing/templates/${tpl.id}`, { ...template({ couponCode: 'FEST40' }), name: 'Festive v2' });
  assert.equal(resave.status, 200, JSON.stringify(resave.json));
  assert.equal((await api('POST', '/admin/coupons/FEST40/resume', {})).status, 200);

  // Pure helpers.
  assert.equal(mk.discountText({ discountType: 'fixed', discountValue: 100 }), '₹100 off');
  assert.equal(mk.discountText({ discountType: 'free' }), 'Free');
  assert.equal(mk.planText(['all']), 'all plans');
  assert.equal(mk.planText(['group_small', 'group_large']), 'Small Group & Large Group plans');
  assert.equal(mk.formatDate(Date.UTC(2026, 11, 31, 20, 0)), '1 Jan 2027', 'India time');
  const view = mk.couponView({ code: 'X1', key: 'INTERNAL-KEY', status: 'EXPIRED', expiresAt: 1, usages: [{ userId: 'u' }] });
  assert.equal(view.key, undefined);
  assert.equal(view.usages, undefined);
  assert.match(view.warning, /expired/);
});

test('images: type and size checks, references, delete only when unused', async () => {
  assert.equal((await upload(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>'), 'image/svg+xml')).status, 415);
  assert.equal((await upload(Buffer.from('GIF89a......'), 'image/gif')).status, 415);
  const json = await fetch(`${t.base}/admin/marketing/images`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${admin.token}` }, body: '{}' });
  assert.equal(json.status, 415);
  const big = Buffer.concat([png(), Buffer.alloc(2 * 1024 * 1024 + 10)]);
  assert.equal((await upload(big)).status, 413);

  const up = await upload(png());
  assert.equal(up.status, 201, JSON.stringify(up.json));
  const id = up.json.image.id;
  assert.match(id, /^rp_[a-f0-9]{24}$/);
  assert.equal(up.json.image.width, 800);

  const bytes = await fetch(`${t.base}/admin/marketing/images/${id}`, { headers: { Authorization: `Bearer ${admin.token}` } });
  assert.equal(bytes.status, 200);
  assert.equal(bytes.headers.get('content-type'), 'image/png');
  const body = Buffer.from(await bytes.arrayBuffer());
  assert.equal(body.indexOf(Buffer.from('Coorg')), -1, 'text metadata stripped');
  assert.equal((await t.api('GET', `/admin/marketing/images/${id}`, undefined, rider.token)).status, 403);

  const withImg = await api('POST', '/admin/marketing/templates', template({
    background: { kind: 'image', imageId: id },
    layers: [{ id: 'img', type: 'image', imageId: id, x: 0.5, y: 0.5, w: 0.5, h: 0.5 }],
  }));
  assert.equal(withImg.status, 201, JSON.stringify(withImg.json));
  const inUse = await api('DELETE', `/admin/marketing/images/${id}`);
  assert.equal(inUse.status, 409);
  assert.equal(inUse.json.code, 'IMAGE_IN_USE');
  assert.equal((await api('DELETE', `/admin/marketing/templates/${withImg.json.template.id}`)).status, 200);
  assert.equal((await api('DELETE', `/admin/marketing/images/${id}`)).status, 200);
  assert.equal((await api('GET', `/admin/marketing/images/${id}`)).status, 404);
});

test('duplicate, archive, conflict check, list filter and audit entries', async () => {
  const a = (await api('POST', '/admin/marketing/templates', template({ name: 'Group ride plan discount' }))).json.template;
  const dup = await api('POST', `/admin/marketing/templates/${a.id}/duplicate`, {});
  assert.equal(dup.status, 201);
  assert.notEqual(dup.json.template.id, a.id);
  assert.equal(dup.json.template.name, 'Group ride plan discount (copy)');
  assert.equal(dup.json.template.layers.length, a.layers.length);

  const arch = await api('PATCH', `/admin/marketing/templates/${a.id}/status`, { status: 'archived' });
  assert.equal(arch.status, 200);
  assert.equal(arch.json.template.status, 'archived');
  assert.equal((await api('PATCH', `/admin/marketing/templates/${a.id}/status`, { status: 'gone' })).status, 400);
  const archived = await api('GET', '/admin/marketing/templates?status=archived');
  assert.ok(archived.json.templates.some((x) => x.id === a.id));
  const active = await api('GET', '/admin/marketing/templates?status=active');
  assert.ok(!active.json.templates.some((x) => x.id === a.id));
  assert.equal(active.json.limits.maxLayers, 40);

  const stale = await api('PUT', `/admin/marketing/templates/${a.id}`, { ...template(), baseUpdatedAt: 1 });
  assert.equal(stale.status, 409);
  assert.equal((await api('GET', '/admin/marketing/templates/mt_ffffffffffffffffffffffff')).status, 404);
  assert.equal((await api('GET', '/admin/marketing/templates/not-an-id')).status, 404);

  const auditRows = await t.gw.repo.listAuditEntries(200);
  const actions = new Set(auditRows.map((x) => x.action));
  for (const act of ['marketing.template.create', 'marketing.template.duplicate', 'marketing.template.archive', 'marketing.image.upload', 'marketing.template.delete']) {
    assert.ok(actions.has(act), act);
  }
});

test('admin switch marketingStudio off: 403 FEATURE_OFF, back on works', async () => {
  const off = await api('PUT', '/admin/features/marketingStudio', { enabled: false, reason: 'Pause campaigns' });
  assert.equal(off.status, 200, JSON.stringify(off.json));
  const r = await api('GET', '/admin/marketing/templates');
  assert.equal(r.status, 403);
  assert.equal(r.json.code, 'FEATURE_OFF');
  // A rider still gets the plain admin refusal.
  assert.equal((await t.api('GET', '/admin/marketing/templates', undefined, rider.token)).json.code, undefined);
  assert.equal((await api('PUT', '/admin/features/marketingStudio', { enabled: true })).status, 200);
  assert.equal((await api('GET', '/admin/marketing/templates')).status, 200);
});
