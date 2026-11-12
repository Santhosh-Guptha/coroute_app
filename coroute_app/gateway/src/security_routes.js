'use strict';
/**
 * 3.57 security: session, sign-out, password reset, re-authentication, e-mail change and 2-step verification
 * endpoints, plus the cookie / CSRF helpers the sign-in routes use. docs/features_355/sessions_and_security.md
 *
 * Public (rate limited):
 *   POST /api/auth/refresh                 { refreshToken? , client? }  (website: httpOnly cookie)  -> new access token
 *   POST /api/auth/logout                  Bearer and/or refresh token / cookie                    -> session revoked, cookie cleared
 *   POST /api/auth/password/forgot         { email }  always 202, the link (30 min, single use) goes by e-mail
 *   POST /api/auth/password/reset          { token, newPassword }  every session of the account ends
 *   POST /api/auth/email/confirm           { token }  confirms a change of e-mail (link sent to the new address)
 *   POST /api/auth/mfa/verify              { mfaToken, code | recoveryCode }  second sign-in step -> session
 *   POST /api/auth/mfa/enroll/start        { mfaToken }  admin without 2-step yet: secret + otpauth URL
 *   POST /api/auth/mfa/enroll/confirm      { mfaToken, code }  -> session + recovery codes (shown once)
 * Signed in:
 *   POST   /api/auth/logout-all            every session and token of the account ends (sockets closed)
 *   POST   /api/auth/reauth                { password | idToken }  marks this session recently re-authenticated
 *   GET    /api/me/sessions                "Where you're signed in"
 *   DELETE /api/me/sessions/:sessionId     sign one of my sessions out (another user's reads as not found)
 *   GET    /api/me/security                2-step status, eligibility, password set, session count
 *   POST   /api/me/email                   { newEmail, currentPassword? }  re-auth, link to the new address, notice to the old
 *   POST   /api/me/mfa/setup | /confirm | /recovery-codes,  DELETE /api/me/mfa   (re-auth needed)
 *
 * Website cookies: __Host-cr_rt (rider site, SameSite=Lax), __Host-cr_adm (/admin) and __Host-cr_op (/operator)
 * (SameSite=Strict); all Secure, HttpOnly, Path=/, never readable by page scripts. Requests that use a cookie
 * must carry `X-CoRoute-CSRF: 1` (a custom header no other site can send without a CORS preflight, which the
 * strict CORS allowlist refuses) and, when the browser sends Origin, an allowed origin.
 */
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const { requireAuth, verifyTokenDetailed, AuthError, publicUser } = require('./auth');
const { SessionStore, policyOf, RT_RE, sha256 } = require('./sessions');
const { siteOriginsOf } = require('./domains');

const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
const COOKIE_NAMES = Object.freeze({ web: '__Host-cr_rt', admin: '__Host-cr_adm', operator: '__Host-cr_op' });

/** The client context of a sign-in request: which kind of session, device label, IP and user agent. */
function ctxOf(req) {
  const b = req.body && typeof req.body === 'object' ? req.body : {};
  const client = String(b.client || req.get('X-CoRoute-Client') || '').toLowerCase().slice(0, 12);
  const dev = b.device && typeof b.device === 'object' ? b.device : {};
  return {
    client,
    v2: String(req.get('X-CoRoute-Session') || '') === '2',
    device: {
      label: typeof dev.label === 'string' ? dev.label : '', platform: typeof dev.platform === 'string' ? dev.platform : '',
      // Round 4 ride lock: the app's device id (hashed on the phone) and install id; only keyed hashes are stored.
      id: typeof dev.id === 'string' ? dev.id.slice(0, 128) : '', installId: typeof dev.installId === 'string' ? dev.installId.slice(0, 128) : '',
    },
    build: buildOf(req),
    ip: req.ip || '',
    ua: String(req.get('user-agent') || '').slice(0, 300),
  };
}

/** The app build of a request (X-CoRoute-Build), 0 when absent (website, scripts, builds before 65). */
function buildOf(req) {
  const n = parseInt(String((req.get && req.get('X-CoRoute-Build')) || ''), 10);
  return Number.isInteger(n) && n > 0 && n < 1000000 ? n : 0;
}

/**
 * Round 4 compatibility: a request from an app build older than MODERN_APP_BUILD (10025) or an API client that is
 * neither a website / console nor a build >= 10025. These keep the behaviours old builds understand.
 */
function isLegacyClient(req) {
  const ctx = typeof req === 'object' && req && req.get ? { client: String((req.body && req.body.client) || req.get('X-CoRoute-Client') || '').toLowerCase(), build: buildOf(req) } : req;
  if (['web', 'admin', 'operator'].includes(ctx.client)) return false;
  return !(ctx.build >= config.modernAppBuild);
}

function parseCookies(req) {
  const out = {};
  const h = String(req.headers.cookie || '');
  if (!h || h.length > 8192) return out;
  for (const part of h.split(';')) {
    const i = part.indexOf('=');
    if (i <= 0) continue;
    const k = part.slice(0, i).trim();
    if (!k || out[k] !== undefined) continue;
    try { out[k] = decodeURIComponent(part.slice(i + 1).trim()); } catch { /* ignore a malformed value */ }
  }
  return out;
}

function setRefreshCookie(res, kind, token) {
  const name = COOKIE_NAMES[kind];
  if (!name) return;
  const pol = policyOf(kind);
  res.cookie(name, token, { httpOnly: true, secure: true, sameSite: pol.sameSite === 'Strict' ? 'strict' : 'lax', path: '/', maxAge: pol.absMs, encode: String });
}
function clearRefreshCookie(res, kind) {
  const name = COOKIE_NAMES[kind];
  if (!name) return;
  const pol = policyOf(kind);
  res.clearCookie(name, { httpOnly: true, secure: true, sameSite: pol.sameSite === 'Strict' ? 'strict' : 'lax', path: '/' });
}

/**
 * Sends a sign-in result. Website kinds: the refresh token goes into its httpOnly cookie, never into the body.
 * The app (and older builds) read `token` and `user` as before; a 2-step answer ({ mfa, mfaToken }) passes through.
 */
function sendSession(res, result, status = 200) {
  res.set('Cache-Control', 'no-store');
  if (result && result.refreshToken && COOKIE_NAMES[result.sessionKind]) {
    setRefreshCookie(res, result.sessionKind, result.refreshToken);
    const { refreshToken, ...rest } = result;
    void refreshToken;
    return res.status(status).json(rest);
  }
  return res.status(status).json(result);
}

/**
 * CSRF guard for requests authenticated by a cookie: the custom header, and an allowed Origin when one is sent.
 * Returns an error message or null.
 */
function csrfProblem(req, allowed) {
  if (String(req.get('X-CoRoute-CSRF') || '') !== '1') return 'Missing request header.';
  const origin = req.get('origin');
  if (origin) {
    const o = String(origin).toLowerCase();
    let sameHost = false;
    try { sameHost = new URL(o).host === String(req.get('host') || '').toLowerCase(); } catch { sameHost = false; }
    if (!sameHost && !allowed.has(o)) return 'Request from another site refused.';
  }
  return null;
}

function maskEmail(e) {
  const [a, d] = String(e || '').split('@');
  if (!a || !d) return 'your address';
  return `${a[0]}***@${d}`;
}
const istTime = (ms) => {
  try { return new Date(ms).toLocaleString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata' }) + ' IST'; } catch { return new Date(ms).toISOString(); }
};

/** Transactional security e-mails (plain text). Never throws; never logs addresses (the mailer logs codes only). */
function securityMailer({ mailerOf, origin, logger = console }) {
  const send = (to, subject, lines) => {
    const mailer = mailerOf ? mailerOf() : null;
    if (!mailer || !to) return Promise.resolve({ sent: false });
    const text = [...lines, '', '— CoRoute', `${origin}/security`].join('\n');
    return Promise.resolve(mailer.send({ to, subject, text, headers: { 'X-CoRoute-Mail': 'security' } }))
      .catch((e) => { logger.warn?.(`[security-mail] ${e && e.message}`); return { sent: false }; });
  };
  /** Round 4 templates (src/security_emails.js): text + HTML. Resolves { sent } and never throws. */
  const sendTemplate = (id, to, vars = {}) => {
    const mailer = mailerOf ? mailerOf() : null;
    if (!mailer || !to) return Promise.resolve({ sent: false });
    let m;
    try { m = require('./security_emails').render(id, vars, { origin }); } catch (e) { logger.warn?.(`[security-mail] ${e.message}`); return Promise.resolve({ sent: false }); }
    return Promise.resolve(mailer.send({ to, subject: m.subject, text: m.text, html: m.html, headers: { 'X-CoRoute-Mail': 'security', 'X-CoRoute-Template': id } }))
      .catch((e) => { logger.warn?.(`[security-mail] ${e && e.message}`); return { sent: false }; });
  };
  return {
    send,
    sendTemplate,
    onEvent(type, user, data = {}) {
      if (!user || !user.email) return;
      const acct = `${origin}/account`;
      switch (type) {
        case 'NEW_DEVICE':
          send(user.email, `New sign-in to CoRoute on ${String(data.device || 'a new device').slice(0, 60)}`, [
            `Hi ${user.name || 'rider'},`, '',
            `Your CoRoute account was just used to sign in on ${data.device || 'a new device'} (${istTime(data.at || Date.now())}).`, '',
            'If this was you, there is nothing to do.',
            `If it was not you: reset your password from ${origin}/signin (Forgot password?) and choose "Sign out of all devices" at ${acct}.`,
          ]);
          break;
        case 'ACCOUNT_LOCKED':
          send(user.email, 'CoRoute: sign-in paused after too many attempts', [
            `Hi ${user.name || 'rider'},`, '',
            `There were too many wrong passwords for your CoRoute account, so password sign-in is paused for ${data.minutes || 15} minutes.`,
            `If this was not you, reset your password from ${origin}/signin (Forgot password?). Safety features in the app keep working.`,
          ]);
          break;
        case 'PASSWORD_CHANGED':
          send(user.email, 'Your CoRoute password was changed', [
            `Hi ${user.name || 'rider'},`, '',
            `The password of your CoRoute account was ${data.reset ? 'reset' : 'changed'} (${istTime(Date.now())}). Other devices were signed out.`,
            `If you did not do this, reset it now from ${origin}/signin (Forgot password?).`,
          ]);
          break;
        case 'EMAIL_CHANGED':
          send(data.from || user.email, 'Your CoRoute e-mail address was changed', [
            `Hi ${user.name || 'rider'},`, '',
            `The e-mail address of your CoRoute account was changed to ${maskEmail(data.to)} (${istTime(Date.now())}).`,
            'If you did not do this, reply to this e-mail or use Send feedback in the app straight away.',
          ]);
          break;
        case 'MFA_ENABLED':
        case 'MFA_DISABLED':
        case 'MFA_RECOVERY_USED':
          send(user.email, type === 'MFA_ENABLED' ? 'CoRoute: 2-step verification is on' : type === 'MFA_DISABLED' ? 'CoRoute: 2-step verification was turned off' : 'CoRoute: a recovery code was used', [
            `Hi ${user.name || 'rider'},`, '',
            type === 'MFA_RECOVERY_USED' ? `A recovery code was used to sign in (${data.left} left).` : `2-step verification was turned ${type === 'MFA_ENABLED' ? 'on' : 'off'} for your account.`,
            'If this was not you, reset your password and sign out of all devices.',
          ]);
          break;
        default:
      }
    },
  };
}

/**
 * Mounts the endpoints. Call before the main /api router (its catch-all requireAuth would answer first).
 * @param {{app: any, auth: any, gate: any, sessions: any, mailerOf?: () => any, logger?: object}} deps
 */
function attachSecurityRoutes({ app, auth, gate, sessions, rideLock = null, mailerOf = null, logger = console }) {
  const origin = config.publicOrigin || '';
  const allowed = new Set([...siteOriginsOf(config), ...config.corsOrigins].map((o) => String(o).toLowerCase()));
  const mail = securityMailer({ mailerOf, origin, logger });
  auth.onSecurityEvent = (type, user, data) => mail.onEvent(type, user, data);
  // Round 4: verification links, ride sign-in codes, 2-step codes and notices go out as SMTP templates.
  auth.mailTemplate = (id, to, vars) => mail.sendTemplate(id, to, vars);
  if (rideLock) rideLock.mail = (id, to, vars) => mail.sendTemplate(id, to, vars);

  const limit = (windowMs, n, key) => rateLimit({ windowMs, limit: n, standardHeaders: 'draft-7', legacyHeaders: false,
    ...(key ? { keyGenerator: key } : {}), message: { error: 'Too many attempts, try again later.', code: 'RATE_LIMITED' } });
  const refreshLimiter = limit(60000, 60);
  const logoutLimiter = limit(60000, 30);
  const forgotIpLimiter = limit(15 * 60000, 5);
  const forgotMailLimiter = limit(60 * 60000, 3, (req) => `forgot:${String(req.body?.email || '').trim().toLowerCase().slice(0, 120)}`);
  const resetLimiter = limit(15 * 60000, 10);
  const mfaLimiter = limit(5 * 60000, 10);
  const reauthLimiter = limit(15 * 60000, 10, (req) => `reauth:${req.user ? req.user.userId : req.ip}`);
  // Round 4: e-mailed codes and links (each also rate limited per account, src/email_codes.js / auth.js).
  const codeSendLimiter = limit(15 * 60000, 10);
  const codeVerifyLimiter = limit(15 * 60000, 20);
  const verifyLinkLimiter = limit(15 * 60000, 20);
  const resendIpLimiter = limit(15 * 60000, 5);
  const resendMailLimiter = limit(60 * 60000, 3, (req) => `resend:${String(req.body?.email || '').trim().toLowerCase().slice(0, 120)}`);
  const authed = requireAuth(gate);
  const r = express.Router();

  /** The refresh token of this request and the session kind it may belong to. */
  function refreshOf(req) {
    const b = req.body && typeof req.body === 'object' ? req.body : {};
    if (typeof b.refreshToken === 'string' && b.refreshToken) return { token: b.refreshToken, kind: null, cookie: false };
    const ctx = ctxOf(req);
    const kind = COOKIE_NAMES[ctx.client] ? ctx.client : null;
    if (!kind) return { token: '', kind: null, cookie: false };
    return { token: parseCookies(req)[COOKIE_NAMES[kind]] || '', kind, cookie: true };
  }

  r.post('/auth/refresh', refreshLimiter, wrap(async (req, res) => {
    const rt = refreshOf(req);
    if (rt.cookie) {
      const bad = csrfProblem(req, allowed);
      if (bad) return res.status(403).json({ error: bad, code: 'CSRF' });
    }
    // No refresh token at all (a console page opened without a session cookie): nothing to refresh, not an error.
    if (!rt.token) return res.status(204).end();
    let out;
    try {
      out = await sessions.refresh(rt.token, { kindHint: rt.kind });
    } catch (e) {
      if (rt.cookie) clearRefreshCookie(res, rt.kind);
      if (e && e.name === 'SessionError') return res.status(401).json({ error: e.message, code: 'SESSION_INVALID' });
      throw e;
    }
    let user;
    try {
      user = await gate._checkUser({ sub: out.session.userId, iat: Math.floor(Date.now() / 1000) });
    } catch (e) {
      if (rt.cookie) clearRefreshCookie(res, rt.kind);
      if (e instanceof AuthError) return res.status(e.status).json({ error: e.message, code: e.code });
      throw e;
    }
    // Round 4 ride lock: a session that never passed the lock check, created after the ride began on another
    // device, may not mint tokens during the ride (sessions signed in before stay signed in).
    if (rideLock) {
      try { await rideLock.checkRefresh(out.session, user); } catch (e) {
        if (e instanceof AuthError) return res.status(e.status).json({ error: e.message, code: e.code, ...(e.extra || {}) });
        throw e;
      }
    }
    const token = auth.issueToken(user, { sid: out.session.sessionId, short: true });
    const body = { token, accessExpiresAt: Date.now() + config.accessTokenTtlMin * 60000, sessionId: out.session.sessionId,
      user: { ...publicUser(user), mfa: !!out.session.mfa } };
    if (COOKIE_NAMES[out.session.kind]) setRefreshCookie(res, out.session.kind, out.refreshToken);
    else body.refreshToken = out.refreshToken;
    res.json(body);
  }));

  r.post('/auth/logout', logoutLimiter, wrap(async (req, res) => {
    const ctx = ctxOf(req);
    const revoked = [];
    // 1) the Bearer token's session (an expired short token still names its session; the signature is checked).
    const h = req.headers.authorization || '';
    const v = h.startsWith('Bearer ') ? verifyTokenDetailed(h.slice(7), { allowExpired: true }) : null;
    if (v && v.claims.sid) {
      const s = await sessions.get(String(v.claims.sid)).catch(() => null);
      if (s && s.userId === v.claims.sub && await sessions.revoke(s.sessionId, 'SIGNED_OUT')) revoked.push(s.kind);
    }
    // 2) the refresh token (body or cookie): only a token that matches its session's current or previous hash.
    const rt = refreshOf(req);
    if (rt.cookie && csrfProblem(req, allowed)) return res.status(403).json({ error: 'Request from another site refused.', code: 'CSRF' });
    const m = RT_RE.exec(String(rt.token || ''));
    if (m) {
      const s = await sessions.get(m[1]).catch(() => null);
      const hsh = sha256(rt.token);
      if (s && (hsh === s.refreshHash || hsh === s.prevRefreshHash) && await sessions.revoke(s.sessionId, 'SIGNED_OUT')) revoked.push(s.kind);
    }
    for (const k of new Set([...revoked, ctx.client])) clearRefreshCookie(res, k);
    // Cached private pages are dropped from the browser cache (the Back button cannot show them).
    if (COOKIE_NAMES[ctx.client]) res.set('Clear-Site-Data', '"cache"');
    res.json({ ok: true, revoked: revoked.length });
  }));

  r.post('/auth/password/forgot', forgotIpLimiter, forgotMailLimiter, wrap(async (req, res) => {
    const email = String(req.body?.email || '').trim().toLowerCase();
    const started = Date.now();
    try {
      const out = await auth.requestPasswordReset(email);
      if (out) {
        mail.send(out.user.email, 'Reset your CoRoute password', [
          `Hi ${out.user.name || 'rider'},`, '',
          'Someone (hopefully you) asked to reset the password of your CoRoute account.',
          `Open this link within ${config.passwordResetTtlMin} minutes to choose a new password. It works once:`, '',
          `${origin}/signin#reset=${out.token}`, '',
          'If you did not ask for this, ignore this e-mail: your password stays the same.',
        ]);
      }
    } catch (e) { logger.warn?.(`[auth] reset request failed: ${e && e.message}`); }
    // The same answer, after about the same time, whether or not the account exists.
    const wait = 400 - (Date.now() - started);
    if (wait > 0 && config.env !== 'test') await new Promise((ok) => setTimeout(ok, wait));
    res.status(202).json({ ok: true, message: 'If an account uses this address, we sent it a link to reset the password. The link works for 30 minutes.' });
  }));

  r.post('/auth/password/reset', resetLimiter, wrap(async (req, res) => {
    res.json(await auth.resetPassword({ token: req.body?.token, newPassword: req.body?.newPassword }));
  }));

  r.post('/auth/email/confirm', resetLimiter, wrap(async (req, res) => {
    res.json(await auth.confirmEmailChange(req.body?.token));
  }));

  r.post('/auth/mfa/verify', mfaLimiter, wrap(async (req, res) => {
    sendSession(res, await auth.mfaVerifyLogin({ mfaToken: req.body?.mfaToken, code: req.body?.code, recoveryCode: req.body?.recoveryCode, emailCode: req.body?.emailCode }, ctxOf(req)));
  }));
  // Round 4: an e-mailed 2-step code for the sign-in step (operators without an authenticator app; never MASTER_ADMIN).
  r.post('/auth/mfa/email-code', codeSendLimiter, wrap(async (req, res) => {
    res.status(202).json(await auth.mfaSendEmailCodeLogin({ mfaToken: req.body?.mfaToken }));
  }));

  // ---- Round 4 ride lock override: "Use e-mail code" after a 423 RIDE_ACTIVE_ELSEWHERE ----
  r.post('/auth/ride-lock/code', codeSendLimiter, wrap(async (req, res) => {
    if (!rideLock) return res.status(404).json({ error: 'Not available.', code: 'NOT_FOUND' });
    res.status(202).json(await rideLock.sendCode(req.body?.lockToken));
  }));
  r.post('/auth/ride-lock/verify', codeVerifyLimiter, wrap(async (req, res) => {
    if (!rideLock) return res.status(404).json({ error: 'Not available.', code: 'NOT_FOUND' });
    const out = await rideLock.verifyCode(req.body?.lockToken, req.body?.code, ctxOf(req));
    const result = await auth._issue(out.user, out.ctx, { mfa: out.mfa, rideLockPassed: true });
    sendSession(res, { ...result, handedOver: out.handedOver });
  }));

  // ---- Round 4 sign-up e-mail verification ----
  r.post('/auth/email/verify', verifyLinkLimiter, wrap(async (req, res) => {
    res.json(await auth.verifyEmail(req.body?.token));
  }));
  r.post('/auth/register/resend', resendIpLimiter, resendMailLimiter, wrap(async (req, res) => {
    const started = Date.now();
    try { await auth.resendVerification(req.body?.email); } catch (e) { logger.warn?.(`[auth] resend failed: ${e && e.message}`); }
    const wait = 400 - (Date.now() - started);
    if (wait > 0 && config.env !== 'test') await new Promise((ok) => setTimeout(ok, wait));
    res.status(202).json({ ok: true, message: 'If this address is waiting for confirmation, we sent a new link. Check your inbox and spam folder.', resendAfterSec: 60 });
  }));
  r.post('/auth/mfa/enroll/start', mfaLimiter, wrap(async (req, res) => {
    res.json(await auth.mfaEnrollStartLogin({ mfaToken: req.body?.mfaToken }));
  }));
  r.post('/auth/mfa/enroll/confirm', mfaLimiter, wrap(async (req, res) => {
    sendSession(res, await auth.mfaEnrollConfirmLogin({ mfaToken: req.body?.mfaToken, code: req.body?.code }, ctxOf(req)));
  }));

  // ---- signed in ----
  r.post('/auth/logout-all', authed, wrap(async (req, res) => {
    const n = await auth.revokeAllSessions(req.user.userId, 'SIGNED_OUT_EVERYWHERE');
    const ctx = ctxOf(req);
    for (const k of Object.keys(COOKIE_NAMES)) clearRefreshCookie(res, k);
    if (COOKIE_NAMES[ctx.client]) res.set('Clear-Site-Data', '"cache"');
    res.json({ ok: true, revoked: n });
  }));

  // Round 4: 2-step step-up of a signed-in session (the app's admin screens on MFA_REQUIRED).
  r.post('/auth/mfa/step-up', authed, mfaLimiter, wrap(async (req, res) => {
    res.json(await auth.mfaStepUp(req.user.userId, req.sessionSid, { code: req.body?.code, recoveryCode: req.body?.recoveryCode, emailCode: req.body?.emailCode }));
  }));
  r.post('/auth/mfa/step-up/email-code', authed, codeSendLimiter, wrap(async (req, res) => {
    res.status(202).json(await auth.mfaSendEmailCode(req.dbUser, { where: 'admin tools in the CoRoute app' }));
  }));

  r.post('/auth/reauth', authed, reauthLimiter, wrap(async (req, res) => {
    await auth.verifyIdentity(req.user.userId, { password: req.body?.password, idToken: req.body?.idToken });
    if (req.sessionSid) await sessions.markReauth(req.sessionSid);
    res.json({ ok: true, validForMin: config.reauthWindowMin });
  }));

  r.get('/me/sessions', authed, wrap(async (req, res) => {
    const list = await sessions.list(req.user.userId);
    res.json({ sessions: list.map((s) => ({ ...s, current: s.sessionId === req.sessionSid })) });
  }));

  r.delete('/me/sessions/:sessionId', authed, wrap(async (req, res) => {
    const s = await sessions.get(String(req.params.sessionId || '')).catch(() => null);
    // Another rider's session reads exactly like a missing one.
    if (!s || s.userId !== req.user.userId || s.revokedAt) return res.status(404).json({ error: 'Session not found', code: 'NOT_FOUND' });
    await sessions.revoke(s.sessionId, 'SIGNED_OUT_REMOTE', { by: req.user.userId });
    res.json({ ok: true, current: s.sessionId === req.sessionSid });
  }));

  /** Sensitive actions: the current password in the body, or a re-authentication within REAUTH_WINDOW_MIN. */
  async function requireRecentAuth(req) {
    const b = req.body || {};
    if ((typeof b.currentPassword === 'string' && b.currentPassword) || (typeof b.idToken === 'string' && b.idToken)) {
      await auth.verifyIdentity(req.user.userId, { password: b.currentPassword, idToken: b.idToken });
      return;
    }
    if (req.authSession && sessions.recentlyAuthenticated(await sessions.get(req.authSession.sessionId))) return;
    throw new AuthError('Confirm it is you first.', 403, 'REAUTH_REQUIRED');
  }

  r.get('/me/security', authed, wrap(async (req, res) => {
    const u = req.dbUser;
    res.json({
      mfaEnabled: !!u.mfaEnabled, mfaEmail: !!u.mfaEmail && u.role !== 'MASTER_ADMIN', mfaEligible: await auth.mfaEligible(u), mfaRecoveryLeft: Array.isArray(u.mfaRecovery) ? u.mfaRecovery.length : 0,
      passwordSet: !!u.passwordHash, provider: u.provider || 'password', sessionKind: req.authSession ? req.authSession.kind : null,
      sessions: (await sessions.list(u.userId)).length,
    });
  }));

  r.post('/me/email', authed, reauthLimiter, wrap(async (req, res) => {
    await requireRecentAuth(req);
    const out = await auth.requestEmailChange(req.user.userId, req.body?.newEmail);
    if (out.token) {
      mail.send(out.newEmail, 'Confirm your new CoRoute e-mail address', [
        `Hi ${out.user.name || 'rider'},`, '',
        'Open this link within 30 minutes to use this address for your CoRoute account:', '',
        `${origin}/account#confirm-email=${out.token}`, '',
        'If you did not ask for this, ignore this e-mail.',
      ]);
      mail.send(out.user.email, 'CoRoute: a change of e-mail address was requested', [
        `Hi ${out.user.name || 'rider'},`, '',
        `Someone signed in to your account asked to change its e-mail address to ${maskEmail(out.newEmail)}. Nothing changes until the new address confirms it.`,
        'If this was not you, change your password and sign out of all devices.',
      ]);
    }
    res.status(202).json({ ok: true, message: 'Check the new address for a confirmation link (valid 30 minutes).' });
  }));

  r.post('/me/mfa/setup', authed, reauthLimiter, wrap(async (req, res) => {
    if (!(await auth.mfaEligible(req.dbUser))) return res.status(403).json({ error: '2-step verification is for administrators and operators.', code: 'NOT_ELIGIBLE' });
    await requireRecentAuth(req);
    res.json(await auth.mfaSetup(req.dbUser));
  }));
  r.post('/me/mfa/confirm', authed, mfaLimiter, wrap(async (req, res) => {
    const out = await auth.mfaConfirm(req.dbUser, req.body?.code);
    if (req.sessionSid) await sessions.markMfa(req.sessionSid);
    // Other sessions continue, but their next web console sign-in asks for a code.
    res.json({ ok: true, recoveryCodes: out.recoveryCodes });
  }));
  r.post('/me/mfa/recovery-codes', authed, reauthLimiter, wrap(async (req, res) => {
    await requireRecentAuth(req);
    res.json(await auth.mfaNewRecoveryCodes(req.user.userId));
  }));
  // Round 4: e-mailed 2-step codes for operators without an authenticator app (not for MASTER_ADMIN).
  r.post('/me/mfa/email', authed, reauthLimiter, wrap(async (req, res) => {
    if (!(await auth.mfaEligible(req.dbUser))) return res.status(403).json({ error: '2-step verification is for administrators and operators.', code: 'NOT_ELIGIBLE' });
    await requireRecentAuth(req);
    res.json(await auth.mfaSetEmail(req.user.userId, req.body?.enable !== false));
  }));
  r.delete('/me/mfa', authed, reauthLimiter, wrap(async (req, res) => {
    await requireRecentAuth(req);
    res.json(await auth.mfaDisable(req.user.userId));
  }));

  // Errors with a machine-readable code keep it (the app and the website act on codes, never on words).
  r.use((err, req, res, next) => {
    const { ValidationError } = require('./validate');
    if (err instanceof AuthError) return res.status(err.status).json({ error: err.message, ...(err.code ? { code: err.code } : {}), ...(err.extra && typeof err.extra === 'object' ? err.extra : {}) });
    if (err instanceof ValidationError) return res.status(err.status).json({ error: err.message, code: err.code, fields: err.fields });
    return next(err);
  });
  app.use('/api', r);
  return { requireRecentAuth, mail };
}

module.exports = { attachSecurityRoutes, sendSession, ctxOf, buildOf, isLegacyClient, parseCookies, csrfProblem, setRefreshCookie, clearRefreshCookie, COOKIE_NAMES, securityMailer };
