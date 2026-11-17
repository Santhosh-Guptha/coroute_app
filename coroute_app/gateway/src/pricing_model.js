'use strict';
/**
 * v3.63 pricing model (owner, 17 Nov 2026: "before prod I'll decide which to make"). One switch in the web admin
 * (Configuration > Pricing model) decides which paid plans are SOLD:
 *
 *   group_plans (default, today)  Community (free, solo) + Small Group (2-6) + Large Group (7-12), bought by the host.
 *   rider_pass                    Community (free, solo) + Rider Pass: one rider, every feature, 30 days, ₹9 list price
 *                                 (editable in Plans & pricing like any plan). A Rider Pass holder hosts group rides
 *                                 with any number of riders (up to the server ceiling MAX_CONVOY_RIDERS) and has every
 *                                 plan feature (communities, chat, Explore sharing ...).
 *
 * Unchanged in both models: safety is free for everyone; joining someone's ride is free (inside a ride every rider has
 * the host's group features); an active plan of the other model keeps working until it ends (nothing is cancelled or
 * refunded by switching). Only what can be bought changes.
 *
 * Storage: subscription_config k='pricing_model' {model, updatedAt, updatedBy}; cached 30 s per node.
 * GET /api/admin/pricing-model, PUT /api/admin/pricing-model {model} (MASTER_ADMIN, audited).
 */
const rateLimit = require('express-rate-limit');
const { COLLECTIONS: C } = require('./oracle/repo');

const DOC_KEY = 'pricing_model';
const MODELS = Object.freeze(['group_plans', 'rider_pass']);
const ON_SALE = Object.freeze({ group_plans: Object.freeze(['group_small', 'group_large']), rider_pass: Object.freeze(['rider_pass']) });
const LABELS = Object.freeze({ group_plans: 'Group plans (host buys Small or Large Group)', rider_pass: 'Rider Pass (every rider: all features for a month)' });
const TTL_MS = 30000;

const cache = new WeakMap();

/** True when plan `id` may be bought under `model` (Community is never bought). */
function onSaleIn(model, id) {
  return (ON_SALE[MODELS.includes(model) ? model : 'group_plans'] || []).includes(id);
}

function forRepo(repo) {
  const soda = repo.soda;
  let st = cache.get(soda);
  if (!st) { st = { at: 0, v: { model: 'group_plans', updatedAt: 0, updatedBy: '' } }; cache.set(soda, st); }
  const api = {
    /** Cached sync value (refreshed in the background when stale). */
    now() { if (Date.now() - st.at > TTL_MS) api.get().catch(() => {}); return st.v.model; },
    async get() {
      if (Date.now() - st.at < TTL_MS) return st.v;
      try {
        const r = await soda.findOne(C.subscriptionConfig, { k: DOC_KEY });
        const m = r && r.value && MODELS.includes(r.value.model) ? r.value.model : 'group_plans';
        st.v = { model: m, updatedAt: (r && r.value && r.value.updatedAt) || 0, updatedBy: (r && r.value && r.value.updatedBy) || '' };
        st.at = Date.now();
      } catch { /* keep the last known model */ }
      return st.v;
    },
    async model() { return (await api.get()).model; },
    async set(model, by) {
      if (!MODELS.includes(model)) throw Object.assign(new Error('Unknown pricing model.'), { status: 400, code: 'BAD_MODEL' });
      const doc = { k: DOC_KEY, model, updatedAt: Date.now(), updatedBy: String(by || 'admin').slice(0, 120) };
      await soda.upsertBy(C.subscriptionConfig, { k: DOC_KEY }, doc);
      st.v = { model, updatedAt: doc.updatedAt, updatedBy: doc.updatedBy }; st.at = Date.now();
      return st.v;
    },
    _reset() { st.at = 0; },
  };
  return api;
}

function registerPricingModelRoutes({ r, repo, wrap, requireAdmin }) {
  const pm = forRepo(repo);
  const lim = rateLimit({ windowMs: 60 * 1000, limit: 20, standardHeaders: 'draft-7', legacyHeaders: false, keyGenerator: (req) => `pm:${req.user ? req.user.userId : req.ip}` });
  r.get('/admin/pricing-model', requireAdmin, wrap(async (req, res) => {
    const v = await pm.get();
    res.set('Cache-Control', 'no-store').json({ ok: true, ...v, models: MODELS.map((id) => ({ id, label: LABELS[id], plans: ON_SALE[id] })) });
  }));
  r.put('/admin/pricing-model', requireAdmin, lim, wrap(async (req, res) => {
    if (!req.user || req.user.role !== 'MASTER_ADMIN') return res.status(403).json({ error: 'Only a master admin can change the pricing model.', code: 'FORBIDDEN' });
    const model = String((req.body && req.body.model) || '');
    if (!MODELS.includes(model)) return res.status(400).json({ error: 'Choose group_plans or rider_pass.', code: 'BAD_MODEL' });
    const before = await pm.model();
    const v = await pm.set(model, req.user.email || req.user.userId);
    if (typeof repo.addAuditEntry === 'function') {
      await repo.addAuditEntry({ by: req.user.email || req.user.userId, byUserId: req.user.userId, action: 'pricing.model.update', target: 'pricing_model', details: { from: before, to: model }, at: Date.now() }).catch(() => {});
    }
    res.json({ ok: true, ...v });
  }));
}

module.exports = { MODELS, ON_SALE, LABELS, DOC_KEY, onSaleIn, forRepo, registerPricingModelRoutes };
