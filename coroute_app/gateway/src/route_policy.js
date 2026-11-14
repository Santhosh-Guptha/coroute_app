'use strict';
/**
 * 3.57 security: the declared access policy of every HTTP route. test/route_policy_357.test.js walks the real
 * express app and FAILS when a route has no policy here, or when a route does not behave as declared
 * (anonymous -> 401 for 'auth' / 'admin' / 'operator'; a plain rider -> 403 for 'admin').
 *
 * Policies:
 *   public    no account needed (listed one by one below, with why)
 *   auth      a signed-in rider (Bearer token of a live session). The default for every /api route.
 *   admin     MASTER_ADMIN (every /api/admin/* route)
 *   operator  an owner / co-organiser of that operator (/api/operator/:operatorId/*), checked server side
 *   page      a website page or asset (GET); private data on it is loaded through 'auth' APIs
 *
 * Adding a public API route? Add it to PUBLIC with a reason; the test refuses it otherwise.
 */

/** Public API routes and why they need no account. Capability-token routes check their token themselves. */
const PUBLIC = Object.freeze({
  // sign-in, sessions, recovery (each rate limited; refresh / 2-step routes check their own token)
  'POST /api/auth/register': 'create an account',
  'POST /api/auth/login': 'sign in',
  'POST /api/auth/google': 'sign in with a Google ID token (verified server side)',
  'POST /api/auth/guest': 'retired: 410 for old builds',
  'POST /api/auth/refresh': 'refresh token (body or httpOnly cookie + CSRF header)',
  'POST /api/auth/logout': 'revokes the session named by the Bearer / refresh token, if any',
  'POST /api/auth/password/forgot': 'always 202, mails a single-use link',
  'POST /api/auth/password/reset': 'single-use 30-minute token',
  'POST /api/auth/email/confirm': 'single-use 30-minute token sent to the new address',
  'POST /api/auth/mfa/verify': 'second sign-in step (10-minute 2-step token)',
  'POST /api/auth/mfa/enroll/start': 'second sign-in step (10-minute 2-step token)',
  'POST /api/auth/mfa/enroll/confirm': 'second sign-in step (10-minute 2-step token)',
  // round 4
  'POST /api/auth/mfa/email-code': 'second sign-in step: e-mails a code (10-minute 2-step token, rate limited)',
  'POST /api/auth/ride-lock/code': 'ride lock override: e-mails a code (15-minute lock token issued after the password)',
  'POST /api/auth/ride-lock/verify': 'ride lock override: lock token + single-use e-mailed code (5 tries)',
  'POST /api/auth/email/verify': 'sign-up verification link (single use, 24 h, hash stored)',
  'POST /api/auth/register/resend': 'always 202, mails a new link to a pending sign-up only',
  'POST /api/auth/delete/confirm': 'account deletion link e-mailed to builds before 10025 (single use, 30 min)',
  // app / website metadata and health
  'GET /api/health': 'load balancer and monitoring',
  'GET /api/health/live': 'load balancer health of the live node',
  'GET /api/meta': 'app version gate and links',
  'GET /api/web/config': 'website: Google web client id, support address',
  'GET /api/public/access': 'website: access mode (no personal data)',
  'GET /api/membership/catalog': 'website: plan catalog',
  'GET /api/subscription/config': 'legacy plan catalog',
  // aggregated, privacy-rounded numbers and approved content for the website
  'GET /api/usage-stats': 'aggregates', 'GET /api/public/usage-stats': 'aggregates',
  'GET /api/impact-stats': 'aggregates', 'GET /api/public/impact-stats': 'aggregates',
  'GET /api/alltime-stats': 'aggregates', 'GET /api/public/alltime-stats': 'aggregates',
  'GET /api/community-stats': 'aggregates', 'GET /api/public/community-stats': 'aggregates',
  'GET /api/community-stories': 'approved, consented reviews', 'GET /api/public/community-stories': 'approved, consented reviews',
  'GET /api/public/review-photos/:feedbackId/:photoId': 'photos of approved, consented reviews only',
  'GET /api/public/leaderboard': 'public usernames that did not opt out',
  'GET /api/public/live-now': 'rounded count of riders on a ride',
  'GET /api/public/board': 'website offers board', 'GET /api/public/board/images/:imageId': 'website offers board images',
  // v3.58 Explore: admin-curated destination list and its admin-uploaded photos (no personal data; distances are worked out on the phone)
  'GET /api/public/destinations': 'admin-curated destinations (no personal data)', 'GET /api/public/destinations/:id/photo': 'admin-uploaded destination photos',
  'GET /api/public/rides/:slug': 'operator rides published as public', 'GET /api/public/clubs/:code': 'club join page',
  'POST /api/pv': 'cookieless page-view counter',
  'POST /api/feedback': 'website feedback form (honeypot, timing, rate limit)',
  // capability tokens / signatures (checked by the handler)
  'GET /api/public/live/:token': 'live emergency link (hashed token, 30 minutes)',
  'GET /api/checkout/order/:orderId': 'old app checkout link (signed t / e)',
  'POST /api/verify-payment': 'legacy web checkout: Razorpay HMAC signature over our order',
  'POST /api/razorpay/callback': 'Razorpay redirect: HMAC signature',
  'POST /api/subscription/validate-coupon': 'legacy coupon check (uniform answers, brute-force brake)',
  'POST /api/validate-coupon': 'legacy coupon check (uniform answers, brute-force brake)',
  'POST /api/subscription/webhook': 'Razorpay webhook: HMAC signature + replay protection',
  'POST /api/membership/webhook': 'Razorpay webhook: HMAC signature + replay protection',
  'POST /api/sms/receipts/:provider/:token': 'SMS provider delivery receipts (secret path token)',
  // guardian pilot (GUARDIAN_ENABLED): public watch endpoints use their own signed links
  // round 4 road & safety intelligence: what is collected, k-min and retention (no data; the privacy page links it)
  'GET /api/intel/info': 'road & safety intelligence: public description of what is collected and kept',
});

/** Non-API routes that are not plain GET pages. */
const OTHER = Object.freeze({
  'POST /email/unsubscribe': 'signed one-click unsubscribe link (RFC 8058)',
  '_ALL /admin/*': 'web admin assets fallback (404 / 400, no data)',
  '_ALL /operator/*': 'operator console assets fallback (404 / 400, no data)',
});

/** The declared policy of "METHOD /path", or null when none applies (the test then fails). */
function policyOf(key) {
  if (PUBLIC[key]) return 'public';
  if (OTHER[key]) return 'public';
  const [method, path] = [key.slice(0, key.indexOf(' ')), key.slice(key.indexOf(' ') + 1)];
  if (/^\/api\/admin(\/|$)/.test(path)) return 'admin';
  if (/^\/api\/operator\/:operatorId(\/|$)/.test(path)) return 'operator';
  if (/^\/api(\/|$)/.test(path)) return 'auth';
  if (method === 'GET' || method === 'HEAD') return 'page';
  return null;
}

/** Every route of an express app as "METHOD /path" (array paths joined with ","; mounted routers prefixed). */
function walkRoutes(app) {
  const out = [];
  const prefixOf = (layer) => {
    const src = layer.regexp && layer.regexp.source;
    if (!src || src === '^\\/?(?=\\/|$)' || layer.regexp.fast_slash) return '';
    return src.replace(/^\^/, '').replace(/\\\/\?\(\?=\\\/\|\$\)$/, '').replace(/\\\//g, '/').replace(/\(\?:\(\[\^\\\/\]\+\?\)\)/g, ':param');
  };
  const walk = (stack, prefix) => {
    for (const l of stack) {
      if (l.route) {
        const p = Array.isArray(l.route.path) ? l.route.path.join(',') : l.route.path;
        for (const m of Object.keys(l.route.methods)) out.push(`${m.toUpperCase()} ${prefix}${p}`);
      } else if (l.name === 'router' && l.handle && l.handle.stack) {
        walk(l.handle.stack, prefix + prefixOf(l));
      }
    }
  };
  walk(app._router.stack, '');
  return [...new Set(out)];
}

module.exports = { PUBLIC, OTHER, policyOf, walkRoutes };
