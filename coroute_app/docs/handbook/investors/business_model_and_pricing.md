# Business model and pricing

How CoRoute makes money, what the code supports today, and a unit-economics framework with formulas. **Prices and costs that are not defined in code are [OWNER TO FILL].** Where the gateway has built-in defaults, they are labelled **current default config**: they apply only until an admin saves a catalogue in the web admin, and are not a launch-price decision.

Sources in the codebase: `gateway/src/plan_pricing.js` (the single price computation), `gateway/src/entitlements.js` (plans and seats), `gateway/src/oracle/repo.js` `_defaultMembershipCatalog()` (default catalogue), `gateway/src/access_mode.js`, `docs/features_355/access_modes.md`, `operators.md`, `web_payments.md`, `play_payments_policy.md`, `sos_sms.md`.

---

## 1. Principles (fixed by owner decisions)

1. **Safety is never gated.** SOS, crash alerts, emergency texts, medical ID, guardians, missing-rider check, stretch alert, buddy pairs and roll call are outside any plan or mode. They cannot be in the list of features a mode leaves out, and SOS, crash detection, emergency texts and medical ID are locked on in the admin feature switches.
2. **Joining a ride is free.** One member with a plan hosts; everyone else joins with the code and gets the host's group features for that ride ("one plan per group ride").
3. **The Play app sells nothing.** No payment SDK, no prices, no buying words, no steering to the website. Plans are bought and managed only on the website (`/plans`, `/account`). The app shows only neutral status: plan name, what it includes, status, end date, and "Your plan is managed in your CoRoute account."
4. **Offers go only by opt-in e-mail**, never in a push or in the app.

---

## 2. Plans (catalogue structure)

The catalogue has three plans (`CATALOG_PLANS`): one free, two paid.

| Plan id | Name | Riders per hosted ride (host included) | Billing period | Current default config price | Purchasable |
|---|---|---|---|---|---|
| `community` | Community | 1 (solo) + join any ride free | — | ₹0 | No (every rider has it) |
| `group_small` | Small Group (2–6) | 6 | 30 days | ₹49 list price | Yes, on the website |
| `group_large` | Large Group (7–12) | 12 | 30 days | ₹99 list price | Yes, on the website |

**Launch prices: [OWNER TO FILL].** The admin edits these in web admin › Plans & pricing (name, list price, billing days, riders, description, features, on sale).

A legacy "Individual" plan (₹9 / 30 days) and legacy tiers (CoRoute Pro, Road Captain, Tour Operator) are honoured until they end and are never sold again.

### 2.1 List price and offer mechanism

Each paid plan has:

- a **list price** (`listPriceInr`, the MRP), and
- an optional **offer** `{ priceInr, label, startAt, endAt }` (India time in the editor, either end open; the offer price must be below the list price).

`plan_pricing.effectivePrice()` is the single source of truth: inside the offer window the price charged is the offer price, otherwise the list price. The website shows the list price struck through, the offer price, the label and "until <date>"; orders and receipts store the list price, offer price and label.

### 2.2 Coupons, floors and upgrades

| Rule | Behaviour |
|---|---|
| Coupon types | Percentage (with optional cap), fixed amount, "pay ₹X", or free period |
| Stacking | Coupons apply on top of the offer price unless the coupon has `stackWithOffer: false` |
| Minimum price | `minPayableInr` floor: no coupon (except an explicit free coupon) takes the price below it |
| Coupon controls | Plan binding, India-time validity window, usage limits, pause / resume / expire, atomic caps, guessing brake |
| Upgrades | While a paid plan runs, a rider may only move up (Community < Small Group < Large Group); the new plan starts now with a full period and a credit for unused days of the current plan |
| Renewal | Plans do not renew on their own (nothing to cancel) |
| ₹0 orders | A 100 % coupon or credit that covers the price activates the plan without payment |
| Refunds | Full or partial, by an admin in the web admin, with reason |

Quote example (format only, from the docs): "Large Group (30 days) ₹99 / Launch offer −₹50 / Coupon −₹10 / To pay now ₹39."

### 2.3 Payment flow

Website sign-in (same account as the app) → `/plans` → server quote → Razorpay Checkout on the website → HMAC-verified confirmation or webhook → the plan unlocks in the app at once (socket event, or a push if the app is closed). Amounts are always computed on the server.

---

## 3. Access modes

Set in web admin › Plans & pricing › Access mode. The app never learns the mode or any price; it only receives capabilities (`canHostGroup`, `maxRiders`, `groupFeatures`, `reason`).

| Mode | Who hosts group rides | Riders per ride | Group features | Website `/plans` |
|---|---|---|---|---|
| **Paid** (default) | Riders with a group plan | The plan's seats (6 or 12) | All, in a group ride | Plans and checkout |
| **Free for everyone** | Every rider | `free.maxRiders` (default 12); a plan with more seats keeps them | All | "CoRoute is free right now"; no checkout |
| **Free up to limits** | Every rider within limits; beyond them, plan holders | `hybrid.maxRiders` (default 6) without a plan | Without a plan: the chosen `hybrid.freeFeatures` | Plans with a line about the free limits |

Free-up-to-limits defaults: 6 riders per ride, 8 hosted group rides per host per India calendar month (a ride counts once the first other rider joins), and a configurable subset of these group features: intercom, riding roles, automatic roles, crew rides, group fuel, regroup suggestion, public ride, nearby groups, bike swap.

Mode changes can be scheduled (India time), are versioned and audited, never shorten or refund a running plan, and never shrink a live ride.

**Strategy note.** The competitor analysis recommends free hosting for small groups because every Indian group-ride app (including Trilyt) is free. *Free up to limits* implements this without code changes. **Chosen launch mode and limits: [OWNER TO FILL].**

---

## 4. Operators and clubs (B2B)

Types: Tour operator, Riding club, Rental fleet, Corporate fleet. Flow: apply on the website → master admin approves with limits, features and validity → operator console at `/operator`.

Default limits per type (editable templates; set per operator on approval):

| Limit | Tour operator | Riding club | Rental fleet | Corporate fleet |
|---|---|---|---|---|
| Roster size | 200 | 150 | 100 | 300 |
| Live rides at once | 3 | 2 | 5 | 5 |
| Rides per month | 30 | 12 | 60 | 40 |
| Riders per ride (lead included) | 30 | 40 | 12 | 25 |
| Co-organisers | 3 | 3 | 2 | 5 |
| Validity (days) | 365 | 365 | 365 | 365 |

Features (checkboxes): multi-group live dashboard, roster and emergency contacts during an SOS (audited), attendance, ride calendar and public sign-ups, broadcasts, CSV export.

**Pricing is not built into the operator flow** (approval sets limits, not a price; GST invoicing is out of scope in 3.56). Options from the release plan (decision D13): per bike per month, per tour, or per operator per year. Recommendation in the plan: per bike per month with a pilot discount. **Operator price list: [OWNER TO FILL].**

---

## 5. Partner perks and future revenue lines

| Line | What exists | Revenue model |
|---|---|---|
| Partner perks | Push kind "Partner perk" (3.56): opt-in, labelled, curated real-world perks only, never CoRoute plans or codes | **[OWNER TO FILL]**: listing fee or per redemption (partners on the map with offers is planned for v3.57) |
| Insurance safe-rider certificate | Planned (v3.57): rider-initiated signed score certificate for a partner insurer | **[OWNER TO FILL]**: referral or partnership fee, subject to IRDAI rules (CoRoute does not sell insurance) |
| Fleet safety | Planned (v3.57) | **[OWNER TO FILL]**: per rider or per bike per month |
| Paid club events | Planned (v3.57); needs marketplace payouts, organiser KYC, GST | **[OWNER TO FILL]**: platform fee per registration |

---

## 6. Unit economics framework

All inputs are placeholders. The same structure is in `financial_model_template.xlsx`.

### 6.1 Definitions and formulas

| Metric | Formula | Input source |
|---|---|---|
| **Monthly active riders (MAR)** | distinct riders with ≥ 1 completed ride in the month | admin analytics |
| **Hosts** | MAR × host share | admin analytics (rides with ≥ 2 riders, by owner) |
| **Paying hosts** | Hosts × host-to-paid conversion | web admin › Revenue (active paid plans) |
| **Plan ARPU (₹ / paying host / month)** | Σ (net plan revenue) ÷ paying hosts; with mix: p_small × price_small + p_large × price_large, adjusted for offers and coupons, × 30 ÷ billing days | web admin › Revenue, Coupons |
| **Operator ARPU** | operator revenue ÷ active operators | contracts **[OWNER TO FILL]** |
| **Revenue (month)** | paying hosts × plan ARPU + operators × operator ARPU + partner revenue | — |
| **Payment fees** | website revenue × payment-gateway fee % | Razorpay agreement **[OWNER TO FILL]** |
| **Variable cost per MAR** | (server SMS cost + e-mail cost + bandwidth / storage share) ÷ MAR | see 6.2 |
| **Gross margin** | (revenue − payment fees − infra − SMS − e-mail) ÷ revenue | — |
| **CAC (blended)** | marketing + sales spend ÷ new riders (or ÷ new paying hosts for paid CAC) | own spend |
| **Payback (months)** | paid CAC ÷ (plan ARPU × gross margin %) | — |
| **LTV (paying host)** | plan ARPU × gross margin % ÷ monthly paid churn | — |
| **Viral coefficient (k)** | invites sent per host × invite acceptance rate | analytics (joins per hosted ride) |

### 6.2 Infrastructure cost drivers

| Driver | What drives it | Unit cost | Notes |
|---|---|---|---|
| **OCI VMs** | Live riders at peak (WebSocket rooms, mirror) | **[OWNER TO FILL]** | Two Oracle Cloud VMs today (E2.1.Micro or A1.Flex class); capacity estimate 200–700 live riders until the soak test measures it. Step cost: add or resize VMs as peak live riders grow. |
| **Database** | Rides, tracks (deleted after 90 days), accounts | **[OWNER TO FILL]** | Oracle Autonomous Database. |
| **Object Storage** | Review photos, profile pictures, backups, APKs | **[OWNER TO FILL]** | |
| **Server SMS (SOS)** | SOS events × contacts texted (+ "safe now" texts) | **[OWNER TO FILL]** ₹ per SMS (MSG91 or Twilio; Indian DLT registration) | Cost guard in code: at most 5 contacts per SOS, 20 SOS texts per rider per India day (both admin-adjustable). Texts sent from the rider's own phone cost CoRoute nothing. Formula: SOS per month × avg contacts × (1 + share resolved "safe now") × ₹ per SMS. |
| **Push (FCM)** | Notifications | ₹0 per message | Firebase Cloud Messaging has no per-message charge. |
| **E-mail (SMTP)** | Purchase / refund receipts, operator decisions, opt-in offer campaigns | **[OWNER TO FILL]** per 1,000 e-mails | Any SMTP provider (e.g. Amazon SES, Zoho, Brevo). |
| **Payment gateway** | Website revenue | **[OWNER TO FILL]** % | Razorpay, website only. |
| **Maps / tiles / places** | Map display, routing, places | **[OWNER TO FILL]** | Places from OpenStreetMap data; check commercial terms of every tile, routing and weather provider (weather source decision D6). |
| **Store and accounts** | Google Play developer account, Apple developer account (iOS) | **[OWNER TO FILL]** | Fixed. |

### 6.3 Worked template (fill the blanks)

```
Inputs (month m)
  MAR                         = [OWNER TO FILL]
  host_share                  = [OWNER TO FILL]   # share of MAR who host >=1 group ride
  paid_conversion             = [OWNER TO FILL]   # share of hosts on a paid plan (0 in "Free for everyone")
  mix_small / mix_large       = [OWNER TO FILL]
  price_small / price_large   = [OWNER TO FILL]   # current default config 49 / 99 per 30 days
  avg_discount_pct            = [OWNER TO FILL]   # offers + coupons
  operators                   = [OWNER TO FILL]
  operator_arpu               = [OWNER TO FILL]
  sos_per_1000_mar            = [OWNER TO FILL]
  contacts_per_sos            = [OWNER TO FILL]   # <= 5 by code
  sms_unit_cost               = [OWNER TO FILL]
  infra_fixed                 = [OWNER TO FILL]

Outputs
  paying_hosts   = MAR * host_share * paid_conversion
  plan_arpu      = (mix_small*price_small + mix_large*price_large) * (1 - avg_discount_pct)
  revenue        = paying_hosts*plan_arpu + operators*operator_arpu
  sms_cost       = MAR/1000 * sos_per_1000_mar * contacts_per_sos * 2 * sms_unit_cost   # x2 = SOS + "safe now" (upper bound)
  gross_margin   = (revenue - revenue*payment_fee_pct - infra_fixed - sms_cost - email_cost) / revenue
```

---

## 7. Decisions the owner still has to make

| # | Decision | Where it is set |
|---|---|---|
| 1 | Launch access mode (Paid / Free for everyone / Free up to limits) and limits | Web admin › Plans & pricing › Access mode |
| 2 | Launch list prices and any launch offer | Web admin › Plans & pricing |
| 3 | Minimum payable price | Web admin › Plans & pricing (pricing rules) |
| 4 | Operator pricing model and price list (D13) | Contracts (not in code) |
| 5 | Partner perk commercial model | Contracts |
| 6 | Referral reward size and caps (D12) | Planned v3.56.x |
| 7 | SMS provider and per-SMS budget; SOS SMS caps | Admin settings / env |
