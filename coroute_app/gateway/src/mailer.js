'use strict';
/**
 * Outgoing e-mail over SMTP (nodemailer). Used for purchase receipts and refunds
 * (docs/features_355/purchase_email.md).
 *
 * Configuration (env, never in code):
 *   SMTP_HOST, SMTP_PORT (587 STARTTLS default; 465 = implicit TLS), SMTP_USER, SMTP_PASS,
 *   MAIL_FROM ("CoRoute <receipts@your-domain>"), optional MAIL_REPLY_TO, SMTP_SECURE=true|false.
 * Without SMTP_HOST and MAIL_FROM the mailer is DISABLED: send() is a no-op that answers
 * { sent: false, disabled: true } (logged once). TLS certificates are always verified.
 *
 * Logs never carry addresses or bodies: only the message id or the error code.
 */

const EMAIL_RE = /^[^\s@<>()",;:]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,24}$/;
const validEmail = (s) => typeof s === 'string' && s.length <= 254 && EMAIL_RE.test(s.trim());

function smtpConfigFromEnv(env = process.env) {
  const host = String(env.SMTP_HOST || '').trim();
  const from = String(env.MAIL_FROM || '').trim();
  if (!host || !from) return null;
  const port = Number(env.SMTP_PORT) || 587;
  const secure = env.SMTP_SECURE ? String(env.SMTP_SECURE).toLowerCase() === 'true' : port === 465;
  const user = String(env.SMTP_USER || '').trim();
  return {
    transport: { host, port, secure, requireTLS: !secure, auth: user ? { user, pass: String(env.SMTP_PASS || '') } : undefined,
      connectionTimeout: 10000, greetingTimeout: 10000, socketTimeout: 20000, tls: { rejectUnauthorized: true, minVersion: 'TLSv1.2' } },
    from,
    replyTo: String(env.MAIL_REPLY_TO || '').trim() || undefined,
  };
}

class Mailer {
  /**
   * @param {object} o
   * @param {object|null} [o.transport]  a nodemailer transport (tests: a fake with sendMail); undefined = from env
   * @param {string} [o.from]
   */
  constructor({ transport, from, replyTo, env = process.env, logger = console } = {}) {
    this.logger = logger;
    this.warned = false;
    if (transport !== undefined) {
      this.transport = transport; this.from = from || 'CoRoute <no-reply@example.invalid>'; this.replyTo = replyTo;
    } else {
      const cfg = smtpConfigFromEnv(env);
      this.from = cfg ? cfg.from : ''; this.replyTo = cfg ? cfg.replyTo : undefined;
      this.transport = null;
      if (cfg) {
        try { this.transport = require('nodemailer').createTransport(cfg.transport); } catch (e) { logger.warn?.(`[mail] SMTP transport not created: ${e.code || e.message}`); }
      }
    }
  }

  get enabled() { return !!this.transport; }

  /** { to, subject, text, html } -> { sent, messageId?, disabled?, error? }. Never throws. */
  async send({ to, subject, text, html, headers }) {
    if (!this.transport) {
      if (!this.warned) { this.warned = true; this.logger.info?.('[mail] SMTP is not configured (SMTP_HOST / MAIL_FROM): e-mails are off'); }
      return { sent: false, disabled: true };
    }
    if (!validEmail(to)) return { sent: false, error: 'BAD_ADDRESS' };
    try {
      const info = await this.transport.sendMail({ from: this.from, to: to.trim(), replyTo: this.replyTo, subject: String(subject || '').slice(0, 200), text, html, headers });
      return { sent: true, messageId: (info && info.messageId) || null };
    } catch (e) {
      const code = String((e && (e.code || e.responseCode)) || 'SEND_FAILED').slice(0, 40);
      this.logger.warn?.(`[mail] send failed: ${code}`);
      return { sent: false, error: code };
    }
  }
}

module.exports = { Mailer, smtpConfigFromEnv, validEmail };
