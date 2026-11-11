# Admin push notifications and message templates (3.56)

The web admin (`/admin`) has two new sections:

- **Notifications**: compose and send "News and updates" pushes, see the history with delivery
  counts, and set up the server SOS SMS (see [sos_sms.md](sos_sms.md)).
- **Templates**: edit the words of the receipt and refund e-mails, the SOS SMS, the plan push
  notices and the guardian arrival message.

Related: [push_notifications.md](push_notifications.md) (the FCM pipeline),
[purchase_email.md](purchase_email.md), [sos_sms.md](sos_sms.md),
[play_payments_policy.md](play_payments_policy.md).

## 3.57 E-mail studio (extends the Offers e-mail)

The Notifications tab **Offers e-mail** is now **E-mail studio** (`public/admin/email_studio.js`,
`src/email_marketing.js`): customised marketing e-mails with coupons built from templates (8 starters,
saved and versioned templates), a block editor (header image, heading, rich text, coupon, price, button,
image, divider, footer always last) with a live preview (desktop / mobile, light / dark, plain text),
variables (`{firstName}` ... `{link}`, unknown ones refused), audiences (opted-in riders, joined / no ride /
never hosted / plan ending / plan ended / crew admins / operators / usernames), single-use unique coupon
codes per rider, send now / schedule / automation rules, a weekly cap (default 2), quiet hours (21:00 to
09:00 IST), signed click links `/r/<token>` (no open pixels; can be switched off) and a report per
campaign (sent, failed, unsubscribed, clicks, coupon redemptions). "Plan ending soon" without a coupon or
price can be an account notice (plan segments only); anything with a coupon or price is marketing and
needs the Offers consent. Every marketing e-mail carries the unsubscribe link, the sender and the postal
address (`MAIL_POSTAL_ADDRESS`, needed for real sends). The 3.56 composer's campaigns and the suppression
list are under **E-mail studio > Settings**; the 3.56 `/api/admin/email/offers/*` endpoints still work.
Full description: [email_marketing.md](email_marketing.md).

## 3.56 push kinds, and Offers e-mail for prices and coupons

The composer first asks for a **Channel**:

* **Push notification**: one of the kinds below. The Play policy guard applies.
* **E-mail (Offers)**: plan offers, prices and coupon codes. These are never allowed in a push. The
  composer's banner explains why: the Google Play payments policy forbids prices, coupons and offers
  in the app and its notifications, and the ads policy forbids third-party ads in notifications.

### Push kinds

Each kind has its own Android channel and its own switch in the app (**Settings > App & privacy**).
The FCM type stays `NEWS`, and the data carries `kind` and `channel`. An older app shows every kind as
"News and updates".

| Kind | Android channel | App switch (`/api/me/push-prefs` field) | Default | Guard |
| --- | --- | --- | --- | --- |
| Update | `coroute_news` "News and updates" | News and updates (`news`) | on | strict (below) |
| Event | `coroute_events` "Events" | Events (`events`) | on | strict |
| Safety tip | `coroute_safety_tips` "Safety tips" | Safety tips (`safetyTips`) | on | strict |
| Community | `coroute_community` "Community" (low importance) | Community (`community`) | on | strict |
| Partner perk | `coroute_partner_perks` "Partner perks" (low importance) | Partner perks (`partnerPerks`) | **off** | partner perk guard |

* Every kind can have a big picture.
* Safety alerts, ride, social and plan pushes are not campaign kinds and can never be turned off
  (`PUT /api/me/push-prefs {safety:false}` returns `400 SAFETY_ALWAYS_ON`).
* The server skips a rider whose switch is off. Android also drops such a push, in the foreground too
  (`PushConfig.isKindEnabled`).
* `GET /api/me/push-prefs` returns `{news, events, safetyTips, community, partnerPerks, safety: true}`.
  `PUT` takes any subset of these booleans; any other key is `400 BAD_PREF`.

**Partner perk** is a real-world perk at a partner business that CoRoute curated for riders, for
example "10% off a chain service at Speed Garage for CoRoute riders".

* The admin must name the partner (2 to 60 characters) and tick "CoRoute curated this perk"
  (`curated: true`, else `PERK_NOT_CONFIRMED`).
* The phone labels it **"Partner perk · <partner>"** (notification sub-text, foreground snackbar).
* It goes only to riders who turned Partner perks on, at most **one per rider per 7 days** (on top of
  the daily cap).
* Guard (`policy_terms.js` `partnerPerkTermIn`):
  * allowed here only: "% off", "offer", "deal", "discount", "sale";
  * still refused: every money or buying word (₹ / Rs amounts, price, buy, pay, checkout,
    subscription, ...), coupon, promo code, voucher, "code", any mention of CoRoute plans or
    membership, and any link or domain.
  * Refused with `422 PLAY_POLICY` and a message that points to the Offers e-mail.

### Offers e-mail (Channel "E-mail (Offers)")

Prices, coupons and offers for CoRoute plans go here, **only to riders who opted in**.

* **Consent** (India DPDP Act friendly): **off by default**.
  * The rider turns "Send me offer e-mails" on or off on the website account page (`/account`,
    `GET/PUT /api/web/marketing-consent {offersEmail}`).
  * Every change is kept with its time and source (collection `marketing_consent`, last 20 changes).
  * The consent row is erased with the account.
* **Unsubscribe**:
  * Every e-mail carries a link `/email/unsubscribe?u=<userId>&t=<HMAC>` (no expiry), plus the
    `List-Unsubscribe` and `List-Unsubscribe-Post: List-Unsubscribe=One-Click` headers (RFC 8058).
  * The link's GET shows one "Unsubscribe" button, so link scanners never unsubscribe anyone. The POST
    (the button, or a mail client's one-click) turns consent off and adds the address to the
    suppression list.
* **Suppression list** (collection `email_suppression`):
  * Stored as the SHA-256 of the lower-cased address; the admin sees it masked.
  * Reasons: `unsubscribe`, `bounce`, `complaint`, `admin`.
  * A suppressed address is never mailed, and it is checked again at send time.
  * Turning consent on again lifts only the rider's own `unsubscribe` entry.
  * The admin can add or remove entries. An erased account's entry stays, so the address is not
    mailed again.
* **Composer** (Notifications > Offers e-mail):
  * Subject (at most 120), heading (at most 120), content (at most 5000).
  * The content is plain text with a small markup: blank line = paragraph, `- ` = bullet, `**bold**`,
    `[label](/path)`. Links may only point to this site; everything else is escaped.
  * Optional image (the push image store) and an optional **coupon block**: code (must exist in
    Coupons and still be usable), headline and note. Its button opens **`/plans?coupon=CODE`**.
    Without a coupon the button opens `/plans`.
  * Audience: every opted-in rider, opted-in and active in the last N days, or opted-in by plan type.
  * Now, or scheduled in India time (at most 60 days ahead).
  * The server renders the preview: the text version on screen, the exact HTML as a download. The
    admin console's CSP allows no frames.
  * **Send test to me** goes to the admin's account e-mail; consent and suppression do not apply to it.
* **Sending**:
  * The leased job `offer-emails` runs every 60 s on one node, with a compare-and-replace lease.
  * It sends at `OFFER_EMAIL_RATE` e-mails per second (default 5) through the receipt mailer
    (`mailer.js`, `SMTP_*` / `MAIL_FROM`).
  * Consent and suppression are re-checked for every rider at send time.
  * Stats per campaign: targeted, sent, skipped, failed.
  * Without SMTP the campaign fails with a clear reason.

| Method and path | What |
| --- | --- |
| `GET /api/admin/email/config` | mail ready, origin, rate, limits |
| `POST /api/admin/email/offers/check` / `preview` | validate / `{subject, html, text, ctaUrl}` |
| `POST /api/admin/email/offers/audience-count` | `{audience}` -> `{riders}` (opted in, valid, not suppressed) |
| `POST /api/admin/email/offers/test` | to the admin's own e-mail |
| `POST /api/admin/email/offers/campaigns` | create (now or `sendAt`) |
| `GET /api/admin/email/offers/campaigns[/:id]`, `POST .../:id/cancel` | history; cancel a scheduled one |
| `GET/POST /api/admin/email/suppression`, `DELETE /api/admin/email/suppression/:hash` | the suppression list |
| `GET/PUT /api/web/marketing-consent` | rider (website), `{offersEmail}` |
| `GET/POST /email/unsubscribe?u=&t=` | public, HMAC token |

Tests: `gateway/test/push_kinds_offers_email_356.test.js`.

## Notifications > Compose push

| Field | Rule |
| --- | --- |
| Title | 1 to 65 characters, one line |
| Message | 1 to 240 characters |
| Big picture | Optional. JPEG, PNG or WebP, at most 1 MB. Recognised by its bytes. EXIF, GPS, XMP and PNG text are removed by the review photo pipeline (`review_photos.preparePhoto`). Stored with a random name and served at `https://<PUBLIC_ORIGIN>/media/push/pi_<id>.<ext>`. Needs an https `PUBLIC_ORIGIN`. |
| Opens | A fixed list: Home, Friends and people, Crews, Ride history, Settings. There is no plans, offers or in-app updates target. |
| Audience | All riders with the app, riders active in the last N days (1 to 365), plan type (Community, Small Group, Large Group; active owners of a plan), a list of up to 200 usernames, or **Send test to me** (the admin's own phones). |
| When | Now, or a date and time in India time (at most 60 days ahead). |

- The preview shows an Android-style card in the light and the dark theme.
- **Count riders** shows how many riders the audience reaches and how many turned News off.
- The title and message are checked as you type (`POST /api/admin/push/check`).

### Play policy guard

Pushes reach the Google Play app, which must not show prices, coupons, discounts, offers, buying
or upgrade words, or links to the plans page. The server refuses such a push with HTTP 422
`PLAY_POLICY` and this message: *"This push mentions "coupon". ... Put offers on the website board
or in an e-mail instead."*

- The terms are in `gateway/src/policy_terms.js`. They include every term of
  `tool/play_policy_scan.dart` (a test reads the Dart file, so the lists cannot drift), plus
  `pay`, `paid`, `offer(s)`, `sale`, `% off`, `deal(s)`, `cashback`, `free trial`, `subscribe`,
  `subscription`, `offer code`, `plans page`, `/mo`, `Rs 99` and links to `/plans`,
  `/checkout`, `/get?coupon`, `/receipt`.
- Links of any kind are refused (`NO_LINKS`). A push opens an app screen, not a URL.
- An e-mail address or phone number in the text is refused (`PERSONAL_DATA`).
- The test send is guarded too.

### Delivery

- Message: an FCM data message of type `NEWS` with `title`, `body`, `imageUrl` (only an https
  `/media/push/pi_<24 hex>.<jpg|png|webp>` URL passes `push.js`), `target` (one of the fixed
  list), `campaignId` and `eventId`. The collapse key is one per campaign.
- Riders can turn off **Settings > App & privacy > News and updates** in the app
  (`PUT /api/me/push-prefs {news:false}`). The server skips them, and Android drops a NEWS push
  while the switch is off. 3.56: each push kind has its own switch (see Push kinds above). Safety, ride, social and plan pushes are not in this category and
  cannot be turned off there.
- Frequency cap: at most **2** campaign pushes per rider per India day
  (`PUSH_NEWS_DAILY_CAP`; collection `push_news_caps`). A test send ignores the cap and the
  opt-out.
- Scheduling: the leased job `push-campaigns` runs every 30 s on one node.
  - It claims a due campaign with a compare-and-replace lease (2 min, renewed after every
    batch). A crashed worker's campaign is taken over when the lease ends and resumes at its
    cursor.
  - It resolves the audience once, then sends in batches of 100 riders at
    `PUSH_CAMPAIGN_RATE` tokens per second (default 50; FCM allows far more).
  - The FCM sender retries 429 / 5xx with backoff (`push.js`).
- The campaign fails with a clear reason when FCM is not configured or the admin switch "Push
  notifications" is off.

### Android

`CoRouteMessagingService.kt` handles `NEWS` like this:

- It posts on the channel **"News and updates"** (`coroute_news`). Riders can also mute this
  channel in Android settings.
- With `imageUrl`, it shows `BigPictureStyle`. The image download is https only, with no
  redirects, 5 s connect / read timeouts, an 8 s deadline and at most 1 MB. It is decoded
  downscaled to at most about 2048 px. On any problem it falls back to the text notification.
- The tap opens the `target` screen (`push_routing.dart` `newsTargets`, anything else opens
  Home). In the foreground the push is a snackbar with "View".

## Notifications > History

The table lists every campaign, including test sends. Columns:

| Column | Meaning |
| --- | --- |
| Riders | Riders in the audience (with a push token) |
| Reached | Riders with at least one device sent |
| Sent | Devices sent |
| Failed | Device sends that failed (not counting invalid tokens) |
| Invalid tokens | Tokens FCM called UNREGISTERED / INVALID_ARGUMENT. They are deleted. |
| News off | Riders skipped because they turned News off |
| Capped | Riders skipped by the daily cap |

A scheduled campaign can be cancelled until it starts.

## Templates

| Template | Channel | Variables |
| --- | --- | --- |
| Purchase receipt e-mail | e-mail | name, plan, period, amount, orderId, paymentId, date, receiptUrl, supportEmail |
| Refund e-mail | e-mail | name, plan, amount, orderId, paymentId, refundId, date, receiptUrl, supportEmail |
| Welcome e-mail (3.57) | e-mail | name, username, guideUrl, accountUrl, supportEmail ([lifecycle_emails.md](lifecycle_emails.md)) |
| Ride summary e-mail (3.57) | e-mail | name, rideName, distance, ridingTime, date, stops, riders, groupName, reportUrl |
| SOS SMS (DLT) | SMS | name, token, lat, lng, time; `{{origin}}` = the site address (fixed) |
| SOS safe-now SMS (DLT) | SMS | name, time |
| Push: plan active | push | plan |
| Push: plan ending | push | date |
| Guardian: arrived safely | browser push | none |

- Placeholders are `{{variable}}`. Each template's variable list is fixed: an unknown variable
  (a typo such as `{{nmae}}`) or a stray `{ }` is refused.
- **E-mail**: the subject, heading, intro and footer are editable. The layout and the payment
  lines are built by the server, and every value is HTML-escaped.
- **Welcome and ride summary e-mails** (3.57) have more word fields (steps, safety line, group ride
  lines; rate line). Their preview also returns the whole e-mail as sent (sample rider, facts, route
  picture) with a "Download HTML preview". The Welcome e-mail page has the **Welcome coupon code**
  setting (an active public coupon, or none).
- **DLT SMS**: the variables and their order must stay exactly as registered. Each value is cut
  to 30 characters (the DLT `{#var#}` limit). Saving a changed text shows a warning that the new
  text must be registered first (and its template id set in Notifications > SMS). Non-GSM
  characters produce a warning (70 characters per part).
- **Push templates** go through the same Play policy guard as admin pushes.
  - `push.js` uses them for `SUBSCRIPTION_ACTIVATED` / `SUBSCRIPTION_EXPIRING` through
    `setPlanTextProvider`, from a cached copy refreshed every minute and after each save.
  - An answer with a forbidden word falls back to the built-in text.
- Versions: collection `message_templates` keeps the current fields and the last 20 versions.
  - **History** can load an older version into the editor.
  - **Reset to default** stores the defaults as a new version.
  - Every save and reset writes an admin audit entry.
- Preview: the rendered text with sample values. The SMS preview shows the character and part
  count.

## Endpoints

All `/api/admin/*` endpoints are MASTER_ADMIN only (`requireAuth` + `requireAdmin`).

| Method and path | What |
| --- | --- |
| `GET /api/admin/push/config` | FCM ready, targets, plan types, daily cap, limits, images allowed |
| `POST /api/admin/push/images` | raw image bytes (Content-Type image/*) -> `{image: {imageId, url, bytes, width, height}}` |
| `POST /api/admin/push/check` | `{title, body, target}` -> ok, or 400 / 422 with the reason |
| `POST /api/admin/push/audience-count` | `{audience}` -> `{riders, optedOut}` |
| `POST /api/admin/push/test` | campaign fields -> sends to the admin's phones, `{result}` |
| `POST /api/admin/push/campaigns` | `{title, body, target, imageId?, audience, sendAt?}` -> 201 `{campaign}` |
| `GET /api/admin/push/campaigns[?limit]`, `GET /api/admin/push/campaigns/:id` | history |
| `POST /api/admin/push/campaigns/:id/cancel` | scheduled only |
| `GET /api/admin/templates` | all templates (current, defaults, variables, version) |
| `POST /api/admin/templates/:id/preview` | `{fields?}` -> `{rendered, errors, warnings}` |
| `PUT /api/admin/templates/:id` | `{fields}` -> `{version, warnings}` (400 with the errors) |
| `POST /api/admin/templates/:id/reset` | defaults as a new version |
| `GET /api/admin/templates/:id/history` | the last 20 versions |
| `GET` / `PUT /api/admin/email/lifecycle/settings` | 3.57 welcome coupon (`{welcomeCoupon}`), e-mail job settings |
| `GET` / `PUT /api/me/push-prefs` | rider: `{news}` (safety pushes always on) |
| `GET /media/push/:file` | public image (cached 30 days, nosniff, `default-src 'none'`) |
| `/api/admin/email/studio/*` | 3.57 E-mail studio: templates, preview, test, campaigns, rules, settings, unique codes, image library ([email_marketing.md](email_marketing.md)) |
| `GET /r/:token`, `GET /email/preview/:token` | 3.57 signed click redirect; the studio's sandboxed preview frame (public) |

## Environment

| Variable | Default | What |
| --- | --- | --- |
| `FCM_SERVICE_ACCOUNT_JSON` / `FCM_SERVICE_ACCOUNT_FILE`, `FCM_PROJECT_ID` | none | FCM sender ([push_notifications.md](push_notifications.md)) |
| `PUBLIC_ORIGIN` | none | Must be https for push images |
| `PUSH_IMAGE_DIR` | `<data>/push-images` (next to `REVIEW_PHOTO_DIR`) | Disk store for images. With `REVIEW_PHOTO_STORE=par` the images go to the bucket under `push-images/`. |
| `PUSH_CAMPAIGN_RATE` | 50 | Tokens per second |
| `PUSH_NEWS_DAILY_CAP` | 2 | Campaign pushes per rider per India day |
| `MAIL_POSTAL_ADDRESS` | none | 3.57: postal address in every marketing e-mail footer; real campaigns and rules need it **[OWNER TO FILL]** |
| `OFFER_EMAIL_RATE` | 5 | Offers / E-mail studio e-mails per second |

## Files

- Gateway:
  - `src/push_campaigns.js`, `src/policy_terms.js`, `src/templates.js`
  - `src/notifications.js` (wiring, jobs)
  - `src/push.js` (NEWS type, imageUrl / target, body 240, pruned count, plan text provider)
- Web admin: `public/admin/notify.js`, `public/admin/templates.js`, `public/admin/notify.css`
- App:
  - `lib/domain/notify/push_routing.dart`, `lib/presentation/widgets/push_router_host.dart`
  - `lib/data/services/push_service.dart` (`newsEnabled`)
  - Settings row "News and updates"
- Android: `CoRouteMessagingService.kt`, `PushChannel.kt` (`setNewsEnabled`)
- Tests: `gateway/test/push_campaigns_355.test.js`, `test/sos_sms_text_356_test.dart` (NEWS routing)
