/* Coroute homepage only: the hero road scene and the map stories that follow the scroll.
   One rAF loop. Scroll progress comes from site.js (--p on [data-progress] and [data-pinned],
   data-active-stage on pinned stories). No libraries, no network requests.
   The scene math is pure, so a build script can bake the same scene into assets/home/hero-road.svg. */
(function () {
  'use strict';

  /* ---------- Scene: a road into the distance through contour-line terrain ---------- */
  var ROAD_HW = 3.6;      // half road width (m)
  var LANE = -1.8;        // riders and the route keep to the left lane
  var Z_FAR = 340;        // farthest terrain line (m)
  var SPACING = 9;        // distance between terrain lines (m)
  var SPEED = 5.5;        // camera speed (m/s): slow, it is a calm ride
  var RIDERS = [
    { z: 50, ph: 0.0, kind: 'lead' },
    { z: 39, ph: 2.1, kind: 'rider' },
    { z: 30, ph: 4.0, kind: 'you' },
    { z: 22, ph: 1.2, kind: 'rider' }
  ];
  var COL = {
    ground: '#0B0D0E', road: '#1C2123', accent: '255,111,46', text: '242,238,231',
    lead: '#FFB347', you: '#FF6F2E', rider: '#8A867F', riderFill: '#191D1E'
  };

  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  /* smooth(a, b, v): 0 at a, 1 at b (works for a > b too). */
  function smooth(a, b, v) { var t = clamp((v - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); }
  function roadC(Z) { return 16 * Math.sin(Z / 95) + 7 * Math.sin(Z / 41 + 1.3); }
  function noise(x, z) {
    return 0.5 + 0.22 * Math.sin(x * 0.045 + z * 0.012) + 0.16 * Math.sin(x * 0.11 - z * 0.027 + 1.7) +
      0.09 * Math.sin(x * 0.27 + z * 0.06 + 0.4) + 0.05 * Math.sin(z * 0.13 - x * 0.02);
  }

  /* Camera for a W x H scene. p (0..1) tilts it from the rider's view toward a top-down map. */
  function camera(W, H, p, camZ) {
    var wide = W >= 1024, mid = W >= 640;
    var e = smooth(0, 0.9, p || 0);
    var th = 0.03 + e * 0.78;
    var slope = roadC(camZ + 0.5) - roadC(camZ - 0.5);
    return {
      W: W, H: H, camZ: camZ, slope: slope, base: roadC(camZ),
      cx: W * (W >= 1280 ? 0.68 : wide ? 0.74 : mid ? 0.6 : 0.5),
      cy: H * (wide ? 0.56 : 0.64),
      f: wide ? H * 0.92 : Math.max(W * 1.15, H * 0.6),
      hC: (wide ? 6 : mid ? 7.5 : 9) + e * 20,
      cs: Math.cos(th), sn: Math.sin(th)
    };
  }
  /* Lateral offset of the road centre at distance z, relative to the camera heading. */
  function xr(c, z) { return roadC(c.camZ + z) - c.base - c.slope * z; }
  function project(c, X, Y, z) {
    var dy = Y - c.hC, zc = z * c.cs - dy * c.sn, yc = dy * c.cs + z * c.sn;
    return [c.cx + c.f * X / zc, c.cy - c.f * yc / zc, zc];
  }
  function rgba(rgb, a) { return 'rgba(' + rgb + ',' + (Math.round(a * 1000) / 1000) + ')'; }

  /* Distant ridges (own layer, so the mouse can move them a little less than the terrain). */
  function drawRidges(pen, c) {
    var N = c.W < 640 ? 40 : 70, ridges = [[1250, 0.06, 7], [980, 0.085, 3], [760, 0.11, 11]];
    ridges.forEach(function (r) {
      var z = r[0], pts = [];
      for (var i = 0; i <= N; i++) {
        var sx = -40 + i * (c.W + 80) / N, X = (sx - c.cx) * z / c.f;
        var Y = 40 + 150 * Math.pow(noise(X * 0.35 + r[2] * 40, r[2] * 90), 1.6);
        var pt = project(c, X, Y, z); pts.push([pt[0], pt[1]]);
      }
      pen.fill(pts.concat([[c.W + 60, c.H + 60], [-60, c.H + 60]]), COL.ground);
      pen.line(pts, rgba(COL.text, r[1]), 1);
    });
  }

  /* Terrain lines (far to near, each one hides what is behind it), then the road on top. */
  function drawGround(pen, c) {
    var N = c.W < 640 ? 44 : 72, k, i;
    var k0 = Math.ceil((c.camZ + 6) / SPACING), k1 = Math.floor((c.camZ + Z_FAR) / SPACING);
    for (k = k1; k >= k0; k--) {
      var Za = k * SPACING, z = Za - c.camZ, zc0 = z * c.cs + c.hC * c.sn, road = xr(c, z), pts = [];
      for (i = 0; i <= N; i++) {
        var sx = -40 + i * (c.W + 80) / N, X = (sx - c.cx) * zc0 / c.f, d = X - road, ad = Math.abs(d);
        var Y = smooth(4.2, 20 + z * 0.2, ad) * (2.5 + Math.min(1, ad / 110) * 44) * noise(d, Za);
        var pt = project(c, X, Y, z); pts.push([pt[0], pt[1]]);
      }
      var a = (0.05 + 0.15 * (1 - z / Z_FAR)) * smooth(Z_FAR, Z_FAR - 70, z) * smooth(6, 22, z);
      pen.fill(pts.concat([[c.W + 60, c.H + 60], [-60, c.H + 60]]), COL.ground);
      pen.line(pts, rgba(COL.text, a), 1);
    }

    // Road surface and edge lines.
    var n = 56, zs = [], L = [], R = [], EL = [], ER = [];
    for (i = 0; i <= n; i++) zs.push(1.2 * Math.pow(Z_FAR / 1.2, i / n));
    zs.forEach(function (z) {
      var x = xr(c, z);
      var l = project(c, x - ROAD_HW, 0, z), r = project(c, x + ROAD_HW, 0, z);
      L.push([l[0], l[1]]); R.push([r[0], r[1]]);
      l = project(c, x - ROAD_HW + 0.25, 0, z); r = project(c, x + ROAD_HW - 0.25, 0, z);
      EL.push([l[0], l[1]]); ER.push([r[0], r[1]]);
    });
    pen.fill(L.concat(R.slice().reverse()), COL.road);
    pen.line(EL, rgba(COL.text, 0.26), 1.2);
    pen.line(ER, rgba(COL.text, 0.26), 1.2);

    // Centre dashes, fixed to the ground so they stream toward the viewer.
    var m0 = Math.ceil((c.camZ + 1.2) / 11), m1 = Math.floor((c.camZ + 170) / 11);
    for (var m = m0; m <= m1; m++) {
      var z1 = m * 11 - c.camZ, z2 = z1 + 4, x1 = xr(c, z1), x2 = xr(c, z2);
      var a1 = project(c, x1 - 0.07, 0, z1), b1 = project(c, x1 + 0.07, 0, z1), a2 = project(c, x2 - 0.07, 0, z2), b2 = project(c, x2 + 0.07, 0, z2);
      pen.fill([[a1[0], a1[1]], [b1[0], b1[1]], [b2[0], b2[1]], [a2[0], a2[1]]], rgba(COL.text, 0.38 * smooth(170, 110, z1)));
    }
  }

  /* The route: faded behind the last rider (the road behind you clears), bright ahead of the group. */
  function drawRoute(pen, c, zBack) {
    function strip(za, zb, alpha) {
      var steps = 10, Ls = [], Rs = [];
      for (var i = 0; i <= steps; i++) {
        var z = za * Math.pow(zb / za, i / steps), x = xr(c, z) + LANE;
        var l = project(c, x - 0.17, 0, z), r = project(c, x + 0.17, 0, z);
        Ls.push([l[0], l[1]]); Rs.push([r[0], r[1]]);
      }
      pen.fill(Ls.concat(Rs.reverse()), rgba(COL.accent, alpha));
    }
    strip(1.2, zBack, 0.26);
    var seg = [zBack, 60, 95, 140, 200, 270, Z_FAR];
    for (var i = 0; i < seg.length - 1; i++) if (seg[i + 1] > seg[i]) strip(seg[i], seg[i + 1], 0.95 - i * 0.14);
  }

  function riderState(t) {
    return RIDERS.map(function (r) {
      return { z: r.z + 2.6 * Math.sin(t * 0.21 + r.ph), sway: 0.22 * Math.sin(t * 0.5 + r.ph * 1.7), kind: r.kind };
    });
  }
  function riderMarks(c, riders) {
    return riders.map(function (r) {
      var pt = project(c, xr(c, r.z) + LANE + r.sway, 0.55, r.z);
      var rad = clamp(c.f * 0.42 / pt[2], 2.5, 13);
      return { x: pt[0], y: pt[1], r: rad, w: Math.max(1.5, rad * 0.24), kind: r.kind };
    });
  }

  function render(pens, W, H, t, p) {
    var c = camera(W, H, p, t * SPEED), riders = riderState(t);
    var zBack = Math.min.apply(null, riders.map(function (r) { return r.z; })) - 3;
    if (pens.ridges) drawRidges(pens.ridges, c);
    drawGround(pens.ground, c);
    drawRoute(pens.ground, c, zBack);
    return riderMarks(c, riders);
  }

  /* Pens: the same drawing calls go to a canvas or to an SVG string. */
  function canvasPen(ctx) {
    function path(pts) { ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]); for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]); }
    return {
      fill: function (pts, col) { path(pts); ctx.closePath(); ctx.fillStyle = col; ctx.fill(); },
      line: function (pts, col, w) { path(pts); ctx.strokeStyle = col; ctx.lineWidth = w; ctx.stroke(); }
    };
  }
  function svgPen() {
    var out = [];
    function d(pts) { return 'M' + pts.map(function (q) { return q[0].toFixed(1) + ' ' + q[1].toFixed(1); }).join(' L'); }
    return {
      out: out,
      fill: function (pts, col) { out.push('<path d="' + d(pts) + 'Z" fill="' + col + '"/>'); },
      line: function (pts, col, w) { out.push('<path d="' + d(pts) + '" fill="none" stroke="' + col + '" stroke-width="' + w + '"/>'); }
    };
  }
  var Scene = { render: render, canvasPen: canvasPen, svgPen: svgPen, COL: COL };

  if (typeof module === 'object' && module.exports) { module.exports = Scene; return; }

  /* ================= Browser ================= */
  var doc = document, win = window;
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || doc).querySelectorAll(sel)); };
  var mq = function (q) { return win.matchMedia ? win.matchMedia(q) : { matches: false }; };
  var reduce = mq('(prefers-reduced-motion: reduce)').matches;
  var coarse = !mq('(hover: hover) and (pointer: fine)').matches;
  var hasIO = 'IntersectionObserver' in win;
  var pOf = function (el) { var v = parseFloat(el.style.getPropertyValue('--p')); return isFinite(v) ? v : 1; };

  /* ---------- Hero ---------- */
  var hero = doc.querySelector('[data-hero]');
  var canvas = hero && hero.querySelector('.hero__ground');
  var ctx = canvas && canvas.getContext && canvas.getContext('2d');
  var ridgeSvg = hero && hero.querySelector('.hero__ridges');
  var riderSvg = hero && hero.querySelector('.hero__riders');
  var heroOn = !!ctx, heroVisible = true, W = 0, H = 0, t = 0, last = 0, lastDraw = 0, lastP = -1;
  var riderEls = [];

  function sizeHero() {
    if (!heroOn) return;
    W = hero.clientWidth; H = hero.clientHeight;
    var dpr = Math.min(coarse ? 1.5 : 2, win.devicePixelRatio || 1); // phones: the soft scene needs no more, and fill cost drops a lot
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    [ridgeSvg, riderSvg].forEach(function (s) { s.setAttribute('viewBox', '0 0 ' + W + ' ' + H); });
    lastP = -1;
  }
  function drawHero() {
    var p = reduce ? 0 : clamp(pOf(hero), 0, 1);
    ctx.clearRect(0, 0, W, H);
    var rp = p !== lastP ? svgPen() : null;   // ridges only change with the tilt or the size
    var marks = render({ ground: canvasPen(ctx), ridges: rp }, W, H, t, p);
    if (rp) ridgeSvg.innerHTML = rp.out.join('');
    marks.forEach(function (m, i) {
      var g = riderEls[i];
      if (!g) {
        g = riderEls[i] = doc.createElementNS('http://www.w3.org/2000/svg', 'circle');
        g.setAttribute('class', 'hero-rider hero-rider--' + m.kind);
        riderSvg.appendChild(g);
      }
      g.setAttribute('cx', m.x.toFixed(1)); g.setAttribute('cy', m.y.toFixed(1));
      g.setAttribute('r', m.r.toFixed(1)); g.setAttribute('stroke-width', m.w.toFixed(1));
    });
    lastP = p;
  }

  /* ---------- Map stories: markers that follow a road path with the scroll ---------- */
  // <span data-track="0:.16 .5:.4 1:.66" data-path="road-id"> ... interpolated by the story's --p.
  var stories = $$('[data-story]').map(function (el) {
    var tracks = $$('[data-track]', el).map(function (m) {
      var path = doc.getElementById(m.getAttribute('data-path'));
      if (!path || !path.getTotalLength) return null;
      var vb = path.ownerSVGElement.viewBox.baseVal;
      var keys = m.getAttribute('data-track').trim().split(/\s+/).map(function (pair) { var a = pair.split(':'); return [+a[0], +a[1]]; });
      return { el: m, path: path, len: path.getTotalLength(), vw: vb.width, vh: vb.height, keys: keys, s: null };
    }).filter(Boolean);
    var dists = $$('[data-dist]', el).map(function (d) {
      return { el: d, of: d.closest('[data-track]'), ref: doc.getElementById(d.getAttribute('data-dist')), km: +d.getAttribute('data-km') || 1 };
    });
    var counter = el.querySelector('[data-stopcount]');
    return { el: el, tracks: tracks, dists: dists, counter: counter, visible: !hasIO, p: -1 };
  });
  function at(keys, p) {
    if (p <= keys[0][0]) return keys[0][1];
    for (var i = 1; i < keys.length; i++) {
      if (p <= keys[i][0]) {
        var k = smooth(keys[i - 1][0], keys[i][0], p);
        return keys[i - 1][1] + (keys[i][1] - keys[i - 1][1]) * k;
      }
    }
    return keys[keys.length - 1][1];
  }
  function fmtDist(km) {
    var a = Math.abs(km), side = km >= 0 ? ' ahead' : ' behind';
    return (a < 1 ? Math.round(a * 100) * 10 + ' m' : a.toFixed(1) + ' km') + side;
  }
  function updateStory(s, force) {
    var p = pOf(s.el);
    if (!force && p === s.p) return;
    s.p = p;
    s.tracks.forEach(function (tr) {
      var v = at(tr.keys, p);
      tr.el._s = v;
      if (tr.s !== null && Math.abs(tr.s - v) < 0.0004) return;
      tr.s = v;
      var pt = tr.path.getPointAtLength(clamp(v, 0, 1) * tr.len);
      tr.el.style.setProperty('--x', (pt.x / tr.vw * 100).toFixed(2) + '%');
      tr.el.style.setProperty('--y', (pt.y / tr.vh * 100).toFixed(2) + '%');
    });
    s.dists.forEach(function (d) {
      if (!d.of || !d.ref || d.of._s == null || d.ref._s == null) return;
      var txt = fmtDist((d.of._s - d.ref._s) * d.km);
      if (d.el.textContent !== txt) d.el.textContent = txt;
    });
    if (s.counter) {
      var marks = (s.counter.getAttribute('data-at') || '').split(/\s+/).map(Number), n = +s.counter.getAttribute('data-from') || 0;
      marks.forEach(function (m) { if (p >= m) n++; });
      var total = +s.counter.getAttribute('data-total');
      s.counter.textContent = n + '/' + total;
      s.el.classList.toggle('is-complete', n >= total);
    }
  }

  /* ---------- One loop ---------- */
  var queued = false;
  function frame(now) {
    queued = false;
    var anim = heroOn && heroVisible && !reduce && !doc.hidden && started;
    if (anim) {
      var dt = last ? Math.min(0.1, (now - last) / 1000) : 0;
      last = now; t += dt;
      // A slow drifting scene: about 30 fps on desktop and 24 on phones is plenty, and halves the CPU cost.
      if (now - lastDraw > (coarse ? 40 : 31)) { lastDraw = now; drawHero(); }
    } else {
      last = 0;
      if (heroOn && heroVisible && pOf(hero) !== lastP) drawHero();
    }
    stories.forEach(function (s) { if (s.visible) updateStory(s, false); });
    if (anim) schedule();
  }
  function schedule() { if (!queued) { queued = true; win.requestAnimationFrame(frame); } }

  if (hasIO) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.target === hero) heroVisible = en.isIntersecting;
        stories.forEach(function (s) { if (s.el === en.target) s.visible = en.isIntersecting; });
      });
      schedule();
    }, { rootMargin: '15% 0px 15% 0px' });
    if (heroOn) io.observe(hero);
    stories.forEach(function (s) { io.observe(s.el); });
  }
  win.addEventListener('scroll', schedule, { passive: true });
  win.addEventListener('resize', function () { sizeHero(); stories.forEach(function (s) { s.p = -1; }); schedule(); }, { passive: true });
  doc.addEventListener('visibilitychange', schedule);

  /* ---------- Discovery: Private / Public demo (visual only) ---------- */
  var demo = doc.querySelector('[data-visibility-demo]');
  if (demo) {
    var btns = $$('[data-vis][aria-controls="' + demo.id + '"]'), touched = false;
    var setVis = function (v) {
      demo.setAttribute('data-visibility', v);
      btns.forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-vis') === v ? 'true' : 'false'); });
    };
    btns.forEach(function (b) { b.addEventListener('click', function () { touched = true; setVis(b.getAttribute('data-vis')); }); });
    // Start Private (the app's default) and switch to Public once, when the demo is in view.
    if (!reduce && hasIO) {
      setVis('private');
      var dio = new IntersectionObserver(function (en) {
        if (!en[0].isIntersecting) return;
        dio.disconnect();
        setTimeout(function () { if (!touched) setVis('public'); }, 1100);
      }, { threshold: 0.6 });
      dio.observe(demo);
    }
  }

  /* ---------- Start ---------- */
  // The first frame is drawn at once; the drift starts only after the page has loaded and settled,
  // so the scene never competes with the first paint and the first interaction.
  var started = false;
  var startLoop = function () { setTimeout(function () { started = true; schedule(); }, 800); };
  if (heroOn) {
    sizeHero();
    drawHero();
    hero.classList.add('is-live');
    if (doc.readyState === 'complete') startLoop(); else win.addEventListener('load', startLoop, { once: true });
  }
  stories.forEach(function (s) { updateStory(s, true); });
  schedule();
})();
