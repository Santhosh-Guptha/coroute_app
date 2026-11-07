# Prompt for the next agent: finish, verify and deploy CoRoute v3.55

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
3. Native: Android Gradle release build (`flutter build apk --release --split-per-abi --dart-define=COROUTE_API=https://coroute.duckdns.org`; check the existing build scripts/release docs for the exact flags). Confirm the manifest permissions needed by new features (SMS send for solo check-in/emergency texts, location, notifications) match `docs/PLAYSTORE_PERMISSIONS.md`. iOS: `flutter build ios` must at least compile; App Store stays "coming soon".
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
- "Need help" in the missing-rider check asks the group to wait; should it raise an SOS instead?
- Rename "Trip head" (it is easily confused with the riding Lead)?
- Admin Warn dialog has no message text box yet (riders get a default line); add one?
- Place-review question after the ride ends is not shown yet.
- Replace the hotspot-only mesh with Google Nearby Connections (Bluetooth + Wi-Fi Direct, ~50–200 m, no setup) for position and SOS?
- Products decisions listed in `docs/UX_NAMING_GUIDE_v3.55.md` section 4 and the original plan's owner decisions.

## 5. Report back
A short summary: branch and commits, flutter/gateway test results, device test results (pass/fail per item), what was tuned, deploy steps done with times, current production version, switches left off, and remaining risks.
