/* 3.56 "Latest from CoRoute": the marketing board (src/board.js, GET /api/public/board).
 * Fills every [data-board] element:
 *   data-board-limit="3"     how many posts (home page: 3; /updates: all, up to 50)
 *   data-board-filter        show the kind filter (All, Updates, Offers, Safety tips, Events)
 *   data-board-hide-empty    keep the whole section hidden while there is nothing to show
 * Everything from the server is written with textContent / attributes checked against strict patterns:
 * links only to pages of this site, images only from /api/public/board/images/, codes A-Z 0-9 - _.
 * Website only: the board is never sent to the app. */
(function () {
  'use strict';
  var roots = document.querySelectorAll('[data-board]');
  if (!roots.length || !window.fetch) return;

  var KINDS = { update: 'Update', offer: 'Offer', safety_tip: 'Safety tip', event: 'Event' };
  var FILTERS = [['', 'All'], ['update', 'Updates'], ['offer', 'Offers'], ['safety_tip', 'Safety tips'], ['event', 'Events']];
  var ICONS = { update: 'i-message', offer: 'i-free', safety_tip: 'i-shield', event: 'i-flag' };
  var LINK = /^\/(?!\/)(?!api(?:\/|$))(?!admin(?:\/|$))[A-Za-z0-9\-._~/]*(?:\?[A-Za-z0-9\-._~=&%]*)?(?:#[A-Za-z0-9\-_]*)?$/;
  var IMG = /^\/api\/public\/board\/images\/rp_[a-f0-9]{24}$/;
  var CODE = /^[A-Z0-9_-]{3,32}$/;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = String(text);
    return e;
  }
  function icon(id) {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'icon');
    svg.setAttribute('aria-hidden', 'true');
    svg.setAttribute('focusable', 'false');
    var use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '/assets/icons.svg#' + id);
    svg.appendChild(use);
    return svg;
  }
  function date(ms) {
    var n = Number(ms);
    if (!n) return '';
    try { return new Date(n).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'Asia/Kolkata' }); } catch (e) { return ''; }
  }
  /** Plain text with its line breaks: one <p> per paragraph, <br> inside. */
  function bodyOf(text) {
    var box = el('div', 'bd-card__body');
    String(text || '').split(/\n{2,}/).forEach(function (para) {
      var p = el('p');
      para.split('\n').forEach(function (line, i) {
        if (i) p.appendChild(document.createElement('br'));
        p.appendChild(document.createTextNode(line));
      });
      box.appendChild(p);
    });
    return box;
  }
  function copy(text, btn, live) {
    var ok = function () {
      btn.classList.add('is-done');
      btn.lastChild.textContent = 'Copied';
      if (live) live.textContent = 'Code ' + text + ' copied.';
      setTimeout(function () { btn.classList.remove('is-done'); btn.lastChild.textContent = 'Copy code'; }, 2000);
    };
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) { navigator.clipboard.writeText(text).then(ok, function () { if (live) live.textContent = 'Code: ' + text; }); return; }
    } catch (e) { /* fall through */ }
    if (live) live.textContent = 'Code: ' + text;
  }

  function couponChip(c, live) {
    if (!c || typeof c.code !== 'string' || !CODE.test(c.code)) return null;
    var box = el('div', 'bd-coupon');
    var code = el('div', 'bd-coupon__code');
    code.appendChild(el('span', 'bd-coupon__label', typeof c.text === 'string' ? c.text.slice(0, 40) : 'Code'));
    code.appendChild(el('b', null, c.code));
    box.appendChild(code);
    var actions = el('div', 'bd-coupon__actions');
    var b = el('button', 'btn btn--secondary btn--sm bd-coupon__copy');
    b.type = 'button';
    b.appendChild(el('span', null, 'Copy code'));
    b.setAttribute('aria-label', 'Copy code ' + c.code);
    b.addEventListener('click', function () { copy(c.code, b, live); });
    actions.appendChild(b);
    var a = el('a', 'btn btn--primary btn--sm', 'Use on plans');
    a.setAttribute('href', '/plans?coupon=' + encodeURIComponent(c.code));
    actions.appendChild(a);
    box.appendChild(actions);
    if (c.validUntil) box.appendChild(el('p', 'bd-coupon__until', 'Valid until ' + date(Number(c.validUntil) - 1)));
    return box;
  }

  function card(p, live) {
    var kind = KINDS[p.kind] ? p.kind : 'update';
    var art = el('article', 'bd-card bd-card--' + kind.replace('_', '-') + (p.pinned ? ' is-pinned' : ''));
    art.setAttribute('data-kind', kind);
    if (typeof p.image === 'object' && p.image && typeof p.image.url === 'string' && IMG.test(p.image.url)) {
      var fig = el('div', 'bd-card__media');
      var img = el('img');
      img.setAttribute('src', p.image.url);
      img.setAttribute('alt', '');
      img.setAttribute('loading', 'lazy');
      img.setAttribute('decoding', 'async');
      if (p.image.width && p.image.height) { img.setAttribute('width', String(Math.round(p.image.width))); img.setAttribute('height', String(Math.round(p.image.height))); }
      img.addEventListener('error', function () { fig.remove(); });
      fig.appendChild(img);
      art.appendChild(fig);
    }
    var inner = el('div', 'bd-card__inner');
    var meta = el('p', 'bd-card__meta');
    var chip = el('span', 'bd-kind bd-kind--' + kind.replace('_', '-'));
    chip.appendChild(icon(ICONS[kind]));
    chip.appendChild(el('span', null, KINDS[kind]));
    meta.appendChild(chip);
    if (p.pinned) meta.appendChild(el('span', 'bd-card__pin', 'Pinned'));
    if (p.date) {
      var t = el('time', 'bd-card__date', date(p.date));
      try { t.setAttribute('datetime', new Date(Number(p.date)).toISOString().slice(0, 10)); } catch (e) { /* bad date */ }
      meta.appendChild(t);
    }
    inner.appendChild(meta);
    inner.appendChild(el('h3', 'bd-card__title', typeof p.title === 'string' ? p.title.slice(0, 80) : ''));
    inner.appendChild(bodyOf(typeof p.body === 'string' ? p.body.slice(0, 600) : ''));
    var chipBox = couponChip(p.coupon, live);
    if (chipBox) inner.appendChild(chipBox);
    if (typeof p.link === 'string' && LINK.test(p.link) && p.link.indexOf('..') < 0) {
      var a = el('a', 'link-arrow bd-card__link');
      a.setAttribute('href', p.link);
      a.appendChild(el('span', null, typeof p.linkLabel === 'string' && p.linkLabel ? p.linkLabel.slice(0, 40) : 'Read more'));
      a.appendChild(icon('i-arrow-right'));
      inner.appendChild(a);
    }
    if (p.endsAt && kind !== 'safety_tip') inner.appendChild(el('p', 'bd-card__ends', 'Until ' + date(Number(p.endsAt) - 1)));
    art.appendChild(inner);
    return art;
  }

  function setup(root) {
    var list = root.querySelector('[data-board-list]') || root;
    var empty = root.querySelector('[data-board-empty]');
    var live = root.querySelector('[data-board-live]');
    var limit = Math.max(1, Math.min(50, parseInt(root.getAttribute('data-board-limit'), 10) || 3));
    var hideEmpty = root.hasAttribute('data-board-hide-empty');
    var filterBox = root.querySelector('[data-board-filters]');
    var kind = '';

    function load() {
      list.setAttribute('aria-busy', 'true');
      fetch('/api/public/board?limit=' + limit + (kind ? '&kind=' + encodeURIComponent(kind) : ''), { headers: { Accept: 'application/json' }, credentials: 'omit' })
        .then(function (r) { if (!r.ok) throw new Error('http'); return r.json(); })
        .then(function (j) {
          var posts = j && Array.isArray(j.posts) ? j.posts.slice(0, limit) : [];
          while (list.firstChild) list.removeChild(list.firstChild);
          list.removeAttribute('aria-busy');
          posts.forEach(function (p) { if (p && typeof p === 'object') list.appendChild(card(p, live)); });
          list.setAttribute('data-state', posts.length ? 'loaded' : 'empty');
          if (empty) empty.hidden = posts.length > 0;
          if (hideEmpty) root.hidden = posts.length === 0 && !kind;
        })
        .catch(function () {
          list.removeAttribute('aria-busy');
          list.setAttribute('data-state', 'error');
          if (hideEmpty) root.hidden = true;
          else if (empty) { empty.hidden = false; }
        });
    }

    if (filterBox) {
      FILTERS.forEach(function (f) {
        var b = el('button', 'bd-filter', f[1]);
        b.type = 'button';
        b.setAttribute('aria-pressed', f[0] === kind ? 'true' : 'false');
        b.setAttribute('data-kind', f[0]);
        b.addEventListener('click', function () {
          kind = f[0];
          var all = filterBox.querySelectorAll('.bd-filter');
          for (var i = 0; i < all.length; i++) all[i].setAttribute('aria-pressed', all[i] === b ? 'true' : 'false');
          load();
        });
        filterBox.appendChild(b);
      });
      var want = (function () { try { return new URLSearchParams(window.location.search).get('kind') || ''; } catch (e) { return ''; } })();
      if (KINDS[want]) {
        kind = want;
        var bs = filterBox.querySelectorAll('.bd-filter');
        for (var i = 0; i < bs.length; i++) bs[i].setAttribute('aria-pressed', bs[i].getAttribute('data-kind') === want ? 'true' : 'false');
      }
    }
    load();
  }

  for (var i = 0; i < roots.length; i++) setup(roots[i]);
})();
