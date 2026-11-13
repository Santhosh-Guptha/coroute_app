/* CoRoute web admin shell extras (3.57 round 3, docs/features_355/web_admin.md):
   #/overview   simple KPIs and charts from existing endpoints (/admin/analytics/overview, /admin/analytics/trends, /admin/web/revenue)
   #/settings   one place for settings: Access mode, Pricing (Plans & pricing), Templates (message words), SMS, E-mail
   #/audit      the audit log (GET /admin/audit) with a filter by action and a search
   Global search (top bar, "/" to focus): riders by username / e-mail, order ids, coupon codes (GET /admin/search).
   Tablet: the menu is a drawer (Menu button, Escape closes). Text is set as text only. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api, date = CR.util.date, inr = CR.util.inr;
  function $(id) { return document.getElementById(id); }

  // ==================================================================== overview
  function kpiTile(label, value, note, href) {
    var t = ui.tile(label, value, note);
    if (!href) return t;
    var a = h('a.tile-link', { href: href, 'aria-label': label + ': ' + value });
    a.appendChild(t);
    return a;
  }
  CR.sections.overview = {
    title: 'Overview',
    render: function (view) {
      var range = ui.select([['7', 'Last 7 days'], ['30', 'Last 30 days'], ['90', 'Last 90 days']], '30', { 'aria-label': 'Period' });
      view.appendChild(ui.pageHead('Overview', 'How CoRoute is doing. Staff accounts are left out.', range));
      var body = h('div', ui.loading());
      view.appendChild(body);
      function load() {
        var days = Number(range.value);
        clear(body).appendChild(ui.loading());
        Promise.all([
          api('GET', '/admin/analytics/overview?days=' + days).catch(function () { return null; }),
          api('GET', '/admin/analytics/trends?days=' + days + '&tz=330').catch(function () { return null; }),
          api('GET', '/admin/web/revenue?days=' + Math.max(7, days) + '&months=12').catch(function () { return null; }),
        ]).then(function (r) {
          clear(body);
          var o = r[0] || {}; var tr = r[1]; var rev = r[2];
          var riders = o.riders || {}; var att = o.attention || {};
          var sum = function (a) { return (a || []).reduce(function (x, y) { return x + (Number(y) || 0); }, 0); };
          var netDays = rev ? rev.daily.reduce(function (a, x) { return a + x.netInr; }, 0) : 0;
          var tiles = h('div.tiles');
          tiles.appendChild(kpiTile('Riders', String(riders.total || 0), (riders.activeToday || 0) + ' active today', '#/riders'));
          if (tr) {
            tiles.appendChild(kpiTile('Rides', String(sum(tr.series.rides)), 'group rides ended, ' + days + ' days'));
            tiles.appendChild(kpiTile('New riders', String(sum(tr.series.signups)), days + ' days', '#/riders'));
          }
          tiles.appendChild(kpiTile('Net revenue', inr(netDays, 0), days + ' days, after refunds', '#/revenue'));
          tiles.appendChild(kpiTile('Paid plans', String(rev && rev.totals ? rev.totals.activePaidPlans || 0 : 0), 'active now', '#/riders'));
          tiles.appendChild(kpiTile('Live rides', String(att.liveRides || 0), (att.openSos || 0) + ' open SOS'));
          body.appendChild(tiles);
          var todo = [];
          if (att.openSos) todo.push([att.openSos + ' open SOS', 'Handle in the app admin console.', 'bad']);
          if (att.onHold) todo.push([att.onHold + ' riders on hold', 'Review on Riders.', 'warn', '#/riders']);
          if (att.reportsOpen) todo.push([att.reportsOpen + ' open reports', 'Public ride reports in the app admin.', 'warn']);
          if (att.reviewsPending || att.photosPending) todo.push([(att.reviewsPending || 0) + ' reviews, ' + (att.photosPending || 0) + ' photos waiting', 'Moderate in the app admin.', '']);
          if (todo.length) {
            var tl = h('ul.todo');
            todo.forEach(function (x) { tl.appendChild(h('li', ui.chip(x[0], x[2]), h('span.small.muted', { text: ' ' + x[1] }), x[3] ? h('a.small', { href: x[3], text: ' Open' }) : null)); });
            body.appendChild(h('div.card.section-gap', h('div.card__head', h('h2', { text: 'Needs attention' })), tl));
          }
          var grid = h('div.chart-grid.section-gap');
          var tick = function (labels) { return function (i) { var step = Math.ceil(labels.length / 7); return (labels.length - 1 - i) % step === 0 ? labels[i] : ''; }; };
          if (tr && CR.chart) {
            grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Active riders per day' })),
              CR.chart({ kind: 'line', title: 'Active riders per day', labels: tr.labels, values: tr.series.activeRiders, format: function (i) { return tr.series.activeRiders[i] + ' riders'; }, tick: tick(tr.labels) })));
            grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'New riders per day' })),
              CR.chart({ kind: 'bar', title: 'New riders per day', labels: tr.labels, values: tr.series.signups, format: function (i) { return tr.series.signups[i] + ' sign-ups'; }, tick: tick(tr.labels) })));
          }
          if (rev && CR.chart) {
            var dl = rev.daily.map(function (x) { var p = x.date.split('-'); return Number(p[2]) + ' ' + ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][Number(p[1]) - 1]; });
            grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Net revenue per day' })),
              CR.chart({ kind: 'bar', title: 'Net revenue per day', money: true, labels: dl, values: rev.daily.map(function (x) { return x.netInr; }), format: function (i) { return inr(rev.daily[i].netInr) + ' · ' + rev.daily[i].orders + ' orders'; }, tick: tick(dl) })));
          }
          if (tr && CR.chart) {
            grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Group rides per day' })),
              CR.chart({ kind: 'bar', title: 'Group rides per day', labels: tr.labels, values: tr.series.rides, format: function (i) { return tr.series.rides[i] + ' rides'; }, tick: tick(tr.labels) })));
          }
          if (grid.firstChild) body.appendChild(grid);
          body.appendChild(h('div.card.section-gap.quick', h('h2', { text: 'Quick actions' }), h('div.row',
            h('a.btn', { href: '#/riders', text: 'Find a rider' }), h('a.btn', { href: '#/email', text: 'Send an e-mail' }), h('a.btn', { href: '#/coupons', text: 'New coupon' }),
            h('a.btn', { href: '#/push', text: 'Send a push' }), h('a.btn', { href: '#/board', text: 'Post on the board' }))));
          if (!r[0] && !r[1] && !r[2]) body.insertBefore(h('div.banner.banner--bad', { text: 'The numbers could not load. Refresh to try again.' }), body.firstChild);
        });
      }
      range.addEventListener('change', load);
      load();
    },
  };

  // ==================================================================== settings
  var SETTINGS_TABS = [['', 'Access mode', 'Paid, free for everyone, or free up to limits'], ['pricing', 'Pricing & payments', 'Plan prices, offers and Razorpay keys'],
    ['templates', 'Templates', 'Words of receipts, welcome, plan assigned, coupon for you, SMS and push notices'], ['sms', 'SMS', 'SOS SMS provider'], ['email', 'E-mail', 'Weekly limit, quiet hours, sender, blocked addresses'], ['summary', 'Weekly summary', 'The Monday e-mail to the administrators']];
  CR.sections.settings = {
    title: 'Settings',
    render: function (view, arg) {
      var sub = arg || '';
      view.appendChild(ui.pageHead('Settings', 'Access mode, pricing, message words, SMS, e-mail and the weekly summary.'));
      var nav = h('div.row.eng-tabs.es-tabs', { role: 'tablist', 'aria-label': 'Settings' });
      SETTINGS_TABS.forEach(function (t) {
        nav.appendChild(h('button.btn.btn--sm', { type: 'button', role: 'tab', title: t[2], 'aria-selected': String(sub === t[0]), 'aria-pressed': String(sub === t[0]), text: t[1],
          onclick: function () { CR.go('#/settings' + (t[0] ? '/' + t[0] : '')); } }));
      });
      view.appendChild(nav);
      var inner = h('div.settings-body');
      view.appendChild(inner);
      if (sub === 'pricing') { if (CR.sections.plans) CR.sections.plans.render(inner, ''); return; }
      if (sub === 'templates') { if (CR.sections.templates) CR.sections.templates.render(inner, ''); return; }
      if (sub === 'sms') { if (CR.renderSms) CR.renderSms(inner); return; }
      if (sub === 'email') { if (CR.emailStudio) CR.emailStudio.renderSettings(inner); return; }
      if (sub === 'summary') { if (CR.renderWeeklySummary) CR.renderWeeklySummary(inner); return; }
      inner.appendChild(h('p.muted', { text: 'Who may host group rides, and whether it needs a plan. The app gets only the result, never prices.' }));
      if (CR.accessModeCard) inner.appendChild(CR.accessModeCard());
    },
  };

  // ==================================================================== audit log
  var AUDIT_GROUPS = [['', 'Everything'], ['rider', 'Rider actions'], ['subscription', 'Plans given / ended'], ['coupon', 'Coupons'], ['payment', 'Payments and refunds'], ['pricing', 'Pricing'],
    ['email', 'E-mail'], ['template', 'Templates'], ['access_mode', 'Access mode'], ['operator', 'Operators'], ['user', 'Rider access'], ['board', 'Board'], ['diag', 'Diagnostics']];
  CR.sections.audit = {
    title: 'Audit log',
    render: function (view) {
      var action = ui.select(AUDIT_GROUPS, '', { 'aria-label': 'Kind of action' });
      var q = h('input', { type: 'search', placeholder: 'Filter by admin, rider id, code…', 'aria-label': 'Filter' });
      view.appendChild(ui.pageHead('Audit log', 'Every change admins made, newest first. Secrets are never logged.'));
      view.appendChild(h('div.toolbar', action, q));
      var out = h('div', ui.loading());
      view.appendChild(out);
      var rows = [];
      function draw() {
        var f = q.value.trim().toLowerCase();
        var list = f ? rows.filter(function (e) { return JSON.stringify(e).toLowerCase().indexOf(f) >= 0; }) : rows;
        clear(out);
        if (!list.length) { out.appendChild(h('div.card.empty-state', h('b', { text: 'Nothing here.' }), h('p.muted', { text: 'Try another kind of action.' }))); return; }
        var tb = h('tbody');
        list.forEach(function (e) {
          var target = e.target ? (/^usr_/.test(e.target) ? h('a', { href: '#/riders/' + encodeURIComponent(e.target), text: e.target }) : h('span.mono', { text: e.target })) : null;
          var details = Object.keys(e.details || {}).filter(function (k) { var v = e.details[k]; return v !== null && v !== undefined && v !== '' && typeof v !== 'object'; }).slice(0, 6)
            .map(function (k) { return k + ': ' + String(e.details[k]).slice(0, 80); }).join(' · ');
          tb.appendChild(h('tr', h('td.nowrap', { text: date(e.at, true) }), h('td', h('span.mono', { text: e.action })), h('td.small', target), h('td.small', { text: details }), h('td.small.muted', { text: e.by || '' })));
        });
        out.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['When (IST)', 'Action', 'Target', 'Details', 'By'].map(function (c) { return h('th', { text: c }); }))), tb)));
        out.appendChild(h('p.small.muted.section-gap', { text: list.length + ' entr' + (list.length === 1 ? 'y' : 'ies') + ' shown.' }));
      }
      function load() {
        clear(out).appendChild(ui.loading());
        api('GET', '/admin/audit?limit=300' + (action.value ? '&action=' + encodeURIComponent(action.value) : '')).then(function (r) { rows = r.entries || []; draw(); })
          .catch(function (e) { clear(out).appendChild(ui.error(e)); });
      }
      action.addEventListener('change', load);
      q.addEventListener('input', draw);
      load();
    },
  };

  // ==================================================================== global search
  function initSearch() {
    var input = $('gsearch'); var list = $('gsearch-list');
    if (!input || !list) return;
    var timer = null; var items = []; var active = -1; var gen = 0;
    function close() { list.hidden = true; input.setAttribute('aria-expanded', 'false'); active = -1; }
    function setActive(i) {
      items.forEach(function (it, j) { it.el.classList.toggle('is-active', j === i); it.el.setAttribute('aria-selected', String(j === i)); });
      active = i;
      if (items[i]) { input.setAttribute('aria-activedescendant', items[i].el.id); items[i].el.scrollIntoView({ block: 'nearest' }); }
    }
    function go(it) { close(); input.value = ''; it.open(); }
    function show(r) {
      clear(list); items = [];
      var add = function (group, entries) {
        if (!entries.length) return;
        list.appendChild(h('div.gsearch__group', { text: group }));
        entries.forEach(function (x) {
          var el = h('button.gsearch__item', { type: 'button', role: 'option', id: 'gs' + items.length }, x.icon || null, h('span', h('b', { text: x.title }), x.sub ? h('small', { text: x.sub }) : null));
          var it = { el: el, open: x.open };
          el.addEventListener('mousedown', function (e) { e.preventDefault(); go(it); });
          items.push(it); list.appendChild(el);
        });
      };
      add('Riders', r.riders.map(function (x) { return { icon: CR.riderAvatar ? CR.riderAvatar(x, 24) : null, title: x.username ? '@' + x.username : x.name, sub: [x.name, x.email, x.planName].filter(Boolean).join(' · '), open: function () { CR.go('#/riders/' + encodeURIComponent(x.userId)); } }; }));
      add('Orders', r.orders.map(function (x) { return { title: x.orderId, sub: x.status + ' · ' + inr(x.amountInr) + (x.username ? ' · @' + x.username : '') + ' · ' + date(x.createdAt), open: function () { if (x.userId) CR.go('#/riders/' + encodeURIComponent(x.userId)); else CR.go('#/payments'); } }; }));
      add('Coupons', r.coupons.map(function (x) { return { title: x.code, sub: x.discount + ' · ' + String(x.status || '').toLowerCase() + (x.parentCode ? ' · from ' + x.parentCode : '') + (x.personal ? ' · personal' : ''), open: function () { if (x.personal) CR.go('#/riders/' + encodeURIComponent(x.personal)); else CR.go('#/coupons'); } }; }));
      if (!items.length) list.appendChild(h('div.gsearch__empty', { text: 'Nothing found.' }));
      list.hidden = false; input.setAttribute('aria-expanded', 'true');
      if (items.length) setActive(0);
    }
    input.addEventListener('input', function () {
      clearTimeout(timer);
      var v = input.value.trim();
      if (v.length < 2) { close(); return; }
      timer = setTimeout(function () {
        var g = ++gen;
        api('GET', '/admin/search?q=' + encodeURIComponent(v)).then(function (r) { if (g === gen && input.value.trim() === v) show(r); }).catch(function () { /* ignore */ });
      }, 200);
    });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown' && items.length) { e.preventDefault(); setActive((active + 1) % items.length); }
      else if (e.key === 'ArrowUp' && items.length) { e.preventDefault(); setActive((active - 1 + items.length) % items.length); }
      else if (e.key === 'Enter' && items[active]) { e.preventDefault(); go(items[active]); }
      else if (e.key === 'Escape') { close(); input.blur(); }
    });
    input.addEventListener('blur', function () { setTimeout(close, 120); });
    document.addEventListener('keydown', function (e) {
      if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey) return;
      var t = e.target; var tag = t && t.tagName;
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || (t && t.isContentEditable) || document.querySelector('.scrim')) return;
      e.preventDefault(); input.focus();
    });
  }

  // ==================================================================== tablet menu drawer
  function initMenu() {
    var btn = $('menu-btn'); var scrim = $('side-scrim');
    if (!btn) return;
    function set(open) {
      document.body.classList.toggle('nav-open', open);
      btn.setAttribute('aria-expanded', String(open));
      if (scrim) scrim.hidden = !open;
      if (open) { var a = document.querySelector('#nav a[aria-current="page"]') || document.querySelector('#nav a'); if (a) a.focus(); }
    }
    btn.addEventListener('click', function () { set(!document.body.classList.contains('nav-open')); });
    if (scrim) scrim.addEventListener('click', function () { set(false); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && document.body.classList.contains('nav-open')) { set(false); btn.focus(); } });
  }

  document.addEventListener('DOMContentLoaded', function () { initSearch(); initMenu(); });
})();
