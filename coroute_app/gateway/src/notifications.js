'use strict';
/**
 * 3.56 notifications wiring (one call from app.js): admin push campaigns, purchase / refund e-mails,
 * server SOS SMS and the editable message templates. Docs: docs/features_355/notifications_admin.md,
 * purchase_email.md, sos_sms.md.
 *
 * Routes:
 *   /api/admin/push/*        campaigns, images, test send, audience count   (admin)
 *   /api/admin/sms/*         SMS provider settings, test SMS, SMS log       (admin)
 *   /api/admin/templates/*   message templates (list, preview, save, reset, history) (admin)
 *   /api/me/push-prefs       the rider's "News and updates" switch            (rider)
 *   /api/web/receipt-email   optional receipt address of an order (website)   (rider)
 *   /api/admin/email/*       Offers e-mail campaigns, suppression list       (admin, 3.56)
 *   /api/web/marketing-consent  the rider's "Offer e-mails" consent (website) (rider, 3.56)
 *   /email/unsubscribe       unsubscribe link / RFC 8058 one-click           (public, HMAC token)
 *   /api/sms/receipts/:provider/:token   provider delivery receipts           (public, token)
 *   /media/push/:file        push big pictures                                (public)
 * Jobs (leased, one node): push-campaigns (30 s), sos-sms retries + purge (15 s), mail-retry (5 min),
 * push-news-caps cleanup (6 h).
 */
const { requireAuth, requireAdmin } = require('./auth');
const { TemplateStore, templatesAdminRouter, fill } = require('./templates');
const { Mailer } = require('./mailer');
const { attachPurchaseEmail, receiptEmailRouter } = require('./purchase_email');
const { PushCampaigns, adminPushRouter, pushMediaRouter, pushPrefsRouter } = require('./push_campaigns');
const { SosSms, adminSmsRouter, smsReceiptsRouter } = require('./sos_sms');
const { OfferEmails, adminOfferEmailRouter, consentRouter, unsubscribeRouter } = require('./offer_emails');

const SYNC_TEMPLATES = ['push_plan_active', 'push_plan_ending', 'guardian_arrival'];

function attachNotifications({ app, repo, soda, gate, push = null, emergencyGateway = null, lease = null, config = {}, logger = console,
  mailTransport, smsProviders, smsFetch, imageStore, env = process.env } = {}) {
  const templates = new TemplateStore({ soda, logger });
  const mailer = new Mailer({ ...(mailTransport !== undefined ? { transport: mailTransport } : {}), env, logger });
  const purchaseEmail = attachPurchaseEmail({ repo, mailer, templates, config, logger });
  const campaigns = new PushCampaigns({ soda, repo, push, origin: config.publicOrigin || '', logger, env, ...(imageStore ? { imageStore } : {}) });
  // 3.56 Offers e-mails (prices / coupons for CoRoute plans: e-mail only, to riders who opted in).
  const offers = new OfferEmails({ soda, repo, mailer, origin: config.publicOrigin || config.linkOrigin || '', secret: config.jwtSecret ? `${config.jwtSecret}:offers` : '', logger, env });
  const sosSms = new SosSms({ soda, templates, config, env, logger, ...(smsFetch ? { fetchImpl: smsFetch } : {}), ...(smsProviders ? { providers: smsProviders } : {}) });
  if (emergencyGateway) emergencyGateway.sosSms = sosSms;

  // Synchronous copies of the templates used on hot paths (plan push notices, guardian arrival).
  const cache = {};
  const refresh = async () => { for (const id of SYNC_TEMPLATES) cache[id] = await templates.fields(id).catch(() => cache[id]); };
  refresh().catch(() => {});
  const timer = setInterval(() => refresh().catch(() => {}), 60000);
  timer.unref?.();
  const save = templates.save.bind(templates);
  templates.save = async (...args) => { const out = await save(...args); refresh().catch(() => {}); return out; };
  try {
    require('./push').setPlanTextProvider((id, vars) => {
      const f = cache[id];
      return f ? { title: fill(f.title, vars), body: fill(f.body, vars) } : null;
    });
  } catch { /* push.js without the hook */ }
  const guardianArrivalText = () => (cache.guardian_arrival ? { title: cache.guardian_arrival.title, body: cache.guardian_arrival.body } : null);

  const audit = typeof repo.addAuditEntry === 'function' ? (e) => repo.addAuditEntry(e).catch(() => {}) : null;
  if (app) {
    app.use(pushMediaRouter({ campaigns }));
    app.use('/api/admin/push', requireAuth(gate), requireAdmin, adminPushRouter({ campaigns, push }));
    app.use('/api/admin/sms', requireAuth(gate), requireAdmin, adminSmsRouter({ sosSms }));
    app.use('/api/admin/templates', requireAuth(gate), requireAdmin, templatesAdminRouter({ templates, constants: () => ({ origin: config.publicOrigin || config.linkOrigin || '' }), audit }));
    app.use('/api/sms', smsReceiptsRouter({ sosSms, env }));
    app.use('/api/me/push-prefs', requireAuth(gate), pushPrefsRouter({ campaigns }));
    app.use('/api/web', receiptEmailRouter({ repo, gate, service: purchaseEmail }));
    app.use('/api/admin/email', requireAuth(gate), requireAdmin, adminOfferEmailRouter({ offers }));
    app.use('/api/web/marketing-consent', requireAuth(gate), consentRouter({ offers, repo }));
    app.use(unsubscribeRouter({ offers }));
  }

  // Account erase: the news switch and cap rows go with the account.
  if (repo && !repo.__newsCascade && typeof repo.deleteUserCascade === 'function') {
    repo.__newsCascade = true;
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await campaigns.forgetUser(user.userId).catch(() => {});
      if (user && user.userId) await offers.forgetUser(user.userId).catch(() => {});
      return out;
    };
  }

  let started = false;
  function startJobs() {
    if (started || !lease) return;
    started = true;
    const min = 60000;
    lease.run('push-campaigns', 30000, () => campaigns.tick(), { firstDelayMs: 20000 });
    lease.run('sos-sms', 15000, () => sosSms.tick(), { firstDelayMs: 15000 });
    lease.run('mail-retry', 5 * min, () => purchaseEmail.retryDue(), { firstDelayMs: 2 * min });
    lease.run('offer-emails', 60000, () => offers.tick(), { firstDelayMs: 30000 });
    lease.run('push-news-caps', 6 * 60 * min, () => campaigns.cleanup(), { firstDelayMs: 10 * min });
  }
  function stop() { clearInterval(timer); }

  return { templates, mailer, purchaseEmail, campaigns, offers, sosSms, startJobs, stop, guardianArrivalText };
}

module.exports = { attachNotifications };
