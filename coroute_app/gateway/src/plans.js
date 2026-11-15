'use strict';
/**
 * v3.60 admin "Features by plan" (docs/features_355/communities_chat_v360.md, section Plans).
 *
 * The master admin decides, per plan (Community = free, Small Group, Large Group), which community and chat
 * features a rider gets and a few limits. It is a different thing from:
 *   - feature_flags.js: a kill switch that turns a feature off for everyone (it still wins: off is off);
 *   - entitlements.js: ride seats come from the plan as before (not editable here).
 * Safety (SOS, crash alarm, emergency texts, Medical ID, guardians, ride lock...) is NOT in this catalog: it can
 * never be put behind a plan.
 *
 * Storage: one document in subscription_config (k='plan_features'), read through a 30 s cache per repo.
 * Missing / unknown values fall back to the defaults: plan features off on Community (free), on for the group plans
 * (owner decision 15 Nov 2026); limits as before v3.60.
 *
 * forRepo(repo) -> { config(), planIdOf(userId), featureFor(userId, id), limitFor(userId, id), effectiveFor(userId) }
 * registerPlanRoutes({ r, repo, wrap, requireAdmin }):
 *   GET  /me/plan-features             the rider's plan, features and limits (the app hides what is off)
 *   GET  /admin/plan-features          catalog + current matrix
 *   PUT  /admin/plan-features          { plans: { community: { features:{}, limits:{} }, ... } } (audited)
 */
const rateLimit = require('express-rate-limit');
const { COLLECTIONS: C } = require('./oracle/repo');

const DOC_KEY = 'plan_features';
const PLAN_IDS = Object.freeze(['community', 'group_small', 'group_large']);
const PLAN_NAMES = Object.freeze({ community: 'Community (free)', group_small: 'Small Group', group_large: 'Large Group' });

/** Features an admin may put behind a plan. Never safety. */
const FEATURES = Object.freeze([
  { id: 'createCommunity', label: 'Create communities', desc: 'Start a new community (joining others is always free).' },
  { id: 'communityRides', label: 'Host community rides', desc: 'Plan rides in a community; members answer Interested or Not interested.' },
  { id: 'crewPolls', label: 'Community polls', desc: 'Ask the community a question with fixed options.' },
  { id: 'communityChat', label: 'Community chat', desc: 'Text chat inside a community.' },
  { id: 'friendChat', label: 'Chat with friends', desc: 'One-to-one text chat with friends.' },
  { id: 'exploreRoutes', label: 'Share routes on Explore', desc: 'Share a ridden route to guide other riders.' },
]);
/** Numbers per plan. min / max bound what the admin can store. */
const LIMITS = Object.freeze([
  { id: 'communitiesOwnedMax', label: 'Communities a rider can run', min: 0, max: 10 },
  { id: 'communityMembersMax', label: 'Members per community', min: 2, max: 100 },
  { id: 'chatMembersMax', label: 'Community chat: largest community with chat', min: 2, max: 100 },
  { id: 'upcomingRidesMax', label: 'Planned community rides at a time', min: 1, max: 10 },
]);
const DEFAULT_LIMITS = Object.freeze({
  community: { communitiesOwnedMax: 10, communityMembersMax: 100, chatMembersMax: 50, upcomingRidesMax: 10 },
  group_small: { communitiesOwnedMax: 10, communityMembersMax: 100, chatMembersMax: 50, upcomingRidesMax: 10 },
  group_large: { communitiesOwnedMax: 10, communityMembersMax: 100, chatMembersMax: 50, upcomingRidesMax: 10 },
});
const FEATURE_IDS = FEATURES.map((f) => f.id);
/**
 * v3.60 owner decision (15 Nov 2026): safety is free for everyone; the features in this list are plan features.
 * Default: off on Community (free), on for Small Group and Large Group. The admin can change any of them.
 */
const DEFAULT_FEATURES = Object.freeze({
  community: Object.freeze(Object.fromEntries(FEATURE_IDS.map((id) => [id, false]))),
  group_small: Object.freeze(Object.fromEntries(FEATURE_IDS.map((id) => [id, true]))),
  group_large: Object.freeze(Object.fromEntries(FEATURE_IDS.map((id) => [id, true]))),
});
const LIMIT_BY_ID = Object.fromEntries(LIMITS.map((l) => [l.id, l]));

class PlanConfigError extends Error {
  constructor(message, field) { super(message); this.status = 400; this.code = 'BAD_PLAN_CONFIG'; this.field = field; }
}

/** The full matrix from a stored value (anything missing or invalid = default). */
function cleanConfig(raw) {
  const out = {};
  for (const p of PLAN_IDS) {
    const src = raw && raw.plans && raw.plans[p] ? raw.plans[p] : {};
    const features = {};
    for (const id of FEATURE_IDS) features[id] = src.features && typeof src.features[id] === 'boolean' ? src.features[id] : DEFAULT_FEATURES[p][id];
    const limits = {};
    for (const l of LIMITS) {
      const v = src.limits ? src.limits[l.id] : undefined;
      limits[l.id] = Number.isInteger(v) && v >= l.min && v <= l.max ? v : DEFAULT_LIMITS[p][l.id];
    }
    out[p] = { features, limits };
  }
  return { plans: out };
}

/** Strict check of an admin PUT body; returns the clean matrix or throws PlanConfigError. */
function validateConfig(body) {
  const b = body && typeof body === 'object' ? body : {};
  if (!b.plans || typeof b.plans !== 'object') throw new PlanConfigError('Send plans.', 'plans');
  for (const [p, v] of Object.entries(b.plans)) {
    if (!PLAN_IDS.includes(p)) throw new PlanConfigError(`Unknown plan ${p}.`, 'plans');
    for (const [id, on] of Object.entries((v && v.features) || {})) {
      if (!FEATURE_IDS.includes(id)) throw new PlanConfigError(`Unknown feature ${id}.`, `${p}.features`);
      if (typeof on !== 'boolean') throw new PlanConfigError(`${id} must be on or off.`, `${p}.features.${id}`);
    }
    for (const [id, n] of Object.entries((v && v.limits) || {})) {
      const l = LIMIT_BY_ID[id];
      if (!l) throw new PlanConfigError(`Unknown limit ${id}.`, `${p}.limits`);
      if (!Number.isInteger(n) || n < l.min || n > l.max) throw new PlanConfigError(`${l.label}: ${l.min} to ${l.max}.`, `${p}.limits.${id}`);
    }
  }
  return cleanConfig(b);
}

/** 'community' | 'group_small' | 'group_large' for a resolved plan (legacy tiers map by seats). */
function planIdFromPlan(plan) {
  if (!plan) return 'community';
  if (PLAN_IDS.includes(plan.category)) return plan.category;
  const seats = Number(plan.seats) || 1;
  return seats >= 7 ? 'group_large' : seats >= 2 ? 'group_small' : 'community';
}

const TTL_MS = 30000;
const cache = new WeakMap();

function forRepo(repo) {
  const soda = repo.soda;
  let state = cache.get(soda);
  if (!state) { state = { at: 0, cfg: cleanConfig(null) }; cache.set(soda, state); }
  const api = {
    async config() {
      if (Date.now() - state.at < TTL_MS) return state.cfg;
      try {
        const r = await soda.findOne(C.subscriptionConfig, { k: DOC_KEY });
        state.cfg = cleanConfig(r ? r.value : null);
        state.at = Date.now();
      } catch { /* keep the last known matrix */ }
      return state.cfg;
    },
    async save(next, by) {
      await soda.upsertBy(C.subscriptionConfig, { k: DOC_KEY }, { k: DOC_KEY, ...next, updatedAt: Date.now(), updatedBy: String(by || 'admin').slice(0, 120) });
      state.cfg = cleanConfig(next); state.at = Date.now();
      return state.cfg;
    },
    async planIdOf(userId) {
      // With payments off nothing is gated: everyone gets the biggest plan's features.
      if (require('./config').paymentsEnabled === false) return 'group_large';
      const plan = await require('./entitlements').resolvePlan(repo, userId).catch(() => null);
      return planIdFromPlan(plan);
    },
    async effectiveFor(userId) {
      const planId = await api.planIdOf(userId);
      const cfg = await api.config();
      return { planId, planName: PLAN_NAMES[planId], ...cfg.plans[planId] };
    },
    async featureFor(userId, id) {
      if (!FEATURE_IDS.includes(id)) return true;
      return (await api.effectiveFor(userId)).features[id] !== false;
    },
    async limitFor(userId, id) {
      if (!LIMIT_BY_ID[id]) return null;
      return (await api.effectiveFor(userId)).limits[id];
    },
    _reset() { state.at = 0; },
  };
  return api;
}

/** 403 PLAN_FEATURE answer for a feature the rider's plan does not include. */
const PLAN_OFF = (label) => ({ error: `${label} is not included in your plan.`, code: 'PLAN_FEATURE' });

function registerPlanRoutes({ r, repo, wrap, requireAdmin }) {
  const plans = forRepo(repo);
  const adminLimit = rateLimit({ windowMs: 60 * 1000, limit: 30, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `pf:${req.user ? req.user.userId : req.ip}` });
  r.get('/me/plan-features', wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store').json({ ok: true, ...(await plans.effectiveFor(req.user.userId)) });
  }));
  r.get('/admin/plan-features', requireAdmin, wrap(async (req, res) => {
    res.set('Cache-Control', 'no-store').json({ ok: true, planIds: PLAN_IDS, planNames: PLAN_NAMES, features: FEATURES, limits: LIMITS, ...(await plans.config()) });
  }));
  r.put('/admin/plan-features', requireAdmin, adminLimit, wrap(async (req, res) => {
    let next;
    try { next = validateConfig(req.body); } catch (e) { if (e instanceof PlanConfigError) return res.status(400).json({ error: e.message, code: e.code, field: e.field }); throw e; }
    const by = (req.user && (req.user.email || req.user.userId)) || 'admin';
    const saved = await plans.save(next, by);
    if (typeof repo.addAuditEntry === 'function') {
      const off = {};
      for (const p of PLAN_IDS) off[p] = FEATURE_IDS.filter((id) => !saved.plans[p].features[id]);
      await repo.addAuditEntry({ by, byUserId: req.user ? req.user.userId : null, action: 'plans.features.update', target: 'plan_features', details: { off, limits: Object.fromEntries(PLAN_IDS.map((p) => [p, saved.plans[p].limits])) }, at: Date.now() }).catch(() => {});
    }
    res.json({ ok: true, ...saved });
  }));
}

module.exports = { DOC_KEY, DEFAULT_FEATURES, PLAN_IDS, PLAN_NAMES, FEATURES, LIMITS, DEFAULT_LIMITS, cleanConfig, validateConfig, planIdFromPlan, forRepo, registerPlanRoutes, PLAN_OFF, PlanConfigError };
