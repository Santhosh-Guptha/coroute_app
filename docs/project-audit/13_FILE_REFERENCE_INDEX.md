# 13. File Reference Index

**Target**: CoRoute Searchable File Reference  
**Modules**: `coroute_app/lib/`, `coroute_app/gateway/`, `coroute_app/android/`, `coroute_app/ios/`  

---

## 1. Flutter Core & Foundation (`coroute_app/lib/core/`)

* [`app_config.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/config/app_config.dart): Runtime configuration constants, API and WebSocket endpoint URLs, Google OAuth Web Client ID, telemetry intervals, and audio sample rate constants.
* [`feature_gates.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/config/feature_gates.dart): Subscription tiers enum (`SubscriptionTier`), feature enum (`Feature`), gating evaluator (`isUnlocked`), tier descriptions, and test overrides.
* [`app_constants.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/constants/app_constants.dart): App branding name, storage keys, and UI sizing tokens.
* [`net_constants.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/constants/net_constants.dart): Network retry thresholds, ping/pong timeouts, roster refresh intervals, and outbox failure retention periods.
* [`l10n.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/l10n/l10n.dart): Localization engine supporting safety texts, unit conversions, and language fallbacks.
* [`app_theme.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/theme/app_theme.dart): High-contrast color palette, AMOLED dark theme tokens, semantic text styles, and elevation shadows.
* [`theme_controller.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/theme/theme_controller.dart): Manages dynamic theme switching, solar position calculations (automatic sunrise/sunset theme changes based on GPS fixes).
* [`design_kit.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/ui/design_kit.dart): 56dp glove-friendly buttons, uppercase section headers (`DsSectionHeader`), metric pills, hero cards, and status tags.

---

## 2. Flutter Data Layer (`coroute_app/lib/data/`)

### Remote Services (`lib/data/services/`)
* [`api_client.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/api_client.dart): HTTP client wrapper handling Bearer JWT headers, JSON encoding/decoding, and centralized error parsing.
* [`auth_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/auth_service.dart): Authentication lifecycle, login/register endpoints, Google Sign-In orchestration, and profile state.
* [`background_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/background_service.dart): Manages Android foreground service lifecycle, notification actions, and app minimization.
* [`convoy_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/convoy_service.dart): Central state machine for group rides, participant telemetry, outbox synchronization, stop point management, and ride lifecycle.
* [`realtime_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/realtime_service.dart): Low-level WebSocket client managing socket connection, reconnect backoffs, heartbeat timers, and frame multiplexing.
* [`intercom_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/intercom_service.dart): Half-duplex helmet audio streaming, VOX energy thresholding, and Road Captain priority voice ducking.
* [`safety_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/safety_service.dart): Coordinates crash detection, emergency alarms, full-screen lock screen intents, and SMS dispatch.
* [`road_hazard_detector.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/road_hazard_detector.dart): Evaluates vertical Z-axis accelerometer spikes to detect potholes and broadcasts them to following riders.
* [`siren_acoustic_detector.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/siren_acoustic_detector.dart): Real-time audio frequency analyzer detecting emergency vehicle sirens and attenuating background chatter.
* [`ble_remote_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/ble_remote_service.dart): State machine and command processor for handlebar-mounted Bluetooth wireless remotes.
* [`biometric_safety_bridge.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/biometric_safety_bridge.dart): Collects smartwatch pulse data to escalate crash severity during acute physical trauma.
* [`satellite_sos_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/satellite_sos_service.dart): Low-connectivity emergency relay transmitting 16-byte encoded packets via satellite or cellular ERSS.
* [`tile_cache_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/tile_cache_service.dart): 2.5 km Minkowski corridor offline map tile prefetcher and SQLite cache.
* [`trip_storage_service.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/trip_storage_service.dart): Local and cloud synchronization for completed trip records and GPX trails.

---

## 3. Flutter Domain Layer (`coroute_app/lib/domain/`)

* [`crash_detector.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/domain/safety/crash_detector.dart): High-G impact detection (> 3.2G) followed by Doppler velocity cessation within 18.0 seconds.
* [`sos_packet_codec.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/domain/safety/sos_packet_codec.dart): Encodes GPS coordinates, altitude, timestamp, and severity into an ultra-compact 16-byte binary payload with CRC-8 validation.
* [`fuel_range.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/domain/safety/fuel_range.dart): Odometer-based fuel consumption model with automatic recovery from GPS uncertainty latches.
* [`ride_facts.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/domain/ride/ride_facts.dart): Spatial calculations for convoy ladder formation, lead-to-sweeper spread, and relative ahead/behind distance.
* [`alert_policy.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/domain/notify/alert_policy.dart): Rate-limiting and prioritization engine preventing notification fatigue for riders.

---

## 4. Flutter Presentation Layer (`coroute_app/lib/presentation/`)

* [`live_cockpit_map_screen.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/rider/live_cockpit_map_screen.dart): Primary active ride cockpit map HUD with Bead Wire, VOX controls, and safety pills.
* [`rider_home_screen.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/rider/rider_home_screen.dart): Persistent shell host for `Home`, `Trips`, `Alerts`, and `Profile` tabs.
* [`crash_alarm_screen.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/safety/crash_alarm_screen.dart): 15-second abort countdown screen rendered over the lock screen during severe impacts.
* [`plan_selector_screen.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/subscription/plan_selector_screen.dart): Interactive plan switcher displaying feature comparison and testing overrides.
* [`trip_planner_screen.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/trip_planner/trip_planner_screen.dart): Interactive route planner with OSRM routing, elevation curves, and waypoint reordering.
* [`offline_map_manager_screen.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/trip_planner/offline_map_manager_screen.dart): Manages cached route corridor packs on local disk.
* [`master_admin_dashboard.dart`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/admin/master_admin_dashboard.dart): Admin governance console for live fleet monitoring and emergency oversight.

---

## 5. Gateway Backend (`coroute_app/gateway/src/`)

* [`server.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/server.js): Gateway process entrypoint initializing Express and WebSocket servers.
* [`app.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/app.js): Express middleware pipeline, security headers (`helmet`), and CORS policies.
* [`routes.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/routes.js): Primary REST router handling authentication, convoy rooms, tracks, and admin operations.
* [`ws.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/ws.js): WebSocket frame router managing client heartbeats, binary audio frames, and telemetry events.
* [`convoys.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/convoys.js): In-memory room manager maintaining live participant sets, state broadcast, and periodic database flushes.
* [`safety_network.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/safety_network.js): Topological routing engine dispatching cross-group mutual aid requests to nearby highway riders.
* [`guardians.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/guardians.js): Ride Guardian capability token issuer, PIN rate-limiter, and projection generator.
* [`road_hazards.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/road_hazards.js): Spatial clustering and broadcast manager for reported road defects.
* [`oracle/soda_repository.js`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/oracle/soda_repository.js): Oracle Autonomous Database SODA document store driver with atomic document replacement.
