/* CoRoute operator console (3.56, docs/features_355/operators.md): sign in with the CoRoute account, then Overview,
   Roster, Rides, Live map, Attendance & reports and Broadcasts for one operator (owner or co-organiser).
   The token lives in sessionStorage only; every call goes to /api/operator/:id/* which checks the role server side.
   Text from the server is always set as text, never as HTML. */
(function () {
  'use strict';

  var TOKEN_KEY = 'cr.op.token';
  var OP_KEY = 'cr.op.current';
  var ACTIVE_KEY = 'cr.op.lastActive';
  var IDLE_MS = 60 * 60 * 1000;
  var RIDE_COLORS = ['#2B7A8C', '#94600F', '#6A4FB3', '#357A50', '#B4527A', '#3D7BC8'];

  // ------------------------------------------------------------------ DOM helpers (as in the web admin)
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
      else if (k === 'value') el.value = v;
      else if (k === 'checked' || k === 'disabled' || k === 'selected' || k === 'hidden' || k === 'readOnly') el[k] = !!v;
      else if (k === 'style') Object.keys(v).forEach(function (s) { el.style.setProperty(s, v[s]); });
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

  var IST = 330 * 60000;
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function date(ms, withTime) {
    if (!ms || Number(ms) <= 0) return '-';
    var d = new Date(Number(ms) + IST);
    var s = d.getUTCDate() + ' ' + MONTHS[d.getUTCMonth()] + ' ' + d.getUTCFullYear();
    if (withTime) s += ', ' + String(d.getUTCHours()).padStart(2, '0') + ':' + String(d.getUTCMinutes()).padStart(2, '0');
    return s;
  }
  function ago(ms) {
    if (!ms) return 'no signal yet';
    var s = Math.max(0, Math.round((Date.now() - ms) / 1000));
    if (s < 60) return s + ' s ago';
    if (s < 3600) return Math.round(s / 60) + ' min ago';
    return Math.round(s / 3600) + ' h ago';
  }
  function toLocalInput(ms) { return ms ? new Date(Number(ms) + IST).toISOString().slice(0, 16) : ''; }
  function fromLocalInput(v) { var t = Date.parse(v + ':00Z'); return isFinite(t) ? t - IST : 0; }
  function monthKey(ms) { return new Date(ms + IST).toISOString().slice(0, 7); }

  // ------------------------------------------------------------------ toasts, dialogs
  function toast(msg, bad) {
    var t = h('div.toast' + (bad ? '.toast--bad' : ''), { role: bad ? 'alert' : 'status', text: msg });
    $('toasts').appendChild(t);
    setTimeout(function () { t.remove(); }, bad ? 7000 : 3500);
  }
  function dialog(opts) {
    return new Promise(function (resolve) {
      var prev = document.activeElement;
      var foot = h('div.dialog__foot');
      var box = h('div.dialog' + (opts.wide ? '.dialog--wide' : ''), { role: 'dialog', 'aria-modal': 'true', 'aria-label': opts.title },
        h('div.dialog__head', h('h2', { text: opts.title }), h('span.spacer'), h('button.btn.btn--ghost.btn--icon', { type: 'button', 'aria-label': 'Close', text: '×', onclick: function () { done(null); } })),
        h('div.dialog__body', opts.body || null), foot);
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
  function chip(text, kind) { return h('span.chip' + (kind ? '.chip--' + kind : ''), { text: text }); }
  function field(label, input, hint) { return h('label.field', h('span', label, hint ? h('small', { text: hint }) : null), input); }
  function tile(label, value, note, used, max) {
    var t = h('div.tile', h('div.tile__label', { text: label }), h('div.tile__value', { text: value }), note ? h('div.tile__note', { text: note }) : null);
    if (max) {
      var pct = Math.min(100, Math.round((used / max) * 100));
      t.appendChild(h('div.meter' + (used >= max ? '.is-full' : ''), h('i', { style: { width: pct + '%' } })));
    }
    return t;
  }
  function pageHead(title, sub, actions) { return h('div.page-head', h('div', h('h1', { text: title }), sub ? h('p', { text: sub }) : null), h('span.spacer'), actions || null); }
  function loading() { return h('div.loading', { text: 'Loading…' }); }
  function errorNode(e) { return h('div.banner.banner--bad', { text: (e && e.message) || 'Something went wrong.' }); }

  // ------------------------------------------------------------------ session & API
  function store(k, v) { try { if (v === null) sessionStorage.removeItem(k); else sessionStorage.setItem(k, v); } catch (e) { /* private mode */ } }
  function read(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  function token() { return read(TOKEN_KEY) || read('coroute_session'); }
  function ApiError(status, body) { var e = new Error((body && body.error) || ('Request failed (' + status + ')')); e.status = status; e.body = body || {}; e.code = body && body.code; return e; }
  function api(method, path, body, opts) {
    opts = opts || {};
    var headers = { Authorization: 'Bearer ' + token() };
    var init = { method: method, headers: headers, credentials: 'omit', cache: 'no-store' };
    if (body !== undefined && body !== null) { init.body = JSON.stringify(body); headers['Content-Type'] = 'application/json'; }
    touch();
    return fetch('/api' + path, init).then(function (res) {
      var fresh = res.headers.get('X-CoRoute-Token');
      if (fresh) store(TOKEN_KEY, fresh);
      if (res.status === 401) { signOut('Your session has ended. Please sign in again.'); throw new ApiError(401, { error: 'Signed out' }); }
      if (opts.raw && res.ok) return res;
      return res.json().catch(function () { return {}; }).then(function (j) {
        if (!res.ok) {
          if (j && (j.code === 'OPERATOR_SUSPENDED')) showSuspended(j);
          throw new ApiError(res.status, j);
        }
        return j;
      });
    });
  }
  function touch() { store(ACTIVE_KEY, String(Date.now())); }
  setInterval(function () {
    if (!token()) return;
    if (Date.now() - (Number(read(ACTIVE_KEY)) || 0) > IDLE_MS) signOut('You were signed out after 60 minutes without activity.');
  }, 15000);
  ['pointerdown', 'keydown'].forEach(function (ev) { document.addEventListener(ev, function () { if (token()) touch(); }, { passive: true }); });

  var S = { me: null, ops: [], opId: null, op: null };
  function base() { return '/operator/' + S.opId; }

  function signOut(message) {
    store(TOKEN_KEY, null); store(ACTIVE_KEY, null); store(OP_KEY, null);
    teardown();
    document.querySelectorAll('.scrim').forEach(function (s) { s.remove(); });
    clear($('view'));
    $('shell').hidden = true; $('noop').hidden = true;
    $('signin').hidden = false;
    var err = $('signin-error');
    err.hidden = !message; err.textContent = message || '';
    $('signin-pw').value = '';
  }
  function showSuspended(j) {
    teardown();
    var v = clear($('view'));
    v.appendChild(pageHead('Account suspended', 'The CoRoute team suspended this operator account. Live rides already under way keep their safety features.'));
    if (j.reason) v.appendChild(h('div.banner.banner--bad', { text: 'Reason: ' + j.reason }));
  }

  $('signin-form').addEventListener('submit', function (e) {
    e.preventDefault();
    var id = $('signin-id').value.trim(); var pw = $('signin-pw').value;
    var err = $('signin-error'); var btn = $('signin-btn');
    if (!id || !pw) { err.hidden = false; err.textContent = 'Enter your email or callsign and password.'; return; }
    btn.disabled = true; btn.textContent = 'Signing in…'; err.hidden = true;
    fetch('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, credentials: 'omit', body: JSON.stringify({ identifier: id, password: pw }) })
      .then(function (res) { return res.json().catch(function () { return {}; }).then(function (j) { return { res: res, j: j }; }); })
      .then(function (r) {
        if (r.res.status === 429) throw new Error('Too many attempts. Wait a few minutes and try again.');
        if (!r.res.ok || !r.j.token) throw new Error(r.j.error || 'Sign in failed.');
        store(TOKEN_KEY, r.j.token);
        $('signin-pw').value = '';
        return start();
      })
      .catch(function (e2) { err.hidden = false; err.textContent = e2.message || 'Sign in failed.'; })
      .then(function () { btn.disabled = false; btn.textContent = 'Sign in'; });
  });
  $('signout').addEventListener('click', function () { signOut(''); });
  $('noop-out').addEventListener('click', function () { signOut(''); });

  function start() {
    return api('GET', '/operator/me').then(function (r) {
      S.me = r.user; S.ops = r.operators || [];
      if (!S.ops.length) {
        $('signin').hidden = true; $('noop').hidden = false;
        if (r.application) {
          $('noop-title').textContent = 'Application ' + (r.application.status === 'PENDING' ? 'waiting for review' : 'not approved');
          $('noop-text').textContent = r.application.status === 'PENDING'
            ? 'The CoRoute team is reviewing "' + r.application.name + '". You can sign in here once it is approved.'
            : 'Your application "' + r.application.name + '" was not approved.' + (r.application.reason ? ' Reason: ' + r.application.reason : '');
          $('noop-apply').textContent = 'See your application';
        }
        return;
      }
      var saved = read(OP_KEY);
      S.opId = S.ops.some(function (o) { return o.operatorId === saved; }) ? saved : S.ops[0].operatorId;
      var sw = clear($('op-switch'));
      S.ops.forEach(function (o) { sw.appendChild(h('option', { value: o.operatorId, text: o.name + (o.role === 'CO_ORGANISER' ? ' (co-organiser)' : ''), selected: o.operatorId === S.opId })); });
      sw.hidden = S.ops.length < 2;
      $('signin').hidden = true; $('noop').hidden = true; $('shell').hidden = false;
      clear($('whoami')).appendChild(h('b', { text: S.me.name || ('@' + S.me.username) }));
      $('whoami').appendChild(document.createTextNode('@' + S.me.username));
      touch();
      return loadOp().then(route);
    }).catch(function (e) {
      if (e.code === 'FEATURE_OFF') { $('signin').hidden = false; $('signin-error').hidden = false; $('signin-error').textContent = 'The operator console is turned off for now.'; }
      else if (e.status !== 401) toast(e.message, true);
    });
  }
  $('op-switch').addEventListener('change', function () { S.opId = this.value; store(OP_KEY, S.opId); loadOp().then(route); });
  function loadOp() {
    return api('GET', base()).then(function (r) { S.op = r.operator; startSosWatch(); return S.op; });
  }
  function feat(name) { return !!(S.op && S.op.features && S.op.features[name]); }
  function writable() { return S.op && S.op.status === 'APPROVED'; }

  // ------------------------------------------------------------------ navigation
  var sections = {};
  var current = null;
  var cleanup = [];
  function teardown() { cleanup.forEach(function (f) { try { f(); } catch (e) { /* ignore */ } }); cleanup = []; }
  function route() {
    if (!token() || !S.op) return;
    var m = /^#\/([a-z]+)(?:\/(.*))?$/.exec(location.hash || '');
    var name = m && sections[m[1]] ? m[1] : 'overview';
    document.querySelectorAll('#nav a').forEach(function (a) { if (a.dataset.section === name) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current'); });
    teardown();
    current = name;
    var view = clear($('view'));
    document.title = sections[name].title + ' · ' + S.op.name + ' · CoRoute Operator';
    if (S.op.status === 'EXPIRED') view.appendChild(h('div.banner', { text: 'This operator account expired on ' + date(S.op.validUntil) + '. You can read your reports; ask CoRoute to extend it to run rides again.' }));
    try { sections[name].render(view, m && m[2] ? decodeURIComponent(m[2]) : ''); } catch (e) { view.appendChild(errorNode(e)); }
    view.focus({ preventScroll: true });
  }
  window.addEventListener('hashchange', route);

  // SOS badge in the nav (every 15 s, also when not on the map).
  var sosTimer = null;
  function startSosWatch() {
    clearInterval(sosTimer);
    function check() {
      if (!S.op || S.op.status === 'SUSPENDED') return;
      api('GET', base() + '/live').then(function (r) { $('sos-badge').hidden = !r.sos; }).catch(function () { /* ignore */ });
    }
    check();
    sosTimer = setInterval(check, 15000);
  }

  // ------------------------------------------------------------------ theme
  function applyTheme(v) {
    if (v === 'light' || v === 'dark') document.documentElement.setAttribute('data-theme', v);
    else document.documentElement.removeAttribute('data-theme');
  }
  (function initTheme() {
    var v = 'system';
    try { v = localStorage.getItem('cr.op.theme') || 'system'; } catch (e) { v = 'system'; }
    var q = /[?&]theme=(light|dark)/.exec(location.search);
    if (q) v = q[1];
    applyTheme(v);
    $('theme').value = v;
    $('theme').addEventListener('change', function () { applyTheme(this.value); try { localStorage.setItem('cr.op.theme', this.value); } catch (e) { /* ignore */ } });
  })();

  // ==================================================================== OVERVIEW
  sections.overview = {
    title: 'Overview',
    render: function (view) {
      view.appendChild(loading());
      loadOp().then(function (op) {
        clear(view);
        if (op.status === 'EXPIRED') view.appendChild(h('div.banner', { text: 'This operator account expired on ' + date(op.validUntil) + '.' }));
        view.appendChild(pageHead(op.name, op.typeLabel + ' · ' + op.city + ' · ' + (op.role === 'OWNER' ? 'You own this account' : 'You are a co-organiser'),
          h('div.actions', h('a.btn.btn--primary', { href: '#/rides', text: 'Schedule a ride' }), h('a.btn', { href: '#/live', text: 'Open live map' }))));
        var u = op.usage, l = op.limits;
        view.appendChild(h('div.tiles',
          tile('Roster', u.members + ' / ' + l.maxMembers, u.pendingInvites ? u.pendingInvites + (u.pendingInvites === 1 ? ' invite waiting' : ' invites waiting') : 'riders on the roster', u.members + u.pendingInvites, l.maxMembers),
          tile('Rides this month', u.ridesThisMonth + ' / ' + l.maxRidesPerMonth, 'scheduled, live or done', u.ridesThisMonth, l.maxRidesPerMonth),
          tile('Live now', u.liveRides + ' / ' + l.maxConcurrentRides, 'rides at the same time', u.liveRides, l.maxConcurrentRides),
          tile('Riders per ride', String(l.maxRidersPerRide), 'lead included'),
          tile('Co-organisers', u.coOrganisers + ' / ' + l.coOrganisers, 'can run rides with you', u.coOrganisers, l.coOrganisers || 1)));
        var feats = h('ul.feat');
        Object.keys(op.featureLabels).forEach(function (k) {
          var on = !!op.features[k];
          feats.appendChild(h('li' + (on ? '' : '.is-off'), h('span.' + (on ? 'yes' : 'no'), { text: on ? 'On' : 'Off' }), op.featureLabels[k]));
        });
        var plan = h('div.card', h('div.card__head', h('h2', { text: 'Your plan' }), h('p', { text: 'Set by CoRoute when your account was approved. Valid until ' + date(op.validUntil) + '.' })), feats);
        var link = h('div.card', h('div.card__head', h('h2', { text: 'Invite riders' }), h('p', { text: 'Share this link, or invite by username on the Roster page. Riders accept in the CoRoute app or on the website.' })));
        if (op.inviteLink) {
          var inp = h('input', { value: op.inviteLink, readOnly: true, 'aria-label': 'Invite link' });
          link.appendChild(h('div.linkbox', inp, h('button.btn', { type: 'button', text: 'Copy', onclick: function () { copy(op.inviteLink); } })));
        } else link.appendChild(h('p.muted', { text: 'The invite link is off. Turn it on on the Roster page.' }));
        link.appendChild(h('p.privacy-note', { style: { 'margin-top': '12px' }, text: 'Privacy: you see riders\' usernames and first names, and their live position only during your rides. Phone numbers, e-mail and medical ID stay private; a rider\'s emergency contact is shown only while that rider has an open SOS in your ride, and every view is recorded.' }));
        view.appendChild(h('div.grid2', plan, link));
      }).catch(function (e) { clear(view).appendChild(errorNode(e)); });
    }
  };
  function copy(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { toast('Copied.'); }, function () { toast('Copy failed. Select and copy the link.', true); });
    else toast('Select and copy the link.');
  }

  // ==================================================================== ROSTER
  sections.roster = {
    title: 'Roster',
    render: function (view) {
      view.appendChild(loading());
      api('GET', base() + '/roster').then(function (r) { draw(view, r); }).catch(function (e) { clear(view).appendChild(errorNode(e)); });
    }
  };
  function draw(view, r) {
    clear(view);
    var total = r.members.length + r.invites.length;
    view.appendChild(pageHead('Roster', r.members.length + ' riders · ' + r.invites.length + (r.invites.length === 1 ? ' invite' : ' invites') + ' waiting · up to ' + r.limits.maxMembers + ' (invites count)'));
    var names = h('input', { type: 'text', placeholder: 'SwiftFalcon482, RoadKite17', 'aria-label': 'Usernames', disabled: !writable() });
    var form = h('div.card', h('div.card__head', h('h2', { text: 'Invite by username' }), h('p', { text: 'Separate usernames with commas. Riders get the invite in the CoRoute app (People > Requests) and choose to join.' })),
      h('div.row', h('div', { style: { flex: '1 1 320px' } }, names), h('button.btn.btn--primary', { type: 'button', text: 'Send invites', disabled: !writable() || total >= r.limits.maxMembers, onclick: function () {
        var list = names.value.split(/[\s,]+/).filter(Boolean);
        if (!list.length) { toast('Enter at least one username.', true); return; }
        api('POST', base() + '/roster/invites', { usernames: list }).then(function (res) {
          var by = {};
          res.results.forEach(function (x) { by[x.status] = (by[x.status] || 0) + 1; });
          var words = { INVITED: 'invited', ALREADY_INVITED: 'already invited', ALREADY_MEMBER: 'already on the roster', NOT_FOUND: 'not found', ROSTER_FULL: 'not sent (roster full)' };
          toast(Object.keys(by).map(function (k) { return by[k] + ' ' + (words[k] || k); }).join(', ') + '.', !by.INVITED);
          sections.roster.render(view);
        }).catch(function (e) { toast(e.message, true); });
      } })));
    if (total >= r.limits.maxMembers) form.appendChild(h('div.banner', { style: { 'margin-top': '12px' }, text: 'Your roster is full. Cancel waiting invites or remove riders to invite more.' }));
    var linkCard = h('div.card', h('div.card__head', h('h2', { text: 'Invite link' }), h('p', { text: 'Anyone with the link can join while there is room. Rotate it to stop an old link.' })));
    if (r.inviteLink) {
      linkCard.appendChild(h('div.linkbox', h('input', { value: r.inviteLink, readOnly: true, 'aria-label': 'Invite link' }), h('button.btn', { type: 'button', text: 'Copy', onclick: function () { copy(r.inviteLink); } })));
    } else linkCard.appendChild(h('p.muted', { text: 'The link is off.' }));
    linkCard.appendChild(h('div.row', { style: { 'margin-top': '10px' } },
      h('button.btn.btn--sm', { type: 'button', text: 'New link', disabled: !writable(), onclick: function () { linkAction('rotate', view); } }),
      r.inviteLink ? h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'Turn off', disabled: !writable(), onclick: function () { linkAction('disable', view); } })
        : h('button.btn.btn--sm', { type: 'button', text: 'Turn on', disabled: !writable(), onclick: function () { linkAction('enable', view); } })));
    view.appendChild(h('div.grid2', form, linkCard));

    var owner = S.op.role === 'OWNER';
    var coCount = r.members.filter(function (m) { return m.role === 'CO_ORGANISER'; }).length;
    var tbody = h('tbody');
    r.members.forEach(function (m) {
      var acts = h('div.actions');
      if (owner && m.role === 'MEMBER' && r.limits.coOrganisers > 0) acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Make co-organiser', disabled: !writable() || coCount >= r.limits.coOrganisers, title: coCount >= r.limits.coOrganisers ? 'Co-organiser limit reached' : '', onclick: function () {
        api('POST', base() + '/co-organisers', { username: m.username }).then(function () { toast('@' + m.username + ' is now a co-organiser.'); sections.roster.render(view); }).catch(function (e) { toast(e.message, true); });
      } }));
      if (owner && m.role === 'CO_ORGANISER') acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Make member', disabled: !writable(), onclick: function () {
        api('DELETE', base() + '/co-organisers/' + encodeURIComponent(m.username)).then(function () { sections.roster.render(view); }).catch(function (e) { toast(e.message, true); });
      } }));
      if (m.role !== 'OWNER' && (owner || m.role === 'MEMBER')) acts.appendChild(h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'Remove', disabled: !writable(), onclick: function () {
        confirmDialog('Remove @' + m.username + '?', 'They leave your roster and stop getting your ride invites. They can be invited again.', 'Remove', true).then(function (ok) {
          if (!ok) return;
          api('DELETE', base() + '/roster/' + encodeURIComponent(m.username)).then(function () { toast('Removed.'); sections.roster.render(view); }).catch(function (e) { toast(e.message, true); });
        });
      } }));
      var roleChip = m.role === 'OWNER' ? chip('Owner', 'info') : m.role === 'CO_ORGANISER' ? chip('Co-organiser', 'ok') : chip('Member');
      tbody.appendChild(h('tr', h('td', h('b', { text: '@' + m.username })), h('td', { text: m.displayName || '-' }), h('td', roleChip), h('td.nowrap', { text: date(m.joinedAt) }), h('td', { text: m.via === 'link' ? 'Link' : 'Invite' }), h('td', acts)));
    });
    view.appendChild(h('div.card', h('div.card__head', h('h2', { text: 'Riders' }), h('p', { text: 'Usernames and first names only. Co-organisers: ' + coCount + ' of ' + r.limits.coOrganisers + '.' })),
      h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Username' }), h('th', { text: 'Name' }), h('th', { text: 'Role' }), h('th', { text: 'Joined' }), h('th', { text: 'Via' }), h('th', { text: '' }))), tbody))));
    if (r.invites.length) {
      var ib = h('tbody');
      r.invites.forEach(function (i) {
        ib.appendChild(h('tr', h('td', h('b', { text: '@' + i.username })), h('td.nowrap', { text: date(i.createdAt) }), h('td.nowrap', { text: date(i.expiresAt) }),
          h('td', h('button.btn.btn--sm', { type: 'button', text: 'Cancel invite', disabled: !writable(), onclick: function () {
            api('DELETE', base() + '/roster/invites/' + i.inviteId).then(function () { sections.roster.render(view); }).catch(function (e) { toast(e.message, true); });
          } }))));
      });
      view.appendChild(h('div.card', h('div.card__head', h('h2', { text: 'Waiting for an answer' })),
        h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Username' }), h('th', { text: 'Sent' }), h('th', { text: 'Expires' }), h('th', { text: '' }))), ib))));
    }
  }
  function linkAction(action, view) {
    api('POST', base() + '/roster/link', { action: action }).then(function () { toast(action === 'disable' ? 'Invite link turned off.' : 'New invite link ready.'); sections.roster.render(view); }).catch(function (e) { toast(e.message, true); });
  }

  // ==================================================================== RIDES
  var RIDE_STATUS = { SCHEDULED: ['Scheduled', 'info'], LIVE: ['Live', 'ok'], ENDED: ['Ended', ''], CANCELLED: ['Cancelled', 'warn'] };
  sections.rides = {
    title: 'Rides',
    render: function (view) {
      view.appendChild(loading());
      api('GET', base() + '/rides').then(function (r) { drawRides(view, r); }).catch(function (e) { clear(view).appendChild(errorNode(e)); });
    }
  };
  function drawRides(view, r) {
    clear(view);
    var l = r.limits, u = r.usage;
    view.appendChild(pageHead('Rides', u.ridesThisMonth + ' of ' + l.maxRidesPerMonth + ' rides this month · ' + u.liveRides + ' of ' + l.maxConcurrentRides + ' live · up to ' + l.maxRidersPerRide + ' riders per ride',
      h('button.btn.btn--primary', { type: 'button', text: 'New ride', disabled: !writable(), onclick: function () { rideForm(null, l, view); } })));
    if (!r.rides.length) { view.appendChild(h('div.card', h('p.empty', { text: 'No rides yet. Schedule your first ride, then start it on the day: it becomes a normal CoRoute group ride led by your lead rider.' }))); return; }
    var tbody = h('tbody');
    r.rides.forEach(function (x) {
      var st = RIDE_STATUS[x.status] || [x.status, ''];
      var acts = h('div.actions');
      var w = writable();
      if (x.status === 'SCHEDULED') {
        acts.appendChild(h('button.btn.btn--sm.btn--primary', { type: 'button', text: 'Start', disabled: !w, onclick: function () { startRide(x, view); } }));
        acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Announce', disabled: !w, title: 'Tell your roster about this ride (push "Community update")', onclick: function () { publish(x, view); } }));
        acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Edit', disabled: !w, onclick: function () { rideForm(x, l, view); } }));
        acts.appendChild(h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'Cancel', disabled: !w, onclick: function () {
          confirmDialog('Cancel ' + x.title + '?', 'Riders who signed up see it as cancelled. It no longer counts against your monthly rides.', 'Cancel ride', true).then(function (ok) {
            if (ok) api('POST', base() + '/rides/' + x.rideId + '/cancel').then(function () { sections.rides.render(view); }).catch(function (e) { toast(e.message, true); });
          });
        } }));
      }
      if (x.status === 'LIVE') {
        acts.appendChild(h('button.btn.btn--sm.btn--primary', { type: 'button', text: 'Invite roster', disabled: !w, onclick: function () { publish(x, view); } }));
        acts.appendChild(h('a.btn.btn--sm', { href: '#/live/' + x.rideId, text: 'Live map' }));
        acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Roles', disabled: !w, onclick: function () { roleDialog(x, view); } }));
        acts.appendChild(h('button.btn.btn--sm.btn--danger', { type: 'button', text: 'End', disabled: !w, onclick: function () {
          confirmDialog('End ' + x.title + '?', 'The ride ends for every rider in it, as when the trip owner ends it in the app.', 'End ride', true).then(function (ok) {
            if (ok) api('POST', base() + '/rides/' + x.rideId + '/end').then(function () { toast('Ride ended.'); sections.rides.render(view); }).catch(function (e) { toast(e.message, true); });
          });
        } }));
      }
      if ((x.status === 'LIVE' || x.status === 'ENDED') && feat('attendance')) acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Attendance', onclick: function () { attendanceDialog(x); } }));
      if (x.publicSignup) acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Sign-ups' + (x.signups.pending ? ' (' + x.signups.pending + ')' : ''), onclick: function () { signupsDialog(x, view); } }));
      var seats = x.status === 'LIVE' ? x.ridersNow + ' / ' + x.maxRiders + ' riding' : (x.publicSignup ? (x.signups.approved + 1) + ' / ' + x.maxRiders + ' booked' : x.maxRiders + ' seats');
      tbody.appendChild(h('tr',
        h('td', h('b', { text: x.title }), h('div.small.muted', { text: [x.meetName, x.destinationName].filter(Boolean).join(' → ') || '-' }),
          x.publicUrl ? h('div.small', h('a', { href: x.publicUrl, target: '_blank', rel: 'noopener noreferrer', text: 'Public page' })) : null),
        h('td.nowrap', { text: date(x.startsAt, true) }),
        h('td', chip(st[0], st[1])),
        h('td', h('div.small', { text: 'Lead @' + (x.lead.username || '-') }), h('div.small.muted', { text: x.sweeper ? 'Sweeper @' + x.sweeper.username : 'No sweeper' })),
        h('td.nowrap', { text: seats }),
        h('td', acts)));
    });
    view.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Ride' }), h('th', { text: 'Starts (IST)' }), h('th', { text: 'Status' }), h('th', { text: 'Roles' }), h('th', { text: 'Seats' }), h('th', { text: '' }))), tbody)));
    view.appendChild(h('p.privacy-note', { style: { 'margin-top': '12px' }, text: 'Starting a ride creates a CoRoute group ride with your lead rider as trip owner; its seats come from your operator limits, not anyone\'s personal plan. "Invite roster" sends ride invites that riders accept in the app.' }));
  }
  function rideForm(x, l, view) {
    var f = {
      title: h('input', { value: x ? x.title : '', maxlength: '80' }),
      startsAt: h('input', { type: 'datetime-local', value: toLocalInput(x ? x.startsAt : Date.now() + 86400000) }),
      meetName: h('input', { value: x ? x.meetName : '', maxlength: '120', placeholder: 'e.g. Cubbon Park gate' }),
      destinationName: h('input', { value: x ? x.destinationName : '', maxlength: '120', placeholder: 'e.g. Nandi Hills' }),
      maxRiders: h('input', { type: 'number', min: '2', max: String(l.maxRidersPerRide), value: String(x ? x.maxRiders : Math.min(12, l.maxRidersPerRide)) }),
      lead: h('input', { value: x ? x.lead.username : (S.me.username || ''), placeholder: 'username' }),
      sweeper: h('input', { value: x && x.sweeper ? x.sweeper.username : '', placeholder: 'username (optional)' }),
      notes: h('textarea', { maxlength: '500', rows: '3', placeholder: 'What riders should know (shown on the public page)' }),
      pub: h('input', { type: 'checkbox', checked: x ? x.publicSignup : false, disabled: !feat('rideCalendar') }),
      appr: h('input', { type: 'checkbox', checked: x ? x.requireApproval : true })
    };
    f.notes.value = x ? x.notes : '';
    var err = h('div.banner.banner--bad', { hidden: true });
    var body = [err, field('Ride name', f.title), h('div.grid2', field('Starts (India time)', f.startsAt), field('Riders', f.maxRiders, 'up to ' + l.maxRidersPerRide + ', lead included')),
      h('div.grid2', field('Meeting point', f.meetName), field('Destination', f.destinationName)),
      h('div.grid2', field('Lead rider', f.lead, 'on your roster'), field('Sweeper', f.sweeper, 'joins as sweeper')), field('Notes', f.notes),
      h('label.check', f.pub, feat('rideCalendar') ? 'Public sign-up page on the CoRoute website' : 'Public sign-up page (not in your plan)'), h('label.check', f.appr, 'I approve each sign-up')];
    return dialog({ title: x ? 'Edit ride' : 'New ride', wide: true, body: body, actions: [{ label: 'Cancel', value: null }, { label: x ? 'Save' : 'Schedule ride', kind: 'primary', onClick: function () {
      var payload = { title: f.title.value, startsAt: fromLocalInput(f.startsAt.value), meetName: f.meetName.value, destinationName: f.destinationName.value, notes: f.notes.value,
        maxRiders: Number(f.maxRiders.value), leadUsername: f.lead.value.replace(/^@/, ''), sweeperUsername: f.sweeper.value.replace(/^@/, ''), publicSignup: f.pub.checked, requireApproval: f.appr.checked };
      return api(x ? 'PATCH' : 'POST', base() + '/rides' + (x ? '/' + x.rideId : ''), payload).then(function () {
        toast(x ? 'Ride saved.' : 'Ride scheduled.'); sections.rides.render(view);
      }).catch(function (e) {
        err.hidden = false;
        err.textContent = e.body && e.body.fields ? Object.keys(e.body.fields).map(function (k) { return e.body.fields[k]; }).join(' ') : e.message;
        return false;
      });
    } }] });
  }
  function startRide(x, view) {
    confirmDialog('Start ' + x.title + ' now?', 'A CoRoute group ride starts with @' + x.lead.username + ' as lead and trip owner (it shows on their phone). Up to ' + x.maxRiders + ' riders. Then use "Invite roster".', 'Start ride').then(function (ok) {
      if (!ok) return;
      api('POST', base() + '/rides/' + x.rideId + '/start').then(function (r) { toast('Ride started with ' + r.capacity + ' seats.'); sections.rides.render(view); }).catch(function (e) { toast(e.message, true); });
    });
  }
  function publish(x, view) {
    var live = x.status === 'LIVE';
    confirmDialog(live ? 'Invite your roster?' : 'Announce this ride?', live ? 'Every roster rider not yet in the ride gets a ride invite in the app, while seats last.' : 'Your roster gets a notice with the ride name, date and meeting point.', live ? 'Send invites' : 'Announce').then(function (ok) {
      if (!ok) return;
      api('POST', base() + '/rides/' + x.rideId + '/publish', {}).then(function (r) {
        toast(live ? r.invited + ' invites sent.' : 'Announced to ' + r.announced + ' riders.'); sections.rides.render(view);
      }).catch(function (e) { toast(e.message, true); });
    });
  }
  function roleDialog(x, view) {
    var name = h('input', { placeholder: 'username' });
    var role = h('select', h('option', { value: 'SWEEPER', text: 'Sweeper' }), h('option', { value: 'LEAD', text: 'Lead' }), h('option', { value: 'PACK', text: 'Middle (pack)' }));
    return dialog({ title: 'Riding role', body: [h('p.muted', { text: 'The rider must be in the ride. The group sees the change at once.' }), h('div.grid2', field('Rider', name), field('Role', role))],
      actions: [{ label: 'Cancel', value: null }, { label: 'Set role', kind: 'primary', onClick: function () {
        return api('POST', base() + '/rides/' + x.rideId + '/roles', { username: name.value.replace(/^@/, ''), role: role.value }).then(function () { toast('Role set.'); });
      } }] });
  }
  function signupsDialog(x, view) {
    var box = h('div', loading());
    function load() {
      api('GET', base() + '/rides/' + x.rideId + '/signups').then(function (r) {
        clear(box);
        box.appendChild(h('p.muted', { text: (r.counts.approved + 1) + ' of ' + r.maxRiders + ' seats taken (lead included) · ' + r.counts.pending + ' waiting' }));
        if (!r.signups.length) { box.appendChild(h('p.empty', { text: 'No sign-ups yet.' })); return; }
        var tb = h('tbody');
        r.signups.forEach(function (s) {
          var acts = h('div.actions');
          if (s.status === 'PENDING' || s.status === 'APPROVED') {
            if (s.status === 'PENDING') acts.appendChild(h('button.btn.btn--sm.btn--primary', { type: 'button', text: 'Approve', disabled: !writable(), onclick: function () { decide(s, true); } }));
            acts.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Decline', disabled: !writable(), onclick: function () { decide(s, false); } }));
          }
          tb.appendChild(h('tr', h('td', h('b', { text: '@' + s.username })), h('td', { text: s.displayName }), h('td', chip(s.status === 'APPROVED' ? 'Approved' : s.status === 'PENDING' ? 'Waiting' : 'Declined', s.status === 'APPROVED' ? 'ok' : s.status === 'PENDING' ? 'warn' : '')), h('td.nowrap', { text: date(s.at, true) }), h('td', acts)));
        });
        box.appendChild(h('div.table-wrap', h('table.table', h('tbody', tb))));
      }).catch(function (e) { clear(box).appendChild(errorNode(e)); });
    }
    function decide(s, yes) {
      api('POST', base() + '/rides/' + x.rideId + '/signups/' + encodeURIComponent(s.username), { approve: yes }).then(load).catch(function (e) { toast(e.message, true); });
    }
    load();
    return dialog({ title: 'Sign-ups · ' + x.title, wide: true, body: [box] }).then(function () { sections.rides.render(view); });
  }
  function attendanceDialog(x) {
    var box = h('div', loading());
    api('GET', base() + '/rides/' + x.rideId + '/attendance').then(function (r) { clear(box).appendChild(attendanceTable(r.attendance)); }).catch(function (e) { clear(box).appendChild(errorNode(e)); });
    return dialog({ title: 'Attendance · ' + x.title, wide: true, body: [box] });
  }
  function attendanceTable(a) {
    var wrap = h('div.stack');
    wrap.appendChild(h('div.tiles', tile('Joined', String(a.joined)), tile('Finished', String(a.finished)), tile('Distance', a.distanceKm + ' km', 'all riders'), tile('Incidents', String(a.incidents.length))));
    var tb = h('tbody');
    a.riders.forEach(function (x) {
      tb.appendChild(h('tr', h('td', h('b', { text: '@' + x.username })), h('td', { text: x.role }), h('td.nowrap', { text: date(x.joinedAt, true) }), h('td.nowrap', { text: x.leftAt ? date(x.leftAt, true) : '-' }),
        h('td', x.finished ? chip('Finished', 'ok') : chip('Left early', 'warn')), h('td.num', { text: x.distanceKm + ' km' }), h('td.num', { text: String(x.incidents) })));
    });
    wrap.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Rider' }), h('th', { text: 'Role' }), h('th', { text: 'Joined' }), h('th', { text: 'Left' }), h('th', { text: 'Result' }), h('th.num', { text: 'Distance' }), h('th.num', { text: 'Incidents' }))), tb)));
    if (a.incidents.length) {
      var ul = h('ul');
      a.incidents.forEach(function (i) { ul.appendChild(h('li', { text: date(i.at, true) + ' · ' + i.type + ' · @' + (i.rider || '-') + ' · ' + i.outcome })); });
      wrap.appendChild(h('div', h('h3', { text: 'Incidents' }), ul));
    }
    wrap.appendChild(h('p.privacy-note', { text: 'No home locations or tracks are shown here or in the export: names, times, distance and outcomes only.' }));
    return wrap;
  }

  // ==================================================================== LIVE MAP
  sections.live = {
    title: 'Live map',
    render: function (view, arg) {
      var sel = arg || null;
      var banner = h('div');
      var list = h('div.live__list', loading());
      var mapEl = h('div');
      var multi = feat('multiGroupDashboard');
      view.appendChild(pageHead('Live map', multi ? 'Every live ride of ' + S.op.name + ' on one map. Updates every 5 seconds.' : 'One live ride at a time (the multi-group dashboard is not in your plan). Updates every 5 seconds.',
        h('button.btn', { type: 'button', text: 'Fit all', onclick: function () { if (map) map.fit(); } })));
      view.appendChild(banner);
      view.appendChild(h('div.live', list, h('div', mapEl, h('div.legend', h('span', h('i', { style: { background: 'var(--c-sos)' } }), 'SOS'), h('span', { text: 'L = lead · S = sweeper · faded = no signal for 5 min' })))));
      var map = window.CoMap ? window.CoMap.create(mapEl) : null;
      var first = true;
      function tick() {
        api('GET', base() + '/live' + (!multi && sel ? '?rideId=' + encodeURIComponent(sel) : '')).then(function (r) {
          $('sos-badge').hidden = !r.sos;
          drawBanner(banner, r.rides);
          clear(list);
          if (!r.rides.length) list.appendChild(h('div.card', h('p.muted', { text: 'No live rides right now. Start a scheduled ride on the Rides page.' })));
          var marks = [];
          r.rides.forEach(function (ride, i) {
            var color = RIDE_COLORS[i % RIDE_COLORS.length];
            var riders = h('ul.ridecard__riders');
            ride.riders.forEach(function (x) {
              var sos = ride.alerts.some(function (a) { return a.rider.username === x.username; });
              riders.appendChild(h('li', h('span.r-role', { text: x.role === 'LEAD' ? 'L' : x.role === 'SWEEPER' ? 'S' : '·' }), h('b' + (x.stale ? '.r-stale' : ''), { text: '@' + x.username }),
                sos ? chip('SOS', 'bad') : null, h('span.spacer'), h('span.small.muted', { text: (x.speedKmh ? x.speedKmh + ' km/h · ' : '') + ago(x.lastSeenAt) })));
              marks.push({ lat: x.lat, lng: x.lng, color: color, sos: sos, stale: x.stale, short: x.role === 'LEAD' ? 'L' : x.role === 'SWEEPER' ? 'S' : (x.displayName || x.username || '?').slice(0, 1).toUpperCase(), label: x.displayName || x.username, title: ride.title + ' · @' + x.username });
            });
            var card = h('div.ridecard' + (sel === ride.rideId ? '.is-sel' : ''), { style: { '--rc': color }, onclick: function () { sel = sel === ride.rideId ? null : ride.rideId; tick(); } },
              h('div.ridecard__title', ride.title, ride.alerts.length ? chip('SOS', 'bad') : chip(ride.tripStatus === 'PAUSED' ? 'Paused' : 'Live', ride.tripStatus === 'PAUSED' ? 'warn' : 'ok')),
              h('div.ridecard__meta', { text: ride.riders.length + ' / ' + ride.capacity + ' riders · started ' + date(ride.startedAt, true) + (ride.destinationName ? ' · to ' + ride.destinationName : '') }), riders);
            list.appendChild(card);
          });
          if (map) {
            var shown = sel ? marks.filter(function (m) { return m.title.indexOf((r.rides.find(function (x) { return x.rideId === sel; }) || {}).title + ' ·') === 0; }) : marks;
            map.setMarkers(shown.length ? shown : marks, { fit: first });
            first = false;
          }
        }).catch(function (e) { if (e.status !== 401) clear(banner).appendChild(errorNode(e)); });
      }
      tick();
      var timer = setInterval(tick, 5000);
      cleanup.push(function () { clearInterval(timer); if (map) map.destroy(); });
    }
  };
  function drawBanner(banner, rides) {
    clear(banner);
    rides.forEach(function (ride) {
      ride.alerts.forEach(function (a) {
        var b = h('div.sos-banner', { role: 'alert' }, h('span.sos-banner__dot'), h('span', { text: (a.alertType === 'CRASH' ? 'Crash alert' : 'SOS') + ': @' + a.rider.username + ' in ' + ride.title + ' · ' + ago(a.startedAt) }), h('span.spacer'));
        if (a.contactsAvailable) b.appendChild(h('button.btn.btn--sm', { type: 'button', text: 'Emergency contact', onclick: function () { sosDialog(ride, a); } }));
        banner.appendChild(b);
      });
    });
  }
  function sosDialog(ride, a) {
    var box = h('div', loading());
    api('GET', base() + '/rides/' + ride.rideId + '/sos/' + encodeURIComponent(a.alertId)).then(function (r) {
      clear(box);
      var c = h('div.contact.stack');
      c.appendChild(h('div', h('div.small.muted', { text: 'Emergency contact of @' + r.rider.username }),
        r.emergencyContact ? h('div', h('b', { text: r.emergencyContact.name || 'Contact' }), ' ', h('a', { href: 'tel:' + r.emergencyContact.phone.replace(/[^0-9+]/g, ''), text: r.emergencyContact.phone })) : h('p', { text: 'No emergency contact saved.' })));
      if (r.riderPhone) c.appendChild(h('div', h('div.small.muted', { text: 'Rider\'s phone' }), h('a', { href: 'tel:' + r.riderPhone.replace(/[^0-9+]/g, ''), text: r.riderPhone })));
      if (r.medical) c.appendChild(h('dl.kv', Object.keys(r.medical).map(function (k) { return [h('dt', { text: k === 'bloodGroup' ? 'Blood group' : k === 'allergies' ? 'Allergies' : 'Notes' }), h('dd', { text: r.medical[k] })]; })));
      c.appendChild(h('div.small', { text: 'Last position: ' + r.lastPosition.lat.toFixed(5) + ', ' + r.lastPosition.lng.toFixed(5) }));
      box.appendChild(c);
      box.appendChild(h('p.privacy-note', { text: r.notice + ' Call 112 first in a life-threatening emergency.' }));
    }).catch(function (e) { clear(box).appendChild(errorNode(e)); });
    return dialog({ title: 'SOS · ' + ride.title, body: [box] });
  }

  // ==================================================================== REPORTS
  sections.reports = {
    title: 'Attendance & reports',
    render: function (view) {
      if (!feat('attendance')) { view.appendChild(pageHead('Attendance & reports')); view.appendChild(h('div.banner.banner--info', { text: 'Attendance is not part of your plan. Ask CoRoute to add it.' })); return; }
      var month = h('input', { type: 'month', value: monthKey(Date.now()), style: { width: 'auto' } });
      var out = h('div', loading());
      var exp = h('button.btn', { type: 'button', text: 'Export CSV', disabled: !feat('exportReports'), title: feat('exportReports') ? '' : 'Export is not in your plan', onclick: function () {
        api('GET', base() + '/reports.csv?month=' + month.value, null, { raw: true }).then(function (res) { return res.blob(); }).then(function (blob) {
          var url = URL.createObjectURL(blob);
          var a = h('a', { href: url, download: 'coroute-' + month.value + '-attendance.csv' });
          document.body.appendChild(a); a.click(); a.remove();
          setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
        }).catch(function (e) { toast(e.message, true); });
      } });
      view.appendChild(pageHead('Attendance & reports', 'Who joined and finished, distance and incidents, per month (India time). No home locations, no tracks.', h('div.row', month, exp)));
      view.appendChild(out);
      function load() {
        clear(out).appendChild(loading());
        api('GET', base() + '/reports?month=' + month.value).then(function (r) {
          clear(out);
          var t = r.totals;
          out.appendChild(h('div.tiles', tile('Rides run', String(t.rides), t.scheduled + ' still scheduled · ' + t.cancelled + ' cancelled'), tile('Riders joined', String(t.riders)), tile('Finished', String(t.finished), t.riders ? Math.round(t.finished / t.riders * 100) + '% of riders' : ''), tile('Distance', t.distanceKm + ' km'), tile('Incidents', String(t.incidents))));
          if (!r.rides.length) { out.appendChild(h('div.card', h('p.empty', { text: 'No rides ran in this month.' }))); return; }
          var tb = h('tbody');
          r.rides.forEach(function (a) {
            var tr = h('tr.is-link', { onclick: function () { attendanceDialog({ rideId: a.rideId, title: a.title }); } },
              h('td', h('b', { text: a.title })), h('td.nowrap', { text: date(a.startedAt || a.startsAt, true) }), h('td', chip(a.status === 'LIVE' ? 'Live' : 'Ended', a.status === 'LIVE' ? 'ok' : '')),
              h('td.num', { text: String(a.joined) }), h('td.num', { text: String(a.finished) }), h('td.num', { text: a.distanceKm + ' km' }), h('td.num', { text: String(a.incidents.length) }));
            tb.appendChild(tr);
          });
          out.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Ride' }), h('th', { text: 'Date' }), h('th', { text: 'Status' }), h('th.num', { text: 'Joined' }), h('th.num', { text: 'Finished' }), h('th.num', { text: 'Distance' }), h('th.num', { text: 'Incidents' }))), tb)));
        }).catch(function (e) { clear(out).appendChild(errorNode(e)); });
      }
      month.addEventListener('change', load);
      load();
    }
  };

  // ==================================================================== BROADCASTS
  sections.broadcasts = {
    title: 'Broadcasts',
    render: function (view) {
      view.appendChild(pageHead('Broadcasts', 'A short message to everyone on your roster: a notice in the CoRoute app ("Community update").'));
      if (!feat('broadcast')) view.appendChild(h('div.banner.banner--info', { text: 'Broadcasts are not part of your plan. Ask CoRoute to add them.' }));
      var title = h('input', { maxlength: '60', placeholder: 'e.g. Sunday ride moved to 6 am', disabled: !feat('broadcast') || !writable() });
      var body = h('textarea', { maxlength: '300', rows: '4', placeholder: 'Meet at the usual fuel stop. Rain gear recommended.', disabled: !feat('broadcast') || !writable() });
      var err = h('div.banner.banner--bad', { hidden: true });
      var list = h('div', loading());
      view.appendChild(h('div.grid2',
        h('div.card', h('div.card__head', h('h2', { text: 'New message' }), h('p', { text: 'Up to 5 a day. No prices, offers or links to pay (Google Play rules), and no phone numbers or e-mail.' })), err,
          h('div.stack', field('Title', title), field('Message', body), h('div.row.row--end', h('button.btn.btn--primary', { type: 'button', text: 'Send to roster', disabled: !feat('broadcast') || !writable(), onclick: function () {
            err.hidden = true;
            api('POST', base() + '/broadcasts', { title: title.value, body: body.value }).then(function (r) {
              toast('Sent to ' + r.broadcast.recipients + ' riders.'); title.value = ''; body.value = ''; load();
            }).catch(function (e) { err.hidden = false; err.textContent = e.message; });
          } })))),
        h('div.card', h('div.card__head', h('h2', { text: 'Sent' })), list)));
      function load() {
        api('GET', base() + '/broadcasts').then(function (r) {
          clear(list);
          if (!r.broadcasts.length) { list.appendChild(h('p.muted', { text: 'Nothing sent yet.' })); return; }
          r.broadcasts.forEach(function (b) {
            list.appendChild(h('div', { style: { padding: '10px 0', 'border-bottom': '1px solid var(--c-border)' } }, h('b', { text: b.title }), h('p', { text: b.body }), h('div.small.muted', { text: date(b.at, true) + ' · ' + b.recipients + ' riders · by @' + b.by })));
          });
        }).catch(function (e) { clear(list).appendChild(errorNode(e)); });
      }
      load();
    }
  };

  // ------------------------------------------------------------------ boot
  if (token()) start(); else $('signin').hidden = false;
})();
