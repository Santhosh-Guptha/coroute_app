/* CoRoute web admin: shell (sign in, session, navigation) and the Payments, Plans & pricing, Coupons and
   Revenue sections. The Marketing studio lives in studio.js. Every call goes to the existing admin APIs
   with the admin's Bearer token; the token is kept in sessionStorage only (gone when the tab closes). */
(function () {
  'use strict';

  var TOKEN_KEY = 'cr.admin.token';
  var USER_KEY = 'cr.admin.user';
  var ACTIVE_KEY = 'cr.admin.lastActive';
  var IDLE_MS = 30 * 60 * 1000;
  var ADMIN_ROLES = ['MASTER_ADMIN'];

  var CR = window.CR = { sections: {}, state: { config: null, planOptions: null } };

  // ------------------------------------------------------------------ small DOM helpers
  /** h('div.card', {attrs}, children...) : builds elements; text is always set as text, never HTML. */
  function h(spec, attrs) {
    var m = /^([a-z0-9]+)((?:[.#][A-Za-z0-9_-]+)*)$/.exec(spec);
    var el = document.createElement(m ? m[1] : 'div');
    if (m && m[2]) m[2].replace(/([.#])([A-Za-z0-9_-]+)/g, function (_, k, v) { if (k === '.') el.classList.add(v); else el.id = v; return ''; });
    var kids = Array.prototype.slice.call(arguments, 2);
    if (attrs && (typeof attrs !== 'object' || attrs instanceof Node || Array.isArray(attrs))) { kids.unshift(attrs); attrs = null; }
    if (attrs) Object.keys(attrs).forEach(function (k) {
      var v = attrs[k];
      if (v === undefined || v === null || v === false) return;
      if (k === 'text') el.textContent = v;
      else if (k === 'class') el.className = v;
      else if (k.slice(0, 2) === 'on' && typeof v === 'function') el.addEventListener(k.slice(2), v);
      else if (k === 'dataset') Object.keys(v).forEach(function (d) { el.dataset[d] = v[d]; });
      else if (k === 'value') el.value = v;
      else if (k === 'checked' || k === 'disabled' || k === 'selected' || k === 'hidden') el[k] = !!v;
      else el.setAttribute(k, v === true ? '' : v);
    });
    append(el, kids);
    return el;
  }
  function append(el, kids) {
    kids.forEach(function (c) {
      if (c === null || c === undefined || c === false) return;
      if (Array.isArray(c)) append(el, c);
      else el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
    });
    return el;
  }
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }
  function $(id) { return document.getElementById(id); }

  // ------------------------------------------------------------------ formatting (India time)
  var IST = 330 * 60000;
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function inr(v, digits) {
    var n = Number(v) || 0;
    return '₹' + n.toLocaleString('en-IN', { maximumFractionDigits: digits === undefined ? 2 : digits, minimumFractionDigits: 0 });
  }
  function date(ms, withTime) {
    if (!ms || Number(ms) <= 0) return '-';
    var d = new Date(Number(ms) + IST);
    var s = d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCFullYear();
    if (withTime) s += ', ' + String(d.getUTCHours()).padStart(2, '0') + ':' + String(d.getUTCMinutes()).padStart(2, '0');
    return s;
  }
  function planLabel(id) {
    var opts = CR.state.planOptions || [];
    for (var i = 0; i < opts.length; i++) if (opts[i].id === id) return opts[i].label;
    var fb = { group_small: 'Small Group', group_large: 'Large Group', community: 'Community', individual: 'Individual (old)', proRider: 'Pro Rider (old)', roadCaptain: 'Road Captain (old)', tourOperator: 'Tour Operator (old)', all: 'All plans' };
    return fb[id] || id || '-';
  }
  /** Epoch ms of a <input type="date"> value at the start (or end) of that day, India time. */
  function dayMs(v, end) {
    if (!v) return 0;
    var p = v.split('-').map(Number);
    return Date.UTC(p[0], p[1] - 1, p[2]) - IST + (end ? 86400000 - 1 : 0);
  }
  /** <input type="datetime-local"> value <-> epoch ms, in India time (coupons are India-only). */
  function toLocalInput(ms) {
    if (!ms) return '';
    var d = new Date(Number(ms) + IST);
    return d.toISOString().slice(0, 16);
  }
  function fromLocalInput(v) {
    if (!v) return 0;
    var t = Date.parse(v + ':00Z');
    return isFinite(t) ? t - IST : 0;
  }
  CR.util = { h: h, append: append, clear: clear, inr: inr, date: date, planLabel: planLabel, dayMs: dayMs, toLocalInput: toLocalInput, fromLocalInput: fromLocalInput };

  // ------------------------------------------------------------------ toasts and dialogs
  function toast(msg, bad) {
    var t = h('div.toast' + (bad ? '.toast--bad' : ''), { role: bad ? 'alert' : 'status', text: msg });
    $('toasts').appendChild(t);
    setTimeout(function () { t.remove(); }, bad ? 7000 : 3500);
  }
  /**
   * Modal dialog. actions: [{label, kind, value, onClick}] : onClick may return a promise; a false
   * result keeps the dialog open. Resolves with the value of the action taken (null on Escape / Cancel).
   */
  function dialog(opts) {
    return new Promise(function (resolve) {
      var prev = document.activeElement;
      var body = h('div.dialog__body', opts.body || null);
      var foot = h('div.dialog__foot');
      var box = h('div.dialog' + (opts.wide ? '.dialog--wide' : ''), { role: 'dialog', 'aria-modal': 'true', 'aria-label': opts.title },
        h('div.dialog__head', h('h2', { text: opts.title }), h('span.spacer'), h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Close', text: '×', onclick: function () { done(null); } })),
        body, foot);
      var scrim = h('div.scrim', box);
      function done(v) { document.removeEventListener('keydown', onKey); scrim.remove(); if (prev && prev.focus) prev.focus(); resolve(v); }
      function onKey(e) { if (e.key === 'Escape') done(null); }
      (opts.actions || [{ label: 'Close', value: null }]).forEach(function (a) {
        var b = h('button.btn' + (a.kind ? '.btn--' + a.kind : ''), { type: 'button', text: a.label });
        b.addEventListener('click', function () {
          if (!a.onClick) return done(a.value === undefined ? a.label : a.value);
          b.disabled = true;
          Promise.resolve().then(a.onClick).then(function (r) { b.disabled = false; if (r !== false) done(r === undefined ? a.value : r); },
            function (e) { b.disabled = false; toast(e.message || String(e), true); });
        });
        foot.appendChild(b);
      });
      scrim.addEventListener('mousedown', function (e) { if (e.target === scrim) done(null); });
      document.addEventListener('keydown', onKey);
      document.body.appendChild(scrim);
      var first = box.querySelector('input, select, textarea') || foot.lastChild;
      if (first) first.focus();
    });
  }
  function confirmDialog(title, message, label, danger) {
    return dialog({ title: title, body: h('p', { text: message }), actions: [{ label: 'Cancel', value: false }, { label: label || 'Confirm', kind: danger ? 'danger' : 'primary', value: true }] })
      .then(function (v) { return v === true; });
  }
  CR.ui = { toast: toast, dialog: dialog, confirm: confirmDialog };

  // ------------------------------------------------------------------ session & API
  function store(k, v) { try { if (v === null) sessionStorage.removeItem(k); else sessionStorage.setItem(k, v); } catch (e) { /* private mode */ } }
  function read(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  function token() { return read(TOKEN_KEY); }
  function tokenExpired(t) {
    try {
      var p = JSON.parse(atob(t.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')));
      return p.exp && p.exp * 1000 < Date.now();
    } catch (e) { return true; }
  }

  function ApiError(status, body) { var e = new Error((body && body.error) || ('Request failed (' + status + ')')); e.status = status; e.body = body || {}; e.code = body && body.code; return e; }

  /** fetch /api + path with the admin's token. opts: { raw: true } returns the Response. 401 signs out. */
  function api(method, path, body, opts) {
    opts = opts || {};
    var headers = { Authorization: 'Bearer ' + token() };
    var init = { method: method, headers: headers, credentials: 'omit', cache: 'no-store' };
    if (body instanceof Blob || body instanceof ArrayBuffer) { init.body = body; headers['Content-Type'] = opts.type || 'application/octet-stream'; }
    else if (body !== undefined && body !== null) { init.body = JSON.stringify(body); headers['Content-Type'] = 'application/json'; }
    touch();
    return fetch('/api' + path, init).then(function (res) {
      var fresh = res.headers.get('X-CoRoute-Token');
      if (fresh) store(TOKEN_KEY, fresh);
      if (res.status === 401) { signOut('Your session has ended. Please sign in again.'); throw new ApiError(401, { error: 'Signed out' }); }
      if (opts.raw && res.ok) return res;
      return res.json().catch(function () { return {}; }).then(function (j) {
        if (!res.ok) throw new ApiError(res.status, j);
        return j;
      });
    });
  }
  CR.api = api;
  CR.download = function (blob, name) {
    var url = URL.createObjectURL(blob);
    var a = h('a', { href: url, download: name });
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
  };

  function touch() { store(ACTIVE_KEY, String(Date.now())); }
  var idleTimer = null;
  function startIdleWatch() {
    touch();
    ['pointerdown', 'keydown', 'wheel', 'touchstart'].forEach(function (ev) { document.addEventListener(ev, touchThrottled, { passive: true }); });
    clearInterval(idleTimer);
    idleTimer = setInterval(checkIdle, 15000);
  }
  var lastTouch = 0;
  function touchThrottled() { var n = Date.now(); if (n - lastTouch > 5000) { lastTouch = n; touch(); } }
  function checkIdle() {
    if (!token()) return;
    var last = Number(read(ACTIVE_KEY)) || 0;
    if (Date.now() - last > IDLE_MS) signOut('You were signed out after 30 minutes without activity.');
    else if (tokenExpired(token())) signOut('Your session has ended. Please sign in again.');
  }
  document.addEventListener('visibilitychange', function () { if (!document.hidden) checkIdle(); });

  function signOut(message) {
    store(TOKEN_KEY, null); store(USER_KEY, null); store(ACTIVE_KEY, null);
    clearInterval(idleTimer);
    CR.state.config = null; CR.state.planOptions = null;
    document.querySelectorAll('.scrim').forEach(function (s) { s.remove(); });
    if (CR.sections.marketing && CR.sections.marketing.teardown) CR.sections.marketing.teardown();
    clear($('view'));
    $('shell').hidden = true;
    $('signin').hidden = false;
    var err = $('signin-error');
    err.hidden = !message; err.textContent = message || '';
    err.classList.toggle('form-error', true);
    $('signin-pw').value = '';
    $('signin-id').focus();
  }
  CR.signOut = signOut;

  function initSignIn() {
    $('signin-form').addEventListener('submit', function (e) {
      e.preventDefault();
      var id = $('signin-id').value.trim(); var pw = $('signin-pw').value;
      var err = $('signin-error'); var btn = $('signin-btn');
      if (!id || !pw) { err.hidden = false; err.textContent = 'Enter your email and password.'; return; }
      btn.disabled = true; btn.textContent = 'Signing in…'; err.hidden = true;
      fetch('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, credentials: 'omit', body: JSON.stringify({ identifier: id, password: pw }) })
        .then(function (res) { return res.json().catch(function () { return {}; }).then(function (j) { return { res: res, j: j }; }); })
        .then(function (r) {
          if (r.res.status === 429) throw new Error('Too many attempts. Wait a few minutes and try again.');
          if (!r.res.ok) throw new Error(r.j.error || 'Sign in failed.');
          var role = r.j.user && r.j.user.role;
          if (ADMIN_ROLES.indexOf(role) < 0) throw new Error('This account is not a CoRoute administrator.');
          store(TOKEN_KEY, r.j.token);
          store(USER_KEY, JSON.stringify({ name: r.j.user.name || '', email: r.j.user.email || '', role: role }));
          $('signin-pw').value = '';
          enterShell();
        })
        .catch(function (e2) { err.hidden = false; err.textContent = e2.message || 'Sign in failed.'; })
        .then(function () { btn.disabled = false; btn.textContent = 'Sign in'; });
    });
  }

  function enterShell() {
    $('signin').hidden = true;
    $('shell').hidden = false;
    var u = {};
    try { u = JSON.parse(read(USER_KEY) || '{}'); } catch (e) { u = {}; }
    clear($('whoami')).appendChild(h('b', { text: u.name || 'Administrator' }));
    $('whoami').appendChild(document.createTextNode(u.email || ''));
    startIdleWatch();
    api('GET', '/admin/web/config').then(function (c) { CR.state.config = c; }).catch(function () { /* defaults */ });
    route();
  }

  CR.config = function () {
    if (CR.state.config) return Promise.resolve(CR.state.config);
    return api('GET', '/admin/web/config').then(function (c) { CR.state.config = c; return c; });
  };
  CR.planOptions = function () {
    if (CR.state.planOptions) return Promise.resolve(CR.state.planOptions);
    return api('GET', '/admin/coupons/plan-options').then(function (r) { CR.state.planOptions = r.plans || []; return CR.state.planOptions; })
      .catch(function () { return []; });
  };

  // ------------------------------------------------------------------ navigation
  var current = null;
  function route() {
    if (!token()) return;
    var m = /^#\/([a-z]+)(?:\/(.*))?$/.exec(location.hash || '');
    var name = m && CR.sections[m[1]] ? m[1] : 'payments';
    var arg = m && m[2] ? decodeURIComponent(m[2]) : '';
    document.querySelectorAll('#nav a').forEach(function (a) { if (a.dataset.section === name) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
    if (current && current !== name && CR.sections[current].teardown) CR.sections[current].teardown();
    current = name;
    var view = clear($('view'));
    document.title = CR.sections[name].title + ' · CoRoute Admin';
    try { CR.sections[name].render(view, arg); } catch (e) { view.appendChild(h('div.banner.banner--bad', { text: e.message })); }
    view.focus({ preventScroll: true });
  }
  CR.go = function (hash) { if (location.hash === hash) route(); else location.hash = hash; };
  window.addEventListener('hashchange', route);

  function pageHead(title, sub, actions) {
    return h('div.page-head', h('div', h('h1', { text: title }), sub ? h('p', { text: sub }) : null), h('span.spacer'), actions || null);
  }
  function loadingNode() { return h('div.loading', { text: 'Loading…' }); }
  function errorNode(e) {
    var msg = e && e.code === 'FEATURE_OFF' ? 'This feature is switched off. Turn it on under Feature switches in the app admin.' : (e && e.message) || 'Something went wrong.';
    return h('div.banner.banner--bad', { text: msg });
  }
  function tile(label, value, note) { return h('div.tile', h('div.tile__label', { text: label }), h('div.tile__value', { text: value }), note ? h('div.tile__note', { text: note }) : null); }
  function chip(text, kind) { return h('span.chip' + (kind ? '.chip--' + kind : ''), { text: text }); }
  function field(label, input, hint) { return h('label.field', h('span', label, hint ? h('small', { text: hint }) : null), input); }
  function select(options, value, attrs) {
    var s = h('select', attrs || {});
    options.forEach(function (o) { s.appendChild(h('option', { value: o[0], text: o[1], selected: String(o[0]) === String(value) })); });
    return s;
  }
  CR.ui.pageHead = pageHead; CR.ui.loading = loadingNode; CR.ui.error = errorNode; CR.ui.tile = tile; CR.ui.chip = chip; CR.ui.field = field; CR.ui.select = select;

  // ------------------------------------------------------------------ theme
  function applyTheme(v) {
    if (v === 'light' || v === 'dark') document.documentElement.setAttribute('data-theme', v);
    else document.documentElement.removeAttribute('data-theme');
  }
  function initTheme() {
    var v = 'system';
    try { v = localStorage.getItem('cr.admin.theme') || 'system'; } catch (e) { v = 'system'; }
    var q = /[?&]theme=(light|dark)/.exec(location.search);
    if (q) v = q[1];
    applyTheme(v);
    $('theme').value = v;
    $('theme').addEventListener('change', function () {
      applyTheme(this.value);
      try { localStorage.setItem('cr.admin.theme', this.value); } catch (e) { /* ignore */ }
      if (CR.onTheme) CR.onTheme();
    });
  }

  // ==================================================================== PAYMENTS
  var STATUS_INFO = {
    PAID: ['Paid', 'ok'], CREATED: ['Not paid', ''], FAILED: ['Failed', 'bad'], SIGNATURE_MISMATCH: ['Signature failed', 'bad'],
    EXPIRED: ['Expired', ''], REFUNDED: ['Refunded', 'warn'], PARTIALLY_REFUNDED: ['Part refunded', 'warn'],
  };
  function statusChip(p) {
    var s = String(p.status || '').toUpperCase();
    if (s === 'PAID' && p.fullyRefunded) return chip('Refunded', 'warn');
    if (s === 'PAID' && p.refundedAmountInPaise > 0) return chip('Part refunded', 'warn');
    var i = STATUS_INFO[s] || [s.toLowerCase().replace(/_/g, ' '), ''];
    return chip(i[0], i[1]);
  }
  function modeChip(p) {
    var m = p.mode || (p.isFree ? 'manual' : '');
    return chip(m === 'live' ? 'Live' : m === 'test' ? 'Test' : m === 'manual' ? 'Manual' : (m || '-'), m === 'live' ? 'info' : '');
  }
  function who(p) { var u = p.user || {}; return u.name || u.email || u.callsign || p.userId || 'Unknown rider'; }

  CR.sections.payments = {
    title: 'Payments',
    render: function (view) {
      var st = { q: '', status: '', mode: '', plan: '', from: '', to: '', rows: [], total: 0, hasMore: false, gen: 0 };
      var tiles = h('div.tiles', loadingNode());
      var tbody = h('tbody');
      var more = h('button.btn', { type: 'button', text: 'Load more', hidden: true, onclick: function () { load(true); } });
      var count = h('span.muted.small');
      var search = h('input', { type: 'search', placeholder: 'Order, payment or user ID', 'aria-label': 'Search payments' });
      var status = select([['', 'Any status'], ['PAID', 'Paid'], ['CREATED', 'Not paid'], ['FAILED', 'Failed'], ['SIGNATURE_MISMATCH', 'Signature failed'], ['EXPIRED', 'Expired']], '', { 'aria-label': 'Status' });
      var mode = select([['', 'Any mode'], ['live', 'Live'], ['test', 'Test'], ['manual', 'Manual']], '', { 'aria-label': 'Mode' });
      var plan = select([['', 'Any plan']], '', { 'aria-label': 'Plan' });
      var from = h('input', { type: 'date', 'aria-label': 'From date' });
      var to = h('input', { type: 'date', 'aria-label': 'To date' });
      var timer = null;
      search.addEventListener('input', function () { clearTimeout(timer); timer = setTimeout(function () { st.q = search.value.trim(); load(); }, 300); });
      [status, mode, plan, from, to].forEach(function (el) { el.addEventListener('change', function () { st.status = status.value; st.mode = mode.value; st.plan = plan.value; st.from = from.value; st.to = to.value; load(); }); });

      view.appendChild(pageHead('Payments', 'Every order and payment, newest first, with refunds. The figures above leave out staff accounts; the list shows every order.',
        h('div.row',
          h('button.btn', { type: 'button', text: 'Export CSV', onclick: exportCsv }),
          h('button.btn', { type: 'button', text: 'Reconcile memberships', onclick: reconcile }))));
      view.appendChild(tiles);
      view.appendChild(h('div.toolbar', search, status, mode, plan, h('span.muted.small', { text: 'From' }), from, h('span.muted.small', { text: 'to' }), to, h('span.spacer'), count));
      view.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Date', 'Rider', 'Plan', 'Amount', 'Mode', 'Status', 'Order'].map(function (c, i) { return h('th', { class: i === 3 ? 'num' : '', text: c }); }))), tbody)));
      view.appendChild(h('div.row', { class: 'row', style: null }, more));

      CR.planOptions().then(function (opts) { opts.forEach(function (o) { plan.appendChild(h('option', { value: o.id, text: o.label })); }); });
      api('GET', '/admin/payments/analytics?range=30d').then(function (a) {
        var s = a.summary || {};
        clear(tiles);
        append(tiles, [tile('Net revenue, 30 days', inr(s.netRevenueInr, 0), 'after refunds and coupons'), tile('Paid orders', String(s.paidOrders || 0), (s.freeActivations || 0) + ' free activations'),
          tile('Failed', String(s.failedOrders || 0), 'payments that did not complete'), tile('Refunded', inr(s.refundedAmountInr, 0), (s.refundedOrders || 0) + ' orders')]);
      }).catch(function (e) { clear(tiles).appendChild(errorNode(e)); });

      function params(extra) {
        var p = new URLSearchParams();
        if (st.q) p.set('q', st.q); if (st.status) p.set('status', st.status); if (st.mode) p.set('mode', st.mode); if (st.plan) p.set('plan', st.plan);
        if (st.from) p.set('from', String(dayMs(st.from))); if (st.to) p.set('to', String(dayMs(st.to, true)));
        Object.keys(extra || {}).forEach(function (k) { p.set(k, extra[k]); });
        return p.toString();
      }
      function load(isMore) {
        var gen = isMore ? st.gen : ++st.gen;
        if (!isMore) { clear(tbody).appendChild(h('tr', h('td', { colspan: '7', class: 'empty', text: 'Loading…' }))); }
        more.disabled = true;
        api('GET', '/admin/payments?' + params({ limit: '50', offset: String(isMore ? st.rows.length : 0) })).then(function (r) {
          if (gen !== st.gen) return;
          if (!isMore) { st.rows = []; clear(tbody); }
          (r.payments || []).forEach(function (p) { st.rows.push(p); tbody.appendChild(row(p)); });
          st.total = r.total || st.rows.length; st.hasMore = !!r.hasMore;
          if (!st.rows.length) tbody.appendChild(h('tr', h('td', { colspan: '7', class: 'empty', text: 'No payments match.' })));
          count.textContent = st.rows.length + ' of ' + st.total;
          more.hidden = !st.hasMore; more.disabled = false;
        }).catch(function (e) { if (gen === st.gen) { clear(tbody).appendChild(h('tr', h('td', { colspan: '7' }, errorNode(e)))); } });
      }
      function row(p) {
        var refunded = Number(p.refundedAmountInPaise) || 0;
        return h('tr.is-link', { tabindex: '0', onclick: function () { detail(p); }, onkeydown: function (e) { if (e.key === 'Enter') detail(p); } },
          h('td.nowrap', { text: date(p.paidAt || p.createdAt, true) }),
          h('td', who(p), p.user && p.user.email && p.user.name ? h('div.muted.small', { text: p.user.email }) : null),
          h('td', { text: planLabel(p.category || p.planTier) + (p.billingCycle ? ' · ' + p.billingCycle : '') }),
          h('td.num', inr(p.amount), refunded ? h('div.muted.small', { text: '−' + inr(refunded / 100) }) : null),
          h('td', modeChip(p)), h('td', statusChip(p)), h('td.mono', { text: p.orderId }));
      }
      function detail(p) {
        var total = Number(p.amountInPaise) || 0; var refunded = Number(p.refundedAmountInPaise) || 0; var remaining = total - refunded;
        var refundable = p.status === 'PAID' && !!p.paymentId && (p.mode === 'test' || p.mode === 'live') && remaining >= 100 && !p.fullyRefunded;
        var kv = h('dl.kv');
        [['Order', p.orderId], ['Payment', p.paymentId || '-'], ['Rider', who(p) + (p.user && p.user.email ? ' (' + p.user.email + ')' : '')], ['User ID', p.userId || '-'],
          ['Plan', planLabel(p.category || p.planTier) + (p.billingCycle ? ' · ' + p.billingCycle : '')], ['Amount', inr(p.amount)],
          ['Discount', p.discountAmount ? inr(p.discountAmount) : '-'], ['Coupon', p.couponCode || '-'], ['Offer', p.offerTitle || '-'],
          ['Mode', p.mode || '-'], ['Status', String(p.status || '')], ['Created', date(p.createdAt, true)], ['Paid', date(p.paidAt, true)],
          ['Refunded', refunded ? inr(refunded / 100) + (p.refundStatus ? ' · ' + p.refundStatus : '') + (p.refundedBy ? ' · by ' + p.refundedBy : '') : '-'],
          ['Refund reason', p.refundReason || '-'], ['Failure', p.failureReason || '-'], ['Channel', p.channel || '-']]
          .forEach(function (x) { kv.appendChild(h('dt', { text: x[0] })); kv.appendChild(h('dd', { class: /Order|Payment|User ID/.test(x[0]) ? 'mono' : '', text: x[1] })); });
        var riderBox = h('div.stack');
        var body = [kv, riderBox];
        if (!refundable && p.status === 'PAID') body.push(h('p.muted.small', { text: p.fullyRefunded ? 'This order is fully refunded.' : (p.mode === 'manual' || !p.paymentId ? 'Manual / free orders have no Razorpay payment to refund.' : '') }));
        if (p.userId) {
          riderBox.appendChild(h('p.muted.small', { text: 'Loading the rider’s plan…' }));
          api('GET', '/admin/payments/users/' + encodeURIComponent(p.userId)).then(function (u) {
            clear(riderBox);
            var pl = u.plan || {};
            riderBox.appendChild(h('div.banner.banner--info', { text: 'Current plan: ' + planLabel(pl.planId || pl.tier || u.subscriptionTier) + (pl.validUntil ? ' until ' + date(pl.validUntil) : '') + ' · ' + (u.orders || []).length + ' orders' }));
          }).catch(function () { clear(riderBox); });
        }
        var actions = [{ label: 'Close', value: null }];
        if (refundable) actions.unshift({ label: 'Refund…', kind: 'danger', onClick: function () { return refund(p, remaining); } });
        dialog({ title: 'Payment ' + inr(p.amount), body: body, wide: true, actions: actions });
      }
      function refund(p, remaining) {
        var amount = h('input', { type: 'number', min: '1', step: '1', max: String(remaining / 100), placeholder: String(remaining / 100) });
        var reason = h('input', { type: 'text', maxlength: '250', placeholder: 'Why (kept in the audit log)' });
        return dialog({
          title: 'Refund ' + who(p),
          body: [h('p', { text: 'Razorpay returns the money to the rider. A FULL refund ends the plan this order bought right away; a partial refund keeps it. This cannot be undone.' }),
            field('Amount (₹)', amount, 'blank = everything left: ' + inr(remaining / 100)), field('Reason', reason)],
          actions: [{ label: 'Cancel', value: null }, { label: 'Refund now', kind: 'danger', onClick: function () {
            var rupees = amount.value.trim();
            var paise = rupees ? Math.round(Number(rupees) * 100) : null;
            if (rupees && (!isFinite(paise) || paise < 100 || paise > remaining)) throw new Error('Enter an amount between ₹1 and ' + inr(remaining / 100) + '.');
            var b = { reason: reason.value.trim() };
            if (paise && paise < remaining) b.amountInPaise = paise;
            return api('POST', '/admin/payments/' + encodeURIComponent(p.orderId) + '/refund', b).then(function (r) {
              toast(r.fullyRefunded ? 'Refunded in full. The plan has ended.' : 'Partial refund sent.');
              document.querySelectorAll('.scrim').forEach(function (s) { s.remove(); });
              load();
              return true;
            });
          } }],
        });
      }
      function exportCsv() {
        var p = new URLSearchParams();
        if (st.from) p.set('from', new Date(dayMs(st.from)).toISOString());
        if (st.to) p.set('to', new Date(dayMs(st.to, true)).toISOString());
        api('GET', '/admin/payments/export.csv' + (p.toString() ? '?' + p : ''), null, { raw: true }).then(function (res) { return res.blob(); }).then(function (b) {
          CR.download(b, 'coroute-payments-' + new Date().toISOString().slice(0, 10) + '.csv');
          toast('CSV downloaded' + (st.from || st.to ? ' for the chosen dates.' : ' (every order).'));
        }).catch(function (e) { toast(e.message, true); });
      }
      function reconcile() {
        confirmDialog('Reconcile memberships?', 'Merges duplicate memberships and links orders that were paid but not attached to a plan. Safe to run more than once.', 'Reconcile').then(function (ok) {
          if (!ok) return;
          api('POST', '/admin/membership/reconcile', {}).then(function (r) {
            var bits = Object.keys(r || {}).filter(function (k) { return typeof r[k] === 'number'; }).map(function (k) { return k + ': ' + r[k]; });
            toast('Memberships checked.' + (bits.length ? ' ' + bits.join(', ') : ''));
            load();
          }).catch(function (e) { toast(e.message, true); });
        });
      }
      load();
    },
  };

  // ==================================================================== PLANS & PRICING
  function maskKey(id) {
    if (!id) return 'not set';
    var m = /^(rzp_(?:test|live)_)(.*)$/.exec(id);
    var tail = (m ? m[2] : id).slice(-4);
    return (m ? m[1] : '') + '••••••' + tail;
  }
  CR.maskKey = maskKey;

  CR.sections.plans = {
    title: 'Plans & pricing',
    render: function (view) {
      var plansBox = h('div', loadingNode());
      var gwBox = h('div.card', loadingNode());
      var auditBox = h('div.card', loadingNode());
      view.appendChild(pageHead('Plans & pricing', 'What riders pay on the website. Community is free and always on; Small Group and Large Group are sold. Changes are recorded in the audit log below.'));
      view.appendChild(plansBox);
      view.appendChild(h('h2', { text: 'Razorpay', class: 'section-gap' }));
      view.appendChild(gwBox);
      view.appendChild(auditBox);

      function loadPlans() {
        api('GET', '/admin/membership/catalog').then(function (r) { renderPlans(r.catalog || {}, r.rules || {}); }).catch(function (e) { clear(plansBox).appendChild(errorNode(e)); });
      }
      function renderPlans(catalog, rules) {
        clear(plansBox);
        rules = rules || {};
        var forms = {};
        var cards = h('div.cards');
        ['community', 'group_small', 'group_large'].concat(Object.keys(catalog).filter(function (k) { return ['community', 'group_small', 'group_large'].indexOf(k) < 0; })).forEach(function (id) {
          var c = catalog[id]; if (!c) return;
          var free = id === 'community';
          var f = forms[id] = {
            name: h('input', { type: 'text', maxlength: '40', value: c.name || id }),
            price: h('input', { type: 'number', min: '0', step: '1', value: String(Number(c.monthlyPriceInr) || 0), disabled: free }),
            days: h('input', { type: 'number', min: '1', max: '3660', step: '1', value: String(Number(c.billingPeriodDays) || 30), disabled: free }),
            cap: h('input', { type: 'number', min: '1', step: '1', value: String(Number(c.capacity) || 1), disabled: free }),
            description: h('textarea', { maxlength: '300', rows: '2', value: c.description || '' }),
            features: h('textarea', { rows: '4', value: (c.features || []).join('\n') }),
            active: h('input', { type: 'checkbox', checked: c.isActive !== false, disabled: free }),
          };
          // 3.56 offer: a lower price for a time window (India time), shown as "₹99 ₹49 Launch offer" on the website.
          var o = c.offer || null;
          f.offerOn = h('input', { type: 'checkbox', checked: !!o, disabled: free });
          f.offerPrice = h('input', { type: 'number', min: '1', step: '1', value: o ? String(o.priceInr) : '', placeholder: 'e.g. 49', 'aria-label': 'Offer price' });
          f.offerLabel = h('input', { type: 'text', maxlength: '40', value: o ? o.label : '', placeholder: 'e.g. Launch offer', 'aria-label': 'Offer label' });
          f.offerStart = h('input', { type: 'datetime-local', value: o && o.startAt ? toLocalInput(o.startAt) : '', 'aria-label': 'Offer starts' });
          f.offerEnd = h('input', { type: 'datetime-local', value: o && o.endAt ? toLocalInput(o.endAt) : '', 'aria-label': 'Offer ends' });
          f.offerPreview = h('p.muted.small', { class: 'muted small offer-preview', 'aria-live': 'polite' });
          f.offerBox = h('div.offer-box', { class: 'offer-box stack', hidden: !o },
            h('div.grid2', field('Offer price (₹)', f.offerPrice, 'below the list price'), field('Label', f.offerLabel, 'shown next to the price')),
            h('div.grid2', field('Starts', f.offerStart, 'India time; blank = now'), field('Ends', f.offerEnd, 'India time; blank = until you remove it')),
            f.offerPreview);
          (function (f) {
            var upd = function () {
              f.offerBox.hidden = !f.offerOn.checked;
              var list = Number(f.price.value) || 0; var op = Number(f.offerPrice.value) || 0;
              var bits = inr(list) + ' → ' + (op ? inr(op) : '…') + ' ' + (f.offerLabel.value.trim() || 'Offer');
              if (f.offerEnd.value) bits += ' until ' + date(fromLocalInput(f.offerEnd.value) - 1);
              if (f.offerStart.value && fromLocalInput(f.offerStart.value) > Date.now()) bits += ' (starts ' + date(fromLocalInput(f.offerStart.value), true) + ')';
              f.offerPreview.textContent = 'Website shows: ' + bits;
            };
            [f.offerOn, f.offerPrice, f.offerLabel, f.offerStart, f.offerEnd, f.price].forEach(function (x) { x.addEventListener('input', upd); x.addEventListener('change', upd); });
            upd();
          })(f);
          cards.appendChild(h('div.card',
            h('div.card__head', h('h3', { text: c.name || id }), h('span.spacer'), free ? chip('Free', 'info') : (c.isActive !== false ? chip('On sale', 'ok') : chip('Not sold', 'warn'))),
            h('div.stack',
              field('Name', f.name),
              free ? null : h('div.grid3', field('List price (₹)', f.price, 'MRP'), field('Billing days', f.days), field('Riders', f.cap)),
              free ? null : h('label.check', f.offerOn, 'Offer price for a time window'),
              free ? null : f.offerBox,
              field('Description', f.description), field('Features', f.features, 'one per line'),
              free ? h('p.muted.small', { text: 'Community is free for every rider: only its name, description and features can be changed.' }) : h('label.check', f.active, 'On sale on the website'))));
        });
        var save = h('button.btn.btn--primary', { type: 'button', text: 'Save plans' });
        save.addEventListener('click', function () {
          var out = {};
          Object.keys(forms).forEach(function (id) {
            var f = forms[id]; var c = catalog[id];
            var features = f.features.value.split('\n').map(function (s) { return s.trim(); }).filter(Boolean);
            if (id === 'community') { out[id] = { name: f.name.value.trim(), description: f.description.value.trim(), features: features }; return; }
            out[id] = Object.assign({}, c, { name: f.name.value.trim(), monthlyPriceInr: Number(f.price.value), listPriceInr: Number(f.price.value), billingPeriodDays: parseInt(f.days.value, 10), capacity: parseInt(f.cap.value, 10),
              description: f.description.value.trim(), features: features, isActive: f.active.checked });
            if (c.maxCapacity !== undefined) out[id].maxCapacity = out[id].capacity;
            out[id].offer = null;
            if (f.offerOn.checked) {
              out[id].offer = { priceInr: Number(f.offerPrice.value), label: f.offerLabel.value.trim(), startAt: f.offerStart.value ? fromLocalInput(f.offerStart.value) : null, endAt: f.offerEnd.value ? fromLocalInput(f.offerEnd.value) : null };
            }
          });
          // Same checks as the server (it checks again): offer below the list price, a label, a valid window.
          var bad = null;
          Object.keys(out).forEach(function (id) {
            var x = out[id]; var o = x.offer; if (bad || !o) return;
            if (!(o.priceInr >= 1) || Math.round(o.priceInr) !== o.priceInr) bad = x.name + ': enter the offer price in whole rupees.';
            else if (o.priceInr >= x.monthlyPriceInr) bad = x.name + ': the offer price must be below the list price (' + inr(x.monthlyPriceInr) + ').';
            else if (rules.minPayableInr && o.priceInr < rules.minPayableInr) bad = x.name + ': the offer price is below the minimum price (' + inr(rules.minPayableInr) + ').';
            else if (!o.label) bad = x.name + ': give the offer a label, like "Launch offer".';
            else if (o.startAt && o.endAt && o.endAt <= o.startAt) bad = x.name + ': the offer must end after it starts.';
            else if (o.endAt && o.endAt <= Date.now()) bad = x.name + ': the offer end is in the past.';
          });
          if (bad) { toast(bad, true); return; }
          var offerChanged = Object.keys(out).filter(function (id) { return id !== 'community' && JSON.stringify(out[id].offer || null) !== JSON.stringify(catalog[id].offer || null); });
          var changed = Object.keys(out).filter(function (id) { return id !== 'community' && (Number(out[id].monthlyPriceInr) !== Number(catalog[id].monthlyPriceInr)); });
          var msg = changed.length ? 'New list prices: ' + changed.map(function (id) { return out[id].name + ' ' + inr(catalog[id].monthlyPriceInr) + ' → ' + inr(out[id].monthlyPriceInr); }).join(', ') + '. Riders already on a plan keep what they paid until it renews.' : 'Save the plan details?';
          if (offerChanged.length) msg += ' Offers: ' + offerChanged.map(function (id) { var o = out[id].offer; return out[id].name + (o ? ' ' + inr(o.priceInr) + ' (' + o.label + (o.endAt ? ', until ' + date(o.endAt - 1) : '') + ')' : ' offer removed'); }).join(', ') + '.';
          confirmDialog('Save plans?', msg, 'Save').then(function (ok) {
            if (!ok) return;
            save.disabled = true;
            api('PUT', '/admin/membership/catalog', { catalog: out }).then(function (r) { toast('Plans saved.'); renderPlans(r.catalog || out, rules); loadAudit(); })
              .catch(function (e) { toast(e.message, true); }).then(function () { save.disabled = false; });
          });
        });
        append(plansBox, [cards, h('div.row.row--end', { class: 'row row--end' }, save)]);
        save.parentNode.classList.add('section-gap');
        // 3.56 minimum price: coupons never take a plan below it (a "free month" coupon is the only exception).
        var minIn = h('input', { type: 'number', min: '0', max: '100000', step: '1', value: String(Number(rules.minPayableInr) || 0), 'aria-label': 'Minimum price' });
        var minSave = h('button.btn', { type: 'button', text: 'Save minimum' });
        minSave.addEventListener('click', function () {
          var v = Number(minIn.value);
          if (!(v >= 0) || Math.round(v) !== v) { toast('Enter the minimum in whole rupees (0 for none).', true); return; }
          minSave.disabled = true;
          api('PUT', '/admin/pricing-rules', { minPayableInr: v }).then(function (r) { rules = r.rules || { minPayableInr: v }; toast('Minimum price saved.'); loadAudit(); })
            .catch(function (e) { toast(e.message, true); }).then(function () { minSave.disabled = false; });
        });
        plansBox.appendChild(h('div.card', { class: 'card section-gap' },
          h('div.card__head', h('h3', { text: 'Minimum price' })),
          h('div.row', field('Coupons never go below (₹)', minIn, '0 = no minimum'), minSave),
          h('p.muted.small', { text: 'Applies to every coupon on every plan, on top of an offer price. A "free month" coupon still makes the plan free.' })));
      }

      function loadGateway() {
        api('GET', '/admin/payment-gateway').then(renderGateway).catch(function (e) { clear(gwBox).appendChild(errorNode(e)); });
      }
      function renderGateway(g) {
        clear(gwBox);
        var enabled = h('input', { type: 'checkbox', checked: g.paymentsEnabled !== false });
        enabled.addEventListener('change', function () {
          var on = enabled.checked;
          confirmDialog(on ? 'Turn payments on?' : 'Turn payments off?', on ? 'Riders can buy plans on the website again.' : 'Riders cannot buy or renew plans until payments are turned back on. Plans already paid for keep working.', on ? 'Turn on' : 'Turn off', !on).then(function (ok) {
            if (!ok) { enabled.checked = !on; return; }
            api('PUT', '/admin/payment-gateway', { paymentsEnabled: on }).then(function (v) { toast(on ? 'Payments are on.' : 'Payments are off.'); renderGateway(v); loadAudit(); }).catch(function (e) { enabled.checked = !on; toast(e.message, true); });
          });
        });
        var modeSel = select([['test', 'Test mode'], ['live', 'Live mode']], g.mode, { 'aria-label': 'Active mode', class: 'select--sm' });
        modeSel.addEventListener('change', function () {
          var next = modeSel.value;
          confirmDialog('Switch to ' + next + ' mode?', next === 'live' ? 'Real money: riders are charged with the live keys.' : 'Test mode: no real money moves. Riders cannot really pay while it is on.', 'Switch', next === 'live').then(function (ok) {
            if (!ok) { modeSel.value = g.mode; return; }
            api('PUT', '/admin/payment-gateway', { mode: next }).then(function (v) { toast('Now in ' + next + ' mode.'); renderGateway(v); loadAudit(); }).catch(function (e) { modeSel.value = g.mode; toast(e.message, true); });
          });
        });
        var modes = h('div.grid2');
        ['test', 'live'].forEach(function (m) {
          var k = g[m] || {};
          modes.appendChild(h('div.card',
            h('div.card__head', h('h3', { text: m === 'live' ? 'Live keys' : 'Test keys' }), h('span.spacer'), g.mode === m ? chip('Active', 'ok') : null),
            h('dl.kv',
              h('dt', { text: 'Key ID' }), h('dd.mono', { text: maskKey(k.keyId) }),
              h('dt', { text: 'Key secret' }), h('dd', chip(k.keySecretSet ? 'Set' : 'Not set', k.keySecretSet ? 'ok' : 'warn')),
              h('dt', { text: 'Webhook secret' }), h('dd', chip(k.webhookSecretSet ? 'Set' : 'Not set', k.webhookSecretSet ? 'ok' : 'warn')),
              k.source ? h('dt', { text: 'From' }) : null, k.source ? h('dd', { text: k.source }) : null),
            h('div.row', { class: 'row section-gap' },
              h('button.btn.btn--sm', { type: 'button', text: 'Test keys', onclick: function () {
                api('POST', '/admin/payment-gateway/test', { mode: m }).then(function (r) { toast(r.ok === false ? 'Razorpay refused the keys.' : 'Razorpay accepted the ' + m + ' keys.', r.ok === false); }).catch(function (e) { toast(e.message, true); });
              } }),
              h('button.btn.btn--sm', { type: 'button', text: 'Replace keys…', onclick: function () { replaceKeys(m); } }))));
        });
        append(gwBox, [
          h('div.card__head', h('h3', { text: 'Payment gateway' }), h('span.spacer'), h('label.check', enabled, 'Payments on'), modeSel,
            h('p', { text: 'Secrets are never shown here or sent back by the server: only whether they are set. Key IDs are masked.' })),
          modes,
          g.updatedAt ? h('p.muted.small', { class: 'muted small section-gap', text: 'Last changed ' + date(g.updatedAt, true) + (g.updatedBy ? ' by ' + g.updatedBy : '') }) : null,
        ]);
      }
      function replaceKeys(m) {
        var keyId = h('input', { type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: 'rzp_' + m + '_…' });
        var secret = h('input', { type: 'password', autocomplete: 'new-password', placeholder: 'leave blank to keep' });
        var hook = h('input', { type: 'password', autocomplete: 'new-password', placeholder: 'leave blank to keep' });
        dialog({ title: 'Replace ' + m + ' keys', body: [h('p.muted', { text: 'Blank fields keep what is saved. The secrets are stored encrypted on the server and never shown again.' }),
          field('Key ID', keyId), field('Key secret', secret), field('Webhook secret', hook)],
        actions: [{ label: 'Cancel', value: null }, { label: 'Save keys', kind: 'primary', onClick: function () {
          var body = {}; body[m] = {};
          if (keyId.value.trim()) body[m].keyId = keyId.value.trim();
          if (secret.value.trim()) body[m].keySecret = secret.value.trim();
          if (hook.value.trim()) body[m].webhookSecret = hook.value.trim();
          if (!Object.keys(body[m]).length) throw new Error('Nothing to change.');
          return api('PUT', '/admin/payment-gateway', body).then(function (v) { secret.value = ''; hook.value = ''; toast('Keys saved.'); renderGateway(v); loadAudit(); return true; });
        } }] });
      }

      function loadAudit() {
        api('GET', '/admin/audit?limit=300').then(function (r) {
          var rows = (r.entries || []).filter(function (e) { return /^(membership\.catalog|pricing|gateway|payment|coupon|offer|membership\.reconcile|marketing|board)/.test(e.action || ''); }).slice(0, 60);
          clear(auditBox);
          auditBox.appendChild(h('div.card__head', h('h3', { text: 'Audit log' }), h('p', { text: 'Money and marketing changes by administrators, newest first (secrets are never logged).' })));
          if (!rows.length) { auditBox.appendChild(h('div.empty', { text: 'No changes recorded yet.' })); return; }
          var tb = h('tbody');
          rows.forEach(function (e) { tb.appendChild(h('tr', h('td.nowrap', { text: date(e.at, true) }), h('td', { text: e.by || '-' }), h('td.mono', { text: e.action }), h('td.mono', { text: e.target === null || e.target === undefined ? '' : String(e.target) }), h('td.small', { text: auditSummary(e) }))); });
          auditBox.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['When', 'Who', 'Action', 'Target', 'Details'].map(function (c) { return h('th', { text: c }); }))), tb)));
        }).catch(function (e) { clear(auditBox).appendChild(errorNode(e)); });
      }
      loadPlans(); loadGateway(); loadAudit();
    },
  };
  function auditSummary(e) {
    var d = e.details || {};
    if (e.action === 'membership.catalog_update' && d.catalog) return Object.keys(d.catalog).filter(function (k) { return k !== 'community'; }).map(function (k) { return (d.catalog[k].name || k) + ' ' + inr(d.catalog[k].monthlyPriceInr) + (d.catalog[k].isActive === false ? ' (not sold)' : ''); }).join(' · ');
    if (e.action === 'gateway.update') return 'mode ' + (d.modeBefore || '?') + ' → ' + (d.mode || '?') + ', payments ' + (d.paymentsEnabled ? 'on' : 'off') + (d.test && d.test.keySecretChanged ? ', test secret replaced' : '') + (d.live && d.live.keySecretChanged ? ', live secret replaced' : '');
    if (e.action === 'pricing.plan_price') return planLabel(e.target) + ': list ' + inr(d.listPriceInrBefore) + ' → ' + inr(d.listPriceInr) + (d.offer ? ', offer ' + inr(d.offer.priceInr) + ' ' + d.offer.label + (d.offer.endAt ? ' until ' + date(d.offer.endAt - 1) : '') : (d.offerBefore ? ', offer removed' : ''));
    if (e.action === 'pricing.rules_update') return 'minimum price ' + inr(d.minPayableInrBefore) + ' → ' + inr(d.minPayableInr);
    if (e.action === 'payment.refund') return inr((d.amountInPaise || 0) / 100) + (d.full ? ' full' : ' partial') + (d.reason ? ' · ' + d.reason : '');
    var s = JSON.stringify(d);
    return s.length > 140 ? s.slice(0, 140) + '…' : (s === '{}' ? '' : s);
  }

  // ==================================================================== COUPONS
  function couponStatus(c, now) {
    var s = String(c.status || '').toUpperCase();
    if ((s === 'ACTIVE' || s === 'SCHEDULED') && c.expiresAt && Number(c.expiresAt) < now) s = 'EXPIRED';
    var map = { ACTIVE: ['Active', 'ok'], SCHEDULED: ['Scheduled', 'info'], PAUSED: ['Paused', 'warn'], EXPIRED: ['Expired', 'bad'], USAGE_LIMIT_REACHED: ['Used up', 'warn'], ARCHIVED: ['Archived', ''], DRAFT: ['Draft', ''] };
    return { key: s, chip: chip((map[s] || [s])[0], (map[s] || [])[1]) };
  }
  function discountLabel(c) {
    if (c.discountType === 'free') return 'Free';
    if (c.discountType === 'fixed') return inr(c.discountValue) + ' off';
    return (Number(c.discountValue) || 0) + '% off' + (Number(c.maxDiscountCap) > 0 ? ' (max ' + inr(c.maxDiscountCap) + ')' : '');
  }
  function plansLabel(tiers) { return !tiers || !tiers.length || tiers.indexOf('all') >= 0 ? 'All plans' : tiers.map(planLabel).join(', '); }

  CR.sections.coupons = {
    title: 'Coupons',
    render: function (view) {
      var st = { list: [], q: '', status: '' };
      var tiles = h('div.tiles', loadingNode());
      var tbody = h('tbody');
      var search = h('input', { type: 'search', placeholder: 'Code, name or campaign', 'aria-label': 'Search coupons' });
      var status = select([['', 'Any status'], ['ACTIVE', 'Active'], ['SCHEDULED', 'Scheduled'], ['PAUSED', 'Paused'], ['EXPIRED', 'Expired'], ['USAGE_LIMIT_REACHED', 'Used up'], ['ARCHIVED', 'Archived'], ['DRAFT', 'Draft']], '', { 'aria-label': 'Status' });
      search.addEventListener('input', function () { st.q = search.value.trim().toLowerCase(); draw(); });
      status.addEventListener('change', function () { st.status = status.value; draw(); });
      view.appendChild(pageHead('Coupons', 'Discount codes riders type at checkout on the website. Usage counts exclude staff test redemptions.',
        h('button.btn.btn--primary', { type: 'button', text: 'New coupon', onclick: function () { edit(null); } })));
      view.appendChild(tiles);
      view.appendChild(h('div.toolbar', search, status));
      view.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Code', 'Discount', 'Plans', 'Valid', 'Used', 'Status', ''].map(function (c, i) { return h('th', { class: i === 4 ? 'num' : '', text: c }); }))), tbody)));

      function load() {
        CR.planOptions().then(function () { return Promise.all([api('GET', '/admin/coupons'), api('GET', '/admin/coupons/usage?limit=1')]); }).then(function (r) {
          st.list = (r[0].coupons || []).sort(function (a, b) { return (b.updatedAt || b.createdAt || 0) - (a.updatedAt || a.createdAt || 0); });
          var s = r[1].summary || {};
          clear(tiles);
          append(tiles, [tile('Coupons', String(s.totalCoupons || st.list.length), (s.activeCoupons || 0) + ' active'), tile('Redemptions', String(s.totalRedemptions || 0), (s.uniqueUsersCount || 0) + ' riders'),
            tile('Discount given', inr(s.totalDiscountGivenInr, 0)), tile('Revenue with coupons', inr(s.revenueGeneratedInr, 0))]);
          draw();
        }).catch(function (e) { clear(tiles).appendChild(errorNode(e)); });
      }
      function draw() {
        clear(tbody);
        var now = Date.now();
        var rows = st.list.filter(function (c) {
          var s = couponStatus(c, now).key;
          if (st.status && s !== st.status) return false;
          if (!st.status && s === 'ARCHIVED') return false;
          return !st.q || [c.code, c.name, c.campaignName].some(function (v) { return String(v || '').toLowerCase().indexOf(st.q) >= 0; });
        });
        if (!rows.length) { tbody.appendChild(h('tr', h('td', { colspan: '7', class: 'empty', text: st.list.length ? 'No coupons match.' : 'No coupons yet. Create the first one.' }))); return; }
        rows.forEach(function (c) {
          var s = couponStatus(c, now);
          var used = Number(c.usageCount) || 0; var max = Number(c.maxUsageTotal) || 0;
          var actions = h('div.row', { class: 'row row--end' });
          var stop = function (fn) { return function (e) { e.stopPropagation(); fn(); }; };
          if (s.key === 'ACTIVE' || s.key === 'SCHEDULED') actions.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Pause', onclick: stop(function () { act(c, 'pause'); }) }));
          if (s.key === 'PAUSED') actions.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Resume', onclick: stop(function () { act(c, 'resume'); }) }));
          if (s.key !== 'EXPIRED' && s.key !== 'ARCHIVED') actions.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Expire', onclick: stop(function () { expire(c); }) }));
          actions.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Edit', onclick: stop(function () { edit(c); }) }));
          tbody.appendChild(h('tr.is-link', { tabindex: '0', dataset: { code: c.code }, onclick: function () { details(c); }, onkeydown: function (e) { if (e.key === 'Enter' && e.target === this) details(c); } },
            h('td', h('b.mono', { text: c.code }), c.name && c.name !== c.code ? h('div.muted.small', { text: c.name + (c.campaignName ? ' · ' + c.campaignName : '') }) : null),
            h('td', { text: discountLabel(c) }), h('td', { text: plansLabel(c.applicableTiers) }),
            h('td.nowrap.small', { text: date(c.validFrom) + ' to ' + date(c.expiresAt) }),
            h('td.num', { text: used + (max ? ' / ' + max : '') }), h('td', s.chip), h('td', actions)));
        });
      }
      function act(c, action) {
        api('POST', '/admin/coupons/' + encodeURIComponent(c.code) + '/' + action, {}).then(function () { toast(c.code + (action === 'pause' ? ' paused.' : ' resumed.')); load(); }).catch(function (e) { toast(e.message, true); });
      }
      function expire(c) {
        confirmDialog('Expire ' + c.code + ' now?', 'Riders cannot use it any more. Marketing images that use it will warn that it has expired. You can edit the end date later to bring it back.', 'Expire now', true).then(function (ok) {
          if (!ok) return;
          var now = Date.now();
          var body = { expiresAt: now, status: 'EXPIRED' };
          if (Number(c.validFrom) >= now) body.validFrom = now - 60000;
          api('PATCH', '/admin/coupons/' + encodeURIComponent(c.code), body).then(function () { toast(c.code + ' expired.'); load(); }).catch(function (e) { toast(e.message, true); });
        });
      }
      function details(c) {
        var box = h('div.stack', loadingNode());
        var s = couponStatus(c, Date.now());
        var kv = h('dl.kv');
        [['Code', c.code], ['Name', c.name || '-'], ['Campaign', c.campaignName || '-'], ['Discount', discountLabel(c)], ['Plans', plansLabel(c.applicableTiers)],
          ['Valid', date(c.validFrom, true) + ' to ' + date(c.expiresAt, true)], ['Used', (c.usageCount || 0) + ' of ' + (c.maxUsageTotal || '∞') + ' · ' + (c.maxUsagePerUser || 1) + ' per rider'],
          ['Minimum order', c.minOrderAmount ? inr(c.minOrderAmount) : '-'], ['Rules', [c.newMembersOnly ? 'new members only' : '', c.firstPaymentOnly ? 'first payment only' : ''].filter(Boolean).join(', ') || '-'],
          ['Notes', c.internalNotes || '-'], ['Created by', c.createdBy || '-']].forEach(function (x) { kv.appendChild(h('dt', { text: x[0] })); kv.appendChild(h('dd', { text: x[1] })); });
        api('GET', '/admin/coupons/usage?code=' + encodeURIComponent(c.code) + '&limit=50').then(function (r) {
          clear(box);
          var rows = r.redemptions || [];
          box.appendChild(h('h3', { text: 'Recent redemptions' }));
          if (!rows.length) { box.appendChild(h('p.muted', { text: 'Not used yet.' })); return; }
          var tb = h('tbody');
          rows.forEach(function (x) { tb.appendChild(h('tr', h('td.nowrap', { text: date(x.redeemedAt || x.reservedAt || x.createdAt, true) }), h('td.mono', { text: x.userId || '-' }), h('td', { text: planLabel(x.category || x.planTier) }), h('td.num', { text: inr(x.discountAmount) }), h('td.num', { text: inr(x.finalAmount) }), h('td', { text: String(x.status || '') }))); });
          box.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['When', 'Rider', 'Plan', 'Discount', 'Paid', 'Status'].map(function (t, i) { return h('th', { class: i === 3 || i === 4 ? 'num' : '', text: t }); }))), tb)));
        }).catch(function (e) { clear(box).appendChild(errorNode(e)); });
        dialog({ title: c.code, wide: true, body: [h('div.row', s.chip), kv, box], actions: [
          { label: 'Make marketing image', onClick: function () { CR.go('#/marketing/new?coupon=' + encodeURIComponent(c.code)); return true; } },
          { label: 'Edit', kind: 'primary', onClick: function () { edit(c); return true; } }] });
      }
      function edit(c) {
        var isNew = !c; c = c || {};
        CR.planOptions().then(function (opts) {
          var now = Date.now();
          var f = {
            code: h('input', { type: 'text', maxlength: '32', value: c.code || '', disabled: !isNew, placeholder: 'e.g. DIWALI40', spellcheck: 'false' }),
            name: h('input', { type: 'text', maxlength: '80', value: c.name && c.name !== c.code ? c.name : '' }),
            campaign: h('input', { type: 'text', maxlength: '80', value: c.campaignName || '' }),
            description: h('input', { type: 'text', maxlength: '200', value: c.description || '' }),
            notes: h('textarea', { rows: '2', maxlength: '500', value: c.internalNotes || '' }),
            type: select([['percentage', 'Percentage'], ['fixed', 'Fixed amount (₹)'], ['free', 'Free (100%)']], c.discountType || 'percentage'),
            value: h('input', { type: 'number', min: '0', step: 'any', value: c.discountValue !== undefined ? String(c.discountValue) : '20' }),
            cap: h('input', { type: 'number', min: '0', step: '1', value: c.maxDiscountCap ? String(c.maxDiscountCap) : '' }),
            maxTotal: h('input', { type: 'number', min: '1', step: '1', value: String(c.maxUsageTotal || 100) }),
            perUser: h('input', { type: 'number', min: '1', step: '1', value: String(c.maxUsagePerUser || 1) }),
            from: h('input', { type: 'datetime-local', value: toLocalInput(c.validFrom || now) }),
            to: h('input', { type: 'datetime-local', value: toLocalInput(c.expiresAt || now + 30 * 86400000) }),
            minOrder: h('input', { type: 'number', min: '0', step: '1', value: c.minOrderAmount ? String(c.minOrderAmount) : '' }),
            newOnly: h('input', { type: 'checkbox', checked: !!c.newMembersOnly }),
            firstOnly: h('input', { type: 'checkbox', checked: !!c.firstPaymentOnly }),
            withOffer: h('input', { type: 'checkbox', checked: c.stackWithOffer !== false }),
            status: select([['ACTIVE', 'Active (from the start date)'], ['DRAFT', 'Draft (not usable)'], ['PAUSED', 'Paused']], ['DRAFT', 'PAUSED'].indexOf(c.status) >= 0 ? c.status : 'ACTIVE'),
          };
          var tiers = c.applicableTiers || ['all'];
          var all = h('input', { type: 'checkbox', checked: tiers.indexOf('all') >= 0 });
          var planChecks = opts.map(function (o) { return { id: o.id, box: h('input', { type: 'checkbox', checked: tiers.indexOf('all') < 0 && tiers.indexOf(o.id) >= 0, disabled: tiers.indexOf('all') >= 0 }), label: o.label + (o.monthlyInr ? ' (' + inr(o.monthlyInr) + ')' : '') }; });
          all.addEventListener('change', function () { planChecks.forEach(function (p) { p.box.disabled = all.checked; if (all.checked) p.box.checked = false; }); });
          var syncType = function () { f.value.disabled = f.type.value === 'free'; f.cap.disabled = f.type.value !== 'percentage'; };
          f.type.addEventListener('change', syncType); syncType();
          var body = [
            h('div.grid2', field('Code', f.code, isNew ? 'A to Z, 0 to 9, - and _' : 'cannot change'), field('Display name', f.name)),
            h('div.grid2', field('Campaign', f.campaign), field('Status', f.status)),
            h('div.grid3', field('Discount type', f.type), field('Value', f.value), field('Cap (₹)', f.cap, '% only')),
            h('div', h('div.panel-title', { text: 'Plans' }), h('div.row', { class: 'row' }, h('label.check', all, 'All plans'), planChecks.map(function (p) { return h('label.check', p.box, p.label); }))),
            h('div.grid2', field('Starts (India time)', f.from), field('Ends (India time)', f.to)),
            h('div.grid3', field('Total uses', f.maxTotal), field('Uses per rider', f.perUser), field('Minimum order (₹)', f.minOrder)),
            h('div.row', h('label.check', f.newOnly, 'New members only'), h('label.check', f.firstOnly, 'First payment only'), h('label.check', f.withOffer, 'Works on top of a plan offer')),
            field('Description', f.description, 'shown to riders'), field('Internal notes', f.notes, 'admins only'),
          ];
          dialog({ title: isNew ? 'New coupon' : 'Edit ' + c.code, wide: true, body: body, actions: [{ label: 'Cancel', value: null }, { label: isNew ? 'Create coupon' : 'Save', kind: 'primary', onClick: function () {
            var code = f.code.value.trim().toUpperCase();
            if (isNew && !/^[A-Z0-9_-]{3,32}$/.test(code)) throw new Error('The code needs 3 to 32 letters, digits, - or _.');
            var type = f.type.value; var value = type === 'free' ? 100 : Number(f.value.value);
            if (type !== 'free' && !(value > 0)) throw new Error('Enter a discount value above 0.');
            if (type === 'percentage' && value > 100) throw new Error('A percentage cannot be above 100.');
            var from = fromLocalInput(f.from.value); var to = fromLocalInput(f.to.value);
            if (!from || !to || to <= from) throw new Error('The coupon must end after it starts.');
            var chosen = all.checked ? ['all'] : planChecks.filter(function (p) { return p.box.checked; }).map(function (p) { return p.id; });
            if (!chosen.length) throw new Error('Pick at least one plan, or All plans.');
            var st2 = f.status.value;
            if (st2 === 'ACTIVE' && from > Date.now()) st2 = 'SCHEDULED';
            if (st2 === 'ACTIVE' && to < Date.now()) st2 = 'EXPIRED';
            var payload = {
              name: f.name.value.trim() || code || c.code, campaignName: f.campaign.value.trim(), description: f.description.value.trim(), internalNotes: f.notes.value.trim(),
              status: st2, discountType: type, discountValue: value, maxDiscountCap: type === 'percentage' && Number(f.cap.value) > 0 ? Number(f.cap.value) : null,
              applicableTiers: chosen, maxUsageTotal: parseInt(f.maxTotal.value, 10) || 100, maxUsagePerUser: parseInt(f.perUser.value, 10) || 1,
              validFrom: from, expiresAt: to, timezone: 'Asia/Kolkata', minOrderAmount: Number(f.minOrder.value) || 0,
              newMembersOnly: f.newOnly.checked, firstPaymentOnly: f.firstOnly.checked, stackWithOffer: f.withOffer.checked, isActive: st2 === 'ACTIVE' || st2 === 'SCHEDULED',
            };
            if (isNew) payload.code = code;
            var req = isNew ? api('POST', '/admin/coupons', payload) : api('PATCH', '/admin/coupons/' + encodeURIComponent(c.code), payload);
            return req.then(function () { toast(isNew ? 'Coupon ' + code + ' created.' : 'Coupon saved.'); load(); return true; });
          } }] });
        });
      }
      load();
    },
  };

  // ==================================================================== REVENUE (hand-drawn SVG charts)
  var SVGNS = 'http://www.w3.org/2000/svg';
  function s(tag, attrs) { var el = document.createElementNS(SVGNS, tag); Object.keys(attrs || {}).forEach(function (k) { el.setAttribute(k, attrs[k]); }); return el; }
  function niceMax(v) { if (v <= 0) return 1; var p = Math.pow(10, Math.floor(Math.log10(v))); var n = v / p; return (n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10) * p; }
  function short(n, money) {
    var a = Math.abs(n); var pre = money ? '₹' : '';
    if (a >= 1e7) return pre + (n / 1e7).toFixed(1).replace(/\.0$/, '') + 'Cr';
    if (a >= 1e5) return pre + (n / 1e5).toFixed(1).replace(/\.0$/, '') + 'L';
    if (a >= 1e3) return pre + (n / 1e3).toFixed(1).replace(/\.0$/, '') + 'k';
    return pre + Math.round(n);
  }
  /**
   * One-series chart. opts: { kind: 'bar'|'line', labels, values, money, title, format(i) -> tooltip value,
   * tick(i) -> axis label or '' }. Thin bars with 4px rounded tops, a 2px line, recessive grid, hover tooltip.
   */
  function chart(opts) {
    var wrap = h('div.chart', { role: 'img', 'aria-label': opts.title });
    var lastW = 0;
    var build = function () {
      var w = Math.round(wrap.clientWidth);
      if (!w || w === lastW) return;
      lastW = w;
      clear(wrap);
      drawChart(wrap, opts, w);
    };
    requestAnimationFrame(build);
    if (window.ResizeObserver) new ResizeObserver(build).observe(wrap);
    return wrap;
  }
  function drawChart(wrap, opts, W) {
    var H = 230; var pad = { l: 52, r: 10, t: 12, b: 26 };
    var svg = s('svg', { viewBox: '0 0 ' + W + ' ' + H, width: W, height: H });
    var vals = opts.values.map(function (v) { return Number(v) || 0; });
    var minV = Math.min(0, Math.min.apply(null, vals)); var maxV = niceMax(Math.max.apply(null, vals.concat([0])));
    // Counts get whole-number ticks only.
    if (!opts.money) maxV = Math.max(4, Math.ceil(maxV / 4) * 4);
    var y = function (v) { return pad.t + (H - pad.t - pad.b) * (1 - (v - minV) / (maxV - minV || 1)); };
    var n = vals.length; var band = (W - pad.l - pad.r) / Math.max(1, n);
    var grid = s('g', { class: 'grid' }); var axis = s('g', { class: 'axis' });
    for (var g = 0; g <= 4; g++) {
      var gv = minV + (maxV - minV) * g / 4; var gy = y(gv);
      grid.appendChild(s('line', { x1: pad.l, x2: W - pad.r, y1: gy, y2: gy }));
      var t = s('text', { x: pad.l - 8, y: gy + 4, 'text-anchor': 'end' }); t.textContent = short(gv, opts.money); axis.appendChild(t);
    }
    svg.appendChild(grid); svg.appendChild(axis);
    opts.labels.forEach(function (lab, i) {
      var tk = opts.tick ? opts.tick(i) : lab;
      var every = Math.max(1, Math.ceil(n * 58 / (W - pad.l - pad.r)));
      if (!opts.tick && (n - 1 - i) % every !== 0) tk = '';
      if (!tk) return;
      var t = s('text', { x: pad.l + band * (i + 0.5), y: H - 8, 'text-anchor': 'middle' }); t.textContent = tk; axis.appendChild(t);
    });
    var tip = h('div.chart__tip', { hidden: true });
    var marks = [];
    if (opts.kind === 'line') {
      var pts = vals.map(function (v, i) { return [pad.l + band * (i + 0.5), y(v)]; });
      var d = pts.map(function (p, i) { return (i ? 'L' : 'M') + p[0].toFixed(1) + ' ' + p[1].toFixed(1); }).join(' ');
      svg.appendChild(s('path', { class: 'area', d: d + ' L' + pts[n - 1][0].toFixed(1) + ' ' + y(0) + ' L' + pts[0][0].toFixed(1) + ' ' + y(0) + ' Z' }));
      svg.appendChild(s('path', { class: 'line', d: d }));
      var cross = s('line', { class: 'cross', y1: pad.t, y2: H - pad.b, visibility: 'hidden' }); svg.appendChild(cross);
      var dot = s('circle', { class: 'dot', r: 4.5, visibility: 'hidden' }); svg.appendChild(dot);
      marks = pts.map(function (p, i) { return { x: p[0], y: p[1], i: i, show: function () { cross.setAttribute('x1', p[0]); cross.setAttribute('x2', p[0]); cross.setAttribute('visibility', 'visible'); dot.setAttribute('cx', p[0]); dot.setAttribute('cy', p[1]); dot.setAttribute('visibility', 'visible'); }, hide: function () { cross.setAttribute('visibility', 'hidden'); dot.setAttribute('visibility', 'hidden'); } }; });
    } else {
      var bw = Math.max(2, Math.min(28, band * 0.62));
      marks = vals.map(function (v, i) {
        var x = pad.l + band * (i + 0.5) - bw / 2; var y0 = y(0); var y1 = y(v); var top = Math.min(y0, y1); var hgt = Math.max(v ? 1 : 0, Math.abs(y0 - y1));
        var r = Math.min(4, bw / 2, hgt);
        // Rounded data end, square at the baseline.
        var path = v >= 0
          ? 'M' + x + ' ' + (top + hgt) + ' V' + (top + r) + ' Q' + x + ' ' + top + ' ' + (x + r) + ' ' + top + ' H' + (x + bw - r) + ' Q' + (x + bw) + ' ' + top + ' ' + (x + bw) + ' ' + (top + r) + ' V' + (top + hgt) + ' Z'
          : 'M' + x + ' ' + top + ' V' + (top + hgt - r) + ' Q' + x + ' ' + (top + hgt) + ' ' + (x + r) + ' ' + (top + hgt) + ' H' + (x + bw - r) + ' Q' + (x + bw) + ' ' + (top + hgt) + ' ' + (x + bw) + ' ' + (top + hgt - r) + ' V' + top + ' Z';
        var bar = s('path', { class: 'bar', d: hgt ? path : 'M0 0' }); svg.appendChild(bar);
        return { x: x + bw / 2, y: top, i: i, show: function () { bar.classList.add('is-hot'); }, hide: function () { bar.classList.remove('is-hot'); } };
      });
    }
    // Hit targets: one full-height band per point (bigger than the mark).
    marks.forEach(function (m) {
      var hit = s('rect', { class: 'hit', x: pad.l + band * m.i, y: pad.t, width: band, height: H - pad.t - pad.b });
      hit.addEventListener('pointerenter', function () {
        m.show();
        clear(tip); tip.appendChild(h('b', { text: opts.format ? opts.format(m.i) : String(vals[m.i]) })); tip.appendChild(document.createTextNode(opts.labels[m.i]));
        var k = 1; var ky = 1;
        tip.style.left = (m.x * k) + 'px'; tip.style.top = (Math.min(m.y, H - pad.b) * ky) + 'px'; tip.hidden = false;
      });
      hit.addEventListener('pointerleave', function () { m.hide(); tip.hidden = true; });
      svg.appendChild(hit);
    });
    wrap.appendChild(svg); wrap.appendChild(tip);
  }
  CR.chart = chart;
  function monthLabel(k) { var p = k.split('-'); return MONTHS[Number(p[1]) - 1] + ' ' + p[0].slice(2); }
  function dayLabel(k) { var p = k.split('-'); return Number(p[2]) + ' ' + MONTHS[Number(p[1]) - 1]; }

  CR.sections.revenue = {
    title: 'Revenue',
    render: function (view) {
      var range = select([['30', 'Last 30 days'], ['60', 'Last 60 days'], ['90', 'Last 90 days']], '30', { 'aria-label': 'Daily range', class: 'select--sm' });
      var body = h('div', loadingNode());
      view.appendChild(pageHead('Revenue', 'Live Razorpay money after refunds, by the day it was paid (India time). Staff accounts and test-mode payments are left out.', range));
      view.appendChild(body);
      range.addEventListener('change', load);
      function load() {
        clear(body).appendChild(loadingNode());
        api('GET', '/admin/web/revenue?days=' + range.value + '&months=12').then(function (r) {
          clear(body);
          var m = r.monthly || []; var d = r.daily || [];
          var thisMonth = m[m.length - 1] || {}; var lastMonth = m[m.length - 2] || {};
          var sumDays = d.reduce(function (a, x) { return a + x.netInr; }, 0);
          append(body, [h('div.tiles',
            tile('Net, last ' + d.length + ' days', inr(sumDays, 0), d.reduce(function (a, x) { return a + x.orders; }, 0) + ' paid orders'),
            tile('This month', inr(thisMonth.netInr, 0), 'last month ' + inr(lastMonth.netInr, 0)),
            tile('Active paid plans', String((r.totals || {}).activePaidPlans || 0), Object.keys(r.activePaidPlans || {}).map(function (k) { return planLabel(k) + ' ' + r.activePaidPlans[k]; }).join(' · ') || 'none yet'),
            tile('Coupon uses this month', String(thisMonth.couponRedemptions || 0), inr(thisMonth.couponDiscountInr, 0) + ' discount given'),
            r.totals && r.totals.testNetInr ? tile('Test mode (not counted)', inr(r.totals.testNetInr, 0), 'all time, net') : null)]);
          var grid = h('div.chart-grid');
          grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Net revenue per day' })),
            chart({ kind: 'bar', title: 'Net revenue per day', money: true, labels: d.map(function (x) { return dayLabel(x.date); }), values: d.map(function (x) { return x.netInr; }),
              format: function (i) { return inr(d[i].netInr) + ' · ' + d[i].orders + ' orders'; }, tick: function (i) { var step = Math.ceil(d.length / 8); return (d.length - 1 - i) % step === 0 ? dayLabel(d[i].date) : ''; } })));
          grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Net revenue per month' })),
            chart({ kind: 'line', title: 'Net revenue per month', money: true, labels: m.map(function (x) { return monthLabel(x.month); }), values: m.map(function (x) { return x.netInr; }),
              format: function (i) { return inr(m[i].netInr) + (m[i].refundsInr ? ' (−' + inr(m[i].refundsInr) + ' refunds)' : ''); } })));
          grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Active paid plans at month end' }), h('p', { text: 'From membership start and end dates; refunded plans are left out.' })),
            chart({ kind: 'bar', title: 'Active paid plans at month end', labels: m.map(function (x) { return monthLabel(x.month); }), values: m.map(function (x) { return x.activePaidPlans; }),
              format: function (i) { return m[i].activePaidPlans + ' plans'; } })));
          grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Coupon redemptions per month' })),
            chart({ kind: 'bar', title: 'Coupon redemptions per month', labels: m.map(function (x) { return monthLabel(x.month); }), values: m.map(function (x) { return x.couponRedemptions; }),
              format: function (i) { return m[i].couponRedemptions + ' uses · ' + inr(m[i].couponDiscountInr) + ' off'; } })));
          body.appendChild(grid);

          var tops = h('div.chart-grid', { class: 'chart-grid section-gap' });
          var tc = h('tbody');
          (r.topCoupons || []).forEach(function (c) { tc.appendChild(h('tr', h('td.mono', { text: c.code }), h('td.num', { text: String(c.redemptions) }), h('td.num', { text: inr(c.discountInr) }), h('td.num', { text: inr(c.netInr) }))); });
          if (!(r.topCoupons || []).length) tc.appendChild(h('tr', h('td', { colspan: '4', class: 'empty', text: 'No coupon redemptions in this period.' })));
          var bp = h('tbody');
          (r.byPlan || []).forEach(function (p) { bp.appendChild(h('tr', h('td', { text: planLabel(p.plan) }), h('td.num', { text: String(p.orders) }), h('td.num', { text: inr(p.netInr) }))); });
          if (!(r.byPlan || []).length) bp.appendChild(h('tr', h('td', { colspan: '3', class: 'empty', text: 'No paid orders yet.' })));
          tops.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Top coupons (12 months)' })), h('div.table-wrap', h('table.table', h('thead', h('tr', ['Code', 'Uses', 'Discount', 'Paid'].map(function (t, i) { return h('th', { class: i ? 'num' : '', text: t }); }))), tc))));
          tops.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'By plan (all time)' })), h('div.table-wrap', h('table.table', h('thead', h('tr', ['Plan', 'Orders', 'Net'].map(function (t, i) { return h('th', { class: i ? 'num' : '', text: t }); }))), bp))));
          body.appendChild(tops);

          var mt = h('tbody');
          m.slice().reverse().forEach(function (x) { mt.appendChild(h('tr', h('td', { text: monthLabel(x.month) }), h('td.num', { text: inr(x.netInr) }), h('td.num', { text: String(x.orders) }), h('td.num', { text: inr(x.refundsInr) }), h('td.num', { text: String(x.activePaidPlans) }), h('td.num', { text: String(x.couponRedemptions) }))); });
          body.appendChild(h('div.card', { class: 'card section-gap' }, h('div.card__head', h('h3', { text: 'Monthly table' })),
            h('div.table-wrap', h('table.table', h('thead', h('tr', ['Month', 'Net', 'Orders', 'Refunds', 'Active plans', 'Coupon uses'].map(function (t, i) { return h('th', { class: i ? 'num' : '', text: t }); }))), mt))));
        }).catch(function (e) { clear(body).appendChild(errorNode(e)); });
      }
      load();
    },
  };

  // ------------------------------------------------------------------ start
  document.addEventListener('DOMContentLoaded', function () {
    initTheme();
    initSignIn();
    $('signout').addEventListener('click', function () { signOut(''); });
    var t = token();
    if (t && !tokenExpired(t) && Date.now() - (Number(read(ACTIVE_KEY)) || 0) <= IDLE_MS) enterShell();
    else signOut(t ? 'You were signed out after 30 minutes without activity.' : '');
  });
})();
