# Website payments and coupons: security review (3.56)

Scope: the web purchase flow (`/signin`, `/plans`, `/account`, `/receipt`, `/checkout`), `src/web_shop.js`,
`membership_routes.js` (quote, order, verify, purchase, activate-free, webhook), `subscription_routes.js`
(webhook, legacy validate / verify, admin coupons, refunds), `plan_pricing.js`, `razorpay_gateway.js`, the coupon
store in `oracle/repo.js`. Shared rules live in **`src/payment_security.js`**.
Tests: `gateway/test/web_payments_security_355.test.js` (20 tests), plus `plan_offers_355.test.js` and
`marketing_board_355.test.js`.

## Threats, mitigations, tests

| # | Threat | Mitigation (where) | Test |
|---|---|---|---|
| 1 | Client sets the amount | Amount always from `plan_pricing.computeQuote` (quote and order, same call). New: Razorpay's order reply must echo our amount in paise and INR, else 502 `GATEWAY_AMOUNT_MISMATCH` and nothing is stored. | `order: the amount is the server's…` |
| 2 | Paying someone else's order / admin settling it | `/membership/verify` refuses any account but the order's rider, **including MASTER_ADMIN** (the old admin bypass is gone). Receipts: own orders only (others 404, admins too). | `verify: bound to the order's rider…`, `web session…` |
| 3 | Same payment activates twice (retry, verify + webhook, both URLs, two nodes) | **Atomic claim**: `repo.claimRazorpayOrder` (compare-and-replace on the ledger order: CREATED/FAILED → SETTLING) before any activation; the loser answers idempotently. One settle path for verify, purchase, both webhooks and the legacy verify/callback (`settlePaidOrder`). A PAID order verified with a different payment id → 409 `REPLAY_ATTACK_DETECTED`. | `concurrent verify + both webhooks…` (4 verifies + 2 webhooks at once → 1 activation, 1 app notice, coupon counted once) |
| 4 | Forged signature | HMAC-SHA256 over `order_id|payment_id` with the order's own mode secret, `timingSafeEqual`; signature must be 64 hex, ids `[A-Za-z0-9_]{6,64}`, strings only (no objects). Webhook: HMAC over the **raw bytes** (`express.raw`, 1 MB), constant time. | `verify…`, `webhooks…` (tampered body 400) |
| 5 | Payment for a different amount / currency | Verify fetches the payment from Razorpay (`gateway.fetchPayment`) and requires same `order_id`, amount in paise, currency, status captured/authorized (`paymentMismatch`). Webhooks check the signed payment entity. If Razorpay cannot be reached the signature stands (it binds the payment to the order we created at our amount). Mismatch → 400, order flagged `paymentMismatch`. | `amount / currency check…` |
| 6 | Webhook replay | Event ids stored in the new `payment_events` collection (unique `eventId`): shared by both URLs, every node and restarts (plus the in-memory and per-order lists). | `webhooks…` |
| 7 | Two webhook URLs both live (double delivery) | Only one is active: `RAZORPAY_WEBHOOK_URL=subscription` (default, the URL in the dashboard) or `membership`. The other answers **410 `WEBHOOK_URL_INACTIVE`** and settles nothing (Razorpay shows the failure, so a wrong setup is visible). | `webhooks…` |
| 8 | Test-mode event settling a live order | Membership webhook now checks `order.mode === mode` like the subscription one. | `webhooks…` |
| 9 | Refund then re-activation | The claim refuses orders with any refund. A full refund (admin or Razorpay) now **ends the plan that order bought** for membership orders (`recordRefund`; before only legacy tiers were revoked) and only that plan (`mem.orderId === order.orderId`). | `refunds…` |
| 10 | Stale orders | Orders carry `expiresAt` (30 min, `ORDER_TTL_MS`); Checkout gets `timeout` (15 min) so it closes first; the coupon hold lasts as long as the order. A genuinely paid late order is still honoured (money was taken). | `order…` |
| 11 | Coupon guessing | Per rider + per IP brake (`CouponGuard`): 10 unknown codes in 15 min → every code lookup (quote, validate, order, activate-free, legacy public validate) answers 429 `COUPON_ATTEMPTS` with `Retry-After`; plus 20 lookups/min (`couponLimiter`). | `coupon brute force…` |
| 12 | Coupon enumeration | Missing, draft, archived, scheduled and private (allow-list) codes give the identical answer (`couponRefusal`: "We couldn't find that code", `COUPON_NOT_FOUND`, same status) on every endpoint; the typed code is never echoed. Expired / used-up / paused codes (they were public) keep their reason. | `coupon enumeration…` |
| 13 | Over-redemption under concurrency | Coupon caps are enforced in **one compare-and-replace of the coupon document** (`_couponAtomic`): total cap counts uses + live holds, per-rider cap counts uses + holds; ₹0 orders use at once; paid orders hold, confirm turns the hold into a use **idempotently by order id**. Admin edits / pause / archive can no longer overwrite usage written meanwhile (`_writeCoupon`). Free activations (`activate-free`, `purchase`) now reserve atomically before activating. | `coupon caps hold under concurrency…` (8 riders, cap 3 → 3; free cap 2, 6 riders → 2; 5 parallel confirms → 1) |
| 14 | Expiry / time zones | Windows are `[validFrom, expiresAt)` (end exclusive, also `computeCouponStatus`). Admin dates accept epoch ms, ISO with a zone, or India-time `YYYY-MM-DD` (from 00:00, **until the end of that day**) / `YYYY-MM-DDTHH:mm`; unreadable dates are 400 instead of silently "30 days". | `coupon window…`, `IST times…`, `coupon codes are case-insensitive…` |
| 15 | Case tricks | Codes trimmed and upper-cased everywhere; only `A-Z 0-9 _ -` up to 32 are looked up. | same |
| 16 | Price below zero / below a minimum | `flooredDiscount`: never below 0; **minimum price** (`PUT /api/admin/pricing-rules { minPayableInr }`, audited) that no coupon goes under (a `free` coupon, the admin's explicit free month, is the exception). | `price floor…` (unit + HTTP) |
| 17 | Stacking | One code per order (an array or two different codes → 400 `ONE_CODE_ONLY`). A coupon with `stackWithOffer: false` is refused (`NOT_WITH_OFFER`) while a plan offer runs. | `order…`, `plan_offers_355` |
| 18 | Non-admin coupon / price / board changes | All admin routes `requireAdmin` (MASTER_ADMIN only): rider 403, anonymous 401; coupon create / update / delete / pause / resume, price and offer changes, minimum price and board posts are in the audit log. | `admin endpoints are MASTER_ADMIN only…` |
| 19 | Session theft / XSS / framing | Token in `sessionStorage`, Bearer only, never in a URL or cookie; strict page CSP (no inline script, `frame-ancestors 'none'`, `base-uri 'none'`), `X-Frame-Options: DENY`, HSTS (helmet), `Referrer-Policy: no-referrer`, no-store; every server value rendered with `textContent` (also the new board). No cookie-based endpoint is used by the shop (the only cookie in the gateway is the guardian pilot's httpOnly credential, not reachable from these pages), so CSRF does not apply. | `web session…`, `website code…` |
| 20 | Sign-in brute force / enumeration | 30 / 15 min per IP, 10 failed / 15 min per account (across IPs); unknown account and wrong password give the same 401 text after the same hashing work. | `web session…` |
| 21 | PII in logs | The payment paths log no bodies, tokens, signatures or e-mails (checked with a capturing logger); `maskEmail` for future log lines; rider-facing order objects drop internal fields (`publicOrder`). | `no tokens, signatures or e-mails in server logs…` |

## Known limits

- The coupon brake is per gateway node (memory); the caps themselves are database-atomic across nodes.
- A rider who opens two payment tabs keeps only the newest hold. If they really pay both orders, both are
  honoured (money was taken) and the coupon counts twice for that rider; the admin sees it in the redemptions and
  can refund. Razorpay has no API to cancel an order.
- When Razorpay's API is unreachable during `/verify`, the amount re-check is skipped (signature only); webhooks
  always carry the signed amount.
