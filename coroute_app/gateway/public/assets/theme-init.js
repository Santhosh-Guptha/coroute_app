/* 3.56 shop pages (strict CSP, no inline script): the saved theme before the first paint. Same as the
   inline line in the other pages: data-theme from localStorage 'coroute_theme' ('light' | 'dark'). */
(function (d) { d.classList.add('js'); try { var t = localStorage.getItem('coroute_theme'); if (t === 'dark' || t === 'light') d.setAttribute('data-theme', t); } catch (e) {} })(document.documentElement);
