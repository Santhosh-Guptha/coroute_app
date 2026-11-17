/* CoRoute web admin: Command center, Configuration portal, Feature switches, command palette (v3.62).
   #/command   live operations view: health of both nodes, riders online, live rides, open SOS, what needs a look,
               recent admin actions. Refreshes every 15 s while the tab is visible (pause button).
   #/config    every setting in one place, each card with its current value and a link to change it.
   #/features  the admin feature switches on the web (were app-admin only). Safety switches are locked on.
   Ctrl/Cmd + K  command palette: jump to any page or run an action. Icons in the menu. Text is always set as text. */
(function () {
  'use strict';
  var CR = window.CR;
  if (!CR) return;
  var h = CR.util.h, clear = CR.util.clear, ui = CR.ui, api = CR.api;
  var SVG = 'http://www.w3.org/2000/svg';

  // ------------------------------------------------------------------ icons (24 px, stroke)
  var ICONS = {
    command: 'M3 12h4l3-8 4 16 3-8h4', overview: 'M4 19V9m6 10V5m6 14v-7m4 7H2', riders: 'M16 19v-1a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v1M9 10a3 3 0 1 0 0-6 3 3 0 0 0 0 6m13 9v-1a4 4 0 0 0-3-3.9M16 4.1a3 3 0 0 1 0 5.8',
    config: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
    features: 'M7 7h10a5 5 0 0 1 0 10H7A5 5 0 0 1 7 7zm0 7a2 2 0 1 0 0-4 2 2 0 0 0 0 4z', phonesignin: 'M7 2h10a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1zm4 17h2',
    payments: 'M2 7h20v12H2zM2 11h20', pricingmodel: 'M12 2v20M17 6H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6', plans: 'M3 7l9-4 9 4-9 4-9-4zm0 5l9 4 9-4M3 17l9 4 9-4', planfeatures: 'M4 6h16M4 12h10M4 18h6m10-6 2 2 4-4', coupons: 'M3 9a3 3 0 0 0 0 6v3h18v-3a3 3 0 0 0 0-6V6H3zm9-3v12',
    revenue: 'M3 17l6-6 4 4 8-8m0 0h-6m6 0v6', email: 'M3 5h18v14H3zm0 0 9 8 9-8', push: 'M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9m-4.3 13a2 2 0 0 1-3.4 0',
    board: 'M4 4h16v12H5l-1 4z', marketing: 'M3 11l15-6v14L3 13zm4 1v6', explore: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm4 6-2 6-6 2 2-6z', operators: 'M3 21h18M5 21V7l7-4 7 4v14M9 21v-6h6v6',
    engagement: 'M12 17.3 18.2 21l-1.6-7 5.4-4.7-7.2-.6L12 2 9.2 8.7 2 9.3l5.4 4.7L5.8 21z', hazards: 'M12 3 2 21h20zm0 6v5m0 3h.01', crashbrain: 'M9 3a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 6 1V5a2 2 0 0 0-3-2zm6 0a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-6 1',
    riderstops: 'M12 21s-7-6-7-11a7 7 0 0 1 14 0c0 5-7 11-7 11zm0-9a2 2 0 1 0 0-4 2 2 0 0 0 0 4', roadquality: 'M4 20 9 4m6 0 5 16M12 6v2m0 4v2m0 4v2', twisty: 'M4 20c0-6 8-4 8-10S6 6 6 4m8 16c0-4 6-4 6-8', dangertimes: 'M12 7v5l3 2m7-2a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
    dataprivacy: 'M12 2 4 5v6c0 5 3.4 9.7 8 11 4.6-1.3 8-6 8-11V5z', business: 'M3 3v18h18M7 14l4-4 3 3 5-6', retention: 'M21 12a9 9 0 1 1-3-6.7L21 8m0-5v5h-5', conversion: 'M3 4h18l-7 8v6l-4 2v-8z', atrisk: 'M12 9v4m0 4h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0',
    insights: 'M12 2a7 7 0 0 0-4 12.7V17h8v-2.3A7 7 0 0 0 12 2zM9 21h6', sendtimes: 'M22 2 11 13M22 2l-7 20-4-9-9-4z', review: 'M9 11l3 3 8-8M20 12v7a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h9', servers: 'M3 4h18v6H3zm0 10h18v6H3zM7 7h.01M7 17h.01', settings: 'M4 21v-7m0-4V3m8 18v-9m0-4V3m8 18v-5m0-4V3M1 14h6m2-6h6m2 8h6', audit: 'M9 5h11M9 12h11M9 19h11M4 5h.01M4 12h.01M4 19h.01',
    search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zm10 2-4.3-4.3', sos: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 5v6m0 4h.01', live: 'M6 19a3 3 0 1 0 0-6 3 3 0 0 0 0 6zm12 0a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 16l4-8h5l3 8M9 8h3',
  };
  function icon(name, size) {
    var s = document.createElementNS(SVG, 'svg');
    s.setAttribute('viewBox', '0 0 24 24'); s.setAttribute('width', String(size || 18)); s.setAttribute('height', String(size || 18));
    s.setAttribute('fill', 'none'); s.setAttribute('stroke', 'currentColor'); s.setAttribute('stroke-width', '1.8');
    s.setAttribute('stroke-linecap', 'round'); s.setAttribute('stroke-linejoin', 'round'); s.setAttribute('aria-hidden', 'true'); s.setAttribute('class', 'ic');
    var p = document.createElementNS(SVG, 'path'); p.setAttribute('d', ICONS[name] || ICONS.overview); s.appendChild(p);
    return s;
  }
  CR.ui.icon = icon;

  function ago(ms) {
    var s = Math.max(0, Math.round((Date.now() - ms) / 1000));
    if (s < 60) return s + ' s ago'; if (s < 3600) return Math.round(s / 60) + ' min ago';
    if (s < 86400) return Math.round(s / 3600) + ' h ago'; return Math.round(s / 86400) + ' d ago';
  }
  function days(n) { return !n ? 'never' : n + (n === 1 ? ' day' : ' days'); }
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /** Counts up to a number (once per change), so live numbers read as live without jumping. */
  function countTo(el, to) {
    var from = Number(el.dataset.v || 0); el.dataset.v = String(to);
    var fmt = function (n) { return Number(n).toLocaleString('en-IN'); };
    if (reduce || from === to) { el.textContent = fmt(to); return; }
    var t0 = performance.now(), dur = 500;
    (function step(t) { var k = Math.min(1, (t - t0) / dur); el.textContent = fmt(Math.round(from + (to - from) * (1 - Math.pow(1 - k, 3)))); if (k < 1) requestAnimationFrame(step); })(t0);
  }

  // ==================================================================== command center
  var timer = null, paused = false;
  function stop() { if (timer) { clearInterval(timer); timer = null; } }
  function kpi(key, label, iconName, href, tone) {
    var val = h('div.cc-kpi__value', { text: '-' });
    var note = h('div.cc-kpi__note', { text: ' ' });
    var el = h(href ? 'a.cc-kpi' : 'div.cc-kpi', href ? { href: href } : {}, h('div.cc-kpi__top', h('span.cc-kpi__icon', icon(iconName, 18)), h('span.cc-kpi__label', { text: label })), val, note);
    if (tone) el.classList.add('cc-kpi--' + tone);
    el.dataset.key = key;
    return { el: el, val: val, note: note };
  }
  function pill(label, state, text, href) {
    var dot = h('span.cc-dot.cc-dot--' + (state || 'idle'));
    return h(href ? 'a.cc-pill' : 'div.cc-pill', href ? { href: href } : {}, dot, h('span.cc-pill__label', { text: label }), h('span.cc-pill__text', { text: text }));
  }

  CR.sections.command = {
    title: 'Command center',
    teardown: stop,
    render: function (view) {
      stop();
      var stamp = h('span.cc-live__text', { text: 'Connecting…' });
      var pauseBtn = h('button.btn.btn--sm', { type: 'button', text: paused ? 'Resume' : 'Pause' });
      var live = h('div.cc-live', h('span.cc-live__dot'), stamp, pauseBtn);
      view.appendChild(h('div.cc-hero',
        h('div', h('p.cc-eyebrow', { text: 'CoRoute operations' }), h('h1', { text: 'Command center' }), h('p.muted', { text: 'Riders, rides, safety and both servers, live.' })),
        h('span.spacer'), live));
      var strip = h('div.cc-strip');
      view.appendChild(strip);
      var k = {
        online: kpi('online', 'Riders online', 'riders', '#/riders'), rides: kpi('rides', 'Live rides', 'live', null),
        sos: kpi('sos', 'Open SOS', 'sos', null), today: kpi('today', 'Active today', 'overview', '#/overview'), total: kpi('total', 'Riders', 'riders', '#/riders'),
      };
      view.appendChild(h('div.cc-kpis', k.online.el, k.rides.el, k.sos.el, k.today.el, k.total.el));
      var attention = h('ul.cc-list'), activity = h('ul.cc-feed'), nodes = h('div.cc-nodes');
      view.appendChild(h('div.cc-grid',
        h('section.card.cc-card', h('div.cc-card__head', h('h2', { text: 'Needs attention' })), attention),
        h('section.card.cc-card', h('div.cc-card__head', h('h2', { text: 'Recent admin actions' }), h('a.small', { href: '#/audit', text: 'Audit log' })), activity)));
      view.appendChild(h('section.card.cc-card.section-gap', h('div.cc-card__head', h('h2', { text: 'Servers' }), h('a.small', { href: '#/servers', text: 'Details' })), nodes));
      var qa = h('div.cc-actions');
      [['Find a rider', '#/riders', 'riders'], ['Send a push', '#/push', 'push'], ['Send an e-mail', '#/email', 'email'], ['Feature switches', '#/features', 'features'],
        ['Configuration', '#/config', 'config'], ['New coupon', '#/coupons', 'coupons']].forEach(function (a) { qa.appendChild(h('a.cc-action', { href: a[1] }, icon(a[2], 18), h('span', { text: a[0] }))); });
      view.appendChild(h('section.section-gap', h('h2.cc-h2', { text: 'Quick actions' }), qa));

      function load() {
        if (paused || document.hidden) return;
        live.classList.add('is-loading');
        Promise.all([
          api('GET', '/admin/business/servers').catch(function () { return null; }),
          api('GET', '/admin/analytics/overview?days=7').catch(function () { return null; }),
          api('GET', '/admin/features').catch(function () { return null; }),
          api('GET', '/admin/session-settings').catch(function () { return null; }),
          api('GET', '/admin/push/config').catch(function () { return null; }),
          api('GET', '/admin/audit?limit=8').catch(function () { return null; }),
        ]).then(function (r) {
          live.classList.remove('is-loading');
          var srv = r[0], ov = r[1] || {}, fl = r[2], ss = r[3], push = r[4], audit = r[5];
          var att = ov.attention || {}, riders = ov.riders || {};
          var online = srv && srv.nodes ? srv.nodes.reduce(function (a, n) { return a + (Number(n.ridersOnline) || 0); }, 0) : null;
          if (online === null) k.online.val.textContent = '-'; else countTo(k.online.val, online);
          k.online.note.textContent = srv ? srv.nodes.length + (srv.nodes.length === 1 ? ' node' : ' nodes') : 'servers not answering';
          countTo(k.rides.val, Number(att.liveRides) || 0); k.rides.note.textContent = 'group rides on the road';
          var sos = Number(att.openSos) || 0;
          countTo(k.sos.val, sos); k.sos.note.textContent = sos ? 'handle in the app admin now' : 'all clear';
          k.sos.el.classList.toggle('cc-kpi--alarm', sos > 0);
          countTo(k.today.val, Number(riders.activeToday) || 0); k.today.note.textContent = 'opened the app today';
          countTo(k.total.val, Number(riders.total) || 0); k.total.note.textContent = 'accounts (staff left out)';

          clear(strip);
          strip.appendChild(pill('Servers', srv ? srv.status : 'bad', srv ? (srv.status === 'ok' ? 'Healthy' : srv.status === 'warn' ? 'Check' : 'Problem') : 'No answer', '#/servers'));
          strip.appendChild(pill('Push', push ? (push.enabled ? 'ok' : 'bad') : 'idle', push ? (push.enabled ? 'Ready' : 'Not configured') : '-', '#/push'));
          if (fl) {
            var off = fl.features.filter(function (f) { return !f.enabled; }).length;
            strip.appendChild(pill('Feature switches', off ? 'warn' : 'ok', off ? off + ' off' : 'All on', '#/features'));
          }
          if (ss) strip.appendChild(pill('Phone sign-in', 'ok', !ss.appIdleDays && !ss.appAbsoluteDays ? 'Stay signed in' : 'Limit ' + days(ss.appIdleDays || ss.appAbsoluteDays), '#/phonesignin'));
          strip.appendChild(pill('Safety', 'ok', 'SOS, crash, texts locked on', '#/features'));

          clear(attention);
          var todo = [];
          if (sos) todo.push(['bad', sos + ' open SOS', 'Handle in the app admin console (Emergencies).']);
          if (srv && srv.status !== 'ok') todo.push([srv.status === 'bad' ? 'bad' : 'warn', 'Servers need a look', 'See Servers for the node and the check.', '#/servers']);
          if (push && !push.enabled) todo.push(['bad', 'Push is not configured', 'Closed-app SOS pushes and notices cannot go out (FCM_SERVICE_ACCOUNT_JSON).', '#/push']);
          if (att.onHold) todo.push(['warn', att.onHold + ' riders on hold', 'Review them on Riders.', '#/riders']);
          if (att.reportsOpen) todo.push(['warn', att.reportsOpen + ' open reports', 'Public ride reports in the app admin.']);
          if (att.reviewsPending || att.photosPending) todo.push(['info', (att.reviewsPending || 0) + ' reviews, ' + (att.photosPending || 0) + ' photos waiting', 'Moderate in the app admin.']);
          if (!todo.length) attention.appendChild(h('li.cc-empty', icon('review', 20), h('span', { text: 'Nothing needs you right now.' })));
          todo.forEach(function (t) {
            attention.appendChild(h('li.cc-item.cc-item--' + t[0], h('span.cc-dot.cc-dot--' + (t[0] === 'info' ? 'ok' : t[0])),
              h('div', h('strong', { text: t[1] }), h('div.small.muted', { text: t[2] })), t[3] ? h('a.btn.btn--sm', { href: t[3], text: 'Open' }) : null));
          });

          clear(activity);
          var rows = audit && audit.entries ? audit.entries : [];
          if (!rows.length) activity.appendChild(h('li.cc-empty', h('span', { text: 'No admin actions yet.' })));
          rows.forEach(function (e) {
            activity.appendChild(h('li', h('span.cc-feed__dot'), h('div', h('div', h('strong', { text: e.action || 'action' }), e.target ? h('span.muted', { text: ' · ' + e.target }) : null),
              h('div.small.muted', { text: (e.by || 'admin') + ' · ' + ago(e.at) }))));
          });

          clear(nodes);
          if (!srv) nodes.appendChild(h('p.muted', { text: 'The servers did not answer.' }));
          else srv.nodes.forEach(function (n) {
            var lag = Number(n.lagP99Ms) || 0;
            nodes.appendChild(h('div.cc-node',
              h('div.cc-node__head', h('span.cc-dot.cc-dot--' + (n.reachable === false ? 'bad' : n.status || 'idle')), h('strong', { text: n.node || (n.self ? 'This node' : 'Other node') }), n.role ? h('span.chip', { text: n.role }) : null),
              n.reachable === false ? h('p.small.muted', { text: n.error || 'Not reachable' }) : h('div.cc-node__stats',
                h('div', h('span.small.muted', { text: 'Online' }), h('b', { text: String(n.ridersOnline) })),
                h('div', h('span.small.muted', { text: 'Lag p99' }), h('b', { text: lag + ' ms' })),
                h('div', h('span.small.muted', { text: 'Memory' }), h('b', { text: (n.memPct || 0) + '%' })),
                h('div', h('span.small.muted', { text: 'Req/s' }), h('b', { text: n.httpPerSec === null || n.httpPerSec === undefined ? '…' : String(n.httpPerSec) }))),
              n.reachable === false ? null : h('div.cc-meter', { role: 'img', 'aria-label': 'Memory ' + (n.memPct || 0) + ' percent' }, h('span', { style: 'width:' + Math.min(100, Number(n.memPct) || 0) + '%' }))));
          });
          stamp.textContent = 'Live · updated ' + new Date().toLocaleTimeString();
        });
      }
      pauseBtn.addEventListener('click', function () {
        paused = !paused; pauseBtn.textContent = paused ? 'Resume' : 'Pause'; live.classList.toggle('is-paused', paused);
        stamp.textContent = paused ? 'Paused' : stamp.textContent; if (!paused) load();
      });
      live.classList.toggle('is-paused', paused);
      load();
      timer = setInterval(load, 15000);
      document.addEventListener('visibilitychange', function onVis() { if (!timer) { document.removeEventListener('visibilitychange', onVis); return; } if (!document.hidden) load(); });
    },
  };

  // ==================================================================== configuration portal
  var CONFIG = [
    ['Riders and access', [
      ['Access mode', 'Paid, free for everyone, or free up to limits for hosting group rides.', '#/settings', 'plans', 'access'],
      ['Phone sign-in', 'How long riders stay signed in on the app. Changes never sign anyone out.', '#/phonesignin', 'phonesignin', 'session'],
      ['Feature switches', 'Turn app features on or off for everyone. Safety stays on.', '#/features', 'features', 'features'],
    ]],
    ['Plans and money', [
      ['Pricing model', 'Group plans (host buys) or Rider Pass (every rider, all features, monthly).', '#/pricingmodel', 'plans', 'pricingmodel'],
      ['Features by plan', 'What Community, Small Group, Large Group and Rider Pass include, and their limits.', '#/planfeatures', 'planfeatures', 'planfeatures'],
      ['Pricing and payments', 'Plan prices, offers and the payment gateway keys.', '#/settings/pricing', 'payments', null],
      ['Coupons', 'Codes, limits and who may use them.', '#/coupons', 'coupons', null],
    ]],
    ['Messages', [
      ['Push notifications', 'Campaigns, kinds and whether push is configured.', '#/push', 'push', 'push'],
      ['E-mail', 'Weekly limit, quiet hours, sender and blocked addresses.', '#/settings/email', 'email', null],
      ['Message words', 'Receipts, welcome, plan assigned, SMS and push notices.', '#/settings/templates', 'board', null],
      ['SOS SMS', 'The SMS provider for emergency texts.', '#/settings/sms', 'sos', null],
      ['Weekly summary', 'The Monday e-mail to the administrators.', '#/settings/summary', 'audit', null],
    ]],
    ['Community and website', [
      ['Explore', 'Shared routes and what Explore shows.', '#/explore', 'explore', null],
      ['Operators', 'Clubs and tour companies, applications and approvals.', '#/operators', 'operators', null],
      ['Ratings and feedback', 'When the app asks for a rating, and the feedback inbox.', '#/engagement', 'engagement', null],
    ]],
    ['System', [
      ['Servers', 'Both gateway nodes, scheduled jobs and backups.', '#/servers', 'servers', 'servers'],
      ['Intelligence database', 'DB 2 for road intelligence and analytics: not set, copying, or in use.', '#/insights', 'servers', 'inteldb'],
      ['Audit log', 'Every admin change, who and when.', '#/audit', 'audit', null],
    ]],
  ];
  var SUMMARIES = {
    access: function () { return api('GET', '/admin/access-mode').then(function (v) { var m = (v.effective && v.effective.mode) || (v.stored && v.stored.mode) || 'paid'; return [{ paid: 'Paid', free: 'Free for everyone', hybrid: 'Free up to limits' }[m] || m, 'info']; }); },
    session: function () { return api('GET', '/admin/session-settings').then(function (v) { return !v.appIdleDays && !v.appAbsoluteDays ? ['Stay signed in', 'ok'] : ['Limit set', 'warn']; }); },
    features: function () { return api('GET', '/admin/features').then(function (v) { var off = v.features.filter(function (f) { return !f.enabled; }).length; return off ? [off + ' off', 'warn'] : ['All on', 'ok']; }); },
    planfeatures: function () { return api('GET', '/admin/plan-features').then(function (v) { var free = v.plans && v.plans.community ? Object.keys(v.plans.community.features).filter(function (k) { return v.plans.community.features[k]; }).length : 0; return [free + ' on for free', 'info']; }); },
    push: function () { return api('GET', '/admin/push/config').then(function (v) { return v.enabled ? ['Ready', 'ok'] : ['Not configured', 'bad']; }); },
    pricingmodel: function () { return api('GET', '/admin/pricing-model').then(function (v) { return [v.model === 'rider_pass' ? 'Rider Pass' : 'Group plans', 'info']; }); },
    inteldb: function () { return api('GET', '/admin/intel/insights').then(function (v) { var d = v.database || {}; if (!d.separate) return ['DB 1 only', 'info']; if (d.intelDb !== 'UP') return ['DB 2 down', 'bad']; return d.mode === 'intel' ? ['DB 2 in use', 'ok'] : d.mode === 'dual' ? ['Copying to DB 2', 'warn'] : ['DB 2 ready', 'info']; }); },
    servers: function () { return api('GET', '/admin/business/servers').then(function (v) { return [v.status === 'ok' ? 'Healthy' : v.status === 'warn' ? 'Check' : 'Problem', v.status === 'ok' ? 'ok' : v.status === 'warn' ? 'warn' : 'bad']; }); },
  };

  CR.sections.config = {
    title: 'Configuration',
    render: function (view) {
      var q = h('input.cfg-search', { type: 'search', placeholder: 'Find a setting', 'aria-label': 'Find a setting' });
      view.appendChild(h('div.cc-hero', h('div', h('p.cc-eyebrow', { text: 'Configuration portal' }), h('h1', { text: 'Configuration' }), h('p.muted', { text: 'Every setting in one place, with what it is set to now.' })), h('span.spacer'), q));
      var wrap = h('div');
      view.appendChild(wrap);
      var cards = [];
      CONFIG.forEach(function (g) {
        var grid = h('div.cfg-grid');
        var sec = h('section.cfg-group', h('h2.cc-h2', { text: g[0] }), grid);
        g[1].forEach(function (c) {
          var val = h('span.chip', { text: c[4] ? '…' : 'Open' });
          var card = h('a.cfg-card', { href: c[2] }, h('div.cfg-card__top', h('span.cfg-card__icon', icon(c[3], 20)), val), h('h3', { text: c[0] }), h('p.small.muted', { text: c[1] }));
          card.dataset.q = (c[0] + ' ' + c[1] + ' ' + g[0]).toLowerCase();
          grid.appendChild(card);
          cards.push({ card: card, sec: sec });
          if (c[4] && SUMMARIES[c[4]]) SUMMARIES[c[4]]().then(function (r) { val.textContent = r[0]; val.className = 'chip chip--' + r[1]; }, function () { val.textContent = 'Open'; });
        });
        wrap.appendChild(sec);
      });
      q.addEventListener('input', function () {
        var t = q.value.trim().toLowerCase();
        cards.forEach(function (x) { x.card.hidden = !!t && x.card.dataset.q.indexOf(t) < 0; });
        wrap.querySelectorAll('.cfg-group').forEach(function (s) { s.hidden = !s.querySelector('.cfg-card:not([hidden])'); });
      });
    },
  };

  // ==================================================================== feature switches (web)
  CR.sections.features = {
    title: 'Feature switches',
    render: function (view) {
      view.appendChild(ui.pageHead('Feature switches', 'Turn app features on or off for every rider. SOS, crash detection, emergency texts and Medical ID are locked on.'));
      var body = h('div', ui.loading());
      view.appendChild(body);
      function load() {
        api('GET', '/admin/features').then(function (v) {
          clear(body);
          var groups = {};
          v.features.forEach(function (f) { (groups[f.group] = groups[f.group] || []).push(f); });
          Object.keys(groups).forEach(function (g) {
            var list = h('div.fs-list');
            groups[g].forEach(function (f) {
              var sw = h('button.fs-switch', { type: 'button', role: 'switch', 'aria-checked': String(!!f.enabled), 'aria-label': f.label, disabled: f.locked });
              sw.appendChild(h('span.fs-switch__knob'));
              sw.addEventListener('click', function () {
                var next = !f.enabled;
                var reason = h('input', { type: 'text', maxlength: '200', placeholder: 'Why (shown in the audit log)', 'aria-label': 'Reason' });
                ui.dialog({ title: (next ? 'Turn on ' : 'Turn off ') + f.label + '?', body: h('div', h('p', { text: next ? 'Riders get it back within a minute.' : 'Riders lose it within a minute, on both servers.' }), reason),
                  actions: [{ label: 'Cancel', value: null }, { label: next ? 'Turn on' : 'Turn off', kind: next ? 'primary' : 'danger', onClick: function () {
                    return api('PUT', '/admin/features/' + encodeURIComponent(f.id), { enabled: next, reason: reason.value.trim() }).then(function () { ui.toast(f.label + (next ? ' is on.' : ' is off.')); load(); return true; });
                  } }] });
              });
              list.appendChild(h('div.fs-row' + (f.enabled ? '' : '.is-off'),
                h('div.fs-row__text', h('div', h('strong', { text: f.label }), f.locked ? h('span.chip.chip--ok', { text: 'Always on' }) : (!f.enabled ? h('span.chip.chip--warn', { text: 'Off' }) : null)),
                  h('div.small.muted', { text: f.description }),
                  f.lastChange ? h('div.small.muted', { text: 'Last change: ' + (f.lastChange.by || 'admin') + (f.lastChange.at ? ', ' + ago(f.lastChange.at) : '') + (f.lastChange.reason ? ' · ' + f.lastChange.reason : '') }) : null),
                sw));
            });
            body.appendChild(h('section.card.section-gap', h('h2', { text: g }), list));
          });
        }).catch(function (e) { clear(body).appendChild(ui.error(e)); });
      }
      load();
    },
  };

  // ==================================================================== command palette (Ctrl / Cmd + K)
  function entries() {
    var out = [], group = '';
    document.querySelectorAll('#nav > *').forEach(function (n) {
      if (n.classList.contains('nav__group')) { group = n.textContent; return; }
      if (n.tagName === 'A') out.push({ label: n.textContent.trim(), group: group || 'Pages', href: n.getAttribute('href'), icon: n.dataset.section });
    });
    out.push({ label: 'Switch light / dark theme', group: 'Actions', run: function () { var t = document.getElementById('theme'); if (!t) return; t.value = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark'; t.dispatchEvent(new Event('change')); }, icon: 'settings' });
    out.push({ label: 'Search riders, orders, coupons', group: 'Actions', run: function () { var s = document.getElementById('gsearch'); if (s) s.focus(); }, icon: 'search' });
    return out;
  }
  function openPalette() {
    if (document.querySelector('.cmdk')) return;
    var prev = document.activeElement;
    var input = h('input.cmdk__input', { type: 'text', placeholder: 'Jump to a page or run an action', 'aria-label': 'Command', role: 'combobox', 'aria-expanded': 'true', 'aria-controls': 'cmdk-list', autocomplete: 'off' });
    var list = h('ul.cmdk__list#cmdk-list', { role: 'listbox' });
    var box = h('div.cmdk', { role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Command palette' }, h('div.cmdk__bar', icon('search', 18), input, h('kbd', { text: 'Esc' })), list);
    var scrim = h('div.cmdk-scrim', box);
    var all = entries(), shown = [], sel = 0;
    function score(e, t) { var l = (e.label + ' ' + e.group).toLowerCase(); if (!t) return 1; if (l.indexOf(t) === 0) return 3; if (l.indexOf(t) >= 0) return 2; var i = 0; for (var c = 0; c < l.length && i < t.length; c++) if (l[c] === t[i]) i++; return i === t.length ? 1 : 0; }
    function paint() {
      var t = input.value.trim().toLowerCase();
      shown = all.map(function (e) { return { e: e, s: score(e, t) }; }).filter(function (x) { return x.s > 0; }).sort(function (a, b) { return b.s - a.s; }).slice(0, 12).map(function (x) { return x.e; });
      sel = Math.min(sel, Math.max(0, shown.length - 1));
      clear(list);
      if (!shown.length) list.appendChild(h('li.cmdk__empty', { text: 'Nothing found' }));
      shown.forEach(function (e, i) {
        var li = h('li.cmdk__item', { role: 'option', 'aria-selected': String(i === sel), id: 'cmdk-o' + i }, icon(e.icon, 16), h('span', { text: e.label }), h('span.cmdk__group', { text: e.group }));
        li.addEventListener('mousemove', function () { if (sel !== i) { sel = i; paint(); } });
        li.addEventListener('click', function () { go(e); });
        list.appendChild(li);
      });
      input.setAttribute('aria-activedescendant', shown.length ? 'cmdk-o' + sel : '');
    }
    function close() { scrim.remove(); document.removeEventListener('keydown', onKey, true); if (prev && prev.focus) prev.focus(); }
    function go(e) { close(); if (e.run) e.run(); else if (e.href) CR.go(e.href); }
    function onKey(ev) {
      if (ev.key === 'Escape') { ev.preventDefault(); close(); }
      else if (ev.key === 'ArrowDown') { ev.preventDefault(); sel = (sel + 1) % Math.max(1, shown.length); paint(); }
      else if (ev.key === 'ArrowUp') { ev.preventDefault(); sel = (sel - 1 + shown.length) % Math.max(1, shown.length); paint(); }
      else if (ev.key === 'Enter' && shown[sel]) { ev.preventDefault(); go(shown[sel]); }
    }
    input.addEventListener('input', function () { sel = 0; paint(); });
    scrim.addEventListener('mousedown', function (ev) { if (ev.target === scrim) close(); });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(scrim);
    paint();
    input.focus();
  }
  CR.openPalette = openPalette;
  document.addEventListener('keydown', function (e) {
    if ((e.ctrlKey || e.metaKey) && (e.key === 'k' || e.key === 'K')) { e.preventDefault(); openPalette(); }
  });

  // ------------------------------------------------------------------ shell polish: menu icons, palette button
  function polish() {
    document.querySelectorAll('#nav a').forEach(function (a) {
      if (a.querySelector('.ic')) return;
      a.insertBefore(icon(a.dataset.section, 17), a.firstChild);
    });
    var bar = document.querySelector('.topbar');
    if (bar && !bar.querySelector('.cmdk-btn')) {
      var mac = /Mac|iPhone|iPad/.test(navigator.platform || '');
      bar.appendChild(h('button.btn.btn--sm.cmdk-btn', { type: 'button', 'aria-label': 'Open the command palette', onclick: openPalette }, icon('command', 16), h('span', { text: 'Jump to' }), h('kbd', { text: mac ? 'Cmd K' : 'Ctrl K' })));
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', polish); else polish();
})();
