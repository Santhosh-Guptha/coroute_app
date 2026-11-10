/* CoRoute web admin: Marketing studio core (no DOM besides the 2D canvas context it is handed).
   A port of the app's lib/domain/marketing/** (template model, placeholders, starters, layout maths)
   and lib/presentation/admin/marketing/marketing_painter.dart, built on the JS painter mirror in
   docs/features_355/marketing_preview/render.html, so templates saved by either console render the
   same. The gateway (src/marketing_templates.js) validates the stored shape.

   Geometry: x / y = layer centre as a fraction of the canvas, w / h fractions of width / height.
   Lengths are units: 1 unit = 1 px when the canvas's short side is 1080 px. Colours '#RRGGBB(AA)'. */
(function (root) {
  'use strict';

  var LIMITS = { maxLayers: 40, maxImageLayers: 10, nameMax: 80, layerNameMax: 40, textMax: 500, couponLineMax: 160, shapeLabelMax: 40, captionMax: 1000, linkMax: 300, minSide: 200, maxSide: 4096 };
  var BRAND = { ink: '#0B0F14', night: '#141B24', teal: '#3EE0EC', deepTeal: '#0E5C63', amber: '#FFB347', paper: '#ECF1F6', white: '#FFFFFF', coral: '#FF6B5A', festive: '#FF8A00', plum: '#3B1E54' };
  var SWATCHES = [BRAND.ink, BRAND.night, BRAND.deepTeal, BRAND.teal, BRAND.amber, BRAND.festive, BRAND.coral, BRAND.plum, BRAND.paper, BRAND.white, '#22C55E', '#000000'];
  var SIZE_PRESETS = [
    { id: 'instagram_post', label: 'Square post', width: 1080, height: 1080 },
    { id: 'instagram_story', label: 'Story', width: 1080, height: 1920 },
    { id: 'whatsapp_status', label: 'WhatsApp status', width: 1080, height: 1920 },
    { id: 'banner', label: 'Banner', width: 1200, height: 628 },
  ];
  var FONTS = ['Manrope', 'sans', 'serif', 'monospace'];
  var SHAPES = ['rect', 'pill', 'circle', 'ribbon', 'star', 'burst'];
  var COUPON_STYLES = ['ticket', 'pill', 'card', 'stamp'];
  var PATTERNS = ['none', 'topo', 'road', 'dots', 'stripes', 'rings', 'chevrons'];
  var LAYER_TYPES = ['text', 'coupon', 'logo', 'shape', 'image', 'qr'];
  var TYPE_LABEL = { text: 'Text', coupon: 'Coupon', logo: 'Logo', shape: 'Badge / shape', image: 'Image', qr: 'QR code' };
  var COLOR_RE = /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/;

  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  function r4(v) { return Math.round(v * 10000) / 10000; }
  function dbl(v, def, min, max) { return typeof v === 'number' && isFinite(v) ? clamp(v, min, max) : def; }
  function weight(v, def) { return typeof v === 'number' && isFinite(v) ? clamp(Math.round(v / 100) * 100, 100, 900) : def; }
  function str(v, def, max) { return typeof v === 'string' ? v.slice(0, max) : def; }
  function oneOf(v, list, def) { return list.indexOf(v) >= 0 ? v : def; }
  function color(v, def) { return typeof v === 'string' && COLOR_RE.test(v) ? v.toUpperCase() : def; }
  function sizeOfPreset(id) { for (var i = 0; i < SIZE_PRESETS.length; i++) if (SIZE_PRESETS[i].id === id) return SIZE_PRESETS[i]; return null; }

  // ------------------------------------------------------------------ model
  function cleanSize(raw) {
    var m = raw && typeof raw === 'object' ? raw : {};
    var p = sizeOfPreset(m.preset || 'instagram_post');
    if (p) return { preset: p.id, width: p.width, height: p.height };
    var w = typeof m.width === 'number' ? Math.round(m.width) : 1080;
    var h = typeof m.height === 'number' ? Math.round(m.height) : 1080;
    return { preset: 'custom', width: clamp(w, LIMITS.minSide, LIMITS.maxSide), height: clamp(h, LIMITS.minSide, LIMITS.maxSide) };
  }
  function cleanBackground(raw) {
    var m = raw && typeof raw === 'object' ? raw : {};
    var cs = Array.isArray(m.colors) ? m.colors.map(function (c) { return color(c, BRAND.ink); }) : [];
    return {
      kind: oneOf(m.kind, ['solid', 'gradient', 'image'], 'solid'),
      color: color(m.color, BRAND.ink),
      colors: cs.length >= 2 ? cs.slice(0, 4) : [BRAND.ink, BRAND.deepTeal],
      angle: dbl(m.angle, 135, 0, 360),
      imageId: typeof m.imageId === 'string' && m.imageId ? m.imageId : null,
      imageFit: oneOf(m.imageFit, ['cover', 'contain'], 'cover'),
      pattern: oneOf(m.pattern, PATTERNS, 'none'),
      patternColor: color(m.patternColor, BRAND.teal),
      patternOpacity: dbl(m.patternOpacity, 0.12, 0, 1),
      overlay: color(m.overlay, null),
    };
  }
  function cleanShadow(raw) {
    if (!raw || typeof raw !== 'object') return null;
    return { color: color(raw.color, '#00000080'), blur: dbl(raw.blur, 12, 0, 100), dx: dbl(raw.dx, 0, -100, 100), dy: dbl(raw.dy, 4, -100, 100) };
  }

  /** A layer with every field of its type filled in (lenient, like MkLayer.fromJson). */
  function cleanLayer(raw) {
    var m = raw && typeof raw === 'object' ? raw : {};
    var type = oneOf(m.type, LAYER_TYPES, 'text');
    var l = {
      id: typeof m.id === 'string' && /^[A-Za-z0-9_-]{1,40}$/.test(m.id) ? m.id : 'l' + Math.random().toString(36).slice(2, 9),
      type: type,
      name: str(m.name, '', LIMITS.layerNameMax),
      x: dbl(m.x, 0.5, -0.5, 1.5), y: dbl(m.y, 0.5, -0.5, 1.5), w: dbl(m.w, 0.5, 0.005, 3), h: dbl(m.h, 0.2, 0.005, 3),
      rotation: dbl(m.rotation, 0, -360, 360), opacity: dbl(m.opacity, 1, 0, 1), hidden: m.hidden === true, locked: m.locked === true,
    };
    switch (type) {
      case 'text':
        l.text = str(m.text, '', LIMITS.textMax); l.font = oneOf(m.font, FONTS, 'Manrope'); l.size = dbl(m.size, 64, 4, 600);
        l.weight = weight(m.weight, 700); l.color = color(m.color, BRAND.white); l.align = oneOf(m.align, ['left', 'center', 'right'], 'center');
        l.letterSpacing = dbl(m.letterSpacing, 0, -20, 100); l.lineHeight = dbl(m.lineHeight, 1.15, 0.7, 3); l.shadow = cleanShadow(m.shadow);
        l.uppercase = m.uppercase === true; l.italic = m.italic === true; l.fit = oneOf(m.fit, ['none', 'shrink'], 'shrink');
        break;
      case 'coupon':
        l.style = oneOf(m.style, COUPON_STYLES, 'ticket'); l.fill = color(m.fill, BRAND.white); l.textColor = color(m.textColor, BRAND.ink);
        l.accent = color(m.accent, BRAND.amber); l.font = oneOf(m.font, FONTS, 'Manrope');
        l.headline = str(m.headline, '{discount}', LIMITS.couponLineMax); l.codeLine = str(m.codeLine, 'Use code {code}', LIMITS.couponLineMax);
        l.footer = str(m.footer, 'Valid till {validUntil} · {plan}', LIMITS.couponLineMax);
        break;
      case 'logo':
        l.variant = oneOf(m.variant, ['mark', 'wordmark'], 'wordmark'); l.color = color(m.color, BRAND.paper);
        break;
      case 'shape':
        l.shape = oneOf(m.shape, SHAPES, 'rect'); l.fill = color(m.fill, BRAND.amber); l.stroke = color(m.stroke, null);
        l.strokeWidth = dbl(m.strokeWidth, 0, 0, 60); l.radius = dbl(m.radius, 24, 0, 500); l.label = str(m.label, '', LIMITS.shapeLabelMax);
        l.labelColor = color(m.labelColor, BRAND.ink); l.labelSize = dbl(m.labelSize, 40, 4, 300); l.font = oneOf(m.font, FONTS, 'Manrope'); l.weight = weight(m.weight, 800);
        break;
      case 'image':
        l.imageId = typeof m.imageId === 'string' && m.imageId ? m.imageId : null; l.fit = oneOf(m.fit, ['cover', 'contain'], 'cover'); l.radius = dbl(m.radius, 0, 0, 500);
        break;
      case 'qr':
        l.data = str(m.data, '{link}', LIMITS.linkMax); l.color = color(m.color, BRAND.ink); l.background = color(m.background, BRAND.white);
        break;
    }
    return l;
  }

  var TYPE_FIELDS = {
    text: ['text', 'font', 'size', 'weight', 'color', 'align', 'letterSpacing', 'lineHeight', 'shadow', 'uppercase', 'italic', 'fit'],
    coupon: ['style', 'fill', 'textColor', 'accent', 'font', 'headline', 'codeLine', 'footer'],
    logo: ['variant', 'color'],
    shape: ['shape', 'fill', 'stroke', 'strokeWidth', 'radius', 'label', 'labelColor', 'labelSize', 'font', 'weight'],
    image: ['imageId', 'fit', 'radius'],
    qr: ['data', 'color', 'background'],
  };
  function layerToJson(l) {
    var o = { id: l.id, type: l.type };
    if (l.name) o.name = l.name;
    ['x', 'y', 'w', 'h', 'rotation', 'opacity'].forEach(function (k) { o[k] = r4(l[k]); });
    o.hidden = !!l.hidden; o.locked = !!l.locked;
    TYPE_FIELDS[l.type].forEach(function (k) { o[k] = typeof l[k] === 'number' && k !== 'weight' ? r4(l[k]) : (l[k] === undefined ? null : l[k]); });
    return o;
  }

  /** A full template object (editor state) from stored / server JSON. Keeps id, coupon view, timestamps. */
  function cleanTemplate(raw) {
    var m = raw && typeof raw === 'object' ? raw : {};
    var code = typeof m.couponCode === 'string' ? m.couponCode.trim().toUpperCase() : '';
    return {
      id: typeof m.id === 'string' && m.id ? m.id : null,
      name: str(m.name, 'Untitled', LIMITS.nameMax),
      status: oneOf(m.status, ['active', 'archived'], 'active'),
      size: cleanSize(m.size),
      background: cleanBackground(m.background),
      couponCode: code || null,
      link: str(m.link, '', LIMITS.linkMax),
      caption: str(m.caption, '', LIMITS.captionMax),
      layers: (Array.isArray(m.layers) ? m.layers : []).slice(0, LIMITS.maxLayers).map(cleanLayer),
      updatedAt: typeof m.updatedAt === 'number' ? m.updatedAt : null,
      updatedBy: m.updatedBy || null,
      coupon: m.coupon && typeof m.coupon === 'object' ? m.coupon : null,
    };
  }
  /** What the gateway stores (POST / PUT body; no id, timestamps or coupon view). */
  function templateToJson(t) {
    var bg = t.background;
    var b = { kind: bg.kind, color: bg.color, angle: r4(bg.angle), imageFit: bg.imageFit, pattern: bg.pattern, patternColor: bg.patternColor, patternOpacity: r4(bg.patternOpacity) };
    if (bg.kind === 'gradient') b.colors = bg.colors.slice(0, 4);
    if (bg.kind === 'image' && bg.imageId) b.imageId = bg.imageId;
    if (bg.overlay) b.overlay = bg.overlay;
    return {
      version: 1, name: t.name, status: t.status, size: { preset: t.size.preset, width: t.size.width, height: t.size.height },
      background: b, couponCode: t.couponCode || null, link: t.link || '', caption: t.caption || '', layers: t.layers.map(layerToJson),
    };
  }
  function copyTemplate(t) { var c = cleanTemplate(JSON.parse(JSON.stringify(templateToJson(t)))); c.id = t.id; c.coupon = t.coupon; c.updatedAt = t.updatedAt; c.updatedBy = t.updatedBy; return c; }

  function nextLayerId(t, prefix) {
    var n = t.layers.length + 1;
    var taken = function (id) { return t.layers.some(function (l) { return l.id === id; }); };
    while (taken(prefix + n)) n++;
    return prefix + n;
  }

  /** New layers with brand-safe defaults (MkLayer.newText / newCoupon / ...). */
  var newLayer = {
    text: function (id, text, y) { return cleanLayer({ id: id, type: 'text', text: text || 'Your headline', x: 0.5, y: y === undefined ? 0.3 : y, w: 0.84, h: 0.14, size: 88, weight: 800, color: BRAND.white }); },
    coupon: function (id) { return cleanLayer({ id: id, type: 'coupon', x: 0.5, y: 0.62, w: 0.8, h: 0.28, fill: BRAND.white, textColor: BRAND.ink, accent: BRAND.amber }); },
    logo: function (id) { return cleanLayer({ id: id, type: 'logo', x: 0.5, y: 0.92, w: 0.34, h: 0.07, color: BRAND.paper }); },
    shape: function (id, shape, label) {
      var round = shape === 'circle' || shape === 'star' || shape === 'burst';
      return cleanLayer({ id: id, type: 'shape', shape: shape, label: label || '', x: round ? 0.82 : 0.5, y: round ? 0.14 : 0.5,
        w: round ? 0.24 : (shape === 'ribbon' ? 0.6 : 0.5), h: round ? 0.24 : (shape === 'ribbon' ? 0.09 : 0.12),
        fill: BRAND.amber, labelColor: BRAND.ink, labelSize: round ? 46 : 40, weight: 800, radius: shape === 'rect' ? 24 : 0 });
    },
    image: function (id, imageId) { return cleanLayer({ id: id, type: 'image', imageId: imageId, x: 0.5, y: 0.45, w: 0.6, h: 0.4, radius: 24 }); },
    qr: function (id) { return cleanLayer({ id: id, type: 'qr', x: 0.86, y: 0.86, w: 0.18, h: 0.18, color: BRAND.ink, background: BRAND.white }); },
  };

  function keepsAspect(l) { return l.type === 'logo' || l.type === 'qr' || l.type === 'image' || (l.type === 'shape' && (l.shape === 'circle' || l.shape === 'star' || l.shape === 'burst')); }

  function displayName(l) {
    if (l.name && l.name.trim()) return l.name.trim();
    if (l.type === 'text') { var t = String(l.text || '').replace(/\n/g, ' ').trim(); return t ? (t.length > 24 ? t.slice(0, 24) + '…' : t) : 'Text'; }
    if (l.type === 'shape') return l.label ? l.label + ' (' + l.shape + ')' : 'Shape: ' + l.shape;
    if (l.type === 'logo') return l.variant === 'mark' ? 'Logo mark' : 'Logo';
    return TYPE_LABEL[l.type];
  }

  function imageIds(t) {
    var ids = [];
    if (t.background.kind === 'image' && t.background.imageId) ids.push(t.background.imageId);
    t.layers.forEach(function (l) { if (l.type === 'image' && l.imageId && ids.indexOf(l.imageId) < 0) ids.push(l.imageId); });
    return ids;
  }

  function validate(t) {
    var out = [];
    if (!t.name.trim()) out.push('Give the template a name.');
    if (t.layers.length > LIMITS.maxLayers) out.push('At most ' + LIMITS.maxLayers + ' layers.');
    if (t.layers.filter(function (l) { return l.type === 'image'; }).length > LIMITS.maxImageLayers) out.push('At most ' + LIMITS.maxImageLayers + ' image layers.');
    if (t.caption.length > LIMITS.captionMax) out.push('The caption is longer than ' + LIMITS.captionMax + ' characters.');
    if (t.background.kind === 'image' && !t.background.imageId) out.push('Pick a background image or another background.');
    var seen = {};
    t.layers.forEach(function (l) {
      if (seen[l.id]) out.push('Two layers share the id ' + l.id + '.');
      seen[l.id] = true;
      if (l.type === 'image' && !l.imageId) out.push('An image layer has no image.');
    });
    return out;
  }

  // ------------------------------------------------------------------ placeholders
  var PLACEHOLDERS = ['code', 'discount', 'validUntil', 'plan', 'name', 'cap', 'link'];
  var SAMPLE = { code: 'RIDE50', discount: '50% off', validUntil: '31 Dec 2026', plan: 'Small Group plan', name: 'Sample offer', cap: 'up to ₹100' };
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  var PLAN_FALLBACK = { group_small: 'Small Group', group_large: 'Large Group', individual: 'Small Group', community: 'Community' };

  function substitute(text, values) {
    return String(text || '').replace(/\{([A-Za-z]+)\}/g, function (m, k) { return PLACEHOLDERS.indexOf(k) >= 0 && values && values[k] !== undefined && values[k] !== null ? String(values[k]) : m; });
  }
  function usedIn(text) { var out = []; String(text || '').replace(/\{([A-Za-z]+)\}/g, function (m, k) { if (PLACEHOLDERS.indexOf(k) >= 0 && out.indexOf(k) < 0) out.push(k); return m; }); return out; }
  function templateNeedsCoupon(t) {
    var coupon = function (s) { return usedIn(s).some(function (n) { return n !== 'link'; }); };
    if (coupon(t.caption)) return true;
    return t.layers.some(function (l) {
      if (l.hidden) return false;
      if (l.type === 'coupon') return true;
      if (l.type === 'text') return coupon(l.text);
      if (l.type === 'shape') return coupon(l.label);
      if (l.type === 'qr') return coupon(l.data);
      return false;
    });
  }
  /**
   * The link for {link} and the QR code: the template's own link (may hold {code}), otherwise
   * <origin>/plans?coupon=CODE (the website's plans page with the coupon filled in), or <origin>/plans
   * when no coupon is bound. Same rule as the gateway's couponLink (src/web_shop.js plansLink).
   */
  function resolveLink(linkTemplate, origin, code) {
    var base = String(origin || '').replace(/\/+$/, '');
    var c = String(code || '').trim();
    var t = String(linkTemplate || '').trim();
    if (!t) return c ? base + '/plans?coupon=' + encodeURIComponent(c) : base + '/plans';
    return t.split('{code}').join(encodeURIComponent(c));
  }
  function inr(v) { return '₹' + Number(v).toLocaleString('en-IN', { maximumFractionDigits: 2 }); }
  function discountText(type, value) {
    var v = Number(value) || 0;
    if (type === 'free' || (type === 'percentage' && v >= 100)) return 'Free';
    if (type === 'fixed') return inr(v) + ' off';
    return (Math.round(v * 100) / 100) + '% off';
  }
  function formatDate(ms) {
    if (!ms || ms <= 0) return '';
    var d = new Date(Number(ms) + 330 * 60000);
    return d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCFullYear();
  }
  function planText(tiers, labels) {
    labels = labels || {};
    if (!tiers || !tiers.length || tiers.indexOf('all') >= 0) return 'all plans';
    var names = [];
    tiers.forEach(function (t) { var n = labels[t] || PLAN_FALLBACK[t] || t; if (names.indexOf(n) < 0) names.push(n); });
    return names.length === 1 ? names[0] + ' plan' : names.slice(0, -1).join(', ') + ' & ' + names[names.length - 1] + ' plans';
  }
  function couponValues(c, labels) {
    var local = {
      code: c.code, discount: discountText(c.discountType, c.discountValue), validUntil: formatDate(c.expiresAt),
      plan: planText(c.plans || ['all'], labels), name: c.name || c.code,
      cap: c.discountType === 'percentage' && Number(c.maxDiscountCap) > 0 ? 'up to ' + inr(c.maxDiscountCap) : '',
    };
    var server = c.placeholders || {};
    var out = {};
    Object.keys(local).forEach(function (k) { out[k] = server[k] !== undefined && server[k] !== null ? server[k] : local[k]; });
    return out;
  }
  /** Values the painter uses: the bound coupon's (server placeholders first) or the samples, plus the link. */
  function valuesFor(t, origin, labels) {
    var c = t.coupon;
    var code = (c && c.code) || t.couponCode;
    var v = c && !c.missing ? couponValues(c, labels) : Object.assign({}, SAMPLE);
    v.link = resolveLink(t.link, origin, code);
    return v;
  }
  function autoCaption(v, bound) {
    if (!bound) return 'Ride together with CoRoute: live group tracking, intercom and SOS for every ride.\nSee the plans: ' + (v.link || '');
    var cap = v.cap ? ' (' + v.cap + ')' : '';
    var until = v.validUntil ? ' Valid till ' + v.validUntil + '.' : '';
    return 'Ride together for less: ' + v.discount + cap + ' on the CoRoute ' + v.plan + '. Use code ' + v.code + ' at checkout.' + until + '\nGet it here: ' + v.link;
  }

  // ------------------------------------------------------------------ starters
  function tpl(o) { return cleanTemplate(o); }
  function L(o) { return o; }
  var STARTERS = [
    { id: 'festive', title: 'Festive offer', description: 'Square post with a coupon ticket and a LIMITED badge.', build: function () {
      return tpl({ name: 'Festive offer', size: { preset: 'instagram_post' },
        background: { kind: 'gradient', colors: [BRAND.plum, '#B4233C', BRAND.festive], angle: 120, pattern: 'rings', patternColor: BRAND.amber, patternOpacity: 0.16 },
        layers: [
          L({ id: 'kicker', type: 'text', text: 'Festive season', uppercase: true, letterSpacing: 10, size: 38, weight: 700, color: BRAND.amber, x: 0.42, y: 0.1, w: 0.7, h: 0.06, align: 'left' }),
          L({ id: 'title', type: 'text', text: 'Ride together,\nsave more', size: 104, weight: 800, color: BRAND.white, align: 'left', lineHeight: 1.05, x: 0.42, y: 0.27, w: 0.76, h: 0.24, shadow: { color: '#00000066', blur: 20, dx: 0, dy: 6 } }),
          Object.assign(layerToJson(newLayer.shape('badge', 'burst', 'LIMITED')), { x: 0.84, y: 0.16, w: 0.24, h: 0.24, rotation: 12, labelSize: 40 }),
          L({ id: 'coupon', type: 'coupon', style: 'ticket', x: 0.5, y: 0.62, w: 0.84, h: 0.3, fill: BRAND.white, textColor: BRAND.ink, accent: BRAND.festive }),
          Object.assign(layerToJson(newLayer.logo('logo')), { x: 0.27, y: 0.91, w: 0.38, h: 0.07 }),
          Object.assign(layerToJson(newLayer.qr('qr')), { x: 0.88, y: 0.89, w: 0.15, h: 0.15 }),
        ] });
    } },
    { id: 'group_plan', title: 'Group ride plan discount', description: 'Plan discount for ride groups, on the road pattern.', build: function () {
      return tpl({ name: 'Group ride plan discount', size: { preset: 'instagram_post' },
        background: { kind: 'gradient', colors: [BRAND.ink, BRAND.deepTeal], angle: 90, pattern: 'road', patternColor: BRAND.teal, patternOpacity: 0.16 },
        layers: [
          L({ id: 'kicker', type: 'text', text: 'Group rides', uppercase: true, letterSpacing: 12, size: 36, weight: 700, color: BRAND.teal, x: 0.5, y: 0.1, w: 0.8, h: 0.06 }),
          L({ id: 'title', type: 'text', text: '{discount} for your\nwhole ride group', size: 96, weight: 800, color: BRAND.white, x: 0.5, y: 0.25, w: 0.88, h: 0.2, lineHeight: 1.05 }),
          L({ id: 'sub', type: 'text', text: 'On the {plan}: live tracking, intercom and SOS for everyone.', size: 38, weight: 500, color: BRAND.paper, x: 0.5, y: 0.4, w: 0.8, h: 0.09 }),
          L({ id: 'coupon', type: 'coupon', style: 'card', x: 0.5, y: 0.64, w: 0.78, h: 0.27, fill: BRAND.paper, textColor: BRAND.ink, accent: BRAND.teal }),
          Object.assign(layerToJson(newLayer.shape('new', 'pill', 'NEW')), { x: 0.84, y: 0.5, w: 0.17, h: 0.065, fill: BRAND.amber, labelSize: 34, rotation: -8 }),
          Object.assign(layerToJson(newLayer.logo('logo')), { x: 0.5, y: 0.91, w: 0.36, h: 0.065 }),
        ] });
    } },
    { id: 'first_ride', title: 'First ride free', description: 'Story with a big headline and a QR code.', build: function () {
      return tpl({ name: 'First ride free', size: { preset: 'instagram_story' },
        background: { kind: 'solid', color: BRAND.ink, pattern: 'topo', patternColor: BRAND.teal, patternOpacity: 0.12 },
        layers: [
          Object.assign(layerToJson(newLayer.logo('logo')), { x: 0.5, y: 0.07, w: 0.42, h: 0.045 }),
          L({ id: 'title', type: 'text', text: 'First ride\nfree', size: 170, weight: 800, color: BRAND.white, x: 0.5, y: 0.27, w: 0.9, h: 0.2, lineHeight: 1.0, shadow: { color: '#3EE0EC80', blur: 40, dx: 0, dy: 0 } }),
          L({ id: 'sub', type: 'text', text: 'Plan your group ride, track everyone live, talk on the go.', size: 44, weight: 500, color: BRAND.paper, x: 0.5, y: 0.42, w: 0.8, h: 0.08 }),
          L({ id: 'coupon', type: 'coupon', style: 'pill', x: 0.5, y: 0.56, w: 0.84, h: 0.11, fill: BRAND.teal, textColor: BRAND.ink, accent: BRAND.ink, headline: '{discount}', codeLine: 'Use code {code}', footer: 'Till {validUntil}' }),
          Object.assign(layerToJson(newLayer.qr('qr')), { x: 0.5, y: 0.76, w: 0.3, h: 0.169 }),
          L({ id: 'scan', type: 'text', text: 'Scan to see the plans', size: 40, weight: 700, color: BRAND.teal, x: 0.5, y: 0.88, w: 0.7, h: 0.035 }),
        ] });
    } },
    { id: 'referral', title: 'Referral', description: 'Light post: bring your riding crew.', build: function () {
      return tpl({ name: 'Referral', size: { preset: 'instagram_post' },
        background: { kind: 'solid', color: BRAND.paper, pattern: 'dots', patternColor: BRAND.ink, patternOpacity: 0.07 },
        layers: [
          Object.assign(layerToJson(newLayer.shape('blob', 'circle', '')), { x: 0.9, y: 0.08, w: 0.5, h: 0.5, fill: '#3EE0EC33' }),
          L({ id: 'title', type: 'text', text: 'Bring your\nriding crew', size: 100, weight: 800, color: BRAND.ink, align: 'left', x: 0.45, y: 0.23, w: 0.8, h: 0.24, lineHeight: 1.05 }),
          L({ id: 'sub', type: 'text', text: 'Share code {code}: your friends get {discount} on CoRoute.', size: 40, weight: 600, color: BRAND.night, align: 'left', x: 0.45, y: 0.41, w: 0.8, h: 0.09 }),
          L({ id: 'coupon', type: 'coupon', style: 'stamp', x: 0.5, y: 0.66, w: 0.8, h: 0.27, fill: BRAND.ink, textColor: BRAND.paper, accent: BRAND.teal }),
          Object.assign(layerToJson(newLayer.logo('logo')), { x: 0.27, y: 0.91, w: 0.36, h: 0.065, color: BRAND.ink }),
        ] });
    } },
    { id: 'flash_sale', title: 'Weekend flash sale', description: 'Wide banner with a ribbon and the code.', build: function () {
      return tpl({ name: 'Weekend flash sale', size: { preset: 'banner' },
        background: { kind: 'gradient', colors: [BRAND.coral, BRAND.amber], angle: 0, pattern: 'stripes', patternColor: BRAND.white, patternOpacity: 0.12 },
        layers: [
          Object.assign(layerToJson(newLayer.shape('ribbon', 'ribbon', 'FLASH SALE')), { x: 0.24, y: 0.17, w: 0.38, h: 0.15, fill: BRAND.ink, labelColor: BRAND.amber, labelSize: 44 }),
          L({ id: 'title', type: 'text', text: '{discount}\nthis weekend', size: 92, weight: 800, color: BRAND.ink, align: 'left', x: 0.3, y: 0.5, w: 0.52, h: 0.42, lineHeight: 1.0 }),
          L({ id: 'coupon', type: 'coupon', style: 'ticket', x: 0.76, y: 0.47, w: 0.4, h: 0.56, fill: BRAND.white, textColor: BRAND.ink, accent: BRAND.coral }),
          Object.assign(layerToJson(newLayer.logo('logo')), { x: 0.17, y: 0.87, w: 0.26, h: 0.1, color: BRAND.ink }),
        ] });
    } },
  ];
  function blank(size) {
    return tpl({ name: 'Untitled offer', size: size || { preset: 'instagram_post' },
      background: { kind: 'gradient', colors: [BRAND.ink, BRAND.deepTeal], pattern: 'topo', patternOpacity: 0.1 },
      layers: [layerToJson(newLayer.text('title', 'Your headline here', 0.3)), layerToJson(newLayer.coupon('coupon')), layerToJson(newLayer.logo('logo'))] });
  }

  // ------------------------------------------------------------------ layout
  function unitScale(w, h) { return Math.min(w, h) / 1080; }
  function boxOf(l, W, H) { return { cx: l.x * W, cy: l.y * H, w: l.w * W, h: l.h * H, angle: l.rotation * Math.PI / 180 }; }
  function boxContains(b, px, py, slop) {
    slop = slop || 0;
    var dx = px - b.cx; var dy = py - b.cy; var c = Math.cos(-b.angle); var s = Math.sin(-b.angle);
    var lx = dx * c - dy * s; var ly = dx * s + dy * c;
    return Math.abs(lx) <= b.w / 2 + slop && Math.abs(ly) <= b.h / 2 + slop;
  }
  function hitTest(t, px, py, slop) {
    for (var i = t.layers.length - 1; i >= 0; i--) {
      var l = t.layers[i];
      if (l.hidden) continue;
      if (boxContains(boxOf(l, t.size.width, t.size.height), px, py, slop)) return i;
    }
    return -1;
  }
  function snapRotation(deg, threshold) {
    threshold = threshold === undefined ? 4 : threshold;
    var d = deg % 360; if (d > 180) d -= 360; if (d <= -180) d += 360;
    var nearest = Math.round(d / 45) * 45;
    return Math.abs(d - nearest) <= threshold ? (nearest === -180 ? 180 : nearest) : d;
  }
  /** The template laid out for another canvas size (mkRetarget): centres kept, aspect layers keep their shape. */
  function retarget(t, size) {
    var out = copyTemplate(t); out.size = cleanSize(size);
    var w0 = t.size.width; var h0 = t.size.height; var w1 = out.size.width; var h1 = out.size.height;
    var k = unitScale(w1, h1) / unitScale(w0, h0);
    out.layers.forEach(function (l) {
      if (keepsAspect(l)) { l.w = clamp(l.w * w0 * k / w1, 0.005, 3); l.h = clamp(l.h * h0 * k / h1, 0.005, 3); }
      else l.h = clamp(l.h * h0 * k / h1, 0.005, 3);
      if (l.w <= 1) l.x = clamp(l.x, l.w / 2, 1 - l.w / 2);
      if (l.h <= 1) l.y = clamp(l.y, l.h / 2, 1 - l.h / 2);
    });
    return out;
  }
  /** Undo / redo snapshots of the template JSON (MkHistory). */
  function History(max) { this.max = max || 80; this.undoStack = []; this.redoStack = []; }
  History.prototype.record = function (t) {
    var s = JSON.stringify(templateToJson(t));
    if (this.undoStack.length && this.undoStack[this.undoStack.length - 1] === s) return;
    this.undoStack.push(s); if (this.undoStack.length > this.max) this.undoStack.shift();
    this.redoStack = [];
  };
  History.prototype.restore = function (s, cur) { var t = cleanTemplate(JSON.parse(s)); t.id = cur.id; t.coupon = cur.coupon; t.updatedAt = cur.updatedAt; t.updatedBy = cur.updatedBy; return t; };
  History.prototype.undo = function (cur) { if (!this.undoStack.length) return null; this.redoStack.push(JSON.stringify(templateToJson(cur))); return this.restore(this.undoStack.pop(), cur); };
  History.prototype.redo = function (cur) { if (!this.redoStack.length) return null; this.undoStack.push(JSON.stringify(templateToJson(cur))); return this.restore(this.redoStack.pop(), cur); };
  History.prototype.clear = function () { this.undoStack = []; this.redoStack = []; };

  // ------------------------------------------------------------------ painter
  function rgba(hex) {
    if (!hex) return 'rgba(0,0,0,0)';
    var r = parseInt(hex.slice(1, 3), 16); var g = parseInt(hex.slice(3, 5), 16); var b = parseInt(hex.slice(5, 7), 16);
    var a = hex.length > 7 ? parseInt(hex.slice(7, 9), 16) / 255 : 1;
    return 'rgba(' + r + ',' + g + ',' + b + ',' + a + ')';
  }
  function withAlpha(hex, o) { return rgba(hex.slice(0, 7) + Math.round(clamp(o, 0, 1) * 255).toString(16).padStart(2, '0')); }
  function alphaOf(hex) { return hex && hex.length > 7 ? parseInt(hex.slice(7, 9), 16) / 255 : 1; }
  function fam(f) { return f === 'Manrope' ? 'Manrope, sans-serif' : (f === 'serif' ? 'Georgia, serif' : (f === 'monospace' ? 'ui-monospace, Menlo, monospace' : 'system-ui, sans-serif')); }
  function setFont(ctx, o, s) { ctx.font = (o.italic ? 'italic ' : '') + o.weight + ' ' + s + 'px ' + fam(o.font); if ('letterSpacing' in ctx) ctx.letterSpacing = ((o.ls || 0) * s / o.size) + 'px'; }

  function wrapLines(ctx, text, maxW) {
    var out = [];
    text.split('\n').forEach(function (para) {
      var line = '';
      para.split(/\s+/).forEach(function (w) {
        if (!w) return;
        var t = line ? line + ' ' + w : w;
        if (ctx.measureText(t).width > maxW && line) { out.push(line); line = w; } else line = t;
      });
      out.push(line);
    });
    return out;
  }
  /** Lines and size of text shrunk (with o.shrink) until it fits the box (TextPainter _fitted). */
  function fitText(ctx, text, box, o) {
    var s = o.size; var lines; var lh;
    for (var g = 0; g < 60; g++) {
      setFont(ctx, o, s);
      lines = o.maxLines === 1 ? [text.replace(/\n/g, ' ')] : wrapLines(ctx, text, box.w);
      lh = s * (o.lh || 1.15);
      var widest = 0;
      text.split(/\s+/).forEach(function (w) { if (w) widest = Math.max(widest, ctx.measureText(w).width); });
      var tooWide = o.maxLines === 1 ? ctx.measureText(lines[0]).width > box.w : widest > box.w;
      var fits = lines.length * lh <= box.h + 0.5 && !tooWide && (!o.maxLines || lines.length <= o.maxLines);
      if (!o.shrink || fits || s <= 4) break;
      s *= 0.93;
    }
    if (o.maxLines && lines.length > o.maxLines) { lines = lines.slice(0, o.maxLines); lines[o.maxLines - 1] += '…'; }
    var width = 0;
    lines.forEach(function (l) { width = Math.max(width, ctx.measureText(l).width); });
    return { lines: lines, lh: lh, s: s, o: o, width: width };
  }
  function drawLines(ctx, f, box, align, fill, shadow) {
    setFont(ctx, f.o, f.s);
    ctx.fillStyle = fill; ctx.textBaseline = 'middle'; ctx.textAlign = align;
    if (shadow) { ctx.shadowColor = shadow.c; ctx.shadowBlur = shadow.b; ctx.shadowOffsetX = shadow.dx; ctx.shadowOffsetY = shadow.dy; }
    var total = f.lines.length * f.lh; var y = box.y + (box.h - total) / 2 + f.lh / 2;
    var x = align === 'left' ? box.x : (align === 'right' ? box.x + box.w : box.x + box.w / 2);
    f.lines.forEach(function (l) { ctx.fillText(l, x, y); y += f.lh; });
    ctx.shadowColor = 'transparent'; ctx.shadowBlur = 0; ctx.shadowOffsetX = 0; ctx.shadowOffsetY = 0;
  }
  function deflate(b, d) { return { x: b.x + d, y: b.y + d, w: b.w - 2 * d, h: b.h - 2 * d }; }
  function dashed(ctx, dash, gap, stroke, width, pathFn) { ctx.save(); ctx.setLineDash([dash, gap]); ctx.strokeStyle = stroke; ctx.lineWidth = width; ctx.beginPath(); pathFn(); ctx.stroke(); ctx.restore(); }
  function rr(ctx, x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, w, h, Math.max(0, Math.min(r, w / 2, h / 2))); }

  function drawMark(ctx, x, y, side) {
    ctx.save(); ctx.translate(x, y); ctx.scale(side / 100, side / 100);
    ctx.fillStyle = BRAND.ink; rr(ctx, 0, 0, 100, 100, 22); ctx.fill();
    var road = function () { ctx.moveTo(20, 82); ctx.bezierCurveTo(20, 36, 80, 64, 80, 18); };
    ctx.strokeStyle = BRAND.teal; ctx.lineWidth = 15; ctx.lineCap = 'round'; ctx.beginPath(); road(); ctx.stroke();
    ctx.lineCap = 'butt'; dashed(ctx, 4.5, 4.5, BRAND.ink, 2.2, road);
    [[21.1, 72.3, BRAND.paper], [50, 50, BRAND.paper], [78.9, 27.7, BRAND.amber]].forEach(function (p) {
      ctx.fillStyle = BRAND.ink; ctx.beginPath(); ctx.arc(p[0], p[1], 9.4, 0, 7); ctx.fill();
      ctx.fillStyle = p[2]; ctx.beginPath(); ctx.arc(p[0], p[1], 7.2, 0, 7); ctx.fill();
    });
    ctx.restore();
  }

  function drawImage(ctx, img, box, fit, radius) {
    ctx.save();
    if (radius > 0) { rr(ctx, box.x, box.y, box.w, box.h, radius); ctx.clip(); }
    if (!img) {
      ctx.fillStyle = 'rgba(255,255,255,0.2)'; ctx.fillRect(box.x, box.y, box.w, box.h);
      ctx.strokeStyle = 'rgba(255,255,255,0.4)'; ctx.lineWidth = Math.max(1, Math.min(box.w, box.h) * 0.01);
      ctx.beginPath(); ctx.moveTo(box.x, box.y); ctx.lineTo(box.x + box.w, box.y + box.h); ctx.moveTo(box.x + box.w, box.y); ctx.lineTo(box.x, box.y + box.h); ctx.stroke();
      ctx.restore(); return;
    }
    var iw = img.width; var ih = img.height;
    if (!radius) { ctx.beginPath(); ctx.rect(box.x, box.y, box.w, box.h); ctx.clip(); }
    var k = fit === 'contain' ? Math.min(box.w / iw, box.h / ih) : Math.max(box.w / iw, box.h / ih);
    var dw = iw * k; var dh = ih * k;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(img, box.x + (box.w - dw) / 2, box.y + (box.h - dh) / 2, dw, dh);
    ctx.restore();
  }

  function paintBackground(ctx, t, images, u) {
    var W = t.size.width; var H = t.size.height; var bg = t.background;
    ctx.fillStyle = rgba(bg.color); ctx.fillRect(0, 0, W, H);
    if (bg.kind === 'gradient' && bg.colors.length >= 2) {
      var a = bg.angle * Math.PI / 180; var dx = Math.cos(a); var dy = Math.sin(a); var half = (Math.abs(dx) * W + Math.abs(dy) * H) / 2;
      var g = ctx.createLinearGradient(W / 2 - dx * half, H / 2 - dy * half, W / 2 + dx * half, H / 2 + dy * half);
      bg.colors.forEach(function (c, i) { g.addColorStop(i / (bg.colors.length - 1), rgba(c)); });
      ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    } else if (bg.kind === 'image') {
      drawImage(ctx, images && bg.imageId ? images[bg.imageId] : null, { x: 0, y: 0, w: W, h: H }, bg.imageFit, 0);
    }
    if (bg.pattern !== 'none' && bg.patternOpacity > 0) {
      var pc = withAlpha(bg.patternColor, bg.patternOpacity * alphaOf(bg.patternColor)); var diag = Math.hypot(W, H);
      ctx.save(); ctx.strokeStyle = pc; ctx.fillStyle = pc; ctx.lineCap = 'round';
      if (bg.pattern === 'dots') { var s = 48 * u; for (var y = s / 2; y < H; y += s) for (var x = s / 2; x < W; x += s) { ctx.beginPath(); ctx.arc(x, y, 4.5 * u, 0, 7); ctx.fill(); } }
      if (bg.pattern === 'stripes') { ctx.translate(W / 2, H / 2); ctx.rotate(-Math.PI / 4); for (var sx = -diag; sx < diag; sx += 64 * u) ctx.fillRect(sx, -diag, 18 * u, diag * 2); }
      if (bg.pattern === 'rings') { ctx.lineWidth = 6 * u; for (var r = 70 * u; r < diag * 1.1; r += 64 * u) { ctx.beginPath(); ctx.arc(W * 0.88, H * 0.12, r, 0, 7); ctx.stroke(); } }
      if (bg.pattern === 'chevrons') {
        ctx.lineWidth = 8 * u; ctx.lineJoin = 'round'; var cs = 80 * u;
        for (var cy = 0; cy < H + cs; cy += cs) { ctx.beginPath(); ctx.moveTo(-cs, cy); for (var cx = -cs; cx < W + cs; cx += cs) { ctx.lineTo(cx + cs / 2, cy - cs * 0.35); ctx.lineTo(cx + cs, cy); } ctx.stroke(); }
      }
      if (bg.pattern === 'topo') {
        ctx.lineWidth = 3.2 * u;
        [[0.18, 0.82, 0], [0.92, 0.12, 1.7]].forEach(function (c) {
          for (var k = 1; k <= 14; k++) {
            ctx.beginPath();
            for (var i = 0; i <= 120; i++) {
              var th = i / 120 * 2 * Math.PI;
              var rad = k * 46 * u + 14 * u * Math.sin(3 * th + k * 0.6 + c[2]) + 9 * u * Math.sin(5 * th - k * 0.9);
              var px = W * c[0] + Math.cos(th) * rad; var py = H * c[1] + Math.sin(th) * rad;
              if (i) ctx.lineTo(px, py); else ctx.moveTo(px, py);
            }
            ctx.closePath(); ctx.stroke();
          }
        });
      }
      if (bg.pattern === 'road') {
        var road = function () { ctx.moveTo(W * 0.02, H * 1.08); ctx.bezierCurveTo(W * 0.08, H * 0.42, W * 0.92, H * 0.78, W * 1.02, -H * 0.06); };
        ctx.lineCap = 'butt'; ctx.lineWidth = 120 * u; ctx.beginPath(); road(); ctx.stroke();
        dashed(ctx, 40 * u, 34 * u, withAlpha(bg.patternColor, Math.min(1, bg.patternOpacity * 2.4)), 9 * u, road);
      }
      ctx.restore();
    }
    if (bg.overlay) { ctx.fillStyle = rgba(bg.overlay); ctx.fillRect(0, 0, W, H); }
  }

  function shapePath(ctx, l, box, u) {
    var bw = box.w; var bh = box.h;
    ctx.beginPath();
    if (l.shape === 'burst' || l.shape === 'star') {
      var n = l.shape === 'star' ? 5 : 16; var inner = l.shape === 'star' ? 0.45 : 0.8;
      for (var i = 0; i < n * 2; i++) { var a = -Math.PI / 2 + i * Math.PI / n; var k = i % 2 ? inner : 1; var x = Math.cos(a) * bw / 2 * k; var y = Math.sin(a) * bh / 2 * k; if (i) ctx.lineTo(x, y); else ctx.moveTo(x, y); }
      ctx.closePath();
    } else if (l.shape === 'circle') ctx.ellipse(0, 0, bw / 2, bh / 2, 0, 0, Math.PI * 2);
    else if (l.shape === 'pill') ctx.roundRect(box.x, box.y, bw, bh, Math.min(bw, bh) / 2);
    else if (l.shape === 'ribbon') { var d = bh * 0.38; ctx.moveTo(box.x, box.y); ctx.lineTo(box.x + bw, box.y); ctx.lineTo(box.x + bw - d, 0); ctx.lineTo(box.x + bw, box.y + bh); ctx.lineTo(box.x, box.y + bh); ctx.lineTo(box.x + d, 0); ctx.closePath(); }
    else ctx.roundRect(box.x, box.y, bw, bh, Math.min(l.radius * u, Math.min(bw, bh) / 2));
  }

  function paintCoupon(ctx, l, box, v, u) {
    var bw = box.w; var bh = box.h; var minSide = Math.min(bw, bh);
    ctx.save(); ctx.shadowColor = 'rgba(0,0,0,0.35)'; ctx.shadowBlur = minSide * 0.08; ctx.shadowOffsetY = minSide * 0.015; ctx.fillStyle = rgba(l.fill);
    if (l.style === 'pill') { rr(ctx, box.x, box.y, bw, bh, bh / 2); ctx.fill(); }
    else if (l.style === 'ticket') {
      ctx.beginPath(); ctx.rect(box.x - bw, box.y - bh, bw * 3, bh * 3);
      ctx.moveTo(box.x + bh * 0.1, 0); ctx.arc(box.x, 0, bh * 0.1, 0, 7); ctx.moveTo(box.x + bw + bh * 0.1, 0); ctx.arc(box.x + bw, 0, bh * 0.1, 0, 7);
      ctx.clip('evenodd'); rr(ctx, box.x, box.y, bw, bh, minSide * 0.09); ctx.fill();
    } else if (l.style === 'stamp') {
      ctx.beginPath(); ctx.rect(box.x - bw, box.y - bh, bw * 3, bh * 3);
      var r = minSide * 0.032; var st = r * 3.2;
      for (var x = box.x + st / 2; x < box.x + bw; x += st) { ctx.moveTo(x + r, box.y); ctx.arc(x, box.y, r, 0, 7); ctx.moveTo(x + r, box.y + bh); ctx.arc(x, box.y + bh, r, 0, 7); }
      for (var y = box.y + st / 2; y < box.y + bh; y += st) { ctx.moveTo(box.x + r, y); ctx.arc(box.x, y, r, 0, 7); ctx.moveTo(box.x + bw + r, y); ctx.arc(box.x + bw, y, r, 0, 7); }
      ctx.clip('evenodd'); ctx.fillRect(box.x, box.y, bw, bh);
    } else {
      rr(ctx, box.x, box.y, bw, bh, minSide * 0.1); ctx.fill();
      ctx.shadowColor = 'transparent'; ctx.save(); ctx.clip(); ctx.fillStyle = rgba(l.accent); ctx.fillRect(box.x, box.y, bw, bh * 0.07); ctx.restore();
    }
    ctx.restore();

    var head = substitute(l.headline, v); var code = substitute(l.codeLine, v); var foot = substitute(l.footer, v);
    var faded = withAlpha(l.textColor, 0.72);
    var chip = function (cell, f) {
      var w = Math.min(cell.w, f.width + cell.h * 0.7);
      var rc = { x: cell.x + (cell.w - w) / 2, y: cell.y + cell.h * 0.04, w: w, h: cell.h * 0.92 };
      ctx.fillStyle = withAlpha(l.accent, 0.15); rr(ctx, rc.x, rc.y, rc.w, rc.h, rc.h * 0.28); ctx.fill();
      dashed(ctx, minSide * 0.025, minSide * 0.016, rgba(l.accent), Math.max(1, minSide * 0.01), function () { ctx.roundRect(rc.x, rc.y, rc.w, rc.h, rc.h * 0.28); });
    };
    var opt = function (size, w) { return { size: size, weight: w, font: l.font, lh: 1.05, shrink: true }; };
    if (l.style === 'pill') {
      var pad = bh * 0.18; var inner = { x: box.x + pad * 2, y: box.y + pad, w: bw - pad * 4, h: bh - pad * 2 };
      var parts = [head, code, foot].filter(function (p) { return p.trim(); });
      if (!parts.length) return;
      var shares = parts.length === 3 ? [0.3, 0.42, 0.28] : (parts.length === 2 ? [0.42, 0.58] : [1]);
      var cx = inner.x;
      parts.forEach(function (p, i) {
        var cell = { x: cx, y: inner.y, w: inner.w * shares[i], h: inner.h };
        var ib = deflate(cell, cell.h * 0.08); var isH = p === head; var isC = p === code;
        var o = opt(inner.h * (isH ? 0.8 : (isC ? 0.5 : 0.4)), isH || isC ? 800 : 600); o.maxLines = 1;
        var f = fitText(ctx, p, ib, o);
        if (isC) chip(cell, f);
        drawLines(ctx, f, ib, 'center', isH || isC ? rgba(l.textColor) : faded);
        cx += cell.w;
      });
      return;
    }
    var pd = minSide * 0.11; var inn = { x: box.x + pd, y: box.y + pd, w: bw - 2 * pd, h: bh - 2 * pd };
    var hasFoot = !!foot.trim(); var hHead = inn.h * (hasFoot ? 0.42 : 0.5); var hCode = inn.h * 0.32; var gap = inn.h * 0.04;
    var yy = inn.y + (l.style === 'card' ? bh * 0.04 : 0);
    if (head.trim()) {
      var rh = { x: inn.x, y: yy, w: inn.w, h: hHead }; var oh = opt(hHead * 0.92, 800); oh.maxLines = 2;
      drawLines(ctx, fitText(ctx, head, rh, oh), rh, 'center', rgba(l.style === 'stamp' ? l.accent : l.textColor));
    }
    yy += hHead + gap;
    if (l.style === 'ticket') dashed(ctx, minSide * 0.03, minSide * 0.022, withAlpha(l.accent, 0.8), Math.max(1, minSide * 0.008), function () { ctx.moveTo(inn.x, yy - gap / 2); ctx.lineTo(inn.x + inn.w, yy - gap / 2); });
    if (code.trim()) {
      var rc = { x: inn.x + inn.w * 0.06, y: yy + gap, w: inn.w * 0.88, h: hCode - gap * 2 }; var ib2 = deflate(rc, rc.h * 0.18);
      var oc = opt(rc.h * 0.55, 800); oc.maxLines = 1; var fc = fitText(ctx, code, ib2, oc);
      chip(rc, fc); drawLines(ctx, fc, ib2, 'center', rgba(l.textColor));
    }
    yy += hCode;
    if (hasFoot) {
      var rf = { x: inn.x, y: yy, w: inn.w, h: inn.y + inn.h - yy };
      if (rf.h > 2) { var of = opt(rf.h * 0.62, 600); of.maxLines = 2; drawLines(ctx, fitText(ctx, foot, rf, of), rf, 'center', faded); }
    }
  }

  function paintQr(ctx, l, box, v) {
    var side = Math.min(box.w, box.h); var sq = { x: -side / 2, y: -side / 2, w: side, h: side };
    var data = substitute(l.data, v).trim(); var q = null;
    try { if (data && root.CRQR) q = root.CRQR.encode(data); } catch (e) { q = null; }
    if (!q) {
      ctx.fillStyle = rgba(l.background); ctx.fillRect(sq.x, sq.y, side, side);
      var ib = deflate(sq, side * 0.1);
      drawLines(ctx, fitText(ctx, data ? 'Link too long for a QR code' : 'No link', ib, { size: side * 0.12, weight: 700, font: 'Manrope', shrink: true }), ib, 'center', rgba(l.color));
      return;
    }
    var n = q.size + 4; var cell = side / n;
    ctx.fillStyle = rgba(l.background); rr(ctx, sq.x, sq.y, side, side, cell * 1.2); ctx.fill();
    ctx.fillStyle = rgba(l.color);
    for (var y = 0; y < q.size; y++) for (var x = 0; x < q.size; x++) if (q.modules[y][x]) ctx.fillRect(sq.x + (x + 2) * cell, sq.y + (y + 2) * cell, cell + 0.6, cell + 0.6);
  }

  /** Draws template t in its own pixel space (t.size.width x t.size.height). images: { id: drawable }. */
  function paint(ctx, t, values, images) {
    var W = t.size.width; var H = t.size.height; var u = unitScale(W, H);
    ctx.save();
    ctx.beginPath(); ctx.rect(0, 0, W, H); ctx.clip();
    paintBackground(ctx, t, images, u);
    t.layers.forEach(function (l) {
      if (l.hidden || l.opacity <= 0) return;
      var bw = l.w * W; var bh = l.h * H;
      ctx.save(); ctx.translate(l.x * W, l.y * H); ctx.rotate(l.rotation * Math.PI / 180); ctx.globalAlpha = l.opacity;
      var box = { x: -bw / 2, y: -bh / 2, w: bw, h: bh };
      if (l.type === 'text') {
        var s = substitute(l.text, values); if (l.uppercase) s = s.toUpperCase();
        if (s.trim()) {
          var f = fitText(ctx, s, box, { size: l.size * u, weight: l.weight, font: l.font, lh: l.lineHeight, ls: l.letterSpacing * u, italic: l.italic, shrink: l.fit === 'shrink' });
          drawLines(ctx, f, box, l.align, rgba(l.color), l.shadow ? { c: rgba(l.shadow.color), b: l.shadow.blur * u, dx: l.shadow.dx * u, dy: l.shadow.dy * u } : null);
        }
      } else if (l.type === 'shape') {
        shapePath(ctx, l, box, u); ctx.fillStyle = rgba(l.fill); ctx.fill();
        if (l.stroke && l.strokeWidth > 0) { ctx.strokeStyle = rgba(l.stroke); ctx.lineWidth = l.strokeWidth * u; ctx.lineJoin = 'round'; ctx.stroke(); }
        var label = substitute(l.label, values);
        if (label.trim()) {
          var m = Math.min(bw, bh);
          var ins = l.shape === 'star' ? deflate(box, m * 0.3)
            : (l.shape === 'burst' || l.shape === 'circle') ? { x: -bw * 0.35, y: -bh * 0.3, w: bw * 0.7, h: bh * 0.6 }
              : l.shape === 'ribbon' ? { x: box.x + bh * 0.5, y: box.y + bh * 0.12, w: bw - bh, h: bh * 0.76 } : deflate(box, m * 0.12);
          drawLines(ctx, fitText(ctx, label, ins, { size: l.labelSize * u, weight: l.weight, font: l.font, lh: 1, shrink: true }), ins, 'center', rgba(l.labelColor));
        }
      } else if (l.type === 'logo') {
        if (l.variant === 'mark') { var sd = Math.min(bw, bh); drawMark(ctx, -sd / 2, -sd / 2, sd); }
        else {
          var side = bh;
          var word = function (sz) { ctx.font = '800 ' + sz + 'px ' + fam('Manrope'); if ('letterSpacing' in ctx) ctx.letterSpacing = (-0.02 * sz) + 'px'; return ctx.measureText('CoRoute').width; };
          var tw = word(side * 0.66); var total = side * 1.25 + tw;
          if (total > bw) { side *= bw / total; tw = word(side * 0.66); total = side * 1.25 + tw; }
          var left = -total / 2; drawMark(ctx, left, -side / 2, side);
          ctx.fillStyle = rgba(l.color); ctx.textBaseline = 'middle'; ctx.textAlign = 'left'; ctx.fillText('CoRoute', left + side * 1.25, 0);
          if ('letterSpacing' in ctx) ctx.letterSpacing = '0px';
        }
      } else if (l.type === 'qr') paintQr(ctx, l, box, values);
      else if (l.type === 'coupon') paintCoupon(ctx, l, box, values, u);
      else if (l.type === 'image') drawImage(ctx, images && l.imageId ? images[l.imageId] : null, box, l.fit, l.radius * u);
      ctx.restore();
    });
    ctx.restore();
  }

  root.CRMK = {
    LIMITS: LIMITS, BRAND: BRAND, SWATCHES: SWATCHES, SIZE_PRESETS: SIZE_PRESETS, FONTS: FONTS, SHAPES: SHAPES, COUPON_STYLES: COUPON_STYLES,
    PATTERNS: PATTERNS, LAYER_TYPES: LAYER_TYPES, TYPE_LABEL: TYPE_LABEL, PLACEHOLDERS: PLACEHOLDERS, SAMPLE: SAMPLE, STARTERS: STARTERS,
    cleanTemplate: cleanTemplate, templateToJson: templateToJson, copyTemplate: copyTemplate, cleanLayer: cleanLayer, layerToJson: layerToJson,
    newLayer: newLayer, nextLayerId: nextLayerId, displayName: displayName, imageIds: imageIds, validate: validate, keepsAspect: keepsAspect,
    substitute: substitute, usedIn: usedIn, templateNeedsCoupon: templateNeedsCoupon, resolveLink: resolveLink, valuesFor: valuesFor,
    couponValues: couponValues, autoCaption: autoCaption, discountText: discountText, formatDate: formatDate, planText: planText,
    blank: blank, unitScale: unitScale, boxOf: boxOf, boxContains: boxContains, hitTest: hitTest, snapRotation: snapRotation,
    retarget: retarget, History: History, paint: paint, sizeOfPreset: sizeOfPreset, clamp: clamp,
  };
})(window);
