/* 3.56 /clubs: clubs I am in, club invites (accept / decline), the invite link (?code=) and leaving.
 * GET /api/clubs, POST /api/clubs/invites/:id/accept|decline, GET /api/public/clubs/:code, POST /api/clubs/join,
 * POST /api/clubs/:operatorId/leave (docs/features_355/operators.md). Text is written with textContent only. */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S || !S.$('cl-clubs')) return;
  var code = S.query('code');
  if (!/^[A-Za-z0-9]{10}$/.test(code)) code = '';

  function notice(text, kind) {
    var n = S.$('cl-notice');
    n.textContent = text || '';
    n.className = 'sh-notice' + (kind ? ' sh-notice--' + kind : '');
    n.hidden = !text;
  }
  function btn(label, cls, onClick) {
    var b = S.el('button', 'btn btn--sm ' + (cls || 'btn--secondary'), label);
    b.type = 'button';
    b.addEventListener('click', function () { b.disabled = true; Promise.resolve(onClick()).then(function () { b.disabled = false; }); });
    return b;
  }
  function item(name, meta, actions, more) {
    var row = S.el('div', 'op-item');
    var text = S.el('div');
    text.appendChild(S.el('div', 'op-item__name', name));
    text.appendChild(S.el('div', 'op-item__meta', meta));
    row.appendChild(text);
    var act = S.el('div', 'op-item__actions');
    (actions || []).forEach(function (a) { act.appendChild(a); });
    row.appendChild(act);
    if (more && more.childNodes.length) row.appendChild(more);
    return row;
  }

  function load() {
    return S.api('GET', '/clubs').then(function (r) {
      if (r.status === 401) { S.toSignIn('/clubs' + (code ? '?code=' + code : '')); return; }
      if (!r.ok) { notice(r.json.error || 'Could not load your clubs.', 'warn'); return; }
      var inv = S.clear(S.$('cl-invites'));
      if (!r.json.invites.length) inv.appendChild(S.el('p', 'op-empty', 'No club invites right now.'));
      r.json.invites.forEach(function (i) {
        inv.appendChild(item(i.name, i.typeLabel + ' · ' + i.city + ' · expires ' + S.date(i.expiresAt), [
          btn('Join', 'btn--primary', function () { return answer(i.inviteId, true); }),
          btn('Decline', 'btn--ghost', function () { return answer(i.inviteId, false); })
        ]));
      });
      var list = S.clear(S.$('cl-clubs'));
      if (!r.json.clubs.length) list.appendChild(S.el('p', 'op-empty', 'You are not in a club yet. Clubs invite you by username or with a link.'));
      r.json.clubs.forEach(function (c) {
        var more = S.el('div', 'op-item__more');
        c.upcoming.forEach(function (u) {
          var p = S.el('div');
          p.appendChild(S.el('b', '', u.title));
          p.appendChild(document.createTextNode(' · ' + S.dateTime(u.startsAt) + (u.meetName ? ' · ' + u.meetName : '')));
          if (u.publicUrl) { var a = S.el('a', 'link', ' Sign up'); a.href = u.publicUrl; p.appendChild(document.createTextNode(' ')); p.appendChild(a); }
          more.appendChild(p);
        });
        c.broadcasts.forEach(function (b) {
          var p = S.el('div');
          p.appendChild(S.el('b', '', b.title + ': '));
          p.appendChild(document.createTextNode(b.body + ' (' + S.date(b.at) + ')'));
          more.appendChild(p);
        });
        var actions = [];
        if (c.role === 'OWNER' || c.role === 'CO_ORGANISER') {
          var open = S.el('a', 'btn btn--sm btn--primary', 'Open console');
          open.href = '/operator';
          actions.push(open);
        }
        if (c.role !== 'OWNER') actions.push(btn('Leave', 'btn--ghost', function () { return leave(c); }));
        list.appendChild(item(c.name, c.typeLabel + ' · ' + c.city + ' · ' + c.members + ' riders · joined ' + S.date(c.joinedAt), actions, more));
      });
      S.$('cl-privacy').textContent = r.json.privacy || '';
    });
  }
  function answer(id, yes) {
    return S.api('POST', '/clubs/invites/' + id + '/' + (yes ? 'accept' : 'decline')).then(function (r) {
      notice(r.ok ? (yes ? 'You joined the club.' : 'Invite declined.') : (r.json.error || 'Could not answer.'), r.ok ? 'ok' : 'warn');
      return load();
    });
  }
  function leave(c) {
    if (!window.confirm('Leave ' + c.name + '? You stop getting its ride invites and messages.')) return null;
    return S.api('POST', '/clubs/' + c.operatorId + '/leave').then(function (r) {
      notice(r.ok ? 'You left ' + c.name + '.' : (r.json.error || 'Could not leave.'), r.ok ? 'ok' : 'warn');
      return load();
    });
  }
  function showJoin() {
    if (!code) return;
    S.api('GET', '/public/clubs/' + code, undefined, { auth: false }).then(function (r) {
      if (!r.ok) { notice(r.json.error || 'This club link does not work any more.', 'warn'); return; }
      var c = r.json.club;
      S.$('cl-join-name').textContent = c.name;
      S.$('cl-join-meta').textContent = c.typeLabel + ' · ' + c.city + ' · ' + c.members + ' riders';
      S.$('cl-join').hidden = false;
      S.$('cl-join-btn').addEventListener('click', function () {
        if (!S.token()) { S.toSignIn('/clubs?code=' + code); return; }
        S.api('POST', '/clubs/join', { code: code }).then(function (j) {
          if (j.status === 401) { S.toSignIn('/clubs?code=' + code); return; }
          S.$('cl-join').hidden = j.ok;
          notice(j.ok ? (j.json.status === 'ALREADY_MEMBER' ? 'You are already in ' + c.name + '.' : 'You joined ' + c.name + '.') : (j.json.error || 'Could not join.'), j.ok ? 'ok' : 'warn');
          if (j.ok) load();
        });
      });
    });
  }

  showJoin();
  if (!S.token()) {
    S.clear(S.$('cl-invites')).appendChild(S.el('p', 'op-empty', 'Sign in to see your club invites.'));
    var list = S.clear(S.$('cl-clubs'));
    var b = S.el('button', 'btn btn--primary', 'Sign in');
    b.type = 'button';
    b.addEventListener('click', function () { S.toSignIn('/clubs' + (code ? '?code=' + code : '')); });
    list.appendChild(b);
    return;
  }
  load();
})();
