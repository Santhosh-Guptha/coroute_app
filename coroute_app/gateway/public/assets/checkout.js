/* Payment page for an order created by an older CoRoute app (3.54 / 3.55): /checkout.html?order=&t=&e=
 * (t = the server's short HMAC over order id + expiry, 30 minutes). Loads GET /api/checkout/order/:id, opens
 * Razorpay Checkout in redirect mode; the server verifies at /api/razorpay/callback and sends the rider back
 * here with ?paid= or ?failed=. Moved out of checkout.html in 3.56 (strict CSP, no inline script). New plans
 * are bought on /plans (assets/plans.js). */
(function () {
  var q = new URLSearchParams(window.location.search);
  function el(id) { return document.getElementById(id); }
  function show(id) {
    ['co-loading', 'co-none', 'co-order', 'co-result'].forEach(function (x) { el(x).hidden = x !== id; });
  }
  function rupees(paise) {
    return 'Rs ' + (Number(paise || 0) / 100).toLocaleString('en-IN', { maximumFractionDigits: 2 });
  }
  function result(ok, title, detail) {
    el('co-result').className = 'co-card co-result ' + (ok ? 'is-ok' : 'is-bad');
    el('co-result-title').textContent = title;
    el('co-result-detail').textContent = detail;
    show('co-result');
  }
  function none(note) {
    if (note) { el('co-none-note').textContent = note; el('co-none-note').hidden = false; }
    show('co-none');
  }

  // Back from the Razorpay redirect: the server checked the signature before sending the rider here.
  if (q.get('paid')) {
    result(true, 'Payment verified',
      q.get('starts')
        ? 'Your payment was verified. Your new plan starts when your current plan ends.'
        : 'Your payment was verified. Your plan is active in the app.');
    history.replaceState(null, '', window.location.pathname);
    return;
  }
  if (q.get('failed')) {
    result(false, 'Payment not completed',
      String(q.get('failed')).slice(0, 200) + '. If money left your account, open the app: your plan activates once Razorpay confirms the payment. Otherwise start again in the app.');
    history.replaceState(null, '', window.location.pathname);
    return;
  }

  var orderId = q.get('order');
  var token = q.get('t');
  var expires = q.get('e');
  if (!orderId || !token || !expires) { none(''); return; }

  show('co-loading');
  var order = null;
  fetch('/api/checkout/order/' + encodeURIComponent(orderId) + '?t=' + encodeURIComponent(token) + '&e=' + encodeURIComponent(expires), { credentials: 'omit' })
    .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { ok: r.ok, j: j }; }); })
    .then(function (res) {
      if (!res.ok) { none(res.j.error || 'This payment link is not valid.'); return; }
      order = res.j;
      if (order.status === 'PAID') {
        result(true, 'Already paid', 'This order is already paid. Your plan is active in the app.');
        return;
      }
      el('co-plan').textContent = order.planLabel || order.planTier;
      el('co-cycle').textContent = order.billingCycle === 'annual' ? 'Yearly' : 'Monthly';
      el('co-amount').textContent = rupees(order.amount);
      var p = order.prefill || {};
      if (p.name || p.email) {
        el('co-payer').textContent = [p.name, p.email].filter(Boolean).join(', ');
        el('co-payer-row').hidden = false;
      }
      if (order.expiresAt) {
        el('co-expiry').textContent = 'This link works until ' + new Date(order.expiresAt).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' }) + '.';
      }
      el('co-pay').textContent = 'Pay ' + rupees(order.amount) + ' by UPI';
      show('co-order');
    })
    .catch(function () { none('Could not load your order. Check your connection and try again.'); });

  function status(text, bad) {
    el('co-status').textContent = text;
    el('co-status').className = 'co-status' + (bad ? ' is-bad' : '');
  }

  // Razorpay Checkout is loaded only when the rider presses Pay.
  function withRazorpay(done) {
    if (window.Razorpay) return done();
    var s = document.createElement('script');
    s.src = 'https://checkout.razorpay.com/v1/checkout.js';
    s.onload = done;
    s.onerror = function () { status('Could not load Razorpay. Check your connection and try again.', true); el('co-pay').disabled = false; };
    document.head.appendChild(s);
  }

  el('co-pay').addEventListener('click', function () {
    if (!order) return;
    if (order.expiresAt && Date.now() > order.expiresAt) { none('This link has expired. Start again in the app.'); return; }
    el('co-pay').disabled = true;
    status('Opening Razorpay...');
    withRazorpay(function () {
      var p = order.prefill || {};
      var options = {
        key: order.key_id,
        amount: order.amount,
        currency: order.currency || 'INR',
        name: order.merchantName || 'CoRoute',
        description: order.planLabel || order.planTier,
        order_id: order.order_id,
        prefill: { name: p.name || '', email: p.email || '', contact: p.contact || '' },
        method: { upi: true, card: false, netbanking: false, wallet: false, emi: false, paylater: false },
        config: { display: { blocks: { upi: { name: 'Pay by UPI', instruments: [{ method: 'upi' }] } }, sequence: ['block.upi'], preferences: { show_default_blocks: false } } },
        theme: { color: '#2B7A8C' },
        // The result is posted to the server, verified there, and the rider comes back here with ?paid= or ?failed=.
        redirect: true,
        callback_url: window.location.origin + '/api/razorpay/callback',
        modal: { ondismiss: function () { status('Payment cancelled. You can try again.', true); el('co-pay').disabled = false; } }
      };
      try {
        new window.Razorpay(options).open();
      } catch (e) {
        status('Could not open Razorpay. Try again.', true);
        el('co-pay').disabled = false;
      }
    });
  });
})();
