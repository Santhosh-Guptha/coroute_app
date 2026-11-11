/* 3.56 /operators/apply: a signed-in rider applies for the operator console (docs/features_355/operators.md).
 * GET /api/operators/application, POST /api/operators/apply. Text is written with textContent only. */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S) return;
  var card = S.$('op-card');
  if (!card) return;
  var STATUS = {
    PENDING: ['Waiting for review', 'warn', 'The CoRoute team is reviewing your application. We reply to your business e-mail.'],
    APPROVED: ['Approved', 'ok', 'Your operator console is ready. Sign in there with this account.'],
    REJECTED: ['Not approved', 'muted', 'You can correct the details and apply again.'],
    SUSPENDED: ['Suspended', 'warn', 'Your operator account is suspended. Contact the CoRoute team.'],
    EXPIRED: ['Expired', 'muted', 'Your operator account has expired. Contact the CoRoute team to extend it.']
  };

  function notice(text, kind) {
    var n = S.$('op-notice');
    n.textContent = text || '';
    n.className = 'sh-notice' + (kind ? ' sh-notice--' + kind : '');
    n.hidden = !text;
  }
  function show(id) {
    ['op-signin', 'op-status', 'op-form'].forEach(function (x) { S.$(x).hidden = x !== id; });
    card.removeAttribute('aria-busy');
  }
  function fact(dl, k, v) {
    if (!v) return;
    var d = S.el('div');
    d.appendChild(S.el('dt', '', k));
    d.appendChild(S.el('dd', '', v));
    dl.appendChild(d);
  }

  function renderStatus(a) {
    var st = STATUS[a.status] || [a.status, 'muted', ''];
    S.$('op-status-name').textContent = a.name;
    var b = S.$('op-status-badge');
    b.textContent = st[0];
    b.className = 'sh-badge sh-badge--' + st[1];
    var dl = S.clear(S.$('op-status-facts'));
    fact(dl, 'Type', a.typeLabel);
    fact(dl, 'City', a.city);
    fact(dl, 'Sent', S.date(a.createdAt));
    if (a.validUntil && a.status === 'APPROVED') fact(dl, 'Valid until', S.date(a.validUntil));
    if (a.reason) fact(dl, 'Reason', a.reason);
    S.$('op-status-text').textContent = st[2];
    var act = S.clear(S.$('op-status-actions'));
    if (a.status === 'APPROVED' || a.status === 'EXPIRED') {
      var l = S.el('a', 'btn btn--primary', 'Open the operator console');
      l.href = '/operator';
      act.appendChild(l);
    }
    if (a.status === 'REJECTED') {
      var again = S.el('button', 'btn btn--primary', 'Apply again');
      again.type = 'button';
      again.addEventListener('click', function () { fill(a); show('op-form'); });
      act.appendChild(again);
    }
    show('op-status');
  }

  function fill(a) {
    S.$('op-type').value = a.type || '';
    S.$('op-name').value = a.name || '';
    S.$('op-city').value = a.city || '';
    S.$('op-riders').value = a.expectedRiders || '';
    S.$('op-email').value = (a.contact && a.contact.email) || '';
    S.$('op-phone').value = (a.contact && a.contact.phone) || '';
    S.$('op-web').value = a.website || '';
    S.$('op-desc').value = a.description || '';
    S.$('op-desc-n').textContent = String((a.description || '').length);
  }

  function errors(fields) {
    document.querySelectorAll('[data-err]').forEach(function (n) { n.textContent = (fields && fields[n.getAttribute('data-err')]) || ''; });
  }

  S.$('op-desc').addEventListener('input', function () { S.$('op-desc-n').textContent = String(this.value.length); });
  S.$('op-signin-btn').addEventListener('click', function () { S.toSignIn('/operators/apply'); });

  S.$('op-form').addEventListener('submit', function (e) {
    e.preventDefault();
    var btn = S.$('op-submit');
    var body = {
      type: S.$('op-type').value, name: S.$('op-name').value, city: S.$('op-city').value,
      expectedRiders: Number(S.$('op-riders').value), email: S.$('op-email').value, phone: S.$('op-phone').value,
      website: S.$('op-web').value, description: S.$('op-desc').value
    };
    errors(null);
    S.$('op-form-status').textContent = '';
    btn.disabled = true; btn.textContent = 'Sending…';
    S.api('POST', '/operators/apply', body).then(function (r) {
      btn.disabled = false; btn.textContent = 'Send application';
      if (r.status === 401) { S.toSignIn('/operators/apply'); return; }
      if (!r.ok) {
        errors(r.json.fields);
        S.$('op-form-status').textContent = r.json.error || 'Could not send. Try again.';
        return;
      }
      notice('Application sent. We will reply to your business e-mail.', 'ok');
      renderStatus(r.json.application);
    });
  });

  if (!S.token()) { show('op-signin'); return; }
  S.api('GET', '/operators/application').then(function (r) {
    if (r.status === 401) { show('op-signin'); return; }
    if (r.status === 403) { notice('Operator applications are closed for now.', 'warn'); card.removeAttribute('aria-busy'); return; }
    if (!r.ok) { notice(r.json.error || 'Could not load. Try again.', 'warn'); card.removeAttribute('aria-busy'); return; }
    if (r.json.coOrganiserOf && r.json.coOrganiserOf.length && !r.json.application) {
      notice('You are a co-organiser of ' + r.json.coOrganiserOf.map(function (o) { return o.name; }).join(', ') + '. Open the operator console at /operator.', 'ok');
    }
    if (r.json.application) renderStatus(r.json.application); else show('op-form');
  });
})();
