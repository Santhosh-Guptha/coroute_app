/* 3.57 /trip/<tripId>: the signed-in rider's own ride (GET /api/trips/:tripId; someone else's trip reads as
 * not found). Numbers only: no map, no positions, no other rider's data. textContent only. */
(function () {
  'use strict';
  var S = window.CoShop;
  if (!S || !S.$('tr')) return;
  var el = S.el;
  var m = /^\/trip\/([A-Za-z0-9_.:-]{3,120})\/?$/.exec(window.location.pathname);
  var id = m ? m[1] : '';
  var box = S.$('tr');
  var status = S.$('tr-status');
  function stop(t) { box.removeAttribute('aria-busy'); S.$('tr-title').textContent = 'Your ride'; status.textContent = t; }
  if (!id) { stop('This trip link is not complete. Open it again from the e-mail.'); return; }
  if (!S.token()) { S.toSignIn('/trip/' + id); return; }

  function km(v) { var n = Math.max(0, Number(v) || 0); return (n >= 100 ? Math.round(n) : Math.round(n * 10) / 10) + ' km'; }
  function dur(ms) { var mins = Math.max(0, Math.round((Number(ms) || 0) / 60000)); var h = Math.floor(mins / 60); return h ? h + ' h ' + (mins % 60) + ' min' : mins + ' min'; }
  function fact(dl, k, v) { if (!v) return; var d = el('div'); d.appendChild(el('dt', null, k)); d.appendChild(el('dd', null, v)); dl.appendChild(d); }

  S.api('GET', '/trips/' + encodeURIComponent(id)).then(function (r) {
    if (r.status === 401) { window.location.replace('/signin?expired=1&next=' + encodeURIComponent('/trip/' + id)); return; }
    if (r.status === 404) { stop('This ride is not on your account. Sign in with the account that rode it.'); return; }
    if (!r.ok || !r.json.trip) { stop(r.json.error || 'This ride could not be loaded. Refresh to try again.'); return; }
    var t = r.json.trip;
    box.removeAttribute('aria-busy');
    S.$('tr-title').textContent = String(t.tripName || 'Your ride').slice(0, 80);
    document.title = String(t.tripName || 'Your ride').slice(0, 60) + ' | Coroute';
    var dl = S.$('tr-facts');
    var start = Number(t.startTimeEpochMs) || 0, end = Number(t.endTimeEpochMs) || 0;
    fact(dl, 'Date', S.date(start || end));
    fact(dl, 'Distance', km(t.totalDistanceKm));
    fact(dl, 'Riding time', dur(Number(t.movingMs) > 0 ? t.movingMs : Math.max(0, end - start)));
    fact(dl, 'Stops', String(Math.max(0, Number(t.stopCount) || 0)));
    fact(dl, 'Riders', String(Math.max(1, Number(t.riderCount) || 1)));
    dl.hidden = false;
    S.$('tr-note').hidden = false;
  });
})();
