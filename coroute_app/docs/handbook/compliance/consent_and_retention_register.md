# Consent and retention register

Every consent, opt-in, opt-out and fixed default in the app and website, and every retention rule,
verified against the code on 11 Nov 2026. Update this register whenever a setting, switch or
purge job changes. Draft, not legal advice.

## 1. Consents, opt-ins and opt-outs

Legend: **Opt-in** = off until the person turns it on. **Opt-out** = on by default, person can turn
it off. **Fixed** = no switch (owner decision), covered by notice. **Action-based** = happens only
when the person acts.

| # | Item | Type / default | Where the person controls it | Stored as | Record of consent | Source |
|---|---|---|---|---|---|---|
| 1 | Offer e-mails (plan prices, coupons) | **Opt-in, off** | Website `/account` "Send me offer e-mails"; unsubscribe link (RFC 8058 one-click) in every mail | `marketing_consent` (`offersEmail`), `email_suppression` | Yes: time + source, last 20 changes | `offer_emails.js`, `GET/PUT /api/web/marketing-consent` |
| 1d | Marketing e-mails from the E-mail studio (3.57: offers, coupons, news, ride ideas, club invitations; unique single-use codes) | **Opt-in, off** (the same consent as 1) | as 1; unsubscribe link carries `cid=` for the campaign report | `marketing_consent`, `email_suppression`, `mail_log` (`kind: marketing`) | Yes: as 1 | `email_marketing.js`; consent and suppression checked again for every e-mail at send time |
| 1e | "Plan ending soon" account notice (3.57, no coupon / price; only riders whose website plan ends or ended) | **Fixed** (transactional, about the rider's own plan) | "Manage e-mails" link; not sent to a hard-suppressed address | `mail_log` (`kind: marketing`, `category: account`) | — | `email_marketing.js` (server refuses a coupon, price or coupon / price variable in an account e-mail) |
| 1f | Click counting in marketing e-mails (3.57) | On, admin switch (Settings > Count clicks); no open pixels | — (minimal, pseudonymous; described in /privacy) | `email_events` (campaign, rider HMAC hash, path, time) | — | `email_marketing.js` `/r/:token` |
| 1a | Ride summary e-mails (3.57: summary of the rider's own ride, at least 2 km / 10 min) | Opt-out, on | Website `/account` "Ride summaries"; signed one-click unsubscribe link (`c=ride_summaries`) in every summary | `email_preferences.rideSummaries` | Yes: category, value, time + source, last 20 changes | `lifecycle_emails.js`, `GET/PUT /api/web/email-preferences` |
| 1b | Tips and news e-mails (3.57: the welcome e-mail's group rides / plans block, product news) | Opt-out, on | Website `/account` "Tips and news"; signed one-click unsubscribe link (`c=tips_news`) in the welcome e-mail | `email_preferences.tipsNews` | Yes: as 1a | `lifecycle_emails.js` |
| 1c | Account and receipt e-mails (receipts, refunds, the welcome e-mail's account part) | **Fixed** (transactional) | none; not sent to a hard-suppressed (bounce / complaint / admin) address for lifecycle mail | `mail_log` (masked address) | — | `purchase_email.js`, `lifecycle_emails.js` |
| 2 | Partner perk pushes | **Opt-in, off** | App Settings > Push notifications (per kind) | `push_prefs.partnerPerks` | Pref value only | `push_campaigns.js` |
| 3 | Push kinds Update, Event, Safety tip, Community | Opt-out, on | App settings per kind; Android channel settings | `push_prefs` | Pref value | `push_campaigns.js` |
| 4 | Push notifications overall | Opt-out, on (hidden in builds without Firebase) | Settings > Push notifications; Android notification permission | token removed when off | — | `push.js`, `PushChannel.kt` |
| 5 | Safety, ride, social, plan pushes | **Fixed** (cannot be turned off in app; `SAFETY_ALWAYS_ON`) | Android channel settings only | — | — | `push_campaigns.js` |
| 6 | Diagnostics log sending | **Action-based** (each send is a choice) | Profile > Help > Send feedback > Attach diagnostics log; View diagnostics > Send / Share; admin request needs a tap | `diag_logs` | Upload reason (`manual`, `safety_prompt`, `admin_request`) | `diag_log_service.dart`, `diag_logs.js` |
| 7 | Automatic sending of safety logs after an SOS/crash | **Opt-in, off** | Diagnostics screen | phone pref `diag.autoSendSafety` | — | `diag_log_service.dart` |
| 8 | Detailed (debug) logs | Opt-in, off; auto-off after 24 h | Diagnostics screen (admins, or hidden 7-tap) | phone pref | — | `diag_policy.dart` |
| 9 | Show me on leaderboards | Opt-out, on | Settings and My profile | `users.publicLeaderboard` | — | `PATCH /api/me/privacy` |
| 10 | Discoverable (search by username, "People you rode with") | Opt-out, on | My profile privacy | `users.discoverable` | — | `PATCH /api/me/privacy` |
| 11 | Help nearby riders (`assistHelp`) | **Fixed on** since 11 Nov (owner) | none (admin switch `assistNetwork` pauses for everyone) | `users.assistHelp` | consent time of the "Riders helping riders" sheet | SETTINGS_MINIMAL round 2 |
| 12 | Ask nearby riders to help me (`assistAsk`) | **Fixed on** since 11 Nov (owner) | none | `users.assistAsk` | as above | same |
| 13 | Group-level nearby help default | Group setting (trip owner/head) | Group settings | `convoys` config `assistDefault` | — | `group_settings_sheet.dart` |
| 14 | Groups nearby (discovery) | Opt-in per ride / feature | Ride sheet | ride config | — | `discovery.js` |
| 15 | Public ride | Off per ride by default | Group settings | ride config | — | `public_ride.js` |
| 16 | Receive emergency texts from my ride group (`smsOptOut`) | Opt-out (on: number given to riders for SOS texts) | Profile | `users.smsOptOut` | — | `validate.js` SWITCHES |
| 17 | Emergency texts (3.57 phone-first: sent from the rider's SIM after an SOS / unanswered crash alarm, plus the group fallback) | **Fixed on**; needs the Android SEND_SMS permission (asked after a disclosure; denied = messages app prefilled) | Safety health (Allow, test text) | on-device queue (`coroute_emergency_texts` prefs: numbers purged 48 h after sending) + ledger (number hashes only) | — | SETTINGS_MINIMAL, sos_sms.md |
| 18 | Crash detection | **Fixed on** (admin switch locked) | none | — | — | SETTINGS_MINIMAL |
| 19 | Medical info sharing with responders | **Fixed** (no consent switch, owner Nov 9); entering medical info is optional | Profile (fill or clear) | `users` medical fields | — | V3_55_RELEASE §1d |
| 20 | Medical ID on lock screen | **Fixed on** (when entered) | none | — | — | SETTINGS_MINIMAL |
| 21 | Ride on lock screen | **Fixed on** | none | — | — | SETTINGS_MINIMAL |
| 22 | Siren alerts (microphone listening during rides) | Opt-out, on | Settings > Ride > Siren alerts; mic permission | phone pref `siren_alerts_v1` | — | SETTINGS_MINIMAL |
| 23 | Voice alerts | Opt-out, on (emergencies always spoken) | Settings | phone pref | — | — |
| 24 | Lower music when speeding / pause music for alerts | On / off (comfort) | Settings > More | phone prefs | — | — |
| 25 | Safety report in my score (5 per-ride counts) | **Fixed on** since 11 Nov (rides recorded while it was off are never sent) | none | phone prefs `coroute_rider_score_use_report_v1`, `..._send_from_v1` | send-from cut-off | SETTINGS_MINIMAL |
| 26 | Share fuel estimate with the group | Opt-in, off | Fuel sheet | phone pref | — | SETTINGS_MINIMAL |
| 27 | Ride Guardian link | Action-based (rider creates, pauses, revokes); group consent for group links | Guardian sheet | `guardian_grants`, `guardian_consents` | consent rows with time | `guardians.js` |
| 28 | Live emergency link | Action-based (rider or lead during an open alert) | SOS screen | hash in alert | audit rows | `routes.js` |
| 29 | Publish trip review photos/story | **Opt-in** tick per review; admin approval | Trip review sheet; withdraw in trip report | `feedback` consent flag | Yes (per review) | `trip_reviews.js` |
| 30 | Place review photo | Action-based; shown after admin check | Place review sheet | `place_reviews` | — | `road_and_places.js` |
| 31 | Profile picture | Optional | My profile | `avatars` | — | `avatars.js` |
| 32 | Friend requests / crew invites / club invites | Both sides must agree | People hub, `/clubs` | `friend_edges`, `crew_invites` | accept time | `friends.js`, `crews.js` |
| 33 | Operator emergency-contact view | Rider joins an operator ride; view only during SOS with `rosterEmergency` | Leave club | — | audit `operator.sos_contacts_viewed` | `operator_routes.js` |
| 34 | Android permissions (location, background location, mic, notifications, Bluetooth, full-screen intent, battery exemption) | System consent, with in-app prominent disclosure | System settings; Safety health screen | OS | OS | `permissions_service.dart` |
| 35 | Website cookies | None used for analytics; only the guardian pilot session cookie (httpOnly) | — | — | — | `app.js`, `guardian_routes.js` |
| 36 | Google sign-in data | Action-based | Choose sign-in method | `users` | — | `auth.js` |
| 37 | **Help make roads safer** (round 4: anonymous road and safety signals, crash alarm numbers + outcome) | **Opt-in, off**; one-time prompt after the first completed ride | App Settings > Road safety; website `/account#roads`; Delete / Download my contributions on both | `intel_consent` (`on`, `at`, `source`, `promptedAt`) | Yes: time + source, last 20 changes | `src/intel/privacy.js`, `GET/PUT /api/intel/consent` |
| 38 | Road safety warnings (hazard ahead, rough road, twisty, nudges) | Opt-out, on (comfort / safety, no data sent) | App Settings > Road safety | phone pref `intel_settings_v1` | — | `intel_care_service.dart` |

**Open items:** record the privacy-notice version accepted (sign-up and material change); 18+
confirmation at sign-up; DPDP review of the fixed-on items 11, 12, 19, 25 (see privacy pack §2.1).

## 2. Retention rules

### 2.1 Server

| Data | Retention | Mechanism | Verified in |
|---|---|---|---|
| Recorded routes (`track_chunks`) | detail 14 days, then simplified; deleted at **90 days** | `retention` job | `config.js` `TRACK_DETAIL_DAYS`, `TRACK_RETENTION_DAYS`; `retention.js` |
| Rider live state / snapshots / `convoy_riders` / trip `breadcrumbTrail` of ended rides | **90 days** after the ride ended | `retention` | `RETENTION_ENDED_CONVOY_DAYS` |
| Coordinates on timeline events and SOS alerts | removed after **90 days** (entry kept) | `retention` | `retention.js` |
| Medical info copy on alerts | until resolve / trip end; leftovers removed by retention | event + `retention` | `retention.js` |
| Stale (never-ended) rides | auto-ended after **36 h** | `convoy-auto-end` | `RETENTION_STALE_CONVOY_HOURS` |
| Voice metadata (`voice_log`) | **7 days**; audio never stored | `retention` | `RETENTION_VOICE_LOG_DAYS` |
| Safety audit (`safety_audit`) | **180 days** | `retention` | `AUDIT_RETENTION_DAYS` |
| Geo cache | 30 days | `retention` | `GEO_CACHE_DAYS` |
| POI cell cache | 7 days | memory + `geo_cache` | `app.js` comment |
| Road hazards | pothole 45 d, rough road 30 d, speed breaker 365 d (renewed by confirmations) | `retention` | `road_and_places.js` |
| Road risk cells | 180 days without a new hard brake | `retention` | `retention.js` |
| Road & safety intelligence raw rows (`intel_raw`: monthly rider hash, cells, no position finer than ~150 m) | **90 days** (`INTEL_RAW_DAYS`); deletable earlier by the rider | `intel-daily` lease job | `src/intel/engine.js` `purgeRaw` |
| Intelligence aggregates (`intel_cells`) | decayed (half-life 90 d), pruned when near zero; current-month short hashes dropped at month change | `intel-daily` | `engine.js` `pruneCells`, `_rider` |
| Crash brain training copies (`intel_crash_train`: sensor numbers, phone maker, month, label; no hash, no position) | **2 years** | `intel-daily` | `engine.js` `purgeRaw` |
| Intelligence consent record | until account deletion | account cascade | `src/intel/routes.js` |
| Guardian grants / sessions | until expiry / revoke, then purged | `retention` | `repo.purgeGuardianAccess` |
| Uploaded diagnostics logs | **30 days**; admin requests 7 days | `diag-log-retention` (6 h) | `diag_logs.js` `RETENTION_DAYS`, `REQUEST_TTL_DAYS` |
| Server SOS SMS rows | numbers, names, links purged **48 h** after last status change | `sos-sms` | `sos_sms.js` `PURGE_AFTER_MS` |
| Live emergency links | 30 min (or alert close); max 3 per alert; only hash stored | runtime | `LIVE_LINK_MIN`, `LIVE_LINK_PER_ALERT` |
| Emergency SMS roster served to phones | valid 12 h | runtime | `ROSTER_VALID_H` |
| Public ride contact log, blocks | 30 days | `public_ride.js` | `public_ride.js` |
| Push tokens | 5 newest per rider; removed on sign-out, switch off, account deletion, FCM unregistered | runtime | `push.js` |
| Push news caps | 3 days (perk window 8 days) | `push-news-caps` | `push_campaigns.js` |
| Pending orders | 30 min TTL (coupon hold same) | runtime | web_payments_security #10 |
| Trips (personal log) | until the rider deletes the trip or account (GPS trail 90 days) | user action | privacy.html |
| Accounts, profile, social data, memberships | until account deletion (immediate cascade) | `DELETE /api/me` | `auth.deleteAccount` |
| E-mail suppression hash | kept after erase (so the address is not mailed again) | — | notifications_admin.md |
| Marketing consent history | last 20 changes; erased with account | — | `offer_emails.js` |
| E-mail category choices (`email_preferences`) | last 20 changes; erased with account | account erase cascade | `lifecycle_emails.js` |
| E-mail send log (`mail_log`): receipts / refunds | masked address, message id or error code; **no automatic purge** (idempotency key) | — | `purchase_email.js` |
| E-mail send log (`mail_log`): welcome / ride summary | masked address, status, reason; kept as the once-only key; erased with account | account erase cascade | `lifecycle_emails.js` |
| E-mail send log (`mail_log`): marketing (3.57) | masked address, status, campaign / rule id, coupon code; kept as the once-only key and for the weekly cap and reports; erased with account | account erase cascade | `email_marketing.js` |
| Marketing click / unsubscribe events (`email_events`, 3.57) | rider HMAC hash only; **400 days**, erased with account | `email-studio` job, account erase cascade | `email_marketing.js` |
| Unique coupon code claims (`email_coupon_codes`, 3.57) | until account erase (the child coupon itself stays as a payment record) | account erase cascade | `email_marketing.js` |
| E-mail studio preview pages (`email_previews`) | 15 minutes (sample data only) | removed on the next preview | `email_marketing.js` |
| Ride summary route picture | not stored (built when the e-mail is sent, attached inline) | — | `route_png.js` |
| Encrypted backups | **30 days** | `backup_jobs.js` / lifecycle rule | `BACKUP_RETENTION_DAYS` |
| Server logs (journald) | rotated by the OS ("within a few weeks" per privacy.html) **[OWNER TO CONFIRM journald limits]** | OS | — |
| Feedback messages, operator applications, payment ledger | **no automatic purge found** **[OWNER TO DECIDE; ledger per tax law]** | — | — |

### 2.2 Phone

| Data | Retention | Verified in |
|---|---|---|
| Diagnostics log | **7 days**, 2 MB files, **20 MB** total | `lib/domain/diag/diag_policy.dart` (`keepDays`, `maxTotalBytes`) |
| Offline route maps | **7 days** after the trip ends; **30 days** if the trip never ended; **300 MB** total, least recently used first; ride in progress never deleted | `lib/domain/geo/offline_map_retention.dart`, SETTINGS_MINIMAL |
| Tile cache (general) | 300 MB budget, 30-day / LRU pruning | `SafetyConstants.tileCacheMaxBytes` |
| Emergency SMS roster (other riders' numbers) | encrypted; deleted at ride end, leave, sign out | `roster_store.dart`, privacy.html |
| Coupon code from a marketing QR / link | 7 days (website flow) | V3_55_RELEASE §1g (app path since retired by the payments policy) |
| Pending SOS (offline) | until delivered (resent with the same clientId) | `safety_service.dart` |
| Track queue (unsent GPS points) | until uploaded (upload grace 30 min server side) | `sqflite_track_queue.dart` |
| Fuel profile | on device only, until changed | privacy.html |

## 3. Change log

| Date | Change | By |
|---|---|---|
| 11 Nov 2026 | Register created from code (handbook) | docs agent |
| 11 Nov 2026 | 3.57 E-mail studio: marketing e-mails (1d), plan-ending account notice (1e), click counting (1f); marketing `mail_log`, `email_events`, `email_coupon_codes`, `email_previews` retention | dev agent |
| 11 Nov 2026 | 3.57 e-mail categories: ride summaries (1a), tips and news (1b), account and receipts (1c); `email_preferences` and lifecycle `mail_log` retention | dev agent |
