/* 3.56 /plans: the rider buys a plan on the website (the Play app sells nothing).
 * Data, all from the server (nothing is priced here):
 *   GET  /api/membership/catalog                 plan cards (public; the list the app used)
 *   GET  /api/me, /api/membership/my             who is signed in and their plan (Bearer from sessionStorage)
 *   GET  /api/membership/quote?plan=&coupon=     price: list price, coupon, upgrade credit, what to pay;
 *                                                409 DOWNGRADE_NOT_ALLOWED text shown as the server words it
 *   POST /api/membership/order                   the server's amount -> Razorpay order (or activated at once at ₹0)
 *   Razorpay Checkout (checkout.razorpay.com)    the payment; then POST /api/membership/verify (signature check)
 * ?coupon=CODE (marketing QR / link) prefills the code (A-Z 0-9 - _, at most 24); ?plan=<id> preselects a plan.
 * Everything is written with textContent. */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S) return;
  var grid = S.$('pl-grid');
  if (!grid) return;
  var el = S.el;

  var FEATURES = {
    essential_safety: 'Crash detection and SOS',
    basic_nav: 'Navigation and offline maps',
    personal_tracking: 'Your own ride history and trip report',
    profile_settings: 'Medical ID and emergency contacts',
    convoy_tracking: 'Live group map for every rider',
    group_trips: 'Host group rides with planned stops',
    ptt_intercom: 'Push-to-talk for the whole group',
    group_safety: 'Group SOS, regroup and lead alerts',
    shared_trips: 'Shared trip report and replay'
  };
  // Lowest first; the server's rule is the truth (409), this only greys out what it would refuse.
  var RANK = ['community', 'individual', 'group_small', 'group_large'];

  var st = {
    plans: [], paymentsEnabled: true, me: null, my: null,
    selected: null, code: S.cleanCode(S.query('coupon')), quote: null, seq: 0, busy: false
  };

  function featureText(k) {
    if (FEATURES[k]) return FEATURES[k];
    var s = String(k).trim();
    if (/^[a-z0-9_]+$/.test(s)) s = s.replace(/_+/g, ' ');
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
  }
  function num(v) { var n = typeof v === 'string' ? parseFloat(v) : v; return typeof n === 'number' && isFinite(n) && n >= 0 ? n : null; }
  function seatsText(p) {
    if (p.max <= 1) return 'Solo rider';
    if (p.min > 1 && p.min < p.max) return p.min + ' to ' + p.max + ' riders, host included';
    return 'Up to ' + p.max + ' riders, host included';
  }
  function step(n) {
    for (var i = 1; i <= 3; i++) {
      var li = S.$('pl-step-' + i);
      li.className = i < n ? 'is-done' : (i === n ? 'is-current' : '');
      if (i === n) li.setAttribute('aria-current', 'step'); else li.removeAttribute('aria-current');
    }
  }

  /** The paid plan running now (the server's membership), or null. */
  function activePaid() {
    var o = st.my && st.my.owned;
    if (!o || o.status !== 'ACTIVE' || !(Number(o.validUntil) > Date.now())) return null;
    if (o.category === 'community') return null;
    return o;
  }
  function currentPlanId() {
    var p = st.my && st.my.plan;
    return p ? String(p.category || (p.isFree ? 'community' : '')) : '';
  }
  /** Why the server would refuse plan `id` now (mirror of the upgrade-only rule), or ''. */
  function blockedReason(id) {
    var cur = activePaid();
    if (!cur) return '';
    var from = RANK.indexOf(cur.category), to = RANK.indexOf(id);
    if (from < 0 || to < 0 || to > from) return '';
    return to === from ? 'Your plan until ' + S.date(cur.validUntil) : 'Available after ' + S.date(cur.validUntil);
  }

  /* ---------- who is signed in ---------- */
  function renderWho() {
    var text = S.$('pl-who-text');
    var actions = S.clear(S.$('pl-who-actions'));
    if (!st.me) {
      text.textContent = 'Sign in to see your plan and your price.';
      var a = el('a', 'btn btn--secondary btn--sm', 'Sign in');
      a.setAttribute('href', '/signin?next=' + encodeURIComponent('/plans' + (st.code ? '?coupon=' + st.code : '')));
      actions.appendChild(a);
      return;
    }
    var who = st.me.username ? '@' + st.me.username : (st.me.name || 'your account');
    var p = st.my && st.my.plan;
    var line = 'Signed in as ' + who + '.';
    if (p) {
      line += p.isFree || p.source === 'community' ? ' Your plan: Community (free).' :
        ' Your plan: ' + S.planName(p) + (p.validUntil ? ', until ' + S.date(p.validUntil) : '') + '.';
    }
    text.textContent = line;
    var acc = el('a', 'btn btn--secondary btn--sm', 'Account');
    acc.setAttribute('href', '/account');
    actions.appendChild(acc);
    var out = el('button', 'btn btn--ghost btn--sm', 'Sign out');
    out.type = 'button';
    out.setAttribute('data-signout', '');
    actions.appendChild(out);
  }

  /* ---------- plan cards ---------- */
  function plansFrom(j) {
    var cats = j && j.categories;
    if (!cats || typeof cats !== 'object') throw new Error('shape');
    var out = [];
    Object.keys(cats).forEach(function (id) {
      var c = cats[id];
      if (!c || typeof c !== 'object' || c.isActive === false) return;
      // 3.56: the server's price now (offer within its window, else the list price) and the list price.
      var list = num(c.listPriceInr) !== null ? num(c.listPriceInr) : num(c.monthlyPriceInr);
      var price = num(c.priceInr) !== null ? num(c.priceInr) : list;
      if (price === null || list === null) return;
      var ao = c.activeOffer && typeof c.activeOffer === 'object' ? c.activeOffer : null;
      var offer = ao && num(ao.priceInr) === price && price < list && typeof ao.label === 'string'
        ? { label: ao.label.slice(0, 40), endsAt: num(ao.endsAt) } : null;
      out.push({
        id: String(c.id || id), name: S.planName(c), price: price, list: list, offer: offer,
        min: Math.round(num(c.minCapacity) || 1), max: Math.round(num(c.maxCapacity) || num(c.capacity) || 1),
        period: num(c.billingPeriodDays) || 30, desc: typeof c.description === 'string' ? c.description.trim() : '',
        free: price === 0 || c.purchasable === false,
        features: Array.isArray(c.features) ? c.features.filter(function (f) { return typeof f === 'string'; }).slice(0, 8) : []
      });
    });
    out.sort(function (a, b) { return a.price - b.price || a.max - b.max; });
    return out;
  }

  function renderPlans() {
    S.clear(grid);
    grid.removeAttribute('aria-busy');
    if (!st.plans.length) {
      grid.appendChild(el('p', 'sh-msg', 'Plans are being updated. Please check again in a few minutes.'));
      grid.setAttribute('data-state', 'empty');
      return;
    }
    var mine = st.me ? currentPlanId() : '';
    var accent = false;
    st.plans.forEach(function (p) {
      var card = el('article', 'sh-plan');
      card.setAttribute('data-plan', p.id);
      var isMine = mine && mine === p.id;
      if (isMine) card.classList.add('is-current');
      if (st.selected === p.id) card.classList.add('is-selected');
      if (!p.free && !accent && !isMine) { card.classList.add('sh-plan--accent'); accent = true; }
      var tags = el('div', 'sh-plan__tags');
      tags.appendChild(el('span', 'sh-plan__tag', p.free ? 'Always free' : (p.max > 1 ? 'Group host' : 'Solo')));
      if (isMine) tags.appendChild(el('span', 'sh-plan__tag sh-plan__tag--mine', 'Your plan'));
      card.appendChild(tags);
      card.appendChild(el('h3', 'sh-plan__name', p.name));
      var seats = el('p', 'sh-plan__seats');
      seats.appendChild(S.icon('i-users'));
      seats.appendChild(el('span', null, seatsText(p)));
      card.appendChild(seats);
      var price = el('p', 'sh-plan__price');
      if (!p.free && p.offer) {
        var was = el('s', 'sh-plan__was', S.inr(p.list));
        was.setAttribute('aria-label', 'Was ' + S.inr(p.list));
        price.appendChild(was);
      }
      price.appendChild(el('span', 'sh-plan__amount', p.free ? 'Free' : S.inr(p.price)));
      price.appendChild(el('span', 'sh-plan__per', p.free ? 'in the app, forever' : (p.period === 30 ? 'per month' : 'for ' + p.period + ' days')));
      card.appendChild(price);
      if (!p.free && p.offer) {
        var off = el('p', 'sh-plan__offer');
        off.appendChild(el('span', 'sh-plan__offer-label', p.offer.label));
        if (p.offer.endsAt) off.appendChild(el('span', 'sh-plan__offer-until', 'until ' + S.date(p.offer.endsAt - 1)));
        card.appendChild(off);
      }
      if (p.desc) card.appendChild(el('p', 'sh-plan__desc', p.desc));
      if (p.features.length) {
        var ul = el('ul', 'sh-plan__list');
        ul.setAttribute('role', 'list');
        p.features.forEach(function (f) {
          var t = featureText(f);
          if (!t) return;
          var li = el('li');
          li.appendChild(S.icon('i-check'));
          li.appendChild(el('span', null, t));
          ul.appendChild(li);
        });
        card.appendChild(ul);
      }
      var cta = el('div', 'sh-plan__cta');
      if (p.free) {
        // Community: nothing to pay; it is what every rider has in the app.
        var a = el('a', 'btn btn--block btn--secondary', isMine ? 'You have this in the app' : 'Free in the app');
        a.setAttribute('href', '/get');
        cta.appendChild(a);
        cta.appendChild(el('p', 'sh-plan__note', 'No payment and no sign-up here. Download the app and ride solo with every safety feature.'));
      } else {
        var why = st.me ? blockedReason(p.id) : '';
        var b = el('button', 'btn btn--block ' + (card.classList.contains('sh-plan--accent') || st.selected === p.id ? 'btn--primary' : 'btn--secondary'),
          why || (st.selected === p.id ? 'Selected' : 'Choose ' + p.name));
        b.type = 'button';
        b.setAttribute('data-choose', p.id);
        if (why || !st.paymentsEnabled) { b.disabled = true; b.setAttribute('aria-disabled', 'true'); }
        if (st.selected === p.id) b.setAttribute('aria-pressed', 'true');
        cta.appendChild(b);
        if (why && why.indexOf('Available after') === 0) cta.appendChild(el('p', 'sh-plan__note', 'You can move to a bigger plan anytime. Smaller plans can be chosen when your current plan ends.'));
      }
      card.appendChild(cta);
      grid.appendChild(card);
    });
    grid.setAttribute('data-state', 'loaded');
    if (!st.paymentsEnabled) {
      grid.appendChild(el('p', 'sh-msg', 'Payments are switched off right now: every feature is open in the app, so there is nothing to buy.'));
    }
  }

  grid.addEventListener('click', function (e) {
    var b = e.target.closest ? e.target.closest('[data-choose]') : null;
    if (!b || b.disabled) return;
    choose(b.getAttribute('data-choose'), true);
  });

  /* ---------- step 2: the server's price ---------- */
  var bill = S.$('co-bill');
  var payBtn = S.$('co-pay');
  var status = S.$('co-status');
  var codeInput = S.$('co-code');
  var codeMsg = S.$('co-code-msg');
  var emailInput = S.$('co-email');

  /* 3.56: the optional receipt address, stored on this order only (POST /api/web/receipt-email). */
  function saveReceiptEmail(o) {
    var v = emailInput ? String(emailInput.value || '').trim() : '';
    if (!v || !o || !o.orderId) return;
    try { S.api('POST', '/web/receipt-email', { orderId: o.orderId, email: v }); } catch (e) { /* the account email is used */ }
  }

  function planById(id) { for (var i = 0; i < st.plans.length; i++) if (st.plans[i].id === id) return st.plans[i]; return null; }
  function say(t) { status.textContent = t || ''; }
  function codeSay(t, kind) { codeMsg.textContent = t || ''; codeMsg.className = 'sh-coupon__msg' + (kind ? ' is-' + kind : ''); }

  function choose(id, scroll) {
    var p = planById(id);
    if (!p || p.free) return;
    st.selected = id;
    st.quote = null;
    renderPlans();
    var sec = S.$('checkout');
    sec.hidden = false;
    S.$('done').hidden = true;
    step(2);
    S.$('co-title').textContent = p.name;
    S.$('co-sub').textContent = seatsText(p) + '. ' + (p.period === 30 ? 'One month' : p.period + ' days') + ' from the day you pay.';
    codeInput.value = st.code;
    say('');
    if (scroll) {
      var top = sec.getBoundingClientRect().top + window.scrollY - 80;
      try { window.scrollTo({ top: top, behavior: 'smooth' }); } catch (e2) { window.scrollTo(0, top); }
    }
    refreshQuote();
  }

  function renderBill(lines, totalLabel) {
    S.clear(bill);
    var dl = el('dl', 'sh-bill__lines');
    lines.forEach(function (l, i) {
      var last = i === lines.length - 1;
      var row = el('div', 'sh-bill__row' + (last ? ' sh-bill__row--total' : '') + (!last && Number(l.amountInr) < 0 ? ' sh-bill__row--minus' : ''));
      row.appendChild(el('dt', null, last && totalLabel ? totalLabel : l.label));
      row.appendChild(el('dd', null, S.inr(l.amountInr)));
      dl.appendChild(row);
    });
    bill.appendChild(dl);
  }

  function renderNotes(notes) {
    var box = S.clear(S.$('co-notes'));
    var list = (notes || []).filter(function (n) { return typeof n === 'string' && n; });
    box.hidden = !list.length;
    list.forEach(function (n) {
      var p = el('p');
      p.appendChild(S.icon('i-clock'));
      p.appendChild(el('span', null, n));
      box.appendChild(p);
    });
  }

  function refreshQuote() {
    var p = planById(st.selected);
    if (!p) return;
    S.$('co-remove').hidden = !st.code;
    if (!st.me) {
      // Signed out: the list price from the catalog; the code is checked after sign-in.
      var lines = [{ label: p.name + ' (' + p.period + ' days)', amountInr: p.list }];
      if (p.offer) lines.push({ label: p.offer.label, amountInr: p.price - p.list });
      lines.push({ label: 'Price', amountInr: p.price });
      renderBill(lines, 'Price before codes and credit');
      renderNotes([]);
      codeSay(st.code ? 'Code ' + st.code + ' is checked after you sign in.' : '', '');
      payBtn.disabled = false;
      payBtn.textContent = 'Sign in to continue';
      return;
    }
    var seq = ++st.seq;
    payBtn.disabled = true;
    payBtn.textContent = 'Checking your price…';
    bill.setAttribute('aria-busy', 'true');
    S.api('GET', '/membership/quote?plan=' + encodeURIComponent(p.id) + (st.code ? '&coupon=' + encodeURIComponent(st.code) : '')).then(function (r) {
      if (seq !== st.seq) return; // a newer request is on its way
      bill.removeAttribute('aria-busy');
      if (r.status === 401) { S.toSignIn('/plans?plan=' + p.id + (st.code ? '&coupon=' + st.code : '')); return; }
      if (!r.ok) {
        st.quote = null;
        S.clear(bill).appendChild(el('p', 'sh-bill__refused', r.json.error || 'This plan cannot be bought right now.'));
        renderNotes([]);
        payBtn.textContent = 'Continue to payment';
        payBtn.disabled = true;
        return;
      }
      var q = r.json;
      st.quote = q;
      renderBill(q.breakdown && q.breakdown.length ? q.breakdown : [{ label: q.planName, amountInr: q.basePriceInr }, { label: 'To pay now', amountInr: q.payableInr }]);
      renderNotes(q.notes);
      if (q.couponError && st.code) codeSay(q.couponError.error || 'This code cannot be used.', 'bad');
      else if (q.couponCode) codeSay(q.couponCode + ' applied: ' + S.inr(q.couponDiscountInr) + ' off.', 'ok');
      else codeSay('', '');
      payBtn.disabled = false;
      payBtn.textContent = q.payableInr > 0 ? 'Continue to payment: ' + S.inr(q.payableInr) : 'Activate ' + S.planName({ name: q.planName }) + ' (nothing to pay)';
    });
  }

  S.$('co-coupon').addEventListener('submit', function (e) {
    e.preventDefault();
    var raw = codeInput.value.trim();
    var c = S.cleanCode(raw);
    if (raw && !c) { codeSay('Codes use letters, numbers, - and _ only.', 'bad'); return; }
    st.code = c;
    refreshQuote();
  });
  S.$('co-remove').addEventListener('click', function () {
    st.code = '';
    codeInput.value = '';
    codeSay('', '');
    refreshQuote();
  });

  /* ---------- step 3: payment ---------- */
  function done(membership, message) {
    S.$('checkout').hidden = true;
    var d = S.$('done');
    d.hidden = false;
    step(3);
    var name = S.planName(membership || {});
    S.$('done-detail').textContent = message ||
      (membership && membership.validUntil ? name + ' is active until ' + S.date(membership.validUntil) + '.' : 'Your plan is active.');
    var card = S.$('done-card');
    card.focus();
    try { d.scrollIntoView({ behavior: 'smooth', block: 'start' }); } catch (e) { /* old browsers */ }
    // Fresh state for the cards and the strip.
    loadMine().then(function () { renderWho(); renderPlans(); });
  }

  function withRazorpay(cb) {
    if (window.Razorpay) return cb();
    var s = document.createElement('script');
    s.src = 'https://checkout.razorpay.com/v1/checkout.js';
    s.async = true;
    s.onload = function () { if (window.Razorpay) cb(); else fail('Could not load Razorpay. Check your connection and try again.'); };
    s.onerror = function () { fail('Could not load Razorpay. Check your connection and try again.'); };
    document.head.appendChild(s);
  }
  function fail(msg) { st.busy = false; payBtn.disabled = false; say(msg); payBtn.textContent = st.quote && st.quote.payableInr > 0 ? 'Continue to payment: ' + S.inr(st.quote.payableInr) : 'Continue to payment'; }

  function verify(resp) {
    payBtn.textContent = 'Confirming your payment…';
    say('');
    S.api('POST', '/membership/verify', {
      orderId: resp.razorpay_order_id, paymentId: resp.razorpay_payment_id, signature: resp.razorpay_signature
    }).then(function (r) {
      st.busy = false;
      if (r.ok) { done(r.json.membership); return; }
      payBtn.disabled = false;
      payBtn.textContent = 'Continue to payment';
      say((r.json.error ? r.json.error + ' ' : '') + 'If money left your account, your plan turns on as soon as Razorpay confirms the payment. Check your account page in a minute.');
    });
  }

  function openCheckout(order) {
    withRazorpay(function () {
      var me = st.me || {};
      var phone = String(me.phone || '').replace(/[^\d+]/g, '');
      var rzp;
      try {
        rzp = new window.Razorpay({
          key: order.keyId,
          order_id: order.orderId,
          amount: order.amountInPaise,
          currency: order.currency || 'INR',
          name: 'CoRoute',
          description: (order.categoryName ? S.planName({ name: order.categoryName }) : 'Plan') + ' plan',
          prefill: { name: me.name || '', email: me.email || '', contact: /^\+?\d{10,13}$/.test(phone) ? phone : '' },
          notes: { channel: 'web' },
          // The order is payable for a limited time (server ORDER_TTL); Checkout closes itself first.
          timeout: Math.max(60, Math.min(1800, Number(order.checkoutTimeoutSeconds) || 900)),
          theme: { color: '#2B7A8C' },
          handler: verify,
          modal: {
            confirm_close: true,
            ondismiss: function () { if (st.busy) fail('Payment not completed. Nothing was charged, you can try again.'); }
          }
        });
        rzp.on('payment.failed', function (resp) {
          var d = resp && resp.error && resp.error.description;
          say('Payment failed' + (d ? ': ' + String(d).slice(0, 160) : '') + '. You can try again.');
        });
        rzp.open();
        payBtn.textContent = 'Waiting for Razorpay…';
      } catch (e) {
        fail('Could not open Razorpay. Try again.');
      }
    });
  }

  payBtn.addEventListener('click', function () {
    var p = planById(st.selected);
    if (!p || st.busy) return;
    if (!st.me) { S.toSignIn('/plans?plan=' + p.id + (st.code ? '&coupon=' + st.code : '')); return; }
    if (!st.quote) return;
    st.busy = true;
    payBtn.disabled = true;
    payBtn.textContent = 'Preparing your order…';
    say('');
    var body = { category: p.id };
    if (st.quote.couponCode) body.offerCode = st.quote.couponCode;
    S.api('POST', '/membership/order', body).then(function (r) {
      if (r.status === 401) { S.toSignIn('/plans?plan=' + p.id); return; }
      if (!r.ok) {
        var reason = r.json.reason || '';
        if (/COUPON/.test(reason)) { st.code = ''; codeInput.value = ''; codeSay(r.json.error || 'That code could not be used.', 'bad'); }
        fail(r.json.error || 'Could not start the payment. Try again.');
        if (/COUPON/.test(reason)) refreshQuote();
        return;
      }
      var o = r.json;
      saveReceiptEmail(o);
      if (o.isAlreadyActive) { st.busy = false; done(o.membership, o.message); return; }
      if (o.isFree) { st.busy = false; done(o.membership); return; }
      if (!o.orderId || !o.keyId || !(o.amountInPaise > 0)) { fail('Payments are not set up right now. Please try again later.'); return; }
      openCheckout(o);
    });
  });

  /* ---------- load ---------- */
  function loadMine() {
    if (!S.token()) { st.me = null; st.my = null; return Promise.resolve(); }
    return Promise.all([S.api('GET', '/me'), S.api('GET', '/membership/my')]).then(function (rs) {
      st.me = rs[0].ok ? rs[0].json : null;
      st.my = rs[0].ok && rs[1].ok ? rs[1].json : null;
    });
  }

  codeInput.value = st.code;
  Promise.all([
    S.api('GET', '/membership/catalog', undefined, { auth: false }),
    loadMine()
  ]).then(function (rs) {
    var cat = rs[0];
    try {
      if (!cat.ok) throw new Error('catalog');
      st.plans = plansFrom(cat.json);
      st.paymentsEnabled = cat.json.paymentsEnabled !== false;
    } catch (e) {
      S.clear(grid).appendChild(el('p', 'sh-msg', 'Plans could not load right now. Please refresh in a moment.'));
      grid.removeAttribute('aria-busy');
      grid.setAttribute('data-state', 'error');
      renderWho();
      return;
    }
    renderWho();
    renderPlans();
    var want = S.cleanPlan(S.query('plan'));
    var p = want ? planById(want) : null;
    if (p && !p.free && st.paymentsEnabled && !(st.me && blockedReason(p.id))) choose(p.id, true);
    else if (st.code && st.paymentsEnabled) {
      // A code from a link with no plan: point at the plans with a short line.
      var first = st.plans.filter(function (x) { return !x.free && !(st.me && blockedReason(x.id)); })[0];
      if (first) {
        var note = el('p', 'sh-codehint');
        note.appendChild(S.icon('i-check'));
        note.appendChild(el('span', null, 'Code ' + st.code + ' is ready. Choose a plan to see your price with it.'));
        grid.parentNode.insertBefore(note, grid);
      }
    }
  });
})();
