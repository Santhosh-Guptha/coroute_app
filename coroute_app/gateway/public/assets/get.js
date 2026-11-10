/* /get: download links only (3.56). Coupon links moved to the plans page: the server answers
 * /get?coupon=CODE with a redirect to /plans?coupon=CODE (src/web_shop.js). This is the fallback for a
 * page served without that redirect (an old cached copy): the same move in the browser, with the code
 * checked against A-Z 0-9 - _ (at most 24). Nothing from the query is ever written into the page. */
(function () {
  'use strict';
  var raw = null;
  try { raw = new URLSearchParams(window.location.search).get('coupon'); } catch (e) { return; }
  if (raw === null) return;
  var code = String(raw).trim().toUpperCase();
  var target = /^[A-Z0-9_-]{1,24}$/.test(code) ? '/plans?coupon=' + encodeURIComponent(code) : '/plans';
  window.location.replace(target);
})();
