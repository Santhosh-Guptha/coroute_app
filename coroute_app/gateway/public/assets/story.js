/* CoRoute home page: "A ride with CoRoute", the scroll story (round 12, docs/quality/ROUND12_WEBSITE_NOTES.md).
   Loaded late by home.js when the story section comes near. The text is in the HTML; this file only draws.
   - Motion allowed: one sticky SVG stage; the chapter in the reading line picks the scene and its scroll progress
     (0 to 1) drives the drawing. A light animation loop runs only while the story is on screen and the tab visible.
   - Reduced motion (or the stage hidden by CSS): each chapter's figure gets a static frame, drawn as it approaches.
   Every scene is a function (g, P) -> draw(p, t). Colours come from CSS classes (home.css, "story-svg"), so the site
   theme applies. No libraries, no network requests, never HTML strings. */
(function () {
  'use strict';
  var doc = document, win = window;
  var root = doc.querySelector('[data-story]');
  if (!root || root.getAttribute('data-ready')) return;
  root.setAttribute('data-ready', '1');

  var NS = 'http://www.w3.org/2000/svg';
  var W = 480, H = 400;
  function E(tag, a, parent) {
    var e = doc.createElementNS(NS, tag);
    for (var k in a) if (a.hasOwnProperty(k)) e.setAttribute(k, a[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  function T(parent, x, y, s, cls, anchor) {
    var t = E('text', { x: x, y: y, 'class': cls || 's-t' }, parent);
    if (anchor) t.setAttribute('text-anchor', anchor);
    t.textContent = s;
    return t;
  }
  function c01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
  function seg(p, a, b) { return c01((p - a) / (b - a)); }
  function ease(v) { return 1 - Math.pow(1 - v, 3); }
  function show(e, o) { e.setAttribute('opacity', o.toFixed(3)); }
  function at(path, len, f) { return path.getPointAtLength(len * c01(f)); }
  function move(e, x, y) { e.setAttribute('transform', 'translate(' + x.toFixed(1) + ' ' + y.toFixed(1) + ')'); }
  function card(g, x, y, w, h, cls) { return E('rect', { x: x, y: y, width: w, height: h, rx: 12, 'class': cls || 's-card' }, g); }
  function draw(path, len, v) { path.setAttribute('stroke-dasharray', len + ' ' + len); path.setAttribute('stroke-dashoffset', (len * (1 - v)).toFixed(1)); }

  /* A rider marker: a filled circle with an initial; tag: 'Lead' / 'Sweep' under it. */
  function rider(g, init, cls, tag) {
    var r = E('g', {}, g);
    E('circle', { r: 12, 'class': 's-ring' }, r);
    E('circle', { r: 10, 'class': cls }, r);
    T(r, 0, 4, init, 's-tw', 'middle');
    if (tag) { E('rect', { x: -18, y: 15, width: 36, height: 15, rx: 7.5, 'class': 's-tag' }, r); T(r, 0, 26, tag, 's-tag-t', 'middle'); }
    return r;
  }
  function land(g) {
    E('rect', { width: W, height: H, 'class': 's-land' }, g);
    E('path', { d: 'M0 120 C 90 80, 170 140, 260 104 S 420 60, 480 96 V0 H0 Z', 'class': 's-hill1' }, g);
    E('path', { d: 'M0 400 V300 C 80 270, 150 320, 240 290 S 400 250, 480 280 V400 Z', 'class': 's-hill2' }, g);
  }
  function road(g, d) {
    E('path', { d: d, 'class': 's-road' }, g);
    E('path', { d: d, 'class': 's-road-in' }, g);
    return E('path', { d: d, 'class': 's-road-mid' }, g);
  }
  function tree(g, x, y, s) { E('path', { d: 'M' + x + ' ' + (y - 22 * s) + ' l' + (11 * s) + ' ' + (24 * s) + ' h' + (-22 * s) + 'z', 'class': 's-tree' }, g); }
  function tick(g, x, y) {
    var k = E('g', { transform: 'translate(' + x + ' ' + y + ')' }, g);
    var c = E('circle', { r: 8, 'class': 's-off' }, k);
    E('path', { d: 'M-3.5 0 l2.5 2.5 l4.5-5', 'class': 's-tick' }, k);
    return c;
  }
  var ROSTER = [['M', 's-r0', 'Meera'], ['I', 's-r1', 'Imran'], ['K', 's-r2', 'Kiran'], ['A', 's-r3', 'Asha'], ['D', 's-r4', 'Dev'], ['R', 's-r5', 'Ravi']];

  var SCENES = {
    /* 1. Planning: route drawn on the map, the crew, the poll, the pre-ride check. */
    plan: function (g) {
      land(g);
      card(g, 12, 12, 290, 376, 's-map');
      for (var i = 0; i < 6; i++) E('path', { d: 'M12 ' + (60 + i * 58) + ' C 90 ' + (40 + i * 58) + ', 180 ' + (90 + i * 58) + ', 302 ' + (52 + i * 58), 'class': 's-grid' }, g);
      var d = 'M48 346 C 92 300, 66 254, 118 232 S 214 204, 190 152 S 232 92, 252 62';
      E('path', { d: d, 'class': 's-road' }, g);
      var rt = E('path', { d: d, 'class': 's-route' }, g);
      var len = rt.getTotalLength();
      var pins = [[48, 346, 's-brand', 'Home', 14, 4], [114, 233, 's-warn', 'Fuel', -12, 4, 'end'], [196, 168, 's-warn', 'Breakfast', 12, 4], [252, 62, 's-brand', 'Ghat', -12, -10, 'end']];
      var pinEls = pins.map(function (q) {
        var k = E('g', { transform: 'translate(' + q[0] + ' ' + q[1] + ')' }, g);
        E('circle', { r: 7, 'class': q[2] + ' s-ringed' }, k);
        T(k, q[4], q[5], q[3], 's-t2', q[6]);
        return k;
      });
      card(g, 314, 12, 154, 124);
      T(g, 326, 34, 'Crew poll', 's-t');
      T(g, 326, 52, 'Sunday 5:30 am?', 's-t2');
      var bars = [[5, 'Sunday'], [1, 'Saturday']].map(function (b, k) {
        var y = 66 + k * 32;
        E('rect', { x: 326, y: y, width: 130, height: 22, rx: 6, 'class': 's-track' }, g);
        var bar = E('rect', { x: 326, y: y, width: 0, height: 22, rx: 6, 'class': k ? 's-bar2' : 's-bar' }, g);
        T(g, 332, y + 15, b[1] + ' ' + b[0], 's-t3');
        return [bar, b[0] / 6 * 130];
      });
      card(g, 314, 146, 154, 76);
      T(g, 326, 168, 'Sunday Sunrise Crew', 's-t3');
      var crew = ROSTER.map(function (r, k) { var m = rider(g, r[0], r[1]); move(m, 334 + k * 23, 198); return m; });
      card(g, 314, 232, 154, 156);
      T(g, 326, 254, 'Pre-ride check', 's-t');
      var checks = ['Location: always', 'Battery 86 %', 'Emergency contact', 'Nearby devices'].map(function (s, k) {
        var y = 280 + k * 28;
        var c = tick(g, 334, y);
        T(g, 348, y + 4, s, 's-t3');
        return c;
      });
      return function (p) {
        draw(rt, len, ease(seg(p, 0.02, 0.6)));
        pinEls.forEach(function (e, k) { show(e, seg(p, k * 0.17, k * 0.17 + 0.08)); });
        bars.forEach(function (b) { b[0].setAttribute('width', (b[1] * ease(seg(p, 0.08, 0.4))).toFixed(1)); });
        crew.forEach(function (e, k) { show(e, seg(p, 0.05 + k * 0.05, 0.12 + k * 0.05)); });
        checks.forEach(function (c, k) { c.setAttribute('class', p > 0.5 + k * 0.11 ? 's-ok' : 's-off'); });
      };
    },

    /* 2. Rolling out: six riders on one live map, lead and sweep, the intercom with noise reduction. */
    roll: function (g) {
      land(g);
      var d = 'M-20 340 C 70 336, 110 252, 196 250 S 326 300, 372 206 S 420 84, 500 66';
      road(g, d);
      var rt = E('path', { d: d, 'class': 's-route s-route--thin' }, g);
      var len = rt.getTotalLength();
      var riders = ROSTER.map(function (r, k) { return rider(g, r[0], r[1], k === 0 ? 'Lead' : k === 5 ? 'Sweep' : ''); });
      riders.reverse(); // draw the lead last (on top)
      card(g, 300, 14, 166, 40);
      E('circle', { cx: 318, cy: 34, r: 5, 'class': 's-ok' }, g);
      T(g, 330, 38, '6 riders, together', 's-t3');
      card(g, 14, 286, 228, 100);
      T(g, 28, 308, 'Intercom', 's-t');
      var who = T(g, 28, 326, 'Meera: "Fuel in 10 km"', 's-t2');
      var nrLabel = T(g, 228, 308, 'Noise reduction', 's-t3', 'end');
      var wave = [];
      for (var i = 0; i < 30; i++) wave.push(E('rect', { x: 28 + i * 6.6, y: 350, width: 3.4, height: 2, rx: 1.7, 'class': 's-wave' }, g));
      return function (p, t) {
        var head = 0.2 + 0.55 * ease(seg(p, 0, 1)) + (t || 0) * 0.004;
        riders.forEach(function (e, j) {
          var k = 5 - j;
          var q = at(rt, len, head - k * 0.075);
          move(e, q.x, q.y);
        });
        var nr = seg(p, 0.35, 0.75);
        nrLabel.textContent = nr > 0.5 ? 'Noise reduction on' : 'Wind and engine';
        who.setAttribute('opacity', nr > 0.5 ? 1 : 0.55);
        wave.forEach(function (b, k) {
          var voice = Math.max(0, Math.sin(k * 0.55 + (t || 0) * 2.2)) * Math.sin(k / 29 * Math.PI) * 26;
          var noise = (0.5 + 0.5 * Math.sin(k * 7.3 + (t || 0) * 9)) * 22 * (1 - nr);
          var h = Math.max(2, voice + noise);
          b.setAttribute('height', h.toFixed(1));
          b.setAttribute('y', (360 - h / 2).toFixed(1));
        });
      };
    },

    /* 3. On the ghat: hairpins, the curve warning with a comfortable speed, the limit sign (est.), hazard ahead. */
    ghat: function (g) {
      land(g);
      for (var i = 0; i < 9; i++) tree(g, 30 + i * 52, 392 - (i % 3) * 8, 0.9);
      var d = 'M70 410 L74 336 C 78 300, 118 292, 160 300 L352 328 C 424 338, 432 268, 382 258 L146 222 C 76 212, 82 146, 144 146 L460 154';
      road(g, d);
      var rt = E('path', { d: d, 'class': 's-route s-route--thin' }, g);
      var len = rt.getTotalLength();
      var hz = E('g', {}, g);
      E('path', { d: 'M0 -14 L13 9 H-13 Z', 'class': 's-warn s-ringed' }, hz);
      T(hz, 0, 6, '!', 's-tw', 'middle');
      E('rect', { x: -138, y: -12, width: 120, height: 22, rx: 11, 'class': 's-pill-warn' }, hz);
      T(hz, -128, 3, 'Gravel reported', 's-t3');
      move(hz, 352, 152);
      var me = rider(g, 'A', 's-r3');
      var warn = E('g', {}, g);
      card(warn, 14, 14, 452, 66, 's-card-warn');
      E('rect', { x: 26, y: 24, width: 46, height: 46, rx: 10, 'class': 's-warn' }, warn);
      E('path', { d: 'M40 62 V44 a8 8 0 0 1 8-8 h6 M51 30 l6 6 -6 6', 'class': 's-arrow' }, warn);
      T(warn, 84, 44, 'Hairpin right', 's-t');
      T(warn, 84, 62, 'Comfortable speed', 's-t2');
      T(warn, 450, 52, '25', 's-big', 'end');
      T(warn, 450, 70, '300 m', 's-t2', 'end');
      var sign = E('g', { transform: 'translate(430 108)' }, g);
      E('circle', { r: 22, 'class': 's-sign' }, sign);
      T(sign, 0, 5, '~40', 's-sign-t', 'middle');
      T(sign, 0, 38, 'est.', 's-t2', 'middle');
      return function (p) {
        var q = at(rt, len, 0.04 + 0.5 * ease(seg(p, 0, 0.9)));
        move(me, q.x, q.y);
        show(warn, seg(p, 0.12, 0.26));
        show(sign, seg(p, 0.05, 0.15));
        show(hz, seg(p, 0.4, 0.55));
      };
    },

    /* 4. No signal in the forest: the offline link passes a message phone to phone, hop by hop. */
    forest: function (g) {
      land(g);
      for (var i = 0; i < 14; i++) { tree(g, 14 + i * 36, 210 + (i % 2) * 10, 1.2); tree(g, 30 + i * 36, 398, 1.1); }
      var d = 'M-10 312 C 110 270, 200 340, 300 298 S 440 248, 490 256';
      road(g, d);
      var rt = E('path', { d: d, 'class': 's-road-mid' }, g);
      var len = rt.getTotalLength();
      var order = [['I', 's-r1', 'Imran'], ['A', 's-r3', 'Asha'], ['D', 's-r4', 'Dev'], ['K', 's-r2', 'Kiran'], ['M', 's-r0', 'Meera']];
      var pts = [0.1, 0.3, 0.5, 0.7, 0.9].map(function (f) { return at(rt, len, f); });
      var links = [];
      for (var k = 0; k < 4; k++) {
        var a = pts[k], b = pts[k + 1], mx = (a.x + b.x) / 2, my = Math.min(a.y, b.y) - 56;
        var l = E('path', { d: 'M' + a.x + ' ' + (a.y - 14) + ' Q ' + mx + ' ' + my + ' ' + b.x + ' ' + (b.y - 14), 'class': 's-link' }, g);
        var lab = T(g, mx, my + 18, '~300 m', 's-t3', 'middle');
        links.push([l, lab, l.getTotalLength()]);
      }
      order.forEach(function (r, k) {
        var m = rider(g, r[0], r[1]);
        move(m, pts[k].x, pts[k].y);
        var bars = E('g', { transform: 'translate(' + (pts[k].x - 8) + ' ' + (pts[k].y + 24) + ')' }, g);
        for (var j = 0; j < 4; j++) E('rect', { x: j * 4.5, y: 10 - j * 3, width: 3, height: 2 + j * 3, rx: 1, 'class': 's-off' }, bars);
        E('path', { d: 'M-1 13 L17 -3', 'class': 's-cross' }, bars);
      });
      var pulse = E('circle', { r: 6, 'class': 's-pulse' }, g);
      card(g, 14, 14, 150, 36);
      T(g, 28, 37, 'No mobile signal', 's-t3');
      var chip = E('g', {}, g);
      E('rect', { x: 172, y: 14, width: 200, height: 36, rx: 18, 'class': 's-pill-warn' }, chip);
      T(chip, 188, 37, 'Offline link: 5 riders, 4 hops', 's-t3');
      var msg = E('g', {}, g);
      card(msg, 254, 62, 212, 54);
      T(msg, 266, 84, 'Imran: Fuel stop after the bridge', 's-t3');
      T(msg, 266, 104, 'via Asha, Dev and Kiran', 's-t2');
      return function (p) {
        show(chip, seg(p, 0.05, 0.15));
        links.forEach(function (l, k) { draw(l[0], l[2], seg(p, 0.08 + k * 0.06, 0.16 + k * 0.06)); show(l[1], seg(p, 0.12 + k * 0.06, 0.2 + k * 0.06)); });
        var q = seg(p, 0.42, 0.9) * 4, hop = Math.min(3, Math.floor(q)), f = q - hop;
        var pt = links[hop][0].getPointAtLength(links[hop][2] * (q >= 4 ? 1 : f));
        pulse.setAttribute('cx', pt.x.toFixed(1)); pulse.setAttribute('cy', pt.y.toFixed(1));
        show(pulse, p > 0.4 && p < 0.93 ? 1 : 0);
        show(msg, seg(p, 0.88, 0.96));
      };
    },

    /* 5. A rider falls behind: the gap grows, the sweep and lead are told, a regroup point, everyone meets. */
    behind: function (g) {
      land(g);
      var d = 'M-20 352 C 100 340, 140 262, 240 262 S 382 206, 500 124';
      road(g, d);
      var rt = E('path', { d: d, 'class': 's-route s-route--thin' }, g);
      var len = rt.getTotalLength();
      var pin = E('g', {}, g);
      var pp = at(rt, len, 0.8);
      E('path', { d: 'M0 0 C -12 -14, -12 -30, 0 -30 C 12 -30, 12 -14, 0 0 Z', 'class': 's-brand s-ringed' }, pin);
      E('circle', { cx: 0, cy: -19, r: 4, 'class': 's-hole' }, pin);
      E('rect', { x: -64, y: -64, width: 128, height: 26, rx: 13, 'class': 's-card' }, pin);
      T(pin, 0, -46, 'Regroup: fuel stop', 's-t3', 'middle');
      move(pin, pp.x, pp.y - 10);
      var group = [0, 1, 3, 4, 5].map(function (k) { return rider(g, ROSTER[k][0], ROSTER[k][1]); });
      var kiran = rider(g, 'K', 's-r2');
      var gap = T(g, 0, 0, '', 's-t3', 'middle');
      var alert = E('g', {}, g);
      card(alert, 14, 14, 250, 58, 's-card-warn');
      T(alert, 28, 38, 'Kiran is falling behind', 's-t');
      T(alert, 28, 58, 'Sweep and lead told, quietly', 's-t2');
      return function (p) {
        var a = seg(p, 0, 0.5), c = ease(seg(p, 0.66, 1));
        var head = 0.64 + 0.04 * a;
        group.forEach(function (e, k) {
          var f = head - k * 0.045;
          f = f + (0.79 - k * 0.022 - f) * c;
          var q = at(rt, len, f); move(e, q.x, q.y);
        });
        var kf = 0.5 - 0.26 * ease(a);
        kf = kf + (0.68 - kf) * c;
        var kq = at(rt, len, kf); move(kiran, kq.x, kq.y);
        var km = (0.2 + 1.0 * ease(a)) * (1 - c);
        gap.textContent = c > 0.95 ? 'Everyone together' : 'Kiran: ' + km.toFixed(1) + ' km behind';
        gap.setAttribute('x', kq.x.toFixed(1)); gap.setAttribute('y', (kq.y + 30).toFixed(1));
        show(alert, seg(p, 0.45, 0.56) * (1 - seg(p, 0.92, 1)));
        show(pin, seg(p, 0.55, 0.66));
      };
    },

    /* 6. The crash: the 30 s check, no answer, SOS by SMS and through the group, the beacon; then "Find Ravi". */
    crash: function (g) {
      var A = E('g', {}, g), B = E('g', {}, g);
      land(A);
      for (var i = 0; i < 8; i++) tree(A, 250 + (i % 4) * 46, 150 + Math.floor(i / 4) * 90, 1.2);
      var d = 'M-20 330 C 120 320, 160 250, 240 236 S 380 250, 500 200';
      road(A, d);
      var ravi = E('g', { transform: 'translate(318 168)' }, A);
      var rip = [0, 1, 2].map(function () { return E('circle', { r: 20, 'class': 's-ripple' }, ravi); });
      E('circle', { r: 13, 'class': 's-sos s-ringed' }, ravi);
      T(ravi, 0, 4, 'R', 's-tw', 'middle');
      var ring = E('g', { transform: 'translate(70 78)' }, A);
      E('circle', { r: 50, 'class': 's-card' }, ring);
      E('circle', { r: 38, 'class': 's-ring-track' }, ring);
      var arc = E('circle', { r: 38, 'class': 's-ring-sos', transform: 'rotate(-90)' }, ring);
      var num = T(ring, 0, 6, '30', 's-big', 'middle');
      var sub = T(ring, 0, 26, 'Are you OK?', 's-t2', 'middle');
      var outs = [['SMS to Amma', 'no data needed', 344, 290], ['Group alerted', 'server and offline link', 150, 380], ['Live link', 'family can follow', 360, 70]].map(function (o) {
        var k = E('g', {}, A);
        E('path', { d: 'M318 168 L' + o[2] + ' ' + (o[3] - 20), 'class': 's-link s-link--sos' }, k);
        card(k, o[2] - 74, o[3] - 40, 148, 44);
        T(k, o[2] - 62, o[3] - 21, o[0], 's-t3');
        T(k, o[2] - 62, o[3] - 6, o[1], 's-t2');
        return k;
      });
      // Phase B: the rescue finder.
      E('rect', { width: W, height: H, 'class': 's-land' }, B);
      card(B, 40, 24, 400, 352);
      T(B, 64, 58, 'Find Ravi', 's-t');
      T(B, 64, 78, 'Siren on. Walk toward the sound.', 's-t2');
      var gp = 'M100 280 A140 140 0 0 1 380 280';
      E('path', { d: gp, 'class': 's-gauge-track' }, B);
      var gauge = E('path', { d: gp, 'class': 's-gauge' }, B);
      var glen = Math.PI * 140;
      T(B, 100, 306, 'Colder', 's-t2', 'middle');
      T(B, 380, 306, 'Hotter', 's-t2', 'middle');
      var dist = T(B, 240, 236, '~100 m', 's-huge', 'middle');
      T(B, 240, 260, 'estimated', 's-t2', 'middle');
      var trend = T(B, 240, 340, '', 's-t3', 'middle');
      var waves = [0, 1, 2].map(function (k) { return E('path', { d: 'M' + (392 + k * 9) + ' 46 a14 14 0 0 1 0 24', 'class': 's-wave-l' }, B); });
      var circ = 2 * Math.PI * 38;
      arc.setAttribute('stroke-dasharray', circ.toFixed(1) + ' ' + circ.toFixed(1));
      return function (p, t) {
        var ph = seg(p, 0.48, 0.56);
        show(A, 1 - ph); show(B, ph);
        var cd = seg(p, 0.02, 0.24);
        arc.setAttribute('stroke-dashoffset', (circ * cd).toFixed(1));
        num.textContent = String(Math.round(30 * (1 - cd)));
        sub.textContent = cd >= 1 ? 'No answer' : 'Are you OK?';
        var sent = seg(p, 0.26, 0.3);
        rip.forEach(function (c, k) {
          var r = ((t || 0) * 0.6 + k / 3) % 1;
          if (!t) r = 0.25 + k * 0.28;
          c.setAttribute('r', (16 + r * 70).toFixed(1));
          show(c, sent * (1 - r) * 0.9);
        });
        outs.forEach(function (o, k) { show(o, seg(p, 0.28 + k * 0.05, 0.34 + k * 0.05)); });
        var f = ease(seg(p, 0.56, 0.95));
        gauge.setAttribute('stroke-dasharray', (glen * (0.12 + 0.8 * f)).toFixed(1) + ' ' + glen.toFixed(1));
        dist.textContent = '~' + Math.max(8, Math.round((100 - 92 * f) / (f > 0.6 ? 1 : 5)) * (f > 0.6 ? 1 : 5)) + ' m';
        trend.textContent = f > 0.97 ? 'Found. Call 112 and stay with him.' : f > 0.05 ? 'Getting warmer' : 'Bluetooth in range';
        waves.forEach(function (w, k) { show(w, t ? 0.3 + 0.7 * Math.max(0, Math.sin(t * 4 - k)) : 0.8); });
      };
    },

    /* 7. Everyone home: the trip report chart (speed over the ride, the group limit), tiles, e-mail and live link. */
    home: function (g) {
      E('rect', { width: W, height: H, 'class': 's-land' }, g);
      card(g, 14, 14, 452, 236);
      T(g, 30, 40, 'Speed over the ride (km/h)', 's-t');
      var x0 = 54, x1 = 446, y0 = 222, y1 = 62;
      var X = function (km) { return x0 + km / 128 * (x1 - x0); };
      var Y = function (v) { return y0 - v / 80 * (y0 - y1); };
      [0, 40, 80].forEach(function (v) { E('path', { d: 'M' + x0 + ' ' + Y(v) + ' H' + x1, 'class': 's-grid' }, g); T(g, x0 - 8, Y(v) + 4, String(v), 's-ax', 'end'); });
      [0, 64, 128].forEach(function (km) { T(g, X(km), 242, km + ' km', 's-ax', km ? (km === 128 ? 'end' : 'middle') : 'start'); });
      E('path', { d: 'M' + x0 + ' ' + Y(60) + ' H' + x1, 'class': 's-limit' }, g);
      T(g, x1, Y(60) - 6, 'Group limit 60', 's-ax s-ax--warn', 'end');
      var vs = [0, 34, 52, 58, 46, 22, 38, 61, 56, 54, 30, 0, 28, 48, 57, 44, 0];
      var dd = vs.map(function (v, k) { return (k ? 'L' : 'M') + X(k * 8).toFixed(1) + ' ' + Y(v).toFixed(1); }).join(' ');
      var line = E('path', { d: dd, 'class': 's-line' }, g);
      var len = line.getTotalLength();
      var tiles = [['128 km', 'Distance'], ['3 h 42 m', 'Moving'], ['3', 'Stops']].map(function (s, k) {
        var e = E('g', { transform: 'translate(' + (14 + k * 154) + ' 262)' }, g);
        card(e, 0, 0, 144, 62);
        T(e, 14, 30, s[0], 's-t');
        T(e, 14, 50, s[1], 's-t2');
        return e;
      });
      var chips = [['Ride summary e-mailed', 14], ['Family followed the live link', 236]].map(function (s) {
        var e = E('g', {}, g);
        E('rect', { x: s[1], y: 338, width: 216, height: 44, rx: 22, 'class': 's-pill-ok' }, e);
        tick(e, s[1] + 22, 360).setAttribute('class', 's-ok');
        T(e, s[1] + 38, 364, s[0], 's-t3');
        return e;
      });
      return function (p) {
        draw(line, len, ease(seg(p, 0.02, 0.55)));
        tiles.forEach(function (e, k) { show(e, seg(p, 0.35 + k * 0.08, 0.45 + k * 0.08)); });
        chips.forEach(function (e, k) { show(e, seg(p, 0.6 + k * 0.1, 0.7 + k * 0.1)); });
      };
    }
  };

  function build(name, svg) {
    var g = E('g', { 'class': 'st-scene' }, svg);
    var fn = SCENES[name];
    return fn ? { g: g, draw: fn(g) } : null;
  }
  function newSvg(parent) {
    var svg = E('svg', { viewBox: '0 0 ' + W + ' ' + H, 'class': 'st-svg', 'aria-hidden': 'true', focusable: 'false', preserveAspectRatio: 'xMidYMid meet' });
    parent.appendChild(svg);
    return svg;
  }

  var steps = [].slice.call(root.querySelectorAll('[data-scene]'));
  var stageBox = root.querySelector('[data-story-stage]');
  var reduce = win.matchMedia && win.matchMedia('(prefers-reduced-motion: reduce)').matches;
  // Older browsers without aspect-ratio (Safari < 15) cannot size the pinned stage: show the still frames instead.
  var hasAspect = !!(win.CSS && win.CSS.supports && win.CSS.supports('aspect-ratio', '1 / 1'));
  var live = hasAspect && !reduce && stageBox && win.getComputedStyle(stageBox.parentNode).display !== 'none';

  /* ---------- Static frames (reduced motion, or a layout without the stage) ---------- */
  function drawFigure(fig) {
    if (fig.getAttribute('data-drawn')) return;
    fig.setAttribute('data-drawn', '1');
    var box = fig.querySelector('.st__box') || fig;
    var s = build(fig.getAttribute('data-frame'), newSvg(box));
    if (s) s.draw(parseFloat(fig.getAttribute('data-p') || '1'), 0);
  }
  if (!live) {
    var figs = [].slice.call(root.querySelectorAll('[data-frame]'));
    if ('IntersectionObserver' in win) {
      var fio = new IntersectionObserver(function (es) { es.forEach(function (e) { if (e.isIntersecting) { fio.unobserve(e.target); drawFigure(e.target); } }); }, { rootMargin: '400px 0px' });
      figs.forEach(function (f) { fio.observe(f); });
    } else figs.forEach(drawFigure);
    root.setAttribute('data-state', 'static');
    return;
  }

  /* ---------- Live stage ---------- */
  root.setAttribute('data-state', 'live');
  var svg = newSvg(stageBox);
  var dots = [].slice.call(root.querySelectorAll('.st__dots li'));
  var cur = null, curName = '', curIdx = -1, curP = 0, visible = false, raf = 0, t0 = 0;

  function setScene(i) {
    var name = steps[i].getAttribute('data-scene');
    if (name === curName) return;
    var old = cur;
    cur = build(name, svg);
    curName = name;
    if (cur) cur.g.setAttribute('class', 'st-scene is-in');
    if (old) {
      old.g.setAttribute('class', 'st-scene is-out');
      win.setTimeout(function () { if (old.g.parentNode) old.g.parentNode.removeChild(old.g); }, 400);
    }
    steps.forEach(function (s, k) { if (k === i) s.setAttribute('data-active', ''); else s.removeAttribute('data-active'); });
    dots.forEach(function (d, k) { d.className = k === i ? 'is-on' : ''; });
  }
  function readingLine() {
    var vh = win.innerHeight;
    var r = stageBox.parentNode.getBoundingClientRect();
    var wide = win.innerWidth >= 900;
    return wide ? vh * 0.5 : Math.min(vh - 40, r.bottom + (vh - r.bottom) * 0.45);
  }
  function measure() {
    var line = readingLine(), idx = 0;
    for (var i = 0; i < steps.length; i++) if (steps[i].getBoundingClientRect().top <= line) idx = i;
    var r = steps[idx].getBoundingClientRect();
    curP = c01((line - r.top) / Math.max(1, r.height * (idx === steps.length - 1 ? 0.45 : 0.85)));
    if (idx !== curIdx) { curIdx = idx; setScene(idx); }
  }
  function frame(ts) {
    raf = 0;
    if (!visible || doc.hidden) return;
    if (!t0) t0 = ts;
    measure();
    if (cur) cur.draw(curP, (ts - t0) / 1000);
    raf = win.requestAnimationFrame(frame);
  }
  function kick() { if (!raf && visible && !doc.hidden) raf = win.requestAnimationFrame(frame); }
  if ('IntersectionObserver' in win) {
    new IntersectionObserver(function (es) { visible = es[0].isIntersecting; kick(); }, { rootMargin: '100px 0px' }).observe(root);
  } else visible = true;
  doc.addEventListener('visibilitychange', kick);
  measure();
  if (cur) cur.draw(curP, 0);
  kick();
})();
