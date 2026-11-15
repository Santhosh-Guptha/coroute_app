/* CoRoute web admin: Features by plan (v3.60, src/plans.js, docs/features_355/communities_chat_v360.md).
   One matrix: for Community (free), Small Group and Large Group, which community and chat features are included,
   and a few limits. Safety (SOS, crash alarm, emergency texts, Medical ID, guardians, ride lock) is never listed:
   it is free for every rider. A feature switched off in Feature switches stays off for everyone, whatever the plan.
   MASTER_ADMIN only; every save is audited server side. Text is always set as text. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear;
  var api = CR.api, ui = CR.ui;

  function render(view) {
    clear(view);
    view.appendChild(ui.pageHead('Features by plan', 'What each plan includes in communities and chat, and its limits. Safety features are free for every rider and are not listed here.'));
    var body = h('div', ui.loading());
    view.appendChild(body);
    api('GET', '/admin/plan-features').then(function (r) {
      clear(body);
      var cfg = JSON.parse(JSON.stringify(r.plans));
      var head = h('tr', h('th', { text: 'Feature' }));
      r.planIds.forEach(function (p) { head.appendChild(h('th.num', { text: r.planNames[p] })); });
      var tb = h('tbody');
      r.features.forEach(function (f) {
        var row = h('tr', h('td', h('strong', { text: f.label }), h('div.muted.small', { text: f.desc })));
        r.planIds.forEach(function (p) {
          var box = h('input', { type: 'checkbox', 'aria-label': f.label + ' in ' + r.planNames[p] });
          box.checked = cfg[p].features[f.id] !== false;
          box.addEventListener('change', function () { cfg[p].features[f.id] = box.checked; });
          row.appendChild(h('td.num', box));
        });
        tb.appendChild(row);
      });
      r.limits.forEach(function (l) {
        var row = h('tr', h('td', h('strong', { text: l.label }), h('div.muted.small', { text: l.min + ' to ' + l.max })));
        r.planIds.forEach(function (p) {
          var inp = h('input', { type: 'number', min: String(l.min), max: String(l.max), step: '1', style: 'width:6em', 'aria-label': l.label + ' for ' + r.planNames[p] });
          inp.value = String(cfg[p].limits[l.id]);
          inp.addEventListener('change', function () { cfg[p].limits[l.id] = Math.round(Number(inp.value)); });
          row.appendChild(h('td.num', inp));
        });
        tb.appendChild(row);
      });
      body.appendChild(h('div.table-wrap', h('table.table', h('thead', head), tb)));
      body.appendChild(h('p.muted.small', { text: 'Ride seats come from the plan (Small Group 6, Large Group 12) and are not changed here. When payments are off, every rider gets the Large Group column.' }));
      body.appendChild(h('div.row', h('button.btn.btn--primary', { type: 'button', text: 'Save', onclick: function () {
        api('PUT', '/admin/plan-features', { plans: cfg }).then(function () { ui.toast('Saved. Riders get it within a minute.'); render(view); })
          .catch(function (e) { ui.toast(e.message, true); });
      } })));
    }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
  }

  CR.sections.planfeatures = { title: 'Features by plan', render: render };
})();
