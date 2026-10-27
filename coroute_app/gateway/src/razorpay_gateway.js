'use strict';
/**
 * Razorpay gateway settings + API client.
 *
 * Two key pairs are kept, TEST and LIVE, and one active MODE picks which pair
 * every new order uses. The platform admin edits them from
 * /pricing-admin.html (or PUT /api/admin/payment-gateway); switching from test
 * to production is a single mode change, no redeploy.
 *
 * Where values come from (first match wins):
 *   1. Admin-saved settings in Oracle (`subscription_config`, k = 'razorpay').
 *      Secrets are stored AES-256-GCM encrypted with a key derived from
 *      JWT_SECRET; they are never returned by any endpoint.
 *   2. Environment: RAZORPAY_MODE, RAZORPAY_TEST_KEY_ID / _SECRET,
 *      RAZORPAY_LIVE_KEY_ID / _SECRET, RAZORPAY_[TEST_|LIVE_]WEBHOOK_SECRET.
 *      The legacy RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET pair is filed under
 *      test or live by its rzp_test_ / rzp_live_ prefix.
 *
 * There is no simulated fallback: if Razorpay cannot be reached or rejects the
 * keys, order creation fails and nothing is activated.
 */
const crypto = require('crypto');
const config = require('./config');

const RZP_API = 'https://api.razorpay.com/v1';
const MODES = ['test', 'live'];
const CACHE_MS = 30 * 1000;

class RazorpayError extends Error {
  constructor(status, message, code) {
    super(message);
    this.status = status;
    this.code = code || 'RAZORPAY_ERROR';
  }
}

function encKey() {
  return crypto.createHash('sha256').update(`${config.jwtSecret}:razorpay-settings:v1`).digest();
}

function encrypt(plain) {
  if (!plain) return '';
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', encKey(), iv);
  const data = Buffer.concat([c.update(String(plain), 'utf8'), c.final()]);
  return ['v1', iv.toString('base64'), c.getAuthTag().toString('base64'), data.toString('base64')].join(':');
}

function decrypt(blob) {
  if (!blob) return '';
  try {
    const [v, iv, tag, data] = String(blob).split(':');
    if (v !== 'v1') return '';
    const d = crypto.createDecipheriv('aes-256-gcm', encKey(), Buffer.from(iv, 'base64'));
    d.setAuthTag(Buffer.from(tag, 'base64'));
    return Buffer.concat([d.update(Buffer.from(data, 'base64')), d.final()]).toString('utf8');
  } catch {
    // JWT_SECRET changed since the secret was saved: treat as not set.
    return '';
  }
}

function envPairs() {
  const e = process.env;
  const t = (v) => String(v || '').trim();
  const out = {
    test: { keyId: t(e.RAZORPAY_TEST_KEY_ID), keySecret: t(e.RAZORPAY_TEST_KEY_SECRET), webhookSecret: t(e.RAZORPAY_TEST_WEBHOOK_SECRET) },
    live: { keyId: t(e.RAZORPAY_LIVE_KEY_ID), keySecret: t(e.RAZORPAY_LIVE_KEY_SECRET), webhookSecret: t(e.RAZORPAY_LIVE_WEBHOOK_SECRET) },
  };
  const legacyId = t(e.RAZORPAY_KEY_ID);
  const legacyMode = legacyId.startsWith('rzp_live_') ? 'live' : (legacyId ? 'test' : null);
  if (legacyMode && !out[legacyMode].keyId) {
    out[legacyMode].keyId = legacyId;
    out[legacyMode].keySecret = out[legacyMode].keySecret || t(e.RAZORPAY_KEY_SECRET);
  }
  const legacyHook = t(e.RAZORPAY_WEBHOOK_SECRET);
  for (const m of MODES) if (!out[m].webhookSecret && legacyHook) out[m].webhookSecret = legacyHook;
  let mode = t(e.RAZORPAY_MODE).toLowerCase();
  if (!MODES.includes(mode)) mode = legacyMode || 'test';
  return { mode, ...out };
}

// Tests replace the HTTP client for every gateway instance (setRazorpayFetch).
let defaultFetch = null;
function setRazorpayFetch(fn) { defaultFetch = fn || null; }

function createRazorpayGateway({ repo, fetchImpl } = {}) {
  let doFetch = fetchImpl || ((...a) => (defaultFetch || fetch)(...a));
  let cache = null;
  let cacheAt = 0;

  async function stored() {
    if (!repo || typeof repo.getPaymentGatewaySettings !== 'function') return null;
    try { return await repo.getPaymentGatewaySettings(); } catch { return null; }
  }

  /** Effective settings with secrets in clear (server-side only). */
  async function settings({ fresh = false } = {}) {
    if (!fresh && cache && Date.now() - cacheAt < CACHE_MS) return cache;
    const env = envPairs();
    const s = (await stored()) || {};
    const pick = (m) => {
      const saved = s[m] || {};
      return {
        keyId: saved.keyId || env[m].keyId,
        keySecret: decrypt(saved.keySecretEnc) || env[m].keySecret,
        webhookSecret: decrypt(saved.webhookSecretEnc) || env[m].webhookSecret,
        source: saved.keyId ? 'admin' : (env[m].keyId ? 'env' : 'none'),
      };
    };
    cache = {
      mode: MODES.includes(s.mode) ? s.mode : env.mode,
      test: pick('test'),
      live: pick('live'),
      updatedAt: s.updatedAt || null,
      updatedBy: s.updatedBy || null,
    };
    cacheAt = Date.now();
    return cache;
  }

  async function keysFor(mode) {
    const s = await settings();
    const m = MODES.includes(mode) ? mode : s.mode;
    return { mode: m, ...s[m] };
  }

  /** What the admin page may see: never a secret. */
  async function publicView() {
    const s = await settings({ fresh: true });
    const view = (p) => ({
      keyId: p.keyId,
      keySecretSet: Boolean(p.keySecret),
      webhookSecretSet: Boolean(p.webhookSecret),
      source: p.source,
    });
    return { mode: s.mode, test: view(s.test), live: view(s.live), updatedAt: s.updatedAt, updatedBy: s.updatedBy };
  }

  /**
   * Admin update. body: { mode?, test?: {keyId?, keySecret?, webhookSecret?}, live?: {...} }.
   * Blank values keep what is saved.
   */
  async function update(body, updatedBy) {
    const cur = (await stored()) || {};
    const next = { mode: cur.mode, test: { ...(cur.test || {}) }, live: { ...(cur.live || {}) } };
    for (const m of MODES) {
      const p = (body && body[m]) || {};
      const id = String(p.keyId || '').trim();
      if (id) {
        if (!new RegExp(`^rzp_${m}_[A-Za-z0-9]+$`).test(id)) {
          throw new RazorpayError(400, `${m} key id must start with rzp_${m}_`, 'BAD_KEY_ID');
        }
        next[m].keyId = id;
      }
      const sec = String(p.keySecret || '').trim();
      if (sec) next[m].keySecretEnc = encrypt(sec);
      const hook = String(p.webhookSecret || '').trim();
      if (hook) next[m].webhookSecretEnc = encrypt(hook);
    }
    if (body && body.mode !== undefined) {
      const mode = String(body.mode).toLowerCase();
      if (!MODES.includes(mode)) throw new RazorpayError(400, 'mode must be test or live', 'BAD_MODE');
      next.mode = mode;
    }
    // Refuse to switch to a mode that has no usable pair.
    cache = null;
    const env = envPairs();
    const target = next.mode || env.mode;
    const hasId = next[target].keyId || env[target].keyId;
    const hasSecret = decrypt(next[target].keySecretEnc) || env[target].keySecret;
    if (body && body.mode !== undefined && (!hasId || !hasSecret)) {
      throw new RazorpayError(400, `Save the ${target} key id and secret before switching to ${target}.`, 'KEYS_MISSING');
    }
    next.updatedAt = Date.now();
    next.updatedBy = updatedBy || 'admin';
    await repo.setPaymentGatewaySettings(next);
    cache = null;
    return publicView();
  }

  async function call(keys, method, path, body) {
    if (!keys.keyId || !keys.keySecret) {
      throw new RazorpayError(500, `Razorpay ${keys.mode} keys are not configured`, 'NOT_CONFIGURED');
    }
    let res;
    try {
      res = await doFetch(`${RZP_API}${path}`, {
        method,
        headers: {
          Authorization: `Basic ${Buffer.from(`${keys.keyId}:${keys.keySecret}`).toString('base64')}`,
          'Content-Type': 'application/json',
        },
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch (e) {
      throw new RazorpayError(500, `Could not reach Razorpay: ${e.message}`, 'RAZORPAY_UNREACHABLE');
    }
    const data = await res.json().catch(() => ({}));
    if (res.status === 401) throw new RazorpayError(401, 'Razorpay authentication failed: invalid key id or secret', 'RAZORPAY_AUTH');
    if (!res.ok) throw new RazorpayError(500, data?.error?.description || `Razorpay error (HTTP ${res.status})`, 'RAZORPAY_ERROR');
    return data;
  }

  /** Real order in the active mode. Returns { id, amount, currency, mode, keyId }. */
  async function createOrder({ amountInPaise, currency = 'INR', receipt, notes }) {
    const amount = Math.round(Number(amountInPaise));
    if (!Number.isFinite(amount) || amount < 100) {
      throw new RazorpayError(400, 'Amount must be at least 100 paise', 'AMOUNT_TOO_LOW');
    }
    const keys = await keysFor();
    const data = await call(keys, 'POST', '/orders', {
      amount,
      currency,
      receipt: String(receipt || `rcpt_${Date.now()}`).slice(0, 40),
      notes: notes || {},
    });
    if (!data.id) throw new RazorpayError(500, 'Razorpay returned no order id', 'RAZORPAY_ERROR');
    return { id: data.id, amount: data.amount, currency: data.currency, mode: keys.mode, keyId: keys.keyId };
  }

  /** Checks the [mode] pair against Razorpay. */
  async function testKeys(mode) {
    const keys = await keysFor(mode);
    await call(keys, 'GET', '/orders?count=1');
    return { ok: true, mode: keys.mode };
  }

  /** HMAC-SHA256(order_id + "|" + payment_id, key secret of [mode]), timing-safe. */
  async function verifySignature({ orderId, paymentId, signature, mode }) {
    const keys = await keysFor(mode);
    if (!keys.keySecret || !orderId || !paymentId || !signature) return false;
    const expected = crypto.createHmac('sha256', keys.keySecret).update(`${orderId}|${paymentId}`).digest('hex');
    const a = Buffer.from(expected);
    const b = Buffer.from(String(signature));
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  /** Webhook body HMAC with either mode's webhook secret. Returns the mode or null. */
  async function verifyWebhook(rawBody, signature) {
    if (!signature) return null;
    const s = await settings();
    for (const m of MODES) {
      const secret = s[m].webhookSecret;
      if (!secret) continue;
      const expected = crypto.createHmac('sha256', secret).update(rawBody).digest('hex');
      const a = Buffer.from(expected);
      const b = Buffer.from(String(signature));
      if (a.length === b.length && crypto.timingSafeEqual(a, b)) return m;
    }
    return null;
  }

  return {
    settings,
    keysFor,
    publicView,
    update,
    createOrder,
    testKeys,
    verifySignature,
    verifyWebhook,
    /** Tests only: swap the HTTP client. */
    _setFetch(fn) { doFetch = fn; cache = null; },
    _clearCache() { cache = null; },
  };
}

module.exports = { createRazorpayGateway, setRazorpayFetch, RazorpayError, _crypto: { encrypt, decrypt } };
