'use strict';
/**
 * v3.59 Explore: admin configuration and real riders' routes (docs/features_355/explore_v359.md).
 *
 * 1. Explore configuration (MASTER_ADMIN, web console "Explore" page and the in-app admin screen):
 *    which sections the app shows and in what order, the categories (the six built-in ones can be renamed, hidden
 *    and re-ordered; up to 6 custom ones can be added), the featured destinations, the headline, and the rider route
 *    rules.
 *      GET  /api/public/explore                    config + active destinations + route counts (one call for the tab)
 *      GET  /api/admin/explore/config              PUT /api/admin/explore/config
 * 2. Rider routes, OPT-IN ONLY: after a ride the rider ticks "Share this route to guide other riders" and picks the
 *    destination. The phone sends a simplified route; the server trims it again (the first and last 1 km are dropped
 *    so nobody's home or office can be found), simplifies it to at most 300 points, checks that it really reaches
 *    the destination, and stores it with the rider's username, distance, riding time, the day (no time of day) and
 *    an optional note. The rider can delete it at any time; an admin can hide or delete it; deleting the account
 *    deletes every shared route.
 *      POST   /api/explore/routes                  share (auth; consent: true required)
 *      GET    /api/explore/routes/mine             my shared routes
 *      DELETE /api/explore/routes/:id              delete my route (or any, for an admin)
 *      GET    /api/explore/destinations/:id/routes live routes of a destination, newest first (auth)
 *      GET    /api/admin/explore/routes            moderation list (?status=live|hidden&destId=)
 *      PATCH  /api/admin/explore/routes/:id        { status: 'live' | 'hidden' }
 *      DELETE /api/admin/explore/routes/:id
 * Feature flag 'exploreRoutes' (Community): off = sharing refused with 403 FEATURE_OFF and no routes listed.
 */
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');

const DEST_COLL = 'destinations';
const ROUTES_COLL = 'explore_routes';
const BUILTIN_CATEGORIES = Object.freeze([
  { id: 'breakfast', label: 'Breakfast rides' }, { id: 'one_day', label: 'One-day rides' }, { id: 'weekend', label: 'Weekend trips' },
  { id: 'twisty', label: 'Twisty roads' }, { id: 'ghats', label: 'Ghats and hills' }, { id: 'night', label: 'Night rides' },
]);
const SECTION_IDS = Object.freeze(['featured', 'rider_routes', 'near_you', 'categories', 'suggest']);
const SECTION_TITLES = Object.freeze({ featured: 'Picked for you', rider_routes: 'Ridden by CoRoute riders', near_you: 'Rides near you', categories: 'Browse by type', suggest: 'Know a great ride?' });
const LIMITS = Object.freeze({
  headlineMax: 60, subtitleMax: 120, labelMax: 24, customCategoriesMax: 6, featuredMax: 12,
  noteMax: 140, pointsIn: 5000, pointsMinIn: 10, pointsOut: 300, trimM: 1000, reachKm: 3, perDestPerUser: 3,
  sharesPerDay: 10, routesPerDestination: 20, maxRouteKm: 2000,
});
const ROUTE_ID_RE = /^rt_[a-f0-9]{12}$/;
const CAT_ID_RE = /^[a-z][a-z0-9_]{1,23}$/;

class ExploreError extends Error {
  constructor(message, field, status = 400, code = 'INVALID') { super(message); this.name = 'ExploreError'; this.field = field; this.status = status; this.code = code; }
}

// ---------------------------------------------------------------- geometry
const R = 6371000;
const rad = (d) => (d * Math.PI) / 180;
function distM(a, b) {
  const dLat = rad(b[0] - a[0]), dLng = rad(b[1] - a[1]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}
function pathLengthM(pts) { let s = 0; for (let i = 1; i < pts.length; i++) s += distM(pts[i - 1], pts[i]); return s; }

/** Drops the first and last `m` metres along the path (home / office privacy). */
function trimEnds(pts, m) {
  const total = pathLengthM(pts);
  if (total <= 2 * m + 500) return [];
  let acc = 0, start = 0;
  for (let i = 1; i < pts.length; i++) { acc += distM(pts[i - 1], pts[i]); if (acc >= m) { start = i; break; } }
  acc = 0; let end = pts.length - 1;
  for (let i = pts.length - 1; i > 0; i--) { acc += distM(pts[i], pts[i - 1]); if (acc >= m) { end = i - 1; break; } }
  return end > start ? pts.slice(start, end + 1) : [];
}

/** Perpendicular distance in metres from p to the segment a-b (local flat projection, fine for short segments). */
function segDistM(p, a, b) {
  const k = Math.cos(rad((a[0] + b[0]) / 2)) * 111320, kLat = 110540;
  const ax = a[1] * k, ay = a[0] * kLat, bx = b[1] * k, by = b[0] * kLat, px = p[1] * k, py = p[0] * kLat;
  const dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
  const t = l2 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) : 0;
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}
function douglasPeucker(pts, eps) {
  if (pts.length < 3) return pts.slice();
  const keep = new Uint8Array(pts.length); keep[0] = 1; keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [s, e] = stack.pop();
    let best = -1, idx = -1;
    for (let i = s + 1; i < e; i++) { const d = segDistM(pts[i], pts[s], pts[e]); if (d > best) { best = d; idx = i; } }
    if (best > eps && idx > 0) { keep[idx] = 1; stack.push([s, idx], [idx, e]); }
  }
  return pts.filter((_, i) => keep[i]);
}
/** Simplifies to at most `max` points, raising the tolerance from 10 m. */
function simplify(pts, max) {
  let eps = 10, out = douglasPeucker(pts, eps);
  while (out.length > max && eps < 5000) { eps *= 1.6; out = douglasPeucker(pts, eps); }
  return out;
}
const round5 = (n) => Math.round(n * 1e5) / 1e5;

/** Validates, trims and simplifies a shared route. Throws ExploreError. */
function cleanRoute(points, dest) {
  if (!Array.isArray(points) || points.length < LIMITS.pointsMinIn) throw new ExploreError('The route is too short to share.', 'points');
  if (points.length > LIMITS.pointsIn) throw new ExploreError(`At most ${LIMITS.pointsIn} points.`, 'points');
  const pts = [];
  for (const p of points) {
    const lat = Array.isArray(p) ? p[0] : p && p.lat, lng = Array.isArray(p) ? p[1] : p && p.lng;
    if (typeof lat !== 'number' || typeof lng !== 'number' || !Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      throw new ExploreError('The route has an invalid point.', 'points');
    }
    if (pts.length && distM(pts[pts.length - 1], [lat, lng]) > 50000) throw new ExploreError('The route has a gap of more than 50 km.', 'points');
    pts.push([lat, lng]);
  }
  const fullKm = pathLengthM(pts) / 1000;
  if (fullKm > LIMITS.maxRouteKm) throw new ExploreError(`Routes can be at most ${LIMITS.maxRouteKm} km.`, 'points');
  // Must really reach the destination: some point within reachKm of it.
  const target = [dest.lat, dest.lng];
  if (!pts.some((p) => distM(p, target) <= LIMITS.reachKm * 1000)) {
    throw new ExploreError(`This ride does not reach ${dest.name} (it never comes within ${LIMITS.reachKm} km).`, 'destId', 422, 'NOT_REACHED');
  }
  const trimmed = trimEnds(pts, LIMITS.trimM);
  if (trimmed.length < 2) throw new ExploreError('The ride is too short to share once the first and last kilometre are left out.', 'points', 422, 'TOO_SHORT');
  const simple = simplify(trimmed, LIMITS.pointsOut).map((p) => [round5(p[0]), round5(p[1])]);
  return { points: simple, distanceKm: Math.round(fullKm * 10) / 10 };
}

// ---------------------------------------------------------------- config
function cleanText(v, max, field) {
  if (v == null) return '';
  if (typeof v !== 'string') throw new ExploreError(`${field} must be text.`, field);
  // eslint-disable-next-line no-control-regex
  const s = v.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s.length > max) throw new ExploreError(`${field} can have at most ${max} characters.`, field);
  return s;
}

function defaultConfig() {
  return {
    headline: 'Where to next?',
    subtitle: 'Places riders love, and the roads real CoRoute riders took to get there.',
    sections: SECTION_IDS.map((id) => ({ id, enabled: true, title: SECTION_TITLES[id] })),
    categories: BUILTIN_CATEGORIES.map((c) => ({ ...c, enabled: true, builtin: true })),
    featured: [],
    routes: { enabled: true, showNotes: true },
    updatedAt: 0, by: null,
  };
}

/** Cleans a full config from the admin (unknown keys ignored). Throws ExploreError. */
function cleanConfig(body, knownDestIds = null) {
  const b = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  const out = defaultConfig();
  if ('headline' in b) out.headline = cleanText(b.headline, LIMITS.headlineMax, 'headline') || out.headline;
  if ('subtitle' in b) out.subtitle = cleanText(b.subtitle, LIMITS.subtitleMax, 'subtitle');
  if (b.sections != null) {
    if (!Array.isArray(b.sections)) throw new ExploreError('sections must be a list.', 'sections');
    const seen = new Set(), list = [];
    for (const s of b.sections) {
      if (!s || !SECTION_IDS.includes(s.id) || seen.has(s.id)) continue;
      seen.add(s.id);
      list.push({ id: s.id, enabled: s.enabled !== false, title: cleanText(s.title, LIMITS.headlineMax, 'section title') || SECTION_TITLES[s.id] });
    }
    for (const id of SECTION_IDS) if (!seen.has(id)) list.push({ id, enabled: false, title: SECTION_TITLES[id] });
    out.sections = list;
  }
  if (b.categories != null) {
    if (!Array.isArray(b.categories)) throw new ExploreError('categories must be a list.', 'categories');
    const seen = new Set(), list = [];
    let custom = 0;
    for (const c of b.categories) {
      if (!c || typeof c.id !== 'string' || !CAT_ID_RE.test(c.id) || seen.has(c.id)) continue;
      const builtin = BUILTIN_CATEGORIES.some((x) => x.id === c.id);
      if (!builtin && ++custom > LIMITS.customCategoriesMax) throw new ExploreError(`At most ${LIMITS.customCategoriesMax} custom categories.`, 'categories');
      seen.add(c.id);
      const label = cleanText(c.label, LIMITS.labelMax, 'category label') || (BUILTIN_CATEGORIES.find((x) => x.id === c.id) || {}).label || '';
      if (label.length < 2) throw new ExploreError(`Category ${c.id} needs a label.`, 'categories');
      list.push({ id: c.id, label, enabled: c.enabled !== false, builtin });
    }
    // Built-in categories are never lost (destinations use them): missing ones come back hidden.
    for (const c of BUILTIN_CATEGORIES) if (!seen.has(c.id)) list.push({ ...c, enabled: false, builtin: true });
    out.categories = list;
  }
  if (b.featured != null) {
    if (!Array.isArray(b.featured)) throw new ExploreError('featured must be a list of destination ids.', 'featured');
    const ids = [...new Set(b.featured.filter((x) => typeof x === 'string' && /^ds_[a-f0-9]{12}$/.test(x)))];
    if (ids.length > LIMITS.featuredMax) throw new ExploreError(`At most ${LIMITS.featuredMax} featured destinations.`, 'featured');
    out.featured = knownDestIds ? ids.filter((id) => knownDestIds.has(id)) : ids;
  }
  if (b.routes != null) {
    const r = b.routes;
    out.routes = { enabled: r.enabled !== false, showNotes: r.showNotes !== false };
  }
  return out;
}

/** Category ids a destination may use: built-in + custom from the config. */
const allowedCategories = (cfg) => (cfg && Array.isArray(cfg.categories) ? cfg.categories.map((c) => c.id) : BUILTIN_CATEGORIES.map((c) => c.id));

function publicConfig(cfg) {
  return {
    headline: cfg.headline, subtitle: cfg.subtitle,
    sections: cfg.sections.filter((s) => s.enabled).map((s) => ({ id: s.id, title: s.title })),
    categories: cfg.categories.filter((c) => c.enabled).map((c) => ({ id: c.id, label: c.label })),
    featured: cfg.featured,
    routes: { enabled: cfg.routes.enabled, showNotes: cfg.routes.showNotes },
  };
}

function createConfigStore(soda) {
  let ready = null, cache = null;
  const ensure = () => (ready ||= soda.ensureCollection(DEST_COLL));
  return {
    clear() { cache = null; },
    async get() {
      if (cache && Date.now() - cache.at < 30000) return cache.cfg;
      await ensure();
      const r = await soda.findOne(DEST_COLL, { type: 'meta', id: 'explore_config' });
      const cfg = r && r.value && r.value.cfg ? { ...defaultConfig(), ...r.value.cfg } : defaultConfig();
      cache = { cfg, at: Date.now() };
      return cfg;
    },
    async save(cfg) {
      await ensure();
      await soda.upsertBy(DEST_COLL, { type: 'meta', id: 'explore_config' }, { type: 'meta', id: 'explore_config', cfg });
      cache = { cfg, at: Date.now() };
      return cfg;
    },
  };
}

// ---------------------------------------------------------------- routes store
const newRouteId = () => `rt_${crypto.randomBytes(6).toString('hex')}`;
const dayOf = (ms) => new Date(ms + 5.5 * 3600000).toISOString().slice(0, 10); // IST calendar day, no time of day

function createRoutesStore(soda) {
  let ready = null;
  const ensure = () => (ready ||= (async () => {
    await soda.ensureCollection(ROUTES_COLL);
    await soda.ensureIndex(ROUTES_COLL, { name: 'explore_routes_id_ux', unique: true, fields: [{ path: 'routeId' }] }).catch(() => {});
  })());
  return {
    async byDest(destId, { status = 'live', limit = LIMITS.routesPerDestination } = {}) {
      await ensure();
      const rows = (await soda.query(ROUTES_COLL, { destId, status }, { limit: 500 })).map((r) => r.value);
      return rows.sort((a, b) => b.createdAt - a.createdAt).slice(0, limit);
    },
    async byUser(userId) { await ensure(); return (await soda.query(ROUTES_COLL, { userId }, { limit: 200 })).map((r) => r.value).sort((a, b) => b.createdAt - a.createdAt); },
    async all(filter = {}) { await ensure(); return (await soda.query(ROUTES_COLL, filter, { limit: 1000 })).map((r) => r.value).sort((a, b) => b.createdAt - a.createdAt); },
    async get(id) { if (!ROUTE_ID_RE.test(String(id))) return null; await ensure(); const r = await soda.findOne(ROUTES_COLL, { routeId: id }); return r ? r.value : null; },
    async save(doc) { await ensure(); await soda.upsertBy(ROUTES_COLL, { routeId: doc.routeId }, doc); return doc; },
    async remove(id) { await ensure(); return soda.removeWhere(ROUTES_COLL, { routeId: id }); },
    async counts() {
      await ensure();
      const out = {};
      for (const r of await soda.query(ROUTES_COLL, { status: 'live' }, { limit: 5000 })) out[r.value.destId] = (out[r.value.destId] || 0) + 1;
      return out;
    },
  };
}

function routeView(r, { showNotes = true, mine = false } = {}) {
  return {
    id: r.routeId, destId: r.destId, username: r.username, points: r.points, distanceKm: r.distanceKm,
    durationMin: r.durationMin || null, day: r.day, note: showNotes ? r.note || '' : '', bike: r.bike || '',
    ...(mine ? { status: r.status, createdAt: r.createdAt } : {}),
  };
}
const adminRouteView = (r) => ({ ...routeView(r, { mine: true }), userId: r.userId, hiddenBy: r.hiddenBy || null, pointsCount: (r.points || []).length });

// ---------------------------------------------------------------- routes (HTTP)
function stateFor(repo) {
  if (!repo.__explore) repo.__explore = { cfg: createConfigStore(repo.soda), routes: createRoutesStore(repo.soda) };
  return repo.__explore;
}

/** GET /api/public/explore (before the auth gate). `destinationsOf()` -> active destinations (public view). */
function registerExplorePublicRoutes({ r, repo, wrap, visibleDestinations, flagsOf = () => null }) {
  const { cfg, routes } = stateFor(repo);
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 120, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests. Try again in a minute.', code: 'RATE_LIMITED' } });
  r.get('/public/explore', limiter, wrap(async (req, res) => {
    const c = await cfg.get();
    const f = flagsOf();
    const routesOn = c.routes.enabled && (!f || f.isOn('exploreRoutes'));
    const v = await visibleDestinations();
    const counts = routesOn ? await routes.counts().catch(() => ({})) : {};
    const pub = publicConfig(c);
    if (!routesOn) pub.sections = pub.sections.filter((s) => s.id !== 'rider_routes');
    pub.routes.enabled = routesOn;
    // A hidden category hides its destinations too (the admin's switch for a whole kind of ride).
    const cats = new Set(pub.categories.map((x) => x.id));
    const body = { config: pub, destinations: v.list.filter((d) => cats.has(d.category)), routeCounts: counts, distance: 'Worked out on your phone from your own position.' };
    const etag = `"${crypto.createHash('sha1').update(JSON.stringify(body)).digest('hex').slice(0, 16)}"`;
    res.set({ 'Cache-Control': 'public, max-age=120', ETag: etag, 'X-Content-Type-Options': 'nosniff' });
    if (req.headers['if-none-match'] === etag) return res.status(304).end();
    res.json(body);
  }));
}

/** Rider routes + admin config/moderation (behind the auth gate). */
function registerExploreRoutes({ r, repo, wrap, requireAdmin, getDestination, listDestinations, flagsOf = () => null }) {
  const { cfg, routes } = stateFor(repo);
  const shareLimit = rateLimit({ windowMs: 24 * 3600 * 1000, limit: LIMITS.sharesPerDay, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `xr:${req.user ? req.user.userId : req.ip}`, message: { error: `You can share up to ${LIMITS.sharesPerDay} routes a day.`, code: 'RATE_LIMITED' } });
  const adminLimit = rateLimit({ windowMs: 60 * 1000, limit: 60, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `xa:${req.user ? req.user.userId : req.ip}` });
  const routesOn = async () => { const c = await cfg.get(); const f = flagsOf(); return c.routes.enabled && (!f || f.isOn('exploreRoutes')); };
  const fail = (res, e) => { if (e instanceof ExploreError) return res.status(e.status).json({ error: e.message, code: e.code, field: e.field }); throw e; };
  const isAdmin = (req) => req.user && req.user.role === 'MASTER_ADMIN';
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  const audit = async (req, action, target, details) => {
    if (typeof repo.addAuditEntry !== 'function') return;
    await repo.addAuditEntry({ by: by(req), byUserId: req.user ? req.user.userId : null, action, target, details, at: Date.now() }).catch(() => {});
  };

  r.post('/explore/routes', shareLimit, wrap(async (req, res) => {
    if (!(await routesOn())) return res.status(403).json({ error: 'Route sharing is turned off right now.', code: 'FEATURE_OFF' });
    if (!(await require('./plans').forRepo(repo).featureFor(req.user.userId, 'exploreRoutes'))) return res.status(403).json({ error: 'Sharing routes is not included in your plan.', code: 'PLAN_FEATURE' });
    const b = req.body || {};
    if (b.consent !== true) return res.status(400).json({ error: 'Sharing needs your consent: tick "Share this route to guide other riders".', code: 'CONSENT_REQUIRED', field: 'consent' });
    const dest = await getDestination(String(b.destId || ''));
    if (!dest || dest.active === false) return res.status(404).json({ error: 'Destination not found.', code: 'NOT_FOUND', field: 'destId' });
    const user = await repo.findUserById(req.user.userId);
    const username = user && user.username;
    if (!username) return res.status(409).json({ error: 'Choose a username first: shared routes show your username.', code: 'USERNAME_REQUIRED' });
    let cleaned, note, durationMin = null, bike = '';
    try {
      cleaned = cleanRoute(b.points, dest);
      note = cleanText(b.note, LIMITS.noteMax, 'note');
      if (b.durationMin != null) {
        const d = Number(b.durationMin);
        if (!Number.isFinite(d) || d < 1 || d > 60 * 72) throw new ExploreError('durationMin must be 1 to 4320.', 'durationMin');
        durationMin = Math.round(d);
      }
      bike = cleanText(b.bike, 40, 'bike');
    } catch (e) { return fail(res, e); }
    const now = Date.now();
    const doc = {
      routeId: newRouteId(), destId: dest.destId, userId: req.user.userId, username, points: cleaned.points, distanceKm: cleaned.distanceKm,
      durationMin, day: dayOf(Number(b.rideEndedAt) > 0 && Number(b.rideEndedAt) <= now ? Number(b.rideEndedAt) : now), note, bike, status: 'live', createdAt: now,
    };
    // Keep at most LIMITS.perDestPerUser routes per rider per destination: the oldest goes.
    const mine = (await routes.byUser(req.user.userId)).filter((x) => x.destId === dest.destId);
    for (const old of mine.slice(LIMITS.perDestPerUser - 1)) await routes.remove(old.routeId);
    await routes.save(doc);
    res.status(201).json({ route: routeView(doc, { mine: true }), first: mine.length === 0 && (await routes.byDest(dest.destId, { limit: 2 })).length === 1 });
  }));

  r.get('/explore/routes/mine', wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store').json({ routes: (await routes.byUser(req.user.userId)).map((x) => routeView(x, { mine: true })) });
  }));

  r.delete('/explore/routes/:id', wrap(async (req, res) => {
    const doc = await routes.get(req.params.id);
    if (!doc || (doc.userId !== req.user.userId && !isAdmin(req))) return res.status(404).json({ error: 'Route not found.', code: 'NOT_FOUND' });
    await routes.remove(doc.routeId);
    if (doc.userId !== req.user.userId) await audit(req, 'explore.route.delete', doc.routeId, { destId: doc.destId });
    res.json({ ok: true });
  }));

  r.get('/explore/destinations/:id/routes', wrap(async (req, res) => {
    if (!(await routesOn())) return res.set('Cache-Control', 'no-store').json({ routes: [], enabled: false });
    const c = await cfg.get();
    const list = await routes.byDest(String(req.params.id || ''));
    res.set('Cache-Control', 'private, max-age=60').json({ routes: list.map((x) => routeView(x, { showNotes: c.routes.showNotes })), enabled: true });
  }));

  // ---- admin
  r.get('/admin/explore/config', requireAdmin, wrap(async (req, res) => {
    const c = await cfg.get();
    const f = flagsOf();
    res.set('Cache-Control', 'no-store').json({ config: c, sectionIds: SECTION_IDS, builtinCategories: BUILTIN_CATEGORIES, limits: LIMITS, routesFlag: !f || f.isOn('exploreRoutes'), counts: await routes.counts().catch(() => ({})) });
  }));
  r.put('/admin/explore/config', requireAdmin, adminLimit, wrap(async (req, res) => {
    let next;
    try {
      const dests = await listDestinations();
      next = cleanConfig(req.body, new Set(dests.map((d) => d.destId)));
      // A category still used by a destination cannot be removed (it can be hidden).
      const ids = new Set(next.categories.map((c) => c.id));
      const used = [...new Set(dests.map((d) => d.category))].filter((c) => !ids.has(c));
      if (used.length) throw new ExploreError(`Category ${used[0]} is still used by a destination: hide it instead, or move those destinations first.`, 'categories', 409, 'IN_USE');
    } catch (e) { return fail(res, e); }
    next.updatedAt = Date.now(); next.by = by(req);
    await cfg.save(next);
    await audit(req, 'explore.config.update', 'explore', { sections: next.sections.filter((s) => s.enabled).map((s) => s.id), featured: next.featured.length, categories: next.categories.length });
    res.json({ config: next });
  }));
  r.get('/admin/explore/routes', requireAdmin, wrap(async (req, res) => {
    const filter = {};
    if (['live', 'hidden'].includes(req.query.status)) filter.status = req.query.status;
    if (typeof req.query.destId === 'string' && /^ds_[a-f0-9]{12}$/.test(req.query.destId)) filter.destId = req.query.destId;
    res.set('Cache-Control', 'no-store').json({ routes: (await routes.all(filter)).map(adminRouteView) });
  }));
  r.patch('/admin/explore/routes/:id', requireAdmin, adminLimit, wrap(async (req, res) => {
    const doc = await routes.get(req.params.id);
    if (!doc) return res.status(404).json({ error: 'Route not found.', code: 'NOT_FOUND' });
    const status = req.body && req.body.status;
    if (!['live', 'hidden'].includes(status)) return res.status(400).json({ error: 'status must be live or hidden.', code: 'INVALID', field: 'status' });
    const next = await routes.save({ ...doc, status, hiddenBy: status === 'hidden' ? by(req) : null, updatedAt: Date.now() });
    await audit(req, `explore.route.${status === 'hidden' ? 'hide' : 'show'}`, doc.routeId, { destId: doc.destId });
    res.json({ route: adminRouteView(next) });
  }));
  r.delete('/admin/explore/routes/:id', requireAdmin, adminLimit, wrap(async (req, res) => {
    const doc = await routes.get(req.params.id);
    if (!doc) return res.status(404).json({ error: 'Route not found.', code: 'NOT_FOUND' });
    await routes.remove(doc.routeId);
    await audit(req, 'explore.route.delete', doc.routeId, { destId: doc.destId });
    res.json({ ok: true });
  }));
}

module.exports = {
  ROUTES_COLL, BUILTIN_CATEGORIES, SECTION_IDS, LIMITS, ExploreError,
  distM, pathLengthM, trimEnds, simplify, cleanRoute, cleanConfig, defaultConfig, publicConfig, allowedCategories,
  stateFor, registerExplorePublicRoutes, registerExploreRoutes,
};
