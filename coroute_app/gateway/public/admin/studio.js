/* CoRoute web admin: Marketing studio (template list, starters and the canvas editor).
   Uses studio_core.js (model, placeholders, painter) and the existing /api/admin/marketing/* endpoints. */
(function () {
  'use strict';
  var CR = window.CR; var MK = window.CRMK;
  var U = CR.util; var h = U.h; var clear = U.clear; var append = U.append;
  var ui = CR.ui; var api = CR.api;

  var imageCache = {}; // id -> Promise<ImageBitmap|null>
  var labels = {}; // plan id -> label, from /admin/marketing/coupons
  var editor = null; // the open editor (for teardown)

  function fontsReady() {
    if (!document.fonts || !document.fonts.load) return Promise.resolve();
    return Promise.all([document.fonts.load('800 40px Manrope'), document.fonts.load('500 40px Manrope')]).catch(function () {});
  }
  function loadImage(id) {
    if (!id) return Promise.resolve(null);
    if (!imageCache[id]) {
      imageCache[id] = api('GET', '/admin/marketing/images/' + encodeURIComponent(id), null, { raw: true })
        .then(function (res) { return res.blob(); }).then(function (b) { return createImageBitmap(b); }).catch(function () { delete imageCache[id]; return null; });
    }
    return imageCache[id];
  }
  function loadImages(t) {
    var ids = MK.imageIds(t); var out = {};
    return Promise.all(ids.map(function (id) { return loadImage(id).then(function (img) { if (img) out[id] = img; }); })).then(function () { return out; });
  }
  function origin() { return (CR.state.config && CR.state.config.publicOrigin) || location.origin; }
  function values(t) { return MK.valuesFor(t, origin(), labels); }

  /** A small canvas preview of a template (fits a box of maxSide px). */
  function thumb(t, maxSide) {
    var k = Math.min(maxSide / t.size.width, maxSide / t.size.height);
    var c = h('canvas'); var dpr = window.devicePixelRatio || 1;
    c.width = Math.round(t.size.width * k * dpr); c.height = Math.round(t.size.height * k * dpr);
    c.style.width = Math.round(t.size.width * k) + 'px'; c.style.height = Math.round(t.size.height * k) + 'px';
    var draw = function (imgs) { var ctx = c.getContext('2d'); ctx.setTransform(k * dpr, 0, 0, k * dpr, 0, 0); MK.paint(ctx, t, values(t), imgs || {}); };
    fontsReady().then(function () { draw({}); return loadImages(t); }).then(function (imgs) { if (Object.keys(imgs).length) draw(imgs); });
    return c;
  }

  /** Full-resolution PNG of a template. */
  function renderPng(t) {
    return Promise.all([fontsReady(), loadImages(t)]).then(function (r) {
      var c = document.createElement('canvas'); c.width = t.size.width; c.height = t.size.height;
      MK.paint(c.getContext('2d'), t, values(t), r[1]);
      return new Promise(function (resolve, reject) { c.toBlob(function (b) { if (b && b.size) resolve(b); else reject(new Error('The image could not be made.')); }, 'image/png'); });
    });
  }
  function fileName(t, size) {
    var base = String(t.name || 'coroute-offer').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'coroute-offer';
    return base + (t.couponCode ? '-' + t.couponCode.toLowerCase() : '') + '-' + size.width + 'x' + size.height + '.png';
  }
  function couponWarning(t) {
    var c = t.coupon;
    if (!c) return t.couponCode ? 'The coupon ' + t.couponCode + ' could not be checked.' : null;
    if (c.missing) return c.warning || 'This coupon no longer exists.';
    if (c.status === 'EXPIRED' || (c.expiresAt && c.expiresAt < Date.now())) return 'The coupon ' + c.code + ' has expired. Riders cannot use it any more.';
    return c.warning || null;
  }

  // ==================================================================== list + starters
  function renderList(view) {
    var tab = 'active';
    var listBox = h('div', ui.loading());
    var tabs = h('div.row');
    var mkTab = function (id, label) { var b = h('button.btn.btn--sm', { type: 'button', text: label, onclick: function () { tab = id; sync(); load(); } }); b.dataset.tab = id; return b; };
    append(tabs, [mkTab('active', 'Active'), mkTab('archived', 'Archived')]);
    function sync() { tabs.querySelectorAll('button').forEach(function (b) { b.classList.toggle('is-on', b.dataset.tab === tab); }); }
    view.appendChild(ui.pageHead('Marketing studio', 'Offer and coupon images for social posts. Text can use {code}, {discount}, {validUntil}, {plan}, {name}, {cap} and {link}; the QR code and {link} open the plans page with the coupon filled in.',
      h('button.btn.btn--primary', { type: 'button', text: 'New image', onclick: function () { CR.go('#/marketing/new'); } })));
    view.appendChild(h('div.toolbar', tabs));
    view.appendChild(listBox);
    sync();
    function load() {
      clear(listBox).appendChild(ui.loading());
      Promise.all([api('GET', '/admin/marketing/templates?status=' + tab), CR.config().catch(function () { return null; }), loadLabels()]).then(function (r) {
        var list = r[0].templates || [];
        clear(listBox);
        if (!list.length) {
          listBox.appendChild(h('div.card', h('div.empty', tab === 'active' ? 'No templates yet. ' : 'Nothing archived. ', tab === 'active' ? h('a', { href: '#/marketing/new', text: 'Start from a starter template.' }) : null)));
          return;
        }
        var grid = h('div.studio-list');
        list.forEach(function (s) {
          var thumbBox = h('div.tcard__thumb', { onclick: function () { CR.go('#/marketing/edit/' + s.id); } });
          var warn = h('div');
          api('GET', '/admin/marketing/templates/' + encodeURIComponent(s.id)).then(function (full) {
            var t = MK.cleanTemplate(full.template);
            thumbBox.appendChild(thumb(t, 210));
            var w = couponWarning(t);
            if (w) warn.appendChild(ui.chip(t.coupon && t.coupon.missing ? 'Coupon missing' : (/expired/i.test(w) ? 'Coupon expired' : 'Coupon not active'), 'bad'));
          }).catch(function () { thumbBox.appendChild(h('span.muted.small', { text: 'Preview unavailable' })); });
          var actions = h('div.row');
          actions.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Open', onclick: function () { CR.go('#/marketing/edit/' + s.id); } }));
          actions.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Duplicate', onclick: function () {
            api('POST', '/admin/marketing/templates/' + s.id + '/duplicate', {}).then(function () { ui.toast('Duplicated.'); load(); }).catch(function (e) { ui.toast(e.message, true); });
          } }));
          actions.appendChild(h('button.btn.btn--sm', { type: 'button', text: s.status === 'archived' ? 'Restore' : 'Archive', onclick: function () {
            api('PATCH', '/admin/marketing/templates/' + s.id + '/status', { status: s.status === 'archived' ? 'active' : 'archived' }).then(function () { load(); }).catch(function (e) { ui.toast(e.message, true); });
          } }));
          actions.appendChild(h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'Delete', onclick: function () {
            ui.confirm('Delete ' + s.name + '?', 'The template is removed for every admin. Images you already exported are not affected.', 'Delete', true).then(function (ok) {
              if (ok) api('DELETE', '/admin/marketing/templates/' + s.id).then(function () { ui.toast('Deleted.'); load(); }).catch(function (e) { ui.toast(e.message, true); });
            });
          } }));
          grid.appendChild(h('div.tcard', thumbBox, h('div.tcard__body',
            h('div.tcard__name', { text: s.name, title: s.name }),
            h('div.muted.small', { text: s.size.width + '×' + s.size.height + (s.couponCode ? ' · ' + s.couponCode : ' · no coupon') + ' · ' + U.date(s.updatedAt) }),
            warn, actions)));
        });
        listBox.appendChild(grid);
      }).catch(function (e) { clear(listBox).appendChild(ui.error(e)); });
    }
    load();
  }

  function loadLabels() {
    return api('GET', '/admin/marketing/coupons?all=1').then(function (r) { labels = r.planLabels || {}; return r.coupons || []; });
  }

  function renderNew(view, coupon) {
    view.appendChild(ui.pageHead('New image', 'Pick a starter. It is copied into a new template you can change freely.',
      h('a.btn', { href: '#/marketing', text: 'Back to templates' })));
    var couponSel = h('select', { 'aria-label': 'Coupon' });
    var sizeSel = ui.select(MK.SIZE_PRESETS.filter(function (p) { return p.id !== 'whatsapp_status'; }).map(function (p) { return [p.id, p.label + ' ' + p.width + '×' + p.height]; }), 'instagram_post');
    var starters = h('div.starters', ui.loading());
    view.appendChild(h('div.card', h('div.grid2', ui.field('Coupon to show', couponSel, 'active coupons only'), ui.field('Size for a blank image', sizeSel))));
    view.appendChild(h('h2', { class: 'section-gap', text: 'Starters' }));
    view.appendChild(starters);
    Promise.all([loadLabels(), CR.config().catch(function () { return null; })]).then(function (r) {
      var coupons = r[0].filter(function (c) { return c.bindable; });
      couponSel.appendChild(h('option', { value: '', text: 'No coupon (sample values)' }));
      coupons.forEach(function (c) { couponSel.appendChild(h('option', { value: c.code, text: c.code + ' · ' + MK.discountText(c.discountType, c.discountValue) + (c.expiresAt ? ' · till ' + MK.formatDate(c.expiresAt) : ''), selected: c.code === coupon })); });
      if (coupon && !coupons.some(function (c) { return c.code === coupon; })) ui.toast('The coupon ' + coupon + ' is not active, so it cannot be used in a new image.', true);
      var byCode = {}; coupons.forEach(function (c) { byCode[c.code] = c; });
      function draw() {
        clear(starters);
        var c = byCode[couponSel.value] || null;
        var items = MK.STARTERS.map(function (s) { return { id: s.id, title: s.title, description: s.description, build: s.build }; });
        items.push({ id: 'blank', title: 'Blank', description: 'A headline, a coupon and the logo on a plain gradient.', build: function () { return MK.blank({ preset: sizeSel.value }); } });
        items.forEach(function (s) {
          var t = s.build(); t.couponCode = c ? c.code : null; t.coupon = c;
          var btn = h('button.starter', { type: 'button', dataset: { starter: s.id } }, h('div.tcard__thumb', thumb(t, 200)), h('div.starter__body', h('b', { text: s.title }), h('span', { text: s.description })));
          btn.addEventListener('click', function () { create(t, btn); });
          starters.appendChild(btn);
        });
      }
      couponSel.addEventListener('change', draw); sizeSel.addEventListener('change', draw);
      draw();
    }).catch(function (e) { clear(starters).appendChild(ui.error(e)); });
    function create(t, btn) {
      btn.disabled = true;
      if (!t.caption) t.caption = MK.autoCaption(values(t), !!t.couponCode);
      api('POST', '/admin/marketing/templates', MK.templateToJson(t)).then(function (r) {
        ui.toast('Template created.');
        CR.go('#/marketing/edit/' + r.template.id);
      }).catch(function (e) { btn.disabled = false; ui.toast(e.message, true); });
    }
  }

  // ==================================================================== editor
  function renderEditor(view, id) {
    var wrap = h('div', ui.loading());
    view.appendChild(wrap);
    Promise.all([api('GET', '/admin/marketing/templates/' + encodeURIComponent(id)), loadLabels(), CR.config().catch(function () { return null; }), fontsReady()]).then(function (r) {
      clear(wrap);
      editor = new Editor(wrap, MK.cleanTemplate(r[0].template), r[1]);
    }).catch(function (e) { clear(wrap).appendChild(ui.error(e)); wrap.appendChild(h('a.btn', { href: '#/marketing', text: 'Back to templates' })); });
  }

  function Editor(root, t, coupons) {
    var ed = this;
    this.t = t; this.coupons = coupons; this.sel = null; this.dirty = false; this.hist = new MK.History(80);
    this.images = {}; this.guides = []; this.drag = null; this.saving = false;
    var nameIn = h('input', { type: 'text', maxlength: String(MK.LIMITS.nameMax), value: t.name, 'aria-label': 'Template name' });
    nameIn.addEventListener('focus', function () { ed.hist.record(ed.t); });
    nameIn.addEventListener('input', function () { ed.t.name = nameIn.value; ed.markDirty(); });
    this.dirtyChip = ui.chip('Saved', 'ok');
    this.saveBtn = h('button.btn.btn--primary', { type: 'button', text: 'Save', onclick: function () { ed.save(); } });
    this.undoBtn = h('button.btn.btn--sm', { type: 'button', text: 'Undo', title: 'Undo (Ctrl+Z)', onclick: function () { ed.undo(); } });
    this.redoBtn = h('button.btn.btn--sm', { type: 'button', text: 'Redo', title: 'Redo (Ctrl+Shift+Z)', onclick: function () { ed.redo(); } });
    var exportBtn = h('button.btn', { type: 'button', text: 'Export PNG', onclick: function () { ed.exportPng(false); } });
    var exportAll = h('button.btn', { type: 'button', text: 'All sizes', title: 'Square, story and banner PNGs', onclick: function () { ed.exportPng(true); } });
    root.appendChild(h('div.page-head', h('div.row', h('a.btn.btn--ghost.btn--sm', { href: '#/marketing', text: '← Templates' }), nameIn), h('span.spacer'),
      h('div.row', this.dirtyChip, this.undoBtn, this.redoBtn, exportBtn, exportAll, this.saveBtn)));
    nameIn.classList.add('name-input');
    this.warnBox = h('div');
    root.appendChild(this.warnBox);

    this.left = h('div.editor__panel');
    this.right = h('div.editor__panel');
    this.canvas = h('canvas', { tabindex: '0', 'aria-label': 'Design canvas. Click a layer to select it, drag to move, arrow keys nudge.' });
    this.area = h('div.stage__area', this.canvas);
    this.zoomLabel = h('span.muted.small');
    var bar = h('div.stage__bar',
      h('button.btn.btn--sm', { type: 'button', text: 'Duplicate', onclick: function () { ed.duplicate(); } }),
      h('button.btn.btn--sm', { type: 'button', text: 'Forward', onclick: function () { ed.zorder(1); } }),
      h('button.btn.btn--sm', { type: 'button', text: 'Backward', onclick: function () { ed.zorder(-1); } }),
      h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'Delete', onclick: function () { ed.removeSel(); } }),
      h('span.spacer'), this.zoomLabel);
    root.appendChild(h('div.editor', this.left, h('div.editor__stage', bar, this.area), this.right));

    this.bindCanvas();
    this.onKey = function (e) { ed.key(e); };
    document.addEventListener('keydown', this.onKey);
    this.onResize = function () { ed.layout(); };
    window.addEventListener('resize', this.onResize);
    this.onUnload = function (e) { if (ed.dirty) { e.preventDefault(); e.returnValue = ''; } };
    window.addEventListener('beforeunload', this.onUnload);
    CR.onTheme = function () { ed.draw(); };
    if (window.ResizeObserver) { this.ro = new ResizeObserver(function () { ed.layout(); }); this.ro.observe(this.area); }
    this.refreshImages();
    this.renderLeft(); this.renderRight(); this.renderWarn();
    this.layout();
    this.syncButtons();
  }

  Editor.prototype.teardown = function () {
    document.removeEventListener('keydown', this.onKey);
    window.removeEventListener('resize', this.onResize);
    window.removeEventListener('beforeunload', this.onUnload);
    if (this.ro) this.ro.disconnect();
    CR.onTheme = null;
  };
  Editor.prototype.selLayer = function () { var id = this.sel; return this.t.layers.filter(function (l) { return l.id === id; })[0] || null; };
  Editor.prototype.markDirty = function () { this.dirty = true; this.dirtyChip.textContent = 'Unsaved'; this.dirtyChip.className = 'chip chip--warn'; this.syncButtons(); };
  Editor.prototype.syncButtons = function () { this.undoBtn.disabled = !this.hist.undoStack.length; this.redoBtn.disabled = !this.hist.redoStack.length; };
  /** Records an undo step, applies fn, redraws (and re-renders the panels unless light). */
  Editor.prototype.change = function (fn, light) {
    this.hist.record(this.t); fn(); this.markDirty(); this.draw();
    if (!light) { this.renderLeft(); this.renderRight(); }
  };
  Editor.prototype.undo = function () { var t = this.hist.undo(this.t); if (t) { this.t = t; this.afterHistory(); } };
  Editor.prototype.redo = function () { var t = this.hist.redo(this.t); if (t) { this.t = t; this.afterHistory(); } };
  Editor.prototype.afterHistory = function () {
    if (!this.selLayer()) this.sel = null;
    this.markDirty(); this.refreshImages(); this.layout(); this.renderLeft(); this.renderRight(); this.renderWarn();
  };
  Editor.prototype.refreshImages = function () { var ed = this; loadImages(this.t).then(function (m) { ed.images = m; ed.draw(); }); };

  // ---------------- stage geometry & drawing
  Editor.prototype.layout = function () {
    var rect = this.area.getBoundingClientRect();
    var availW = Math.max(120, rect.width - 36); var availH = Math.max(120, rect.height - 36);
    var W = this.t.size.width; var H = this.t.size.height;
    this.scale = Math.min(availW / W, availH / H);
    var dpr = window.devicePixelRatio || 1;
    this.canvas.style.width = Math.round(W * this.scale) + 'px'; this.canvas.style.height = Math.round(H * this.scale) + 'px';
    this.canvas.width = Math.round(W * this.scale * dpr); this.canvas.height = Math.round(H * this.scale * dpr);
    this.dpr = dpr;
    this.zoomLabel.textContent = W + '×' + H + ' · ' + Math.round(this.scale * 100) + '%';
    this.draw();
  };
  Editor.prototype.draw = function () {
    var ctx = this.canvas.getContext('2d'); var k = this.scale * this.dpr;
    ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    ctx.setTransform(k, 0, 0, k, 0, 0);
    MK.paint(ctx, this.t, values(this.t), this.images);
    // Overlay in screen pixels: guides, selection box, handles.
    ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    var s = this.scale; var W = this.t.size.width * s; var H = this.t.size.height * s;
    ctx.save(); ctx.strokeStyle = '#FF3D9A'; ctx.lineWidth = 1; ctx.setLineDash([4, 3]);
    this.guides.forEach(function (g) { ctx.beginPath(); if (g.v !== undefined) { ctx.moveTo(g.v * W + 0.5, 0); ctx.lineTo(g.v * W + 0.5, H); } else { ctx.moveTo(0, g.h * H + 0.5); ctx.lineTo(W, g.h * H + 0.5); } ctx.stroke(); });
    ctx.restore();
    var l = this.selLayer();
    if (l && !l.hidden) {
      var b = this.screenBox(l);
      ctx.save(); ctx.translate(b.cx, b.cy); ctx.rotate(b.angle);
      ctx.strokeStyle = '#2B7A8C'; ctx.lineWidth = 1.5; ctx.setLineDash(l.locked ? [5, 4] : []);
      ctx.strokeRect(-b.w / 2, -b.h / 2, b.w, b.h);
      ctx.setLineDash([]);
      if (!l.locked) {
        ctx.fillStyle = '#FFFFFF';
        this.handles(b).forEach(function (hd) {
          ctx.beginPath();
          if (hd.kind === 'rotate') { ctx.moveTo(0, -b.h / 2); ctx.lineTo(0, hd.ly + 6); ctx.stroke(); ctx.beginPath(); ctx.arc(hd.lx, hd.ly, 6, 0, 7); }
          else ctx.rect(hd.lx - 5, hd.ly - 5, 10, 10);
          ctx.fill(); ctx.stroke();
        });
      }
      ctx.restore();
    }
  };
  Editor.prototype.screenBox = function (l) { var s = this.scale; var W = this.t.size.width; var H = this.t.size.height; return { cx: l.x * W * s, cy: l.y * H * s, w: l.w * W * s, h: l.h * H * s, angle: l.rotation * Math.PI / 180 }; };
  Editor.prototype.handles = function (b) {
    return [{ kind: 'nw', lx: -b.w / 2, ly: -b.h / 2 }, { kind: 'ne', lx: b.w / 2, ly: -b.h / 2 }, { kind: 'sw', lx: -b.w / 2, ly: b.h / 2 }, { kind: 'se', lx: b.w / 2, ly: b.h / 2 },
      { kind: 'e', lx: b.w / 2, ly: 0 }, { kind: 'w', lx: -b.w / 2, ly: 0 }, { kind: 'n', lx: 0, ly: -b.h / 2 }, { kind: 's', lx: 0, ly: b.h / 2 },
      { kind: 'rotate', lx: 0, ly: -b.h / 2 - 26 }];
  };
  /** Pointer position in screen px relative to the canvas. */
  Editor.prototype.pt = function (e) { var r = this.canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
  function toLocal(b, p) { var dx = p.x - b.cx; var dy = p.y - b.cy; var c = Math.cos(-b.angle); var s = Math.sin(-b.angle); return { x: dx * c - dy * s, y: dx * s + dy * c }; }

  Editor.prototype.bindCanvas = function () {
    var ed = this; var c = this.canvas;
    c.addEventListener('pointerdown', function (e) {
      c.focus({ preventScroll: true });
      var p = ed.pt(e); var l = ed.selLayer();
      if (l && !l.locked && !l.hidden) {
        var b = ed.screenBox(l); var lp = toLocal(b, p);
        var hit = ed.handles(b).filter(function (hd) { return Math.abs(lp.x - hd.lx) <= 9 && Math.abs(lp.y - hd.ly) <= 9; })[0];
        if (hit) { ed.startDrag(hit.kind, p, e); return; }
      }
      var s = ed.scale;
      var idx = MK.hitTest(ed.t, p.x / s, p.y / s, 4 / s);
      if (idx < 0) { ed.select(null); return; }
      var hitL = ed.t.layers[idx];
      if (ed.sel !== hitL.id) ed.select(hitL.id);
      if (!hitL.locked) ed.startDrag('move', p, e);
    });
    c.addEventListener('pointermove', function (e) {
      if (ed.drag) { ed.moveDrag(ed.pt(e), e); return; }
      var p = ed.pt(e); var l = ed.selLayer(); var cur = 'default';
      if (l && !l.locked && !l.hidden) {
        var b = ed.screenBox(l); var lp = toLocal(b, p);
        var hit = ed.handles(b).filter(function (hd) { return Math.abs(lp.x - hd.lx) <= 9 && Math.abs(lp.y - hd.ly) <= 9; })[0];
        if (hit) cur = hit.kind === 'rotate' ? 'grab' : (/^(n|s)$/.test(hit.kind) ? 'ns-resize' : /^(e|w)$/.test(hit.kind) ? 'ew-resize' : (hit.kind === 'nw' || hit.kind === 'se' ? 'nwse-resize' : 'nesw-resize'));
        else if (MK.boxContains(b, p.x, p.y, 2)) cur = 'move';
      }
      c.style.cursor = cur;
    });
    var end = function () {
      if (!ed.drag) return;
      var moved = ed.drag.moved; ed.drag = null; ed.guides = [];
      ed.draw();
      if (moved) { ed.renderRight(); ed.renderLeft(); }
    };
    c.addEventListener('pointerup', end); c.addEventListener('pointercancel', end); c.addEventListener('lostpointercapture', end);
    c.addEventListener('dblclick', function () { var l = ed.selLayer(); if (l && l.type === 'text') { var ta = ed.right.querySelector('textarea'); if (ta) { ta.focus(); ta.select(); } } });
  };
  Editor.prototype.startDrag = function (kind, p, e) {
    var l = this.selLayer();
    this.canvas.setPointerCapture(e.pointerId);
    this.drag = { kind: kind, start: p, orig: JSON.parse(JSON.stringify(l)), moved: false, recorded: false };
  };
  Editor.prototype.moveDrag = function (p, e) {
    var d = this.drag; var l = this.selLayer(); if (!l) return;
    var dxs = p.x - d.start.x; var dys = p.y - d.start.y;
    if (!d.moved && Math.hypot(dxs, dys) < 2) return;
    if (!d.recorded) { this.hist.record(MK.cleanTemplate(Object.assign(MK.templateToJson(this.t), { layers: this.t.layers.map(function (x) { return x.id === l.id ? MK.layerToJson(Object.assign({}, x, d.orig)) : MK.layerToJson(x); }) }))); d.recorded = true; }
    d.moved = true;
    var W = this.t.size.width; var H = this.t.size.height; var s = this.scale; var o = d.orig;
    this.guides = [];
    if (d.kind === 'move') {
      var nx = o.x + dxs / (W * s); var ny = o.y + dys / (H * s);
      if (!e.altKey) { var sn = this.snap(l, nx, ny); nx = sn.x; ny = sn.y; }
      l.x = MK.clamp(nx, -0.5, 1.5); l.y = MK.clamp(ny, -0.5, 1.5);
    } else if (d.kind === 'rotate') {
      var b = this.screenBox(o);
      var ang = Math.atan2(p.y - b.cy, p.x - b.cx) * 180 / Math.PI + 90;
      l.rotation = e.shiftKey ? Math.round(ang / 15) * 15 : MK.snapRotation(ang);
      if (l.rotation > 180) l.rotation -= 360;
    } else {
      // Resize in the layer's own frame; the opposite edge / corner stays put.
      var bo = this.screenBox(o); var lp = toLocal(bo, p); var k = d.kind;
      var left = -bo.w / 2; var right = bo.w / 2; var top = -bo.h / 2; var bottom = bo.h / 2;
      if (k.indexOf('w') >= 0) left = Math.min(lp.x, right - 6); if (k.indexOf('e') >= 0) right = Math.max(lp.x, left + 6);
      if (k.indexOf('n') >= 0) top = Math.min(lp.y, bottom - 6); if (k.indexOf('s') >= 0) bottom = Math.max(lp.y, top + 6);
      var nw = right - left; var nh = bottom - top;
      var keep = MK.keepsAspect(l) || e.shiftKey;
      if (keep && k.length === 2) {
        var ratio = bo.w / bo.h;
        if (nw / nh > ratio) nw = nh * ratio; else nh = nw / ratio;
        if (k.indexOf('w') >= 0) left = right - nw; else right = left + nw;
        if (k.indexOf('n') >= 0) top = bottom - nh; else bottom = top + nh;
      }
      var cxl = (left + right) / 2; var cyl = (top + bottom) / 2;
      var cos = Math.cos(bo.angle); var sin = Math.sin(bo.angle);
      var cx = bo.cx + cxl * cos - cyl * sin; var cy = bo.cy + cxl * sin + cyl * cos;
      l.x = cx / (W * s); l.y = cy / (H * s);
      l.w = MK.clamp(nw / (W * s), 0.005, 3); l.h = MK.clamp(nh / (H * s), 0.005, 3);
    }
    this.markDirty(); this.draw();
  };
  /** Snap guides: the canvas centre lines and edges, and other layers' centres (within 6 screen px). */
  Editor.prototype.snap = function (l, x, y) {
    var W = this.t.size.width * this.scale; var H = this.t.size.height * this.scale; var thr = 6;
    var vs = [0.5, l.w / 2, 1 - l.w / 2]; var hs = [0.5, l.h / 2, 1 - l.h / 2];
    var vLines = [0.5, 0.5, 0, 1]; var hLines = [0.5, 0.5, 0, 1];
    var cand = function (targets, lines, v, size) {
      var best = null;
      targets.forEach(function (t, i) { var dd = Math.abs((v - t) * size); if (dd <= thr && (!best || dd < best.d)) best = { v: t, d: dd, line: lines[i] }; });
      return best;
    };
    var others = this.t.layers.filter(function (o) { return o.id !== l.id && !o.hidden; });
    others.forEach(function (o) { vs.push(o.x); vLines.push(o.x); hs.push(o.y); hLines.push(o.y); });
    var bx = cand(vs, [0.5, 0, 1].concat(others.map(function (o) { return o.x; })), x, W);
    var by = cand(hs, [0.5, 0, 1].concat(others.map(function (o) { return o.y; })), y, H);
    if (bx) { x = bx.v; this.guides.push({ v: bx.line }); }
    if (by) { y = by.v; this.guides.push({ h: by.line }); }
    return { x: x, y: y };
  };
  Editor.prototype.select = function (id) { this.sel = id; this.draw(); this.renderLeft(); this.renderRight(); };

  Editor.prototype.key = function (e) {
    var tag = (e.target && e.target.tagName) || '';
    var typing = /INPUT|TEXTAREA|SELECT/.test(tag);
    var mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); this.save(); return; }
    if (typing) return;
    if (mod && e.key.toLowerCase() === 'z') { e.preventDefault(); if (e.shiftKey) this.redo(); else this.undo(); return; }
    if (mod && e.key.toLowerCase() === 'y') { e.preventDefault(); this.redo(); return; }
    var l = this.selLayer(); if (!l) return;
    if (mod && e.key.toLowerCase() === 'd') { e.preventDefault(); this.duplicate(); return; }
    if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); this.removeSel(); return; }
    if (e.key === 'Escape') { this.select(null); return; }
    var step = (e.shiftKey ? 10 : 1);
    var mv = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
    if (mv && !l.locked) {
      e.preventDefault();
      var ed = this;
      this.change(function () { l.x += mv[0] * step / ed.t.size.width; l.y += mv[1] * step / ed.t.size.height; }, true);
    }
  };

  // ---------------- layer operations
  Editor.prototype.add = function (layer) {
    if (this.t.layers.length >= MK.LIMITS.maxLayers) { ui.toast('At most ' + MK.LIMITS.maxLayers + ' layers.', true); return; }
    var ed = this;
    this.change(function () { ed.t.layers.push(layer); ed.sel = layer.id; });
  };
  Editor.prototype.duplicate = function () {
    var l = this.selLayer(); if (!l) return;
    if (this.t.layers.length >= MK.LIMITS.maxLayers) { ui.toast('At most ' + MK.LIMITS.maxLayers + ' layers.', true); return; }
    var ed = this;
    this.change(function () {
      var c = MK.cleanLayer(JSON.parse(JSON.stringify(MK.layerToJson(l))));
      c.id = MK.nextLayerId(ed.t, l.type); c.x = Math.min(1.5, l.x + 0.03); c.y = Math.min(1.5, l.y + 0.03); c.locked = false;
      ed.t.layers.splice(ed.t.layers.indexOf(l) + 1, 0, c); ed.sel = c.id;
    });
  };
  Editor.prototype.removeSel = function () {
    var l = this.selLayer(); if (!l) return;
    var ed = this;
    this.change(function () { ed.t.layers.splice(ed.t.layers.indexOf(l), 1); ed.sel = null; });
    this.renderWarn();
  };
  Editor.prototype.zorder = function (dir, layer) {
    var l = layer || this.selLayer(); if (!l) return;
    var a = this.t.layers; var i = a.indexOf(l); var j = i + dir;
    if (j < 0 || j >= a.length) return;
    this.change(function () { a.splice(i, 1); a.splice(j, 0, l); });
  };

  // ---------------- left panel: template settings, add, layers
  Editor.prototype.renderLeft = function () {
    var ed = this; var t = this.t; var p = clear(this.left);
    // Size
    var sizeSel = ui.select(MK.SIZE_PRESETS.map(function (s) { return [s.id, s.label + ' ' + s.width + '×' + s.height]; }).concat([['custom', 'Custom size']]), t.size.preset, { 'aria-label': 'Canvas size' });
    var cw = h('input', { type: 'number', min: String(MK.LIMITS.minSide), max: String(MK.LIMITS.maxSide), value: String(t.size.width), 'aria-label': 'Width' });
    var ch = h('input', { type: 'number', min: String(MK.LIMITS.minSide), max: String(MK.LIMITS.maxSide), value: String(t.size.height), 'aria-label': 'Height' });
    var custom = h('div.grid2', { hidden: t.size.preset !== 'custom' }, ui.field('Width', cw), ui.field('Height', ch));
    var resize = function (size) {
      ed.change(function () { var n = MK.retarget(ed.t, size); ed.t.size = n.size; ed.t.layers = n.layers; });
      ed.layout();
    };
    sizeSel.addEventListener('change', function () {
      if (sizeSel.value === 'custom') { custom.hidden = false; resize({ preset: 'custom', width: t.size.width, height: t.size.height }); return; }
      resize({ preset: sizeSel.value });
    });
    var applyCustom = function () { var w = parseInt(cw.value, 10); var hh = parseInt(ch.value, 10); if (w && hh) resize({ preset: 'custom', width: w, height: hh }); };
    cw.addEventListener('change', applyCustom); ch.addEventListener('change', applyCustom);
    // Coupon
    var cSel = h('select', { 'aria-label': 'Coupon' });
    cSel.appendChild(h('option', { value: '', text: 'No coupon (sample values)' }));
    var seen = false;
    this.coupons.forEach(function (c) {
      if (!c.bindable && c.code !== t.couponCode) return;
      if (c.code === t.couponCode) seen = true;
      cSel.appendChild(h('option', { value: c.code, selected: c.code === t.couponCode, text: c.code + ' · ' + MK.discountText(c.discountType, c.discountValue) + (c.bindable ? '' : ' (' + c.status.toLowerCase() + ')') }));
    });
    if (t.couponCode && !seen) cSel.appendChild(h('option', { value: t.couponCode, selected: true, text: t.couponCode + ' (missing)' }));
    cSel.addEventListener('change', function () {
      var code = cSel.value || null;
      var c = ed.coupons.filter(function (x) { return x.code === code; })[0] || null;
      ed.change(function () { ed.t.couponCode = code; ed.t.coupon = c; });
      ed.renderWarn();
    });
    var link = h('input', { type: 'text', maxlength: String(MK.LIMITS.linkMax), value: t.link, placeholder: 'default: plans page with the coupon' });
    link.addEventListener('focus', function () { ed.hist.record(ed.t); });
    link.addEventListener('input', function () { ed.t.link = link.value; ed.markDirty(); ed.draw(); linkOut.textContent = values(ed.t).link; });
    var linkOut = h('div.muted.small.mono.linkout', { text: values(t).link });
    append(p, [h('div.inspector-sec', h('div.panel-title', { text: 'Canvas' }), sizeSel, custom),
      h('div.inspector-sec', h('div.panel-title', { text: 'Coupon' }), cSel, ui.field('Link for {link} and QR', link, '{code} allowed'), linkOut)]);
    // Add
    var add = function (label, fn) { return h('button.btn.btn--sm', { type: 'button', text: label, onclick: fn }); };
    var nid = function (prefix) { return MK.nextLayerId(ed.t, prefix); };
    append(p, [h('div.inspector-sec', h('div.panel-title', { text: 'Add' }), h('div.addgrid',
      add('Text', function () { ed.add(MK.newLayer.text(nid('text'), 'New text', 0.5)); }),
      add('Coupon', function () { ed.add(MK.newLayer.coupon(nid('coupon'))); }),
      add('Logo', function () { ed.add(MK.newLayer.logo(nid('logo'))); }),
      add('QR code', function () { ed.add(MK.newLayer.qr(nid('qr'))); }),
      add('Badge', function () { ed.add(MK.newLayer.shape(nid('badge'), 'burst', 'NEW')); }),
      add('Ribbon', function () { ed.add(MK.newLayer.shape(nid('ribbon'), 'ribbon', 'LIMITED')); }),
      add('Shape', function () { ed.add(MK.newLayer.shape(nid('shape'), 'rect', '')); }),
      add('Image…', function () { pickImage(function (img) { ed.add(MK.newLayer.image(nid('image'), img.id)); ed.refreshImages(); }); })))]);
    // Layers (top first)
    var list = h('ul.layers');
    t.layers.slice().reverse().forEach(function (l) {
      var li = h('li', { class: l.id === ed.sel ? 'is-sel' : '', dataset: { layer: l.id }, onclick: function () { ed.select(l.id); } },
        h('span.lname', { text: MK.displayName(l), title: MK.displayName(l) }), h('span.ltype', { text: l.type }),
        h('div.lbtns',
        h('button', { type: 'button', title: l.hidden ? 'Show' : 'Hide', text: l.hidden ? 'show' : 'hide', onclick: function (e) { e.stopPropagation(); ed.change(function () { l.hidden = !l.hidden; }); } }),
        h('button', { type: 'button', title: l.locked ? 'Unlock' : 'Lock', text: l.locked ? 'unlock' : 'lock', onclick: function (e) { e.stopPropagation(); ed.change(function () { l.locked = !l.locked; }); } }),
        h('button', { type: 'button', title: 'Move up', text: '↑', onclick: function (e) { e.stopPropagation(); ed.zorder(1, l); } }),
        h('button', { type: 'button', title: 'Move down', text: '↓', onclick: function (e) { e.stopPropagation(); ed.zorder(-1, l); } })));
      list.appendChild(li);
    });
    append(p, [h('div.inspector-sec', h('div.panel-title', { text: 'Layers (' + t.layers.length + '/' + MK.LIMITS.maxLayers + ')' }), t.layers.length ? list : h('p.muted.small', { text: 'No layers.' }))]);
  };

  // ---------------- right panel: inspector + caption
  function colorInput(value, onChange, opts) {
    opts = opts || {};
    var hex = value || '#000000';
    var picker = h('input', { type: 'color', value: hex.slice(0, 7) });
    var text = h('input', { type: 'text', value: hex, maxlength: '9', spellcheck: 'false' });
    var commit = function (v) { if (/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(v)) { onChange(v.toUpperCase()); } };
    picker.addEventListener('input', function () { var v = picker.value.toUpperCase() + (hex.length > 7 ? hex.slice(7) : ''); text.value = v; hex = v; commit(v); });
    text.addEventListener('change', function () { hex = text.value; if (/^#[0-9a-fA-F]{6}/.test(hex)) picker.value = hex.slice(0, 7); commit(hex); });
    var sw = h('div.swatches');
    MK.SWATCHES.forEach(function (c) { var b = h('button.swatch', { type: 'button', title: c, 'aria-label': c }); b.style.background = c; b.addEventListener('click', function () { text.value = c; picker.value = c; hex = c; commit(c); }); sw.appendChild(b); });
    var row = h('div.colorrow', picker, text);
    if (opts.clearable) row.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'None', onclick: function () { onChange(null); } }));
    return h('div.stack', { class: 'stack' }, row, opts.noSwatches ? null : sw);
  }
  Editor.prototype.renderRight = function () {
    var ed = this; var p = clear(this.right); var l = this.selLayer();
    var set = function (obj, key, light) { return function (v) { ed.change(function () { obj[key] = v; }, light !== false); }; };
    var num = function (obj, key, min, max, step, light) {
      var inp = h('input', { type: 'number', min: String(min), max: String(max), step: String(step || 1), value: String(Math.round(obj[key] * 1000) / 1000) });
      inp.addEventListener('change', function () { var v = Number(inp.value); if (isFinite(v)) ed.change(function () { obj[key] = MK.clamp(v, min, max); }, light !== false); });
      return inp;
    };
    var range = function (obj, key, min, max, step) {
      var inp = h('input', { type: 'range', min: String(min), max: String(max), step: String(step), value: String(obj[key]) });
      inp.addEventListener('pointerdown', function () { ed.hist.record(ed.t); });
      inp.addEventListener('input', function () { obj[key] = Number(inp.value); ed.markDirty(); ed.draw(); });
      return inp;
    };
    var sel = function (obj, key, options, light, cast) { var s = ui.select(options, obj[key]); s.addEventListener('change', function () { ed.change(function () { obj[key] = cast ? cast(s.value) : s.value; }, light); }); return s; };
    var check = function (obj, key, label) { var c = h('input', { type: 'checkbox', checked: !!obj[key] }); c.addEventListener('change', function () { ed.change(function () { obj[key] = c.checked; }); }); return h('label.check', c, label); };
    var textArea = function (obj, key, max, rows) {
      var ta = h('textarea', { rows: String(rows || 3), maxlength: String(max), value: obj[key] || '' });
      ta.addEventListener('focus', function () { ed.hist.record(ed.t); });
      ta.addEventListener('input', function () { obj[key] = ta.value; ed.markDirty(); ed.draw(); });
      ta.addEventListener('blur', function () { ed.renderLeft(); });
      return ta;
    };
    var phChips = function (target) {
      return h('div.ph-chips', MK.PLACEHOLDERS.map(function (n) {
        return h('button', { type: 'button', text: '{' + n + '}', onclick: function () {
          var ta = target(); if (!ta) return;
          var a = ta.selectionStart || ta.value.length; ta.focus();
          ta.setRangeText('{' + n + '}', a, ta.selectionEnd || a, 'end'); ta.dispatchEvent(new Event('input'));
        } });
      }));
    };
    var opts = function (arr, labelsMap) { return arr.map(function (x) { return [x, labelsMap ? labelsMap[x] || x : x]; }); };

    if (!l) {
      var bg = this.t.background;
      var secs = [h('div.panel-title', { text: 'Background' }), ui.field('Kind', sel(bg, 'kind', [['solid', 'Solid colour'], ['gradient', 'Gradient'], ['image', 'Image']]))];
      if (bg.kind === 'gradient') {
        bg.colors.forEach(function (c, i) { secs.push(ui.field('Colour ' + (i + 1), colorInput(c, function (v) { ed.change(function () { bg.colors[i] = v; }, true); }, { noSwatches: i > 0 }))); });
        secs.push(h('div.row', h('button.btn.btn--sm', { type: 'button', text: 'Add colour', disabled: bg.colors.length >= 4, onclick: function () { ed.change(function () { bg.colors.push(MK.BRAND.amber); }); } }),
          h('button.btn.btn--sm', { type: 'button', text: 'Remove colour', disabled: bg.colors.length <= 2, onclick: function () { ed.change(function () { bg.colors.pop(); }); } })));
        secs.push(ui.field('Angle', range(bg, 'angle', 0, 360, 1)));
      } else secs.push(ui.field(bg.kind === 'image' ? 'Colour behind the image' : 'Colour', colorInput(bg.color, set(bg, 'color'))));
      if (bg.kind === 'image') {
        secs.push(h('div.row', h('button.btn.btn--sm', { type: 'button', text: bg.imageId ? 'Change image…' : 'Pick image…', onclick: function () { pickImage(function (img) { ed.change(function () { bg.imageId = img.id; }); ed.refreshImages(); }); } }),
          sel(bg, 'imageFit', [['cover', 'Cover'], ['contain', 'Contain']], true)));
        if (!bg.imageId) secs.push(h('div.banner', { text: 'Pick a background image, or choose another kind.' }));
      }
      secs.push(ui.field('Pattern', sel(bg, 'pattern', opts(MK.PATTERNS))));
      if (bg.pattern !== 'none') { secs.push(ui.field('Pattern colour', colorInput(bg.patternColor, set(bg, 'patternColor'), { noSwatches: true }))); secs.push(ui.field('Pattern strength', range(bg, 'patternOpacity', 0, 1, 0.01))); }
      secs.push(ui.field('Tint over the background', colorInput(bg.overlay, set(bg, 'overlay'), { clearable: true, noSwatches: true }), 'e.g. #00000066 darkens a photo'));
      p.appendChild(h('div.inspector-sec', secs));
      p.appendChild(h('p.muted.small', { text: 'Click a layer on the canvas or in the list to edit it. Drag to move (Alt: no snapping), corner handles resize (Shift keeps the shape), the round handle rotates.' }));
    } else {
      var secs2 = [h('div.row', h('div.panel-title', { text: MK.TYPE_LABEL[l.type] }), h('span.spacer'), h('span.muted.small.mono', { text: l.id }))];
      var nameIn = h('input', { type: 'text', maxlength: String(MK.LIMITS.layerNameMax), value: l.name, placeholder: MK.displayName(l) });
      nameIn.addEventListener('change', function () { ed.change(function () { l.name = nameIn.value.trim(); }); });
      secs2.push(ui.field('Layer name', nameIn));
      if (l.type === 'text') {
        var ta = textArea(l, 'text', MK.LIMITS.textMax, 3);
        secs2.push(ui.field('Text', ta), phChips(function () { return ta; }));
        secs2.push(h('div.grid2', ui.field('Font', sel(l, 'font', opts(MK.FONTS), true)), ui.field('Weight', sel(l, 'weight', [[400, 'Regular'], [500, 'Medium'], [600, 'Semibold'], [700, 'Bold'], [800, 'Extra bold'], [900, 'Black']], true, Number))));
        secs2.push(h('div.grid2', ui.field('Size', num(l, 'size', 4, 600, 1)), ui.field('Align', sel(l, 'align', [['left', 'Left'], ['center', 'Centre'], ['right', 'Right']], true))));
        secs2.push(h('div.grid2', ui.field('Line height', num(l, 'lineHeight', 0.7, 3, 0.05)), ui.field('Letter spacing', num(l, 'letterSpacing', -20, 100, 1))));
        secs2.push(ui.field('Colour', colorInput(l.color, set(l, 'color'))));
        secs2.push(h('div.row', check(l, 'uppercase', 'Upper case'), check(l, 'italic', 'Italic')));
        var fitC = h('input', { type: 'checkbox', checked: l.fit === 'shrink' }); fitC.addEventListener('change', function () { ed.change(function () { l.fit = fitC.checked ? 'shrink' : 'none'; }); });
        secs2.push(h('label.check', fitC, 'Shrink to fit the box'));
        var shC = h('input', { type: 'checkbox', checked: !!l.shadow }); shC.addEventListener('change', function () { ed.change(function () { l.shadow = shC.checked ? { color: '#00000066', blur: 16, dx: 0, dy: 6 } : null; }); });
        secs2.push(h('label.check', shC, 'Shadow'));
        if (l.shadow) secs2.push(h('div.grid2', ui.field('Blur', num(l.shadow, 'blur', 0, 100, 1)), ui.field('Offset Y', num(l.shadow, 'dy', -100, 100, 1))), ui.field('Shadow colour', colorInput(l.shadow.color, set(l.shadow, 'color'), { noSwatches: true })));
      } else if (l.type === 'coupon') {
        var hd = textArea(l, 'headline', MK.LIMITS.couponLineMax, 1); var cd = textArea(l, 'codeLine', MK.LIMITS.couponLineMax, 1); var ft = textArea(l, 'footer', MK.LIMITS.couponLineMax, 1);
        var lastTa = hd; [hd, cd, ft].forEach(function (x) { x.addEventListener('focus', function () { lastTa = x; }); });
        secs2.push(ui.field('Style', sel(l, 'style', [['ticket', 'Ticket'], ['pill', 'Pill'], ['card', 'Card'], ['stamp', 'Stamp']], true)));
        secs2.push(ui.field('Headline', hd), ui.field('Code line', cd), ui.field('Footer', ft), phChips(function () { return lastTa; }));
        secs2.push(ui.field('Fill', colorInput(l.fill, set(l, 'fill'))), ui.field('Text', colorInput(l.textColor, set(l, 'textColor'), { noSwatches: true })), ui.field('Accent', colorInput(l.accent, set(l, 'accent'), { noSwatches: true })));
        secs2.push(ui.field('Font', sel(l, 'font', opts(MK.FONTS), true)));
      } else if (l.type === 'logo') {
        secs2.push(ui.field('Variant', sel(l, 'variant', [['wordmark', 'Mark + CoRoute'], ['mark', 'Mark only']], true)));
        if (l.variant === 'wordmark') secs2.push(ui.field('Word colour', colorInput(l.color, set(l, 'color'))));
      } else if (l.type === 'shape') {
        var lb = h('input', { type: 'text', maxlength: String(MK.LIMITS.shapeLabelMax), value: l.label });
        lb.addEventListener('focus', function () { ed.hist.record(ed.t); });
        lb.addEventListener('input', function () { l.label = lb.value; ed.markDirty(); ed.draw(); });
        secs2.push(ui.field('Shape', sel(l, 'shape', opts(MK.SHAPES))), ui.field('Label', lb), phChips(function () { return lb; }));
        secs2.push(ui.field('Fill', colorInput(l.fill, set(l, 'fill'))), ui.field('Label colour', colorInput(l.labelColor, set(l, 'labelColor'), { noSwatches: true })));
        secs2.push(h('div.grid2', ui.field('Label size', num(l, 'labelSize', 4, 300, 1)), ui.field('Corner radius', num(l, 'radius', 0, 500, 1))));
        secs2.push(h('div.grid2', ui.field('Outline width', num(l, 'strokeWidth', 0, 60, 1)), ui.field('Font', sel(l, 'font', opts(MK.FONTS), true))));
        secs2.push(ui.field('Outline colour', colorInput(l.stroke, set(l, 'stroke'), { clearable: true, noSwatches: true })));
      } else if (l.type === 'image') {
        secs2.push(h('div.row', h('button.btn.btn--sm', { type: 'button', text: 'Change image…', onclick: function () { pickImage(function (img) { ed.change(function () { l.imageId = img.id; }); ed.refreshImages(); }); } }), sel(l, 'fit', [['cover', 'Cover'], ['contain', 'Contain']], true)));
        secs2.push(ui.field('Corner radius', num(l, 'radius', 0, 500, 1)));
      } else if (l.type === 'qr') {
        var qd = h('input', { type: 'text', maxlength: String(MK.LIMITS.linkMax), value: l.data });
        qd.addEventListener('focus', function () { ed.hist.record(ed.t); });
        qd.addEventListener('input', function () { l.data = qd.value; ed.markDirty(); ed.draw(); qOut.textContent = MK.substitute(l.data, values(ed.t)); });
        var qOut = h('div.muted.small.mono.linkout', { text: MK.substitute(l.data, values(this.t)) });
        secs2.push(ui.field('QR content', qd, '{link} = the coupon link'), qOut);
        secs2.push(ui.field('Dots', colorInput(l.color, set(l, 'color'), { noSwatches: true })), ui.field('Background', colorInput(l.background, set(l, 'background'), { noSwatches: true })));
        secs2.push(h('p.muted.small', { text: 'Keep strong contrast (dark dots on light) so phones can scan it.' }));
      }
      p.appendChild(h('div.inspector-sec', secs2));
      p.appendChild(h('div.inspector-sec', h('div.panel-title', { text: 'Position' }),
        h('div.grid2', ui.field('X %', pct(l, 'x')), ui.field('Y %', pct(l, 'y'))),
        h('div.grid2', ui.field('Width %', pct(l, 'w')), ui.field('Height %', pct(l, 'h'))),
        h('div.grid2', ui.field('Rotation', num(l, 'rotation', -360, 360, 1)), ui.field('Opacity', range(l, 'opacity', 0, 1, 0.01))),
        h('div.row', h('button.btn.btn--sm', { type: 'button', text: 'Centre horizontally', onclick: function () { ed.change(function () { l.x = 0.5; }); } }),
          h('button.btn.btn--sm', { type: 'button', text: 'Centre vertically', onclick: function () { ed.change(function () { l.y = 0.5; }); } }))));
    }
    // Caption
    var cap = h('textarea', { rows: '5', maxlength: String(MK.LIMITS.captionMax), value: this.t.caption });
    cap.addEventListener('focus', function () { ed.hist.record(ed.t); });
    var capOut = h('div.small', { text: MK.substitute(this.t.caption, values(this.t)) });
    capOut.classList.add('muted');
    cap.addEventListener('input', function () { ed.t.caption = cap.value; ed.markDirty(); capOut.textContent = MK.substitute(ed.t.caption, values(ed.t)); });
    p.appendChild(h('div.inspector-sec', h('div.panel-title', { text: 'Caption' }), cap, phChips(function () { return cap; }),
      h('div.row', h('button.btn.btn--sm', { type: 'button', text: 'Write for me', onclick: function () { ed.change(function () { ed.t.caption = MK.autoCaption(values(ed.t), !!ed.t.couponCode); }); } }),
        h('button.btn.btn--sm', { type: 'button', text: 'Copy caption', onclick: function () {
          var text = MK.substitute(ed.t.caption, values(ed.t));
          (navigator.clipboard ? navigator.clipboard.writeText(text) : Promise.reject(new Error('no clipboard'))).then(function () { ui.toast('Caption copied.'); }, function () { ui.toast('Copy failed: select the preview text and copy it.', true); });
        } })),
      h('div.panel-title', { text: 'As posted' }), capOut));
    function pct(obj, key) {
      var inp = h('input', { type: 'number', step: '0.5', value: String(Math.round(obj[key] * 1000) / 10) });
      inp.addEventListener('change', function () { var v = Number(inp.value); if (isFinite(v)) ed.change(function () { obj[key] = MK.clamp(v / 100, key === 'w' || key === 'h' ? 0.005 : -0.5, key === 'w' || key === 'h' ? 3 : 1.5); }); });
      return inp;
    }
  };

  Editor.prototype.renderWarn = function () {
    var w = couponWarning(this.t); var box = clear(this.warnBox);
    if (w) box.appendChild(h('div.banner.banner--bad', { text: w + ' Pick an active coupon before sharing this image.' }));
    else if (!this.t.couponCode && MK.templateNeedsCoupon(this.t)) box.appendChild(h('div.banner.banner--info', { text: 'No coupon is bound: the preview shows sample values (code RIDE50). Pick a coupon on the left before exporting.' }));
  };

  // ---------------- save & export
  Editor.prototype.save = function () {
    var ed = this;
    if (this.saving) return Promise.resolve(false);
    var problems = MK.validate(this.t);
    if (problems.length) { ui.toast(problems[0], true); return Promise.resolve(false); }
    this.saving = true; this.saveBtn.disabled = true; this.saveBtn.textContent = 'Saving…';
    var body = MK.templateToJson(this.t); body.baseUpdatedAt = this.t.updatedAt || undefined;
    return api('PUT', '/admin/marketing/templates/' + encodeURIComponent(this.t.id), body).then(function (r) {
      var fresh = MK.cleanTemplate(r.template);
      ed.t.updatedAt = fresh.updatedAt; ed.t.updatedBy = fresh.updatedBy; ed.t.coupon = fresh.coupon;
      ed.dirty = false; ed.dirtyChip.textContent = 'Saved'; ed.dirtyChip.className = 'chip chip--ok';
      ed.renderWarn(); ed.draw();
      ui.toast('Saved.');
      return true;
    }).catch(function (e) {
      if (e.code === 'CONFLICT') ui.toast('Someone else saved this template meanwhile (' + (e.body.updatedBy || 'another admin') + '). Copy your changes, then reload.', true);
      else ui.toast(e.message, true);
      return false;
    }).then(function (ok) { ed.saving = false; ed.saveBtn.disabled = false; ed.saveBtn.textContent = 'Save'; return ok; });
  };
  Editor.prototype.exportPng = function (all) {
    var ed = this; var t = this.t;
    var problems = MK.validate(t);
    if (problems.length) { ui.toast(problems[0], true); return; }
    var w = couponWarning(t);
    var go = function () {
      var sizes = all ? [{ preset: 'instagram_post' }, { preset: 'instagram_story' }, { preset: 'banner' }] : [t.size];
      if (all && t.size.preset === 'custom') sizes.push(t.size);
      var chain = Promise.resolve(); var n = 0;
      sizes.forEach(function (sz) {
        chain = chain.then(function () {
          var tt = sz === t.size ? t : MK.retarget(t, sz);
          return renderPng(tt).then(function (blob) { n++; CR.download(blob, fileName(tt, tt.size)); return new Promise(function (r) { setTimeout(r, 350); }); });
        });
      });
      chain.then(function () { ui.toast(n === 1 ? 'PNG downloaded (' + t.size.width + '×' + t.size.height + ').' : n + ' PNGs downloaded.'); }, function (e) { ui.toast(e.message, true); });
    };
    if (w) ui.confirm('Export anyway?', w, 'Export', true).then(function (ok) { if (ok) go(); });
    else if (!t.couponCode && MK.templateNeedsCoupon(t)) ui.confirm('Export with sample values?', 'No coupon is bound, so the image shows the sample code RIDE50.', 'Export').then(function (ok) { if (ok) go(); });
    else go();
  };

  // ---------------- image library
  function pickImage(onPick) {
    var grid = h('div.studio-list', CR.ui.loading());
    var file = h('input', { type: 'file', accept: 'image/png,image/jpeg,image/webp' });
    var status = h('span.muted.small', { text: 'JPEG, PNG or WebP up to 2 MB. Location data is removed on upload.' });
    var close = null;
    file.addEventListener('change', function () {
      var f = file.files && file.files[0]; if (!f) return;
      if (f.size > 2 * 1024 * 1024) { ui.toast('This image is larger than 2 MB.', true); return; }
      status.textContent = 'Uploading…';
      api('POST', '/admin/marketing/images', f, { type: f.type || 'application/octet-stream' }).then(function (r) {
        status.textContent = 'Uploaded.';
        onPick(r.image); if (close) close();
      }).catch(function (e) { status.textContent = e.message; ui.toast(e.message, true); });
    });
    api('GET', '/admin/marketing/images').then(function (r) {
      clear(grid);
      if (!(r.images || []).length) { grid.appendChild(h('p.muted', { text: 'No images uploaded yet.' })); return; }
      r.images.forEach(function (img) {
        var c = h('canvas'); c.width = 200; c.height = 150;
        loadImage(img.id).then(function (bm) { if (!bm) return; var ctx = c.getContext('2d'); var k = Math.min(200 / bm.width, 150 / bm.height); ctx.drawImage(bm, (200 - bm.width * k) / 2, (150 - bm.height * k) / 2, bm.width * k, bm.height * k); });
        grid.appendChild(h('div.tcard', h('div.tcard__thumb', { onclick: function () { onPick(img); if (close) close(); } }, c),
          h('div.tcard__body', h('span.muted.small', { text: img.width + '×' + img.height + ' · ' + Math.round(img.bytes / 1024) + ' KB' }),
            h('div.row', h('button.btn.btn--sm', { type: 'button', text: 'Use', onclick: function () { onPick(img); if (close) close(); } }),
              h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'Delete', onclick: function () {
                api('DELETE', '/admin/marketing/images/' + img.id).then(function () { ui.toast('Image deleted.'); if (close) close(); pickImage(onPick); }).catch(function (e) { ui.toast(e.message, true); });
              } })))));
      });
    }).catch(function (e) { clear(grid).appendChild(ui.error(e)); });
    ui.dialog({ title: 'Images', wide: true, body: [h('div.row', file), status, grid], actions: [{ label: 'Close', value: null }] });
    close = function () { var s = document.querySelectorAll('.scrim'); if (s.length) s[s.length - 1].remove(); };
  }

  // ==================================================================== section
  CR.sections.marketing = {
    title: 'Marketing studio',
    render: function (view, arg) {
      if (editor) { editor.teardown(); editor = null; }
      var m;
      if ((m = /^edit\/(mt_[a-f0-9]{24})$/.exec(arg || ''))) return renderEditor(view, m[1]);
      if ((m = /^new(?:\?coupon=([A-Z0-9_-]+))?$/.exec(arg || ''))) return renderNew(view, m[1] || '');
      return renderList(view);
    },
    teardown: function () { if (editor) { editor.teardown(); editor = null; } },
  };
})();
