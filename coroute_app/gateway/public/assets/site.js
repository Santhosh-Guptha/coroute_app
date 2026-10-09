/* Coroute website behaviour. No libraries, no third-party requests, no cookies.
   Data-attribute API is documented in FOUNDATION.md. */
(function () {
  'use strict';
  var doc = document, root = doc.documentElement, win = window;
  root.classList.add('js');
  var mq = function (q) { return win.matchMedia ? win.matchMedia(q) : { matches: false, addEventListener: function () {} }; };
  var reduceMQ = mq('(prefers-reduced-motion: reduce)');
  var reduce = reduceMQ.matches;
  var finePointer = mq('(hover: hover) and (pointer: fine)').matches;
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || doc).querySelectorAll(sel)); };
  var clamp = function (v, a, b) { return v < a ? a : v > b ? b : v; };
  var hasIO = 'IntersectionObserver' in win;
  var passive = { passive: true };

  /* ---------- Header: compact solid state after 64 px ---------- */
  var header = doc.querySelector('[data-header]');
  function updateHeader() {
    if (header) header.classList.toggle('is-scrolled', win.scrollY > 64);
  }

  /* ---------- Mobile menu (disclosure) ---------- */
  var toggle = doc.querySelector('.nav-toggle');
  var menu = toggle && doc.getElementById(toggle.getAttribute('aria-controls'));
  function setMenu(open, restoreFocus) {
    if (!menu) return;
    toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    toggle.querySelector('.nav-toggle__label').textContent = open ? 'Close' : 'Menu';
    menu.hidden = !open;
    header.classList.toggle('is-open', open);
    root.classList.toggle('menu-open', open);
    if (open) {
      menu.classList.remove('is-entering'); void menu.offsetWidth; menu.classList.add('is-entering');
      var first = menu.querySelector('a,button'); if (first) first.focus();
    } else if (restoreFocus) toggle.focus();
  }
  if (menu) {
    toggle.addEventListener('click', function () { setMenu(toggle.getAttribute('aria-expanded') !== 'true', true); });
    doc.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') setMenu(false, true);
    });
    // Leaving the header with the keyboard closes the menu (it covers the page).
    header.addEventListener('focusout', function (e) {
      if (toggle.getAttribute('aria-expanded') === 'true' && e.relatedTarget && !header.contains(e.relatedTarget)) setMenu(false, false);
    });
    menu.addEventListener('click', function (e) { if (e.target.closest('a')) setMenu(false, false); });
    mq('(min-width: 1024px)').addEventListener('change', function (e) { if (e.matches) setMenu(false, false); });
  }

  /* ---------- Visibility: which progress/animated elements are on screen ---------- */
  var progressEls = $$('[data-progress],[data-pinned]');
  var visible = new Set();
  var offscreenWatch = $$('[data-progress],[data-pinned],[data-depth-scene],.map,[data-anim]');
  if (hasIO) {
    var visIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        en.target.classList.toggle('is-offscreen', !en.isIntersecting);
        if (en.isIntersecting) visible.add(en.target); else visible.delete(en.target);
      });
      schedule();
    }, { rootMargin: '10% 0px 10% 0px' });
    offscreenWatch.forEach(function (el) { visIO.observe(el); });
  } else progressEls.forEach(function (el) { visible.add(el); });

  /* ---------- Route draw: measure path length once ---------- */
  function measureRoutes(ctx) {
    $$('[data-route]', ctx).forEach(function (el) {
      var paths = el.tagName.toLowerCase() === 'path' ? [el] : $$('path', el);
      paths.forEach(function (p) {
        if (!p.getTotalLength) return;
        var len = Math.ceil(p.getTotalLength()) + 1;
        p.style.setProperty('--len', len + 'px');
        p.classList.add('route-draw');
        if (el.getAttribute('data-route') === 'reveal' || p.getAttribute('data-route') === 'reveal') {
          p.classList.add('is-timed');
          p.style.setProperty('--p', reduce ? 1 : 0);
          if (!reduce) watchReveal(p, function () { p.style.setProperty('--p', 1); });
        }
      });
    });
  }

  /* ---------- Scroll progress ---------- */
  function progressOf(el, mode, r, vh) {
    if (mode === 'pinned') return clamp(-r.top / Math.max(1, r.height - vh), 0, 1);
    if (mode === 'enter') return clamp((vh - r.top) / (vh * 0.6), 0, 1);       // top enters bottom -> top at 40%
    if (mode === 'exit') return clamp(-r.top / Math.max(1, r.height), 0, 1);    // top at top -> bottom at top
    if (mode === 'center') return clamp((vh / 2 - r.top) / Math.max(1, r.height), 0, 1); // crosses viewport centre
    return clamp((vh - r.top) / (vh + r.height), 0, 1);                          // 'view': enters -> leaves
  }
  function isStatic(el) {
    var s = el.querySelector('.pinned__sticky');
    return reduce || !s || getComputedStyle(s).position !== 'sticky';
  }
  function setStage(el, p) {
    var stages = el._stages || (el._stages = $$('[data-stage]', el));
    if (!stages.length) return;
    var n = 0;
    stages.forEach(function (s) { n = Math.max(n, +s.getAttribute('data-stage') + 1); });
    var stat = isStatic(el);
    el.classList.toggle('is-static', stat);
    var cur = stat ? n - 1 : Math.min(n - 1, Math.floor(p * n));
    if (el._cur === cur && el._stat === stat) return;
    el._cur = cur; el._stat = stat;
    el.setAttribute('data-active-stage', String(cur));
    stages.forEach(function (s) {
      var i = +s.getAttribute('data-stage');
      s.classList.toggle('is-active', stat || i === cur);
      s.classList.toggle('is-past', i < cur);
      // Every stage stays in the accessibility tree, in order: screen readers read the whole story while
      // the visual cross-fade follows the scroll. Only the visible stage is marked as the current step.
      if (!stat && i === cur) s.setAttribute('aria-current', 'step'); else s.removeAttribute('aria-current');
    });
  }
  function updateProgress(all) {
    var vh = win.innerHeight;
    (all ? progressEls : progressEls.filter(function (el) { return visible.has(el); })).forEach(function (el) {
      var pinned = el.hasAttribute('data-pinned');
      var mode = pinned ? 'pinned' : (el.getAttribute('data-progress') || 'view');
      var p = reduce ? 1 : progressOf(el, mode, el.getBoundingClientRect(), vh);
      if (pinned && isStatic(el)) p = 1;
      p = Math.round(p * 1000) / 1000;
      if (el._p !== p) { el._p = p; el.style.setProperty('--p', p); }
      if (pinned) setStage(el, p);
    });
  }

  /* ---------- rAF scheduler (scroll + resize) ---------- */
  var queued = false;
  function frame() { queued = false; updateHeader(); updateProgress(false); }
  function schedule() { if (!queued) { queued = true; win.requestAnimationFrame(frame); } }
  win.addEventListener('scroll', schedule, passive);
  win.addEventListener('resize', function () { progressEls.forEach(function (el) { el._cur = -1; }); schedule(); }, passive);

  /* ---------- Reveal on intersect (once) ---------- */
  var revealIO = hasIO && !reduce ? new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      if (!en.isIntersecting) return;
      revealIO.unobserve(en.target);
      var cb = en.target._onReveal; if (cb) { en.target._onReveal = null; cb(); }
    });
  }, { rootMargin: '0px 0px -10% 0px', threshold: 0.01 }) : null;
  function watchReveal(el, cb) {
    if (!revealIO) return cb();
    el._onReveal = cb; revealIO.observe(el);
  }
  $$('[data-reveal-stagger]').forEach(function (parent) {
    var step = +parent.getAttribute('data-reveal-stagger') || 80;
    $$('[data-reveal]', parent).forEach(function (el, i) { el.style.setProperty('--reveal-delay', (i * step) + 'ms'); });
  });
  // Content already on the first screen is shown at once (no fade): it is what the visitor came to read,
  // and fading it in would delay the largest contentful paint by the reveal duration.
  var firstScreen = win.innerHeight;
  $$('[data-reveal]').forEach(function (el) {
    if (revealIO && win.scrollY < 8) {
      var r = el.getBoundingClientRect();
      if (r.top < firstScreen * 0.9 && r.bottom > 0 && !el.closest('[data-pinned]')) { el.classList.add('is-in', 'is-instant'); return; }
    }
    watchReveal(el, function () { el.classList.add('is-in'); });
  });

  /* ---------- Numbers: data-count="12" (data-count-decimals, data-count-from) ---------- */
  function fmt(el, v) {
    var d = +(el.getAttribute('data-count-decimals') || 0);
    return v.toFixed(d);
  }
  function countTo(el) {
    var to = parseFloat(el.getAttribute('data-count'));
    if (!isFinite(to)) return;
    var from = el._v != null ? el._v : parseFloat(el.getAttribute('data-count-from') || el.textContent) || 0;
    el._v = to;
    if (reduce || from === to) { el.textContent = fmt(el, to); return; }
    var t0 = null, dur = +(el.getAttribute('data-count-duration') || 900);
    var id = el._raf = (el._raf || 0) + 1;
    win.requestAnimationFrame(function tick(t) {
      if (el._raf !== id) return;
      if (t0 === null) t0 = t;
      var k = clamp((t - t0) / dur, 0, 1), e = 1 - Math.pow(1 - k, 3);
      el.textContent = fmt(el, from + (to - from) * e);
      if (k < 1) win.requestAnimationFrame(tick);
    });
  }
  var counters = $$('[data-count]');
  counters.forEach(function (el) {
    var f = el.getAttribute('data-count-from');
    if (f != null && !reduce && revealIO) { el._v = parseFloat(f) || 0; el.textContent = fmt(el, el._v); }
    watchReveal(el, function () { countTo(el); });
  });
  if ('MutationObserver' in win && counters.length) {
    var mo = new MutationObserver(function (list) { list.forEach(function (m) { countTo(m.target); }); });
    counters.forEach(function (el) { mo.observe(el, { attributes: true, attributeFilter: ['data-count'] }); });
  }

  /* ---------- Hero depth: data-depth-scene > [data-depth="px"] (fine pointers only) ---------- */
  if (finePointer && !reduce) {
    $$('[data-depth-scene]').forEach(function (scene) {
      var layers = $$('[data-depth]', scene), tx = 0, ty = 0, x = 0, y = 0, running = false;
      if (!layers.length) return;
      function step() {
        x += (tx - x) * 0.08; y += (ty - y) * 0.08;
        layers.forEach(function (l) {
          var a = +l.getAttribute('data-depth') || 0;
          l.style.translate = (x * a).toFixed(2) + 'px ' + (y * a).toFixed(2) + 'px';
        });
        if ((Math.abs(tx - x) > 0.001 || Math.abs(ty - y) > 0.001) && !scene.classList.contains('is-offscreen')) win.requestAnimationFrame(step);
        else running = false;
      }
      scene.addEventListener('pointermove', function (e) {
        if (e.pointerType !== 'mouse' || scene.classList.contains('is-offscreen')) return;
        var r = scene.getBoundingClientRect();
        tx = -clamp((e.clientX - r.left) / r.width * 2 - 1, -1, 1);
        ty = -clamp((e.clientY - r.top) / r.height * 2 - 1, -1, 1);
        if (!running) { running = true; win.requestAnimationFrame(step); }
      }, passive);
      scene.addEventListener('pointerleave', function () { tx = 0; ty = 0; if (!running) { running = true; win.requestAnimationFrame(step); } }, passive);
    });
  }

  /* ---------- Page transitions on internal links ---------- */
  if (!reduce) {
    doc.addEventListener('click', function (e) {
      var a = e.target.closest && e.target.closest('a[href]');
      if (!a || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      if (a.target && a.target !== '_self' || a.hasAttribute('download') || a.hasAttribute('data-no-transition')) return;
      var url = new URL(a.href, location.href);
      if (url.origin !== location.origin || /^\/(download|api|join)(\/|$)/.test(url.pathname) || /\.[a-z0-9]+$/i.test(url.pathname)) return;
      if (url.pathname === location.pathname && url.search === location.search) return; // same page / hash link
      e.preventDefault();
      root.classList.add('is-leaving');
      setTimeout(function () { location.href = url.href; }, 150);
    });
    win.addEventListener('pageshow', function () { root.classList.remove('is-leaving'); });
  }

  /* ---------- Feedback form: POST /api/feedback (JSON) ---------- */
  var form = doc.querySelector('form[data-feedback]');
  if (form) {
    var $ = function (id) { return doc.getElementById(id); };
    var t = $('fb-t'), email = $('fb-email'), msg = $('fb-message'), status = $('fb-status'), btn = $('fb-submit');
    var btnLabel = btn.textContent;
    var stamp = function () { t.value = String(Date.now()); };
    stamp();
    var setErr = function (el, text) {
      var e = $(el.id + '-err'); if (e) e.textContent = text || '';
      el.setAttribute('aria-invalid', text ? 'true' : 'false');
    };
    var setState = function (state, text) {
      form.setAttribute('data-state', state);
      status.textContent = text || '';
    };
    var checkEmail = function () {
      var bad = !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.value.trim());
      setErr(email, bad ? 'Enter a valid e-mail address.' : ''); return !bad;
    };
    var checkMsg = function () {
      var m = msg.value.trim(), text = m.length < 20 ? 'Please write at least 20 characters.' : m.length > 2000 ? 'Please keep it under 2000 characters.' : '';
      setErr(msg, text); return !text;
    };
    var validate = function () { var a = checkEmail(), b = checkMsg(); return a && b; };
    // Errors show on blur and clear while typing, so the layout settles before the submit click.
    email.addEventListener('blur', function () { if (email.value) checkEmail(); });
    msg.addEventListener('blur', function () { if (msg.value) checkMsg(); });
    email.addEventListener('input', function () { if (email.getAttribute('aria-invalid') === 'true') checkEmail(); });
    msg.addEventListener('input', function () { if (msg.getAttribute('aria-invalid') === 'true') checkMsg(); });
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      if (form.getAttribute('data-state') === 'sending') return;
      if (!validate()) {
        setState('error', 'Please correct the highlighted fields.');
        (email.getAttribute('aria-invalid') === 'true' ? email : msg).focus();
        return;
      }
      setState('sending', 'Sending…');
      btn.disabled = true; btn.textContent = 'Sending…';
      var data = {};
      new FormData(form).forEach(function (v, k) { data[k] = v; });
      fetch(form.getAttribute('action') || '/api/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) })
        .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { status: r.status, j: j }; }); })
        .then(function (res) {
          if (res.status === 201 || res.status === 204) {
            form.reset(); stamp();
            setState('sent', 'Thanks. Your feedback reached the Coroute team.');
            return;
          }
          var j = res.j || {};
          var text = j.error || (res.status === 429 ? 'Too many messages from this network. Please try again later.' : 'Could not send right now. Please try again later.');
          setState('error', text);
          if (j.fields) { if (j.fields.email) setErr(email, j.fields.email); if (j.fields.message) setErr(msg, j.fields.message); }
          if (res.status === 400) stamp();
        })
        .catch(function () { setState('error', 'Could not reach the server. Please check your connection and try again.'); })
        .then(function () { btn.disabled = false; btn.textContent = btnLabel; });
    });
  }

  /* ---------- First-party page-view count: path and referrer host only. No cookies, no identifiers. ---------- */
  try {
    var payload = JSON.stringify({ path: location.pathname, ref: doc.referrer || '' });
    if (navigator.sendBeacon) navigator.sendBeacon('/api/pv', new Blob([payload], { type: 'text/plain' }));
    else fetch('/api/pv', { method: 'POST', body: payload, keepalive: true }).catch(function () {});
  } catch (e) { /* ignore */ }

  /* ---------- Start ---------- */
  measureRoutes(doc);
  updateHeader();
  updateProgress(true);
  reduceMQ.addEventListener && reduceMQ.addEventListener('change', function (e) { reduce = e.matches; progressEls.forEach(function (el) { el._cur = -1; }); updateProgress(true); });
  win.Coroute = { count: function (el, to) { el.setAttribute('data-count', String(to)); }, refresh: function () { measureRoutes(doc); updateProgress(true); } };
  win.__corouteReady = true;
})();
