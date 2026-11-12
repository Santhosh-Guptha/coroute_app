'use strict';
/**
 * 3.57 security: log redaction. Nothing secret or personal reaches a server log line:
 *   - JWTs and "Bearer <token>"            -> [token]
 *   - refresh tokens (rt1.<...>)          -> [token]
 *   - e-mail addresses                     -> a***@e***.com (first letter of each part)
 *   - phone numbers (7+ digits)            -> ******3210 (last 4 digits only)
 *   - password= / otp= / code= / secret= / token= values in query strings and key=value text -> [redacted]
 * Objects: values under keys that look secret (password, token, otp, secret, code, authorization, cookie,
 * refreshToken, recovery...) become [redacted]; strings are redacted as above (deep, cycle safe).
 *
 * redactingLogger(logger) wraps console-like loggers (info / warn / error / debug / log), so every module
 * that logs through the gateway logger is covered. docs/features_355/sessions_and_security.md
 */

const SECRET_KEY = /pass(word)?|pwd|token|secret|otp|totp|authorization|cookie|recovery|refresh|api[-_]?key|signature|mfa|code$/i;
const JWT = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g;
const BEARER = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi;
const REFRESH = /\brt1\.[A-Za-z0-9_.-]{20,}/g;
const EMAIL = /\b([A-Za-z0-9._%+-])[A-Za-z0-9._%+-]*@([A-Za-z0-9])[A-Za-z0-9-]*((?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24})\b/g;
// +91 98765 43210, 9876543210, 098-765-43210 ... (7 or more digits, optional + and separators). Not inside words/ids.
const PHONE = /(?<![A-Za-z0-9_.-])\+?\d(?:[\s-]?\d){6,14}(?![A-Za-z0-9_])/g;
const KV = /\b(password|passwd|pwd|otp|totp|code|secret|token|refreshToken|refresh_token|access_token|t)=([^&\s"']+)/gi;

function redactString(s) {
  if (typeof s !== 'string' || !s) return s;
  return s
    .replace(JWT, '[token]')
    .replace(BEARER, (m, kind) => `${kind} [token]`)
    .replace(REFRESH, '[token]')
    .replace(KV, (m, k) => `${k}=[redacted]`)
    .replace(EMAIL, (m, a, d, tld) => `${a}***@${d}***${tld}`)
    .replace(PHONE, (m) => {
      const digits = m.replace(/\D/g, '');
      // Unix ms timestamps and similar 13-digit numbers are not phone numbers.
      if (digits.length >= 12 && /^1[5-9]\d{11}$/.test(digits)) return m;
      return `${'*'.repeat(Math.max(0, digits.length - 4))}${digits.slice(-4)}`;
    });
}

function redact(value, depth = 0, seen = new WeakSet()) {
  if (typeof value === 'string') return redactString(value);
  if (!value || typeof value !== 'object') return value;
  if (value instanceof Error) {
    const e = new Error(redactString(value.message));
    e.name = value.name; e.code = value.code; e.status = value.status;
    return e;
  }
  if (seen.has(value) || depth > 6) return '[…]';
  seen.add(value);
  if (Array.isArray(value)) return value.map((v) => redact(v, depth + 1, seen));
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    out[k] = SECRET_KEY.test(k) && v !== null && v !== undefined && typeof v !== 'boolean' && typeof v !== 'number' ? '[redacted]' : redact(v, depth + 1, seen);
  }
  return out;
}

/** A logger whose every argument is redacted first. Wrapping twice is harmless. */
function redactingLogger(logger = console) {
  if (!logger || logger.__redacting) return logger;
  const wrap = (fn) => (typeof fn === 'function' ? (...args) => fn.apply(logger, args.map((a) => redact(a))) : fn);
  return {
    __redacting: true,
    info: wrap(logger.info), warn: wrap(logger.warn), error: wrap(logger.error),
    debug: wrap(logger.debug), log: wrap(logger.log), trace: wrap(logger.trace),
  };
}

module.exports = { redact, redactString, redactingLogger };
