# Rider payments on the website (3.56)

The Play app no longer sells anything (Google Play payments policy). Plans, prices, coupons, payments and the
rider's account are on the website. Razorpay stays, on the website only. The membership rules on the server
did not change: one price computation (`plan_pricing.js`), upgrade-only while a paid plan runs, coupons with the
same rules, the same orders, verify and webhooks.

Code: `gateway/src/web_shop.js` (pages, CSP, `/api/web/*`, coupon forward, app notification),
`gateway/public/{plans,signin,account,receipt}.html`, `gateway/public/assets/{shop,plans,signin,account,receipt,checkout,theme-init}.js`,
`gateway/public/assets/shop.css`. Tests: `gateway/test/web_plans_355.test.js`, `website.test.js`,
`website_get_coupon_355.test.js`, `marketing_templates_355.test.js`.

## Flow

1. **Sign in** (`/signin`). The same CoRoute account as the app: email or callsign + password
   (`POST /api/auth/login`), or **Sign in with Google** when `GOOGLE_WEB_CLIENT_ID` is set
   (Google Identity Services button -> `POST /api/auth/google { idToken }`, verified with the same audience
   list as the app). A temporary password from an admin reset asks for a new one first
   (`POST /api/me/password`). "Forgot password?" shows the same help as the app (Google, or e-mail support
   for a temporary password); there is no self-service reset on the server.
2. **Plans** (`/plans`). Cards from `GET /api/membership/catalog` (the list the app used), with what each plan
   includes. Signed in, the current plan is marked "Your plan" and plans the server would refuse
   (same or smaller while a paid plan runs) are greyed out with the end date.
   Choosing a paid plan opens **Review your price**: `GET /api/membership/quote?plan=&coupon=` gives the
   breakdown (list price, coupon, credit for the unused days of the current plan, to pay now) and the notes.
   A refused code shows the server's reason under the field and the full price; 409
   `DOWNGRADE_NOT_ALLOWED` shows the server's text. `?coupon=CODE` prefills the code (A-Z 0-9 - _, max 24),
   `?plan=<id>` preselects a plan. Signed out, the list price shows and the button reads "Sign in to continue"
   (back to `/plans?plan=..&coupon=..` afterwards). **Community** is free: no payment, it links to the app.
3. **Pay**. `POST /api/membership/order { category, offerCode }` (header `X-CoRoute-Client: web`, stored as
   `channel: 'web'` on the order). The amount is the server's quote; anything the browser sends as an amount
   is ignored. At ₹0 (100% coupon, or credit covering it) the plan is activated at once. Otherwise
   Razorpay Checkout (`https://checkout.razorpay.com/v1/checkout.js`, modal) opens with the server's order;
   its handler posts to `POST /api/membership/verify` (HMAC signature, order owner, replay checks).
4. **Done**. The plan is active; the page links to the account/receipt and `coroute://subscription`.
   The app updates at once: `SUBSCRIPTION_ACTIVATED { plan, validUntil, orderId, source }` goes to the
   rider's sockets (every app build re-reads `/membership/my` on it), and an FCM push
   (`type SUBSCRIPTION_ACTIVATED`, routed to the membership screen) goes only when no app socket got it.
   No e-mail or SMS confirmation: there is no e-mail provider and the SMS gateway is for emergencies only.
5. **Account** (`/account`). Username, name, e-mail, current plan, status (Active / Ends in N days / Free),
   start and end date, a plan change waiting to start, the payment list (`GET /api/membership/payments`)
   with **View receipt** for paid orders. Plans do not renew on their own, so there is nothing to cancel
   (no cancel button). Sign out clears the session. No ride data anywhere on these pages.
6. **Receipt** (`/receipt?order=<orderId>`, `GET /api/web/receipt/:orderId`). Printable (print CSS hides
   the site chrome): seller, billed to, paid on, breakdown, plan and period, method, coupon, payment id,
   refund. Someone else's order answers 404 like a missing one; an unpaid order 409.

If the tab closes after paying but before `/verify`, Razorpay's webhook activates the plan (below).

## Plan prices and offers (3.56)

Each paid plan has a **list price** (`listPriceInr`, MRP; `monthlyPriceInr` is kept equal for older readers; a
stored catalog without it reads its price as the list price) and an optional **offer**
`{ priceInr, label, startAt, endAt }`. The price charged is the offer price inside `[startAt, endAt)` (India time
in the editor, either end open), else the list price (`plan_pricing.effectivePrice`, the single source of truth).
`GET /api/membership/catalog` adds per plan `listPriceInr`, `priceInr` (now) and `activeOffer { priceInr, label,
endsAt }` (null before an offer starts; the stored offer itself is not exposed). The quote breakdown reads
"Large Group (30 days) ₹99 / Launch offer −₹50 / Coupon −₹10 / To pay now ₹39": coupons apply on top of the offer
price unless the coupon has `stackWithOffer: false` (then refused while the offer runs), and never below the
minimum price (`PUT /api/admin/pricing-rules { minPayableInr }`). Plan cards (`/plans` and the home page) show the
list price struck through, the offer price, the label and "until <date>"; the order stores `listPriceInr`,
`offerPriceInr`, `offerLabel`; the receipt shows the offer line and label, the account list "₹49 (Launch offer)".
Without a catalog the pages show no prices (only "Plans could not load…" / a pointer to the plans page).

## Access mode (3.56)

* In "free for everyone" mode ([access_modes.md](access_modes.md)), `/plans` shows "CoRoute is free
  right now" and hides the checkout, and `POST /api/membership/order` answers `409 FREE_MODE`.
* `/account` is unchanged. It also has the "Send me offer e-mails" consent switch (off by default; see
  [notifications_admin.md](notifications_admin.md)).
* In "free up to limits" mode, `/plans` shows the free limits above the plans.

## Endpoints

| Endpoint | Auth | Notes |
|---|---|---|
| `GET /api/membership/catalog` | public | existing |
| `POST /api/auth/login`, `/api/auth/google` | public | existing; rate limited 30 / 15 min per IP, 10 failed / 15 min per account |
| `GET /api/me`, `/api/membership/my`, `/api/membership/payments` | Bearer | existing |
| `GET /api/membership/quote` | Bearer | existing (plan_pricing.computeQuote) |
| `POST /api/membership/order`, `/api/membership/verify` | Bearer | existing; 3.56 adds `channel` and the app notification |
| `GET /api/web/config` | public | new: `{ googleClientId, supportEmail, paymentsEnabled, merchantName }` |
| `GET /api/web/receipt/:orderId` | Bearer | new: one paid order of this rider |
| `POST /api/subscription/webhook`, `/api/membership/webhook` | Razorpay HMAC | 3.56: a membership order is settled as a membership on **either** URL |
| `GET /get?coupon=CODE` | public | new: 302 to `/plans?coupon=CODE` |
| `GET/PUT /api/admin/pricing-rules` | admin | 3.56: minimum price coupons never go below (audited) |
| `GET /api/public/board` | public | 3.56 marketing board ([marketing_board.md](marketing_board.md)) |
| `GET /checkout` (no order) | public | new: 302 to `/plans` |

Webhook fix (3.56): `/api/subscription/webhook` (the URL configured in Razorpay) used to run the legacy tier
activation for every order. For a membership order that marked it PAID without giving the plan, so a web
payment whose tab closed before `/verify` was lost. Now `isMembershipOrder(order)` (a `category`, no
`planTier`) goes to `settleMembershipPayment`: activation, coupon redemption, `SUBSCRIPTION_ACTIVATED`. The
legacy `/api/verify-payment` and `/api/razorpay/callback` do the same for membership orders.

## Security

3.56 security review (threats, fixes, tests): [web_payments_security.md](web_payments_security.md). In short:
atomic order claim (one activation per payment, never after a refund), verify only by the order's rider,
Razorpay amount / currency re-check, persistent webhook event ids, **one webhook URL active**
(`RAZORPAY_WEBHOOK_URL`, default `subscription`; the other answers 410), order expiry (30 min) and Checkout
timeout, coupon caps atomic, coupon guessing braked (429) with uniform refusals, India-time coupon windows
(end exclusive), price floor, one code per order.

- **Session**: the JWT from the login API is kept in `sessionStorage` only (gone when the tab closes), sent as
  `Authorization: Bearer`, never in a URL, cookie or `localStorage`. A 401 clears it. The sliding refresh header
  (`X-CoRoute-Token`) is honoured. CSRF does not apply (no cookies).
- **CSP** on `/plans`, `/signin`, `/account`, `/receipt`, `/checkout` (set in `web_shop.js`, replacing the
  site-wide one): `script-src 'self'` (+ `https://checkout.razorpay.com` on /plans and /checkout,
  + `https://accounts.google.com/gsi/client` on /signin only when Google is configured), no `'unsafe-inline'`
  scripts, `frame-ancestors 'none'`, `object-src 'none'`, `base-uri 'none'`, `frame-src` only Razorpay
  (`api.`/`checkout.razorpay.com`) or Google GSI where needed, `connect-src 'self'` + `api.razorpay.com`,
  `lumberjack.razorpay.com`. Plus `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`,
  `Cache-Control: no-store`, `noindex` (except /plans). No inline scripts: the theme bootstrap is
  `assets/theme-init.js`; the old checkout script moved to `assets/checkout.js`.
- **XSS**: every value from the server or the URL is written with `textContent`; codes and plan ids from the
  URL are checked against strict patterns; the server never renders the query into a page. `?next=` after
  sign-in accepts only `/plans`, `/account`, `/receipt` on this site.
- **Amounts** are always computed on the server (`plan_pricing.js`), at quote and again at order time.
- **Payments**: Razorpay signature (HMAC over `order_id|payment_id`) checked by `/membership/verify`;
  webhooks require `X-Razorpay-Signature` (HMAC over the raw body, 1 MB cap) and are de-duplicated by event id.
- Allowed Razorpay domains live in one constant (`RAZORPAY` in `web_shop.js`).

## Old app compatibility

- **3.54 / 3.55 in-app purchase** (native Razorpay SDK -> `/membership/order` + `/membership/verify`): unchanged.
  Those builds now also get `SUBSCRIPTION_ACTIVATED` after their own purchase (harmless: they re-read the plan).
- **Old website checkout links** (`/checkout.html?order=<id>&t=<hmac>&e=<expiry>`, created by
  `/subscription/create-order`; legacy sales are off, but a link can still be open): the page, its API
  (`GET /api/checkout/order/:id`), redirect mode and the return (`?paid=` / `?failed=`) work as before.
  Only a visit without those parameters is sent to `/plans`.
- **Coupon links printed before 3.56** (`/get?coupon=CODE`): forwarded to `/plans?coupon=CODE`. A 3.55 app that
  still opens `/get` links itself keeps its old behaviour.
- **Marketing studio**: coupon placeholders now include `link` = `<origin>/plans?coupon=CODE`
  (`couponLink()` in `marketing_templates.js`; origin = `PUBLIC_ORIGIN`, else the request host), used for the
  QR code and `{link}`.

## Website changes

- Header: "Pricing" (`/#pricing`) became **Plans** (`/plans`); an **Account** link next to "Get the app"
  (in the mobile menu as "Account and sign in"). Footer: "Plans and pricing", "Your account".
- Home: the plan cards link to `/plans?plan=<id>`; the notes say plans are bought on the plans page.
- `/get`: download links only (no prices, no coupon chip).
- `/plans` is in the sitemap; `/account`, `/signin`, `/receipt` are not.

## Owner setup

1. **Razorpay dashboard**
   - Website URL / business details: `https://coroute.devmonks.space` and the plans page `/plans`
     (Razorpay checks the website for prices, terms, privacy, refund and contact information).
   - Webhook: keep `https://coroute.devmonks.space/api/subscription/webhook` (events `payment.captured`,
     `order.paid`, `payment.failed`, `refund.processed`, `refund.created`) with the webhook secret already set
     in the admin console / env. Web orders are handled there now. Since 3.56 only one URL is live:
     `/api/membership/webhook` answers 410 unless `RAZORPAY_WEBHOOK_URL=membership` is set (then the
     subscription URL answers 410 instead).
   - Live keys: unchanged (admin console payment gateway or `RAZORPAY_LIVE_*`).
2. **Google sign-in on the website (optional)**: Google Cloud console -> APIs and services -> Credentials ->
   OAuth client ID of type **Web application** (the Android app usually already uses one as its server client
   id: it can be the same). Add **Authorized JavaScript origins** `https://coroute.devmonks.space` (and the
   legacy host if used). Set `GOOGLE_WEB_CLIENT_ID=<id>.apps.googleusercontent.com` in the gateway env and
   restart. It is also accepted as an ID-token audience (added to `GOOGLE_CLIENT_IDS` automatically). Without
   it the page offers email/callsign + password only.
3. `PUBLIC_ORIGIN` must be the https site origin (coupon links and receipts use it).
4. Optional: `SUPPORT_EMAIL` (shown in "Forgot password?" and on receipts).
