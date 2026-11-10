'use strict';
/**
 * 3.55 ratings & reviews engagement (docs/features_355/ratings_reviews.md).
 *
 * One versioned config document (subscription_config k='engagement_config') that the web admin
 * "Engagement" section edits and the app reads:
 *   - texts of the after-ride prompts (en / hi / te; hi and te fall back to en),
 *   - quick chips of the trip review and of the place review per category group,
 *   - the "Rate CoRoute" (Google Play in-app review) timing rules,
 *   - the after-ride review switches (trip, places, how many places, how long the trip report asks).
 * Plus the in-app "Send feedback" inbox and review statistics for the admin.
 *
 * Endpoints (all under /api):
 *   GET  /app/engagement-config            rider: { ok, version, config } (ETag, private max-age=300)
 *   POST /me/feedback                      rider: { message, topic?, appVersion?, device?, contactOk? }
 *   GET  /admin/engagement/config          admin: { ok, version, config, defaults, history }
 *   PUT  /admin/engagement/config          admin: { config, baseVersion } (409 VERSION_CONFLICT)
 *   POST /admin/engagement/config/restore  admin: { version } (a version kept in the history)
 *   GET  /admin/engagement/feedback        admin: ?status=OPEN|HANDLED&q=&limit=
 *   PUT  /admin/engagement/feedback/:id    admin: { handled: bool, note? }
 *   GET  /admin/engagement/stats           admin: ?days=90 trip ratings, chips, place ratings by category
 *
 * Trip and place reviews themselves keep their own endpoints (POST /api/trips/:tripId/feedback,
 * POST /api/places/reviews); both accept `chips` (ids from this config).
 *
 * Google Play rules kept here (and checked by test/engagement_355.test.js):
 *  - No prices, payments, coupons, offers or rewards in any template, in any language.
 *  - No incentive to rate ("rate us to get ...", "5 stars for ...") and no gating wording ("Enjoying
 *    CoRoute? Rate us" / "Not happy? Tell us instead"): the app never asks how the rider feels before
 *    the Play review, and every rider gets the same Play review flow.
 *  - The rating ask can be switched off or made rarer, never more often than 3 times a year.
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { requireAuth, requireAdmin } = require('./auth');
const { plainText } = require('./trip_reviews');
const { COLLECTIONS: C } = require('./oracle/repo');

const DOC_KEY = 'engagement_config';
const FEEDBACK_COLL = 'engagement_feedback';
const HISTORY_MAX = 10;
const LANGS = Object.freeze(['en', 'hi', 'te']);
const CHIP_GROUPS = Object.freeze(['stay', 'food', 'fuel', 'viewpoint', 'other']);
const FEEDBACK_TOPICS = Object.freeze(['general', 'bug', 'idea', 'ride', 'places', 'other']);
const CHIP_ID = /^[a-z][a-z0-9_]{0,31}$/;
const FEEDBACK_ID = /^af_[a-f0-9]{20}$/;
const MAX_CHIPS = 10;
const CHIP_LABEL_MAX = 28;
const NOTE_MAX = 280;
const FEEDBACK_MIN = 5;
const FEEDBACK_MAX = 1000;
const DAY = 86400000;

/** Text keys the admin can edit, with their length limit. */
const TEXT_KEYS = Object.freeze({
  tripTitle: 60,
  tripSubtitle: 160,
  noteHint: 80,
  placesTitle: 60,
  placesSubtitle: 160,
  rateTitle: 40,
  rateSubtitle: 120,
  feedbackTitle: 40,
  feedbackSubtitle: 160,
  thanks: 80,
});

const t = (en, hi, te) => ({ en, hi, te });
const chip = (id, en, hi, te) => ({ id, label: t(en, hi, te) });

const DEFAULT_CONFIG = Object.freeze({
  texts: {
    tripTitle: t('How was the ride?', 'राइड कैसी रही?', 'రైడ్ ఎలా ఉంది?'),
    tripSubtitle: t('Optional. Only you and the CoRoute team see your note.', 'वैकल्पिक। आपका नोट सिर्फ़ आप और CoRoute टीम देखती है।', 'ఐచ్ఛికం. మీ నోట్ మీకు మరియు CoRoute టీమ్‌కు మాత్రమే కనిపిస్తుంది.'),
    noteHint: t('Add a short note (optional)', 'छोटा नोट लिखें (वैकल्पिक)', 'చిన్న నోట్ రాయండి (ఐచ్ఛికం)'),
    placesTitle: t('Places you stopped at', 'जहाँ आप रुके', 'మీరు ఆగిన చోట్లు'),
    placesSubtitle: t('A quick rating helps the next riders.', 'आपकी रेटिंग अगले राइडर्स की मदद करती है।', 'మీ రేటింగ్ తర్వాతి రైడర్లకు ఉపయోగపడుతుంది.'),
    rateTitle: t('Rate CoRoute', 'CoRoute को रेट करें', 'CoRouteకి రేటింగ్ ఇవ్వండి'),
    rateSubtitle: t('Share your opinion on Google Play', 'Google Play पर अपनी राय दें', 'Google Playలో మీ అభిప్రాయం చెప్పండి'),
    feedbackTitle: t('Send feedback', 'सुझाव भेजें', 'అభిప్రాయం పంపండి'),
    feedbackSubtitle: t('Tell the CoRoute team what to fix or improve.', 'CoRoute टीम को बताएं क्या सुधारें।', 'ఏమి మెరుగుపరచాలో CoRoute టీమ్‌కు చెప్పండి.'),
    thanks: t('Thanks, saved.', 'धन्यवाद, सेव हो गया।', 'ధన్యవాదాలు, సేవ్ అయింది.'),
  },
  tripChips: [
    chip('great_route', 'Great route', 'बढ़िया रास्ता', 'మంచి రూట్'),
    chip('good_pace', 'Good pace', 'सही रफ़्तार', 'సరైన వేగం'),
    chip('too_fast', 'Too fast', 'बहुत तेज़', 'చాలా వేగం'),
    chip('long_breaks', 'Long breaks', 'लंबे ब्रेक', 'పెద్ద బ్రేక్‌లు'),
    chip('bad_roads', 'Bad roads', 'खराब सड़कें', 'చెడ్డ రోడ్లు'),
    chip('safe_group', 'Safe group', 'सुरक्षित ग्रुप', 'సురక్షిత గ్రూప్'),
  ],
  placeChips: {
    stay: [
      chip('clean', 'Clean', 'साफ़', 'శుభ్రంగా'),
      chip('bike_parking', 'Bike parking', 'बाइक पार्किंग', 'బైక్ పార్కింగ్'),
      chip('safe', 'Safe', 'सुरक्षित', 'సురక్షితం'),
      chip('good_value', 'Good value', 'पैसा वसूल', 'విలువైనది'),
    ],
    food: [
      chip('tasty', 'Tasty', 'स्वादिष्ट', 'రుచికరం'),
      chip('quick', 'Quick', 'जल्दी', 'త్వరగా'),
      chip('hygienic', 'Hygienic', 'साफ़-सुथरा', 'పరిశుభ్రం'),
      chip('bike_parking', 'Bike parking', 'बाइक पार्किंग', 'బైక్ పార్కింగ్'),
    ],
    fuel: [
      chip('quick', 'Quick', 'जल्दी', 'త్వరగా'),
      chip('clean_toilets', 'Clean toilets', 'साफ़ शौचालय', 'శుభ్రమైన టాయిలెట్లు'),
      chip('air_pump', 'Air pump', 'हवा भरने की मशीन', 'గాలి పంపు'),
    ],
    viewpoint: [
      chip('great_view', 'Great view', 'शानदार नज़ारा', 'అద్భుత దృశ్యం'),
      chip('safe_parking', 'Safe parking', 'सुरक्षित पार्किंग', 'సురక్షిత పార్కింగ్'),
      chip('crowded', 'Crowded', 'भीड़', 'రద్దీ'),
    ],
    other: [
      chip('helpful', 'Helpful', 'मददगार', 'సహాయకరం'),
      chip('clean', 'Clean', 'साफ़', 'శుభ్రంగా'),
      chip('safe', 'Safe', 'सुरक्षित', 'సురక్షితం'),
    ],
  },
  ratingPrompt: { enabled: true, afterRides: 3, cooldownDays: 30, maxPerYear: 3 },
  reviews: { tripEnabled: true, placesEnabled: true, maxPlaces: 2, reportDays: 7 },
});

/** Rules for the numbers (min, max). maxPerYear never above 3 (owner rule, Play quota). */
const RANGES = Object.freeze({
  'ratingPrompt.afterRides': [1, 50],
  'ratingPrompt.cooldownDays': [14, 365],
  'ratingPrompt.maxPerYear': [1, 3],
  'reviews.maxPlaces': [0, 2],
  'reviews.reportDays': [0, 7],
});

class EngagementError extends Error {
  constructor(status, message, code, fields) {
    super(message);
    this.status = status;
    this.code = code;
    if (fields) this.fields = fields;
  }
}

// ------------------------------------------------------------------ Play-neutral guard
/**
 * Words a Play listing prompt must never carry: money, payments, offers and rewards (English, Hindi,
 * Telugu), incentives to rate, and gating ("enjoying it? rate us" / "not happy? tell us instead").
 */
const POLICY_RULES = Object.freeze([
  { code: 'MONEY', re: /(₹|\$|€|£|\brs\.?\s*\d|\binr\b|\busd\b|rupee|price|pricing|cost|paid|payment|pay\b|purchase|\bbuy|checkout|subscri|premium|upgrade|renew|refund|wallet)/i },
  { code: 'OFFER', re: /(coupon|discount|voucher|promo|offer|\bdeals?\b|cashback|cash back|\d+\s*%\s*off|percent off|\bsale\b|free\s+(month|week|day|plan|trial|ride|pro|access|upgrade)|\btrial)/i },
  { code: 'REWARD', re: /(reward|gift|prize|\bwin\b|winner|lucky draw|contest|giveaway|bonus|\bpoints?\b|badge|unlock|in exchange|in return)/i },
  { code: 'INCENTIVE', re: /((rate|review)\s+(us\s+)?(to|and)\s+(get|win|earn|unlock|receive)|(get|win|earn|unlock|receive)\b.{0,40}\b(for|by)\s+(rating|reviewing|a review|5 stars|five stars)|5[\s-]?stars?\s+(for|to|and)|five[\s-]?stars?\s+(for|to|and))/i },
  { code: 'GATING', re: /((enjoy|enjoying|like|liking|love|loving|happy)\b.{0,40}\b(rate|review|play store|google play|stars?)|(not happy|unhappy|dislike|don't like|do not like|disappointed)\b.{0,60}\b(feedback|tell us|write to us|instead))/i },
  // Hindi and Telugu money / offer / reward words.
  { code: 'MONEY', re: /(कीमत|दाम|भुगतान|पैसे दें|खरीद|सदस्यता|ధర|చెల్లింపు|కొనుగోలు|సభ్యత్వ)/ },
  { code: 'OFFER', re: /(कूपन|छूट|डिस्काउंट|ऑफ़र|ऑफर|मुफ़्त|मुफ्त|फ्री|కూపన్|డిస్కౌంట్|తగ్గింపు|ఆఫర్|ఉచిత|ఫ్రీ)/ },
  { code: 'REWARD', re: /(इनाम|उपहार|गिफ्ट|पुरस्कार|बोनस|బహుమతి|గిఫ్ట్|బోనస్|రివార్డ్)/ },
]);

const POLICY_MESSAGES = Object.freeze({
  MONEY: 'No prices, payments or plans in app prompts (Google Play policy).',
  OFFER: 'No coupons, discounts, offers or free trials in app prompts (Google Play policy).',
  REWARD: 'No rewards, gifts, prizes or points for reviews (Google Play policy).',
  INCENTIVE: 'Never offer anything for a rating or review (Google Play policy).',
  GATING: 'Do not ask how the rider feels before sending them to rate (no review gating, Google Play policy).',
});

/** The first Play policy problem in [text] ('MONEY' | 'OFFER' | 'REWARD' | 'INCENTIVE' | 'GATING') or null. */
function policyProblem(text) {
  const s = String(text || '');
  if (!s) return null;
  // "Good value" for a stay is about the place, not CoRoute: the word "value" is fine on its own.
  for (const rule of POLICY_RULES) if (rule.re.test(s)) return rule.code;
  return null;
}

// ------------------------------------------------------------------ validation
const clone = (v) => JSON.parse(JSON.stringify(v));
const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);

/** A clean { en, hi, te } (en required unless [optional]); problems go into [fields] under [path]. */
function cleanLocalized(v, path, max, fields, { optional = false } = {}) {
  const out = {};
  const src = typeof v === 'string' ? { en: v } : (isObj(v) ? v : {});
  for (const lang of LANGS) {
    const raw = src[lang];
    if (raw === undefined || raw === null) continue;
    if (typeof raw !== 'string') { fields[`${path}.${lang}`] = 'Text only.'; continue; }
    const s = plainText(raw).replace(/\s+/g, ' ').trim();
    if (!s) continue;
    if (s.length > max) { fields[`${path}.${lang}`] = `Keep it under ${max} characters.`; continue; }
    const bad = policyProblem(s);
    if (bad) { fields[`${path}.${lang}`] = POLICY_MESSAGES[bad]; continue; }
    out[lang] = s;
  }
  if (!out.en && !optional && !fields[`${path}.en`]) fields[`${path}.en`] = 'English text is required.';
  return out;
}

function cleanChipList(list, path, fields) {
  if (list === undefined) return null;
  if (!Array.isArray(list)) { fields[path] = 'A list of chips.'; return []; }
  if (list.length > MAX_CHIPS) { fields[path] = `Up to ${MAX_CHIPS} chips.`; return []; }
  const seen = new Set();
  const out = [];
  list.forEach((c, i) => {
    const p = `${path}[${i}]`;
    if (!isObj(c)) { fields[p] = 'Each chip needs an id and a label.'; return; }
    const id = String(c.id || '').trim();
    if (!CHIP_ID.test(id)) { fields[`${p}.id`] = 'Id: lower-case letters, digits and _ (up to 32), starting with a letter.'; return; }
    if (seen.has(id)) { fields[`${p}.id`] = `"${id}" is used twice.`; return; }
    seen.add(id);
    const label = cleanLocalized(c.label, `${p}.label`, CHIP_LABEL_MAX, fields);
    if (label.en) out.push({ id, label });
  });
  return out;
}

function cleanInt(v, key, fields, fallback) {
  const [min, max] = RANGES[key];
  if (v === undefined || v === null || v === '') return fallback;
  const n = Number(v);
  if (!Number.isInteger(n) || n < min || n > max) { fields[key] = `Whole number from ${min} to ${max}.`; return fallback; }
  return n;
}

const cleanBool = (v, fallback) => (typeof v === 'boolean' ? v : fallback);

/**
 * Validates an admin's config (missing parts keep the defaults). Returns the clean config or throws
 * EngagementError(422) with `fields` (path -> message). Unknown keys are dropped.
 */
function validateConfig(input) {
  const b = isObj(input) ? input : {};
  const d = DEFAULT_CONFIG;
  const fields = {};
  const texts = {};
  const srcTexts = isObj(b.texts) ? b.texts : {};
  for (const [key, max] of Object.entries(TEXT_KEYS)) {
    texts[key] = srcTexts[key] === undefined ? clone(d.texts[key]) : cleanLocalized(srcTexts[key], `texts.${key}`, max, fields);
  }
  const tripChips = cleanChipList(b.tripChips, 'tripChips', fields) || clone(d.tripChips);
  const placeChips = {};
  const srcPlace = isObj(b.placeChips) ? b.placeChips : {};
  for (const g of CHIP_GROUPS) placeChips[g] = cleanChipList(srcPlace[g], `placeChips.${g}`, fields) || clone(d.placeChips[g]);
  const rp = isObj(b.ratingPrompt) ? b.ratingPrompt : {};
  const ratingPrompt = {
    enabled: cleanBool(rp.enabled, d.ratingPrompt.enabled),
    afterRides: cleanInt(rp.afterRides, 'ratingPrompt.afterRides', fields, d.ratingPrompt.afterRides),
    cooldownDays: cleanInt(rp.cooldownDays, 'ratingPrompt.cooldownDays', fields, d.ratingPrompt.cooldownDays),
    maxPerYear: cleanInt(rp.maxPerYear, 'ratingPrompt.maxPerYear', fields, d.ratingPrompt.maxPerYear),
  };
  const rv = isObj(b.reviews) ? b.reviews : {};
  const reviews = {
    tripEnabled: cleanBool(rv.tripEnabled, d.reviews.tripEnabled),
    placesEnabled: cleanBool(rv.placesEnabled, d.reviews.placesEnabled),
    maxPlaces: cleanInt(rv.maxPlaces, 'reviews.maxPlaces', fields, d.reviews.maxPlaces),
    reportDays: cleanInt(rv.reportDays, 'reviews.reportDays', fields, d.reviews.reportDays),
  };
  if (Object.keys(fields).length) throw new EngagementError(422, 'Please correct the highlighted fields.', 'INVALID_CONFIG', fields);
  return { texts, tripChips, placeChips, ratingPrompt, reviews };
}

/**
 * Chip ids a rider sent with a review: at most [MAX_CHIPS] distinct ids of the id shape (unknown ids
 * are kept as sent; the stats only label the ones in the config). Never throws.
 */
function cleanChipIds(v) {
  if (!Array.isArray(v)) return [];
  const out = [];
  for (const x of v) {
    const id = typeof x === 'string' ? x.trim() : '';
    if (CHIP_ID.test(id) && !out.includes(id)) out.push(id);
    if (out.length >= MAX_CHIPS) break;
  }
  return out;
}

// ------------------------------------------------------------------ config store
class EngagementStore {
  constructor({ repo, cacheMs = 30000 }) {
    this.repo = repo;
    this.soda = repo.soda;
    this.cacheMs = cacheMs;
    this.cached = null;
    this.cachedAt = 0;
  }

  async _read() {
    const row = await this.soda.findOne(C.subscriptionConfig, { k: DOC_KEY }).catch(() => null);
    return row && row.value ? row.value : null;
  }

  /** { version, config, updatedAt, updatedBy, history }: version 0 = the built-in defaults. */
  async get({ fresh = false } = {}) {
    if (!fresh && this.cached && Date.now() - this.cachedAt < this.cacheMs) return this.cached;
    let doc = null;
    try { doc = await this._read(); } catch { doc = null; }
    let out;
    if (doc && isObj(doc.config)) {
      let config;
      // A stored config that no longer passes (rules got stricter) falls back to the defaults.
      try { config = validateConfig(doc.config); } catch { config = clone(DEFAULT_CONFIG); }
      out = { version: Number(doc.version) || 1, config, updatedAt: doc.updatedAt || 0, updatedBy: doc.updatedBy || '', history: Array.isArray(doc.history) ? doc.history : [] };
    } else {
      out = { version: 0, config: clone(DEFAULT_CONFIG), updatedAt: 0, updatedBy: '', history: [] };
    }
    this.cached = out;
    this.cachedAt = Date.now();
    return out;
  }

  /** Saves a validated config as the next version. Throws 409 when [baseVersion] is not the current one. */
  async save(input, { baseVersion, by = 'admin', note = '' } = {}) {
    const config = validateConfig(input);
    const cur = await this.get({ fresh: true });
    if (baseVersion !== undefined && baseVersion !== null && Number(baseVersion) !== cur.version) {
      throw new EngagementError(409, 'Someone saved a newer version. Reload and apply your change again.', 'VERSION_CONFLICT');
    }
    const version = cur.version + 1;
    const now = Date.now();
    const entry = { version, at: now, by: String(by).slice(0, 120), note: plainText(note).slice(0, 120), config };
    const history = [entry, ...cur.history.filter((h) => h && h.version !== version)].slice(0, HISTORY_MAX);
    await this.soda.upsertBy(C.subscriptionConfig, { k: DOC_KEY }, { k: DOC_KEY, version, config, updatedAt: now, updatedBy: entry.by, history });
    this.cached = null;
    return this.get({ fresh: true });
  }

  async restore(version, { by = 'admin', baseVersion } = {}) {
    const cur = await this.get({ fresh: true });
    const h = cur.history.find((x) => x && Number(x.version) === Number(version));
    if (!h || !isObj(h.config)) throw new EngagementError(404, 'That version is not kept any more.', 'NOT_FOUND');
    return this.save(h.config, { baseVersion: baseVersion === undefined ? cur.version : baseVersion, by, note: `Restored version ${h.version}` });
  }
}

// ------------------------------------------------------------------ feedback
/** A rider's in-app feedback, validated. Throws EngagementError(422). */
function validateFeedback(body) {
  const b = isObj(body) ? body : {};
  const fields = {};
  const message = plainText(typeof b.message === 'string' ? b.message.slice(0, FEEDBACK_MAX * 2) : '');
  if (message.length < FEEDBACK_MIN) fields.message = `Please write at least ${FEEDBACK_MIN} characters.`;
  else if (message.length > FEEDBACK_MAX) fields.message = `Please keep it under ${FEEDBACK_MAX} characters.`;
  else if ((message.match(/https?:\/\//gi) || []).length > 2) fields.message = 'Too many links.';
  const topic = String(b.topic || 'general').trim().toLowerCase();
  if (!FEEDBACK_TOPICS.includes(topic)) fields.topic = 'Choose a topic from the list.';
  if (Object.keys(fields).length) throw new EngagementError(422, 'Please correct the highlighted fields.', 'INVALID_FEEDBACK', fields);
  const short = (v, n) => plainText(typeof v === 'string' ? v : '').replace(/\s+/g, ' ').slice(0, n);
  return {
    message, topic,
    appVersion: short(b.appVersion, 40),
    device: short(b.device, 80),
    platform: ['android', 'ios', 'web'].includes(String(b.platform || '').toLowerCase()) ? String(b.platform).toLowerCase() : '',
    contactOk: b.contactOk === true,
  };
}

const firstName = (n) => String(n || '').trim().split(/\s+/)[0].slice(0, 30) || 'Rider';

async function addFeedback(soda, user, input, now = Date.now()) {
  // The same text from the same rider within 10 minutes is a double tap: kept once.
  const recent = await soda.query(FEEDBACK_COLL, { userId: String(user.userId) }, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit: 5 }).catch(() => []);
  const dup = recent.map((r) => r.value).find((f) => f && f.message === input.message && now - (f.createdAt || 0) < 10 * 60000);
  if (dup) return { doc: dup, duplicate: true };
  const doc = {
    feedbackId: `af_${crypto.randomBytes(10).toString('hex')}`,
    userId: String(user.userId),
    userName: firstName(user.name),
    // The e-mail only when the rider asked to be contacted.
    email: input.contactOk && user.email ? String(user.email).slice(0, 120) : '',
    message: input.message,
    topic: input.topic,
    appVersion: input.appVersion,
    device: input.device,
    platform: input.platform,
    contactOk: input.contactOk,
    status: 'OPEN',
    createdAt: now,
    handledAt: null,
    handledBy: '',
    adminNote: '',
  };
  await soda.insert(FEEDBACK_COLL, doc);
  return { doc, duplicate: false };
}

/** Admin list: newest first, optional status and free-text filter (message, name, topic, version). */
async function listFeedback(soda, { status = null, q = '', limit = 200 } = {}) {
  const filter = status ? { status } : {};
  const rows = await soda.query(FEEDBACK_COLL, filter, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit: 1000 }).catch(() => []);
  const all = rows.map((r) => r.value).filter((f) => f && f.feedbackId);
  const needle = String(q || '').trim().toLowerCase().slice(0, 80);
  const hits = needle ? all.filter((f) => [f.message, f.userName, f.topic, f.appVersion, f.device, f.email].some((v) => String(v || '').toLowerCase().includes(needle))) : all;
  return hits.slice(0, Math.max(1, Math.min(500, Number(limit) || 200)));
}

async function setHandled(soda, feedbackId, { handled, note, by }) {
  if (!FEEDBACK_ID.test(String(feedbackId || ''))) return null;
  const row = await soda.findOne(FEEDBACK_COLL, { feedbackId: String(feedbackId) });
  if (!row) return null;
  const next = {
    ...row.value,
    status: handled ? 'HANDLED' : 'OPEN',
    handledAt: handled ? Date.now() : null,
    handledBy: handled ? String(by || 'admin').slice(0, 120) : '',
    adminNote: note === undefined ? (row.value.adminNote || '') : plainText(note).slice(0, 500),
  };
  await soda.replace(FEEDBACK_COLL, row.key, next);
  return next;
}

// ------------------------------------------------------------------ stats
const round1 = (n) => Math.round(n * 10) / 10;

/** Place category (place review) -> chip group of the config. Same table as the app (EngagementConfig.groupOf). */
function chipGroupOf(category) {
  switch (String(category || '').toLowerCase()) {
    case 'stay': return 'stay';
    case 'food': return 'food';
    case 'fuel': case 'ev': return 'fuel';
    case 'viewpoint': case 'heritage': return 'viewpoint';
    default: return 'other';
  }
}

function labelMap(list) {
  const m = {};
  for (const c of list || []) m[c.id] = (c.label && c.label.en) || c.id;
  return m;
}

function countChips(rows, labels) {
  const counts = new Map();
  for (const r of rows) for (const id of cleanChipIds(r.chips)) counts.set(id, (counts.get(id) || 0) + 1);
  return [...counts.entries()].map(([id, count]) => ({ id, label: labels[id] || id, count })).sort((a, b) => b.count - a.count || a.id.localeCompare(b.id));
}

/**
 * Review statistics (pure: rows in, numbers out). [trips]: trip review docs, [places]: place review
 * docs, [feedback]: in-app feedback docs. Only rows of the last [days] days (by submission time).
 */
function computeStats({ trips = [], places = [], feedback = [], config = DEFAULT_CONFIG, days = 90, now = Date.now() }) {
  const since = now - days * DAY;
  const tripRows = trips.filter((r) => r && Number.isInteger(r.rating) && r.rating >= 1 && r.rating <= 5 && (r.submittedAt || r.updatedAt || 0) >= since && r.status !== 'WITHDRAWN');
  const placeRows = places.filter((r) => r && Number(r.rating) >= 1 && Number(r.rating) <= 5 && (r.createdAt || r.updatedAt || 0) >= since);
  const dist = [0, 0, 0, 0, 0];
  for (const r of tripRows) dist[r.rating - 1]++;
  const avg = (rows) => (rows.length ? round1(rows.reduce((a, r) => a + Number(r.rating), 0) / rows.length) : null);
  // Weekly trip rating trend (oldest first), at most 13 weeks.
  const weeks = Math.min(13, Math.max(1, Math.ceil(days / 7)));
  const weekly = [];
  for (let i = weeks - 1; i >= 0; i--) {
    const from = now - (i + 1) * 7 * DAY, to = now - i * 7 * DAY;
    const w = tripRows.filter((r) => { const at = r.submittedAt || r.updatedAt || 0; return at >= from && at < to; });
    weekly.push({ weekStart: from, count: w.length, avg: avg(w) });
  }
  const byCategory = {};
  for (const r of placeRows) {
    const c = String(r.category || 'other');
    (byCategory[c] = byCategory[c] || []).push(r);
  }
  const placeCategories = Object.entries(byCategory).map(([category, rows]) => ({ category, group: chipGroupOf(category), count: rows.length, avg: avg(rows) }))
    .sort((a, b) => b.count - a.count || a.category.localeCompare(b.category));
  const placeChips = {};
  for (const g of CHIP_GROUPS) {
    placeChips[g] = countChips(placeRows.filter((r) => chipGroupOf(r.category) === g), labelMap(config.placeChips && config.placeChips[g]));
  }
  return {
    days,
    trip: { count: tripRows.length, avg: avg(tripRows), distribution: dist, chips: countChips(tripRows, labelMap(config.tripChips)), withNote: tripRows.filter((r) => String(r.writtenFeedback || '').trim()).length, weekly },
    places: { count: placeRows.length, avg: avg(placeRows), categories: placeCategories, chips: placeChips },
    feedback: { total: feedback.length, open: feedback.filter((f) => f && f.status !== 'HANDLED').length },
  };
}

// ------------------------------------------------------------------ routes
const wrap = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function sendError(res, e) {
  if (!(e instanceof EngagementError)) throw e;
  return res.status(e.status).json({ error: e.message, code: e.code, ...(e.fields ? { fields: e.fields } : {}) });
}

/** What the app gets: the config without the admin history. */
function appView(state) {
  return { ok: true, version: state.version, config: state.config };
}

function engagementRouter({ repo, gate, store = null }) {
  const r = express.Router();
  const st = store || new EngagementStore({ repo });
  const soda = repo.soda;
  const auth = requireAuth(gate);
  const byUser = (windowMs, limit, message) => rateLimit({
    windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false, validate: false,
    keyGenerator: (req) => `eng:${req.user?.userId || req.ip}`,
    message: { error: message, code: 'RATE_LIMITED' },
  });
  const readLimiter = byUser(60 * 1000, 30, 'Too many requests. Try again later.');
  const feedbackHourly = byUser(60 * 60 * 1000, 5, 'Thanks! You sent a lot of feedback this hour. Please try again later.');
  const feedbackDaily = byUser(24 * 60 * 60 * 1000, 20, 'Thanks! You sent a lot of feedback today. Please try again tomorrow.');

  r.get('/app/engagement-config', auth, readLimiter, wrap(async (req, res) => {
    const state = await st.get();
    const etag = `"eng-${state.version}"`;
    res.set('Cache-Control', 'private, max-age=300').set('ETag', etag);
    if (req.headers['if-none-match'] === etag) return res.status(304).end();
    res.json(appView(state));
  }));

  r.post('/me/feedback', auth, feedbackHourly, feedbackDaily, wrap(async (req, res) => {
    let input;
    try { input = validateFeedback(req.body); } catch (e) { return sendError(res, e); }
    const user = { userId: req.user.userId, name: req.dbUser?.name || req.user.name, email: req.dbUser?.email || req.user.email };
    const { doc, duplicate } = await addFeedback(soda, user, input);
    res.status(duplicate ? 200 : 201).json({ ok: true, feedbackId: doc.feedbackId, duplicate });
  }));

  // ---- admin ----
  const admin = [auth, requireAdmin];
  const adminName = (req) => req.user?.email || req.user?.userId || 'admin';

  r.get('/admin/engagement/config', ...admin, wrap(async (req, res) => {
    const state = await st.get({ fresh: true });
    res.set('Cache-Control', 'no-store').json({
      ok: true, version: state.version, config: state.config, updatedAt: state.updatedAt, updatedBy: state.updatedBy,
      defaults: DEFAULT_CONFIG, languages: LANGS, chipGroups: CHIP_GROUPS, textKeys: TEXT_KEYS, ranges: RANGES,
      history: state.history.map((h) => ({ version: h.version, at: h.at, by: h.by, note: h.note || '' })),
    });
  }));

  r.put('/admin/engagement/config', ...admin, wrap(async (req, res) => {
    const b = isObj(req.body) ? req.body : {};
    try {
      const state = await st.save(b.config, { baseVersion: b.baseVersion, by: adminName(req), note: b.note });
      await audit(repo, req, 'ENGAGEMENT_CONFIG_SAVED', `version ${state.version}`);
      res.json({ ok: true, version: state.version, config: state.config });
    } catch (e) { return sendError(res, e); }
  }));

  r.post('/admin/engagement/config/restore', ...admin, wrap(async (req, res) => {
    const b = isObj(req.body) ? req.body : {};
    try {
      const state = await st.restore(b.version, { by: adminName(req), baseVersion: b.baseVersion });
      await audit(repo, req, 'ENGAGEMENT_CONFIG_RESTORED', `version ${b.version} -> ${state.version}`);
      res.json({ ok: true, version: state.version, config: state.config });
    } catch (e) { return sendError(res, e); }
  }));

  r.get('/admin/engagement/feedback', ...admin, wrap(async (req, res) => {
    const status = ['OPEN', 'HANDLED'].includes(String(req.query.status || '').toUpperCase()) ? String(req.query.status).toUpperCase() : null;
    const items = await listFeedback(soda, { status, q: req.query.q, limit: req.query.limit });
    const all = status || req.query.q ? await listFeedback(soda, { limit: 1000 }) : items;
    res.set('Cache-Control', 'no-store').json({
      ok: true, items,
      counts: { total: all.length, open: all.filter((f) => f.status !== 'HANDLED').length, handled: all.filter((f) => f.status === 'HANDLED').length },
    });
  }));

  r.put('/admin/engagement/feedback/:feedbackId', ...admin, wrap(async (req, res) => {
    const b = isObj(req.body) ? req.body : {};
    if (typeof b.handled !== 'boolean') return res.status(400).json({ error: 'Send handled: true or false.', code: 'BAD_REQUEST' });
    const out = await setHandled(soda, req.params.feedbackId, { handled: b.handled, note: b.note, by: adminName(req) });
    if (!out) return res.status(404).json({ error: 'Feedback not found.', code: 'NOT_FOUND' });
    res.json({ ok: true, item: out });
  }));

  r.get('/admin/engagement/stats', ...admin, wrap(async (req, res) => {
    const days = Math.max(7, Math.min(365, Number.parseInt(req.query.days, 10) || 90));
    const [state, trips, places, feedback] = await Promise.all([
      st.get(),
      typeof repo.listTripFeedback === 'function' ? repo.listTripFeedback(1000).catch(() => []) : [],
      typeof repo.listPlaceReviews === 'function' ? repo.listPlaceReviews({ limit: 1000 }).catch(() => []) : [],
      listFeedback(soda, { limit: 1000 }),
    ]);
    res.set('Cache-Control', 'no-store').json({ ok: true, ...computeStats({ trips, places, feedback, config: state.config, days }) });
  }));

  return r;
}

async function audit(repo, req, action, detail) {
  if (!repo || typeof repo.addAuditEntry !== 'function') return;
  try {
    await repo.addAuditEntry({ at: Date.now(), by: req.user?.email || req.user?.userId || 'admin', byUserId: req.user?.userId || null, action, detail: String(detail).slice(0, 200) });
  } catch { /* the audit trail never blocks a save */ }
}

/**
 * Wiring, once in app.js: the router under /api, the feedback collection, and account erase (a
 * rider's feedback goes with the account).
 */
function attachEngagement({ app, repo, gate, logger = console }) {
  const store = new EngagementStore({ repo });
  Promise.resolve(repo.soda && typeof repo.soda.ensureCollection === 'function' ? repo.soda.ensureCollection(FEEDBACK_COLL) : null)
    .catch((e) => logger.warn?.(`[engagement] collection not ready: ${e.message}`));
  if (typeof repo.deleteUserCascade === 'function') {
    const cascade = repo.deleteUserCascade.bind(repo);
    repo.deleteUserCascade = async (user, opts) => {
      const out = await cascade(user, opts);
      if (user && user.userId) await repo.soda.removeWhere(FEEDBACK_COLL, { userId: String(user.userId) }).catch(() => {});
      return out;
    };
  }
  app.use('/api', engagementRouter({ repo, gate, store }));
  return { store };
}

module.exports = {
  DEFAULT_CONFIG, LANGS, CHIP_GROUPS, TEXT_KEYS, RANGES, FEEDBACK_TOPICS, FEEDBACK_COLL, NOTE_MAX, MAX_CHIPS,
  EngagementError, EngagementStore, policyProblem, validateConfig, cleanChipIds, validateFeedback,
  addFeedback, listFeedback, setHandled, computeStats, chipGroupOf, engagementRouter, attachEngagement,
};
