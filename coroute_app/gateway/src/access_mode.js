'use strict';
/**
 * 3.56 access mode ("monetization mode"): does hosting a group ride need a group plan?
 * Docs: docs/features_355/access_modes.md. Set in the web admin (Plans & pricing > Access mode).
 *
 * Modes:
 *   paid    (default, the behaviour before 3.56) hosting a group ride needs a group plan bought on the
 *           website; Community hosts solo rides (entitlements.js).
 *   free    "free for everyone": every rider hosts group rides with every group feature, up to
 *           free.maxRiders riders (default 12, host included); no plan checks anywhere. Paid plans
 *           keep running untouched (a host's plan seats count when they are higher); nothing is refunded.
 *   hybrid  "free up to limits": a rider without a group plan hosts group rides of at most
 *           hybrid.maxRiders riders, at most hybrid.maxHostedRidesPerMonth group rides per India
 *           calendar month, with only the group features in hybrid.freeFeatures. Beyond that a plan is
 *           needed (website). A rider with a group plan has their plan (never less than the free limit).
 *
 * Optional schedule: { at, mode } switches to `mode` at `at` (epoch ms; the admin enters India time),
 * e.g. a free launch period that ends on a date and reverts to paid. The switch is computed (pure,
 * effectiveDoc), so it happens on time on both nodes even without a write; the next admin save stores it.
 *
 * Single source of truth: this module (server). The app gets only the resulting capabilities
 * (GET /api/me/capabilities, also `capabilities` in GET /api/membership/my): canHostGroup, maxRiders,
 * groupFeatures ('all' or a list of feature ids), hostedRidesLeft, reason code, gated, version.
 * Never a price, a plan price or a mode name with money in it (tests check the payload keys).
 *
 * Storage: one document in subscription_config (k='access_mode') with a version number and the last
 * 50 changes; every save is also an admin audit entry. Both gateway nodes re-read it every 30 s and a
 * save pokes the other node over the mirror (extension 'am', a poke only: the DB is the truth). A
 * change of the effective mode (a save or the schedule boundary) emits 'change': app.js pushes
 * CAPABILITIES_CHANGED to every connected app and refreshes the seats of live rides (never shrinks one).
 *
 * Hosted group rides per month (hybrid): counted when the first other rider joins a ride hosted on the
 * free tier (collection hosted_ride_counts, key "<userId>:<YYYY-MM>" in India time).
 */
const { EventEmitter } = require('events');
const { COLLECTIONS: C } = require('./oracle/repo');
const { clampSeats, resolvePlan } = require('./entitlements');

const DOC_KEY = 'access_mode';
const COUNT_COLLECTION = 'hosted_ride_counts';
const HISTORY_MAX = 50;
const MODES = Object.freeze(['paid', 'free', 'hybrid']);
const IST_MS = 330 * 60000;
const MAX_SCHEDULE_AHEAD = 366 * 86400000;

/**
 * Group features a hybrid free tier can include or leave out (ids of the feature switch catalog,
 * feature_flags.js). Safety features (missing-rider check, stretch alert, buddy pairs, roll call,
 * SOS ...) are never in this list: they are never gated. Messages and regroup come with every group ride.
 */
const GATABLE_GROUP_FEATURES = Object.freeze([
  Object.freeze({ id: 'intercom', label: 'Group talk (push-to-talk)' }),
  Object.freeze({ id: 'rideRoles', label: 'Riding roles (lead, sweep, swaps)' }),
  Object.freeze({ id: 'autoRoles', label: 'Automatic roles' }),
  Object.freeze({ id: 'crewRides', label: 'Start a ride with a crew' }),
  Object.freeze({ id: 'groupFuel', label: 'Group fuel stop' }),
  Object.freeze({ id: 'regroupSuggest', label: 'Smart regroup point' }),
  Object.freeze({ id: 'publicRide', label: 'Public ride' }),
  Object.freeze({ id: 'discovery', label: 'Nearby groups' }),
  Object.freeze({ id: 'vehicleSwap', label: 'Bike swap' }),
]);
const GATABLE_IDS = Object.freeze(GATABLE_GROUP_FEATURES.map((f) => f.id));

const DEFAULTS = Object.freeze({
  mode: 'paid',
  free: Object.freeze({ maxRiders: 12 }),
  hybrid: Object.freeze({ maxRiders: 6, maxHostedRidesPerMonth: 8, freeFeatures: GATABLE_IDS }),
  schedule: null,
});

/** Refusal codes the app maps to neutral words (lib/domain/membership/plan_gate_messages.dart). */
const REASONS = Object.freeze({
  GROUP_PLAN_REQUIRED: 'GROUP_PLAN_REQUIRED',
  HOSTED_RIDES_LIMIT: 'HOSTED_RIDES_LIMIT',
  GROUP_FEATURE_LOCKED: 'GROUP_FEATURE_LOCKED',
});
const GROUP_FEATURE_LOCKED_MESSAGE = "This isn't included in this ride.";

class AccessModeError extends Error {
  constructor(message, code = 'BAD_ACCESS_MODE', status = 400) { super(message); this.code = code; this.statusCode = status; }
}

const int = (v) => Math.floor(Number(v));

/** "YYYY-MM" of `now` in India time (the monthly hosting limit resets on the 1st, 00:00 IST). */
function istMonth(now = Date.now()) { return new Date(now + IST_MS).toISOString().slice(0, 7); }

/**
 * Epoch ms of an India-time "YYYY-MM-DDTHH:MM" (seconds optional), or NaN. A number passes through.
 * "2026-12-01T00:00" -> 2026-11-30T18:30:00Z.
 */
function parseIst(v) {
  if (typeof v === 'number') return Number.isFinite(v) ? v : NaN;
  const m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(String(v || '').trim());
  if (!m) return NaN;
  const [y, mo, d, h, mi, s] = m.slice(1).map((x) => Number(x || 0));
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59) return NaN;
  const utc = Date.UTC(y, mo - 1, d, h, mi, s);
  if (new Date(utc).getUTCDate() !== d) return NaN; // 31 Feb
  return utc - IST_MS;
}

/** "01 Dec 2026, 00:00 IST" */
function istLabel(ms) {
  if (!Number.isFinite(Number(ms)) || !ms) return '';
  const s = new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false, timeZone: 'Asia/Kolkata' }).format(new Date(Number(ms)));
  return `${s} IST`;
}

/** A clean stored document (unknown fields dropped, numbers clamped to sane ranges). Pure. */
function cleanDoc(raw) {
  const d = raw && typeof raw === 'object' ? raw : {};
  const mode = MODES.includes(d.mode) ? d.mode : DEFAULTS.mode;
  const f = d.free && typeof d.free === 'object' ? d.free : {};
  const hy = d.hybrid && typeof d.hybrid === 'object' ? d.hybrid : {};
  const range = (v, lo, hi, dflt) => { const n = int(v); return Number.isFinite(n) && n >= lo && n <= hi ? n : dflt; };
  const features = Array.isArray(hy.freeFeatures) ? [...new Set(hy.freeFeatures.filter((x) => GATABLE_IDS.includes(x)))] : [...DEFAULTS.hybrid.freeFeatures];
  let schedule = null;
  if (d.schedule && typeof d.schedule === 'object' && MODES.includes(d.schedule.mode) && Number(d.schedule.at) > 0) {
    schedule = { at: Number(d.schedule.at), mode: d.schedule.mode };
  }
  return {
    mode,
    free: { maxRiders: range(f.maxRiders, 2, 1000, DEFAULTS.free.maxRiders) },
    hybrid: {
      maxRiders: range(hy.maxRiders, 2, 1000, DEFAULTS.hybrid.maxRiders),
      maxHostedRidesPerMonth: range(hy.maxHostedRidesPerMonth, 0, 1000, DEFAULTS.hybrid.maxHostedRidesPerMonth),
      freeFeatures: features,
    },
    schedule,
  };
}

/**
 * The settings in force at `now`: a schedule whose time has come replaces the mode (pure).
 * @returns {{mode, free, hybrid, schedule, scheduleApplied: boolean}}
 */
function effectiveDoc(raw, now = Date.now()) {
  const d = cleanDoc(raw);
  if (d.schedule && now >= d.schedule.at) return { ...d, mode: d.schedule.mode, schedule: null, scheduleApplied: true };
  return { ...d, scheduleApplied: false };
}

/**
 * Pure: the rider's hosting capabilities from their plan (entitlements.planFrom / resolvePlan), the
 * effective settings and their hosted group rides this month. Never carries a price.
 * @returns {{gated, canHostGroup, maxRiders, groupFeatures: 'all'|string[], hostedRidesLeft: number|null,
 *            hostedRidesLimit: number|null, reason: string|null, freeTier: boolean}}
 */
function capabilitiesFor({ plan, settings, hostedThisMonth = 0, paymentsEnabled = true }) {
  const p = plan || { seats: 1, canHostGroup: false };
  const planSeats = p.canHostGroup ? clampSeats(p.seats) : 0;
  const s = settings || effectiveDoc(null);
  const all = { groupFeatures: 'all', hostedRidesLeft: null, hostedRidesLimit: null, reason: null, freeTier: false };
  if (paymentsEnabled === false) {
    // Server run without payments (PAYMENTS_ENABLED=false): nothing is gated, the seats are the ceiling.
    return { ...all, gated: false, canHostGroup: true, maxRiders: clampSeats(Number.MAX_SAFE_INTEGER) };
  }
  if (s.mode === 'free') {
    return { ...all, gated: false, canHostGroup: true, maxRiders: clampSeats(Math.max(planSeats, s.free.maxRiders)) };
  }
  if (s.mode === 'hybrid') {
    if (p.canHostGroup) return { ...all, gated: true, canHostGroup: true, maxRiders: clampSeats(Math.max(planSeats, s.hybrid.maxRiders)) };
    const limit = s.hybrid.maxHostedRidesPerMonth;
    const left = Math.max(0, limit - Math.max(0, int(hostedThisMonth) || 0));
    if (left > 0) {
      return { gated: true, canHostGroup: true, maxRiders: clampSeats(s.hybrid.maxRiders), groupFeatures: [...s.hybrid.freeFeatures],
        hostedRidesLeft: left, hostedRidesLimit: limit, reason: null, freeTier: true };
    }
    return { gated: true, canHostGroup: false, maxRiders: 1, groupFeatures: [], hostedRidesLeft: 0, hostedRidesLimit: limit,
      reason: REASONS.HOSTED_RIDES_LIMIT, freeTier: false };
  }
  // paid
  if (p.canHostGroup) return { ...all, gated: true, canHostGroup: true, maxRiders: planSeats };
  return { ...all, gated: true, canHostGroup: false, maxRiders: 1, groupFeatures: [], reason: REASONS.GROUP_PLAN_REQUIRED };
}

/** The app's capability payload (GET /api/me/capabilities): no prices, no plan names, no mode internals. */
function appPayload(caps, version = 0) {
  return {
    gated: !!caps.gated,
    canHostGroup: !!caps.canHostGroup,
    maxRiders: caps.maxRiders,
    groupFeatures: caps.groupFeatures === 'all' ? 'all' : [...caps.groupFeatures],
    hostedRidesLeft: caps.hostedRidesLeft,
    hostedRidesLimit: caps.hostedRidesLimit,
    reason: caps.reason,
    version,
  };
}

/** The first id of `ids` a ride with `groupFeatures` (null/'all' = every feature) leaves out, or null. */
function lockedFeature(groupFeatures, ids) {
  if (!Array.isArray(groupFeatures) || !ids || !ids.length) return null;
  for (const id of ids) if (GATABLE_IDS.includes(id) && !groupFeatures.includes(id)) return id;
  return null;
}

/**
 * Validates an admin update (partial: only the given parts change). Returns the next clean document.
 * Throws AccessModeError with a plain message.
 */
function validateUpdate(current, body, now = Date.now()) {
  const b = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  const next = cleanDoc(effectiveDoc(current, now).scheduleApplied ? { ...current, mode: current.schedule.mode, schedule: null } : current);
  if (b.mode !== undefined) {
    if (!MODES.includes(b.mode)) throw new AccessModeError('Choose a mode: paid, free or hybrid.', 'BAD_MODE');
    next.mode = b.mode;
  }
  const num = (v, lo, hi, label) => {
    const n = Number(v);
    if (!Number.isInteger(n) || n < lo || n > hi) throw new AccessModeError(`${label} must be a whole number from ${lo} to ${hi}.`, 'BAD_LIMIT');
    return n;
  };
  if (b.free !== undefined) {
    if (!b.free || typeof b.free !== 'object') throw new AccessModeError('free must be an object.', 'BAD_LIMIT');
    if (b.free.maxRiders !== undefined) next.free.maxRiders = num(b.free.maxRiders, 2, 1000, 'Riders per ride (free)');
  }
  if (b.hybrid !== undefined) {
    const h = b.hybrid;
    if (!h || typeof h !== 'object') throw new AccessModeError('hybrid must be an object.', 'BAD_LIMIT');
    if (h.maxRiders !== undefined) next.hybrid.maxRiders = num(h.maxRiders, 2, 1000, 'Riders per free group ride');
    if (h.maxHostedRidesPerMonth !== undefined) next.hybrid.maxHostedRidesPerMonth = num(h.maxHostedRidesPerMonth, 0, 1000, 'Free group rides per month');
    if (h.freeFeatures !== undefined) {
      if (!Array.isArray(h.freeFeatures)) throw new AccessModeError('freeFeatures must be a list of feature ids.', 'BAD_FEATURES');
      const bad = h.freeFeatures.find((x) => !GATABLE_IDS.includes(x));
      if (bad !== undefined) throw new AccessModeError(`Unknown group feature "${String(bad).slice(0, 40)}".`, 'BAD_FEATURES');
      next.hybrid.freeFeatures = [...new Set(h.freeFeatures)];
    }
  }
  if (b.schedule !== undefined) {
    if (b.schedule === null) next.schedule = null;
    else {
      const s = b.schedule;
      if (!s || typeof s !== 'object' || !MODES.includes(s.mode)) throw new AccessModeError('A schedule needs a mode: paid, free or hybrid.', 'BAD_SCHEDULE');
      const at = s.atIst !== undefined ? parseIst(s.atIst) : Number(s.at);
      if (!Number.isFinite(at) || at <= 0) throw new AccessModeError('Enter the date and time of the change in India time (YYYY-MM-DDTHH:MM).', 'BAD_SCHEDULE');
      if (at <= now) throw new AccessModeError('The scheduled change must be in the future.', 'BAD_SCHEDULE');
      if (at > now + MAX_SCHEDULE_AHEAD) throw new AccessModeError('Schedule at most a year ahead.', 'BAD_SCHEDULE');
      if (s.mode === next.mode) throw new AccessModeError('The scheduled mode is the same as the current mode.', 'BAD_SCHEDULE');
      next.schedule = { at, mode: s.mode };
    }
  }
  return next;
}

class AccessMode extends EventEmitter {
  constructor({ repo = null, soda = null, logger = console, refreshMs = 30000, tickMs = 15000, clock = Date.now, paymentsEnabled } = {}) {
    super();
    this.repo = repo;
    this.soda = soda || (repo && repo.soda) || null;
    this.log = logger;
    this.refreshMs = Math.max(1000, refreshMs);
    this.tickMs = Math.max(1000, tickMs);
    this.clock = clock;
    this._paymentsEnabled = paymentsEnabled;
    this.doc = cleanDoc(null);
    this.version = 0;
    this.updatedAt = 0;
    this.updatedBy = null;
    this.history = [];
    this.timers = [];
    this.mirror = null; // Mirror.register('am', this)
    this._lastKey = this._effectiveKey();
    this._countsReady = null;
  }

  paymentsEnabled() {
    if (this._paymentsEnabled !== undefined) return this._paymentsEnabled !== false;
    return require('./config').paymentsEnabled !== false;
  }

  /** The settings in force now. */
  effective(now = this.clock()) { return effectiveDoc(this.doc, now); }
  /** True while every rider hosts group rides without a plan ('free' mode, or payments off). */
  isFreeForAll(now = this.clock()) { return !this.paymentsEnabled() || this.effective(now).mode === 'free'; }
  mode(now = this.clock()) { return this.effective(now).mode; }

  _effectiveKey(now = this.clock()) {
    const e = effectiveDoc(this.doc, now);
    return JSON.stringify([e.mode, e.free, e.hybrid]);
  }

  /** Emits 'change' when what riders get moved (a save, a re-read, or the schedule boundary). */
  _maybeEmit(reason) {
    const key = this._effectiveKey();
    if (key === this._lastKey) return false;
    this._lastKey = key;
    const e = this.effective();
    this.emit('change', { version: this.version, mode: e.mode, reason });
    return true;
  }

  _apply(stored) {
    this.doc = cleanDoc(stored);
    this.version = Number(stored && stored.version) || 0;
    this.updatedAt = Number(stored && stored.updatedAt) || 0;
    this.updatedBy = (stored && stored.updatedBy) || null;
    this.history = Array.isArray(stored && stored.history) ? stored.history.slice(-HISTORY_MAX) : [];
  }

  async _read() {
    if (!this.soda) return null;
    const r = await this.soda.findOne(C.subscriptionConfig, { k: DOC_KEY });
    return r ? r.value : null;
  }

  /** Re-reads the document; on a read error the last known state stays. */
  async refresh() {
    try {
      const d = await this._read();
      if (d) this._apply(d);
      this._maybeEmit('refresh');
    } catch (e) {
      this.log.warn?.(`[access-mode] refresh failed, keeping last known state: ${e.message}`);
    }
  }

  /** The schedule boundary check (every tickMs): a scheduled change takes effect on time. */
  tick() { return this._maybeEmit('schedule'); }

  start() {
    if (this.timers.length) return this;
    const a = setInterval(() => { this.refresh(); }, this.refreshMs);
    const b = setInterval(() => { this.tick(); }, this.tickMs);
    for (const t of [a, b]) if (t.unref) t.unref();
    this.timers = [a, b];
    return this;
  }
  stop() { for (const t of this.timers) clearInterval(t); this.timers = []; }

  /** Admin update (validated, versioned, history). Read-modify-write on the freshest document. */
  async set(body, { by = 'admin', byUserId = null, reason = '' } = {}) {
    if (!this.soda) throw new AccessModeError('Access mode is not available.', 'UNAVAILABLE', 503);
    const why = typeof reason === 'string' ? reason.replace(/[\u0000-\u001f\u007f]+/g, ' ').trim().slice(0, 200) : '';
    const stored = (await this._read()) || {};
    const now = this.clock();
    const before = cleanDoc(stored);
    const next = validateUpdate(stored, body, now);
    if (b(body).expectedVersion !== undefined && Number(b(body).expectedVersion) !== (Number(stored.version) || 0)) {
      throw new AccessModeError('Someone else changed the access mode. Reload and try again.', 'VERSION_CONFLICT', 409);
    }
    const version = (Number(stored.version) || 0) + 1;
    const history = Array.isArray(stored.history) ? stored.history.slice(-(HISTORY_MAX - 1)) : [];
    const entry = { version, at: now, by: String(by).slice(0, 120), reason: why, before, after: next };
    history.push(entry);
    const doc = { k: DOC_KEY, ...next, version, updatedAt: now, updatedBy: String(by).slice(0, 120), updatedByUserId: byUserId, history };
    await this.soda.upsertBy(C.subscriptionConfig, { k: DOC_KEY }, doc);
    this._apply(doc);
    this._maybeEmit('admin');
    try { if (this.mirror) this.mirror.ext('am', { op: 'REFRESH', version }); } catch { /* the 30 s re-read converges */ }
    return { entry, view: this.adminView() };
  }

  adminView() {
    const now = this.clock();
    const e = this.effective(now);
    return {
      ok: true,
      stored: { ...this.doc },
      effective: { mode: e.mode, free: e.free, hybrid: e.hybrid, scheduleApplied: e.scheduleApplied },
      schedule: this.doc.schedule && !e.scheduleApplied ? { ...this.doc.schedule, atIst: istLabel(this.doc.schedule.at) } : null,
      version: this.version,
      updatedAt: this.updatedAt,
      updatedBy: this.updatedBy,
      paymentsEnabled: this.paymentsEnabled(),
      modes: MODES,
      features: GATABLE_GROUP_FEATURES,
      defaults: DEFAULTS,
      history: [...this.history].reverse().slice(0, 20),
    };
  }

  /** What the public website may know (GET /api/public/access): mode and the free limits, no rider data. */
  publicView() {
    const e = this.effective();
    const mode = this.paymentsEnabled() ? e.mode : 'free';
    const out = { mode, checkout: mode !== 'free' };
    if (mode === 'free') out.free = { maxRiders: clampSeats(e.free.maxRiders) };
    if (mode === 'hybrid') out.hybrid = { maxRiders: clampSeats(e.hybrid.maxRiders), maxHostedRidesPerMonth: e.hybrid.maxHostedRidesPerMonth };
    if (this.doc.schedule && !e.scheduleApplied) out.changesAt = this.doc.schedule.at;
    if (this.doc.schedule && !e.scheduleApplied) out.nextMode = this.doc.schedule.mode;
    return out;
  }

  // ---- hosted group rides per month (hybrid free tier) ----
  async _counts() {
    if (!this.soda) return false;
    if (!this._countsReady) {
      this._countsReady = (async () => {
        await this.soda.ensureCollection(COUNT_COLLECTION);
        await this.soda.ensureIndex(COUNT_COLLECTION, { name: `${COUNT_COLLECTION}_key_ux`, unique: true, fields: [{ path: 'key' }] }).catch(() => {});
      })().catch((e) => { this._countsReady = null; throw e; });
    }
    await this._countsReady;
    return true;
  }

  async hostedThisMonth(userId, now = this.clock()) {
    if (!userId || !(await this._counts().catch(() => false))) return 0;
    const row = await this.soda.findOne(COUNT_COLLECTION, { key: `${userId}:${istMonth(now)}` }).catch(() => null);
    return row ? Number(row.value.count) || 0 : 0;
  }

  /** One more hosted free-tier group ride this month (the first other rider joined). */
  async countHostedRide(userId, now = this.clock()) {
    if (!userId || !(await this._counts().catch(() => false))) return 0;
    const month = istMonth(now);
    const key = `${userId}:${month}`;
    for (let i = 0; i < 3; i++) {
      const row = await this.soda.findOne(COUNT_COLLECTION, { key });
      if (!row) {
        try { await this.soda.insert(COUNT_COLLECTION, { key, userId, month, count: 1, updatedAt: now }); return 1; } catch { continue; }
      }
      const next = { ...row.value, count: (Number(row.value.count) || 0) + 1, updatedAt: now };
      if (typeof this.soda.compareAndReplace === 'function') {
        if (await this.soda.compareAndReplace(COUNT_COLLECTION, row.key, row.value, next)) return next.count;
      } else { await this.soda.replace(COUNT_COLLECTION, row.key, next); return next.count; }
    }
    return 0;
  }

  async forgetUser(userId) {
    if (!userId || !(await this._counts().catch(() => false))) return;
    await this.soda.removeWhere(COUNT_COLLECTION, { userId }).catch(() => {});
  }

  /** Capabilities of `userId` now (plan resolved when not given). */
  async capabilitiesOf(userId, { plan = null, now = this.clock() } = {}) {
    const p = plan || (this.repo ? await resolvePlan(this.repo, userId, { now }) : null);
    const settings = this.effective(now);
    const hosted = settings.mode === 'hybrid' && !(p && p.canHostGroup) ? await this.hostedThisMonth(userId, now) : 0;
    return capabilitiesFor({ plan: p, settings, hostedThisMonth: hosted, paymentsEnabled: this.paymentsEnabled() });
  }

  async appCapabilities(userId, opts = {}) { return appPayload(await this.capabilitiesOf(userId, opts), this.version); }

  // ---- mirror extension 'am': a poke only ----
  exportState() { return { version: this.version }; }
  importState() { this.refresh(); }
  applyRemote() { this.refresh(); }
}

function b(body) { return body && typeof body === 'object' ? body : {}; }

/**
 * Routes: GET /api/me/capabilities (rider), GET /api/public/access (website), GET/PUT
 * /api/admin/access-mode (MASTER_ADMIN, audited).
 */
function attachAccessModeRoutes({ app, accessMode, repo, gate }) {
  const express = require('express');
  const rateLimit = require('express-rate-limit');
  const { requireAuth, requireAdmin } = require('./auth');
  const limiter = (limit) => rateLimit({ windowMs: 60 * 1000, limit, standardHeaders: 'draft-7', legacyHeaders: false,
    keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many requests.' } });

  app.get('/api/public/access', limiter(120), (req, res) => {
    res.set('Cache-Control', 'public, max-age=30').json({ ok: true, ...accessMode.publicView() });
  });

  app.get('/api/me/capabilities', requireAuth(gate), limiter(60), async (req, res, next) => {
    try {
      res.set('Cache-Control', 'no-store').json({ ok: true, capabilities: await accessMode.appCapabilities(req.user.userId) });
    } catch (e) { next(e); }
  });

  const r = express.Router();
  r.use((req, res, nx) => { res.set('Cache-Control', 'no-store'); nx(); });
  r.get('/', async (req, res, nx) => { try { await accessMode.refresh(); res.json(accessMode.adminView()); } catch (e) { nx(e); } });
  r.put('/', limiter(30), async (req, res, nx) => {
    try {
      const body = b(req.body);
      const by = req.user?.email || req.user?.userId || 'admin';
      let out;
      try {
        out = await accessMode.set(body, { by, byUserId: req.user?.userId || null, reason: typeof body.reason === 'string' ? body.reason : '' });
      } catch (e) {
        if (e instanceof AccessModeError) return res.status(e.statusCode).json({ error: e.message, code: e.code });
        throw e;
      }
      if (repo && typeof repo.addAuditEntry === 'function') {
        await repo.addAuditEntry({ at: Date.now(), by, byUserId: req.user?.userId || null, action: 'access_mode.update', target: out.entry.after.mode,
          details: { version: out.entry.version, before: out.entry.before, after: out.entry.after, reason: out.entry.reason } }).catch(() => {});
      }
      res.json(out.view);
    } catch (e) { nx(e); }
  });
  app.use('/api/admin/access-mode', requireAuth(gate), requireAdmin, r);

  // Account erase: the hosted-ride counters go with the account.
  if (repo && !repo.__accessCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__accessCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await accessMode.forgetUser(user.userId).catch(() => {});
      return out;
    };
  }
}

module.exports = {
  AccessMode, AccessModeError, attachAccessModeRoutes, capabilitiesFor, appPayload, effectiveDoc, cleanDoc, validateUpdate, lockedFeature,
  parseIst, istMonth, istLabel, MODES, DEFAULTS, GATABLE_GROUP_FEATURES, GATABLE_IDS, REASONS, GROUP_FEATURE_LOCKED_MESSAGE, DOC_KEY, COUNT_COLLECTION,
};
