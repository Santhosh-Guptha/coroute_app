/* 3.56 shop pages (strict CSP, no inline script): the saved theme before the first paint. Same as the
   inline line in the other pages: data-theme from localStorage 'coroute_theme' ('light' | 'dark'). */
(function (d) { d.classList.add('js'); try { var t = localStorage.getItem('coroute_theme'); if (t === 'dark' || t === 'light') d.setAttribute('data-theme', t); } catch (e) {} })(document.documentElement);
/* v3.58 device compatibility: browsers without flexbox gap (Safari < 14.1, Chrome < 84) get .no-flexgap, which turns on
   the margin fallbacks that tool/web_compat/css_compat.js writes next to every flex `gap`. */
(function (d) {
  try {
    var f = document.createElement('div'); f.style.cssText = 'display:flex;flex-direction:column;row-gap:1px;position:absolute;visibility:hidden';
    f.appendChild(document.createElement('div')); f.appendChild(document.createElement('div'));
    (document.body || d).appendChild(f);
    var ok = f.scrollHeight === 1; f.parentNode.removeChild(f);
    if (!ok) d.classList.add('no-flexgap');
  } catch (e) { /* keep the modern layout */ }
})(document.documentElement);
