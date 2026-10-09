/* Coroute legal pages: section navigation open on desktop / collapsible on mobile, current section, back to top.
   Everything works without this file: the navigation is a plain <details open> list of anchor links. */
(function () {
  'use strict';
  var toc = document.querySelector('[data-legal-toc]');
  var links = toc ? Array.prototype.slice.call(toc.querySelectorAll('a[href^="#"]')) : [];
  var wide = window.matchMedia('(min-width: 1024px)');

  // Desktop: always open (the summary is just a label). Mobile: closed until tapped.
  function syncOpen() { if (toc) toc.open = wide.matches; }
  syncOpen();
  if (wide.addEventListener) wide.addEventListener('change', syncOpen); else if (wide.addListener) wide.addListener(syncOpen);
  if (toc) {
    toc.querySelector('summary').addEventListener('click', function (e) { if (wide.matches) e.preventDefault(); });
    // On mobile, close the list after choosing a section so the text is in view.
    links.forEach(function (a) { a.addEventListener('click', function () { if (!wide.matches) toc.open = false; }); });
  }

  // Current section: the last section whose top has passed a line just under the header.
  var sections = links.map(function (a) { return document.getElementById(a.getAttribute('href').slice(1)); });
  var float = document.querySelector('[data-legal-totop]');
  var ticking = false;
  function update() {
    ticking = false;
    var line = 140, current = -1;
    for (var i = 0; i < sections.length; i++) {
      if (sections[i] && sections[i].getBoundingClientRect().top - line <= 0) current = i;
    }
    // At the very bottom the last short sections cannot reach the line: mark the last one.
    if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4 && sections.length) current = sections.length - 1;
    links.forEach(function (a, i) {
      var on = i === current;
      a.classList.toggle('is-current', on);
      if (on) a.setAttribute('aria-current', 'true'); else a.removeAttribute('aria-current');
    });
    if (float) float.classList.toggle('is-visible', window.scrollY > 900);
  }
  function schedule() { if (!ticking) { ticking = true; window.requestAnimationFrame(update); } }
  window.addEventListener('scroll', schedule, { passive: true });
  window.addEventListener('resize', schedule, { passive: true });
  update();
})();
