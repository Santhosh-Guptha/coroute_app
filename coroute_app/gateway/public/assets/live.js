/* Live emergency link page (/e/<token>). No libraries, no cookies, no analytics.
   Why not site.js: its page-view beacon posts location.pathname, which here contains the link token.
   This file repeats the two bits of shell behaviour the page needs (compact header on scroll, mobile menu)
   and adds the map and the 30 second refresh from /api/public/live/<token>.
   The only requests that leave this origin are the OpenStreetMap tile images, loaded by the viewer's browser
   as ordinary page use (9 to 15 tiles at zoom 15, no prefetch, no bulk download), and the "Open in Google Maps" link when the viewer taps it. */
(function () {
  'use strict';
  var doc = document, win = window;

  /* ---------- Shell: header state and the mobile menu (same classes as site.js) ---------- */
  var header = doc.querySelector('[data-header]');
  function updateHeader() { if (header) header.classList.toggle('is-scrolled', win.scrollY > 64); }
  win.addEventListener('scroll', updateHeader, { passive: true });
  updateHeader();
  var toggle = doc.querySelector('.nav-toggle');
  var menu = toggle && doc.getElementById(toggle.getAttribute('aria-controls'));
  function setMenu(open, restoreFocus) {
    if (!menu) return;
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    var label = toggle.querySelector('.nav-toggle__label');
    if (label) label.textContent = open ? 'Close' : 'Menu';
    menu.hidden = !open;
    header.classList.toggle('is-open', open);
    doc.documentElement.classList.toggle('menu-open', open);
    if (open) { var first = menu.querySelector('a,button'); if (first) first.focus(); }
    else if (restoreFocus) toggle.focus();
  }
  if (menu) {
    toggle.addEventListener('click', function () { setMenu(toggle.getAttribute('aria-expanded') !== 'true', true); });
    doc.addEventListener('keydown', function (e) { if (e.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') setMenu(false, true); });
    menu.addEventListener('click', function (e) { if (e.target.closest('a')) setMenu(false, false); });
  }

  /* ---------- Live map and refresh ---------- */
  var card = doc.querySelector('[data-live]');
  var map = doc.querySelector('.live-map');
  if (!card || !map) return; // the expired page has no map

  var TILE_BASE = 'https://tile.openstreetmap.org/';
  var ZOOM = 15, TILE = 256, REFRESH_MS = 30000, MOVE_M = 50;
  var tilesBox = map.querySelector('[data-tiles]');
  var posEl = card.querySelector('[data-pos]');
  var updatedEl = card.querySelector('[data-updated]');
  var expiresEl = card.querySelector('[data-expires-text]');
  var statusEl = card.querySelector('[data-status]');
  var mapsLink = card.querySelector('[data-maps]');
  var token = (location.pathname.match(/^\/e\/([A-Za-z0-9_-]{32})\/?$/) || [])[1];

  var toMs = function (v) { if (typeof v === 'number') return v; var t = Date.parse(String(v || '')); return isNaN(t) ? 0 : t; };
  var state = {
    lat: parseFloat(map.getAttribute('data-lat')),
    lng: parseFloat(map.getAttribute('data-lng')),
    at: toMs(map.getAttribute('data-at')),
    expiresAt: toMs(card.getAttribute('data-expires')),
    done: false,
    timer: 0,
    inflight: false
  };
  if (!isFinite(state.lat) || !isFinite(state.lng)) return;

  function fmt5(n) { return (Math.round(n * 1e5) / 1e5).toFixed(5); }
  function timeOf(ms) {
    var d = new Date(ms);
    return isNaN(d.getTime()) ? '' : d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }
  function ago(ms) {
    if (!ms) return 'unknown';
    var s = Math.max(0, Math.round((Date.now() - ms) / 1000));
    if (s < 45) return 'just now';
    var m = Math.round(s / 60);
    if (m < 60) return m + ' min ago (' + timeOf(ms) + ')';
    var h = Math.floor(m / 60);
    return h + ' h ' + (m % 60) + ' min ago (' + timeOf(ms) + ')';
  }
  function distanceM(aLat, aLng, bLat, bLng) {
    var R = 6371000, r = Math.PI / 180;
    var dLat = (bLat - aLat) * r, dLng = (bLng - aLng) * r;
    var x = Math.sin(dLat / 2), y = Math.sin(dLng / 2);
    var h = x * x + Math.cos(aLat * r) * Math.cos(bLat * r) * y * y;
    return 2 * R * Math.asin(Math.sqrt(h));
  }

  /* Web Mercator tile coordinates (fractional) for the point at ZOOM. */
  function tileXY(lat, lng) {
    var n = Math.pow(2, ZOOM);
    var la = Math.max(-85.0511, Math.min(85.0511, lat)) * Math.PI / 180;
    return {
      x: (lng + 180) / 360 * n,
      y: (1 - Math.log(Math.tan(la) + 1 / Math.cos(la)) / Math.PI) / 2 * n
    };
  }
  /* Grid size: enough 256 px tiles to cover the box plus one for the fractional offset, odd counts so the
     centre tile stays in the middle. A phone gets 3x3; a desktop card gets 5x3 (15 tiles, the most ever loaded). */
  function gridSize() {
    var odd = function (n) { return n % 2 ? n : n + 1; };
    var cols = Math.min(5, odd(Math.ceil(map.clientWidth / TILE) + 1));
    var rows = Math.min(5, odd(Math.ceil(map.clientHeight / TILE) + 1));
    return { cols: Math.max(3, cols), rows: Math.max(3, rows) };
  }
  var drawn = null; // centre tile and grid size currently drawn
  var failed = 0, total = 0;
  var noteEl = map.querySelector('.live-map__nojs');
  function onTileError(img) {
    img.style.visibility = 'hidden';
    failed++;
    if (failed >= total && noteEl) {
      noteEl.textContent = 'Map images could not be loaded. The position and the buttons below still work.';
      map.classList.remove('is-ready');
    }
  }
  function drawMap(lat, lng) {
    var t = tileXY(lat, lng);
    var cx = Math.floor(t.x), cy = Math.floor(t.y);
    var fx = t.x - cx, fy = t.y - cy;
    var g = gridSize();
    var hc = Math.floor(g.cols / 2), hr = Math.floor(g.rows / 2);
    // The grid holds tiles cx-hc..cx+hc and cy-hr..cy+hr; shift it so the point (centre tile + fraction) sits at the middle.
    tilesBox.style.width = g.cols * TILE + 'px';
    tilesBox.style.height = g.rows * TILE + 'px';
    tilesBox.style.gridTemplateColumns = 'repeat(' + g.cols + ',' + TILE + 'px)';
    tilesBox.style.gridTemplateRows = 'repeat(' + g.rows + ',' + TILE + 'px)';
    tilesBox.style.transform = 'translate(' + (-(hc + fx) * TILE) + 'px,' + (-(hr + fy) * TILE) + 'px)';
    if (drawn && drawn.x === cx && drawn.y === cy && drawn.cols === g.cols && drawn.rows === g.rows) return;
    drawn = { x: cx, y: cy, cols: g.cols, rows: g.rows };
    var n = Math.pow(2, ZOOM);
    var frag = doc.createDocumentFragment();
    failed = 0; total = 0;
    for (var dy = -hr; dy <= hr; dy++) {
      for (var dx = -hc; dx <= hc; dx++) {
        var img = doc.createElement('img');
        var x = ((cx + dx) % n + n) % n, y = cy + dy;
        img.alt = '';
        img.decoding = 'async';
        img.referrerPolicy = 'no-referrer';
        img.addEventListener('error', onTileError.bind(null, img));
        if (y >= 0 && y < n) { img.src = TILE_BASE + ZOOM + '/' + x + '/' + y + '.png'; total++; }
        else img.style.visibility = 'hidden';
        frag.appendChild(img);
      }
    }
    tilesBox.textContent = '';
    tilesBox.appendChild(frag);
    map.classList.add('is-ready');
  }
  var resizeTimer = 0;
  win.addEventListener('resize', function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { drawMap(state.lat, state.lng); }, 200);
  });

  function setStatus(text, cls) {
    if (!statusEl) return;
    statusEl.textContent = text;
    statusEl.className = 'live__status t-small ' + (cls || 't-muted');
  }
  function render() {
    if (posEl) posEl.textContent = fmt5(state.lat) + ', ' + fmt5(state.lng);
    if (updatedEl) {
      updatedEl.textContent = ago(state.at);
      if (state.at) updatedEl.setAttribute('datetime', new Date(state.at).toISOString());
    }
    if (expiresEl && state.expiresAt) {
      expiresEl.textContent = timeOf(state.expiresAt);
      expiresEl.setAttribute('datetime', new Date(state.expiresAt).toISOString());
    }
    if (mapsLink) mapsLink.href = 'https://www.google.com/maps/dir/?api=1&destination=' + fmt5(state.lat) + ',' + fmt5(state.lng);
    map.setAttribute('aria-label', 'Map of the rider\'s last known position, ' + fmt5(state.lat) + ', ' + fmt5(state.lng));
  }

  function expire(reason) {
    if (state.done) return;
    state.done = true;
    if (state.timer) { clearInterval(state.timer); state.timer = 0; }
    map.classList.add('is-done');
    setStatus(reason || 'This link has expired. The last position shown here may be out of date.', 'is-done');
    var gone = doc.createElement('div');
    gone.className = 'live__gone';
    gone.setAttribute('role', 'alert');
    var h = doc.createElement('h2'); h.textContent = 'This link has expired';
    var p1 = doc.createElement('p'); p1.textContent = 'Live emergency links in Coroute last 30 minutes or until the rider\'s group closes the alert. The position above is the last one this page received and may be out of date.';
    var p2 = doc.createElement('p'); p2.textContent = 'If someone is in danger, call 112.';
    gone.appendChild(h); gone.appendChild(p1); gone.appendChild(p2);
    var facts = card.querySelector('.live__facts');
    card.insertBefore(gone, facts || null);
  }

  function apply(j) {
    var lat = Number(j.lat), lng = Number(j.lng);
    if (!isFinite(lat) || !isFinite(lng)) return;
    var moved = distanceM(state.lat, state.lng, lat, lng) > MOVE_M;
    state.lat = lat; state.lng = lng;
    state.at = toMs(j.at) || state.at;
    if (j.expiresAt) state.expiresAt = toMs(j.expiresAt) || state.expiresAt;
    if (moved) drawMap(lat, lng);
    render();
    setStatus('Refreshes every 30 seconds while this page is open. Last check ' + timeOf(Date.now()) + '.', 't-muted');
  }

  function refresh() {
    if (state.done || state.inflight) return;
    if (state.expiresAt && Date.now() >= state.expiresAt) { expire(); return; }
    if (!token) { render(); return; }
    state.inflight = true;
    fetch('/api/public/live/' + token, { cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer', headers: { Accept: 'application/json' } })
      .then(function (res) {
        if (res.status === 410 || res.status === 404) { expire(); return null; }
        if (!res.ok) throw new Error('status ' + res.status);
        return res.json();
      })
      .then(function (j) { if (j && j.active !== false) apply(j); else if (j) expire(); })
      .catch(function () {
        render();
        setStatus('Could not refresh. Showing the last position received, updated ' + ago(state.at) + '.', 'is-warn');
      })
      .then(function () { state.inflight = false; });
  }

  drawMap(state.lat, state.lng);
  render();
  refresh();
  state.timer = setInterval(refresh, REFRESH_MS);
  doc.addEventListener('visibilitychange', function () { if (!doc.hidden) refresh(); });
})();
