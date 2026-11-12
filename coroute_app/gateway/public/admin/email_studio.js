/* CoRoute web admin: e-mail building blocks (3.57, src/email_marketing.js, docs/features_355/email_marketing.md).
   3.57 round 3: the sending flow is the 3-step wizard in email_wizard.js ("E-mail" in the menu). This file gives it:
     CR.emailStudio.editor(draft, opts)   the block editor (basic blocks first, "More blocks" for images, price, divider)
     CR.emailStudio.preview()             the sandboxed preview frame (mobile / desktop, light / dark, plain text)
     CR.emailStudio.renderHistory / renderAutomations / renderTemplates / renderSettings   the other E-mail tabs
   Text is always set as text. The preview is the server's HTML in a sandboxed same-origin frame (/email/preview/<token>,
   its own CSP, no scripts); the console's CSP allows frames from this site only. Every rule (consent, links, variables,
   categories, caps) is enforced by the server; this page only helps. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var BASE = '/admin/email/studio';
  var STATUS = { SCHEDULED: ['Scheduled', 'info'], SENDING: ['Sending', 'warn'], SENT: ['Sent', 'ok'], FAILED: ['Failed', 'bad'], CANCELLED: ['Cancelled', ''] };
  var PLAN_NAMES = { group_small: 'Small Group', group_large: 'Large Group' };
  var BLOCK_HINTS = {
    header_image: 'A wide picture at the top.', heading: 'A title line.', text: '**bold**, *italic*, [label](/path), "- " bullets, blank line = new paragraph.',
    coupon: 'An active coupon: code, discount, validity and a button to /plans?coupon=CODE.', price: 'List price struck through and the offer price, read from Plans & pricing when the e-mail is sent.',
    button: 'Opens a page of this site.', image: 'A picture, optionally linking to a page of this site.', divider: 'A thin line.', footer: 'Always last: unsubscribe, sender, postal address.'
  };
  var cfg = null;
  var seq = 0;
  var uid = function () { seq++; return 'b' + seq; };

  function loadConfig() {
    if (cfg) return Promise.resolve(cfg);
    return api('GET', BASE + '/config').then(function (c) { cfg = c; return c; });
  }
  function errorList(e) {
    var list = (e && e.body && e.body.errors) || [e && e.message];
    var box = h('div.banner.banner--bad', { role: 'alert' });
    if (list.length === 1) box.textContent = list[0];
    else box.appendChild(h('ul.es-errs', list.slice(0, 8).map(function (x) { return h('li', { text: x }); })));
    return box;
  }
  function strip(design) {
    return { subject: design.subject, preheader: design.preheader, blocks: design.blocks.map(function (b) { var o = {}; Object.keys(b).forEach(function (k) { if (k.charAt(0) !== '_') o[k] = b[k]; }); return o; }) };
  }
  function withIds(design) {
    var d = JSON.parse(JSON.stringify(design || { subject: '', preheader: '', blocks: [] }));
    d.blocks = (d.blocks || []).map(function (b) { b._id = uid(); return b; });
    if (!d.blocks.some(function (b) { return b.type === 'footer'; })) d.blocks.push({ type: 'footer', note: '', _id: uid() });
    return d;
  }
  function newBlock(type) {
    var b = { type: type, _id: uid() };
    if (type === 'heading') { b.text = 'A new heading'; b.level = 1; }
    if (type === 'text') b.text = 'Hi {firstName},\n\nWrite your message here.';
    if (type === 'button') { b.label = 'See plans'; b.path = '/plans'; b.style = 'primary'; }
    if (type === 'coupon') { b.code = ''; b.headline = ''; b.note = ''; b.buttonLabel = 'Use {couponCode}'; }
    if (type === 'price') { b.planId = 'group_large'; b.buttonLabel = 'See the offer'; b.note = ''; }
    if (type === 'image' || type === 'header_image') { b.imageId = ''; b.alt = ''; }
    return b;
  }
  function audienceText(a) {
    if (!a) return '-';
    var seg = (cfg && cfg.segments || []).filter(function (s) { return s.kind === a.kind; })[0];
    var label = seg ? seg.label : a.kind;
    if (a.days) label = label.replace('N days', a.days + ' days');
    if (a.kind === 'usernames') label = (a.usernames || []).length + ' username(s)';
    if (a.kind === 'plan') label = 'Plan: ' + (a.plans || []).join(', ');
    return label;
  }

  // ==================================================================== editor + preview (shared by the wizard)
  /** A compose state: a design (blocks carry _id), category, unique-code options, the template it came from. */
  function freshDraft() {
    return { templateId: null, version: 0, name: '', category: 'marketing', design: withIds({ subject: '', preheader: '', blocks: [newBlock('heading'), newBlock('text')] }),
      unique: { enabled: false, prefix: '', validDays: 14 }, dirty: false };
  }
  function draftFrom(t, opts) {
    var d = freshDraft();
    d.templateId = t.starter || t.system ? null : (t.templateId || null);
    d.version = t.version || 0;
    d.name = t.name || '';
    d.category = t.category || 'marketing';
    d.design = withIds(t.design);
    d.fromStarter = t.starter ? t.id : null;
    d.system = t.system ? t.id : null;
    if (opts && opts.coupon) d.design.blocks.forEach(function (b) { if (b.type === 'coupon') b.code = opts.coupon; });
    return d;
  }
  /** Blocks most e-mails need; the rest sit behind "More blocks". */
  var BASIC_BLOCKS = ['heading', 'text', 'button', 'coupon'];

  /**
   * The block editor (subject, preheader, variables, blocks). opts: { onChange(), compact, coupons (Promise) }.
   * Returns { node, refreshCoupons(list) }.
   */
  function emailEditor(d, opts) {
    opts = opts || {};
    var coupons = [];
    var lastField = null;
    var blockList = h('div.es-blocks');
    var showMore = d.design.blocks.some(function (b) { return BASIC_BLOCKS.indexOf(b.type) < 0 && b.type !== 'footer'; });
    var subject = h('input', { type: 'text', maxlength: '150', value: d.design.subject, placeholder: '{firstName}, a festive ride offer for your crew', 'aria-label': 'Subject' });
    var preheader = h('input', { type: 'text', maxlength: '200', value: d.design.preheader || '', placeholder: 'The short line mail apps show after the subject', 'aria-label': 'Preheader' });
    function touched() { d.dirty = true; if (opts.onChange) opts.onChange(); }
    function trackFocus(el) { el.addEventListener('focus', function () { lastField = el; }); return el; }
    trackFocus(subject); trackFocus(preheader);
    subject.addEventListener('input', function () { d.design.subject = subject.value; touched(); });
    preheader.addEventListener('input', function () { d.design.preheader = preheader.value; touched(); });

    var varBar = h('div.es-vars', { 'aria-label': 'Insert a variable' });
    function insertVar(name) {
      var el = lastField;
      if (!el || !document.body.contains(el)) { ui.toast('Click into a text field first.', true); return; }
      var token = '{' + name + '}';
      var s = el.selectionStart || el.value.length, e = el.selectionEnd || el.value.length;
      el.value = el.value.slice(0, s) + token + el.value.slice(e);
      el.focus(); el.setSelectionRange(s + token.length, s + token.length);
      el.dispatchEvent(new Event('input'));
    }
    cfg.variables.forEach(function (v) { varBar.appendChild(h('button.btn.btn--sm.es-var', { type: 'button', title: v.label, text: '{' + v.name + '}', onclick: function () { insertVar(v.name); } })); });

    function move(i, delta) {
      var j = i + delta; var bl = d.design.blocks;
      if (j < 0 || j >= bl.length - 1 || bl[i].type === 'footer') return;
      var t = bl[i]; bl[i] = bl[j]; bl[j] = t; drawBlocks(); touched();
    }
    var couponFills = [];
    function drawBlocks() {
      couponFills = [];
      clear(blockList);
      d.design.blocks.forEach(function (b, i) { blockList.appendChild(blockCard(b, i)); });
      blockList.appendChild(addBar());
    }
    function addBar() {
      var bar = h('div.es-addbar.row');
      (cfg.blockTypes || []).filter(function (t) { return t.type !== 'footer' && (showMore || BASIC_BLOCKS.indexOf(t.type) >= 0); }).forEach(function (t) {
        bar.appendChild(h('button.btn.btn--sm', { type: 'button', text: '+ ' + t.label, title: BLOCK_HINTS[t.type] || '', onclick: function () {
          if (t.type === 'coupon' && d.design.blocks.some(function (b) { return b.type === 'coupon'; })) { ui.toast('One coupon block per e-mail.', true); return; }
          d.design.blocks.splice(d.design.blocks.length - 1, 0, newBlock(t.type)); drawBlocks(); touched();
        } }));
      });
      bar.appendChild(h('button.btn.btn--sm.btn--ghost', { type: 'button', 'aria-expanded': String(showMore), text: showMore ? 'Fewer blocks' : 'More blocks…', title: 'Images, price, divider',
        onclick: function () { showMore = !showMore; drawBlocks(); } }));
      return bar;
    }
    function input(b, key, attrs) {
      attrs = attrs || {};
      var a = {};
      Object.keys(attrs).forEach(function (k) { if (k !== 'multiline') a[k] = attrs[k]; });
      if (!attrs.multiline) a.type = 'text';
      a.value = b[key] || '';
      var el = h(attrs.multiline ? 'textarea' : 'input', a);
      el.addEventListener('input', function () { b[key] = el.value; touched(); });
      return trackFocus(el);
    }
    function blockCard(b, i) {
      var label = (cfg.blockTypes.filter(function (t) { return t.type === b.type; })[0] || {}).label || b.type;
      var isFoot = b.type === 'footer';
      var last = d.design.blocks.length - 1;
      var tools = h('div.es-block__tools',
        h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Move up', title: 'Move up', text: '↑', disabled: isFoot || i === 0, onclick: function () { move(i, -1); } }),
        h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Move down', title: 'Move down', text: '↓', disabled: isFoot || i >= last - 1, onclick: function () { move(i, 1); } }),
        h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Duplicate', title: 'Duplicate', text: '⧉', disabled: isFoot || b.type === 'coupon', onclick: function () {
          var c = JSON.parse(JSON.stringify(b)); c._id = uid(); d.design.blocks.splice(i + 1, 0, c); drawBlocks(); touched();
        } }),
        h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Delete', title: 'Delete', text: '×', disabled: isFoot, onclick: function () { d.design.blocks.splice(i, 1); drawBlocks(); touched(); } }));
      var body = h('div.es-block__body');
      if (b.type === 'heading') {
        var lv = ui.select([['1', 'Large'], ['2', 'Small']], String(b.level || 1), { 'aria-label': 'Size' });
        lv.addEventListener('change', function () { b.level = Number(lv.value); touched(); });
        body.appendChild(h('div.es-row2', ui.field('Heading', input(b, 'text', { maxlength: '150' })), ui.field('Size', lv)));
      } else if (b.type === 'text') {
        var ta = input(b, 'text', { multiline: true, rows: '5', maxlength: '3000', 'aria-label': 'Text' });
        var wrap = function (before, after, ph) {
          var s = ta.selectionStart, e = ta.selectionEnd; var sel = ta.value.slice(s, e) || ph;
          ta.value = ta.value.slice(0, s) + before + sel + after + ta.value.slice(e); ta.focus(); ta.setSelectionRange(s + before.length, s + before.length + sel.length); ta.dispatchEvent(new Event('input'));
        };
        var fmt = h('div.es-fmt', h('button.btn.btn--sm', { type: 'button', title: 'Bold', 'aria-label': 'Bold', onclick: function () { wrap('**', '**', 'bold'); } }, h('b', { text: 'B' })),
          h('button.btn.btn--sm', { type: 'button', title: 'Italic', 'aria-label': 'Italic', onclick: function () { wrap('*', '*', 'italic'); } }, h('i', { text: 'I' })),
          h('button.btn.btn--sm', { type: 'button', text: 'Link', title: 'Links may only open pages of this site', onclick: function () {
            var path = h('select'); ['/plans', '/updates', '/guide', '/operators/apply', '/account', '/features', '/safety', '/clubs'].forEach(function (p) { path.appendChild(h('option', { value: p, text: p })); });
            ui.dialog({ title: 'Link to a page of this site', body: [ui.field('Page', path), h('p.small.muted', { text: 'Links may only point to this site. Other sites are refused.' })], actions: [{ label: 'Cancel', value: null }, { label: 'Insert', kind: 'primary', value: true }] })
              .then(function (ok) { if (ok) wrap('[', '](' + path.value + ')', 'label'); });
          } }), h('button.btn.btn--sm', { type: 'button', text: '• List', onclick: function () { wrap('\n- ', '', 'item'); } }));
        body.appendChild(fmt); body.appendChild(ta);
      } else if (b.type === 'button') {
        var path = ui.select(cfg.buttonPaths.map(function (p) { return [p, p]; }), (b.path || '/plans').split('?')[0], { 'aria-label': 'Page' });
        var style = ui.select([['primary', 'Filled'], ['secondary', 'Outline']], b.style || 'primary', { 'aria-label': 'Style' });
        path.addEventListener('change', function () { b.path = path.value; touched(); });
        style.addEventListener('change', function () { b.style = style.value; touched(); });
        body.appendChild(h('div.grid3', ui.field('Text', input(b, 'label', { maxlength: '40' })), ui.field('Opens', path), ui.field('Style', style)));
      } else if (b.type === 'coupon') {
        var csel = h('select', { 'aria-label': 'Coupon' });
        var info = h('div.small.muted');
        var fill = function () {
          clear(csel);
          if (opts.couponLocked) { csel.appendChild(h('option', { value: '', text: 'The personal code made for this rider' })); csel.disabled = true; info.textContent = ''; return; }
          csel.appendChild(h('option', { value: '', text: coupons.length ? 'Choose an active coupon…' : 'No active coupons: create one in Plans & coupons' }));
          coupons.forEach(function (c) { csel.appendChild(h('option', { value: c.code, text: c.code + ' · ' + couponLabel(c), selected: c.code === b.code })); });
          if (b.code && !coupons.some(function (c) { return c.code === b.code; })) csel.appendChild(h('option', { value: b.code, text: b.code + ' (not active)', selected: true }));
          var c = coupons.filter(function (x) { return x.code === b.code; })[0];
          info.textContent = c ? couponLabel(c) + ' · valid until ' + CR.util.date(c.expiresAt) + (c.status === 'SCHEDULED' ? ' · starts ' + CR.util.date(c.validFrom) : '') : '';
        };
        csel.addEventListener('change', function () { b.code = csel.value; fill(); touched(); });
        couponFills.push(fill);
        fill();
        body.appendChild(h('div.es-row2', ui.field('Coupon', csel), ui.field('Button text', input(b, 'buttonLabel', { maxlength: '40', placeholder: 'Use {couponCode}' }))));
        body.appendChild(info);
        body.appendChild(h('div.grid2', ui.field('Headline', input(b, 'headline', { maxlength: '80', placeholder: 'Festive offer' }), 'optional'), ui.field('Note', input(b, 'note', { maxlength: '160', placeholder: 'Valid until {validUntil}.' }), 'optional')));
      } else if (b.type === 'price') {
        var plan = ui.select(cfg.plans.map(function (p) { return [p, PLAN_NAMES[p] || p]; }), b.planId || 'group_large', { 'aria-label': 'Plan' });
        plan.addEventListener('change', function () { b.planId = plan.value; touched(); });
        body.appendChild(h('div.grid3', ui.field('Plan', plan), ui.field('Button text', input(b, 'buttonLabel', { maxlength: '40', placeholder: 'See plans' })), ui.field('Note', input(b, 'note', { maxlength: '160' }), 'optional')));
        body.appendChild(h('p.small.muted', { text: 'Prices come from Plans & pricing when the e-mail is sent.' }));
      } else if (b.type === 'header_image' || b.type === 'image') {
        body.appendChild(imagePicker(b, touched, input));
      } else if (b.type === 'footer') {
        body.appendChild(ui.field('Extra footer note', input(b, 'note', { multiline: true, rows: '2', maxlength: '500', placeholder: 'Optional, e.g. "Ride safe."' }), 'optional'));
      }
      return h('section.es-block' + (isFoot ? '.es-block--locked' : ''), { 'aria-label': label },
        h('div.es-block__head', h('span.es-block__type', { text: label }), h('span.es-block__hint.small.muted', { text: isFoot ? 'Always last: why they get it, unsubscribe, sender, address.' : '', title: BLOCK_HINTS[b.type] || '' }), h('span.spacer'), tools), body);
    }
    drawBlocks();
    var node = h('div.stack',
      ui.field('Subject', subject, 'variables allowed'), ui.field('Preheader', preheader, 'optional'),
      h('details.es-more', h('summary', { text: 'Personalise: insert a variable' }), h('p.small.muted', { text: 'Click a text field, then a variable. Missing values get a safe fallback ("there", "rider").' }), varBar),
      h('div.stack', h('div.panel-title', { text: 'Blocks' }), blockList));
    return {
      node: node,
      redraw: drawBlocks,
      setCoupons: function (list) { coupons = list || []; couponFills.forEach(function (f) { f(); }); },
    };
  }
  function couponLabel(c) {
    var v = Number(c.discountValue) || 0;
    if (c.discountType === 'percentage') return v + '% off';
    if (c.discountType === 'fixed') return '₹' + v + ' off';
    if (c.discountType === 'free') return 'free period';
    return 'discount';
  }
  /** Active public coupons for the coupon block. */
  function activeCoupons() {
    return api('GET', '/admin/coupons').then(function (r) {
      return ((r && r.coupons) || []).filter(function (c) { return (c.status === 'ACTIVE' || c.status === 'SCHEDULED') && !c.parentCode && !(c.allowedUserIds && c.allowedUserIds.length); });
    }).catch(function () { return []; });
  }
  function imagePicker(b, touched, input) {
    var thumb = h('div.es-thumb', b._url ? h('img', { src: b._url, alt: '' }) : h('span.small.muted', { text: b.imageId ? 'Image chosen' : 'No image yet' }));
    var file = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp', 'aria-label': 'Upload an image' });
    var status = h('span.small.muted');
    var set = function (img) { b.imageId = img.imageId; b._url = img.url ? img.url.replace(/^https?:\/\/[^/]+/, '') : ''; clear(thumb).appendChild(b._url ? h('img', { src: b._url, alt: '' }) : h('span.small', { text: 'Image chosen' })); touched(); };
    file.addEventListener('change', function () {
      var f = file.files && file.files[0]; if (!f) return;
      if (f.size > 1024 * 1024) { ui.toast('The image is larger than 1 MB.', true); file.value = ''; return; }
      status.textContent = 'Uploading…';
      api('POST', '/admin/push/images', f, { type: f.type || 'application/octet-stream' }).then(function (r) { status.textContent = ''; set(r.image); })
        .catch(function (e) { status.textContent = e.message; file.value = ''; });
    });
    var lib = h('button.btn.btn--sm', { type: 'button', text: 'From the image library', onclick: function () { pickFromLibrary().then(function (img) { if (img) set(img); }); } });
    var link = null;
    if (b.type === 'image') {
      link = ui.select([['', 'No link']].concat(cfg.buttonPaths.map(function (p) { return [p, 'Links to ' + p]; })), b.path || '', { 'aria-label': 'Image link' });
      link.addEventListener('change', function () { b.path = link.value || undefined; if (!link.value) delete b.path; touched(); });
    }
    return h('div.es-img', thumb, h('div.stack', h('div.row', h('label.btn.btn--sm.es-upload', 'Upload', file), lib, status),
      ui.field('Alt text', input(b, 'alt', { maxlength: '120', placeholder: 'Describe the picture' })), link ? ui.field('Link', link) : null));
  }
  function seg(opts, value, onPick, label) {
    var g = h('div.es-seg', { role: 'group', 'aria-label': label });
    opts.forEach(function (o) {
      g.appendChild(h('button.btn.btn--sm', { type: 'button', 'aria-pressed': String(o[0] === value), text: o[1], title: o[2] || '', onclick: function () {
        Array.prototype.forEach.call(g.children, function (c) { c.setAttribute('aria-pressed', 'false'); }); this.setAttribute('aria-pressed', 'true'); onPick(o[0]);
      } }));
    });
    return g;
  }
  /**
   * The preview: the server's HTML in a sandboxed same-origin frame (desktop / mobile, light / dark, plain text).
   * show(r) takes a preview answer { subject, preheader, text, previewUrl, darkPreviewUrl }.
   */
  function emailPreview() {
    var frame = h('iframe.es-frame', { title: 'E-mail preview', sandbox: 'allow-popups', referrerpolicy: 'no-referrer', loading: 'lazy' });
    var frameWrap = h('div.es-frame-wrap.es-frame-wrap--desktop', frame);
    var textOut = h('pre.es-textout', { text: '' });
    var subjOut = h('div.es-inbox', h('b', { text: 'Subject' }), h('span', { text: '' }), h('b', { text: 'Preheader' }), h('span', { text: '' }));
    var pv = { device: 'desktop', scheme: 'light', urls: null };
    var deviceSeg = seg([['desktop', 'Desktop'], ['mobile', 'Mobile']], pv.device, function (v) { pv.device = v; frameWrap.className = 'es-frame-wrap es-frame-wrap--' + v; }, 'Device');
    var schemeSeg = seg([['light', 'Light'], ['dark', 'Dark']], pv.scheme, function (v) { pv.scheme = v; if (pv.urls) frame.src = v === 'dark' && pv.urls.dark ? pv.urls.dark : pv.urls.light; }, 'Colour scheme');
    var viewSeg = seg([['html', 'E-mail'], ['text', 'Plain text']], 'html', function (v) { frameWrap.hidden = v !== 'html'; textOut.hidden = v !== 'text'; }, 'View');
    textOut.hidden = true;
    var node = h('div.stack.es-pv', h('div.row', deviceSeg, schemeSeg, h('span.spacer'), viewSeg), subjOut, frameWrap, textOut);
    return {
      node: node,
      show: function (r) {
        pv.urls = { light: r.previewUrl, dark: r.darkPreviewUrl };
        frame.src = pv.scheme === 'dark' && pv.urls.dark ? pv.urls.dark : pv.urls.light;
        textOut.textContent = r.text || '';
        subjOut.children[1].textContent = r.subject || ''; subjOut.children[3].textContent = r.preheader || '-';
      },
    };
  }
  /** Saves a draft as a template (new, or a new version of the one it came from). */
  function saveTemplate(d, asNew) {
    var name = (d.name || '').trim();
    var go = function (n) {
      var body = { name: n, category: d.category, design: strip(d.design) };
      var update = d.templateId && !asNew;
      var req = update ? api('PUT', BASE + '/templates/' + d.templateId, Object.assign(body, { baseVersion: d.version })) : api('POST', BASE + '/templates', body);
      return req.then(function (r) {
        d.templateId = r.template.templateId; d.version = r.template.version; d.name = r.template.name; d.fromStarter = null; d.system = null; d.dirty = false;
        ui.toast((update ? 'Saved version ' + r.template.version + ' of ' : 'Saved as a new template: ') + r.template.name + '.');
        return r.template;
      });
    };
    if (name && !(asNew && d.templateId)) return go(name).catch(function (e) { ui.toast(e.message, true); });
    var n = h('input', { type: 'text', maxlength: '80', value: asNew && name ? name + ' (copy)' : name });
    return ui.dialog({ title: asNew ? 'Save as a new template' : 'Save template', body: [ui.field('Name', n)], actions: [{ label: 'Cancel', value: null }, { label: 'Save', kind: 'primary', onClick: function () {
      if (!n.value.trim()) throw new Error('Name the template.');
      return go(n.value.trim()).then(function () { return true; });
    } }] });
  }

  /** The marketing studio and board images; resolves with an imported { imageId, url } or null. */
  function pickFromLibrary() {
    return new Promise(function (resolve) {
      var grid = h('div.es-lib', ui.loading());
      var urls = [];
      var chosen = null;
      api('GET', BASE + '/images/library').then(function (r) {
        clear(grid);
        if (!r.images.length) { grid.appendChild(h('p.muted', { text: 'No images in the marketing studio or on the board yet. Export a studio PNG and upload it instead.' })); return; }
        r.images.forEach(function (img) {
          var im = h('img', { alt: img.source + ' image' });
          var btn = h('button.es-lib__item', { type: 'button', 'aria-label': 'Use this ' + img.source + ' image', onclick: function () { chosen = img; grid.querySelectorAll('.es-lib__item').forEach(function (b) { b.classList.remove('is-on'); }); btn.classList.add('is-on'); } },
            im, h('span.small', { text: (img.source === 'board' ? 'Board' : 'Studio') + (img.width ? ' · ' + img.width + '×' + img.height : '') }));
          grid.appendChild(btn);
          api('GET', img.previewUrl.replace(/^\/api/, ''), null, { raw: true }).then(function (res) { return res.blob(); }).then(function (bl) { var u = URL.createObjectURL(bl); urls.push(u); im.src = u; }).catch(function () {});
        });
      }).catch(function (e) { clear(grid).appendChild(ui.error(e)); });
      ui.dialog({ title: 'Image library', wide: true, body: [h('p.small.muted', { text: 'Images from the Marketing studio and the Board. The chosen one is copied to the public e-mail image store (up to 1 MB).' }), grid],
        actions: [{ label: 'Cancel', value: null }, { label: 'Use image', kind: 'primary', onClick: function () {
          if (!chosen) throw new Error('Choose an image.');
          return api('POST', BASE + '/images/import', { source: chosen.source, id: chosen.id }).then(function (r) { return r.image; });
        } }] }).then(function (v) { urls.forEach(function (u) { URL.revokeObjectURL(u); }); resolve(v || null); });
    });
  }

  // ==================================================================== templates
  function renderTemplates(view) {
    var showArchived = false;
    var box = h('div', ui.loading());
    var toggle = h('label.check', h('input', { type: 'checkbox', onchange: function () { showArchived = this.checked; load(); } }), 'Show archived');
    view.appendChild(h('div.row.section-gap', h('h2', { text: 'Ready-made' }), h('span.small.muted', { text: '"Use" opens a copy in the wizard. Save it there to make it yours.' }),
      h('span.spacer'), h('a.btn.btn--sm.btn--ghost', { href: '#/settings/templates', text: 'Words of automatic e-mails…', title: 'Welcome, receipts, plan assigned, coupon for you' })));
    var starters = h('div.es-cards');
    view.appendChild(starters);
    view.appendChild(h('div.row.section-gap', h('h2', { text: 'Your templates' }), h('span.spacer'), toggle));
    view.appendChild(box);
    function card(t, actions) {
      return h('div.card.es-tcard', h('div.row', h('b', { text: t.name }), h('span.spacer'), ui.chip(t.category === 'account' ? 'Account' : 'Marketing', t.category === 'account' ? 'warn' : 'info')),
        h('div.small.es-tcard__subj', { text: t.design.subject }), t.description ? h('p.small.muted', { text: t.description }) : null,
        h('div.small.muted', { text: t.design.blocks.filter(function (b) { return b.type !== 'footer'; }).map(function (b) { return b.type.replace('_', ' '); }).join(' · ') }),
        h('div.row.row--end', actions));
    }
    function useIt(t) {
      api('GET', BASE + '/templates/' + encodeURIComponent(t.templateId || t.id)).then(function (r) {
        CR.state.wizardPrefill = { template: r.template };
        CR.go('#/email');
      }).catch(function (e) { ui.toast(e.message, true); });
    }
    function history(t) {
      api('GET', BASE + '/templates/' + t.templateId).then(function (r) {
        var tb = h('tbody');
        r.template.history.forEach(function (v) {
          tb.appendChild(h('tr', h('td', { text: 'v' + v.version }), h('td', { text: CR.util.date(v.savedAt, true) }), h('td.small', { text: v.savedBy || '-' }), h('td.small', { text: v.subject || '' }),
            h('td', h('button.btn.btn--sm', { type: 'button', text: 'Open', onclick: function () {
              api('GET', BASE + '/templates/' + t.templateId + '/versions/' + v.version).then(function (x) {
                document.querySelectorAll('.scrim').forEach(function (s) { s.remove(); });
                CR.state.wizardPrefill = { template: { templateId: t.templateId, version: r.template.version, name: r.template.name, category: x.version.category, design: x.version.design }, dirty: true };
                ui.toast('Version ' + v.version + ' is open. Save it as a template to make it the current version.');
                CR.go('#/email');
              }).catch(function (e) { ui.toast(e.message, true); });
            } }))));
        });
        ui.dialog({ title: 'Versions of ' + r.template.name, wide: true, body: [h('div.table-wrap', h('table.table', h('thead', h('tr', ['Version', 'Saved', 'By', 'Subject', ''].map(function (c) { return h('th', { text: c }); }))), tb))] });
      }).catch(function (e) { ui.toast(e.message, true); });
    }
    function load() {
      api('GET', BASE + '/templates' + (showArchived ? '?archived=1' : '')).then(function (r) {
        clear(starters);
        r.starters.forEach(function (s) { starters.appendChild(card(s, [h('button.btn.btn--sm.btn--primary', { type: 'button', text: 'Use', onclick: function () { useIt(s); } })])); });
        clear(box);
        if (!r.templates.length) { box.appendChild(h('div.card.empty', { text: 'No saved templates yet. Use a ready-made one and save it.' })); return; }
        var grid = h('div.es-cards');
        r.templates.forEach(function (t) {
          var arch = t.status === 'archived';
          grid.appendChild(card(t, [
            h('span.small.muted', { text: 'v' + t.version + ' · ' + CR.util.date(t.updatedAt) }), h('span.spacer'),
            h('button.btn.btn--sm', { type: 'button', text: 'Versions', onclick: function () { history(t); } }),
            h('button.btn.btn--sm', { type: 'button', text: 'Duplicate', onclick: function () { api('POST', BASE + '/templates/' + t.templateId + '/duplicate', {}).then(function () { ui.toast('Duplicated.'); load(); }).catch(function (e) { ui.toast(e.message, true); }); } }),
            h('button.btn.btn--sm', { type: 'button', text: arch ? 'Unarchive' : 'Archive', onclick: function () { api('POST', BASE + '/templates/' + t.templateId + (arch ? '/unarchive' : '/archive'), {}).then(load).catch(function (e) { ui.toast(e.message, true); }); } }),
            arch ? null : h('button.btn.btn--sm.btn--primary', { type: 'button', text: 'Edit', onclick: function () { useIt(t); } })]));
        });
        box.appendChild(grid);
      }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
    }
    load();
  }

  // ==================================================================== campaigns
  function reportDialog(title, id, isRule) {
    var body = h('div.stack', ui.loading());
    api('GET', BASE + (isRule ? '/rules/' + id + '/report' : '/campaigns/' + id)).then(function (r) {
      var rep = r.report; var c = r.campaign;
      clear(body);
      var tiles = h('div.tiles');
      [['Queued', rep.queued], ['Sent', rep.sent], ['Failed', rep.failed], ['Unsubscribed', rep.unsubscribed], ['Clicks', rep.clicks.total, rep.clicks.unique + ' rider(s)'],
        ['Coupon redemptions', rep.redemptions.count, rep.redemptions.count ? '₹' + rep.redemptions.discountInr + ' off · ₹' + rep.redemptions.revenueInr + ' paid' : '']].forEach(function (x) { tiles.appendChild(ui.tile(x[0], String(x[1]), x[2])); });
      body.appendChild(tiles);
      if (c) {
        var s = c.stats || {};
        var kv = h('dl.kv');
        [['Status', (STATUS[c.status] || [c.status])[0]], ['Audience', audienceText(c.audience)], ['Category', c.category === 'account' ? 'Account notice' : 'Marketing (Offers consent)'],
          ['When', CR.util.date(c.sendAt, true) + ' IST'], ['Targeted', String(s.targeted || 0)], ['Skipped at send time', String(s.skipped || 0) + ' (consent, suppression, account gone)'],
          ['Over the weekly cap', String(s.capped || 0)], ['Coupon', c.couponCode ? c.couponCode + (c.uniqueCoupon ? ' (unique codes ' + c.uniqueCoupon.prefix + '-…)' : '') : '-'],
          ['Click tracking', c.trackClicks ? 'On' : 'Off'], ['Error', c.error || '-']].forEach(function (x) { kv.appendChild(h('dt', { text: x[0] })); kv.appendChild(h('dd', { text: x[1] })); });
        body.appendChild(kv);
      }
      if (rep.clicks.byLink.length) {
        var tb = h('tbody');
        rep.clicks.byLink.forEach(function (l) { tb.appendChild(h('tr', h('td.mono', { text: l.path }), h('td.num', { text: String(l.total) }))); });
        body.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Link' }), h('th.num', { text: 'Clicks' }))), tb)));
      }
      body.appendChild(h('p.small.muted', { text: 'Clicks are counted through signed redirect links, without open pixels. Redemptions: the campaign\'s codes used by its recipients after it started (successful payments).' }));
    }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
    ui.dialog({ title: title, wide: true, body: [body] });
  }

  function renderCampaigns(view) {
    var box = h('div', ui.loading());
    view.appendChild(box);
    api('GET', BASE + '/campaigns?limit=100').then(function (r) {
      var tb = h('tbody');
      (r.campaigns || []).forEach(function (c) {
        var s = STATUS[c.status] || [c.status, '']; var st = c.stats || {};
        tb.appendChild(h('tr.is-link', { tabindex: '0', onclick: function () { reportDialog(c.name, c.campaignId); }, onkeydown: function (e) { if (e.key === 'Enter') reportDialog(c.name, c.campaignId); } },
          h('td.nowrap', { text: CR.util.date(c.sendAt, true) }), h('td', h('b', { text: c.name }), h('div.small.muted', { text: c.design.subject })),
          h('td.small', { text: audienceText(c.audience) }), h('td', { text: c.couponCode || '-' }), h('td', ui.chip(s[0], s[1])),
          h('td.num', { text: String(st.targeted || 0) }), h('td.num', { text: String(st.sent || 0) }), h('td.num', { text: String((st.skipped || 0) + (st.capped || 0)) }), h('td.num', { text: String(st.failed || 0) }),
          h('td', c.status === 'SCHEDULED' ? h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Cancel', onclick: function (e) {
            e.stopPropagation();
            api('POST', BASE + '/campaigns/' + c.campaignId + '/cancel', {}).then(function () { CR.go('#/email/history'); }).catch(function (er) { ui.toast(er.message, true); });
          } }) : null)));
      });
      if (!tb.firstChild) tb.appendChild(h('tr', h('td', { colspan: '10', class: 'empty', text: 'Nothing sent yet. Start with Send.' })));
      clear(box).appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['When (IST)', 'Campaign', 'Audience', 'Coupon', 'Status', 'Riders', 'Sent', 'Skipped', 'Failed', ''].map(function (c, i) { return h('th', { class: i >= 5 && i <= 8 ? 'num' : '', text: c }); }))), tb)));
    }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
  }

  // ==================================================================== automation
  function renderAutomation(view) {
    var box = h('div', ui.loading());
    var templates = [];
    view.appendChild(h('div.row.section-gap', h('p.small.muted', { text: 'A rule sends a saved template to a segment, checked every minute outside the quiet hours: once per rider per occurrence, never above the weekly cap, with consent checked at send time.' }),
      h('span.spacer'), h('button.btn.btn--primary', { type: 'button', text: 'New rule', onclick: function () { edit(null); } })));
    view.appendChild(box);
    function edit(rule) {
      var x = rule || {};
      var trig = ui.select(cfg.triggers.map(function (t) { return [t.id, t.label]; }), x.trigger || 'inactive');
      var name = h('input', { type: 'text', maxlength: '80', value: x.name || '' });
      var daysIn = h('input', { type: 'number', min: '1', max: '365', value: String(x.days || 30) });
      var cool = h('input', { type: 'number', min: '0', max: '730', value: String(x.cooldownDays !== undefined ? x.cooldownDays : 90) });
      var tpl = ui.select(templates.map(function (t) { return [t.templateId, t.name + (t.category === 'account' ? ' (account)' : '')]; }), x.templateId || (templates[0] && templates[0].templateId));
      var coupon = h('input', { type: 'text', maxlength: '24', value: x.couponCode || '', placeholder: 'BACK20', autocapitalize: 'characters' });
      var uq = h('input', { type: 'checkbox', checked: !!(x.uniqueCoupon && x.uniqueCoupon.enabled) });
      var uqp = h('input', { type: 'text', maxlength: '10', value: (x.uniqueCoupon && x.uniqueCoupon.prefix) || '' });
      var uqd = h('input', { type: 'number', min: '1', max: '90', value: String((x.uniqueCoupon && x.uniqueCoupon.validDays) || 14) });
      var en = h('input', { type: 'checkbox', checked: x.enabled !== false });
      trig.addEventListener('change', function () { var t = cfg.triggers.filter(function (y) { return y.id === trig.value; })[0]; daysIn.value = t.defaultDays; cool.value = t.cooldown; });
      if (!templates.length) { ui.toast('Save a template first (Templates > Use a starter > Save).', true); return; }
      ui.dialog({ title: rule ? 'Edit rule' : 'New automation rule', wide: true, body: [
        h('div.grid2', ui.field('Name', name), ui.field('When', trig)),
        h('div.grid2', ui.field('N days', daysIn), ui.field('Once per rider per N days', cool, '0 = once per occurrence (plan rules: once per plan period)')),
        h('div.grid2', ui.field('Template', tpl), ui.field('Coupon for the coupon block', coupon, 'when the template has one')),
        h('div.row', h('label.check', uq, 'Unique single-use codes'), ui.field('Prefix', uqp), ui.field('Valid days', uqd)),
        h('label.check', en, 'Enabled')],
      actions: [{ label: 'Cancel', value: null }, { label: 'Save', kind: 'primary', onClick: function () {
        var body = { name: name.value, trigger: trig.value, days: Number(daysIn.value), cooldownDays: Number(cool.value), templateId: tpl.value, couponCode: coupon.value.trim() || undefined,
          uniqueCoupon: uq.checked ? { enabled: true, prefix: uqp.value, validDays: Number(uqd.value) } : undefined, enabled: en.checked };
        return (rule ? api('PUT', BASE + '/rules/' + rule.ruleId, body) : api('POST', BASE + '/rules', body)).then(function () { ui.toast('Rule saved.'); load(); return true; });
      } }] });
    }
    function load() {
      Promise.all([api('GET', BASE + '/rules'), api('GET', BASE + '/templates')]).then(function (r) {
        templates = r[1].templates;
        var tb = h('tbody');
        r[0].rules.forEach(function (x) {
          var t = templates.filter(function (y) { return y.templateId === x.templateId; })[0];
          var trigLabel = (cfg.triggers.filter(function (y) { return y.id === x.trigger; })[0] || {}).label || x.trigger;
          tb.appendChild(h('tr', h('td', h('b', { text: x.name }), h('div.small.muted', { text: trigLabel.replace('N days', x.days + ' days') })),
            h('td', { text: t ? t.name : '(missing template)' }), h('td', { text: x.couponCode || '-' }), h('td.small', { text: x.cooldownDays ? 'once per ' + x.cooldownDays + ' days' : 'once per occurrence' }),
            h('td', ui.chip(x.enabled ? 'On' : 'Off', x.enabled ? 'ok' : '')), h('td.num', { text: String((x.stats && x.stats.sent) || 0) }), h('td.small', { text: x.lastRunAt ? CR.util.date(x.lastRunAt, true) : '-' }),
            h('td', h('div.row.row--end', h('button.btn.btn--sm', { type: 'button', text: 'Report', onclick: function () { reportDialog(x.name, x.ruleId, true); } }),
              h('button.btn.btn--sm', { type: 'button', text: x.enabled ? 'Turn off' : 'Turn on', onclick: function () { api('PUT', BASE + '/rules/' + x.ruleId, { enabled: !x.enabled }).then(load).catch(function (e) { ui.toast(e.message, true); }); } }),
              h('button.btn.btn--sm', { type: 'button', text: 'Edit', onclick: function () { edit(x); } }),
              h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'Delete', onclick: function () { ui.confirm('Delete rule?', 'It stops sending. Its sent e-mails stay in the reports.', 'Delete', true).then(function (ok) { if (ok) api('DELETE', BASE + '/rules/' + x.ruleId).then(load).catch(function (e) { ui.toast(e.message, true); }); }); } })))));
        });
        if (!tb.firstChild) tb.appendChild(h('tr', h('td', { colspan: '8', class: 'empty', text: 'No rules yet. Example: "No ride for 30 days" -> Win-back template, once per rider per 90 days.' })));
        clear(box).appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Rule', 'Template', 'Coupon', 'Repeat', 'Status', 'Sent', 'Last run', ''].map(function (c, i) { return h('th', { class: i === 5 ? 'num' : '', text: c }); }))), tb)));
      }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
    }
    loadConfig().then(load);
  }

  // ==================================================================== settings
  function renderSettings(view) {
    var s = cfg.settings;
    var cap = h('input', { type: 'number', min: '1', max: '14', value: String(s.maxPerWeek) });
    var qs = h('input', { type: 'number', min: '0', max: '23', value: String(s.quietStartHour) });
    var qe = h('input', { type: 'number', min: '0', max: '23', value: String(s.quietEndHour) });
    var trk = h('input', { type: 'checkbox', checked: !!s.clickTracking });
    view.appendChild(h('div.grid2.section-gap',
      h('div.card.stack', h('h3', { text: 'Sending rules' }),
        ui.field('Marketing e-mails per rider per week', cap, 'campaigns and rules together; account notices do not count'),
        h('div.grid2', ui.field('Quiet hours from (IST hour)', qs), ui.field('until (IST hour)', qe)), h('p.small.muted', { text: 'Nothing is sent in the quiet hours; a campaign due then goes out when they end. Same hour twice = no quiet hours.' }),
        h('label.check', trk, 'Count clicks in marketing e-mails (signed redirect links /r/…; no open pixels)'),
        h('div.row.row--end', h('button.btn.btn--primary', { type: 'button', text: 'Save', onclick: function () {
          api('PUT', BASE + '/settings', { maxPerWeek: Number(cap.value), quietStartHour: Number(qs.value), quietEndHour: Number(qe.value), clickTracking: trk.checked })
            .then(function (r) { cfg.settings = r; ui.toast('Saved.'); }).catch(function (e) { ui.toast(e.message, true); });
        } }))),
      h('div.card.stack', h('h3', { text: 'Sender identity' }),
        h('dl.kv', h('dt', { text: 'Postal address' }), h('dd', cfg.postalAddressSet ? ui.chip('Set (MAIL_POSTAL_ADDRESS)', 'ok') : ui.chip('Not set: ' + cfg.postalPlaceholder, 'bad')),
          h('dt', { text: 'Site address' }), h('dd', { text: cfg.origin || 'PUBLIC_ORIGIN not set' }), h('dt', { text: 'SMTP' }), h('dd', cfg.enabled ? ui.chip('Configured', 'ok') : ui.chip('Not configured', 'bad')),
          h('dt', { text: 'Rate' }), h('dd', { text: cfg.ratePerSec + ' e-mails per second (OFFER_EMAIL_RATE)' })),
        h('p.small.muted', { text: 'Every marketing e-mail has the Offers unsubscribe link and one-click headers, "Sent by CoRoute", the postal address and the support address. Real campaigns need the postal address; test sends work without it.' }))));
    var supp = h('div');
    view.appendChild(h('h2.section-gap', { text: 'Suppression list' }));
    view.appendChild(supp);
    if (CR.renderSuppression) CR.renderSuppression(supp);
    var legacy = h('div');
    view.appendChild(h('h2.section-gap', { text: 'Earlier offers e-mails (3.56 composer)' }));
    view.appendChild(legacy);
    if (CR.renderLegacyOffers) CR.renderLegacyOffers(legacy);
  }

  CR.emailStudio = {
    BASE: BASE, loadConfig: loadConfig, config: function () { return cfg; }, editor: emailEditor, preview: emailPreview, freshDraft: freshDraft, draftFrom: draftFrom,
    strip: strip, withIds: withIds, newBlock: newBlock, errorList: errorList, activeCoupons: activeCoupons, saveTemplate: saveTemplate, audienceText: audienceText, couponLabel: couponLabel,
    reportDialog: reportDialog, STATUS: STATUS,
    renderHistory: function (v) { return loadConfig().then(function () { renderCampaigns(v); }); },
    renderAutomations: function (v) { return loadConfig().then(function () { renderAutomation(v); }); },
    renderTemplates: function (v) { return loadConfig().then(function () { renderTemplates(v); }); },
    renderSettings: function (v) { return loadConfig().then(function () { renderSettings(v); }); },
  };
  /** Coupons page: "E-mail this coupon" opens the wizard with a coupon e-mail ready (the coupon filled in). */
  CR.emailCoupon = function (code) { CR.state.wizardPrefill = { starter: 'festive_coupon', coupon: code }; CR.go('#/email'); };
})();
