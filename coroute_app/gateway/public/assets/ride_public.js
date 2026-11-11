/* 3.56 /rides/<slug>: public sign-up page of an operator ride. GET /api/public/rides/:slug; signed in:
 * GET /api/rides/:slug/me, POST/DELETE /api/rides/:slug/signup (docs/features_355/operators.md). */
(function () {
  'use strict';
  var S = window.CoShop;
  var intro = S && S.$('rp-intro');
  if (!intro) return;
  var slug = intro.getAttribute('data-slug') || '';
  if (!/^[a-z0-9-]{3,70}$/.test(slug)) return;
  var STATUS = { PENDING: ['Waiting for approval', 'warn'], APPROVED: ['You are in', 'ok'], REJECTED: ['Not approved', 'muted'], CANCELLED: ['Cancelled', 'muted'] };

  function notice(text, kind) {
    var n = S.$('rp-notice');
    n.textContent = text || '';
    n.className = 'sh-notice' + (kind ? ' sh-notice--' + kind : '');
    n.hidden = !text;
  }
  function fact(dl, k, v) {
    if (!v) return;
    var d = S.el('div');
    d.appendChild(S.el('dt', '', k));
    d.appendChild(S.el('dd', '', v));
    dl.appendChild(d);
  }
  function button(label, cls, fn) {
    var b = S.el('button', 'btn ' + cls, label);
    b.type = 'button';
    b.addEventListener('click', fn);
    return b;
  }
  function render(ride, me) {
    S.$('rp-card').removeAttribute('aria-busy');
    var dl = S.clear(S.$('rp-facts'));
    fact(dl, 'Starts', S.dateTime(ride.startsAt) + ' IST');
    fact(dl, 'Meet at', ride.meetName);
    fact(dl, 'Ride to', ride.destinationName);
    fact(dl, 'Run by', ride.operator.name + ' · ' + ride.operator.typeLabel + ', ' + ride.operator.city);
    S.$('rp-notes').textContent = ride.notes || '';
    S.$('rp-seats').textContent = String(ride.seatsLeft);
    S.$('rp-seats-of').textContent = 'of ' + ride.maxRiders + ' seats left' + (ride.requireApproval ? ' · the organiser approves sign-ups' : '');
    var badge = S.$('rp-badge');
    var st = me && me.status && STATUS[me.status];
    badge.hidden = !st;
    if (st) { badge.textContent = st[0]; badge.className = 'sh-badge sh-badge--' + st[1]; }
    var act = S.clear(S.$('rp-actions'));
    var text = '';
    if (ride.status === 'ENDED') text = 'This ride has ended.';
    else if (me && (me.status === 'PENDING' || me.status === 'APPROVED')) {
      text = me.status === 'PENDING' ? 'The organiser will approve or decline your sign-up.' : (ride.status === 'LIVE' ? '' : 'Your seat is held. The join code appears here when the ride starts.');
      act.appendChild(button('Cancel my sign-up', 'btn--ghost', cancel));
    } else if (me && me.status === 'REJECTED') text = 'The organiser did not approve your sign-up.';
    else if (!ride.signupOpen) text = ride.seatsLeft > 0 ? 'Sign-up is closed.' : 'This ride is full.';
    else if (!S.token()) act.appendChild(button('Sign in to sign up', 'btn--primary btn--lg btn--block', function () { S.toSignIn('/rides/' + slug); }));
    else act.appendChild(button(ride.requireApproval ? 'Ask to join' : 'Sign up', 'btn--primary btn--lg btn--block', signUp));
    S.$('rp-text').textContent = text;
    var join = me && me.join;
    S.$('rp-join').hidden = !join;
    if (join) { S.$('rp-code').textContent = join.code; S.$('rp-join-link').href = join.url; }
  }
  function load() {
    if (S.token()) {
      return S.api('GET', '/rides/' + slug + '/me').then(function (r) {
        if (r.ok) return render(r.json.ride, r.json);
        if (r.status === 401) return loadPublic();
        notice(r.json.error || 'Could not load this ride.', 'warn');
      });
    }
    return loadPublic();
  }
  function loadPublic() {
    return S.api('GET', '/public/rides/' + slug, undefined, { auth: false }).then(function (r) {
      if (!r.ok) { notice(r.json.error || 'This ride is not available.', 'warn'); S.$('rp-card').removeAttribute('aria-busy'); return; }
      render(r.json.ride, null);
    });
  }
  function signUp() {
    S.api('POST', '/rides/' + slug + '/signup').then(function (r) {
      if (r.status === 401) { S.toSignIn('/rides/' + slug); return; }
      notice(r.ok ? (r.json.status === 'APPROVED' ? 'You are signed up.' : 'Sign-up sent. The organiser will approve it.') : (r.json.error || 'Could not sign up.'), r.ok ? 'ok' : 'warn');
      load();
    });
  }
  function cancel() {
    S.api('DELETE', '/rides/' + slug + '/signup').then(function (r) {
      notice(r.ok ? 'Your sign-up is cancelled.' : (r.json.error || 'Could not cancel.'), r.ok ? 'ok' : 'warn');
      load();
    });
  }
  load();
})();
