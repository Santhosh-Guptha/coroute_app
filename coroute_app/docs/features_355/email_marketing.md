# E-mail marketing studio (3.57)

Customised marketing e-mails with coupons, built from templates, in the web admin. **3.57 round 3:** one menu item
**E-mail** (`#/email`) with a 3-step wizard used for one rider, several riders or an audience, and the tabs
**History**, **Automations**, **Templates** and **Settings** (see "The wizard" below). The old entry points
(Notifications > E-mail studio, the 3.56 Offers e-mail tab, the push composer's e-mail channel) are gone; their links
(`#/notifications/email/...`) redirect to the new tabs. It extends the 3.56 Offers e-mail
([notifications_admin.md](notifications_admin.md)): the same consent switch, suppression list, signed unsubscribe link
and leased sending job.

E-mail only. Nothing here reaches the Play app (no push, socket event or in-app text), so the Play payments policy
([play_payments_policy.md](play_payments_policy.md)) is not affected.

Code: `gateway/src/email_marketing.js` (server), `gateway/public/admin/email_wizard.js` (the wizard, tabs, status),
`email_studio.js` (block editor, preview, History / Automations / Templates / Settings) and `email_studio.css`.
Tests: `gateway/test/email_marketing_357.test.js`, `gateway/test/web_admin_riders_357.test.js`.

## The wizard (3.57 round 3)

Owner request: "Sending mail in the website is very confusing: make it simple." One flow, three steps, plain words,
details in `?` tooltips.

| Step | What the admin does |
|---|---|
| **1 Who** | **One rider** (search by username / name / e-mail; shows "Agreed to offers" or "No offer consent" and a blocked address), **Several riders** (paste usernames), or **An audience** (a segment, N days; a live count "N riders agreed to offers", plus how many can get an account message for the plan segments) |
| **2 What** | Template cards with sketch thumbnails: **Write a quick message**, **Welcome**, **Plan assigned**, **Coupon for you** (system templates built from the words in Settings > Templates), the ready-made starters (Festive offer, Launch offer, ...) and saved templates. Edit in the block editor: Heading, Text, Button, Coupon first; Image, Header image, Price and Divider behind **More blocks**; variables under "Personalise". Kind: **About their account** (transactional) or **Offer or news** (marketing); a coupon or price forces "Offer". Coupon picker inline; "a personal single-use code" (one rider) or "every rider their own code" (several / audience). Save template / Save as new. |
| **3 Check & send** | Preview (desktop / mobile, light / dark, plain text; for one rider exactly as that rider gets it). Checklist: subject set; links and content OK (the server's own check); consent ("Account message: no offer consent needed", "The rider agreed to offer e-mails", or "N riders will get it"); postal address set (needed for offers and campaigns); e-mail server set up. One rider without consent: "Service message: the rider asked for it" + a note. Send test to me. **Send now** (one rider: at once) or **Send now / Schedule** (several / audience: a campaign) |

After sending: one rider: a result card ("Sent to a***@x · Account message"), "Back to @rider", "Send another";
several / audience: the status page `#/email/status/<campaignId>` (progress bar, riders, sent, left out, failed,
clicks, coupon uses, cancel while scheduled, full report), refreshed every 3 s while sending.

How the wizard sends:

| Who | Request | Rules |
|---|---|---|
| One rider | `POST /api/admin/riders/:userId/email` ([web_riders_admin.md](web_riders_admin.md)) | 1:1 message: no quiet hours or weekly cap; transactional skips only hard-suppressed addresses; marketing needs the Offers consent or a noted service message; idempotent per request id; audited |
| Several riders | `POST /campaigns` with `audience: { kind: 'usernames' }` | marketing: consent per rider; **account notices to named riders are now allowed (at most 50)**, with the footer "the CoRoute team wrote to you about your account" |
| An audience | `POST /campaigns` with the segment | as before (consent, cap, quiet hours, schedule) |

Tabs: **History** (campaigns with results; one-to-one e-mails are on each rider's page), **Automations** (rules),
**Templates** (ready-made and saved; "Use" opens the wizard; "Words of automatic e-mails" links to Settings >
Templates), **Settings** (weekly limit, quiet hours, click tracking, sender identity, suppression list, earlier 3.56
offers e-mails). The Coupons page's "E-mail this coupon" opens the wizard with the Festive offer and the coupon filled in.

## What the admin can do

| Tab | What |
|---|---|
| Compose | Block editor with a live preview (desktop / mobile, light / dark, plain text), subject and preheader, variables, unique codes, audience with a count, send now or schedule (India time), test to me |
| Templates | 8 starters (read-only, "Use") and saved templates: edit, **save** (new version), **save as new**, **duplicate**, **archive** / unarchive, **versions** (open any older version and save it again to restore it) |
| Campaigns | Every campaign with its status and numbers; click one for the report |
| Automation | Rules: a segment and a saved template, e.g. "no ride for 30 days -> win-back, once per rider per 90 days" |
| Settings | Weekly cap, quiet hours, click tracking, sender identity status, suppression list, the earlier 3.56 offers e-mails |

The Coupons page shows "N unique e-mail codes" under a parent coupon. A coupon's details list its
single-use codes, and the **E-mail this coupon** button opens the composer with the coupon block filled in.

### Starters

| Starter | Category | Blocks |
|---|---|---|
| Festive offer with coupon | marketing | header image, heading, text, coupon, divider, text |
| Launch / limited-time offer | marketing | heading, text, **price** (list price struck through, offer price from the pricing config), text |
| New feature announcement | marketing | image (links to /updates), heading, text, button /updates |
| Ride season: weekend ride ideas | marketing | header image, heading, bullet text, button /guide |
| Win-back: we miss you (coupon) | marketing | heading, text, coupon |
| Plan ending soon | **account** | heading, text, button /account (no coupon, no price) |
| Club / operator invitation | marketing | heading, text, button /operators/apply |
| Safety tips newsletter | marketing | heading, bullet text, divider, text, button /guide |

### Blocks

| Block | Fields | Rules |
|---|---|---|
| Header image / Image | upload (the push image pipeline: JPEG / PNG / WebP, 1 MB, EXIF removed) or **From the image library** (Marketing studio and Board images, copied to the public store), alt text; Image: an optional link | needed when sending; links: the button pages |
| Heading | text, size | one line, 150 characters |
| Rich text | `**bold**`, `*italic*` / `_italic_`, `[label](/path)`, `- ` bullets, blank line = paragraph | 3000 characters; links only to pages of this site (never /api, /admin, /r/, /email/); HTML is refused |
| Coupon | an active coupon (or a scheduled one), headline, note, button text | shows the code, the discount ("40% off", "₹50 off" ...) and "valid until"; the button opens `/plans?coupon=CODE`; one per e-mail |
| Price | a group plan, button text, note | list price and offer price read from **Plans & pricing at send time**; a running offer shows the list price struck through, the offer label and its end |
| Button | text, page, filled / outline | pages: `/plans`, `/updates`, `/guide`, `/operators/apply`, `/account` (and their sub-paths / query) |
| Divider | | |
| Footer | an optional note | always last and always present: why the rider gets it, **Unsubscribe** (Offers, marketing only), **Manage e-mails**, "Sent by CoRoute", the **postal address** (`MAIL_POSTAL_ADDRESS`) and the support address |

Every block can be moved up / down, duplicated (not the coupon) and deleted; the footer cannot.
At most 30 blocks.

The HTML is a table layout with every value escaped, `color-scheme: light dark` and a dark-mode style
block (`prefers-color-scheme: dark`) for mail apps that support it; the light colours also read well when
a mail app inverts them. A hidden preheader follows the subject. The plain-text alternative is generated
from the same blocks.

### Variables

`{firstName}` `{username}` `{planName}` `{planEndsOn}` `{couponCode}` `{discount}` `{validUntil}`
`{listPrice}` `{offerPrice}` `{link}`, in the subject, preheader and every text field.

* Anything else in `{ }` is refused ("uses an unknown variable {nmae}").
* `{couponCode}`, `{discount}`, `{validUntil}` need a coupon block; `{listPrice}`, `{offerPrice}` a price block.
* Missing values get a safe fallback: `there`, `rider`, `your plan`, `soon`, `a discount`, ...
* Values are escaped in HTML and are never read as markup (a name like `**x**` stays text).
* `{link}`: the coupon link, else the first button's page, else `/plans`.

## Categories and consent (enforced by the server)

| Category | Who can get it | Unsubscribe | Cap |
|---|---|---|---|
| **marketing** (default) | only riders with **Offer e-mails** on (`marketing_consent.offersEmail`), never a suppressed address (any reason) | Offers link + `List-Unsubscribe` / `List-Unsubscribe-Post` (RFC 8058) | yes |
| **account** | riders whose website plan ends within N days or ended in the last N days (only these two segments); consent not needed; bounce / complaint / admin suppression respected | "Manage e-mails" link | no |

A template with a coupon block, a price block, or a coupon / price variable can never be an account
e-mail: "Plan ending soon" with a coupon is marketing and needs the Offers consent. Consent and
suppression are checked again for every rider at send time.

## Audiences

| Segment | Meaning |
|---|---|
| Every rider who opted in | consent on |
| Joined in the last N days | account created within N days |
| No ride for N days | no trip ended in the last N days (and the account is older than N days) |
| Never hosted a group ride | no ride created by the rider |
| Website plan ends within N days | an active group plan ending within N days (marketing or account) |
| Website plan ended in the last N days | the latest group plan ended within N days, not renewed |
| Crew admins | admin or co-admin of a crew |
| Operators and club owners | owners and co-organisers of an approved, valid operator |
| Usernames | up to 500 usernames |
| Active in the last N days, By plan type | the 3.56 audiences |

Riders' cities are not stored, so there is no city segment. **Count riders** shows the number after
consent and suppression. **Send test to me** goes to the admin's own address (consent, caps and quiet
hours do not apply; the subject starts with `[Test]`).

## Unique coupon codes

Optional per campaign or rule ("A single-use code per rider"): the coupon block's coupon is the
**parent** (it must be active and public: no rider list). Each recipient gets their own child code:

* `<PREFIX>-<8 random letters / digits>` (no 0 / O / 1 / I / L), e.g. `DIW-QHR95Q2X`.
* An ordinary coupon with the parent's discount, plans and rules, plus: 1 use in total, 1 per rider,
  only that rider (`allowedUserIds`), ends at the sooner of the parent's end and N days (1 to 90),
  `parentCode`, `emailCampaignId`, created by `email-studio`.
* Redeemed on `/plans?coupon=CODE` like any coupon; the existing atomic reservation
  (`repo.reserveCouponSlot`, compare-and-replace) makes a single-use code usable once even under a race.
* `email_coupon_codes` holds a unique claim per code and per (campaign, rider): a retry or a second node
  gets the same code, never a second one.
* Kept out of the main coupon list (`repo.listCoupons` leaves children out unless `includeChildren`);
  listed per parent in the coupon details and with `GET /api/admin/email/studio/unique-codes?parent=CODE`.
* A test send with unique codes makes a real single-use code for the admin (for QA on /plans).

## Sending, scheduling and automation

* **Send now** or **Schedule** (India time, up to 90 days ahead). The leased job `email-studio` (every
  minute, one node) claims due campaigns with a compare-and-replace lease, resolves the audience once,
  and sends in batches at `OFFER_EMAIL_RATE` e-mails per second (default 5).
* **Idempotency**: before an e-mail is sent, a `mail_log` row with a unique key is inserted:
  `mkt:<campaignId>:<userId>` for campaigns, `auto:<ruleId>:<userId>:<occurrence>` for rules. A second
  run, another node or a restart can never send it again (a crash between the insert and the send
  leaves that one e-mail unsent: at most once).
* **Frequency cap**: at most `maxPerWeek` marketing e-mails per rider per 7 days (default **2**),
  campaigns and rules together. Over the cap = skipped ("Over the weekly cap" in the report).
* **Quiet hours** (India time, default **21:00 to 09:00**): nothing is sent; a campaign due in the
  quiet hours (or reaching them mid-way) goes out when they end. Same start and end hour = no quiet hours.
* **Suppression and bounces**: suppressed addresses are skipped; a permanent SMTP refusal (5xx) adds
  the address to the suppression list with reason `bounce`.
* **Real campaigns and enabled rules need `MAIL_POSTAL_ADDRESS`** (409 `NO_POSTAL_ADDRESS`); previews
  and test sends show the placeholder `[OWNER TO FILL in config: MAIL_POSTAL_ADDRESS]`.
* A coupon that became unusable before the job ran fails the campaign ("Cannot send any more: ...");
  the price block always uses the prices at send time.
* If access mode is "Free for everyone", a coupon or price block shows a warning.

**Automation rules** (Automation tab): trigger + N days + a saved template + an optional coupon for the
template's coupon block + optional unique codes + "once per rider per N days".

| Trigger | Segment | Default N | Repeat |
|---|---|---|---|
| No ride for N days | inactive | 30 | once per rider per 90 days |
| Plan ends in N days | plan_ends_within | 3 | once per plan period (the plan's end date is the occurrence) |
| Plan ended N days ago (or less) | plan_expired_within | 7 | once per plan period |
| Joined in the last N days | joined_within | 7 | once per rider per 365 days |

Rules run in the same job, outside the quiet hours, with the same consent, cap and idempotency checks.
The template's current version is used; the version is stored on each `mail_log` row.

## Reporting and click tracking

Per campaign (and per rule): **queued** (mail_log rows), **sent**, **failed**, skipped at send time,
over the cap, **unsubscribed** (the unsubscribe link carries `cid=<campaignId>`; counted only for a
rider who got that campaign), **coupon redemptions** (successful redemptions of the campaign's codes,
the parent and its children, by its recipients after the first send, with the discount and the amount
paid), and **clicks** (total, unique riders, per link).

Clicks go through signed redirect links `https://<site>/r/<token>`:

* token = base64url(`<campaignId>|<rider hash>|<path>`) + HMAC-SHA256 signature. The target is inside
  the signed token and must be a path of this site, so `/r/` is never an open redirect; a bad token
  redirects to `/`.
* The rider hash is an HMAC of the user id (16 characters): no user id or e-mail in the link or the
  click row. Click rows (`email_events`: campaign, rider hash, path, time) are removed with the account
  and after 400 days.
* **No open pixels**: opens are never tracked.
* **Settings > Count clicks** off: new e-mails carry direct links, and clicks on older links are not
  counted (they still redirect). A campaign can also be sent without tracking.
* The plain-text version always has direct links; unsubscribe and "Manage e-mails" are never tracked.

## Endpoints

All under `/api/admin/email/studio` (requireAuth + requireAdmin; every write is audited as
`email.template.*`, `email.campaign.*`, `email.rule.*`, `email.studio.settings`, `email.image.import`).

| Method | Path | What |
|---|---|---|
| GET | `/config` | variables, block types, button pages, segments, triggers, settings, postal address set, SMTP on |
| GET / PUT | `/settings` | `{ maxPerWeek 1-14, quietStartHour, quietEndHour 0-23, clickTracking }` |
| GET | `/templates[?archived=1]` | `{ starters, templates }` |
| POST | `/templates` | `{ fromStarter }` or `{ fromTemplate }` or `{ name, category, design }` |
| GET | `/templates/:id` | a template with its version history (a starter id returns the starter) |
| GET | `/templates/:id/versions/:v` | one version's design |
| PUT | `/templates/:id` | save a new version (`baseVersion`: 409 `VERSION_CONFLICT` when someone saved meanwhile) |
| POST | `/templates/:id/duplicate`, `/archive`, `/unarchive` | |
| POST | `/check` | validate a design (`errors[]`, `warnings[]`) |
| POST | `/preview` | `{ subject, preheader, html, text, previewUrl, darkPreviewUrl, images }` |
| POST | `/audience-count` | `{ audience, category }` -> `{ riders }` |
| POST | `/test` | send to the admin's own address |
| POST / GET | `/campaigns` | create (`{ name, design, category, audience, sendAt, uniqueCoupon, trackClicks, templateId }`) / list |
| GET | `/campaigns/:id` | campaign + report |
| POST | `/campaigns/:id/cancel` | a scheduled campaign that has not started |
| GET / POST | `/rules`; PUT / DELETE `/rules/:id`; GET `/rules/:id/report` | automation rules |
| GET | `/unique-codes[?parent=CODE]` | summary per parent, or the codes of one parent |
| GET | `/images/library`; POST `/images/import` `{ source: marketing / board, id }` | image library |

Public: `GET /r/:token` (click redirect, rate limited) and `GET /email/preview/:token` (the editor's
preview frame: random 24-character token valid 15 minutes, stored in `email_previews`; served with its
own CSP `default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data: https:; frame-ancestors
'self'; sandbox allow-popups`, no scripts). The admin console's CSP gained `frame-src 'self'` for it.

## Collections

`email_studio_templates` (current design + last 30 versions), `email_studio_campaigns`,
`email_studio_rules`, `email_studio_settings`, `email_coupon_codes`, `email_events` (clicks,
unsubscribes), `email_previews`, plus `mail_log` rows with `kind: 'marketing'`.

Account erase removes the rider's marketing `mail_log` rows, click / unsubscribe events and code claims
(the child coupons stay as payment records); the suppression hash stays (as before).

## Configuration

| Env | Default | What |
|---|---|---|
| `MAIL_POSTAL_ADDRESS` | (none) | **[OWNER TO FILL]** the postal address in every marketing e-mail footer; needed for real campaigns and rules |
| `OFFER_EMAIL_RATE` | 5 | e-mails per second (shared with the 3.56 offers e-mails) |
| `PUBLIC_ORIGIN` | | links, images and `/r/` links |
| `SMTP_*`, `MAIL_FROM` | | e-mail on / off |

## Compliance notes (India DPDP Act)

* Marketing e-mails need the rider's own opt-in (off by default), recorded with time and source; the
  consent is checked again for every e-mail. Unsubscribing (link or one-click) turns it off and
  suppresses the address.
* Every marketing e-mail names the sender ("Sent by CoRoute"), the postal address and the support
  address, and has the unsubscribe link and headers.
* Purpose limitation: segments use data CoRoute already holds for the service (account date, rides,
  plan, crew / operator role); no city or location is used. Click tracking is minimal (no opens, a
  pseudonymous rider hash), can be switched off, and is described in the privacy notice (/privacy,
  "E-mails and notifications").
* Retention: see the consent and retention register (`docs/handbook/compliance/consent_and_retention_register.md`).

## QA checklist

1. Set `MAIL_POSTAL_ADDRESS` and SMTP; open /admin > E-mail.
2. Step 1 An audience > Next > Festive offer with coupon; choose an active coupon, upload a header image; check the preview in
   Mobile / Dark and the Plain text view; Save template.
3. Tick unique codes (prefix e.g. `QA`), **Send test to me**: the e-mail has your own `QA-XXXXXXXX` code.
4. Sign in on the website as yourself, open the e-mail's coupon button (`/plans?coupon=QA-...`) and
   redeem it (Razorpay test mode); a second use is refused.
5. With a test rider who turned on offer e-mails: wizard > Several riders = that rider; the
   report shows sent 1; click a link (clicks 1); press Unsubscribe in the e-mail -> the account page
   shows offer e-mails off, the report shows unsubscribed 1, a new campaign skips the rider.
6. Plan ending: a test rider with a plan ending in 2 days, an automation rule "Plan ends in 3 days" with
   the Plan ending template -> one e-mail, not repeated on the next run.
