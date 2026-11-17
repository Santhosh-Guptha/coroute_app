/* CoRoute web admin: Phone sign-in (v3.62, src/session_settings.js).
   How long riders stay signed in on the phone app. 0 = never signed out by time (the default).
   A saved rule applies ONLY to phone sign-ins made after saving: riders who are already signed in keep the rule they
   signed in with, so saving here never signs anyone out. Sign-out, password change, "sign out everywhere", account
   hold and admin revoke still end a session at once. MASTER_ADMIN only to save; audited. Text is always set as text. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear;
  var api = CR.api, ui = CR.ui;

  function days(n) { return n === 0 ? 'Never' : (n + (n === 1 ? ' day' : ' days')); }

  function render(view) {
    clear(view);
    view.appendChild(ui.pageHead('Phone sign-in', 'How long riders stay signed in on the phone app. Riders already signed in are never affected by a change here.'));
    var body = h('div', ui.loading());
    view.appendChild(body);
    api('GET', '/admin/session-settings').then(function (r) {
      clear(body);
      var idle = h('input', { type: 'number', min: String(r.limits.appIdleDays[0]), max: String(r.limits.appIdleDays[1]), step: '1', style: 'width:7em', 'aria-label': 'Sign out after this many days without opening the app (0 = never)' });
      idle.value = String(r.appIdleDays);
      var abs = h('input', { type: 'number', min: String(r.limits.appAbsoluteDays[0]), max: String(r.limits.appAbsoluteDays[1]), step: '1', style: 'width:7em', 'aria-label': 'Sign out this many days after signing in (0 = never)' });
      abs.value = String(r.appAbsoluteDays);
      var tb = h('tbody',
        h('tr', h('td', h('strong', { text: 'Sign out after days without opening the app' }), h('div.muted.small', { text: '0 = never (recommended). 1 to 365.' })), h('td.num', idle)),
        h('tr', h('td', h('strong', { text: 'Sign out this many days after signing in' }), h('div.muted.small', { text: '0 = never (recommended). 1 to 3650. Never during a ride or an SOS.' })), h('td.num', abs))
      );
      var stay = !r.appIdleDays && !r.appAbsoluteDays;
      var status = h('div.ps-status' + (stay ? '.ps-status--ok' : '.ps-status--warn'),
        h('div', h('p.cc-eyebrow', { text: 'Now' }), h('h2', { text: stay ? 'Riders stay signed in' : 'New sign-ins have a time limit' }),
          h('p.muted', { text: 'Unused: ' + days(r.appIdleDays) + ' · After sign-in: ' + days(r.appAbsoluteDays) + '. ' + r.note })),
        typeof r.liveAppSessions === 'number' ? h('div.ps-count', h('b', { text: Number(r.liveAppSessions).toLocaleString('en-IN') }), h('span.small.muted', { text: 'phones signed in, kept as they are' })) : null);
      body.appendChild(status);
      body.appendChild(h('div.card.section-gap', h('h2', { text: 'Rule for new phone sign-ins' }), h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Setting' }), h('th.num', { text: 'Days' }))), tb))));
      if (!r.saved && (r.env.appIdleDays || r.env.appAbsoluteDays)) {
        body.appendChild(h('p.muted.small', { text: 'Not saved here yet: the default comes from the server file (SESSION_APP_IDLE_DAYS=' + r.env.appIdleDays + ', SESSION_APP_ABSOLUTE_DAYS=' + r.env.appAbsoluteDays + '). Save 0 / 0 to keep riders signed in.' }));
      }
      body.appendChild(h('p.muted.small', { text: 'Always kept, whatever you set: sign-out, password change, "sign out everywhere", account hold or block, and your own revoke end a session at once. A lost network reply never signs a phone out.' }));
      if (r.updatedAt) body.appendChild(h('p.muted.small', { text: 'Last saved ' + new Date(r.updatedAt).toLocaleString() + ' by ' + (r.updatedBy || 'admin') + '.' }));
      body.appendChild(h('div.row.section-gap', h('button.btn.btn--primary', { type: 'button', text: 'Save rule for new sign-ins', onclick: function () {
        var btn = this; if (btn.disabled) return; btn.disabled = true; // v3.62 QA: one save per click
        var payload = { appIdleDays: Math.round(Number(idle.value)), appAbsoluteDays: Math.round(Number(abs.value)) };
        api('PUT', '/admin/session-settings', payload).then(function () { ui.toast('Saved. Applies to phone sign-ins from now on; riders signed in now are not affected.'); render(view); })
          .catch(function (e) { btn.disabled = false; ui.toast(e.message, true); });
      } })));
    }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
  }

  CR.sections.phonesignin = { title: 'Phone sign-in', render: render };
})();
