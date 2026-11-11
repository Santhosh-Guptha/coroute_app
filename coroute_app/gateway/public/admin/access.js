/* CoRoute web admin: Plans & pricing > "Access mode" (3.56, src/access_mode.js, docs/features_355/access_modes.md).
   Paid (a group plan to host group rides) / Free for everyone / Free up to limits, with an optional
   scheduled change in India time. Saved server-side with a version, a reason and the audit log; the
   app gets only its resulting capabilities (never prices) and refreshes within seconds. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var MODE_LABELS = { paid: 'Paid: hosting group rides needs a group plan', free: 'Free for everyone: every rider gets every group feature', hybrid: 'Free up to limits: free hosting within limits, a plan beyond them' };
  var SHORT = { paid: 'Paid', free: 'Free for everyone', hybrid: 'Free up to limits' };

  CR.accessModeCard = function () {
    var box = h('div.card', ui.loading());
    function load() { api('GET', '/admin/access-mode').then(render).catch(function (e) { clear(box).appendChild(ui.error(e)); }); }

    function render(v) {
      clear(box);
      var s = v.stored || {};
      var eff = v.effective || {};
      var mode = CR.ui.select(['paid', 'free', 'hybrid'].map(function (m) { return [m, MODE_LABELS[m]]; }), s.mode || 'paid');
      var freeMax = h('input', { type: 'number', min: '2', max: '1000', step: '1', value: String((s.free && s.free.maxRiders) || 12) });
      var hyMax = h('input', { type: 'number', min: '2', max: '1000', step: '1', value: String((s.hybrid && s.hybrid.maxRiders) || 6) });
      var hyRides = h('input', { type: 'number', min: '0', max: '1000', step: '1', value: String(s.hybrid ? s.hybrid.maxHostedRidesPerMonth : 8) });
      var featBoxes = h('div.stack');
      var free = (s.hybrid && s.hybrid.freeFeatures) || [];
      (v.features || []).forEach(function (f) {
        featBoxes.appendChild(h('label.check', h('input', { type: 'checkbox', value: f.id, checked: free.indexOf(f.id) >= 0 }), f.label));
      });
      var schedOn = h('input', { type: 'checkbox', checked: !!v.schedule });
      var schedMode = CR.ui.select(['paid', 'free', 'hybrid'].map(function (m) { return [m, SHORT[m]]; }), v.schedule ? v.schedule.mode : 'paid');
      var schedAt = h('input', { type: 'datetime-local', value: v.schedule ? CR.util.toLocalInput(v.schedule.at) : '' });
      var reason = h('input', { type: 'text', maxlength: '200', placeholder: 'Launch month: free for everyone' });
      var freeBox = h('div.stack', CR.ui.field('Riders per group ride', freeMax, 'host included; paid plans with more seats keep them'));
      var hyBox = h('div.stack',
        h('div.grid2', CR.ui.field('Riders per free group ride', hyMax, 'host included'), CR.ui.field('Free group rides per month', hyRides, 'per host, India calendar month')),
        h('div.field', h('span', 'Group features included for free'), featBoxes, h('small', { text: 'Safety features (SOS, crash alerts, missing-rider check, buddy pairs) are never limited.' })));
      var schedBox = h('div.grid2', CR.ui.field('Then switch to', schedMode), CR.ui.field('At (India time)', schedAt));
      function layout() { freeBox.hidden = mode.value !== 'free'; hyBox.hidden = mode.value !== 'hybrid'; schedBox.hidden = !schedOn.checked; }
      [mode, schedOn].forEach(function (x) { x.addEventListener('change', layout); });

      var save = h('button.btn.btn--primary', { type: 'button', text: 'Save access mode', onclick: function () {
        var body = { mode: mode.value, expectedVersion: v.version, reason: reason.value,
          free: { maxRiders: Number(freeMax.value) },
          hybrid: { maxRiders: Number(hyMax.value), maxHostedRidesPerMonth: Number(hyRides.value),
            freeFeatures: Array.prototype.slice.call(featBoxes.querySelectorAll('input:checked')).map(function (x) { return x.value; }) },
          schedule: schedOn.checked ? { mode: schedMode.value, atIst: schedAt.value } : null };
        var msg = 'Riders get "' + SHORT[body.mode] + '" now' + (body.schedule ? ', then "' + SHORT[body.schedule.mode] + '" at ' + (schedAt.value || '?').replace('T', ' ') + ' IST' : '') + '. Connected apps update within seconds. Paid plans keep running; nothing is refunded.';
        ui.confirm('Change access mode?', msg, 'Save').then(function (ok) {
          if (!ok) return;
          save.disabled = true;
          api('PUT', '/admin/access-mode', body).then(function (nv) { ui.toast('Access mode saved (version ' + nv.version + ').'); render(nv); })
            .catch(function (e) { ui.toast(e.message, true); if (e.code === 'VERSION_CONFLICT') load(); }).then(function () { save.disabled = false; });
        });
      } });

      var now = 'Now: ' + (SHORT[eff.mode] || eff.mode) + (eff.scheduleApplied ? ' (scheduled change reached)' : '') + (v.schedule ? ' · changes to ' + SHORT[v.schedule.mode] + ' on ' + v.schedule.atIst : '');
      var hist = h('tbody');
      (v.history || []).forEach(function (e) {
        var a = e.after || {};
        hist.appendChild(h('tr', h('td', { text: 'v' + e.version }), h('td', { text: CR.util.date(e.at, true) }), h('td', { text: e.by || '' }),
          h('td', { text: (SHORT[(e.before || {}).mode] || '-') + ' → ' + (SHORT[a.mode] || a.mode) + (a.schedule ? ' (then ' + SHORT[a.schedule.mode] + ')' : '') }), h('td', { text: e.reason || '' })));
      });
      box.appendChild(h('div.card__head', h('h3', { text: 'Access mode' }), h('span.spacer'), ui.chip(SHORT[eff.mode] || eff.mode, eff.mode === 'paid' ? 'info' : 'ok')));
      box.appendChild(h('div.stack',
        h('p.muted.small', { text: now + (v.paymentsEnabled === false ? ' · Payments are switched off on this server (PAYMENTS_ENABLED=false): everything is free regardless.' : '') }),
        h('p.muted.small', { text: 'The app never shows prices or plans for this: it only learns what a rider may host (riders per ride, group features) and shows neutral words like "This ride is full."' }),
        CR.ui.field('Mode', mode), freeBox, hyBox,
        h('label.check', schedOn, 'Schedule a change (for example: a free launch period that ends on a date)'), schedBox,
        CR.ui.field('Reason', reason, 'kept in the history and the audit log'),
        h('div.row.row--end', save),
        (v.history || []).length ? h('details', h('summary', { text: 'History (version ' + v.version + ')' }),
          h('div.table-wrap', h('table.table', h('thead', h('tr', ['Version', 'When', 'By', 'Change', 'Reason'].map(function (c) { return h('th', { text: c }); }))), hist))) : null));
      layout();
    }
    load();
    return box;
  };
})();
