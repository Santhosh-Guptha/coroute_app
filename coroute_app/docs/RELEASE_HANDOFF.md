# CoRoute release handoff

Updated 2026-10-09. Changes are local, uncommitted and undeployed. This handoff separates implemented behaviour from unverified device behaviour and future features. It is not a claim that the entire original roadmap is complete.

## Implemented in this working tree
- [x] Route-aware Essentials discovery and category UI, road access/detour checks, partial coverage, bounded caching, offline fallback and stop add/suggest flows.
- [x] Fuel profiles, reserve/buffer calculations, explicit refill, uncertainty after tracking gaps, fresh opt-in group estimates and shared route coordinator.
- [x] Expanded Android Group/Fuel notification, alert surfaces, contextual fuel action, stale-action fallback and freshness updates without extra GPS events.
- [x] Battery-aware routine telemetry/notification cadence; critical activity keeps its intended cadence.
- [x] Guardian personal/consented-group links, three access levels, PIN, expiry, pause/resume, revocation, separate read-only browser sessions and bounded polling.
- [x] Optional generic browser push, durable retries, endpoint validation and authorization checks. Push remains opt-in and not guaranteed delivery.
- [x] Guardian webpage and service-worker assets in the existing gateway website.

## Fixes and tests completed in this pass
- [x] Guardian widget coverage: narrow screen at 2x text, acknowledgement, PIN validation, load retry, failed consent, pause/resume/revoke and delayed old-account response.
- [x] Guardian sheet state resets on session/group changes; invalid PIN rejected locally.
- [x] Convoy deletion clears dependent Guardian grants, sessions, jobs, subscriptions, pauses, revocations and group consent records in bounded batches.
- [x] Timeline filters private fields/peers; routine warnings suppressed during known planned-stop/pause intervals; off-route/separation require five minutes.
- [x] Browser DOM tests cover capability removal, revoked access, PIN gate, offline backoff and hidden-page late response.
- [x] Browser clears private content when hidden; late hidden-page responses do not restore location.
- [x] Service worker ignores malformed payloads and prevents external notification-click destinations.
- [x] Push tests cover preference revisions, opt-out during delivery preparation, invalid input, provider 410, shutdown and overlapping ticks in one process.
- [x] Enabled push HTTP tests cover origin checks, missing sessions, preference validation and subscription ownership.
- [x] Notification freshness/disposal and old-fuel-action tests.
- [x] Cache/auth tests: concurrent writes, newest 18 entries, save failure/recovery, expiry, credential replacement, timeout and captive/error responses.
- [x] Fuel sharing tests: default private, minimal payload, immediate opt-out, uncertain/invalid range suppression and listener disposal.
- [x] Fixed an existing weather-test clock-boundary race; production weather behaviour unchanged.

## Verified results
| Check | Result |
|---|---|
| Full Flutter suite | 888/888 passed |
| Additional fuel-sharing tests added after full run began | 2/2 passed |
| Full gateway suite after weather test correction | 273/273 passed |
| Android debug APK build | Passed; build/app/outputs/flutter-apk/app-debug.apk |
| Flutter analyzer | Passed: no issues |
| Guardian/fuel-sharing rerun after style fixes | 6/6 passed; overlaps counts above |
| Git whitespace check | Passed |
| Signed release/R8 build | Not executed |
| Actual device/push/battery measurements | Not executed |

The debug build recovered from a Kotlin incremental-cache error and completed successfully. Plugin/SDK compatibility warnings remain build-maintenance items. The generated debug APK is for testing, not the website release artifact.

## Release gates still unchecked
- [ ] Validate native notifications on Android: collapsed/expanded, actions, cold start, process death, permissions, dark mode, large text and OEM battery restrictions. No Android/iOS device was connected; only Windows/Chrome/Edge were listed.
- [ ] Measure actual battery drain/network use on a controlled ride; do not publish a battery-savings percentage.
- [ ] Configure and test the real Essentials provider, including outage/rate limits and local coverage.
- [ ] Validate Guardian in real browsers and iOS installed-web-app mode, with actual test push delivery under HTTPS. VM DOM tests do not replace browser/device QA.
- [ ] Resolve two moderate npm audit findings in the gaxios/uuid dependency chain. Audit fix dry-run offered no package changes; no forced upgrade was applied.
- [ ] Validate production Oracle migrations and deletion/retention in staging. Tests use MemorySoda; long-term consent retention still needs review.
- [ ] Keep Guardian push disabled for multi-instance deployments until atomic job claiming and multiworker load/restart tests are implemented. Single-process overlap tests do not establish distributed safety.
- [ ] Review fuel preferences/account scoping on shared devices before broad rollout.
- [ ] Build with the existing production signing key and verify its certificate. Current Gradle configuration falls back to debug signing if release signing is absent.
- [ ] Select the next version/build number above the published build. Current source versions remain app 3.16.0+76 and gateway 3.16.0; this task did not increment them.

## Remaining features, not release claims
- [ ] Position-aware group station selection and learned mileage/confidence calibration.
- [ ] Contextual food/rest/stay/repair, breakdown assistance, voice summaries and offline emergency route pack.
- [ ] Complete rider-specific notification details, overflow and off-route presentation; device accessibility review.
- [ ] Guardian embedded route/map and ETA confidence, registered guardians, configurable expiry/labels, audit/history and contact actions.
- [ ] SMS/email/WhatsApp/OTP integrations after provider selection and authorized configuration.
- [ ] Guardian multiworker push claiming, larger-load tests, restart races, resubscription improvements and retention audit.

Full scenario IDs and manual expected results: [New feature test scenarios](NEW_FEATURE_TEST_SCENARIOS.md).
Implementation/file map: [Implementation checklist](IMPLEMENTATION_CHECKLIST.md).
Existing production instructions: [Gateway deployment runbook](../gateway/deploy/RUNBOOK.md).

## Build and website checklist for the release owner
1. Finish relevant unchecked gates above; keep unvalidated features disabled. Review git diff and include all required untracked source/test/assets; preserve unrelated work.
2. Run Flutter analyze and test, and gateway npm test on the exact release checkout. Do not change dependencies afterward without revalidation.
3. Set version/build and production signing through the existing key.properties/environment setup. Do not put credentials in Git or this document.
4. Build release APKs using the existing runbook. From coroute_app in PowerShell:
```powershell
& 'C:/Users/santhosh/flutter/bin/flutter.bat' pub get
& 'C:/Users/santhosh/flutter/bin/flutter.bat' analyze --no-pub
& 'C:/Users/santhosh/flutter/bin/flutter.bat' test --no-pub
& 'C:/Users/santhosh/flutter/bin/flutter.bat' build apk --release --split-per-abi --target-platform android-arm,android-arm64 --obfuscate --split-debug-info=build/symbols --dart-define=COROUTE_API=https://coroute.duckdns.org
```
Use your verified production origin if it differs. Keep build/symbols with the release artifacts. Verify APK signing and upgrade installation over the currently published app before release.
5. Deploy gateway code, lockfile, migrations and the public website together using the runbook. Required new assets include watch.html, assets/guardian.js, assets/guardian.css, _watch-sw.js and watch.webmanifest. The app serves the worker through /watch-sw.js; do not bypass the route/privacy headers.
6. Production configuration: ESSENTIALS_OVERPASS_URL for discovery; GUARDIAN_ENABLED with exact HTTPS PUBLIC_ORIGIN for Guardian; optional VAPID values only after push gates pass. New entries are documented with disabled defaults in gateway/deploy/.env.example.
7. Publish the signed arm64/arm32 APKs through the existing /download and /download/32bit setup. Preserve existing APKs during website sync. Do not upload app-debug.apk as the release.
8. Smoke-test health/meta, login, a normal ride, Essentials online/offline, Guardian creation/revocation, website privacy headers and download targets. Keep the previous gateway build/APKs available for rollback.
9. Update website release copy only for enabled, validated behaviour. Do not claim guaranteed safety, exhaustive station coverage, all roadmap features, measured battery savings or guaranteed notification delivery.

Suggested factual release copy, once the matching features are enabled and validated:
"CoRoute adds route essentials, personal fuel estimates and an expanded ride notification. Optional Ride Guardian links let riders share selected trip updates with trusted people. Availability depends on connectivity, permissions and configured services."

Nothing has been committed, deployed, sent to guardians or published by this task.
