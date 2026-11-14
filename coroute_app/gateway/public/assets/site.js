/* CoRoute website behaviour. No libraries, no third-party requests, no cookies.
   Data-attribute API is documented in FOUNDATION.md. */
(function () {
  'use strict';
  var doc = document, root = doc.documentElement, win = window;
  root.classList.add('js');
  var mq = function (q) { return win.matchMedia ? win.matchMedia(q) : { matches: false, addEventListener: function () {} }; };
  /* Safari < 14 has MediaQueryList.addListener only; calling addEventListener there threw and stopped this file. */
  var onMQ = function (m, fn) { if (!m) return; if (m.addEventListener) m.addEventListener('change', fn); else if (m.addListener) m.addListener(fn); };
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

  /* ---------- Header fit: narrow phones (Galaxy Fold 280 px) and large system text ----------
     When the header row does not fit, drop the theme button (also in the footer), then the "Get the app" button (also
     in the menu), so the page never scrolls sideways. Re-checked on resize, font load and text-size changes. */
  var headerInner = header && header.querySelector('.site-header__inner');
  function fitHeader() {
    if (!headerInner) return;
    root.classList.remove('hdr-tight', 'hdr-tighter');
    // The row may push the header box itself wider than the screen, so compare with the page width too.
    var over = function () {
      var w = root.clientWidth;
      return headerInner.scrollWidth > headerInner.clientWidth + 1 || headerInner.getBoundingClientRect().right > w + 1 ||
        root.scrollWidth > w + 1 && header.scrollWidth > w + 1;
    };
    if (!over()) return;
    root.classList.add('hdr-tight');
    if (over()) root.classList.add('hdr-tighter');
  }
  if (headerInner) {
    fitHeader();
    win.addEventListener('resize', fitHeader, passive);
    win.addEventListener('load', fitHeader);
    if (doc.fonts && doc.fonts.ready) doc.fonts.ready.then(fitHeader);
    if ('ResizeObserver' in win) { var hro = new win.ResizeObserver(fitHeader); hro.observe(header); $$('.site-header__actions, .brand', header).forEach(function (n) { hro.observe(n); }); }
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
    onMQ(mq('(min-width: 1024px)'), function (e) { if (e.matches) setMenu(false, false); });
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
  /* 3.55: cards on every page enter like the app's lists, a short stagger per row. Pages only mark their blocks with
     classes; this tags them, and siblings that reveal together get increasing delays (capped, so nothing waits long). */
  var AUTO_REVEAL = '.hm-features > li, .hm-steps > li, .hm-facts > div, .philosophy-grid > *, .pg-never > *, .pg-perms > *, ' +
    '.pg-faq details, .hm-cta, .pg-cta, .hm-notice, .pg-dl__card, .legal-summary, .imp-grid > .imp-tile, .imp-safety, .nf__links > li';
  $$(AUTO_REVEAL).forEach(function (el) {
    if (!el.hasAttribute('data-reveal') && !el.closest('[data-pinned]')) el.setAttribute('data-reveal', '');
  });
  $$('[data-reveal]').forEach(function (el) {
    if (el.style.getPropertyValue('--reveal-delay') || !el.parentElement || el.parentElement.hasAttribute('data-reveal-stagger')) return;
    var sibs = Array.prototype.filter.call(el.parentElement.children, function (c) { return c.hasAttribute('data-reveal'); });
    var i = sibs.indexOf(el);
    if (sibs.length > 1 && i > 0) el.style.setProperty('--reveal-delay', (Math.min(i, 6) * 70) + 'ms');
  });
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
      if (r.top < firstScreen * 0.9 && r.bottom > 0 && !el.closest('[data-pinned]')) { el.classList.add('is-in', 'is-instant', 'is-done'); return; }
    }
    watchReveal(el, function () {
      el.classList.add('is-in');
      setTimeout(function () { el.classList.add('is-done'); }, 900 + (parseInt(el.style.getPropertyValue('--reveal-delay'), 10) || 0));
    });
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

  /* ---------- Page transitions on internal links ----------
     Browsers with cross-document view transitions cross-fade by themselves (site.css @view-transition); the rest get
     this short fade-out. Nothing moves with reduced motion. */
  var nativePageTransitions = 'onpagereveal' in win && !!(win.CSS && CSS.supports && CSS.supports('view-transition-name: none'));
  if (!reduce && !nativePageTransitions) {
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
    var consent = $('fb-consent');
    // Topic: links such as "Share a safety idea" (data-fb-topic) or /?topic=safety-idea#feedback preselect it.
    var topic = $('fb-topic');
    var pickTopic = function (v) {
      if (!topic || !v) return;
      for (var i = 0; i < topic.options.length; i++) if (topic.options[i].value === v) { topic.value = v; return; }
    };
    try { pickTopic(new URLSearchParams(location.search).get('topic')); } catch (e) { /* old browser */ }
    $$('[data-fb-topic]').forEach(function (a) {
      a.addEventListener('click', function () { pickTopic(a.getAttribute('data-fb-topic')); });
    });
    var checkConsent = function () {
      if (!consent) return true;
      setErr(consent, consent.checked ? '' : 'Please tick the box so we can store your message and reply.'); return consent.checked;
    };
    if (consent) consent.addEventListener('change', checkConsent);
    var validate = function () { var a = checkEmail(), b = checkMsg(), c = checkConsent(); return a && b && c; };
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
        (email.getAttribute('aria-invalid') === 'true' ? email : msg.getAttribute('aria-invalid') === 'true' ? msg : consent || msg).focus();
        return;
      }
      setState('sending', 'Sending...');
      btn.disabled = true; btn.textContent = 'Sending...';
      var data = {};
      new FormData(form).forEach(function (v, k) { data[k] = v; });
      fetch(form.getAttribute('action') || '/api/feedback', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) })
        .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { status: r.status, j: j }; }); })
        .then(function (res) {
          if (res.status === 201 || res.status === 204) {
            var keepTopic = topic ? topic.value : '';
            form.reset(); stamp(); pickTopic(keepTopic);
            setState('sent', 'Thanks. Your feedback reached the CoRoute team.');
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

  /* ---------- Rider reviews: approved post-trip stories only ----------
     Source: GET /api/public/community-stories?limit=N -> { ok, stories: [...], summary: { count, averageRating } }.
     Fallback: GET /community-stories (may be a bare array). Every value is rider-written text, so it is only ever
     placed with textContent / setAttribute, never parsed as markup. Nothing is invented: no sample stories, no default rating. */
  var reviewsBox = doc.getElementById('community-stories-container');
  if (reviewsBox) {
    var reviewsSummary = doc.getElementById('reviews-summary');
    var reviewLimit = clamp(parseInt(reviewsBox.getAttribute('data-limit'), 10) || 6, 1, 24);
    var SVGNS = 'http://www.w3.org/2000/svg';
    var make = function (tag, cls, text) {
      var n = doc.createElement(tag);
      if (cls) n.className = cls;
      if (text != null) n.textContent = String(text);
      return n;
    };
    var str = function (v, max) {
      if (v == null) return '';
      var s = String(v).replace(/\s+\n/g, '\n').trim();
      return max && s.length > max ? s.slice(0, max - 1).trim() + '...' : s;
    };
    var num = function (v) { var n = typeof v === 'string' ? parseFloat(v) : v; return typeof n === 'number' && isFinite(n) ? n : null; };
    var toDate = function (v) {
      if (v == null || v === '') return null;
      var d = new Date(typeof v === 'string' && /^\d+$/.test(v) ? +v : v);
      return isNaN(d.getTime()) ? null : d;
    };
    // Photos: same-site paths or https only. Anything else (javascript:, protocol-relative, http) is dropped.
    var safeSrc = function (u) {
      var s = str(u);
      return /^https:\/\/[^\s"'<>]+$/i.test(s) || /^\/(?!\/)[^\s"'<>]*$/.test(s) ? s : '';
    };
    var listOf = function (data) {
      if (Array.isArray(data)) return data;
      if (data && Array.isArray(data.stories)) return data.stories;
      return null;
    };
    // Only real, moderated feedback: it has an id and words, and is not a seeded placeholder.
    var isReal = function (s) {
      if (!s || typeof s !== 'object') return false;
      var id = str(s.feedbackId);
      if (!id || /^(fb-)?(seed|demo|sample|test)\b/i.test(id)) return false;
      return !!str(s.formattedText || s.writtenFeedback);
    };
    var stars = function (rating) {
      var r = num(rating);
      if (r === null) return null;
      r = Math.round(clamp(r, 1, 5));
      var wrap = make('p', 'rv-stars');
      wrap.setAttribute('role', 'img');
      wrap.setAttribute('aria-label', 'Rated ' + r + ' out of 5');
      for (var i = 1; i <= 5; i++) {
        var svg = doc.createElementNS(SVGNS, 'svg');
        svg.setAttribute('viewBox', '0 0 20 20');
        svg.setAttribute('aria-hidden', 'true');
        svg.setAttribute('focusable', 'false');
        svg.setAttribute('class', i <= r ? 'rv-star is-on' : 'rv-star');
        var p = doc.createElementNS(SVGNS, 'path');
        p.setAttribute('d', 'M10 1.6l2.6 5.3 5.8.8-4.2 4.1 1 5.8L10 14.9l-5.2 2.7 1-5.8L1.6 7.7l5.8-.8z');
        svg.appendChild(p);
        wrap.appendChild(svg);
      }
      return wrap;
    };
    var fact = function (dl, label, value) {
      if (!value) return;
      var d = make('div');
      d.appendChild(make('dt', null, label));
      d.appendChild(make('dd', null, value));
      dl.appendChild(d);
    };
    // Card templates chosen by the admin (same ids as the gateway's TEMPLATES): how many photos each shows.
    var TEMPLATES = { 'photo-left': [1, 1], 'photo-top': [1, 1], 'quote-card': [0, 0], 'gallery': [2, 3] };
    var LEGACY = { 'text-left-pic-right': 'photo-left', 'pic-left-text-right': 'photo-left', 'pic-top-text-bottom': 'photo-top', 'multi-pic-grid': 'gallery', 'text-only': 'quote-card' };
    // Same rule as the server: a template that needs more photos than the story has falls back to one that fits.
    var templateFor = function (s, n) {
      var t = str(s.template || s.templateLayout || s.layout);
      t = TEMPLATES[t] ? t : (LEGACY[t] || '');
      if (t) {
        if (n >= TEMPLATES[t][0]) return t;
        return t === 'gallery' && n >= 1 ? 'photo-top' : 'quote-card';
      }
      return n >= 2 ? 'gallery' : n === 1 ? 'photo-left' : 'quote-card';
    };
    var photoEl = function (src, size, alt, onGone) {
      var img = doc.createElement('img');
      img.loading = 'lazy';
      img.decoding = 'async';
      var w = size && num(size.width), h = size && num(size.height);
      img.width = w && w > 0 ? Math.round(w) : 480;
      img.height = h && h > 0 ? Math.round(h) : 360;
      img.alt = alt;
      img.addEventListener('error', onGone);
      img.src = src;
      return img;
    };
    var renderCard = function (s) {
      var trip = str(s.tripName, 90);
      var from = str(s.routeFrom, 60), to = str(s.routeTo, 60);
      var rider = str(s.riderLabel || s.anonymousRiderLabel, 60) || 'CoRoute rider';
      var text = str(s.formattedText || s.writtenFeedback, 1800);
      var srcs = (Array.isArray(s.photos) ? s.photos : Array.isArray(s.selectedPhotos) ? s.selectedPhotos : []);
      var sizes = Array.isArray(s.photoSizes) ? s.photoSizes : [];
      var photos = [];
      srcs.forEach(function (u, i) { var src = safeSrc(u); if (src) photos.push({ src: src, size: sizes[i] || null }); });
      var template = templateFor(s, photos.length);
      photos = photos.slice(0, TEMPLATES[template][1]);
      var outer = make('article', 'rv-card rv-card--' + template);
      outer.setAttribute('data-template', template);
      var card = make('div', 'rv-card__body');
      var head = make('header', 'rv-card__head');
      var st = stars(s.rating);
      if (st) head.appendChild(st);
      head.appendChild(make('h3', 'rv-card__trip', trip || (from && to ? from + ' to ' + to : 'A CoRoute trip')));
      // The route line only adds something when the trip name is not already "<from> to <to>".
      var routeText = from && to ? from + ' to ' + to : '';
      if (routeText && trip && trip.toLowerCase() !== routeText.toLowerCase()) head.appendChild(make('p', 'rv-card__route', routeText));
      card.appendChild(head);

      var quote = make('blockquote', 'rv-card__quote');
      var qp = make('p', null, text);
      quote.appendChild(qp);
      card.appendChild(quote);
      if (text.length > 360) {
        quote.classList.add('is-clamped');
        var more = make('button', 'rv-card__more', 'Read the full story');
        more.type = 'button';
        more.setAttribute('aria-expanded', 'false');
        more.addEventListener('click', function () {
          var open = quote.classList.toggle('is-clamped') === false;
          more.setAttribute('aria-expanded', open ? 'true' : 'false');
          more.textContent = open ? 'Show less' : 'Read the full story';
        });
        card.appendChild(more);
      }

      // Photos: only the ones an admin selected for the website, laid out by the card's template.
      if (photos.length) {
        var altOf = function (i) { return 'Group photo' + (photos.length > 1 ? ' ' + (i + 1) : '') + ' from ' + (trip || 'this trip') + ', shared by ' + rider; };
        var media;
        if (template === 'gallery') {
          media = make('ul', 'rv-card__photos rv-card__gallery');
          media.setAttribute('role', 'list');
          photos.forEach(function (p, i) {
            var li = make('li');
            li.appendChild(photoEl(p.src, p.size, altOf(i), function () {
              li.remove();
              if (!media.children.length) { media.remove(); outer.classList.add('is-photoless'); }
            }));
            media.appendChild(li);
          });
        } else {
          media = make('figure', 'rv-card__media');
          media.appendChild(photoEl(photos[0].src, photos[0].size, altOf(0), function () { media.remove(); outer.classList.add('is-photoless'); }));
        }
        outer.appendChild(media);
      }

      var dl = make('dl', 'rv-card__facts');
      var km = num(s.distanceKm), days = num(s.durationDays);
      if (km !== null && km > 0) fact(dl, 'Distance', Math.round(km).toLocaleString('en-IN') + ' km');
      if (days !== null && days > 0) { days = Math.max(1, Math.round(days)); fact(dl, 'Duration', days + (days === 1 ? ' day' : ' days')); }
      if (dl.children.length) card.appendChild(dl);

      var foot = make('footer', 'rv-card__foot');
      foot.appendChild(make('span', 'rv-card__rider', rider));
      var badge = make('span', 'rv-card__badge', 'Completed trip, approved');
      foot.appendChild(badge);
      var when = toDate(s.approvedAt) || toDate(s.submittedAt);
      if (when) {
        var tm = make('time', 'rv-card__date', when.toLocaleDateString('en-IN', { month: 'short', year: 'numeric' }));
        tm.setAttribute('datetime', when.toISOString().slice(0, 10));
        foot.appendChild(tm);
      }
      card.appendChild(foot);
      outer.appendChild(card);
      return outer;
    };
    var setSummary = function (text) {
      if (!reviewsSummary) return;
      reviewsSummary.textContent = text || '';
      reviewsSummary.hidden = !text;
    };
    var showMessage = function (kind) {
      reviewsBox.textContent = '';
      reviewsBox.setAttribute('data-state', kind);
      var box = make('div', 'rv-empty' + (kind === 'error' ? ' rv-empty--error' : ''));
      if (kind === 'error') {
        box.appendChild(make('h3', 'rv-empty__title', 'Rider stories could not load right now.'));
        box.appendChild(make('p', null, 'This does not affect the app or your rides. Please try again in a moment.'));
        var retry = make('button', 'btn btn--outline', 'Try again');
        retry.type = 'button';
        retry.addEventListener('click', loadReviews);
        box.appendChild(retry);
      } else {
        box.appendChild(make('h3', 'rv-empty__title', 'No published stories yet.'));
        box.appendChild(make('p', null, 'Rider stories appear here after a ride and a moderation check. Finish your first convoy and share yours.'));
        var cta = make('a', 'btn btn--primary', 'Get the app');
        cta.href = '/get';
        box.appendChild(cta);
      }
      reviewsBox.appendChild(box);
      setSummary('');
    };
    var render = function (data) {
      var list = (listOf(data) || []).filter(isReal).slice(0, reviewLimit);
      reviewsBox.removeAttribute('aria-busy');
      if (!list.length) return showMessage('empty');
      reviewsBox.textContent = '';
      reviewsBox.setAttribute('data-state', 'loaded');
      var grid = make('div', 'rv-grid');
      list.forEach(function (s) { grid.appendChild(renderCard(s)); });
      reviewsBox.appendChild(grid);
      // Summary: the server's numbers when it sends them, otherwise only what is on screen.
      var sum = data && !Array.isArray(data) ? data.summary : null;
      var count = sum ? num(sum.count) : null, avg = sum ? num(sum.averageRating) : null;
      if (count && avg) {
        setSummary('Average ' + avg.toFixed(1) + ' out of 5 from ' + count + (count === 1 ? ' approved story' : ' approved stories') + '.');
      } else {
        var rated = list.map(function (s) { return num(s.rating); }).filter(function (r) { return r !== null && r >= 1 && r <= 5; });
        if (rated.length) {
          var a = rated.reduce(function (x, y) { return x + y; }, 0) / rated.length;
          setSummary('Average ' + a.toFixed(1) + ' out of 5 across the ' + (rated.length === 1 ? 'story' : rated.length + ' stories') + ' shown here.');
        } else setSummary('');
      }
    };
    var getJSON = function (url) {
      return fetch(url, { headers: { Accept: 'application/json' }, credentials: 'omit' }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      }).then(function (j) {
        if (!listOf(j)) throw new Error('unexpected shape');
        return j;
      });
    };
    function loadReviews() {
      reviewsBox.setAttribute('aria-busy', 'true');
      reviewsBox.setAttribute('data-state', 'loading');
      getJSON('/api/public/community-stories?limit=' + reviewLimit)
        .catch(function () { return getJSON('/community-stories'); })
        .then(render)
        .catch(function () { reviewsBox.removeAttribute('aria-busy'); showMessage('error'); });
    }
    if ('fetch' in win) {
      // Load when the section comes near the screen: the first screen of the page needs no network.
      if (hasIO) {
        var rvIO = new IntersectionObserver(function (en) {
          if (!en[0].isIntersecting) return;
          rvIO.disconnect();
          loadReviews();
        }, { rootMargin: '600px 0px' });
        rvIO.observe(reviewsBox);
      } else loadReviews();
    } else showMessage('error');
  }

  /* ---------- Theme toggle (system / light / dark), remembered in this browser only ----------
     "system" follows the phone or computer setting (no data-theme). The head of every page applies a saved choice
     before the first paint, so there is no flash of the wrong theme. */
  var themeBtn = doc.getElementById('theme-toggle');
  var themeSetters = $$('[data-theme-set]');
  var THEME_ORDER = ['system', 'light', 'dark'];
  var THEME_BG = { light: '#F6F4F0', dark: '#15181C' };
  var themeMetas = $$('meta[name="theme-color"]');
  themeMetas.forEach(function (m) { m.setAttribute('data-default', m.getAttribute('content') || ''); });
  var readTheme = function () {
    var t = null;
    try { t = win.localStorage.getItem('coroute_theme'); } catch (e) { /* storage blocked */ }
    return t === 'dark' || t === 'light' ? t : 'system';
  };
  var applyTheme = function (mode, save) {
    if (mode === 'light' || mode === 'dark') root.setAttribute('data-theme', mode);
    else { mode = 'system'; root.removeAttribute('data-theme'); }
    themeMetas.forEach(function (m) { m.setAttribute('content', mode === 'system' ? m.getAttribute('data-default') : THEME_BG[mode]); });
    if (themeBtn) {
      themeBtn.setAttribute('data-mode', mode);
      themeBtn.setAttribute('aria-label', 'Theme: ' + mode + '. Change theme');
      themeBtn.setAttribute('title', 'Theme: ' + mode);
    }
    themeSetters.forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-theme-set') === mode ? 'true' : 'false'); });
    if (save) {
      try { if (mode === 'system') win.localStorage.removeItem('coroute_theme'); else win.localStorage.setItem('coroute_theme', mode); } catch (e) { /* storage blocked */ }
    }
  };
  applyTheme(readTheme(), false);
  if (themeBtn) {
    themeBtn.addEventListener('click', function () {
      var cur = themeBtn.getAttribute('data-mode') || 'system';
      applyTheme(THEME_ORDER[(THEME_ORDER.indexOf(cur) + 1) % THEME_ORDER.length], true);
    });
  }
  themeSetters.forEach(function (b) {
    b.addEventListener('click', function () { applyTheme(b.getAttribute('data-theme-set'), true); });
  });

  /* ---------- CoRoute impact, all time (3.55b): real totals from real riders since CoRoute began ----------
     Source: GET /api/public/alltime-stats -> { ok, enabled, scope: 'all-time', stats: { ridersWithRide, registeredRiders,
     kmRidden, movingHours, ridesCompleted, groupRides, largestGroup, longestTripKm, bikes, safety: { sosResolved,
     crashAlerts, alertsAnswered, medianResponseSec, roadReports }, thisWeek: { rides, km, movingHours, riders } } },
     falling back to GET /api/public/impact-stats (same tiles, no rider count) on an older server. The server already makes every number coarse (src/public_privacy.js safeImpact): 0 or null
     means "not enough yet", and such a tile stays hidden. The same floors are applied here again, so an older or
     misconfigured server can never put an exact small number on the page. A box ([data-impact]) shows only when at
     least two of its tiles are real. Checked every minute while the tab is visible; counters roll up, never with
     reduced motion. Values go in with textContent only. */
  var impactBoxes = doc.querySelectorAll ? Array.prototype.slice.call(doc.querySelectorAll('[data-impact]')) : [];
  if (impactBoxes.length && 'fetch' in win) {
    var iNum = function (v) { var n = typeof v === 'string' ? parseFloat(v) : v; return typeof n === 'number' && isFinite(n) && n > 0 ? n : null; };
    var iCount = function (v) {
      var n = iNum(v); if (n === null) return null;
      n = Math.floor(n); if (n < 10) return null;
      var step = n < 1000 ? 10 : n < 100000 ? 100 : 1000;
      return Math.floor(n / step) * step;
    };
    var iKm = function (v) {
      var n = iNum(v); if (n === null) return null;
      var step = n < 10000 ? 100 : 1000, r = Math.floor(n / step) * step;
      return r >= 100 ? r : null;
    };
    var iPlus = function (n) { return Math.round(n).toLocaleString('en-IN') + '+'; };
    var iPlain = function (n) { return Math.round(n).toLocaleString('en-IN'); };
    // A median response time as people say it: "40 s", "3 min", "1 h 10 min". Never animated.
    var iDuration = function (sec) {
      if (sec < 60) return [String(Math.round(sec)), 's'];
      if (sec < 3600) return [String(Math.round(sec / 60)), 'min'];
      var h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
      return [String(h), m ? 'h ' + m + ' min' : 'h'];
    };
    var impactValues = function (st) {
      var s = st.safety && typeof st.safety === 'object' ? st.safety : {};
      var rides = iCount(st.ridesCompleted), groups = iCount(st.groupRides != null ? st.groupRides : st.groupsRidden);
      var largest = iNum(st.largestGroup), longest = iNum(st.longestTripKm), resp = iNum(s.medianResponseSec);
      return {
        // Riders with at least one completed ride (all time); an older server has no such number.
        riders: { n: iCount(st.ridersWithRide), fmt: iPlus },
        km: { n: iKm(st.kmRidden), fmt: iPlus },
        hours: { n: iCount(st.movingHours), fmt: iPlus },
        rides: { n: rides, fmt: iPlus },
        groupRides: { n: groups, fmt: iPlus },
        // A record of one ride, without names: only alongside enough group rides (the server gates it the same way).
        largestGroup: { n: groups !== null && largest !== null && largest >= 2 ? Math.floor(largest) : null, fmt: iPlain },
        longestTrip: { n: rides !== null && longest !== null && longest >= 10 ? Math.floor(longest / 10) * 10 : null, fmt: iPlus },
        bikes: { n: iCount(st.bikes), fmt: iPlus },
        sos: { n: iCount(s.sosResolved), fmt: iPlus },
        crash: { n: iCount(s.crashAlerts), fmt: iPlus },
        answered: { n: iCount(s.alertsAnswered), fmt: iPlus },
        response: { n: resp !== null ? Math.round(resp) : null, duration: true },
        roads: { n: iCount(s.roadReports), fmt: iPlus },
      };
    };
    var iReduce = !win.matchMedia || win.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var iSeen = !('IntersectionObserver' in win);
    var iPending = [];
    var iWrite = function (dd, text, unit) {
      dd.textContent = text;
      if (unit) { var u = doc.createElement('small'); u.textContent = unit; dd.appendChild(u); }
    };
    var iRoll = function (dd, from, to, fmt) {
      if (iReduce || !win.requestAnimationFrame || from === to) { iWrite(dd, fmt(to)); return; }
      var t0 = null, dur = from ? 900 : 1400, id = dd._roll = (dd._roll || 0) + 1;
      iWrite(dd, fmt(from));
      win.requestAnimationFrame(function step(now) {
        if (dd._roll !== id) return;
        if (t0 === null) t0 = now;
        var k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3);
        iWrite(dd, fmt(from + (to - from) * e));
        if (k < 1) win.requestAnimationFrame(step);
      });
    };
    var renderImpact = function (st) {
      var v = impactValues(st);
      var now = new Date();
      impactBoxes.forEach(function (box) {
        var tiles = Array.prototype.slice.call(box.querySelectorAll('[data-impact-key]'));
        var real = 0, missing = 0;
        tiles.forEach(function (tile) {
          var val = v[tile.getAttribute('data-impact-key')];
          var dd = tile.querySelector('[data-impact-value]');
          if (!val || val.n === null || !dd) { tile.hidden = true; missing++; return; }
          real++;
          var prev = tile._n;
          tile._n = val.n;
          tile.hidden = false;
          if (val.duration) {
            var d = iDuration(val.n);
            dd.setAttribute('aria-label', d[0] + ' ' + d[1]);
            iWrite(dd, d[0], d[1]);
          } else {
            dd.setAttribute('aria-label', val.fmt(val.n));
            // First time: roll up from zero when the box comes into view. Later: from the last shown value.
            if (prev == null && !iSeen) { iWrite(dd, val.fmt(0)); iPending.push([dd, val.n, val.fmt]); }
            else iRoll(dd, prev == null ? 0 : prev, val.n, val.fmt);
          }
          if (prev != null && prev !== val.n && !iReduce) {
            tile.classList.remove('is-updated'); void tile.offsetWidth; tile.classList.add('is-updated');
          }
        });
        Array.prototype.slice.call(box.querySelectorAll('[data-impact-group]')).forEach(function (g) {
          g.hidden = !g.querySelector('[data-impact-key]:not([hidden])');
        });
        var note = box.querySelector('[data-impact-note]');
        if (note) note.hidden = !(missing && real >= 2);
        // This week, as a small second line: only when 10 rides that week are behind it.
        var wk = box.querySelector('[data-impact-week]');
        if (wk) {
          var w = st.thisWeek && typeof st.thisWeek === 'object' ? st.thisWeek : {};
          var wRides = iCount(w.rides), wKm = wRides !== null ? iKm(w.km) : null;
          wk.textContent = wRides !== null ? 'This week: ' + iPlus(wRides) + ' rides' + (wKm !== null ? ', ' + iPlus(wKm) + ' km' : '') + '.' : '';
          wk.hidden = wRides === null;
        }
        var upd = box.querySelector('[data-impact-updated]');
        if (upd) upd.textContent = 'Updated ' + now.toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', hour12: false });
        box.hidden = real < 2;
      });
    };
    var iLast = 0;
    var loadImpact = function () {
      if (doc.hidden) return;
      iLast = Date.now();
      var iGet = function (url) {
        return fetch(url, { headers: { Accept: 'application/json' }, credentials: 'omit' })
          .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); });
      };
      iGet('/api/public/alltime-stats')
        .catch(function () { return iGet('/api/public/impact-stats'); })
        .then(function (j) {
          // Switched off by the admin or the feature flag: hide, and say nothing.
          if (!j || j.enabled === false || !j.stats || typeof j.stats !== 'object') { impactBoxes.forEach(function (b) { b.hidden = true; }); return; }
          renderImpact(j.stats);
        })
        .catch(function () { /* stays as it was: no numbers are better than wrong ones */ });
    };
    if (!iSeen) {
      var impIO = new IntersectionObserver(function (entries) {
        if (!entries.some(function (en) { return en.isIntersecting; })) return;
        iSeen = true;
        impIO.disconnect();
        iPending.splice(0).forEach(function (p) { iRoll(p[0], 0, p[1], p[2]); });
      }, { threshold: 0.15 });
      impactBoxes.forEach(function (b) { impIO.observe(b); });
    }
    loadImpact();
    if (win.setInterval) win.setInterval(loadImpact, 60000);
    if (doc.addEventListener) {
      doc.addEventListener('visibilitychange', function () { if (!doc.hidden && Date.now() - iLast >= 60000) loadImpact(); });
    }
  }

  /* ---------- Leaderboards (3.55b): riders by their unique username ----------
     Source: GET /api/public/leaderboard -> { updatedAt, topScore: [{ username, score, rides }], longestRide: [{ username, km }],
     mostKm: [{ username, km }], mostHours: [{ username, hours }], mostRides: [{ username, rides }] } (rounded on the server;
     riders who hid their name in the app are not in it). A box ([data-leaderboard]) has tabs ([data-lb-tab="topScore"] ...),
     one list ([data-lb-list]) and an empty note ([data-lb-empty]). With data-lb-hide-empty the whole box stays hidden until
     a board has a rider (home page); without it the empty note shows (the leaderboard page). A missing endpoint (404) or
     a bad answer counts as empty: nothing is invented. Usernames go in with textContent only, cleaned of control and
     direction characters and cut to 32 characters. Tabs follow the ARIA tabs pattern (arrow keys, Home, End). Checked
     every 5 minutes while the tab is visible; rows slide in and bars grow, never with reduced motion. */
  var lbBoxes = doc.querySelectorAll ? Array.prototype.slice.call(doc.querySelectorAll('[data-leaderboard]')) : [];
  if (lbBoxes.length && 'fetch' in win) {
    var LB = {
      topScore: { field: 'score', label: 'Top rider', fmt: function (n) { return Math.floor(n).toLocaleString('en-IN'); }, unit: '/ 100', sub: 'rides' },
      longestRide: { field: 'km', label: 'Longest ride', fmt: function (n) { return Math.floor(n).toLocaleString('en-IN'); }, unit: 'km' },
      mostKm: { field: 'km', label: 'Most km', fmt: function (n) { return Math.floor(n).toLocaleString('en-IN'); }, unit: 'km' },
      mostHours: { field: 'hours', label: 'Most hours', fmt: function (n) { return Math.floor(n).toLocaleString('en-IN'); }, unit: 'h' },
      mostRides: { field: 'rides', label: 'Most rides', fmt: function (n) { return Math.floor(n).toLocaleString('en-IN'); }, unit: 'rides' },
    };
    var lbReduce = !win.matchMedia || win.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var lbName = function (v) {
      if (typeof v !== 'string') return '';
      var s = v.replace(/[\u0000-\u001F\u007F-\u009F\u00AD\u200B-\u200F\u2028-\u202E\u2060-\u2069\uFEFF]/g, '').trim();
      return Array.from ? Array.from(s).slice(0, 32).join('') : s.slice(0, 32);
    };
    var lbNum = function (v) { var n = typeof v === 'string' ? parseFloat(v) : v; return typeof n === 'number' && isFinite(n) && n > 0 ? n : null; };
    // Every board as a clean list: real usernames and positive values only, highest first, no duplicates.
    var lbClean = function (j) {
      var src = j && typeof j === 'object' ? (j.boards && typeof j.boards === 'object' ? j.boards : j) : {};
      var out = {};
      Object.keys(LB).forEach(function (key) {
        var meta = LB[key], seen = {}, rows = [];
        (Array.isArray(src[key]) ? src[key] : []).forEach(function (e) {
          if (!e || typeof e !== 'object') return;
          var name = lbName(e.username), n = lbNum(e[meta.field]);
          if (!name || n === null || seen[name.toLowerCase()]) return;
          seen[name.toLowerCase()] = true;
          rows.push({ name: name, n: n, sub: meta.sub ? lbNum(e[meta.sub]) : null });
        });
        rows.sort(function (a, b) { return b.n - a.n; });
        out[key] = rows;
      });
      return out;
    };
    var lbHue = function (name) { var h = 0; for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360; return h; };
    var lbRender = function (box, key, rows) {
      var list = box.querySelector('[data-lb-list]');
      if (!list) return;
      var meta = LB[key], limit = parseInt(box.getAttribute('data-lb-limit') || '10', 10) || 10;
      var shown = rows.slice(0, Math.max(1, Math.min(10, limit)));
      var max = shown.length ? shown[0].n : 0;
      list.textContent = '';
      list.setAttribute('aria-label', meta.label + ', top ' + shown.length);
      var bars = [];
      shown.forEach(function (r, i) {
        var li = doc.createElement('li');
        li.className = 'lb-row' + (i < 3 ? ' lb-row--' + (i + 1) : '');
        if (li.style && li.style.setProperty) li.style.setProperty('--i', String(i));
        var rank = doc.createElement('span'); rank.className = 'lb-row__rank'; rank.textContent = String(i + 1);
        var av = doc.createElement('span'); av.className = 'lb-row__avatar'; av.setAttribute('aria-hidden', 'true');
        av.textContent = (Array.from ? Array.from(r.name)[0] : r.name.charAt(0)).toUpperCase();
        if (av.style && av.style.setProperty) av.style.setProperty('--h', String(lbHue(r.name)));
        var who = doc.createElement('span'); who.className = 'lb-row__who';
        var nm = doc.createElement('span'); nm.className = 'lb-row__name'; nm.textContent = r.name;
        who.appendChild(nm);
        if (r.sub !== null) { var sb = doc.createElement('span'); sb.className = 'lb-row__sub'; sb.textContent = Math.floor(r.sub).toLocaleString('en-IN') + (Math.floor(r.sub) === 1 ? ' ride' : ' rides'); who.appendChild(sb); }
        var val = doc.createElement('span'); val.className = 'lb-row__value';
        val.textContent = meta.fmt(r.n);
        var u = doc.createElement('small'); u.textContent = ' ' + (meta.unit === 'rides' && Math.floor(r.n) === 1 ? 'ride' : meta.unit); val.appendChild(u);
        var bar = doc.createElement('span'); bar.className = 'lb-row__bar'; bar.setAttribute('aria-hidden', 'true');
        var fill = doc.createElement('span'); bar.appendChild(fill);
        bars.push([fill, max ? Math.max(4, Math.round((r.n / max) * 100)) : 0]);
        li.appendChild(rank); li.appendChild(av); li.appendChild(who); li.appendChild(val); li.appendChild(bar);
        list.appendChild(li);
      });
      var grow = function () { bars.forEach(function (b) { if (b[0].style) b[0].style.width = b[1] + '%'; }); };
      if (lbReduce || !win.requestAnimationFrame) grow();
      else {
        if (list.classList) { list.classList.remove('is-anim'); void list.offsetWidth; list.classList.add('is-anim'); }
        win.requestAnimationFrame(function () { win.requestAnimationFrame(grow); });
      }
    };
    var lbSetup = function (box) {
      if (box._lb) return box._lb;
      var tabs = Array.prototype.slice.call(box.querySelectorAll('[data-lb-tab]'));
      var state = box._lb = { tabs: tabs, current: null, boards: null };
      var select = function (tab, focus) {
        tabs.forEach(function (t) {
          var on = t === tab;
          t.setAttribute('aria-selected', on ? 'true' : 'false');
          t.setAttribute('tabindex', on ? '0' : '-1');
        });
        var panel = box.querySelector('[data-lb-panel]');
        if (panel && tab.id) panel.setAttribute('aria-labelledby', tab.id);
        state.current = tab.getAttribute('data-lb-tab');
        if (focus && tab.focus) tab.focus();
        if (state.boards) lbRender(box, state.current, state.boards[state.current] || []);
      };
      state.select = select;
      tabs.forEach(function (t) {
        if (!t.addEventListener) return;
        t.addEventListener('click', function () { select(t, false); });
        t.addEventListener('keydown', function (e) {
          var vis = tabs.filter(function (x) { return !x.hidden; });
          var i = vis.indexOf(t), next = null;
          if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = vis[(i + 1) % vis.length];
          else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = vis[(i - 1 + vis.length) % vis.length];
          else if (e.key === 'Home') next = vis[0];
          else if (e.key === 'End') next = vis[vis.length - 1];
          if (next) { e.preventDefault(); select(next, true); }
        });
      });
      return state;
    };
    var lbShow = function (boards, updatedAt) {
      lbBoxes.forEach(function (box) {
        var st = lbSetup(box);
        st.boards = boards;
        var any = false;
        st.tabs.forEach(function (t) {
          var has = (boards[t.getAttribute('data-lb-tab')] || []).length > 0;
          t.hidden = !has;
          if (has) any = true;
        });
        var empty = box.querySelector('[data-lb-empty]'), body = box.querySelector('[data-lb-body]');
        if (empty) empty.hidden = any;
        if (body) body.hidden = !any;
        var live = box.querySelector('[data-lb-live]');
        if (live) live.hidden = !any;
        var upd = box.querySelector('[data-lb-updated]');
        var at = updatedAt ? new Date(typeof updatedAt === 'string' && /^\d+$/.test(updatedAt) ? +updatedAt : updatedAt) : null;
        if (upd) upd.textContent = any && at && !isNaN(at.getTime()) ? 'Updated ' + at.toLocaleDateString('en-IN', { day: 'numeric', month: 'short' }) + ', ' + at.toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', hour12: false }) : '';
        box.hidden = !any && box.hasAttribute('data-lb-hide-empty');
        if (!any) { var list = box.querySelector('[data-lb-list]'); if (list) list.textContent = ''; return; }
        var keep = st.tabs.filter(function (t) { return !t.hidden && t.getAttribute('data-lb-tab') === st.current; })[0];
        var first = keep || st.tabs.filter(function (t) { return !t.hidden; })[0];
        if (first) st.select(first, false);
      });
    };
    var lbLast = 0;
    var loadBoards = function () {
      if (doc.hidden) return;
      lbLast = Date.now();
      fetch('/api/public/leaderboard', { headers: { Accept: 'application/json' }, credentials: 'omit' })
        .then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
        .then(function (j) {
          if (!j || j.enabled === false) return lbShow(lbClean(null), null);
          lbShow(lbClean(j), j.updatedAt);
        })
        .catch(function () { lbShow(lbClean(null), null); });
    };
    loadBoards();
    if (win.setInterval) win.setInterval(loadBoards, 300000);
    if (doc.addEventListener) {
      doc.addEventListener('visibilitychange', function () { if (!doc.hidden && Date.now() - lbLast >= 300000) loadBoards(); });
    }
  }

  /* ---------- Accordion (FAQ buttons; <details> needs no script) ---------- */
  $$('.accordion-trigger').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var expanded = btn.getAttribute('aria-expanded') === 'true';
      var panel = btn.nextElementSibling;
      btn.setAttribute('aria-expanded', expanded ? 'false' : 'true');
      if (panel) panel.hidden = expanded;
    });
  });

  /* ---------- Start ---------- */
  measureRoutes(doc);
  updateHeader();
  updateProgress(true);
  onMQ(reduceMQ, function (e) { reduce = e.matches; progressEls.forEach(function (el) { el._cur = -1; }); updateProgress(true); });
  win.Coroute = { count: function (el, to) { el.setAttribute('data-count', String(to)); }, refresh: function () { measureRoutes(doc); updateProgress(true); } };
  win.__corouteReady = true;
})();
