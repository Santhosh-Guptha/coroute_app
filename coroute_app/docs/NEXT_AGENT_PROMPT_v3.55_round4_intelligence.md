# CoRoute v3.55 round 4 (road & safety intelligence): full prompt for the release agent (12 Nov 2026)

A NEW increment after round 3. Ships the gateway/website/web admin AND app build **3.55.0+10026**.
Design: docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md. Capacity: docs/intelligence/CAPABILITY_v3.56.md.
Paste everything inside the block.

```
You are the release agent for CoRoute (motorcycle group/solo riding SAFETY app: Flutter Android app + Node.js gateway on
two OCI VMs + website + web admin). Ship the round 4 "road & safety intelligence" increment: commit, test, build
3.55.0+10026, deploy the gateway (VM2 then VM1), QA on devices, Play internal testing. Report after each section.
STOP at any failed safety gate.

=== 0. PREREQUISITE AND RULES ===
- PREREQUISITE: round 3 (docs/NEXT_AGENT_PROMPT_v3.55_round3.md, build 10025) is COMMITTED, DEPLOYED and VERIFIED.
  If not, finish round 3 first; do not mix the two in one commit.
- Never commit or print secrets. New secret this round: INTEL_HASH_KEY (OCI Vault, >= 32 random chars,
  `openssl rand -base64 48`). Without it the gateway derives the key from JWT_SECRET and warns at start.
- The app shows no prices/payments/coupons: `dart tool/play_policy_scan.dart` must print 0 hits.
- Never weaken SOS, crash detection, emergency texts, the lock-screen Medical ID, "Call 112" or the ride lock.
- Note: lib/main.dart blocks touched in round 3 and round 4 are dart-formatted (whitespace only) inside the changed
  hunks; behaviour is unchanged.

=== 1. FILES ===
Gateway (new):   gateway/src/intel/{config,math,geohash,privacy,engine,crash_brain,router_adapter,routes}.js
                 gateway/public/admin/{intel.js,leaflet.js,leaflet.css}   (Leaflet 1.9.4, BSD-2-Clause)
                 gateway/deploy/valhalla/{docker-compose.yml,coroute-valhalla.service,refresh_tiles.sh,README.md}
                 gateway/test/_intel_helpers.js, gateway/test/intel_{privacy,hazards,crash_brain,road,router,memory}_356.test.js
                 gateway/test/fixtures/intel/{osrm_route,osrm_no_route,valhalla_route,valhalla_no_route}.json
Gateway (changed): src/app.js (wiring, jobs, shutdown), src/routes.js (health `intel`, ETA factor on POST /geo/route),
                 src/geo.js (ROUTER_KIND=valhalla path; safety-network table stays on OSRM), src/web_admin.js (admin CSP
                 img-src tile.openstreetmap.org), src/feature_flags.js (hazardAhead, longRideNudges, roughRoadAhead,
                 twistyAhead, fallingBehind), src/route_policy.js (GET /api/intel/info public), public/admin/index.html,
                 public/admin/admin.css, public/account.html, public/assets/account.js, public/assets/shop.css,
                 public/privacy.html, public/privacy-and-security.html, public/partials/footer.html, deploy/.env.example
App (new):       lib/domain/intel/{geohash,sha256,intel_event,ride_signal_detector,hazard_ahead,falling_behind,
                 long_ride_nudges,intel_policies}.dart, lib/data/services/intel_care_service.dart,
                 lib/presentation/settings/{road_safety_screen,intel_prompt_host}.dart,
                 test/intel_{hazard_ahead,falling_behind,long_ride_nudges,pothole_signals,consent_prompt}_356_test.dart
App (changed):   lib/main.dart, lib/data/services/{safety_service,road_care_service,group_safety_service}.dart,
                 lib/domain/safety/{crash_detector,ride_safety_summary}.dart, lib/data/models/route_model.dart,
                 lib/presentation/ride/group_safety_cards.dart, lib/presentation/trip_planner/trip_planner_screen.dart,
                 lib/presentation/settings/settings_screen.dart, pubspec.yaml (3.55.0+10026)
Tools / docs:    tool/intel_admin_smoke.js, docs/intelligence/*, docs/handbook/users/{user_guide,faq,
                 privacy_summary_for_riders}.md, docs/handbook/compliance/{play_store_compliance,
                 consent_and_retention_register,privacy_compliance_pack}.md, docs/handbook/technical/api_reference.md,
                 this file. No Kotlin / manifest change (no new permission).

=== 2. COMMIT CHUNKS (branch release/v3.55.0) ===
1. "intel: privacy base, aggregation engine, crash brain, router adapter (gateway)" - src/intel/*, app.js, routes.js,
   geo.js, feature_flags.js, route_policy.js, deploy/.env.example, gateway tests + fixtures.
2. "intel: web admin Road & safety intelligence pages, /account consent, privacy pages" - public/**, web_admin.js,
   tool/intel_admin_smoke.js.
3. "intel: Valhalla deploy (prepared, A1 only)" - deploy/valhalla/*.
4. "app: road & safety intelligence (warnings, nudges, falling behind, crash brain params, consent) 3.55.0+10026" -
   lib/**, test/intel_*_356_test.dart, pubspec.yaml.
5. "docs: road & safety intelligence, handbook, Play data safety" - docs/**.

=== 3. TESTS (all must pass) ===
- cd gateway && npm ci && npm test   (1237 tests on 12 Nov; flaky alone-reruns: two_node_failover, public_ride_mirror,
  job_lease, login performance - rerun those files alone before calling it a failure)
- cd gateway && node --test test/intel_*_356.test.js   (40 tests)
- flutter pub get && flutter analyze && flutter test   (new: test/intel_*_356_test.dart, 40 cases; also run
  test/crash_detector_test.dart, test/sensor_safety_355_test.dart, test/settings_minimal_355_test.dart)
- dart tool/play_policy_scan.dart -> 0 hits
- node tool/intel_admin_smoke.js /tmp/intel   (Playwright: admin pages light/dark + /account card; must exit 0)

=== 4. BUILD ===
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols (versionCode 10026), plus split APKs as
in MASTER_AGENT_PROMPT. Keep the build-10025 artefacts.

=== 5. DEPLOY (gateway first, then the app; VM2 then VM1) ===
- OCI Vault: add INTEL_HASH_KEY; make sure coroute-secrets.service exports it to /run/coroute/secrets.env.
- /etc/coroute/gateway.env (non-secret; defaults shown, add only to change):
  INTEL_ENABLED=true  INTEL_K_MIN=5  INTEL_RAW_DAYS=90  INTEL_HALF_LIFE_DAYS=90  CRASH_BRAIN_MODE=shadow
  ROUTER_KIND=osrm  FUEL_GAP_KM=80   (kill switch: INTEL_KILL=true)
- New collections are created at boot (intel_consent, intel_raw, intel_cells, intel_meta, intel_crash_train).
- After restart: GET /api/health -> `intel.enabled: true`, leases include intel-aggregate / intel-daily on ONE node
  (prefers web = VM2). Admin > Road & safety intelligence > Data & privacy shows "Rider hash key: INTEL_HASH_KEY set".
- Admin CSP now allows images from https://tile.openstreetmap.org (admin maps only). Caddy needs no change.
- Old app builds (<= 10025) are unaffected: they never call /api/intel/*; POST /api/geo/route only gains optional
  fields (etaSource, routerDurationS, per-leg etaFactor) that old builds ignore.
- Do NOT set ROUTER_KIND=valhalla on the micro VMs. Valhalla needs the A1 (gateway/deploy/valhalla/README.md).

=== 6. QA CHECKLIST (devices; build 10026; report each) ===
Prepare a seeded test hotspot (staging or production with a test admin; remove afterwards): on the gateway host run a
one-off node script that calls `intel.consent.set(id, true)` for 5 test rider ids and `intel.ingestEvents(id,
[{type:'hard_brake', gh:<geohash-7 of a spot on your test road>, hb:<0-7 bucket of the direction you will ride>,
ts:Date.now()}])` for each, then `intel.aggregate()` on the lease holder (or wait 5 min). Check
GET /api/intel/hazards?tiles=<geohash-4> as a rider returns the cell.
1. Hazard warning: ride toward the seeded spot in the seeded direction at > 15 km/h with the app (no SOS open):
   "Hazard ahead in ~400 meters..." and a chip 300-500 m before; nothing riding the other way; only one per 2 km.
   Turn on airplane mode after the ride started: the warning still comes (offline cache). Settings > Road safety >
   Hazard warnings off: no warning. Raise a test crash alarm near the spot: no hazard voice over the alarm.
   Lock the phone (lock-screen cockpit): chip + voice still appear.
2. Falling behind (2 phones, group ride with a planned route): lead rides ~60 km/h, second phone ~40 km/h:
   within ~2-3 min the lead (and sweep) hear "<name> is falling behind" with "Send regroup at <place>" when stopped;
   tap it -> the existing meeting point is set. A rider waiting at a planned stop is never reported.
3. Fatigue reminder with a short interval: DEBUG build, Settings > Road safety > "QA: short break interval" 2 min ->
   break nudge after 2 min of riding; snooze silences 20 min; the always-on 2 h reminder flow is unchanged (prompt,
   60 s / 90 s escalation). Night notice: set the phone clock to 23:10 and ride 30 min (or debug).
4. Fuel gap: plan a route through a long stretch without fuel places (e.g. 120 km of ghat road): Plan a ride shows
   "No known fuel for N km after <station>" under the route.
5. Crash brain shadow page: Admin > Crash brain shows mode shadow, "Approve" disabled; GET /api/intel/crash-params as a
   rider -> params null. Cancel a crash alarm on a consenting test phone -> "Was this a real crash?" sheet after the
   alarm closes (not during a ride); answer -> admin Crash brain labelled count grows after the next aggregation.
6. Consent on/off: new rider, finish one short ride -> one-time "Help make roads safer?" sheet; "Not now" never asks
   again. Settings > Road safety switch on -> /account#roads shows it on (and vice versa); turn it off mid-ride ->
   nothing from that ride appears in "Download my contributions".
7. Delete my contributions: consenting phone rides 3 km with a hard brake; Download shows rows; Delete -> message about
   90 days; after <= 5 min, Download is empty and the admin hazard counts drop.
8. Twisty: ride a twisty road with a planned route -> "Twisty section next N km" heads-up; trip report Safety summary
   shows "Twisty roads: N km".
9. Regression gate (block A of MASTER_AGENT_PROMPT): SOS hold, crash alarm countdown + auto SOS, emergency texts,
   lock-screen Medical ID, ride lock: unchanged.

=== 7. PLAY DATA SAFETY (update before rolling 10026 beyond internal testing) ===
docs/handbook/compliance/play_store_compliance.md §2 "Round 4": Location approximate -> collected, optional, App
functionality + Analytics, not shared; App activity (crash alarm outcome) -> collected, optional, not shared; deletion
available in-app and on the web. No new permissions (no manifest change). Release notes: "Road safety warnings: hazard
ahead, rough road, twisty roads, long-ride and night nudges. Optional: help make roads safer by sharing anonymous road
signals."

=== 8. OWNER DECISIONS (ask, do not invent) ===
O-1  Keep CRASH_BRAIN_MODE=shadow until >= 200 labelled alarms per group and a review of the held-out numbers.
O-2  Crash alarm features: consent-only (built) vs legitimate safety use without consent (needs legal review).
O-3  Break interval: the app offers 1 h 30 / 1 h 45 / 2 h (the 2 h reminder is always on per the Nov 11 decision);
     allow 2 h 30 / 3 h (relaxes the always-on reminder)?
O-4  "Rough road ahead" default ON (low priority, 1 per 5 km) - confirm.
O-5  Fold the 3.55 risky-stretch heads-up (road_risk.js, no consent switch, k >= 10) into the consented hazard layer?
O-6  INTEL_K_MIN 5 at launch (raise to 10 for the first months while rider numbers are small?).
O-7  Admin map tiles from tile.openstreetmap.org (low volume) vs a self-hosted / licensed tile server.
O-8  Saved home / work places do not exist in the app; the privacy-zone trimming is ready for when they do.
O-W1 Existing 3.16 route weather uses Open-Meteo's free tier (non-commercial terms): replace or license before launch.
O-V  When the A1 arrives: Valhalla (gateway/deploy/valhalla/README.md) and ROUTER_KIND=valhalla.
```
