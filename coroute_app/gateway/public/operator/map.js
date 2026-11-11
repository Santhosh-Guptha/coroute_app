/* CoRoute operator console: a small slippy map (no third-party script). OpenStreetMap tiles when they load
   (allowed by the console CSP), a plain grid when they do not; markers are DOM nodes, text set as text.
   window.CoMap.create(el) -> { setMarkers(list), fit(points), invalidate() }. */
(function () {
  'use strict';
  var TILE = 256;
  function project(lat, lng, z) {
    var s = TILE * Math.pow(2, z);
    var la = Math.max(-85.05, Math.min(85.05, lat)) * Math.PI / 180;
    return { x: (lng + 180) / 360 * s, y: (1 - Math.log(Math.tan(la) + 1 / Math.cos(la)) / Math.PI) / 2 * s };
  }
  function unproject(x, y, z) {
    var s = TILE * Math.pow(2, z);
    var lng = x / s * 360 - 180;
    var n = Math.PI - 2 * Math.PI * y / s;
    return { lat: 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n))), lng: lng };
  }
  function el(tag, cls, text) { var n = document.createElement(tag); if (cls) n.className = cls; if (text !== undefined) n.textContent = text; return n; }

  function create(root) {
    root.classList.add('map');
    var tiles = el('div', 'map__tiles');
    var marks = el('div', 'map__marks');
    var empty = el('div', 'map__empty', 'No live positions yet.');
    var zoom = el('div', 'map__zoom');
    var zin = el('button', 'btn', '+'); zin.type = 'button'; zin.setAttribute('aria-label', 'Zoom in');
    var zout = el('button', 'btn', '−'); zout.type = 'button'; zout.setAttribute('aria-label', 'Zoom out');
    zoom.appendChild(zin); zoom.appendChild(zout);
    var attr = el('div', 'map__attr', '© OpenStreetMap contributors');
    root.appendChild(tiles); root.appendChild(marks); root.appendChild(empty); root.appendChild(zoom); root.appendChild(attr);
    var st = { lat: 20.6, lng: 78.9, z: 5, markers: [], userMoved: false };
    var cache = {};

    function size() { return { w: root.clientWidth || 800, h: root.clientHeight || 500 }; }
    function render() {
      var sz = size();
      var c = project(st.lat, st.lng, st.z);
      var ox = c.x - sz.w / 2, oy = c.y - sz.h / 2;
      var n = Math.pow(2, st.z);
      var x0 = Math.floor(ox / TILE), x1 = Math.floor((ox + sz.w) / TILE), y0 = Math.max(0, Math.floor(oy / TILE)), y1 = Math.min(n - 1, Math.floor((oy + sz.h) / TILE));
      var keep = {};
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          var wx = ((x % n) + n) % n;
          var key = st.z + '/' + wx + '/' + y + '@' + x;
          keep[key] = true;
          var img = cache[key];
          if (!img) {
            img = document.createElement('img');
            img.alt = '';
            img.decoding = 'async';
            img.referrerPolicy = 'no-referrer';
            img.onerror = function () { this.style.visibility = 'hidden'; };
            img.src = 'https://tile.openstreetmap.org/' + st.z + '/' + wx + '/' + y + '.png';
            cache[key] = img;
            tiles.appendChild(img);
          }
          img.style.left = Math.round(x * TILE - ox) + 'px';
          img.style.top = Math.round(y * TILE - oy) + 'px';
        }
      }
      Object.keys(cache).forEach(function (k) { if (!keep[k]) { cache[k].remove(); delete cache[k]; } });
      while (marks.firstChild) marks.removeChild(marks.firstChild);
      var labelled = [];
      // SOS markers first so their labels win; a label is left out when another one is too close.
      st.markers.slice().sort(function (a, b) { return (b.sos ? 1 : 0) - (a.sos ? 1 : 0); }).forEach(function (m) {
        if (!m.lat && !m.lng) return;
        var p = project(m.lat, m.lng, st.z);
        var d = el('div', 'mk' + (m.sos ? ' mk--sos' : '') + (m.stale ? ' mk--stale' : ''), m.short || '');
        if (m.color) d.style.setProperty('--mc', m.color);
        d.style.left = Math.round(p.x - ox) + 'px';
        d.style.top = Math.round(p.y - oy) + 'px';
        d.title = m.title || '';
        var lx = p.x - ox, ly = p.y - oy;
        var free = !labelled.some(function (q) { return Math.abs(q[0] - lx) < 70 && Math.abs(q[1] - ly) < 26; });
        if (m.label && free) { d.appendChild(el('span', 'mk__label', m.label)); labelled.push([lx, ly]); }
        marks.appendChild(d);
      });
      empty.hidden = st.markers.some(function (m) { return m.lat || m.lng; });
    }
    function fit(points) {
      var pts = (points || []).filter(function (p) { return p && (p.lat || p.lng); });
      if (!pts.length) { render(); return; }
      var sz = size();
      var z = 16;
      for (; z > 3; z--) {
        var a = pts.map(function (p) { return project(p.lat, p.lng, z); });
        var xs = a.map(function (p) { return p.x; }), ys = a.map(function (p) { return p.y; });
        if (Math.max.apply(null, xs) - Math.min.apply(null, xs) < sz.w - 120 && Math.max.apply(null, ys) - Math.min.apply(null, ys) < sz.h - 120) break;
      }
      var b = pts.map(function (p) { return project(p.lat, p.lng, z); });
      var cx = (Math.max.apply(null, b.map(function (p) { return p.x; })) + Math.min.apply(null, b.map(function (p) { return p.x; }))) / 2;
      var cy = (Math.max.apply(null, b.map(function (p) { return p.y; })) + Math.min.apply(null, b.map(function (p) { return p.y; }))) / 2;
      var c = unproject(cx, cy, z);
      st.lat = c.lat; st.lng = c.lng; st.z = z;
      render();
    }
    function zoomBy(d) { st.z = Math.max(3, Math.min(18, st.z + d)); st.userMoved = true; render(); }
    zin.addEventListener('click', function () { zoomBy(1); });
    zout.addEventListener('click', function () { zoomBy(-1); });
    root.addEventListener('wheel', function (e) { e.preventDefault(); zoomBy(e.deltaY < 0 ? 1 : -1); }, { passive: false });
    var drag = null;
    root.addEventListener('pointerdown', function (e) {
      if (e.target.closest('.map__zoom')) return;
      drag = { x: e.clientX, y: e.clientY, c: project(st.lat, st.lng, st.z) };
      root.classList.add('is-drag');
      root.setPointerCapture(e.pointerId);
    });
    root.addEventListener('pointermove', function (e) {
      if (!drag) return;
      var c = unproject(drag.c.x - (e.clientX - drag.x), drag.c.y - (e.clientY - drag.y), st.z);
      st.lat = c.lat; st.lng = c.lng; st.userMoved = true;
      render();
    });
    function end() { drag = null; root.classList.remove('is-drag'); }
    root.addEventListener('pointerup', end);
    root.addEventListener('pointercancel', end);
    window.addEventListener('resize', render);
    render();
    return {
      setMarkers: function (list, opts) {
        st.markers = list || [];
        if ((opts && opts.fit) || !st.userMoved) fit(st.markers); else render();
      },
      fit: function (p) { st.userMoved = false; fit(p || st.markers); },
      invalidate: render,
      destroy: function () { window.removeEventListener('resize', render); }
    };
  }
  window.CoMap = { create: create, project: project };
})();
