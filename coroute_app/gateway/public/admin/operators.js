/* CoRoute web admin: Operators (3.56, docs/features_355/operators.md). Review operator / club applications, approve
   with limits and features (defaults from a per-type template), reject with a reason, suspend / reinstate, change
   limits later, edit the templates. Every decision is audited server side (GET /api/admin/audit?action=operator).
   Uses the shell in admin.js (window.CR). Text is always set as text. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, date = CR.util.date;
  var api = CR.api, ui = CR.ui;

  var STATUS = { PENDING: ['Waiting', 'warn'], APPROVED: ['Approved', 'ok'], REJECTED: ['Rejected', ''], SUSPENDED: ['Suspended', 'bad'], EXPIRED: ['Expired', ''] };
  var LIMIT_LABELS = {
    maxMembers: ['Roster size', 'riders on the roster (pending invites count)'],
    maxConcurrentRides: ['Live rides at once', 'concurrent rides'],
    maxRidesPerMonth: ['Rides per month', 'India-time calendar month'],
    maxRidersPerRide: ['Riders per ride', 'lead included; server ceiling applies'],
    coOrganisers: ['Co-organisers', '0 = owner only']
  };
  var state = { status: 'PENDING', type: '', q: '' };

  function statusChip(s) { var i = STATUS[s] || [s, '']; return ui.chip(i[0], i[1]); }

  // ---- nav badge: pending applications (every 60 s while signed in) ----
  function badge() {
    var link = document.querySelector('#nav a[data-section="operators"]');
    if (!link) return;
    var tok = null;
    try { tok = sessionStorage.getItem('cr.admin.token'); } catch (e) { tok = null; }
    if (!tok) return;
    api('GET', '/admin/operators/summary').then(function (r) {
      var b = link.querySelector('.navcount');
      if (!b) { b = h('span.navcount.chip.chip--warn'); link.appendChild(b); }
      b.textContent = String(r.pending);
      b.hidden = !r.pending;
    }).catch(function () { /* ignore */ });
  }
  setTimeout(badge, 1500);
  setInterval(badge, 60000);

  // ==================================================================== list
  function renderList(view) {
    clear(view);
    var tabs = h('div.row', { role: 'tablist', 'aria-label': 'Status' });
    var search = h('input', { type: 'search', placeholder: 'Name, city or e-mail', value: state.q });
    var type = CR.ui.select([['', 'All types'], ['TOUR_OPERATOR', 'Tour operator'], ['RIDING_CLUB', 'Riding club'], ['RENTAL_FLEET', 'Rental fleet'], ['CORPORATE_FLEET', 'Corporate fleet']], state.type);
    view.appendChild(ui.pageHead('Operators', 'Tour operators, riding clubs and fleets that applied for the operator console. Approve with limits and features; every decision is audited.',
      h('button.btn', { type: 'button', text: 'Templates per type', onclick: templatesDialog })));
    var banner = h('div');
    view.appendChild(banner);
    view.appendChild(tabs);
    view.appendChild(h('div.toolbar.op-gap', search, type));
    var body = h('div', ui.loading());
    view.appendChild(body);
    function load() {
      var qs = '?status=' + encodeURIComponent(state.status) + '&type=' + encodeURIComponent(state.type) + '&q=' + encodeURIComponent(state.q);
      api('GET', '/admin/operators' + qs).then(function (r) {
        clear(banner);
        if (!r.featureOn) banner.appendChild(h('div.banner', { text: 'The "Operator & club console" feature switch is off: riders cannot apply and consoles are closed. Turn it on under Feature switches in the app admin.' }));
        clear(tabs);
        [['PENDING', 'Waiting'], ['APPROVED', 'Approved'], ['SUSPENDED', 'Suspended'], ['REJECTED', 'Rejected'], ['EXPIRED', 'Expired'], ['', 'All']].forEach(function (t) {
          var n = t[0] ? (r.counts[t[0]] || 0) : Object.keys(r.counts).reduce(function (s, k) { return s + r.counts[k]; }, 0);
          tabs.appendChild(h('button.btn.btn--sm' + (state.status === t[0] ? '.is-on' : ''), { type: 'button', role: 'tab', 'aria-selected': String(state.status === t[0]), text: t[1] + ' (' + n + ')',
            onclick: function () { state.status = t[0]; load(); } }));
        });
        clear(body);
        if (!r.operators.length) { body.appendChild(h('div.card', h('p.empty', { text: 'No operators here.' }))); return; }
        var tb = h('tbody');
        r.operators.forEach(function (o) {
          tb.appendChild(h('tr.is-link', { onclick: function () { CR.go('#/operators/' + o.operatorId); } },
            h('td', h('b', { text: o.name }), h('div.small.muted', { text: o.owner ? '@' + o.owner.username : '-' })),
            h('td', { text: o.typeLabel }), h('td', { text: o.city }), h('td', statusChip(o.status)),
            h('td.num', { text: String(o.expectedRiders) }), h('td.nowrap', { text: date(o.createdAt) }),
            h('td.nowrap', { text: o.validUntil ? date(o.validUntil) : '-' })));
        });
        body.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Organisation' }), h('th', { text: 'Type' }), h('th', { text: 'City' }), h('th', { text: 'Status' }), h('th.num', { text: 'Expected riders' }), h('th', { text: 'Applied' }), h('th', { text: 'Valid until' }))), tb)));
      }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
    }
    var t = null;
    search.addEventListener('input', function () { clearTimeout(t); t = setTimeout(function () { state.q = search.value.trim(); load(); }, 300); });
    type.addEventListener('change', function () { state.type = type.value; load(); });
    load();
  }

  // ==================================================================== detail
  function limitsForm(base, features, featureLabels, bounds, validityDays) {
    var inputs = {};
    var grid = h('div.grid3');
    Object.keys(LIMIT_LABELS).forEach(function (k) {
      var b = bounds[k] || [0, 100000];
      inputs[k] = h('input', { type: 'number', min: String(b[0]), max: String(b[1]), value: String(base[k] == null ? b[0] : base[k]) });
      grid.appendChild(ui.field(LIMIT_LABELS[k][0], inputs[k], b[0] + '-' + b[1] + ' · ' + LIMIT_LABELS[k][1]));
    });
    var vb = bounds.validityDays || [1, 1095];
    var validity = h('input', { type: 'number', min: String(vb[0]), max: String(vb[1]), value: String(validityDays || 365) });
    grid.appendChild(ui.field('Valid for (days)', validity, 'from today; ' + vb[0] + '-' + vb[1]));
    var checks = {};
    var feats = h('div.stack');
    Object.keys(featureLabels).forEach(function (k) {
      checks[k] = h('input', { type: 'checkbox', checked: !!features[k] });
      feats.appendChild(h('label.check', checks[k], featureLabels[k]));
    });
    return {
      el: h('div.stack', h('h3', { text: 'Limits' }), grid, h('h3', { text: 'Features' }), feats),
      value: function () {
        var limits = {}; var f = {};
        Object.keys(inputs).forEach(function (k) { limits[k] = Number(inputs[k].value); });
        Object.keys(checks).forEach(function (k) { f[k] = checks[k].checked; });
        return { limits: limits, features: f, validityDays: Number(validity.value) };
      }
    };
  }

  function renderDetail(view, id) {
    clear(view).appendChild(ui.loading());
    api('GET', '/admin/operators/' + encodeURIComponent(id)).then(function (r) {
      var o = r.operator;
      clear(view);
      view.appendChild(h('p', h('a', { href: '#/operators', text: '← All operators' })));
      view.appendChild(ui.pageHead(o.name, o.typeLabel + ' · ' + o.city + ' · applied ' + date(o.createdAt, true), statusChip(o.status)));
      if (o.reason) view.appendChild(h('div.banner' + (o.status === 'SUSPENDED' ? '.banner--bad' : ''), { text: 'Reason given: ' + o.reason }));
      var kv = h('dl.kv',
        h('dt', { text: 'Owner' }), h('dd', { text: o.owner ? '@' + o.owner.username + ' (' + (o.owner.name || '-') + ')' : '-' }),
        h('dt', { text: 'Owner account e-mail' }), h('dd', { text: o.ownerEmail || '-' }),
        h('dt', { text: 'Business e-mail' }), h('dd', h('a', { href: 'mailto:' + o.contact.email, text: o.contact.email })),
        h('dt', { text: 'Business phone' }), h('dd', { text: o.contact.phone }),
        h('dt', { text: 'Website' }), h('dd', o.website ? h('a', { href: o.website, target: '_blank', rel: 'noopener noreferrer', text: o.website }) : '-'),
        h('dt', { text: 'Expected riders' }), h('dd', { text: String(o.expectedRiders) }),
        h('dt', { text: 'Description' }), h('dd', { text: o.description }),
        o.coOrganisers && o.coOrganisers.length ? [h('dt', { text: 'Co-organisers' }), h('dd', { text: o.coOrganisers.map(function (c) { return '@' + c.username; }).join(', ') })] : null,
        o.validUntil ? [h('dt', { text: 'Valid' }), h('dd', { text: date(o.validFrom) + ' to ' + date(o.validUntil) })] : null);
      var info = h('div.card', h('div.card__head', h('h2', { text: 'Application' }), h('p', { text: 'The business contact is private: only CoRoute admins and the owner see it.' })), kv);
      var hist = h('div.card', h('div.card__head', h('h2', { text: 'History' })));
      var ul = h('ul.op-hist');
      (o.history || []).slice().reverse().forEach(function (e) {
        ul.appendChild(h('li', { text: date(e.at, true) + ' · ' + e.action.toLowerCase() + (e.by ? ' by ' + e.by : '') + (e.reason ? ' · ' + e.reason : '') }));
      });
      hist.appendChild(ul);
      hist.appendChild(h('p.small.muted.op-gap', { text: 'Full audit trail: Plans & pricing > Audit log (action "operator").' }));
      view.appendChild(h('div.grid2', info, hist));

      if (r.usage) {
        var u = r.usage, l = o.limits || {};
        view.appendChild(h('div.tiles.op-gap',
          ui.tile('Roster', u.members + ' / ' + (l.maxMembers || '-'), u.pendingInvites + ' invites waiting'),
          ui.tile('Rides this month', u.ridesThisMonth + ' / ' + (l.maxRidesPerMonth || '-')),
          ui.tile('Live now', u.liveRides + ' / ' + (l.maxConcurrentRides || '-')),
          ui.tile('All rides', String(u.totalRides)),
          ui.tile('Co-organisers', u.coOrganisers + ' / ' + (l.coOrganisers == null ? '-' : l.coOrganisers))));
      }

      var act = h('div.card.op-gap');
      var pending = o.status === 'PENDING' || o.status === 'REJECTED';
      var base = pending ? r.template.limits : (o.limits || r.template.limits);
      var feats = pending ? r.template.features : (o.features || r.template.features);
      var days = pending ? r.template.validityDays : Math.max(1, Math.round(((o.validUntil || Date.now()) - Date.now()) / 86400000));
      var form = limitsForm(base, feats, r.features, r.bounds, days);
      act.appendChild(h('div.card__head', h('h2', { text: pending ? 'Approve with these limits' : 'Limits and features' }),
        h('p', { text: pending ? 'Defaults come from the ' + o.typeLabel + ' template. Change any of them for this operator.' : 'Changes apply at once; a ride already under way keeps its seats.' })));
      act.appendChild(form.el);
      var buttons = h('div.row.row--end.op-gap');
      function run(path, method, body, msg) {
        return api(method || 'POST', '/admin/operators/' + o.operatorId + path, body).then(function () { ui.toast(msg); renderDetail(view, id); badge(); });
      }
      function withReason(title, label, path, msg, danger) {
        var reason = h('textarea', { rows: '3', maxlength: '300', placeholder: 'The operator sees this reason.' });
        return ui.dialog({ title: title, body: [ui.field('Reason', reason)], actions: [{ label: 'Cancel', value: null }, { label: label, kind: danger ? 'danger' : 'primary', onClick: function () {
          return run(path, 'POST', { reason: reason.value }, msg);
        } }] });
      }
      if (o.status === 'PENDING') {
        buttons.appendChild(h('button.btn.btn--danger', { type: 'button', text: 'Reject…', onclick: function () { withReason('Reject ' + o.name, 'Reject', '/reject', 'Application rejected.', true); } }));
      }
      if (pending) {
        buttons.appendChild(h('button.btn.btn--primary', { type: 'button', text: 'Approve', onclick: function () {
          var v = form.value();
          ui.confirm('Approve ' + o.name + '?', 'The owner gets the operator console with these limits for ' + v.validityDays + ' days, and a club roster in the app.', 'Approve').then(function (ok) {
            if (ok) run('/approve', 'POST', v, 'Approved.').catch(function (e) { ui.toast(e.message, true); });
          });
        } }));
      } else {
        if (o.status === 'APPROVED' || o.status === 'EXPIRED') buttons.appendChild(h('button.btn.btn--danger', { type: 'button', text: 'Suspend…', onclick: function () { withReason('Suspend ' + o.name, 'Suspend', '/suspend', 'Operator suspended.', true); } }));
        if (o.status === 'SUSPENDED') buttons.appendChild(h('button.btn', { type: 'button', text: 'Reinstate', onclick: function () {
          ui.confirm('Reinstate ' + o.name + '?', 'The console opens again with the current limits.', 'Reinstate').then(function (ok) { if (ok) run('/reinstate', 'POST', {}, 'Operator reinstated.').catch(function (e) { ui.toast(e.message, true); }); });
        } }));
        buttons.appendChild(h('button.btn.btn--primary', { type: 'button', text: 'Save limits', onclick: function () {
          run('/limits', 'PUT', form.value(), 'Limits saved.').catch(function (e) { ui.toast(e.message, true); });
        } }));
      }
      act.appendChild(buttons);
      view.appendChild(act);
    }).catch(function (e) { clear(view).appendChild(ui.error(e)); });
  }

  // ==================================================================== templates
  function templatesDialog() {
    api('GET', '/admin/operators/templates').then(function (r) {
      var forms = {};
      var body = [h('p.muted', { text: 'Defaults filled in when you approve an operator of each type. Changing a template never changes operators already approved.' })];
      Object.keys(r.types).forEach(function (t) {
        var tpl = r.templates[t];
        forms[t] = limitsForm(tpl.limits, tpl.features, r.features, r.bounds, tpl.validityDays);
        body.push(h('div.card', h('div.card__head', h('h2', { text: r.types[t] })), forms[t].el));
      });
      ui.dialog({ title: 'Templates per operator type', wide: true, body: body, actions: [{ label: 'Cancel', value: null }, { label: 'Save templates', kind: 'primary', onClick: function () {
        var out = {};
        Object.keys(forms).forEach(function (t) { out[t] = forms[t].value(); });
        return api('PUT', '/admin/operators/templates', { templates: out }).then(function () { ui.toast('Templates saved.'); });
      } }] });
    }).catch(function (e) { ui.toast(e.message, true); });
  }

  CR.sections.operators = {
    title: 'Operators',
    render: function (view, arg) { if (arg) renderDetail(view, arg); else renderList(view); badge(); },
    teardown: function () { /* nothing kept running */ },
  };
})();
