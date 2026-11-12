/* CoRoute web admin: "Push notifications" (3.56, docs/features_355/notifications_admin.md; 3.57 round 3: e-mail moved to
   its own "E-mail" menu item (email_wizard.js) and the SMS settings to Settings > SMS).
   #/push                   compose a push (title, body, image, screen, audience, schedule) with an Android preview
   #/push/history           campaigns with delivery counts (cancel a scheduled one)
   CR.renderSms(view)       SOS SMS provider settings (secrets shown as Set / Not set), test SMS, SMS log per SOS (Settings > SMS)
   Every call goes to /api/admin/push/* or /api/admin/sms/* with the admin's token (CR.api). Text is always set
   as text (never HTML). Pushes reach the Play app: the server refuses money / buying / offer words. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var TARGET_LABELS = { home: 'Home', friends: 'Friends and people', crews: 'Crews', rides: 'Ride history', settings: 'Settings' };
  var PLAN_LABELS = { community: 'Community (free)', group_small: 'Small Group', group_large: 'Large Group' };
  // 3.56 push kinds (src/push_campaigns.js KINDS): each has its own Android channel and in-app switch.
  var KIND_LABELS = { update: 'Update', event: 'Event', safety_tip: 'Safety tip', community: 'Community', partner_perk: 'Partner perk' };
  var KIND_HINTS = {
    update: 'New features and app news. Riders turn this off with "News and updates".',
    event: 'Rides, meet-ups and community events. Own channel "Events".',
    safety_tip: 'Riding safety tips. Own channel "Safety tips". (SOS, crash and ride alerts are never campaigns and are always on.)',
    community: 'Community stories and milestones. Own channel "Community".',
    partner_perk: 'A real-world perk at a partner CoRoute curated (e.g. "10% off a service at a partner garage"). Only riders who turned "Partner perks" on get it, at most one a week. Never a CoRoute plan, price, coupon or purchase link.'
  };
  var STATUS = { SCHEDULED: ['Scheduled', 'info'], SENDING: ['Sending', 'warn'], SENT: ['Sent', 'ok'], FAILED: ['Failed', 'bad'], CANCELLED: ['Cancelled', ''] };

  function tabs(active) {
    var nav = h('div.row.eng-tabs', { role: 'tablist', 'aria-label': 'Push notifications' });
    [['', 'Send'], ['history', 'History']].forEach(function (t) {
      nav.appendChild(h('button.btn.btn--sm', { type: 'button', role: 'tab', 'aria-selected': String(active === t[0]), 'aria-pressed': String(active === t[0]), text: t[1], onclick: function () { CR.go('#/push' + (t[0] ? '/' + t[0] : '')); } }));
    });
    return nav;
  }
  function counter(input, max) {
    var c = h('small', { text: '0 / ' + max });
    function upd() { var n = input.value.length; c.textContent = n + ' / ' + max; c.style.color = n > max ? 'var(--c-sos-ink)' : ''; }
    input.addEventListener('input', upd); upd();
    return c;
  }
  function audienceText(a) {
    if (!a) return '-';
    if (a.kind === 'test') return 'Test (me)';
    if (a.kind === 'active') return 'Active in last ' + a.days + ' days';
    if (a.kind === 'plan') return 'Plan: ' + (a.plans || []).map(function (p) { return PLAN_LABELS[p] || p; }).join(', ');
    if (a.kind === 'users') return (a.usernames || []).length + ' username(s)';
    return 'All riders';
  }

  /** Android-style notification card (collapsed text + big picture), light or dark. */
  function previewCard(theme, st) {
    var card = h('div.np-card.np-card--' + theme, { 'aria-label': 'Preview, ' + theme + ' theme' });
    var label = st.pushKind === 'partner_perk' ? 'CoRoute · Partner perk' + (st.partnerName ? ' · ' + st.partnerName : '') + ' · now' : 'CoRoute · ' + (KIND_LABELS[st.pushKind] || 'Update') + ' · now';
    card.appendChild(h('div.np-card__top', h('span.np-card__icon', { 'aria-hidden': 'true' }), h('span', { text: label })));
    card.appendChild(h('div.np-card__title', { text: st.title || 'Title' }));
    card.appendChild(h('div.np-card__body', { text: st.body || 'Your message appears here.' }));
    if (st.imageBlobUrl) card.appendChild(h('img.np-card__img', { src: st.imageBlobUrl, alt: '' }));
    return card;
  }

  // ==================================================================== compose
  function renderCompose(view) {
    var st = { title: '', body: '', target: 'home', imageId: null, imageBlobUrl: null, kind: 'all', days: 30, plans: ['community'], usernames: '', when: 'now', at: '', pushKind: 'update', partnerName: '' };

    var pushKind = CR.ui.select(Object.keys(KIND_LABELS).map(function (k) { return [k, KIND_LABELS[k]]; }), 'update');
    var kindHint = h('div.small.muted', { text: KIND_HINTS.update });
    var partner = h('input', { type: 'text', maxlength: '60', placeholder: 'Speed Garage, Indiranagar' });
    var curated = h('input', { type: 'checkbox' });
    var partnerField = h('div.stack', CR.ui.field('Partner', partner, 'the real-world business offering the perk'),
      h('label.check', curated, 'CoRoute curated this perk: a real-world perk at this partner, not a CoRoute plan or digital good, with no purchase link.'));
    var cfg = null;
    var policy = h('div');
    var previews = h('div.np-previews');
    var title = h('input', { type: 'text', maxlength: '65', placeholder: 'Crew polls are here' });
    var body = h('textarea', { rows: '4', maxlength: '240', placeholder: 'Ask your crew where to ride next, right in the app.' });
    var target = CR.ui.select([['home', 'Home'], ['friends', 'Friends and people'], ['crews', 'Crews'], ['rides', 'Ride history'], ['settings', 'Settings']], 'home');
    var file = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp' });
    var imgInfo = h('div.small.muted', { text: 'Optional. JPEG, PNG or WebP up to 1 MB. Location and camera data are removed.' });
    var removeImg = h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Remove image', hidden: true });
    var kind = CR.ui.select([['all', 'All riders'], ['active', 'Riders active in the last N days'], ['plan', 'Plan type'], ['users', 'Usernames']], 'all');
    var days = h('input', { type: 'number', min: '1', max: '365', value: '30' });
    var planBoxes = h('div.row');
    Object.keys(PLAN_LABELS).forEach(function (p) {
      var cb = h('input', { type: 'checkbox', value: p, checked: p === 'community' });
      cb.addEventListener('change', function () { st.plans = Array.prototype.slice.call(planBoxes.querySelectorAll('input:checked')).map(function (x) { return x.value; }); });
      planBoxes.appendChild(h('label.check', cb, PLAN_LABELS[p]));
    });
    var users = h('textarea', { rows: '3', placeholder: 'SwiftFalcon482, CalmRider77' });
    var daysField = CR.ui.field('N days', days); var planField = h('div.field', h('span', 'Plan types'), planBoxes); var usersField = CR.ui.field('Usernames', users, 'comma or space separated, up to 200');
    var when = CR.ui.select([['now', 'Send now'], ['later', 'Schedule (India time)']], 'now');
    var at = h('input', { type: 'datetime-local' });
    var atField = CR.ui.field('Date and time (IST)', at);
    var reach = h('span.small.muted');
    var countBtn = h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Count riders' });
    var testBtn = h('button.btn', { type: 'button', text: 'Send test to me' });
    var sendBtn = h('button.btn.btn--primary', { type: 'button', text: 'Send now' });

    function audience() {
      if (st.kind === 'active') return { kind: 'active', days: Number(days.value) };
      if (st.kind === 'plan') return { kind: 'plan', plans: st.plans };
      if (st.kind === 'users') return { kind: 'users', usernames: users.value };
      return { kind: 'all' };
    }
    function payload() {
      return { title: title.value, body: body.value, target: target.value, imageId: st.imageId || undefined, audience: audience(),
        kind: pushKind.value, partnerName: pushKind.value === 'partner_perk' ? partner.value : undefined, curated: pushKind.value === 'partner_perk' ? curated.checked : undefined,
        sendAt: st.when === 'later' ? CR.util.fromLocalInput(at.value) : 0 };
    }
    function redraw() {
      st.title = title.value; st.body = body.value; st.pushKind = pushKind.value; st.partnerName = partner.value.trim();
      partnerField.hidden = st.pushKind !== 'partner_perk';
      kindHint.textContent = KIND_HINTS[st.pushKind] || '';
      clear(previews).appendChild(previewCard('light', st));
      previews.appendChild(previewCard('dark', st));
      daysField.hidden = st.kind !== 'active'; planField.hidden = st.kind !== 'plan'; usersField.hidden = st.kind !== 'users';
      atField.hidden = st.when !== 'later';
      sendBtn.textContent = st.when === 'later' ? 'Schedule' : 'Send now';
    }
    var checkTimer = null;
    function check() {
      clearTimeout(checkTimer);
      checkTimer = setTimeout(function () {
        if (!title.value.trim() || !body.value.trim()) { clear(policy); return; }
        api('POST', '/admin/push/check', { title: title.value, body: body.value, target: target.value, kind: pushKind.value, partnerName: partner.value, curated: curated.checked }).then(function () { clear(policy); })
          .catch(function (e) { clear(policy).appendChild(h('div.banner.banner--bad', { role: 'alert', text: e.message })); });
      }, 450);
    }
    [title, body, partner].forEach(function (el) { el.addEventListener('input', function () { redraw(); check(); }); });
    [pushKind, curated].forEach(function (el) { el.addEventListener('change', function () { reach.textContent = ''; redraw(); check(); }); });
    kind.addEventListener('change', function () { st.kind = kind.value; reach.textContent = ''; redraw(); });
    when.addEventListener('change', function () { st.when = when.value; redraw(); });
    file.addEventListener('change', function () {
      var f = file.files && file.files[0];
      if (!f) return;
      if (f.size > 1024 * 1024) { ui.toast('The image is larger than 1 MB.', true); file.value = ''; return; }
      imgInfo.textContent = 'Uploading…';
      api('POST', '/admin/push/images', f, { type: f.type || 'application/octet-stream' }).then(function (r) {
        st.imageId = r.image.imageId;
        if (st.imageBlobUrl) URL.revokeObjectURL(st.imageBlobUrl);
        st.imageBlobUrl = URL.createObjectURL(f);
        imgInfo.textContent = 'Image ready (' + Math.round(r.image.bytes / 1024) + ' KB' + (r.image.width ? ', ' + r.image.width + '×' + r.image.height : '') + '). Phones show it when expanded.';
        removeImg.hidden = false;
        redraw();
      }).catch(function (e) { imgInfo.textContent = e.message; file.value = ''; });
    });
    removeImg.addEventListener('click', function () {
      st.imageId = null; if (st.imageBlobUrl) URL.revokeObjectURL(st.imageBlobUrl); st.imageBlobUrl = null; file.value = '';
      removeImg.hidden = true; imgInfo.textContent = 'No image.'; redraw();
    });
    countBtn.addEventListener('click', function () {
      reach.textContent = 'Counting…';
      api('POST', '/admin/push/audience-count', { audience: audience(), kind: pushKind.value }).then(function (r) {
        reach.textContent = r.riders + ' rider(s) with the app' + (r.optedOut ? ', ' + r.optedOut + ' turned ' + (KIND_LABELS[pushKind.value] || 'this kind') + (pushKind.value === 'partner_perk' ? ' not on' : ' off') : '') + '. At most ' + ((cfg && cfg.dailyCap) || 2) + ' a day per rider.';
      }).catch(function (e) { reach.textContent = e.message; });
    });
    testBtn.addEventListener('click', function () {
      testBtn.disabled = true;
      api('POST', '/admin/push/test', payload()).then(function (r) {
        var res = r.result || {};
        ui.toast(res.sent ? 'Test sent to your phone (' + res.sent + ' device' + (res.sent > 1 ? 's' : '') + ').' : (r.error || 'Not delivered: sign in to the CoRoute app with this admin account and allow notifications.'), !res.sent);
      }).catch(function (e) { ui.toast(e.message, true); }).then(function () { testBtn.disabled = false; });
    });
    sendBtn.addEventListener('click', function () {
      var p = payload();
      if (st.when === 'later' && !p.sendAt) { ui.toast('Choose the date and time.', true); return; }
      var msg = (st.when === 'later' ? 'Schedule this push for ' + CR.util.date(p.sendAt, true) + ' (IST)' : 'Send this push now') + ' to: ' + audienceText(p.audience) + '?';
      ui.confirm(st.when === 'later' ? 'Schedule push' : 'Send push', msg, st.when === 'later' ? 'Schedule' : 'Send').then(function (ok) {
        if (!ok) return;
        sendBtn.disabled = true;
        api('POST', '/admin/push/campaigns', p).then(function () {
          ui.toast(st.when === 'later' ? 'Scheduled.' : 'Sending. See History for the counts.');
          CR.go('#/push/history');
        }).catch(function (e) { ui.toast(e.message, true); }).then(function () { sendBtn.disabled = false; });
      });
    });

    var banner = h('div');
    view.appendChild(ui.pageHead('Push notifications', 'A short message on riders\' phones. No prices or coupons here (Play policy): those go by e-mail.'));
    view.appendChild(tabs(''));
    view.appendChild(banner);
    view.appendChild(h('div.np-grid.section-gap',
      h('div.card.stack',
        h('p.small.muted', 'Prices, coupons and plan offers? ', h('a', { href: '#/email', text: 'Send an e-mail instead.' })),
        CR.ui.field('Kind', pushKind, 'own Android channel and in-app switch'), kindHint, partnerField,
        CR.ui.field('Title', title, null), h('div.row.row--end', counter(title, 65)),
        CR.ui.field('Message', body), h('div.row.row--end', counter(body, 240)),
        policy,
        h('div.field', h('span', 'Big picture'), file, imgInfo, removeImg),
        CR.ui.field('Opens', target, 'the screen a tap opens'),
        CR.ui.field('Audience', kind), daysField, planField, usersField,
        h('div.row', countBtn, reach),
        CR.ui.field('When', when), atField,
        h('div.banner.banner--info', { text: 'Google Play policy: pushes reach the Play app, which must not show prices, coupons, discounts, offers, buying or upgrade words, or links to the plans page (payments policy), and must not carry third-party ads (ads policy). Offers and coupons for CoRoute plans are e-mail only: choose Channel "E-mail (Offers)"; it goes only to riders who opted in on the website, with an unsubscribe link.' }),
        h('div.row.row--end', testBtn, sendBtn)),
      h('div.card', h('div.card__head', h('h3', { text: 'Preview' }), h('p', { text: 'Android, expanded. Phones may shorten the text.' })), previews)));
    redraw();
    api('GET', '/admin/push/config').then(function (c) {
      cfg = c;
      if (!c.enabled) banner.appendChild(h('div.banner.banner--bad.section-gap', { text: 'Push is not configured on this server (FCM_SERVICE_ACCOUNT_JSON). Campaigns will fail until it is.' }));
      if (!c.imagesAllowed) { file.disabled = true; imgInfo.textContent = 'Images need the site on https (PUBLIC_ORIGIN).'; }
    }).catch(function () { /* defaults */ });
  }

  // ==================================================================== history
  function renderHistory(view) {
    var tbody = h('tbody');
    var refresh = h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Refresh' });
    view.appendChild(ui.pageHead('Push notifications', 'What was sent, with delivery counts.', refresh));
    view.appendChild(tabs('history'));
    var wrap = h('div.card.section-gap', h('div.table-wrap', h('table.table',
      h('thead', h('tr', ['Created', 'Push', 'Audience', 'Status', 'Send time', 'Riders', 'Reached', 'Sent', 'Failed', 'Invalid tokens', 'News off', 'Capped', ''].map(function (t, i) { return h('th', { class: i >= 5 && i <= 11 ? 'num' : '', text: t }); }))),
      tbody)));
    view.appendChild(wrap);
    function load() {
      clear(tbody).appendChild(h('tr', h('td', { colspan: '13' }, ui.loading())));
      api('GET', '/admin/push/campaigns?limit=100').then(function (r) {
        clear(tbody);
        if (!r.campaigns.length) { tbody.appendChild(h('tr', h('td.empty', { colspan: '13', text: 'No pushes yet.' }))); return; }
        r.campaigns.forEach(function (c) {
          var s = STATUS[c.status] || [c.status, ''];
          var stt = c.stats || {};
          var cancel = c.status === 'SCHEDULED' ? h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Cancel', onclick: function () {
            ui.confirm('Cancel push', 'Cancel "' + c.title + '"?', 'Cancel push', true).then(function (ok) {
              if (ok) api('POST', '/admin/push/campaigns/' + encodeURIComponent(c.campaignId) + '/cancel').then(load).catch(function (e) { ui.toast(e.message, true); });
            });
          } }) : null;
          tbody.appendChild(h('tr',
            h('td', { text: CR.util.date(c.createdAt, true) }),
            h('td', h('b', { text: c.title }), h('div.small.muted', { text: c.body }), c.error ? h('div.small.np-err', { text: c.error }) : null),
            h('td', { text: audienceText(c.audience) + (c.target ? ' · opens ' + (TARGET_LABELS[c.target] || c.target) : '') + (c.imageUrl ? ' · image' : '') }),
            h('td', ui.chip(s[0], s[1])),
            h('td', { text: CR.util.date(c.sendAt, true) }),
            ['targeted', 'reached', 'sent', 'failed', 'pruned', 'optedOut', 'capped'].map(function (k) { return h('td.num', { text: String(stt[k] || 0) }); }),
            h('td', cancel)));
        });
      }).catch(function (e) { clear(tbody).appendChild(h('tr', h('td', { colspan: '13' }, ui.error(e)))); });
    }
    refresh.addEventListener('click', load);
    load();
  }

  // ==================================================================== SMS
  function renderSms(view) {
    var body = h('div', ui.loading());
    view.appendChild(h('p.muted.section-gap', { text: 'Server SMS to emergency contacts during an SOS, and the "safe now" follow-up.' }));
    view.appendChild(body);
    api('GET', '/admin/sms/settings').then(function (r) { draw(r); }).catch(function (e) { clear(body).appendChild(ui.error(e)); });

    function draw(r) {
      clear(body);
      var s = r.settings;
      var provider = CR.ui.select(r.providers.map(function (p) { return [p, { off: 'Off (earlier path / outbox)', log: 'Log only (testing)', msg91: 'MSG91 (India, DLT)', twilio: 'Twilio' }[p] || p]; }), s.provider);
      var inp = function (v, ph) { return h('input', { type: 'text', value: v || '', placeholder: ph || '' }); };
      var f = {
        senderId: inp(s.senderId, 'CORUTE'), dltEntityId: inp(s.dltEntityId, '1101xxxxxxxxxxxxxxx'), dltTemplateIdSos: inp(s.dltTemplateIdSos, '1107xxxxxxxxxxxxxxx'),
        dltTemplateIdSafe: inp(s.dltTemplateIdSafe, '1107xxxxxxxxxxxxxxx'), msg91TemplateIdSos: inp(s.msg91TemplateIdSos, 'MSG91 template id'), msg91TemplateIdSafe: inp(s.msg91TemplateIdSafe, 'MSG91 template id'),
        maxPerSos: h('input', { type: 'number', min: '1', max: '10', value: String(s.maxPerSos) }), maxPerUserDay: h('input', { type: 'number', min: '1', max: '100', value: String(s.maxPerUserDay) }),
      };
      var safe = h('input', { type: 'checkbox', checked: s.safeSms });
      var save = h('button.btn.btn--primary', { type: 'button', text: 'Save SMS settings' });
      save.addEventListener('click', function () {
        var p = { provider: provider.value, safeSms: safe.checked };
        Object.keys(f).forEach(function (k) { p[k] = f[k].type === 'number' ? Number(f[k].value) : f[k].value.trim(); });
        save.disabled = true;
        api('PUT', '/admin/sms/settings', p).then(function (nr) { ui.toast('Saved.'); draw(nr); }).catch(function (e) { ui.toast(e.message, true); save.disabled = false; });
      });
      var secrets = h('div.kv');
      Object.keys(r.secrets).forEach(function (k) { secrets.appendChild(h('span.mono', { text: k })); secrets.appendChild(h('span', ui.chip(r.secrets[k], r.secrets[k] === 'Set' ? 'ok' : ''))); });
      var phone = h('input', { type: 'tel', placeholder: '+919876543210' });
      var testBtn = h('button.btn', { type: 'button', text: 'Send test SMS' });
      testBtn.addEventListener('click', function () {
        testBtn.disabled = true;
        api('POST', '/admin/sms/test', { phone: phone.value }).then(function (x) { ui.toast('Test SMS to ' + x.to + ': ' + x.status + (x.error ? ' (' + x.error + ')' : ''), x.status !== 'SENT'); })
          .catch(function (e) { ui.toast(e.message, true); }).then(function () { testBtn.disabled = false; });
      });
      body.appendChild(h('div.grid2.section-gap',
        h('div.card.stack', h('div.card__head', h('h3', { text: 'Provider' }), ui.chip(r.ready ? 'Ready' : 'Not active', r.ready ? 'ok' : 'warn')),
          CR.ui.field('Provider', provider),
          h('div.grid2', CR.ui.field('Sender id (DLT header)', f.senderId), CR.ui.field('DLT entity id', f.dltEntityId)),
          h('div.grid2', CR.ui.field('DLT template id: SOS', f.dltTemplateIdSos), CR.ui.field('DLT template id: safe now', f.dltTemplateIdSafe)),
          h('div.grid2', CR.ui.field('MSG91 template: SOS', f.msg91TemplateIdSos), CR.ui.field('MSG91 template: safe now', f.msg91TemplateIdSafe)),
          h('div.grid2', CR.ui.field('SMS per SOS', f.maxPerSos, 'contacts texted'), CR.ui.field('SMS per rider per day', f.maxPerUserDay, 'cost guard')),
          h('label.check', safe, 'Send "safe now" when the SOS is resolved or cancelled'),
          h('div.banner.banner--info', { text: 'The SMS words are in Templates (SOS SMS, SOS safe-now SMS). They must match the DLT-registered text exactly.' }),
          h('div.row.row--end', save)),
        h('div.card.stack', h('div.card__head', h('h3', { text: 'Secrets (server environment)' }), h('p', { text: 'Set on the server only. Shown here as Set or Not set.' })), secrets,
          r.receiptsUrl ? h('div.small', h('b', { text: 'Delivery receipts URL: ' }), h('span.mono', { text: r.receiptsUrl })) : h('div.small.muted', { text: 'Delivery receipts need an https PUBLIC_ORIGIN and SMS_WEBHOOK_TOKEN.' }),
          h('div.small.muted', { text: 'Outbound hosts: ' + r.hosts.join(', ') }),
          h('div.row', phone, testBtn))));
      var logBody = h('tbody');
      body.appendChild(h('div.card.section-gap', h('div.card__head', h('h3', { text: 'SMS log' }), h('p', { text: 'Per SOS. Numbers are masked; numbers and texts are deleted 48 hours after the last update.' })),
        h('div.table-wrap', h('table.table', h('thead', h('tr', ['Time', 'SOS', 'Kind', 'To', 'Status', 'Tries', 'Note'].map(function (t) { return h('th', { text: t }); }))), logBody))));
      api('GET', '/admin/sms/log?limit=50').then(function (lr) {
        if (!lr.sos.length) { logBody.appendChild(h('tr', h('td.empty', { colspan: '7', text: 'No SMS yet.' }))); return; }
        lr.sos.forEach(function (g) {
          g.messages.forEach(function (m, i) {
            var kindChip = { DELIVERED: 'ok', SENT: 'info', QUEUED: 'warn', FAILED: 'bad', CANCELLED: '' }[m.status];
            logBody.appendChild(h('tr', h('td', { text: CR.util.date(m.createdAt, true) }), h('td.mono', { text: i ? '' : g.sosKey }), h('td', { text: m.kind }),
              h('td.mono', { text: m.to }), h('td', ui.chip(m.status, kindChip || '')), h('td.num', { text: String(m.attempts || 0) }), h('td.small', { text: m.error || '' })));
          });
        });
      }).catch(function (e) { logBody.appendChild(h('tr', h('td', { colspan: '7' }, ui.error(e)))); });
    }
  }

  var pushSection = {
    title: 'Push notifications',
    render: function (view, arg) {
      if (arg === 'history') return renderHistory(view);
      return renderCompose(view);
    },
  };
  CR.sections.push = pushSection;
  CR.renderSms = function (view) { renderSms(view); };
})();
