# CoRoute v3.55 deployment prompt (primary)

Written Nov 9, 2026. This is the one prompt to paste into the owner's coding agent to take v3.55 from
"code-complete" to "released". It replaces the step lists in `docs/NEXT_AGENT_PROMPT_v3.55.md` (that file
stays as history and as a detailed reference for each round's device checks).

How to use it: open Claude Code (or your coding agent) on the owner's Windows machine in the repository
`wise-chandrasekhar/coroute_app`, then paste everything below the line. Have 2–4 Android phones, a USB
cable, and access to the OCI console / OCI CLI ready. Never paste a secret into the chat.

---

You are releasing **CoRoute v3.55** (Flutter app + Node gateway + website). Safety comes first: never ship
anything that could stop SOS, crash detection, emergency texts or the lock-screen Medical ID from working.

**Environment.** Repository `wise-chandrasekhar/coroute_app` on the owner's Windows machine, branch
`release/v3.55.0` (all v3.55 work is in the working tree, mostly uncommitted). Flutter SDK
`C:\Users\<you>\flutter` (Flutter 3.47.1; check with `flutter --version`). The gateway is in `gateway/`
(Node 20+). Production is two OCI VMs behind an OCI Network Load Balancer, database on Oracle Autonomous DB,
secrets in **OCI Vault** (fetched at boot by `coroute-secrets.service` into `/run/coroute/secrets.env`,
OCIDs listed in `/etc/coroute/secret_ids.env`), non-secret settings in `/etc/coroute/gateway.env`.

**What was verified before you.** The code was written and checked without a Flutter engine, an Android SDK
or phones: Dart was analyzer-checked (`dart analyze lib test`: no issues) and pure logic ran with plain `dart`;
the gateway suite passed in full (`npm test`: 904 / 904 in the docs agent's run on Nov 9, Linux, Node 20+). **No `flutter test` has run, no APK has been built, and the new
Kotlin has never been compiled. Nothing has run on a phone or been deployed.**

## Ground rules (apply to every step)

1. **Stop-and-report gates.** Each step ends with a gate. If a gate fails, stop, write down what failed
   (command, output summary, file), and report to the owner before going on. A failed **safety** check
   (SOS, crash alarm, emergency texts, Medical ID, critical audio) means: do not publish the app to Play,
   do not raise any build setting, and report.
2. **Secrets.** Never print, paste, commit or copy a secret value into a doc, a commit, a log you share, or
   the chat. Read them from where they live (OCI Vault, `/etc/coroute/*.env` on the VMs, `~/.gradle/gradle.properties`
   on the build machine, CI secrets). Never open or quote `gateway/deploy/CLUSTER_CREDENTIALS.md` or copy
   values out of `gateway/deploy/setup_new_vm.sh`.
3. **Ask the owner, never invent.** Anything in "Owner-provided items" (Step 5) must come from the owner.
   If you need it and do not have it, ask and wait; carry on with the steps that do not depend on it.
4. **Fix code, not tests.** When a test fails, fix the code under test. Change a test only when it asserts a
   string that was changed on purpose (see `docs/UX_NAMING_GUIDE_v3.55.md`), and say so in the commit.
5. **Small changes.** Fix build errors with the smallest change and list each one (file + one line). Tune
   thresholds only inside the ranges in the feature docs; any change to crash or SOS logic needs a
   regression test.
6. **Never raise `MIN_APP_BUILD` in this release.** 3.54 users (DuckDNS built in) must keep working.

---

## Step 1. Read first (in this order)

1. `PROJECT_CONTEXT.md` (top section "Current state: v3.55").
2. `docs/V3_55_RELEASE.md`: every owner request and round, compatibility notes, "Before release".
3. `docs/FEATURE_STATUS.md`: every feature, status, admin switch id, what is still pending.
4. `docs/SAFETY_SCENARIO_REVIEW_v3.55.md`: real-time safety scenarios, defects fixed, open risks.
5. `docs/features_355/*.md`, in particular: `platform.md` (runbooks: secret rotation, Object Storage, drills),
   `push_notifications.md` (Firebase setup), `crews_polls.md` (crew ride invites), `bike_markers_pillion.md`
   (pillion seat, one answer per bike), `rider_score.md`, `usernames_friends_profiles.md`, `marketing_studio.md`,
   `audio_and_calls.md`, `sound_awareness_and_intercom.md`, `speed_accuracy.md`, `group_safety.md`,
   `sensor_safety.md`, `solo_guardian.md`, `road_context.md`.
6. `docs/DOMAIN_MIGRATION_devmonks.md`: the move to `coroute.devmonks.space` (DNS, Caddy, env, order).
7. `docs/SETTINGS_LIVE_AUDIT_v3.55.md` and `docs/UX_NAMING_GUIDE_v3.55.md` (one name per concept; use it for
   any text you touch).
8. Deployment: `gateway/deploy/RUNBOOK.md`, `docs/PRODUCTION_TWO_VM_RUNBOOK.md`,
   `gateway/deploy/PLAY_STORE_CHECKLIST.md`, `docs/PLAYSTORE_PERMISSIONS.md`.
9. `docs/NEXT_AGENT_PROMPT_v3.55.md`: detailed device steps from each round (this prompt consolidates them).

**Gate 1:** you can state, in five lines, what v3.55 adds, which admin switches exist, and the deploy order
(gateway VM2 → VM1, then the app). If any listed file is missing, report it.

## Step 2. Secrets hygiene (before any commit)

1. `git status --porcelain` and `git ls-files` must not show any of: `CLUSTER_CREDENTIALS.md`, `.env`
   (any `gateway/.env`, `gateway/deploy/.env`; `.env.example` is fine), `android/key.properties`, `*.jks`,
   `*.keystore`, `google-services.json`, any Firebase / Google service-account JSON, `secret_ids.env`, backups
   or dumps. If a secret file is **tracked**, remove it from the index (`git rm --cached <file>`), add it to
   `.gitignore`, and tell the owner (the value must then be rotated, because it is in history).
2. `gateway/deploy/CLUSTER_CREDENTIALS.md` is **untracked and not ignored** today. Add it to `.gitignore`
   (also add: `android/key.properties`, `*.jks`, `*.keystore`, `**/google-services.json`,
   `**/*service-account*.json`, `**/fcm*.json`, `.env`, `gateway/.env`, `gateway/deploy/.env`,
   `__pycache__/`, `*.whl`). Check with `git check-ignore -v gateway/deploy/CLUSTER_CREDENTIALS.md`.
3. Stray build files in the working tree: `qrcode-8.2-py3-none-any.whl` at the repo root and the
   `__pycache__` folders are not part of the product; do not commit them (delete or ignore).
4. Scan what you are about to commit for secrets: `git diff --cached | findstr /i /c:"PRIVATE KEY" /c:"AIza"
   /c:"password=" /c:"secret=" /c:"token="` (or `git secrets` / `gitleaks` if installed). Placeholders in `.env.example`
   and docs are fine; real values are not.
5. **Rotations to schedule** (do them in Step 6, server deploy, never print values):
   - The leaked **JWT secret** (old values are in git history): runbook in `docs/features_355/platform.md`
     "Rotating the leaked JWT secret", with a **short grace window of 24–72 h** via `JWT_SECRET_PREVIOUS`.
   - The leaked **database password**: `platform.md` "Rotating the leaked database password" (Vault, OCI
     console `ALTER USER`, restart VM2 then VM1 right away, outside peak hours).
   - The **DuckDNS token**: `gateway/deploy/setup_new_vm.sh` (legacy single-VM script) contains it in plain
     text. Ask the owner to regenerate it at duckdns.org, store the new value only in OCI Vault as
     `DUCKDNS_TOKEN` (it reaches Caddy through `/run/coroute/caddy.env`), and **remove the literal from
     `setup_new_vm.sh`** (read it from the environment instead, e.g. `${DUCKDNS_TOKEN:?set DUCKDNS_TOKEN}`).
     Do not copy the old value anywhere while editing. Purging git history (`git filter-repo --replace-text`)
     is optional; rotation is what closes the leak.

**Gate 2:** `git status` shows no secret file staged or tracked; `.gitignore` covers the list above; the
literal token is gone from `setup_new_vm.sh` (show the diff with the old line redacted).

## Step 3. Commit the working tree in logical commits

Never use `git reset --hard`, `git clean`, `git stash` or force-push on this branch unless the owner asks.

1. Confirm the branch: `git branch --show-current` = `release/v3.55.0`.
2. Delete `coroute_app/_to_delete/` (retired files, see `V3_55_RELEASE.md`) if it exists.
3. Commit in this order, each commit only its area (use `git add <paths>`, never `git add -A` before Step 2 is
   done):
   1. `gateway:` `gateway/src`, `gateway/public`, `gateway/scripts`, `gateway/deploy` (no secrets), `gateway/package*.json`.
   2. `gateway tests:` `gateway/test`.
   3. `app services:` `lib/core`, `lib/data`, `lib/domain`, `lib/main.dart`.
   4. `app UI:` `lib/presentation`, `assets`, `pubspec.yaml`, `pubspec.lock`.
   5. `android native:` `android/` (Kotlin, manifest, `res/`, Gradle files; never `key.properties` or keystores).
   6. `website:` website sources under `gateway/public` if not in commit 1 (split if that reads better).
   7. `docs:` `docs/`, `PROJECT_CONTEXT.md`, `PRODUCTION_RELEASE_TRACKER.md`, `store/`.
   8. `tests:` `test/`.
4. Messages say what changed and why in one line, then details.

**Gate 3:** `git status` is clean apart from ignored files; `git log --oneline` shows the commits; nothing in
`git show --stat` is a secret.

## Step 4. Build and test

### 4a. Flutter

```
flutter --version            # expect 3.47.1
flutter pub get
flutter analyze              # fix errors; warnings only if trivial
flutter test                 # full suite
```

Collect the v3.55 tests from every round with `ls test/*355* test/*_355_*` (PowerShell: `dir test\*355*`) and
run them first on their own (`flutter test test/<file>`). Key suites:

- Round 1–2 (roles, roads, safety): `road_context_355_test`, `road_places_355_test`, `road_care_service_355_test`,
  `heritage_places_355_test`, `off_route_group_355_test`, `sensor_safety_355_test`,
  `sensor_safety_355_service_test`, `group_safety_355_test`, `garage_355_test`, `vehicle_swap_355_test`,
  `feature_flags_test`, `solo_eta_check_in_test`, `coverage_log_test`, `roll_call_test`,
  `admin_warnings_service_test`.
- Round 3 (sound, calls, live settings): `audio_and_calls_355_test`, `siren_detector_355_test`,
  `voice_cleanup_355_test`, `settings_live_355_test`, `group_settings_release_355_test`,
  `rider_vehicle_355_test`, `speed_audio_policy_test`, `call_alert_queue_test`, `crash_alarm_screen_test`,
  `phone_call_and_fuel_safety_test`, `audio_priority_and_fatigue_test`, `speed_estimator_test`.
- Owner decisions (Nov 9): `missing_rider_sos_355_test`, `ride_taps_and_reviews_355_test`,
  `medical_info_share_test`, `admin_warn_text_test`.
- Round 4 (social, score, bikes): `username_rules_test`, `rider_score_355_test`, `crews_polls_355_test`,
  `marketing_template_355_test`, `bike_markers_garage_355_test`, `pillion_group_safety_355_test`.
- Latest round (push, crew rides, domain): `push_routing_355_test`, `crew_ride_invites_355_test`,
  `gateway_hosts_test`, `app_config_https_test`.

Fix the code under test, not the test, unless the test asserts an intentionally changed string (for example
"Ace Rider" replaced "Road Captain"; trip head texts).

### 4b. Gateway

```
cd gateway
npm ci
npm test
```

All must pass. Known timing-sensitive tests: `public_ride_mirror` (two-node replication),
`two_node_failover` (hand-back), `job_lease` ("real timers: two nodes") and the login performance test. If
one fails, re-run it alone (`node --test test/<file>.test.js`); it must pass alone and you note it. Any
other failure is real. New suites in this release include `push_355`, `crew_ride_invites_355`,
`domain_migration`, `pillion_seat_355`, `crews_polls_355`, `usernames_friends_355`, `rider_score_355`,
`website_leaderboard_355`, `public_stats_alltime_355`, `marketing_templates_355`, `config_live_355`,
`rider_vehicle_355`, `feature_flags_355`, `group_safety_355`.

### 4c. Android release build

1. **First compile of the new Kotlin** (never compiled before) in
   `android/app/src/main/kotlin/space/devmonks/coroute_app/`: `MediaVolumeGuard.kt` (new), `TtsChannel.kt`,
   `PhoneCallChannel.kt`, `RideNotification.kt`, `PushChannel.kt` (new), `CoRouteMessagingService.kt` (new),
   `MainActivity.kt`, plus `AndroidManifest.xml`, `res/layout/ride_notif_expanded.xml`,
   `android/settings.gradle.kts`, `android/app/build.gradle.kts` (Firebase BoM 33.7.0 + `firebase-messaging`,
   no google-services plugin). Start with `flutter build apk --debug`. Fix compile errors carefully, one at
   a time, smallest change, and list each (file + one line). Do not remove a safety path to make it compile.
2. **Firebase client values** (Step 5 item 1) go to the build as Gradle properties or environment / CI
   secrets, never into the repo: `COROUTE_FCM_APP_ID`, `COROUTE_FCM_API_KEY`, `COROUTE_FCM_PROJECT_ID`,
   `COROUTE_FCM_SENDER_ID` in `%USERPROFILE%\.gradle\gradle.properties` (or `-P...` / env vars). Without
   them the app builds with push off (no crash, no Settings switch); that build is fine for the first tests
   but not for release.
3. **No `COROUTE_API` define.** The app's default host is `https://coroute.devmonks.space` with an automatic
   fallback to `https://coroute.duckdns.org` (`lib/core/config/app_config.dart`,
   `lib/core/config/gateway_hosts.dart`). An explicit `--dart-define=COROUTE_API=...` turns the fallback off,
   so do not pass it.
4. **Version.** `pubspec.yaml` must read `version: 3.55.0+<build>` and `gateway/package.json` `3.55.0`. The
   tree already says `3.55.0+10019` (3.54 was `+10018`). If build `10019` was ever uploaded to Play (any
   track) or published as an APK, use the next unused number. Set `LATEST_APP_BUILD` on the server to the
   build you publish. **Never raise `MIN_APP_BUILD`.**
5. Release builds (signing from `android/key.properties`, which stays out of git):
   ```
   flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64 --obfuscate --split-debug-info=build/symbols
   flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
   ```
   Keep `build/symbols` (not committed). Compute SHA-256 of both APKs for `SHA256SUMS.txt`.
6. Check the merged manifest permissions against `docs/PLAYSTORE_PERMISSIONS.md` (SMS send, location incl.
   background, notifications, microphone foreground service, full-screen intent, phone state optional,
   Do Not Disturb access) and that `CoRouteMessagingService` is declared `exported=false` with the
   `com.google.firebase.MESSAGING_EVENT` filter. App Links: two `autoVerify` hosts
   (`coroute.duckdns.org` and `coroute.devmonks.space`).
7. iOS stays "coming soon" (no `ios/` folder in this release); do not block on it.

**Gate 4:** `flutter analyze` clean, `flutter test` all green, `npm test` all green (flaky ones pass alone),
release APKs and AAB built, with the list of fixes you made. Any failure in a safety test (SOS, crash,
emergency SMS, Medical ID, critical audio, missing-rider SOS) = stop and report.

## Step 5. Owner-provided items (ask the owner; never invent or reuse old values)

| # | Item | What to ask for | Where it goes |
|---|---|---|---|
| 1 | **Firebase** | A Firebase project (Analytics not needed) with an Android app `space.devmonks.coroute_app`; the 4 client values (app id, API key, project id, sender id); FCM API (V1) enabled; a service account with role Firebase Cloud Messaging API Admin and its **JSON key**. Steps: `docs/features_355/push_notifications.md` "Owner setup". | Client values: build machine Gradle properties / CI secrets. Service-account JSON: OCI Vault (new secret, e.g. `coroute-FCM_SERVICE_ACCOUNT_JSON`, OCID added to `/etc/coroute/secret_ids.env` on both VMs as `FCM_SERVICE_ACCOUNT_JSON=<ocid>`), or a root-owned 0600 file and `FCM_SERVICE_ACCOUNT_FILE`. Never the repo. |
| 2 | **DNS** at the `devmonks.space` DNS provider | `coroute.devmonks.space` **A** → the NLB reserved public IP (same as `dig +short coroute.duckdns.org`), TTL 300; `_acme-challenge.coroute.devmonks.space` **CNAME** → `_acme-challenge.coroute.duckdns.org.`, TTL 300; optional CAA on the subdomain only. Also: domain auto-renew + registrar lock. | DNS provider console (owner). |
| 3 | **DLT SMS templates** (India) | Whitelist the URL `coroute.devmonks.space` in the DLT templates used for server SMS **before** `PUBLIC_ORIGIN` switches (operators block A2P SMS with non-whitelisted URLs). Test a live-link SMS on Jio, Airtel and Vi. | Owner's DLT / SMS provider portal. |
| 4 | **Razorpay** | Add the webhook `https://coroute.devmonks.space/api/subscription/webhook` (and `/api/membership/webhook` if used) with the same webhook secret; update the website URL in the Razorpay account / KYC. Keep the DuckDNS webhook until the new one shows deliveries, then remove it. | Razorpay dashboard (owner). |
| 5 | **Play Console** | Privacy policy URL `https://coroute.devmonks.space/privacy`, website URL, listing text (`store/LISTING.md`), Play App Signing SHA-256 (App integrity) for `assetlinks.json`, internal testers list. | Play Console (owner). |
| 6 | **DuckDNS token rotation** | Regenerate at duckdns.org and put it in OCI Vault `DUCKDNS_TOKEN` (Step 2.5). | OCI Vault. |
| 7 | Optional: Google Cloud OAuth web client origins | Add `https://coroute.devmonks.space` only if the web client lists JavaScript origins / redirect URIs. | Google Cloud Console. |

**Gate 5:** each item is either done by the owner (confirmed in writing) or explicitly deferred by the owner.
Items 2, 3 and 5 must be done before the app build with the new default host goes to Play (Step 8).

## Step 6. Server deploy (two OCI VMs, rolling, per `gateway/deploy/RUNBOOK.md` §7 and `docs/PRODUCTION_TWO_VM_RUNBOOK.md`)

1. **Back up first.** Take an encrypted DB backup (RUNBOOK §6b / the nightly backup script run by hand) and
   keep the 3.54 gateway tarball for rollback. Record the backup id and time.
2. **Environment** (`/etc/coroute/gateway.env` on **both** VMs; secrets only via Vault + `secret_ids.env`):
   ```
   PUBLIC_ORIGIN=https://coroute.devmonks.space
   LEGACY_ORIGINS=https://coroute.duckdns.org
   REDIRECT_LEGACY_HOST=false
   LATEST_APP_BUILD=<the build you publish>
   # MIN_APP_BUILD unchanged
   # FCM_SERVICE_ACCOUNT_JSON comes from Vault (secret_ids.env); FCM_PROJECT_ID optional
   ```
   Keep every existing variable (DB, JWT, MIRROR_KEY, SETTINGS_ENCRYPTION_KEY, Razorpay, SMS, VAPID,
   LIVE_RIDER_CAP, ...). Only set `PUBLIC_ORIGIN` after the DLT whitelisting (Step 5 item 3) if server SMS is on.
3. **Caddy, both names** (`gateway/deploy/caddy/Caddyfile.vm2` / `.vm1` serve
   `coroute.devmonks.space, coroute.duckdns.org`): needs the DNS records from Step 5 item 2 first
   (`dig @1.1.1.1` and `dig @8.8.8.8` agree). `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`;
   **VM2 first** `systemctl reload caddy`, wait for "certificate obtained successfully" for
   `coroute.devmonks.space` in `journalctl -u caddy`, **then VM1**. Check
   `curl -sI https://coroute.devmonks.space/api/health` = 200 with a valid certificate and the same on
   `coroute.duckdns.org`. If `dns_challenge_override_domain` does not validate, follow the fallback in
   `DOMAIN_MIGRATION_devmonks.md` step 2 (Caddy build with the provider's DNS plugin) and report.
4. **Secret rotations** (Step 2.5): JWT secret with `JWT_SECRET_PREVIOUS` (24–72 h grace; check
   `SETTINGS_ENCRYPTION_KEY` is deployed and the admin payment page opened once **before**), DB password, and
   the DuckDNS token. Restart order each time: VM2, then VM1
   (`sudo systemctl restart coroute-secrets && sudo systemctl restart coroute-gateway`). Log names only
   (never values) in `gateway/deploy/VM_OPERATIONS_LOG.md`. Put a reminder to remove `JWT_SECRET_PREVIOUS`
   at the end of the grace window.
5. **Deploy the gateway: VM2 first, then VM1** (RUNBOOK §7: `rsync -a --delete --exclude node_modules
   --exclude 'coroute*.apk'`, `npm ci --omit=dev`, restart). After each VM:
   - `/api/health`, `/api/health/live` and `/api/meta` answer 200 on that VM; `/api/meta` shows version 3.55.0
     and `downloadUrl` on `https://coroute.devmonks.space/download`.
   - The log has no "FCM not configured" (when the key is set) and shows the secrets loaded (names only).
   - A 3.54 app still signs in, joins a ride and talks.
   - Run the failover drill (stop VM1's gateway while a test ride runs on two phones; rides continue on VM2;
     start it again; hand-back works). A pending swap ask survives; a two-node split with automatic roles
     ends with one Lead.
6. **One-time admin actions** (as master admin, after both VMs run 3.55):
   - `POST /api/admin/usernames/backfill` once (idempotent). Confirm every older account has a username.
   - Admin > Plans **Reconcile** once (cleans leftover memberships).
   - Admin > **Feature switches**: all new ids present and on by default: `speedAudio`, `callAwareAlerts`,
     `voiceCleanup`, `riderVehicleLive`, `friends`, `profilePhotos`, `crews`, `crewPolls`,
     `crewRides`, `riderScore`, `leaderboard`, `marketingStudio`, `pillionSeat`, `pushNotifications`,
     besides the earlier 3.55 ids. `sos`, `crashDetection`, `emergencySms`, `medicalId` show as **locked on**
     (try to turn one off: it must be refused).
   - Jobs run on one node each under the job lease: `username-backfill`, `rider-score-daily`, `public-stats`.
7. **Website and links** on both hosts:
   - `GET /api/public/alltime-stats` and `GET /api/public/leaderboard` answer; the home "CoRoute impact, all time"
     tiles render (counts under 10 show 0, by design); `/leaderboard` stays hidden until a rider passes the
     3-ride rule (empty right after launch is expected).
   - `https://coroute.devmonks.space/` has `<link rel="canonical" href="https://coroute.devmonks.space/">`;
     `sitemap.xml` lists the new origin; iOS shows "coming soon".
   - `curl -s https://coroute.devmonks.space/.well-known/assetlinks.json` equals the DuckDNS copy (200,
     `application/json`, no redirect) and contains the Play App Signing SHA-256; Google's checker
     (`digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://coroute.devmonks.space&relation=delegate_permission/common.handle_all_urls`) lists it.
   - `./deploy/smoke_test.sh https://coroute.devmonks.space` and `./deploy/smoke_test.sh https://coroute.duckdns.org` pass.
8. **HSTS:** only after the checks above pass, raise the new host's HSTS in both Caddyfiles from
   `max-age=300` to `max-age=31536000` (no `includeSubDomains` on `devmonks.space`), reload VM2 then VM1.
   This is an owner decision point: confirm with the owner first.
9. Publish the APKs on the gateway (RUNBOOK §4) or Object Storage (Step 9) and update `SHA256SUMS.txt`.

**Rollback:** a new feature misbehaving → turn its switch off in Admin > Feature switches (no redeploy). A
gateway problem → redeploy the 3.54 tarball on that VM (VM1 first if VM2 is healthy, and vice versa);
restore from the backup only if data was harmed. A domain problem → the app falls back to DuckDNS by itself;
leave `PUBLIC_ORIGIN` empty and restart to return links to DuckDNS.

**Gate 6:** both VMs on 3.55, health green on both hosts, failover drill passed, backfill and Reconcile done,
switches list complete with safety ids locked, assetlinks verified on both hosts. Anything red = stop.

## Step 7. Real-device safety gate (2–4 Android phones; one group ride and one solo ride)

Install the release APK on every phone (at least one Android 14+, one older Android 10–12, one Bluetooth
helmet set, ANC earbuds if possible). Record for each check: phone model, Android version, pass / fail, notes.
Write the table to `docs/DEVICE_TEST_RESULTS_v3.55.md`. **Any safety failure (section A, and the safety lines
in B–E) = stop; do not publish the app to Play.** Detailed steps per check are in
`docs/NEXT_AGENT_PROMPT_v3.55.md` and the feature docs; pass criteria are below.

### A. SOS, crash, medical (safety)
| Check | Pass when |
|---|---|
| SOS hold from home and cockpit | Group, emergency contact and guardian get it; delivery is durable (survives app kill / reconnect). |
| SMS fallback | With mobile data off but signal on, the SOS goes out by SMS. |
| Lock-screen Medical ID | Opens from the lock screen; shows the entered medical info. |
| Crash alarm test path | 15 s countdown, loud alarm, "I'm OK" cancels; uncancelled sends the SOS. |
| Crash detection switched off during a countdown | The running alarm continues with "Crash detection is off for new alarms. This alarm is still running: tap I'm OK to cancel it." |
| "Bike down?" | Fires for a parked bike tipped over; not for the side stand or phone into a pocket. |
| Critical lines with media volume 0 / Do Not Disturb (DND access granted) | Critical and SOS channels still sound; with a headset they play in the headset. |
| Full-screen SOS from another rider | Over the lock screen; on Android 14+ with full-screen denied, a heads-up instead. |
| Medical info to helpers | During a test SOS the group, a guardian link and an accepted responder from another group see the medical info, and the accepted responder also sees the emergency contact (owner decision: yes); after resolving it is gone. |
| Pillion phone SOS / crash | Works exactly as on a rider's own bike; the merged marker turns red. |
| Feature switches | `sos`, `crashDetection`, `emergencySms`, `medicalId` cannot be switched off; with `bleRemote` and `offlineMesh` off, remote SOS and the mesh SOS beacon still work. |

### B. Live settings changes mid-ride
| Check | Pass when |
|---|---|
| Group speed limit and personal speed warning | The stricter one warns at the next fix; cockpit chip and lock-screen line agree. |
| Town / near-stop limit | Warns near a planned stop. |
| Group sliders | Value shows while dragging; one change sent on release; other riders see it. |
| Active garage bike changed mid-ride | Colour (and model on the rider card) updates on other phones within a second. |
| Lock-screen visibility switch | Updates the posted notification. |
| Admin `intercom` off during a held push-to-talk | Talk ends for listeners. |

### C. Speed vs GPS
| Check | Pass when |
|---|---|
| Steady 40 / 60 / 80 km/h beside a GPS speed app | Within ±1–2 km/h (the bike speedometer reads a few km/h higher; expected, no offset setting: owner decided no). |
| Under trees / in town on a route ride | Speed does not freeze; stopping reads 0 within ~2 s and stays 0 parked. |

### D. Music, calls, notifications on the lock screen
| Check | Pass when |
|---|---|
| Ducking with Spotify, YouTube Music, JioSaavn | Ordinary line lowers music; it returns ~0.7 s after. With "Pause music during alerts" it pauses and resumes. |
| Critical line during music | Music pauses; line heard. |
| "Lower music when speeding" | 10 % over for 4 s → 60 %, 25 % → 30 %, 40 % → paused + "Slow down"; 3 km/h under for 5 s → restored. Manual volume change stops CoRoute touching it; app kill while lowered → restored at next start. |
| Calls ringing / on a call | Ordinary lines wait; a critical alert gives a short tone + phrase in the earpiece / helmet link, **not heard by the caller**; after the call "Safety alert during your call: ..." then "While you were on the call: ...". Works without READ_PHONE_STATE. Hands-free comes back after the call. |
| Lock screen ride notification | Shows speed (rounded to 5), limit, next warning, intercom state. |
| Lock screen **Talk** / **Mute** | Work without unlocking (Android 14: `dumpsys activity services space.devmonks.coroute_app` shows `foregroundServiceType=0x88` while the mic is used). |

### E. Sirens, horns, intercom voice
| Check | Pass when |
|---|---|
| Sirens (wail, yelp, hi-lo incl. Indian 1050/700 Hz) at ~10 m; phone on mount, tank bag, jacket pocket; 40–60 and 80 km/h | Alert time, spoken line, cockpit card, intercom lowered are recorded; pocket-at-speed misses are recorded (expected). |
| Sirens with **ANC earbuds** + music | Music pauses, line heard **in the earbuds only**, clear at low media volume; music back after; heads-up with screen off. No group card. |
| Sirens with **helmet set** | Detection on the phone's built-in mic (`dumpsys audio`: `AUDIO_DEVICE_IN_BUILTIN_MIC`, no SCO, music stays A2DP); critical lines in the headset. |
| Sirens on the **phone speaker**, no music | Tone + vibration + card, no speech. |
| Horns | Two close horns → "Horn close by. Check your mirrors." with earbuds / helmet / music (Automatic); nothing on the speaker with Automatic; own horn ignored; mic indicator off for horns with no headset and no music. |
| Mic routing | Push-to-talk held → helmet mic; released → built-in; hands-free → phone mic; headset change re-planned within 15 s. |
| Switch off (`sirenDetector`) | Mic indicator off within a second when the intercom is idle. Battery < 15 %: detection pauses, intercom works. |
| Intercom voice cleanup at 60–100 km/h | Breathing and wind gusts do not open the hands-free gate; speech opens it within ~40 ms with the first syllable intact; no blasts for listeners; data saver gives 8 kHz voice with no gap. |
| 20–30 min ride in normal traffic | Count false siren alerts (lab: 0 in 20 min; musical truck horns, beepers and ringtones must not alert). |

### F. Group roles, trip head, pillion, bikes (group ride)
| Check | Pass when |
|---|---|
| Roles | Set Lead / Middle / Sweeper, swap; position prompts spoken; automatic roles with real spacing; an automatic lead has no management rights. |
| **Trip head = settings only** | The trip head can change the trip's group settings only: cannot remove riders, end the trip, pause, set roles or stops; End Ride shows for the trip owner only; **choosing a trip head does not make them Lead** (riding roles unchanged). A Lead the owner picked can change settings and pause / resume, not end. Manage-riders sheet shows the one-line role explanations. |
| Pillion seat flow (2–3 phones) | Pillion picks the bike and confirms; everyone sees / hears "Kiran is riding pillion with Asha"; rider can **Decline** for 60 s (chip while moving), later **Remove pillion**; decline / rider leaves → pillion asked to pick again; `pillionSeat` off → old link and separate markers. |
| **Pillion pair: one answer counts for both** | Stop the pair's bike while the group moves on: both phones ask "Are you OK?"; answer on **either** phone (I'm OK, a stop reason, Need help) → the card closes on **both** phones and the lead gets at most one notice; no "no answer" for that stop. Neither answers → the lead gets **one** notice for the bike. SOS from either phone opens an alert on every phone. |
| Bike markers legibility (4+ phones, white / black bikes, an electric scooter) | Shape and colour recognisable at normal zoom in sunlight on the mount and on the dark map; ring / role letter / status dot / "me" glow read at a glance; faces direction of travel; stale rider fades; 10+ riders pan / zoom smoothly. Two-rider bike shows two people and "Asha + Kiran"; TalkBack reads "...with pillion Kiran...". |
| Complete-bike sheet | Create ride / Join with code with an incomplete bike opens "Complete your bike" pre-filled; "Save and continue" goes on; closing only cancels that create / join; electric asks no engine / tank; "I'm riding pillion (no bike)" leads to the pillion pick; SOS works from home with an incomplete bike. |
| Missing-rider **Send SOS** hold | Short tap sends nothing; 1.5 s hold with gloves sends the real SOS (group, contact, SMS fallback) and closes the card; "Need help" only asks the group to wait. |
| Chips while moving | Off-route, swap ask, historic place, place review: one voice line + chip without buttons at speed; full card after stopping (≤ 3 km/h for 5 s); a pillion's phone shows buttons while moving; after the ride "Rate places from your ride" (at most 2). |
| Earlier group checks | Pothole / speed-breaker warnings reach riders behind (none during a crash alarm); fuel auto-route with signal and in airplane mode; off-route "route to group"; stretch alert; buddy pairs (7+ or seat override); roll call; solo ETA check-in text; mesh position + SOS on one hotspot (record range). |

### G. Social, crews, push, domain, marketing
| Check | Pass when |
|---|---|
| Profile, username, photo | New account gets a generated username; change with live availability; second change inside 30 days refused with the date; photo from camera and gallery (HEIC / PNG, portrait / landscape) shows on profile, to a friend and on the rider card within seconds; no location EXIF in the downloaded avatar; remove → initials. |
| Friends + invite link on **both hosts** | Share the invite via WhatsApp; on a phone with the app, a `https://coroute.devmonks.space/join/friend/<code>` link **and** a `https://coroute.duckdns.org/join/friend/<code>` link open the app (signed in → request sent; signed out → request after sign-up); without the app → download page that never names the inviter. `adb shell pm get-app-links space.devmonks.coroute_app` shows both hosts `verified`. Ride join links `/join/<code>` on both hosts open the app. Block hides your profile silently. |
| Crews and polls | Create a crew, invite two friends (only friends listed), each accepts; co-admin; polls single / multiple / anonymous / "Ride date"; live bars on two phones; close early; member poll rule; admin leaves → hand-over; badge counts invites and unanswered polls; admin console can delete a poll and a crew. |
| **Crew ride invite, app killed** | Host (trip owner, with a group plan) taps **Start a ride** on the crew screen (or **Invite crew to my ride**), picks members ("Select all" works), sends; on the invitee's phone with CoRoute **force-stopped**, a "Ride invitation" notification arrives (high priority); tapping it opens the **Ride invitation** screen (host, crew, ride, start → destination names, riders "3 of 6 riders", Accept / Decline). **Accept** runs the normal join: profile check, permissions, **Complete your bike** or "I'm riding pillion", then the pre-ride checklist; the host gets a snackbar. Decline → host sees Declined. A host without a group plan cannot invite (gateway `409 SOLO_TRIP_ONLY`; note the text the app shows); a full ride shows "no seat left" in the summary; the trip head cannot invite. An invite never skips bike details or plan rules. Expired after 12 h / ride end. |
| **Push notifications** | With CoRoute force-stopped: friend request (opens Friends), crew invite (opens Crews), new poll (opens the crew), ride invite (opens the invitation). With the app open: in-app notice, no system notification. Lock screen hides the text (private). Token refresh: clear storage / reinstall and sign in → new token registered, old one pruned. **Sign-out stops pushes.** Settings › Account & privacy › **Push notifications** off stops them; on asks for permission if needed. Admin `pushNotifications` off stops all. Android 13+ with notifications denied: nothing posted, no crash. |
| **Domain fallback** | On a test phone block `coroute.devmonks.space` (e.g. a hosts-file / DNS blocker app, or a Private DNS that does not resolve it): the app still signs in and rides through `coroute.duckdns.org`; unblock and restart the app → it uses the new host again. A POST is never sent twice. The WebSocket and share links follow the host in use. |
| Rider score and leaderboards | After 3 rides of 10 km+ the score, level (Learner / Steady / Skilled / **Ace Rider**) and tips appear; turning off "Use my ride safety report for my rider score" shows Smoothness "Not measured yet"; "You: #n" on the leaderboard; opt-out removes you from the website within 5 min. |
| Marketing studio (admin) | Each starter, bind a coupon, move / resize / rotate, QR scans to `<server>/get?coupon=CODE`, Save; **Share PNG** and **Share all sizes** into WhatsApp and Files; 1080x1920 and 1200x628 layouts need no fix; expired coupon asks to confirm. |
| Website on a phone and a desktop, light and dark | All-time tiles and `/leaderboard`; the "riders" tile = registered riders with at least one completed ride (owner: OK). |

**Gate 7:** every section A line passes on at least two phones, and every other line passes or has an owner-
accepted note. Update `docs/FEATURE_STATUS.md`: move a row from "Needs device check" to "Stable" only for
rows you actually checked on a phone.

## Step 8. Drills, soak, storage, then Play Store

1. **Failure drills** (`docs/PRODUCTION_TWO_VM_RUNBOOK.md` §8): stop one VM during a live test ride, DB
   connection loss, Caddy restart; riders keep riding, nothing lost.
2. **30-minute soak** with `gateway/scripts/load_convoy_ws.js`: record peak live riders, p95 latency, RSS and
   CPU on both VMs; write the measured cap into `LIVE_RIDER_CAP` and restart VM2 then VM1.
3. **Monthly restore test**: restore the backup into DB 2 with `--dry-run` first (§9.3); put a monthly
   calendar reminder.
4. **Object Storage** (settings only, code exists; `platform.md` "Moving review photos and APKs to Object
   Storage"): review / place photos via PAR (`REVIEW_PHOTO_STORE=par`, PAR URL in Vault), migrate with
   `--dry-run` then real then `--verify`; APKs via object-level read-only PARs (`APK_URL`, `APK_ARM32_URL`),
   one-year expiry with a reminder. Profile pictures follow the same store where configured.
5. **Play Store**: upload the AAB to **internal testing**; testers install from Play; repeat the section A
   checks and the App Links check with the Play-signed build (Play App Signing key in `assetlinks.json`).
   Then **production staged rollout: 10 % → 50 % → 100 %**, at least 24–48 h per stage, watching: Play
   Console crashes / ANRs (target crash-free ≥ 99.5 %), gateway errors and latency, SOS / SMS delivery,
   push delivery (send failures in the gateway log), sign-in failures, the admin app-builds screen. Halt the
   rollout on any safety regression. After 100 %: `PLAY_STORE_URL` in `gateway.env` (RUNBOOK "After the
   Play Store listing is live"), `LATEST_APP_BUILD` = the Play build.
6. iOS stays **"coming soon"** on the website and in the listing; no TestFlight in this release.
7. Keep `coroute.duckdns.org` fully served (DNS updater, certificate, Caddy name) for **at least 6 months** and
   until `MIN_APP_BUILD` reaches the first build with the new default host and no older builds show in
   admin → app builds.

**Gate 8:** soak cap recorded, restore test done, Play internal test passed, rollout stages completed or
halted with a reason.

## Step 9. Report back (to the owner)

Use this format:

```
CoRoute v3.55 release report (<date>)
Branch / commits: release/v3.55.0, <n> commits (<first>..<last>)
Versions: app 3.55.0+<build>, gateway 3.55.0, Flutter <version>, LATEST_APP_BUILD <n>, MIN_APP_BUILD <unchanged n>
Build fixes: <file: one line> ...
Tests: flutter analyze <result>; flutter test <passed>/<total>; npm test <passed>/<total> (flaky re-runs: ...)
Device gate: table per section A–G: check | phone / Android | pass/fail | notes; false siren / horn count
Server: backup id/time; VM2 deployed <time>; VM1 deployed <time>; failover drill <result>; soak cap <n>
Domain: DNS ok?; certs both names?; assetlinks both hosts?; HSTS raised? (yes/no, when)
Secrets rotated (names only): JWT (grace ends <time>), DB password, DuckDNS token; setup_new_vm.sh cleaned
Push: Firebase configured?; test pushes ok?
URLs: https://coroute.devmonks.space, /download, /leaderboard, Play listing URL
Switches left off and why: ...
Open issues / risks: ...
```

Also update `PRODUCTION_RELEASE_TRACKER.md` (repo root), `PROJECT_CONTEXT.md` and `docs/FEATURE_STATUS.md`
with build numbers, test results, deploy times and anything left open.

### Open owner decisions (bring these up; do not decide alone)

- **Credit beyond the plan price** (original v3.55 plan): what happens when a prorated credit is larger than
  the new plan's price.
- **When to enable `REDIRECT_LEGACY_HOST=true`** (website pages on DuckDNS 301 to the new host; API, sockets,
  assetlinks, live and guardian links never redirect). Suggested: not before `MIN_APP_BUILD` covers the
  first new-host build and DuckDNS traffic is low; DuckDNS stays served at least 6 months either way.
- **HSTS raise** on `coroute.devmonks.space` from 300 s to 1 year, after the domain checks pass (Step 6.8).
- Already decided this round (no action): emergency contact shared with an accepted outside helper = **yes**
  (built); per-bike speedometer offset = **no** (not built); website "riders" definition = **OK**.
