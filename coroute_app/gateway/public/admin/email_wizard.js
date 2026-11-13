/* CoRoute web admin: "E-mail" (3.57 round 3, docs/features_355/email_marketing.md "The wizard").
   One place to send e-mail, in three steps, used for one rider, several riders or an audience:
     1 Who     one rider (search) / several usernames / an audience (segment, live count)
     2 What    a template card (Welcome, Plan assigned, Coupon for you, Festive offer, ...) or "Write a quick message",
               edited in the block editor (email_studio.js; advanced blocks behind "More blocks")
     3 Check   preview (mobile / desktop, light / dark), a checklist (subject, consent, links, postal address), send / schedule
   #/email                  the wizard          #/email/rider/<userId>  the wizard for one rider (from the rider page)
   #/email/status/<id>      a campaign's status  #/email/history | automations | templates | settings   the other tabs
   One rider: POST /api/admin/riders/:id/email (a 1:1 message, sent at once). Several / audience: a campaign
   (POST /api/admin/email/studio/campaigns). The server decides consent, suppression and links; this page explains. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var ES = null;
  var BASE = '/admin/email/studio';
  var TABS = [['', 'Send', 'Send an e-mail in three steps'], ['history', 'History', 'What was sent, with results'], ['automations', 'Automations', 'E-mails that go out on their own'],
    ['templates', 'Templates', 'Saved and ready-made e-mails'], ['settings', 'Settings', 'Weekly limit, quiet hours, sender, blocked addresses']];
  var CAT = { account: ['About their account', 'Transactional: no offer consent needed. No coupons or prices.'], marketing: ['Offer or news', 'Marketing: only riders who agreed to offer e-mails get it. Unsubscribe link added.'] };
  var poll = null;

  function tabs(active) {
    var nav = h('div.row.eng-tabs.es-tabs', { role: 'tablist', 'aria-label': 'E-mail' });
    TABS.forEach(function (t) {
      nav.appendChild(h('button.btn.btn--sm', { type: 'button', role: 'tab', title: t[2], 'aria-selected': String(active === t[0]), 'aria-pressed': String(active === t[0]), text: t[1],
        onclick: function () { CR.go('#/email' + (t[0] ? '/' + t[0] : '')); } }));
    });
    return nav;
  }
  function info(text) { return h('span.tip', { tabindex: '0', role: 'note', title: text, 'aria-label': text, text: '?' }); }
  function rid() { var a = new Uint8Array(10); crypto.getRandomValues(a); return 'w' + Array.prototype.map.call(a, function (x) { return ('0' + x.toString(16)).slice(-2); }).join(''); }

  // ------------------------------------------------------------------ state
  var wz = null;
  function fresh() {
    return { step: 1, who: 'audience', rider: null, usernames: '', audience: { kind: 'all', days: 30 }, mode: null, pick: null, draft: null,
      quick: { subject: '', text: '', button: '', category: 'account' }, unique: { enabled: false, prefix: '', validDays: 14 }, personalCode: false,
      service: false, serviceNote: '', when: 'now', at: '', name: '', requestId: rid() };
  }
  function category() { return wz.mode === 'quick' ? wz.quick.category : (wz.draft ? wz.draft.category : 'marketing'); }
  function hasPromo() {
    if (wz.mode !== 'template' || !wz.draft) return false;
    return wz.draft.design.blocks.some(function (b) { return b.type === 'coupon' || b.type === 'price'; });
  }
  function design() {
    if (wz.mode === 'quick') {
      var blocks = [{ type: 'text', text: wz.quick.text }];
      if (wz.quick.button) blocks.push({ type: 'button', label: wz.quick.buttonLabel || 'Open', path: wz.quick.button, style: 'primary' });
      blocks.push({ type: 'footer', note: '' });
      return { subject: wz.quick.subject, preheader: '', blocks: blocks };
    }
    return ES.strip(wz.draft.design);
  }
  function uniquePayload() {
    if (wz.mode !== 'template' || !wz.draft || !wz.draft.design.blocks.some(function (b) { return b.type === 'coupon'; })) return undefined;
    if (wz.who === 'one') return wz.personalCode ? { enabled: true, prefix: wz.unique.prefix || 'ME', validDays: Number(wz.unique.validDays) || 14 } : undefined;
    return wz.unique.enabled ? { enabled: true, prefix: wz.unique.prefix, validDays: Number(wz.unique.validDays) || 14 } : undefined;
  }
  function audience() {
    if (wz.who === 'several') return { kind: 'usernames', usernames: wz.usernames };
    var a = { kind: wz.audience.kind };
    var s = (ES.config().segments || []).filter(function (x) { return x.kind === a.kind; })[0] || {};
    if (s.days) a.days = Number(wz.audience.days) || 30;
    if (a.kind === 'plan') a.plans = ['community', 'group_small', 'group_large'];
    return a;
  }
  function names(v) { return String(v || '').split(/[\s,]+/).map(function (x) { return x.trim().replace(/^@/, ''); }).filter(Boolean); }

  // ------------------------------------------------------------------ stepper
  function stepper(view) {
    var labels = [['Who', whoSummary()], ['What', whatSummary()], ['Check & send', '']];
    var ol = h('ol.wz-steps', { 'aria-label': 'Steps' });
    labels.forEach(function (l, i) {
      var n = i + 1;
      var done = n < wz.step;
      var li = h('li.wz-step' + (n === wz.step ? '.is-on' : '') + (done ? '.is-done' : ''), { 'aria-current': n === wz.step ? 'step' : null },
        h('button', { type: 'button', disabled: n > wz.step, onclick: function () { wz.step = n; render(view); } },
          h('span.wz-step__n', { text: done ? '\u2713' : String(n) }), h('span.wz-step__t', h('b', { text: l[0] }), l[1] ? h('small', { text: l[1] }) : null)));
      ol.appendChild(li);
    });
    return ol;
  }
  function whoSummary() {
    if (wz.step <= 1) return '';
    if (wz.who === 'one') return wz.rider ? '@' + (wz.rider.username || wz.rider.name) : '';
    if (wz.who === 'several') return names(wz.usernames).length + ' riders';
    return ES.audienceText(audience());
  }
  function whatSummary() {
    if (wz.step <= 2 || !wz.mode) return '';
    return wz.mode === 'quick' ? 'Quick message' : (wz.pick && wz.pick.name) || 'E-mail';
  }

  // ------------------------------------------------------------------ step 1: who
  function stepWho(box, view) {
    var next = h('button.btn.btn--primary', { type: 'button', text: 'Next: what to send' });
    var panel = h('div.wz-panel');
    var opts = [['one', 'One rider', 'Search by username or e-mail.'], ['several', 'Several riders', 'Paste usernames.'], ['audience', 'An audience', 'A group, e.g. "no ride for 30 days".']];
    var cards = h('div.wz-who', { role: 'radiogroup', 'aria-label': 'Who gets it' });
    opts.forEach(function (o) {
      var c = h('button.wz-card' + (wz.who === o[0] ? '.is-on' : ''), { type: 'button', role: 'radio', 'aria-checked': String(wz.who === o[0]), onclick: function () { wz.who = o[0]; render(view); } },
        h('span.wz-card__dot', { 'aria-hidden': 'true' }), h('b', { text: o[1] }), h('span.small.muted', { text: o[2] }));
      cards.appendChild(c);
    });
    function valid() {
      if (wz.who === 'one') return !!wz.rider;
      if (wz.who === 'several') return names(wz.usernames).length > 0 && names(wz.usernames).length <= 500;
      return true;
    }
    function sync() { next.disabled = !valid(); }
    if (wz.who === 'one') {
      var q = h('input', { type: 'search', placeholder: 'Username, name or e-mail', 'aria-label': 'Find a rider', autocomplete: 'off' });
      var results = h('div.wz-results', { role: 'listbox', 'aria-label': 'Riders' });
      var chosen = h('div');
      var timer = null;
      var drawChosen = function () {
        clear(chosen);
        if (!wz.rider) return;
        var r = wz.rider;
        chosen.appendChild(h('div.wz-rider', CR.riderAvatar ? CR.riderAvatar(r, 40) : null,
          h('div', h('b', { text: r.username ? '@' + r.username : r.name }), h('div.small.muted', { text: [r.name, r.email].filter(Boolean).join(' · ') })),
          h('span.spacer'),
          r.consent === undefined ? null : r.consent ? ui.chip('Agreed to offers', 'ok') : ui.chip('No offer consent', ''),
          r.suppressed ? ui.chip('Blocked: ' + r.suppressed, 'bad') : null,
          h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Change', onclick: function () { wz.rider = null; render(view); } })));
      };
      q.addEventListener('input', function () {
        clearTimeout(timer);
        var v = q.value.trim();
        if (v.length < 2) { clear(results); return; }
        timer = setTimeout(function () {
          api('GET', '/admin/search?q=' + encodeURIComponent(v)).then(function (r) {
            clear(results);
            if (!r.riders.length) { results.appendChild(h('p.small.muted', { text: 'No rider found.' })); return; }
            r.riders.forEach(function (x) {
              results.appendChild(h('button.wz-result', { type: 'button', role: 'option', onclick: function () { pickRider(x.userId); } },
                CR.riderAvatar ? CR.riderAvatar(x, 28) : null, h('b', { text: x.username ? '@' + x.username : x.name }), h('span.small.muted', { text: [x.name, x.email].filter(Boolean).join(' · ') })));
            });
          }).catch(function (e) { clear(results).appendChild(ui.error(e)); });
        }, 250);
      });
      var pickRider = function (userId) {
        loadRider(userId).then(function () { clear(results); q.value = ''; drawChosen(); sync(); }).catch(function (e) { ui.toast(e.message, true); });
      };
      panel.appendChild(h('div.stack', wz.rider ? null : ui.field('Find a rider', q), results, chosen));
      drawChosen();
    } else if (wz.who === 'several') {
      var ta = h('textarea', { rows: '4', placeholder: 'SwiftFalcon482, @RoadRunner77', value: wz.usernames, 'aria-label': 'Usernames' });
      var count = h('span.small.muted');
      var upd = function () { var n = names(ta.value).length; count.textContent = n ? n + ' username' + (n === 1 ? '' : 's') + (n > 500 ? ' (at most 500)' : '') : ''; };
      ta.addEventListener('input', function () { wz.usernames = ta.value; upd(); sync(); });
      upd();
      panel.appendChild(h('div.stack', ui.field('Usernames', ta, 'comma or space separated'), count,
        h('p.small.muted', 'Offers go only to those who agreed to offer e-mails. Account messages: up to 50 riders.', info('Unknown usernames are skipped. Riders who unsubscribed or whose address bounced never get it.'))));
    } else {
      var segs = (ES.config().segments || []).filter(function (s) { return s.kind !== 'usernames' && s.kind !== 'plan'; });
      var sel = ui.select(segs.map(function (s) { return [s.kind, s.label]; }), wz.audience.kind, { 'aria-label': 'Audience' });
      var days = h('input', { type: 'number', min: '1', max: '365', value: String(wz.audience.days || 30), 'aria-label': 'N days' });
      var daysField = ui.field('N days', days);
      var live = h('div.wz-count', { 'aria-live': 'polite' });
      var ct = null;
      var count2 = function () {
        clearTimeout(ct);
        live.textContent = 'Counting…';
        ct = setTimeout(function () {
          var a = audience();
          var seg2 = segs.filter(function (s) { return s.kind === a.kind; })[0] || {};
          Promise.all([api('POST', BASE + '/audience-count', { audience: a, category: 'marketing' }),
            seg2.account ? api('POST', BASE + '/audience-count', { audience: a, category: 'account' }) : Promise.resolve(null)]).then(function (r) {
            clear(live);
            live.appendChild(h('b', { text: String(r[0].riders) }));
            live.appendChild(document.createTextNode(' riders agreed to offers and can get an offer e-mail.'));
            if (r[1]) live.appendChild(h('div.small.muted', { text: r[1].riders + ' can get an account message (about their plan).' }));
          }).catch(function (e) { live.textContent = e.message; });
        }, 300);
      };
      var syncSeg = function () { var s = segs.filter(function (x) { return x.kind === sel.value; })[0] || {}; daysField.hidden = !s.days; };
      sel.addEventListener('change', function () { wz.audience.kind = sel.value; syncSeg(); count2(); });
      days.addEventListener('input', function () { wz.audience.days = Number(days.value); count2(); });
      syncSeg(); count2();
      panel.appendChild(h('div.stack', h('div.es-row2', ui.field('Audience', sel), daysField), live,
        h('p.small.muted', 'Only riders who agreed to offers get offer e-mails.', info('Consent and blocked addresses are checked again for every rider when the e-mail goes out. At most ' + ES.config().settings.maxPerWeek + ' offer e-mails per rider per week.'))));
    }
    next.addEventListener('click', function () { if (valid()) { wz.step = 2; render(view); } });
    sync();
    box.appendChild(h('div.card.stack', h('h2', { text: 'Who gets it?' }), cards, panel, h('div.row.row--end', next)));
  }
  function loadRider(userId) {
    return api('GET', '/admin/riders/' + encodeURIComponent(userId)).then(function (d) {
      wz.rider = { userId: d.rider.userId, username: d.rider.username, name: d.rider.name, email: d.rider.email, avatarUrl: d.rider.avatarUrl, consent: d.emails.offersConsent, suppressed: d.emails.suppressed };
      return wz.rider;
    });
  }

  // ------------------------------------------------------------------ step 2: what
  function thumb(dsg) {
    var t = h('div.wz-thumb', { 'aria-hidden': 'true' }, h('div.wz-t-brand'));
    (dsg.blocks || []).filter(function (b) { return b.type !== 'footer'; }).slice(0, 6).forEach(function (b) {
      if (b.type === 'heading') t.appendChild(h('div.wz-t-h'));
      else if (b.type === 'text') { t.appendChild(h('div.wz-t-p')); t.appendChild(h('div.wz-t-p.wz-t-p--short')); }
      else if (b.type === 'coupon') t.appendChild(h('div.wz-t-coupon', h('span')));
      else if (b.type === 'button') t.appendChild(h('div.wz-t-btn'));
      else if (b.type === 'image' || b.type === 'header_image') t.appendChild(h('div.wz-t-img'));
      else if (b.type === 'price') t.appendChild(h('div.wz-t-price', h('span'), h('span')));
      else if (b.type === 'divider') t.appendChild(h('div.wz-t-hr'));
    });
    t.appendChild(h('div.wz-t-foot'));
    return t;
  }
  function stepWhat(box, view) {
    var next = h('button.btn.btn--primary', { type: 'button', text: 'Next: check and send' });
    var back = h('button.btn', { type: 'button', text: 'Back', onclick: function () { wz.step = 1; render(view); } });
    if (!wz.mode) {
      var gallery = h('div.stack', ui.loading());
      box.appendChild(h('div.card.stack', h('h2', { text: 'What do you want to send?' }), h('p.muted', { text: 'Pick a template, or write a short message.' }), gallery, h('div.row', back)));
      Promise.all([api('GET', '/admin/email-wizard/templates').catch(function () { return { system: [] }; }), api('GET', BASE + '/templates')]).then(function (r) {
        clear(gallery);
        var grid = h('div.wz-gallery');
        var card = function (t, kind, onPick) {
          var cat = t.category === 'account' ? 'account' : 'marketing';
          return h('button.wz-tpl', { type: 'button', onclick: onPick, 'aria-label': 'Use ' + t.name },
            kind === 'quick' ? h('div.wz-thumb.wz-thumb--quick', { 'aria-hidden': 'true' }, h('span', { text: 'Aa' })) : thumb(t.design),
            h('span.wz-tpl__name', { text: t.name }),
            h('span.row', kind === 'quick' ? ui.chip('Plain text', '') : ui.chip(cat === 'account' ? 'Account' : 'Offer', cat === 'account' ? 'warn' : 'info'), kind === 'saved' ? ui.chip('Saved', '') : null));
        };
        grid.appendChild(card({ name: 'Write a quick message', category: 'account' }, 'quick', function () { wz.mode = 'quick'; wz.pick = { name: 'Quick message' }; render(view); }));
        var pickT = function (t) { wz.mode = 'template'; wz.pick = t; wz.draft = ES.draftFrom(t); wz.personalCode = wz.who === 'one' && t.id === 'coupon_gift'; render(view); };
        (r[0].system || []).forEach(function (t) { grid.appendChild(card(t, 'system', function () { pickT({ id: t.id, system: true, name: t.name, category: t.category, design: t.design }); })); });
        var starters = r[1].starters || [];
        starters.forEach(function (t) { grid.appendChild(card(t, 'starter', function () { pickT(Object.assign({}, t, { starter: true })); })); });
        (r[1].templates || []).forEach(function (t) {
          grid.appendChild(card(t, 'saved', function () {
            api('GET', BASE + '/templates/' + t.templateId).then(function (x) { pickT(x.template); }).catch(function (e) { ui.toast(e.message, true); });
          }));
        });
        gallery.appendChild(grid);
      }).catch(function (e) { clear(gallery).appendChild(ui.error(e)); });
      return;
    }
    var head = h('div.row', h('h2', { text: wz.mode === 'quick' ? 'Write a quick message' : wz.pick.name }), h('span.spacer'),
      h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Choose another', onclick: function () {
        var go = function () { wz.mode = null; wz.pick = null; wz.draft = null; render(view); };
        if (wz.draft && wz.draft.dirty) ui.confirm('Choose another?', 'Your changes to this e-mail are lost.', 'Choose another', true).then(function (ok) { if (ok) go(); }); else go();
      } }));
    var catBox = h('div.wz-cat');
    var drawCat = function () {
      clear(catBox);
      var cur = category();
      var promo = hasPromo();
      var g = h('div.es-seg', { role: 'radiogroup', 'aria-label': 'Kind of e-mail' });
      ['account', 'marketing'].forEach(function (k) {
        var dis = k === 'account' && promo;
        g.appendChild(h('button.btn.btn--sm', { type: 'button', role: 'radio', 'aria-checked': String(cur === k), 'aria-pressed': String(cur === k), disabled: dis, text: CAT[k][0],
          title: dis ? 'A coupon or price makes it an offer e-mail.' : CAT[k][1], onclick: function () { if (wz.mode === 'quick') wz.quick.category = k; else wz.draft.category = k; drawCat(); } }));
      });
      if (promo && cur === 'account') { if (wz.mode === 'quick') wz.quick.category = 'marketing'; else wz.draft.category = 'marketing'; return drawCat(); }
      catBox.appendChild(h('div.row', h('span.small.muted', { text: 'Kind:' }), g, info(CAT[cur][1])));
      catBox.appendChild(h('p.small.' + (cur === 'account' ? 'muted' : 'wz-note'), { text: cur === 'account' ? 'Sent to everyone you picked (except bounced addresses). No coupons or prices.' : 'Only riders who agreed to offer e-mails get it.' }));
    };
    var body = h('div.stack');
    if (wz.mode === 'quick') {
      var subj = h('input', { type: 'text', maxlength: '150', value: wz.quick.subject, placeholder: 'About your crew invite', 'aria-label': 'Subject' });
      var text = h('textarea', { rows: '7', maxlength: '3000', value: wz.quick.text, placeholder: 'Hi {firstName},\n\nWrite your message here. **bold**, *italic*, [a link](/guide).', 'aria-label': 'Message' });
      var btnPage = ui.select([['', 'No button']].concat(ES.config().buttonPaths.map(function (p) { return [p, 'Button to ' + p]; })), wz.quick.button, { 'aria-label': 'Button' });
      var btnLabel = h('input', { type: 'text', maxlength: '40', value: wz.quick.buttonLabel || '', placeholder: 'Open', 'aria-label': 'Button text' });
      var lblField = ui.field('Button text', btnLabel);
      lblField.hidden = !wz.quick.button;
      subj.addEventListener('input', function () { wz.quick.subject = subj.value; sync(); });
      text.addEventListener('input', function () { wz.quick.text = text.value; sync(); });
      btnPage.addEventListener('change', function () { wz.quick.button = btnPage.value; lblField.hidden = !btnPage.value; });
      btnLabel.addEventListener('input', function () { wz.quick.buttonLabel = btnLabel.value; });
      body.appendChild(ui.field('Subject', subj));
      body.appendChild(ui.field('Message', text, 'links only to pages of this site'));
      body.appendChild(h('div.es-row2', ui.field('Button', btnPage, 'optional'), lblField));
    } else {
      var ed = ES.editor(wz.draft, { onChange: function () { drawCat(); drawCoupon(); sync(); } });
      body.appendChild(ed.node);
      ES.activeCoupons().then(ed.setCoupons);
      var couponOpts = h('div');
      var drawCoupon = function () {
        clear(couponOpts);
        var has = wz.draft.design.blocks.some(function (b) { return b.type === 'coupon'; });
        if (!has) return;
        if (wz.who === 'one') {
          var cb = h('input', { type: 'checkbox', checked: wz.personalCode });
          cb.addEventListener('change', function () { wz.personalCode = cb.checked; });
          couponOpts.appendChild(h('label.check', cb, 'Make a personal single-use code for this rider from the chosen coupon', info('Only this rider can use it, once. It ends with the coupon or after 14 days.')));
        } else {
          var on = h('input', { type: 'checkbox', checked: wz.unique.enabled });
          var pre = h('input', { type: 'text', maxlength: '10', value: wz.unique.prefix, placeholder: 'XMAS', 'aria-label': 'Code prefix' });
          var dd = h('input', { type: 'number', min: '1', max: '90', value: String(wz.unique.validDays || 14), 'aria-label': 'Valid days' });
          var f = h('div.grid2', ui.field('Code prefix', pre, '2 to 10 letters or digits'), ui.field('Valid for (days)', dd));
          f.hidden = !on.checked;
          on.addEventListener('change', function () { wz.unique.enabled = on.checked; f.hidden = !on.checked; });
          pre.addEventListener('input', function () { wz.unique.prefix = pre.value.toUpperCase(); });
          dd.addEventListener('input', function () { wz.unique.validDays = Number(dd.value); });
          couponOpts.appendChild(h('div.stack', h('label.check', on, 'Give every rider their own single-use code', info('Each rider gets a code like XMAS-QHR95Q2X that only they can use, once.')), f));
        }
      };
      drawCoupon();
      body.appendChild(couponOpts);
      body.appendChild(h('div.row', h('button.btn.btn--sm', { type: 'button', text: wz.draft.templateId ? 'Save template' : 'Save as template', onclick: function () { ES.saveTemplate(wz.draft, false); } }),
        wz.draft.templateId ? h('button.btn.btn--sm.btn--ghost', { type: 'button', text: 'Save as new', onclick: function () { ES.saveTemplate(wz.draft, true); } }) : null));
    }
    function valid() {
      if (wz.mode === 'quick') return wz.quick.subject.trim() && wz.quick.text.trim();
      return !!wz.draft.design.subject.trim();
    }
    function sync() { next.disabled = !valid(); }
    next.addEventListener('click', function () { if (valid()) { wz.step = 3; render(view); } });
    drawCat(); sync();
    box.appendChild(h('div.card.stack', head, catBox, body, h('div.row', back, h('span.spacer'), next)));
  }

  // ------------------------------------------------------------------ step 3: check & send
  function stepCheck(box, view) {
    var pv = ES.preview();
    var list = h('ul.wz-check', { 'aria-live': 'polite' });
    var problems = h('div');
    var send = h('button.btn.btn--primary', { type: 'button', text: 'Send now', disabled: true });
    var test = h('button.btn', { type: 'button', text: 'Send test to me', title: 'To your own address, with [Test] in the subject' });
    var back = h('button.btn', { type: 'button', text: 'Back', onclick: function () { wz.step = 2; render(view); } });
    var cat = category();
    var cfg = ES.config();
    var item = function (ok, text, tipText) {
      list.appendChild(h('li.wz-ci' + (ok === true ? '.is-ok' : ok === false ? '.is-bad' : '.is-wait'), h('span.wz-ci__icon', { 'aria-hidden': 'true', text: ok === true ? '\u2713' : ok === false ? '!' : '…' }),
        h('span', { text: text }), tipText ? info(tipText) : null));
    };
    var serviceBox = h('div');
    var whenBox = h('div');
    var payload = function () { return { design: design(), category: cat, uniqueCoupon: uniquePayload() }; };
    // Controls: when (campaigns), service message (one rider, offer, no consent).
    if (wz.who !== 'one') {
      var when = ui.select([['now', 'Send now'], ['best', 'At each rider\'s best time (within 24 hours)'], ['later', 'Schedule (India time)']], wz.when, { 'aria-label': 'When' });
      var bestNote = h('p.small.muted', { text: 'Each rider gets it at the hour they usually open the app or their e-mail (Business > Best send time), never in the quiet hours. Riders without a known hour get it now.' });
      var at = h('input', { type: 'datetime-local', value: wz.at, 'aria-label': 'Date and time (IST)' });
      var atField = ui.field('Date and time (IST)', at);
      var nm = h('input', { type: 'text', maxlength: '80', value: wz.name, placeholder: 'Diwali 2026 offer', 'aria-label': 'Name for History' });
      var syncWhen = function () { atField.hidden = when.value !== 'later'; bestNote.hidden = when.value !== 'best'; send.textContent = when.value === 'later' ? 'Schedule' : when.value === 'best' ? 'Send at best times' : 'Send now'; };
      when.addEventListener('change', function () { wz.when = when.value; syncWhen(); });
      at.addEventListener('input', function () { wz.at = at.value; });
      nm.addEventListener('input', function () { wz.name = nm.value; });
      whenBox.appendChild(h('div.stack', h('div.es-row2', ui.field('When', when), atField), bestNote, ui.field('Name in History', nm, 'optional')));
      syncWhen();
    }
    var run = function () {
      clear(list); clear(problems); send.disabled = true;
      var d = payload();
      item(!!(d.design.subject || '').trim(), 'Subject is set');
      var checks = [];
      // Content and links (the server's own checks).
      checks.push(api('POST', BASE + '/check', Object.assign({ forSend: true }, d)).then(function (r) { return { ok: true, warnings: r.warnings || [] }; }, function (e) { return { ok: false, error: e }; }));
      // Preview + consent.
      if (wz.who === 'one') {
        checks.push(api('POST', '/admin/riders/' + encodeURIComponent(wz.rider.userId) + '/preview', Object.assign({ service: wz.service, serviceNote: wz.serviceNote }, d)).then(function (r) { return r; }, function (e) { return { error: e }; }));
      } else {
        checks.push(api('POST', BASE + '/preview', d).then(function (r) { return r; }, function (e) { return { error: e }; }));
        checks.push(api('POST', BASE + '/audience-count', { audience: audience(), category: cat }).then(function (r) { return r; }, function (e) { return { error: e }; }));
      }
      Promise.all(checks).then(function (r) {
        clear(list);
        var ok = !!(d.design.subject || '').trim();
        item(ok, 'Subject is set');
        var chk = r[0];
        item(chk.ok, chk.ok ? 'Links and content are OK' : 'Fix the e-mail: ' + chk.error.message, 'Links may only open pages of this site. Variables must be known. A coupon must be active.');
        if (!chk.ok) { problems.appendChild(ES.errorList(chk.error)); ok = false; }
        (chk.warnings || []).forEach(function (w) { problems.appendChild(h('div.banner', { text: w })); });
        var p = r[1];
        if (p && !p.error) pv.show(p); else if (p && p.error) problems.appendChild(ES.errorList(p.error));
        if (wz.who === 'one') {
          var c = p && p.check;
          if (!c) { item(false, 'Could not check this rider'); ok = false; } else if (cat === 'account') {
            item(c.allowed, c.allowed ? 'Account message: no offer consent needed' : c.reason, 'Transactional e-mails go to every rider except bounced or reported addresses.');
            ok = ok && c.allowed;
          } else {
            item(c.allowed, c.allowed ? (c.classification === 'service' ? 'Service message the rider asked for (noted)' : 'The rider agreed to offer e-mails') : c.reason);
            ok = ok && c.allowed;
            if (!c.offersConsent && !(c.suppressed && c.suppressed !== 'unsubscribe')) drawService();
          }
        } else {
          var n = r[2];
          if (n && n.error) { item(false, n.error.message); ok = false; } else {
            item(n.riders > 0, n.riders + ' rider' + (n.riders === 1 ? '' : 's') + ' will get it' + (cat === 'marketing' ? ' (agreed to offers, address not blocked)' : ' (address not blocked)'),
              cat === 'marketing' ? 'Riders without offer consent, unsubscribed or bounced addresses are left out.' : null);
            ok = ok && n.riders > 0;
          }
        }
        var needAddr = cat === 'marketing' || wz.who !== 'one';
        var addrSet = p && p.postalAddressSet;
        item(needAddr ? !!addrSet : true, needAddr ? (addrSet ? 'Postal address is set' : 'Postal address is not set (MAIL_POSTAL_ADDRESS)') : 'Postal address: not needed for an account message',
          'Offer e-mails must show the sender\'s postal address. Set MAIL_POSTAL_ADDRESS in the server config.');
        if (needAddr && !addrSet) ok = false;
        item(!!cfg.enabled, cfg.enabled ? 'E-mail server is set up' : 'E-mail server is not set up (SMTP)');
        if (!cfg.enabled) ok = false;
        send.disabled = !ok;
      });
    };
    var drawService = function () {
      if (serviceBox.firstChild) return;
      var cb = h('input', { type: 'checkbox', checked: wz.service });
      var note = h('input', { type: 'text', maxlength: '300', value: wz.serviceNote, placeholder: 'e.g. Asked for a code on support chat #4411', 'aria-label': 'Why the rider asked' });
      var nf = ui.field('Note (kept in the audit log)', note);
      nf.hidden = !cb.checked;
      cb.addEventListener('change', function () { wz.service = cb.checked; nf.hidden = !cb.checked; if (!cb.checked || wz.serviceNote.trim().length >= 3) run(); });
      var t = null;
      note.addEventListener('input', function () { wz.serviceNote = note.value; clearTimeout(t); t = setTimeout(run, 500); });
      serviceBox.appendChild(h('div.wz-service.stack', h('label.check', cb, 'Service message: the rider asked for it', info('A one-to-one message the rider requested is not marketing. Write why; it is audited.')), nf));
    };
    test.addEventListener('click', function () {
      test.disabled = true;
      api('POST', BASE + '/test', payload()).then(function (r) {
        ui.toast(r.sent ? 'Test sent to ' + r.to + (r.uniqueCode ? ' with your own code ' + r.uniqueCode : '') + '.' : 'Not sent: ' + (r.error || 'unknown error'), !r.sent);
      }).catch(function (e) { ui.toast(e.message, true); }).then(function () { test.disabled = false; });
    });
    send.addEventListener('click', function () {
      var d = payload();
      if (wz.who === 'one') {
        var r0 = wz.rider;
        ui.confirm('Send e-mail', 'Send "' + d.design.subject + '" to @' + (r0.username || r0.name) + ' now?', 'Send').then(function (ok) {
          if (!ok) return;
          send.disabled = true;
          api('POST', '/admin/riders/' + encodeURIComponent(r0.userId) + '/email', Object.assign({ requestId: wz.requestId, service: wz.service, serviceNote: wz.serviceNote, templateId: wz.pick && (wz.pick.templateId || wz.pick.id) || 'quick' }, d)).then(function (r) {
            done(view, { one: true, sent: r.sent, duplicate: r.duplicate, to: r.to, classification: r.classification, couponCode: r.couponCode, error: r.error, rider: r0 });
          }).catch(function (e) { send.disabled = false; clear(problems).appendChild(ES.errorList(e)); ui.toast(e.message, true); });
        });
        return;
      }
      var body = Object.assign({ audience: audience(), name: wz.name || (wz.pick && wz.pick.name) || d.design.subject, templateId: wz.draft && wz.draft.templateId || undefined }, d);
      body.sendAt = wz.when === 'later' ? CR.util.fromLocalInput(wz.at) : 0;
      if (wz.when === 'later' && !body.sendAt) { ui.toast('Choose the date and time.', true); return; }
      if (wz.when === 'best') body.bestTime = true;
      var what = wz.when === 'later' ? 'Schedule this e-mail for ' + CR.util.date(body.sendAt, true) + ' (IST)?' : wz.when === 'best' ? 'Send this e-mail to each rider at their best time in the next 24 hours?' : 'Send this e-mail now?';
      ui.confirm(wz.when === 'later' ? 'Schedule e-mail' : 'Send e-mail', what + ' ' + (cat === 'marketing' ? 'Only riders who agreed to offers get it.' : 'An account message.'), wz.when === 'later' ? 'Schedule' : 'Send').then(function (ok) {
        if (!ok) return;
        send.disabled = true;
        api('POST', BASE + '/campaigns', body).then(function (r) {
          ui.toast(wz.when === 'later' ? 'Scheduled.' : wz.when === 'best' ? 'Queued: each rider gets it at their best time.' : r.quietNow ? 'Queued: quiet hours now; it goes out when they end.' : 'Sending.');
          wz = fresh();
          CR.go('#/email/status/' + r.campaign.campaignId);
        }).catch(function (e) { send.disabled = false; clear(problems).appendChild(ES.errorList(e)); ui.toast(e.message, true); });
      });
    });
    box.appendChild(h('div.wz-check-grid',
      h('div.card.stack', h('h2', { text: 'Check and send' }),
        h('dl.kv', h('dt', { text: 'To' }), h('dd', { text: wz.who === 'one' ? '@' + (wz.rider.username || wz.rider.name) + (wz.rider.email ? ' · ' + wz.rider.email : '') : whoSummary() }),
          h('dt', { text: 'Kind' }), h('dd', h('span', { text: CAT[cat][0] + ' ' }), ui.chip(cat === 'account' ? 'Transactional' : 'Marketing', cat === 'account' ? 'warn' : 'info'))),
        list, serviceBox, problems, whenBox,
        h('div.row', back, h('span.spacer'), h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Re-check', onclick: run }), test, send)),
      h('div.card.stack.wz-pv', h('h3', { text: 'Preview' }), pv.node,
        h('p.small.muted', { text: wz.who === 'one' ? 'Exactly as this rider gets it.' : 'Sample rider "Asha". Each rider gets their own name, code and unsubscribe link.' }))));
    run();
  }

  function done(view, r) {
    wz = fresh();
    clear(view);
    view.appendChild(ui.pageHead('E-mail', null));
    view.appendChild(tabs(''));
    var card = h('div.card.stack.wz-done');
    if (r.sent || r.duplicate) {
      card.appendChild(h('div.wz-done__icon', { 'aria-hidden': 'true', text: '\u2713' }));
      card.appendChild(h('h2', { text: r.duplicate ? 'Already sent' : 'Sent to ' + r.to }));
      card.appendChild(h('p.muted', { text: (r.classification === 'transactional' ? 'Account message' : r.classification === 'service' ? 'Service message (noted in the audit log)' : 'Offer e-mail') + (r.couponCode ? ' · personal code ' + r.couponCode : '') + '.' }));
    } else {
      card.appendChild(h('div.wz-done__icon.is-bad', { 'aria-hidden': 'true', text: '!' }));
      card.appendChild(h('h2', { text: 'Not sent' }));
      card.appendChild(h('p.muted', { text: r.error || 'The mail server refused it. Try again later.' }));
    }
    card.appendChild(h('div.row', h('a.btn', { href: '#/riders/' + encodeURIComponent(r.rider.userId), text: 'Back to @' + (r.rider.username || r.rider.name) }),
      h('button.btn.btn--primary', { type: 'button', text: 'Send another', onclick: function () { wz = fresh(); CR.go('#/email'); } })));
    view.appendChild(card);
  }

  // ------------------------------------------------------------------ status of a campaign
  function renderStatus(view, id) {
    var box = h('div.card.stack', ui.loading());
    view.appendChild(box);
    var load = function () {
      api('GET', BASE + '/campaigns/' + encodeURIComponent(id)).then(function (r) {
        var c = r.campaign; var s = c.stats || {}; var rep = r.report || {};
        var st = ES.STATUS[c.status] || [c.status, ''];
        var processed = (s.sent || 0) + (s.failed || 0) + (s.skipped || 0) + (s.capped || 0);
        var pct = s.targeted ? Math.min(100, Math.round(processed / s.targeted * 100)) : (c.status === 'SENT' ? 100 : 0);
        clear(box);
        box.appendChild(h('div.row', h('h2', { text: c.name }), ui.chip(st[0], st[1]), h('span.spacer'), h('a.btn.btn--sm', { href: '#/email/history', text: 'All sent e-mails' })));
        box.appendChild(h('p.muted', { text: c.design.subject + ' · ' + ES.audienceText(c.audience) + ' · ' + (c.category === 'account' ? 'Account message' : 'Offer e-mail') }));
        var bar = h('div.wz-progress', { role: 'progressbar', 'aria-valuemin': '0', 'aria-valuemax': '100', 'aria-valuenow': String(pct), 'aria-label': 'Progress' }, h('span'));
        bar.firstChild.style.width = pct + '%';
        box.appendChild(bar);
        var tiles = h('div.tiles');
        [['Riders', s.targeted || 0], ['Sent', s.sent || 0], ['Left out', (s.skipped || 0) + (s.capped || 0), 'no consent, blocked or weekly limit'], ['Failed', s.failed || 0],
          ['Clicks', rep.clicks ? rep.clicks.total : 0], ['Coupon uses', rep.redemptions ? rep.redemptions.count : 0]].forEach(function (x) { tiles.appendChild(ui.tile(x[0], String(x[1]), x[2])); });
        box.appendChild(tiles);
        if (c.status === 'SCHEDULED') box.appendChild(h('p', { text: 'Goes out ' + CR.util.date(c.sendAt, true) + ' (IST).' }));
        if (c.error) box.appendChild(h('div.banner.banner--bad', { text: c.error }));
        box.appendChild(h('div.row', h('button.btn', { type: 'button', text: 'Full report', onclick: function () { ES.reportDialog(c.name, c.campaignId); } }),
          c.status === 'SCHEDULED' ? h('button.btn.btn--danger', { type: 'button', text: 'Cancel', onclick: function () {
            ui.confirm('Cancel e-mail?', 'It will not be sent.', 'Cancel e-mail', true).then(function (ok) { if (ok) api('POST', BASE + '/campaigns/' + c.campaignId + '/cancel', {}).then(load).catch(function (e) { ui.toast(e.message, true); }); });
          } }) : null, h('span.spacer'), h('button.btn.btn--primary', { type: 'button', text: 'Send another', onclick: function () { CR.go('#/email'); } })));
        clearTimeout(poll);
        if (c.status === 'SCHEDULED' || c.status === 'SENDING') poll = setTimeout(load, 3000);
      }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
    };
    load();
  }

  // ------------------------------------------------------------------ section
  var currentView = null;
  var lastStep = 0;
  function render(view) {
    currentView = view;
    if (wz.step !== lastStep) { lastStep = wz.step; window.scrollTo(0, 0); }
    clear(view);
    view.appendChild(ui.pageHead('E-mail', 'Send to one rider, a few, or a group, in three steps.'));
    view.appendChild(tabs(''));
    if (!ES.config().enabled) view.appendChild(h('div.banner.banner--bad', { text: 'E-mail is not set up on this server (SMTP_HOST / MAIL_FROM). You can prepare e-mails, but nothing is sent.' }));
    view.appendChild(stepper(view));
    var box = h('div.wz-body');
    view.appendChild(box);
    if (wz.step === 1) stepWho(box, view);
    else if (wz.step === 2) stepWhat(box, view);
    else stepCheck(box, view);
  }
  function applyPrefill() {
    var pre = CR.state.wizardPrefill; CR.state.wizardPrefill = null;
    if (!pre) return Promise.resolve();
    wz = fresh();
    // Round 6 (Business > At risk): a list of riders, already limited to those who agreed to offer e-mails.
    if (Array.isArray(pre.usernames) && pre.usernames.length) { wz.who = 'several'; wz.usernames = pre.usernames.join(', '); wz.step = 2; if (pre.name) wz.name = pre.name; }
    if (pre.template) {
      wz.mode = 'template'; wz.pick = pre.template; wz.draft = ES.draftFrom(pre.template); if (pre.dirty) wz.draft.dirty = true;
      return Promise.resolve();
    }
    if (pre.starter) {
      return api('GET', BASE + '/templates/' + encodeURIComponent(pre.starter)).then(function (r) {
        var t = Object.assign({}, r.template, { starter: true });
        wz.mode = 'template'; wz.pick = t; wz.draft = ES.draftFrom(t, { coupon: pre.coupon });
      }).catch(function () {});
    }
    return Promise.resolve();
  }

  CR.sections.email = {
    title: 'E-mail',
    render: function (view, arg) {
      ES = CR.emailStudio;
      if (!ES) { view.appendChild(h('div.banner.banner--bad', { text: 'The e-mail tools did not load. Reload the page.' })); return; }
      var parts = String(arg || '').split('/');
      var sub = parts[0];
      var wrap = h('div', ui.loading());
      view.appendChild(wrap);
      ES.loadConfig().then(function () {
        clear(view);
        if (['history', 'automations', 'templates', 'settings'].indexOf(sub) >= 0) {
          var lead = { history: 'Everything sent to a group, with results. One-to-one e-mails are on each rider\'s page.', automations: 'E-mails that go out on their own, e.g. "no ride for 30 days".',
            templates: 'Saved e-mails and ready-made ones. Use one to start the wizard.', settings: 'Weekly limit, quiet hours, sender details and blocked addresses.' }[sub];
          view.appendChild(ui.pageHead('E-mail', lead));
          view.appendChild(tabs(sub));
          var inner = h('div.es-view');
          view.appendChild(inner);
          var fn = { history: ES.renderHistory, automations: ES.renderAutomations, templates: ES.renderTemplates, settings: ES.renderSettings }[sub];
          return fn(inner);
        }
        if (sub === 'status' && parts[1]) {
          view.appendChild(ui.pageHead('E-mail', 'Status of what you sent.'));
          view.appendChild(tabs('history'));
          return renderStatus(view, parts[1]);
        }
        if (!wz) wz = fresh();
        return applyPrefill().then(function () {
          if (sub === 'rider' && parts[1]) {
            if (!wz.rider || wz.rider.userId !== parts[1]) { var keep = wz.mode ? wz : null; wz = keep || fresh(); wz.who = 'one'; wz.requestId = rid(); }
            return loadRider(parts[1]).then(function () { if (wz.step === 1) wz.step = 2; render(view); });
          }
          render(view);
        });
      }).catch(function (e) { clear(view).appendChild(ui.error(e)); });
    },
    teardown: function () { clearTimeout(poll); poll = null; currentView = null; },
  };
  void currentView;
})();
