/* CoRoute web admin: Notifications > "Offers e-mail" (3.56, src/offer_emails.js).
   Prices, coupons and plan offers never go in a push (Google Play payments policy); they go by e-mail to
   riders who turned on offer e-mails on the website account page. Every e-mail has an unsubscribe link.
   #/notifications/email  compose (subject, heading, rich content, image, coupon block, audience, schedule),
                          server preview, test to me, campaigns, suppression list.
   Text is always set as text; the server preview is shown as text, the HTML is offered as a download.
   3.57: the Notifications "Offers e-mail" tab opens the E-mail studio (email_studio.js), which reuses the
   suppression list and the list of these earlier campaigns from here (CR.renderSuppression, CR.renderLegacyOffers). */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var PLAN_LABELS = { community: 'Community (free)', group_small: 'Small Group', group_large: 'Large Group' };
  var STATUS = { SCHEDULED: ['Scheduled', 'info'], SENDING: ['Sending', 'warn'], SENT: ['Sent', 'ok'], FAILED: ['Failed', 'bad'], CANCELLED: ['Cancelled', ''] };

  /** 3.57: the 3.56 offers campaigns (also shown in E-mail studio > Settings). */
  CR.renderLegacyOffers = function (list) {
    var loadList = function () { CR.renderLegacyOffers(list); };
    api('GET', '/admin/email/offers/campaigns?limit=50').then(function (r) {
      var tb = h('tbody');
      (r.campaigns || []).forEach(function (c) {
        var s = STATUS[c.status] || [c.status, ''];
        var s2 = c.stats || {};
        tb.appendChild(h('tr', h('td', { text: CR.util.date(c.sendAt, true) }), h('td', { text: c.subject }), h('td', { text: c.coupon ? c.coupon.code : '-' }),
          h('td', ui.chip(s[0], s[1])), h('td.num', { text: String(s2.targeted || 0) }), h('td.num', { text: String(s2.sent || 0) }), h('td.num', { text: String(s2.skipped || 0) }), h('td.num', { text: String(s2.failed || 0) }),
          h('td', c.status === 'SCHEDULED' ? h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Cancel', onclick: function () {
            api('POST', '/admin/email/offers/campaigns/' + encodeURIComponent(c.campaignId) + '/cancel', {}).then(loadList).catch(function (e) { ui.toast(e.message, true); });
          } }) : null)));
      });
      if (!tb.firstChild) tb.appendChild(h('tr', h('td', { colspan: '9', class: 'muted', text: 'No offers e-mails yet.' })));
      clear(list).appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['When', 'Subject', 'Coupon', 'Status', 'Riders', 'Sent', 'Skipped', 'Failed', ''].map(function (c) { return h('th', { text: c }); }))), tb)));
    }).catch(function (e) { clear(list).appendChild(ui.error(e)); });
  };
  /** 3.57: the suppression list (also shown in E-mail studio > Settings). */
  CR.renderSuppression = function (supp) {
    var loadSupp = function () { CR.renderSuppression(supp); };
    var email = h('input', { type: 'email', placeholder: 'rider@example.com' });
    var add = h('button.btn.btn--sm', { type: 'button', text: 'Add to suppression list', onclick: function () {
      api('POST', '/admin/email/suppression', { email: email.value, reason: 'admin' }).then(function () { ui.toast('Added.'); loadSupp(); }).catch(function (e) { ui.toast(e.message, true); });
    } });
    api('GET', '/admin/email/suppression').then(function (r) {
      var tb = h('tbody');
      (r.entries || []).forEach(function (x) {
        tb.appendChild(h('tr', h('td', { text: x.masked || '-' }), h('td', { text: x.reason }), h('td', { text: CR.util.date(x.at, true) }),
          h('td', h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Remove', onclick: function () {
            ui.confirm('Remove from suppression list?', 'This address may get offer e-mails again, but only while the rider has offer e-mails turned on.', 'Remove').then(function (ok) {
              if (ok) api('DELETE', '/admin/email/suppression/' + x.emailHash).then(loadSupp).catch(function (e) { ui.toast(e.message, true); });
            });
          } }))));
      });
      if (!tb.firstChild) tb.appendChild(h('tr', h('td', { colspan: '4', class: 'muted', text: 'Nobody on the list.' })));
      clear(supp).appendChild(h('div.stack', h('p.small.muted', { text: 'Addresses here never get an offer e-mail (unsubscribed, bounced, complained, or added by an admin). Stored as a hash; shown masked.' }),
        h('div.row', email, add), h('div.table-wrap', h('table.table', h('thead', h('tr', ['Address', 'Reason', 'Since', ''].map(function (c) { return h('th', { text: c }); }))), tb))));
    }).catch(function (e) { clear(supp).appendChild(ui.error(e)); });
  };

  CR.renderOfferEmail = function (view) {
    var st = { imageId: null, kind: 'all', when: 'now' };
    var banner = h('div');
    var subject = h('input', { type: 'text', maxlength: '120', placeholder: 'Ride together for less this month' });
    var heading = h('input', { type: 'text', maxlength: '120', placeholder: 'Large Group, now at a launch offer' });
    var content = h('textarea', { rows: '8', maxlength: '5000', placeholder: 'Plan your next group ride with up to 12 riders.\n\n- Group talk and regroup\n- Live group map\n\n**Offer ends Sunday.** See [all plans](/plans).' });
    var couponCode = h('input', { type: 'text', maxlength: '24', placeholder: 'RIDE50', autocapitalize: 'characters' });
    var couponHeadline = h('input', { type: 'text', maxlength: '80', placeholder: '50% off your first month' });
    var couponNote = h('input', { type: 'text', maxlength: '160', placeholder: 'Valid until 30 Nov on Large Group.' });
    var file = h('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp' });
    var imgInfo = h('div.small.muted', { text: 'Optional. JPEG, PNG or WebP up to 1 MB.' });
    var kind = CR.ui.select([['all', 'Every rider who opted in'], ['active', 'Opted in and active in the last N days'], ['plan', 'Opted in, by plan type']], 'all');
    var days = h('input', { type: 'number', min: '1', max: '365', value: '30' });
    var planBoxes = h('div.row');
    Object.keys(PLAN_LABELS).forEach(function (p) { planBoxes.appendChild(h('label.check', h('input', { type: 'checkbox', value: p, checked: p === 'community' }), PLAN_LABELS[p])); });
    var daysField = CR.ui.field('N days', days); var planField = h('div.field', h('span', 'Plan types'), planBoxes);
    var when = CR.ui.select([['now', 'Send now'], ['later', 'Schedule (India time)']], 'now');
    var at = h('input', { type: 'datetime-local' });
    var atField = CR.ui.field('Date and time (IST)', at);
    var reach = h('span.small.muted');
    var errors = h('div');
    // The admin console's CSP allows no frames and no inline styles, so the preview is the text version
    // here plus the exact HTML as a download (open it in a browser tab).
    var lastHtml = '';
    var frame = h('pre.small', { text: 'Write a subject and the content to see the preview.' });
    frame.className = 'small eng-msg';
    var dl = h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Download HTML preview', disabled: true, onclick: function () {
      if (lastHtml) CR.download(new Blob([lastHtml], { type: 'text/html' }), 'offers-email-preview.html');
    } });
    var list = h('div', ui.loading());
    var supp = h('div', ui.loading());

    function audience() {
      if (st.kind === 'active') return { kind: 'active', days: Number(days.value) };
      if (st.kind === 'plan') return { kind: 'plan', plans: Array.prototype.slice.call(planBoxes.querySelectorAll('input:checked')).map(function (x) { return x.value; }) };
      return { kind: 'all' };
    }
    function payload() {
      var code = couponCode.value.trim();
      return { subject: subject.value, heading: heading.value, content: content.value, imageId: st.imageId || undefined,
        coupon: code ? { code: code, headline: couponHeadline.value, note: couponNote.value } : undefined,
        audience: audience(), sendAt: st.when === 'later' ? CR.util.fromLocalInput(at.value) : 0 };
    }
    function layout() { daysField.hidden = st.kind !== 'active'; planField.hidden = st.kind !== 'plan'; atField.hidden = st.when !== 'later'; sendBtn.textContent = st.when === 'later' ? 'Schedule' : 'Send now'; }
    var timer = null;
    function preview() {
      clearTimeout(timer);
      timer = setTimeout(function () {
        if (!subject.value.trim() || !content.value.trim()) { clear(errors); return; }
        api('POST', '/admin/email/offers/preview', payload()).then(function (r) { clear(errors); frame.textContent = 'Subject: ' + r.subject + '\n\n' + r.text; lastHtml = r.html; dl.disabled = false; })
          .catch(function (e) { clear(errors).appendChild(h('div.banner.banner--bad', { role: 'alert', text: e.message })); });
      }, 500);
    }
    [subject, heading, content, couponCode, couponHeadline, couponNote].forEach(function (el) { el.addEventListener('input', preview); });
    kind.addEventListener('change', function () { st.kind = kind.value; reach.textContent = ''; layout(); });
    when.addEventListener('change', function () { st.when = when.value; layout(); });
    file.addEventListener('change', function () {
      var f = file.files && file.files[0];
      if (!f) return;
      if (f.size > 1024 * 1024) { ui.toast('The image is larger than 1 MB.', true); file.value = ''; return; }
      imgInfo.textContent = 'Uploading…';
      api('POST', '/admin/push/images', f, { type: f.type || 'application/octet-stream' }).then(function (r) {
        st.imageId = r.image.imageId; imgInfo.textContent = 'Image ready (' + Math.round(r.image.bytes / 1024) + ' KB).'; preview();
      }).catch(function (e) { imgInfo.textContent = e.message; file.value = ''; });
    });
    var countBtn = h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Count riders', onclick: function () {
      reach.textContent = 'Counting…';
      api('POST', '/admin/email/offers/audience-count', { audience: audience() }).then(function (r) { reach.textContent = r.riders + ' rider(s) opted in with a valid, unsuppressed e-mail.'; })
        .catch(function (e) { reach.textContent = e.message; });
    } });
    var testBtn = h('button.btn', { type: 'button', text: 'Send test to me', onclick: function () {
      testBtn.disabled = true;
      api('POST', '/admin/email/offers/test', payload()).then(function (r) { ui.toast(r.sent ? 'Test sent to ' + r.to + '.' : 'Not sent: ' + (r.error || 'unknown error'), !r.sent); })
        .catch(function (e) { ui.toast(e.message, true); }).then(function () { testBtn.disabled = false; });
    } });
    var sendBtn = h('button.btn.btn--primary', { type: 'button', text: 'Send now', onclick: function () {
      var p = payload();
      if (st.when === 'later' && !p.sendAt) { ui.toast('Choose the date and time.', true); return; }
      ui.confirm(st.when === 'later' ? 'Schedule e-mail' : 'Send e-mail', (st.when === 'later' ? 'Schedule this offers e-mail for ' + CR.util.date(p.sendAt, true) + ' (IST)?' : 'Send this offers e-mail now?') + ' Only riders who opted in get it.', st.when === 'later' ? 'Schedule' : 'Send').then(function (ok) {
        if (!ok) return;
        sendBtn.disabled = true;
        api('POST', '/admin/email/offers/campaigns', p).then(function () { ui.toast(st.when === 'later' ? 'Scheduled.' : 'Sending.'); loadList(); })
          .catch(function (e) { ui.toast(e.message, true); }).then(function () { sendBtn.disabled = false; });
      });
    } });

    function loadList() { CR.renderLegacyOffers(list); }
    function loadSupp() { CR.renderSuppression(supp); }

    view.appendChild(banner);
    view.appendChild(h('div.np-grid.section-gap',
      h('div.card.stack',
        h('div.banner.banner--info', { text: 'Why e-mail: Google Play does not allow prices, coupons or plan offers in the app or its notifications. Offers e-mails go only to riders who turned on offer e-mails on the website (off by default), skip the suppression list, and carry an unsubscribe link and one-click unsubscribe headers.' }),
        CR.ui.field('Subject', subject), CR.ui.field('Heading', heading, 'optional; the subject is used when empty'),
        CR.ui.field('Content', content, 'blank line = paragraph, "- " = bullet, **bold**, [label](/path) links to this site only'),
        h('div.field', h('span', 'Image'), file, imgInfo),
        h('fieldset.stack', h('legend', { text: 'Coupon block (optional)' }), h('div.grid2', CR.ui.field('Code', couponCode, 'must exist in Coupons'), CR.ui.field('Headline', couponHeadline)), CR.ui.field('Note', couponNote),
          h('p.small.muted', { text: 'The button opens /plans?coupon=CODE on the website.' })),
        errors,
        CR.ui.field('Audience', kind), daysField, planField, h('div.row', countBtn, reach),
        CR.ui.field('When', when), atField,
        h('div.row.row--end', testBtn, sendBtn)),
      h('div.card', h('div.card__head', h('h3', { text: 'Preview' }), h('p', { text: 'Rendered by the server, exactly as sent (unsubscribe link per rider).' })), h('div.row', dl), frame)));
    view.appendChild(h('h2.section-gap', { text: 'Offers e-mails' }));
    view.appendChild(list);
    view.appendChild(h('h2.section-gap', { text: 'Suppression list' }));
    view.appendChild(supp);
    layout();
    loadList();
    loadSupp();
    api('GET', '/admin/email/config').then(function (c) {
      if (!c.enabled) banner.appendChild(h('div.banner.banner--bad.section-gap', { text: 'E-mail is not configured on this server (SMTP_HOST / MAIL_FROM). Campaigns will fail until it is.' }));
    }).catch(function () { /* defaults */ });
  };
})();
