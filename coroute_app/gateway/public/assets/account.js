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
      if (me.avatarUrl) { var img = el('img'); img.setAttribute('src', me.avatarUrl); img.setAttribute('alt', ''); img.setAttribute('width', '64'); img.setAttribute('height', '64'); av.appendChild(img); }
      else av.textContent = String(me.username || me.name || '?').slice(0, 2).toUpperCase();
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
