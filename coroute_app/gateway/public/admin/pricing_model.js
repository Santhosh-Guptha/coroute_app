/* CoRoute web admin: Pricing model (v3.63, src/pricing_model.js).
   Choose what riders can buy: Group plans (today: Community free + Small Group + Large Group, bought by the host) or
   Rider Pass (Community free + one monthly pass per rider with every feature; any number of riders can join rides).
   Switching never cancels or refunds a running plan: only what can be bought changes. MASTER_ADMIN; audited.
   Prices are edited in Plans & pricing (the Rider Pass list price starts at Rs 9). Text is always set as text. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;

  var INFO = {
    group_plans: { title: 'Group plans', lines: ['Community: free, solo rides, every safety feature', 'Small Group: the host pays, up to 6 riders', 'Large Group: the host pays, up to 12 riders', 'Joining a ride is free'] },
    rider_pass: { title: 'Rider Pass', lines: ['Community: free, solo rides, every safety feature', 'Rider Pass: each rider pays monthly (list price starts at Rs 9) and gets every feature', 'A Rider Pass holder hosts rides that any number of riders can join', 'Joining a ride is free'] },
  };

  function render(view) {
    view.appendChild(h('div.cc-hero', h('div', h('p.cc-eyebrow', { text: 'Configuration' }), h('h1', { text: 'Pricing model' }),
      h('p.muted', { text: 'What riders can buy on the website. Safety is free in both. Switching never cancels or refunds a running plan.' }))));
    var body = h('div', ui.loading());
    view.appendChild(body);
    function load() {
      api('GET', '/admin/pricing-model').then(function (r) {
        clear(body);
        var grid = h('div.pm-grid');
        r.models.forEach(function (m) {
          var on = r.model === m.id;
          var info = INFO[m.id] || { title: m.label, lines: [] };
          var ul = h('ul.pm-list');
          info.lines.forEach(function (l) { ul.appendChild(h('li', { text: l })); });
          var btn = h('button.btn' + (on ? '' : '.btn--primary'), { type: 'button', text: on ? 'In use' : 'Use this model', disabled: on });
          btn.addEventListener('click', function () {
            ui.confirm('Switch to ' + info.title + '?', 'The website sells ' + (m.id === 'rider_pass' ? 'only the Rider Pass' : 'only Small Group and Large Group') + ' from now on. Plans riders already paid for keep working until they end.', 'Switch', false)
              .then(function (ok) {
                if (!ok) return;
                btn.disabled = true;
                api('PUT', '/admin/pricing-model', { model: m.id }).then(function () { ui.toast('Pricing model: ' + info.title + '. The website follows within a minute.'); load(); })
                  .catch(function (e) { btn.disabled = false; ui.toast(e.message, true); });
              });
          });
          grid.appendChild(h('section.card.pm-card' + (on ? '.is-on' : ''), h('div.cc-card__head', h('h2', { text: info.title }), on ? ui.chip('In use', 'ok') : null), ul, h('div.row', btn)));
        });
        body.appendChild(grid);
        body.appendChild(h('p.muted.small.section-gap', { text: 'Prices and offers: Plans & pricing. Which plan includes communities and chat: Features by plan (Rider Pass has its own column, all on by default).' }));
        if (r.updatedAt) body.appendChild(h('p.muted.small', { text: 'Last changed ' + new Date(r.updatedAt).toLocaleString() + ' by ' + (r.updatedBy || 'admin') + '.' }));
      }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
    }
    load();
  }

  CR.sections.pricingmodel = { title: 'Pricing model', render: render };
})();
