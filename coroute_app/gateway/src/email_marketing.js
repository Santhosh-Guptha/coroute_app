'use strict';
/**
 * 3.57 e-mail marketing studio: customised marketing e-mails with coupons, built from templates in the web
 * admin (Notifications > E-mail studio). Docs: docs/features_355/email_marketing.md.
 *
 * It extends the 3.56 Offers e-mail (offer_emails.js): the same consent (the rider's "Offer e-mails"
 * switch, off by default), suppression list, signed unsubscribe link and one-click headers, and the same
 * leased, rate-limited sending pattern. E-mail only: nothing here reaches the Play app (no push, no
 * socket event, no in-app text), so the Play payments policy is not affected.
 *
 * Templates (collection email_studio_templates): a template is { name, category, design } where design =
 * { subject, preheader, blocks[] }. Eight built-in starters (read-only; "Use" copies one). Saving writes a
 * new version (the last 30 are kept, any can be restored by saving it again); duplicate, archive and
 * unarchive. Blocks: header_image, heading, text (**bold**, *italic*, [label](/path) links to this site
 * only), coupon (an active coupon: code, discount, validity, button to /plans?coupon=CODE), price (a plan's
 * list price struck through and the offer price, read from the pricing config at send time), button
 * (internal pages only: BUTTON_PATHS), image, divider, footer (always last, always present: unsubscribe,
 * sender identity, postal address MAIL_POSTAL_ADDRESS). Variables {firstName} ... {link} (VARIABLES): an
 * unknown one is refused; a missing value gets a safe fallback.
 *
 * Categories (enforced by the server, never by the page):
 *   marketing  (default) only riders with the Offers consent, never a suppressed address, the Offers
 *              unsubscribe link and List-Unsubscribe headers, counted in the frequency cap.
 *   account    "Plan ending soon" style notices about the rider's own plan: allowed only with no coupon,
 *              no price block and no coupon / price variables, and only to the plan segments
 *              (plan_ends_within / plan_expired_within). Hard-suppressed addresses (bounce, complaint,
 *              admin) are skipped. A template with a coupon or a price is always marketing.
 *
 * Audiences (SEGMENTS): all opted-in, joined in the last N days, no ride for N days, never hosted a group
 * ride, plan ends within N days, plan ended in the last N days, crew admins, operators / club owners,
 * usernames, plus the 3.56 "active in N days" and "plan type". City is not stored for riders, so there is
 * no city segment. "Send test to me" goes to the admin's own address only.
 *
 * Sending: a campaign (email_studio_campaigns) is SCHEDULED for a time (India time in the page), claimed by
 * the leased job 'email-studio' (one node, compare-and-replace lease), and sent in batches at
 * OFFER_EMAIL_RATE per second. Per recipient, at send time: consent, suppression and the frequency cap
 * (settings.maxPerWeek marketing e-mails per rider per 7 days, default 2) are checked again; a mail_log
 * row with the unique key mkt:<campaignId>:<userId> is inserted BEFORE the e-mail is sent (never twice,
 * on any node). Quiet hours (settings, India time, default 21:00 to 09:00): nothing is sent; a campaign due
 * then waits for the morning. A permanent SMTP refusal (5xx) puts the address on the suppression list
 * (reason bounce). Automation rules (email_studio_rules): a segment + a template, e.g. "no ride for 30 days
 * -> win-back, once per rider per 90 days" or "plan ends in 3 days -> reminder, once per plan period",
 * checked by the same job (key auto:<ruleId>:<userId>:<occurrence>).
 *
 * Unique coupon codes (optional per campaign / rule): a single-use child code per recipient from an active
 * public parent coupon (<PREFIX>-<8 random>, 1 use in total, 1 per rider, only that rider, expiry = the
 * sooner of the parent's end and N days). email_coupon_codes holds a unique claim per code and per
 * (campaign, rider), so a retry reuses the same code and two nodes never issue two. The child is an
 * ordinary coupon (parentCode, emailCampaignId), so /plans redeems it with the usual atomic reservation.
 *
 * Reporting: queued, sent, failed, skipped, unsubscribed (the unsubscribe link carries cid=), coupon
 * redemptions (redemptions of the campaign's codes by its recipients after it started), and clicks through
 * signed redirect links /r/<token> (HMAC; the target is an internal path inside the signed token, so it is
 * never an open redirect). No open pixels. Clicks are stored with a pseudonymous rider hash, removed with
 * the account; tracking can be switched off (settings.clickTracking; then links are direct).
 */
const crypto = require('crypto');
const express = require('express');
const rateLimit = require('express-rate-limit');
const { validEmail } = require('./mailer');
const { cleanCouponCode } = require('./web_shop');
const { effectivePrice } = require('./plan_pricing');
const { EMAIL_BRAND, brandHeaderRow } = require('./email_brand');

const C = Object.freeze({
  templates: 'email_studio_templates', campaigns: 'email_studio_campaigns', rules: 'email_studio_rules', settings: 'email_studio_settings',
  codes: 'email_coupon_codes', events: 'email_events', previews: 'email_previews',
});
const LOG = 'mail_log';
const DAY = 86400000;
const IST = 330 * 60000;
const TEMPLATE_ID = /^et_[a-f0-9]{16}$/;
const CAMPAIGN_ID = /^ec_[a-f0-9]{20}$/;
const RULE_ID = /^ea_[a-f0-9]{16}$/;
const IMAGE_ID = /^pi_[a-f0-9]{24}$/;
const MAX_VERSIONS = 30;
const MAX_BLOCKS = 30;
const PAID_PLANS = Object.freeze(['group_small', 'group_large']);
const POSTAL_PLACEHOLDER = '[OWNER TO FILL in config: MAIL_POSTAL_ADDRESS]';
const HARD_SUPPRESSION = Object.freeze(['bounce', 'complaint', 'admin']);
/** Footer line of an account notice written to named riders (3.57 round 3: wizard "several riders" / rider page). */
const SERVICE_WHY = 'You get this e-mail because the CoRoute team wrote to you about your account.';

/** Personalisation variables: name -> { label, fallback }. Anything else in { } is refused. */
const VARIABLES = Object.freeze({
  firstName: { label: 'First name', fallback: 'there', sample: 'Asha' },
  username: { label: 'Username (without @)', fallback: 'rider', sample: 'SwiftFalcon482' },
  planName: { label: 'Plan name', fallback: 'your plan', sample: 'Small Group' },
  planEndsOn: { label: 'Plan end date', fallback: 'soon', sample: '14 Nov 2026' },
  couponCode: { label: 'Coupon code (needs a coupon block)', fallback: '', sample: 'DIWALI40', needs: 'coupon' },
  discount: { label: 'Discount, e.g. "40% off" (needs a coupon block)', fallback: 'a discount', sample: '40% off', needs: 'coupon' },
  validUntil: { label: 'Coupon valid until (needs a coupon block)', fallback: 'soon', sample: '30 Nov 2026', needs: 'coupon' },
  listPrice: { label: 'Plan list price (needs a price block)', fallback: 'the list price', sample: '₹99', needs: 'price' },
  offerPrice: { label: 'Plan offer price (needs a price block)', fallback: 'the offer price', sample: '₹49', needs: 'price' },
  link: { label: 'Main link (coupon link, else the first button, else /plans)', fallback: '', sample: 'https://coroute.example/plans' },
});
const VAR_RE = /\{([^{}\n]{0,40})\}/g;

/** Pages a button may open (and their sub-paths / query strings). */
const BUTTON_PATHS = Object.freeze(['/plans', '/updates', '/guide', '/operators/apply', '/account']);
/** Rich-text links: any page of this site except the API, the admin and the e-mail endpoints. */
const SITE_PATH = /^\/(?!\/)(?!api(?:[/?#]|$))(?!admin(?:[/?#]|$))(?!r\/)(?!email\/)[A-Za-z0-9\-._~/]*(?:\?[A-Za-z0-9\-._~=&%+]*)?(?:#[A-Za-z0-9\-_]*)?$/;

const BLOCK_TYPES = Object.freeze(['header_image', 'heading', 'text', 'coupon', 'price', 'button', 'image', 'divider', 'footer']);
const BLOCK_LABELS = Object.freeze({ header_image: 'Header image', heading: 'Heading', text: 'Rich text', coupon: 'Coupon', price: 'Price', button: 'Button', image: 'Image', divider: 'Divider', footer: 'Footer' });

const SEGMENTS = Object.freeze({
  all: { label: 'Every rider who opted in' },
  joined_within: { label: 'Joined in the last N days', days: true },
  inactive: { label: 'No ride for N days', days: true },
  never_hosted: { label: 'Never hosted a group ride' },
  plan_ends_within: { label: 'Website plan ends within N days', days: true, account: true },
  plan_expired_within: { label: 'Website plan ended in the last N days', days: true, account: true },
  crew_admins: { label: 'Crew admins' },
  operators: { label: 'Operators and club owners' },
  usernames: { label: 'Usernames', account: true },
  active: { label: 'Active in the last N days', days: true },
  plan: { label: 'By plan type' },
});
const RULE_TRIGGERS = Object.freeze({
  inactive: { label: 'No ride for N days', segment: 'inactive', defaultDays: 30, cooldown: 90 },
  plan_ending: { label: 'Plan ends in N days', segment: 'plan_ends_within', defaultDays: 3, cooldown: 0 },
  plan_expired: { label: 'Plan ended N days ago (or less)', segment: 'plan_expired_within', defaultDays: 7, cooldown: 0 },
  joined: { label: 'Joined in the last N days', segment: 'joined_within', defaultDays: 7, cooldown: 365 },
});
const DEFAULT_SETTINGS = Object.freeze({ maxPerWeek: 2, quietStartHour: 21, quietEndHour: 9, clickTracking: true });

class StudioError extends Error {
  constructor(message, code = 'BAD_EMAIL', status = 400, extra = {}) { super(message); this.code = code; this.status = status; Object.assign(this, extra); }
}

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const oneLine = (s) => String(s == null ? '' : s).replace(/[\u0000-\u001f\u007f\u2028\u2029]+/g, ' ').replace(/\s{2,}/g, ' ').trim();
const multiLine = (s) => String(s == null ? '' : s).replace(/\r\n/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
const hex = (n) => crypto.randomBytes(n).toString('hex');
const firstNameOf = (n) => String(n || '').trim().split(/\s+/)[0].slice(0, 40);
const inr = (n) => `₹${Math.round(Number(n) || 0)}`;
const shortPlanName = (n) => String(n || '').replace(/\s*\([^)]*\)\s*$/, '');
const maskEmail = (e) => String(e || '').trim().replace(/^(.).*?(@.*)$/, '$1***$2');
const emailHash = (e) => crypto.createHash('sha256').update(String(e || '').trim().toLowerCase()).digest('hex');
function istDate(ms) {
  const t = Number(ms);
  if (!Number.isFinite(t) || t <= 0) return '';
  return new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }).format(new Date(t));
}
const istHour = (ms) => new Date(ms + IST).getUTCHours();
const istDay = (ms) => new Date(ms + IST).toISOString().slice(0, 10);

/** Text of a coupon's discount: "40% off", "₹50 off", "a free plan period", "pay only ₹29". */
function discountText(c) {
  if (!c) return '';
  const v = Number(c.discountValue) || 0;
  if (c.discountType === 'percentage') return `${Math.round(v)}% off${Number(c.maxDiscountCap) > 0 ? ` (up to ${inr(c.maxDiscountCap)})` : ''}`;
  if (c.discountType === 'fixed') return `${inr(v)} off`;
  if (c.discountType === 'free') return 'a free plan period';
  if (c.discountType === 'price') return `pay only ${inr(v)}`;
  return 'a discount';
}

// =================================================================== starters
const B = (type, fields = {}) => ({ type, ...fields });
const FOOTER = B('footer', { note: '' });
const STARTERS = Object.freeze([
  { id: 'festive_coupon', name: 'Festive offer with coupon', category: 'marketing', description: 'A festive greeting with a coupon block.',
    design: { subject: '{firstName}, a festive ride offer for your crew', preheader: 'Use {couponCode} for {discount} on group plans until {validUntil}.',
      blocks: [B('header_image', { imageId: '', alt: 'Riders on a festive evening ride' }), B('heading', { text: 'Ride together this festive season', level: 1 }),
        B('text', { text: 'Hi {firstName},\n\nThe roads are bright and the crew is ready. Host your festive group ride with live group map, group talk and SOS for everyone.\n\n**{discount}** on a group plan with the code below, until {validUntil}.' }),
        B('coupon', { code: '', headline: 'Festive offer', note: 'One use per rider. On the website only.', buttonLabel: 'Use {couponCode}' }), B('divider'),
        B('text', { text: '*Every safety feature stays free for every rider.*' }), FOOTER] } },
  { id: 'launch_offer', name: 'Launch / limited-time offer', category: 'marketing', description: 'List price struck through and the offer price, from the pricing config at send time.',
    design: { subject: 'Large Group at {offerPrice} for a limited time', preheader: 'Was {listPrice}. The offer ends soon.',
      blocks: [B('heading', { text: 'A launch offer for bigger crews', level: 1 }),
        B('text', { text: 'Hi {firstName}, plan your next weekend ride with up to 12 riders.\n\n- Live group map and regroup\n- Group talk (push-to-talk)\n- Missing-rider checks and SOS' }),
        B('price', { planId: 'group_large', buttonLabel: 'See the offer' }), B('text', { text: 'The price is the one on the website when you open it.' }), FOOTER] } },
  { id: 'feature_news', name: 'New feature announcement', category: 'marketing', description: 'A new feature with a picture and a link to the updates page.',
    design: { subject: 'New in CoRoute: crew polls', preheader: 'Ask your crew where to ride next, right in the app.',
      blocks: [B('image', { imageId: '', alt: 'Crew polls in the app', path: '/updates' }), B('heading', { text: 'Crew polls are here', level: 1 }),
        B('text', { text: 'Hi {firstName},\n\nAsk your crew where to ride next and when. Everyone votes in the app, and the ride starts from the winning plan.' }),
        B('button', { label: 'Read what is new', path: '/updates', style: 'primary' }), FOOTER] } },
  { id: 'ride_season', name: 'Ride season: weekend ride ideas', category: 'marketing', description: 'Weekend ride ideas and the quick start guide.',
    design: { subject: 'Weekend ride ideas for {firstName}', preheader: 'Three easy ways to make this weekend a group ride.',
      blocks: [B('header_image', { imageId: '', alt: 'A winding road at sunrise' }), B('heading', { text: 'Riding season is here', level: 1 }),
        B('text', { text: '- **Sunrise loop:** start early, regroup at the first tea stop.\n- **Coffee run:** a short ride for new riders in the crew.\n- **Hill climb:** set a lead and a sweep before you go.' }),
        B('button', { label: 'Open the quick start guide', path: '/guide', style: 'primary' }), FOOTER] } },
  { id: 'winback_coupon', name: 'Win-back: we miss you (coupon)', category: 'marketing', description: 'For riders without a ride for a while, with a coupon.',
    design: { subject: 'We miss you on the road, {firstName}', preheader: 'Come back with {discount} on a group plan.',
      blocks: [B('heading', { text: 'We miss you, {firstName}', level: 1 }),
        B('text', { text: 'It has been a while since your last ride with CoRoute. Your crew, your bikes and your safety settings are all still there.\n\nHere is **{discount}** to host your next group ride.' }),
        B('coupon', { code: '', headline: 'Welcome back', note: 'Valid until {validUntil}.', buttonLabel: 'Use {couponCode}' }), FOOTER] } },
  { id: 'plan_ending', name: 'Plan ending soon', category: 'account', description: 'An account notice for riders whose website plan ends in N days. No coupon or price (else it is marketing).',
    design: { subject: 'Your {planName} plan ends on {planEndsOn}', preheader: 'Nothing is lost when it ends: rides, crews and safety stay.',
      blocks: [B('heading', { text: 'Your plan ends on {planEndsOn}', level: 1 }),
        B('text', { text: 'Hi {firstName}, your **{planName}** plan on the CoRoute website ends on {planEndsOn}.\n\nAfter that you keep every safety feature and can still join group rides. Hosting group rides needs a group plan again.' }),
        B('button', { label: 'See your account', path: '/account', style: 'primary' }), FOOTER] } },
  { id: 'club_invite', name: 'Club / operator invitation', category: 'marketing', description: 'Invite riding clubs and tour operators to the operator console.',
    design: { subject: 'Run a riding club? Bring it to CoRoute', preheader: 'Rides, sign-ups and broadcasts for your members in one place.',
      blocks: [B('heading', { text: 'CoRoute for clubs and tour operators', level: 1 }),
        B('text', { text: 'Hi {firstName},\n\nIf you run rides for a club or a tour group, the operator console gives you ride pages, sign-ups, a members crew and broadcasts.' }),
        B('button', { label: 'Apply as an operator', path: '/operators/apply', style: 'primary' }), FOOTER] } },
  { id: 'safety_tips', name: 'Safety tips newsletter', category: 'marketing', description: 'A short newsletter of riding safety tips.',
    design: { subject: 'Three safety checks before your next ride', preheader: 'Two minutes that matter on every ride.',
      blocks: [B('heading', { text: 'Ride safe, {firstName}', level: 1 }),
        B('text', { text: '- **Emergency contact:** check it is current (Profile > Emergency contact).\n- **Crash detection:** keep the app allowed to run in the background.\n- **Regroup point:** agree on one before the ride.' }),
        B('divider'), B('text', { text: 'More in the [quick start guide](/guide).' }), B('button', { label: 'Read the guide', path: '/guide', style: 'secondary' }), FOOTER] } },
]);
const starterById = (id) => STARTERS.find((s) => s.id === id) || null;

// =================================================================== validation (pure)
function varsIn(text) { return [...String(text || '').matchAll(VAR_RE)].map((m) => m[1]); }

/** Text fields of a block that may hold variables. */
function textFieldsOf(b) {
  switch (b.type) {
    case 'heading': return ['text'];
    case 'text': return ['text'];
    case 'coupon': return ['headline', 'note', 'buttonLabel'];
    case 'price': return ['buttonLabel', 'note'];
    case 'button': return ['label'];
    case 'header_image': case 'image': return ['alt'];
    case 'footer': return ['note'];
    default: return [];
  }
}

/** A button target: one of BUTTON_PATHS (optionally a sub-path or a query), or ''. */
function cleanButtonPath(p) {
  const s = String(p || '').trim();
  if (!SITE_PATH.test(s)) return '';
  const base = s.split(/[?#]/)[0].replace(/\/+$/, '') || '/';
  return BUTTON_PATHS.some((x) => base === x || base.startsWith(`${x}/`)) ? s : '';
}
/** A rich-text link: a path of this site (or <origin>/path) -> the path, else ''. */
function cleanSitePath(href, origin) {
  let h = String(href || '').trim();
  const o = String(origin || '').replace(/\/+$/, '');
  if (o && h.startsWith(`${o}/`)) h = h.slice(o.length);
  return SITE_PATH.test(h) ? h : '';
}

/**
 * Checks and cleans a design. mode 'template' allows an empty coupon code / image (filled in when
 * composing); mode 'send' needs them. Returns { design, errors, warnings, category, uses }.
 */
function validateDesign(input, { category = 'marketing', mode = 'template', origin = '' } = {}) {
  const errors = []; const warnings = [];
  const d = input && typeof input === 'object' ? input : {};
  const subject = oneLine(d.subject);
  const preheader = oneLine(d.preheader);
  if (!subject) errors.push('Write a subject.');
  if (subject.length > 150) errors.push('The subject is longer than 150 characters.');
  if (preheader.length > 200) errors.push('The preheader is longer than 200 characters.');
  const raw = Array.isArray(d.blocks) ? d.blocks : [];
  if (raw.length > MAX_BLOCKS + 1) errors.push(`At most ${MAX_BLOCKS} blocks.`);
  const blocks = [];
  let footer = null;
  for (let i = 0; i < Math.min(raw.length, MAX_BLOCKS + 1); i++) {
    const r = raw[i] && typeof raw[i] === 'object' ? raw[i] : {};
    const type = String(r.type || '');
    const n = `Block ${i + 1} (${BLOCK_LABELS[type] || type || '?'})`;
    if (!BLOCK_TYPES.includes(type)) { errors.push(`${n}: unknown block type.`); continue; }
    const b = { type };
    if (type === 'heading') {
      b.text = oneLine(r.text); b.level = Number(r.level) === 2 ? 2 : 1;
      if (!b.text) errors.push(`${n}: write the heading.`);
      if (b.text.length > 150) errors.push(`${n}: longer than 150 characters.`);
    } else if (type === 'text') {
      b.text = multiLine(r.text);
      if (!b.text) errors.push(`${n}: write the text.`);
      if (b.text.length > 3000) errors.push(`${n}: longer than 3000 characters.`);
      for (const m of b.text.matchAll(/\[([^\]]{1,80})\]\(([^)\s]{1,300})\)/g)) {
        if (!cleanSitePath(m[2], origin)) errors.push(`${n}: links may only point to pages of this site: ${m[2].slice(0, 60)}`);
      }
      if (/<\s*[a-z!/]/i.test(b.text)) errors.push(`${n}: HTML is not allowed; use **bold**, *italic* and [label](/path).`);
    } else if (type === 'header_image' || type === 'image') {
      b.imageId = r.imageId ? String(r.imageId) : '';
      b.alt = oneLine(r.alt).slice(0, 120);
      if (b.imageId && !IMAGE_ID.test(b.imageId)) errors.push(`${n}: unknown image.`);
      if (!b.imageId && mode === 'send') errors.push(`${n}: choose an image (or delete the block).`);
      if (type === 'image' && r.path) {
        b.path = cleanSitePath(r.path, origin);
        if (!b.path) errors.push(`${n}: the image link may only point to a page of this site.`);
      }
    } else if (type === 'coupon') {
      b.code = r.code ? cleanCouponCode(r.code) : '';
      if (r.code && !b.code) errors.push(`${n}: a coupon code has only letters, digits, - and _ (at most 24).`);
      if (!b.code && mode === 'send') errors.push(`${n}: choose a coupon.`);
      b.headline = oneLine(r.headline).slice(0, 80);
      b.note = oneLine(r.note).slice(0, 160);
      b.buttonLabel = oneLine(r.buttonLabel).slice(0, 40);
    } else if (type === 'price') {
      b.planId = String(r.planId || '');
      if (!PAID_PLANS.includes(b.planId)) errors.push(`${n}: choose a group plan.`);
      b.buttonLabel = oneLine(r.buttonLabel).slice(0, 40);
      b.note = oneLine(r.note).slice(0, 160);
    } else if (type === 'button') {
      b.label = oneLine(r.label).slice(0, 40);
      b.path = cleanButtonPath(r.path);
      b.style = r.style === 'secondary' ? 'secondary' : 'primary';
      if (!b.label) errors.push(`${n}: write the button text.`);
      if (!b.path) errors.push(`${n}: a button may only open ${BUTTON_PATHS.join(', ')}.`);
    } else if (type === 'footer') {
      b.note = multiLine(r.note).slice(0, 500);
      if (footer) { errors.push('Only one footer.'); continue; }
      footer = b;
      continue;
    }
    blocks.push(b);
  }
  if (footer && raw.findIndex((x) => x && x.type === 'footer') !== raw.length - 1) warnings.push('The footer is always the last block.');
  blocks.push(footer || { type: 'footer', note: '' });
  if (blocks.filter((b) => b.type === 'coupon').length > 1) errors.push('At most one coupon block.');
  if (blocks.length <= 1) errors.push('Add at least one block.');

  // Variables.
  const used = new Set();
  const check = (text, where) => {
    for (const v of varsIn(text)) {
      if (!Object.prototype.hasOwnProperty.call(VARIABLES, v)) errors.push(`${where} uses an unknown variable {${v}}. Allowed: ${Object.keys(VARIABLES).map((k) => `{${k}}`).join(', ')}.`);
      else used.add(v);
    }
  };
  check(subject, 'The subject'); check(preheader, 'The preheader');
  blocks.forEach((b, i) => textFieldsOf(b).forEach((f) => check(b[f], `Block ${i + 1} (${BLOCK_LABELS[b.type]})`)));
  const hasCoupon = blocks.some((b) => b.type === 'coupon');
  const hasPrice = blocks.some((b) => b.type === 'price');
  for (const v of used) {
    if (VARIABLES[v].needs === 'coupon' && !hasCoupon) errors.push(`{${v}} needs a coupon block.`);
    if (VARIABLES[v].needs === 'price' && !hasPrice) errors.push(`{${v}} needs a price block.`);
  }
  const promo = hasCoupon || hasPrice || [...used].some((v) => VARIABLES[v].needs);
  const cat = category === 'account' ? 'account' : 'marketing';
  if (cat === 'account' && promo) errors.push('An account e-mail cannot carry a coupon, a price or coupon / price variables. Make it a marketing e-mail (sent only to riders who opted in to offers).');
  return { design: { subject, preheader, blocks }, errors, warnings, category: cat, uses: { variables: [...used], coupon: hasCoupon, price: hasPrice } };
}

// =================================================================== rendering (pure)
const COLORS = { brand: EMAIL_BRAND.teal, ink: '#111827', body: '#374151', muted: '#6b7280', bg: '#f4f5f7', card: '#ffffff', rule: '#e5e7eb', couponBg: EMAIL_BRAND.tealTint };
const DARK_RULES = '.cr-body{background:#0f1115!important}.cr-card{background:#1a1d24!important}.cr-ink{color:#f3f4f6!important}.cr-text{color:#d1d5db!important}'
  + '.cr-muted{color:#a7adbb!important}.cr-rule{border-color:#2f3440!important}.cr-coupon{background:#221f38!important;border-color:#9d93ff!important}'
  + '.cr-code{color:#8FCBD7!important}.cr-link{color:#8FCBD7!important}.cr-strike{color:#8b93a3!important}.cr-brand{color:#8FCBD7!important}';

/** Inline markup of a line (already escaped) -> HTML; links via `link(path)`. */
function inlineHtml(raw, origin, link) {
  let s = esc(raw);
  s = s.replace(/\*\*([^*]{1,300})\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*\w])\*([^*\n]{1,300})\*(?!\*)/g, '$1<em>$2</em>');
  s = s.replace(/(^|[^\w])_([^_\n]{1,300})_(?!\w)/g, '$1<em>$2</em>');
  s = s.replace(/\[([^\]]{1,80})\]\(([^)\s]{1,300})\)/g, (m, label, href) => {
    const p = cleanSitePath(href.replace(/&amp;/g, '&'), origin);
    if (!p) return label;
    return `<a class="cr-link" href="${esc(link(p))}" style="color:${COLORS.brand};text-decoration:underline;">${label}</a>`;
  });
  return s;
}
function inlineText(raw, origin) {
  return String(raw).replace(/\*\*([^*]{1,300})\*\*/g, '$1').replace(/(^|[^*\w])\*([^*\n]{1,300})\*(?!\*)/g, '$1$2').replace(/(^|[^\w])_([^_\n]{1,300})_(?!\w)/g, '$1$2')
    .replace(/\[([^\]]{1,80})\]\(([^)\s]{1,300})\)/g, (m, l, h) => { const p = cleanSitePath(h, origin); return p ? `${l} (${origin}${p})` : l; });
}
/** Replaces {var} with values (escaped for HTML when `html`). Unknown names never get here (validated). */
function fillVars(s, vars, html) {
  return String(s).replace(VAR_RE, (m, k) => (Object.prototype.hasOwnProperty.call(vars, k) ? (html ? esc(vars[k]) : String(vars[k])) : m));
}
function richText(text, origin, link, vars) {
  const blocks = String(text || '').split(/\n{2,}/).map((x) => x.trim()).filter(Boolean);
  const html = []; const out = [];
  for (const b of blocks) {
    const lines = b.split('\n');
    if (lines.every((l) => /^\s*-\s+/.test(l))) {
      html.push(`<ul style="margin:0 0 14px 18px;padding:0;">${lines.map((l) => `<li style="margin:0 0 6px;">${fillVars(inlineHtml(l.replace(/^\s*-\s+/, ''), origin, link), vars, true)}</li>`).join('')}</ul>`);
      out.push(lines.map((l) => `* ${fillVars(inlineText(l.replace(/^\s*-\s+/, ''), origin), vars, false)}`).join('\n'));
    } else {
      html.push(`<p style="margin:0 0 14px;">${lines.map((l) => fillVars(inlineHtml(l, origin, link), vars, true)).join('<br>')}</p>`);
      out.push(lines.map((l) => fillVars(inlineText(l, origin), vars, false)).join('\n'));
    }
  }
  return { html: html.join(''), text: out.join('\n\n') };
}

/**
 * The whole e-mail (pure). ctx: { origin, vars, coupon {code, discount, validUntil, url}, prices
 * {planId: {name, listPriceInr, priceInr, offer}}, images {imageId: url}, link(path) -> url, category,
 * unsubscribeUrl, accountUrl, postalAddress, supportEmail, forceDark, sample }.
 */
function renderDesign(design, ctx) {
  const o = String(ctx.origin || '').replace(/\/+$/, '');
  const vars = ctx.vars || {};
  const link = ctx.link || ((p) => `${o}${p}`);
  const v = (s) => fillVars(s, vars, false);
  const vh = (s) => fillVars(esc(s), vars, true);
  const rows = []; const text = [];
  const links = [];
  const track = (p) => { links.push(p); return link(p); };
  const btn = (url, label, secondary) => `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:4px 0 16px;"><tr><td style="border-radius:8px;background:${secondary ? 'transparent' : COLORS.brand};${secondary ? `border:2px solid ${COLORS.brand};` : ''}">`
    + `<a href="${esc(url)}" class="${secondary ? 'cr-link' : ''}" style="display:inline-block;padding:11px 20px;font-size:15px;font-weight:600;text-decoration:none;color:${secondary ? COLORS.brand : '#ffffff'};border-radius:8px;">${label}</a></td></tr></table>`;
  for (const b of design.blocks) {
    if (b.type === 'header_image' || b.type === 'image') {
      const url = ctx.images && ctx.images[b.imageId];
      if (!url) continue;
      const img = `<img src="${esc(url)}" alt="${vh(b.alt)}" width="544" style="display:block;width:100%;max-width:544px;height:auto;border:0;border-radius:${b.type === 'header_image' ? '10px' : '8px'};">`;
      rows.push(`<tr><td style="padding:0 0 18px;">${b.type === 'image' && b.path ? `<a href="${esc(track(b.path))}">${img}</a>` : img}</td></tr>`);
      if (b.alt) text.push(`[${v(b.alt)}]`);
    } else if (b.type === 'heading') {
      const size = b.level === 2 ? 18 : 24;
      rows.push(`<tr><td class="cr-ink" style="font-size:${size}px;line-height:1.3;font-weight:700;color:${COLORS.ink};padding:0 0 12px;">${vh(b.text)}</td></tr>`);
      text.push(v(b.text).toUpperCase() === v(b.text) ? v(b.text) : `${v(b.text)}\n${'-'.repeat(Math.min(60, v(b.text).length))}`);
    } else if (b.type === 'text') {
      const r = richText(b.text, o, track, vars);
      rows.push(`<tr><td class="cr-text" style="font-size:15px;line-height:1.6;color:${COLORS.body};">${r.html}</td></tr>`);
      text.push(r.text);
    } else if (b.type === 'coupon') {
      const c = ctx.coupon;
      if (!c || !c.code) {
        rows.push(`<tr><td class="cr-muted" style="padding:6px 0 16px;font-size:13px;color:${COLORS.muted};">[Coupon block: choose a coupon]</td></tr>`);
        continue;
      }
      const label = b.buttonLabel ? v(b.buttonLabel) : `Use ${c.code}`;
      rows.push(`<tr><td style="padding:4px 0 18px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="cr-coupon" style="background:${COLORS.couponBg};border:2px dashed ${COLORS.brand};border-radius:12px;">`
        + '<tr><td style="padding:18px 16px;text-align:center;">'
        + (b.headline ? `<div class="cr-ink" style="font-size:16px;font-weight:700;color:${COLORS.ink};padding-bottom:6px;">${vh(b.headline)}</div>` : '')
        + `<div class="cr-code" style="font-family:SFMono-Regular,Menlo,Consolas,monospace;font-size:26px;font-weight:700;letter-spacing:3px;color:${COLORS.brand};padding:4px 0;">${esc(c.code)}</div>`
        + `<div class="cr-text" style="font-size:14px;color:${COLORS.body};padding-top:4px;">${esc(c.discount)}${c.validUntil ? ` · valid until ${esc(c.validUntil)}` : ''}</div>`
        + (b.note ? `<div class="cr-muted" style="font-size:12px;color:${COLORS.muted};padding-top:6px;">${vh(b.note)}</div>` : '')
        + `<div style="padding-top:12px;">${btn(track(c.path), esc(label), false).replace('margin:4px 0 16px;', 'margin:0 auto;')}</div>`
        + '</td></tr></table></td></tr>');
      text.push([b.headline ? v(b.headline) : 'Your code', `Code: ${c.code} (${c.discount}${c.validUntil ? `, valid until ${c.validUntil}` : ''})`, ...(b.note ? [v(b.note)] : []), `${label}: ${o}${c.path}`].join('\n'));
    } else if (b.type === 'price') {
      const p = ctx.prices && ctx.prices[b.planId];
      if (!p) continue;
      const offer = p.offer && p.priceInr < p.listPriceInr;
      const label = b.buttonLabel ? v(b.buttonLabel) : 'See plans';
      rows.push(`<tr><td style="padding:4px 0 18px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="cr-rule" style="border:1px solid ${COLORS.rule};border-radius:12px;">`
        + '<tr><td style="padding:16px;">'
        + `<div class="cr-ink" style="font-size:16px;font-weight:700;color:${COLORS.ink};">${esc(p.name)}</div>`
        + `<div style="padding:6px 0 2px;">${offer ? `<span class="cr-strike" style="font-size:16px;color:${COLORS.muted};text-decoration:line-through;">${esc(inr(p.listPriceInr))}</span> ` : ''}`
        + `<span class="cr-brand" style="font-size:28px;font-weight:800;color:${COLORS.brand};">${esc(inr(p.priceInr))}</span><span class="cr-muted" style="font-size:13px;color:${COLORS.muted};"> / ${esc(String(p.days || 30))} days</span></div>`
        + (offer ? `<div class="cr-text" style="font-size:13px;color:${COLORS.body};">${esc(p.offer.label)}${p.offer.endAt ? ` · until ${esc(istDate(p.offer.endAt))}` : ''}</div>` : '')
        + (b.note ? `<div class="cr-muted" style="font-size:12px;color:${COLORS.muted};padding-top:6px;">${vh(b.note)}</div>` : '')
        + `<div style="padding-top:12px;">${btn(track('/plans'), esc(label), false).replace('margin:4px 0 16px;', 'margin:0;')}</div>`
        + '</td></tr></table></td></tr>');
      text.push(`${p.name}: ${offer ? `${inr(p.listPriceInr)} -> ${inr(p.priceInr)} (${p.offer.label}${p.offer.endAt ? `, until ${istDate(p.offer.endAt)}` : ''})` : inr(p.priceInr)} per ${p.days || 30} days${b.note ? `\n${v(b.note)}` : ''}\n${label}: ${o}/plans`);
    } else if (b.type === 'button') {
      rows.push(`<tr><td>${btn(track(b.path), vh(b.label), b.style === 'secondary')}</td></tr>`);
      text.push(`${v(b.label)}: ${o}${b.path}`);
    } else if (b.type === 'divider') {
      rows.push(`<tr><td style="padding:6px 0 18px;"><div class="cr-rule" style="border-top:1px solid ${COLORS.rule};height:1px;line-height:1px;font-size:1px;">&nbsp;</div></td></tr>`);
      text.push('----');
    }
  }
  // Footer: always last, always there.
  const foot = design.blocks.find((b) => b.type === 'footer') || { note: '' };
  const marketing = ctx.category !== 'account';
  // 3.57 round 3: a transactional 1:1 e-mail from the rider page leaves the address line out when it is not set
  // (never the placeholder in a real e-mail); marketing e-mails always need it (checked before sending).
  const address = ctx.postalAddress || (ctx.omitMissingAddress ? '' : POSTAL_PLACEHOLDER);
  const why = ctx.why ? String(ctx.why) : marketing ? 'You get this e-mail because you turned on offer e-mails in your CoRoute account.' : 'You get this e-mail about your CoRoute plan on the website.';
  const footHtml = (foot.note ? `${vh(foot.note).replace(/\n/g, '<br>')}<br><br>` : '')
    + `${esc(why)} ` + (marketing ? `<a class="cr-muted" href="${esc(ctx.unsubscribeUrl)}" style="color:${COLORS.muted};text-decoration:underline;">Unsubscribe</a> · ` : '')
    + `<a class="cr-muted" href="${esc(ctx.accountUrl)}" style="color:${COLORS.muted};text-decoration:underline;">Manage e-mails</a>`
    + `<br><br>Sent by CoRoute${address ? ` · ${esc(address)}` : ''}${ctx.supportEmail ? ` · ${esc(ctx.supportEmail)}` : ''}`;
  rows.push(`<tr><td class="cr-muted cr-rule" style="font-size:12px;line-height:1.6;color:${COLORS.muted};padding-top:16px;border-top:1px solid ${COLORS.rule};">${footHtml}</td></tr>`);
  text.push([...(foot.note ? [v(foot.note), ''] : []), why, ...(marketing ? [`Unsubscribe: ${ctx.unsubscribeUrl}`] : []), `Manage e-mails: ${ctx.accountUrl}`, '', `Sent by CoRoute${address ? ` · ${address}` : ''}${ctx.supportEmail ? ` · ${ctx.supportEmail}` : ''}`].join('\n'));

  const subject = v(design.subject);
  const preheader = v(design.preheader || '');
  const darkCss = ctx.forceDark ? DARK_RULES : `@media (prefers-color-scheme: dark){${DARK_RULES}}`;
  const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">'
    + `<title>${esc(subject)}</title><style>:root{color-scheme:light dark;supported-color-schemes:light dark;}${darkCss}@media (max-width:600px){.cr-pad{padding:20px 16px!important}}</style></head>`
    + `<body class="cr-body" style="margin:0;padding:0;background:${COLORS.bg};font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">`
    + (preheader ? `<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;mso-hide:all;">${esc(preheader)}${'&#847;&zwnj;&nbsp;'.repeat(30)}</div>` : '')
    + `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="cr-body" style="background:${COLORS.bg};padding:24px 12px;"><tr><td align="center">`
    + `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="cr-card cr-pad" style="max-width:600px;background:${COLORS.card};border-radius:14px;padding:28px 28px 20px;">`
    + brandHeaderRow(o, 'cr-brand')
    + rows.join('')
    + '</table></td></tr></table></body></html>';
  return { subject, preheader, html, text: `${text.join('\n\n')}\n\n-- CoRoute\n`, links };
}

// =================================================================== service
class EmailStudio {
  constructor({ soda, repo, mailer, offers, campaigns = null, accessMode = null, config = {}, secret = '', logger = console, clock = Date.now, sleep,
    ratePerSec, batchSize = 50, leaseMs = 2 * 60000, env = process.env, photoStore = null } = {}) {
    this.soda = soda; this.repo = repo; this.mailer = mailer; this.offers = offers; this.pushCampaigns = campaigns; this.accessMode = accessMode;
    this.config = config; this.logger = logger; this.clock = clock; this.env = env;
    this.secret = secret || 'email-studio-dev-secret';
    this.sleep = sleep || ((ms) => new Promise((r) => { const t = setTimeout(r, ms); t.unref?.(); }));
    this.ratePerSec = Math.max(1, Number(ratePerSec || env.OFFER_EMAIL_RATE) || 5);
    this.batchSize = Math.max(1, batchSize);
    this.leaseMs = leaseMs;
    this.photoStore = photoStore;
    this.worker = `${require('os').hostname()}:${process.pid}:${hex(3)}`;
    this.ready = null; this.running = false;
    if (offers) offers.onUnsubscribe = (userId, cid) => this.recordUnsubscribe(userId, cid);
  }

  origin() { return String(this.config.publicOrigin || this.config.linkOrigin || (this.offers && this.offers.origin) || '').replace(/\/+$/, ''); }
  get enabled() { return !!(this.mailer && this.mailer.enabled); }
  postalAddress() { return String(this.env.MAIL_POSTAL_ADDRESS || this.config.mailPostalAddress || '').replace(/\s+/g, ' ').trim().slice(0, 300); }

  async ensureStore() {
    if (!this.ready) {
      this.ready = (async () => {
        for (const c of [...Object.values(C), LOG]) await this.soda.ensureCollection(c);
        const idx = (c, name, fields, unique = false) => this.soda.ensureIndex(c, { name, unique, fields: fields.map((p) => (typeof p === 'string' ? { path: p } : p)) });
        await idx(C.templates, 'email_studio_templates_id_ux', ['templateId'], true);
        await idx(C.campaigns, 'email_studio_campaigns_id_ux', ['campaignId'], true);
        await idx(C.campaigns, 'email_studio_campaigns_status_ix', ['status']);
        await idx(C.rules, 'email_studio_rules_id_ux', ['ruleId'], true);
        await idx(C.settings, 'email_studio_settings_k_ux', ['k'], true);
        await idx(C.codes, 'email_coupon_codes_code_ux', ['code'], true);
        await idx(C.codes, 'email_coupon_codes_key_ux', ['key'], true);
        await idx(C.codes, 'email_coupon_codes_parent_ix', ['parentCode']);
        await idx(C.events, 'email_events_cid_ix', ['campaignId', 'type']);
        await idx(C.previews, 'email_previews_token_ux', ['token'], true);
        await idx(LOG, `${LOG}_key_ux`, ['key'], true);
        await idx(LOG, 'mail_log_marketing_ix', ['userId', 'kind', { path: 'sentAt', datatype: 'number' }]);
        await idx(LOG, 'mail_log_campaign_ix', ['campaignId', 'status']);
      })().catch((e) => { this.ready = null; throw e; });
    }
    return this.ready;
  }

  // ------------------------------------------------------------ settings
  async settings() {
    await this.ensureStore();
    const row = await this.soda.findOne(C.settings, { k: 'marketing' });
    const v = row ? row.value : {};
    return { ...DEFAULT_SETTINGS, ...Object.fromEntries(Object.keys(DEFAULT_SETTINGS).filter((k) => v[k] !== undefined).map((k) => [k, v[k]])), updatedAt: v.updatedAt || 0, updatedBy: v.updatedBy || null };
  }

  async setSettings(body, { by = 'admin' } = {}) {
    const b = body && typeof body === 'object' ? body : {};
    const cur = await this.settings();
    const next = { maxPerWeek: cur.maxPerWeek, quietStartHour: cur.quietStartHour, quietEndHour: cur.quietEndHour, clickTracking: cur.clickTracking };
    if (b.maxPerWeek !== undefined) {
      const n = Math.round(Number(b.maxPerWeek));
      if (!(n >= 1 && n <= 14)) throw new StudioError('Marketing e-mails per rider per week: 1 to 14.', 'BAD_SETTINGS');
      next.maxPerWeek = n;
    }
    for (const k of ['quietStartHour', 'quietEndHour']) {
      if (b[k] === undefined) continue;
      const n = Math.round(Number(b[k]));
      if (!(n >= 0 && n <= 23)) throw new StudioError('Quiet hours are whole hours from 0 to 23 (India time).', 'BAD_SETTINGS');
      next[k] = n;
    }
    if (b.clickTracking !== undefined) {
      if (typeof b.clickTracking !== 'boolean') throw new StudioError('clickTracking must be true or false.', 'BAD_SETTINGS');
      next.clickTracking = b.clickTracking;
    }
    await this.soda.upsertBy(C.settings, { k: 'marketing' }, { k: 'marketing', ...next, updatedAt: this.clock(), updatedBy: String(by).slice(0, 120) });
    return this.settings();
  }

  /** True while India time is inside the quiet hours (start == end: no quiet hours). */
  isQuiet(s, now = this.clock()) {
    const a = Number(s.quietStartHour); const b = Number(s.quietEndHour);
    if (a === b) return false;
    const h = istHour(now);
    return a < b ? (h >= a && h < b) : (h >= a || h < b);
  }

  // ------------------------------------------------------------ templates
  _tplPublic(doc, { withHistory = false } = {}) {
    if (!doc) return null;
    const { history, key, ...rest } = doc; // eslint-disable-line no-unused-vars
    const out = { ...rest, versions: Array.isArray(history) ? history.length : 0 };
    if (withHistory) out.history = (history || []).map((h) => ({ version: h.version, savedAt: h.savedAt, savedBy: h.savedBy, subject: h.design && h.design.subject })).reverse();
    return out;
  }

  async listTemplates({ archived = false } = {}) {
    await this.ensureStore();
    const rows = await this.soda.query(C.templates, {}, { limit: 500, orderBy: [{ path: 'updatedAt', datatype: 'number', order: 'desc' }] });
    const saved = rows.map((r) => this._tplPublic(r.value)).filter((t) => archived || t.status !== 'archived');
    return { starters: STARTERS.map((s) => ({ ...s, starter: true })), templates: saved };
  }

  async getTemplate(id, { withHistory = true } = {}) {
    if (!TEMPLATE_ID.test(String(id))) {
      const s = starterById(String(id));
      if (s) return { ...s, templateId: s.id, starter: true, version: 0 };
      return null;
    }
    await this.ensureStore();
    const row = await this.soda.findOne(C.templates, { templateId: id });
    return row ? this._tplPublic(row.value, { withHistory }) : null;
  }

  async templateVersion(id, version) {
    if (!TEMPLATE_ID.test(String(id))) return null;
    await this.ensureStore();
    const row = await this.soda.findOne(C.templates, { templateId: id });
    const h = row && (row.value.history || []).find((x) => x.version === Number(version));
    return h ? { templateId: id, version: h.version, design: h.design, category: h.category || row.value.category, savedAt: h.savedAt, savedBy: h.savedBy } : null;
  }

  _cleanTemplateInput(b) {
    const name = oneLine(b.name).slice(0, 80);
    if (!name) throw new StudioError('Name the template.', 'NAME_REQUIRED');
    const category = b.category === 'account' ? 'account' : 'marketing';
    const v = validateDesign(b.design, { category, mode: 'template', origin: this.origin() });
    if (v.errors.length) throw new StudioError(v.errors[0], 'BAD_TEMPLATE', 400, { errors: v.errors, warnings: v.warnings });
    return { name, category, description: oneLine(b.description).slice(0, 200), design: v.design, warnings: v.warnings };
  }

  /** New template: { fromStarter } or { fromTemplate } (copies), or { name, category, design }. */
  async createTemplate(body, { by = 'admin' } = {}) {
    const b = body && typeof body === 'object' ? { ...body } : {};
    if (b.fromStarter || b.fromTemplate) {
      const src = b.fromStarter ? starterById(String(b.fromStarter)) : await this.getTemplate(String(b.fromTemplate), { withHistory: false });
      if (!src) throw new StudioError('Template not found.', 'NOT_FOUND', 404);
      b.name = b.name || (b.fromStarter ? src.name : `${src.name} (copy)`);
      b.category = b.category || src.category;
      b.description = b.description !== undefined ? b.description : src.description;
      b.design = b.design || src.design;
      b.basedOn = b.fromStarter ? `starter:${src.id}` : `${src.templateId}@${src.version}`;
    }
    const t = this._cleanTemplateInput(b);
    await this.ensureStore();
    const now = this.clock();
    const by_ = String(by).slice(0, 120);
    const doc = { templateId: `et_${hex(8)}`, name: t.name, category: t.category, description: t.description, design: t.design, status: 'active', version: 1,
      basedOn: b.basedOn ? String(b.basedOn).slice(0, 80) : null, createdAt: now, createdBy: by_, updatedAt: now, updatedBy: by_,
      history: [{ version: 1, design: t.design, category: t.category, name: t.name, savedAt: now, savedBy: by_ }] };
    await this.soda.insert(C.templates, doc);
    return { template: this._tplPublic(doc), warnings: t.warnings };
  }

  /** Saves a new version. `baseVersion` (optional): refuse when someone saved in between. */
  async updateTemplate(id, body, { by = 'admin' } = {}) {
    if (!TEMPLATE_ID.test(String(id))) throw new StudioError(starterById(String(id)) ? 'Starters cannot be changed. Use one to make your own template.' : 'Template not found.', starterById(String(id)) ? 'READ_ONLY' : 'NOT_FOUND', starterById(String(id)) ? 409 : 404);
    const b = body && typeof body === 'object' ? body : {};
    await this.ensureStore();
    for (let i = 0; i < 5; i++) {
      const row = await this.soda.findOne(C.templates, { templateId: id });
      if (!row) throw new StudioError('Template not found.', 'NOT_FOUND', 404);
      const cur = row.value;
      if (b.baseVersion !== undefined && Number(b.baseVersion) !== cur.version) throw new StudioError(`Someone saved version ${cur.version} meanwhile. Reload it first.`, 'VERSION_CONFLICT', 409, { version: cur.version });
      const t = this._cleanTemplateInput({ name: b.name !== undefined ? b.name : cur.name, category: b.category || cur.category, description: b.description !== undefined ? b.description : cur.description, design: b.design || cur.design });
      const now = this.clock();
      const version = cur.version + 1;
      const by_ = String(by).slice(0, 120);
      const next = { ...cur, name: t.name, category: t.category, description: t.description, design: t.design, version, updatedAt: now, updatedBy: by_,
        history: [...(cur.history || []), { version, design: t.design, category: t.category, name: t.name, savedAt: now, savedBy: by_ }].slice(-MAX_VERSIONS) };
      if (await this.soda.compareAndReplace(C.templates, row.key, cur, next)) return { template: this._tplPublic(next), warnings: t.warnings };
    }
    throw new StudioError('The template is busy. Try again.', 'CONFLICT', 409);
  }

  async setTemplateStatus(id, status, { by = 'admin' } = {}) {
    if (!TEMPLATE_ID.test(String(id))) throw new StudioError('Template not found.', 'NOT_FOUND', 404);
    await this.ensureStore();
    const row = await this.soda.findOne(C.templates, { templateId: id });
    if (!row) throw new StudioError('Template not found.', 'NOT_FOUND', 404);
    const next = { ...row.value, status, updatedAt: this.clock(), updatedBy: String(by).slice(0, 120) };
    if (!(await this.soda.compareAndReplace(C.templates, row.key, row.value, next))) throw new StudioError('The template changed. Try again.', 'CONFLICT', 409);
    return this._tplPublic(next);
  }

  // ------------------------------------------------------------ data for rendering
  async _catalogPrices(now = this.clock()) {
    const catalog = this.repo && typeof this.repo.getMembershipCatalog === 'function' ? await this.repo.getMembershipCatalog().catch(() => ({})) : {};
    const out = {};
    for (const id of PAID_PLANS) {
      const p = catalog[id];
      if (!p || p.isActive === false) continue;
      const e = effectivePrice(p, now);
      out[id] = { name: shortPlanName(p.name || id), listPriceInr: e.listPriceInr, priceInr: e.priceInr, offer: e.offer, days: Number(p.billingPeriodDays) || 30 };
    }
    return out;
  }

  async _images(design) {
    const ids = [...new Set(design.blocks.filter((b) => (b.type === 'image' || b.type === 'header_image') && b.imageId).map((b) => b.imageId))];
    const out = {};
    if (!ids.length) return out;
    await this.soda.ensureCollection('push_images');
    for (const id of ids) {
      const row = await this.soda.findOne('push_images', { imageId: id });
      if (row) out[id] = `${this.origin()}/media/push/${row.value.imageId}.${row.value.ext}`;
    }
    return out;
  }

  /** Why the coupon cannot go in a mail now, or null. `unique`: the parent of child codes (must be public). */
  async couponProblem(code, { unique = false } = {}) {
    const c = this.repo && typeof this.repo.findCoupon === 'function' ? await this.repo.findCoupon(code).catch(() => null) : null;
    if (!c) return { problem: `There is no coupon ${code}. Create it in Coupons first.` };
    if (c.parentCode) return { problem: `${code} is a single-use code of another campaign. Choose its parent ${c.parentCode}.` };
    const ok = unique ? ['ACTIVE'] : ['ACTIVE', 'SCHEDULED'];
    if (!ok.includes(c.status)) return { problem: `Coupon ${code} is ${String(c.status || '').toLowerCase().replace(/_/g, ' ')}.${unique ? ' Unique codes need an active parent coupon.' : ''}` };
    if (unique && Array.isArray(c.allowedUserIds) && c.allowedUserIds.length) return { problem: `Coupon ${code} is for chosen riders only; unique codes need a public parent coupon.` };
    return { coupon: c };
  }

  _uniqueOpts(u) {
    if (!u || typeof u !== 'object' || !u.enabled) return null;
    const prefix = String(u.prefix || '').trim().toUpperCase();
    if (!/^[A-Z0-9]{2,10}$/.test(prefix)) throw new StudioError('Unique codes: the prefix has 2 to 10 letters or digits.', 'BAD_UNIQUE');
    const validDays = Math.round(Number(u.validDays) || 14);
    if (!(validDays >= 1 && validDays <= 90)) throw new StudioError('Unique codes: valid for 1 to 90 days.', 'BAD_UNIQUE');
    return { enabled: true, prefix, validDays };
  }

  /**
   * Everything a send needs, checked: design (mode send), category, coupon, unique codes, images.
   * Throws StudioError with all problems.
   */
  async prepare(input, { forSend = true, couponDoc = null } = {}) {
    const b = input && typeof input === 'object' ? input : {};
    if (!/^https?:\/\//.test(this.origin())) throw new StudioError('Marketing e-mails need the site address (PUBLIC_ORIGIN) for their links.', 'NO_ORIGIN', 503);
    // 3.57 round 3: a personal single-use code made for one rider (rider page) fills the coupon block as it is.
    if (couponDoc && b.design && Array.isArray(b.design.blocks)) {
      b.design = { ...b.design, blocks: b.design.blocks.map((x) => (x && x.type === 'coupon' ? { ...x, code: couponDoc.code } : x)) };
    }
    const v = validateDesign(b.design, { category: b.category, mode: forSend ? 'send' : 'template', origin: this.origin() });
    const errors = v.errors.slice(); const warnings = v.warnings.slice();
    let unique = null;
    try { unique = this._uniqueOpts(b.uniqueCoupon); } catch (e) { errors.push(e.message); }
    const couponBlock = v.design.blocks.find((x) => x.type === 'coupon');
    let coupon = null;
    if (unique && !couponBlock) errors.push('Unique codes need a coupon block (its coupon is the parent).');
    if (couponDoc && !couponBlock) errors.push('This e-mail needs a coupon block for the code.');
    if (couponBlock && couponDoc) coupon = couponDoc;
    else if (couponBlock && couponBlock.code) {
      const r = await this.couponProblem(couponBlock.code, { unique: !!unique });
      if (r.problem) errors.push(r.problem); else coupon = r.coupon;
    }
    const images = await this._images(v.design);
    for (const blk of v.design.blocks) if ((blk.type === 'image' || blk.type === 'header_image') && blk.imageId && !images[blk.imageId]) errors.push('An image is no longer uploaded. Choose it again.');
    try {
      const mode = this.accessMode ? this.accessMode.publicView().mode : 'paid';
      if (mode === 'free' && (v.uses.coupon || v.uses.price)) warnings.push('Group rides are free for everyone right now (access mode). A coupon or a price may confuse riders.');
    } catch { /* no access mode */ }
    if (errors.length) throw new StudioError(errors[0], 'BAD_EMAIL', 400, { errors, warnings });
    return { design: v.design, category: v.category, uses: v.uses, coupon, unique, images, warnings };
  }

  validateAudience(a, category) {
    const aud = a && typeof a === 'object' ? a : { kind: 'all' };
    const kind = String(aud.kind || 'all');
    const seg = SEGMENTS[kind];
    if (!seg) throw new StudioError('Unknown audience.', 'BAD_AUDIENCE');
    if (category === 'account' && !seg.account) throw new StudioError('An account e-mail goes only to riders whose plan ends soon or ended recently. Choose that audience, or make it a marketing e-mail.', 'ACCOUNT_AUDIENCE');
    const out = { kind };
    if (seg.days) {
      const days = Math.round(Number(aud.days));
      if (!(days >= 1 && days <= 365)) throw new StudioError(`${seg.label}: N must be 1 to 365.`, 'BAD_AUDIENCE');
      out.days = days;
    }
    if (kind === 'plan') {
      const ok = ['community', ...PAID_PLANS];
      const plans = [...new Set((Array.isArray(aud.plans) ? aud.plans : []).map(String))];
      if (!plans.length || plans.some((p) => !ok.includes(p))) throw new StudioError(`Choose plan types from: ${ok.join(', ')}.`, 'BAD_AUDIENCE');
      out.plans = plans;
    }
    if (kind === 'usernames') {
      const raw = Array.isArray(aud.usernames) ? aud.usernames : String(aud.usernames || '').split(/[\s,]+/);
      const names = [...new Set(raw.map((s) => String(s).trim().replace(/^@/, '').toLowerCase()).filter(Boolean))];
      if (!names.length) throw new StudioError('Enter at least one username.', 'BAD_AUDIENCE');
      if (names.length > 500) throw new StudioError('At most 500 usernames at once.', 'BAD_AUDIENCE');
      // 3.57 round 3: an account notice to named riders (e.g. "about your account") is for a handful of people.
      if (category === 'account' && names.length > 50) throw new StudioError('An account notice goes to at most 50 named riders. Send a marketing e-mail for more.', 'BAD_AUDIENCE');
      if (names.some((n) => !/^[a-z0-9_.]{3,30}$/.test(n))) throw new StudioError('A username can only have letters, digits, _ and .', 'BAD_AUDIENCE');
      out.usernames = names;
    }
    return out;
  }

  // ------------------------------------------------------------ audience
  async _memberships() {
    const { COLLECTIONS } = require('./oracle/repo');
    const rows = await this.soda.query(COLLECTIONS.memberships, {}, { limit: 100000 }).catch(() => []);
    const map = new Map();
    for (const r of rows) {
      const m = r.value;
      if (!m || !m.ownerUserId || !PAID_PLANS.includes(m.category) || m.statusReason === 'REFUNDED') continue;
      const prev = map.get(m.ownerUserId);
      if (!prev || (Number(m.validUntil) || 0) > (Number(prev.validUntil) || 0)) map.set(m.ownerUserId, m);
    }
    return map;
  }

  async _consenting() {
    await this.offers.ensureStore();
    const ids = [];
    for await (const page of this.soda.scan('marketing_consent')) for (const r of page) if (r.value && r.value.offersEmail === true && r.value.userId) ids.push(r.value.userId);
    return ids;
  }

  async _suppressed(email, category) {
    const row = await this.soda.findOne('email_suppression', { emailHash: emailHash(email) });
    if (!row) return false;
    return category === 'account' ? HARD_SUPPRESSION.includes(row.value.reason) : true;
  }

  /** [{ userId, email }] of the audience (consent / suppression per category). */
  async resolveAudience(aud, category = 'marketing') {
    await this.ensureStore();
    const now = this.clock();
    const kind = aud.kind;
    const needMemberships = ['plan_ends_within', 'plan_expired_within', 'plan'].includes(kind);
    const mems = needMemberships ? await this._memberships() : null;
    let ids = null;
    let only = null;
    if (kind === 'crew_admins') {
      const rows = await this.soda.query('crew_members', { role: { $in: ['ADMIN', 'CO_ADMIN'] } }, { limit: 100000 }).catch(() => []);
      only = new Set(rows.map((r) => r.value.userId));
    } else if (kind === 'operators') {
      const rows = await this.soda.query('operators', { status: 'APPROVED' }, { limit: 20000 }).catch(() => []);
      only = new Set();
      for (const r of rows) {
        const op = r.value;
        if (Number(op.validUntil) > 0 && Number(op.validUntil) <= now) continue;
        if (op.ownerId) only.add(op.ownerId);
        for (const c of op.coOrganisers || []) only.add(c);
      }
    } else if (kind === 'usernames') {
      const { findUserByUsername } = require('./usernames');
      only = new Set();
      for (const n of aud.usernames) { const u = await findUserByUsername(this.repo, n).catch(() => null); if (u && u.userId) only.add(u.userId); }
    }
    // Account notices: the plan segments (riders holding a plan), or named riders (3.57 round 3); marketing: consent.
    if (category === 'account') ids = kind === 'usernames' ? [...only] : [...mems.keys()];
    else ids = await this._consenting();
    const out = [];
    for (const uid of [...new Set(ids)]) {
      if (only && !only.has(uid)) continue;
      const m = mems ? mems.get(uid) : null;
      const until = m ? Number(m.validUntil) || 0 : 0;
      if (kind === 'plan_ends_within' && !(m && m.status === 'ACTIVE' && until > now && until <= now + aud.days * DAY)) continue;
      if (kind === 'plan_expired_within' && !(m && until <= now && until >= now - aud.days * DAY)) continue;
      if (kind === 'plan') {
        const cat = m && m.status === 'ACTIVE' && until > now ? m.category : 'community';
        if (!aud.plans.includes(cat)) continue;
      }
      const u = await this.repo.findUserById(uid).catch(() => null);
      if (!u || u.deletedAt || !validEmail(u.email)) continue;
      if (kind === 'joined_within' && !((Number(u.createdAt) || 0) >= now - aud.days * DAY)) continue;
      if (kind === 'active' && Math.max(Number(u.lastActiveAt) || 0, Number(u.lastLoginAt) || 0) < now - aud.days * DAY) continue;
      if (kind === 'inactive') {
        if ((Number(u.createdAt) || 0) > now - aud.days * DAY) continue;
        const t = await this.soda.query('trips', { userId: uid }, { limit: 1, orderBy: [{ path: 'endTimeEpochMs', datatype: 'number', order: 'desc' }] }).catch(() => []);
        if (t.length && (Number(t[0].value.endTimeEpochMs) || 0) >= now - aud.days * DAY) continue;
      }
      if (kind === 'never_hosted') {
        const c = await this.soda.query('convoys', { createdByUserId: uid }, { limit: 1 }).catch(() => []);
        if (c.length) continue;
      }
      if (await this._suppressed(u.email, category)) continue;
      out.push({ userId: uid, email: u.email.trim() });
    }
    return out;
  }

  async audienceCount(audience, category = 'marketing') {
    const cat = category === 'account' ? 'account' : 'marketing';
    const aud = this.validateAudience(audience, cat);
    return { riders: (await this.resolveAudience(aud, cat)).length, category: cat };
  }

  // ------------------------------------------------------------ unique codes
  /** The single-use child code of `parent` for (campaign, rider); the same code on a retry. */
  async issueUniqueCode(parent, { campaignId, userId, prefix, validDays, campaignName = '', createdBy = 'email-studio', notes = '' }) {
    await this.ensureStore();
    const key = `${campaignId}:${userId}`;
    const now = this.clock();
    const expiresAt = Math.min(Number(parent.expiresAt) || Infinity, now + validDays * DAY);
    const child = (code) => ({
      code, name: `${parent.name || parent.code} (single-use)`, campaignName: campaignName || parent.campaignName || '', description: parent.description || '',
      internalNotes: notes ? String(notes).slice(0, 500) : `Single-use code from e-mail campaign ${campaignId} (parent ${parent.code}).`, status: 'ACTIVE',
      discountType: parent.discountType, discountValue: parent.discountValue, maxDiscountCap: parent.maxDiscountCap, minOrderAmount: parent.minOrderAmount,
      validFrom: now - 60000, expiresAt, maxUsageTotal: 1, maxUsagePerUser: 1, applicableTiers: parent.applicableTiers, newMembersOnly: !!parent.newMembersOnly,
      firstPaymentOnly: !!parent.firstPaymentOnly, allowedUserIds: [userId], stackWithOffer: parent.stackWithOffer, createdBy: String(createdBy || 'email-studio').slice(0, 120),
      parentCode: parent.code, emailCampaignId: campaignId,
    });
    const ensureCoupon = async (code) => { if (!(await this.repo.findCoupon(code).catch(() => null))) await this.repo.saveCoupon(child(code)); return code; };
    const existing = await this.soda.findOne(C.codes, { key });
    if (existing) return ensureCoupon(existing.value.code);
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    for (let i = 0; i < 10; i++) {
      const bytes = crypto.randomBytes(8);
      const code = `${prefix}-${[...bytes].map((x) => alphabet[x % alphabet.length]).join('')}`;
      if (await this.repo.findCoupon(code).catch(() => null)) continue;
      try {
        await this.soda.insert(C.codes, { code, key, parentCode: parent.code, campaignId, userId, createdAt: now, expiresAt });
      } catch (e) {
        if (!(e && (e.status === 409 || /unique/i.test(e.message || '')))) throw e;
        const again = await this.soda.findOne(C.codes, { key });
        if (again) return ensureCoupon(again.value.code);
        continue; // code clash: another random code
      }
      return ensureCoupon(code);
    }
    throw new StudioError('Could not make a unique code. Try again.', 'UNIQUE_FAILED', 503);
  }

  async listUniqueCodes(parentCode, { limit = 500 } = {}) {
    await this.ensureStore();
    const code = cleanCouponCode(parentCode);
    if (!code) return [];
    const rows = await this.soda.query(C.codes, { parentCode: code }, { limit: Math.min(5000, limit), orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }] });
    const out = [];
    for (const r of rows) {
      const c = await this.repo.findCoupon(r.value.code).catch(() => null);
      out.push({ code: r.value.code, campaignId: r.value.campaignId, createdAt: r.value.createdAt, expiresAt: r.value.expiresAt,
        status: c ? c.status : 'MISSING', used: c ? (Number(c.usageCount) || 0) > 0 : false });
    }
    return out;
  }

  async uniqueSummary() {
    await this.ensureStore();
    const rows = await this.soda.query(C.codes, {}, { limit: 100000 });
    const out = {};
    for (const r of rows) { const p = r.value.parentCode; out[p] = out[p] || { issued: 0 }; out[p].issued++; }
    return out;
  }

  // ------------------------------------------------------------ links
  userHash(userId) { return crypto.createHmac('sha256', this.secret).update(`click-user:v1:${userId}`).digest('base64url').slice(0, 16); }

  clickToken(campaignId, userId, path) {
    const payload = `${campaignId}|${userId ? this.userHash(userId) : '-'}|${path}`;
    const sig = crypto.createHmac('sha256', this.secret).update(`click:v1:${payload}`).digest('base64url').slice(0, 22);
    return `${Buffer.from(payload).toString('base64url')}.${sig}`;
  }

  /** { campaignId, uh, path } of a valid token, else null. */
  readClickToken(token) {
    const t = String(token || '');
    if (t.length > 700) return null;
    const i = t.lastIndexOf('.');
    if (i <= 0) return null;
    let payload;
    try { payload = Buffer.from(t.slice(0, i), 'base64url').toString('utf8'); } catch { return null; }
    const want = Buffer.from(crypto.createHmac('sha256', this.secret).update(`click:v1:${payload}`).digest('base64url').slice(0, 22));
    const got = Buffer.from(t.slice(i + 1));
    if (want.length !== got.length || !crypto.timingSafeEqual(want, got)) return null;
    const [campaignId, uh, ...rest] = payload.split('|');
    const path = rest.join('|');
    if (!cleanSitePath(path, '')) return null;
    return { campaignId, uh, path };
  }

  async recordClick(info) {
    const s = await this.settings();
    if (!s.clickTracking) return false;
    if (!CAMPAIGN_ID.test(info.campaignId) && !RULE_ID.test(info.campaignId)) return false;
    await this.soda.insert(C.events, { type: 'click', campaignId: info.campaignId, uh: info.uh, path: info.path.slice(0, 300), at: this.clock() });
    return true;
  }

  async recordUnsubscribe(userId, campaignId) {
    if (!CAMPAIGN_ID.test(campaignId) && !RULE_ID.test(campaignId)) return;
    await this.ensureStore();
    const sent = await this.soda.findOne(LOG, { campaignId, userId, kind: 'marketing' });
    if (!sent) return;
    await this.soda.insert(C.events, { type: 'unsubscribe', campaignId, uh: this.userHash(userId), at: this.clock() });
  }

  // ------------------------------------------------------------ previews (iframe)
  async storePreview(html) {
    await this.ensureStore();
    const now = this.clock();
    await this.soda.removeWhere(C.previews, { expiresAt: { $lt: now } }).catch(() => {});
    const token = crypto.randomBytes(18).toString('base64url');
    await this.soda.insert(C.previews, { token, html, expiresAt: now + 15 * 60000 });
    return token;
  }
  async readPreview(token) {
    if (!/^[A-Za-z0-9_-]{24}$/.test(String(token))) return null;
    await this.ensureStore();
    const row = await this.soda.findOne(C.previews, { token: String(token) });
    return row && row.value.expiresAt > this.clock() ? row.value.html : null;
  }

  // ------------------------------------------------------------ building one e-mail
  async _planVars(userId) {
    const m = this.repo && typeof this.repo.findMembershipByOwner === 'function' ? await this.repo.findMembershipByOwner(userId).catch(() => null) : null;
    if (!m || !PAID_PLANS.includes(m.category)) return {};
    const catalog = await this.repo.getMembershipCatalog().catch(() => ({}));
    return { planName: shortPlanName(m.categoryName || (catalog[m.category] && catalog[m.category].name) || m.category), planEndsOn: istDate(m.validUntil) };
  }

  /**
   * One rider's e-mail. prep: from prepare(); user (or null for a sample); opts: { campaignId, track,
   * couponCode (a unique code for this rider), prices, forceDark, previewImages }.
   */
  async build(prep, user, opts = {}) {
    const o = this.origin();
    const prices = opts.prices || await this._catalogPrices();
    const couponDoc = prep.coupon;
    let coupon = null;
    if (couponDoc) {
      const code = opts.couponCode || couponDoc.code;
      coupon = { code, discount: discountText(couponDoc), validUntil: istDate(opts.couponExpiresAt || couponDoc.expiresAt), path: `/plans?coupon=${encodeURIComponent(code)}` };
    }
    const sample = !user;
    const planVars = user ? await this._planVars(user.userId) : { planName: VARIABLES.planName.sample, planEndsOn: VARIABLES.planEndsOn.sample };
    const priceBlock = prep.design.blocks.find((b) => b.type === 'price');
    const price = priceBlock ? prices[priceBlock.planId] : null;
    const firstButton = prep.design.blocks.find((b) => b.type === 'button');
    const linkPath = coupon ? coupon.path : firstButton ? firstButton.path : '/plans';
    const raw = {
      firstName: user ? firstNameOf(user.name) : VARIABLES.firstName.sample,
      username: user ? String(user.username || '').replace(/^@/, '') : VARIABLES.username.sample,
      planName: planVars.planName, planEndsOn: planVars.planEndsOn,
      couponCode: coupon ? coupon.code : '', discount: coupon ? coupon.discount : '', validUntil: coupon ? coupon.validUntil : '',
      listPrice: price ? inr(price.listPriceInr) : '', offerPrice: price ? inr(price.priceInr) : '',
      link: `${o}${linkPath}`,
    };
    // 3.57 round 3: the rider page preview fills values the e-mail will have once the action is done (plan, end date).
    if (opts.vars && typeof opts.vars === 'object') for (const k of Object.keys(VARIABLES)) if (opts.vars[k]) raw[k] = opts.vars[k];
    const vars = {};
    for (const [k, spec] of Object.entries(VARIABLES)) vars[k] = raw[k] ? String(raw[k]).replace(/\s+/g, ' ').trim().slice(0, 120) : spec.fallback;
    const track = !!opts.track && opts.campaignId;
    const link = (p) => (track ? `${o}/r/${this.clickToken(opts.campaignId, user ? user.userId : null, p)}` : `${o}${p}`);
    const unsub = user ? `${this.offers.unsubscribeUrl(user.userId)}${opts.campaignId ? `&cid=${opts.campaignId}` : ''}` : `${o}/email/unsubscribe`;
    const images = opts.previewImages ? Object.fromEntries(Object.entries(prep.images).map(([k, url]) => [k, url.replace(o, '')])) : prep.images;
    const mail = renderDesign(prep.design, {
      origin: o, vars, coupon, prices, images, link, category: prep.category, unsubscribeUrl: unsub, accountUrl: `${o}/account#emails`,
      postalAddress: this.postalAddress(), supportEmail: String(this.config.supportEmail || '').trim(), forceDark: !!opts.forceDark, sample,
      why: opts.why || null, omitMissingAddress: !!opts.omitMissingAddress,
    });
    const headers = { 'X-CoRoute-Mail': opts.mailKind || 'marketing', 'X-CoRoute-Category': prep.category === 'account' ? 'account' : 'offers', ...(opts.campaignId ? { 'X-CoRoute-Campaign': opts.campaignId } : {}) };
    if (prep.category !== 'account' && user) { headers['List-Unsubscribe'] = `<${unsub}>`; headers['List-Unsubscribe-Post'] = 'List-Unsubscribe=One-Click'; }
    return { ...mail, headers, vars };
  }

  async preview(input, { forceDark = false } = {}) {
    const prep = await this.prepare(input, { forSend: false });
    const unique = prep.unique && prep.coupon ? `${prep.unique.prefix}-SAMPLE01` : null;
    const m = await this.build(prep, null, { couponCode: unique, previewImages: true, forceDark });
    const token = await this.storePreview(m.html);
    let darkToken = null;
    if (!forceDark) darkToken = await this.storePreview((await this.build(prep, null, { couponCode: unique, previewImages: true, forceDark: true })).html);
    return { subject: m.subject, preheader: m.preheader, html: m.html, text: m.text, category: prep.category, warnings: prep.warnings,
      images: Object.fromEntries(Object.entries(prep.images).map(([k, url]) => [k, url.replace(this.origin(), '')])),
      previewUrl: `/email/preview/${token}`, darkPreviewUrl: darkToken ? `/email/preview/${darkToken}` : null, postalAddressSet: !!this.postalAddress() };
  }

  /** "Send test to me": the admin's own address; consent, caps and quiet hours do not apply. */
  async testSend(input, { userId }) {
    const prep = await this.prepare(input);
    const u = await this.repo.findUserById(userId).catch(() => null);
    if (!u || !validEmail(u.email)) throw new StudioError('Your admin account has no e-mail address.', 'NO_ADDRESS');
    let code = null; let expiresAt = null;
    if (prep.unique && prep.coupon) {
      code = await this.issueUniqueCode(prep.coupon, { campaignId: `test_${istDay(this.clock()).replace(/-/g, '')}_${hex(3)}`, userId, prefix: prep.unique.prefix, validDays: prep.unique.validDays, campaignName: 'Test send' });
      expiresAt = (await this.repo.findCoupon(code)).expiresAt;
    }
    const m = await this.build(prep, u, { couponCode: code, couponExpiresAt: expiresAt });
    const r = await this.mailer.send({ to: u.email, subject: `[Test] ${m.subject}`, html: m.html, text: m.text, headers: m.headers });
    if (r.disabled) throw new StudioError('E-mail is not configured on this server (SMTP_HOST / MAIL_FROM).', 'MAIL_OFF', 503);
    return { sent: !!r.sent, to: maskEmail(u.email), error: r.error || null, uniqueCode: code };
  }

  // ------------------------------------------------------------ campaigns
  _campPublic(doc) {
    if (!doc) return null;
    const { recipients, dueAts, leaseUntil, worker, key, ...rest } = doc; // eslint-disable-line no-unused-vars
    return { ...rest, recipients: Array.isArray(recipients) ? recipients.length : 0 };
  }

  async createCampaign(input, { by = 'admin' } = {}) {
    const b = input && typeof input === 'object' ? input : {};
    const prep = await this.prepare(b);
    if (!this.postalAddress()) throw new StudioError('Set the postal address for the e-mail footer first (MAIL_POSTAL_ADDRESS in the server config). Test sends work without it.', 'NO_POSTAL_ADDRESS', 409);
    const audience = this.validateAudience(b.audience, prep.category);
    const now = this.clock();
    let sendAt = Number(b.sendAt) || 0;
    if (!sendAt || sendAt < now) {
      if (sendAt && sendAt < now - 5 * 60000) throw new StudioError('The send time is in the past.', 'BAD_TIME');
      sendAt = now;
    }
    if (sendAt > now + 90 * DAY) throw new StudioError('Schedule at most 90 days ahead.', 'BAD_TIME');
    let templateRef = null;
    if (b.templateId) {
      const t = await this.getTemplate(String(b.templateId), { withHistory: false });
      if (t) templateRef = { templateId: t.templateId, version: t.version || 0, name: t.name };
    }
    const s = await this.settings();
    await this.ensureStore();
    const doc = {
      campaignId: `ec_${hex(10)}`, name: oneLine(b.name).slice(0, 80) || prep.design.subject.slice(0, 80), category: prep.category, design: prep.design,
      template: templateRef, couponCode: prep.coupon ? prep.coupon.code : null, uniqueCoupon: prep.unique, audience, sendAt,
      // Round 6: "Send at each rider's best time" (src/business/): each rider gets it at their preferred India-time
      // hour within 24 hours of sendAt, never inside the quiet hours; riders without a known hour get it at sendAt.
      bestTime: b.bestTime === true,
      trackClicks: b.trackClicks === false ? false : !!s.clickTracking, status: 'SCHEDULED', createdAt: now, createdBy: String(by).slice(0, 120), updatedAt: now,
      stats: { targeted: 0, sent: 0, failed: 0, skipped: 0, capped: 0 }, cursor: 0, recipients: null, leaseUntil: 0, worker: null, error: null, startedAt: null, finishedAt: null,
    };
    await this.soda.insert(C.campaigns, doc);
    return { campaign: this._campPublic(doc), warnings: prep.warnings, quietNow: this.isQuiet(s, now) };
  }

  async listCampaigns({ limit = 50 } = {}) {
    await this.ensureStore();
    const rows = await this.soda.query(C.campaigns, {}, { orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }], limit: Math.min(200, Math.max(1, limit)) });
    return rows.map((r) => this._campPublic(r.value));
  }

  async getCampaign(id) {
    if (!CAMPAIGN_ID.test(String(id))) return null;
    await this.ensureStore();
    const row = await this.soda.findOne(C.campaigns, { campaignId: id });
    return row ? this._campPublic(row.value) : null;
  }

  async cancelCampaign(id, { by = 'admin' } = {}) {
    if (!CAMPAIGN_ID.test(String(id))) throw new StudioError('Campaign not found.', 'NOT_FOUND', 404);
    await this.ensureStore();
    const row = await this.soda.findOne(C.campaigns, { campaignId: id });
    if (!row) throw new StudioError('Campaign not found.', 'NOT_FOUND', 404);
    if (row.value.status !== 'SCHEDULED') throw new StudioError('Only a scheduled campaign that has not started can be cancelled.', 'NOT_CANCELLABLE', 409);
    const next = { ...row.value, status: 'CANCELLED', cancelledBy: String(by).slice(0, 120), updatedAt: this.clock(), finishedAt: this.clock() };
    if (!(await this.soda.compareAndReplace(C.campaigns, row.key, row.value, next))) throw new StudioError('The campaign changed. Try again.', 'CONFLICT', 409);
    return this._campPublic(next);
  }

  /** Report of a campaign or an automation rule (id ec_ / ea_). */
  async report(id) {
    await this.ensureStore();
    const logs = await this.soda.query(LOG, { campaignId: id, kind: 'marketing' }, { limit: 200000 });
    const byStatus = { SENT: 0, FAILED: 0, SENDING: 0, SKIPPED: 0 };
    const recipients = new Set(); const codes = new Set();
    let firstAt = Infinity;
    for (const r of logs) {
      const v = r.value;
      byStatus[v.status] = (byStatus[v.status] || 0) + 1;
      if (v.status === 'SENT') { recipients.add(v.userId); firstAt = Math.min(firstAt, Number(v.sentAt) || Infinity); }
      if (v.couponCode) codes.add(v.couponCode);
    }
    const events = await this.soda.query(C.events, { campaignId: id }, { limit: 200000 });
    const clicks = events.filter((e) => e.value.type === 'click');
    const byPath = new Map();
    for (const e of clicks) byPath.set(e.value.path, (byPath.get(e.value.path) || 0) + 1);
    const unsub = new Set(events.filter((e) => e.value.type === 'unsubscribe').map((e) => e.value.uh));
    let redemptions = { count: 0, discountInr: 0, revenueInr: 0 };
    if (codes.size && typeof this.repo.listCouponRedemptions === 'function') {
      const all = await this.repo.listCouponRedemptions({ status: 'SUCCESS' }, 20000).catch(() => []);
      for (const rd of all) {
        if (!codes.has(String(rd.couponCode || '').toUpperCase()) || !recipients.has(rd.userId)) continue;
        if ((Number(rd.redeemedAt || rd.createdAt) || 0) < (firstAt === Infinity ? 0 : firstAt)) continue;
        redemptions.count++; redemptions.discountInr += Number(rd.discountAmount) || 0; redemptions.revenueInr += Number(rd.finalAmount) || 0;
      }
    }
    redemptions = { count: redemptions.count, discountInr: Math.round(redemptions.discountInr), revenueInr: Math.round(redemptions.revenueInr * 100) / 100 };
    return {
      queued: logs.length, sent: byStatus.SENT, failed: byStatus.FAILED, inFlight: byStatus.SENDING, unsubscribed: unsub.size,
      clicks: { total: clicks.length, unique: new Set(clicks.map((e) => e.value.uh)).size, byLink: [...byPath.entries()].map(([path, total]) => ({ path, total })).sort((a, b) => b.total - a.total) },
      redemptions,
    };
  }

  // ------------------------------------------------------------ automation rules
  _rulePublic(doc) { if (!doc) return null; const { key, ...rest } = doc; return rest; } // eslint-disable-line no-unused-vars

  async _cleanRule(b) {
    const name = oneLine(b.name).slice(0, 80);
    if (!name) throw new StudioError('Name the rule.', 'NAME_REQUIRED');
    const trig = RULE_TRIGGERS[String(b.trigger || '')];
    if (!trig) throw new StudioError(`Trigger must be one of: ${Object.keys(RULE_TRIGGERS).join(', ')}.`, 'BAD_RULE');
    const days = Math.round(Number(b.days || trig.defaultDays));
    if (!(days >= 1 && days <= 365)) throw new StudioError('N days must be 1 to 365.', 'BAD_RULE');
    const cooldownDays = Math.round(Number(b.cooldownDays !== undefined ? b.cooldownDays : trig.cooldown));
    if (!(cooldownDays >= 0 && cooldownDays <= 730)) throw new StudioError('Once per rider per N days: 0 to 730.', 'BAD_RULE');
    if (!TEMPLATE_ID.test(String(b.templateId || ''))) throw new StudioError('Choose a saved template (make one from a starter first).', 'BAD_RULE');
    const t = await this.getTemplate(String(b.templateId), { withHistory: false });
    if (!t || t.status === 'archived') throw new StudioError('The template is missing or archived.', 'BAD_RULE');
    const couponCode = b.couponCode ? cleanCouponCode(b.couponCode) : '';
    const design = this._withCoupon(t.design, couponCode);
    const prep = await this.prepare({ design, category: t.category, uniqueCoupon: b.uniqueCoupon });
    this.validateAudience({ kind: trig.segment, days }, prep.category);
    return { name, trigger: String(b.trigger), days, cooldownDays, templateId: t.templateId, couponCode: couponCode || null, uniqueCoupon: prep.unique, enabled: b.enabled !== false };
  }

  _withCoupon(design, code) {
    if (!code) return design;
    return { ...design, blocks: design.blocks.map((x) => (x.type === 'coupon' ? { ...x, code } : x)) };
  }

  async listRules() {
    await this.ensureStore();
    const rows = await this.soda.query(C.rules, {}, { limit: 200, orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }] });
    return rows.map((r) => this._rulePublic(r.value));
  }

  async createRule(body, { by = 'admin' } = {}) {
    const r = await this._cleanRule(body || {});
    if (r.enabled && !this.postalAddress()) throw new StudioError('Set the postal address for the e-mail footer first (MAIL_POSTAL_ADDRESS).', 'NO_POSTAL_ADDRESS', 409);
    await this.ensureStore();
    const now = this.clock();
    const doc = { ruleId: `ea_${hex(8)}`, ...r, createdAt: now, createdBy: String(by).slice(0, 120), updatedAt: now, lastRunAt: 0, stats: { sent: 0, skipped: 0, failed: 0 } };
    await this.soda.insert(C.rules, doc);
    return this._rulePublic(doc);
  }

  async updateRule(id, body, { by = 'admin' } = {}) {
    if (!RULE_ID.test(String(id))) throw new StudioError('Rule not found.', 'NOT_FOUND', 404);
    await this.ensureStore();
    const row = await this.soda.findOne(C.rules, { ruleId: id });
    if (!row) throw new StudioError('Rule not found.', 'NOT_FOUND', 404);
    const r = await this._cleanRule({ ...row.value, ...(body || {}) });
    if (r.enabled && !this.postalAddress()) throw new StudioError('Set the postal address for the e-mail footer first (MAIL_POSTAL_ADDRESS).', 'NO_POSTAL_ADDRESS', 409);
    const next = { ...row.value, ...r, updatedAt: this.clock(), updatedBy: String(by).slice(0, 120) };
    if (!(await this.soda.compareAndReplace(C.rules, row.key, row.value, next))) throw new StudioError('The rule changed. Try again.', 'CONFLICT', 409);
    return this._rulePublic(next);
  }

  async deleteRule(id) {
    if (!RULE_ID.test(String(id))) throw new StudioError('Rule not found.', 'NOT_FOUND', 404);
    await this.ensureStore();
    const n = await this.soda.removeWhere(C.rules, { ruleId: id });
    if (!n) throw new StudioError('Rule not found.', 'NOT_FOUND', 404);
    return { ok: true };
  }

  // ------------------------------------------------------------ sending
  async _sentThisWeek(userId) {
    const rows = await this.soda.query(LOG, { userId, kind: 'marketing', category: 'marketing', status: 'SENT', sentAt: { $gte: this.clock() - 7 * DAY } }, { limit: 50 });
    return rows.length;
  }

  /**
   * One recipient, every check at send time. Returns 'sent' | 'failed' | 'skipped' | 'capped' | 'dup'.
   * ctx: { id (campaign or rule id), prep, key, settings, prices, couponUnusable, meta }.
   */
  async _sendOne(userId, ctx) {
    const u = await this.repo.findUserById(userId).catch(() => null);
    if (!u || u.deletedAt || !validEmail(u.email)) return 'skipped';
    if (ctx.prep.category === 'marketing') {
      const consent = await this.offers.consentOf(userId);
      if (!consent.offersEmail) return 'skipped';
    }
    if (await this._suppressed(u.email, ctx.prep.category)) return 'skipped';
    if (ctx.prep.category === 'marketing' && (await this._sentThisWeek(userId)) >= ctx.settings.maxPerWeek) return 'capped';
    const now = this.clock();
    try {
      await this.soda.insert(LOG, { key: ctx.key, kind: 'marketing', category: ctx.prep.category, campaignId: ctx.id, userId, to: maskEmail(u.email), status: 'SENDING',
        createdAt: now, updatedAt: now, ...(ctx.meta || {}) });
    } catch (e) {
      if (e && (e.status === 409 || /unique/i.test(e.message || ''))) return 'dup';
      throw e;
    }
    const row = await this.soda.findOne(LOG, { key: ctx.key });
    let code = null; let expiresAt = null; let result;
    try {
      if (ctx.prep.unique && ctx.prep.coupon) {
        code = await this.issueUniqueCode(ctx.prep.coupon, { campaignId: ctx.id, userId, prefix: ctx.prep.unique.prefix, validDays: ctx.prep.unique.validDays, campaignName: ctx.name || '' });
        const cc = await this.repo.findCoupon(code).catch(() => null);
        expiresAt = cc ? cc.expiresAt : null;
      }
      const m = await this.build(ctx.prep, u, { campaignId: ctx.id, track: ctx.track, couponCode: code, couponExpiresAt: expiresAt, prices: ctx.prices, why: ctx.why || null });
      result = await this.mailer.send({ to: u.email.trim(), subject: m.subject, html: m.html, text: m.text, headers: m.headers });
    } catch (e) {
      result = { sent: false, error: String((e && e.code) || 'BUILD_FAILED').slice(0, 40) };
    }
    if (!result.sent && Number(result.responseCode) >= 500 && Number(result.responseCode) < 600) {
      await this.offers.suppress(u.email, 'bounce', 'smtp').catch(() => {});
    }
    const done = { ...row.value, status: result.sent ? 'SENT' : 'FAILED', sentAt: result.sent ? this.clock() : null, error: result.sent ? null : String(result.error || 'SEND_FAILED').slice(0, 40),
      messageId: result.messageId || null, couponCode: code || (ctx.prep.coupon ? ctx.prep.coupon.code : null), updatedAt: this.clock() };
    await this.soda.compareAndReplace(LOG, row.key, row.value, done);
    return result.sent ? 'sent' : 'failed';
  }

  /** Leased job: due campaigns, then automation rules. Nothing during quiet hours. */
  async tick() {
    if (this.running) return 0;
    this.running = true;
    let n = 0;
    try {
      await this.ensureStore();
      const s = await this.settings();
      if (this.isQuiet(s)) return 0;
      for (let guard = 0; guard < 10; guard++) {
        const claimed = await this._claimNext();
        if (!claimed) break;
        n++;
        await this._run(claimed, s);
      }
      await this.runAutomations(s);
      await this.soda.removeWhere(C.events, { at: { $lt: this.clock() - 400 * DAY } }).catch(() => {});
    } catch (e) {
      this.logger.warn?.(`[email-studio] tick failed: ${e.message}`);
    } finally { this.running = false; }
    return n;
  }

  async _claimNext() {
    const now = this.clock();
    const due = [
      ...(await this.soda.query(C.campaigns, { status: 'SCHEDULED', sendAt: { $lte: now } }, { limit: 5 })),
      ...(await this.soda.query(C.campaigns, { status: 'SENDING', leaseUntil: { $lt: now } }, { limit: 5 })),
    ];
    for (const row of due) {
      const next = { ...row.value, status: 'SENDING', worker: this.worker, leaseUntil: now + this.leaseMs, startedAt: row.value.startedAt || now, updatedAt: now };
      if (await this.soda.compareAndReplace(C.campaigns, row.key, row.value, next)) return { key: row.key, doc: next };
    }
    return null;
  }

  async _save(state, patch) {
    const next = { ...state.doc, ...patch, updatedAt: this.clock() };
    if (next.status === 'SENDING') next.leaseUntil = this.clock() + this.leaseMs;
    const ok = await this.soda.compareAndReplace(C.campaigns, state.key, state.doc, next);
    if (ok) state.doc = next;
    return ok;
  }

  async _run(state, settings) {
    const fail = (error) => this._save(state, { status: 'FAILED', error: String(error).slice(0, 200), finishedAt: this.clock(), recipients: [], leaseUntil: 0 });
    if (!this.enabled) return fail('E-mail is not configured on this server (SMTP_HOST / MAIL_FROM).');
    if (!this.postalAddress()) return fail('The postal address for the e-mail footer is not set (MAIL_POSTAL_ADDRESS).');
    let prep;
    try { prep = await this.prepare({ design: state.doc.design, category: state.doc.category, uniqueCoupon: state.doc.uniqueCoupon }); } catch (e) {
      return fail(`Cannot send any more: ${e.message}`);
    }
    if (!Array.isArray(state.doc.recipients)) {
      let list;
      try { list = (await this.resolveAudience(state.doc.audience, state.doc.category)).map((x) => x.userId); } catch (e) { return fail(`Audience could not be read: ${e.message}`); }
      if (!(await this._save(state, { recipients: list, cursor: 0, stats: { ...state.doc.stats, targeted: list.length } }))) return;
    }
    if (state.doc.bestTime && !Array.isArray(state.doc.dueAts)) {
      const plan = await this._bestTimePlan(state.doc.recipients, state.doc.startedAt || this.clock(), settings);
      if (!(await this._save(state, { recipients: plan.recipients, dueAts: plan.dueAts, cursor: 0, stats: { ...state.doc.stats, timed: plan.timed } }))) return;
    }
    while (state.doc.cursor < state.doc.recipients.length) {
      if (this.isQuiet(settings)) { await this._save(state, { status: 'SCHEDULED', sendAt: this.clock(), leaseUntil: 0, worker: null }); return; }
      const started = this.clock();
      let batch = this.batchSize;
      if (Array.isArray(state.doc.dueAts)) {
        // Best-time campaign: only the riders whose hour has come; the rest wait (the campaign goes back to SCHEDULED).
        const nextDue = Number(state.doc.dueAts[state.doc.cursor]) || 0;
        if (nextDue > started) { await this._save(state, { status: 'SCHEDULED', sendAt: nextDue, leaseUntil: 0, worker: null }); return; }
        let n = 0;
        while (n < this.batchSize && state.doc.cursor + n < state.doc.recipients.length && (Number(state.doc.dueAts[state.doc.cursor + n]) || 0) <= started) n++;
        batch = Math.max(1, n);
      }
      const prices = await this._catalogPrices();
      const slice = state.doc.recipients.slice(state.doc.cursor, state.doc.cursor + batch);
      const stats = { ...state.doc.stats };
      let mailed = 0;
      for (const uid of slice) {
        const r = await this._sendOne(uid, { id: state.doc.campaignId, name: state.doc.name, prep, key: `mkt:${state.doc.campaignId}:${uid}`, settings, prices, track: state.doc.trackClicks,
          why: state.doc.category === 'account' && state.doc.audience && state.doc.audience.kind === 'usernames' ? SERVICE_WHY : null });
        if (r === 'sent') { stats.sent++; mailed++; } else if (r === 'failed') { stats.failed++; mailed++; } else if (r === 'capped') stats.capped = (stats.capped || 0) + 1; else stats.skipped++;
      }
      if (!(await this._save(state, { cursor: state.doc.cursor + slice.length, stats }))) return;
      const wantMs = Math.ceil((mailed / this.ratePerSec) * 1000);
      const spent = this.clock() - started;
      if (state.doc.cursor < state.doc.recipients.length && wantMs > spent) await this.sleep(wantMs - spent);
    }
    await this._save(state, { status: 'SENT', finishedAt: this.clock(), recipients: [], dueAts: null, leaseUntil: 0 });
  }

  /**
   * Round 6: when each recipient of a best-time campaign is due. `this.sendTimes.bestHours(userIds)` (the business
   * brain) gives the riders' preferred India-time hour; the due time is the next occurrence of that hour within 24 h
   * of `start`, moved out of the quiet hours (to the hour they end). Riders without a known hour are due at `start`.
   * Returns the recipients ordered by due time with the parallel dueAts list.
   */
  async _bestTimePlan(recipients, start, settings) {
    let best = new Map();
    try { if (this.sendTimes && typeof this.sendTimes.bestHours === 'function') best = await this.sendTimes.bestHours(recipients); } catch { best = new Map(); }
    const HOUR = 3600000;
    const startHour = Math.floor((start + IST) / HOUR);
    const rows = recipients.map((uid, i) => {
      let due = start;
      const h = best.get(uid);
      if (Number.isInteger(h) && h >= 0 && h < 24) {
        const ahead = (h - (startHour % 24) + 24) % 24;
        due = ahead === 0 ? start : (startHour + ahead) * HOUR - IST;
        for (let guard = 0; guard < 24 && this.isQuiet(settings, due); guard++) due += HOUR;
      }
      return { uid, due, i };
    });
    rows.sort((a, b) => a.due - b.due || a.i - b.i);
    return { recipients: rows.map((x) => x.uid), dueAts: rows.map((x) => x.due), timed: rows.filter((x) => x.due > start).length };
  }

  /** Every enabled rule: its segment now, once per rider per occurrence / cooldown, frequency cap. */
  async runAutomations(settings) {
    if (!this.enabled || !this.postalAddress()) return 0;
    const s = settings || await this.settings();
    if (this.isQuiet(s)) return 0;
    const rules = (await this.soda.query(C.rules, { enabled: true }, { limit: 100 })).map((r) => r.value);
    let sent = 0;
    for (const rule of rules) {
      try { sent += await this._runRule(rule, s); } catch (e) { this.logger.warn?.(`[email-studio] rule ${rule.ruleId} failed: ${e.message}`); }
    }
    return sent;
  }

  async _runRule(rule, settings) {
    const trig = RULE_TRIGGERS[rule.trigger];
    const t = await this.getTemplate(rule.templateId, { withHistory: false });
    if (!trig || !t || t.status === 'archived') return 0;
    let prep;
    try { prep = await this.prepare({ design: this._withCoupon(t.design, rule.couponCode), category: t.category, uniqueCoupon: rule.uniqueCoupon }); } catch (e) {
      this.logger.warn?.(`[email-studio] rule ${rule.ruleId} skipped: ${e.message}`);
      return 0;
    }
    const aud = { kind: trig.segment, days: rule.days };
    const list = await this.resolveAudience(aud, prep.category);
    const mems = trig.segment.startsWith('plan_') ? await this._memberships() : null;
    const now = this.clock();
    const prices = await this._catalogPrices();
    const started = now;
    let sent = 0; let mailed = 0;
    const stats = { sent: 0, skipped: 0, failed: 0 };
    for (const { userId } of list) {
      // Occurrence: the plan period for plan rules (once per plan end), else the India day (+ the cooldown).
      const occ = mems ? String(Number((mems.get(userId) || {}).validUntil) || 0) : istDay(now);
      if (rule.cooldownDays > 0) {
        const last = await this.soda.query(LOG, { campaignId: rule.ruleId, userId, kind: 'marketing' }, { limit: 1, orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }] });
        if (last.length && (Number(last[0].value.createdAt) || 0) > now - rule.cooldownDays * DAY) { stats.skipped++; continue; }
      }
      const r = await this._sendOne(userId, { id: rule.ruleId, name: rule.name, prep, key: `auto:${rule.ruleId}:${userId}:${occ}`, settings, prices, track: !!settings.clickTracking,
        meta: { templateId: t.templateId, templateVersion: t.version } });
      if (r === 'sent') { sent++; stats.sent++; mailed++; } else if (r === 'failed') { stats.failed++; mailed++; } else if (r !== 'dup') stats.skipped++;
      if (mailed) {
        const want = Math.ceil((mailed / this.ratePerSec) * 1000);
        const spent = this.clock() - started;
        if (want > spent) await this.sleep(Math.min(want - spent, 5000));
      }
    }
    const row = await this.soda.findOne(C.rules, { ruleId: rule.ruleId });
    if (row) {
      const prev = row.value.stats || { sent: 0, skipped: 0, failed: 0 };
      await this.soda.compareAndReplace(C.rules, row.key, row.value, { ...row.value, lastRunAt: this.clock(), stats: { sent: prev.sent + stats.sent, skipped: prev.skipped + stats.skipped, failed: prev.failed + stats.failed } }).catch(() => {});
    }
    return sent;
  }

  // ------------------------------------------------------------ 3.57 round 3: one e-mail to one rider (web admin)
  /**
   * May this rider get a direct e-mail of `category` now? Transactional ('account'): yes unless the address is
   * hard-suppressed (bounce, complaint, admin). Marketing: only with the Offers consent and no suppression, or
   * when the admin marks it a service message the rider asked for (`service` + a note); a bounce / complaint /
   * admin suppression still blocks it.
   */
  async directCheck(user, category, { service = false, serviceNote = '' } = {}) {
    await this.offers.ensureStore();
    const hasEmail = !!(user && validEmail(user.email));
    const consent = user ? await this.offers.consentOf(user.userId) : { offersEmail: false };
    const row = hasEmail ? await this.soda.findOne('email_suppression', { emailHash: emailHash(user.email) }) : null;
    const suppressed = row ? row.value.reason : null;
    const hard = !!(suppressed && HARD_SUPPRESSION.includes(suppressed));
    const out = { classification: category === 'account' ? 'transactional' : (service ? 'service' : 'marketing'), hasEmail, offersConsent: !!consent.offersEmail, suppressed, allowed: false, code: null, reason: '' };
    if (!hasEmail) return { ...out, code: 'NO_ADDRESS', reason: 'This rider has no valid e-mail address.' };
    if (hard) return { ...out, code: 'SUPPRESSED', reason: `E-mails to this address are stopped (${suppressed}).` };
    if (category === 'account') return { ...out, allowed: true };
    if (service) {
      if (oneLine(serviceNote).length < 3) return { ...out, code: 'NOTE_REQUIRED', reason: 'Write a short note: why the rider asked for this.' };
      return { ...out, allowed: true };
    }
    if (suppressed) return { ...out, code: 'SUPPRESSED', reason: 'This rider unsubscribed from offer e-mails.' };
    if (!consent.offersEmail) return { ...out, code: 'NO_CONSENT', reason: 'This rider has not agreed to offer e-mails. Tick "service message" with a note if they asked for it, or share the code yourself.' };
    return { ...out, allowed: true };
  }

  /**
   * Sends one e-mail to one rider at once (no quiet hours or weekly cap: a 1:1 message, not a campaign).
   * input: { design, category, uniqueCoupon, couponDoc, service, serviceNote, key (idempotency), why, meta }.
   * The mail_log row `direct:<key>` is written before sending: a retry with the same key never sends twice.
   */
  async sendDirect(userId, input = {}, { by = 'admin' } = {}) {
    await this.ensureStore();
    if (!this.enabled) throw new StudioError('E-mail is not configured on this server (SMTP_HOST / MAIL_FROM).', 'MAIL_OFF', 503);
    const u = await this.repo.findUserById(String(userId)).catch(() => null);
    if (!u || u.deletedAt) throw new StudioError('Rider not found.', 'NOT_FOUND', 404);
    const category = input.category === 'account' ? 'account' : 'marketing';
    const prep = await this.prepare({ design: input.design, category, uniqueCoupon: input.uniqueCoupon }, { couponDoc: input.couponDoc || null });
    const check = await this.directCheck(u, prep.category, { service: !!input.service, serviceNote: input.serviceNote });
    if (!check.allowed) throw new StudioError(check.reason, check.code, 409, { check });
    if (prep.category === 'marketing' && !this.postalAddress()) throw new StudioError('Set the postal address for the e-mail footer first (MAIL_POSTAL_ADDRESS). Offer e-mails need it.', 'NO_POSTAL_ADDRESS', 409);
    const key = `direct:${String(input.key || `${u.userId}:${hex(8)}`).slice(0, 120)}`;
    const now = this.clock();
    try {
      await this.soda.insert(LOG, { key, kind: 'direct', category: prep.category, classification: check.classification, userId: u.userId, to: maskEmail(u.email), status: 'SENDING',
        by: String(by).slice(0, 120), subject: oneLine(prep.design.subject).slice(0, 150), createdAt: now, updatedAt: now, ...(input.meta || {}) });
    } catch (e) {
      if (e && (e.status === 409 || /unique/i.test(e.message || ''))) return { sent: false, duplicate: true, to: maskEmail(u.email), classification: check.classification };
      throw e;
    }
    const row = await this.soda.findOne(LOG, { key });
    let code = null; let expiresAt = null; let result;
    try {
      if (prep.unique && prep.coupon) {
        const cid = `dm_${crypto.createHash('sha256').update(key).digest('hex').slice(0, 16)}`;
        code = await this.issueUniqueCode(prep.coupon, { campaignId: cid, userId: u.userId, prefix: prep.unique.prefix, validDays: prep.unique.validDays, campaignName: 'Direct e-mail' });
        const cc = await this.repo.findCoupon(code).catch(() => null);
        expiresAt = cc ? cc.expiresAt : null;
      } else if (input.couponDoc) {
        code = input.couponDoc.code; expiresAt = input.couponDoc.expiresAt;
      }
      const why = input.why || (prep.category === 'account' ? SERVICE_WHY : check.classification === 'service' ? 'You get this e-mail because you asked the CoRoute team for it.' : null);
      const m = await this.build(prep, u, { couponCode: code, couponExpiresAt: expiresAt, why, omitMissingAddress: prep.category === 'account', mailKind: 'direct' });
      result = await this.mailer.send({ to: u.email.trim(), subject: m.subject, html: m.html, text: m.text, headers: m.headers });
    } catch (e) {
      result = { sent: false, error: String((e && e.code) || 'BUILD_FAILED').slice(0, 40) };
    }
    if (!result.sent && Number(result.responseCode) >= 500 && Number(result.responseCode) < 600) await this.offers.suppress(u.email, 'bounce', 'smtp').catch(() => {});
    await this.soda.compareAndReplace(LOG, row.key, row.value, { ...row.value, status: result.sent ? 'SENT' : 'FAILED', sentAt: result.sent ? this.clock() : null,
      error: result.sent ? null : String(result.error || 'SEND_FAILED').slice(0, 40), messageId: result.messageId || null, couponCode: code || null, updatedAt: this.clock() });
    return { sent: !!result.sent, error: result.sent ? null : (result.error || 'SEND_FAILED'), to: maskEmail(u.email), classification: check.classification, category: prep.category, couponCode: code, key };
  }

  /** The direct e-mails a rider got (newest first), for the rider page. */
  async directLog(userId, { limit = 30 } = {}) {
    await this.ensureStore();
    const rows = await this.soda.query(LOG, { userId: String(userId), kind: 'direct' }, { limit: Math.min(100, limit), orderBy: [{ path: 'createdAt', datatype: 'number', order: 'desc' }] }).catch(() => []);
    return rows.map((r) => ({ at: r.value.createdAt, subject: r.value.subject || '', category: r.value.category, classification: r.value.classification || null, status: r.value.status, by: r.value.by || null, couponCode: r.value.couponCode || null, template: r.value.template || null }));
  }

  // ------------------------------------------------------------ images (library)
  _photos() {
    if (!this.photoStore) this.photoStore = require('./review_photos').createPhotoStore(require('./config').reviewPhotoDir);
    return this.photoStore;
  }

  /** Marketing studio and board images an e-mail may reuse. */
  async imageLibrary() {
    const { COLLECTIONS } = require('./oracle/repo');
    const out = [];
    const mk = await this.soda.query(COLLECTIONS.subscriptionConfig, { k: 'mkt_image' }, { limit: 300 }).catch(() => []);
    for (const r of mk) out.push({ source: 'marketing', id: r.value.id, width: r.value.width || null, height: r.value.height || null, bytes: r.value.bytes || 0, at: r.value.at || 0, previewUrl: `/api/admin/marketing/images/${r.value.id}` });
    await this.soda.ensureCollection('board_posts');
    const bd = await this.soda.query('board_posts', { type: 'image' }, { limit: 300 }).catch(() => []);
    for (const r of bd) out.push({ source: 'board', id: r.value.postId, width: r.value.width || null, height: r.value.height || null, bytes: r.value.bytes || 0, at: r.value.at || 0, previewUrl: `/api/admin/board/images/${r.value.postId}` });
    return out.sort((a, b) => b.at - a.at);
  }

  /** Copies a library image into the public e-mail / push image store. */
  async importImage({ source, id }, { by = 'admin' } = {}) {
    if (!this.pushCampaigns) throw new StudioError('Images are not available on this server.', 'NO_IMAGES', 503);
    const { COLLECTIONS } = require('./oracle/repo');
    let meta = null;
    if (source === 'marketing') {
      const r = await this.soda.findOne(COLLECTIONS.subscriptionConfig, { k: 'mkt_image', id: String(id) });
      meta = r ? r.value : null;
    } else if (source === 'board') {
      const r = await this.soda.findOne('board_posts', { type: 'image', postId: String(id) });
      meta = r ? { ...r.value, id: r.value.postId } : null;
    }
    if (!meta) throw new StudioError('Image not found.', 'NOT_FOUND', 404);
    const data = await this._photos().read(meta).catch(() => null);
    if (!data) throw new StudioError('Image not found.', 'NOT_FOUND', 404);
    try {
      const img = await this.pushCampaigns.saveImage(data, by);
      return { imageId: img.imageId, url: img.url, bytes: img.bytes, width: img.width, height: img.height };
    } catch (e) {
      throw new StudioError(e.message || 'The image could not be used.', e.code || 'BAD_IMAGE', e.status || 400);
    }
  }

  // ------------------------------------------------------------ account erase
  async forgetUser(userId) {
    await this.ensureStore();
    await this.soda.removeWhere(LOG, { userId, kind: 'marketing' }).catch(() => {});
    await this.soda.removeWhere(LOG, { userId, kind: 'direct' }).catch(() => {});
    await this.soda.removeWhere(C.events, { uh: this.userHash(userId) }).catch(() => {});
    await this.soda.removeWhere(C.codes, { userId }).catch(() => {});
  }
}

// =================================================================== routers
function adminStudioRouter({ studio, audit = null }) {
  const r = express.Router();
  r.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  const by = (req) => (req.user && (req.user.email || req.user.userId)) || 'admin';
  const log = (req, action, target, details) => { if (audit) audit({ by: by(req), action, target, details, at: Date.now() }); };
  const h = (fn) => async (req, res, next) => {
    try { await fn(req, res); } catch (e) {
      if (e instanceof StudioError) return res.status(e.status).json({ error: e.message, code: e.code, errors: e.errors, warnings: e.warnings });
      next(e);
    }
  };
  r.get('/config', h(async (req, res) => {
    const s = await studio.settings();
    res.json({ enabled: studio.enabled, origin: studio.origin(), postalAddressSet: !!studio.postalAddress(), postalPlaceholder: POSTAL_PLACEHOLDER, ratePerSec: studio.ratePerSec,
      variables: Object.entries(VARIABLES).map(([name, x]) => ({ name, label: x.label, fallback: x.fallback, needs: x.needs || null })),
      blockTypes: BLOCK_TYPES.map((t) => ({ type: t, label: BLOCK_LABELS[t] })), buttonPaths: BUTTON_PATHS,
      segments: Object.entries(SEGMENTS).map(([kind, x]) => ({ kind, label: x.label, days: !!x.days, account: !!x.account })),
      triggers: Object.entries(RULE_TRIGGERS).map(([id, x]) => ({ id, label: x.label, defaultDays: x.defaultDays, cooldown: x.cooldown })),
      settings: s, quietNow: studio.isQuiet(s), plans: PAID_PLANS });
  }));
  r.get('/settings', h(async (req, res) => { res.json(await studio.settings()); }));
  r.put('/settings', h(async (req, res) => { const s = await studio.setSettings(req.body, { by: by(req) }); log(req, 'email.studio.settings', 'settings', s); res.json(s); }));
  // Templates
  r.get('/templates', h(async (req, res) => { res.json(await studio.listTemplates({ archived: req.query.archived === '1' })); }));
  r.post('/templates', h(async (req, res) => { const out = await studio.createTemplate(req.body, { by: by(req) }); log(req, 'email.template.create', out.template.templateId, { name: out.template.name }); res.status(201).json(out); }));
  r.get('/templates/:id', h(async (req, res) => {
    const t = await studio.getTemplate(req.params.id);
    if (!t) return res.status(404).json({ error: 'Template not found.', code: 'NOT_FOUND' });
    res.json({ template: t });
  }));
  r.get('/templates/:id/versions/:v', h(async (req, res) => {
    const t = await studio.templateVersion(req.params.id, req.params.v);
    if (!t) return res.status(404).json({ error: 'Version not found.', code: 'NOT_FOUND' });
    res.json({ version: t });
  }));
  r.put('/templates/:id', h(async (req, res) => { const out = await studio.updateTemplate(req.params.id, req.body, { by: by(req) }); log(req, 'email.template.save', req.params.id, { version: out.template.version }); res.json(out); }));
  r.post('/templates/:id/duplicate', h(async (req, res) => {
    const out = await studio.createTemplate({ fromTemplate: req.params.id, name: req.body && req.body.name }, { by: by(req) });
    log(req, 'email.template.duplicate', out.template.templateId, { from: req.params.id });
    res.status(201).json(out);
  }));
  r.post('/templates/:id/archive', h(async (req, res) => { const t = await studio.setTemplateStatus(req.params.id, 'archived', { by: by(req) }); log(req, 'email.template.archive', req.params.id, {}); res.json({ template: t }); }));
  r.post('/templates/:id/unarchive', h(async (req, res) => { const t = await studio.setTemplateStatus(req.params.id, 'active', { by: by(req) }); log(req, 'email.template.unarchive', req.params.id, {}); res.json({ template: t }); }));
  // Compose
  r.post('/check', h(async (req, res) => {
    const prep = await studio.prepare(req.body, { forSend: req.body && req.body.forSend !== false });
    res.json({ ok: true, category: prep.category, uses: prep.uses, warnings: prep.warnings });
  }));
  r.post('/preview', h(async (req, res) => { res.json(await studio.preview(req.body)); }));
  r.post('/audience-count', h(async (req, res) => { res.json(await studio.audienceCount(req.body && req.body.audience, req.body && req.body.category)); }));
  r.post('/test', h(async (req, res) => { res.json(await studio.testSend(req.body, { userId: req.user.userId })); }));
  // Campaigns
  r.post('/campaigns', h(async (req, res) => {
    const out = await studio.createCampaign(req.body, { by: by(req) });
    log(req, 'email.campaign.create', out.campaign.campaignId, { audience: out.campaign.audience, sendAt: out.campaign.sendAt, category: out.campaign.category });
    if (out.campaign.sendAt <= Date.now() + 1000) setImmediate(() => studio.tick().catch(() => {}));
    res.status(201).json(out);
  }));
  r.get('/campaigns', h(async (req, res) => { res.json({ campaigns: await studio.listCampaigns({ limit: Number(req.query.limit) || 50 }) }); }));
  r.get('/campaigns/:id', h(async (req, res) => {
    const c = await studio.getCampaign(req.params.id);
    if (!c) return res.status(404).json({ error: 'Campaign not found.', code: 'NOT_FOUND' });
    res.json({ campaign: c, report: await studio.report(c.campaignId) });
  }));
  r.post('/campaigns/:id/cancel', h(async (req, res) => { const c = await studio.cancelCampaign(req.params.id, { by: by(req) }); log(req, 'email.campaign.cancel', req.params.id, {}); res.json({ campaign: c }); }));
  // Automation rules
  r.get('/rules', h(async (req, res) => { res.json({ rules: await studio.listRules() }); }));
  r.post('/rules', h(async (req, res) => { const x = await studio.createRule(req.body, { by: by(req) }); log(req, 'email.rule.create', x.ruleId, { trigger: x.trigger, templateId: x.templateId }); res.status(201).json({ rule: x }); }));
  r.put('/rules/:id', h(async (req, res) => { const x = await studio.updateRule(req.params.id, req.body, { by: by(req) }); log(req, 'email.rule.update', x.ruleId, { enabled: x.enabled }); res.json({ rule: x }); }));
  r.delete('/rules/:id', h(async (req, res) => { const x = await studio.deleteRule(req.params.id); log(req, 'email.rule.delete', req.params.id, {}); res.json(x); }));
  r.get('/rules/:id/report', h(async (req, res) => {
    if (!RULE_ID.test(req.params.id)) return res.status(404).json({ error: 'Rule not found.', code: 'NOT_FOUND' });
    res.json({ report: await studio.report(req.params.id) });
  }));
  // Unique codes, images
  r.get('/unique-codes', h(async (req, res) => {
    if (req.query.parent) return res.json({ codes: await studio.listUniqueCodes(String(req.query.parent), { limit: Number(req.query.limit) || 500 }) });
    res.json({ summary: await studio.uniqueSummary() });
  }));
  r.get('/images/library', h(async (req, res) => { res.json({ images: await studio.imageLibrary() }); }));
  r.post('/images/import', h(async (req, res) => {
    const b = req.body || {};
    const img = await studio.importImage({ source: String(b.source || ''), id: String(b.id || '') }, { by: by(req) });
    log(req, 'email.image.import', img.imageId, { source: b.source });
    res.status(201).json({ image: img });
  }));
  return r;
}

/** /r/<token> (click redirect) and /email/preview/<token> (the editor's sandboxed preview frame). */
function publicStudioRouter({ studio }) {
  const r = express.Router();
  const limiter = rateLimit({ windowMs: 60 * 1000, limit: 120, standardHeaders: 'draft-7', legacyHeaders: false, message: 'Too many requests.' });
  r.get('/r/:token', limiter, async (req, res, next) => {
    try {
      res.set({ 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Robots-Tag': 'noindex' });
      const info = studio.readClickToken(req.params.token);
      if (!info) return res.redirect(302, '/');
      await studio.recordClick(info).catch(() => {});
      return res.redirect(302, `${studio.origin() || ''}${info.path}`);
    } catch (e) { next(e); }
  });
  r.get('/email/preview/:token', limiter, async (req, res, next) => {
    try {
      const html = await studio.readPreview(req.params.token);
      res.removeHeader('X-Frame-Options');
      res.set({ 'Cache-Control': 'no-store', 'X-Robots-Tag': 'noindex', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'SAMEORIGIN',
        'Content-Security-Policy': "default-src 'none'; img-src 'self' data: https:; style-src 'unsafe-inline'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'; sandbox allow-popups" });
      if (!html) return res.status(404).type('html').send('<!doctype html><p style="font-family:sans-serif;color:#6b7280">This preview has expired. Change anything to refresh it.</p>');
      return res.type('html').send(html);
    } catch (e) { next(e); }
  });
  return r;
}

module.exports = {
  EmailStudio, StudioError, adminStudioRouter, publicStudioRouter, validateDesign, renderDesign, discountText, cleanButtonPath, cleanSitePath,
  STARTERS, VARIABLES, BUTTON_PATHS, BLOCK_TYPES, SEGMENTS, RULE_TRIGGERS, DEFAULT_SETTINGS, POSTAL_PLACEHOLDER, C, SERVICE_WHY, HARD_SUPPRESSION, emailHash, maskEmail,
};
