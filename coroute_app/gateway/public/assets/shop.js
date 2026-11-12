/* 3.56 rider shop helpers (signin, plans, account, receipt). docs/features_355/web_payments.md
 * 3.57 sessions (docs/features_355/sessions_and_security.md):
 * - The short access token (15 min) lives in sessionStorage only, is sent as a Bearer header and never put in a URL
 *   or localStorage. The refresh token is an httpOnly __Host- cookie this script can never read; it is used only by
 *   POST /api/auth/refresh and /api/auth/logout, with the X-CoRoute-CSRF header.
 * - A 401 TOKEN_EXPIRED is refreshed once (one refresh at a time for the whole page), then the call is repeated
 *   once. A refused refresh goes to /signin with "You were signed out". No loops.
 * - 60 minutes without activity signs out (server and this tab; the activity time is kept per tab in sessionStorage);
 *   signing out in one tab tells the others (BroadcastChannel; nothing in localStorage);
 *   the Back button never shows a private page again (pageshow re-check, no-store pages).
 * - Everything from the server is written with textContent (el()); no HTML strings anywhere.
 * - Prices are never computed here: the server's quote is shown as it comes. */
(function () {
  'use strict';
  try { document.documentElement.style.visibility = ''; } catch (e) { /* ignore */ }
  var KEY = 'coroute_session';
  var ACTIVE = 'cr.web.lastActive';
  var OUT = 'cr.web.signedOut';
  var IDLE_MS = 60 * 60 * 1000;
  var store = null;
  try { store = window.sessionStorage; store.getItem(KEY); } catch (e) { store = null; }
  // Other tabs of this site hear about a sign-out at once (no storage shared for it; nothing persists).
  var channel = null;
  try { channel = typeof window.BroadcastChannel === 'function' ? new window.BroadcastChannel('coroute-session') : null; } catch (e) { channel = null; }
  // QA only: a shorter idle time for this tab (never longer than the real one).
  try { var q = Number(store && store.getItem('cr.idleMs')); if (q > 0 && q < IDLE_MS) IDLE_MS = q; } catch (e) { /* default */ }

  function token() { try { return store ? store.getItem(KEY) || '' : ''; } catch (e) { return ''; } }
  function setToken(t) {
    try { if (store && typeof t === 'string' && /^[A-Za-z0-9._-]{20,4096}$/.test(t)) store.setItem(KEY, t); } catch (e) { /* private mode */ }
  }
  function dropToken() { try { if (store) store.removeItem(KEY); } catch (e) { /* ignore */ } }

  var CSRF = { 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1' };
  var refreshing = null;
  /** One refresh at a time: resolves true with a new access token in sessionStorage, else false. */
  function refresh() {
    if (refreshing) return refreshing;
    refreshing = fetch('/api/auth/refresh', {
      method: 'POST', credentials: 'same-origin', cache: 'no-store',
      headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1' },
      body: JSON.stringify({ client: 'web' })
    }).then(function (r) {
      if (r.status === 204) return false; // no session cookie: nothing to refresh
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (r.ok && j.token) { setToken(j.token); return true; }
        if (r.status === 401 || r.status === 403) dropToken();
        return false;
      });
    }).catch(function () { return false; }).then(function (ok) { refreshing = null; return ok; });
    return refreshing;
  }

  /** The session ended on the server: this tab forgets it and goes to sign in, coming back to this page. */
  function expired(reason) {
    dropToken();
    var here = window.location.pathname + window.location.search;
    window.location.replace('/signin?expired=' + (reason === 'idle' ? 'idle' : '1') + '&next=' + encodeURIComponent(safeNext(here)));
  }

  /** fetch JSON from the API: { ok, status, json }. Never throws. A 401 refreshes once, then signs out. */
  function api(method, path, body, opts) {
    opts = opts || {};
    function send() {
      var headers = { Accept: 'application/json', 'X-CoRoute-Client': 'web' };
      var t = token();
      if (t && opts.auth !== false) headers.Authorization = 'Bearer ' + t;
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      return fetch('/api' + path, {
        method: method, headers: headers, credentials: 'same-origin', cache: 'no-store', referrerPolicy: 'no-referrer',
        body: body === undefined ? undefined : JSON.stringify(body)
      }).then(function (r) {
        // Sliding session of older long tokens: the server hands a fresh token.
        var fresh = r.headers.get('X-CoRoute-Token');
        if (fresh) setToken(fresh);
        return r.json().catch(function () { return {}; }).then(function (j) { return { ok: r.ok, status: r.status, json: j || {}, hadToken: !!t }; });
      });
    }
    return send().then(function (res) {
      if (res.status !== 401 || opts.auth === false || !res.hadToken) return res;
      // Only the gateway's session codes end the session here (a wrong password in a form never does).
      if (res.json.code !== 'TOKEN_EXPIRED') {
        if (res.json.code && res.json.code !== 'SESSION_INVALID') return res;
        dropToken(); if (!opts.noRedirect) expired(); return res;
      }
      return refresh().then(function (ok) {
        if (!ok) { if (!opts.noRedirect) expired(); return res; }
        return send().then(function (again) {
          if (again.status === 401 && !opts.noRedirect) expired();
          return again;
        });
      });
    }).catch(function () {
      return { ok: false, status: 0, json: { error: 'Could not reach CoRoute. Check your connection and try again.' } };
    });
  }

  /** Signs out on the server (this session, or every session with all=true), then leaves for `to` (default /). */
  function signOut(opts) {
    opts = opts || {};
    var t = token();
    var headers = { Accept: 'application/json', 'Content-Type': 'application/json', 'X-CoRoute-Client': 'web', 'X-CoRoute-CSRF': '1' };
    if (t) headers.Authorization = 'Bearer ' + t;
    var done = function () {
      dropToken();
      try { if (store) store.removeItem(ACTIVE); if (channel) channel.postMessage({ type: OUT, at: Date.now() }); } catch (e) { /* ignore */ }
      if (opts.stay) return;
      window.location.replace(opts.to || '/');
    };
    return fetch(opts.all ? '/api/auth/logout-all' : '/api/auth/logout', {
      method: 'POST', credentials: 'same-origin', cache: 'no-store', headers: headers, body: JSON.stringify({ client: 'web' }), keepalive: true
    }).then(done, done);
  }

  // ---- idle sign-out (60 minutes), shared by every tab of this site ----
  var lastTouch = 0;
  function touch() {
    var n = Date.now();
    if (n - lastTouch < 5000) return;
    lastTouch = n;
    try { if (store) store.setItem(ACTIVE, String(n)); if (channel) channel.postMessage({ type: 'cr.web.active', at: n }); } catch (e) { /* ignore */ }
  }
  function idleCheck() {
    if (!token()) return;
    var last = 0;
    try { last = Number(store && store.getItem(ACTIVE)) || 0; } catch (e) { last = 0; }
    if (!last) { touch(); return; }
    if (Date.now() - last > IDLE_MS) signOut({ to: '/signin?expired=idle' });
  }
  ['pointerdown', 'keydown', 'wheel', 'touchstart', 'scroll'].forEach(function (ev) { document.addEventListener(ev, touch, { passive: true, capture: true }); });
  if (typeof setInterval === 'function') setInterval(idleCheck, IDLE_MS < 120000 ? 1000 : 30000);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) idleCheck(); });

  // Signed out in another tab: this one follows at once (the server already ended the shared session).
  if (channel) channel.onmessage = function (e) {
    if (!e || !e.data) return;
    // Activity in another tab keeps this one (and the shared session) signed in.
    if (e.data.type === 'cr.web.active') { try { if (store && Number(e.data.at) > 0) store.setItem(ACTIVE, String(Number(e.data.at))); } catch (x) { /* ignore */ } return; }
    if (e.data.type !== OUT) return;
    dropToken();
    if (isPrivatePage()) window.location.replace('/');
  };
  /** Pages that show account data (they load it only through the API, and are never cached). */
  function isPrivatePage() {
    return /^\/(account|receipt|trip\/|operators\/apply)/.test(window.location.pathname) || !!document.querySelector('[data-private]');
  }
  // Back / forward cache: a private page restored from memory is checked again before anything shows.
  if (window.addEventListener) window.addEventListener('pageshow', function (e) {
    if (!e.persisted || !isPrivatePage()) return;
    if (!token()) { document.documentElement.style.visibility = 'hidden'; window.location.replace('/signin?expired=1'); return; }
    window.location.reload();
  });

  /** <tag class="cls">text</tag>, text set with textContent. */
  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }
  function icon(id, cls) {
    var ns = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('class', 'icon' + (cls ? ' ' + cls : ''));
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    var use = document.createElementNS(ns, 'use');
    use.setAttribute('href', (document.documentElement.getAttribute('data-icons') || '/assets/icons.svg') + '#' + id);
    svg.appendChild(use);
    return svg;
  }
  function clear(n) { while (n && n.firstChild) n.removeChild(n.firstChild); return n; }
  function $(id) { return document.getElementById(id); }

  /** "₹49", "₹1,299", "−₹31" for a negative line. */
  function inr(v) {
    var n = Number(v) || 0;
    var s = '₹' + Math.abs(n).toLocaleString('en-IN', { maximumFractionDigits: 2 });
    return n < 0 ? '−' + s : s;
  }
  /** "19 Nov 2026" (India time). */
  function date(ms) {
    var n = Number(ms);
    if (!n) return '';
    try { return new Date(n).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }); } catch (e) { return new Date(n).toDateString(); }
  }
  function dateTime(ms) {
    var n = Number(ms);
    if (!n) return '';
    try { return new Date(n).toLocaleString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit', timeZone: 'Asia/Kolkata' }); } catch (e) { return new Date(n).toString(); }
  }

  /** A coupon code from a link: A-Z 0-9 - _, at most 24 (uppercased), else ''. */
  function cleanCode(raw) {
    var s = String(raw == null ? '' : raw).trim().toUpperCase();
    return /^[A-Z0-9_-]{1,24}$/.test(s) ? s : '';
  }
  /** A plan id from a link (letters, digits, _), else ''. */
  function cleanPlan(raw) {
    var s = String(raw == null ? '' : raw).trim();
    return /^[a-z][a-z0-9_]{1,30}$/.test(s) ? s : '';
  }
  /** Where to go after signing in: only these pages of this site, with a clean query. */
  function safeNext(raw) {
    var s = String(raw || '');
    // 3.56 operator console pages: /operators/apply, /clubs, /rides/<slug> (src/operator_routes.js).
    // 3.57 /trip/<tripId>: the ride summary e-mail's "View trip report" link.
    var m = /^\/(plans|account|receipt|operators\/apply|clubs|rides\/[a-z0-9-]{3,70}|trip\/[A-Za-z0-9_.:-]{3,120})(?:\?([A-Za-z0-9_=&%.-]{0,200}))?$/.exec(s);
    return m ? s : '/account';
  }
  function query(name) {
    try { return new URLSearchParams(window.location.search).get(name) || ''; } catch (e) { return ''; }
  }
  /** "Small Group (2-6)" reads "Small Group". */
  function planName(p) { return String((p && (p.name || p.categoryName || p.id)) || 'Plan').replace(/\s*\([^)]*\)\s*$/, '').trim() || 'Plan'; }

  /** Sends the visitor to sign in, coming back to `next` afterwards. */
  function toSignIn(next) {
    window.location.assign('/signin?next=' + encodeURIComponent(safeNext(next)));
  }

  window.CoShop = {
    token: token, setToken: setToken, signOut: signOut, refresh: refresh, api: api, el: el, icon: icon, clear: clear, $: $,
    inr: inr, date: date, dateTime: dateTime, cleanCode: cleanCode, cleanPlan: cleanPlan, safeNext: safeNext,
    query: query, planName: planName, toSignIn: toSignIn, csrfHeaders: CSRF
  };

  // Sign-out buttons on any shop page: the server session ends, then the home page (Back cannot return).
  // data-signout="all": every device.
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('[data-signout]') : null;
    if (!b) return;
    e.preventDefault();
    b.disabled = true;
    signOut({ all: b.getAttribute('data-signout') === 'all' });
  });
})();
