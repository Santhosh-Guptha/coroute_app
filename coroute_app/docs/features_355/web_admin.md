# Web admin (3.55)

Money and marketing admin features left the mobile app (Google Play policy risk: in-app pricing,
coupons and payment controls) and moved to a browser console served by the gateway at **`/admin`**.

## Sections

| Section | What it does | APIs it calls (all existing unless marked new) |
|---|---|---|
| **Payments** | Search / filter every Razorpay order (order, payment or user id; status; live / test / manual; plan; date range), 30-day tiles, detail dialog with the rider's current plan, **refund** (full or partial, with reason, confirmation), **Export CSV** (date range), **Reconcile memberships** | `GET /api/admin/payments`, `GET /api/admin/payments/analytics`, `GET /api/admin/payments/users/:userId`, `POST /api/admin/payments/:orderId/refund`, `GET /api/admin/payments/export.csv`, `POST /api/admin/membership/reconcile` |
| **Plans & pricing** | Edit the membership catalog (name, **list price (MRP)** and, 3.56, an **offer**: offer price, label, start / end in India time, with a "Website shows: ₹99 → ₹49 Launch offer until 30 Nov" preview and the server's checks: offer below list, label, valid window; a **minimum price** card), billing days, riders, description, features, on sale; Community: text only). Razorpay: payments on/off, test/live mode, key ids **masked** (`rzp_live_••••••1234`), secrets shown only as **Set / Not set**, replace keys (blank keeps), test keys. Audit log of money and marketing changes | `GET/PUT /api/admin/membership/catalog`, `GET/PUT /api/admin/payment-gateway`, `POST /api/admin/payment-gateway/test`, `GET /api/admin/audit` |
| **Coupons** | Usage tiles, list with status (active, scheduled, paused, expired, used up, archived, draft), create / edit (type, value, cap, plans, window in India time, limits, rules incl. "works on top of a plan offer" (3.56), notes), pause / resume, **expire now**, recent redemptions per coupon, "Make marketing image" | `GET/POST /api/admin/coupons`, `PATCH /api/admin/coupons/:code`, `POST /api/admin/coupons/:code/pause|resume`, `GET /api/admin/coupons/usage`, `GET /api/admin/coupons/plan-options` |
| **Marketing studio** | Template list (active / archived, thumbnails, duplicate, archive, delete, warnings for expired / missing coupons), starters (festive, group plan, first ride, referral, flash sale, blank) bound to an active coupon, canvas editor, PNG export | `/api/admin/marketing/*` (`src/marketing_templates.js`) |
| **Board** (3.56) | "Latest from CoRoute" posts for the website: list (status, window, coupon), editor with a live preview of the website card, image upload (EXIF removed), coupon picker (active / scheduled), schedule in India time, pin, publish / archive / delete ([marketing_board.md](marketing_board.md)) | **new** `GET/POST /api/admin/board`, `PATCH/DELETE /api/admin/board/:id`, `POST /api/admin/board/images`, `GET /api/admin/board/images/:id`, `GET /api/admin/board/coupons` |
| **Revenue** | Tiles and hand-drawn SVG charts: net revenue per day (30 / 60 / 90 days) and per month (12 months), active paid plans at month end, coupon redemptions per month; top coupons, revenue by plan, monthly table | **new** `GET /api/admin/web/revenue` |

Everything else (riders, rides, safety, reviews, feature switches, diagnostics, …) stays in the
**app admin console**. The `marketingStudio` feature switch is still flipped there; while it is off the
studio section shows "This feature is switched off".

### Marketing studio editor

Port of the Flutter studio (`lib/domain/marketing/**`, `lib/presentation/admin/marketing/**`), built on
the JS painter mirror in `docs/features_355/marketing_preview/render.html`, so templates saved by
either console render the same (same JSON schema v1, relative geometry, units at a 1080 px short side).

- Files: `gateway/public/admin/studio_core.js` (model, placeholders, starters, retarget, undo history,
  painter), `studio.js` (list, starters, editor UI), `qr.js` (QR encoder).
- Sizes: square post 1080×1080, story / WhatsApp status 1080×1920, banner 1200×628, custom 200–4096.
  Changing size re-lays out the layers (`retarget`, same rules as the app).
- Layers: background (solid / gradient 2–4 colours / uploaded image, built-in patterns, tint), text,
  coupon block (ticket / pill / card / stamp), logo (mark or wordmark), badges and shapes (rect, pill,
  circle, ribbon, star, burst), uploaded images (≤ 2 MB, EXIF stripped by the gateway), QR code.
- Select by click (canvas or layer list), drag to move with snap guides (canvas centre / edges and
  other layers' centres; Alt disables), 8 resize handles (Shift or aspect layers keep the shape),
  rotate handle (snaps to 45°, Shift 15° steps), arrow keys nudge (Shift ×10), Ctrl+Z / Ctrl+Shift+Z,
  Ctrl+D duplicate, Delete, Ctrl+S save. Hide / lock / reorder in the layer list.
- Coupon binding: only active / scheduled coupons can be newly bound (server rule). A bound coupon
  that expired, was paused or deleted shows a red banner, a chip in the list, and a confirmation
  before export.
- Placeholders `{code} {discount} {validUntil} {plan} {name} {cap} {link}`; the server's values are
  preferred. **`{link}` and the QR code = `<PUBLIC_ORIGIN>/plans?coupon=CODE`** (the website plans
  page, same rule as `couponLink` / `plansLink` in the gateway; `<origin>/plans` without a coupon).
  A template's own link may hold `{code}`. Old `/get?coupon=` links are redirected by `src/web_shop.js`.
- Export: full resolution with `canvas.toBlob('image/png')`; "All sizes" exports square, story and
  banner (plus the custom size). Caption editor with placeholder chips, "Write for me" and
  "Copy caption" (copies the filled-in text).
- QR encoder: byte mode, level M, versions 1–10, automatic mask; a port of the Dart encoder, checked
  module for module against the Python `qrcode` reference vectors (test below) and decoded with
  OpenCV from an exported PNG during development.

## Security

- **Who can sign in:** the page uses the existing `POST /api/auth/login` (rate limited: 30 / 15 min
  per IP and 10 failed attempts / 15 min per account). Only `MASTER_ADMIN` accounts get in: that is
  the role `requireAdmin` accepts on every admin API, so the page refuses other roles up front and the
  server refuses them anyway (rider token → 403, no token → 401; covered by the test).
- **Token:** kept in `sessionStorage` only (gone when the tab closes), sent as `Authorization: Bearer`,
  never in a cookie or URL. Any `401` signs out at once; a rotated token (`X-CoRoute-Token`) is picked up.
- **Idle timeout:** signed out after **30 minutes** without pointer / keyboard activity (checked every
  15 s and when the tab becomes visible), and when the JWT expires.
- **Headers on every `/admin` response** (`src/web_admin.js`): `Content-Security-Policy: default-src
  'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; font-src 'self';
  connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'`
  (no inline script or style, no third party, not even Razorpay), `X-Frame-Options: DENY`,
  `X-Robots-Tag: noindex, nofollow, noarchive`, `Referrer-Policy: no-referrer`,
  `Cache-Control: no-store` on the page. Assets are versioned (`?v=<hash>`); `robots.txt` disallows `/admin`.
- **Secrets:** Razorpay key secrets and webhook secrets are never sent to the browser (the gateway's
  `publicView` returns only `keySecretSet` / `webhookSecretSet`); key ids are masked in the UI. New
  secrets are typed into password fields and not kept after saving. The audit log records what
  changed, never a secret.
- All text from the server is inserted as text nodes (no `innerHTML`).

## How to sign in

1. Open `https://<your domain>/admin` on a desktop or tablet browser.
2. Sign in with the email and password of a master administrator account (the same account as the app
   admin console; `BOOTSTRAP_ADMIN_EMAILS` accounts become master admins on login).
3. Theme: Auto / Light / Dark at the bottom of the sidebar (remembered on that browser).

## 3.56 additions

* **Plans & pricing > Access mode** (`public/admin/access.js`):
  * Paid, Free for everyone (riders per ride), or Free up to limits (riders per free group ride, free
    group rides per month, the group features included for free).
  * An optional scheduled change in India time, a reason, and the version history.
  * Saved with `PUT /api/admin/access-mode`, audited as `access_mode.update`. See
    [access_modes.md](access_modes.md).
* **Notifications**:
  * the composer has a **Channel** (Push / E-mail (Offers)) and a push **Kind** (Update, Event, Safety
    tip, Community, Partner perk, with partner name and the "curated" confirmation);
  * new tab **Offers e-mail** (`public/admin/offers.js`) with the composer, campaigns and the
    suppression list.
  * See [notifications_admin.md](notifications_admin.md).

## New endpoints

- 3.56: `GET/PUT /api/admin/pricing-rules` (minimum price), `GET /api/admin/membership/catalog` now also returns `effective` (price now per plan) and `rules`; `PUT /api/admin/membership/catalog` accepts `listPriceInr` and `offer` (audited as `pricing.plan_price`). Board endpoints: see [marketing_board.md](marketing_board.md).

- `GET /api/admin/web/config` (admin): `{ publicOrigin, plansUrl, paymentsEnabled, version, user }`.
- `GET /api/admin/web/revenue?days=7..366&months=3..36` (admin, read only): `daily[]` and `monthly[]`
  (India-time buckets: `netInr` after refunds, `refundsInr`, `orders`, `testNetInr`; monthly also
  `activePaidPlans`, `couponRedemptions`, `couponDiscountInr`), `totals`, `activePaidPlans` by plan,
  `byPlan`, `topCoupons`. Staff accounts are left out; Razorpay test-mode money is reported apart.

## Tests

- `gateway/test/web_admin_355.test.js`: page and assets served with the CSP / noindex / no-store
  headers and no inline script or style; unknown `/admin/*` paths 404; robots.txt; login is rate
  limited; every admin API the console uses refuses a rider token (403) and no token (401); the new
  config and revenue endpoints (refunds, test mode, staff, memberships, coupon redemptions, bounds);
  the QR encoder against reference matrices.
- `tool/web_admin_smoke.js`: boots a test-mode gateway in-process (MemorySoda), seeds an admin, riders,
  coupons, orders and memberships, then with Playwright/Chromium: a rider is refused at sign-in, the
  admin signs in, opens every section, downloads the CSV, creates a coupon in the UI, creates a template
  from a starter bound to it, drags / undoes / saves, exports a PNG (checks a real 1080×1080 PNG) and
  all sizes, and takes light, dark and tablet screenshots. Fails on any page error or CSP violation.
  Run: `node tool/web_admin_smoke.js [screenshot dir]`.
