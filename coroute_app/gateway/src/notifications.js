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
 *                            (3.57: ?c=ride_summaries|tips_news per category, lifecycle_emails.js)
 *   /api/web/email-preferences  the rider's e-mail categories (website)      (rider, 3.57)
 *   /api/admin/email/lifecycle/settings  welcome coupon setting              (admin, 3.57)
 *   /api/admin/email/studio/*  e-mail marketing studio: templates, campaigns, automation rules,
 *                            unique coupon codes, reports (admin, 3.57, email_marketing.js)
 *   /r/:token                signed click redirect of marketing e-mails       (public, HMAC)
 *   /email/preview/:token    the studio's sandboxed preview frame             (public, random token, 15 min)
 *   /api/sms/receipts/:provider/:token   provider delivery receipts           (public, token)
 *   /media/push/:file        push big pictures                                (public)
 * Jobs (leased, one node): push-campaigns (30 s), sos-sms retries + purge (15 s), mail-retry (5 min),
 * lifecycle-mail (1 min: welcome and ride summary e-mails, 3.57), email-studio (1 min: marketing campaigns
 * and automation rules, 3.57),
 * push-news-caps cleanup (6 h).
 */
const { requireAuth, requireAdmin } = require('./auth');
const { TemplateStore, templatesAdminRouter, fill } = require('./templates');
const { Mailer } = require('./mailer');
const { attachPurchaseEmail, receiptEmailRouter } = require('./purchase_email');
const { PushCampaigns, adminPushRouter, pushMediaRouter, pushPrefsRouter } = require('./push_campaigns');
const { SosSms, adminSmsRouter, smsReceiptsRouter } = require('./sos_sms');
const { OfferEmails, adminOfferEmailRouter, consentRouter, unsubscribeRouter } = require('./offer_emails');
const { LifecycleEmails, preferencesRouter, adminLifecycleRouter, categoryUnsubscribeRouter } = require('./lifecycle_emails');
const { EmailStudio, adminStudioRouter, publicStudioRouter } = require('./email_marketing');

const SYNC_TEMPLATES = ['push_plan_active', 'push_plan_ending', 'guardian_arrival'];

function attachNotifications({ app, repo, soda, gate, push = null, emergencyGateway = null, lease = null, config = {}, logger = console,
  mailTransport, smsProviders, smsFetch, imageStore, accessMode = null, env = process.env } = {}) {
  const templates = new TemplateStore({ soda, logger });
  const mailer = new Mailer({ ...(mailTransport !== undefined ? { transport: mailTransport } : {}), env, logger });
  const purchaseEmail = attachPurchaseEmail({ repo, mailer, templates, config, logger });
  const campaigns = new PushCampaigns({ soda, repo, push, origin: config.publicOrigin || '', logger, env, ...(imageStore ? { imageStore } : {}) });
  // 3.56 Offers e-mails (prices / coupons for CoRoute plans: e-mail only, to riders who opted in).
  const offers = new OfferEmails({ soda, repo, mailer, origin: config.publicOrigin || config.linkOrigin || '', secret: config.jwtSecret ? `${config.jwtSecret}:offers` : '', logger, env });
  // 3.57 lifecycle e-mails: welcome (new accounts) and ride summaries, e-mail categories (lifecycle_emails.js).
  const lifecycle = new LifecycleEmails({ soda, repo, mailer, templates, offers, accessMode, config,
    secret: config.jwtSecret ? `${config.jwtSecret}:lifecycle` : '', logger, env });
  // 3.57 e-mail marketing studio (email_marketing.js): templates, block editor, segments, unique codes, automation.
  const studio = new EmailStudio({ soda, repo, mailer, offers, campaigns, accessMode, config,
    secret: config.jwtSecret ? `${config.jwtSecret}:studio` : '', logger, env });
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
    app.use('/api/admin/templates', requireAuth(gate), requireAdmin, templatesAdminRouter({ templates, constants: () => ({ origin: config.publicOrigin || config.linkOrigin || '' }), audit,
      mailPreview: (id, rendered) => lifecycle.previewMail(id, rendered) }));
    app.use('/api/sms', smsReceiptsRouter({ sosSms, env }));
    app.use('/api/me/push-prefs', requireAuth(gate), pushPrefsRouter({ campaigns }));
    app.use('/api/web', receiptEmailRouter({ repo, gate, service: purchaseEmail }));
    app.use('/api/admin/email/lifecycle', requireAuth(gate), requireAdmin, adminLifecycleRouter({ lifecycle, audit }));
    app.use('/api/admin/email/studio', requireAuth(gate), requireAdmin, adminStudioRouter({ studio, audit }));
    app.use(publicStudioRouter({ studio }));
    app.use('/api/admin/email', requireAuth(gate), requireAdmin, adminOfferEmailRouter({ offers }));
    app.use('/api/web/marketing-consent', requireAuth(gate), consentRouter({ offers, repo }));
    app.use('/api/web/email-preferences', requireAuth(gate), preferencesRouter({ lifecycle, offers, repo }));
    // Category links (c=ride_summaries / tips_news) first; offer links (no c) fall through to the offers router.
    app.use(categoryUnsubscribeRouter({ lifecycle }));
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
      if (user && user.userId) await lifecycle.forgetUser(user.userId).catch(() => {});
      if (user && user.userId) await studio.forgetUser(user.userId).catch(() => {});
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
    lease.run('lifecycle-mail', 60000, () => lifecycle.processDue(), { firstDelayMs: 45000 });
    lease.run('email-studio', 60000, () => studio.tick(), { firstDelayMs: 50000 });
    lease.run('push-news-caps', 6 * 60 * min, () => campaigns.cleanup(), { firstDelayMs: 10 * min });
  }
  function stop() { clearInterval(timer); }

  return { templates, mailer, purchaseEmail, campaigns, offers, lifecycle, studio, sosSms, startJobs, stop, guardianArrivalText };
}

module.exports = { attachNotifications };
