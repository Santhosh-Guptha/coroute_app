/* 3.56 /receipt?order=<orderId>: one printable receipt for a paid order of the signed-in rider
 * (GET /api/web/receipt/:orderId; someone else's order reads as not found). textContent only. */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S || !S.$('rc')) return;
  var el = S.el;
  var id = S.query('order');
  if (!S.token()) { S.toSignIn('/receipt' + (/^[A-Za-z0-9_.:-]{4,80}$/.test(id) ? '?order=' + id : '')); return; }
  var status = S.$('rc-status');
  var box = S.$('rc');
  function stop(t) { box.removeAttribute('aria-busy'); status.textContent = t; }
  if (!/^[A-Za-z0-9_.:-]{4,80}$/.test(id)) { stop('This receipt link is not complete. Open it again from your account.'); return; }

  var METHODS = { RAZORPAY: 'Razorpay', UPI: 'UPI', CARD: 'Card', NETBANKING: 'Net banking', WALLET: 'Wallet', COUPON: 'Coupon (nothing to pay)', CREDIT: 'Credit from your previous plan', ADMIN: 'Given by CoRoute' };

  S.api('GET', '/web/receipt/' + encodeURIComponent(id)).then(function (r) {
    if (r.status === 401) { window.location.replace('/signin?expired=1&next=' + encodeURIComponent('/receipt?order=' + id)); return; }
    if (!r.ok || !r.json.receipt) { stop(r.json.error || 'This receipt could not be loaded.'); return; }
    var x = r.json.receipt;
    box.removeAttribute('aria-busy');
    S.$('rc-seller').textContent = x.seller.name || 'CoRoute';
    S.$('rc-site').textContent = [String(x.seller.site || '').replace(/^https?:\/\//, ''), x.seller.supportEmail].filter(Boolean).join(' · ');
    S.$('rc-no').textContent = 'No. ' + x.receiptNo;
    var to = S.$('rc-to');
    to.appendChild(el('b', null, x.billedTo.name || (x.billedTo.username ? '@' + x.billedTo.username : 'CoRoute rider')));
    if (x.billedTo.username && x.billedTo.name) { to.appendChild(document.createElement('br')); to.appendChild(document.createTextNode('@' + x.billedTo.username)); }
    if (x.billedTo.email) { to.appendChild(document.createElement('br')); to.appendChild(document.createTextNode(x.billedTo.email)); }
    S.$('rc-paid').textContent = S.dateTime(x.paidAt || x.createdAt);

    var dl = S.$('rc-lines');
    (x.lines || []).forEach(function (l, i, all) {
      var last = i === all.length - 1;
      var row = el('div', 'sh-bill__row' + (last ? ' sh-bill__row--total' : '') + (!last && Number(l.amountInr) < 0 ? ' sh-bill__row--minus' : ''));
      row.appendChild(el('dt', null, last ? 'Total paid' : l.label));
      row.appendChild(el('dd', null, S.inr(last ? x.amountInr : l.amountInr)));
      dl.appendChild(row);
    });
    var facts = S.$('rc-facts');
    var fact = function (k, v) { if (!v) return; var d = el('div'); d.appendChild(el('dt', null, k)); d.appendChild(el('dd', null, v)); facts.appendChild(d); };
    fact('Plan', x.planName + (x.seats ? ', up to ' + x.seats + ' riders' : ''));
    if (x.periodStartsAt && x.periodEndsAt) fact('Period', S.date(x.periodStartsAt) + ' to ' + S.date(x.periodEndsAt));
    fact('Paid with', METHODS[String(x.method || '').toUpperCase()] || String(x.method || ''));
    if (x.offerLabel) fact('Offer', x.offerLabel + (x.listPriceInr ? ' (list price ' + S.inr(x.listPriceInr) + ')' : ''));
    if (x.couponCode) fact('Code', x.couponCode);
    fact('Payment id', x.paymentId);
    fact('Order id', x.orderId !== x.receiptNo ? x.orderId : '');
    if (x.refundedInr > 0 || x.refundStatus) fact('Refund', (x.refundedInr > 0 ? S.inr(x.refundedInr) + ' ' : '') + (x.refundStatus === 'PROCESSED' ? 'refunded' : 'refund ' + String(x.refundStatus || '').toLowerCase()));
    S.$('rc-foot').textContent = 'Amounts in Indian rupees. This plan does not renew on its own. Keep this receipt for your records.';
    S.$('rc-body').hidden = false;
    var pb = S.$('rc-print');
    pb.disabled = false;
    pb.addEventListener('click', function () { window.print(); });
  });
})();
