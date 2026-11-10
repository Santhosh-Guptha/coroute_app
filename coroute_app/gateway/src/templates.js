'use strict';
/**
 * Message templates the web admin can edit (docs/features_355/notifications_admin.md, "Templates"):
 * the purchase receipt and refund e-mails, the SOS and "safe now" SMS (DLT registered), the neutral
 * plan push notices and the guardian arrival message.
 *
 *  - Text with {{variable}} placeholders. Each template has a FIXED list of variables: an unknown
 *    one is refused, so a typo can never send "{{nmae}}" to a rider.
 *  - DLT SMS templates (India): the text is registered with the operator, so the variables and their
 *    order must stay exactly as registered; the admin is warned that any change of the fixed text
 *    needs a re-registration (sos_sms.md). Values are capped at 30 characters (the DLT {#var#} limit).
 *  - Push templates reach the Play app: the policy guard (policy_terms.js) refuses money / buying /
 *    offer words, like admin pushes.
 *  - E-mail templates edit the words (subject, heading, intro, footer). The HTML layout and the
 *    payment lines are built by code (purchase_email.js) with every value escaped.
 *  - Stored in collection `message_templates` (one document per template, current fields + the last
 *    20 versions). Reset writes the defaults as a new version. Reads are cached for 30 s per node.
 */
const { forbiddenTermIn, policyRefusal } = require('./policy_terms');

const COLLECTION = 'message_templates';
const VAR_RE = /\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}/g;
const MAX_HISTORY = 20;
const DLT_VAR_MAX = 30;

const v = (name, sample, description) => ({ name, sample, description });
const EMAIL_FIELDS = {
  subject: { label: 'Subject', max: 150 },
  heading: { label: 'Heading', max: 120 },
  intro: { label: 'Intro paragraph', max: 1500, multiline: true },
  footer: { label: 'Footer', max: 1500, multiline: true },
};

/** Every editable template: its fields, variables (fixed) and default text. */
const DEFINITIONS = Object.freeze({
  purchase_receipt: {
    label: 'Purchase receipt e-mail', channel: 'email',
    description: 'Sent once after a successful website payment (both the payment check and the Razorpay webhook paths). The payment lines (plan, list price, offer, coupon, credit, tax, amount charged) are added below the intro by the server.',
    fields: EMAIL_FIELDS,
    variables: [v('name', 'Asha', 'Rider name (or "there")'), v('plan', 'Small Group', 'Plan name'), v('period', '10 Nov 2026 to 10 Dec 2026', 'Plan period'),
      v('amount', '₹499.00', 'Amount charged'), v('orderId', 'order_Nx12AbCdEf', 'Razorpay order id'), v('paymentId', 'pay_Nx12AbCdEf', 'Razorpay payment id'),
      v('date', '10 Nov 2026, 14:05 IST', 'Payment date (India time)'), v('receiptUrl', 'https://coroute.example/receipt?order=order_Nx12AbCdEf', 'Receipt page link'),
      v('supportEmail', 'support@coroute.example', 'Support e-mail')],
    defaults: {
      subject: 'Your CoRoute receipt: {{plan}}',
      heading: 'Thank you, {{name}}',
      intro: 'Your {{plan}} plan is active ({{period}}). Here are your payment details.',
      footer: 'You can see this receipt any time at {{receiptUrl}}. Questions about this payment? Write to {{supportEmail}} and mention order {{orderId}}.',
    },
  },
  refund: {
    label: 'Refund e-mail', channel: 'email',
    description: 'Sent once per refund amount when a refund is processed (admin refund or Razorpay webhook).',
    fields: EMAIL_FIELDS,
    variables: [v('name', 'Asha', 'Rider name (or "there")'), v('plan', 'Small Group', 'Plan name'), v('amount', '₹499.00', 'Amount refunded'),
      v('orderId', 'order_Nx12AbCdEf', 'Razorpay order id'), v('paymentId', 'pay_Nx12AbCdEf', 'Razorpay payment id'), v('refundId', 'rfnd_Nx12AbCdEf', 'Refund id'),
      v('date', '12 Nov 2026, 10:30 IST', 'Refund date (India time)'), v('receiptUrl', 'https://coroute.example/receipt?order=order_Nx12AbCdEf', 'Receipt page link'),
      v('supportEmail', 'support@coroute.example', 'Support e-mail')],
    defaults: {
      subject: 'Your CoRoute refund: {{amount}}',
      heading: 'Your refund is on its way',
      intro: 'Hi {{name}}, we refunded {{amount}} for your {{plan}} plan. Banks usually show it within 5 to 7 working days.',
      footer: 'Order {{orderId}}. Questions? Write to {{supportEmail}}.',
    },
  },
  sos_sms: {
    label: 'SOS SMS (DLT)', channel: 'sms', dlt: true,
    description: 'Sent by the server to the rider\'s emergency contacts when an SOS reaches it and the phone could not text them. {{origin}} is this site\'s address (fixed text in the DLT registration).',
    fields: { text: { label: 'SMS text', max: 300, multiline: true } },
    constants: ['origin'],
    variables: [v('name', 'Asha', 'Rider name (30 characters at most)'), v('token', 'Ab3dEf6hIj9lMn0pQr2tUv', 'Live link code (22 characters)'),
      v('lat', '12.97160', 'Latitude'), v('lng', '77.59456', 'Longitude'), v('time', '14:05', 'Time of the SOS (India time)')],
    defaults: {
      text: 'CoRoute SOS: {{name}} needs help. Live: {{origin}}/e/{{token}} Lat {{lat}} Lng {{lng}} at {{time}} IST. Call 112. -CoRoute',
    },
  },
  sos_safe_sms: {
    label: 'SOS safe-now SMS (DLT)', channel: 'sms', dlt: true,
    description: 'Sent to the same contacts when the SOS is resolved or cancelled.',
    fields: { text: { label: 'SMS text', max: 300, multiline: true } },
    variables: [v('name', 'Asha', 'Rider name (30 characters at most)'), v('time', '14:20', 'Time the SOS was closed (India time)')],
    defaults: {
      text: 'CoRoute: {{name}} is safe now. The SOS alert was closed at {{time}} IST. No action is needed. -CoRoute',
    },
  },
  push_plan_active: {
    label: 'Push: plan active', channel: 'push', playNeutral: true,
    description: 'Neutral account status when a plan becomes active (Play policy: no prices, buying or offer words).',
    fields: { title: { label: 'Title', max: 65 }, body: { label: 'Body', max: 240, multiline: true } },
    variables: [v('plan', 'Small Group', 'Plan name')],
    defaults: { title: 'Your plan', body: 'Your {{plan}} plan is active.' },
  },
  push_plan_ending: {
    label: 'Push: plan ending', channel: 'push', playNeutral: true,
    description: 'Neutral reminder a few days before a plan ends (no "renew", no link).',
    fields: { title: { label: 'Title', max: 65 }, body: { label: 'Body', max: 240, multiline: true } },
    variables: [v('date', '12 Dec', 'End date')],
    defaults: { title: 'Your plan', body: 'Your plan ends on {{date}}.' },
  },
  guardian_arrival: {
    label: 'Guardian: arrived safely', channel: 'webpush',
    description: 'Browser notification to Ride Guardian watchers when the rider arrives. No names or places are sent.',
    fields: { title: { label: 'Title', max: 65 }, body: { label: 'Body', max: 200, multiline: true } },
    variables: [],
    defaults: { title: 'CoRoute: arrived safely', body: 'The rider arrived safely. Location sharing has stopped.' },
  },
});

class TemplateError extends Error {
  constructor(message, code = 'BAD_TEMPLATE', status = 400) { super(message); this.code = code; this.status = status; }
}

const varsIn = (text) => [...String(text || '').matchAll(VAR_RE)].map((m) => m[1]);
const clean = (s) => String(s == null ? '' : s).replace(/\r\n/g, '\n').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '');

/** Fills {{var}} placeholders; unknown ones stay as they are (validation refuses them first). */
function fill(text, vars) {
  return String(text || '').replace(VAR_RE, (m, k) => (Object.prototype.hasOwnProperty.call(vars, k) && vars[k] != null ? String(vars[k]) : m));
}

/**
 * Problems with `fields` for template `id`: { errors: [..], warnings: [..] }. Errors block saving.
 */
function validateFields(id, fields) {
  const def = DEFINITIONS[id];
  const errors = []; const warnings = [];
  if (!def) return { errors: ['Unknown template.'], warnings };
  if (!fields || typeof fields !== 'object' || Array.isArray(fields)) return { errors: ['Template fields are missing.'], warnings };
  const allowed = new Set([...def.variables.map((x) => x.name), ...(def.constants || [])]);
  for (const k of Object.keys(fields)) if (!def.fields[k]) errors.push(`Unknown field "${k}".`);
  for (const [k, spec] of Object.entries(def.fields)) {
    const text = clean(fields[k]);
    if (!text.trim()) { errors.push(`${spec.label} is empty.`); continue; }
    if (text.length > spec.max) errors.push(`${spec.label} is longer than ${spec.max} characters.`);
    if (!spec.multiline && /\n/.test(text)) errors.push(`${spec.label} must be one line.`);
    const bad = varsIn(text).filter((n) => !allowed.has(n));
    if (bad.length) errors.push(`${spec.label} uses unknown variable${bad.length > 1 ? 's' : ''} ${[...new Set(bad)].map((n) => `{{${n}}}`).join(', ')}. Allowed: ${[...allowed].map((n) => `{{${n}}}`).join(', ') || 'none'}.`);
    // Single braces that look like a mistyped placeholder.
    if (/\{[^{}]*\}/.test(text.replace(VAR_RE, ''))) errors.push(`${spec.label} has a { } that is not a {{variable}}.`);
    if (def.playNeutral || def.channel === 'push') {
      const term = forbiddenTermIn(fill(text, Object.fromEntries(def.variables.map((x) => [x.name, '']))));
      if (term) errors.push(policyRefusal(term, `${spec.label}`));
    }
  }
  if (def.dlt) {
    const text = clean(fields.text);
    const want = varsIn(def.defaults.text);
    const got = varsIn(text);
    if (want.join(',') !== got.join(',')) {
      errors.push(`A DLT template must keep exactly these variables in this order: ${want.map((n) => `{{${n}}}`).join(' ')}.`);
    }
    if (/[^\x20-\x7e\n£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¤¡ÄÖÑÜ§¿äöñüà]/.test(text)) warnings.push('This text has characters outside the GSM set: each SMS part then holds 70 characters instead of 160.');
    if (text !== clean(def.defaults.text)) warnings.push('DLT: the operator only delivers SMS that match the registered template exactly. Register this new text (and its template id) before saving it, or texts will be blocked.');
  }
  return { errors, warnings };
}

class TemplateStore {
  constructor({ soda = null, logger = console, clock = Date.now, cacheMs = 30000 } = {}) {
    this.soda = soda; this.logger = logger; this.clock = clock; this.cacheMs = cacheMs;
    this.cache = new Map(); // id -> { at, doc }
    this.ready = null;
  }

  async _ensure() {
    if (!this.soda) return;
    if (!this.ready) {
      this.ready = (async () => {
        await this.soda.ensureCollection(COLLECTION);
        await this.soda.ensureIndex(COLLECTION, { name: `${COLLECTION}_id_ux`, unique: true, fields: [{ path: 'id' }] });
      })().catch((e) => { this.ready = null; throw e; });
    }
    await this.ready;
  }

  async _doc(id) {
    const c = this.cache.get(id);
    if (c && this.clock() - c.at < this.cacheMs) return c.doc;
    let doc = null;
    try {
      await this._ensure();
      const row = this.soda ? await this.soda.findOne(COLLECTION, { id }) : null;
      doc = row ? row.value : null;
    } catch (e) { this.logger.warn?.(`[templates] read failed (defaults used): ${e.message}`); }
    this.cache.set(id, { at: this.clock(), doc });
    return doc;
  }

  /** Current fields of a template (saved version, else the defaults). */
  async fields(id) {
    const def = DEFINITIONS[id];
    if (!def) throw new TemplateError('Unknown template.', 'UNKNOWN_TEMPLATE', 404);
    const doc = await this._doc(id);
    const f = doc && doc.fields && typeof doc.fields === 'object' ? doc.fields : null;
    // A saved version that no longer validates (definitions changed) falls back to the defaults.
    if (f && validateFields(id, f).errors.length === 0) return { ...def.defaults, ...f };
    return { ...def.defaults };
  }

  /**
   * Rendered text of every field. `vars` values are strings; DLT templates cap each at 30 characters.
   * `override`: fields to render instead of the stored ones (preview).
   */
  async render(id, vars = {}, { override = null, constants = {} } = {}) {
    const def = DEFINITIONS[id];
    if (!def) throw new TemplateError('Unknown template.', 'UNKNOWN_TEMPLATE', 404);
    const fields = override || (await this.fields(id));
    const values = {};
    for (const x of def.variables) {
      let s = clean(vars[x.name] == null ? '' : vars[x.name]).replace(/\s+/g, ' ').trim();
      if (def.dlt && s.length > DLT_VAR_MAX) s = s.slice(0, DLT_VAR_MAX).trim();
      values[x.name] = s;
    }
    for (const k of def.constants || []) values[k] = String(constants[k] == null ? '' : constants[k]);
    const out = {};
    for (const k of Object.keys(def.fields)) out[k] = fill(clean(fields[k]), values);
    return out;
  }

  /** Everything the admin page needs. */
  async list() {
    const out = [];
    for (const [id, def] of Object.entries(DEFINITIONS)) {
      const doc = await this._doc(id);
      const current = await this.fields(id);
      out.push({
        id, label: def.label, channel: def.channel, description: def.description, dlt: !!def.dlt, playNeutral: !!def.playNeutral,
        fields: def.fields, variables: def.variables, constants: def.constants || [], defaults: def.defaults, current,
        version: (doc && doc.version) || 0, updatedAt: (doc && doc.updatedAt) || null, updatedBy: (doc && doc.updatedBy) || null,
        isDefault: JSON.stringify(current) === JSON.stringify(def.defaults),
        warning: def.dlt ? 'DLT registered text: keep the variables; any change of the words needs a new DLT registration first.' : null,
      });
    }
    return out;
  }

  async history(id) {
    if (!DEFINITIONS[id]) throw new TemplateError('Unknown template.', 'UNKNOWN_TEMPLATE', 404);
    const doc = await this._doc(id);
    return (doc && Array.isArray(doc.history) ? doc.history : []).slice().reverse();
  }

  /** Validates and stores a new version. Returns { version, warnings }. Throws TemplateError. */
  async save(id, fields, { by = 'admin', reset = false } = {}) {
    const def = DEFINITIONS[id];
    if (!def) throw new TemplateError('Unknown template.', 'UNKNOWN_TEMPLATE', 404);
    const picked = {};
    for (const k of Object.keys(def.fields)) picked[k] = clean(fields && fields[k]);
    const extra = fields && typeof fields === 'object' ? Object.keys(fields).filter((k) => !def.fields[k]) : [];
    const { errors, warnings } = validateFields(id, extra.length ? { ...picked, ...Object.fromEntries(extra.map((k) => [k, fields[k]])) } : picked);
    if (errors.length) throw Object.assign(new TemplateError(errors.join(' '), 'BAD_TEMPLATE', 400), { errors, warnings });
    if (!this.soda) throw new TemplateError('Templates cannot be saved without a database.', 'NO_STORE', 503);
    await this._ensure();
    const row = await this.soda.findOne(COLLECTION, { id });
    const prev = row ? row.value : null;
    const now = this.clock();
    const version = ((prev && prev.version) || 0) + 1;
    const entry = { version, fields: picked, updatedAt: now, updatedBy: String(by).slice(0, 120), reset: !!reset };
    const history = [...((prev && prev.history) || []), entry].slice(-MAX_HISTORY);
    const doc = { id, version, fields: picked, updatedAt: now, updatedBy: entry.updatedBy, history };
    await this.soda.upsertBy(COLLECTION, { id }, doc);
    this.cache.set(id, { at: now, doc });
    return { version, warnings };
  }

  async reset(id, { by = 'admin' } = {}) {
    const def = DEFINITIONS[id];
    if (!def) throw new TemplateError('Unknown template.', 'UNKNOWN_TEMPLATE', 404);
    return this.save(id, def.defaults, { by, reset: true });
  }

  /** Rendered sample (the variables' samples) of `fields` (or the stored ones), with problems. */
  async preview(id, fields = null, { constants = {} } = {}) {
    const def = DEFINITIONS[id];
    if (!def) throw new TemplateError('Unknown template.', 'UNKNOWN_TEMPLATE', 404);
    const f = fields ? Object.fromEntries(Object.keys(def.fields).map((k) => [k, clean(fields[k])])) : await this.fields(id);
    const check = validateFields(id, fields || f);
    const sample = Object.fromEntries(def.variables.map((x) => [x.name, x.sample]));
    const rendered = await this.render(id, sample, { override: f, constants });
    return { rendered, errors: check.errors, warnings: check.warnings };
  }
}

/** /api/admin/templates (mounted behind requireAuth + requireAdmin). */
function templatesAdminRouter({ templates, constants = () => ({}), audit = null }) {
  const express = require('express');
  const r = express.Router();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  const fail = (res, e, next) => {
    if (e instanceof TemplateError) return res.status(e.status).json({ error: e.message, code: e.code, errors: e.errors || undefined, warnings: e.warnings || undefined });
    return next(e);
  };
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  r.get('/', async (req, res, next) => { try { res.json({ templates: await templates.list() }); } catch (e) { fail(res, e, next); } });
  r.get('/:id/history', async (req, res, next) => { try { res.json({ history: await templates.history(req.params.id) }); } catch (e) { fail(res, e, next); } });
  r.post('/:id/preview', async (req, res, next) => {
    try { res.json(await templates.preview(req.params.id, req.body && req.body.fields ? req.body.fields : null, { constants: constants() })); } catch (e) { fail(res, e, next); }
  });
  r.put('/:id', async (req, res, next) => {
    try {
      const out = await templates.save(req.params.id, (req.body && req.body.fields) || {}, { by: by(req) });
      if (audit) audit({ by: by(req), action: 'template.save', target: req.params.id, details: { version: out.version }, at: Date.now() });
      res.json({ ok: true, ...out });
    } catch (e) { fail(res, e, next); }
  });
  r.post('/:id/reset', async (req, res, next) => {
    try {
      const out = await templates.reset(req.params.id, { by: by(req) });
      if (audit) audit({ by: by(req), action: 'template.reset', target: req.params.id, details: { version: out.version }, at: Date.now() });
      res.json({ ok: true, ...out });
    } catch (e) { fail(res, e, next); }
  });
  return r;
}

module.exports = { DEFINITIONS, TemplateStore, TemplateError, validateFields, templatesAdminRouter, fill, varsIn, COLLECTION, DLT_VAR_MAX };
