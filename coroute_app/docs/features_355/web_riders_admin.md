# Riders in the web admin (3.57 round 3)

Owner request: "In the website admin, show the riders and assign a plan or allocate a coupon for that one person,
and send them a mail about it." The app admin console had a riders list; the browser console at `/admin` now has
one too (menu **Riders**), with a rider page and three actions an admin takes for one person.

Website / gateway only. Nothing here reaches the Play app as text: a plan given here shows in the app exactly like
the app console's "Change plan" (the app re-reads its plan on `SUBSCRIPTION_ACTIVATED`), and coupons and offer
e-mails stay on the website and in e-mail (Play payments policy, [play_payments_policy.md](play_payments_policy.md)).

Code: `gateway/src/admin_riders.js` (service + routers), `gateway/public/admin/riders.js` (pages and dialogs),
`gateway/public/admin/email_wizard.js` (the "Send e-mail" step). Test: `gateway/test/web_admin_riders_357.test.js`.
Smoke + screenshots: `node tool/web_console_smoke.js <dir>`.

## Riders list (`#/riders`)

| Part | What |
|---|---|
| Search | username (with or without `@`), name, e-mail, or an exact user id |
| Filters | plan (any / any paid / Small Group / Large Group / Community), access status (Active / On hold / Blocked), joined from / to (India dates), last ride (7 / 30 / 90 days, no ride for 30+ / 90+ days, never), role (operator or club owner, crew admin, CoRoute admin), emergency contact (has / has not), include staff |
| Sort | last active (default), newest, most rides, name, plan ends soonest |
| Columns | avatar, @username + e-mail, name, plan + ends on, rides, last active, joined, chips (on hold, operator, crew admin, no emergency contact, staff) |
| Pages | 25 per page, Previous / Next |

Staff accounts (admins, `STAFF_EMAILS`) are hidden unless "Include staff" is ticked. The list never carries a phone
number, medical data or the emergency contact's number (only "has an emergency contact": yes / no).

## Rider page (`#/riders/<userId>`)

* **Header**: avatar, @username, name, e-mail, plan, access status, operator / crew admin / admin chips, emergency
  contact set or missing, joined and last active. Buttons: **Assign plan**, **Give a coupon**, **Send e-mail**, **More**
  (Suspend / restore access, Remove profile picture, Ask the app for logs, Payments for refunds).
* **Plan and payments**: the plan as the app shows it (`planView`), ends on, seats; every order (paid, given by an
  admin with who and why, refunded amount, coupon) with "Copy id".
* **Coupons**: personal codes given to the rider (personal, direct e-mail, e-mail campaign) with status and end date;
  coupons the rider used.
* **E-mail choices** (read-only): account and receipts, ride summaries, tips and news, Offers consent (with date),
  blocked address (unsubscribed / bounce / complaint / admin); the e-mails admins sent to this rider.
* **Rides**: count, distance, last ride, the 8 most recent rides (date, name, km, time, group / solo).
* **Diagnostics**: log uploads of the last 30 days with Download; "Ask for logs".
* **Admin actions on this rider**: the audit trail (`target = userId`), newest first.

No medical ID, blood group, allergies, notes or emergency contact number are read or returned.

## Actions

Each action is a short dialog with a plain summary, a live e-mail preview (the real renderer, in the sandboxed
preview frame), a required **reason** (kept in the audit log) and a request id (a double click never does it twice).

### Assign plan

Plan (Small Group, Large Group, or Community = end the plan now), duration (days, or until an India date), reason,
"Send e-mail to rider" (on by default).

* Uses the existing admin grant (`admin_plans.assignPlan`, the app console's "Change plan"): a ₹0 ledger order
  (`mode: manual`, `method: ADMIN`, `grantedBy`, `reason`), the membership activated from it, any legacy tier ended,
  effective at once. The same plan again adds the days to the time left. Seat conflicts answer 409.
* Audit: `rider.assign_plan` (plan, days, reason, order id, valid until) plus the grant's own `subscription.grant`.
* E-mail: the **Plan assigned** template (Settings > Templates; subject, heading, message, button text, footer, with
  `{{name}} {{username}} {{plan}} {{validUntil}}`), laid out by the e-mail studio renderer with a "See your account"
  button to `/account`. An account (transactional) e-mail: no offer consent needed, a bounced / reported / admin-blocked
  address is skipped. Sent once per grant (`mail_log` key `direct:plan_assigned:<orderId>`). Audit `rider.email`.

### Give a personal coupon

From an existing coupon (an active coupon for everyone) or a quick one (percent 1 to 100 or amount ₹1 to ₹100000,
any group plan or one plan), valid 1 to 90 days, reason, optional e-mail.

* The code is a single-use child made by the e-mail studio's unique codes (`EmailStudio.issueUniqueCode`):
  `<PARENT LETTERS>-<8 random>` (e.g. `DIWALI-QHR95Q2X`; quick coupons `GIFT-…`), the parent's discount, plans and
  rules, 1 use in total, 1 per rider, **only this rider** (`allowedUserIds`), ending at the sooner of the parent's end
  and N days. A quick coupon has the pseudo parent `PERSONAL` (no public coupon is created). Redeemed on
  `/plans?coupon=CODE` with the usual atomic reservation; anyone else gets the coupon refused.
* Audit: `rider.coupon` (code, parent, discount, valid until, reason, e-mail, service note).
* The result dialog shows the code with **Copy code**, the `/plans?coupon=CODE` link with **Copy link**, and whether
  the e-mail went.

**Consent rule for the coupon e-mail** (a coupon is marketing; India DPDP Act):

| Rider | E-mail |
|---|---|
| agreed to offer e-mails, address not blocked | sent as an offer e-mail (unsubscribe link and headers, postal address) |
| no Offers consent | **not sent** unless the admin ticks **"Service message: the rider asked for it"** and writes a note (audited as `rider.email.service`); otherwise the code is shown to copy and share by hand |
| unsubscribed from offers | only as a noted service message |
| bounce / complaint / admin suppression | never sent; share the code by hand |

The code is made either way; the answer says `email: { sent: false, code: 'NO_CONSENT' | 'NOTE_REQUIRED' | 'SUPPRESSED' }`.

### Send an e-mail

"Send e-mail" opens the E-mail wizard for this rider (`#/email/rider/<userId>`): pick a template (Plan assigned,
Coupon for you, Welcome, the ready-made ones, saved templates) or write a quick message (subject, text with
`**bold**`, `*italic*`, `[label](/path)` links to this site only, optional button), check, send. See
[email_marketing.md](email_marketing.md), "The wizard".

* Classification shown clearly: **About their account** (transactional: no consent, no coupon or price allowed) or
  **Offer or news** (marketing: Offers consent, or a noted service message). A coupon or price block always makes it
  an offer e-mail.
* Suppression respected (transactional: hard suppression only; marketing: any).
* "Make a personal single-use code for this rider" turns the coupon block into a code only they can use.
* Sent at once (a 1:1 message: no quiet hours, not counted in the weekly cap), idempotent per request id, audited
  `rider.email` (template, subject, category, classification, service note).

### Other quick actions (More)

Already available APIs, linked from the page: suspend / restore (`PATCH /api/admin/users/:userId/config`), remove
picture (`DELETE /api/admin/users/:userId/avatar`), ask for logs (`POST /api/admin/diag-logs/request`), refunds on the
Payments page.

## Endpoints (all `requireAuth` + `requireAdmin` = MASTER_ADMIN unless noted)

| Method | Path | What | Limit |
|---|---|---|---|
| GET | `/api/admin/riders?q=&plan=&status=&joinedFrom=&joinedTo=&lastRide=&role=&emergency=&staff=&sort=&dir=&page=&limit=` | list (`riders[]`, `total`, `page`, `pages`) | 120/min/admin |
| GET | `/api/admin/riders/:userId` | rider page data | 120/min |
| POST | `/api/admin/riders/:userId/preview` | `{ system: plan_assigned \| coupon_gift \| welcome, planName, planEndsOn, coupon }` or `{ design, category, uniqueCoupon, service, serviceNote }` -> `{ subject, previewUrl, darkPreviewUrl, text, check }` | 120/min |
| POST | `/api/admin/riders/:userId/email/check` | `{ category, service, serviceNote }` -> `{ check: { classification, offersConsent, suppressed, allowed, code, reason } }` | 120/min |
| POST | `/api/admin/riders/:userId/assign-plan` | `{ plan, days \| until, reason, sendEmail, requestId }` | 30/min |
| POST | `/api/admin/riders/:userId/coupon` | `{ parentCode \| quick: { discountType, discountValue, plans }, validDays, reason, sendEmail, service, serviceNote, requestId }` (201) | 30/min |
| POST | `/api/admin/riders/:userId/email` | `{ design, category, templateId, uniqueCoupon, service, serviceNote, requestId }` | 30/min |
| GET | `/api/admin/email-wizard/templates` | the system designs (Welcome, Plan assigned, Coupon for you) built from the editable words | 60/min |
| GET | `/api/admin/search?q=` | global search: riders (username / e-mail / name), orders (order or payment id), coupon codes | 120/min |
| GET | `/api/me/coupons` | **rider**: my personal codes (`code, discount, validUntil, state, plans, plansPath`) | 30/min/rider |

Errors: `{ error, code }` with `REASON_REQUIRED`, `BAD_PLAN`, `BAD_DAYS`, `BAD_COUPON`, `NOT_FOUND`, `NO_CONSENT`,
`NOTE_REQUIRED`, `SUPPRESSED`, `NO_ADDRESS`, `NO_POSTAL_ADDRESS` (offer e-mails), `MAIL_OFF`, `CAPACITY_CONFLICT`.

## Data

No new collection. Plans: the existing ledger order + `memberships`. Codes: `coupons` (child, `parentCode`,
`allowedUserIds`) + `email_coupon_codes` (`campaignId: gift_<hash>` or `dm_<hash>`). E-mails: `mail_log` rows with
`kind: 'direct'` (removed with the account). Audit: `subscription_config k='audit'`, `target = userId`.

## QA

1. `/admin` > Riders: search a username, filter "No emergency contact", open a rider.
2. Assign plan > Small Group, 30 days, reason, e-mail on > the preview shows the plan and end date > Assign. The rider's
   app shows Small Group; one e-mail arrives; the audit trail shows "Plan assigned".
3. Give a coupon > an active coupon, rider without offer consent: the e-mail is off with the explanation; tick
   "service message" + note > the e-mail goes; or untick and copy the code. Redeem it on `/plans?coupon=CODE` as that
   rider (works once); as another rider it is refused. `/account` > Your coupons lists it.
4. Send e-mail > Write a quick message (About their account) > Check: no consent needed > Send. With the address on the
   suppression list (bounce) the check shows "stopped" and Send stays off.
