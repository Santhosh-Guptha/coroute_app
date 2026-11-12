# Google Play compliance

Written 11 Nov 2026 for the first Play production release (app `3.55.0`, next build per
MASTER_AGENT_PROMPT). Sources: [docs/features_355/play_payments_policy.md](../../features_355/play_payments_policy.md),
[docs/PLAYSTORE_PERMISSIONS.md](../../PLAYSTORE_PERMISSIONS.md), [docs/MASTER_AGENT_PROMPT_v3.55.md §8](../../MASTER_AGENT_PROMPT_v3.55.md),
[docs/features_355/ratings_reviews.md](../../features_355/ratings_reviews.md), `android/app/src/main/AndroidManifest.xml`,
`android/app/build.gradle.kts`. Play policies change; re-check the Play Console policy pages
before each submission. Not legal advice.

## 1. Payments policy: consumption-only app

Owner decision (10 Nov 2026): **the Play app sells nothing.** Plans are bought and managed only on
the website (`/plans`, `/account`, Razorpay). One build serves Play and the website APK.

| Rule | How it is enforced |
|---|---|
| No payment SDK (Razorpay, Play Billing, Stripe, UPI intents, Install Referrer) | `tool/play_policy_scan.dart` checks pubspec, lockfile, Gradle, ProGuard, manifest. **0 hits on 11 Nov 2026.** |
| No money or buying words in anything a rider or reviewer can see | Same scan over every Dart string literal, Android XML, Kotlin strings, text assets. Server side: `policy_terms.js` refuses such words in pushes, broadcasts and prompt templates (422 `PLAY_POLICY`); `ApiClient` replaces any server message with money words by "This isn't available right now." |
| No steering to the website to pay | No link, button, QR or text pointing to plans. Allowed neutral line only: "Your plan is managed in your CoRoute account." (not tappable). |
| Locked features say what is so | `PlanGateMessages`: "Hosting a group ride needs a group plan.", "This ride is full.", "This isn't included in this ride." No upgrade button. |
| Free mode hides plans entirely | Access mode "Free for everyone": `capabilities.gated=false`, no plan chip or rows. |
| Neutral plan notices | `SUBSCRIPTION_*` pushes: "Your Small Group plan is active.", "Your plan ends on 12 Dec." |
| Staff admin in the app has no payments | Payments, coupons, revenue, marketing live in the web admin only. |
| Coupons and offers only on the website and in opt-in e-mail | Push "Partner perk" kind may say "% off / offer / deal" for a third-party business only, never CoRoute plans, codes or links. |

Reviewer risk notes: the website sells digital access consumed in the app. Google allows apps to
not offer in-app purchase if the app itself contains no purchase flow, prices or steering
(consumption-only / "reader-like" model). Keep the store listing free of prices and offers too.
**[LEGAL REVIEW]** whether any Play programme (e.g. external offers in India) is required.

## 2. Data safety form (proposed answers)

| Data type (Play category) | Collected | Shared (Play definition: to third parties) | Purpose | Optional? | Notes |
|---|---|---|---|---|---|
| Location: precise | Yes | **Yes, with other users** (ride group, guardians, accepted helpers) | App functionality, safety | Required for rides | Background location during rides |
| Location: approximate | Yes (derived) | No | App functionality | — | |
| Personal info: name | Yes | Yes, with other users in the ride | Account, app functionality | Required | Username public on leaderboards unless opted out |
| Personal info: e-mail | Yes | No (processors only) | Account management, communications (opt-in offers) | Required | |
| Personal info: phone number | Yes | Yes, with ride members (an SMS provider only if the server SMS path is turned on; off today) | App functionality, safety | Required for group rides | Never to other groups. Emergency texts are sent by the rider's own phone (SEND_SMS) to the contact the rider chose: user-initiated transfer, not "shared" by CoRoute |
| Personal info: user IDs | Yes | No | Account | Required | |
| Personal info: other (vehicle, emergency contact) | Yes | Yes, with ride members / helpers during SOS | Safety | Emergency contact required for group rides | |
| Health and fitness: health info | Yes (Medical ID: blood group, allergies, notes) | Yes, with responders **only during an open SOS** | Safety | **Optional** | Never to admins |
| Messages: other in-app messages | Yes (ride chat) | With ride members | App functionality | Optional | |
| Photos | Yes (profile picture, review photos) | Review photos on website only after consent + approval | App functionality | Optional | EXIF removed |
| Audio: voice or sound recordings | Voice transmitted live to ride members; **not stored**. Siren detection on device only. | With ride members (live) | App functionality | Optional (intercom) | Declare "processed ephemerally" for voice |
| App activity: app interactions, in-app search | Limited (feature analytics aggregates, map searches proxied) | No | Analytics, app functionality | — | |
| App info and performance: crash logs, diagnostics | Yes, **only when the user sends** the diagnostics log | No | Analytics / troubleshooting | Optional | |
| Device or other IDs | Yes (FCM push token) | No (Google FCM as processor) | Notifications | Optional (push switch) | |
| Financial info: purchase history | **Not collected by the app** (website only) | — | — | — | Answer "No" for the app |

Security practices: data encrypted in transit (TLS) — **Yes**; users can request deletion — **Yes**
(in-app Delete account + web URL `https://coroute.devmonks.space/delete-account`); committed to the
Families policy — **No** (18+ app); independent security review — **No** (not yet).

No ads; no data sale; no third-party analytics SDKs.

## 3. Sensitive permission declarations

| Permission | Declaration text (draft) | Evidence |
|---|---|---|
| `ACCESS_BACKGROUND_LOCATION` | "CoRoute is a motorcycle group-ride safety app. During an active ride it shares the rider's position with their ride group and keeps SOS and crash alerts working while the phone is locked in a mount or pocket. Location is not collected outside an active ride." | In-app **prominent disclosure** before the system dialog (permissions screen / phone check); demo video per `tool/play_video/README.md` (record, edit, upload as YouTube Unlisted) **[video kit referenced by MASTER_AGENT_PROMPT; check it exists in the build machine copy]** |
| `FOREGROUND_SERVICE_LOCATION` | Ride foreground service: GPS, group link and crash detection with the screen off, persistent notification with SOS. | Same video |
| `FOREGROUND_SERVICE_MICROPHONE` | Same service gets the microphone type only while the rider uses group voice intercom or siren alerts; started from the foreground with RECORD_AUDIO granted. | Video + intercom clip |
| `USE_FULL_SCREEN_INTENT` | Alarm / safety category: crash alarm countdown and another rider's SOS over the lock screen so the rider can answer without unlocking. Falls back to heads-up when denied (Android 14+). | Screenshot of crash alarm |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Core safety function (multi-hour ride tracking and crash detection) is killed by OEM battery managers otherwise; asked once from the phone check after explanation. **If Play rejects: remove the permission and keep the "open battery settings" fix button.** | Phone check screen |
| `RECORD_AUDIO` | Intercom and siren detection; nothing recorded or uploaded. | Settings subtitle "Listens on your phone during rides. Nothing is recorded." |
| `SEND_SMS` (3.57) | Permissions Declaration Form, section 3a below. | In-app prominent disclosure (`EmergencyTextsDisclosure`) + video 2 (section 3b) |

Lock-screen cockpit round (docs/features_355/lock_screen_cockpit.md):
- **Added** `POST_PROMOTED_NOTIFICATIONS` (normal permission, no declaration form, nothing asked at run time):
  Android 16+ shows the ride notification as a Live Update (status bar chip, lock screen, always-on display)
  with the next turn or the group status. Riders can turn Live Updates off for CoRoute in Android settings; the
  ride notification then looks as before. Data Safety: no change (nothing new leaves the phone).
- The cockpit over the lock screen during a ride uses `setShowWhenLocked` on the app's own window only (no
  permission). It never turns the screen on; **no** `USE_FULL_SCREEN_INTENT` for the cockpit or the Live Update.
  The full-screen intent stays limited to the crash alarm and another rider's SOS (alarm / safety category,
  unchanged declaration above).

Not declared: `READ_SMS`, `RECEIVE_SMS`, `READ_PHONE_STATE`, `READ_CALL_LOG`, `READ_CONTACTS`,
`BLUETOOTH_SCAN`, `HIGH_SAMPLING_RATE_SENSORS`, `FOREGROUND_SERVICE_HEALTH`.
`<uses-feature android:name="android.hardware.telephony" android:required="false"/>` keeps tablets
without a SIM eligible (Play would otherwise filter them out because SEND_SMS implies telephony).

### 3a. SEND_SMS: Permissions Declaration Form (SMS and Call Log permissions)

CoRoute is **not** the default SMS handler. It qualifies under the exception
**"Physical safety / emergency alerts: apps that send SMS alerts in emergency situations"**
(Play Console > App content > Sensitive app permissions > SMS and Call Log permissions).
Only `SEND_SMS` is requested; no SMS or call log data is read.

Paste into the form:

- **Core functionality**: Physical safety / emergency alerts (send SMS in emergency situations).
- **Why the app needs the permission** (text field):

  > CoRoute is a motorcycle ride-safety app. When the rider raises an SOS, or when crash detection
  > rings for 30 seconds and the rider does not answer (they may be unconscious), the app sends a
  > text message from the rider's own phone to the emergency contacts the rider chose. The text says
  > who, what happened (SOS or possible crash), the time, a live location link and the coordinates.
  > When the emergency is closed, the same contacts get a short "safe now" text. Texts are sent
  > automatically because an injured rider may not be able to touch the phone; this is the core
  > safety purpose of the app. Without the permission the app can only open the messages app with
  > the text filled in, which needs a tap. The app sends at most 30 emergency texts a day, never
  > sends marketing or other messages, never reads SMS, and asks for the permission only after an
  > in-app disclosure that explains this and that carrier SMS charges apply. Riders can also send
  > one test text from Safety health after confirming.

- **Is the app the default SMS handler?** No.
- **Video link**: video 2 below (YouTube, Unlisted).
- **Data safety**: phone numbers of emergency contacts stay on the device for sending; nothing
  about the texts is uploaded (the diagnostics log keeps at most the last 3 digits, and only when the
  rider sends the log).

### 3b. Video 2: emergency texts (for the SMS declaration)

`tool/play_video/` is not in this tree, so the script lives here. 60 to 90 s, screen recording of a
Play-signed build (internal track), phone language English, no real personal numbers on screen
(use a team phone as the contact). Upload as YouTube **Unlisted**.

1. (0-10 s) Title card: "CoRoute: emergency texts from the rider's phone (SEND_SMS)".
2. (10-25 s) Profile > Emergency contact: type a name and the team phone number, Save. The note
   "We text this person from your phone in an emergency" is visible.
3. (25-40 s) The disclosure screen opens: show the full text ("CoRoute sends a text from your phone
   to your emergency contacts when you raise an SOS or after a crash alarm, even if you can't touch
   the phone. Normal SMS charges from your carrier apply."), tap **Allow texts**, then the Android
   permission dialog, tap **Allow**.
4. (40-50 s) Safety health: "Emergency texts" shows as ready.
5. (50-70 s) Start a ride, lock the phone, open SOS from the ride notification, hold SOS. Do not touch
   the phone: after 10 s the SOS screen says "Texted your emergency contact from your phone.
   Delivered." (Alternative take: let a crash alarm count down to 0 without answering.)
6. (70-85 s) Cut to the second phone: the received SMS (name, "needs help" / "may have crashed",
   time, live link, coordinates). Tap the live link: the live page opens.
7. (85-90 s) Back on the rider phone: "I'm safe now"; the second phone receives "safe now".

Optional extra take for the reviewer: deny the permission and show that the SOS text then opens in
the messages app instead.

## 4. In-app review rules

`InAppReviewChannel.kt` + Play In-App Review API (`com.google.android.play:review:2.0.2`):

- **No gating**: never ask "Do you like CoRoute?" before showing the Play card; everyone who meets
  the timing rules gets the same card.
- **No incentives**: nothing offered for a rating; "Send feedback" is a separate row, never a branch.
- Never during a ride or within 20 s of its end; rare by design; Google decides whether the card
  shows (quota). Fallback to the Play listing only when the card could not run.
- Admin prompt texts are policy-checked on the server and again in the app.
- Ask early testers for honest reviews only; no rewards.

## 5. Notifications and ads

- No ads, no ad SDK.
- Push campaigns are categorised kinds with their own Android channels and in-app opt-outs (Update,
  Event, Safety tip, Community on by default; **Partner perk off by default**). Safety, ride, social
  and plan notices are functional and cannot be turned off in the app (Android channel controls
  still apply). Daily caps (`PUSH_NEWS_DAILY_CAP` 2) and one perk per 7 days. No links in pushes.
- Notification permission (`POST_NOTIFICATIONS`) requested with an explanation; the app still works
  without push.
- Lock-screen content: pushes are private on the lock screen; another group's emergency shows no names.

## 6. Account deletion

- In app: Profile > Account > **Delete account** (immediate, `DELETE /api/me`).
- Web: `https://coroute.devmonks.space/delete-account` (Play "delete account URL" field). Today the
  page offers an e-mail request; **align its "24 to 48 hours" with privacy.html "within 30 days"**
  and state what is kept (payment records for tax **[LEGAL REVIEW]**, suppression hash).

## 7. Target API and technical requirements

| Requirement | Status |
|---|---|
| Target API level | **targetSdk 36** (Play requires API 36 for app updates from 31 Aug 2026; new apps likewise) — met |
| App Bundle | `flutter build appbundle --release` |
| Play App Signing | Accept; add the App signing SHA-256 to `gateway/public/.well-known/assetlinks.json` next to the upload key; deploy to both hosts |
| 64-bit | Flutter AAB includes arm64-v8a |
| Exported components | Only launcher/deep-link activity and the Medical ID tile service (protected); review `ShareInActivity` export (needs an intent filter for share) |
| Version code | next unused build number (`pubspec.yaml +N`) |

## 8. Testing tracks and closed testing requirement

Personal developer accounts created after 13 Nov 2023 must run a **closed test with at least 12
testers opted in for 14 continuous days** before applying for production (MASTER_AGENT_PROMPT 8.5).

1. Internal testing (team) → pre-launch report clean ([../technical/qa_test_plan.md §5](../technical/qa_test_plan.md#5-play-pre-launch-report-handling)).
2. Closed testing: ≥ 12 testers, 14 continuous days, collect feedback (Profile > Help > Send feedback).
3. Dashboard > Apply for production, answer honestly (who tested, what changed).
4. Production: India first, staged rollout 10 % → 50 % → 100 %, advance only with crash-free
   ≥ 99.5 % and no SOS/crash issue in 48 h.
5. Then set `PLAY_STORE_URL` in the gateway env and `LATEST_APP_BUILD` to the released build.

## 9. App content declarations (checklist)

- [ ] Privacy policy URL: `https://coroute.devmonks.space/privacy` (fix the findings in the privacy pack first).
- [ ] Ads: **No ads**.
- [ ] App access: reviewer account (e-mail + password) with a group plan assigned in `/admin`, or
      access mode Free; written steps (create ride, see map, SOS hold screen and cancel).
      Reviewer's emergency contact must be a team number (an SOS texts it automatically when
      SEND_SMS is allowed; cancelling within 10 s of the press texts nobody).
- [ ] Sensitive app permissions: SMS and Call Log form for `SEND_SMS` (section 3a) with video 2.
- [ ] Content rating questionnaire: users interact; location shared with other users; no violence etc.
- [ ] Target audience: **18+**.
- [ ] News / Government / Financial features: No. Health: user-entered emergency medical info only (not a health app).
- [ ] Data safety (section 2), account deletion (section 6), sensitive permissions (section 3).
- [ ] Store listing from `store/` (`LISTING.md`, icon, feature graphic, screenshots); category Maps &
      Navigation; **no prices or offers** in listing text; contact e-mail **[OWNER TO FILL]**;
      website `https://coroute.devmonks.space`.
