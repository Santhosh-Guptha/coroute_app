/* 3.56 rider shop helpers (signin, plans, account, receipt). docs/features_355/web_payments.md
 * - The session token lives in sessionStorage only (gone when the tab closes), is sent as a Bearer header
 *   and never put in a URL, a cookie or localStorage. Signing out removes it.
 * - Everything from the server is written with textContent (el()); no HTML strings anywhere.
 * - Prices are never computed here: the server's quote is shown as it comes. */
(function () {
  'use strict';
  var KEY = 'coroute_session';
  var store = null;
  try { store = window.sessionStorage; store.getItem(KEY); } catch (e) { store = null; }

  function token() { try { return store ? store.getItem(KEY) || '' : ''; } catch (e) { return ''; } }
  function setToken(t) {
    try { if (store && typeof t === 'string' && /^[A-Za-z0-9._-]{20,4096}$/.test(t)) store.setItem(KEY, t); } catch (e) { /* private mode */ }
  }
  function signOut() {
    try { if (store) store.removeItem(KEY); } catch (e) { /* ignore */ }
  }

  /** fetch JSON from the API: { ok, status, json }. Never throws. A 401 ends the web session. */
  function api(method, path, body, opts) {
    opts = opts || {};
    var headers = { Accept: 'application/json', 'X-CoRoute-Client': 'web' };
    var t = token();
    if (t && opts.auth !== false) headers.Authorization = 'Bearer ' + t;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    return fetch('/api' + path, {
      method: method, headers: headers, credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer',
      body: body === undefined ? undefined : JSON.stringify(body)
    }).then(function (r) {
      // Sliding session: the server hands a fresh token on long-lived sessions.
      var fresh = r.headers.get('X-CoRoute-Token');
      if (fresh) setToken(fresh);
      if (r.status === 401 && t && opts.auth !== false) signOut();
      return r.json().catch(function () { return {}; }).then(function (j) { return { ok: r.ok, status: r.status, json: j || {} }; });
    }).catch(function () {
      return { ok: false, status: 0, json: { error: 'Could not reach CoRoute. Check your connection and try again.' } };
    });
  }

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
    token: token, setToken: setToken, signOut: signOut, api: api, el: el, icon: icon, clear: clear, $: $,
    inr: inr, date: date, dateTime: dateTime, cleanCode: cleanCode, cleanPlan: cleanPlan, safeNext: safeNext,
    query: query, planName: planName, toSignIn: toSignIn
  };

  // Sign-out buttons on any shop page.
  document.addEventListener('click', function (e) {
    var b = e.target && e.target.closest ? e.target.closest('[data-signout]') : null;
    if (!b) return;
    e.preventDefault();
    signOut();
    window.location.assign('/signin?out=1');
  });
})();
