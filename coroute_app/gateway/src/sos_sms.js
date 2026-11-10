'use strict';
/**
 * 3.56 server SOS SMS (docs/features_355/sos_sms.md).
 *
 * When an SOS reaches the gateway (directly, or relayed by another rider's phone) and the rider's
 * phone did not text the contacts itself, the server texts each emergency contact ONCE per SOS through
 * an SMS provider, and texts the same contacts "safe now" when the SOS is resolved or cancelled.
 *
 * Providers (one interface: send({to, body, kind, vars, settings}) -> {messageId}):
 *   msg91   MSG91 Flow API (India, DLT): template variables are sent separately, MSG91 holds the
 *           DLT-registered text (MSG91_AUTH_KEY; template ids in the admin settings).
 *   twilio  Twilio Messages API: the full text is sent; for India it must match the DLT template
 *           registered with Twilio exactly (TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER or
 *           TWILIO_MESSAGING_SERVICE_SID).
 *   log     records the message only (tests, staging). Nothing leaves the server.
 *   off     the earlier gateway path (emergency_sms_gateway.js providers / outbox) is used.
 * Outbound calls go only to SMS_HOSTS (https).
 *
 * Rules: one SMS per contact per SOS (unique row key), at most maxPerSos contacts per SOS and
 * maxPerUserDay SMS per rider per India day (cost guard; "safe now" texts are exempt from the daily
 * cap because they only go to contacts already texted); retries with backoff (30 s, 2 min, 10 min) on
 * network / 429 / 5xx; delivery receipts (provider callbacks) update each contact's status; phone
 * numbers, names and links are purged from the rows 48 h after the last status change. Logs carry
 * only the masked number (***210) and the SOS id.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { toE164, redactPhones } = require('./emergency_sms_gateway');

const C = Object.freeze({ rows: 'sos_sms', settings: 'sms_settings' });
const SMS_HOSTS = new Set(['control.msg91.com', 'api.msg91.com', 'api.twilio.com']);
const PROVIDERS = ['off', 'log', 'msg91', 'twilio'];
const RETRY_DELAYS_MS = [30000, 120000, 600000];
const PURGE_AFTER_MS = 48 * 3600 * 1000;
const FINAL = new Set(['DELIVERED', 'FAILED', 'UNDELIVERED', 'CANCELLED', 'CAPPED']);
const DAY = 86400000;
const IST = 330 * 60000;

const sha = (s) => crypto.createHash('sha256').update(String(s)).digest('hex');
const mask = (phone) => `***${String(phone || '').replace(/\D/g, '').slice(-3)}`;
const istDay = (ms) => new Date(ms + IST).toISOString().slice(0, 10);
const istTime = (ms) => new Date(ms + IST).toISOString().slice(11, 16);
const firstName = (s) => String(s || '').trim().split(/\s+/)[0].slice(0, 30) || 'A CoRoute rider';
const DLT_ID = /^\d{10,25}$/;

class ProviderError extends Error {
  constructor(message, { retryable = false, code = 'PROVIDER_ERROR' } = {}) { super(message); this.retryable = retryable; this.code = code; }
}

async function postJson(fetchImpl, url, { headers = {}, body, form = null, timeoutMs = 8000 }) {
  const u = new URL(url);
  if (u.protocol !== 'https:' || !SMS_HOSTS.has(u.hostname)) throw new ProviderError('SMS host is not allowed', { code: 'HOST_NOT_ALLOWED' });
  let res;
  try {
    res = await fetchImpl(u.href, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(timeoutMs),
      headers: { accept: 'application/json', ...(form ? { 'content-type': 'application/x-www-form-urlencoded' } : { 'content-type': 'application/json' }), ...headers },
      body: form ? new URLSearchParams(form).toString() : JSON.stringify(body),
    });
  } catch (e) { throw new ProviderError(`network: ${e.name || e.code || 'error'}`, { retryable: true, code: 'NETWORK' }); }
  let json = null;
  try { json = await res.json(); } catch { json = null; }
  if (res.status === 429 || res.status >= 500) throw new ProviderError(`HTTP ${res.status}`, { retryable: true, code: `HTTP_${res.status}` });
  if (res.status >= 400) throw new ProviderError(`HTTP ${res.status}: ${redactPhones(JSON.stringify(json || {})).slice(0, 160)}`, { code: `HTTP_${res.status}` });
  return json || {};
}

/** Built-in provider adapters. `env` holds the secrets (never stored, never shown). */
function builtInProviders({ env, fetchImpl, callbackUrl }) {
  return {
    log: {
      configured: () => true,
      sent: [],
      async send(m) { this.sent.push({ to: m.to, body: m.body, kind: m.kind, vars: m.vars }); if (this.sent.length > 500) this.sent.shift(); return { messageId: `log_${crypto.randomBytes(8).toString('hex')}` }; },
    },
    msg91: {
      configured: (s) => !!env.MSG91_AUTH_KEY && !!(s.kindTemplate && s.kindTemplate.SOS),
      async send(m) {
        const templateId = m.settings.kindTemplate[m.kind] || m.settings.kindTemplate.SOS;
        if (!env.MSG91_AUTH_KEY || !templateId) throw new ProviderError('MSG91 is not configured', { code: 'NOT_CONFIGURED' });
        const recipient = { mobiles: m.to.replace(/^\+/, ''), ...m.vars };
        const json = await postJson(fetchImpl, 'https://control.msg91.com/api/v5/flow', {
          headers: { authkey: env.MSG91_AUTH_KEY },
          body: { template_id: templateId, short_url: '0', ...(m.settings.senderId ? { sender: m.settings.senderId } : {}), recipients: [recipient] },
        });
        if (json.type && String(json.type).toLowerCase() !== 'success') throw new ProviderError(`MSG91: ${String(json.message || 'refused').slice(0, 120)}`, { code: 'REFUSED' });
        return { messageId: String(json.request_id || json.message || `m91_${crypto.randomBytes(6).toString('hex')}`).slice(0, 80) };
      },
    },
    twilio: {
      configured: () => !!(env.TWILIO_ACCOUNT_SID && env.TWILIO_AUTH_TOKEN && (env.TWILIO_FROM_NUMBER || env.TWILIO_MESSAGING_SERVICE_SID)),
      async send(m) {
        if (!this.configured()) throw new ProviderError('Twilio is not configured', { code: 'NOT_CONFIGURED' });
        const sid = env.TWILIO_ACCOUNT_SID;
        const form = { To: m.to, Body: m.body };
        if (env.TWILIO_MESSAGING_SERVICE_SID) form.MessagingServiceSid = env.TWILIO_MESSAGING_SERVICE_SID; else form.From = env.TWILIO_FROM_NUMBER;
        const cb = callbackUrl('twilio');
        if (cb) form.StatusCallback = cb;
        const json = await postJson(fetchImpl, `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}/Messages.json`, {
          headers: { authorization: `Basic ${Buffer.from(`${sid}:${env.TWILIO_AUTH_TOKEN}`).toString('base64')}` }, form,
        });
        return { messageId: String(json.sid || `tw_${crypto.randomBytes(6).toString('hex')}`).slice(0, 80) };
      },
    },
  };
}

/** Twilio's X-Twilio-Signature: base64 HMAC-SHA1 of the URL + sorted form keys and values. */
function twilioSignature(authToken, url, params) {
  const data = url + Object.keys(params || {}).sort().map((k) => k + params[k]).join('');
  return crypto.createHmac('sha1', authToken).update(Buffer.from(data, 'utf8')).digest('base64');
}

/** Provider status word -> our status. */
function mapStatus(s) {
  const v = String(s || '').toLowerCase();
  if (/^(1|delivered|delivrd|success)$/.test(v) || /\bdelivered\b/.test(v) && !/undeliver/.test(v)) return 'DELIVERED';
  if (/undeliver|fail|reject|ndnc|block|expire|invalid|^(2|9|16|17|25|26)$/.test(v)) return 'FAILED';
  if (/sent|queued|accepted|sending|submitted|^(8)$/.test(v)) return 'SENT';
  return null;
}

class SosSms {
  constructor({ soda, templates, config = {}, env = process.env, logger = console, clock = Date.now, fetchImpl = globalThis.fetch, providers = {}, settingsCacheMs = 15000 } = {}) {
    this.soda = soda; this.templates = templates; this.config = config; this.env = env; this.logger = logger; this.clock = clock;
    this.settingsCacheMs = settingsCacheMs;
    this.providers = { ...builtInProviders({ env, fetchImpl, callbackUrl: (p) => this.callbackUrl(p) }), ...providers };
    this.cache = null;
    this.ready = null;
    this.running = false;
  }

  origin() { return this.config.publicOrigin || this.config.linkOrigin || ''; }
  webhookToken() { return String(this.env.SMS_WEBHOOK_TOKEN || '').trim(); }
  callbackUrl(provider) {
    const o = this.origin(); const t = this.webhookToken();
    return /^https:\/\//.test(o) && t ? `${o}/api/sms/receipts/${provider}/${encodeURIComponent(t)}` : '';
  }

  async _ensure() {
    if (!this.ready) {
      this.ready = (async () => {
        await this.soda.ensureCollection(C.rows);
        await this.soda.ensureCollection(C.settings);
        const idx = (c, name, fields, unique = false) => this.soda.ensureIndex(c, { name, unique, fields: fields.map((p) => ({ path: p })) });
        await idx(C.rows, 'sos_sms_dedupe_ux', ['dedupe'], true);
        await idx(C.rows, 'sos_sms_sos_ix', ['sosKey']);
        await idx(C.rows, 'sos_sms_msg_ix', ['providerMessageId']);
        await idx(C.settings, 'sms_settings_k_ux', ['k'], true);
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  // ------------------------------------------------------------ settings
  envDefaults() {
    const e = this.env;
    const num = (v, d) => (Number.isFinite(Number(v)) && Number(v) > 0 ? Math.round(Number(v)) : d);
    return {
      provider: PROVIDERS.includes(String(e.SMS_PROVIDER || '').toLowerCase()) ? String(e.SMS_PROVIDER).toLowerCase() : 'off',
      senderId: String(e.SMS_SENDER_ID || '').trim(), dltEntityId: String(e.SMS_DLT_ENTITY_ID || '').trim(),
      dltTemplateIdSos: String(e.SMS_DLT_TEMPLATE_ID_SOS || '').trim(), dltTemplateIdSafe: String(e.SMS_DLT_TEMPLATE_ID_SAFE || '').trim(),
      msg91TemplateIdSos: String(e.MSG91_TEMPLATE_ID_SOS || '').trim(), msg91TemplateIdSafe: String(e.MSG91_TEMPLATE_ID_SAFE || '').trim(),
      maxPerSos: num(e.SMS_MAX_PER_SOS, 5), maxPerUserDay: num(e.SMS_MAX_PER_USER_DAY, 20), safeSms: String(e.SMS_SAFE_SMS || 'true') !== 'false',
    };
  }

  async getSettings() {
    if (this.cache && this.clock() - this.cache.at < this.settingsCacheMs) return this.cache.value;
    let saved = null;
    try { await this._ensure(); const row = await this.soda.findOne(C.settings, { k: 'settings' }); saved = row ? row.value : null; } catch (e) { this.logger.warn?.(`[sos-sms] settings read failed: ${e.message}`); }
    const s = { ...this.envDefaults(), ...(saved ? Object.fromEntries(Object.entries(saved).filter(([k]) => !['k', 'updatedAt', 'updatedBy'].includes(k))) : {}) };
    s.kindTemplate = s.provider === 'msg91' ? { SOS: s.msg91TemplateIdSos, SAFE: s.msg91TemplateIdSafe || s.msg91TemplateIdSos, TEST: s.msg91TemplateIdSafe || s.msg91TemplateIdSos }
      : { SOS: s.dltTemplateIdSos, SAFE: s.dltTemplateIdSafe, TEST: s.dltTemplateIdSafe };
    this.cache = { at: this.clock(), value: s };
    return s;
  }

  /** Admin view: settings + which secrets are set (never their values). */
  async adminSettings() {
    const s = await this.getSettings();
    const e = this.env;
    const has = (k) => (String(e[k] || '').trim() ? 'Set' : 'Not set');
    const p = this.providers[s.provider];
    return {
      settings: { provider: s.provider, senderId: s.senderId, dltEntityId: s.dltEntityId, dltTemplateIdSos: s.dltTemplateIdSos, dltTemplateIdSafe: s.dltTemplateIdSafe,
        msg91TemplateIdSos: s.msg91TemplateIdSos, msg91TemplateIdSafe: s.msg91TemplateIdSafe, maxPerSos: s.maxPerSos, maxPerUserDay: s.maxPerUserDay, safeSms: s.safeSms },
      providers: PROVIDERS.concat(Object.keys(this.providers).filter((k) => !PROVIDERS.includes(k))),
      secrets: { MSG91_AUTH_KEY: has('MSG91_AUTH_KEY'), TWILIO_ACCOUNT_SID: has('TWILIO_ACCOUNT_SID'), TWILIO_AUTH_TOKEN: has('TWILIO_AUTH_TOKEN'),
        TWILIO_FROM_NUMBER: has('TWILIO_FROM_NUMBER'), TWILIO_MESSAGING_SERVICE_SID: has('TWILIO_MESSAGING_SERVICE_SID'), SMS_WEBHOOK_TOKEN: has('SMS_WEBHOOK_TOKEN') },
      ready: s.provider !== 'off' && !!(p && p.configured(s)),
      receiptsUrl: this.callbackUrl(s.provider === 'off' ? 'msg91' : s.provider) ? `${this.origin()}/api/sms/receipts/${s.provider === 'off' ? 'msg91' : s.provider}/<SMS_WEBHOOK_TOKEN>` : '',
      hosts: [...SMS_HOSTS],
    };
  }

  async saveSettings(input, { by = 'admin' } = {}) {
    const b = input && typeof input === 'object' ? input : {};
    const cur = await this.getSettings();
    const known = PROVIDERS.concat(Object.keys(this.providers));
    const next = {};
    const err = (m) => Object.assign(new Error(m), { status: 400, code: 'BAD_SETTINGS' });
    if (b.provider !== undefined) { if (!known.includes(String(b.provider))) throw err('Unknown SMS provider.'); next.provider = String(b.provider); }
    if (b.senderId !== undefined) { const v = String(b.senderId || '').trim(); if (v && !/^[A-Za-z]{6}$|^\+?\d{6,15}$/.test(v)) throw err('Sender id: 6 letters (DLT header) or a phone number.'); next.senderId = v; }
    for (const k of ['dltEntityId', 'dltTemplateIdSos', 'dltTemplateIdSafe']) {
      if (b[k] !== undefined) { const v = String(b[k] || '').trim(); if (v && !DLT_ID.test(v)) throw err(`${k}: DLT ids are 10 to 25 digits.`); next[k] = v; }
    }
    for (const k of ['msg91TemplateIdSos', 'msg91TemplateIdSafe']) {
      if (b[k] !== undefined) { const v = String(b[k] || '').trim(); if (v && !/^[A-Za-z0-9]{8,40}$/.test(v)) throw err(`${k}: MSG91 template ids are letters and digits.`); next[k] = v; }
    }
    if (b.maxPerSos !== undefined) { const v = Math.round(Number(b.maxPerSos)); if (!(v >= 1 && v <= 10)) throw err('SMS per SOS: 1 to 10.'); next.maxPerSos = v; }
    if (b.maxPerUserDay !== undefined) { const v = Math.round(Number(b.maxPerUserDay)); if (!(v >= 1 && v <= 100)) throw err('SMS per rider per day: 1 to 100.'); next.maxPerUserDay = v; }
    if (b.safeSms !== undefined) next.safeSms = b.safeSms === true;
    await this._ensure();
    const row = await this.soda.findOne(C.settings, { k: 'settings' });
    const keep = row ? row.value : {};
    await this.soda.upsertBy(C.settings, { k: 'settings' }, { ...keep, ...next, k: 'settings', updatedAt: this.clock(), updatedBy: String(by).slice(0, 120) });
    this.cache = null;
    void cur;
    return this.adminSettings();
  }

  /** True when the new path handles SOS texts (a provider is chosen and configured). */
  async isActive() {
    const s = await this.getSettings();
    const p = this.providers[s.provider];
    return s.provider !== 'off' && !!p && p.configured(s);
  }

  // ------------------------------------------------------------ sending
  async _render(kind, vars) {
    const id = kind === 'SOS' ? 'sos_sms' : 'sos_safe_sms';
    const out = await this.templates.render(id, vars, { constants: { origin: this.origin() } });
    return out.text;
  }

  _varsFor(kind, v) {
    return kind === 'SOS' ? { name: v.name, token: v.token, lat: v.lat, lng: v.lng, time: v.time } : { name: v.name, time: v.time };
  }

  async _countToday(userId) {
    const rows = await this.soda.query(C.rows, { userId, day: istDay(this.clock()) }, { limit: 1000 });
    return rows.filter((r) => r.value.kind === 'SOS' && r.value.status !== 'CAPPED').length;
  }

  /**
   * Texts each contact once for this SOS. `token`: the live link code (22 characters, /e/<token>).
   * Returns { active, results: [{ to (masked), status }] }.
   */
  async dispatchSos({ sosKey, userId = null, riderName, lat, lng, token, contacts = [], at = this.clock() }) {
    if (!sosKey) return { active: false, results: [] };
    const s = await this.getSettings();
    if (!(await this.isActive())) return { active: false, results: [] };
    await this._ensure();
    const vars = { name: firstName(riderName), token: String(token || ''), lat: Number(lat).toFixed(5), lng: Number(lng).toFixed(5), time: istTime(at) };
    const body = await this._render('SOS', this._varsFor('SOS', vars));
    const already = await this.soda.query(C.rows, { sosKey, kind: 'SOS' }, { limit: 50 });
    let used = already.length;
    let today = userId ? await this._countToday(userId) : 0;
    const results = [];
    const seen = new Set();
    for (const c of contacts) {
      const to = toE164(c && (c.phone || c.number));
      if (!/^\+\d{8,15}$/.test(to) || seen.has(to)) continue;
      seen.add(to);
      const dedupe = `${sosKey}:SOS:${sha(to)}`;
      if (already.some((r) => r.value.dedupe === dedupe)) { results.push({ to: mask(to), status: 'DUPLICATE' }); continue; }
      if (used >= s.maxPerSos) { results.push({ to: mask(to), status: 'CAPPED', reason: 'PER_SOS' }); continue; }
      if (userId && today >= s.maxPerUserDay) {
        results.push({ to: mask(to), status: 'CAPPED', reason: 'PER_DAY' });
        this.logger.warn?.(`[sos-sms] SOS ${sosKey}: daily SMS cap reached, ${mask(to)} not texted`);
        continue;
      }
      const row = await this._insertRow({ sosKey, kind: 'SOS', to, userId, vars, body, dedupe, provider: s.provider });
      if (!row) { results.push({ to: mask(to), status: 'DUPLICATE' }); continue; }
      used++; today++;
      const status = await this._attempt(row);
      results.push({ to: mask(to), status, messageId: row.value.providerMessageId || null });
    }
    return { active: true, results };
  }

  /** "Safe now" to every contact that got (or is still getting) this SOS's text. */
  async dispatchSafe(sosKey, { at = this.clock() } = {}) {
    if (!sosKey) return { results: [] };
    await this._ensure();
    const s = await this.getSettings();
    const rows = await this.soda.query(C.rows, { sosKey, kind: 'SOS' }, { limit: 50 });
    const results = [];
    for (const r of rows) {
      const v = r.value;
      if (v.status === 'QUEUED') {
        // Not delivered yet: stop retrying; a "safe now" for a text they never got would only confuse.
        await this._update(r.key, v, { status: 'CANCELLED', nextAttemptAt: null, lastError: 'SOS closed before delivery' });
        results.push({ to: v.toMasked, status: 'CANCELLED' });
        continue;
      }
      if (!['SENT', 'DELIVERED'].includes(v.status) || !v.to || !s.safeSms || !(await this.isActive())) continue;
      const vars = { name: (v.vars && v.vars.name) || 'A CoRoute rider', time: istTime(at) };
      const body = await this._render('SAFE', vars);
      const row = await this._insertRow({ sosKey, kind: 'SAFE', to: v.to, userId: v.userId, vars, body, dedupe: `${sosKey}:SAFE:${v.toHash}`, provider: s.provider });
      if (!row) continue;
      results.push({ to: v.toMasked, status: await this._attempt(row) });
    }
    return { results };
  }

  async _insertRow({ sosKey, kind, to, userId, vars, body, dedupe, provider }) {
    const now = this.clock();
    const doc = {
      smsId: `sms_${crypto.randomBytes(8).toString('hex')}`, sosKey: String(sosKey).slice(0, 80), kind, userId: userId || null, day: istDay(now),
      to, toHash: sha(to), toMasked: mask(to), vars: this._varsFor(kind, vars), body, dedupe, provider, providerMessageId: null,
      status: 'QUEUED', attempts: 0, nextAttemptAt: now, lastError: null, createdAt: now, updatedAt: now, deliveredAt: null, purged: false,
    };
    try {
      const key = await this.soda.insert(C.rows, doc);
      return { key, value: doc };
    } catch (e) {
      if (e && (e.status === 409 || /unique/i.test(e.message || ''))) return null;
      throw e;
    }
  }

  async _update(key, prev, patch) {
    const next = { ...prev, ...patch, updatedAt: this.clock() };
    await this.soda.replace(C.rows, key, next);
    return next;
  }

  /** One provider attempt for a QUEUED row. Returns the row's new status. */
  async _attempt(row) {
    const s = await this.getSettings();
    const provider = this.providers[row.value.provider] || this.providers[s.provider];
    const attempts = (row.value.attempts || 0) + 1;
    try {
      if (!provider) throw new ProviderError('provider not available', { code: 'NO_PROVIDER' });
      const r = await provider.send({ to: row.value.to, body: row.value.body, kind: row.value.kind, vars: row.value.vars, settings: s });
      row.value = await this._update(row.key, row.value, { status: 'SENT', attempts, providerMessageId: r.messageId || null, nextAttemptAt: null, lastError: null, sentAt: this.clock() });
      this.logger.info?.(`[sos-sms] ${row.value.kind} for ${row.value.sosKey} to ${row.value.toMasked}: sent`);
      return 'SENT';
    } catch (e) {
      const retry = e && e.retryable && attempts <= RETRY_DELAYS_MS.length;
      const lastError = redactPhones(String((e && (e.code || e.message)) || 'error')).slice(0, 120);
      row.value = await this._update(row.key, row.value, retry
        ? { status: 'QUEUED', attempts, nextAttemptAt: this.clock() + RETRY_DELAYS_MS[attempts - 1], lastError }
        : { status: 'FAILED', attempts, nextAttemptAt: null, lastError });
      this.logger.warn?.(`[sos-sms] ${row.value.kind} for ${row.value.sosKey} to ${row.value.toMasked}: ${retry ? 'retry later' : 'failed'} (${lastError})`);
      return row.value.status;
    }
  }

  /** Leased job: retries due rows and purges old personal data. */
  async tick() {
    if (this.running) return { retried: 0, purged: 0 };
    this.running = true;
    let retried = 0; let purged = 0;
    try {
      await this._ensure();
      const due = await this.soda.query(C.rows, { status: 'QUEUED', nextAttemptAt: { $lte: this.clock() } }, { limit: 100 });
      for (const r of due) { await this._attempt({ key: r.key, value: r.value }); retried++; }
      const old = await this.soda.query(C.rows, { purged: false, updatedAt: { $lt: this.clock() - PURGE_AFTER_MS } }, { limit: 200 });
      for (const r of old) {
        if (r.value.status === 'QUEUED') continue;
        await this.soda.replace(C.rows, r.key, { ...r.value, to: null, vars: null, body: null, purged: true });
        purged++;
      }
    } catch (e) { this.logger.warn?.(`[sos-sms] tick failed: ${e.message}`); } finally { this.running = false; }
    return { retried, purged };
  }

  // ------------------------------------------------------------ receipts
  /** Provider delivery receipts -> status per contact. Returns how many rows changed. */
  async onReceipts(provider, items) {
    await this._ensure();
    let n = 0;
    for (const it of items) {
      if (!it || !it.messageId) continue;
      const status = mapStatus(it.status);
      if (!status) continue;
      let rows = await this.soda.query(C.rows, { providerMessageId: String(it.messageId) }, { limit: 10 });
      // MSG91 receipts name the request id and the number: pick that contact's row.
      if (rows.length > 1 && it.number) rows = rows.filter((r) => r.value.toHash === sha(toE164(it.number)));
      for (const r of rows) {
        if (r.value.provider !== provider && !(provider === 'msg91' && r.value.provider === 'msg91')) continue;
        if (FINAL.has(r.value.status) && r.value.status !== 'FAILED') continue;
        if (r.value.status === status) continue;
        await this._update(r.key, r.value, { status, ...(status === 'DELIVERED' ? { deliveredAt: this.clock() } : {}), ...(status === 'FAILED' ? { lastError: String(it.reason || it.status || 'undelivered').slice(0, 80) } : {}) });
        n++;
      }
    }
    return n;
  }

  // ------------------------------------------------------------ admin
  async log({ limit = 50 } = {}) {
    await this._ensure();
    const rows = await this.soda.query(C.rows, {}, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit: Math.min(1000, limit * 6) });
    const groups = new Map();
    for (const r of rows) {
      const v = r.value;
      if (!groups.has(v.sosKey)) groups.set(v.sosKey, { sosKey: v.sosKey, userId: v.userId, createdAt: v.createdAt, messages: [] });
      const g = groups.get(v.sosKey);
      g.createdAt = Math.min(g.createdAt, v.createdAt);
      g.messages.push({ kind: v.kind, to: v.toMasked, status: v.status, attempts: v.attempts, provider: v.provider, error: v.lastError, createdAt: v.createdAt, updatedAt: v.updatedAt, deliveredAt: v.deliveredAt });
    }
    return [...groups.values()].slice(0, limit);
  }

  /** Test SMS (the safe-now template with a sample name) to one number; not counted in caps. */
  async testSend(phone, { by = 'admin' } = {}) {
    const to = toE164(phone);
    if (!/^\+\d{8,15}$/.test(to)) throw Object.assign(new Error('Enter a phone number with country code, like +919876543210.'), { status: 400, code: 'BAD_PHONE' });
    if (!(await this.isActive())) throw Object.assign(new Error('Choose and configure an SMS provider first.'), { status: 409, code: 'SMS_OFF' });
    await this._ensure();
    const s = await this.getSettings();
    const vars = { name: 'CoRoute test', time: istTime(this.clock()) };
    const body = await this._render('SAFE', vars);
    const row = await this._insertRow({ sosKey: `test_${crypto.randomBytes(6).toString('hex')}`, kind: 'TEST', to, userId: null, vars, body, dedupe: `test:${crypto.randomBytes(8).toString('hex')}`, provider: s.provider });
    const status = await this._attempt(row);
    void by;
    return { to: mask(to), status, error: row.value.lastError || null };
  }
}

// ------------------------------------------------------------ routers
function adminSmsRouter({ sosSms }) {
  const r = express.Router();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  const fail = (res, e, next) => (e && e.status && e.status < 500 ? res.status(e.status).json({ error: e.message, code: e.code }) : next(e));
  r.get('/settings', async (req, res, next) => { try { res.json(await sosSms.adminSettings()); } catch (e) { fail(res, e, next); } });
  r.put('/settings', async (req, res, next) => { try { res.json(await sosSms.saveSettings(req.body, { by: by(req) })); } catch (e) { fail(res, e, next); } });
  r.post('/test', async (req, res, next) => { try { res.json(await sosSms.testSend(req.body && req.body.phone, { by: by(req) })); } catch (e) { fail(res, e, next); } });
  r.get('/log', async (req, res, next) => { try { res.json({ sos: await sosSms.log({ limit: Math.min(200, Number(req.query.limit) || 50) }) }); } catch (e) { fail(res, e, next); } });
  return r;
}

/**
 * Public delivery receipt webhooks: POST /api/sms/receipts/:provider/:token. The token is
 * SMS_WEBHOOK_TOKEN (constant-time compare); Twilio callbacks are also checked with
 * X-Twilio-Signature when TWILIO_AUTH_TOKEN is set. Always answers quickly with 200 / 204.
 */
function smsReceiptsRouter({ sosSms, env = process.env }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 600, standardHeaders: 'draft-7', legacyHeaders: false, message: { error: 'Too many requests.' } });
  r.post('/receipts/:provider/:token', limiter, express.urlencoded({ extended: false, limit: '256kb' }), async (req, res, next) => {
    try {
      const want = String(env.SMS_WEBHOOK_TOKEN || '');
      const got = String(req.params.token || '');
      const ok = want.length >= 16 && got.length === want.length && crypto.timingSafeEqual(Buffer.from(got), Buffer.from(want));
      if (!ok) return res.status(404).json({ error: 'Not found' });
      const provider = req.params.provider;
      const body = req.body && typeof req.body === 'object' ? req.body : {};
      let items = [];
      if (provider === 'twilio') {
        if (env.TWILIO_AUTH_TOKEN) {
          const url = `${sosSms.origin()}${req.originalUrl}`;
          const sig = String(req.get('x-twilio-signature') || '');
          const exp = twilioSignature(env.TWILIO_AUTH_TOKEN, url, body);
          if (sig.length !== exp.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(exp))) return res.status(403).json({ error: 'Bad signature' });
        }
        items = [{ messageId: body.MessageSid || body.SmsSid, status: body.MessageStatus || body.SmsStatus, reason: body.ErrorCode }];
      } else if (provider === 'msg91') {
        let data = body.data !== undefined ? body.data : body;
        if (typeof data === 'string') { try { data = JSON.parse(data); } catch { data = []; } }
        const list = Array.isArray(data) ? data : (Array.isArray(data && data.data) ? data.data : [data]);
        for (const d of list) {
          if (!d) continue;
          const reports = Array.isArray(d.report) ? d.report : [d];
          for (const rep of reports) items.push({ messageId: d.requestId || d.request_id || rep.requestId, number: rep.number || rep.mobile, status: rep.desc || rep.status, reason: rep.desc });
        }
      } else return res.status(404).json({ error: 'Not found' });
      await sosSms.onReceipts(provider, items);
      res.status(200).json({ ok: true });
    } catch (e) { next(e); }
  });
  return r;
}

module.exports = { SosSms, ProviderError, adminSmsRouter, smsReceiptsRouter, twilioSignature, mapStatus, SMS_HOSTS, PROVIDERS, RETRY_DELAYS_MS, C };
