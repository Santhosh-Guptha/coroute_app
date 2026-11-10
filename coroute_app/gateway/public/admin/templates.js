/* CoRoute web admin: "Templates" (3.56). Edit message templates with {{variables}} and a live preview:
   purchase receipt / refund e-mails, SOS / safe-now SMS (DLT: variables fixed, re-registration warning),
   plan push notices (Play-neutral) and the guardian arrival message. Saved on the server with versions;
   "Reset to default" stores the defaults as a new version. API: /api/admin/templates (CR.api). */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var CHANNEL = { email: 'E-mail', sms: 'SMS', push: 'Push', webpush: 'Guardian browser' };

  function smsParts(text) {
    var gsm = /^[\x20-\x7e\n£¥èéùìòÇØøÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ¤¡ÄÖÑÜ§¿äöñüà]*$/.test(text);
    var n = text.length;
    if (gsm) return n <= 160 ? 1 : Math.ceil(n / 153);
    return n <= 70 ? 1 : Math.ceil(n / 67);
  }

  function editor(view, t, onSaved) {
    var inputs = {};
    var last = null;
    var problems = h('div.stack');
    var preview = h('div.tp-preview');
    var form = h('div.stack');
    Object.keys(t.fields).forEach(function (k) {
      var spec = t.fields[k];
      var el = spec.multiline ? h('textarea', { rows: k === 'text' ? '4' : '3', maxlength: String(spec.max) }) : h('input', { type: 'text', maxlength: String(spec.max) });
      el.value = t.current[k] || '';
      el.addEventListener('focus', function () { last = el; });
      el.addEventListener('input', schedule);
      inputs[k] = el;
      form.appendChild(CR.ui.field(spec.label, el, 'up to ' + spec.max));
    });
    var vars = h('div.row');
    t.variables.concat((t.constants || []).map(function (c) { return { name: c, description: 'fixed (site address)' }; })).forEach(function (v) {
      vars.appendChild(h('button.btn.btn--ghost.btn--sm', { type: 'button', title: v.description || '', text: '{{' + v.name + '}}', onclick: function () {
        var el = last || inputs[Object.keys(inputs)[0]];
        var s = el.selectionStart || el.value.length, e = el.selectionEnd || el.value.length;
        el.value = el.value.slice(0, s) + '{{' + v.name + '}}' + el.value.slice(e);
        el.focus(); el.selectionStart = el.selectionEnd = s + v.name.length + 4;
        schedule();
      } }));
    });
    if (!t.variables.length && !(t.constants || []).length) vars.appendChild(h('span.small.muted', { text: 'This template has no variables.' }));

    function fields() { var o = {}; Object.keys(inputs).forEach(function (k) { o[k] = inputs[k].value; }); return o; }
    var timer = null;
    function schedule() { clearTimeout(timer); timer = setTimeout(refresh, 350); }
    function refresh() {
      api('POST', '/admin/templates/' + encodeURIComponent(t.id) + '/preview', { fields: fields() }).then(function (r) {
        clear(problems);
        r.errors.forEach(function (e) { problems.appendChild(h('div.banner.banner--bad', { role: 'alert', text: e })); });
        r.warnings.forEach(function (w) { problems.appendChild(h('div.banner.banner--info', { text: w })); });
        drawPreview(r.rendered);
        save.disabled = r.errors.length > 0;
      }).catch(function (e) { clear(problems).appendChild(ui.error(e)); });
    }
    function drawPreview(r) {
      clear(preview);
      if (t.channel === 'email') {
        preview.appendChild(h('div.tp-mail',
          h('div.tp-mail__subject', h('span.muted', { text: 'Subject: ' }), r.subject),
          h('div.tp-mail__brand', { text: 'CoRoute' }), h('div.tp-mail__heading', { text: r.heading }), h('p', { text: r.intro }),
          h('div.tp-mail__lines', { text: '(Plan, list price, offer, coupon, credit and amount lines are added here by the server.)' }),
          h('p.small.muted', { text: r.footer })));
      } else if (t.channel === 'sms') {
        preview.appendChild(h('div.tp-sms', { text: r.text }));
        preview.appendChild(h('div.small.muted', { text: r.text.length + ' characters, ' + smsParts(r.text) + ' SMS part(s). Sample values shown.' }));
      } else {
        var card = h('div.np-card.np-card--light', h('div.np-card__top', h('span.np-card__icon'), h('span', { text: t.channel === 'webpush' ? 'Browser · now' : 'CoRoute · now' })),
          h('div.np-card__title', { text: r.title }), h('div.np-card__body', { text: r.body }));
        preview.appendChild(card);
      }
    }
    var save = h('button.btn.btn--primary', { type: 'button', text: 'Save new version' });
    save.addEventListener('click', function () {
      var go = function () {
        save.disabled = true;
        api('PUT', '/admin/templates/' + encodeURIComponent(t.id), { fields: fields() }).then(function (r) {
          ui.toast('Saved version ' + r.version + '.' + (r.warnings && r.warnings.length ? ' ' + r.warnings[0] : ''));
          onSaved();
        }).catch(function (e) { ui.toast(e.message, true); save.disabled = false; });
      };
      if (t.dlt) ui.confirm('DLT template', 'Operators deliver only SMS that match the registered DLT template exactly. Save only after this exact text is registered (and its template id is set in Notifications > SMS).', 'Save').then(function (ok) { if (ok) go(); });
      else go();
    });
    var reset = h('button.btn.btn--ghost', { type: 'button', text: 'Reset to default' });
    reset.addEventListener('click', function () {
      ui.confirm('Reset template', 'Store the default text of "' + t.label + '" as a new version?', 'Reset', true).then(function (ok) {
        if (ok) api('POST', '/admin/templates/' + encodeURIComponent(t.id) + '/reset').then(function () { ui.toast('Reset to default.'); onSaved(); }).catch(function (e) { ui.toast(e.message, true); });
      });
    });
    var hist = h('button.btn.btn--ghost', { type: 'button', text: 'History' });
    hist.addEventListener('click', function () {
      api('GET', '/admin/templates/' + encodeURIComponent(t.id) + '/history').then(function (r) {
        var list = h('div.stack');
        if (!r.history.length) list.appendChild(h('p.muted', { text: 'Only the default text so far.' }));
        r.history.forEach(function (v) {
          list.appendChild(h('div.card', h('div.row.row--between', h('b', { text: 'Version ' + v.version + (v.reset ? ' (reset)' : '') }), h('span.small.muted', { text: CR.util.date(v.updatedAt, true) + ' · ' + (v.updatedBy || '') })),
            Object.keys(v.fields).map(function (k) { return h('div.small', h('span.muted', { text: k + ': ' }), v.fields[k]); }),
            h('div.row.row--end', h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Load into editor', onclick: function () {
              Object.keys(inputs).forEach(function (k) { if (v.fields[k] !== undefined) inputs[k].value = v.fields[k]; });
              document.querySelectorAll('.scrim').forEach(function (s) { s.remove(); });
              refresh();
            } }))));
        });
        ui.dialog({ title: 'History: ' + t.label, body: list, wide: true });
      }).catch(function (e) { ui.toast(e.message, true); });
    });

    clear(view);
    view.appendChild(ui.pageHead(t.label, t.description, h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'All templates', onclick: function () { CR.go('#/templates'); } })));
    if (t.warning) view.appendChild(h('div.banner.banner--info', { text: t.warning }));
    if (t.playNeutral) view.appendChild(h('div.banner.banner--info', { text: 'Reaches the Play app: no prices, buying, renew, upgrade or offer words, no links.' }));
    view.appendChild(h('div.grid2.section-gap',
      h('div.card.stack', form, h('div.field', h('span', 'Variables (click to insert)'), vars), problems, h('div.row.row--end', hist, reset, save)),
      h('div.card', h('div.card__head', h('h3', { text: 'Preview' }), h('p', { text: 'With sample values. Version ' + t.version + (t.isDefault ? ' (default text)' : '') })), preview)));
    refresh();
  }

  CR.sections.templates = {
    title: 'Templates',
    render: function (view, arg) {
      view.appendChild(ui.loading());
      api('GET', '/admin/templates').then(function (r) {
        var pick = arg && r.templates.filter(function (x) { return x.id === arg; })[0];
        if (pick) return editor(view, pick, function () { CR.go('#/templates/' + pick.id); });
        clear(view);
        view.appendChild(ui.pageHead('Templates', 'Message templates with variables. Saved with versions; reset any time.'));
        var tb = h('tbody');
        r.templates.forEach(function (t) {
          tb.appendChild(h('tr',
            h('td', h('a', { href: '#/templates/' + t.id, text: t.label }), h('div.small.muted', { text: t.description })),
            h('td', ui.chip(CHANNEL[t.channel] || t.channel, t.dlt ? 'warn' : '')),
            h('td.num', { text: String(t.version) }),
            h('td', { text: t.isDefault ? 'Default' : (t.updatedAt ? CR.util.date(t.updatedAt, true) : 'Edited') })));
        });
        view.appendChild(h('div.card.section-gap', h('div.table-wrap', h('table.table', h('thead', h('tr', ['Template', 'Channel', 'Version', 'Text'].map(function (x, i) { return h('th', { class: i === 2 ? 'num' : '', text: x }); }))), tb))));
      }).catch(function (e) { clear(view).appendChild(ui.error(e)); });
    },
  };
})();
