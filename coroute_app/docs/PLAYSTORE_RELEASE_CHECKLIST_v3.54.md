# Play Store release checklist: CoRoute 3.54.0 (build 10018)

App id `space.devmonks.coroute_app`. Previous build: 3.53.20+10017 (gateway `LATEST_APP_BUILD` default 10017).
Permission-by-permission reasons and declaration texts: [PLAYSTORE_PERMISSIONS.md](PLAYSTORE_PERMISSIONS.md).

## 1. Build

```bash
cd coroute_app
flutter pub get                       # picks up image_picker ^1.2.2 (lockfile changes; commit it)
flutter analyze                       # must be 0 errors, 0 warnings
flutter test                          # full suite; see section 8 for the tests changed in 3.54
flutter build appbundle --release     # -> build/app/outputs/bundle/release/app-release.aab
```

- [ ] `pubspec.yaml` version is `3.54.0+10018` (versionCode 10018 > every uploaded build).
- [ ] No `--dart-define=COROUTE_API=http://...`: release builds ignore any non-HTTPS gateway and use `https://coroute.duckdns.org`.
- [ ] Optional sideload APKs: `flutter build apk --release --split-per-abi`.

## 2. Signing

- [ ] `android/key.properties` (git-ignored) present with `storeFile`, `storePassword`, `keyAlias`, `keyPassword`, or CI env `COROUTE_STORE_FILE`, `COROUTE_STORE_PASSWORD`, `COROUTE_KEY_ALIAS`, `COROUTE_KEY_PASSWORD`. Template: `android/key.properties.example`.
- [ ] Since 3.54 a release assemble/bundle **fails** ("Release signing is not configured") when any of these or the keystore file is missing. It never falls back to the debug key.
- [ ] Play App Signing enrolled; the key in `key.properties` is the **upload** key. Back up the keystore and passwords outside the repo.
- [ ] Verify: `keytool -printcert -jarfile app-release.aab` shows the upload certificate, not `CN=Android Debug`.

## 3. Android configuration (done in 3.54, verify once on a build machine)

- [ ] `targetSdk = 36` (pinned; Play requires 36 for updates from 31 Aug 2026). `compileSdk = 37` kept on purpose (raised in commit 3d96e53 for the release build). `minSdk = max(Flutter default, 23)`, unchanged; image_picker 1.2.x and the other plugins need less.
- [ ] R8 on: `isMinifyEnabled = true`, `isShrinkResources = true`, rules in `android/app/proguard-rules.pro` (Flutter, notifications/Gson, foreground task, record, Razorpay incl. `onPayment*` callbacks, Credential Manager, app channels). After the first release build, check `build/app/outputs/mapping/release/missing_rules.txt` is empty or only has `-dontwarn` candidates. Upload `mapping.txt` to Play for readable crash traces.
- [ ] Manifest: `allowBackup="false"`, `fullBackupContent="false"`, `dataExtractionRules` excludes everything (no cloud backup or device transfer of the session token, SOS queue or ride data). `usesCleartextTraffic="false"` plus `network_security_config.xml` with cleartext prohibited. A debug-only override (`src/debug/res/xml`) allows HTTP to `10.0.2.2` / `localhost` for local gateways.
- [ ] `<queries>` has `android.media.action.IMAGE_CAPTURE` (image_picker camera on Android 11+). No CAMERA permission is declared, so the camera app takes the photo.
- [ ] Exported components: only `MainActivity` (launcher, deep links) and `MedicalTileService` (guarded by `BIND_QUICK_SETTINGS_TILE`). Everything else is `exported="false"`.

## 4. Permission declarations (Play Console > App content)

- [ ] **Location permissions / background location.** Decision for 3.54: **keep `ACCESS_BACKGROUND_LOCATION` and submit the declaration** (feature: "share live position with your riding group and detect crashes during a ride the rider started"). Video: start ride > prominent disclosure > "Allow all the time" > lock phone > second phone keeps seeing updates. Fallback if rejected: remove the permission; the `location` foreground service already covers screen-off riding (convoy and offline solo ride), then set `locationAlways` to not required in `PermissionsService`.
- [ ] **Foreground service types:** `location` (ride tracking and crash detection, including the new offline solo ride) and `microphone` (intercom). One short video each.
- [ ] **Full-screen intent:** crash alarm (safety alarm with countdown and "I'm OK").
- [ ] **Battery optimisation exemption:** justification text from PLAYSTORE_PERMISSIONS.md (long rides killed by OEMs otherwise).
- [ ] No SEND_SMS / CALL_PHONE: SOS texts open the messages app; calls open the dialer.

## 5. Data safety form

Declare (all encrypted in transit, HTTPS/WSS only; users can request deletion in the app):

| Data | Collected | Shared | Purpose |
|---|---|---|---|
| Precise and approximate location | Yes | With the rider's own group only (app functionality) | Convoy tracking, SOS, crash alert |
| Name, email, phone, emergency contact | Yes | With the rider's group (name), emergency contact (SOS text) | Account, safety |
| Photos (post-trip review photo, optional) | Yes | Shown publicly only with consent and admin approval | App functionality |
| Audio (intercom) | Streamed live to the group, not stored | With the group | App functionality |
| Purchase history (memberships via Razorpay) | Yes | Payment processor | Payments |
| Crash logs / diagnostics | Only if a crash reporter is added; none in 3.54 | | |

- [ ] Re-check against the gateway's actual retention before submitting (trip history, review photos, SOS records).

## 6. Store listing assets (`store/`)

- [ ] Icon `store/icon_512.png` (512x512), feature graphic `store/feature_graphic_1024x500.png`.
- [ ] 4 to 8 phone screenshots via `store/capture_screenshots.ps1` (cockpit, convoy, SOS sheet, crash alarm, trip summary, the new "Ride solo without internet" card).
- [ ] Texts from `store/LISTING.md`; "What's new" for 3.54: crash detection from 12 km/h in slow traffic; crash detection and SOS by text on a solo ride with no internet; admin rider search.
- [ ] Privacy policy `https://coroute.duckdns.org/privacy`, terms `/terms` reachable over HTTPS.

## 7. Gateway deploy (before or with the app rollout)

- [ ] Run gateway tests (`cd gateway && npm test`).
- [ ] Copy the gateway as in `gateway/deploy/RUNBOOK.md` (rsync to `/opt/coroute/gateway/`).
- [ ] **New env `REVIEW_PHOTO_DIR`** in `/etc/coroute/gateway.env`: a private folder **outside** `public/`, writable by the service user, included in backups, e.g.
  `sudo install -d -o coroute -g coroute -m 750 /var/lib/coroute/review-photos` and `REVIEW_PHOTO_DIR=/var/lib/coroute/review-photos` (default if unset: `gateway/data/review-photos`, which an `rsync --delete` of the code folder would wipe).
- [ ] The unit has `ProtectSystem=strict` with `ReadWritePaths=/opt/coroute/gateway` only, so allow the photo folder: `sudo systemctl edit coroute-gateway` and add `[Service]` / `ReadWritePaths=/var/lib/coroute/review-photos`, then `sudo systemctl daemon-reload`. Without it photo uploads fail with EROFS.
- [ ] Set `LATEST_APP_BUILD=10018` once the AAB is live (leave `MIN_APP_BUILD` unchanged).
- [ ] `sudo systemctl restart coroute-gateway`, then `./deploy/smoke_test.sh https://coroute.duckdns.org`.
- [ ] Check `GET /api/admin/analytics/riders` and `GET /api/admin/coupons/plan-options` answer for an admin (the app falls back to `/admin/users` on a 404, and shows plan names without prices when plan-options is missing).

## 8. Tests changed in 3.54 (run before the build)

`test/crash_detector_test.dart` (new arming rule: 12 km/h for 10 s or above 25 km/h, 3 min disarm; slow-traffic tip-over), `test/safety_service_test.dart` (sensor hysteresis, offline solo ride: detection, SMS to contact, messages app, convoy takeover), `test/app_config_https_test.dart` (new), `test/admin_console_test.dart` (server-side rider list, filters, load more), `test/admin_coupon_and_trip_view_test.dart` (plan prices from the catalog), `test/scenario_c_low_battery_throttle_test.dart`, `test/advanced_crash_detection_test.dart` (comments only).

## 9. Real-device test matrix (internal testing track first)

| Test | Devices | Pass when |
|---|---|---|
| Crash detection, screen off 30 min | Samsung (One UI 6/7), Pixel (Android 15/16), Xiaomi or Oppo | Ride (or simulate with a car) 30 min screen-off; the accelerometer keeps reporting (`detectorArmed` in phone check), a tap test fires the alarm full-screen over the lock screen within 20 s of stillness |
| Slow-traffic arming | Any | 12 to 20 km/h for 10 s arms the sensor; stays on at red lights; off after 3 min parked (battery stats show no sensor use while parked) |
| Offline solo ride | Samsung + Pixel, airplane mode with GPS on | Start "Ride solo without internet"; ride notification shows; simulated crash with no answer: SOS text to the emergency contact (messages app opens when the phone is in hand); Call contact / 112 buttons work |
| SOS SMS composer | Samsung (comma separator) and Pixel (semicolon) | Messages app opens with every recipient and the map link; nothing is sent without pressing Send |
| Precise location dialog | Android 12+ | "Approximate" choice is upgraded via the precise-location dialog before a ride |
| Map follow smoothness, 50 riders | Mid-range phone (e.g. Redmi Note / Galaxy A) | Live cockpit with 50 simulated riders: no visible stutter, follow camera smooth, frame times under 16 ms in the profile build |
| Photo upload | Android 13+ (photo picker) and Android 11/12 (camera via IMAGE_CAPTURE) | Gallery and camera picks work, upload succeeds, photo hidden until admin approval |
| Release signing guard | Build machine | `flutter build appbundle --release` without `key.properties` fails with the signing message |
| HTTPS only | Release build | Built with `--dart-define=COROUTE_API=http://...` still talks to `https://coroute.duckdns.org` |
