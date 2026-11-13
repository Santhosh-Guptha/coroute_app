'use strict';
/**
 * Round 6 business brain: wiring, jobs and the MASTER_ADMIN API (docs/intelligence/BUSINESS_ANALYTICS.md).
 *
 *   GET  /api/admin/business/overview      funnel, revenue trend, renewals due, last run
 *   GET  /api/admin/business/retention     weekly sign-up cohorts x weeks active
 *   GET  /api/admin/business/conversion    plans, coupons, e-mail campaigns, /plans views
 *   GET  /api/admin/business/churn         "At risk this week" (names joined here; consent checked live)
 *   POST /api/admin/business/churn/winback usernames of the at-risk riders who may get offer e-mails (for the wizard)
 *   GET  /api/admin/business/sendtime      best send time: riders per hour of the week
 *   GET  /api/admin/business/review        payment / coupon / sign-up signals to review (never an automatic block)
 *   POST /api/admin/business/review/:id    mark a signal reviewed / open again (audited)
 *   GET  /api/admin/business/servers       both nodes' health from their /metrics, job runs, backup age
 *   GET|PUT /api/admin/business/settings   the weekly summary switch
 *   GET  /api/admin/business/summary/preview, POST /summary/test   the weekly e-mail (test goes to the caller only)
 *   POST /api/admin/business/refresh       run the nightly computation now (one at a time)
 *
 * Every route sits behind requireAuth + requireAdmin (MASTER_ADMIN). Jobs run under the job lease.
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth, requireAdmin } = require('../auth');
const { validEmail } = require('../mailer');
const { BusinessBrain } = require('./brain');
const { ServerHealth } = require('./servers');
const { WeeklySummary } = require('./summary');

const SIGNAL_LABEL = Object.freeze({
  device_accounts: 'Many accounts on one phone', signup_network: 'Many sign-ups from one network', unverified_burst: 'Burst of unconfirmed sign-ups',
  failed_payments: 'Many failed payments', refund_pattern: 'Refund pattern', coupon_retries: 'Coupon orders started and left',
});

function attachBusiness({ app, soda, rawSoda, repo, gate, lease, config = {}, logger = console, metrics, studio = null, mailer = null, templates = null,
  clock = Date.now, fetchImpl = globalThis.fetch, node = '', env = process.env } = {}) {
  const brain = new BusinessBrain({ soda, rawSoda, repo, studio, logger, clock, env, node });
  const servers = new ServerHealth({ metrics, lease, soda, config, env, fetchImpl, clock, node, role: config.gatewayRole || 'all' });
  const summary = new WeeklySummary({ brain, soda, repo, mailer, templates, servers, config, logger, clock });
  const audit = (req, action, target, details) => (typeof repo.addAuditEntry === 'function'
    ? repo.addAuditEntry({ at: Date.now(), by: (req.user && (req.user.email || req.user.userId)) || 'admin', byUserId: req.user ? req.user.userId : null, action, target, details }).catch(() => {}) : null);

  /** Display fields of a rider for the admin lists, and whether a marketing e-mail may be sent to them now. */
  async function riderCard(userId) {
    const u = await repo.findUserById(userId).catch(() => null);
    if (!u || u.deletedAt) return null;
    let mailable = false; let whyNot = 'E-mail tools are off';
    if (studio && studio.offers) {
      const consent = await studio.offers.consentOf(userId).catch(() => ({ offersEmail: false }));
      if (!validEmail(u.email)) whyNot = 'No valid e-mail address';
      else if (!consent.offersEmail) whyNot = 'Has not agreed to offer e-mails';
      else if (await studio._suppressed(u.email, 'marketing').catch(() => true)) whyNot = 'Unsubscribed or address blocked';
      else { mailable = true; whyNot = ''; }
    }
    return { userId, username: u.username || '', name: u.name || '', mailable, whyNot };
  }

  const r = express.Router();
  const limiter = (n) => rateLimit({ windowMs: 60 * 1000, limit: n, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res)).catch((e) => (e && e.status && e.status < 500 ? res.status(e.status).json({ error: e.message, code: e.code }) : next(e)));
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  r.use(limiter(120));
  const meta = async () => {
    const state = (await brain.getAgg('state')) || {};
    return { enabled: brain.enabled, lastRunAt: state.lastRunAt || 0, lastRunMs: state.lastRunMs || 0, truncated: state.truncated || [], counts: state.counts || null, running: !!brain.running };
  };

  r.get('/overview', wrap(async (req, res) => {
    const [funnel, revenue, churn, week, m] = await Promise.all([brain.getAgg('funnel'), brain.getAgg('revenue'), brain.getAgg('churn'), brain.getAgg('week'), meta()]);
    res.json({ meta: m, funnel, revenue, week, atRisk: churn ? { count: churn.atRisk.length, counts: churn.counts } : null });
  }));
  r.get('/retention', wrap(async (req, res) => res.json({ meta: await meta(), retention: await brain.getAgg('cohorts') })));
  r.get('/conversion', wrap(async (req, res) => res.json({ meta: await meta(), conversion: await brain.getAgg('conversion') })));
  r.get('/sendtime', wrap(async (req, res) => res.json({ meta: await meta(), sendtime: await brain.getAgg('sendtime') })));

  r.get('/churn', wrap(async (req, res) => {
    const churn = await brain.getAgg('churn');
    const limit = Math.min(100, Math.max(1, parseInt(req.query.limit, 10) || 50));
    const offset = Math.max(0, parseInt(req.query.offset, 10) || 0);
    const all = churn ? churn.atRisk : [];
    const riders = [];
    for (const item of all.slice(offset, offset + limit)) {
      const card = await riderCard(item.userId);
      if (card) riders.push({ ...item, ...card });
    }
    res.json({ meta: await meta(), total: all.length, offset, limit, counts: churn ? churn.counts : null, model: churn ? churn.model : null, minScore: churn ? churn.minScore : 50, riders });
  }));

  r.post('/churn/winback', limiter(10), wrap(async (req, res) => {
    const churn = await brain.getAgg('churn');
    const want = Array.isArray(req.body && req.body.userIds) ? new Set(req.body.userIds.map(String).slice(0, 500)) : null;
    const usernames = []; let notMailable = 0;
    for (const item of (churn ? churn.atRisk : [])) {
      if (want && !want.has(item.userId)) continue;
      const card = await riderCard(item.userId);
      if (card && card.mailable && card.username) usernames.push(card.username); else notMailable++;
    }
    await audit(req, 'business.winback_prepare', null, { mailable: usernames.length, notMailable });
    // Nothing is sent here: the e-mail wizard opens with these riders, and its own consent checks run again at send time.
    res.json({ usernames: usernames.slice(0, 500), mailable: usernames.length, notMailable, starter: 'winback_coupon', category: 'marketing' });
  }));

  r.get('/review', wrap(async (req, res) => {
    const [sig, st] = await Promise.all([brain.getAgg('signals'), brain.getAgg('review-state')]);
    const state = (st && st.items) || {};
    const items = [];
    for (const s of (sig ? sig.items : [])) {
      const riders = [];
      for (const uid of (s.userIds || []).slice(0, 10)) {
        const u = await repo.findUserById(uid).catch(() => null);
        if (u && !u.deletedAt) riders.push({ userId: uid, username: u.username || '', name: u.name || '', status: u.status || 'ACTIVE' });
      }
      items.push({ id: s.id, type: s.type, label: SIGNAL_LABEL[s.type] || s.type, count: s.count, severity: s.severity, note: s.note, at: s.at || 0, riders,
        review: state[s.id] || { status: 'OPEN' } });
    }
    res.json({ meta: await meta(), items, note: 'Signals for a person to review. Nothing here blocks or changes an account.' });
  }));
  r.post('/review/:id', limiter(30), wrap(async (req, res) => {
    const id = String(req.params.id || '');
    const status = String((req.body && req.body.status) || '').toUpperCase();
    if (!/^[a-f0-9]{12}$/.test(id) || !['REVIEWED', 'OPEN'].includes(status)) return res.status(400).json({ error: 'Choose REVIEWED or OPEN.', code: 'BAD_REVIEW' });
    const sig = await brain.getAgg('signals');
    if (!sig || !sig.items.some((s) => s.id === id)) return res.status(404).json({ error: 'This signal is no longer listed.', code: 'NOT_FOUND' });
    const st = (await brain.getAgg('review-state')) || { items: {} };
    const items = { ...(st.items || {}) };
    items[id] = { status, note: String((req.body && req.body.note) || '').replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 300), by: req.user.email || req.user.userId, at: Date.now() };
    await brain.putAgg('review-state', { items });
    await audit(req, 'business.signal_review', id, { status });
    return res.json({ id, review: items[id] });
  }));

  r.get('/servers', wrap(async (req, res) => res.json(await servers.snapshot())));

  r.get('/settings', wrap(async (req, res) => res.json({ ...(await summary.settings()), mailConfigured: !!(mailer && mailer.enabled), recipients: (await summary.recipients()).length, sendsAt: 'Monday 09:00 India time' })));
  r.put('/settings', limiter(20), wrap(async (req, res) => {
    const out = await summary.setSettings(req.body, { by: req.user.email || req.user.userId });
    await audit(req, 'business.settings', null, { weeklySummary: out.weeklySummary });
    res.json(out);
  }));
  r.get('/summary/preview', wrap(async (req, res) => { const m = await summary.render(); res.json({ subject: m.subject, text: m.text, lines: m.lines }); }));
  r.post('/summary/test', limiter(5), wrap(async (req, res) => {
    if (!mailer || !mailer.enabled) return res.status(503).json({ error: 'E-mail is not configured on this server (SMTP_HOST / MAIL_FROM).', code: 'MAIL_OFF' });
    const me = await repo.findUserById(req.user.userId).catch(() => null);
    if (!me || !validEmail(me.email)) return res.status(400).json({ error: 'Your account has no valid e-mail address.', code: 'NO_ADDRESS' });
    const out = await summary.send({ to: [me.email.trim()] });
    await audit(req, 'business.summary_test', null, { sent: out.sent });
    return res.json(out);
  }));

  r.post('/refresh', limiter(4), wrap(async (req, res) => {
    if (!brain.enabled) return res.status(409).json({ error: 'Business analytics are switched off on this server (BUSINESS_ANALYTICS=off).', code: 'OFF' });
    const already = !!brain.running;
    const p = brain.runNightly({});
    await audit(req, 'business.refresh', null, { already });
    // Small data: answer when done. Larger: answer after 8 s and let it finish in the background.
    const out = await Promise.race([p.then((state) => ({ done: true, state })), new Promise((resolve) => { const t = setTimeout(() => resolve({ done: false }), 8000); t.unref?.(); })]);
    p.catch((e) => logger.warn?.(`[business] refresh failed: ${String(e.message).slice(0, 120)}`));
    res.status(out.done ? 200 : 202).json({ ...out, meta: await meta() });
  }));

  if (app) app.use('/api/admin/business', requireAuth(gate), requireAdmin, r);

  // Account erase: the rider's send-time document goes with the account.
  if (repo && !repo.__businessCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__businessCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await brain.forgetUser(user.userId).catch(() => {});
      return out;
    };
  }

  let flushTimer = null;
  let started = false;
  function startJobs() {
    if (started || !lease || !brain.enabled) return;
    started = true;
    const min = 60000;
    // App opens seen by THIS node are written by this node (a few small documents); the leased job folds them.
    flushTimer = setInterval(() => brain.flushOpens().catch(() => {}), 10 * min);
    flushTimer.unref?.();
    lease.run('business-nightly', 24 * 60 * min, ({ signal } = {}) => brain.runNightly({ signal }), { firstDelayMs: 35 * min });
    lease.run('business-weekly-summary', 60 * min, () => summary.tick(), { firstDelayMs: 12 * min });
  }
  function stop() { if (flushTimer) clearInterval(flushTimer); flushTimer = null; }

  return { brain, servers, summary, router: r, startJobs, stop, riderCard };
}

module.exports = { attachBusiness, SIGNAL_LABEL };
