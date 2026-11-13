'use strict';
/**
 * Round 8: the background-work producers moved onto the job queue, and their handlers. Called once per process from
 * the app.js round 8 mount block, so a gateway and a separate worker (gateway/worker.js boots the same createApp)
 * register exactly the same handlers around exactly the same service objects: a job does what the inline code did.
 *
 *   type                     producer                                         handler
 *   email.security           security_routes securityMailer (codes, links,    the same mailer call (sealed payload,
 *                            notices): jobs.urgent, inline fallback            priority 0, removed when done)
 *   email.lifecycle          welcome + ride summary (lifecycle_emails.js)     lifecycle.process(key) (mail_log claim)
 *                            ride summary picture (route_png) renders here
 *   email.receipt / refund   purchase_email.js onOrderUpdated / receipt route sendReceipt / sendRefund (mail_log claim)
 *   push.fanout              PushService.notifyUsers outside a job            the original notifyUsers (FCM)
 *   roads.fetch              road_cells.js a missing / stale cell              one Overpass fetch under the budget
 *   photo.delete             avatars.js replaced pictures / stale originals    deleteAvatarDoc (Object Storage / DB)
 *   lease-routed batches     LEASE_ROUTES below                               the leased function itself
 *
 * Never routed: sos-sms, guardian-push, convoy-auto-end, retention, sessions, subscriptions, db-keepalive (SOS / alerts
 * / live rooms / safety). The SOS push of the app is the socket + SOS SMS path; PushService carries no SOS type.
 */
const { inJob } = require('./context');
const { Defer, RetryLater } = require('./errors');

/** Leased ticks whose WORK moves to the queue (the lease keeps the schedule). */
const LEASE_ROUTES = Object.freeze({
  'lifecycle-mail': { type: 'email.lifecycle_due', leaseMs: 5 * 60000 },
  'mail-retry': { type: 'email.receipt_retry', leaseMs: 5 * 60000 },
  'offer-emails': { type: 'email.offers_tick', leaseMs: 5 * 60000 },
  'email-studio': { type: 'email.studio_tick', leaseMs: 5 * 60000 },
  'business-weekly-summary': { type: 'email.business_summary', leaseMs: 5 * 60000 },
  'push-campaigns': { type: 'push.campaigns_tick', leaseMs: 5 * 60000 },
  'push-news-caps': { type: 'batch.push_caps_cleanup', leaseMs: 5 * 60000 },
  'business-nightly': { type: 'batch.business_nightly', leaseMs: 10 * 60000 },
  'intel-aggregate': { type: 'batch.intel_aggregate', leaseMs: 5 * 60000 },
  'intel-daily': { type: 'batch.intel_daily', leaseMs: 10 * 60000 },
  'rider-score-daily': { type: 'batch.rider_score', leaseMs: 10 * 60000 },
  'diag-log-retention': { type: 'batch.diag_retention', leaseMs: 5 * 60000 },
  'backup-critical': { type: 'batch.backup_critical', leaseMs: 10 * 60000 },
  'backup-full': { type: 'batch.backup_full', leaseMs: 10 * 60000 },
});
/** Lease names that must never go through the queue (asserted by test/jobs8_sos.test.js). */
const NEVER_ROUTED = Object.freeze(['sos-sms', 'guardian-push', 'convoy-auto-end', 'retention', 'auth-sessions-sweep', 'subscriptions', 'db-keepalive']);

const PUSH_CHUNK = 100;

function registerProducers({ jobs, notifications = null, push = null, security = null, roadCells = null, repo = null, logger = console } = {}) {
  // ---------------------------------------------------------------- security e-mails (codes first)
  if (security && security.mail && !security.mail.__jobs) {
    const m = security.mail;
    m.__jobs = true;
    const rawSend = m.send;
    const rawTemplate = m.sendTemplate;
    const mailOn = () => !!(notifications && notifications.mailer && notifications.mailer.enabled);
    jobs.register('email.security', async (p) => (p.k === 'template' ? rawTemplate(p.id, p.to, p.vars || {}) : rawSend(p.to, p.subject, p.lines || [])),
      { leaseMs: 30000, timeoutMs: 60000, maxAttempts: 4, backoffBaseMs: 2000, priority: 0 });
    m.send = (to, subject, lines) => {
      if (!to || !mailOn()) return rawSend(to, subject, lines);
      return jobs.urgent('email.security', { k: 'text', to, subject, lines }, {}, () => rawSend(to, subject, lines));
    };
    m.sendTemplate = (id, to, vars = {}) => {
      if (!to || !mailOn()) return rawTemplate(id, to, vars);
      return jobs.urgent('email.security', { k: 'template', id, to, vars }, {}, () => rawTemplate(id, to, vars));
    };
  }

  // ---------------------------------------------------------------- lifecycle (welcome, ride summary + route picture)
  if (notifications && notifications.lifecycle) {
    const life = notifications.lifecycle;
    life.jobs = jobs;
    jobs.register('email.lifecycle', async ({ key }) => life.process(String(key)), { leaseMs: 2 * 60000, timeoutMs: 3 * 60000, maxAttempts: 4, priority: 3 });
  }
  // ---------------------------------------------------------------- receipts / refunds
  if (notifications && notifications.purchaseEmail) {
    const pe = notifications.purchaseEmail;
    pe.jobs = jobs;
    jobs.register('email.receipt', async ({ orderId }) => pe.sendReceipt(String(orderId)), { leaseMs: 60000, timeoutMs: 2 * 60000, maxAttempts: 4, priority: 3 });
    jobs.register('email.refund', async ({ orderId }) => pe.sendRefund(String(orderId)), { leaseMs: 60000, timeoutMs: 2 * 60000, maxAttempts: 4, priority: 3 });
  }

  // ---------------------------------------------------------------- push fan-out
  if (push && typeof push.notifyUsers === 'function' && !push.__jobs) {
    push.__jobs = true;
    const direct = push.notifyUsers.bind(push);
    push.notifyUsersDirect = direct;
    jobs.register('push.fanout', async ({ userIds, opts }) => direct(userIds, opts || {}), { leaseMs: 2 * 60000, timeoutMs: 3 * 60000, maxAttempts: 3, priority: 4 });
    push.notifyUsers = async (userIds, opts = {}) => {
      const switchOff = (() => { try { const fl = push.flagsOf && push.flagsOf(); return !!(fl && typeof fl.isOn === 'function' && !fl.isOn('pushNotifications')); } catch { return false; } })();
      // Inside a job (a campaign tick on the worker), push off / unconfigured: the old direct path.
      if (!jobs.enabled || inJob() || !push.enabled || switchOff) return direct(userIds, opts);
      let ids = [...new Set((Array.isArray(userIds) ? userIds : [userIds]).filter((x) => typeof x === 'string' && x))].slice(0, 500);
      const out = { sent: 0, skipped: 0, failed: 0, queued: 0 };
      if (!ids.length) return out;
      // "Has a live socket" can only be answered here, where the sockets are: decided before enqueueing.
      if (opts.skipConnected) { const before = ids.length; ids = ids.filter((u) => !push._connected(u)); out.skipped += before - ids.length; }
      const { skipConnected, ...rest } = opts; // eslint-disable-line no-unused-vars
      const eventId = rest.data && typeof rest.data.eventId === 'string' ? rest.data.eventId.slice(0, 120) : '';
      const priority = rest.priority === 'high' ? 1 : 4;
      for (let i = 0; i < ids.length; i += PUSH_CHUNK) {
        const chunk = ids.slice(i, i + PUSH_CHUNK);
        try {
          await jobs.enqueue('push.fanout', { userIds: chunk, opts: rest }, { priority, ...(eventId ? { key: `push:${eventId}:${i / PUSH_CHUNK}` } : {}) });
          out.queued += chunk.length;
        } catch (e) {
          const r = await direct(chunk, rest); // the queue is down: never lose the notice
          out.sent += r.sent || 0; out.skipped += r.skipped || 0; out.failed += r.failed || 0;
        }
      }
      return out;
    };
  }

  // ---------------------------------------------------------------- road cells upstream
  if (roadCells && typeof roadCells.fetchForJob === 'function') {
    const roads = roadCells;
    roads.jobs = jobs;
    jobs.register('roads.fetch', async ({ cell }) => {
      const r = await roads.fetchForJob(String(cell));
      if (r.deferMs) throw new Defer(r.deferMs);
      if (r.retryMs) throw new RetryLater(r.retryMs, 'upstream refused');
      return r;
    }, { leaseMs: 60000, timeoutMs: 90000, maxAttempts: 5, backoffBaseMs: 30000, priority: 5 });
  }

  // ---------------------------------------------------------------- avatars / photos
  if (repo && repo.soda) {
    const A = require('../avatars');
    A.attachPhotoJobs(repo.soda, jobs);
    jobs.register('photo.delete', async ({ avatarIds }) => {
      let n = 0;
      for (const id of (Array.isArray(avatarIds) ? avatarIds : []).slice(0, 20)) {
        if (!A.isAvatarId(id) && !A.isOriginalId(id)) continue;
        if (await A.deleteAvatarDoc(repo.soda, id, {})) n++;
      }
      return { removed: n };
    }, { leaseMs: 60000, timeoutMs: 60000, maxAttempts: 5, priority: 6 });
  }
  logger.info?.(`[jobs] ${jobs.registry.size} job types registered${jobs.enabled ? '' : ' (JOBS_QUEUE=off: producers work inline)'}`);
  return jobs;
}

module.exports = { registerProducers, LEASE_ROUTES, NEVER_ROUTED, PUSH_CHUNK };
