# CoRoute Master Requirements Traceability Matrix

Document Identifier: CR-DOC-TEST-RTM-001  
Version: 1.0.0-PROD  
Classification: Safety Verification and Requirements Traceability  
Status: Authoritative Engineering Traceability Baseline  
Character Encoding: UTF-8 (Strict ASCII hyphens, Zero raw emojis)

--------------------------------------------------------------------------------

## 1. Traceability Architecture Framework

This document establishes the end-to-end traceability matrix connecting every functional, safety, and distributed requirement to its corresponding codebase implementation, automated test verification, runtime telemetry/logging, and formal release gates.

The verification pipeline enforces the strict rule:
Requirement -> Implementation Code Symbol -> Automated Verification Test -> Telemetry / Log -> Release Gate

Release Priority Definitions:
- P0: Life, safety, or privacy critical. No known failures, flakiness, or privacy bypasses permitted. Release-blocking.
- P1: High ride-safety and operational impact. Release-blocking unless formal signed risk acceptance is recorded.
- P2: Important operational feature with existing safe fallback. Canary rollout permitted.
- P3: Experience, visual presentation, or non-safety analytics. Non-blocking.

--------------------------------------------------------------------------------

## 2. Production Feature Requirements Traceability (REQ-01 to REQ-15)

| Req ID | Requirement Name | Priority | Implementation Files & Primary Symbols | Protocol / API / Schema | Verification Level & Automated Tests | Telemetry / Audit Log Event | Release Gate |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| REQ-01 | Zero-Permission SMS Intent & Indian Emergency Dispatch | P0 | `android/.../SmsChannel.kt` (`launchSmsIntent`), `lib/data/services/sms_sender.dart` (`NativeSmsSender`), `lib/presentation/widgets/emergency_sos_sheet.dart` | `Intent.ACTION_SENDTO`, `smsto:<cleanTo>`, speed-dial: 112, 108, 100, 1073 | Unit / Mobile E2E: `test/sms_fallback_test.dart`, `test/scenario_f_indian_emergency_fallback_test.dart` | `EMERGENCY_SMS_INTENT_LAUNCHED`, `EMERGENCY_DIALLER_TRIGGERED` | GATE-P0-SMS-SAFETY |
| REQ-02 | Offline Emergency Corridor Pack & ICE Medical Card | P0 | `lib/data/local/emergency_corridor_store.dart` (`EmergencyCorridorStore`), `lib/data/models/ice_profile.dart`, `lib/data/local/ice_profile_store.dart` | SQLite table `emergency_corridor_places`, `GET /api/v1/routes/:id/emergency-corridor` | Unit / Local Store: `test/scenario_tunnel_and_offline_test.dart`, `test/scenario_f_indian_emergency_fallback_test.dart` | `OFFLINE_CORRIDOR_LOADED`, `ICE_PROFILE_ACCESSED` | GATE-P0-ICE-PRIVACY |
| REQ-03 | Dead-Zone Tunnel Coasting & GPS Shadow Dead-Reckoning | P0 | `lib/domain/tracking/dead_reckoning_engine.dart` (`DeadReckoningEngine`), `lib/domain/route/off_route_detector.dart` (`OffRouteDetector`) | Along-route exponential speed decay projection: $v(t) = v_0 \cdot e^{-\alpha t}$ | Unit / Deterministic Sim: `test/scenario_a_tunnel_blackout_test.dart`, `test/scenario_tunnel_and_offline_test.dart` | `TUNNEL_COASTING_ENGAGED`, `TUNNEL_COASTING_EXPIRED` | GATE-P0-DEAD-RECKON |
| REQ-04 | Multi-Stage Battery Governor & Last-Gasp Beacon | P0 | `lib/domain/tracking/ride_power_policy.dart` (`RidePowerPolicy`), `lib/data/services/convoy_service.dart`, `gateway/src/ws.js` | 4-tier governor (Normal, Conserve, Extreme, Last-Gasp <=5%), frame `LAST_GASP_BEACON` | Unit / Power Sim: `test/ride_power_policy_test.dart`, `test/scenario_c_low_battery_throttle_test.dart` | `BATTERY_GOVERNOR_TIER_CHANGED`, `LAST_GASP_BEACON_EMITTED` | GATE-P0-LAST-GASP |
| REQ-05 | OEM Killer Defense & Screen-Off Liveness Guard | P0 | `android/app/src/main/AndroidManifest.xml`, `android/.../RideNotification.kt`, `lib/data/services/background_service.dart` | `foregroundServiceType="location\|microphone"`, sticky restart, wakelock renewal | Unit / Android Platform: `test/scenario_battery_and_emergency_test.dart`, `test/network_settings_ui_test.dart` | `BACKGROUND_SERVICE_STARTED`, `WAKELOCK_ACQUIRED` | GATE-P0-BG-LIVENESS |
| REQ-06 | Patchy Network Binary Framing & Delta Sync | P1 | `lib/data/services/realtime_service.dart`, `gateway/src/ws.js` (`handleBinaryTelemetry`) | 24-byte compact binary frame `0x10`, encoded polyline delta synchronization | Contract / Integration: `test/network_wire_test.dart`, `gateway/test/net_compat.test.js` | `BINARY_FRAME_DECODED`, `DELTA_SYNC_COMPLETED` | GATE-P1-WIRE-COMPAT |
| REQ-07 | Learned Fuel Model & Speed/Elevation Bins | P1 | `lib/domain/safety/fuel_consumption_learner.dart` (`SpeedBinConsumptionLearner`), `lib/domain/safety/fuel_profile.dart` | 3 speed bins: Urban (<45 km/h), Cruise (45-85 km/h), Highway (>85 km/h), EMA updates | Unit / Property: `test/scenario_fuel_and_essentials_test.dart`, `test/fuel_range_test.dart` | `SPEED_BIN_SAMPLE_RECORDED`, `FUEL_MODEL_CALIBRATED` | GATE-P1-FUEL-ESTIMATE |
| REQ-08 | Resilient Convoy Bottleneck & COCO Station Guidance | P1 | `lib/domain/safety/group_fuel.dart` (`commonFuelStop`), `gateway/src/essentials.js` (`FILTERS.FUEL`) | Bounded bottleneck search: contributors >= 1, COCO verified tags (IOCL, BPCL, HPCL, Shell) | Unit / Contract: `test/group_fuel_stop_test.dart`, `test/scenario_fuel_and_essentials_test.dart` | `GROUP_FUEL_BOTTLENECK_CALCULATED`, `COCO_STATION_MATCHED` | GATE-P1-FUEL-STOP |
| REQ-09 | India Roadside Support (Puncture Repair & DH/CHCs) | P1 | `gateway/src/essentials.js`, `lib/presentation/ride/essentials_sheet.dart` (`EssentialsSheet`) | Overpass queries for `shop=tyres`, `craft=welder`, `healthcare=centre` | Integration / Contract: `gateway/test/essentials.test.js`, `test/scenario_fuel_and_essentials_test.dart` | `ROADSIDE_ESSENTIALS_QUERY_SERVED`, `POIS_PARSED` | GATE-P1-POI-RELIABLE |
| REQ-10 | One-Click Offline Route Corridor & Tile Pre-Cache | P1 | `lib/data/services/tile_cache_service.dart` (`TileCacheService`), `lib/presentation/trip_planner/trip_planner_screen.dart` | 3 km polygon buffer, zoom 10-15 vector tiles stored in SQLite | Unit / Store E2E: `test/tile_cache_test.dart`, `test/trip_storage_test.dart` | `CORRIDOR_PACK_DOWNLOAD_STARTED`, `PACK_ACTIVATED` | GATE-P1-TILE-CACHE |
| REQ-11 | Convoy Sub-Cluster / Split-Pack Detection | P2 | `gateway/src/timeline.js` (`detectSubClusters`), `lib/presentation/rider/live_cockpit_map_screen.dart` | 1D along-route clustering, event `CONVOY_SPLIT`, split threshold 1200m for > 45s | Contract / Sim: `gateway/test/convoy_watchdog.test.js`, `test/scenario_d_convoy_split_test.dart` | `CONVOY_SPLIT_DETECTED`, `SUB_CLUSTERS_UPDATED` | GATE-P2-CONVOY-SPLIT |
| REQ-12 | Dynamic Rendezvous & "Regroup Ahead" Protocol | P2 | `gateway/src/convoys.js` (`setRegroupPoint`), `lib/presentation/rider/live_cockpit_map_screen.dart` | Client `REGROUP_SET`, server broadcast `REGROUP_ACTIVE`, completion radius 150m | Contract / E2E: `gateway/test/convoy_watchdog.test.js`, `test/scenario_d_convoy_split_test.dart` | `REGROUP_POINT_SET`, `REGROUP_CONVERGENCE_ACHIEVED` | GATE-P2-REGROUP |
| REQ-13 | Sweeper Distress Reverse-Escalation Safeguard | P2 | `gateway/src/timeline.js` (`checkSweeperDistress`), `lib/data/services/voice_service.dart` | Event `SWEEPER_DISTRESS`: Sweeper speed < 5 km/h while Lead > 35 km/h for > 90s | Contract / Audio: `gateway/test/convoy_watchdog.test.js`, `test/scenario_convoy_dynamics_test.dart` | `SWEEPER_DISTRESS_TRIGGERED`, `LEAD_ALARM_DISPATCHED` | GATE-P2-SWEEPER-DISTRESS |
| REQ-14 | Lost Rider Breadcrumb & Compass Directional Beacon | P2 | `lib/domain/route/lost_rider_recovery_coordinator.dart`, `lib/presentation/rider/live_cockpit_map_screen.dart` | Reverse track backtrack vector + hardware compass bearing calculation | Unit / Math: `test/route_guidance_test.dart`, `test/scenario_tunnel_and_offline_test.dart` | `LOST_RIDER_HOMING_ACTIVE`, `BACKTRACK_VECTOR_COMPUTED` | GATE-P2-LOST-RIDER |
| REQ-15 | Hands-Free Bluetooth Helmet Earcon Protocol | P2 | `lib/data/services/voice_service.dart` (`VoiceService`), `assets/audio/` earcon tokens | Distinct audio tones (SOS, split, regroup, fuel), 70% audio ducking | Unit / Audio: `test/voice_service_test.dart`, `test/voice_hud_notification_test.dart` | `EARCON_PLAYED`, `AUDIO_DUCKING_APPLIED` | GATE-P2-AUDIO-EARCON |

--------------------------------------------------------------------------------

## 3. Deep Research Report Architectural Domains Traceability (Sections A to R)

| Section Ref | Domain Name | Priority | Core Requirements & Safety Invariants | Implementation File & Symbol | Existing Test Suite Reference | Release Gate |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| SEC-A | Ride & Group Core | P0 / P1 | Complete tenancy isolation, member state sync, strict session expiration | `gateway/src/convoys.js`, `lib/data/services/convoy_service.dart` | `gateway/test/gateway.test.js`, `test/rebuilds_test.dart` | GATE-P0-AUTH-ISOLATION |
| SEC-B | Convoy Safety | P1 | Dynamic separation monitoring, stationary rider traffic suppression | `lib/domain/route/route_guide.dart`, `gateway/src/timeline.js` | `gateway/test/timeline.test.js`, `test/route_alerts_test.dart` | GATE-P1-CONVOY-SAFETY |
| SEC-C | Crash & SOS Lifecycle | P0 | Multi-sensor crash verification, 30s cancellation, server dedupe | `lib/domain/safety/crash_detector.dart`, `gateway/src/convoys.js` | `test/safety_service_test.dart`, `gateway/test/safety_sos.test.js` | GATE-P0-SOS-DEDUPE |
| SEC-D | Emergency Information | P0 | Medical data isolation: visible only during open SOS, purged on close | `lib/data/models/ice_profile.dart`, `gateway/src/auth.js` | `gateway/test/profile_medical.test.js`, `test/medical_profile_test.dart` | GATE-P0-ICE-PRIVACY |
| SEC-E | Nearby Group Assistance | P1 | Route-aware cross-group assistance matching; concurrency capped at 2 | `gateway/src/safety_network.js`, `lib/data/models/network_wire.dart` | `gateway/test/safety_network.test.js`, `test/incident_ui_test.dart` | GATE-P1-ASSIST-MATCH |
| SEC-F | Approaching Hazard Warning | P1 | Along-route hazard lookahead; opposite carriageway suppression | `gateway/src/safety_network.js`, `lib/domain/route/threshold_announcer.dart` | `gateway/test/net_hazard.test.js`, `test/route_alerts_test.dart` | GATE-P1-HAZARD-WARN |
| SEC-G | Public/Private Discovery | P2 | Private groups strictly omitted from social discovery and encounters | `gateway/src/discovery.js`, `lib/data/models/convoy_model.dart` | `gateway/test/discovery.test.js`, `test/discovery_card_test.dart` | GATE-P2-DISCOVERY-SECLUSION |
| SEC-H | Privacy Separation Invariant | P0 | Social privacy setting != Safety relay consent; zero metadata leakage | `gateway/src/feature_policy.js`, `gateway/src/safety_network.js` | `gateway/test/net_privacy.test.js`, `gateway/test/feature_policy.test.js` | GATE-P0-PRIVACY-SPLIT |
| SEC-I | Route Essentials Discovery | P1 | Corridor bounding box search, OSRM road detour computation | `gateway/src/essentials.js`, `lib/domain/safety/essentials_discovery.dart` | `gateway/test/essentials.test.js`, `test/route_essentials_test.dart` | GATE-P1-ESSENTIALS |
| SEC-J | Fuel Intelligence | P1 | Theoretical vs safe remaining range; clear estimation labelling | `lib/domain/safety/fuel_range.dart`, `fuel_profile.dart` | `test/fuel_range_test.dart`, `test/scenario_fuel_and_essentials_test.dart` | GATE-P1-FUEL-INTELLIGENCE |
| SEC-K | Per-Rider Fuel Decision Support | P1 | Never skip station if next exceeds safe range; range-risk alarm | `lib/domain/safety/fuel_profile.dart` (`fuelAdvice`) | `test/fuel_range_test.dart`, `test/scenario_fuel_and_essentials_test.dart` | GATE-P1-RANGE-RISK |
| SEC-L | Ride Guardian Web Experience | P0 | Capability token entropy (24-byte), SHA-256 hash storage, instant revoke | `gateway/src/guardians.js`, `gateway/public/watch.html` | `gateway/test/guardians.test.js`, `gateway/test/guardian_browser.test.js` | GATE-P0-GUARDIAN-REVOKE |
| SEC-M | Offline Ride Pack | P1 | Pre-cached vector tiles, geometry, POIs; atomic local activation | `lib/data/services/tile_cache_service.dart`, `emergency_corridor_store.dart` | `test/tile_cache_test.dart`, `test/trip_storage_test.dart` | GATE-P1-OFFLINE-PACK |
| SEC-N | Delay-Tolerant Relay Core | P0 | RFC 9171 bundle encapsulation, origin pseudonymity (Planned) | Architectural specification; local `lib/data/local/outbox_store.dart` | Discrete Sim Specification (Planned Suite) | GATE-P0-DTN-INTEGRITY |
| SEC-O | Store-Carry-Forward Model | P0 | Multi-carrier transfer across dead zones; intermediate audit states (Planned) | Architectural specification; simulated contact graphs | Discrete Sim Specification (Planned Suite) | GATE-P0-STORE-CARRY-FWD |
| SEC-P | DTN TTL & Bundle Age | P0 | Bundles past TTL dropped immediately; clock skew defense (Planned) | Architectural specification; strict RFC 9171 age calculation | Unit / Property Specification (Planned Suite) | GATE-P0-BUNDLE-TTL |
| SEC-Q | Hop Limit Bounds | P0 | Monotonic hop increment; loop rejection A-B-C-A (Planned) | Architectural specification; $H \le H_{max}$ threshold | Property Specification (Planned Suite) | GATE-P0-HOP-LIMIT |
| SEC-R | Multi-Transport Deduplication | P0 | Multi-path bundle arrival dedupes to single canonical incident | `gateway/src/convoys.js` (`handleSos`), `lib/data/local/outbox_store.dart` | `gateway/test/safety_sos.test.js`, `gateway/test/outbox.test.js` | GATE-P0-SOS-DEDUPE |

--------------------------------------------------------------------------------

## 4. Release Gate Mapping and Enforcement Protocol

All code modifications targeting `main` or release tags must pass their associated gates in the automated continuous integration pipeline:

1. Gate `GATE-P0-SMS-SAFETY`:
   - Verification: Launching emergency SOS on Android 12 through Android 15 triggers `Intent.ACTION_SENDTO` with pre-filled coordinates. Zero runtime `SEND_SMS` permissions requested.
   - Test Command: `flutter test test/sms_fallback_test.dart test/scenario_f_indian_emergency_fallback_test.dart`
2. Gate `GATE-P0-GUARDIAN-REVOKE`:
   - Verification: Revoking a Guardian capability token terminates all open WebSockets within 500 ms and returns HTTP 410 on all subsequent snapshot/ticket queries.
   - Test Command: `cd gateway && node --test test/guardians.test.js test/guardian_browser.test.js`
3. Gate `GATE-P0-ICE-PRIVACY`:
   - Verification: Medical profile information is strictly omitted from admin listings, discovery feeds, and public timeline events.
   - Test Command: `cd gateway && node --test test/profile_medical.test.js test/emergency_status.test.js`
4. Gate `GATE-P1-FUEL-STOP`:
   - Verification: Convoy fuel stop engine executes successfully with partial group participation (contributors >= 1) and surfaces the limiting bottleneck rider.
   - Test Command: `flutter test test/group_fuel_stop_test.dart test/scenario_fuel_and_essentials_test.dart`
5. Gate `GATE-P1-CONVOY-SAFETY`:
   - Verification: Sub-cluster split recognition and Sweeper distress reverse-escalation trigger without false alarm storms.
   - Test Command: `cd gateway && node --test test/convoy_watchdog.test.js && cd .. && flutter test test/scenario_d_convoy_split_test.dart`
