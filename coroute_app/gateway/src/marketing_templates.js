'use strict';
/**
 * 3.55 Marketing studio: templates for coupon / special-offer images, made in the admin console.
 *
 * The app's editor draws a template (JSON) with one painter for both the preview and the exported
 * PNG; the gateway only stores and checks templates. Every route is admin only (requireAdmin first,
 * so a rider always gets 403) and answers 403 FEATURE_OFF while the admin switch `marketingStudio`
 * is off.
 *
 *   GET    /api/admin/marketing/templates?status=active|archived|all
 *   POST   /api/admin/marketing/templates                 create (body: template)
 *   GET    /api/admin/marketing/templates/:id             one template + its live coupon view
 *   PUT    /api/admin/marketing/templates/:id             replace (optional baseUpdatedAt -> 409 on conflict)
 *   PATCH  /api/admin/marketing/templates/:id/status      { status: 'active' | 'archived' }
 *   POST   /api/admin/marketing/templates/:id/duplicate   copy named "<name> (copy)"
 *   DELETE /api/admin/marketing/templates/:id
 *   GET    /api/admin/marketing/coupons                   coupons a template can be bound to (public fields only)
 *   POST   /api/admin/marketing/images                    raw JPEG / PNG / WebP bytes (<= 2 MB)
 *   GET    /api/admin/marketing/images                    uploaded images (metadata)
 *   GET    /api/admin/marketing/images/:id                the image bytes
 *   DELETE /api/admin/marketing/images/:id                only when no template uses it
 *
 * Storage: templates and image metadata are documents in subscription_config (k='mkt_template' /
 * k='mkt_image'; backed up with the critical set). Image bytes go through the review photo store
 * (./review_photos: magic-byte type check, 2 MB, EXIF/GPS stripped, disk or Object Storage PAR).
 *
 * Coupon safety: a template stores only the coupon CODE (what riders type anyway). The coupon view
 * never carries the store key, usages, rider ids or internal notes. Only an ACTIVE (or SCHEDULED)
 * coupon can be newly bound; a bound coupon that later expired / was paused stays bound and the
 * view carries `warning` so the editor and the export say so.
 *
 * Geometry is relative: x / y are the layer centre as a fraction of the canvas, w / h fractions of
 * the canvas width / height. Lengths (font size, stroke, radius, shadow, letter spacing) are in
 * units of 1 px at a 1080 px short side, so one template renders at any size.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const config = require('./config');
const reviewPhotos = require('./review_photos');
const { COLLECTIONS: C } = require('./oracle/repo');

const FEATURE_ID = 'marketingStudio';
const K_TEMPLATE = 'mkt_template';
const K_IMAGE = 'mkt_image';
const SCHEMA_VERSION = 1;

const LIMITS = Object.freeze({
  maxLayers: 40,
  maxImageLayers: 10,
  nameMax: 80,
  layerNameMax: 40,
  textMax: 500,
  couponLineMax: 160,
  shapeLabelMax: 40,
  captionMax: 1000,
  linkMax: 300,
  minSide: 200,
  maxSide: 4096,
  maxTemplates: 300,
  maxImages: 300,
  maxDocChars: 200000,
});

const SIZE_PRESETS = Object.freeze({
  instagram_post: Object.freeze({ width: 1080, height: 1080, label: 'Instagram post' }),
  instagram_story: Object.freeze({ width: 1080, height: 1920, label: 'Instagram story' }),
  whatsapp_status: Object.freeze({ width: 1080, height: 1920, label: 'WhatsApp status' }),
  banner: Object.freeze({ width: 1200, height: 628, label: 'Banner' }),
  custom: null,
});

const LAYER_TYPES = Object.freeze(['text', 'coupon', 'logo', 'shape', 'image', 'qr']);
const FONTS = Object.freeze(['Manrope', 'sans', 'serif', 'monospace']);
const SHAPES = Object.freeze(['rect', 'pill', 'circle', 'ribbon', 'star', 'burst']);
const PATTERNS = Object.freeze(['none', 'topo', 'road', 'dots', 'stripes', 'rings', 'chevrons']);
const BG_KINDS = Object.freeze(['solid', 'gradient', 'image']);
const COUPON_STYLES = Object.freeze(['ticket', 'pill', 'card', 'stamp']);
const STATUSES = Object.freeze(['active', 'archived']);
const PLACEHOLDERS = Object.freeze(['code', 'discount', 'validUntil', 'plan', 'name', 'cap', 'link']);

const COLOR_RE = /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/;
const TEMPLATE_ID_RE = /^mt_[a-f0-9]{24}$/;
const LAYER_ID_RE = /^[A-Za-z0-9_-]{1,40}$/;
const CODE_RE = /^[A-Z0-9_-]{2,40}$/;

class TemplateError extends Error {
  constructor(message, path = '', status = 400, code = 'BAD_TEMPLATE') {
    super(path ? `${path}: ${message}` : message);
    this.status = status; this.code = code; this.path = path;
  }
}

// ------------------------------------------------------------------ field checks
const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const CTRL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;

function str(v, path, max, { required = false, def = '', multiline = false } = {}) {
  if (v === undefined || v === null) {
    if (required) throw new TemplateError('is required', path);
    return def;
  }
  if (typeof v !== 'string') throw new TemplateError('must be text', path);
  let s = v.replace(CTRL, '');
  if (!multiline) s = s.replace(/[\r\n\t]+/g, ' ');
  if (s.length > max) throw new TemplateError(`must be at most ${max} characters`, path);
  if (required && !s.trim()) throw new TemplateError('is required', path);
  return s;
}

function num(v, path, min, max, def) {
  if (v === undefined || v === null) {
    if (def === undefined) throw new TemplateError('is required', path);
    return def;
  }
  if (typeof v !== 'number' || !Number.isFinite(v)) throw new TemplateError('must be a number', path);
  if (v < min || v > max) throw new TemplateError(`must be between ${min} and ${max}`, path);
  return Math.round(v * 10000) / 10000;
}

function int(v, path, min, max, def) {
  const n = num(v, path, min, max, def);
  if (!Number.isInteger(n)) throw new TemplateError('must be a whole number', path);
  return n;
}

function color(v, path, def) {
  if (v === undefined || v === null) {
    if (def === undefined) throw new TemplateError('is required', path);
    return def;
  }
  if (typeof v !== 'string' || !COLOR_RE.test(v)) throw new TemplateError('must be a colour like #RRGGBB or #RRGGBBAA', path);
  return v.toUpperCase();
}

function optColor(v, path) {
  if (v === undefined || v === null || v === '') return null;
  return color(v, path);
}

function oneOf(v, path, list, def) {
  if (v === undefined || v === null) {
    if (def === undefined) throw new TemplateError('is required', path);
    return def;
  }
  if (!list.includes(v)) throw new TemplateError(`must be one of ${list.join(', ')}`, path);
  return v;
}

const bool = (v, def = false) => (typeof v === 'boolean' ? v : def);

function imageRef(v, path, { required = true } = {}) {
  if (v === undefined || v === null || v === '') {
    if (required) throw new TemplateError('is required', path);
    return null;
  }
  if (!reviewPhotos.isPhotoId(v)) throw new TemplateError('is not an uploaded image', path);
  return v;
}

// ------------------------------------------------------------------ schema
function cleanSize(v) {
  if (!isObj(v)) throw new TemplateError('is required', 'size');
  const preset = oneOf(v.preset, 'size.preset', Object.keys(SIZE_PRESETS), 'custom');
  const p = SIZE_PRESETS[preset];
  if (p) return { preset, width: p.width, height: p.height };
  return {
    preset,
    width: int(v.width, 'size.width', LIMITS.minSide, LIMITS.maxSide),
    height: int(v.height, 'size.height', LIMITS.minSide, LIMITS.maxSide),
  };
}

function cleanBackground(v) {
  const b = isObj(v) ? v : {};
  const kind = oneOf(b.kind, 'background.kind', BG_KINDS, 'solid');
  const out = {
    kind,
    color: color(b.color, 'background.color', '#0B0F14'),
    colors: null,
    angle: num(b.angle, 'background.angle', 0, 360, 135),
    imageId: null,
    imageFit: oneOf(b.imageFit, 'background.imageFit', ['cover', 'contain'], 'cover'),
    pattern: oneOf(b.pattern, 'background.pattern', PATTERNS, 'none'),
    patternColor: color(b.patternColor, 'background.patternColor', '#3EE0EC'),
    patternOpacity: num(b.patternOpacity, 'background.patternOpacity', 0, 1, 0.12),
    overlay: optColor(b.overlay, 'background.overlay'),
  };
  if (kind === 'gradient') {
    if (!Array.isArray(b.colors) || b.colors.length < 2 || b.colors.length > 4) throw new TemplateError('needs 2 to 4 colours', 'background.colors');
    out.colors = b.colors.map((c, i) => color(c, `background.colors[${i}]`));
  }
  if (kind === 'image') out.imageId = imageRef(b.imageId, 'background.imageId');
  return out;
}

function cleanShadow(v, path) {
  if (v === undefined || v === null || v === false) return null;
  if (!isObj(v)) throw new TemplateError('must be an object or null', path);
  return {
    color: color(v.color, `${path}.color`, '#00000080'),
    blur: num(v.blur, `${path}.blur`, 0, 100, 12),
    dx: num(v.dx, `${path}.dx`, -100, 100, 0),
    dy: num(v.dy, `${path}.dy`, -100, 100, 4),
  };
}

function cleanLayer(v, i) {
  const p = `layers[${i}]`;
  if (!isObj(v)) throw new TemplateError('must be an object', p);
  const type = oneOf(v.type, `${p}.type`, LAYER_TYPES);
  const id = typeof v.id === 'string' && LAYER_ID_RE.test(v.id) ? v.id : null;
  if (!id) throw new TemplateError('must be 1-40 letters, digits, - or _', `${p}.id`);
  const base = {
    id, type,
    name: str(v.name, `${p}.name`, LIMITS.layerNameMax),
    x: num(v.x, `${p}.x`, -0.5, 1.5, 0.5),
    y: num(v.y, `${p}.y`, -0.5, 1.5, 0.5),
    w: num(v.w, `${p}.w`, 0.005, 3, 0.5),
    h: num(v.h, `${p}.h`, 0.005, 3, 0.2),
    rotation: num(v.rotation, `${p}.rotation`, -360, 360, 0),
    opacity: num(v.opacity, `${p}.opacity`, 0, 1, 1),
    hidden: bool(v.hidden),
    locked: bool(v.locked),
  };
  switch (type) {
    case 'text':
      return {
        ...base,
        text: str(v.text, `${p}.text`, LIMITS.textMax, { multiline: true }),
        font: oneOf(v.font, `${p}.font`, FONTS, 'Manrope'),
        size: num(v.size, `${p}.size`, 4, 600, 64),
        weight: int(v.weight, `${p}.weight`, 100, 900, 700),
        color: color(v.color, `${p}.color`, '#FFFFFF'),
        align: oneOf(v.align, `${p}.align`, ['left', 'center', 'right'], 'center'),
        letterSpacing: num(v.letterSpacing, `${p}.letterSpacing`, -20, 100, 0),
        lineHeight: num(v.lineHeight, `${p}.lineHeight`, 0.7, 3, 1.15),
        shadow: cleanShadow(v.shadow, `${p}.shadow`),
        uppercase: bool(v.uppercase),
        italic: bool(v.italic),
        fit: oneOf(v.fit, `${p}.fit`, ['none', 'shrink'], 'shrink'),
      };
    case 'coupon':
      return {
        ...base,
        style: oneOf(v.style, `${p}.style`, COUPON_STYLES, 'ticket'),
        fill: color(v.fill, `${p}.fill`, '#FFFFFF'),
        textColor: color(v.textColor, `${p}.textColor`, '#0B0F14'),
        accent: color(v.accent, `${p}.accent`, '#FFB347'),
        font: oneOf(v.font, `${p}.font`, FONTS, 'Manrope'),
        headline: str(v.headline, `${p}.headline`, LIMITS.couponLineMax, { def: '{discount}' }),
        codeLine: str(v.codeLine, `${p}.codeLine`, LIMITS.couponLineMax, { def: 'Use code {code}' }),
        footer: str(v.footer, `${p}.footer`, LIMITS.couponLineMax, { def: 'Valid till {validUntil} · {plan}' }),
      };
    case 'logo':
      return {
        ...base,
        variant: oneOf(v.variant, `${p}.variant`, ['mark', 'wordmark'], 'wordmark'),
        color: color(v.color, `${p}.color`, '#ECF1F6'),
      };
    case 'shape':
      return {
        ...base,
        shape: oneOf(v.shape, `${p}.shape`, SHAPES, 'rect'),
        fill: color(v.fill, `${p}.fill`, '#FFB347'),
        stroke: optColor(v.stroke, `${p}.stroke`),
        strokeWidth: num(v.strokeWidth, `${p}.strokeWidth`, 0, 60, 0),
        radius: num(v.radius, `${p}.radius`, 0, 500, 24),
        label: str(v.label, `${p}.label`, LIMITS.shapeLabelMax),
        labelColor: color(v.labelColor, `${p}.labelColor`, '#0B0F14'),
        labelSize: num(v.labelSize, `${p}.labelSize`, 4, 300, 40),
        font: oneOf(v.font, `${p}.font`, FONTS, 'Manrope'),
        weight: int(v.weight, `${p}.weight`, 100, 900, 800),
      };
    case 'image':
      return {
        ...base,
        imageId: imageRef(v.imageId, `${p}.imageId`),
        fit: oneOf(v.fit, `${p}.fit`, ['cover', 'contain'], 'cover'),
        radius: num(v.radius, `${p}.radius`, 0, 500, 0),
      };
    case 'qr':
      return {
        ...base,
        data: str(v.data, `${p}.data`, LIMITS.linkMax, { def: '{link}' }),
        color: color(v.color, `${p}.color`, '#0B0F14'),
        background: color(v.background, `${p}.background`, '#FFFFFF'),
      };
    default:
      throw new TemplateError('unknown layer type', `${p}.type`);
  }
}

/**
 * The canonical template from client input (unknown keys dropped). Throws TemplateError.
 * Image references are checked for shape here; that they exist is checked by the route.
 */
function cleanTemplate(input) {
  if (!isObj(input)) throw new TemplateError('Send the template as a JSON object.');
  if (input.version !== undefined && input.version !== SCHEMA_VERSION) throw new TemplateError(`must be ${SCHEMA_VERSION}`, 'version');
  if (!Array.isArray(input.layers)) throw new TemplateError('must be a list', 'layers');
  if (input.layers.length > LIMITS.maxLayers) throw new TemplateError(`at most ${LIMITS.maxLayers} layers`, 'layers', 400, 'TOO_MANY_LAYERS');
  const layers = input.layers.map(cleanLayer);
  const ids = new Set();
  for (const [i, l] of layers.entries()) {
    if (ids.has(l.id)) throw new TemplateError('is used twice', `layers[${i}].id`);
    ids.add(l.id);
  }
  if (layers.filter((l) => l.type === 'image').length > LIMITS.maxImageLayers) throw new TemplateError(`at most ${LIMITS.maxImageLayers} image layers`, 'layers', 400, 'TOO_MANY_IMAGES');
  let couponCode = null;
  if (input.couponCode !== undefined && input.couponCode !== null && input.couponCode !== '') {
    if (typeof input.couponCode !== 'string') throw new TemplateError('must be text', 'couponCode');
    couponCode = input.couponCode.trim().toUpperCase();
    if (!CODE_RE.test(couponCode)) throw new TemplateError('is not a coupon code', 'couponCode');
  }
  const out = {
    version: SCHEMA_VERSION,
    name: str(input.name, 'name', LIMITS.nameMax, { required: true }).trim(),
    status: oneOf(input.status, 'status', STATUSES, 'active'),
    size: cleanSize(input.size),
    background: cleanBackground(input.background),
    couponCode,
    link: str(input.link, 'link', LIMITS.linkMax, { def: '' }),
    caption: str(input.caption, 'caption', LIMITS.captionMax, { multiline: true }),
    layers,
  };
  if (JSON.stringify(out).length > LIMITS.maxDocChars) throw new TemplateError('The template is too large.', '', 413, 'TEMPLATE_TOO_LARGE');
  return out;
}

/** Every uploaded image id a template uses. */
function imageIdsOf(t) {
  const ids = new Set();
  if (t && t.background && t.background.imageId) ids.add(t.background.imageId);
  for (const l of (t && Array.isArray(t.layers) ? t.layers : [])) if (l && l.type === 'image' && l.imageId) ids.add(l.imageId);
  return [...ids];
}

// ------------------------------------------------------------------ coupons and placeholders
const PLAN_FALLBACK = { group_small: 'Small Group', group_large: 'Large Group', individual: 'Small Group', community: 'Community' };
const IST_MS = 330 * 60000;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/** "30 Nov 2026" in India time (the app's coupons are India-only), or '' without a date. */
function formatDate(ms) {
  const n = Number(ms);
  if (!Number.isFinite(n) || n <= 0) return '';
  const d = new Date(n + IST_MS);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

const inr = (v) => `₹${Number(v).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;

function discountText(c) {
  const v = Number(c.discountValue) || 0;
  if (c.discountType === 'free' || (c.discountType === 'percentage' && v >= 100)) return 'Free';
  if (c.discountType === 'fixed') return `${inr(v)} off`;
  return `${Math.round(v * 100) / 100}% off`;
}

function planText(tiers, labels = {}) {
  const list = Array.isArray(tiers) ? tiers.map(String) : [];
  if (!list.length || list.includes('all')) return 'all plans';
  const names = [...new Set(list.map((t) => labels[t] || PLAN_FALLBACK[t] || t))];
  return names.length === 1 ? `${names[0]} plan` : `${names.slice(0, -1).join(', ')} & ${names[names.length - 1]} plans`;
}

/** {code, discount, validUntil, plan, name, cap} for a coupon record (link is added by the app). */
function couponPlaceholders(c, labels = {}) {
  if (!c) return null;
  const cap = Number(c.maxDiscountCap);
  return {
    code: String(c.code || ''),
    discount: discountText(c),
    validUntil: formatDate(c.expiresAt),
    plan: planText(c.applicableTiers, labels),
    name: String(c.name || c.code || ''),
    cap: c.discountType === 'percentage' && cap > 0 ? `up to ${inr(cap)}` : '',
  };
}

/** Replaces known {placeholders}; unknown braces stay as typed. */
function substitute(text, values) {
  return String(text || '').replace(/\{([A-Za-z]+)\}/g, (m, k) => (values && PLACEHOLDERS.includes(k) && values[k] !== undefined && values[k] !== null ? String(values[k]) : m));
}

const BINDABLE = new Set(['ACTIVE', 'SCHEDULED']);

/**
 * What the editor may see of a coupon: public fields only (never the store key, usages, rider ids
 * or internal notes) + placeholders + a warning when it can no longer be redeemed.
 */
function couponView(c, labels = {}, now = Date.now()) {
  if (!c) return null;
  const status = String(c.status || '').toUpperCase() || 'ACTIVE';
  const bindable = BINDABLE.has(status) && !(c.expiresAt && Number(c.expiresAt) < now);
  let warning = null;
  if (status === 'EXPIRED' || (c.expiresAt && Number(c.expiresAt) < now)) warning = 'This coupon has expired. Riders cannot use it any more.';
  else if (status === 'PAUSED') warning = 'This coupon is paused. Riders cannot use it until it is resumed.';
  else if (status === 'USAGE_LIMIT_REACHED') warning = 'This coupon has reached its usage limit.';
  else if (status === 'ARCHIVED' || status === 'DRAFT') warning = 'This coupon is not active.';
  else if (status === 'SCHEDULED') warning = `This coupon starts on ${formatDate(c.validFrom)}.`;
  return {
    code: String(c.code || ''),
    name: String(c.name || c.code || ''),
    campaignName: String(c.campaignName || ''),
    discountType: c.discountType || 'percentage',
    discountValue: Number(c.discountValue) || 0,
    maxDiscountCap: c.maxDiscountCap === null || c.maxDiscountCap === undefined ? null : Number(c.maxDiscountCap),
    validFrom: Number(c.validFrom) || null,
    expiresAt: Number(c.expiresAt) || null,
    status,
    bindable,
    warning,
    plans: (Array.isArray(c.applicableTiers) ? c.applicableTiers : ['all']).map(String),
    placeholders: couponPlaceholders(c, labels),
  };
}

// ------------------------------------------------------------------ store
const newTemplateId = () => `mt_${crypto.randomBytes(12).toString('hex')}`;
const strip = (v) => { if (!v) return v; const { key, k, ...rest } = v; void key; void k; return rest; };

function createMarketingStore(soda) {
  const coll = C.subscriptionConfig;
  return {
    async listTemplates() {
      const rows = await soda.query(coll, { k: K_TEMPLATE }, { limit: LIMITS.maxTemplates + 50 });
      return rows.map((r) => strip(r.value)).sort((a, b) => (Number(b.updatedAt) || 0) - (Number(a.updatedAt) || 0));
    },
    async getTemplate(id) {
      if (!TEMPLATE_ID_RE.test(String(id))) return null;
      const r = await soda.findOne(coll, { k: K_TEMPLATE, id: String(id) });
      return r ? strip(r.value) : null;
    },
    async saveTemplate(doc) {
      await soda.upsertBy(coll, { k: K_TEMPLATE, id: doc.id }, { ...doc, k: K_TEMPLATE });
      return doc;
    },
    async removeTemplate(id) { return soda.removeWhere(coll, { k: K_TEMPLATE, id: String(id) }); },
    async listImages() {
      const rows = await soda.query(coll, { k: K_IMAGE }, { limit: LIMITS.maxImages + 50 });
      return rows.map((r) => strip(r.value)).sort((a, b) => (Number(b.at) || 0) - (Number(a.at) || 0));
    },
    async getImage(id) {
      if (!reviewPhotos.isPhotoId(id)) return null;
      const r = await soda.findOne(coll, { k: K_IMAGE, id: String(id) });
      return r ? strip(r.value) : null;
    },
    async saveImage(meta) { await soda.upsertBy(coll, { k: K_IMAGE, id: meta.id }, { ...meta, k: K_IMAGE }); return meta; },
    async removeImage(id) { return soda.removeWhere(coll, { k: K_IMAGE, id: String(id) }); },
  };
}

// ------------------------------------------------------------------ routes
function registerMarketingRoutes({ r, repo, wrap, requireAdmin, flagsOf = () => null, photoStore = null }) {
  const soda = repo && repo.soda;
  const store = soda ? createMarketingStore(soda) : null;
  let photos = photoStore;
  const photosOf = () => { if (!photos) photos = reviewPhotos.createPhotoStore(config.reviewPhotoDir); return photos; };

  const limiter = (n) => rateLimit({ windowMs: 60 * 1000, limit: n, standardHeaders: 'draft-7', legacyHeaders: false, validate: false,
    keyGenerator: (req) => req.user?.userId || req.ip, message: { error: 'Too many requests. Wait a minute.', code: 'RATE_LIMITED' } });
  const readLimit = limiter(240);
  const writeLimit = limiter(90);
  const uploadLimit = limiter(30);

  // After requireAdmin: the admin switch (off -> 403 FEATURE_OFF), and the store must exist.
  const ready = (req, res, next) => {
    const fl = typeof flagsOf === 'function' ? flagsOf() : null;
    if (fl && typeof fl.isOn === 'function' && !fl.isOn(FEATURE_ID)) {
      return res.status(403).set('Cache-Control', 'no-store').json({ error: 'This feature is turned off for now.', code: 'FEATURE_OFF', feature: FEATURE_ID });
    }
    if (!store) return res.status(503).json({ error: 'The marketing studio is not available.', code: 'UNAVAILABLE' });
    next();
  };

  const by = (req) => req.user?.email || req.user?.userId || 'admin';
  const audit = async (req, action, target, details) => {
    if (!repo || typeof repo.addAuditEntry !== 'function') return;
    try { await repo.addAuditEntry({ at: Date.now(), by: by(req), byUserId: req.user?.userId || null, action, target, details }); } catch { /* never in the way */ }
  };
  const fail = (res, e) => {
    if (e instanceof TemplateError) return res.status(e.status).json({ error: e.message, code: e.code, path: e.path || undefined });
    throw e;
  };

  const planLabels = async () => {
    const out = {};
    try {
      const { couponPlanOptions } = require('./subscription_routes');
      for (const o of await couponPlanOptions(repo)) out[o.id] = o.label;
    } catch { /* fallback labels */ }
    return out;
  };
  const findCoupon = async (code) => (code && typeof repo.findCoupon === 'function' ? repo.findCoupon(code).catch(() => null) : null);

  /** The template as the console gets it: the stored doc + the live coupon view (or a missing-coupon warning). */
  const viewOf = async (t, labels) => {
    if (!t) return null;
    let coupon = null;
    if (t.couponCode) {
      const c = await findCoupon(t.couponCode);
      coupon = c ? couponView(c, labels) : { code: t.couponCode, missing: true, bindable: false, warning: 'This coupon no longer exists.', placeholders: null };
    }
    return { ...t, coupon };
  };

  /** Checks the coupon binding and image references of a cleaned template (previous: the stored one). */
  const checkRefs = async (clean, previous = null) => {
    if (clean.couponCode && clean.couponCode !== (previous && previous.couponCode)) {
      const c = await findCoupon(clean.couponCode);
      if (!c) throw new TemplateError('Coupon not found.', 'couponCode', 400, 'COUPON_NOT_FOUND');
      const v = couponView(c);
      if (!v.bindable) throw new TemplateError('Only an active coupon can be used in a template.', 'couponCode', 400, 'COUPON_NOT_ACTIVE');
    }
    for (const id of imageIdsOf(clean)) {
      if (!await store.getImage(id)) throw new TemplateError(`image ${id} was not uploaded`, 'layers', 400, 'UNKNOWN_IMAGE');
    }
  };

  const tplId = (req) => String(req.params.id || '');
  const notFound = (res) => res.status(404).json({ error: 'Template not found.', code: 'NOT_FOUND' });

  r.get('/admin/marketing/templates', requireAdmin, ready, readLimit, wrap(async (req, res) => {
    const status = ['active', 'archived', 'all'].includes(req.query.status) ? req.query.status : 'all';
    const list = (await store.listTemplates()).filter((t) => status === 'all' || t.status === status);
    res.set('Cache-Control', 'no-store').json({
      ok: true,
      limits: LIMITS,
      sizes: SIZE_PRESETS,
      templates: list.map((t) => ({
        id: t.id, name: t.name, status: t.status, size: t.size, couponCode: t.couponCode || null,
        layerCount: Array.isArray(t.layers) ? t.layers.length : 0, updatedAt: t.updatedAt, updatedBy: t.updatedBy, createdAt: t.createdAt,
      })),
    });
  }));

  r.post('/admin/marketing/templates', requireAdmin, ready, writeLimit, wrap(async (req, res) => {
    let clean;
    try { clean = cleanTemplate(req.body); await checkRefs(clean); } catch (e) { return fail(res, e); }
    if ((await store.listTemplates()).length >= LIMITS.maxTemplates) {
      return res.status(409).json({ error: `At most ${LIMITS.maxTemplates} templates. Delete old ones first.`, code: 'TOO_MANY_TEMPLATES' });
    }
    const now = Date.now();
    const doc = { ...clean, id: newTemplateId(), createdAt: now, updatedAt: now, createdBy: by(req), updatedBy: by(req) };
    await store.saveTemplate(doc);
    await audit(req, 'marketing.template.create', doc.id, { name: doc.name, couponCode: doc.couponCode });
    res.status(201).set('Cache-Control', 'no-store').json({ ok: true, template: await viewOf(doc, await planLabels()) });
  }));

  r.get('/admin/marketing/templates/:id', requireAdmin, ready, readLimit, wrap(async (req, res) => {
    const t = await store.getTemplate(tplId(req));
    if (!t) return notFound(res);
    res.set('Cache-Control', 'no-store').json({ ok: true, template: await viewOf(t, await planLabels()) });
  }));

  r.put('/admin/marketing/templates/:id', requireAdmin, ready, writeLimit, wrap(async (req, res) => {
    const prev = await store.getTemplate(tplId(req));
    if (!prev) return notFound(res);
    const base = req.body && Number(req.body.baseUpdatedAt);
    if (base && Number(prev.updatedAt) !== base) {
      return res.status(409).json({ error: 'Someone else saved this template meanwhile. Reload it first.', code: 'CONFLICT', updatedAt: prev.updatedAt, updatedBy: prev.updatedBy });
    }
    let clean;
    try { clean = cleanTemplate(req.body); await checkRefs(clean, prev); } catch (e) { return fail(res, e); }
    const doc = { ...clean, id: prev.id, createdAt: prev.createdAt, createdBy: prev.createdBy, updatedAt: Math.max(Date.now(), (Number(prev.updatedAt) || 0) + 1), updatedBy: by(req) };
    await store.saveTemplate(doc);
    await audit(req, 'marketing.template.update', doc.id, { name: doc.name, couponCode: doc.couponCode, layers: doc.layers.length });
    res.set('Cache-Control', 'no-store').json({ ok: true, template: await viewOf(doc, await planLabels()) });
  }));

  r.patch('/admin/marketing/templates/:id/status', requireAdmin, ready, writeLimit, wrap(async (req, res) => {
    const prev = await store.getTemplate(tplId(req));
    if (!prev) return notFound(res);
    const status = req.body && req.body.status;
    if (!STATUSES.includes(status)) return res.status(400).json({ error: 'status must be active or archived', code: 'BAD_TEMPLATE', path: 'status' });
    const doc = { ...prev, status, updatedAt: Math.max(Date.now(), (Number(prev.updatedAt) || 0) + 1), updatedBy: by(req) };
    await store.saveTemplate(doc);
    await audit(req, status === 'archived' ? 'marketing.template.archive' : 'marketing.template.activate', doc.id, { name: doc.name });
    res.set('Cache-Control', 'no-store').json({ ok: true, template: await viewOf(doc, await planLabels()) });
  }));

  r.post('/admin/marketing/templates/:id/duplicate', requireAdmin, ready, writeLimit, wrap(async (req, res) => {
    const prev = await store.getTemplate(tplId(req));
    if (!prev) return notFound(res);
    if ((await store.listTemplates()).length >= LIMITS.maxTemplates) {
      return res.status(409).json({ error: `At most ${LIMITS.maxTemplates} templates. Delete old ones first.`, code: 'TOO_MANY_TEMPLATES' });
    }
    const now = Date.now();
    const name = `${String(prev.name || 'Template').slice(0, LIMITS.nameMax - 7)} (copy)`;
    const doc = { ...prev, id: newTemplateId(), name, status: 'active', createdAt: now, updatedAt: now, createdBy: by(req), updatedBy: by(req) };
    await store.saveTemplate(doc);
    await audit(req, 'marketing.template.duplicate', doc.id, { from: prev.id, name });
    res.status(201).set('Cache-Control', 'no-store').json({ ok: true, template: await viewOf(doc, await planLabels()) });
  }));

  r.delete('/admin/marketing/templates/:id', requireAdmin, ready, writeLimit, wrap(async (req, res) => {
    const prev = await store.getTemplate(tplId(req));
    if (!prev) return notFound(res);
    await store.removeTemplate(prev.id);
    await audit(req, 'marketing.template.delete', prev.id, { name: prev.name });
    res.json({ ok: true, id: prev.id });
  }));

  r.get('/admin/marketing/coupons', requireAdmin, ready, readLimit, wrap(async (req, res) => {
    const labels = await planLabels();
    const list = typeof repo.listCoupons === 'function' ? await repo.listCoupons(500) : [];
    const coupons = list.map((c) => couponView(c, labels)).filter((c) => req.query.all === '1' || c.bindable);
    res.set('Cache-Control', 'no-store').json({ ok: true, coupons, planLabels: labels });
  }));

  // ---------------- images ----------------
  const rawImage = express.raw({ type: () => true, limit: reviewPhotos.MAX_BYTES });
  r.post('/admin/marketing/images', requireAdmin, ready, uploadLimit, (req, res, next) => {
    if (req.is('application/json') || req.is('multipart/form-data')) {
      return res.status(415).json({ error: 'Send the image bytes as image/jpeg, image/png or image/webp.', code: 'UNSUPPORTED_PHOTO' });
    }
    rawImage(req, res, (err) => {
      if (!err) return next();
      if (err.type === 'entity.too.large') return res.status(413).json({ error: 'This image is too large (up to 2 MB).', code: 'PHOTO_TOO_LARGE' });
      return res.status(400).json({ error: 'The image did not arrive complete. Please try again.', code: 'NO_PHOTO' });
    });
  }, wrap(async (req, res) => {
    let prepared;
    try { prepared = reviewPhotos.preparePhoto(req.body); } catch (e) {
      if (!(e instanceof reviewPhotos.PhotoError)) throw e;
      return res.status(e.status).json({ error: e.message, code: e.code });
    }
    if ((await store.listImages()).length >= LIMITS.maxImages) {
      return res.status(409).json({ error: `At most ${LIMITS.maxImages} images. Delete unused ones first.`, code: 'TOO_MANY_IMAGES' });
    }
    const meta = await photosOf().save(prepared);
    const doc = { id: meta.id, mime: meta.mime, ext: meta.ext, bytes: meta.bytes, width: meta.width, height: meta.height, at: Date.now(), by: by(req) };
    await store.saveImage(doc);
    await audit(req, 'marketing.image.upload', doc.id, { bytes: doc.bytes, mime: doc.mime });
    res.status(201).json({ ok: true, image: { id: doc.id, mime: doc.mime, width: doc.width, height: doc.height, bytes: doc.bytes, url: `/api/admin/marketing/images/${doc.id}` } });
  }));

  r.get('/admin/marketing/images', requireAdmin, ready, readLimit, wrap(async (req, res) => {
    const list = await store.listImages();
    res.set('Cache-Control', 'no-store').json({ ok: true, images: list.map((m) => ({ id: m.id, mime: m.mime, width: m.width, height: m.height, bytes: m.bytes, at: m.at, url: `/api/admin/marketing/images/${m.id}` })) });
  }));

  r.get('/admin/marketing/images/:id', requireAdmin, ready, readLimit, wrap(async (req, res) => {
    const meta = await store.getImage(String(req.params.id || ''));
    const data = meta ? await photosOf().read(meta) : null;
    if (!data) return res.status(404).json({ error: 'Image not found.', code: 'NOT_FOUND' });
    res.set({ 'Content-Type': meta.mime, 'Cache-Control': 'private, max-age=86400', 'X-Content-Type-Options': 'nosniff' }).send(data);
  }));

  r.delete('/admin/marketing/images/:id', requireAdmin, ready, writeLimit, wrap(async (req, res) => {
    const meta = await store.getImage(String(req.params.id || ''));
    if (!meta) return res.status(404).json({ error: 'Image not found.', code: 'NOT_FOUND' });
    const users = (await store.listTemplates()).filter((t) => imageIdsOf(t).includes(meta.id));
    if (users.length) return res.status(409).json({ error: `Used by ${users.length} template(s). Remove it there first.`, code: 'IMAGE_IN_USE', templates: users.map((t) => ({ id: t.id, name: t.name })) });
    await photosOf().remove(meta).catch(() => {});
    await store.removeImage(meta.id);
    await audit(req, 'marketing.image.delete', meta.id, {});
    res.json({ ok: true, id: meta.id });
  }));
}

module.exports = {
  FEATURE_ID, LIMITS, SIZE_PRESETS, LAYER_TYPES, FONTS, SHAPES, PATTERNS, COUPON_STYLES, PLACEHOLDERS, SCHEMA_VERSION,
  TemplateError, cleanTemplate, imageIdsOf, couponPlaceholders, couponView, substitute, formatDate, discountText, planText,
  createMarketingStore, registerMarketingRoutes,
};
