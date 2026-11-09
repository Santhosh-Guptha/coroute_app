/* 3.55 /get?coupon=CODE (marketing studio QR / {link}, docs/features_355/marketing_studio.md).
 * Shows "Code CODE will be applied in the app" and hands the code to the app:
 *   - Google Play (when the site has PLAY_STORE_URL): the install link carries &referrer=coupon%3DCODE
 *     (Play Install Referrer, read once by the app on first launch);
 *   - already installed (Android): "Open in the app" opens coroute://get?coupon=CODE;
 *   - anything else: "Copy code" to paste on the plan screen.
 * The code is checked against A-Z 0-9 - _ (at most 24) and only ever written with textContent. */
(function () {
  'use strict';
  var chip = document.getElementById('code-chip');
  if (!chip) return;
  var raw = '';
  try { raw = new URLSearchParams(window.location.search).get('coupon') || ''; } catch (e) { return; }
  var code = raw.trim().toUpperCase();
  if (!/^[A-Z0-9_-]{1,24}$/.test(code)) return;

  // Play Store link with the code as Install Referrer (https only).
  var storeLink = '';
  var play = document.getElementById('play-store');
  var playUrl = play ? play.getAttribute('data-href') : '';
  if (playUrl) {
    try {
      var u = new URL(playUrl);
      if (u.protocol === 'https:') {
        u.searchParams.set('referrer', 'coupon=' + code);
        storeLink = u.toString();
      }
    } catch (e) { storeLink = ''; }
  }
  if (storeLink) {
    var downloads = document.querySelectorAll('a[href="/download"]');
    for (var i = 0; i < downloads.length; i++) downloads[i].setAttribute('href', storeLink);
  }

  var text = document.createElement('p');
  text.className = 'code-chip__text';
  var strong = document.createElement('strong');
  strong.className = 'code-chip__code';
  strong.textContent = code;
  text.appendChild(document.createTextNode('Code '));
  text.appendChild(strong);
  text.appendChild(document.createTextNode(' will be applied in the app'));
  chip.appendChild(text);

  var actions = document.createElement('div');
  actions.className = 'code-chip__actions';

  // Already installed: open the app with the code (Android). Not installed: the store / download.
  if (/Android/i.test(navigator.userAgent || '')) {
    var fallback = storeLink || (window.location.origin + '/download');
    var open = document.createElement('a');
    open.className = 'btn btn--secondary btn--sm';
    open.id = 'code-open';
    open.setAttribute('href', 'intent://get?coupon=' + encodeURIComponent(code) +
      '#Intent;scheme=coroute;package=space.devmonks.coroute_app;S.browser_fallback_url=' +
      encodeURIComponent(fallback) + ';end');
    open.textContent = 'Open in the app';
    actions.appendChild(open);
  }

  var copy = document.createElement('button');
  copy.type = 'button';
  copy.className = 'btn btn--secondary btn--sm';
  copy.id = 'code-copy';
  copy.textContent = 'Copy code';
  copy.addEventListener('click', function () {
    var done = function () { copy.textContent = 'Copied'; };
    var manual = function () {
      try {
        var t = document.createElement('textarea');
        t.value = code;
        t.setAttribute('readonly', '');
        t.style.position = 'fixed';
        t.style.opacity = '0';
        document.body.appendChild(t);
        t.select();
        if (document.execCommand('copy')) done();
        document.body.removeChild(t);
      } catch (e) { /* the code stays visible to type */ }
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(code).then(done, manual);
    else manual();
  });
  actions.appendChild(copy);
  chip.appendChild(actions);
  chip.hidden = false;
})();
