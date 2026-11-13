/* CoRoute web admin: "Business" and "Servers" (round 6, src/business/, docs/intelligence/BUSINESS_ANALYTICS.md).
   Overview (activation funnel, revenue trend, renewals due), Retention (weekly cohorts), Conversion (plans, coupons,
   e-mail campaigns), At risk (churn warning with a win-back e-mail through the e-mail wizard), Send times, Review
   (payment / sign-up signals, never an automatic block), Servers (both nodes, jobs, backups) and the weekly summary
   switch in Settings. The numbers are computed every night on the server; every call is MASTER_ADMIN only. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api, inr = CR.util.inr, date = CR.util.date;
  var BASE = '/admin/business';
  var DOW = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  var timer = null;

  function teardown() { if (timer) { clearInterval(timer); timer = null; } }
  function pct(a, b) { return b > 0 ? Math.round((a / b) * 100) : 0; }
  function weekLabel(ms) { return date(ms).replace(/ \d{4}$/, ''); }
  function ago(ms) {
    if (!ms) return 'never';
    var m = Math.round((Date.now() - ms) / 60000);
    if (m < 2) return 'just now';
    if (m < 90) return m + ' min ago';
    var hrs = Math.round(m / 60);
    return hrs < 48 ? hrs + ' h ago' : Math.round(hrs / 24) + ' days ago';
  }

  /** "Numbers from last night" line with the Refresh button; shown on every Business page. */
  function metaBar(meta, reload) {
    var btn = h('button.btn.btn--ghost.btn--sm', { type: 'button', text: 'Refresh numbers now' });
    btn.addEventListener('click', function () {
      btn.disabled = true; btn.textContent = 'Working…';
      api('POST', BASE + '/refresh', {}).then(function (r) {
        ui.toast(r.done ? 'Numbers refreshed.' : 'Still working. Look again in a minute.');
        reload();
      }).catch(function (e) { ui.toast(e.message, true); btn.disabled = false; btn.textContent = 'Refresh numbers now'; });
    });
    var text = !meta.enabled ? 'Business analytics are switched off on this server.'
      : meta.lastRunAt ? 'Numbers from ' + date(meta.lastRunAt, true) + ' (' + ago(meta.lastRunAt) + '). They are refreshed every night. Staff accounts are left out.'
        : 'No numbers yet. They are computed every night; you can also refresh them now.';
    var bar = h('div.biz-meta', h('span.muted.small', { text: text }), meta.enabled ? btn : null);
    if (meta.truncated && meta.truncated.length) bar.appendChild(h('span.chip.chip--warn', { title: 'The nightly job stopped at its size limit for: ' + meta.truncated.join(', '), text: 'Partial' }));
    return bar;
  }
  function emptyCard(text) { return h('div.card', h('p.empty', { text: text })); }

  /** A page: head, meta bar, body from draw(data, body, reload). */
  function page(spec) {
    return {
      title: spec.title,
      teardown: teardown,
      render: function (view) {
        teardown();
        view.appendChild(ui.pageHead(spec.title, spec.sub));
        var top = h('div');
        var body = h('div', ui.loading());
        view.appendChild(top); view.appendChild(body);
        function load() {
          api('GET', BASE + spec.path).then(function (r) {
            clear(top).appendChild(metaBar(r.meta || { enabled: true }, load));
            clear(body);
            spec.draw(r, body, load);
          }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
        }
        load();
      },
    };
  }

  /** Horizontal bars with the value and the share of the first step (the funnel). */
  function funnelCard(title, sub, f) {
    var steps = [['Signed up', f.signedUp], ['Confirmed their e-mail', f.verified], ['Rode at least once', f.firstRide], ['Rode in a group', f.firstGroupRide], ['Paid for a plan', f.paid]];
    var list = h('div.biz-funnel', { role: 'list' });
    steps.forEach(function (s, i) {
      var share = pct(s[1], f.signedUp);
      var prev = i ? steps[i - 1][1] : 0;
      var bar = h('div.biz-bar__fill');
      bar.style.width = Math.max(share, s[1] ? 2 : 0) + '%';
      list.appendChild(h('div.biz-bar', { role: 'listitem' },
        h('div.biz-bar__label', h('b', { text: s[0] }), h('span.muted.small', { text: i ? (prev ? pct(s[1], prev) + '% of the step before' : '') : 'everyone' })),
        h('div.biz-bar__track', bar),
        h('div.biz-bar__value', h('b', { text: String(s[1]) }), h('span.muted.small', { text: share + '%' }))));
    });
    return h('div.card', h('div.card__head', h('h3', { text: title }), h('p', { text: sub })), list);
  }

  // ==================================================================== overview
  CR.sections.business = page({
    title: 'Business overview', path: '/overview',
    sub: 'How riders move from signing up to riding and paying, what came in, and which plans end soon.',
    draw: function (r, body) {
      if (!r.funnel) { body.appendChild(emptyCard('Nothing computed yet. Use "Refresh numbers now" above.')); return; }
      var wk = r.week || {}; var rev = r.revenue || { weekly: [], renewals: {}, last7: {} };
      body.appendChild(h('div.tiles',
        ui.tile('Riders active, 7 days', String(wk.activeRiders7 || 0), 'of ' + (wk.totalRiders || 0) + ' riders'),
        ui.tile('New riders, 7 days', String(wk.newRiders7 || 0), (wk.ridersRode7 || 0) + ' riders rode'),
        ui.tile('Net revenue, 7 days', inr(rev.last7.netInr, 0), (rev.last7.orders || 0) + ' paid orders'),
        ui.tile('Plans ending in 7 days', String(rev.renewals.in7 || 0), (rev.renewals.in30 || 0) + ' within 30 days'),
        h('a.tile-link', { href: '#/atrisk' }, ui.tile('Riders at risk', String(r.atRisk ? r.atRisk.count : 0), 'open the list'))));
      var grid = h('div.chart-grid');
      grid.appendChild(funnelCard('Activation, sign-ups of the last 90 days', 'Each step counts riders who also did the steps before it.', r.funnel.recent));
      grid.appendChild(funnelCard('Activation, all riders', 'Every rider who ever signed up.', r.funnel.all));
      var w = rev.weekly || [];
      grid.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Net revenue per week' }), h('p', { text: 'Live payments after refunds, by the week they were paid (weeks start on Monday, India time).' })),
        CR.chart({ kind: 'bar', title: 'Net revenue per week', money: true, labels: w.map(function (x) { return weekLabel(x.start); }), values: w.map(function (x) { return x.netInr; }),
          format: function (i) { return inr(w[i].netInr) + ' · ' + w[i].orders + ' orders'; }, tick: function (i) { return (w.length - 1 - i) % 4 === 0 ? weekLabel(w[i].start) : ''; } })));
      var list = (rev.renewals.list || []).slice().sort(function (a, b) { return a.until - b.until; });
      var rn = h('div.card', h('div.card__head', h('h3', { text: 'Renewals due' }), h('p', { text: 'Paid plans that end in the next 30 days. The "Plan ends in N days" automation in E-mail can remind them.' })));
      if (!list.length) rn.appendChild(h('p.empty', { text: 'No paid plan ends in the next 30 days.' }));
      else {
        var tb = h('tbody');
        list.slice(0, 12).forEach(function (x) {
          tb.appendChild(h('tr.is-link', { onclick: function () { CR.go('#/riders/' + encodeURIComponent(x.userId)); } },
            h('td', { text: CR.util.planLabel(x.plan) }), h('td.nowrap', { text: date(x.until) }), h('td.num', { text: Math.max(0, Math.ceil((x.until - Date.now()) / 86400000)) + ' days' })));
        });
        rn.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Plan' }), h('th', { text: 'Ends' }), h('th.num', { text: 'In' }))), tb)));
        if (list.length > 12) rn.appendChild(h('p.muted.small', { text: 'Showing 12 of ' + (rev.renewals.in30 || list.length) + '.' }));
      }
      grid.appendChild(rn);
      body.appendChild(grid);
    },
  });

  // ==================================================================== retention
  function heatClass(share) { return 'heat-' + (share <= 0 ? 0 : share < 10 ? 1 : share < 25 ? 2 : share < 45 ? 3 : share < 65 ? 4 : 5); }
  CR.sections.retention = page({
    title: 'Retention', path: '/retention',
    sub: 'Riders by the week they signed up, and the share of them who rode at least once in each week after.',
    draw: function (r, body) {
      var ret = r.retention;
      if (!ret) { body.appendChild(emptyCard('Nothing computed yet. Use "Refresh numbers now" above.')); return; }
      var cohorts = ret.cohorts.filter(function (c) { return c.size > 0; });
      if (!cohorts.length) { body.appendChild(emptyCard('No sign-ups in the last ' + ret.weeks + ' weeks.')); return; }
      var head = h('tr', h('th', { text: 'Signed up in the week of' }), h('th.num', { text: 'Riders' }));
      for (var k = 0; k < ret.weeks; k++) head.appendChild(h('th.num', { text: k === 0 ? 'Week 0' : '+' + k }));
      var tb = h('tbody');
      ret.cohorts.forEach(function (c) {
        if (!c.size) return;
        var tr = h('tr', h('th.nowrap', { scope: 'row', text: weekLabel(c.start) }), h('td.num', { text: String(c.size) }));
        for (var i = 0; i < ret.weeks; i++) {
          if (i >= c.active.length) { tr.appendChild(h('td.heat.heat-na', { 'aria-label': 'not yet' })); continue; }
          var share = pct(c.active[i], c.size);
          tr.appendChild(h('td.heat.' + heatClass(share), { title: c.active[i] + ' of ' + c.size + ' riders rode in week ' + (i === 0 ? '0 (the sign-up week)' : '+' + i), text: share + '%' }));
        }
        tb.appendChild(tr);
      });
      body.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Weekly cohorts' }), h('p', { text: 'Read a row left to right: week 0 is the week they signed up. Darker = more of them rode. "Rode" means a ride with a finished ride report.' })),
        h('div.table-wrap', h('table.table.biz-cohort', h('thead', head), tb)),
        h('div.biz-legend', { 'aria-hidden': 'true' }, h('span.muted.small', { text: 'Share who rode:' }),
          ['0%', '<10%', '<25%', '<45%', '<65%', '65%+'].map(function (t, i) { return h('span.heat.heat-' + i, { text: t }); }))));
    },
  });

  // ==================================================================== conversion
  CR.sections.conversion = page({
    title: 'Conversion', path: '/conversion',
    sub: 'Which plans, coupons and e-mail campaigns turn into paid plans.',
    draw: function (r, body) {
      var c = r.conversion;
      if (!c) { body.appendChild(emptyCard('Nothing computed yet. Use "Refresh numbers now" above.')); return; }
      var paid = c.plans.reduce(function (a, p) { return a + p.paid; }, 0);
      var created = c.plans.reduce(function (a, p) { return a + p.created; }, 0);
      var views = c.planViews && c.planViews.tracked ? c.planViews.views30 : null;
      body.appendChild(h('div.tiles',
        ui.tile('Plans page views, 30 days', views === null ? '-' : String(views), views === null ? 'not counted yet' : 'cookieless page counter'),
        ui.tile('Orders started', String(created), 'all time, live mode'),
        ui.tile('Orders paid', String(paid), pct(paid, created) + '% of started'),
        ui.tile('Coupons used', String(c.coupons.reduce(function (a, x) { return a + (x.redeemed || 0); }, 0)), inr(c.coupons.reduce(function (a, x) { return a + x.discountInr; }, 0), 0) + ' discount given')));
      function table(title, sub, cols, rows, empty) {
        var card = h('div.card', h('div.card__head', h('h3', { text: title }), h('p', { text: sub })));
        if (!rows.length) { card.appendChild(h('p.empty', { text: empty })); return card; }
        var tb = h('tbody');
        rows.forEach(function (row) { tb.appendChild(h('tr', cols.map(function (col) { return h('td' + (col[2] ? '.num' : ''), { text: col[1](row) }); }))); });
        card.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', cols.map(function (col) { return h('th' + (col[2] ? '.num' : ''), { text: col[0] }); }))), tb)));
        return card;
      }
      body.appendChild(table('Plans', 'Orders by plan. "Paid" includes orders that were later refunded; net is after refunds.',
        [['Plan', function (p) { return CR.util.planLabel(p.plan); }], ['Started', function (p) { return String(p.created); }, 1], ['Paid', function (p) { return String(p.paid); }, 1],
          ['Paid of started', function (p) { return pct(p.paid, p.created) + '%'; }, 1], ['Failed', function (p) { return String(p.failed); }, 1], ['Refunded', function (p) { return String(p.refunded); }, 1], ['Net', function (p) { return inr(p.netInr, 0); }, 1]],
        c.plans, 'No orders yet.'));
      body.appendChild(table('Coupons', 'Uses of each code. Revenue is what riders paid with the code, after refunds.',
        [['Code', function (x) { return x.code; }], ['Used', function (x) { return String(x.redeemed || x.paid || 0); }, 1], ['Free activations', function (x) { return String(x.free || 0); }, 1],
          ['Discount given', function (x) { return inr(x.discountInr, 0); }, 1], ['Revenue', function (x) { return inr(x.revenueInr, 0); }, 1]],
        c.coupons, 'No coupon was used yet.'));
      body.appendChild(table('E-mail campaigns', 'From the e-mail reports: sent, riders who clicked, coupon uses by riders who got the e-mail, and what they paid.',
        [['Campaign', function (x) { return x.name; }], ['Sent on', function (x) { return date(x.sentAt); }], ['Sent', function (x) { return String(x.sent); }, 1], ['Clicked', function (x) { return x.clicks + ' (' + pct(x.clicks, x.sent) + '%)'; }, 1],
          ['Coupon used', function (x) { return x.couponCode ? String(x.redeemed) : '-'; }, 1], ['Revenue', function (x) { return x.couponCode ? inr(x.revenueInr, 0) : '-'; }, 1], ['Unsubscribed', function (x) { return String(x.unsubscribed); }, 1]],
        c.campaigns || [], 'No e-mail campaign was sent yet.'));
    },
  });

  // ==================================================================== at risk
  function scoreChip(score) { return ui.chip(String(score), score >= 70 ? 'bad' : 'warn'); }
  function winback(userIds) {
    return api('POST', BASE + '/churn/winback', userIds ? { userIds: userIds } : {}).then(function (r) {
      if (!r.mailable) { ui.toast('None of these riders agreed to offer e-mails, so none can be mailed.', true); return; }
      CR.state.wizardPrefill = { starter: r.starter, usernames: r.usernames, name: 'Win-back: riders at risk' };
      ui.toast(r.mailable + ' riders can get it' + (r.notMailable ? '; ' + r.notMailable + ' did not agree to offer e-mails' : '') + '.');
      CR.go('#/email');
    }).catch(function (e) { ui.toast(e.message, true); });
  }
  CR.sections.atrisk = page({
    title: 'At risk this week', path: '/churn?limit=50',
    sub: 'Riders who look like they are drifting away: riding less, not opening the app, or a plan that is ending. A warning to act on, not a verdict.',
    draw: function (r, body) {
      var m = r.model || {};
      body.appendChild(h('div.tiles',
        ui.tile('On the list', String(r.total), 'score ' + r.minScore + ' or more'),
        ui.tile('High risk', String(r.counts ? r.counts.high : 0), 'score 70 or more'),
        ui.tile('Riders scored', String(r.counts ? r.counts.scored : 0), 'rode once or held a plan'),
        ui.tile('Learned model', m.active ? 'In use' : 'Not yet', m.active ? 'checked on ' + m.heldOut + ' riders (AUC ' + m.auc + ')' : (m.reason || 'needs more history'))));
      body.appendChild(h('details.card.biz-how', h('summary', { text: 'How the score works' }),
        h('p', { text: 'Points are added for plain facts: no ride for more than 14, 30 or 60 days (15, 30, 40 points); riding half as much as before, or not at all (20, 25); a plan that ends within 14 days (15) or ended and was not renewed (20); the app not opened for more than 14 or 30 days (10, 20). The score is capped at 100, and the facts behind it are listed for each rider.' }),
        h('p', { text: 'When at least 200 riders have enough history, a small learned model (a logistic regression on ride counts and dates only) is trained every night and checked on riders it has not seen. If it is reliable, its probability is shown next to the rule score. It never uses positions, speeds or messages.' })));
      if (!r.riders.length) { body.appendChild(emptyCard(r.meta && r.meta.lastRunAt ? 'No rider is at risk this week.' : 'Nothing computed yet. Use "Refresh numbers now" above.')); return; }
      var mailable = r.riders.filter(function (x) { return x.mailable; });
      var send = h('button.btn.btn--primary', { type: 'button', text: 'Send win-back e-mail (' + mailable.length + ')', disabled: !mailable.length });
      send.addEventListener('click', function () { send.disabled = true; winback(null).then(function () { send.disabled = false; }); });
      body.appendChild(h('div.toolbar', send, h('span.muted.small', { text: 'Opens the e-mail wizard with the riders who agreed to offer e-mails. You check and send it there. ' + (r.riders.length - mailable.length) + ' on this page did not agree and cannot be mailed.' })));
      var tb = h('tbody');
      r.riders.forEach(function (x) {
        var why = h('ul.biz-factors');
        x.factors.forEach(function (f) { why.appendChild(h('li', { text: f.label })); });
        var one = h('button.btn.btn--sm', { type: 'button', text: 'E-mail', disabled: !x.mailable, title: x.mailable ? 'Open the e-mail wizard for this rider' : x.whyNot });
        one.addEventListener('click', function (e) { e.stopPropagation(); winback([x.userId]); });
        tb.appendChild(h('tr',
          h('td', h('a', { href: '#/riders/' + encodeURIComponent(x.userId), text: x.username ? '@' + x.username : x.name || 'Rider' }), x.name && x.username ? h('div.muted.small', { text: x.name }) : null),
          h('td.num', scoreChip(x.score), x.modelScore !== undefined ? h('div.muted.small', { title: 'Probability from the learned model', text: 'model ' + x.modelScore + '%' }) : null),
          h('td', why),
          h('td.nowrap', { text: x.lastRideAt ? date(x.lastRideAt) : 'never' }),
          h('td.nowrap', { text: x.planEndsAt ? date(x.planEndsAt) : '-' }),
          h('td', x.mailable ? ui.chip('Can be mailed', 'ok') : ui.chip(x.whyNot || 'Cannot be mailed'), h('div.biz-act', one))));
      });
      body.appendChild(h('div.table-wrap', h('table.table.biz-risk', h('thead', h('tr', h('th', { text: 'Rider' }), h('th.num', { text: 'Score' }), h('th', { text: 'Why' }), h('th', { text: 'Last ride' }), h('th', { text: 'Plan ends' }), h('th', { text: 'Offer e-mails' }))), tb)));
      if (r.total > r.riders.length) body.appendChild(h('p.muted.small', { text: 'Showing the ' + r.riders.length + ' highest scores of ' + r.total + '.' }));
    },
  });

  // ==================================================================== send times
  CR.sections.sendtimes = page({
    title: 'Best send time', path: '/sendtime',
    sub: 'When each rider usually opens the app or clicks an e-mail, by hour of the week (India time). The e-mail wizard can send "at each rider\'s best time".',
    draw: function (r, body) {
      var s = r.sendtime;
      if (!s || !s.withBest) {
        body.appendChild(emptyCard('Not enough app opens counted yet. A rider gets a best time after about five opens or clicks; riders without one get e-mails at the scheduled time.'));
        return;
      }
      var topHour = 0;
      for (var i = 1; i < 24; i++) if (s.hours[i] > s.hours[topHour]) topHour = i;
      body.appendChild(h('div.tiles',
        ui.tile('Riders with a best time', String(s.withBest), 'of ' + s.riders + ' with any count'),
        ui.tile('Most common hour', String(topHour).padStart(2, '0') + ':00', s.hours[topHour] + ' riders'),
        ui.tile('Used by', 'E-mail wizard', '"At each rider\'s best time"')));
      var max = Math.max.apply(null, s.grid.concat([1]));
      var head = h('tr', h('th', { text: '' }));
      for (var hh = 0; hh < 24; hh++) head.appendChild(h('th.num', { text: hh % 3 === 0 ? String(hh).padStart(2, '0') : '' }));
      var tb = h('tbody');
      DOW.forEach(function (d, di) {
        var tr = h('tr', h('th', { scope: 'row', text: d }));
        for (var x = 0; x < 24; x++) {
          var n = s.grid[di * 24 + x];
          var share = n ? Math.max(1, Math.round((n / max) * 100)) : 0;
          tr.appendChild(h('td.heat.heat-cell.' + heatClass(share * 0.8), { title: n + ' riders prefer ' + d + ' ' + String(x).padStart(2, '0') + ':00', text: n ? String(n) : '' }));
        }
        tb.appendChild(tr);
      });
      body.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Riders by preferred hour of the week' }), h('p', { text: 'Each rider counts once, in the hour they are most often active. Quiet hours (E-mail > Settings) are always respected: an e-mail due in a quiet hour waits until they end.' })),
        h('div.table-wrap', h('table.table.biz-hours', h('thead', head), tb))));
    },
  });

  // ==================================================================== review
  var SEV = { 3: ['High', 'bad'], 2: ['Medium', 'warn'], 1: ['Low', ''] };
  CR.sections.review = page({
    title: 'Review list', path: '/review',
    sub: 'Patterns worth a look: many accounts on one phone, many failed payments, refunds, coupon orders left unpaid, bursts of sign-ups. Nothing here blocks anyone; you decide.',
    draw: function (r, body, reload) {
      body.appendChild(h('div.banner.banner--info', { text: 'These are signals, not proof. A family sharing a phone, a club signing up together or a card that keeps failing look the same. Open the rider before acting; holding or blocking an account is done on the rider page, by you.' }));
      if (!r.items.length) { body.appendChild(emptyCard(r.meta && r.meta.lastRunAt ? 'Nothing to review.' : 'Nothing computed yet. Use "Refresh numbers now" above.')); return; }
      var open = r.items.filter(function (x) { return x.review.status !== 'REVIEWED'; });
      body.appendChild(h('div.tiles', ui.tile('To review', String(open.length)), ui.tile('High', String(open.filter(function (x) { return x.severity >= 3; }).length)), ui.tile('Reviewed', String(r.items.length - open.length))));
      var tb = h('tbody');
      r.items.forEach(function (x) {
        var who = h('div.biz-who');
        x.riders.forEach(function (u) { who.appendChild(h('a', { href: '#/riders/' + encodeURIComponent(u.userId), text: u.username ? '@' + u.username : u.name || 'Rider' })); });
        if (x.count > x.riders.length && x.riders.length && (x.type === 'device_accounts' || x.type === 'signup_network')) who.appendChild(h('span.muted.small', { text: '+' + (x.count - x.riders.length) + ' more' }));
        var done = x.review.status === 'REVIEWED';
        var btn = h('button.btn.btn--sm', { type: 'button', text: done ? 'Open again' : 'Mark reviewed' });
        btn.addEventListener('click', function () {
          btn.disabled = true;
          api('POST', BASE + '/review/' + x.id, { status: done ? 'OPEN' : 'REVIEWED' }).then(function () { ui.toast(done ? 'Opened again.' : 'Marked as reviewed.'); reload(); }).catch(function (e) { ui.toast(e.message, true); btn.disabled = false; });
        });
        tb.appendChild(h('tr' + (done ? '.is-done' : ''),
          h('td', h('b', { text: x.label }), h('div.muted.small', { text: x.note })),
          h('td', ui.chip(SEV[x.severity][0], SEV[x.severity][1])),
          h('td', x.riders.length ? who : h('span.muted.small', { text: x.at ? date(x.at, true) : '-' })),
          h('td', done ? h('span.muted.small', { text: 'Reviewed ' + date(x.review.at) + (x.review.by ? ' by ' + x.review.by : '') }) : ui.chip('To review', 'info')),
          h('td.num', btn)));
      });
      body.appendChild(h('div.table-wrap', h('table.table.biz-review', h('thead', h('tr', h('th', { text: 'Signal' }), h('th', { text: 'Level' }), h('th', { text: 'Riders' }), h('th', { text: 'Status' }), h('th', { text: '' }))), tb)));
    },
  });

  // ==================================================================== servers
  var WORD = { ok: ['Healthy', 'ok'], warn: ['Needs a look', 'warn'], bad: ['Needs attention', 'bad'] };
  function statusChip(s) { var w = WORD[s] || WORD.ok; return ui.chip(w[0], w[1]); }
  function uptime(s) { return s < 3600 ? Math.round(s / 60) + ' min' : s < 172800 ? Math.round(s / 3600) + ' h' : Math.round(s / 86400) + ' days'; }
  function metric(label, value, level, hint) {
    return h('div.srv-metric' + (level && level !== 'ok' ? '.is-' + level : ''), h('div.srv-metric__label', { text: label }), h('div.srv-metric__value', { text: value }), hint ? h('div.srv-metric__hint', { text: hint }) : null);
  }
  function nodeCard(n) {
    var title = (n.node || (n.self ? 'This node' : 'Other node')) + (n.role ? ' · ' + n.role : '');
    var card = h('div.card.srv-node', h('div.card__head.row.row--between', h('h3', { text: title }), statusChip(n.status)));
    if (n.reachable === false) { card.appendChild(h('p.banner.banner--bad', { text: n.error })); return card; }
    card.appendChild(h('div.srv-grid',
      metric('Riders online', String(n.ridersOnline), n.checks.riders, n.roomsLoaded + ' rides in memory'),
      metric('Event loop lag', n.lagP99Ms + ' ms', n.checks.lag, 'fine below 50 ms'),
      metric('Memory', n.rssMb + ' MB', n.checks.memory, n.memPct + '% of ' + n.memLimitMb + ' MB · heap ' + n.heapPct + '%'),
      metric('Database calls', n.dbCallsPerSec === null ? '…' : n.dbCallsPerSec + ' /s', n.checks.database, n.dbQueue + ' waiting'),
      metric('Requests', n.httpPerSec === null ? '…' : n.httpPerSec + ' /s', 'ok', 'HTTP, all routes'),
      metric('Shed requests', String(n.shedTotal), n.checks.shedding, n.shedding ? 'shedding now' : 'since start'),
      metric('Link to other node', n.mirrorUp === null ? '-' : n.mirrorUp ? 'Up' : 'Down', n.checks.mirror, 'live mirror'),
      metric('Running for', uptime(n.uptimeS), 'ok', n.version ? 'version ' + n.version : '')));
    if (n.notes.length) { var ul = h('ul.srv-notes'); n.notes.forEach(function (t) { ul.appendChild(h('li', { text: t })); }); card.appendChild(ul); }
    return card;
  }
  CR.sections.servers = {
    title: 'Servers',
    teardown: teardown,
    render: function (view) {
      teardown();
      var state = h('span');
      view.appendChild(ui.pageHead('Servers', 'Both gateway nodes right now, the scheduled jobs and the backups. Refreshes every 15 seconds.', state));
      var body = h('div', ui.loading());
      view.appendChild(body);
      function load() {
        api('GET', BASE + '/servers').then(function (r) {
          clear(state).appendChild(statusChip(r.status));
          clear(body);
          var nodes = h('div.chart-grid');
          r.nodes.forEach(function (n) { nodes.appendChild(nodeCard(n)); });
          if (r.nodes.length < 2) nodes.appendChild(h('div.card.srv-node', h('div.card__head', h('h3', { text: 'Other node' })),
            h('p.muted', { text: r.peerConfigured ? 'The other node did not answer.' : 'This server runs as a single node, or the other node\'s address is not set (PEER_METRICS_URL / MIRROR_PEER_URL).' })));
          body.appendChild(nodes);
          var b = r.backup || {};
          var bk = h('div.card', h('div.card__head.row.row--between', h('h3', { text: 'Backups' }), statusChip(b.status || 'warn')));
          if (!b.known) bk.appendChild(h('p.muted', { text: b.note || 'No backup has reported yet.' }));
          else {
            bk.appendChild(h('div.srv-grid',
              metric('Last full backup', b.fullAgeHours === null ? 'never' : b.fullAgeHours + ' h ago', b.fullAgeHours === null || b.fullAgeHours >= 50 ? 'bad' : b.fullAgeHours >= 26 ? 'warn' : 'ok', 'daily; fine below 26 h'),
              metric('Last hourly backup', b.criticalAgeHours === null ? 'never' : b.criticalAgeHours + ' h ago', b.criticalAgeHours === null || b.criticalAgeHours >= 12 ? 'bad' : b.criticalAgeHours >= 3 ? 'warn' : 'ok', 'accounts, plans, payments')));
            if (b.note) bk.appendChild(h('p.muted.small', { text: b.note }));
          }
          body.appendChild(bk);
          var jobs = h('div.card', h('div.card__head', h('h3', { text: 'Scheduled jobs' }), h('p', { text: 'Each job runs on one node at a time. "Later than expected" means it missed more than two of its turns.' })));
          if (!r.jobs.length) jobs.appendChild(h('p.empty', { text: 'No job has run yet.' }));
          else {
            var tb = h('tbody');
            r.jobs.forEach(function (j) {
              tb.appendChild(h('tr', h('td.mono', { text: j.name }), h('td.nowrap', { text: j.lastRunAt ? ago(j.lastRunAt) : 'not yet' }), h('td', { text: j.lastRunBy || j.heldBy || '-' }),
                h('td', { text: j.everyMs ? (j.everyMs >= 3600000 ? Math.round(j.everyMs / 3600000) + ' h' : j.everyMs >= 60000 ? Math.round(j.everyMs / 60000) + ' min' : Math.round(j.everyMs / 1000) + ' s') : (j.known ? 'once' : '-') }),
                h('td', j.status === 'ok' ? ui.chip('On time', 'ok') : ui.chip(j.note, 'warn'))));
            });
            jobs.appendChild(h('div.table-wrap', h('table.table', h('thead', h('tr', h('th', { text: 'Job' }), h('th', { text: 'Last run' }), h('th', { text: 'On node' }), h('th', { text: 'Every' }), h('th', { text: 'Status' }))), tb)));
          }
          body.appendChild(jobs);
        }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
      }
      load();
      timer = setInterval(load, 15000);
    },
  };

  // ==================================================================== weekly summary (Settings tab)
  CR.renderWeeklySummary = function (box) {
    box.appendChild(ui.loading());
    Promise.all([api('GET', BASE + '/settings'), api('GET', BASE + '/summary/preview')]).then(function (res) {
      var s = res[0]; var p = res[1];
      clear(box);
      var sw = h('input', { type: 'checkbox', checked: s.weeklySummary, 'aria-label': 'Send the weekly summary e-mail' });
      sw.addEventListener('change', function () {
        var on = sw.checked;
        api('PUT', BASE + '/settings', { weeklySummary: on }).then(function () { ui.toast(on ? 'The weekly summary is on.' : 'The weekly summary is off.'); }).catch(function (e) { sw.checked = !on; ui.toast(e.message, true); });
      });
      var test = h('button.btn', { type: 'button', text: 'Send me a test now', disabled: !s.mailConfigured });
      test.addEventListener('click', function () {
        test.disabled = true;
        api('POST', BASE + '/summary/test', {}).then(function (r) { ui.toast(r.sent ? 'Sent to your address.' : 'Could not send it.', !r.sent); }).catch(function (e) { ui.toast(e.message, true); }).then(function () { test.disabled = false; });
      });
      box.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Weekly owner summary' }), h('p', { text: 'A short e-mail every ' + s.sendsAt + ' to the ' + s.recipients + ' administrator ' + (s.recipients === 1 ? 'address' : 'addresses') + ': riders active and new, rides, SOS and crash alerts, revenue, riders at risk and server health. Counts only, no rider names.' })),
        h('label.row.biz-switch', sw, h('span', { text: 'Send the weekly summary e-mail' })),
        s.mailConfigured ? null : h('p.banner', { text: 'E-mail is not configured on this server (SMTP_HOST / MAIL_FROM), so nothing is sent.' }),
        h('div.row', test, h('a.btn.btn--ghost', { href: '#/settings/templates', text: 'Edit the words' }))));
      box.appendChild(h('div.card', h('div.card__head', h('h3', { text: 'Preview with this week\'s numbers' }), h('p', { text: 'Subject: ' + p.subject })), h('pre.biz-preview', { text: p.text })));
    }).catch(function (e) { clear(box).appendChild(ui.error(e)); });
  };
})();
