# Prompt for the next agent: finish, verify and deploy CoRoute v3.55

> **Use [DEPLOY_PROMPT_v3.55.md](DEPLOY_PROMPT_v3.55.md) instead (Nov 9, latest round).** It is the primary,
> self-contained prompt for the owner's coding agent: branch `release/v3.55.0`, secrets hygiene (incl. the
> DuckDNS token in `setup_new_vm.sh`), logical commits, build and tests from every round, owner-provided items
> (Firebase, DNS, DLT, Razorpay, Play Console), the two-VM deploy with the domain move to
> `coroute.devmonks.space`, one consolidated real-device safety gate (incl. push notifications, crew ride
> invites, pillion one-answer, trip head settings-only, domain fallback), drills, Play staged rollout and the
> report format. This file is kept as history and as the detailed per-round reference for device steps; where
> the two differ (branch name, `COROUTE_API` define, trip head rights, open decisions), DEPLOY_PROMPT wins.

You are taking over the CoRoute v3.55 release. Work in `wise-chandrasekhar/coroute_app` (git branch `release/v3.54.0-full`; all v3.55 work is UNCOMMITTED in the working tree). Flutter SDK is at `C:\Users\santhosh\flutter` (3.47.1). Safety comes first: never ship anything that could stop SOS, crash detection, emergency texts or the lock-screen Medical ID from working.

## 1. Read first (in this order)
1. `PROJECT_CONTEXT.md` (top section "Current state: v3.55")
2. `docs/V3_55_RELEASE.md`: every owner request and how it was built, compatibility notes, "Before release"
3. `docs/FEATURE_STATUS.md`: every feature, status, admin switch id, what is still pending
4. `docs/SAFETY_SCENARIO_REVIEW_v3.55.md`: real-time safety scenarios, 11 defects fixed, open risks
5. `docs/features_355/*.md`: road_context, sensor_safety, solo_guardian, group_safety, platform (thresholds, device checks, runbooks)
6. `docs/UX_NAMING_GUIDE_v3.55.md`: one name per concept; follow it for any new text
7. `docs/NEXT_RELEASE_PLAN_v3.55.md`: the owner's original plan
8. Deployment: `gateway/deploy/RUNBOOK.md`, `docs/PRODUCTION_TWO_VM_RUNBOOK.md`, `docs/features_355/platform.md`

## 2. What is already done (do not redo)
- Owner requests: riding roles Lead/Middle/Sweeper with swap and an automatic-roles toggle (off by default; an automatic lead has no lead rights); admin "Change plan" now creates real memberships; data cleanup removes memberships (with a mass-deletion guard); bigger map icons; stabilised fuel auto-route; guest mode removed completely; no mock or sample data; website redesigned with live usage and impact numbers and "iOS coming soon"; dwell-based place reviews with photos and moderation; "route to group" when off route; historic places on the way; pothole/speed-breaker/rough-road warnings from the lead, saved for later rides; bike and rider/pillion swap; bike details (cc, colour, cooling) with engine-rest advice; admin Feature switches (SOS, crash detection, emergency texts and Medical ID locked on).
- All 21 features of the v3.55 plan (bend warning, speed limits, altitude, night care, fatigue score, rider-down, crash learning, mount check, SOS battery reserve, safety report, solo ETA check-in, no-signal ahead, arrival message, public-rider help, roll call, missing-rider check, stretch alert, regroup point, group break planner, buddy pairs, risky stretch) plus admin warnings delivery; the offline crash queue was retired (duplicate of the pending-SOS store); voice-command/siren services no longer start at launch.
- Verified so far (without a Flutter engine): `dart analyze lib test` = No issues; gateway `npm test` = 794/795 (the one failure is the timing-flaky `public_ride_mirror` two-node test, which passes when re-run alone). Dart tests were only run through a stand-in, never with `flutter test`. Nothing has run on a phone or been deployed.
- Retired files were moved to `coroute_app/_to_delete/v355_retired/` (delete that folder).

## 3. Your tasks, in order (stop and report at any failed safety gate)
1. Branch and baseline: create branch `release/v3.55.0` from the current working tree. Delete `_to_delete/`. Do NOT commit secrets: `CLUSTER_CREDENTIALS.md`, `.env`, `android/key.properties`, keystores must stay out of git (check `.gitignore`; if any secret file is tracked, remove it from the index and tell the owner). Commit in logical chunks (gateway, app services, app UI, website, docs, tests).
2. Build checks: `flutter pub get`, `flutter analyze`, `flutter test`. Fix failures in the code under test, not by weakening tests, unless the test asserts on an intentionally changed string (see the UX guide). New Dart tests to watch: `test/*355*_test.dart`, `test/feature_flags_test.dart`, `test/garage_355_test.dart`, `test/road_context_355_test.dart`, `test/sensor_safety_355_*`, `test/group_safety_355_test.dart`, `test/solo_eta_check_in_test.dart`, `test/coverage_log_test.dart`, `test/roll_call_test.dart`, `test/admin_warnings_service_test.dart`. Then `cd gateway && npm ci && npm test` (all green; re-run the flaky mirror test alone if it fails).
3. Native: Android Gradle release build (`flutter build apk --release --split-per-abi`, **no** `COROUTE_API` define since the latest round: the app defaults to `coroute.devmonks.space` with a DuckDNS fallback; check the existing build scripts/release docs for the exact flags). Confirm the manifest permissions needed by new features (SMS send for solo check-in/emergency texts, location, notifications) match `docs/PLAYSTORE_PERMISSIONS.md`. iOS: `flutter build ios` must at least compile; App Store stays "coming soon".
4. Version: bump `pubspec.yaml` to `3.55.0+10019` and `gateway/package.json` to `3.55.0`; update the gateway's latest/minimum build settings only as the release docs describe (never raise the minimum build in this release; existing 3.54 users must keep working).
5. Real-device safety gate (2–4 Android phones, one ride as a group, one solo). Must pass before any production deploy:
   - SOS hold, durable delivery, SMS fallback with mobile data off, lock-screen Medical ID; crash alarm test path; "Bike down?" on a parked bike tipped over vs side stand vs phone into pocket.
   - Pothole/speed-breaker warnings from the lead reach the riders behind (voice, card, map); no warning during a crash alarm.
   - Roles: set Lead/Middle/Sweeper, swap, automatic roles with real spacing; position prompts spoken; owner keeps control.
   - Fuel auto-route with signal and in airplane mode (pump marked, retried, cleared on arrival).
   - Off-route "route to group", missing-rider check, stretch alert, buddy pairs (7+ riders, or test with the seat override), roll call, solo ETA check-in text.
   - Feature switches: turning a feature off in the admin console reaches phones within seconds; SOS/crash cannot be turned off; with the `bleRemote` and `offlineMesh` switches off, remote SOS and the mesh SOS beacon still work.
   - Mesh: it is UDP broadcast on a shared Wi-Fi hotspot only (no Bluetooth). Verify position + SOS between phones on one hotspot; record the real range. Voice/intercom needs internet.
   Record results in `docs/DEVICE_TEST_RESULTS_v3.55.md`. Tune thresholds only inside the documented ranges; any change to crash or SOS logic needs a regression test.
6. Security before deploy (`docs/features_355/platform.md`): rotate the leaked JWT secret (short grace window, 24–72 h, via JWT_SECRET_PREVIOUS) and the DB password (OCI console + Vault + restart order for both VMs). Never print or commit the values.
7. Deploy (two OCI VMs, follow `docs/PRODUCTION_TWO_VM_RUNBOOK.md` / `gateway/deploy/RUNBOOK.md`): take an encrypted backup first; deploy node 2, check `/api/meta` and health, run the failover drill, then node 1; collections `road_hazards`, `place_reviews`, road-risk and the feature-flags document are created automatically at start. After deploy: open Admin > Feature switches once (all on except as the owner decides), run Admin > Plans "Reconcile" once, check the website (impact numbers stay hidden until 10 rides exist; iOS shows "coming soon"), run the 30-minute soak test and set the live-rider cap. Publish the APKs and update `SHA256SUMS.txt` the way earlier releases did.
8. Rollback plan: any new feature misbehaving in production → turn its switch off in Admin > Feature switches (no redeploy). A gateway problem → redeploy the 3.54 gateway tarball (keep it) and restore from the pre-deploy backup only if data was harmed.
9. Docs: update `docs/FEATURE_STATUS.md` (move rows from "Needs device check" to "Stable" only with device evidence), `PROJECT_CONTEXT.md`, `PRODUCTION_RELEASE_TRACKER.md` (repo root) with build numbers, test results, deploy time and anything left open.

## 4. Open decisions to bring to the owner (do not decide alone)
- ~~"Need help" in the missing-rider check~~, ~~rename "Trip head"~~, ~~admin Warn text box~~, ~~place-review question after the ride~~: decided and built Nov 9 (see `docs/V3_55_RELEASE.md` §1d).
- ~~Own domain instead of DuckDNS~~: decided, `coroute.devmonks.space` (`docs/DOMAIN_MIGRATION_devmonks.md`).
- ~~Optional per-bike "Speedometer offset"~~: decided no.
- Replace the hotspot-only mesh with Google Nearby Connections (Bluetooth + Wi-Fi Direct, ~50–200 m, no setup) for position and SOS?
- Products decisions listed in `docs/UX_NAMING_GUIDE_v3.55.md` section 4 and the original plan's owner decisions.

## 5. Report back
A short summary: branch and commits, flutter/gateway test results, device test results (pass/fail per item), what was tuned, deploy steps done with times, current production version, switches left off, and remaining risks.

---

# Update Nov 9, 2026: sound, calls, live settings round

The branch is now `release/v3.55.0`. Everything above still applies; add the steps below.

Paste everything below into Claude Code opened on the CoRoute repository (app + `gateway/`), on a machine
that has **Flutter 3.47.1, the Android SDK / Gradle, adb and 2–4 Android phones** (at least one Android 14+,
and one Bluetooth helmet set). Never paste secrets into chat, docs or commits; secrets live in OCI Vault.

---

You are taking CoRoute v3.55 from "code-complete" to "released". The code was written and checked
without a Flutter engine or an Android SDK: the Dart was analyzer-checked and pure logic was run with
plain `dart`, but **no Flutter test has run, no APK has been built, and the round-3 Kotlin has never been
compiled**. Read first: `docs/V3_55_RELEASE.md`, `docs/FEATURE_STATUS.md`, `docs/SAFETY_SCENARIO_REVIEW_v3.55.md`,
`docs/SETTINGS_LIVE_AUDIT_v3.55.md`, `docs/features_355/audio_and_calls.md`,
`docs/features_355/sound_awareness_and_intercom.md`, `docs/features_355/platform.md`.

## Step 1: make it build

1. `flutter pub get && flutter analyze` (fix errors only).
2. `flutter test`. New or changed suites to watch: every `test/*355*_test.dart`, `test/speed_audio_policy_test.dart`,
   `test/call_alert_queue_test.dart`, `test/audio_and_calls_355_test.dart`, `test/crash_alarm_screen_test.dart`,
   `test/phone_call_and_fuel_safety_test.dart`, `test/audio_priority_and_fatigue_test.dart`,
   `test/feature_flags_test.dart`, `test/garage_355_test.dart`. Fix the code, not the tests, unless a test
   asserts an intentionally changed string.
3. **Compile the round-3 native code** (first time ever): `flutter build apk --debug`, then
   `flutter build apk --release --split-per-abi`. Files: `android/app/src/main/kotlin/space/devmonks/coroute_app/`
   `TtsChannel.kt`, `MediaVolumeGuard.kt` (new), `PhoneCallChannel.kt`, `RideNotification.kt`, `MainActivity.kt`,
   plus `AndroidManifest.xml`, `res/layout/ride_notif_expanded.xml`, `android/settings.gradle.kts`.
   Fix compile errors with the smallest change and note each one.
4. Gateway: `cd gateway && npm ci && npm test` (new: `config_live_355`, `rider_vehicle_355`; the
   `public_ride_mirror` two-node test is known to be timing-sensitive).

## Step 2: device checks (record phone model, Android version, result, notes for each)

### Live settings
- Change the group speed limit and the personal speed warning mid-ride: the stricter one warns at the next fix; the cockpit chip and lock-screen line agree.
- Town / near-stop limit warns near a planned stop.
- Group sliders: drag shows the value, one change sent on release; other riders see it.
- Change the active garage bike mid-ride: the colour (and model on the rider card) updates on other phones within a second; a second change within 10 s follows after the window.
- Turn crash detection off during a test countdown: the alarm keeps running with "Crash detection is off for new alarms. This alarm is still running: tap I'm OK to cancel it." (screen and notification).
- Lock-screen visibility switch updates the posted notification. Admin `intercom` off during a held PTT ends the talk for listeners.

### Music, alerts, calls
- With Spotify, YouTube Music and JioSaavn playing: an ordinary line lowers the music and it returns about 0.7 s after; with "Pause music during alerts" it pauses and resumes.
- Critical line (test SOS / crash countdown): music pauses; the line is heard with media volume at 0; with Do Not Disturb on after granting CoRoute DND access, the critical and SOS channels still sound. With a Bluetooth helmet set or earbuds, the line plays in the headset (media speech, volume floor 60 %) and not on the phone speaker.
- "Lower music when speeding" (use a GPS simulator or a safe test road): 10 % over for 4 s → 60 %, 25 % → 30 %, 40 % → paused + "Slow down" line; back 3 km/h under for 5 s → restored. Change the volume yourself while lowered: CoRoute stops touching it. Kill the app while lowered: volume restored at the next start. Test a Bluetooth absolute-volume headset.
- Phone calls: while ringing, ordinary lines wait and a critical line plays in full; on a call, a critical alert gives a short tone and phrase in the earpiece / helmet call link, **not heard by the caller** (ask the caller), plus buzz and heads-up; after the call, "Safety alert during your call: …" then "While you were on the call: …". Test without READ_PHONE_STATE (Android 12+ audio-mode path; older phones poll). Hands-free talk comes back after the call.
- Full-screen intent: another rider's SOS over the lock screen; on Android 14+ with full-screen denied, a heads-up instead.

### Lock screen and intercom
- Ride notification shows speed (rounded to 5), limit, next warning, intercom state.
- Screen locked: **Talk** arms hands-free, **Mute** stops hearing the group, both without unlocking (Android 14: microphone foreground service from a notification action). `adb shell dumpsys activity services space.devmonks.coroute_app` shows `foregroundServiceType=0x88` while the mic is in use.
- Hands-free at 60–100 km/h with a helmet mic: hard breathing and wind gusts do not open the gate; speech opens it within about 40 ms with the first syllable intact. Listeners hear no blasts from a loud rider.
- Data saver on: listeners hear 8 kHz voice at the right speed; toggling it during hands-free gives no audible gap.

### Sirens and horns
- Siren recordings (wail, yelp, hi-lo incl. Indian 1050/700 Hz) at about 10 m with the phone on a **handlebar mount, in a tank bag and in a jacket pocket**, at 40–60 km/h and at 80 km/h: alert time, spoken line, cockpit card, intercom lowered; with ANC earbuds + music (spoken in the earbuds, not the speaker) and with the phone speaker (tone only). Expect pocket-at-speed misses; record them.
- Screen locked: the spoken siren alert still plays.
- Horns: two close horns → "Horn close by. Check your mirrors." with earbuds / helmet set / music (Automatic); nothing on the speaker with Automatic, vibration + card with On; own horn ignored.
- Bluetooth headset: detection keeps music in A2DP stereo (no SCO) and always uses the phone's built-in mic; hands-free uses the phone mic too (Nov 9); push-to-talk uses the helmet mic while held; a headset change re-plans the mic within 15 s.
- Battery under 15 % (not charging): detection pauses, intercom still works.
- Admin `sirenDetector` off (or Siren alerts off): the Android mic indicator goes off within a second when the intercom is idle; any siren duck is lifted.
- Ride 20–30 min in normal traffic with detection on: count false siren alerts (lab result was 0 in 20 min of synthetic audio).

### Owner decisions round (Nov 9)
- **Siren with ANC earbuds**: noise cancellation on, music playing, phone on the mount; play a siren recording near the phone (not the earbuds). Music pauses, the line is heard **in the earbuds only** (not on the phone speaker), clearly even with a low media volume; volume and music come back after; lock-screen heads-up with the screen off. Then phone speaker, no music: tone + vibration + card, no speech. No group card is sent.
- **Helmet set mic routing**: during detection `adb shell dumpsys audio` shows capture on `AUDIO_DEVICE_IN_BUILTIN_MIC` with no SCO and music in A2DP stereo; push-to-talk held → helmet mic (SCO), released → back to the built-in mic; hands-free → phone mic (listeners can understand you from a mount / tank-bag phone at 40–80 km/h); wired earphones with an in-line mic → detection still on the built-in mic. Critical lines (test SOS) play in the headset, not the speaker; unplug → alarm stream on the speaker.
- **Horns on Automatic**: no headset and no music → the mic indicator stays off for horns (with Siren alerts off); connect earbuds → within ~3 s the mic opens and two horns give "Horn close by".
- **Speed vs a GPS app**: run a GPS speed app (or a second phone) beside CoRoute at steady 40, 60, 80 km/h: within ±1–2 km/h; note the bike speedometer (expect a few km/h higher). Under trees / in a town on a route ride the speed does not freeze; stopping reads 0 within ~2 s and stays 0 while parked.
- **Hold Send SOS**: trigger the missing-rider check (stop while the group moves on); a short tap on the red "Send SOS · hold to send" sends nothing; a 1.5 s hold (with gloves) sends the real SOS (group, contact, SMS fallback) and closes the card; "Need help" only asks the group to wait.
- **Chips while moving**: off-route, swap ask, historic place and place review show one voice line + a chip without buttons at speed, and the full card with buttons after stopping (≤ 3 km/h for 5 s); a pillion's phone shows the buttons while moving. After the ride, "Rate places from your ride" (at most 2).
- **Trip head rights** (second owner decision): the trip head can change the trip's group settings only (no removing riders, no ending the trip, no pause / roles / stops as such; End Ride shows for the trip owner only); a Lead the owner picked can change settings and pause / resume but not end; an automatic lead has no management rights. Check the manage-riders sheet shows the one-line role explanations.
- **Medical info**: with medical info in the profile (no switch), open a test SOS: the group, a guardian link and an accepted responder from another group see it; after resolving, it is gone.
- **Failover drill additions**: a pending swap ask survives stopping the primary VM; a two-node split with automatic roles ends with one Lead.

### Social, score, website, marketing, bikes (Nov 9, round 4)
Read first: `docs/features_355/usernames_friends_profiles.md`, `rider_score.md`, `crews_polls.md`, `marketing_studio.md`, `bike_markers_pillion.md`. New Dart suites for Step 1: `test/username_rules_test.dart`, `test/rider_score_355_test.dart`, `test/crews_polls_355_test.dart`, `test/marketing_template_355_test.dart`, `test/bike_markers_garage_355_test.dart`. New gateway suites (already green here): `usernames_friends_355`, `rider_score_355`, `crews_polls_355`, `marketing_templates_355`, `pillion_seat_355`, `public_stats_alltime_355`, `website_leaderboard_355`.
- **Bike markers legibility**: a group ride with 4+ phones on different bike types and colours (incl. white, black and an electric scooter). On the map, in daylight on the mount and on the dark map style: each bike shape and colour is recognisable at normal zoom; ring colour (moving / stopped amber / SOS red), role letter (L / S), status dot and "me" glow still read at a glance; the bike faces its direction of travel and the heading arrow points right; a stale rider fades. Pan / zoom with 10+ riders stays smooth (no jank; markers are cached per type / colour / size).
- **Two-rider bike**: a seated pillion has no own marker; the rider's bike shows two people and the label "Asha + Kiran"; TalkBack reads "…with pillion Kiran…"; on the pillion's phone the pair follows the pillion's own position; switch off the rider's data for 30 s: the pair stays on the map (carried by the pillion's position).
- **Complete-bike sheet on join / create**: with a bike missing its type or mileage, Create ride and Join with code open "Complete your bike" pre-filled (model preset, type guess); "Save and continue" goes straight on; closing the sheet only cancels that create / join; an electric bike asks no engine or tank; "I'm riding pillion (no bike)" on join leads to the pillion pick. SOS works from the home screen with an incomplete bike. Existing riders with an incomplete bike are asked once on Home.
- **Pillion seat flow on 2–3 phones**: the pillion picks the bike in "Whose bike are you on?" and confirms; every phone shows / speaks "Kiran is riding pillion with Asha"; the rider gets "Kiran is riding pillion with you" with **Decline** for 60 s (a chip while moving), later **Remove pillion** on the rider card; decline → the pillion is asked to pick again; rider leaves → the pillion is asked to pick again; moving to another bike tells the first rider. With the admin `pillionSeat` switch off, the old link and separate markers come back. Crash test / SOS from the pillion's phone works exactly as before; other phones count the bike once in the missing-rider check, spread and stretch alert (each of the pair's two phones still asks its own "Are you OK?"; note what the lead sees when neither answers).
- **Profile photo upload**: camera and gallery, portrait and landscape, a large HEIC / PNG; the picture appears on My profile, to a friend and on the ride rider card within seconds; remove picture → initials; admin "Remove profile picture" works. Check that no location EXIF remains (download via the avatar URL and inspect).
- **Username**: a new account gets a generated name; change it (live availability: Available / taken / not allowed); a second change inside 30 days is refused with the date; capitals-only change works.
- **Friend invite link opens the app**: share the invite from My profile via WhatsApp; tap on a second phone with the app installed (signed in → request sent; signed out → after sign-up the inviter gets the request); without the app → download page that never names the inviter. Friend request / accepted notices: snackbar in the app, system notification during a ride (channel `coroute_social`). Block hides your profile from them and they are not told.
- **Crews invite / poll**: create a crew, invite two friends (only friends are listed), each accepts; make one co-admin; start a poll (single choice, then multiple choice, then anonymous and the "Ride date" template); vote on two phones and watch the bars update live; close early; a member cannot start a poll until "Members can create polls" is on; admin leaves → hand-over picker. Badge on "My profile & friends" counts invitations and unanswered polls. Admin console "Crews" can delete a poll and a crew.
- **Rider score and leaderboards**: after 3 rides of 10 km or more the score, level and tips appear; turning off "Use my ride safety report for my rider score" shows Smoothness as "Not measured yet"; the leaderboard screen shows "You: #n"; turning off "Show my username on public leaderboards" removes you from the website within 5 minutes.
- **Marketing studio export / share** (admin phone or tablet): start from each starter, bind an active coupon, move / resize / rotate a layer, add a QR code and scan it (opens `<server>/get?coupon=CODE`), Save; **Share PNG** and **Share all sizes** into WhatsApp and "Save image" / Files; check the 1080x1920 and 1200x628 re-layouts need no manual fix; an expired coupon asks for confirmation.
- **Website**: home "CoRoute impact, all time" tiles and `/leaderboard` on a real phone and a desktop, light and dark; the leaderboard section stays hidden until at least one rider has passed the 3-ride rule (10 km+ rides, username, leaderboard on), so an empty board right after launch is expected.

## Step 3: deploy (unchanged from earlier rounds, see `docs/features_355/platform.md`)

1. Bump versions (pubspec and gateway), update SHA256SUMS.
2. Deploy the gateway to both OCI VMs; run the failover drill and the 30-minute soak; write the measured cap into `LIVE_RIDER_CAP`.
3. Open Admin > Feature switches once: the new switches `speedAudio`, `callAwareAlerts`, `voiceCleanup`, `riderVehicleLive` appear (default on). Run Admin > Plans "Reconcile" once.
   Round 4: the switches `friends`, `profilePhotos`, `crews`, `crewPolls`, `riderScore`, `leaderboard`, `marketingStudio`, `pillionSeat` also appear (default on). Then run the **username backfill once** as master admin: `POST /api/admin/usernames/backfill` (idempotent; the startup job also runs it under the `username-backfill` lease, this makes sure every older account has a username before the website leaderboard and friend search are used). Confirm `GET /api/public/alltime-stats` answers and the `rider-score-daily` and `public-stats` jobs run on one node only.
4. Rotate the leaked JWT secret and DB password with the short grace window (runbook in platform.md). Do not print secret values anywhere.
5. Publish the APK; Play Store listing; iPhone TestFlight.

## Report back

What you fixed to build (file + one line each), test results, the device-check table (pass / fail / notes per
phone), false-alarm count from the real ride, and anything you switched off with an admin switch and why.
Update `docs/FEATURE_STATUS.md` statuses from "Needs device check" to "Stable" only for rows you actually
checked on a phone.
