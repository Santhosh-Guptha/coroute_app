/* CoRoute web admin: "Riders" (3.57 round 3, src/admin_riders.js, docs/features_355/web_riders_admin.md).
   #/riders            list: search (username, name, e-mail), filters (plan, status, joined, last ride, role, emergency contact),
                       sort, pages
   #/riders/<userId>   rider page: profile (no medical data), plan and payments, coupons, e-mail choices, rides, diagnostics,
                       audit trail; actions: Assign plan, Give a coupon, Send e-mail (the E-mail wizard), Suspend, Remove picture,
                       Ask for logs
   Every action has a short dialog with a preview and a reason, and is audited on the server. Text is set as text only. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api, date = CR.util.date;
  var PLAN = { community: 'Community', group_small: 'Small Group', group_large: 'Large Group' };
  var STATUS = { ACTIVE: ['Active', 'ok'], ON_HOLD: ['On hold', 'warn'], BLOCKED: ['Blocked', 'bad'] };
  var DAY = 86400000;
  var filters = { q: '', plan: '', status: '', lastRide: '', role: '', emergency: '', joinedFrom: '', joinedTo: '', sort: 'lastActive', staff: '0', page: 1 };

  function rid() { var a = new Uint8Array(10); crypto.getRandomValues(a); return 'r' + Array.prototype.map.call(a, function (x) { return ('0' + x.toString(16)).slice(-2); }).join(''); }
  function info(text) { return h('span.tip', { tabindex: '0', role: 'note', title: text, 'aria-label': text, text: '?' }); }
  function ago(ms) {
    if (!ms) return 'never';
    var d = Date.now() - ms;
    if (d < 3600000) return Math.max(1, Math.round(d / 60000)) + ' min ago';
    if (d < DAY) return Math.round(d / 3600000) + ' h ago';
    if (d < 30 * DAY) return Math.round(d / DAY) + ' days ago';
    return date(ms);
  }
  /** A round avatar: the rider's picture, else their initials. */
  function avatar(r, size) {
    var s = String(size || 32);
    var label = (r.username || r.name || '?').replace(/^@/, '');
    var box = h('span.avatar', { 'aria-hidden': 'true', dataset: { size: s } });
    if (r.avatarUrl) box.appendChild(h('img', { src: r.avatarUrl, alt: '', width: s, height: s, loading: 'lazy', referrerpolicy: 'no-referrer' }));
    else box.textContent = label.slice(0, 2).toUpperCase();
    return box;
  }
  CR.riderAvatar = avatar;
  function planChip(plan, name) { return ui.chip(PLAN[plan] || name || plan || 'Community', plan && plan !== 'community' ? 'info' : ''); }
  function copy(text) {
    var done = function () { ui.toast('Copied ' + text + '.'); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () { ui.toast('Copy failed: select it and copy by hand.', true); });
    else ui.toast('Copy is not available here: select it and copy by hand.', true);
  }

  // ==================================================================== list
  function renderList(view) {
    view.appendChild(ui.pageHead('Riders', 'Find a rider, then assign a plan, give a coupon or send an e-mail.'));
    var q = h('input', { type: 'search', value: filters.q, placeholder: 'Username, name or e-mail', 'aria-label': 'Search riders' });
    var sel = function (key, opts, label) {
      var s = ui.select(opts, filters[key], { 'aria-label': label });
      s.addEventListener('change', function () { filters[key] = s.value; filters.page = 1; load(); });
      return s;
    };
    var plan = sel('plan', [['', 'Any plan'], ['paid', 'Any paid plan'], ['group_small', 'Small Group'], ['group_large', 'Large Group'], ['community', 'Community (free)']], 'Plan');
    var status = sel('status', [['', 'Any status'], ['ACTIVE', 'Active'], ['ON_HOLD', 'On hold'], ['BLOCKED', 'Blocked']], 'Access status');
    var lastRide = sel('lastRide', [['', 'Any last ride'], ['7d', 'Rode in the last 7 days'], ['30d', 'Rode in the last 30 days'], ['90d', 'Rode in the last 90 days'], ['over30d', 'No ride for 30+ days'], ['over90d', 'No ride for 90+ days'], ['never', 'Never rode']], 'Last ride');
    var role = sel('role', [['', 'Any role'], ['operator', 'Operator / club owner'], ['crew_admin', 'Crew admin'], ['admin', 'CoRoute admin']], 'Role');
    var emergency = sel('emergency', [['', 'Emergency contact: any'], ['yes', 'Has emergency contact'], ['no', 'No emergency contact']], 'Emergency contact');
    var sort = sel('sort', [['lastActive', 'Sort: last active'], ['joined', 'Sort: newest'], ['rides', 'Sort: most rides'], ['name', 'Sort: name'], ['planEnds', 'Sort: plan ends soonest']], 'Sort');
    var from = h('input', { type: 'date', value: filters.joinedFrom, 'aria-label': 'Joined from' });
    var to = h('input', { type: 'date', value: filters.joinedTo, 'aria-label': 'Joined until' });
    from.addEventListener('change', function () { filters.joinedFrom = from.value; filters.page = 1; load(); });
    to.addEventListener('change', function () { filters.joinedTo = to.value; filters.page = 1; load(); });
    var staff = h('input', { type: 'checkbox', checked: filters.staff === 'all' });
    staff.addEventListener('change', function () { filters.staff = staff.checked ? 'all' : '0'; filters.page = 1; load(); });
    var timer = null;
    q.addEventListener('input', function () { clearTimeout(timer); timer = setTimeout(function () { filters.q = q.value.trim(); filters.page = 1; load(); }, 250); });
    var reset = h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Clear filters', onclick: function () {
      filters = { q: '', plan: '', status: '', lastRide: '', role: '', emergency: '', joinedFrom: '', joinedTo: '', sort: 'lastActive', staff: '0', page: 1 };
      CR.go('#/riders');
    } });
    view.appendChild(h('div.card.stack.rd-filters',
      h('div.toolbar', q, plan, status, lastRide, sort),
      h('div.toolbar', role, emergency, h('label.field.field--inline', h('span', 'Joined'), from), h('span.small.muted', { text: 'to' }), to,
        h('label.check', staff, 'Include staff'), h('span.spacer'), reset)));
    var out = h('div', ui.loading());
    view.appendChild(out);
    function load() {
      var qs = Object.keys(filters).filter(function (k) { return filters[k] !== '' && filters[k] !== null; }).map(function (k) { return k + '=' + encodeURIComponent(filters[k]); }).join('&');
      api('GET', '/admin/riders?limit=25&' + qs).then(function (r) {
        clear(out);
        var tb = h('tbody');
        r.riders.forEach(function (x) {
          var open = function () { CR.go('#/riders/' + encodeURIComponent(x.userId)); };
          var st = STATUS[x.status] || [x.status, ''];
          tb.appendChild(h('tr.is-link', { tabindex: '0', onclick: open, onkeydown: function (e) { if (e.key === 'Enter') open(); } },
            h('td.rd-who', avatar(x, 32), h('div', h('b', { text: x.username ? '@' + x.username : '(no username)' }), h('div.small.muted', { text: x.email || '' }))),
            h('td', { text: x.name || '-' }),
            h('td', planChip(x.plan, x.planName), x.planValidUntil && x.plan !== 'community' ? h('div.small.muted', { text: 'until ' + date(x.planValidUntil) }) : null),
            h('td.num', { text: String(x.rides) }),
            h('td.nowrap', { text: ago(x.lastSeenAt) }),
            h('td.nowrap', { text: date(x.createdAt) }),
            h('td', x.status !== 'ACTIVE' ? ui.chip(st[0], st[1]) : null, x.operator ? ui.chip('Operator', '') : null, x.crewAdmin ? ui.chip('Crew admin', '') : null,
              !x.hasEmergencyContact ? ui.chip('No emergency contact', 'warn') : null, x.staff ? ui.chip('Staff', '') : null)));
        });
        if (!r.riders.length) {
          out.appendChild(h('div.card.empty-state', h('b', { text: 'No riders match.' }), h('p.muted', { text: 'Try fewer filters or another spelling.' }), reset.cloneNode(true)));
          out.lastChild.lastChild.addEventListener('click', function () { reset.click(); });
          return;
        }
        out.appendChild(h('div.table-wrap', h('table.table.rd-table', h('thead', h('tr', ['Rider', 'Name', 'Plan', 'Rides', 'Last active', 'Joined', ''].map(function (c, i) { return h('th', { class: i === 3 ? 'num' : '', text: c, scope: 'col' }); }))), tb)));
        out.appendChild(h('div.row.pager', h('span.small.muted', { text: r.total + ' rider' + (r.total === 1 ? '' : 's') + (r.excludesStaff && r.staffCount ? ' (staff hidden)' : '') + ' · page ' + r.page + ' of ' + r.pages }),
          h('span.spacer'),
          h('button.btn.btn--sm', { type: 'button', text: '← Previous', disabled: r.page <= 1, onclick: function () { filters.page = r.page - 1; load(); } }),
          h('button.btn.btn--sm', { type: 'button', text: 'Next →', disabled: r.page >= r.pages, onclick: function () { filters.page = r.page + 1; load(); } })));
      }).catch(function (e) { clear(out).appendChild(ui.error(e)); });
    }
    load();
    q.focus();
  }

  // ==================================================================== rider page
  var ACTION_LABELS = {
    'rider.assign_plan': 'Plan assigned', 'subscription.grant': 'Plan granted (ledger)', 'subscription.revoke': 'Plan ended', 'rider.coupon': 'Coupon given', 'rider.email': 'E-mail sent',
    'rider.email.service': 'Service e-mail (rider asked)', 'user.status': 'Access changed', 'user.role': 'Role changed', 'user.limits': 'Limits changed', 'diag.request': 'Logs requested',
    'avatar.remove': 'Picture removed', 'payment.refund': 'Refund', 'rider.ride_lock_end': 'Ride lock ended',
  };
  function auditLine(e) {
    var d = e.details || {};
    var bits = [];
    if (d.plan) bits.push(PLAN[d.plan] || d.plan);
    if (d.days) bits.push(d.days + ' days');
    if (d.code) bits.push(d.code);
    if (d.template) bits.push(d.template);
    if (d.subject) bits.push('"' + d.subject + '"');
    if (d.to) bits.push('to ' + d.to);
    if (d.reason) bits.push('reason: ' + d.reason);
    if (d.serviceNote) bits.push('note: ' + d.serviceNote);
    if (d.sent === false) bits.push('not sent');
    return bits.join(' · ');
  }

  function renderRider(view, userId) {
    var box = h('div', ui.loading());
    view.appendChild(h('p', h('a', { href: '#/riders', text: '← All riders' })));
    view.appendChild(box);
    api('GET', '/admin/riders/' + encodeURIComponent(userId)).then(function (d) { draw(d); }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
    function reload() { CR.go('#/riders/' + encodeURIComponent(userId)); }
    function draw(d) {
      clear(box);
      var r = d.rider; var p = d.plan;
      var st = STATUS[r.status] || [r.status, ''];
      // ---- header
      var more = h('div.menu');
      var moreBtn = h('button.btn', { type: 'button', 'aria-haspopup': 'true', 'aria-expanded': 'false', text: 'More ▾' });
      var menu = h('div.menu__list', { role: 'menu', hidden: true },
        h('button.menu__item', { type: 'button', role: 'menuitem', text: r.status === 'ACTIVE' ? 'Suspend access…' : 'Restore access…', onclick: function () { closeMenu(); suspendDialog(r, reload); } }),
        r.avatarUrl ? h('button.menu__item', { type: 'button', role: 'menuitem', text: 'Remove profile picture…', onclick: function () { closeMenu(); removeAvatar(r, reload); } }) : null,
        h('button.menu__item', { type: 'button', role: 'menuitem', text: 'Ask the app for logs…', onclick: function () { closeMenu(); askLogs(r, reload); } }),
        d.rideLock && d.rideLock.onRide ? h('button.menu__item', { type: 'button', role: 'menuitem', text: 'End ride lock…', onclick: function () { closeMenu(); endRideLock(r, d.rideLock, reload); } }) : null,
        h('a.menu__item', { role: 'menuitem', href: '#/payments', text: 'Payments (refunds)' }));
      function closeMenu() { menu.hidden = true; moreBtn.setAttribute('aria-expanded', 'false'); }
      moreBtn.addEventListener('click', function (e) { e.stopPropagation(); menu.hidden = !menu.hidden; moreBtn.setAttribute('aria-expanded', String(!menu.hidden)); if (!menu.hidden && menu.firstChild) menu.firstChild.focus(); });
      menu.addEventListener('keydown', function (e) { if (e.key === 'Escape') { closeMenu(); moreBtn.focus(); } });
      document.addEventListener('click', function onDoc(e) { if (!document.body.contains(more)) { document.removeEventListener('click', onDoc); return; } if (!more.contains(e.target)) closeMenu(); });
      more.appendChild(moreBtn); more.appendChild(menu);
      box.appendChild(h('div.card.rd-head',
        avatar(r, 64),
        h('div.rd-head__main', h('h1', { text: r.username ? '@' + r.username : (r.name || 'Rider') }),
          h('p.muted', { text: [r.name, r.email].filter(Boolean).join(' · ') }),
          h('div.row', planChip(p.tier, p.name), ui.chip(st[0], st[1]), r.operator ? ui.chip('Operator', '') : null, r.crewAdmin ? ui.chip('Crew admin', '') : null,
            r.role === 'MASTER_ADMIN' ? ui.chip('CoRoute admin', 'info') : null,
            r.hasEmergencyContact ? ui.chip('Emergency contact set', 'ok') : ui.chip('No emergency contact', 'warn'),
            // Round 4 ride lock: "On a ride (device)" (no ride details, no place).
            d.rideLock && d.rideLock.onRide ? ui.chip('On a ride (' + (d.rideLock.device || 'phone') + ')', 'info') : null,
            h('span.small.muted', { text: 'Joined ' + date(r.createdAt) + ' · last active ' + ago(r.lastSeenAt) }))),
        h('div.rd-head__actions',
          h('button.btn.btn--primary', { type: 'button', text: 'Assign plan', onclick: function () { assignDialog(d, reload); } }),
          h('button.btn', { type: 'button', text: 'Give a coupon', onclick: function () { couponDialog(d, reload); } }),
          h('button.btn', { type: 'button', text: 'Send e-mail', onclick: function () { CR.go('#/email/rider/' + encodeURIComponent(r.userId)); } }),
          more)));
      if (r.statusReason) box.appendChild(h('div.banner', { text: 'Access note: ' + r.statusReason }));

      var grid = h('div.rd-grid');
      // ---- plan & payments
      var pay = h('tbody');
      d.payments.forEach(function (o) {
        var refunded = o.refundedInr > 0;
        pay.appendChild(h('tr', h('td.nowrap', { text: date(o.paidAt || o.createdAt) }), h('td', { text: PLAN[o.plan] || o.plan || '-' }),
          h('td.num', { text: o.method === 'ADMIN' ? 'Given' : CR.util.inr(o.amountInr) }),
          h('td', ui.chip(refunded ? 'Refunded ' + CR.util.inr(o.refundedInr) : o.status === 'PAID' ? 'Paid' : o.status.toLowerCase().replace(/_/g, ' '), refunded ? 'warn' : o.status === 'PAID' ? 'ok' : '')),
          h('td.small', o.couponCode ? h('span.mono', { text: o.couponCode }) : null, o.grantedBy ? h('div.muted', { text: 'by ' + o.grantedBy + (o.reason ? ': ' + o.reason : '') }) : null),
          h('td', h('button.btn.btn--ghost.btn--sm', { type: 'button', title: 'Copy order id', text: 'Copy id', onclick: function () { copy(o.orderId); } }))));
      });
      grid.appendChild(h('section.card.stack', h('div.card__head', h('h2', { text: 'Plan and payments' })),
        h('dl.kv', h('dt', { text: 'Plan' }), h('dd', { text: p.name + (p.source === 'legacy' ? ' (older plan)' : '') }),
          h('dt', { text: 'Ends on' }), h('dd', { text: p.validUntil ? date(p.validUntil) + ' (' + p.daysRemaining + ' days left)' : (p.tier === 'community' ? 'Free, no end' : '-') }),
          h('dt', { text: 'Riders' }), h('dd', { text: 'Up to ' + (p.seats || 1) })),
        d.payments.length ? h('div.table-wrap', h('table.table', h('thead', h('tr', ['Date', 'Plan', 'Amount', 'Status', 'Coupon / note', ''].map(function (c, i) { return h('th', { class: i === 2 ? 'num' : '', text: c }); }))), pay))
          : h('p.empty', { text: 'No payments or given plans yet.' })));
      // ---- coupons
      var cp = h('div.stack');
      if (d.coupons.assigned.length) {
        var ct = h('tbody');
        d.coupons.assigned.forEach(function (c) {
          ct.appendChild(h('tr', h('td', h('span.mono', { text: c.code })), h('td', { text: c.discount }), h('td.small', { text: c.source }),
            h('td', ui.chip(c.used ? 'Used' : c.status === 'ACTIVE' ? 'Active' : c.status.toLowerCase().replace(/_/g, ' '), c.used ? '' : c.status === 'ACTIVE' ? 'ok' : '')),
            h('td.nowrap', { text: c.expiresAt ? date(c.expiresAt) : '-' }),
            h('td', h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Copy', onclick: function () { copy(c.code); } }))));
        });
        cp.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Code', 'Discount', 'From', 'Status', 'Ends', ''].map(function (c) { return h('th', { text: c }); }))), ct)));
      } else cp.appendChild(h('p.empty', { text: 'No personal coupons yet.' }));
      if (d.coupons.used.length) {
        cp.appendChild(h('h3', { text: 'Coupons used' }));
        var ut = h('tbody');
        d.coupons.used.forEach(function (c) { ut.appendChild(h('tr', h('td', h('span.mono', { text: c.code })), h('td', { text: c.status }), h('td.num', { text: CR.util.inr(c.discountInr) + ' off' }), h('td.nowrap', { text: date(c.at) }))); });
        cp.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Code', 'Status', 'Discount', 'When'].map(function (c, i) { return h('th', { class: i === 2 ? 'num' : '', text: c }); }))), ut)));
      }
      grid.appendChild(h('section.card.stack', h('div.card__head', h('h2', { text: 'Coupons' }), h('span.spacer'), h('button.btn.btn--sm', { type: 'button', text: 'Give a coupon', onclick: function () { couponDialog(d, reload); } })), cp));
      // ---- e-mails
      var em = d.emails;
      var yes = function (v) { return v === null || v === undefined ? '-' : v ? 'On' : 'Off'; };
      var mailBox = h('section.card.stack', h('div.card__head', h('h2', { text: 'E-mail choices' }), info('Riders change these on their account page. Read-only here.')),
        h('dl.kv', h('dt', { text: 'Account and receipts' }), h('dd', { text: em.hasEmail ? 'Always on' : 'No e-mail address' }),
          h('dt', { text: 'Ride summaries' }), h('dd', { text: yes(em.rideSummaries) }), h('dt', { text: 'Tips and news' }), h('dd', { text: yes(em.tipsNews) }),
          h('dt', { text: 'Offers' }), h('dd', em.offersConsent ? ui.chip('Agreed' + (em.consentUpdatedAt ? ' ' + date(em.consentUpdatedAt) : ''), 'ok') : ui.chip('Not agreed', '')),
          h('dt', { text: 'Blocked address' }), h('dd', em.suppressed ? ui.chip(em.suppressed === 'unsubscribe' ? 'Unsubscribed from offers' : 'Stopped: ' + em.suppressed, em.suppressed === 'unsubscribe' ? 'warn' : 'bad') : h('span', { text: 'No' }))));
      if (em.recent.length) {
        var et = h('tbody');
        em.recent.forEach(function (x) {
          et.appendChild(h('tr', h('td.nowrap', { text: date(x.at, true) }), h('td', { text: x.subject }), h('td', ui.chip(x.classification === 'transactional' ? 'Account' : x.classification === 'service' ? 'Service' : 'Offer', '')),
            h('td', ui.chip(x.status === 'SENT' ? 'Sent' : x.status.toLowerCase(), x.status === 'SENT' ? 'ok' : x.status === 'FAILED' ? 'bad' : ''))));
        });
        mailBox.appendChild(h('h3', { text: 'E-mails from admins' }));
        mailBox.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['When', 'Subject', 'Kind', 'Status'].map(function (c) { return h('th', { text: c }); }))), et)));
      }
      grid.appendChild(mailBox);
      // ---- rides
      var rt = h('tbody');
      d.rides.recent.forEach(function (t) {
        rt.appendChild(h('tr', h('td.nowrap', { text: date(t.endedAt) }), h('td', { text: t.name }), h('td.num', { text: t.km + ' km' }), h('td.num', { text: Math.floor(t.minutes / 60) + ' h ' + (t.minutes % 60) + ' min' }), h('td', t.group ? ui.chip('Group', '') : ui.chip('Solo', ''))));
      });
      grid.appendChild(h('section.card.stack', h('div.card__head', h('h2', { text: 'Rides' })),
        h('div.tiles.tiles--sm', ui.tile('Rides', String(d.rides.count)), ui.tile('Distance', Math.round(d.rides.km) + ' km'), ui.tile('Last ride', d.rides.lastRideAt ? ago(d.rides.lastRideAt) : 'never')),
        d.rides.recent.length ? h('div.table-wrap', h('table.table', h('thead', h('tr', ['Date', 'Ride', 'Distance', 'Time', ''].map(function (c, i) { return h('th', { class: i === 2 || i === 3 ? 'num' : '', text: c }); }))), rt)) : h('p.empty', { text: 'No rides yet.' })));
      // ---- diagnostics
      var dg = h('div.stack');
      if (d.diagnostics.length) {
        var dt = h('tbody');
        d.diagnostics.forEach(function (x) {
          dt.appendChild(h('tr', h('td.nowrap', { text: date(x.at, true) }), h('td', { text: x.reason }), h('td.small', { text: x.build }), h('td.num', { text: Math.round((x.bytes || 0) / 1024) + ' KB' }),
            h('td', h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Download', onclick: function () {
              api('GET', '/admin/diag-logs/' + encodeURIComponent(x.id) + '/download', null, { raw: true }).then(function (res) { return res.blob(); })
                .then(function (b) { CR.download(b, 'coroute-log-' + x.id + '.jsonl.gz'); }).catch(function (e) { ui.toast(e.message, true); });
            } }))));
        });
        dg.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', ['Uploaded', 'Why', 'App build', 'Size', ''].map(function (c, i) { return h('th', { class: i === 3 ? 'num' : '', text: c }); }))), dt)));
      } else dg.appendChild(h('p.empty', { text: 'No log uploads in the last 30 days.' }));
      grid.appendChild(h('section.card.stack', h('div.card__head', h('h2', { text: 'Diagnostics' }), h('span.spacer'), h('button.btn.btn--sm', { type: 'button', text: 'Ask for logs', onclick: function () { askLogs(r, reload); } })), dg));
      box.appendChild(grid);
      // ---- audit
      var at = h('tbody');
      d.audit.forEach(function (e) {
        at.appendChild(h('tr', h('td.nowrap', { text: date(e.at, true) }), h('td', { text: ACTION_LABELS[e.action] || e.action }), h('td.small', { text: auditLine(e) }), h('td.small.muted', { text: e.by || '' })));
      });
      box.appendChild(h('section.card.stack.section-gap', h('div.card__head', h('h2', { text: 'Admin actions on this rider' }), h('span.spacer'), h('a.btn.btn--sm.btn--ghost', { href: '#/audit', text: 'Full audit log' })),
        d.audit.length ? h('div.table-wrap', h('table.table', h('thead', h('tr', ['When', 'Action', 'Details', 'By'].map(function (c) { return h('th', { text: c }); }))), at)) : h('p.empty', { text: 'Nothing yet.' })));
    }
  }

  // ==================================================================== dialogs
  function previewBox() {
    var frame = h('iframe.rd-frame', { title: 'E-mail preview', sandbox: 'allow-popups', referrerpolicy: 'no-referrer' });
    var subj = h('div.small');
    var note = h('div.small.muted');
    var node = h('div.rd-preview', h('div.panel-title', { text: 'E-mail preview' }), subj, h('div.rd-frame-wrap', frame), note);
    var gen = 0;
    return {
      node: node,
      load: function (userId, body) {
        var g = ++gen;
        note.textContent = 'Loading…';
        return api('POST', '/admin/riders/' + encodeURIComponent(userId) + '/preview', body).then(function (r) {
          if (g !== gen) return r;
          frame.src = r.previewUrl; subj.textContent = 'Subject: ' + r.subject; note.textContent = '';
          return r;
        }).catch(function (e) { if (g === gen) note.textContent = e.message; throw e; });
      },
      hide: function (v) { node.hidden = v; },
    };
  }

  function assignDialog(d, reload) {
    var r = d.rider;
    var plan = ui.select([['group_small', 'Small Group'], ['group_large', 'Large Group'], ['community', 'Community (end the plan now)']], d.plan.tier !== 'community' ? d.plan.tier : 'group_small', { 'aria-label': 'Plan' });
    var mode = ui.select([['days', 'For a number of days'], ['until', 'Until a date']], 'days', { 'aria-label': 'Duration' });
    var days = h('input', { type: 'number', min: '1', max: '3660', value: '30', 'aria-label': 'Days' });
    var until = h('input', { type: 'date', 'aria-label': 'Until', min: new Date(Date.now() + DAY).toISOString().slice(0, 10), value: new Date(Date.now() + 30 * DAY).toISOString().slice(0, 10) });
    var daysF = ui.field('Days', days); var untilF = ui.field('Until (India date)', until);
    var reason = h('input', { type: 'text', maxlength: '500', placeholder: 'e.g. Beta tester thank-you', 'aria-label': 'Reason', required: true });
    var send = h('input', { type: 'checkbox', checked: true });
    var summary = h('p.rd-summary');
    var pv = previewBox();
    var durWrap = h('div.es-row2', ui.field('Duration', mode), daysF, untilF);
    function endMs() {
      if (mode.value === 'until') return until.value ? CR.util.dayMs(until.value, true) : 0;
      var n = Number(days.value) || 0;
      var same = d.plan.tier === plan.value && d.plan.validUntil > Date.now();
      return (same ? d.plan.validUntil : Date.now()) + n * DAY;
    }
    var t = null;
    function sync() {
      var comm = plan.value === 'community';
      durWrap.hidden = comm;
      daysF.hidden = mode.value !== 'days'; untilF.hidden = mode.value !== 'until';
      send.parentNode.hidden = comm;
      var e = endMs();
      var same = d.plan.tier === plan.value && d.plan.validUntil > Date.now();
      summary.textContent = comm ? '@' + (r.username || r.name) + ' goes back to Community now. Their group plan ends at once.'
        : '@' + (r.username || r.name) + ' gets ' + PLAN[plan.value] + (same && mode.value === 'days' ? ' (days added to the time left)' : ', starting now') + ', until ' + (e ? date(e) : '…') + '. Nothing to pay.';
      pv.hide(comm || !send.checked);
      clearTimeout(t);
      if (!comm && send.checked && e) t = setTimeout(function () { pv.load(r.userId, { system: 'plan_assigned', planName: PLAN[plan.value], planEndsOn: e }).catch(function () {}); }, 300);
    }
    [plan, mode, days, until, send].forEach(function (el) { el.addEventListener('input', sync); el.addEventListener('change', sync); });
    var body = h('div.rd-dialog',
      h('div.stack', ui.field('Plan', plan), durWrap, ui.field('Reason', reason, 'kept in the audit log'), h('label.check', send, 'Send e-mail to rider ("Plan assigned")', info('An account e-mail with the plan, the end date and a link to their account. Edit its words in Settings > Templates.')), summary),
      pv.node);
    var requestId = rid();
    ui.dialog({ title: 'Assign plan to @' + (r.username || r.name), wide: true, body: [body], actions: [{ label: 'Cancel', value: null }, { label: 'Assign plan', kind: 'primary', onClick: function () {
      if (reason.value.trim().length < 3) { reason.focus(); throw new Error('Write a short reason.'); }
      var b = { plan: plan.value, reason: reason.value.trim(), sendEmail: send.checked && plan.value !== 'community', requestId: requestId };
      if (plan.value !== 'community') { if (mode.value === 'until') b.until = until.value; else b.days = Number(days.value); }
      return api('POST', '/admin/riders/' + encodeURIComponent(r.userId) + '/assign-plan', b).then(function (res) {
        var msg = plan.value === 'community' ? 'Plan ended.' : PLAN[res.plan.tier] + ' assigned until ' + date(res.plan.validUntil) + '.';
        if (res.email) msg += res.email.sent ? ' E-mail sent.' : ' E-mail not sent: ' + (res.email.reason || res.email.error || 'refused') + '.';
        ui.toast(msg, res.email && !res.email.sent);
        reload();
        return true;
      });
    } }] });
    sync();
  }

  function couponDialog(d, reload) {
    var r = d.rider;
    var consent = d.emails.offersConsent;
    var blocked = d.emails.suppressed && d.emails.suppressed !== 'unsubscribe' ? d.emails.suppressed : null;
    var mode = ui.select([['parent', 'From an existing coupon'], ['quick', 'Quick coupon']], 'parent', { 'aria-label': 'Coupon source' });
    var parent = h('select', { 'aria-label': 'Coupon' }, h('option', { value: '', text: 'Loading coupons…' }));
    var qType = ui.select([['percentage', 'Percent off'], ['fixed', 'Amount off (₹)']], 'percentage', { 'aria-label': 'Type' });
    var qVal = h('input', { type: 'number', min: '1', max: '100000', value: '20', 'aria-label': 'Value' });
    var qPlans = ui.select([['', 'Any group plan'], ['group_small', 'Small Group only'], ['group_large', 'Large Group only']], '', { 'aria-label': 'Plans' });
    var parentF = ui.field('Coupon', parent, 'active coupons for everyone');
    var quickF = h('div.grid3', ui.field('Type', qType), ui.field('Value', qVal), ui.field('Works on', qPlans));
    var validDays = h('input', { type: 'number', min: '1', max: '90', value: '14', 'aria-label': 'Valid days' });
    var reason = h('input', { type: 'text', maxlength: '500', placeholder: 'e.g. Ride cancelled by us', 'aria-label': 'Reason' });
    var send = h('input', { type: 'checkbox', checked: consent && !blocked, disabled: !!blocked });
    var service = h('input', { type: 'checkbox' });
    var note = h('input', { type: 'text', maxlength: '300', placeholder: 'e.g. Asked on support chat #4411', 'aria-label': 'Service note' });
    var noteF = ui.field('Why the rider asked (audited)', note);
    var serviceBox = h('div.wz-service.stack', h('label.check', service, 'Service message: the rider asked for it', info('A one-to-one message the rider requested is not marketing. Write why; it is kept in the audit log.')), noteF);
    var consentLine = h('p.small');
    var pv = previewBox();
    var coupons = [];
    api('GET', '/admin/coupons').then(function (res) {
      coupons = (res.coupons || []).filter(function (c) { return c.status === 'ACTIVE' && !c.parentCode && !(c.allowedUserIds && c.allowedUserIds.length); });
      clear(parent);
      if (!coupons.length) { parent.appendChild(h('option', { value: '', text: 'No active coupons: use a quick coupon' })); mode.value = 'quick'; }
      coupons.forEach(function (c) { parent.appendChild(h('option', { value: c.code, text: c.code + ' · ' + couponText(c) + ' · until ' + date(c.expiresAt) })); });
      sync();
    }).catch(function () { clear(parent).appendChild(h('option', { value: '', text: 'Coupons could not load' })); });
    function couponText(c) { var v = Number(c.discountValue) || 0; return c.discountType === 'percentage' ? v + '% off' : c.discountType === 'fixed' ? '₹' + v + ' off' : 'discount'; }
    function sample() {
      if (mode.value === 'quick') return { code: 'GIFT-SAMPLE01', discountType: qType.value, discountValue: Number(qVal.value) || 0, expiresAt: Date.now() + (Number(validDays.value) || 14) * DAY };
      var c = coupons.filter(function (x) { return x.code === parent.value; })[0];
      var letters = c ? c.code.replace(/[^A-Z]/g, '').slice(0, 6) : '';
      return c ? { code: (letters.length >= 2 ? letters : 'GIFT') + '-SAMPLE01', discountType: c.discountType, discountValue: c.discountValue, maxDiscountCap: c.maxDiscountCap, expiresAt: Math.min(Number(c.expiresAt) || Infinity, Date.now() + (Number(validDays.value) || 14) * DAY) } : null;
    }
    var t = null;
    function sync() {
      parentF.hidden = mode.value !== 'parent'; quickF.hidden = mode.value !== 'quick';
      var canMail = !blocked && (consent || service.checked);
      serviceBox.hidden = consent || !!blocked || !send.checked;
      noteF.hidden = !service.checked;
      consentLine.className = 'small ' + (blocked ? 'np-err' : consent ? 'muted' : 'wz-note');
      consentLine.textContent = blocked ? 'E-mails to this address are stopped (' + blocked + '). You will get the code to share yourself.'
        : consent ? '@' + (r.username || r.name) + ' agreed to offer e-mails.'
          : '@' + (r.username || r.name) + ' has not agreed to offer e-mails. Tick "service message" if they asked for it, or untick e-mail and share the code yourself.';
      pv.hide(!send.checked);
      clearTimeout(t);
      var s = sample();
      if (send.checked && s) t = setTimeout(function () { pv.load(r.userId, { system: 'coupon_gift', coupon: s, service: service.checked, serviceNote: note.value }).catch(function () {}); }, 300);
      void canMail;
    }
    [mode, parent, qType, qVal, qPlans, validDays, send, service, note].forEach(function (el) { el.addEventListener('change', sync); el.addEventListener('input', sync); });
    var body = h('div.rd-dialog',
      h('div.stack', ui.field('Coupon', mode), parentF, quickF, ui.field('Valid for (days)', validDays, '1 to 90; never longer than the coupon'),
        ui.field('Reason', reason, 'kept in the audit log'),
        h('p.small.muted', 'A single-use code only @' + (r.username || r.name) + ' can use.', info('Made from the coupon you pick (same discount and plans), one use in total, only for this rider.')),
        h('label.check', send, 'E-mail it to the rider ("Coupon for you")'), consentLine, serviceBox),
      pv.node);
    var requestId = rid();
    ui.dialog({ title: 'Give @' + (r.username || r.name) + ' a coupon', wide: true, body: [body], actions: [{ label: 'Cancel', value: null }, { label: 'Make the code', kind: 'primary', onClick: function () {
      if (reason.value.trim().length < 3) { reason.focus(); throw new Error('Write a short reason.'); }
      if (send.checked && !consent && service.checked && note.value.trim().length < 3) { note.focus(); throw new Error('Write why the rider asked for it.'); }
      var b = { validDays: Number(validDays.value), reason: reason.value.trim(), sendEmail: send.checked, service: service.checked && !consent, serviceNote: note.value.trim(), requestId: requestId };
      if (mode.value === 'parent') { if (!parent.value) throw new Error('Choose a coupon.'); b.parentCode = parent.value; }
      else b.quick = { discountType: qType.value, discountValue: Number(qVal.value), plans: qPlans.value ? [qPlans.value] : [] };
      return api('POST', '/admin/riders/' + encodeURIComponent(r.userId) + '/coupon', b).then(function (res) {
        setTimeout(function () { codeDialog(r, res, reload); }, 0);
        return true;
      });
    } }] });
    sync();
  }
  function codeDialog(r, res, reload) {
    var c = res.coupon; var e = res.email;
    var status = !e ? 'Not e-mailed. Share the code yourself.' : e.sent ? 'E-mailed to ' + e.to + (e.classification === 'service' ? ' as a service message.' : '.') : 'Not e-mailed: ' + (e.reason || e.error || 'refused') + ' Share the code yourself.';
    ui.dialog({ title: 'Code for @' + (r.username || r.name), body: [
      h('div.rd-code', h('span.mono', { text: c.code }), h('button.btn.btn--sm', { type: 'button', text: 'Copy code', onclick: function () { copy(c.code); } })),
      h('p', { text: c.discount + ' · one use · only for this rider · until ' + (c.validUntil || date(c.expiresAt)) + '.' }),
      h('div.row', h('span.small.mono.linkout', { text: c.plansUrl }), h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Copy link', onclick: function () { copy(c.plansUrl); } })),
      h('div.banner' + (e && e.sent ? '.banner--info' : ''), { text: status })],
    actions: [{ label: 'Done', kind: 'primary', value: true }] }).then(reload);
  }

  function suspendDialog(r, reload) {
    var to = ui.select(r.status === 'ACTIVE' ? [['ON_HOLD', 'On hold (can sign in, cannot ride with groups)'], ['BLOCKED', 'Blocked']] : [['ACTIVE', 'Active']], r.status === 'ACTIVE' ? 'ON_HOLD' : 'ACTIVE', { 'aria-label': 'Access' });
    var reason = h('input', { type: 'text', maxlength: '200', placeholder: 'Shown to the rider', 'aria-label': 'Reason' });
    ui.dialog({ title: (r.status === 'ACTIVE' ? 'Suspend ' : 'Restore ') + '@' + (r.username || r.name), body: [ui.field('Access', to), ui.field('Reason', reason, 'audited')],
      actions: [{ label: 'Cancel', value: null }, { label: 'Save', kind: r.status === 'ACTIVE' ? 'danger' : 'primary', onClick: function () {
        if (to.value !== 'ACTIVE' && reason.value.trim().length < 3) throw new Error('Write a short reason.');
        return api('PATCH', '/admin/users/' + encodeURIComponent(r.userId) + '/config', { status: to.value, reason: reason.value.trim() }).then(function () { ui.toast('Access updated.'); reload(); return true; });
      } }] });
  }
  /** Round 4: MASTER_ADMIN only (the API is behind requireAdmin), reason required, audited. */
  function endRideLock(r, lock, reload) {
    var reason = h('input', { type: 'text', maxlength: '300', placeholder: 'For example: rider phoned, phone broken mid-ride', 'aria-label': 'Reason' });
    ui.dialog({ title: 'End ride lock for @' + (r.username || r.name), body: [
      h('p', { text: '@' + (r.username || r.name) + ' is on a ride on ' + (lock.device || 'a phone') + ', so signing in on another device is blocked. Ending the lock lets them sign in elsewhere now. The ride itself and any open SOS are not changed.' }),
      ui.field('Reason', reason, 'audited')],
      actions: [{ label: 'Cancel', value: null }, { label: 'End ride lock', kind: 'danger', onClick: function () {
        if (reason.value.trim().length < 3) throw new Error('Write a short reason.');
        return api('POST', '/admin/riders/' + encodeURIComponent(r.userId) + '/ride-lock/end', { reason: reason.value.trim() }).then(function (res) {
          ui.toast(res.ended ? 'Ride lock ended.' : 'The ride already ended; nothing was locked.');
          reload();
          return true;
        });
      } }] });
  }
  function removeAvatar(r, reload) {
    ui.confirm('Remove profile picture?', 'The picture of @' + (r.username || r.name) + ' is deleted. They can upload a new one.', 'Remove', true).then(function (ok) {
      if (ok) api('DELETE', '/admin/users/' + encodeURIComponent(r.userId) + '/avatar').then(function () { ui.toast('Picture removed.'); reload(); }).catch(function (e) { ui.toast(e.message, true); });
    });
  }
  function askLogs(r, reload) {
    ui.confirm('Ask for logs?', 'The app of @' + (r.username || r.name) + ' is asked to upload its diagnostic logs (no location history, no messages). It shows up under Diagnostics.', 'Ask').then(function (ok) {
      if (ok) api('POST', '/admin/diag-logs/request', { userId: r.userId }).then(function (x) { ui.toast(x.delivered ? 'Asked. The app is online.' : 'Asked. The app gets it when it is next online.'); reload(); }).catch(function (e) { ui.toast(e.message, true); });
    });
  }

  CR.sections.riders = {
    title: 'Riders',
    render: function (view, arg) { if (arg) renderRider(view, arg); else renderList(view); },
  };
})();
