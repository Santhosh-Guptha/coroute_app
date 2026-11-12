'use strict';
/**
 * Round 4: one-time codes sent by e-mail (ride lock override, e-mail 2-step for operators).
 *
 *  - 6 digits from crypto.randomInt; only an HMAC (JWT_SECRET, purpose, user, binding, code) is stored, on the user
 *    document (`ec_<purpose>`), with its expiry (EMAIL_CODE_TTL_MIN, 10 min) and wrong tries (EMAIL_CODE_MAX_TRIES, 5).
 *  - Single use: a right code is removed at once; the 5th wrong try removes it too (a new code must be sent).
 *  - Rate limited per account and purpose: one code per 60 s, at most 5 per hour (stored with the account, so both
 *    gateway nodes see it), plus the per-IP limiters of the routes.
 *  - `bind`: the code only works with the sign-in attempt it was sent for (the ride lock token id).
 */
const crypto = require('crypto');
const config = require('./config');
const { AuthError } = require('./auth');

const RESEND_SEC = 60;
const PER_HOUR = 5;

class EmailCodes {
  constructor({ repo, clock = () => Date.now() } = {}) { this.repo = repo; this.clock = clock; }

  _hash(purpose, userId, bind, code) {
    return crypto.createHmac('sha256', String(config.jwtSecret)).update(`emailcode|${purpose}|${userId}|${bind || ''}|${code}`).digest('hex');
  }

  /** Creates (or replaces) the code. Returns { code, expiresAt, resendAfterSec }. Throws 429 RATE_LIMITED. */
  async issue(user, purpose, { bind = '' } = {}) {
    const fresh = await this.repo.findUserById(user.userId);
    if (!fresh) throw new AuthError('This sign-in step expired. Sign in again.', 401, 'CODE_EXPIRED');
    const t = this.clock();
    const sentKey = `ec_${purpose}_sent`;
    const sent = (Array.isArray(fresh[sentKey]) ? fresh[sentKey] : []).filter((x) => t - x < 3600000);
    const last = sent.length ? Math.max(...sent) : 0;
    if (t - last < RESEND_SEC * 1000) {
      const e = new AuthError(`Wait ${Math.ceil((RESEND_SEC * 1000 - (t - last)) / 1000)} seconds before asking for another code.`, 429, 'RATE_LIMITED');
      e.extra = { retryAfterSec: Math.ceil((RESEND_SEC * 1000 - (t - last)) / 1000) };
      throw e;
    }
    if (sent.length >= PER_HOUR) {
      const e = new AuthError('Too many codes were sent. Try again in an hour.', 429, 'RATE_LIMITED');
      e.extra = { retryAfterSec: Math.ceil((3600000 - (t - Math.min(...sent))) / 1000) };
      throw e;
    }
    const code = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
    const expiresAt = t + config.emailCodeTtlMin * 60000;
    await this.repo.updateUser(fresh.key, { [`ec_${purpose}`]: { hash: this._hash(purpose, fresh.userId, bind, code), exp: expiresAt, tries: 0 }, [sentKey]: [...sent, t] });
    return { code, expiresAt, resendAfterSec: RESEND_SEC };
  }

  /** Checks a code; single use. Resolves to the fresh user, or throws 401 CODE_WRONG / CODE_EXPIRED. */
  async verify(user, purpose, code, { bind = '' } = {}) {
    const fresh = await this.repo.findUserById(user.userId);
    const key = `ec_${purpose}`;
    const rec = fresh && fresh[key];
    const t = this.clock();
    if (!rec || !rec.hash || !(Number(rec.exp) > t)) {
      if (rec && fresh) await this.repo.updateUser(fresh.key, { [key]: null }).catch(() => null);
      throw new AuthError('This code expired. Ask for a new one.', 401, 'CODE_EXPIRED');
    }
    const clean = String(code == null ? '' : code).replace(/\s+/g, '');
    const want = Buffer.from(rec.hash, 'hex');
    const got = Buffer.from(this._hash(purpose, fresh.userId, bind, /^\d{6}$/.test(clean) ? clean : 'x'), 'hex');
    if (want.length === got.length && crypto.timingSafeEqual(want, got)) {
      await this.repo.updateUser(fresh.key, { [key]: null });
      return fresh;
    }
    const tries = (Number(rec.tries) || 0) + 1;
    const left = Math.max(0, config.emailCodeMaxTries - tries);
    await this.repo.updateUser(fresh.key, { [key]: left > 0 ? { ...rec, tries } : null });
    const e = left > 0
      ? new AuthError(`That code is not right. ${left} ${left === 1 ? 'try' : 'tries'} left.`, 401, 'CODE_WRONG')
      : new AuthError('Too many wrong codes. Ask for a new one.', 401, 'CODE_EXPIRED');
    e.extra = { triesLeft: left };
    throw e;
  }
}

module.exports = { EmailCodes, RESEND_SEC, PER_HOUR };
