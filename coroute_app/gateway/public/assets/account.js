/* 3.56 /account: the rider's plan and payments on the website. No ride data.
 *   GET /api/me                  username, name, e-mail (nothing medical is shown)
 *   GET /api/membership/my       plan, end date, a plan change waiting to start
 *   GET /api/membership/payments every order, newest first -> receipts (/receipt?order=<id>, paid orders)
 *   GET /api/membership/catalog  plan names for the payment list
 * Plans never renew on their own, so there is nothing to cancel. Text is written with textContent only. */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S || !S.$('ac-plan')) return;
  var el = S.el;
  if (!S.token()) { S.toSignIn('/account'); return; }

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
        ab.className = 'sh-notice sh-notice--ok';
        ab.style.display = 'flex';
        ab.style.alignItems = 'center';
        ab.style.justifyContent = 'space-between';
        ab.style.marginBottom = '24px';
        ab.style.padding = '14px 20px';
        ab.style.borderRadius = '12px';
        var txt = el('div');
        txt.appendChild(el('strong', null, 'Administrator Access: '));
        txt.appendChild(document.createTextNode('You are signed in as a Master Administrator.'));
        var btn = el('a', 'btn btn--primary', 'Open Admin Console');
        btn.setAttribute('href', '/admin');
        ab.appendChild(txt);
        ab.appendChild(btn);
        ab.hidden = false;
      }
    }
    var who = me.username ? '@' + me.username : (me.name || 'Rider');
    S.$('ac-title').textContent = 'Hi, ' + who + '.';
    S.$('ac-who').textContent = [me.name && me.username ? me.name : '', me.email || ''].filter(Boolean).join(' · ') || 'Your plan and payments.';
    renderPlan(me, rs[1].ok ? rs[1].json : null);
    var names = {};
    var cats = rs[3].ok && rs[3].json.categories ? rs[3].json.categories : {};
    Object.keys(cats).forEach(function (id) { names[id] = S.planName(cats[id]); });
    if (!names.individual) names.individual = 'Individual';
    if (rs[2].ok) renderPayments(rs[2].json.payments, names);
    else S.clear(S.$('ac-payments')).appendChild(el('p', 't-small t-muted', 'Payments could not load. Refresh to try again.'));
  });
})();
