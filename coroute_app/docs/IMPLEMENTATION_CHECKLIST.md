# CoRoute implementation and next-agent checklist

Updated: 2026-10-09. This is a working handoff, not a release certification.
All changes remain uncommitted and undeployed. Preserve existing workspace edits, especially alert_service.dart and alert_persistence_test.dart from separate work.

## Status key
- [x] Implemented in the working tree; verification limits are listed separately.
- [ ] Remaining implementation, configuration, or validation.

## Route Essentials and fuel
- [x] Route-corridor discovery, category filtering, bounded provider work, verified road access/detour, cache freshness and stale fallback.
- [x] Authenticated gateway endpoint, explicit disabled-provider and outage states; no invented detour or exhaustive-coverage claims.
- [x] Personal fuel profile, reserve buffer, full/partial refill, range uncertainty, persisted range baseline, opt-in shared usable range with expiry.
- [x] Existing-style fuel and essentials sheets, account entry, cockpit bar/markers, pre-ride preview, lead add/member suggest stop flow.
- [x] Shared essentials coordinator consumes the existing location stream; no second GPS subscription.
- [x] Serialized cache writes and authorization-failure retry suppression implemented.
- [x] Added concurrent default cache writes, cache bounds, storage failure/recovery, token change and authentication retry suppression tests.
- [ ] Position-aware group fuel-station recommendation; learned mileage and confidence calibration.
- [ ] Audit the original feature brief against existing weather, hazard, rest and emergency features before adding duplicates.
- [ ] Remaining brief capabilities: contextual food/rest/stay/repair recommendations, breakdown assistance, voice summaries, offline emergency route pack and richer leader intelligence.
- [ ] Configure ESSENTIALS_OVERPASS_URL and validate real provider coverage, limits and failure behaviour.
- [ ] Review per-account scoping of stored fuel preferences and account-switch behaviour.

## Smart ride notification and battery
- [x] Native expanded Group/Fuel views, self/ahead/behind line, next fuel distances, remaining usable range and fuel details action.
- [x] Native light/dark normal, warning, critical and positive surfaces; existing emergency priority preserved.
- [x] Conservative battery policy, reduced routine telemetry/notification frequency, optional discovery suppression and shared GPS source.
- [x] Freshness deadlines invalidate displayed information without network polling.
- [x] Tested freshness deadline, disposal, ended-ride fuel action and stale-action map fallback.
- [ ] Native cold launch, account changes during native actions and broadcast fallback need device coverage.
- [ ] Rider-specific details, full rider overflow, strict route-relative ordering and off-route presentation.
- [ ] Offline/unknown visual state and accessible labels must be reviewed on devices; colour alone must never convey severity.
- [x] Android debug APK compiled successfully.
- [ ] Inspect collapsed/expanded notification on supported Android versions, dark mode and large text.
- [ ] Real-device background/foreground, permission denial, battery saver, process death and reconnection checks.
- [ ] Measure battery/network use against baseline; no battery-savings percentage has been established.

## Ride Guardian / Trip Monitor
- [x] Separate observer access, personal and consented-group scope, BASIC/LIVE/EMERGENCY_ONLY permissions.
- [x] Hashed capability tokens and browser sessions, optional hashed PIN, expiry, durable revocation, pause/resume and membership checks.
- [x] Group subjects pinned to the consent present when a link is created; withdrawal removes access and later consent cannot broaden old links.
- [x] Explicit allowlisted projections exclude contacts, medical details, fuel and unconsented peers.
- [x] Flutter creation/share/consent/manage sheet follows existing sheet patterns.
- [x] Responsive browser status page, stale/offline handling, hidden-page backoff, timeline and external map links.
- [x] Optional Web Push capability, service worker, generic notifications, durable retry jobs, opt-out and authorization rechecks.
- [x] Deleted-grant sessions return unavailable; consent is checked again after timeline loading; pause/resume/revoke regressions added.
- [x] Guardian widget tests cover narrow layout, 2x text, PIN, consent failure, retry, pause/revoke and account switching.
- [x] Convoy deletion clears Guardian records and has isolation/idempotency tests.
- [ ] Audit long-term consent retention and production database deletion races.
- [x] Timeline suppresses warnings starting in known planned-stop/pause intervals; off-route/separation require five minutes. Bounded event-history limitations still need production review.
- [x] Added timeline privacy/threshold and PIN/pause/push HTTP tests.
- [ ] Embedded route/map, destination/ETA confidence, registered guardians, contact actions and audit/history features remain pending.
- [ ] Push multi-instance atomic claiming/coalescing, throughput and race tests; current worker is not production-load certified.
- [ ] Validate browser push delivery, service-worker update behaviour and iOS installed-web-app flow on devices.
- [ ] Configurable expiry/label UI, resubscription UX and cold-session recovery need further work.
- [ ] External SMS/email/WhatsApp/OTP integrations require provider selection and credentials; no external messages were sent.

## Configuration and rollout gates
Guardian is disabled by default. Enable only after validation:
- GUARDIAN_ENABLED=true and an exact HTTPS PUBLIC_ORIGIN.
- Optional GUARDIAN_PUSH_ENABLED=true with GUARDIAN_VAPID_PUBLIC_KEY, GUARDIAN_VAPID_PRIVATE_KEY and GUARDIAN_VAPID_SUBJECT.
Never put private keys, capability URLs or session credentials in logs or this document.
- [x] Inspected npm audit: gaxios/uuid, two moderate findings; compatible audit fix dry-run made no changes.
- [ ] Resolve dependency findings with a reviewed compatible update.
- [ ] Run current full Flutter analyzer/tests, gateway tests and Android build.
- [ ] Exercise offline launch, stale cache, no cache, intermittent network, timeout, unauthorized response, provider outage, permission denial and recovery on device.
- [ ] Commit/deploy only when requested; this checklist does not authorize a rollout.

## Verification ledger
Older user-provided baseline: analyzer clean, Flutter 860/860, gateway 235/235. These do not certify subsequent changes.
Earlier agent runs: focused Flutter 108/108; gateway 258/258; analyzer clean. Later PIN/pause/cache/notification changes followed some of these runs.
Current run: Guardian and push unit tests 26/26, including deleted grant, pause/revoke and consent-withdrawal race regressions.
Current focused Flutter notification/fuel/coordinator tests: 26/26 passed. Current full gateway suite: 262/262 passed (including the 26 Guardian/push unit tests above). Full Flutter suite and analyzer still need a rerun after all latest edits.
No native build, real-device notification QA, battery benchmark or actual push delivery is verified yet.

## File map
- Gateway discovery: gateway/src/essentials.js; test/essentials*.test.js.
- Guardian: gateway/src/guardians.js, guardian_routes.js, guardian_push.js; oracle/repo.js; retention.js; app.js.
- Browser: gateway/public/watch.html, assets/guardian.js, assets/guardian.css, _watch-sw.js, watch.webmanifest.
- Flutter: lib/data/services/ride_essentials_coordinator.dart, route_essentials_service.dart, ride_notification_service.dart; lib/presentation/ride/{essentials,fuel,guardian}_sheet.dart.
- Domain: lib/domain/safety/{fuel_profile,fuel_range,group_fuel}.dart; domain/notify/fuel_notification.dart; domain/tracking/ride_power_policy.dart.
- Native: android/app/src/main/kotlin/space/devmonks/coroute_app/RideNotification.kt and ride_notif XML resources.
- Design context: SMART_RIDE_NOTIFICATION_PLAN.md and RIDE_GUARDIAN_PLAN.md. Their future sections are not proof of implementation.

## Next agent: recommended execution order
1. Read git diff and this ledger; preserve unrelated edits. Review privacy and deletion gaps first.
2. Add missing regression tests and fix failures; then finish notification lifecycle and Guardian UI work.
3. Build Android, perform device/browser checks, and measure battery usage.
4. Map remaining original brief items to existing app capabilities and implement in small verified increments.
5. Update this checklist with commands, counts, remaining limitations and exact configuration needs.

Commands (PowerShell; run Flutter from coroute_app and Node from coroute_app/gateway):
```powershell
& 'C:/Users/santhosh/flutter/bin/flutter.bat' analyze
& 'C:/Users/santhosh/flutter/bin/flutter.bat' test --no-pub
& 'C:/Users/santhosh/flutter/bin/flutter.bat' build apk --debug
node --test test/guardians.test.js test/guardian_push.test.js test/guardians_integration.test.js
npm test
```
SDK-cache writes and localhost integration tests may require sandbox escalation. Record limitations instead of declaring a skipped check passed.

## Scenario coverage update
See [New feature test scenarios](NEW_FEATURE_TEST_SCENARIOS.md) for executable test inventory, detailed manual acceptance cases and remaining automation gaps. Latest test-writing pass: focused Flutter 90/90 and full gateway 260/260 passed. Added cache expiry/concurrency, credential recovery, timeout recovery and Guardian PIN/pause HTTP cases; corrected the mixed HTTP-error test so authentication blocking does not skip later status cases. These current totals supersede earlier totals for this working tree; manual checks remain pending.

## Latest completion pass
See [Release handoff](RELEASE_HANDOFF.md) for the authoritative latest results and release gates. Full Flutter: 888/888; later fuel-sharing tests: 2/2; full gateway: 273/273; Android debug APK built. Browser VM/service-worker tests and push HTTP/race tests added. Actual device and distributed-worker checks remain pending; earlier ledger entries are historical.

Final analyzer: no issues. Guardian/fuel-sharing post-style rerun: 6/6 passed (overlapping tests, not additional unique tests). Git diff --check passed. Release owner should use RELEASE_HANDOFF.md for remaining gates.
