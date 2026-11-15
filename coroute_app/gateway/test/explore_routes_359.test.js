'use strict';
/**
 * v3.59 Explore (src/explore.js): admin configuration (sections, categories incl. custom, featured, headline),
 * the one-call public Explore endpoint, and opt-in rider routes (consent, trimming of the first and last km,
 * simplification, must reach the destination, username shown, owner/admin delete, admin hide, account deletion,
 * feature flag).
 */
process.env.NODE_ENV = 'test';
process.env.TIMELINE_TICK_MS = '3600000';
process.env.BOOTSTRAP_ADMIN_EMAILS = 'exploreadmin@coroute.test';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const X = require('../src/explore');
const { boot } = require('./_helpers');

let env; let A; let rider; let other;
before(async () => {
  env = await boot();
  A = (await env.register('Explore Admin', 'exploreadmin@coroute.test')).token;
  rider = await env.register('Route Rider', 'route.rider@coroute.test');
  other = await env.register('Other Rider', 'other.rider@coroute.test');
});
after(async () => { await env.gw.shutdown(); });

/** A ride from ~25 km south of Nandi Hills (13.3702, 77.6835) up to the top, a point every ~100 m. */
function rideTo(lat = 13.3702, lng = 77.6835, km = 25) {
  const pts = [];
  const n = km * 10;
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    pts.push([lat - (1 - t) * (km / 111) + Math.sin(t * 20) * 0.002, lng + Math.cos(t * 13) * 0.002]);
  }
  return pts;
}
async function nandiId() {
  const r = await env.api('GET', '/public/destinations');
  return r.json.destinations.find((d) => d.name === 'Nandi Hills').id;
}

test('geometry: trimming drops the first and last km; simplification caps the points', () => {
  const pts = rideTo();
  const total = X.pathLengthM(pts);
  const trimmed = X.trimEnds(pts, 1000);
  assert.ok(X.distM(pts[0], trimmed[0]) >= 500, 'start moved away from home');
  assert.ok(Math.abs(X.pathLengthM(trimmed) - (total - 2000)) < 400, 'about 2 km shorter');
  const simple = X.simplify(trimmed, 50);
  assert.ok(simple.length <= 50 && simple.length >= 2);
  assert.deepEqual(X.trimEnds(pts.slice(0, 20), 1000), [], 'too short to share');
  const dest = { name: 'Nandi Hills', lat: 13.3702, lng: 77.6835 };
  const c = X.cleanRoute(pts, dest);
  assert.ok(c.points.length <= X.LIMITS.pointsOut);
  assert.ok(c.distanceKm > 20 && c.distanceKm < 40);
  assert.throws(() => X.cleanRoute(rideTo(12.9, 77.5, 10), dest), /does not reach Nandi Hills/);
  assert.throws(() => X.cleanRoute([[1, 1]], dest), /too short/);
  assert.throws(() => X.cleanRoute([...rideTo(), [20, 77]], dest), /gap of more than 50 km/);
});

test('config rules: sections complete, built-in categories never lost, custom ones limited', () => {
  const c = X.cleanConfig({ sections: [{ id: 'near_you', enabled: true }, { id: 'nope' }], categories: [{ id: 'coffee', label: 'Coffee runs' }], featured: ['ds_aaaaaaaaaaaa', 'bad', 'ds_aaaaaaaaaaaa'] });
  assert.deepEqual(c.sections.map((s) => s.id).sort(), [...X.SECTION_IDS].sort());
  assert.equal(c.sections[0].id, 'near_you');
  assert.equal(c.sections.find((s) => s.id === 'featured').enabled, false, 'missing sections come back hidden');
  assert.ok(c.categories.some((x) => x.id === 'coffee' && !x.builtin));
  assert.ok(X.BUILTIN_CATEGORIES.every((b) => c.categories.some((x) => x.id === b.id)), 'built-ins kept');
  assert.deepEqual(c.featured, ['ds_aaaaaaaaaaaa']);
  const many = Array.from({ length: 7 }, (_, i) => ({ id: `cat_${i}`, label: `Cat ${i}` }));
  assert.throws(() => X.cleanConfig({ categories: many }), /At most 6 custom/);
  assert.throws(() => X.cleanConfig({ headline: 'x'.repeat(61) }), /at most 60/);
});

test('admin config: MASTER_ADMIN only, saved, shapes the public Explore call; custom category usable by destinations', async () => {
  assert.equal((await env.api('GET', '/admin/explore/config')).status, 401);
  assert.equal((await env.api('GET', '/admin/explore/config', null, rider.token)).status, 403);
  const id = await nandiId();
  const g = await env.api('GET', '/admin/explore/config', null, A);
  assert.equal(g.status, 200);
  assert.equal(g.json.config.sections.length, X.SECTION_IDS.length);
  const cfg = { ...g.json.config, headline: 'Ride somewhere new', featured: [id],
    sections: [{ id: 'featured', enabled: true, title: 'Owner picks' }, { id: 'near_you', enabled: true }, { id: 'rider_routes', enabled: true }, { id: 'categories', enabled: false }, { id: 'suggest', enabled: true }],
    categories: [...g.json.config.categories.map((c) => (c.id === 'night' ? { ...c, enabled: false } : c)), { id: 'coffee', label: 'Coffee runs', enabled: true }] };
  const p = await env.api('PUT', '/admin/explore/config', cfg, A);
  assert.equal(p.status, 200, JSON.stringify(p.json));
  const pub = await env.api('GET', '/public/explore');
  assert.equal(pub.status, 200);
  assert.equal(pub.json.config.headline, 'Ride somewhere new');
  assert.deepEqual(pub.json.config.sections.map((s) => s.id), ['featured', 'near_you', 'rider_routes', 'suggest'], 'hidden section left out, admin order');
  assert.equal(pub.json.config.sections[0].title, 'Owner picks');
  assert.deepEqual(pub.json.config.featured, [id]);
  assert.ok(!pub.json.config.categories.some((c) => c.id === 'night'), 'hidden category left out');
  assert.ok(pub.json.config.categories.some((c) => c.id === 'coffee'));
  assert.ok(pub.json.destinations.length >= 9);
  assert.ok(!pub.json.destinations.some((d) => d.category === 'night'), 'destinations of a hidden category are not listed');
  assert.ok(pub.headers.get('etag'));
  // a destination can now use the custom category
  const d = await env.api('POST', '/admin/destinations', { name: 'Filter Coffee Point', lat: 13.1, lng: 77.6, category: 'coffee' }, A);
  assert.equal(d.status, 201, JSON.stringify(d.json));
  // and that category cannot be removed while in use
  const rm = await env.api('PUT', '/admin/explore/config', { ...p.json.config, categories: p.json.config.categories.filter((c) => c.id !== 'coffee') }, A);
  assert.equal(rm.status, 409);
  assert.equal(rm.json.code, 'IN_USE');
});

test('rider routes: consent required, trimmed, username shown, listed for the destination; must reach it', async () => {
  const id = await nandiId();
  const pts = rideTo();
  const noConsent = await env.api('POST', '/explore/routes', { destId: id, points: pts }, rider.token);
  assert.equal(noConsent.status, 400);
  assert.equal(noConsent.json.code, 'CONSENT_REQUIRED');
  assert.equal((await env.api('POST', '/explore/routes', { destId: id, points: pts, consent: true })).status, 401);
  const wrong = await env.api('POST', '/explore/routes', { destId: id, points: rideTo(12.9, 77.5, 10), consent: true }, rider.token);
  assert.equal(wrong.status, 422);
  assert.equal(wrong.json.code, 'NOT_REACHED');
  const ok = await env.api('POST', '/explore/routes', { destId: id, points: pts, consent: true, durationMin: 55, note: 'Go before 6 am, the gate opens then.', rideEndedAt: Date.now() - 3600000 }, rider.token);
  assert.equal(ok.status, 201, JSON.stringify(ok.json));
  assert.equal(ok.json.first, true, 'first rider to guide others');
  const route = ok.json.route;
  assert.match(route.id, /^rt_[a-f0-9]{12}$/);
  assert.ok(route.username && route.username.length >= 3);
  assert.match(route.day, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(route.points.length <= 300);
  assert.ok(X.distM(route.points[0], pts[0]) > 500, 'the start (near home) is not in the shared route');
  // listed (riders only), no user ids
  assert.equal((await env.api('GET', `/explore/destinations/${id}/routes`)).status, 401);
  const list = await env.api('GET', `/explore/destinations/${id}/routes`, null, other.token);
  assert.equal(list.status, 200);
  assert.equal(list.json.routes.length, 1);
  assert.equal(list.json.routes[0].note, 'Go before 6 am, the gate opens then.');
  assert.ok(!('userId' in list.json.routes[0]));
  const pub = await env.api('GET', '/public/explore');
  assert.equal(pub.json.routeCounts[id], 1);
  // a second rider is not "first"
  const second = await env.api('POST', '/explore/routes', { destId: id, points: rideTo(13.3702, 77.6835, 30), consent: true }, other.token);
  assert.equal(second.status, 201);
  assert.equal(second.json.first, false);
});

test('rider routes: owner deletes, others cannot; admin hides and deletes; at most 3 per destination per rider', async () => {
  const id = await nandiId();
  const mine = await env.api('GET', '/explore/routes/mine', null, rider.token);
  const rid = mine.json.routes[0].id;
  assert.equal((await env.api('DELETE', `/explore/routes/${rid}`, null, other.token)).status, 404);
  // admin hide -> gone from the list, back when shown
  const hide = await env.api('PATCH', `/admin/explore/routes/${rid}`, { status: 'hidden' }, A);
  assert.equal(hide.status, 200);
  let list = await env.api('GET', `/explore/destinations/${id}/routes`, null, other.token);
  assert.ok(!list.json.routes.some((r) => r.id === rid));
  const mod = await env.api('GET', '/admin/explore/routes?status=hidden', null, A);
  assert.ok(mod.json.routes.some((r) => r.id === rid && r.userId === rider.user.userId));
  await env.api('PATCH', `/admin/explore/routes/${rid}`, { status: 'live' }, A);
  // three more shares keep only three
  for (let i = 0; i < 3; i++) assert.equal((await env.api('POST', '/explore/routes', { destId: id, points: rideTo(13.3702, 77.6835, 20 + i), consent: true }, rider.token)).status, 201);
  const after3 = await env.api('GET', '/explore/routes/mine', null, rider.token);
  assert.equal(after3.json.routes.filter((r) => r.destId === id).length, 3);
  // owner delete
  const del = await env.api('DELETE', `/explore/routes/${after3.json.routes[0].id}`, null, rider.token);
  assert.equal(del.status, 200);
  // admin delete
  const any = (await env.api('GET', '/admin/explore/routes', null, A)).json.routes[0];
  assert.equal((await env.api('DELETE', `/admin/explore/routes/${any.id}`, null, A)).status, 200);
});

test('feature flag off: no sharing, no routes, section left out', async () => {
  const id = await nandiId();
  const flags = env.gw.convoys.featureFlags;
  await flags.set('exploreRoutes', false, { reason: 'test' });
  try {
    const r = await env.api('POST', '/explore/routes', { destId: id, points: rideTo(), consent: true }, other.token);
    assert.equal(r.status, 403);
    assert.equal(r.json.code, 'FEATURE_OFF');
    const list = await env.api('GET', `/explore/destinations/${id}/routes`, null, other.token);
    assert.deepEqual(list.json.routes, []);
    const pub = await env.api('GET', '/public/explore');
    assert.ok(!pub.json.config.sections.some((s) => s.id === 'rider_routes'));
    assert.deepEqual(pub.json.routeCounts, {});
  } finally { await flags.set('exploreRoutes', true); }
});

test('account deletion removes every shared route', async () => {
  const id = await nandiId();
  const temp = await env.register('Temp Rider', 'temp.rider@coroute.test');
  assert.equal((await env.api('POST', '/explore/routes', { destId: id, points: rideTo(), consent: true }, temp.token)).status, 201);
  const user = await env.gw.repo.findUserById(temp.user.userId);
  await env.gw.repo.deleteUserCascade(user, {});
  const all = (await env.api('GET', '/admin/explore/routes', null, A)).json.routes;
  assert.ok(!all.some((r) => r.userId === temp.user.userId));
});
