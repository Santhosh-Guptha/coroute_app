'use strict';
/**
 * Google Play payments policy guard for text that reaches the Android app (push notifications and
 * push templates). Same forbidden terms as the app scan (tool/play_policy_scan.dart
 * `forbiddenTerms`), plus the steering words of docs/features_355/play_payments_policy.md rule 2/3
 * and the offer words that admin-written marketing pushes must not use.
 *
 * test/push_campaigns_355.test.js checks that every alternative of the Dart regex is covered here,
 * so the two lists cannot drift apart.
 */

/** The app scan's list (tool/play_policy_scan.dart), verbatim. */
const APP_SCAN_TERMS = ['razorpay', '₹', '\\bINR\\b', 'price', 'pricing', 'per month', 'upgrade', 'purchase', '\\bbuy\\b', '\\bbuying\\b', 'checkout', 'coupon', 'discount', 'renew', 'payment'];

/** Policy rule 2/3 extras and offer wording (marketing pushes only go to the website board / e-mail). */
const EXTRA_TERMS = ['\\bpay\\b', '\\bpaid\\b', 'offer code', 'plans page', '/mo\\b', '\\brs\\.?\\s?\\d', '\\boffers?\\b', '\\bsale\\b', '%\\s?off\\b', '\\bdeals?\\b', 'cashback', 'free trial', 'subscribe', 'subscription'];

const FORBIDDEN = new RegExp(`(${[...APP_SCAN_TERMS, ...EXTRA_TERMS].join('|')})`, 'i');

/** Links to the website's buying pages (any host): /plans, /checkout, /get?coupon=, /account/billing. */
const STEERING_LINK = /(\/plans\b|\/checkout\b|\/get\?coupon|[?&]coupon=|\/receipt\b)/i;

/**
 * The first forbidden term in `text`, or null. Checks words and links to the buying pages.
 * @returns {string|null}
 */
function forbiddenTermIn(text) {
  const s = String(text == null ? '' : text);
  const m = FORBIDDEN.exec(s);
  if (m) return m[1];
  const l = STEERING_LINK.exec(s);
  return l ? l[1] : null;
}

/** The admin message for a refused push text. */
function policyRefusal(term, where = 'This push') {
  return `${where} mentions "${term}". Push notifications reach the Play app, which must not show prices, coupons, discounts, offers or buying words, or link to the plans page (Google Play payments policy). Put offers on the website board or in an e-mail instead.`;
}

module.exports = { APP_SCAN_TERMS, EXTRA_TERMS, FORBIDDEN, STEERING_LINK, forbiddenTermIn, policyRefusal };
