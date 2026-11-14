/* 3.56 /account: the rider's console on the website (3.57 round 3: profile header, plan, personal coupons,
 * payments, recent rides, clubs, e-mail choices, security). No tracking.
 *   GET /api/me                  username, name, e-mail, picture (nothing medical is shown)
 *   GET /api/me/coupons          personal codes given to me (copy, "Use on plans")
 *   GET /api/trips?summary=1     my recent rides -> /trip/<id>
 *   GET /api/clubs               clubs I am in (-> /clubs)
 *   GET /api/membership/my       plan, end date, a plan change waiting to start
 *   GET /api/membership/payments every order, newest first -> receipts (/receipt?order=<id>, paid orders)
 *   GET /api/membership/catalog  plan names for the payment list
 *   GET / PUT /api/web/email-preferences  e-mail categories (3.57; #emails is the e-mails' "Manage e-mails" link)
 * Plans never renew on their own, so there is nothing to cancel. Text is written with textContent only. */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S || !S.$('ac-plan')) return;
  var el = S.el;
  // 3.57: the confirmation link of a change of e-mail (#confirm-email=<token>; read and removed from the address
  // bar at once). Every session ends with the change, so the rider signs in again with the new address.
  var cm = /^#confirm-email=([A-Za-z0-9_-]{40,60})$/.exec(window.location.hash || '');
  if (cm) {
    try { window.history.replaceState(null, '', '/account'); } catch (e) { /* ignore */ }
    S.api('POST', '/auth/email/confirm', { token: cm[1] }, { auth: false }).then(function (r) {
      S.signOut({ stay: true }).then(function () {
        window.location.replace(r.ok ? '/signin?out=1&emailChanged=1' : '/signin?expired=1');
      });
    });
    return;
  }
  // Round 4: the account deletion link e-mailed to app builds before 10025 (#confirm-delete=<token>, single use,
  // 30 minutes). Nothing is deleted until the rider confirms here once more.
  var dm = /^#confirm-delete=([A-Za-z0-9_-]{40,60})$/.exec(window.location.hash || '');
  if (dm) {
    try { window.history.replaceState(null, '', '/account'); } catch (e) { /* ignore */ }
    confirmDelete(dm[1]);
    return;
  }
  if (!S.token()) { S.toSignIn('/account'); return; }
  loadSessions();
  initEmailChange();
  initRoads();

  var STATUS = {
    PAID: ['Paid', 'ok'], CREATED: ['Not completed', 'muted'], FAILED: ['Failed', 'bad'], SIGNATURE_MISMATCH: ['Failed', 'bad'],
    EXPIRED: ['Expired', 'muted'], REFUNDED: ['Refunded', 'muted']
  };
  var DAY = 86400000;

  function fact(dl, k, v) {
    if (!v) return;
    var d = el('div');
    d.appendChild(el('dt', null, k));
    d.appendChild(el('dd', null, v));
    dl.appendChild(d);
  }
  function badge(text, kind) {
    var b = S.$('ac-plan-status');
    b.textContent = text;
    b.className = 'sh-badge sh-badge--' + kind;
    b.hidden = false;
  }

  function renderPlan(me, my) {
    var box = S.$('ac-plan');
    box.removeAttribute('aria-busy');
    var p = (my && my.plan) || { isFree: true, name: 'Community', source: 'community' };
    var o = my && my.owned;
    var free = p.isFree || p.source === 'community';
    S.$('ac-plan-name').textContent = free ? 'Community' : S.planName(p);
    var dl = S.clear(S.$('ac-facts'));
    var note = S.$('ac-plan-note');
    var actions = S.clear(S.$('ac-plan-actions'));
    var now = Date.now();
    if (free) {
      badge('Free', 'muted');
      fact(dl, 'Price', 'Free, forever');
      fact(dl, 'Rides', 'Solo rides with every safety feature, and joining any group ride');
      var part = (my && my.participating || []).filter(function (m) { return m.status === 'ACTIVE' && Number(m.validUntil) > now; })[0];
      note.textContent = part ? 'You also ride in a group plan shared with you' + (part.ownerName ? ' by ' + part.ownerName : '') + '.' :
        'To host a group ride, choose a group plan.';
      var a = el('a', 'btn btn--primary', 'See group plans');
      a.setAttribute('href', '/plans');
      actions.appendChild(a);
      return;
    }
    var until = Number(p.validUntil) || (o && Number(o.validUntil)) || 0;
    var left = until ? Math.ceil((until - now) / DAY) : 0;
    if (until && until <= now) badge('Ended', 'muted');
    else if (left <= 7) badge(left <= 1 ? 'Ends today or tomorrow' : 'Ends in ' + left + ' days', 'warn');
    else badge('Active', 'ok');
    fact(dl, 'Riders', p.seats ? 'Up to ' + p.seats + ', host included' : '');
    if (o && o.validFrom) fact(dl, 'Started', S.date(o.validFrom));
    fact(dl, 'Ends', until ? S.date(until) + ' (does not renew on its own)' : '');
    if (p.source === 'legacy' || p.legacyTier) fact(dl, 'Bought as', String(p.legacyTier || 'an earlier plan'));
    if (p.nextPlan && typeof p.nextPlan === 'object') {
      fact(dl, 'Then', S.planName(p.nextPlan) + (p.nextPlan.startsAt ? ' from ' + S.date(p.nextPlan.startsAt) : ''));
    }
    note.textContent = 'You can move to a bigger plan anytime. Smaller plans can be chosen when this one ends.';
    var b = el('a', 'btn btn--primary', 'Change plan');
    b.setAttribute('href', '/plans');
    actions.appendChild(b);
  }

  function renderPayments(list, names) {
    var wrap = S.clear(S.$('ac-payments'));
    wrap.removeAttribute('aria-busy');
    // Orders that never reached Razorpay's page are noise once they are old.
    var rows = (list || []).filter(function (x) { return x && (x.status !== 'CREATED' || Date.now() - (Number(x.createdAt) || 0) < 7 * DAY); });
    if (!rows.length) {
      var empty = el('div', 'sh-empty');
      empty.appendChild(el('p', null, 'No payments yet.'));
      var a = el('a', 'link', 'See plans');
      a.setAttribute('href', '/plans');
      empty.appendChild(a);
      wrap.appendChild(empty);
      return;
    }
    var table = el('table', 'sh-table');
    var thead = el('thead');
    var hr = el('tr');
    ['Date', 'Plan', 'Amount', 'Status', 'Receipt'].forEach(function (h) { var th = el('th', null, h); th.setAttribute('scope', 'col'); hr.appendChild(th); });
    thead.appendChild(hr);
    table.appendChild(thead);
    var tb = el('tbody');
    rows.forEach(function (x) {
      var tr = el('tr');
      var td = function (label, text, cls) { var c = el('td', cls || null, text); c.setAttribute('data-label', label); tr.appendChild(c); return c; };
      td('Date', S.date(x.paidAt || x.createdAt));
      td('Plan', names[x.category] || x.category || 'Plan');
      td('Amount', x.isFree ? (x.offerCode ? 'Free with ' + x.offerCode : 'Free') : S.inr(x.amountInr) + (typeof x.offerLabel === 'string' && x.offerLabel ? ' (' + x.offerLabel.slice(0, 40) + ')' : ''), 'sh-num');
      var stv = x.refundStatus === 'PROCESSED' || (x.refundedAmount > 0) ? STATUS.REFUNDED : (STATUS[x.status] || [String(x.status || ''), 'muted']);
      var sc = td('Status', '');
      sc.appendChild(el('span', 'sh-pill sh-pill--' + stv[1], stv[0]));
      var rc = td('Receipt', '');
      if (x.status === 'PAID') {
        var a = el('a', 'link', 'View receipt');
        a.setAttribute('href', '/receipt?order=' + encodeURIComponent(x.orderId));
        rc.appendChild(a);
      } else {
        rc.appendChild(el('span', 't-faint', '\u2013'));
      }
      tb.appendChild(tr);
    });
    table.appendChild(tb);
    wrap.appendChild(table);
  }

  Promise.all([
    S.api('GET', '/me'), S.api('GET', '/membership/my'), S.api('GET', '/membership/payments'),
    S.api('GET', '/membership/catalog', undefined, { auth: false })
  ]).then(function (rs) {
    if (rs[0].status === 401) { window.location.replace('/signin?expired=1&next=%2Faccount'); return; }
    if (!rs[0].ok) { S.$('ac-who').textContent = 'Could not load your account. Refresh the page to try again.'; return; }
    var me = rs[0].json;
    if (me.role === 'MASTER_ADMIN') {
      var ab = S.$('ac-admin-banner');
      if (ab) {
        S.clear(ab);
        var txt = el('p');
        txt.appendChild(el('strong', null, 'Administrator: '));
        txt.appendChild(document.createTextNode('you are signed in as a CoRoute admin.'));
        var btn = el('a', 'btn btn--primary', 'Open the admin console');
        btn.setAttribute('href', '/admin');
        ab.appendChild(txt);
        ab.appendChild(btn);
        ab.hidden = false;
      }
    }
    var av = S.$('ac-avatar');
    if (av) {
      S.clear(av);
      // 3.56: the picture needs the Bearer header, so it is fetched and drawn by the picture section below
      // (window.CoAvatar); until then, and when there is none, the initials.
      av.textContent = String(me.username || me.name || '?').slice(0, 2).toUpperCase();
      av.setAttribute('data-initials', av.textContent);
      if (window.CoAvatar) window.CoAvatar.show(me.avatarUrl || null);
    }
    var who = me.username ? '@' + me.username : (me.name || 'Rider');
    S.$('ac-title').textContent = who;
    S.$('ac-who').textContent = [me.name && me.username ? me.name : '', me.email || ''].filter(Boolean).join(' · ') || 'Your plan and payments.';
    renderPlan(me, rs[1].ok ? rs[1].json : null);
    var names = {};
    var cats = rs[3].ok && rs[3].json.categories ? rs[3].json.categories : {};
    Object.keys(cats).forEach(function (id) { names[id] = S.planName(cats[id]); });
    if (!names.individual) names.individual = 'Individual';
    if (rs[2].ok) renderPayments(rs[2].json.payments, names);
    else S.clear(S.$('ac-payments')).appendChild(el('p', 't-small t-muted', 'Payments could not load. Refresh to try again.'));
    loadConsent();
    loadCoupons();
    loadRides();
    loadClubs();
  });

  /* 3.57 round 3: personal coupons (GET /api/me/coupons): copy the code, or open /plans with it filled in. */
  var STATE = { ACTIVE: ['Ready to use', 'ok'], SCHEDULED: ['Starts soon', 'muted'], USED: ['Used', 'muted'], EXPIRED: ['Expired', 'muted'], NOT_ACTIVE: ['Paused', 'muted'] };
  function loadCoupons() {
    var box = S.$('ac-coupons');
    if (!box) return;
    S.api('GET', '/me/coupons').then(function (r) {
      S.clear(box); box.removeAttribute('aria-busy');
      var list = r.ok && r.json && r.json.coupons ? r.json.coupons : null;
      if (!list) { box.appendChild(el('p', 't-small t-muted', 'Your coupons could not load. Refresh to try again.')); return; }
      if (!list.length) {
        var e = el('div', 'sh-empty');
        e.appendChild(el('p', null, 'No personal coupons right now.'));
        e.appendChild(el('p', 't-small t-muted', 'When CoRoute gives you a code, it shows up here.'));
        box.appendChild(e);
        return;
      }
      list.forEach(function (c) {
        var card = el('div', 'sh-card ac-coupon' + (c.state === 'ACTIVE' ? '' : ' is-off'));
        var top = el('div', 'ac-coupon__top');
        top.appendChild(el('span', 'ac-coupon__code', c.code));
        var st = STATE[c.state] || [c.state, 'muted'];
        top.appendChild(el('span', 'sh-pill sh-pill--' + st[1], st[0]));
        card.appendChild(top);
        card.appendChild(el('p', 'ac-coupon__what', c.discount + (c.plans && c.plans.length ? ' on ' + c.plans.map(function (p) { return p === 'group_large' ? 'Large Group' : p === 'group_small' ? 'Small Group' : p; }).join(', ') : ' on a group plan')));
        if (c.validUntil) card.appendChild(el('p', 't-small t-muted', (c.state === 'EXPIRED' ? 'Ended ' : 'Valid until ') + c.validUntil));
        if (c.state === 'ACTIVE') {
          var row = el('div', 'sh-actions');
          var copy = el('button', 'btn btn--secondary btn--sm', 'Copy code');
          copy.setAttribute('type', 'button');
          copy.addEventListener('click', function () {
            var ok = function () { copy.textContent = 'Copied'; setTimeout(function () { copy.textContent = 'Copy code'; }, 1800); };
            if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(c.code).then(ok, function () { copy.textContent = c.code; });
            else copy.textContent = c.code;
          });
          var use = el('a', 'btn btn--primary btn--sm', 'Use on plans');
          use.setAttribute('href', c.plansPath);
          row.appendChild(copy); row.appendChild(use);
          card.appendChild(row);
        }
        box.appendChild(card);
      });
    });
  }

  /* Recent rides (the rider's own trips, newest first) with a link to each trip page. */
  function loadRides() {
    var box = S.$('ac-rides');
    if (!box) return;
    S.api('GET', '/trips?summary=1').then(function (r) {
      S.clear(box); box.removeAttribute('aria-busy');
      var trips = r.ok && r.json && Array.isArray(r.json.trips) ? r.json.trips.slice() : null;
      if (!trips) { box.appendChild(el('p', 't-small t-muted', 'Your rides could not load.')); return; }
      trips.sort(function (a, b) { return (Number(b.endTimeEpochMs) || 0) - (Number(a.endTimeEpochMs) || 0); });
      if (!trips.length) { box.appendChild(el('p', 't-small t-muted', 'No rides yet. Start one in the app: rides show up here with a summary.')); return; }
      var ul = el('ul', 'ac-list');
      ul.setAttribute('role', 'list');
      trips.slice(0, 5).forEach(function (t) {
        var li = el('li');
        var a = el('a', 'ac-list__link');
        a.setAttribute('href', '/trip/' + encodeURIComponent(t.tripId));
        a.appendChild(el('span', 'ac-list__title', String(t.tripName || t.name || 'Ride').slice(0, 80)));
        var km = Number(t.totalDistanceKm) || (Number(t.distanceM) || 0) / 1000;
        var mins = Math.round(Math.max(0, (Number(t.endTimeEpochMs) || 0) - (Number(t.startTimeEpochMs) || 0)) / 60000);
        a.appendChild(el('span', 't-small t-muted', [S.date(t.endTimeEpochMs), km ? km.toFixed(km < 10 ? 1 : 0) + ' km' : '', mins ? Math.floor(mins / 60) + ' h ' + (mins % 60) + ' min' : ''].filter(Boolean).join(' · ')));
        li.appendChild(a);
        ul.appendChild(li);
      });
      box.appendChild(ul);
      if (trips.length > 5) box.appendChild(el('p', 't-small t-muted', trips.length + ' rides in all. The full history is in the app (Trips).'));
    });
  }

  /* Clubs I am in (GET /api/clubs), with a link to /clubs. Off or failing: just the link. */
  function loadClubs() {
    var box = S.$('ac-clubs');
    if (!box) return;
    S.api('GET', '/clubs').then(function (r) {
      S.clear(box); box.removeAttribute('aria-busy');
      var clubs = r.ok && r.json && Array.isArray(r.json.clubs) ? r.json.clubs : [];
      var invites = r.ok && r.json && Array.isArray(r.json.invites) ? r.json.invites : [];
      if (clubs.length) {
        var ul = el('ul', 'ac-list');
        ul.setAttribute('role', 'list');
        clubs.slice(0, 5).forEach(function (c) {
          var li = el('li');
          var a = el('a', 'ac-list__link');
          a.setAttribute('href', '/clubs');
          a.appendChild(el('span', 'ac-list__title', c.name));
          a.appendChild(el('span', 't-small t-muted', [c.typeLabel, c.city, c.role === 'OWNER' ? 'Owner' : c.role === 'CO_ORGANISER' ? 'Co-organiser' : 'Member'].filter(Boolean).join(' · ')));
          li.appendChild(a);
          ul.appendChild(li);
        });
        box.appendChild(ul);
      } else {
        box.appendChild(el('p', 't-small t-muted', 'You are not in a club yet. Riding clubs and tour operators can invite you.'));
      }
      if (invites.length) box.appendChild(el('p', 't-small', invites.length === 1 ? 'You have 1 club invite waiting.' : 'You have ' + invites.length + ' club invites waiting.'));
      var a2 = el('a', 'link', clubs.length || invites.length ? 'Open your clubs' : 'About clubs');
      a2.setAttribute('href', '/clubs');
      box.appendChild(a2);
    });
  }

  /* 3.57 "Where you're signed in": GET /api/me/sessions, DELETE /api/me/sessions/:id (this browser -> home). */
  function loadSessions() {
    var box = S.$('ac-sessions');
    if (!box) return;
    S.api('GET', '/me/sessions').then(function (r) {
      S.clear(box); box.removeAttribute('aria-busy');
      var list = r.ok && r.json && Array.isArray(r.json.sessions) ? r.json.sessions : [];
      if (!list.length) { box.appendChild(el('p', 't-small t-muted', r.ok ? 'No other sessions.' : 'Could not load your sessions. Refresh to try again.')); return; }
      var ul = el('ul', 'ac-list');
      ul.setAttribute('role', 'list');
      list.forEach(function (x) {
        var li = el('li', 'ac-session');
        var info = el('div');
        var kind = x.kind === 'admin' ? 'Web admin' : x.kind === 'operator' ? 'Operator console' : x.kind === 'web' ? 'Website' : 'App';
        info.appendChild(el('span', 'ac-list__title', (x.deviceLabel || kind) + (x.current ? ' (this browser)' : '')));
        info.appendChild(el('span', 't-small t-muted', kind + ' · last active ' + S.dateTime(x.lastSeenAt) + ' · signed in ' + S.date(x.createdAt)));
        li.appendChild(info);
        var b = el('button', 'btn btn--ghost btn--sm', x.current ? 'Sign out' : 'Sign out this device');
        b.setAttribute('type', 'button');
        b.addEventListener('click', function () {
          if (x.current) { S.signOut(); return; }
          b.disabled = true;
          S.api('DELETE', '/me/sessions/' + encodeURIComponent(x.sessionId)).then(function (d) {
            if (d.ok) li.remove(); else { b.disabled = false; b.textContent = 'Try again'; }
          });
        });
        li.appendChild(b);
        ul.appendChild(li);
      });
      box.appendChild(ul);
    });
  }

  /* 3.57 change of e-mail: POST /api/me/email { newEmail, currentPassword } (link to the new address). */
  function initEmailChange() {
    var f = S.$('ac-email-form');
    if (!f) return;
    f.addEventListener('submit', function (e) {
      e.preventDefault();
      var st = S.$('ac-email-status');
      var to = S.$('ac-email-new').value.trim();
      var pw = S.$('ac-email-pw').value;
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) { st.textContent = 'Enter the new e-mail address.'; return; }
      if (!pw) { st.textContent = 'Enter your password to confirm it is you.'; return; }
      st.textContent = '';
      S.api('POST', '/me/email', { newEmail: to, currentPassword: pw }).then(function (r) {
        S.$('ac-email-pw').value = '';
        if (!r.ok) { st.textContent = (r.json && r.json.error) || 'Could not send the link.'; return; }
        var n = S.$('ac-email-notice');
        n.textContent = r.json.message || 'Check the new address for a confirmation link.';
        n.className = 'sh-notice sh-notice--ok';
        n.hidden = false;
        f.reset();
      });
    });
  }

  /* 3.56 "Offer e-mails" consent and 3.57 e-mail categories (GET / PUT /api/web/email-preferences):
   * account and receipts always; ride summaries and tips and news on until turned off; offers off until turned on. */
  function loadConsent() {
    var note = S.$('ac-offers-note');
    var boxes = { rideSummaries: S.$('ac-rides'), tipsNews: S.$('ac-tips'), offers: S.$('ac-offers') };
    if (!note || !boxes.offers) return;
    var hasEmail = false;
    function say(cats, suppressed) {
      if (!hasEmail) { note.textContent = 'Add an e-mail address to your account to get e-mails from CoRoute.'; return; }
      if (suppressed) { note.textContent = 'E-mails to your address bounced or were reported, so we paused them. Write to us to turn them on again.'; return; }
      note.textContent = cats.offers ? 'Offer e-mails are on. You can turn any of these off here or with the link in the e-mail.'
        : 'Offer e-mails are off. We never send offers unless you turn this on.';
    }
    function apply(j) {
      hasEmail = !!j.hasEmail;
      var c = j.categories || {};
      Object.keys(boxes).forEach(function (k) { if (!boxes[k]) return; boxes[k].checked = c[k] === true; boxes[k].disabled = !hasEmail; });
      say(c, j.suppressed);
    }
    S.api('GET', '/web/email-preferences').then(function (r) {
      if (!r.ok) { note.textContent = 'Your e-mail choices could not load. Refresh to try again.'; return; }
      apply(r.json);
    });
    Object.keys(boxes).forEach(function (k) {
      var box = boxes[k];
      if (!box) return;
      box.addEventListener('change', function () {
        var want = box.checked;
        var body = {};
        body[k] = want;
        box.disabled = true;
        S.api('PUT', '/web/email-preferences', body).then(function (r) {
          box.disabled = false;
          if (!r.ok) { box.checked = !want; note.textContent = (r.json && r.json.error) || 'Could not save. Try again.'; return; }
          apply(r.json);
        });
      });
    });
  }

  /* Round 4 "Help make roads safer" (GET / PUT /api/intel/consent): opt-in, off until the rider turns it on.
   * Download (GET /api/intel/me/contributions) and delete (DELETE /api/intel/me/contributions) my contributions. */
  function initRoads() {
    var box = S.$('ac-roads-on');
    var note = S.$('ac-roads-note');
    var status = S.$('ac-roads-status');
    if (!box || !note) return;
    function say(on, at) {
      note.textContent = on ? 'Thank you. Sharing is on' + (at ? ' since ' + new Date(at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '') + '. Turn it off at any time.'
        : 'Sharing is off. Nothing from your rides is used for road statistics.';
    }
    S.api('GET', '/intel/consent').then(function (r) {
      if (!r.ok) { note.textContent = 'Could not load this setting. Refresh to try again.'; return; }
      box.checked = r.json.on === true;
      box.disabled = false;
      say(box.checked, r.json.at);
    });
    box.addEventListener('change', function () {
      var want = box.checked;
      box.disabled = true;
      S.api('PUT', '/intel/consent', { on: want, source: 'web' }).then(function (r) {
        box.disabled = false;
        if (!r.ok) { box.checked = !want; note.textContent = (r.json && r.json.error) || 'Could not save. Try again.'; return; }
        say(r.json.on, r.json.at);
      });
    });
    S.$('ac-roads-export').addEventListener('click', function () {
      S.api('GET', '/intel/me/contributions').then(function (r) {
        if (!r.ok) { status.textContent = 'Could not download. Try again.'; return; }
        var blob = new Blob([JSON.stringify(r.json, null, 2)], { type: 'application/json' });
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'coroute-road-contributions.json';
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(function () { URL.revokeObjectURL(a.href); }, 4000);
        status.textContent = (r.json.rows || []).length + ' contributions from the last 90 days downloaded.';
      });
    });
    S.$('ac-roads-delete').addEventListener('click', function () {
      if (!window.confirm('Delete your road and safety contributions?\n\nEverything from the last 90 days is removed, including its share of the totals. Older contributions exist only inside anonymous totals that cannot be traced back to you, so they cannot be split out.')) return;
      S.api('DELETE', '/intel/me/contributions').then(function (r) {
        status.textContent = r.ok ? (r.json.message || 'Deleted.') : 'Could not delete. Try again.';
      });
    });
  }

  /** Round 4: one clear confirmation step for the e-mailed deletion link. */
  function confirmDelete(token) {
    var main = document.getElementById('main') || document.body;
    var box = document.createElement('section');
    box.className = 'container sh-card';
    box.setAttribute('aria-labelledby', 'del-title');
    box.style.margin = '2rem auto';
    box.style.maxWidth = '36rem';
    var h = document.createElement('h1'); h.id = 'del-title'; h.className = 'sh-card__title'; h.textContent = 'Delete your CoRoute account?';
    var p1 = document.createElement('p'); p1.textContent = 'This deletes your account, your rides, your trips and everything else in it, on every device. It cannot be undone.';
    var p2 = document.createElement('p'); p2.className = 't-small t-muted'; p2.textContent = 'If you did not ask for this, close this page and change your password.';
    var st = document.createElement('p'); st.className = 'sh-status'; st.setAttribute('role', 'alert');
    var btn = document.createElement('button'); btn.type = 'button'; btn.className = 'btn btn--primary'; btn.id = 'del-confirm'; btn.textContent = 'Delete my account';
    var keep = document.createElement('a'); keep.className = 'btn btn--ghost'; keep.href = '/'; keep.textContent = 'Keep my account';
    var actions = document.createElement('div'); actions.className = 'sh-actions'; actions.appendChild(btn); actions.appendChild(keep);
    [h, p1, p2, st, actions].forEach(function (n) { box.appendChild(n); });
    while (main.firstChild) main.removeChild(main.firstChild);
    main.appendChild(box);
    btn.addEventListener('click', function () {
      btn.disabled = true;
      S.api('POST', '/auth/delete/confirm', { token: token }, { auth: false }).then(function (r) {
        if (!r.ok) { btn.disabled = false; st.textContent = r.json.error || 'This link is not valid any more. Ask again from the app.'; return; }
        st.className = 'sh-status sh-status--ok';
        st.textContent = r.json.message || 'Your CoRoute account and its data were deleted.';
        actions.hidden = true;
        S.signOut({ stay: true }).catch(function () { /* nothing left to sign out */ });
      });
    });
  }
})();


/* ---------------------------------------------------------------------------------------------------------
 * 3.56 "Adjust your profile picture" (docs/features_355/profile_photo_adjust.md).
 *   GET  /api/me/profile            avatarUrl, avatarAdjustable, avatarCrop
 *   GET  /api/me/avatar/original    my original picture (only I can read it)
 *   POST /api/me/avatar/original    a new original (at most 2048 px, drawn on a canvas first: no EXIF, no GPS)
 *   POST /api/me/avatar/crop        the round 512 px picture + cx, cy, zoom, rot (+ original=<id> for a new one)
 *   DELETE /api/me/avatar           removes both
 * Canvas only, no library, no inline script. The crop numbers are the same as in the app
 * (lib/domain/media/avatar_crop.dart): rot = quarter turns clockwise; zoom 1..8; cx, cy = centre of the square,
 * 0..1 of the picture after turning. Keyboard on the preview: arrows move, + - zoom, [ ] turn, 0 resets.
 * --------------------------------------------------------------------------------------------------------- */
(function () {
  'use strict';
  var MAX_ZOOM = 8, OUT = 512, MIN_SIDE = 32, ORIGINAL_MAX = 2048, MAX_BYTES = 2 * 1024 * 1024;

  // ---- numbers (no DOM; also read by gateway/test/avatar_adjust_web_356.test.js) ----
  var M = {
    MAX_ZOOM: MAX_ZOOM, OUT: OUT, ORIGINAL_MAX: ORIGINAL_MAX,
    normRot: function (r) { return ((Math.round(r) % 4) + 4) % 4; },
    rotatedSize: function (w, h, rot) { return M.normRot(rot) % 2 ? [h, w] : [w, h]; },
    maxZoomFor: function (w, h) { var s = Math.min(w, h); return s > 0 ? Math.max(1, Math.min(MAX_ZOOM, s / MIN_SIDE)) : 1; },
    clamp: function (w, h, c) {
      if (!(w > 0) || !(h > 0)) return { cx: 0.5, cy: 0.5, zoom: 1, rot: 0 };
      var rot = M.normRot(isFinite(c.rot) ? c.rot : 0);
      var zoom = isFinite(c.zoom) ? Math.min(M.maxZoomFor(w, h), Math.max(1, c.zoom)) : 1;
      var rs = M.rotatedSize(w, h, rot), side = Math.min(w, h) / zoom;
      var fit = function (v, extent) {
        var half = side / 2 / extent;
        if (half >= 0.5) return 0.5;
        return Math.min(1 - half, Math.max(half, isFinite(v) ? v : 0.5));
      };
      return { cx: fit(c.cx, rs[0]), cy: fit(c.cy, rs[1]), zoom: zoom, rot: rot };
    },
    /** The square in the turned picture's pixels: { left, top, side }. */
    rotatedSquare: function (w, h, crop) {
      var c = M.clamp(w, h, crop), rs = M.rotatedSize(w, h, c.rot), side = Math.min(w, h) / c.zoom;
      return { left: c.cx * rs[0] - side / 2, top: c.cy * rs[1] - side / 2, side: side };
    },
    /** The same square in the file's own (unturned) pixels. */
    sourceSquare: function (w, h, crop) {
      var c = M.clamp(w, h, crop), s = M.rotatedSquare(w, h, c);
      if (c.rot === 1) return { left: s.top, top: h - (s.left + s.side), side: s.side };
      if (c.rot === 2) return { left: w - (s.left + s.side), top: h - (s.top + s.side), side: s.side };
      if (c.rot === 3) return { left: w - (s.top + s.side), top: s.left, side: s.side };
      return s;
    },
    outputSize: function (w, h, crop) { var c = M.clamp(w, h, crop); return Math.max(1, Math.min(OUT, Math.round(Math.min(w, h) / c.zoom))); },
    pan: function (w, h, crop, dx, dy, viewSide) {
      var c = M.clamp(w, h, crop);
      if (!(viewSide > 0)) return c;
      var rs = M.rotatedSize(w, h, c.rot), per = Math.min(w, h) / c.zoom / viewSide;
      return M.clamp(w, h, { cx: c.cx - dx * per / rs[0], cy: c.cy - dy * per / rs[1], zoom: c.zoom, rot: c.rot });
    },
    zoomTo: function (w, h, crop, zoom, fx, fy) {
      var c = M.clamp(w, h, crop);
      fx = fx === undefined ? 0.5 : fx; fy = fy === undefined ? 0.5 : fy;
      var z = Math.min(M.maxZoomFor(w, h), Math.max(1, isFinite(zoom) ? zoom : c.zoom));
      var rs = M.rotatedSize(w, h, c.rot), before = Math.min(w, h) / c.zoom, after = Math.min(w, h) / z;
      var px = c.cx * rs[0] + (fx - 0.5) * before, py = c.cy * rs[1] + (fy - 0.5) * before;
      return M.clamp(w, h, { cx: (px - (fx - 0.5) * after) / rs[0], cy: (py - (fy - 0.5) * after) / rs[1], zoom: z, rot: c.rot });
    },
    rotate: function (w, h, crop, turns) {
      var c = M.clamp(w, h, crop), n = M.normRot(turns);
      for (var i = 0; i < n; i++) c = { cx: 1 - c.cy, cy: c.cx, zoom: c.zoom, rot: M.normRot(c.rot + 1) };
      return M.clamp(w, h, c);
    },
    originalSize: function (w, h) {
      if (!(w > 0) || !(h > 0)) return [0, 0];
      var long = Math.max(w, h);
      if (long <= ORIGINAL_MAX) return [w, h];
      var k = ORIGINAL_MAX / long;
      return [Math.max(1, Math.round(w * k)), Math.max(1, Math.round(h * k))];
    },
    query: function (c) {
      var r4 = function (v) { return String(Math.round(v * 10000) / 10000); };
      return 'cx=' + r4(c.cx) + '&cy=' + r4(c.cy) + '&zoom=' + r4(c.zoom) + '&rot=' + c.rot;
    },
    /** A crop from the server, or null when it is not usable. */
    parse: function (raw) {
      if (!raw || typeof raw !== 'object') return null;
      var ok = function (v, lo, hi) { return typeof v === 'number' && isFinite(v) && v >= lo && v <= hi; };
      if (!ok(raw.cx, 0, 1) || !ok(raw.cy, 0, 1) || !ok(raw.zoom, 1, MAX_ZOOM) || !ok(raw.rot, 0, 3) || raw.rot !== Math.round(raw.rot)) return null;
      return { cx: raw.cx, cy: raw.cy, zoom: raw.zoom, rot: raw.rot };
    }
  };
  if (typeof window === 'undefined') return;
  window.CoAvatarCrop = M;

  var S = window.CoShop;
  var avatarBox = S && S.$ ? S.$('ac-avatar') : null;
  var dialog = S && S.$ ? S.$('ac-crop') : null;
  if (!S || !avatarBox) return;

  /** fetch with the session's Bearer header; one refresh on 401. Resolves the Response (or null offline). */
  function authed(method, path, body, type) {
    function send() {
      var headers = { 'X-CoRoute-Client': 'web' };
      if (S.token()) headers.Authorization = 'Bearer ' + S.token();
      if (type) headers['Content-Type'] = type;
      return fetch('/api' + path, { method: method, headers: headers, body: body, credentials: 'same-origin', cache: 'no-store', referrerPolicy: 'no-referrer' });
    }
    return send().then(function (r) {
      if (r.status !== 401 || !S.refresh) return r;
      return S.refresh().then(function (ok) { return ok ? send() : r; });
    }).catch(function () { return null; });
  }
  function bitmapOf(blob) {
    if (!window.createImageBitmap) return Promise.reject(new Error('unsupported'));
    return window.createImageBitmap(blob, { imageOrientation: 'from-image' }).catch(function () { return window.createImageBitmap(blob); });
  }
  /** Draws the crop of `img` (bitmap or canvas, w x h) so that the square fills `side` pixels of ctx. */
  function paintCrop(ctx, img, w, h, crop, side) {
    var c = M.clamp(w, h, crop), sq = M.rotatedSquare(w, h, c), rs = M.rotatedSize(w, h, c.rot), k = side / sq.side;
    ctx.save();
    ctx.beginPath(); ctx.rect(0, 0, side, side); ctx.clip();
    ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'high';
    ctx.scale(k, k);
    ctx.translate(-sq.left, -sq.top);
    ctx.translate(rs[0] / 2, rs[1] / 2);
    ctx.rotate(c.rot * Math.PI / 2);
    ctx.translate(-w / 2, -h / 2);
    ctx.drawImage(img, 0, 0, w, h);
    ctx.restore();
  }
  function toBlob(canvas, quality) {
    return new Promise(function (resolve) { canvas.toBlob(function (b) { resolve(b); }, 'image/jpeg', quality); });
  }

  // ---- the picture in the page header (needs the Bearer header, so it is fetched and drawn) ----
  var profile = null;
  function showAvatar(url) {
    var initials = avatarBox.getAttribute('data-initials') || avatarBox.textContent || '';
    if (!url) { S.clear(avatarBox); avatarBox.textContent = initials; return Promise.resolve(); }
    return authed('GET', url.replace(/^\/api/, '')).then(function (r) {
      if (!r || !r.ok) return null;
      return r.blob().then(bitmapOf);
    }).then(function (bmp) {
      if (!bmp) return;
      var c = document.createElement('canvas');
      c.width = 192; c.height = 192;
      var side = Math.min(bmp.width, bmp.height);
      c.getContext('2d').drawImage(bmp, (bmp.width - side) / 2, (bmp.height - side) / 2, side, side, 0, 0, 192, 192);
      S.clear(avatarBox);
      avatarBox.appendChild(c);
    }).catch(function () { /* the initials stay */ });
  }
  window.CoAvatar = { show: showAvatar };

  var editBtn = S.$('ac-photo-edit');
  // Older browsers (Safari < 15.4: no <dialog>, no createImageBitmap) cannot run the photo editor: hide its button
  // instead of showing one that does nothing. The picture itself still shows, and the app can change it.
  if (!dialog || !editBtn || typeof dialog.showModal !== 'function' || !window.createImageBitmap) { if (editBtn) editBtn.hidden = true; return; }
  var canvas = S.$('ac-crop-canvas'), ctx = canvas.getContext('2d');
  var zoomInput = S.$('ac-crop-zoom'), fileInput = S.$('ac-crop-file'), msg = S.$('ac-crop-msg'), help = S.$('ac-crop-help');
  var saveBtn = S.$('ac-crop-save'), removeBtn = S.$('ac-crop-remove'), emptyNote = S.$('ac-crop-empty');
  var tools = [S.$('ac-crop-left'), S.$('ac-crop-right'), S.$('ac-crop-reset')];
  var HELP = help.textContent;
  var st = { img: null, w: 0, h: 0, crop: { cx: 0.5, cy: 0.5, zoom: 1, rot: 0 }, keepOriginal: false, busy: false };

  function say(text, kind) {
    msg.textContent = text || '';
    msg.className = 'sh-notice' + (kind === 'warn' ? ' sh-notice--warn' : kind === 'ok' ? ' sh-notice--ok' : '');
    msg.hidden = !text;
  }
  function draw() {
    var side = canvas.width;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = '#15181c';
    ctx.fillRect(0, 0, side, side);
    if (st.img) paintCrop(ctx, st.img, st.w, st.h, st.crop, side);
    // Dim everything outside the circle, then its ring.
    ctx.save();
    ctx.beginPath();
    ctx.rect(0, 0, side, side);
    ctx.arc(side / 2, side / 2, side / 2 - 4, 0, Math.PI * 2, true);
    ctx.fillStyle = 'rgba(0, 0, 0, 0.62)';
    ctx.fill('evenodd');
    ctx.beginPath();
    ctx.arc(side / 2, side / 2, side / 2 - 4, 0, Math.PI * 2);
    ctx.lineWidth = 5; ctx.strokeStyle = '#ffffff';
    ctx.stroke();
    ctx.restore();
  }
  function sync() {
    var has = !!st.img, maxZ = has ? M.maxZoomFor(st.w, st.h) : 1;
    zoomInput.max = String(Math.max(1.01, maxZ));
    zoomInput.value = String(st.crop.zoom);
    zoomInput.disabled = !has || st.busy || maxZ <= 1;
    zoomInput.setAttribute('aria-valuetext', 'Zoom ' + st.crop.zoom.toFixed(1) + ' times');
    tools.forEach(function (b) { b.disabled = !has || st.busy; });
    saveBtn.disabled = !has || st.busy;
    saveBtn.textContent = st.busy ? 'Saving…' : 'Save';
    emptyNote.hidden = has;
    removeBtn.hidden = !(profile && profile.avatarUrl);
    removeBtn.disabled = st.busy;
    draw();
  }
  function setCrop(c) { if (!st.img || st.busy) return; st.crop = M.clamp(st.w, st.h, c); sync(); }
  function setImage(img, w, h, crop, keepOriginal, note) {
    st.img = img; st.w = w; st.h = h; st.keepOriginal = keepOriginal;
    st.crop = M.clamp(w, h, crop || { cx: 0.5, cy: 0.5, zoom: 1, rot: 0 });
    help.textContent = note || HELP;
    say('');
    sync();
  }
  /** A file or downloaded picture -> a canvas at most 2048 px on its long side (orientation applied, no metadata). */
  function workingCopy(blob) {
    return bitmapOf(blob).then(function (bmp) {
      var size = M.originalSize(bmp.width, bmp.height);
      var c = document.createElement('canvas');
      c.width = size[0]; c.height = size[1];
      var g = c.getContext('2d');
      g.imageSmoothingEnabled = true; g.imageSmoothingQuality = 'high';
      g.drawImage(bmp, 0, 0, size[0], size[1]);
      if (bmp.close) bmp.close();
      return c;
    });
  }

  function open() {
    st.img = null; st.busy = false;
    help.textContent = HELP;
    say('Loading your picture…');
    sync();
    dialog.showModal();
    canvas.focus();
    S.api('GET', '/me/profile').then(function (res) {
      if (!res.ok) { say(res.json.error || 'Your picture could not be loaded.', 'warn'); return null; }
      profile = res.json.profile || {};
      sync();
      if (!profile.avatarUrl) { say('Choose a picture to start.'); return null; }
      var fromOriginal = !!profile.avatarAdjustable;
      return authed('GET', fromOriginal ? '/me/avatar/original' : profile.avatarUrl.replace(/^\/api/, '')).then(function (r) {
        if (!r || !r.ok) { say('Your picture could not be loaded. Choose a new picture, or try again later.', 'warn'); return null; }
        return r.blob().then(workingCopy).then(function (c) {
          setImage(c, c.width, c.height, fromOriginal ? M.parse(profile.avatarCrop) : null, !fromOriginal,
            fromOriginal ? null : 'The original of this picture was not kept, so you are adjusting the current picture. Choose a new picture for full quality.');
        });
      });
    }).catch(function () { say('Your picture could not be loaded.', 'warn'); });
  }
  function close() { if (dialog.open) dialog.close(); editBtn.focus(); }

  function pickFile() {
    var f = fileInput.files && fileInput.files[0];
    fileInput.value = '';
    if (!f) return;
    if (!/^image\/(jpeg|png|webp)$/.test(f.type)) { say('Use a JPEG, PNG or WebP picture.', 'warn'); return; }
    if (f.size > 25 * 1024 * 1024) { say('This picture is too large. Choose one under 25 MB.', 'warn'); return; }
    workingCopy(f).then(function (c) { setImage(c, c.width, c.height, null, true, null); canvas.focus(); })
      .catch(function () { say('This picture could not be opened. Please choose another one.', 'warn'); });
  }

  /** The original as JPEG under 2 MB (lower quality when needed), or null. */
  function encodeOriginal(src) {
    var qualities = [0.88, 0.75, 0.6], i = 0;
    function next() {
      if (i >= qualities.length) return Promise.resolve(null);
      return toBlob(src, qualities[i++]).then(function (b) { return b && b.size <= MAX_BYTES ? b : next(); });
    }
    return next();
  }
  function fail(r, fallback) {
    if (!r) return Promise.resolve('Could not reach CoRoute. Check your connection and try again.');
    return r.json().catch(function () { return {}; }).then(function (j) { return (j && j.error) || fallback; });
  }
  function save() {
    if (!st.img || st.busy) return;
    st.busy = true; say(''); sync();
    var out = M.outputSize(st.w, st.h, st.crop);
    var c = document.createElement('canvas');
    c.width = out; c.height = out;
    var g = c.getContext('2d');
    g.fillStyle = '#ffffff'; g.fillRect(0, 0, out, out);
    paintCrop(g, st.img, st.w, st.h, st.crop, out);
    var query = M.query(st.crop);
    var step = st.keepOriginal
      ? encodeOriginal(st.img).then(function (blob) {
        if (!blob) return { error: 'This picture is too large. Please choose a smaller one.' };
        return authed('POST', '/me/avatar/original', blob, 'image/jpeg').then(function (r) {
          if (!r || !r.ok) return fail(r, 'The picture could not be saved.').then(function (e) { return { error: e }; });
          return r.json().then(function (j) { return { id: j.originalId }; });
        });
      })
      : Promise.resolve({});
    step.then(function (o) {
      if (o.error) return o.error;
      return toBlob(c, 0.88).then(function (blob) {
        if (!blob) return 'The picture could not be saved.';
        return authed('POST', '/me/avatar/crop?' + query + (o.id ? '&original=' + encodeURIComponent(o.id) : ''), blob, 'image/jpeg').then(function (r) {
          if (!r || !r.ok) return fail(r, 'The picture could not be saved.');
          return r.json().then(function (j) {
            if (profile) { profile.avatarUrl = j.avatarUrl; profile.avatarAdjustable = true; profile.avatarCrop = j.avatarCrop; }
            st.keepOriginal = false;
            return showAvatar(j.avatarUrl).then(function () { return null; });
          });
        });
      });
    }).catch(function () { return 'The picture could not be saved.'; }).then(function (problem) {
      st.busy = false;
      if (problem) { say(problem, 'warn'); sync(); return; }
      sync();
      close();
    });
  }
  function remove() {
    if (st.busy) return;
    st.busy = true; sync();
    S.api('DELETE', '/me/avatar').then(function (res) {
      st.busy = false;
      if (!res.ok) { say(res.json.error || 'The picture could not be removed.', 'warn'); sync(); return; }
      if (profile) { profile.avatarUrl = null; profile.avatarAdjustable = false; profile.avatarCrop = null; }
      st.img = null;
      showAvatar(null);
      sync();
      close();
    });
  }

  // ---- pointer, wheel and keyboard on the preview ----
  var pointers = {}, pinch = null;
  var viewSide = function () { return canvas.getBoundingClientRect().width || 1; };
  function count() { return Object.keys(pointers).length; }
  function spread() { var k = Object.keys(pointers); var a = pointers[k[0]], b = pointers[k[1]]; return Math.hypot(a.x - b.x, a.y - b.y); }
  canvas.addEventListener('pointerdown', function (e) {
    if (!st.img) return;
    try { canvas.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    pointers[e.pointerId] = { x: e.clientX, y: e.clientY };
    pinch = count() === 2 ? { d: spread(), zoom: st.crop.zoom } : null;
  });
  canvas.addEventListener('pointermove', function (e) {
    var p = pointers[e.pointerId];
    if (!p || !st.img) return;
    var dx = e.clientX - p.x, dy = e.clientY - p.y;
    p.x = e.clientX; p.y = e.clientY;
    var n = count();
    var c = M.pan(st.w, st.h, st.crop, dx / n, dy / n, viewSide());
    if (pinch && n === 2 && pinch.d > 0) c = M.zoomTo(st.w, st.h, c, pinch.zoom * spread() / pinch.d);
    setCrop(c);
  });
  var up = function (e) { delete pointers[e.pointerId]; pinch = null; };
  canvas.addEventListener('pointerup', up);
  canvas.addEventListener('pointercancel', up);
  canvas.addEventListener('wheel', function (e) {
    if (!st.img) return;
    e.preventDefault();
    var r = canvas.getBoundingClientRect();
    setCrop(M.zoomTo(st.w, st.h, st.crop, st.crop.zoom * (e.deltaY < 0 ? 1.1 : 1 / 1.1), (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height));
  }, { passive: false });
  canvas.addEventListener('keydown', function (e) {
    if (!st.img) return;
    var step = (e.shiftKey ? 40 : 10), v = viewSide(), done = true;
    if (e.key === 'ArrowLeft') setCrop(M.pan(st.w, st.h, st.crop, step, 0, v));
    else if (e.key === 'ArrowRight') setCrop(M.pan(st.w, st.h, st.crop, -step, 0, v));
    else if (e.key === 'ArrowUp') setCrop(M.pan(st.w, st.h, st.crop, 0, step, v));
    else if (e.key === 'ArrowDown') setCrop(M.pan(st.w, st.h, st.crop, 0, -step, v));
    else if (e.key === '+' || e.key === '=') setCrop(M.zoomTo(st.w, st.h, st.crop, st.crop.zoom * 1.1));
    else if (e.key === '-' || e.key === '_') setCrop(M.zoomTo(st.w, st.h, st.crop, st.crop.zoom / 1.1));
    else if (e.key === '[') setCrop(M.rotate(st.w, st.h, st.crop, -1));
    else if (e.key === ']') setCrop(M.rotate(st.w, st.h, st.crop, 1));
    else if (e.key === '0') setCrop({ cx: 0.5, cy: 0.5, zoom: 1, rot: 0 });
    else done = false;
    if (done) e.preventDefault();
  });
  zoomInput.addEventListener('input', function () { setCrop(M.zoomTo(st.w, st.h, st.crop, Number(zoomInput.value))); });
  tools[0].addEventListener('click', function () { setCrop(M.rotate(st.w, st.h, st.crop, -1)); });
  tools[1].addEventListener('click', function () { setCrop(M.rotate(st.w, st.h, st.crop, 1)); });
  tools[2].addEventListener('click', function () { setCrop({ cx: 0.5, cy: 0.5, zoom: 1, rot: 0 }); });
  fileInput.addEventListener('change', pickFile);
  saveBtn.addEventListener('click', save);
  removeBtn.addEventListener('click', remove);
  S.$('ac-crop-cancel').addEventListener('click', close);
  S.$('ac-crop-form').addEventListener('submit', function (e) { e.preventDefault(); });
  dialog.addEventListener('cancel', function (e) { if (st.busy) e.preventDefault(); });
  editBtn.addEventListener('click', open);
  editBtn.hidden = false;
})();
