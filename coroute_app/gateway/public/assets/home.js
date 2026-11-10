/* CoRoute homepage only: starts the 3D hero late, shows how many riders are out right now, and renders the
   pricing cards from the app's plan list. No libraries, no third-party requests, only text nodes (never HTML strings). */
(function () {
  'use strict';
  var doc = document, win = window;
  var fetch = win.fetch ? win.fetch.bind(win) : null;
  var getJSON = function (url) {
    return fetch(url, { headers: { Accept: 'application/json' }, credentials: 'omit' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  };
  var sprite = (function () {
    var u = doc.querySelector('use[href^="/assets/icons.svg"]');
    return u ? u.getAttribute('href').split('#')[0] : '/assets/icons.svg';
  })();
  var icon = function (id, cls) {
    var svg = doc.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'icon' + (cls ? ' ' + cls : ''));
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    var use = doc.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', sprite + '#' + id);
    svg.appendChild(use);
    return svg;
  };
  var el = function (tag, cls, text) {
    var e = doc.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  };

  /* ---------- 3D hero: text first, the scene streams in after the page has loaded ----------
     Not started for reduced motion (the drawing stays), on save-data, or when the scene script fails. */
  var hero = doc.querySelector('[data-hero3d]');
  if (hero) {
    var reduceMQ = win.matchMedia ? win.matchMedia('(prefers-reduced-motion: reduce)') : { matches: false };
    var saveData = !!(win.navigator && win.navigator.connection && win.navigator.connection.saveData);
    var startHero = function () {
      if (hero.getAttribute('data-loading') || reduceMQ.matches) return;
      hero.setAttribute('data-loading', '1');
      var s = doc.createElement('script');
      s.src = hero.getAttribute('data-src');
      s.async = true;
      s.onerror = function () { hero.setAttribute('data-state', 'fallback'); };
      doc.body.appendChild(s);
    };
    var whenIdle = function () {
      if (win.requestIdleCallback) win.requestIdleCallback(startHero, { timeout: 1500 });
      else win.setTimeout(startHero, 300);
    };
    if (reduceMQ.matches || saveData) hero.setAttribute('data-state', 'static');
    else if (doc.readyState === 'complete') whenIdle();
    else win.addEventListener('load', whenIdle, { once: true });
    // Turning reduced motion off later starts the scene; turning it on is handled inside hero3d.js.
    if (reduceMQ.addEventListener) reduceMQ.addEventListener('change', function (e) { if (!e.matches && !saveData) whenIdle(); });
  }

  /* ---------- Live now: GET /api/public/live-now -> { ridersOnRide, groupsRiding, updatedAt } ----------
     The server rounds riders down to tens (below 10 reads as 0) so nobody can be singled out. Shown only from 10 up;
     an idle evening simply shows nothing. Checked again every minute while the tab is visible. */
  var liveBox = doc.querySelector('[data-live-now]');
  var liveText = doc.getElementById('live-now-text');
  if (liveBox && liveText && fetch) {
    var renderLive = function (j) {
      var n = j && typeof j.ridersOnRide === 'number' && isFinite(j.ridersOnRide) ? Math.floor(j.ridersOnRide) : 0;
      var g = j && typeof j.groupsRiding === 'number' && isFinite(j.groupsRiding) ? Math.floor(j.groupsRiding) : 0;
      if (n < 10) { liveBox.hidden = true; return; }
      var text = n.toLocaleString('en-IN') + '+ riders on the road right now';
      if (g >= 2) text += ', in ' + g.toLocaleString('en-IN') + ' groups';
      liveText.textContent = text + '.';
      liveBox.hidden = false;
    };
    var loadLive = function () {
      if (doc.hidden) return;
      getJSON('/api/public/live-now').then(renderLive).catch(function () { liveBox.hidden = true; });
    };
    loadLive();
    win.setInterval(loadLive, 60000);
    doc.addEventListener('visibilitychange', function () { if (!doc.hidden) loadLive(); });
  }

  /* ---------- Pricing: read live from GET /api/membership/catalog ----------
     { categories: { <id>: { id, name, monthlyPriceInr, minCapacity, maxCapacity, capacity, billingPeriodDays,
     features[], description, isActive } } }. Prices are set by the CoRoute team in the admin console, so this page
     never writes one down: no answer means no prices, only a pointer to the app. A price of 0 reads "Free". */
  var priceList = doc.getElementById('pricing-list');
  var groupPlans = doc.getElementById('group-plans');
  if ((priceList || groupPlans) && fetch) {
    var FEATURES = {
      essential_safety: 'Crash detection and SOS',
      basic_nav: 'Navigation and offline maps',
      personal_tracking: 'Your own ride history and trip report',
      profile_settings: 'Medical ID and emergency contacts',
      convoy_tracking: 'Live group map for every rider',
      group_trips: 'Host group rides with planned stops',
      ptt_intercom: 'Push-to-talk for the whole group',
      group_safety: 'Group SOS, regroup and lead alerts',
      shared_trips: 'Shared trip report and replay'
    };
    var pNum = function (v) { var n = typeof v === 'string' ? parseFloat(v) : v; return typeof n === 'number' && isFinite(n) && n >= 0 ? n : null; };
    var cleanName = function (c) { return String(c.name || c.id || 'Plan').replace(/\s*\([^)]*\)\s*$/, '').trim() || 'Plan'; };
    // A feature is a key (convoy_tracking) or, for newer plans, already a sentence ("Medical ID").
    var featureText = function (k) {
      if (FEATURES[k]) return FEATURES[k];
      var s = String(k).trim();
      if (/^[a-z0-9_]+$/.test(s)) s = s.replace(/_+/g, ' ');
      return s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
    };
    var plansFrom = function (j) {
      var cats = j && j.categories;
      if (!cats || typeof cats !== 'object') throw new Error('unexpected shape');
      var out = [];
      Object.keys(cats).forEach(function (id) {
        var c = cats[id];
        if (!c || typeof c !== 'object' || c.isActive === false) return;
        // 3.56: the server's price now (offer within its window) and the list price it replaces.
        var list = pNum(c.listPriceInr) !== null ? pNum(c.listPriceInr) : pNum(c.monthlyPriceInr);
        var price = pNum(c.priceInr) !== null ? pNum(c.priceInr) : list;
        if (price === null || list === null) return;
        var ao = c.activeOffer && typeof c.activeOffer === 'object' && pNum(c.activeOffer.priceInr) === price && price < list && typeof c.activeOffer.label === 'string' ? c.activeOffer : null;
        var max = pNum(c.maxCapacity) || pNum(c.capacity) || 1;
        var min = pNum(c.minCapacity) || 1;
        out.push({ id: String(c.id || id), name: cleanName(c), price: price, list: list, offer: ao ? String(ao.label).slice(0, 40) : '', min: Math.round(min), max: Math.round(max),
          period: pNum(c.billingPeriodDays) || 30, desc: typeof c.description === 'string' ? c.description.trim() : '',
          features: Array.isArray(c.features) ? c.features.filter(function (f) { return typeof f === 'string'; }).slice(0, 8) : [] });
      });
      out.sort(function (a, b) { return a.price - b.price || a.max - b.max; });
      return out;
    };
    var seatsText = function (p) {
      if (p.max <= 1) return 'Solo rider';
      if (p.min > 1 && p.min < p.max) return p.min + ' to ' + p.max + ' riders, host included';
      return 'Up to ' + p.max + ' riders, host included';
    };
    // "Get safety for your group rides": one chip per group plan (name, seats, price), only from the catalog.
    var renderGroupPlans = function (plans) {
      if (!groupPlans) return;
      groupPlans.textContent = '';
      plans.forEach(function (p) {
        if (p.max <= 1 || p.price === 0) return;
        var li = el('li', 'gx-plan');
        li.setAttribute('data-plan', p.id);
        li.appendChild(el('span', 'gx-plan__name', p.name));
        li.appendChild(el('span', 'gx-plan__seats', seatsText(p)));
        var price = el('span', 'gx-plan__price');
        price.appendChild(el('b', null, '\u20B9' + p.price.toLocaleString('en-IN', { maximumFractionDigits: 2 })));
        price.appendChild(doc.createTextNode(p.period === 30 ? ' a month' : ' for ' + p.period + ' days'));
        li.appendChild(price);
        groupPlans.appendChild(li);
      });
      groupPlans.hidden = !groupPlans.children.length;
    };
    var renderPlans = function (plans) {
      renderGroupPlans(plans);
      if (!priceList) return;
      priceList.textContent = '';
      priceList.removeAttribute('aria-busy');
      if (!plans.length) { priceMessage('empty'); return; }
      var accentDone = false;
      plans.forEach(function (p) {
        var free = p.price === 0;
        var card = el('article', 'px-card');
        card.setAttribute('data-plan', p.id);
        if (!free && p.max > 1 && !accentDone) { card.classList.add('px-card--accent'); accentDone = true; }
        card.appendChild(el('span', 'px-card__tag', free ? (p.max <= 1 ? 'Always free' : 'Free') : (p.max > 1 ? 'Group host' : 'Solo')));
        card.appendChild(el('h3', 'px-card__name', p.name));
        var seats = el('p', 'px-card__seats');
        seats.appendChild(icon('i-users'));
        seats.appendChild(el('span', null, seatsText(p)));
        card.appendChild(seats);
        var price = el('p', 'px-card__price');
        if (!free && p.offer) price.appendChild(el('s', 'px-card__was', '₹' + p.list.toLocaleString('en-IN', { maximumFractionDigits: 2 })));
        price.appendChild(el('span', 'px-card__amount', free ? 'Free' : '₹' + p.price.toLocaleString('en-IN', { maximumFractionDigits: 2 })));
        price.appendChild(el('span', 'px-card__per', free ? (p.max <= 1 ? 'for solo riders, forever' : 'no payment needed') : (p.period === 30 ? 'per month' : 'per ' + p.period + ' days')));
        card.appendChild(price);
        if (!free && p.offer) card.appendChild(el('p', 'px-card__offer', p.offer));
        if (p.desc) card.appendChild(el('p', 'px-card__desc', p.desc));
        if (p.features.length) {
          var ul = el('ul', 'px-card__list');
          ul.setAttribute('role', 'list');
          p.features.forEach(function (f) {
            var t = featureText(f);
            if (!t) return;
            var li = el('li');
            li.appendChild(icon('i-check'));
            li.appendChild(el('span', null, t));
            ul.appendChild(li);
          });
          card.appendChild(ul);
        }
        var cta = el('div', 'px-card__cta');
        // 3.56: paid plans are bought on /plans (the app sells nothing); Community is the free download.
        var a = el('a', 'btn btn--block ' + (card.classList.contains('px-card--accent') ? 'btn--primary' : 'btn--secondary'), free ? 'Download free' : 'Choose ' + p.name);
        a.setAttribute('href', free ? '/get' : '/plans?plan=' + encodeURIComponent(p.id));
        cta.appendChild(a);
        card.appendChild(cta);
        priceList.appendChild(card);
      });
      priceList.setAttribute('data-state', 'loaded');
    };
    var priceMessage = function (state) {
      if (!priceList) return;
      priceList.textContent = '';
      priceList.removeAttribute('aria-busy');
      priceList.setAttribute('data-state', state);
      var p = el('p', 'px-msg', state === 'empty' ? 'Plans are being updated. See the plans page in a moment.' : 'Prices could not load right now. See the plans page in a moment.');
      priceList.appendChild(p);
    };
    getJSON('/api/membership/catalog').then(plansFrom).then(renderPlans).catch(function () { priceMessage('error'); });
  }
  /* ---------- end pricing ---------- */
})();
