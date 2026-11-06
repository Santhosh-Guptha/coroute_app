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

  /* ---------- CoRoute in numbers: real usage counts only ----------
     Source: GET /api/public/usage-stats -> { ok, stats: { riders, ridesCompleted, kmRidden, groupsRidden, sosResolved,
     avgRating (or null), updatedAt } }. Fallback when that is missing (404 on older servers): GET /api/public/community-stats
     -> { enabled, totalRiders, totalKilometers }. The section stays hidden unless the numbers are real and large enough
     to mean something (at least 10 completed rides); a small or missing number is left out, never shown as a boast.
     Privacy: the server already rounds (src/public_privacy.js); the same rules are applied here too, so an older
     server's exact totals are never shown: counts rounded down to tens (hundreds from 1,000), nothing below 10,
     distance rounded down to 100 km (1,000 km from 10,000 km), shown with "+" because the real total is higher. */
  var usageBox = doc.querySelector('[data-usage-stats]');
  var usageList = doc.getElementById('usage-stats-list');
  if (usageBox && usageList && 'fetch' in win) {
    var uNum = function (v) { var n = typeof v === 'string' ? parseFloat(v) : v; return typeof n === 'number' && isFinite(n) && n >= 0 ? n : null; };
    var uFmt = function (n) { return Math.round(n).toLocaleString('en-IN') + '+'; };
    var uCount = function (n) {
      if (n === null || n < 10) return null;
      var step = n < 1000 ? 10 : n < 100000 ? 100 : 1000;
      return Math.floor(n / step) * step;
    };
    var uKm = function (n) {
      if (n === null) return null;
      var r = Math.floor(n / (n < 10000 ? 100 : 1000)) * (n < 10000 ? 100 : 1000);
      return r >= 100 ? r : null;
    };
    var uGet = function (url) {
      return fetch(url, { headers: { Accept: 'application/json' }, credentials: 'omit' }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      });
    };
    var fromUsage = function (j) {
      var st = j && j.stats;
      if (!st || typeof st !== 'object') throw new Error('unexpected shape');
      return {
        riders: uCount(uNum(st.riders)), rides: uCount(uNum(st.ridesCompleted)), km: uKm(uNum(st.kmRidden)), groups: uCount(uNum(st.groupsRidden)),
        sos: uCount(uNum(st.sosResolved)), rating: uNum(st.avgRating), updatedAt: st.updatedAt, gate: uCount(uNum(st.ridesCompleted)) !== null,
      };
    };
    var fromCommunity = function (j) {
      if (!j || j.enabled === false) throw new Error('private');
      var riders = uCount(uNum(j.totalRiders)), km = uKm(uNum(j.totalKilometers));
      // No completed-ride count here, so ask more of the numbers that are present.
      return { riders: riders, rides: null, km: km, groups: null, sos: null, rating: null, updatedAt: j.lastUpdated, gate: riders !== null && km !== null && km >= 1000 };
    };
    // Counters roll up to the real value (from the last shown value on a refresh). Without animation support,
    // or with reduced motion, the final number is written at once.
    var uShown = {};
    var uReduce = win.matchMedia ? win.matchMedia('(prefers-reduced-motion: reduce)').matches : true;
    var uAnimate = function (dd, key, to, fmt) {
      var from = key in uShown ? uShown[key] : 0;
      uShown[key] = to;
      dd.setAttribute('aria-label', fmt(to));
      if (uReduce || !win.requestAnimationFrame || from === to) { dd.textContent = fmt(to); return; }
      var t0 = null, dur = from ? 900 : 1400;
      dd.textContent = fmt(from);
      var step = function (now) {
        if (t0 === null) t0 = now;
        var k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3);
        dd.textContent = fmt(from + (to - from) * e);
        if (k < 1) win.requestAnimationFrame(step);
      };
      win.requestAnimationFrame(step);
    };
    var uRating = function (n) { return n.toFixed(1) + ' / 5'; };
    var renderUsage = function (u) {
      if (!u.gate) return;
      var tiles = [];
      if (u.rides !== null && u.rides >= 10) tiles.push(['Rides completed', u.rides, uFmt]);
      if (u.km !== null && u.km >= 100) tiles.push(['Kilometres ridden', u.km, uFmt]);
      if (u.riders !== null && u.riders >= 10) tiles.push(['Riders', u.riders, uFmt]);
      if (u.groups !== null && u.groups >= 10) tiles.push(['Group rides', u.groups, uFmt]);
      if (u.sos !== null && u.sos >= 10) tiles.push(['SOS alerts resolved', u.sos, uFmt]);
      if (u.rating !== null && u.rating >= 1 && u.rating <= 5) tiles.push(['Average rider rating', u.rating, uRating]);
      if (tiles.length < 2) return;
      usageList.textContent = '';
      tiles.forEach(function (t) {
        var d = doc.createElement('div');
        var dt = doc.createElement('dt'); dt.textContent = t[0];
        var dd = doc.createElement('dd');
        d.appendChild(dt); d.appendChild(dd);
        usageList.appendChild(d);
        uAnimate(dd, t[0], t[2] === uRating ? Math.round(t[1] * 10) / 10 : Math.round(t[1]), t[2]);
      });
      var note = doc.getElementById('usage-stats-note');
      var at = u.updatedAt ? new Date(typeof u.updatedAt === 'string' && /^\d+$/.test(u.updatedAt) ? +u.updatedAt : u.updatedAt) : null;
      if (note) note.textContent = at && !isNaN(at.getTime()) ? 'Updated ' + at.toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) + '.' : '';
      usageBox.hidden = false;
    };
    var loadUsage = function () {
      if (doc.hidden) return;
      uGet('/api/public/usage-stats').then(fromUsage)
        .catch(function () { return uGet('/api/public/community-stats').then(fromCommunity); })
        .then(renderUsage)
        .catch(function () { /* stays as it was: no numbers are better than wrong ones */ });
    };
    loadUsage();
    // Live: check again every minute while the page is open (the server caches, so this is cheap).
    if (win.setInterval) win.setInterval(loadUsage, 60000);
  }

  /* ---------- Theme toggle (light / dark), remembered in this browser only ---------- */
  var themeBtn = doc.getElementById('theme-toggle');
  var savedTheme = null;
  try { savedTheme = win.localStorage.getItem('coroute_theme'); } catch (e) { /* storage blocked */ }
  if (savedTheme !== 'dark' && savedTheme !== 'light') savedTheme = mq('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  root.setAttribute('data-theme', savedTheme);
  if (themeBtn) {
    var syncThemeBtn = function () { themeBtn.setAttribute('aria-pressed', root.getAttribute('data-theme') === 'dark' ? 'true' : 'false'); };
    syncThemeBtn();
    themeBtn.addEventListener('click', function () {
      var next = root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      syncThemeBtn();
      try { win.localStorage.setItem('coroute_theme', next); } catch (e) { /* storage blocked */ }
    });
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
  reduceMQ.addEventListener && reduceMQ.addEventListener('change', function (e) { reduce = e.matches; progressEls.forEach(function (el) { el._cur = -1; }); updateProgress(true); });
  win.Coroute = { count: function (el, to) { el.setAttribute('data-count', String(to)); }, refresh: function () { measureRoutes(doc); updateProgress(true); } };
  win.__corouteReady = true;
})();
