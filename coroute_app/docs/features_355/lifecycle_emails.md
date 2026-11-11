# Welcome and ride summary e-mails, e-mail categories (3.57)

Two e-mails that riders get from their own account activity:

- a **welcome e-mail** once per new account;
- a **ride summary** ("memory") e-mail after each ride they finish.

Riders now choose which e-mails they get, by **category**, on the website account page and with a link in
every e-mail. Receipts and refunds are unchanged ([purchase_email.md](purchase_email.md)). Offer e-mails
stay opt-in ([notifications_admin.md](notifications_admin.md), Offers e-mail).

E-mail is outside the Play app, so Play's in-app payment rules do not apply to it. A link to the website's
group plans is allowed in an e-mail. Marketing and transactional mail are still kept apart for consent
(India DPDP Act), see Categories below.

Code: `gateway/src/lifecycle_emails.js` (service, routers), `gateway/src/route_png.js` (route picture),
templates in `gateway/src/templates.js`. Test: `gateway/test/lifecycle_emails_357.test.js`.

## What existed before 3.57, and what was added

| E-mail | Before | 3.57 |
| --- | --- | --- |
| Purchase receipt, refund | yes (`purchase_email.js`) | unchanged; the retry job now picks receipt / refund rows only |
| Offer e-mails (plan offers, coupons) | yes, opt-in campaigns (`offer_emails.js`) | unchanged; also switchable from the new categories |
| Welcome e-mail | no | **new** |
| Ride summary e-mail | no | **new** |
| E-mail categories, per-category unsubscribe | offers only | **new**: Ride summaries, Tips and news |

## Categories

| Category | Default | What it covers | Turn off |
| --- | --- | --- | --- |
| Account and receipts | always on | receipts, refunds, the welcome e-mail's account part | cannot (transactional) |
| Ride summaries | on | the summary of the rider's own ride | `/account`, or the link in each summary |
| Tips and news | on | the welcome e-mail's "Group rides" block (plans link), occasional product news | `/account`, or the link in the welcome e-mail |
| Offers | **off** | plan offers and coupon codes (campaigns) | `/account`, or the link in each offer e-mail |

- Ride summaries are on by default: they are about the rider's own activity and carry no offer. Every
  one has a one-click opt-out.
- The welcome e-mail is transactional. Its "Group rides" block counts as light marketing, so it is
  included only while the rider keeps **Tips and news** on.
- Every change of a category is kept with its time and source (`website` or `unsubscribe`), the last 20
  changes per rider (collection `email_preferences`). Offers keep their own history in
  `marketing_consent`.

## Welcome e-mail

**When.** Once per account:

- after a password sign-up;
- after the first Google sign-in (the account is created then).

Signing in again, `GET /me` or a second Google sign-in never sends another one.

**How it is sent.**

- `auth.onUserReady` (with `created`) queues it in the background after the username exists. The
  registration request never waits for it and never fails because of it.
- The `mail_log` row `welcome:<userId>` (unique key) is inserted before sending.
- No SMTP, or no valid e-mail address on the account: nothing is queued.

**Content** (template **Welcome e-mail**, every field editable):

1. Greeting with the first name and `@username`.
2. Three quick steps:
   - add your emergency contact and Medical ID;
   - add your bike;
   - start a ride.
3. "Every safety feature is free" line.
4. Button to the quick start guide: `https://<PUBLIC_ORIGIN>/guide`. This is the new page `/guide`, made
   from `docs/handbook/users/quick_start.md`; keep the two in step.
5. **Group rides** block (only with Tips and news on). It follows the access mode
   ([access_modes.md](access_modes.md)):

   | Access mode | Block |
   | --- | --- |
   | Free for everyone (or payments off) | the free line ("Group rides are free right now ...") and no link |
   | Paid, or Free up to limits | the plans line and a "See group plans" button to `https://<PUBLIC_ORIGIN>/plans?utm_source=welcome` |

   **Welcome coupon:** with a welcome coupon set (see the admin section), the button opens
   `https://<PUBLIC_ORIGIN>/plans?coupon=CODE&utm_source=welcome`. The coupon is checked again when each
   e-mail is built. A coupon that has expired, been paused or used up is simply left out.
6. Footer:
   - support address;
   - "Unsubscribe from tips and news", only when the block is present;
   - "Manage e-mails" (`/account#emails`).

The headers `List-Unsubscribe` (the tips and news link) and `List-Unsubscribe-Post: List-Unsubscribe=One-Click`
are set.

## Ride summary e-mail

**When.** Once per rider per ride:

- `TimelineEngine.finishTrip` hands the finished report to `convoys.tripMemory.onTripFinished`. This is
  never awaited and never blocks the report.
- For each analysed rider with a trip document, a row `trip_memory:<groupId>:<userId>` is queued, due
  `TRIP_MEMORY_DELAY_MIN` minutes later (default 10). The delay lets late track uploads rebuild the
  report first.
- A later rebuild queues nothing new (the unique key).

**Rules, checked when queued and again when sent:**

- at least **2 km** and **10 minutes** (end time minus start time);
- the rider's own trip document only. A trip the rider deleted is skipped (`TRIP_GONE`);
- Ride summaries on (`OPTED_OUT` otherwise);
- an address that is valid and not hard-suppressed.

**Content** (template **Ride summary e-mail**):

- subject, for example "Your ride: Nandi Hills sunrise ride · 128 km";
- ride name, date (India), distance, riding time (moving time when known), stops, riders in the group,
  and the group or crew name when the ride has one;
- **no top speed or average speed**: speed is never celebrated;
- a route picture (below);
- a "View trip report" button to `https://<PUBLIC_ORIGIN>/trip/<tripId>?utm_source=ride_summary`;
- "Rate the places you stopped" line, with no incentive.

**Privacy:**

- Only the recipient's own trip document is read.
- No other rider's name, position or numbers (only the count of riders).
- No start or destination place names, and no coordinates in the text or HTML.
- The route picture:
  - is a PNG drawn on the server in pure JavaScript (`route_png.js`, node:zlib, no image library,
    because none is a dependency);
  - is the rider's own cleaned trail on a plain background with a start and an end marker;
  - has no map tiles, coordinates or names;
  - leaves the first and the last **300 m** off, so a home or work address is never shown;
  - is not made for a trail shorter than about 650 m, and never joins a signal gap with a drawn line;
  - is attached inline (`cid:`), never hosted at a URL.

**`/trip/<tripId>`** (the button):

- a small website page with strict CSP, `no-store` and `noindex`;
- it shows the ride's numbers (date, distance, riding time, stops, riders) to the **signed-in owner
  only**: it reads `GET /api/trips/:tripId`, which answers 404 for anyone else;
- without a session it goes to `/signin?next=/trip/<id>` first;
- the full report with the map stays in the app (Trips). Android App Links do not cover `/trip/` today,
  so the link opens the website.

## Sending, retries, idempotency

- The rows live in `mail_log`, the same collection and unique `key` index as the receipts. A row is
  inserted before anything is sent.
- **Claiming:** a QUEUED row is claimed with compare-and-replace (status SENDING plus a 2-minute lease)
  by the process that sends it. Two gateway nodes never send the same e-mail.
- **When:**
  - the welcome goes right away, in the background;
  - the leased job `lifecycle-mail` (every minute, one node) sends what is due and retries.
- **Rate:** batches at `LIFECYCLE_EMAIL_RATE` e-mails per second (default 5).
- **Retries:** a failed SMTP send becomes RETRY and is tried again after 5 min × attempts, 3 tries in
  all, then FAILED.
- **Skips:** a skip is stored as SKIPPED with its reason, for example `OPTED_OUT`, `TRIP_GONE`,
  `SUPPRESSED`, `TOO_SHORT`, `USER_GONE`, `NO_EMAIL`.
- **Logs:** the row keeps a masked address (`a***@example.com`), the message id or the error code. Logs
  never carry addresses or bodies.
- **Suppression** (`email_suppression`, admin Notifications):
  - an address suppressed for a **bounce**, a **complaint** or by an **admin** gets no lifecycle e-mail;
  - an **unsubscribe** entry (written by the offers unsubscribe) stops offer e-mails only.
- **SMTP not configured:** nothing is queued or sent (`mailer.enabled` is false).
- **Tests:** a fake transport (`createApp({ mailTransport })`). The test files of other features ignore
  `X-CoRoute-Mail: welcome`.
- **Account erase** removes the rider's `email_preferences` row and their welcome / ride summary
  `mail_log` rows. The suppression hash stays.

## Unsubscribe links

`https://<PUBLIC_ORIGIN>/email/unsubscribe?u=<userId>&c=<ride_summaries|tips_news>&t=<HMAC>`

- The token is an HMAC-SHA256 of the category and the user id, with the server secret
  (`JWT_SECRET:lifecycle`). It has no expiry, so an old e-mail's link keeps working. A token for one
  category does not work for another.
- **GET** shows a page with one "Unsubscribe" button. Link scanners never unsubscribe anyone.
- **POST** (the button, or a mail client's RFC 8058 one-click) turns that category off.
- A link without `c` (or `c=offers`) is the existing offers link, handled by `offer_emails.js`.

## Endpoints

| Method and path | Who | What |
| --- | --- | --- |
| `GET /api/web/email-preferences` | rider | `{categories: {account, rideSummaries, tipsNews, offers}, locked: ['account'], hasEmail, suppressed}` |
| `PUT /api/web/email-preferences` | rider | any of `{rideSummaries, tipsNews, offers}` (booleans). `account` is refused (400). Offers go through the existing consent. |
| `GET` / `POST /email/unsubscribe?u&c&t` | public, signed | per-category unsubscribe (above) |
| `GET /api/admin/email/lifecycle/settings` | admin | welcome coupon, SMTP on/off, rate, delay, thresholds |
| `PUT /api/admin/email/lifecycle/settings` | admin | `{welcomeCoupon}`: '' clears it. The code must exist, be ACTIVE and be public (no rider list). Audited. |
| `POST /api/admin/templates/:id/preview` | admin | for `welcome` / `trip_memory` also `mail: {subject, html, text}`: the whole e-mail with a sample rider and route |
| `GET /guide` | public | quick start guide page |
| `GET /trip/:tripId` | page | the owner's ride summary page (data through `GET /api/trips/:tripId`) |

## Web admin

**Templates** has two new entries:

- **Welcome e-mail**: subject, heading, intro, three steps, safety line, guide line, the two group ride
  lines, footer. Variables: `name`, `username`, `guideUrl`, `accountUrl`, `supportEmail`.
- **Ride summary e-mail**: subject, heading, intro, rate line, footer. Variables: `name`, `rideName`,
  `distance`, `ridingTime`, `date`, `stops`, `riders`, `groupName`, `reportUrl`.

Both work like the other templates:

- unknown variables are refused;
- every save is a new version (the last 20 are kept);
- History and Reset to default;
- the preview shows the whole e-mail as text, with a "Download HTML preview".

The Welcome e-mail page also has the **Welcome coupon code** setting.

## Environment

| Variable | Default | What |
| --- | --- | --- |
| `SMTP_*`, `MAIL_FROM`, `MAIL_REPLY_TO` | unset = e-mail off | as for receipts ([purchase_email.md](purchase_email.md)); never in the repo |
| `PUBLIC_ORIGIN` | | the links in the e-mails |
| `SUPPORT_EMAIL` | | shown in the welcome e-mail (else the website contact form) |
| `TRIP_MEMORY_DELAY_MIN` | 10 | minutes between the trip report and the ride summary |
| `LIFECYCLE_EMAIL_RATE` | 5 | e-mails per second for the job |

## Deliverability (owner)

Check spam placement before launch:

- SPF, DKIM and DMARC on the sending domain;
- a Gmail and an Outlook test inbox;
- `List-Unsubscribe` shown by Gmail.

The welcome e-mail goes out right after a sign-up. Watch the provider's bounce and complaint numbers in
the first days, and add bounced or complaining addresses to the suppression list (admin Notifications).

## QA checklist

1. Register a new account (password) and sign in with a new Google account: one welcome e-mail each.
2. Check the plans block in each access mode: Paid and Free up to limits show the button, Free for
   everyone shows the free line. Set a welcome coupon and check the link.
3. Finish a ride of 2 km and 10 minutes or more. About 10 minutes after the report, the ride summary
   arrives: route picture without the first and last 300 m, no speeds, "View trip report" opens
   `/trip/<id>` (sign in as the rider).
4. Open the unsubscribe link: a page with a button only. Press it: the category is off on `/account`.
   Use Gmail's "Unsubscribe" (one-click): the same.
5. Suppress the address as a bounce: no ride summary.
