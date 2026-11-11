'use strict';
/**
 * 3.56 Operator / club console: HTTP API, pages, pushes, audit (docs/features_355/operators.md).
 * Rules and storage: src/operators.js.
 *
 *   attachOperators({ app, repo, gate, convoys, hub, tracks, featureFlags, site, pageVars, notFoundPage, mailerOf, logger })
 *   once in app.js, BEFORE the website's static files (the console assets get their own headers).
 *
 * Pages
 *   /operators/apply     website page (site shell): a signed-in rider applies
 *   /clubs               website page: my clubs, club invites (accept / decline), leave; /clubs/join/<code>
 *   /rides/<slug>        website page: public sign-up page of an operator ride
 *   /operator            the operator console (single page, strict CSP of its own, noindex)
 *
 * API (all JSON under /api; switch `operators` gates everything but the admin review)
 *   applicant  GET /operators/application, POST /operators/apply
 *   admin      GET /admin/operators[?status&type&q], GET /admin/operators/summary, GET /admin/operators/:id,
 *              POST /admin/operators/:id/{approve|reject|suspend|reinstate}, PUT /admin/operators/:id/limits,
 *              GET/PUT /admin/operators/templates
 *   console    GET /operator/me, GET /operator/:id, roster, invites, invite link, co-organisers, rides,
 *              sign-ups, start / publish / end, roles, live dashboard, SOS contacts, attendance, reports
 *              (+ CSV), broadcasts — see the doc for the full list
 *   members    GET /clubs, POST /clubs/invites/:inviteId/{accept|decline}, POST /clubs/join,
 *              POST /clubs/:operatorId/leave, GET /clubs/:operatorId/broadcasts
 *   public     GET /public/rides/:slug, GET /public/clubs/:code; POST|DELETE /rides/:slug/signup, GET /rides/:slug/me
 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const OP = require('./operators');
const CR = require('./crews');
const U = require('./usernames');
const F = require('./friends');
const RI = require('./crew_ride_invites');
const { requireAuth, requireAdmin } = require('./auth');
const { forbiddenTermIn, policyRefusal } = require('./policy_terms');
const { analyseTrack } = require('./tracks');

const FEATURE_OFF = { error: 'This feature is turned off for now.', code: 'FEATURE_OFF', feature: 'operators' };
const NOT_FOUND = { error: 'Operator not found.', code: 'OPERATOR_NOT_FOUND' };
const RIDE_NOT_FOUND = { error: 'Ride not found.', code: 'RIDE_NOT_FOUND' };
const ACTIVE = ['PLANNING', 'STARTED', 'PAUSED'];
const LIVE = ['STARTED', 'PAUSED'];
const HOUR = 3600000;
const DAY = 24 * HOUR;
const IST = 330 * 60000;

/** Strict CSP of the console: no inline code, only this site and the OpenStreetMap tiles of the live map. */
const CONSOLE_CSP = [
  "default-src 'none'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data: blob: https://tile.openstreetmap.org https://*.tile.openstreetmap.org",
  "font-src 'self'",
  "connect-src 'self'",
  "base-uri 'none'",
  "form-action 'none'",
  "frame-ancestors 'none'",
  "object-src 'none'",
  "manifest-src 'none'",
  "worker-src 'none'",
].join('; ');
const ASSET_TYPES = { '.js': 'application/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };
/** Website pages of this feature (rendered through the site shell: src/pages.js SPECIAL_PAGES). */
const SITE_FILES = Object.freeze(['operators_apply.html', 'clubs.html', 'ride_public.html']);

const firstName = (name) => String(name || '').trim().split(/\s+/)[0].slice(0, 20);
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function consoleHeaders(res) {
  res.set({
    'Content-Security-Policy': CONSOLE_CSP,
    'X-Robots-Tag': 'noindex, nofollow, noarchive',
    'Referrer-Policy': 'no-referrer',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()',
  });
}

/** Headers of the three website pages: strict CSP (no inline script), no referrer, no-store. */
function sitePageHeaders(res, { index = false } = {}) {
  res.set({
    'Content-Security-Policy': require('./web_shop').shopCsp(),
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'X-Robots-Tag': index ? 'index, follow' : 'noindex, nofollow',
    'Cache-Control': 'no-store',
  });
}

/** CSV cell (formula injection guarded). */
function csvCell(v) {
  let s = v === null || v === undefined ? '' : String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}
const istDate = (ms) => (ms ? new Date(ms + IST).toISOString().slice(0, 16).replace('T', ' ') : '');

function attachOperators({ app, repo, gate, convoys, hub = null, tracks = null, featureFlags = null, site = null, pageVars = () => ({}), notFoundPage = null, mailerOf = () => null, logger = console, publicDir = path.join(__dirname, '..', 'public') }) {
  const soda = repo.soda;
  const isOn = () => !featureFlags || featureFlags.isOn('operators');
  const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
  const perUser = (req) => req.user?.userId || req.ip;
  const limiter = (windowMs, limit, message) => rateLimit({ windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: perUser, message: { error: message, code: 'RATE_LIMITED' } });
  const readLimiter = limiter(60 * 1000, 240, 'Too many requests. Wait a minute.');
  const writeLimiter = limiter(60 * 1000, 60, 'Too many changes. Wait a minute.');
  const applyLimiter = limiter(DAY, 5, 'Too many applications today. Try again tomorrow.');
  const inviteLimiter = limiter(DAY, 300, 'Too many invites today. Try again tomorrow.');
  const signupLimiter = limiter(60 * 60 * 1000, 30, 'Too many sign-ups. Try again later.');
  const publicLimiter = rateLimit({ windowMs: 60 * 1000, limit: 120, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  const pushOf = () => (hub && hub.push) || (convoys && convoys.push) || null;
  const socket = (userId, payload) => { try { if (hub) hub.sendToUser(userId, payload); } catch { /* best effort */ } };
  const originOf = (req) => config.publicOrigin || `${req.protocol}://${req.get('host')}`;
  const feature = (req, res, next) => (isOn() ? next() : res.status(403).set('Cache-Control', 'no-store').json(FEATURE_OFF));
  const fail = (res, e) => {
    if (e instanceof OP.OperatorError) {
      const body = { error: e.message, code: e.code };
      if (e.fields) body.fields = e.fields;
      if (e.limit !== undefined) body.limit = e.limit;
      return res.status(e.status).json(body);
    }
    if (e instanceof CR.CrewError) return res.status(e.status).json({ error: e.message, code: e.code });
    if (e && e.name === 'ConvoyError') return res.status(e.status || 400).json({ error: e.message, code: e.reason || 'CONVOY_ERROR' });
    throw e;
  };
  const audit = (req, action, target, details = {}) => {
    const u = req.user || {};
    return Promise.resolve(repo.addAuditEntry({ by: u.email || u.name || u.userId || null, byUserId: u.userId || null, action, target, details }))
      .catch((e) => logger.warn?.(`[operators] audit failed: ${e.message}`));
  };

  const userById = async (id) => {
    if (!id) return null;
    const u = await repo.findUserById(id).catch(() => null);
    if (!u || u.username) return u;
    return U.ensureUsername(repo, u).catch(() => u);
  };
  const usersByIds = async (ids) => {
    const map = new Map();
    for (const id of [...new Set(ids.filter(Boolean))]) {
      const u = await userById(id);
      if (u) map.set(id, u);
    }
    return map;
  };
  const card = (u) => ({ username: (u && u.username) || '', displayName: firstName(u && u.name) });
  const byUsername = async (raw) => {
    const name = typeof raw === 'string' ? raw.trim().replace(/^@/, '') : '';
    if (!name) return null;
    const u = await U.findUserByUsername(repo, name).catch(() => null);
    return u && u.status !== 'BLOCKED' ? u : null;
  };

  // ---- convoy helpers ----
  const metaOf = async (groupId) => {
    if (!groupId) return null;
    const live = convoys.rooms && convoys.rooms.get(groupId);
    if (live) return live.meta;
    return repo.getConvoyMeta(groupId).catch(() => null);
  };
  const convoyActive = async (groupId) => {
    const m = await metaOf(groupId);
    return !!m && ACTIVE.includes(m.tripStatus);
  };
  /** A LIVE ride whose convoy ended reads (and is stored) ENDED. */
  const syncRide = async (ride) => {
    if (ride.status !== OP.RIDE_STATUS.LIVE) return ride;
    const m = await metaOf(ride.groupId);
    if (m && ACTIVE.includes(m.tripStatus)) return ride;
    return OP.saveRide(soda, { ...ride, status: OP.RIDE_STATUS.ENDED, endedAt: (m && m.endedAtEpochMs) || Date.now() });
  };

  // ---- e-mail (only when SMTP is configured) ----
  const mail = (to, subject, text) => {
    const m = mailerOf && mailerOf();
    if (!m || !m.enabled || !to) return;
    Promise.resolve(m.send({ to, subject, text })).catch(() => {});
  };
  const reviewEmail = () => String(process.env.OPERATOR_REVIEW_EMAIL || config.supportEmail || '').trim();

  // ---- account erase ----
  if (!repo.__operatorsCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__operatorsCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      if (user && user.userId) await OP.forgetOperatorUser(soda, user.userId).catch(() => {});
      return cascade(user, opts);
    };
  }

  // ---- the assigned sweeper takes the role when joining the ride ----
  if (convoys && typeof convoys.on === 'function') {
    convoys.on('event', (gid, ev) => {
      if (!ev || ev.type !== 'RIDER_UPDATE' || !ev.joined || !ev.rider) return;
      const room = convoys.rooms.get(gid);
      if (!room || !room.meta.operatorRideId) return;
      OP.getRide(soda, room.meta.operatorRideId).then((ride) => {
        if (!ride || ride.sweeperUserId !== ev.rider.userId) return null;
        const owner = room.meta.tripOwnerUserId || room.meta.createdByUserId;
        return convoys.setRole(gid, { userId: owner, role: 'RIDER' }, ev.rider.userId, 'SWEEPER');
      }).catch(() => {});
    });
  }

  // ======================================================================== pages
  const pages = express.Router();
  const sitePage = (file, vars = {}) => (req, res) => {
    if (!isOn() || !site || !site.has(file)) return notFoundPage ? notFoundPage(req, res) : res.status(404).end();
    sitePageHeaders(res);
    res.type('html').send(site.render(file, { ...pageVars(req), ...vars }));
  };
  pages.get(['/operators/apply', '/operators/apply.html'], sitePage('operators_apply.html'));
  pages.get(['/clubs', '/clubs.html'], sitePage('clubs.html'));
  pages.get('/clubs/join/:code', (req, res, next) => {
    const code = String(req.params.code || '');
    if (!OP.isInviteCode(code)) return notFoundPage ? notFoundPage(req, res) : next();
    res.set('Cache-Control', 'no-store').redirect(302, `/clubs?code=${encodeURIComponent(code)}`);
  });
  pages.get('/rides/:slug', wrap(async (req, res) => {
    const slug = String(req.params.slug || '');
    const ride = isOn() && OP.isSlug(slug) ? await OP.rideBySlug(soda, slug) : null;
    const op = ride && ride.publicSignup ? await OP.getOperator(soda, ride.operatorId) : null;
    if (!ride || !op || !site || !site.has('ride_public.html') || ride.status === OP.RIDE_STATUS.CANCELLED) {
      return notFoundPage ? notFoundPage(req, res) : res.status(404).end();
    }
    sitePageHeaders(res, { index: true });
    res.type('html').send(site.render('ride_public.html', {
      ...pageVars(req), __SLUG__: esc(slug), __RIDE_TITLE__: esc(ride.title), __OPERATOR_NAME__: esc(op.name),
      __RIDE_DESC__: esc(`${ride.title} by ${op.name}${ride.meetName ? `, from ${ride.meetName}` : ''}${ride.destinationName ? ` to ${ride.destinationName}` : ''}. Sign up on CoRoute.`),
    }));
  }));

  // The console: /operator + its assets (read once, versioned like the web admin).
  const dir = path.join(publicDir, 'operator');
  if (fs.existsSync(path.join(dir, 'index.html'))) {
    const assets = new Map();
    for (const f of fs.readdirSync(dir)) {
      const ext = path.extname(f);
      if (!ASSET_TYPES[ext] || !/^[a-z0-9_-]+\.[a-z]+$/.test(f)) continue;
      const buf = fs.readFileSync(path.join(dir, f));
      assets.set(f, { buf, type: ASSET_TYPES[ext], hash: crypto.createHash('sha256').update(buf).digest('hex').slice(0, 10) });
    }
    const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8')
      .replace(/(\/operator\/)([a-z0-9_-]+\.[a-z]+)(?=")/g, (m, p, f) => (assets.has(f) ? `${p}${f}?v=${assets.get(f).hash}` : m));
    pages.get(['/operator', '/operator/'], (req, res) => {
      consoleHeaders(res);
      res.set('Cache-Control', 'no-store').type('html').send(html);
    });
    pages.get('/operator/:file', (req, res) => {
      const a = assets.get(req.params.file);
      consoleHeaders(res);
      if (!a) return res.status(404).set('Cache-Control', 'no-store').type('text/plain').send('Not found');
      res.set({ 'Content-Type': a.type, 'Cache-Control': req.query.v === a.hash ? 'public, max-age=604800, immutable' : 'no-cache' }).send(a.buf);
    });
    pages.all('/operator/*', (req, res) => { consoleHeaders(res); res.status(404).set('Cache-Control', 'no-store').type('text/plain').send('Not found'); });
  }
  app.use(pages);

  // ======================================================================== API
  const r = express.Router();
  r.use(['/operators', '/operator', '/admin/operators', '/clubs', '/public/rides', '/public/clubs', '/rides'], (req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });

  // ---- public (no sign-in) ----
  const publicRideView = async (ride, op) => {
    const counts = OP.signupCounts(ride);
    const seatsLeft = Math.max(0, ride.maxRiders - 1 - counts.approved - (ride.requireApproval ? 0 : counts.pending));
    return {
      slug: ride.slug, title: ride.title, startsAt: ride.startsAt, meetName: ride.meetName, destinationName: ride.destinationName, notes: ride.notes,
      maxRiders: ride.maxRiders, seatsLeft, requireApproval: !!ride.requireApproval, status: ride.status,
      signupOpen: [OP.RIDE_STATUS.SCHEDULED, OP.RIDE_STATUS.LIVE].includes(ride.status) && seatsLeft > 0 && OP.effectiveStatus(op) === OP.STATUS.APPROVED,
      operator: { name: op.name, type: op.type, typeLabel: OP.TYPES[op.type], city: op.city, website: op.website || '' },
    };
  };
  const publicRide = async (slug) => {
    const ride = OP.isSlug(slug) ? await OP.rideBySlug(soda, slug) : null;
    if (!ride || !ride.publicSignup || ride.status === OP.RIDE_STATUS.CANCELLED) return null;
    const op = await OP.getOperator(soda, ride.operatorId);
    if (!op || ![OP.STATUS.APPROVED, OP.STATUS.SUSPENDED].includes(op.status)) return null;
    return { ride: await syncRide(ride), op };
  };
  r.get('/public/rides/:slug', feature, publicLimiter, wrap(async (req, res) => {
    const found = await publicRide(String(req.params.slug || ''));
    if (!found) return res.status(404).json(RIDE_NOT_FOUND);
    res.json({ ride: await publicRideView(found.ride, found.op) });
  }));
  r.get('/public/clubs/:code', feature, publicLimiter, wrap(async (req, res) => {
    const op = await OP.operatorByInviteCode(soda, String(req.params.code || ''));
    if (!op || OP.effectiveStatus(op) !== OP.STATUS.APPROVED) return res.status(404).json({ error: 'This club link does not work any more.', code: 'LINK_GONE' });
    const crew = op.crewId ? await CR.getCrew(soda, op.crewId) : null;
    res.json({ club: { name: op.name, type: op.type, typeLabel: OP.TYPES[op.type], city: op.city, members: (crew && crew.memberCount) || 0 } });
  }));

  // Everything below needs a signed-in account.
  const authed = requireAuth(gate);

  // ---- applicant ----
  const applicationView = (op) => op && ({
    operatorId: op.operatorId, type: op.type, typeLabel: OP.TYPES[op.type], name: op.name, city: op.city, contact: op.contact,
    website: op.website, expectedRiders: op.expectedRiders, description: op.description, status: OP.effectiveStatus(op),
    reason: op.reason || '', createdAt: op.createdAt, decidedAt: op.decidedAt || 0, validUntil: op.validUntil || 0,
  });
  r.get('/operators/application', authed, feature, readLimiter, wrap(async (req, res) => {
    const op = await OP.operatorOfOwner(soda, req.user.userId);
    const co = (await OP.operatorsFor(soda, req.user.userId)).filter((o) => o.ownerId !== req.user.userId);
    res.json({ application: applicationView(op), types: OP.TYPES, coOrganiserOf: co.map((o) => ({ operatorId: o.operatorId, name: o.name })) });
  }));
  r.post('/operators/apply', authed, feature, applyLimiter, wrap(async (req, res) => {
    let op;
    try { op = await OP.apply(soda, req.user.userId, req.body || {}); } catch (e) { return fail(res, e); }
    await audit(req, 'operator.applied', op.operatorId, { type: op.type, name: op.name, city: op.city });
    const owner = await userById(req.user.userId);
    mail(reviewEmail(), `New operator application: ${op.name}`,
      `${OP.TYPES[op.type]} "${op.name}" (${op.city}) applied for the CoRoute operator console.\nApplicant: @${(owner && owner.username) || '-'}\nExpected riders: ${op.expectedRiders}\n\nReview it in the web admin: ${config.publicOrigin || ''}/admin#/operators/${op.operatorId}\n`);
    res.status(201).json({ application: applicationView(op) });
  }));

  // ---- admin review (works even with the switch off) ----
  const usage = async (op) => {
    const ros = op.crewId ? await OP.roster(soda, op) : { members: [], invites: [] };
    const rides = await OP.ridesOf(soda, op.operatorId);
    const month = OP.istMonth(Date.now());
    let live = 0;
    for (const x of rides) if (x.status === OP.RIDE_STATUS.LIVE && await convoyActive(x.groupId)) live++;
    return {
      members: ros.members.length, pendingInvites: ros.invites.length,
      ridesThisMonth: rides.filter((x) => x.month === month && x.status !== OP.RIDE_STATUS.CANCELLED).length,
      liveRides: live, totalRides: rides.length, coOrganisers: (op.coOrganisers || []).length,
    };
  };
  const adminRow = (op, owner) => ({
    operatorId: op.operatorId, name: op.name, type: op.type, typeLabel: OP.TYPES[op.type], city: op.city, status: OP.effectiveStatus(op),
    expectedRiders: op.expectedRiders, createdAt: op.createdAt, decidedAt: op.decidedAt || 0, validUntil: op.validUntil || 0,
    owner: owner ? { username: owner.username || '', name: owner.name || '' } : null, limits: op.limits || null,
  });
  r.get('/admin/operators/summary', authed, requireAdmin, wrap(async (req, res) => {
    const all = await OP.listOperators(soda, {});
    res.json({ pending: all.filter((o) => o.status === OP.STATUS.PENDING).length, total: all.length, featureOn: isOn() });
  }));
  r.get('/admin/operators/templates', authed, requireAdmin, wrap(async (req, res) => {
    const t = await OP.getTemplates(soda);
    res.json({ ...t, types: OP.TYPES, features: OP.FEATURES, bounds: OP.limitBounds(), defaults: OP.DEFAULT_TEMPLATES });
  }));
  r.put('/admin/operators/templates', authed, requireAdmin, wrap(async (req, res) => {
    const templates = await OP.saveTemplates(soda, (req.body && req.body.templates) || {}, req.user.email || req.user.userId);
    await audit(req, 'operator.templates', 'templates', { templates });
    res.json({ templates });
  }));
  r.get('/admin/operators', authed, requireAdmin, wrap(async (req, res) => {
    const status = String(req.query.status || '').toUpperCase();
    const type = String(req.query.type || '').toUpperCase();
    const all = await OP.listOperators(soda, {});
    const counts = { PENDING: 0, APPROVED: 0, REJECTED: 0, SUSPENDED: 0, EXPIRED: 0 };
    for (const o of all) counts[OP.effectiveStatus(o)] = (counts[OP.effectiveStatus(o)] || 0) + 1;
    let rows = await OP.listOperators(soda, { type, q: req.query.q });
    if (status) rows = rows.filter((o) => OP.effectiveStatus(o) === status);
    const owners = await usersByIds(rows.map((o) => o.ownerId));
    res.json({ operators: rows.map((o) => adminRow(o, owners.get(o.ownerId))), counts, types: OP.TYPES, featureOn: isOn() });
  }));
  r.get('/admin/operators/:operatorId', authed, requireAdmin, wrap(async (req, res) => {
    const op = await OP.getOperator(soda, String(req.params.operatorId));
    if (!op) return res.status(404).json(NOT_FOUND);
    const owner = await userById(op.ownerId);
    const co = await usersByIds(op.coOrganisers || []);
    const tpl = (await OP.getTemplates(soda)).templates[op.type];
    res.json({
      operator: {
        ...adminRow(op, owner), contact: op.contact, website: op.website, description: op.description, reason: op.reason || '',
        features: op.features || null, validFrom: op.validFrom || 0, history: op.history || [],
        ownerEmail: (owner && owner.email) || '', coOrganisers: [...co.values()].map(card),
      },
      usage: op.status === OP.STATUS.PENDING ? null : await usage(op),
      template: tpl, features: OP.FEATURES, bounds: OP.limitBounds(),
    });
  }));
  const decision = (action) => wrap(async (req, res) => {
    const op = await OP.getOperator(soda, String(req.params.operatorId));
    if (!op) return res.status(404).json(NOT_FOUND);
    const b = req.body || {};
    let next;
    try {
      next = await OP.decide(soda, op, action, { by: req.user.email || req.user.userId, reason: b.reason, limits: b.limits, features: b.features, validUntil: b.validUntil, validityDays: b.validityDays });
    } catch (e) { return fail(res, e); }
    await audit(req, `operator.${action.toLowerCase()}`, op.operatorId, {
      name: op.name, from: op.status, to: next.status, reason: next.reason || OP.clean(b.reason, 300) || '',
      ...(['APPROVE', 'LIMITS'].includes(action) ? { limits: next.limits, features: next.features, validUntil: next.validUntil } : {}),
    });
    const owner = await userById(op.ownerId);
    if (['APPROVE', 'REJECT', 'SUSPEND', 'REINSTATE'].includes(action)) {
      const words = { APPROVE: 'approved', REJECT: 'not approved', SUSPEND: 'suspended', REINSTATE: 'reinstated' }[action];
      mail(op.contact && op.contact.email, `Your CoRoute operator account: ${words}`,
        `Hello${owner && owner.name ? ` ${firstName(owner.name)}` : ''},\n\nYour CoRoute operator account "${op.name}" was ${words}.${next.reason ? `\nReason: ${next.reason}` : ''}\n${action === 'APPROVE' || action === 'REINSTATE' ? `\nOpen the operator console: ${config.publicOrigin || ''}/operator\n` : ''}`);
      socket(op.ownerId, { type: 'OPERATOR_STATUS', operatorId: op.operatorId, status: next.status });
    }
    res.json({ operator: { ...adminRow(next, owner), features: next.features, reason: next.reason || '', history: next.history || [] } });
  });
  r.post('/admin/operators/:operatorId/approve', authed, requireAdmin, writeLimiter, decision('APPROVE'));
  r.post('/admin/operators/:operatorId/reject', authed, requireAdmin, writeLimiter, decision('REJECT'));
  r.post('/admin/operators/:operatorId/suspend', authed, requireAdmin, writeLimiter, decision('SUSPEND'));
  r.post('/admin/operators/:operatorId/reinstate', authed, requireAdmin, writeLimiter, decision('REINSTATE'));
  r.put('/admin/operators/:operatorId/limits', authed, requireAdmin, writeLimiter, decision('LIMITS'));

  // ---- console access ----
  /** Loads req.op / req.opRole. Suspended: 403 for everything; expired: read only. */
  const access = ({ write = false, owner = false } = {}) => wrap(async (req, res, next) => {
    const op = await OP.getOperator(soda, String(req.params.operatorId || ''));
    const role = OP.roleIn(op, req.user.userId);
    if (!op || !role || ![OP.STATUS.APPROVED, OP.STATUS.SUSPENDED].includes(op.status)) return res.status(404).json(NOT_FOUND);
    const st = OP.effectiveStatus(op);
    if (st === OP.STATUS.SUSPENDED) return res.status(403).json({ error: 'This operator account is suspended.', code: 'OPERATOR_SUSPENDED', reason: op.reason || '' });
    if (write && st === 'EXPIRED') return res.status(403).json({ error: 'This operator account has expired. Contact CoRoute to extend it.', code: 'OPERATOR_EXPIRED' });
    if (owner && role !== 'OWNER') return res.status(403).json({ error: 'Only the account owner can do this.', code: 'OWNER_ONLY' });
    req.op = op; req.opRole = role;
    next();
  });
  const needFeature = (name) => (req, res, next) => (req.op.features && req.op.features[name]
    ? next()
    : res.status(403).json({ error: `${OP.FEATURES[name]} is not part of your plan.`, code: 'NOT_IN_PLAN', feature: name }));
  const C_ = '/operator/:operatorId';

  const consoleView = async (op, role, req) => ({
    operatorId: op.operatorId, name: op.name, type: op.type, typeLabel: OP.TYPES[op.type], city: op.city, website: op.website || '',
    status: OP.effectiveStatus(op), reason: op.reason || '', limits: op.limits, features: op.features, featureLabels: OP.FEATURES,
    validFrom: op.validFrom || 0, validUntil: op.validUntil || 0, role, crewId: op.crewId || null,
    contact: role === 'OWNER' ? op.contact : undefined,
    inviteLink: op.inviteLinkOn && op.inviteCode ? `${originOf(req)}/clubs/join/${op.inviteCode}` : null,
    usage: await usage(op),
  });
  r.get('/operator/me', authed, feature, readLimiter, wrap(async (req, res) => {
    const list = await OP.operatorsFor(soda, req.user.userId);
    const own = await OP.operatorOfOwner(soda, req.user.userId);
    const me = await userById(req.user.userId);
    res.json({
      user: { ...card(me), name: (me && me.name) || '' },
      operators: list.map((o) => ({ operatorId: o.operatorId, name: o.name, type: o.type, typeLabel: OP.TYPES[o.type], status: OP.effectiveStatus(o), reason: o.reason || '', role: OP.roleIn(o, req.user.userId) })),
      application: own && ![OP.STATUS.APPROVED, OP.STATUS.SUSPENDED].includes(own.status) ? applicationView(own) : null,
    });
  }));
  r.get(C_, authed, feature, readLimiter, access(), wrap(async (req, res) => {
    res.json({ operator: await consoleView(req.op, req.opRole, req) });
  }));

  // ---- roster ----
  r.get(`${C_}/roster`, authed, feature, readLimiter, access(), wrap(async (req, res) => {
    const op = req.op;
    const { members, invites } = await OP.roster(soda, op);
    const users = await usersByIds([...members.map((m) => m.userId), ...invites.map((i) => i.userId), ...invites.map((i) => i.invitedBy)]);
    const co = new Set(op.coOrganisers || []);
    const rows = members.filter((m) => users.get(m.userId)).map((m) => ({
      ...card(users.get(m.userId)), joinedAt: m.joinedAt, via: m.via || 'invite',
      role: m.userId === op.ownerId ? 'OWNER' : co.has(m.userId) ? 'CO_ORGANISER' : 'MEMBER',
    }));
    const order = { OWNER: 0, CO_ORGANISER: 1, MEMBER: 2 };
    rows.sort((a, b) => order[a.role] - order[b.role] || a.joinedAt - b.joinedAt);
    res.json({
      members: rows,
      invites: invites.filter((i) => users.get(i.userId)).map((i) => ({ inviteId: i.inviteId, ...card(users.get(i.userId)), invitedBy: card(users.get(i.invitedBy)).username, createdAt: i.createdAt, expiresAt: i.expiresAt })),
      limits: { maxMembers: op.limits.maxMembers, coOrganisers: op.limits.coOrganisers },
      inviteLink: op.inviteLinkOn && op.inviteCode ? `${originOf(req)}/clubs/join/${op.inviteCode}` : null,
    });
  }));
  r.post(`${C_}/roster/invites`, authed, feature, inviteLimiter, access({ write: true }), wrap(async (req, res) => {
    const op = req.op;
    const raw = req.body && (req.body.usernames ?? req.body.username);
    const names = RI.cleanUsernames(raw).slice(0, 50);
    if (!names.length) return res.status(422).json({ error: 'Enter at least one username.', code: 'NO_INVITEES' });
    const crew = await CR.getCrew(soda, op.crewId);
    const results = [];
    let full = false;
    for (const name of names) {
      const u = await byUsername(name);
      if (!u || (await F.blockedEither(soda, op.ownerId, u.userId))) { results.push({ username: name, status: 'NOT_FOUND' }); continue; }
      if (full) { results.push({ username: u.username, status: 'ROSTER_FULL' }); continue; }
      let out;
      try { out = await OP.inviteToRoster(soda, op, req.user.userId, u.userId); } catch (e) {
        if (e instanceof OP.OperatorError && e.code === 'ROSTER_FULL') {
          full = true;
          if (names.length === 1) return fail(res, e);
          results.push({ username: u.username, status: 'ROSTER_FULL' }); continue;
        }
        return fail(res, e);
      }
      results.push({ username: u.username, status: out.status });
      if (out.status === 'INVITED') {
        // The app shows it in its crew invites (People hub > Requests); the push opens that list.
        const payload = { type: 'CREW_INVITE', inviteId: out.invite.inviteId, crewId: op.crewId, crewName: (crew && crew.name) || op.name, username: op.name, club: true, requestType: 'OPERATOR_INVITE', eventId: `CREW_INVITE:${out.invite.inviteId}` };
        socket(u.userId, payload);
        const p = pushOf();
        if (p && typeof p.notifyUsers === 'function') {
          Promise.resolve(p.notifyUsers([u.userId], { type: 'CREW_INVITE', title: 'Club invite', body: `${op.name} invited you to join their club on CoRoute`, data: { inviteId: out.invite.inviteId, crewId: op.crewId, kind: 'OPERATOR_INVITE', eventId: payload.eventId } })).catch(() => {});
        }
      }
    }
    const invited = results.filter((x) => x.status === 'INVITED').length;
    if (invited) await audit(req, 'operator.roster_invite', op.operatorId, { invited });
    res.status(invited ? 201 : 200).json({ results });
  }));
  r.delete(`${C_}/roster/invites/:inviteId`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const ok = await CR.cancelInvite(soda, req.op.crewId, String(req.params.inviteId || ''));
    res.status(ok ? 200 : 404).json(ok ? { ok: true } : { error: 'Invite not found.', code: 'NOT_FOUND' });
  }));
  r.post(`${C_}/roster/link`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const action = String((req.body && req.body.action) || '');
    if (!['rotate', 'disable', 'enable'].includes(action)) return res.status(422).json({ error: 'Use rotate, disable or enable.', code: 'BAD_ACTION' });
    const op = await OP.saveOperator(soda, {
      ...req.op, inviteCode: action === 'rotate' || !req.op.inviteCode ? OP.randomCode() : req.op.inviteCode, inviteLinkOn: action !== 'disable',
    });
    await audit(req, 'operator.invite_link', op.operatorId, { action });
    res.json({ inviteLink: op.inviteLinkOn ? `${originOf(req)}/clubs/join/${op.inviteCode}` : null });
  }));
  r.delete(`${C_}/roster/:username`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const op = req.op;
    const u = await U.findUserByUsername(repo, String(req.params.username || '')).catch(() => null);
    const m = u && op.crewId ? await CR.memberOf(soda, op.crewId, u.userId) : null;
    if (!m) return res.status(404).json({ error: 'This rider is not on the roster.', code: 'NOT_A_MEMBER' });
    if (u.userId === op.ownerId) return res.status(409).json({ error: 'The account owner stays on the roster.', code: 'NOT_ALLOWED' });
    if ((op.coOrganisers || []).includes(u.userId) && req.opRole !== 'OWNER') return res.status(403).json({ error: 'Only the account owner can remove a co-organiser.', code: 'OWNER_ONLY' });
    const crew = await CR.getCrew(soda, op.crewId);
    await CR.leaveCrew(soda, crew, u.userId);
    if ((op.coOrganisers || []).includes(u.userId)) await OP.saveOperator(soda, { ...op, coOrganisers: op.coOrganisers.filter((x) => x !== u.userId) });
    socket(u.userId, { type: 'CREW_REMOVED', crewId: op.crewId, crewName: crew ? crew.name : op.name });
    await audit(req, 'operator.roster_remove', op.operatorId, { username: u.username });
    res.json({ ok: true });
  }));

  // ---- co-organisers (owner only) ----
  r.post(`${C_}/co-organisers`, authed, feature, writeLimiter, access({ write: true, owner: true }), wrap(async (req, res) => {
    const op = req.op;
    const u = await byUsername(req.body && req.body.username);
    if (!u || !op.crewId || !(await CR.memberOf(soda, op.crewId, u.userId))) {
      return res.status(422).json({ error: 'Co-organisers are picked from your roster. Invite the rider first.', code: 'NOT_A_MEMBER' });
    }
    const list = op.coOrganisers || [];
    if (u.userId === op.ownerId || list.includes(u.userId)) return res.json({ ok: true, coOrganisers: list.length });
    if (list.length >= op.limits.coOrganisers) {
      return res.status(409).json({ error: `Your plan allows ${op.limits.coOrganisers} co-organiser${op.limits.coOrganisers === 1 ? '' : 's'}.`, code: 'CO_ORGANISER_LIMIT', limit: op.limits.coOrganisers });
    }
    const next = await OP.saveOperator(soda, { ...op, coOrganisers: [...list, u.userId] });
    await OP.setCrewRole(soda, op.crewId, u.userId, CR.ROLES.CO_ADMIN);
    await audit(req, 'operator.co_organiser_add', op.operatorId, { username: u.username });
    res.status(201).json({ ok: true, coOrganisers: next.coOrganisers.length });
  }));
  r.delete(`${C_}/co-organisers/:username`, authed, feature, writeLimiter, access({ write: true, owner: true }), wrap(async (req, res) => {
    const op = req.op;
    const u = await U.findUserByUsername(repo, String(req.params.username || '')).catch(() => null);
    if (!u || !(op.coOrganisers || []).includes(u.userId)) return res.status(404).json({ error: 'Not a co-organiser.', code: 'NOT_FOUND' });
    await OP.saveOperator(soda, { ...op, coOrganisers: op.coOrganisers.filter((x) => x !== u.userId) });
    await OP.setCrewRole(soda, op.crewId, u.userId, CR.ROLES.MEMBER);
    await audit(req, 'operator.co_organiser_remove', op.operatorId, { username: u.username });
    res.json({ ok: true });
  }));

  // ---- rides ----
  const rideView = async (ride, op, req, users) => {
    const counts = OP.signupCounts(ride);
    const room = ride.groupId ? convoys.rooms.get(ride.groupId) : null;
    return {
      rideId: ride.rideId, title: ride.title, slug: ride.slug, startsAt: ride.startsAt, meetName: ride.meetName, destinationName: ride.destinationName,
      notes: ride.notes, maxRiders: ride.maxRiders, status: ride.status, startedAt: ride.startedAt || 0, endedAt: ride.endedAt || 0,
      lead: card(users.get(ride.leadUserId)), sweeper: ride.sweeperUserId ? card(users.get(ride.sweeperUserId)) : null,
      publicSignup: !!ride.publicSignup, requireApproval: !!ride.requireApproval, signups: counts,
      publicUrl: ride.publicSignup ? `${originOf(req)}/rides/${ride.slug}` : null,
      ridersNow: room ? room.riders.size : 0, publishedAt: ride.publishedAt || 0, invited: ride.invited || 0,
    };
  };
  const rideOf = async (req) => {
    const ride = await OP.getRide(soda, String(req.params.rideId || ''));
    return ride && ride.operatorId === req.op.operatorId ? syncRide(ride) : null;
  };
  /** Lead / sweeper: on the roster (the owner and co-organisers are). */
  const pickRider = async (op, raw, label) => {
    if (raw === undefined || raw === null || raw === '') return null;
    const u = await byUsername(raw);
    if (!u || !op.crewId || !(await CR.memberOf(soda, op.crewId, u.userId))) {
      throw new OP.OperatorError(`The ${label} must be on your roster.`, 'NOT_A_MEMBER', 422, { fields: { [label]: `@${String(raw).replace(/^@/, '')} is not on your roster.` } });
    }
    return u.userId;
  };

  r.get(`${C_}/rides`, authed, feature, readLimiter, access(), wrap(async (req, res) => {
    const rides = [];
    for (const x of await OP.ridesOf(soda, req.op.operatorId)) rides.push(await syncRide(x));
    const users = await usersByIds(rides.flatMap((x) => [x.leadUserId, x.sweeperUserId]));
    const out = [];
    for (const x of rides) out.push(await rideView(x, req.op, req, users));
    const month = OP.istMonth(Date.now());
    res.json({
      rides: out,
      limits: { maxConcurrentRides: req.op.limits.maxConcurrentRides, maxRidesPerMonth: req.op.limits.maxRidesPerMonth, maxRidersPerRide: req.op.limits.maxRidersPerRide },
      usage: { ridesThisMonth: rides.filter((x) => x.month === month && x.status !== OP.RIDE_STATUS.CANCELLED).length, liveRides: rides.filter((x) => x.status === OP.RIDE_STATUS.LIVE).length },
    });
  }));
  r.post(`${C_}/rides`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const op = req.op;
    const b = req.body || {};
    let ride;
    try {
      const fields = OP.validateRide({ ...b, startsAt: b.startsAt ?? Date.now() }, op);
      fields.leadUserId = (await pickRider(op, b.leadUsername, 'lead')) || req.user.userId;
      fields.sweeperUserId = await pickRider(op, b.sweeperUsername, 'sweeper');
      if (fields.sweeperUserId && fields.sweeperUserId === fields.leadUserId) throw new OP.OperatorError('Pick a different rider as sweeper.', 'INVALID_RIDE', 422, { fields: { sweeper: 'The lead cannot also be the sweeper.' } });
      ride = await OP.createRide(soda, op, req.user.userId, fields);
    } catch (e) { return fail(res, e); }
    await audit(req, 'operator.ride_create', op.operatorId, { rideId: ride.rideId, title: ride.title, startsAt: ride.startsAt, maxRiders: ride.maxRiders });
    const users = await usersByIds([ride.leadUserId, ride.sweeperUserId]);
    res.status(201).json({ ride: await rideView(ride, op, req, users) });
  }));
  r.patch(`${C_}/rides/:rideId`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const op = req.op;
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    if (ride.status !== OP.RIDE_STATUS.SCHEDULED) return res.status(409).json({ error: 'Only a scheduled ride can be changed.', code: 'RIDE_NOT_SCHEDULED' });
    const b = req.body || {};
    let next;
    try {
      const fields = OP.validateRide(b, op, { partial: true });
      if (fields.maxRiders !== undefined && fields.maxRiders - 1 < OP.signupCounts(ride).approved) {
        throw new OP.OperatorError('More riders are already approved than that.', 'INVALID_RIDE', 422, { fields: { maxRiders: 'Lower than the approved sign-ups.' } });
      }
      if (b.leadUsername !== undefined) fields.leadUserId = (await pickRider(op, b.leadUsername, 'lead')) || ride.leadUserId;
      if (b.sweeperUsername !== undefined) fields.sweeperUserId = await pickRider(op, b.sweeperUsername, 'sweeper');
      if (fields.startsAt !== undefined && OP.istMonth(fields.startsAt) !== ride.month) {
        if ((await OP.ridesInMonth(soda, op.operatorId, fields.startsAt)) >= op.limits.maxRidesPerMonth) {
          throw new OP.OperatorError(`Your plan allows ${op.limits.maxRidesPerMonth} rides a month; that month is full.`, 'RIDES_PER_MONTH_LIMIT', 409, { limit: op.limits.maxRidesPerMonth });
        }
        fields.month = OP.istMonth(fields.startsAt);
      }
      next = await OP.saveRide(soda, { ...ride, ...fields });
    } catch (e) { return fail(res, e); }
    await audit(req, 'operator.ride_update', op.operatorId, { rideId: ride.rideId });
    const users = await usersByIds([next.leadUserId, next.sweeperUserId]);
    res.json({ ride: await rideView(next, op, req, users) });
  }));
  r.post(`${C_}/rides/:rideId/cancel`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    if (ride.status !== OP.RIDE_STATUS.SCHEDULED) return res.status(409).json({ error: 'Only a scheduled ride can be cancelled. End a live ride instead.', code: 'RIDE_NOT_SCHEDULED' });
    await OP.saveRide(soda, { ...ride, status: OP.RIDE_STATUS.CANCELLED, endedAt: Date.now() });
    await audit(req, 'operator.ride_cancel', req.op.operatorId, { rideId: ride.rideId });
    res.json({ ok: true, status: OP.RIDE_STATUS.CANCELLED });
  }));

  /** Starts the ride: a normal convoy whose trip owner is the lead, seats from the operator limits. */
  r.post(`${C_}/rides/:rideId/start`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const op = req.op;
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    if (ride.status !== OP.RIDE_STATUS.SCHEDULED) return res.status(409).json({ error: 'This ride is not waiting to start.', code: 'RIDE_NOT_SCHEDULED' });
    const live = await OP.liveRides(soda, op.operatorId, convoyActive);
    if (live.length >= op.limits.maxConcurrentRides) {
      return res.status(409).json({ error: `Your plan allows ${op.limits.maxConcurrentRides} live ride${op.limits.maxConcurrentRides === 1 ? '' : 's'} at a time. End one first.`, code: 'CONCURRENT_RIDES_LIMIT', limit: op.limits.maxConcurrentRides });
    }
    const lead = await repo.findUserById(ride.leadUserId);
    if (!lead || lead.status === 'BLOCKED') return res.status(422).json({ error: 'The lead rider account is not available. Pick another lead.', code: 'LEAD_UNAVAILABLE' });
    const leadIdentity = require('./auth').identityOf(lead);
    const capacity = await capacityFor(op, ride);
    let snap;
    try {
      // convoys.createConvoy opts.operator: seats from the operator limits, not the lead's plan.
      snap = await convoys.createConvoy(leadIdentity, { name: ride.title, startPoint: ride.meetName, destination: ride.destinationName },
        { operator: { operatorId: op.operatorId, rideId: ride.rideId, capacity } });
    } catch (e) { return fail(res, e); }
    const next = await OP.saveRide(soda, { ...ride, status: OP.RIDE_STATUS.LIVE, groupId: snap.groupId, startedAt: Date.now() });
    await audit(req, 'operator.ride_start', op.operatorId, { rideId: ride.rideId, groupId: snap.groupId, capacity });
    const users = await usersByIds([next.leadUserId, next.sweeperUserId]);
    res.json({ ride: await rideView(next, op, req, users), groupId: snap.groupId, capacity });
  }));
  const capacityFor = async (op, ride) => Math.max(2, Math.min(ride.maxRiders, op.limits.maxRidersPerRide, Math.max(2, Number(config.maxConvoyRiders) || 2)));

  /**
   * Publishes the ride to the roster. Live: crew ride invites (accepted in the app, normal join
   * rules, the ride's seats). Scheduled: an announcement (News push "Community update").
   */
  r.post(`${C_}/rides/:rideId/publish`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const op = req.op;
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    const { members } = await OP.roster(soda, op);
    const names = req.body && req.body.usernames !== undefined ? new Set(RI.cleanUsernames(req.body.usernames).map((x) => x.toLowerCase())) : null;
    const users = await usersByIds(members.map((m) => m.userId));
    const targets = members.map((m) => users.get(m.userId)).filter((u) => u && u.status !== 'BLOCKED' && (!names || names.has(String(u.username || '').toLowerCase())));
    if (ride.status === OP.RIDE_STATUS.SCHEDULED) {
      const ids = targets.map((u) => u.userId).filter((id) => id !== req.user.userId);
      const when = new Date(ride.startsAt + IST).toISOString().slice(0, 16).replace('T', ' ');
      const title = OP.clean(`${op.name}: new ride`, 60);
      const body = OP.clean(`${ride.title} on ${when} IST${ride.meetName ? ` from ${ride.meetName}` : ''}.`, 240);
      const term = forbiddenTermIn(`${title}\n${body}`);
      if (term) return res.status(422).json({ error: policyRefusal(term, 'This announcement'), code: 'PLAY_POLICY' });
      for (const id of ids) socket(id, { type: 'CLUB_BROADCAST', operatorId: op.operatorId, crewId: op.crewId, title, body, rideId: ride.rideId });
      const p = pushOf();
      if (p && ids.length) Promise.resolve(p.notifyUsers(ids, { type: 'NEWS', title, body, target: 'crews', data: { kind: 'community_update', operatorId: op.operatorId, rideId: ride.rideId } })).catch(() => {});
      await OP.saveRide(soda, { ...ride, publishedAt: Date.now() });
      await audit(req, 'operator.ride_announce', op.operatorId, { rideId: ride.rideId, recipients: ids.length });
      return res.json({ announced: ids.length, invited: 0 });
    }
    if (ride.status !== OP.RIDE_STATUS.LIVE) return res.status(409).json({ error: 'This ride has ended.', code: 'RIDE_ENDED' });
    const room = await convoys.getRoom(ride.groupId, { required: false });
    if (!room) return res.status(409).json({ error: 'This ride has ended.', code: 'RIDE_ENDED' });
    const owner = room.meta.tripOwnerUserId || room.meta.createdByUserId;
    if (!(await CR.memberOf(soda, op.crewId, owner))) return res.status(409).json({ error: 'The lead must be on the roster to invite it.', code: 'LEAD_NOT_ON_ROSTER' });
    await soda.ensureCollection(RI.COLL);
    const existing = (await soda.query(RI.COLL, { groupId: ride.groupId }, { limit: 2000 })).map((x) => ({ ...x.value, key: x.key }));
    const now = Date.now();
    const pendingOf = (inv) => inv.status === 'PENDING' && inv.expiresAt > now;
    let pending = existing.filter((inv) => pendingOf(inv) && !room.riders.has(inv.toUserId)).length;
    const capacity = convoys._storedCapacity ? convoys._storedCapacity(room.meta) : ride.maxRiders;
    const results = [];
    const sent = [];
    for (const u of targets) {
      if (room.riders.has(u.userId) || u.userId === owner) { results.push({ username: u.username, status: 'ALREADY_IN_RIDE' }); continue; }
      const prev = existing.find((inv) => inv.toUserId === u.userId);
      if (prev && pendingOf(prev)) { results.push({ username: u.username, status: 'ALREADY_INVITED' }); continue; }
      if (room.riders.size + pending >= capacity) { results.push({ username: u.username, status: 'RIDE_FULL' }); continue; }
      const invite = {
        inviteId: `ri_${crypto.randomBytes(8).toString('hex')}`, inviteKey: `${ride.groupId}|${u.userId}`, groupId: ride.groupId, crewId: op.crewId,
        fromUserId: owner, toUserId: u.userId, status: 'PENDING', createdAt: now, expiresAt: now + RI.LIMITS.TTL_MS, answeredAt: 0, operatorId: op.operatorId,
      };
      if (prev) await soda.replace(RI.COLL, prev.key, invite); else await soda.insert(RI.COLL, invite);
      pending++;
      sent.push({ u, invite });
      results.push({ username: u.username, status: 'INVITED' });
    }
    const text = { title: 'Ride invitation', body: OP.clean(`${op.name} invited you to the ride ${ride.title}`, 240) };
    const p = pushOf();
    for (const { u, invite } of sent) {
      socket(u.userId, { type: 'RIDE_INVITE', inviteId: invite.inviteId, crewId: op.crewId, crewName: op.name, rideName: ride.title, username: op.name, expiresAt: invite.expiresAt, eventId: `RIDE_INVITE:${invite.inviteId}` });
      if (p) Promise.resolve(p.notifyUsers([u.userId], { type: 'RIDE_INVITE', title: text.title, body: text.body, data: { inviteId: invite.inviteId, eventId: `RIDE_INVITE:${invite.inviteId}` }, priority: 'high', ttlSec: 1800 })).catch(() => {});
    }
    await OP.saveRide(soda, { ...ride, publishedAt: now, invited: (ride.invited || 0) + sent.length });
    await audit(req, 'operator.ride_publish', op.operatorId, { rideId: ride.rideId, invited: sent.length });
    res.status(sent.length ? 201 : 200).json({ invited: sent.length, results, capacity, riders: room.riders.size });
  }));
  r.post(`${C_}/rides/:rideId/end`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    if (ride.status !== OP.RIDE_STATUS.LIVE) return res.status(409).json({ error: 'This ride is not live.', code: 'RIDE_NOT_LIVE' });
    try { await convoys.setTripStatus(ride.groupId, 'ENDED'); } catch (e) { return fail(res, e); }
    const next = await OP.saveRide(soda, { ...ride, status: OP.RIDE_STATUS.ENDED, endedAt: Date.now() });
    await audit(req, 'operator.ride_end', req.op.operatorId, { rideId: ride.rideId, groupId: ride.groupId });
    res.json({ ok: true, status: next.status });
  }));
  r.post(`${C_}/rides/:rideId/roles`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    const role = String((req.body && req.body.role) || '').toUpperCase();
    if (!['LEAD', 'SWEEPER', 'PACK'].includes(role)) return res.status(422).json({ error: 'Role must be LEAD, SWEEPER or PACK.', code: 'BAD_ROLE' });
    const u = await byUsername(req.body && req.body.username);
    if (!u) return res.status(404).json({ error: 'Rider not found.', code: 'NOT_FOUND' });
    if (ride.status === OP.RIDE_STATUS.SCHEDULED) {
      if (role === 'PACK') return res.status(422).json({ error: 'Assign LEAD or SWEEPER before the ride.', code: 'BAD_ROLE' });
      try {
        const uid = await pickRider(req.op, u.username, role === 'LEAD' ? 'lead' : 'sweeper');
        const patch = role === 'LEAD' ? { leadUserId: uid, sweeperUserId: ride.sweeperUserId === uid ? null : ride.sweeperUserId } : { sweeperUserId: uid };
        await OP.saveRide(soda, { ...ride, ...patch });
      } catch (e) { return fail(res, e); }
      return res.json({ ok: true, role });
    }
    if (ride.status !== OP.RIDE_STATUS.LIVE) return res.status(409).json({ error: 'This ride has ended.', code: 'RIDE_ENDED' });
    const room = await convoys.getRoom(ride.groupId, { required: false });
    const owner = room && (room.meta.tripOwnerUserId || room.meta.createdByUserId);
    try { await convoys.setRole(ride.groupId, { userId: owner, role: 'RIDER' }, u.userId, role); } catch (e) { return fail(res, e); }
    if (role === 'SWEEPER') await OP.saveRide(soda, { ...ride, sweeperUserId: u.userId });
    await audit(req, 'operator.ride_role', req.op.operatorId, { rideId: ride.rideId, username: u.username, role });
    res.json({ ok: true, role });
  }));

  // ---- public sign-ups (console side) ----
  r.get(`${C_}/rides/:rideId/signups`, authed, feature, readLimiter, access(), wrap(async (req, res) => {
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    const list = (ride.signups || []).filter((s) => s.status !== 'CANCELLED');
    const users = await usersByIds(list.map((s) => s.userId));
    res.json({
      signups: list.filter((s) => users.get(s.userId)).map((s) => ({ ...card(users.get(s.userId)), status: s.status, at: s.at, decidedAt: s.decidedAt || 0 })),
      counts: OP.signupCounts(ride), maxRiders: ride.maxRiders,
    });
  }));
  r.post(`${C_}/rides/:rideId/signups/:username`, authed, feature, writeLimiter, access({ write: true }), wrap(async (req, res) => {
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    const u = await U.findUserByUsername(repo, String(req.params.username || '')).catch(() => null);
    if (!u) return res.status(404).json({ error: 'No such sign-up.', code: 'NOT_FOUND' });
    const approve = !!(req.body && (req.body.approve === true || req.body.decision === 'APPROVE'));
    let next;
    try { next = await OP.decideSignup(soda, ride, u.userId, approve); } catch (e) { return fail(res, e); }
    socket(u.userId, { type: 'OPERATOR_SIGNUP', slug: ride.slug, status: approve ? 'APPROVED' : 'REJECTED' });
    await audit(req, 'operator.signup_decision', req.op.operatorId, { rideId: ride.rideId, username: u.username, approve });
    res.json({ ok: true, status: approve ? 'APPROVED' : 'REJECTED', counts: OP.signupCounts(next) });
  }));

  // ---- live dashboard ----
  const liveView = async (ride, op) => {
    const room = await convoys.getRoom(ride.groupId, { required: false });
    if (!room) return null;
    const users = await usersByIds([...room.riders.keys()]);
    const now = Date.now();
    const riders = [...room.riders.values()].map((x) => ({
      ...card(users.get(x.userId) || { name: x.name }), role: x.role || 'PACK',
      lat: Number(x.lat) || 0, lng: Number(x.lng) || 0, speedKmh: Math.round(Number(x.speedKmh) || 0), heading: Number(x.heading) || 0,
      batteryLevel: x.batteryLevel ?? null, presence: x.presence || '', lastSeenAt: x.lastSeenEpochMs || 0,
      stale: !x.lastSeenEpochMs || now - x.lastSeenEpochMs > 5 * 60000, statusReason: x.statusReason || '',
    }));
    const alerts = [...room.alerts.values()].filter((a) => !a.resolved).map((a) => ({
      alertId: a.alertId, alertType: a.alertType || 'EMERGENCY', auto: !!a.auto, startedAt: a.timestamp || 0,
      rider: card(users.get(a.userId) || { name: a.userName }), lat: Number(a.lat) || 0, lng: Number(a.lng) || 0,
      sos: true, contactsAvailable: !!(op.features && op.features.rosterEmergency),
    }));
    return {
      rideId: ride.rideId, title: ride.title, groupId: ride.groupId, tripStatus: room.meta.tripStatus, startedAt: ride.startedAt,
      capacity: convoys._storedCapacity ? convoys._storedCapacity(room.meta) : ride.maxRiders, riders, alerts,
      destinationName: ride.destinationName, meetName: ride.meetName,
    };
  };
  r.get(`${C_}/live`, authed, feature, readLimiter, access(), wrap(async (req, res) => {
    const op = req.op;
    let rides = await OP.liveRides(soda, op.operatorId, convoyActive);
    const multi = !!op.features.multiGroupDashboard;
    const wanted = String(req.query.rideId || '');
    if (!multi) rides = rides.filter((x) => (wanted ? x.rideId === wanted : true)).slice(0, 1);
    else if (wanted) rides = rides.filter((x) => x.rideId === wanted);
    const out = [];
    for (const ride of rides) { const v = await liveView(ride, op); if (v) out.push(v); }
    res.json({ rides: out, multi, sos: out.some((x) => x.alerts.length > 0), at: Date.now() });
  }));
  /** A rider's emergency contact (and medical ID) while that rider's SOS is open in an operator ride. Audited. */
  r.get(`${C_}/rides/:rideId/sos/:alertId`, authed, feature, readLimiter, access(), needFeature('rosterEmergency'), wrap(async (req, res) => {
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    const room = ride.status === OP.RIDE_STATUS.LIVE ? await convoys.getRoom(ride.groupId, { required: false }) : null;
    const alert = room && room.alerts.get(String(req.params.alertId || ''));
    if (!room || !LIVE.includes(room.meta.tripStatus) || !alert || alert.resolved) {
      return res.status(403).json({ error: 'Emergency contacts are shown only while that rider has an open SOS.', code: 'NO_ACTIVE_SOS' });
    }
    const u = await repo.findUserById(alert.userId);
    const rider = room.riders.get(alert.userId) || {};
    const contact = rider.emergencyContact || (u && u.emergencyContact) || '';
    const medical = {};
    if (u && u.bloodGroup) medical.bloodGroup = String(u.bloodGroup);
    if (u && u.allergies) medical.allergies = String(u.allergies);
    if (u && u.medicalNotes) medical.notes = String(u.medicalNotes);
    await audit(req, 'operator.sos_contacts_viewed', req.op.operatorId, { rideId: ride.rideId, groupId: ride.groupId, alertId: alert.alertId, rider: (u && u.username) || '' });
    res.json({
      rider: card(u), alertType: alert.alertType || 'EMERGENCY', startedAt: alert.timestamp || 0,
      riderPhone: rider.phone || '', emergencyContact: contact ? { name: rider.emergencyContactName || (u && u.emergencyContactName) || '', phone: contact } : null,
      medical: Object.keys(medical).length ? medical : null,
      lastPosition: { lat: Number(alert.lat) || Number(rider.lat) || 0, lng: Number(alert.lng) || Number(rider.lng) || 0 },
      notice: 'Shown because of an open SOS. This view was recorded in the audit log.',
    });
  }));

  // ---- attendance & reports ----
  const attendanceOf = async (ride) => {
    if (ride.status === OP.RIDE_STATUS.ENDED && ride.attendance) return ride.attendance;
    const meta = await metaOf(ride.groupId);
    if (!meta) return null;
    const members = Array.isArray(meta.memberSummary) && meta.memberSummary.length ? meta.memberSummary : Object.values(meta.members || {});
    const users = await usersByIds(members.map((m) => m.userId));
    const alerts = await repo.listAlerts(ride.groupId, { includeResolved: true }).catch(() => []);
    const ended = !ACTIVE.includes(meta.tripStatus);
    const arrivals = meta.destinationArrivals || {};
    const rows = [];
    for (const m of members) {
      let distanceKm = 0;
      if (tracks) {
        try {
          const pts = (await tracks.load(ride.groupId, { userId: m.userId })).get(m.userId) || [];
          distanceKm = Math.round(analyseTrack(pts).distanceM / 100) / 10;
        } catch { distanceKm = 0; }
      }
      const left = Number(m.leftAt) > Number(m.joinedAt || 0);
      rows.push({
        ...card(users.get(m.userId) || { name: m.name }), role: m.role || 'PACK', joinedAt: m.firstJoinedAt || m.joinedAt || 0, leftAt: left ? m.leftAt : 0,
        finished: !!arrivals[m.userId] || (ended && !left), arrived: !!arrivals[m.userId], distanceKm,
        incidents: alerts.filter((a) => a.userId === m.userId).length,
      });
    }
    const out = {
      rideId: ride.rideId, title: ride.title, startsAt: ride.startsAt, startedAt: ride.startedAt || meta.createdAtEpochMs || 0, endedAt: meta.endedAtEpochMs || 0,
      status: ride.status, joined: rows.length, finished: rows.filter((x) => x.finished).length,
      distanceKm: Math.round(rows.reduce((s, x) => s + x.distanceKm, 0) * 10) / 10, riders: rows,
      // Incidents: type, time, outcome. Never a location.
      incidents: alerts.map((a) => ({ type: a.alertType || 'EMERGENCY', at: a.timestamp || 0, resolved: !!a.resolved, outcome: a.resolveReason || (a.resolved ? 'RESOLVED' : 'OPEN'), rider: card(users.get(a.userId) || { name: a.userName }).username })),
    };
    if (ended && ride.status === OP.RIDE_STATUS.ENDED) await OP.saveRide(soda, { ...ride, attendance: out }).catch(() => {});
    return out;
  };
  r.get(`${C_}/rides/:rideId/attendance`, authed, feature, readLimiter, access(), needFeature('attendance'), wrap(async (req, res) => {
    const ride = await rideOf(req);
    if (!ride) return res.status(404).json(RIDE_NOT_FOUND);
    if (!ride.groupId) return res.status(409).json({ error: 'This ride has not started yet.', code: 'RIDE_NOT_STARTED' });
    res.json({ attendance: await attendanceOf(ride) });
  }));
  const monthOf = (q) => (/^\d{4}-\d{2}$/.test(String(q || '')) ? String(q) : OP.istMonth(Date.now()));
  const reportRides = async (op, month) => {
    const out = [];
    for (const x of await OP.ridesOf(soda, op.operatorId)) {
      if (x.month !== month || !x.groupId) continue;
      const a = await attendanceOf(await syncRide(x));
      if (a) out.push(a);
    }
    return out.sort((a, b) => a.startsAt - b.startsAt);
  };
  r.get(`${C_}/reports`, authed, feature, readLimiter, access(), needFeature('attendance'), wrap(async (req, res) => {
    const month = monthOf(req.query.month);
    const rides = await reportRides(req.op, month);
    const all = await OP.ridesOf(soda, req.op.operatorId);
    res.json({
      month, rides: rides.map(({ riders, ...rest }) => ({ ...rest, riders: riders.length })),
      totals: {
        rides: rides.length, scheduled: all.filter((x) => x.month === month && x.status === OP.RIDE_STATUS.SCHEDULED).length,
        cancelled: all.filter((x) => x.month === month && x.status === OP.RIDE_STATUS.CANCELLED).length,
        riders: rides.reduce((s, x) => s + x.joined, 0), finished: rides.reduce((s, x) => s + x.finished, 0),
        distanceKm: Math.round(rides.reduce((s, x) => s + x.distanceKm, 0) * 10) / 10, incidents: rides.reduce((s, x) => s + x.incidents.length, 0),
      },
      canExport: !!req.op.features.exportReports,
    });
  }));
  r.get(`${C_}/reports.csv`, authed, feature, readLimiter, access(), needFeature('exportReports'), wrap(async (req, res) => {
    const month = monthOf(req.query.month);
    const rides = await reportRides(req.op, month);
    const lines = [['ride', 'ride_date_ist', 'status', 'username', 'first_name', 'role', 'joined_ist', 'left_ist', 'finished', 'distance_km', 'incidents'].join(',')];
    for (const a of rides) {
      for (const x of a.riders) {
        lines.push([a.title, istDate(a.startedAt || a.startsAt), a.status, x.username, x.displayName, x.role, istDate(x.joinedAt), istDate(x.leftAt), x.finished ? 'yes' : 'no', x.distanceKm, x.incidents].map(csvCell).join(','));
      }
    }
    await audit(req, 'operator.report_export', req.op.operatorId, { month, rides: rides.length });
    res.set('Content-Disposition', `attachment; filename="coroute-${month}-attendance.csv"`).type('text/csv; charset=utf-8').send(`﻿${lines.join('\r\n')}\r\n`);
  }));

  // ---- broadcasts ----
  r.get(`${C_}/broadcasts`, authed, feature, readLimiter, access(), wrap(async (req, res) => {
    const list = await OP.broadcastsOf(soda, req.op.operatorId, 50);
    const users = await usersByIds(list.map((b) => b.by));
    res.json({ broadcasts: list.map((b) => ({ broadcastId: b.broadcastId, title: b.title, body: b.body, at: b.at, recipients: b.recipients, by: card(users.get(b.by)).username })), perDay: OP.BROADCAST_LIMITS.PER_DAY });
  }));
  r.post(`${C_}/broadcasts`, authed, feature, writeLimiter, access({ write: true }), needFeature('broadcast'), wrap(async (req, res) => {
    const op = req.op;
    const title = OP.clean(req.body && req.body.title, OP.BROADCAST_LIMITS.TITLE_MAX);
    const body = OP.clean(req.body && req.body.body, OP.BROADCAST_LIMITS.BODY_MAX);
    if (title.length < 3 || body.length < 3) return res.status(422).json({ error: 'Write a title and a message.', code: 'EMPTY_MESSAGE' });
    // Play payments policy: the push reaches the Play app (same guard as the admin push campaigns).
    const term = forbiddenTermIn(`${title}\n${body}`);
    if (term) return res.status(422).json({ error: policyRefusal(term, 'This message'), code: 'PLAY_POLICY', term });
    if (OP.CONTACT_IN_TEXT.test(`${title} ${body}`)) return res.status(422).json({ error: 'Leave phone numbers and e-mail addresses out of broadcasts.', code: 'CONTACT_IN_TEXT' });
    const today = (await OP.broadcastsOf(soda, op.operatorId, 100)).filter((b) => b.at > Date.now() - DAY).length;
    if (today >= OP.BROADCAST_LIMITS.PER_DAY) return res.status(429).json({ error: `Up to ${OP.BROADCAST_LIMITS.PER_DAY} broadcasts a day.`, code: 'BROADCAST_LIMIT' });
    const { members } = await OP.roster(soda, op);
    const ids = members.map((m) => m.userId).filter((id) => id !== req.user.userId);
    const doc = { broadcastId: `ob_${crypto.randomBytes(8).toString('hex')}`, operatorId: op.operatorId, title, body, by: req.user.userId, at: Date.now(), recipients: ids.length };
    await OP.addBroadcast(soda, doc);
    for (const id of ids) socket(id, { type: 'CLUB_BROADCAST', operatorId: op.operatorId, crewId: op.crewId, broadcastId: doc.broadcastId, title, body });
    const p = pushOf();
    // Push kind "Community update": the app's NEWS notice, opening the crews list (the club is a crew).
    let pushed = null;
    if (p && ids.length) pushed = await Promise.resolve(p.notifyUsers(ids, { type: 'NEWS', title: OP.clean(`${op.name}: ${title}`, 80), body, target: 'crews', data: { kind: 'community_update', operatorId: op.operatorId, broadcastId: doc.broadcastId } })).catch(() => null);
    await audit(req, 'operator.broadcast', op.operatorId, { broadcastId: doc.broadcastId, recipients: ids.length });
    res.status(201).json({ broadcast: { broadcastId: doc.broadcastId, title, body, at: doc.at, recipients: ids.length }, push: pushed });
  }));

  // ---- members: my clubs ----
  const clubInvite = async (inviteId, userId) => {
    if (!CR.isInviteId(inviteId)) return null;
    await CR.ensureCrewStore(soda);
    const row = await soda.findOne(CR.COLLECTIONS.invites, { inviteId });
    if (!row || row.value.userId !== userId) return null;
    const crew = await CR.getCrew(soda, row.value.crewId);
    return crew && crew.club ? { invite: row.value, crew } : null;
  };
  r.get('/clubs', authed, feature, readLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const clubs = [];
    for (const m of await CR.membershipsOf(soda, uid)) {
      const crew = await CR.getCrew(soda, m.crewId);
      if (!crew || !crew.club) continue;
      const op = await OP.getOperator(soda, crew.club.operatorId);
      if (!op) continue;
      const latest = (await OP.broadcastsOf(soda, op.operatorId, 3)).map((b) => ({ title: b.title, body: b.body, at: b.at }));
      const upcoming = (await OP.ridesOf(soda, op.operatorId)).filter((x) => x.status === OP.RIDE_STATUS.SCHEDULED && x.startsAt > Date.now() - 6 * HOUR)
        .sort((a, b) => a.startsAt - b.startsAt).slice(0, 3).map((x) => ({ title: x.title, startsAt: x.startsAt, meetName: x.meetName, publicUrl: x.publicSignup ? `/rides/${x.slug}` : null }));
      clubs.push({
        operatorId: op.operatorId, crewId: crew.crewId, name: op.name, type: op.type, typeLabel: OP.TYPES[op.type], city: op.city, members: crew.memberCount || 0,
        role: op.ownerId === uid ? 'OWNER' : (op.coOrganisers || []).includes(uid) ? 'CO_ORGANISER' : 'MEMBER', joinedAt: m.joinedAt,
        status: OP.effectiveStatus(op), broadcasts: latest, upcoming,
      });
    }
    const invites = [];
    for (const inv of await CR.invitesFor(soda, uid)) {
      const crew = await CR.getCrew(soda, inv.crewId);
      if (!crew || !crew.club) continue;
      const op = await OP.getOperator(soda, crew.club.operatorId);
      if (!op || OP.effectiveStatus(op) !== OP.STATUS.APPROVED) continue;
      invites.push({ requestType: 'OPERATOR_INVITE', inviteId: inv.inviteId, crewId: crew.crewId, operatorId: op.operatorId, name: op.name, type: op.type, typeLabel: OP.TYPES[op.type], city: op.city, createdAt: inv.createdAt, expiresAt: inv.expiresAt });
    }
    res.json({ clubs: clubs.sort((a, b) => a.name.localeCompare(b.name)), invites, privacy: 'Clubs see your username and first name, and your live position only during their rides. Your phone, e-mail and medical ID stay private (an emergency contact is shown to the organiser only while you have an open SOS in their ride).' });
  }));
  const answerClub = (yes) => wrap(async (req, res) => {
    const found = await clubInvite(String(req.params.inviteId || ''), req.user.userId);
    if (!found) return res.status(404).json({ error: 'This invite is no longer waiting.', code: 'NOT_FOUND' });
    let out;
    try { out = await CR.respondInvite(soda, req.user.userId, found.invite.inviteId, yes); } catch (e) { return fail(res, e); }
    if (!out) return res.status(404).json({ error: 'This invite is no longer waiting.', code: 'NOT_FOUND' });
    res.json({ ok: true, status: out.status, operatorId: found.crew.club.operatorId });
  });
  r.post('/clubs/invites/:inviteId/accept', authed, feature, writeLimiter, answerClub(true));
  r.post('/clubs/invites/:inviteId/decline', authed, feature, writeLimiter, answerClub(false));
  r.post('/clubs/join', authed, feature, writeLimiter, wrap(async (req, res) => {
    const op = await OP.operatorByInviteCode(soda, String((req.body && req.body.code) || ''));
    if (!op || OP.effectiveStatus(op) !== OP.STATUS.APPROVED) return res.status(404).json({ error: 'This club link does not work any more.', code: 'LINK_GONE' });
    if (await F.blockedEither(soda, op.ownerId, req.user.userId)) return res.status(404).json({ error: 'This club link does not work any more.', code: 'LINK_GONE' });
    let out;
    try { out = await OP.joinByLink(soda, op, req.user.userId); } catch (e) { return fail(res, e); }
    res.status(out.status === 'JOINED' ? 201 : 200).json({ status: out.status, operatorId: op.operatorId, name: op.name });
  }));
  r.post('/clubs/:operatorId/leave', authed, feature, writeLimiter, wrap(async (req, res) => {
    const op = await OP.getOperator(soda, String(req.params.operatorId || ''));
    const crew = op && op.crewId ? await CR.getCrew(soda, op.crewId) : null;
    if (!crew || !(await CR.memberOf(soda, crew.crewId, req.user.userId))) return res.status(404).json({ error: 'You are not in this club.', code: 'NOT_A_MEMBER' });
    if (op.ownerId === req.user.userId) return res.status(409).json({ error: 'The account owner cannot leave its own club.', code: 'CLUB_MANAGED' });
    await CR.leaveCrew(soda, crew, req.user.userId);
    if ((op.coOrganisers || []).includes(req.user.userId)) await OP.saveOperator(soda, { ...op, coOrganisers: op.coOrganisers.filter((x) => x !== req.user.userId) });
    res.json({ ok: true, left: true });
  }));
  r.get('/clubs/:operatorId/broadcasts', authed, feature, readLimiter, wrap(async (req, res) => {
    const op = await OP.getOperator(soda, String(req.params.operatorId || ''));
    if (!op || !op.crewId || !(await CR.memberOf(soda, op.crewId, req.user.userId))) return res.status(404).json({ error: 'You are not in this club.', code: 'NOT_A_MEMBER' });
    res.json({ broadcasts: (await OP.broadcastsOf(soda, op.operatorId, 50)).map((b) => ({ title: b.title, body: b.body, at: b.at })) });
  }));

  // ---- public sign-up (signed in) ----
  r.post('/rides/:slug/signup', authed, feature, signupLimiter, wrap(async (req, res) => {
    const found = await publicRide(String(req.params.slug || ''));
    if (!found) return res.status(404).json(RIDE_NOT_FOUND);
    if (OP.effectiveStatus(found.op) !== OP.STATUS.APPROVED) return res.status(409).json({ error: 'Sign-up for this ride is closed.', code: 'SIGNUP_CLOSED' });
    if (await F.blockedEither(soda, found.op.ownerId, req.user.userId)) return res.status(404).json(RIDE_NOT_FOUND);
    let out;
    try { out = await OP.signUp(soda, found.ride, req.user.userId); } catch (e) { return fail(res, e); }
    if (!out.already) {
      for (const id of [found.op.ownerId, ...(found.op.coOrganisers || [])]) socket(id, { type: 'OPERATOR_SIGNUP', operatorId: found.op.operatorId, rideId: found.ride.rideId, status: out.signup.status });
    }
    res.status(out.already ? 200 : 201).json({ status: out.signup.status, ride: await publicRideView(out.ride, found.op) });
  }));
  r.delete('/rides/:slug/signup', authed, feature, writeLimiter, wrap(async (req, res) => {
    const found = await publicRide(String(req.params.slug || ''));
    if (!found) return res.status(404).json(RIDE_NOT_FOUND);
    const next = await OP.cancelSignup(soda, found.ride, req.user.userId);
    res.json({ ok: true, ride: await publicRideView(next, found.op) });
  }));
  r.get('/rides/:slug/me', authed, feature, readLimiter, wrap(async (req, res) => {
    const found = await publicRide(String(req.params.slug || ''));
    if (!found) return res.status(404).json(RIDE_NOT_FOUND);
    const s = (found.ride.signups || []).find((x) => x.userId === req.user.userId);
    const status = s ? s.status : null;
    let join = null;
    // Approved riders get the join code once the ride is live (normal join rules and seats apply).
    if (status === 'APPROVED' && found.ride.status === OP.RIDE_STATUS.LIVE) {
      const meta = await metaOf(found.ride.groupId);
      if (meta && ACTIVE.includes(meta.tripStatus)) join = { code: meta.joinCode, url: `${originOf(req)}/join/${meta.joinCode}` };
    }
    res.json({ status, join, ride: await publicRideView(found.ride, found.op) });
  }));

  app.use('/api', r);
  return { router: r, attendanceOf };
}

module.exports = { attachOperators, CONSOLE_CSP, SITE_FILES, csvCell };
