'use strict';
/**
 * Round 6 business brain (docs/intelligence/BUSINESS_ANALYTICS.md). Sized for the 1 GB micro VMs:
 *
 *  - computed NIGHTLY under the job lease ('business-nightly'), from data the gateway already has, page by page
 *    (PAGE documents at a time, a short pause between pages, an AbortSignal checked on every page);
 *  - memory is bounded: one compact record per rider with rides (MAX_RIDERS), fixed-size aggregates, capped lists;
 *  - stored as SMALL AGGREGATES in `business_agg` (one document per page of the web admin). No copy of personal
 *    data: aggregates hold counts; the two per-rider lists (at risk, signals) hold user ids and numbers only, and
 *    names are joined when a MASTER_ADMIN opens the page. `business_riders` keeps one tiny document per rider with
 *    an hour-of-week histogram of app opens / e-mail clicks (best send time); it goes with the account on erase.
 *  - staff accounts (admins, STAFF_EMAILS) are left out of every figure, like the other dashboards.
 *
 * Sources: users (sign-up, verified, last app open), rider_scores (ride facts: end time and group size, numbers
 * only), memberships (plan end dates), subscription_config (orders, coupon redemptions), auth_sessions (keyed
 * device / network hashes, never the ids), pageviews (/plans views), the e-mail studio's reports and click events.
 */
const crypto = require('crypto');
const M = require('./churn_model');

const DAY = 86400000;
const WEEK = 7 * DAY;
const IST = 330 * 60000;
const AGG = 'business_agg';
const RIDERS = 'business_riders';
const OBS = 'business_obs';
const PAID_PLANS = Object.freeze(['group_small', 'group_large']);
const COHORT_WEEKS = 12;
const TREND_WEEKS = 26;
const AT_RISK_MAX = 200;
const AT_RISK_MIN_SCORE = 50;
const SIGNALS_MAX = 100;
const OBS_MAX_USERS = 5000;
const HIST_TOTAL_MAX = 400;

/** India-time week number (weeks start on Monday 00:00 IST) and its start in epoch ms. */
const weekOf = (t) => Math.floor((Number(t) + IST + 3 * DAY) / WEEK);
const weekStart = (w) => w * WEEK - 3 * DAY - IST;
const dayOf = (t) => Math.floor((Number(t) + IST) / DAY);
/** 0..167, Monday 00:00 IST = 0. */
function hourOfWeek(t) {
  const d = new Date(Number(t) + IST);
  return ((d.getUTCDay() + 6) % 7) * 24 + d.getUTCHours();
}
const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const round2 = (n) => Math.round(n * 100) / 100;
const hashId = (s) => crypto.createHash('sha256').update(String(s)).digest('hex').slice(0, 12);

/** The preferred hour bucket of a histogram { "<hourOfWeek>": count }: { how, hour, dow, n } or null (too little data). */
function bestOf(hist, minEvents = 5) {
  let total = 0;
  const byHour = new Array(24).fill(0);
  const cells = [];
  for (const [k, v] of Object.entries(hist || {})) {
    const how = Number(k); const n = num(v);
    if (!(how >= 0 && how < 168) || n <= 0) continue;
    total += n; byHour[how % 24] += n; cells.push([how, n]);
  }
  if (total < minEvents) return null;
  // The hour of day first (summed over the week), then the weekday on which that hour is busiest.
  let hour = 0;
  for (let h = 1; h < 24; h++) if (byHour[h] > byHour[hour]) hour = h;
  let best = -1; let bestN = 0;
  for (const [how, n] of cells) if (how % 24 === hour && (n > bestN || (n === bestN && how < best))) { best = how; bestN = n; }
  return { how: best, hour, dow: Math.floor(best / 24), n: total };
}

/** Adds counts into a histogram, halving everything when it grows past HIST_TOTAL_MAX (old habits fade). */
function addHist(hist, add) {
  const out = { ...(hist || {}) };
  for (const [k, v] of Object.entries(add || {})) out[k] = num(out[k]) + num(v);
  let total = 0;
  for (const v of Object.values(out)) total += v;
  if (total > HIST_TOTAL_MAX) for (const k of Object.keys(out)) { out[k] = Math.floor(out[k] / 2); if (!out[k]) delete out[k]; }
  return out;
}

class BusinessBrain {
  /**
   * @param {object} o
   * @param {object} o.soda      the gateway's SODA client (decrypting wrapper)
   * @param {object} [o.rawSoda] the raw client for whole-collection scans (stored documents; no protected field is read)
   * @param {object} o.repo
   * @param {object} [o.studio]  e-mail studio (campaign reports, click user hash, consent through studio.offers)
   */
  constructor({ soda, rawSoda = null, repo, studio = null, logger = console, clock = Date.now, env = process.env, node = '',
    page = null, pauseMs = null, maxRiders = null, maxUsers = null } = {}) {
    this.soda = soda; this.raw = rawSoda || soda.__raw || soda; this.repo = repo; this.studio = studio; this.log = logger; this.clock = clock; this.node = node;
    const envNum = (k, d, lo, hi) => { const n = Number(env[k]); return env[k] !== undefined && env[k] !== '' && Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : d; };
    this.enabled = String(env.BUSINESS_ANALYTICS || 'on').trim().toLowerCase() !== 'off';
    this.page = page || envNum('BUSINESS_PAGE_SIZE', 200, 20, 500);
    this.pauseMs = pauseMs !== null ? pauseMs : envNum('BUSINESS_PAGE_PAUSE_MS', env.NODE_ENV === 'test' ? 0 : 40, 0, 2000);
    this.maxRiders = maxRiders || envNum('BUSINESS_MAX_RIDERS', 100000, 100, 1000000);
    this.maxUsers = maxUsers || envNum('BUSINESS_MAX_USERS', 300000, 100, 5000000);
    this.ready = null;
    this.running = null;
    // App opens seen by this node since its last flush: userId -> { how: count }. Bounded; never raw request data.
    this.opens = new Map();
    this.lastOpenHour = new Map();
    this.stats = { opensSeen: 0, opensDropped: 0, obsFlushed: 0, runs: 0, pages: 0, peakRiders: 0 };
  }

  async ensureStore() {
    if (!this.ready) {
      this.ready = (async () => {
        for (const c of [AGG, RIDERS, OBS]) await this.soda.ensureCollection(c);
        await this.soda.ensureIndex(AGG, { name: 'business_agg_k_uq', unique: true, fields: [{ path: 'k', datatype: 'string', maxLength: 80 }] }).catch(() => {});
        await this.soda.ensureIndex(RIDERS, { name: 'business_riders_user_uq', unique: true, fields: [{ path: 'userId', datatype: 'string', maxLength: 80 }] }).catch(() => {});
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  async _pause(signal) {
    this.stats.pages++;
    if (signal && signal.aborted) throw Object.assign(new Error('business job stopped'), { code: 'ABORTED' });
    await new Promise((r) => { if (this.pauseMs > 0) { const t = setTimeout(r, this.pauseMs); t.unref?.(); } else setImmediate(r); });
  }

  async getAgg(k) {
    await this.ensureStore();
    const row = await this.soda.findOne(AGG, { k });
    if (!row) return null;
    const { casRev, ...value } = row.value; // eslint-disable-line no-unused-vars
    return value;
  }

  async putAgg(k, value) {
    await this.ensureStore();
    const doc = { ...value, k, updatedAt: this.clock() };
    await this.soda.upsertBy(AGG, { k }, doc);
    return doc;
  }

  // ------------------------------------------------------------------ app opens (best send time)
  /**
   * One app open of a rider (the gateway calls this when an authenticated /api/me is served). Counted at most once
   * per rider per hour; kept in a bounded map until the next flush. Never throws, never awaits.
   */
  observeOpen(userId, t = this.clock()) {
    if (!this.enabled || !userId) return;
    const hourNo = Math.floor(t / 3600000);
    if (this.lastOpenHour.get(userId) === hourNo) return;
    if (!this.opens.has(userId) && this.opens.size >= OBS_MAX_USERS) { this.stats.opensDropped++; return; }
    if (this.lastOpenHour.size >= OBS_MAX_USERS * 2) this.lastOpenHour.clear();
    this.lastOpenHour.set(userId, hourNo);
    const how = hourOfWeek(t);
    const cur = this.opens.get(userId) || {};
    cur[how] = (cur[how] || 0) + 1;
    this.opens.set(userId, cur);
    this.stats.opensSeen++;
  }

  /** Writes this node's pending opens as a few small batch documents (any node; the nightly job folds them). */
  async flushOpens() {
    if (!this.opens.size) return 0;
    const entries = [...this.opens.entries()];
    this.opens = new Map();
    await this.ensureStore();
    let n = 0;
    for (let i = 0; i < entries.length; i += 500) {
      const o = [];
      for (const [uid, h] of entries.slice(i, i + 500)) for (const [how, c] of Object.entries(h)) o.push([uid, Number(how), c]);
      await this.soda.insert(OBS, { node: this.node, at: this.clock(), o });
      n += o.length;
    }
    this.stats.obsFlushed += n;
    return n;
  }

  /** Folds the stored open batches and new e-mail clicks into the riders' histograms. Bounded per run. */
  async foldSendTimes({ signal = null, state = {} } = {}) {
    await this.ensureStore();
    const add = new Map(); // userId -> { how: n }
    const put = (uid, how, n) => {
      if (!add.has(uid) && add.size >= this.maxRiders) return;
      const h = add.get(uid) || {};
      h[how] = (h[how] || 0) + n;
      add.set(uid, h);
    };
    // 1. open batches written by both nodes (deleted once folded)
    const done = [];
    for (let guard = 0; guard < 200; guard++) {
      const rows = await this.soda.query(OBS, { at: { $lte: this.clock() } }, { limit: 50, offset: done.length });
      for (const r of rows) { for (const e of (r.value.o || [])) if (Array.isArray(e) && e[0]) put(String(e[0]), Number(e[1]) || 0, Number(e[2]) || 1); done.push(r.key); }
      await this._pause(signal);
      if (rows.length < 50) break;
    }
    // 2. e-mail clicks since the last run (hashed user id; matched to riders below)
    const clicks = new Map(); // uh -> { how: n }
    let cursor = num(state.clickCursor);
    const since = cursor || this.clock() - 90 * DAY;
    let lastAt = since;
    for (let offset = 0; offset < 20000; offset += this.page) {
      const rows = await this.soda.query('email_events', { type: 'click', at: { $gt: since } }, { orderBy: [{ path: 'at', datatype: 'number', order: 'asc' }], limit: this.page, offset }).catch(() => []);
      for (const r of rows) {
        const e = r.value;
        if (!e || !e.uh) continue;
        const h = clicks.get(e.uh) || {};
        const how = hourOfWeek(e.at);
        h[how] = (h[how] || 0) + 2; // a click on an e-mail says more about e-mail time than an app open
        clicks.set(e.uh, h);
        if (num(e.at) > lastAt) lastAt = num(e.at);
      }
      await this._pause(signal);
      if (rows.length < this.page) break;
    }
    cursor = lastAt;
    if (clicks.size && this.studio && typeof this.studio.userHash === 'function') {
      // Riders who clicked are riders we mailed: the consenting set is small. Match their hash without a full scan.
      const ids = await this.studio._consenting().catch(() => []);
      for (const uid of ids) {
        const h = clicks.get(this.studio.userHash(uid));
        if (h) for (const [how, n] of Object.entries(h)) put(uid, Number(how), n);
      }
    }
    // 3. merge into the per-rider documents, a few at a time
    let written = 0;
    const ids = [...add.keys()];
    for (let i = 0; i < ids.length; i += 25) {
      await Promise.all(ids.slice(i, i + 25).map(async (uid) => {
        const row = await this.soda.findOne(RIDERS, { userId: uid });
        const hist = addHist(row ? row.value.hist : {}, add.get(uid));
        const best = bestOf(hist);
        const doc = { userId: uid, hist, best: best ? best.how : -1, bestHour: best ? best.hour : -1, n: best ? best.n : Object.values(hist).reduce((s, v) => s + v, 0), updatedAt: this.clock() };
        if (row) await this.soda.replace(RIDERS, row.key, doc); else await this.soda.insert(RIDERS, doc).catch(() => {});
        written++;
      }));
      await this._pause(signal);
    }
    for (const key of done) await this.soda.remove(OBS, key).catch(() => {});
    return { riders: written, batches: done.length, clickCursor: cursor };
  }

  /** userId -> preferred India-time hour (0-23), for the riders that have one. At most 1000 ids per call. */
  async bestHours(userIds) {
    const out = new Map();
    if (!this.enabled) return out;
    await this.ensureStore();
    const ids = [...new Set((userIds || []).map(String))].slice(0, 20000);
    for (let i = 0; i < ids.length; i += 100) {
      const rows = await this.soda.query(RIDERS, { userId: { $in: ids.slice(i, i + 100) } }, { limit: 100 }).catch(() => []);
      for (const r of rows) if (r.value && r.value.bestHour >= 0) out.set(r.value.userId, r.value.bestHour);
    }
    return out;
  }

  async forgetUser(userId) {
    if (!userId) return;
    await this.soda.removeWhere(RIDERS, { userId: String(userId) }).catch(() => {});
    this.opens.delete(userId); this.lastOpenHour.delete(userId);
  }

  // ------------------------------------------------------------------ the nightly computation
  /** Runs once at a time on this node; a second call while it runs gets the same promise. */
  runNightly(opts = {}) {
    if (!this.enabled) return Promise.resolve({ skipped: 'OFF' });
    if (!this.running) this.running = this._runNightly(opts).finally(() => { this.running = null; });
    return this.running;
  }

  async _runNightly({ signal = null, now = this.clock() } = {}) {
    await this.ensureStore();
    const started = Date.now();
    const prevState = (await this.getAgg('state')) || {};
    const steps = {};
    const timed = async (name, fn) => { const t0 = Date.now(); const out = await fn(); steps[name] = Date.now() - t0; return out; };
    const truncated = [];
    const staff = typeof this.repo.staffUserIds === 'function' ? await this.repo.staffUserIds().catch(() => new Set()) : new Set();

    await this.flushOpens().catch(() => {});
    const sendFold = await timed('sendTimes', () => this.foldSendTimes({ signal, state: prevState }));

    // ---- rides: one compact record per rider (ride days of the last 26 weeks, first ride, first group ride)
    const riders = await timed('rides', () => this._scanRides({ signal, now, staff, truncated }));
    this.stats.peakRiders = Math.max(this.stats.peakRiders, riders.size);

    // ---- plans: latest paid membership per owner
    const plans = await timed('plans', () => this._scanMemberships({ signal, staff }));

    // ---- orders and coupon redemptions: plan / coupon conversion, revenue trend, payment signals
    const money = await timed('orders', () => this._scanOrders({ signal, now, staff, truncated }));

    // ---- users: cohorts, funnel, churn scores, renewals, spam bursts
    const people = await timed('users', () => this._scanUsers({ signal, now, staff, riders, plans, money, truncated }));

    // ---- sessions: many accounts on one device, bulk sign-ups from one network
    const sess = await timed('sessions', () => this._scanSessions({ signal, now, staff, newUsers: people.newUsers, truncated }));

    // ---- send times: how many riders prefer each hour of the week
    const sendtime = await timed('sendtimeAgg', () => this._sendTimeAgg({ signal }));

    // ---- campaigns: reuse the e-mail studio's own reports
    const prevConversion = await this.getAgg('conversion');
    const campaigns = await timed('campaigns', () => this._campaigns({ signal, now, prev: prevConversion }));

    const planViews = await this._planViews(now).catch(() => ({ views30: 0, days: [] }));

    // ---- store the aggregates (each a small document)
    const reviewPrev = (await this.getAgg('review-state')) || { items: {} };
    const signals = [...money.signals, ...people.signals, ...sess.signals]
      .sort((a, b) => b.severity - a.severity || b.count - a.count).slice(0, SIGNALS_MAX)
      .map((s) => ({ ...s, id: hashId(`${s.type}|${s.key}`) }));
    await this.putAgg('cohorts', { weeks: COHORT_WEEKS, cohorts: people.cohorts, generatedAt: now });
    await this.putAgg('funnel', { all: people.funnelAll, recent: people.funnelRecent, recentDays: 90, generatedAt: now });
    await this.putAgg('conversion', { plans: money.plans, coupons: money.coupons, campaigns, planViews, generatedAt: now });
    await this.putAgg('revenue', { weekly: money.weekly, renewals: people.renewals, last7: money.last7, generatedAt: now });
    await this.putAgg('churn', { atRisk: people.atRisk, counts: people.riskCounts, model: people.modelInfo, minScore: AT_RISK_MIN_SCORE, generatedAt: now });
    await this.putAgg('signals', { items: signals, generatedAt: now });
    await this.putAgg('sendtime', { ...sendtime, generatedAt: now });
    await this.putAgg('week', { activeRiders7: people.active7, newRiders7: people.new7, rideDays7: people.rideDays7, ridersRode7: people.rode7, totalRiders: people.total, generatedAt: now });
    // Review decisions of signals that no longer exist are dropped after 90 days.
    const keep = {};
    for (const [id, v] of Object.entries(reviewPrev.items || {})) if (signals.some((s) => s.id === id) || now - num(v.at) < 90 * DAY) keep[id] = v;
    if (Object.keys(keep).length !== Object.keys(reviewPrev.items || {}).length) await this.putAgg('review-state', { items: keep });

    this.stats.runs++;
    const state = { ...prevState, lastRunAt: now, lastRunMs: Date.now() - started, lastRunBy: this.node, steps, truncated, clickCursor: sendFold.clickCursor,
      counts: { riders: riders.size, users: people.total, orders: money.orders, sessions: sess.scanned, signals: signals.length, atRisk: people.atRisk.length } };
    await this.putAgg('state', state);
    return state;
  }

  /** userId -> { days: number[] (ride days, last 182 days), groupDays: Set, first, firstGroup, last } from rider_scores. */
  async _scanRides({ signal, now, staff, truncated }) {
    const out = new Map();
    const minDay = dayOf(now) - 182;
    let scanned = 0;
    for await (const page of this.raw.scan('rider_scores', { pageSize: Math.min(this.page, 100) })) {
      for (const row of page) {
        const v = row.value;
        if (!v || !v.userId || staff.has(v.userId)) continue;
        const rides = Array.isArray(v.rides) ? v.rides : [];
        const archivedRides = num(v.archived && v.archived.rides);
        if (!rides.length && !archivedRides) continue;
        if (out.size >= this.maxRiders) { if (!truncated.includes('riders')) truncated.push('riders'); continue; }
        const days = new Set(); const groupDays = new Set();
        let first = 0; let firstGroup = 0; let last = 0;
        for (const r of rides) {
          const at = num(r && r.endedAt);
          if (!at) continue;
          if (!first || at < first) first = at;
          if (at > last) last = at;
          const group = num(r.groupSize) >= 2;
          if (group && (!firstGroup || at < firstGroup)) firstGroup = at;
          const d = dayOf(at);
          if (d >= minDay) { days.add(d); if (group) groupDays.add(d); }
        }
        // Rides folded away by the rider score (older than its window) still count as "rode once".
        if (!first && archivedRides) first = num(v.updatedAt) || now - 400 * DAY;
        out.set(v.userId, { days: [...days], groupDays, first, firstGroup, last });
      }
      scanned += page.length;
      await this._pause(signal);
    }
    void scanned;
    return out;
  }

  async _scanMemberships({ signal, staff }) {
    const map = new Map();
    for await (const page of this.raw.scan('memberships', { pageSize: this.page })) {
      for (const row of page) {
        const m = row.value;
        if (!m || !m.ownerUserId || staff.has(m.ownerUserId) || !PAID_PLANS.includes(m.category) || m.statusReason === 'REFUNDED') continue;
        const prev = map.get(m.ownerUserId);
        if (!prev || num(m.validUntil) > prev.until) map.set(m.ownerUserId, { until: num(m.validUntil), category: m.category, active: m.status === 'ACTIVE' });
      }
      await this._pause(signal);
    }
    return map;
  }

  async _scanOrders({ signal, now, staff, truncated }) {
    const plans = new Map(); const coupons = new Map();
    const w0 = weekOf(now) - (TREND_WEEKS - 1);
    const weekly = Array.from({ length: TREND_WEEKS }, (_, i) => ({ week: w0 + i, start: weekStart(w0 + i), netInr: 0, orders: 0, refundsInr: 0 }));
    const paidUsers = new Set();
    const failed = new Map(); const refunds = new Map();
    const last7 = { netInr: 0, orders: 0, refundsInr: 0 };
    let orders = 0;
    const planOf = (o) => String(o.category || o.planTier || 'other');
    const P = (id) => { if (!plans.has(id)) plans.set(id, { plan: id, created: 0, paid: 0, refunded: 0, failed: 0, netInr: 0 }); return plans.get(id); };
    for (let offset = 0; ; offset += this.page) {
      if (offset >= 200000) { truncated.push('orders'); break; }
      const rows = await this.soda.query('subscription_config', { k: 'rzp_order' }, { limit: this.page, offset });
      for (const r of rows) {
        const o = r.value;
        if (!o || (o.userId && staff.has(o.userId)) || o.mode === 'test') continue;
        orders++;
        const p = P(planOf(o));
        const status = String(o.status || '').toUpperCase();
        const paise = num(o.amountInPaise);
        p.created++;
        if (status === 'FAILED') {
          p.failed++;
          if (o.userId && num(o.updatedAt || o.createdAt) >= now - 30 * DAY) failed.set(o.userId, (failed.get(o.userId) || 0) + 1);
        }
        if (status !== 'PAID') continue;
        const at = num(o.paidAt) || num(o.createdAt);
        const refunded = num(o.refundedAmountInPaise) / 100;
        const net = paise / 100 - refunded;
        p.paid++; p.netInr += net;
        const wasRefunded = refunded > 0 || o.fullyRefunded || (Array.isArray(o.refunds) && o.refunds.length > 0);
        if (wasRefunded) {
          p.refunded++;
          if (o.userId) {
            const rf = refunds.get(o.userId) || { count: 0, quick: 0, lastAt: 0 };
            rf.count++;
            const firstRefundAt = Array.isArray(o.refunds) && o.refunds.length ? num(o.refunds[0].at || o.refunds[0].createdAt) : num(o.refundedAt);
            if (firstRefundAt && firstRefundAt - at <= 48 * 3600000) rf.quick++;
            rf.lastAt = Math.max(rf.lastAt, firstRefundAt || at);
            refunds.set(o.userId, rf);
          }
        }
        if (paise > 0 && o.userId && paidUsers.size < this.maxUsers) paidUsers.add(o.userId);
        const w = weekly[weekOf(at) - w0];
        if (w && paise > 0) { w.netInr += net; w.orders++; w.refundsInr += refunded; }
        if (paise > 0 && at >= now - 7 * DAY) { last7.netInr += net; last7.orders++; last7.refundsInr += refunded; }
        const code = String(o.couponCode || '').trim().toUpperCase();
        if (code) {
          const c = coupons.get(code) || { code, orders: 0, paid: 0, revenueInr: 0, discountInr: 0, free: 0 };
          c.orders++; c.paid++; c.revenueInr += net;
          coupons.set(code, c);
        }
      }
      await this._pause(signal);
      if (rows.length < this.page) break;
    }
    // Coupon redemptions: discount given, free activations, and riders who start many orders with a code and leave them.
    const retries = new Map();
    for (let offset = 0; offset < 200000; offset += this.page) {
      const rows = await this.soda.query('subscription_config', { k: 'coupon_redemption' }, { limit: this.page, offset });
      for (const r of rows) {
        const rd = r.value;
        if (!rd || (rd.userId && staff.has(rd.userId))) continue;
        const code = String(rd.couponCode || '').trim().toUpperCase();
        const at = num(rd.redeemedAt || rd.reservedAt || rd.createdAt);
        if (rd.status === 'SUCCESS' && code) {
          const c = coupons.get(code) || { code, orders: 0, paid: 0, revenueInr: 0, discountInr: 0, free: 0 };
          c.discountInr += num(rd.discountAmount);
          c.redeemed = (c.redeemed || 0) + 1;
          if (rd.isFree || num(rd.finalAmount) === 0) c.free++;
          coupons.set(code, c);
        } else if (['CANCELLED', 'EXPIRED', 'RESERVED'].includes(String(rd.status)) && rd.userId && rd.userId !== 'guest' && at >= now - 30 * DAY) {
          retries.set(rd.userId, (retries.get(rd.userId) || 0) + 1);
        }
      }
      await this._pause(signal);
      if (rows.length < this.page) break;
    }
    const signals = [];
    for (const [uid, n] of failed) if (n >= 4) signals.push({ type: 'failed_payments', key: uid, userIds: [uid], count: n, severity: n >= 8 ? 3 : 2, note: `${n} failed payments in 30 days` });
    for (const [uid, rf] of refunds) if (rf.count >= 2 || rf.quick >= 1) signals.push({ type: 'refund_pattern', key: uid, userIds: [uid], count: rf.count, severity: rf.count >= 3 ? 3 : (rf.count >= 2 ? 2 : 1), note: rf.quick ? `${rf.count} refunded ${rf.count === 1 ? 'order' : 'orders'}, ${rf.quick} within 48 hours of paying` : `${rf.count} refunded orders` });
    for (const [uid, n] of retries) if (n >= 5) signals.push({ type: 'coupon_retries', key: uid, userIds: [uid], count: n, severity: n >= 10 ? 2 : 1, note: `${n} coupon orders started and not paid in 30 days` });
    const fix = (o) => { for (const k of Object.keys(o)) if (typeof o[k] === 'number' && !Number.isInteger(o[k])) o[k] = round2(o[k]); return o; };
    return {
      orders, paidUsers, signals,
      plans: [...plans.values()].map(fix).sort((a, b) => b.paid - a.paid || b.created - a.created).slice(0, 20),
      coupons: [...coupons.values()].map(fix).sort((a, b) => (b.redeemed || b.paid) - (a.redeemed || a.paid)).slice(0, 50),
      weekly: weekly.map(fix), last7: fix(last7),
    };
  }

  async _scanUsers({ signal, now, staff, riders, plans, money, truncated }) {
    const thisWeek = weekOf(now);
    const firstCohort = thisWeek - (COHORT_WEEKS - 1);
    const cohorts = Array.from({ length: COHORT_WEEKS }, (_, i) => ({ week: firstCohort + i, start: weekStart(firstCohort + i), size: 0, active: new Array(COHORT_WEEKS - i).fill(0) }));
    const funnel = () => ({ signedUp: 0, verified: 0, firstRide: 0, firstGroupRide: 0, paid: 0 });
    const funnelAll = funnel(); const funnelRecent = funnel();
    const renewals = { in7: 0, in14: 0, in30: 0, list: [] };
    const risk = []; // bounded: the AT_RISK_MAX highest scores
    const riskCounts = { high: 0, medium: 0, scored: 0 };
    const samples = [];
    const unverifiedByHour = new Map();
    const newUsers = new Set();
    let total = 0; let active7 = 0; let new7 = 0; let rideDays7 = 0; let rode7 = 0; let seen = 0;
    const today = dayOf(now);
    for await (const page of this.raw.scan('users', { pageSize: this.page })) {
      for (const row of page) {
        const u = row.value;
        if (!u || !u.userId || u.deletedAt || staff.has(u.userId)) continue;
        if (++seen > this.maxUsers) { if (!truncated.includes('users')) truncated.push('users'); break; }
        total++;
        const created = num(u.createdAt);
        const verified = u.emailVerified !== false;
        const r = riders.get(u.userId) || null;
        const plan = plans.get(u.userId) || null;
        const paid = money.paidUsers.has(u.userId);
        const lastOpen = Math.max(num(u.lastActiveAt), num(u.lastLoginAt));
        if (lastOpen >= now - 7 * DAY) active7++;
        if (created >= now - 7 * DAY) { new7++; if (newUsers.size < 20000) newUsers.add(u.userId); }
        if (r) { let n = 0; for (const d of r.days) if (today - d < 7) n++; rideDays7 += n; if (n) rode7++; }
        // funnel
        for (const [f, on] of [[funnelAll, true], [funnelRecent, created >= now - 90 * DAY]]) {
          if (!on) continue;
          f.signedUp++;
          if (verified) f.verified++;
          if (verified && r && r.first) f.firstRide++;
          if (verified && r && r.firstGroup) f.firstGroupRide++;
          if (verified && paid) f.paid++;
        }
        // weekly cohort retention: active = rode at least once in that week
        const cw = weekOf(created);
        const c = cw >= firstCohort && cw <= thisWeek ? cohorts[cw - firstCohort] : null;
        if (c) {
          c.size++;
          if (r) {
            const weeks = new Set(r.days.map((d) => weekOf(d * DAY - IST + 12 * 3600000)));
            for (let k = 0; k < c.active.length; k++) if (weeks.has(cw + k)) c.active[k]++;
          }
        }
        // unverified bursts (spam sign-ups): unverified accounts created in the same hour, last 7 days
        if (!verified && created >= now - 7 * DAY) { const hr = Math.floor(created / 3600000); unverifiedByHour.set(hr, (unverifiedByHour.get(hr) || 0) + 1); }
        // renewals due
        if (plan && plan.active && plan.until > now && plan.until <= now + 30 * DAY) {
          renewals.in30++;
          if (plan.until <= now + 14 * DAY) renewals.in14++;
          if (plan.until <= now + 7 * DAY) renewals.in7++;
          if (renewals.list.length < 50) renewals.list.push({ userId: u.userId, plan: plan.category, until: plan.until });
        }
        // churn warning: riders who rode at least once, or hold / held a paid plan
        if (r || plan) {
          let d30 = 0; let prev60 = 0;
          if (r) for (const d of r.days) { const age = today - d; if (age <= 30) d30++; else if (age <= 90) prev60++; }
          const facts = { lastRideAt: r ? r.last : 0, rideDays30: d30, rideDaysPrev60: prev60, planEndsAt: plan && plan.active && plan.until > now ? plan.until : 0,
            planEndedAt: plan && plan.until <= now ? plan.until : 0, lastOpenAt: lastOpen };
          const lost = r && r.last && now - r.last > 120 * DAY && !(facts.planEndsAt > now);
          if (!lost) {
            const rule = M.ruleScore(facts, now);
            riskCounts.scored++;
            if (rule.score >= 70) riskCounts.high++; else if (rule.score >= AT_RISK_MIN_SCORE) riskCounts.medium++;
            const f = r ? M.featuresAt(r.days, now, { createdAt: created, groupDays: r.groupDays }) : null;
            if (rule.score >= AT_RISK_MIN_SCORE) {
              const item = { userId: u.userId, score: rule.score, factors: rule.factors.slice(0, 3).map((x) => ({ key: x.key, label: x.label, points: x.points })),
                lastRideAt: facts.lastRideAt, lastOpenAt: lastOpen, planEndsAt: facts.planEndsAt || facts.planEndedAt || 0, f };
              if (risk.length < AT_RISK_MAX) risk.push(item);
              else {
                let lo = 0;
                for (let i = 1; i < risk.length; i++) if (risk[i].score < risk[lo].score) lo = i;
                if (risk[lo].score < item.score) risk[lo] = item;
              }
            }
          }
          // one training row per rider with history (reservoir of MAX_SAMPLES)
          if (r) {
            const s = M.sampleOf(r.days, now, { createdAt: created, groupDays: r.groupDays });
            if (s) {
              if (samples.length < M.MAX_SAMPLES) samples.push(s);
              else { const j = Math.floor(Math.random() * (seen + 1)); if (j < M.MAX_SAMPLES) samples[j] = s; }
            }
          }
        }
      }
      await this._pause(signal);
      if (seen > this.maxUsers) break;
    }
    // The small logistic regression, when there is enough history; else the rules alone.
    const model = M.train(samples, { now });
    for (const item of risk) {
      if (model.ok && item.f) {
        const p = M.predict(model, item.f);
        item.modelScore = Math.round(p.p * 100);
        item.modelFactors = p.factors.map((x) => ({ key: x.key, label: x.label }));
      }
      delete item.f;
    }
    risk.sort((a, b) => b.score - a.score || (b.modelScore || 0) - (a.modelScore || 0) || a.lastRideAt - b.lastRideAt);
    const modelInfo = { active: !!model.ok, reason: model.reason || null, samples: model.n, churned: model.churned, auc: model.auc === undefined ? null : model.auc,
      heldOut: model.heldOut || 0, trainedAt: now, features: M.FEATURES, weights: model.ok ? model.w : null };
    const signals = [];
    for (const [hr, n] of unverifiedByHour) if (n >= 10) signals.push({ type: 'unverified_burst', key: `h${hr}`, userIds: [], count: n, severity: n >= 30 ? 3 : 2, at: hr * 3600000, note: `${n} sign-ups in one hour that never confirmed their e-mail` });
    return { cohorts, funnelAll, funnelRecent, renewals, atRisk: risk, riskCounts, modelInfo, signals, newUsers, total, active7, new7, rideDays7, rode7 };
  }

  async _scanSessions({ signal, now, staff, newUsers, truncated }) {
    const byDevice = new Map(); // deviceKey -> Set(userId) (sessions of the last 90 days)
    const byIp = new Map(); // ipHash -> Set(userId) of accounts created in the last 7 days
    let scanned = 0;
    for await (const page of this.raw.scan('auth_sessions', { pageSize: this.page })) {
      for (const row of page) {
        const s = row.value;
        scanned++;
        if (!s || !s.userId || staff.has(s.userId) || num(s.createdAt) < now - 90 * DAY) continue;
        if (s.deviceKey) {
          let set = byDevice.get(s.deviceKey);
          if (!set) { if (byDevice.size >= 50000) { if (!truncated.includes('devices')) truncated.push('devices'); } else { set = new Set(); byDevice.set(s.deviceKey, set); } }
          if (set && set.size < 30) set.add(s.userId);
        }
        if (s.ipHash && newUsers.has(s.userId)) {
          let set = byIp.get(s.ipHash);
          if (!set) { set = new Set(); byIp.set(s.ipHash, set); }
          if (set.size < 60) set.add(s.userId);
        }
      }
      await this._pause(signal);
      if (scanned >= 400000) { truncated.push('sessions'); break; }
    }
    const signals = [];
    for (const [key, set] of byDevice) if (set.size >= 4) signals.push({ type: 'device_accounts', key: hashId(key), userIds: [...set].slice(0, 10), count: set.size, severity: set.size >= 8 ? 3 : 2, note: `${set.size}${set.size >= 30 ? '+' : ''} accounts signed in on one phone in 90 days` });
    for (const [key, set] of byIp) if (set.size >= 8) signals.push({ type: 'signup_network', key: hashId(key), userIds: [...set].slice(0, 10), count: set.size, severity: set.size >= 20 ? 3 : 2, note: `${set.size}${set.size >= 60 ? '+' : ''} new accounts from one network in 7 days` });
    return { signals, scanned };
  }

  async _sendTimeAgg({ signal }) {
    const grid = new Array(168).fill(0); const hours = new Array(24).fill(0);
    let riders = 0; let withBest = 0;
    for await (const page of this.raw.scan(RIDERS, { pageSize: this.page })) {
      for (const row of page) {
        const v = row.value;
        if (!v) continue;
        riders++;
        if (v.best >= 0 && v.best < 168) { grid[v.best]++; withBest++; if (v.bestHour >= 0) hours[v.bestHour]++; }
      }
      await this._pause(signal);
    }
    return { grid, hours, riders, withBest };
  }

  async _campaigns({ signal, now, prev }) {
    if (!this.studio || typeof this.studio.listCampaigns !== 'function') return [];
    const old = new Map(((prev && prev.campaigns) || []).map((c) => [c.campaignId, c]));
    const list = await this.studio.listCampaigns({ limit: 30 }).catch(() => []);
    const out = [];
    let fresh = 0;
    for (const c of list) {
      if (!['SENT', 'SENDING', 'SCHEDULED'].includes(c.status) || !num(c.startedAt)) continue;
      const cached = old.get(c.campaignId);
      // A campaign that finished more than 14 days ago keeps its stored numbers (no re-read of its log).
      if (cached && c.status === 'SENT' && now - num(c.finishedAt) > 14 * DAY) { out.push(cached); continue; }
      if (fresh >= 10) { if (cached) out.push(cached); continue; }
      fresh++;
      const rep = await this.studio.report(c.campaignId).catch(() => null);
      out.push({ campaignId: c.campaignId, name: c.name, category: c.category, couponCode: c.couponCode || null, sentAt: num(c.startedAt), status: c.status,
        sent: rep ? rep.sent : num(c.stats && c.stats.sent), clicks: rep ? rep.clicks.unique : 0, unsubscribed: rep ? rep.unsubscribed : 0,
        redeemed: rep ? rep.redemptions.count : 0, revenueInr: rep ? rep.redemptions.revenueInr : 0, discountInr: rep ? rep.redemptions.discountInr : 0 });
      await this._pause(signal);
    }
    return out.slice(0, 30);
  }

  async _planViews(now) {
    if (typeof this.repo.listPageviews !== 'function') return { views30: 0, days: [] };
    const since = new Date(now - 30 * DAY + IST).toISOString().slice(0, 10);
    const rows = await this.repo.listPageviews(since);
    let views30 = 0;
    for (const r of rows) if (r.path === '/plans' || r.path === '/plans.html') views30 += num(r.count);
    return { views30, tracked: rows.length > 0 };
  }
}

module.exports = { BusinessBrain, AGG, RIDERS, OBS, COHORT_WEEKS, TREND_WEEKS, AT_RISK_MAX, AT_RISK_MIN_SCORE, OBS_MAX_USERS, weekOf, weekStart, dayOf, hourOfWeek, bestOf, addHist, hashId };
