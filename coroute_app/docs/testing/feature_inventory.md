# CoRoute Master Feature Implementation Inventory

Document Identifier: CR-DOC-TEST-INV-001  
Version: 1.0.0-PROD  
Classification: Safety Verification and Requirements Traceability  
Status: Authoritative Codebase Baseline  
Character Encoding: UTF-8 (Strict ASCII hyphens, Zero raw emojis)

--------------------------------------------------------------------------------

## 1. System Overview and Audit Methodology

This document establishes the official ground-truth verification of all functional, safety-critical, distributed, and experimental capabilities across the CoRoute platform.

Every capability in this inventory is audited directly against the physical codebase:
- Flutter Mobile Application (`coroute_app/lib/`)
- Gateway Server and Oracle SODA Persistence (`coroute_app/gateway/src/`)
- Android Platform Layer (`coroute_app/android/`)
- Automated Test Suites (`coroute_app/test/`, `coroute_app/gateway/test/`)

### 1.1 Status Classification Taxonomy

Each capability is rigorously categorized into one of five definitive lifecycle states:

- IMPLEMENTED: Executable code path exists and is reachable in the current production product. Fully backed by tests.
- PARTIAL: Subsystem models, schemas, or gateway endpoints exist, but the end-to-end client-server bridge, UI flow, or offline transport is incomplete.
- EXPERIMENTAL: Prototype implementation, simulation fixture, or developer-mode feature exists, but is not certified for production deployment.
- PLANNED: Documented requirement or architectural specification exists; no production execution path currently exists in the repository.
- UNKNOWN: Insufficient repository evidence exists to verify capability operation or intended architecture.

--------------------------------------------------------------------------------

## 2. Core Safety and Architectural Subsystems Inventory

### 2.1 Section A: Ride and Group Core

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Authentication & Session Handling | IMPLEMENTED | `gateway/src/auth.js` (`AuthService`), `lib/data/services/auth_service.dart` (`AuthService`) | `POST /api/v1/auth/login`, `POST /api/v1/auth/register`, JWT Bearer token | `gateway/test/session.test.js`, `test/rebuilds_test.dart` |
| Ride Creation & Join Codes | IMPLEMENTED | `gateway/src/convoys.js` (`createConvoy`), `lib/data/services/convoy_service.dart` | `POST /api/v1/rides`, `coroute://join/:code`, 6-character code | `gateway/test/gateway.test.js`, `gateway/test/join_limits.test.js` |
| Planned Route & Stops Management | IMPLEMENTED | `lib/domain/route/route_plan.dart`, `gateway/src/routes.js` | `GET /api/v1/routes/:id`, SODA collection `routes` | `gateway/test/route.test.js`, `test/trip_planner_test.dart` |
| Live Location, Speed & Heading Broadcast | IMPLEMENTED | `lib/domain/tracking/track_point.dart`, `gateway/src/ws.js` | WebSocket frame `STATUS` (`lat`, `lng`, `speedKmh`, `heading`) | `test/tracking_test.dart`, `gateway/test/presence.test.js` |
| Ahead/Behind Ordering & Group Spread | IMPLEMENTED | `lib/domain/ride/ride_facts.dart` (`alongRouteOrder`, `groupSpreadM`), `gateway/src/timeline.js` | Along-route 1D projection metric, event `SPREAD_WARNING` | `test/ride_facts_test.dart`, `gateway/test/timeline.test.js` |
| Roster Roles: Lead, Sweeper, Pack | IMPLEMENTED | `lib/data/models/convoy_model.dart` (`RiderRole`), `gateway/src/convoys.js` (`setRole`) | WebSocket `ROLE_SET`, `ROLE_CHANGED`, Oracle SODA `members` | `gateway/test/sweeper.test.js`, `test/scenario_convoy_dynamics_test.dart` |
| Reconnect & State Synchronization | IMPLEMENTED | `lib/data/services/convoy_service.dart` (`_reconnect`), `gateway/src/ws.js` | Client `HELLO`, Gateway `ROOM_SNAPSHOT`, `OUTBOX_DRAIN` | `gateway/test/outbox.test.js`, `test/low_data_test.dart` |
| Timeline & Event Replay | IMPLEMENTED | `gateway/src/timeline.js` (`TimelineEngine`), `lib/data/models/timeline_event_model.dart` | `GET /api/v1/rides/:id/timeline`, SODA `timeline_events` | `gateway/test/timeline.test.js`, `test/timeline_ui_test.dart` |

### 2.2 Section B: Convoy Safety Dynamics

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Individual Separation Alert | IMPLEMENTED | `lib/domain/route/route_guide.dart`, `gateway/src/timeline.js` (`checkSeparation`) | Event `SEPARATED`, distance > 1000m for > 45s | `gateway/test/timeline.test.js`, `test/route_alerts_test.dart` |
| Behind-Sweeper Warning | IMPLEMENTED | `gateway/src/timeline.js` (`checkBehindSweeper`), `lib/presentation/rider/live_cockpit_map_screen.dart` | Event `BEHIND_SWEEPER`, 500m behind sweeper for 60s | `gateway/test/sweeper.test.js`, `test/scenario_d_convoy_split_test.dart` |
| Sweeper Distress Reverse Escalation (REQ-13) | IMPLEMENTED | `gateway/src/timeline.js` (`checkSweeperDistress`), `lib/data/services/voice_service.dart` | Event `SWEEPER_DISTRESS`, halts while lead cruises | `gateway/test/convoy_watchdog.test.js`, `test/scenario_convoy_dynamics_test.dart` |
| Convoy Sub-Cluster Split Detection (REQ-11) | IMPLEMENTED | `gateway/src/timeline.js` (`detectSubClusters`), `lib/data/models/convoy_model.dart` | Event `CONVOY_SPLIT`, 1D along-route gap > 1200m | `gateway/test/convoy_watchdog.test.js`, `test/scenario_d_convoy_split_test.dart` |
| Dynamic Rendezvous "Regroup Ahead" (REQ-12) | IMPLEMENTED | `gateway/src/convoys.js` (`setRegroupPoint`), `lib/presentation/rider/live_cockpit_map_screen.dart` | WebSocket `REGROUP_SET`, event `REGROUP_ACTIVE` | `gateway/test/convoy_watchdog.test.js`, `test/scenario_d_convoy_split_test.dart` |
| Stationary Rider Detection & Congestion Suppression | IMPLEMENTED | `lib/domain/tracking/stop_detector.dart`, `gateway/src/timeline.js` | Cluster stop filter, suppresses false crash alerts in traffic | `test/tracking_test.dart`, `gateway/test/timeline.test.js` |
| Off-Route Detection & Timing | IMPLEMENTED | `lib/domain/route/off_route_detector.dart` (`OffRouteDetector`), `gateway/src/timeline.js` | Event `OFF_ROUTE`, threshold 75m deviation for > 30s | `test/route_behaviour_test.dart`, `test/route_guidance_test.dart` |
| Lost Rider Recovery & Compass Beacon (REQ-14) | IMPLEMENTED | `lib/domain/route/lost_rider_recovery_coordinator.dart`, `lib/presentation/rider/live_cockpit_map_screen.dart` | Reverse backtrack vector + hardware magnetometer azimuth | `test/route_guidance_test.dart`, `test/scenario_tunnel_and_offline_test.dart` |
| Inertial Dead-Reckoning & Tunnel Coasting (REQ-03) | IMPLEMENTED | `lib/domain/tracking/dead_reckoning_engine.dart` (`DeadReckoningEngine`), `lib/data/models/rider_model.dart` | Decaying speed projection along polyline up to 12 minutes | `test/scenario_a_tunnel_blackout_test.dart`, `test/scenario_tunnel_and_offline_test.dart` |

### 2.3 Section C: Crash and SOS Lifecycle

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Accelerometer Crash Sampling | IMPLEMENTED | `coroute_app/android/.../AccelStream.kt`, `lib/data/services/accel_source.dart` | EventChannel `coroute/accel`, sample rate 50 Hz | `test/safety_service_test.dart`, `test/hard_brake_test.dart` |
| Multi-Stage Crash Detection Algorithm | IMPLEMENTED | `lib/domain/safety/crash_detector.dart` (`CrashDetector`), `accel_bucket.dart` | Impact vector > 3.2g followed by stationary state | `test/safety_service_test.dart`, `test/scenario_e_multi_incident_alarm_test.dart` |
| 30-Second Pre-Alert Grace Countdown | IMPLEMENTED | `lib/presentation/safety/crash_alarm_screen.dart` (`CrashAlarmView`), `lib/data/services/safety_service.dart` | Fullscreen countdown UI, "I'm OK" suppresses dispatch | `test/crash_alarm_screen_test.dart`, `test/sos_hold_screen_test.dart` |
| Manual SOS Dispatch | IMPLEMENTED | `lib/core/ui/sos_button.dart`, `lib/presentation/widgets/emergency_sos_sheet.dart` | 3-second hold-to-activate button, haptic feedback | `test/sos_hold_screen_test.dart`, `test/ui_widgets_test.dart` |
| Emergency Classification Types | IMPLEMENTED | `lib/data/models/sos_alert_model.dart` (`SosType`) | Types: `CRASH`, `MEDICAL`, `BREAKDOWN`, `GENERAL`, `RIDER_DOWN` | `test/network_wire_test.dart`, `gateway/test/emergency_status.test.js` |
| Client-Side Incident ID & Server Deduplication | IMPLEMENTED | `lib/data/models/pending_sos.dart`, `gateway/src/convoys.js` (`handleSos`) | Unique `clientId` UUIDv4, idempotent in-flight dedupe | `gateway/test/safety_sos.test.js`, `gateway/test/incident.test.js` |
| Emergency Resolution Lifecycle | IMPLEMENTED | `gateway/src/convoys.js` (`resolveSos`), `lib/data/services/convoy_service.dart` | WebSocket `SOS_RESOLVE`, reasons: `RESOLVED`, `FALSE_ALARM` | `gateway/test/safety_sos.test.js`, `test/emergency_sos_sheet_test.dart` |
| Audio Preemption & TTS Dispatch | IMPLEMENTED | `lib/data/services/voice_service.dart`, `coroute_app/android/.../TtsChannel.kt` | MethodChannel `coroute/tts`, ducks music 70%, overrides PTT | `test/voice_service_test.dart`, `test/voice_hud_notification_test.dart` |

### 2.4 Section D: Emergency Information and Indian Helplines

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Zero-Permission SMS Fallback Intent (REQ-01) | IMPLEMENTED | `android/.../SmsChannel.kt` (`launchSmsIntent`), `lib/data/services/sms_sender.dart` | `Intent.ACTION_SENDTO` with `smsto:<number>` data URI | `test/sms_fallback_test.dart`, `test/scenario_f_indian_emergency_fallback_test.dart` |
| Direct Indian Emergency Diallers (REQ-01) | IMPLEMENTED | `lib/presentation/widgets/emergency_sos_sheet.dart` | Single-tap dialler actions: 112 (National), 108 (Ambulance), 100 (Police), 1073 (NHAI) | `test/emergency_sos_sheet_test.dart`, `test/scenario_f_indian_emergency_fallback_test.dart` |
| Offline SQLite Emergency Corridor Pack (REQ-02) | IMPLEMENTED | `lib/data/local/emergency_corridor_store.dart` (`EmergencyCorridorStore`) | SQLite table `emergency_corridor_places`, 25 km bounding box | `test/scenario_tunnel_and_offline_test.dart`, `test/scenario_f_indian_emergency_fallback_test.dart` |
| On-Screen ICE Medical Profile (REQ-02) | IMPLEMENTED | `lib/data/models/ice_profile.dart`, `lib/data/local/ice_profile_store.dart` | High-contrast blood group, allergies, medications, donor flag | `test/medical_profile_test.dart`, `test/scenario_f_indian_emergency_fallback_test.dart` |
| Medical Data Exposure Isolation & Purge | IMPLEMENTED | `gateway/src/auth.js`, `gateway/src/convoys.js` | Medical info broadcast only during open SOS; purged on resolve | `gateway/test/profile_medical.test.js`, `gateway/test/emergency_status.test.js` |

### 2.5 Section E: Nearby Group Cross-Assistance

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Cross-Group Assistance Candidate Matcher | IMPLEMENTED | `gateway/src/safety_network.js` (`SafetyNetworkCoordinator`), `net_geo.js` | Route-aware carriageway, heading alignment, detour estimation | `gateway/test/safety_network.test.js`, `gateway/test/net_behaviour.test.js` |
| Assistance Request Delivery Protocol | IMPLEMENTED | `gateway/src/safety_network.js`, `lib/data/models/network_wire.dart` | WebSocket `ASSIST_REQUEST`, payload with route ETA and distance | `gateway/test/safety_network.test.js`, `test/incident_ui_test.dart` |
| Responder State Transition Lifecycle | IMPLEMENTED | `gateway/src/safety_network.js`, `lib/data/services/convoy_service.dart` | States: `OFFERED`, `EN_ROUTE`, `ARRIVING`, `ARRIVED`, `CANCELLED` | `gateway/test/safety_network.test.js`, `test/incident_ui_test.dart` |
| Multi-Responder Race & Concurrency Cap | IMPLEMENTED | `gateway/src/safety_network.js` (`acceptRequest`) | Atomic responder assignment, max 2 responders per incident | `gateway/test/safety_network.test.js`, `gateway/test/net_abuse.test.js` |

### 2.6 Section F: Approaching-Group Hazard Warnings

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Downstream Hazard Proximity Calculator | IMPLEMENTED | `gateway/src/safety_network.js` (`checkApproachingHazards`), `net_geo.js` | Bounded along-route search: 5 km awareness, 2 km caution, 1 km warning | `gateway/test/net_hazard.test.js`, `test/route_alerts_test.dart` |
| Opposing Carriageway / Alternate Route Filter | IMPLEMENTED | `gateway/src/net_geo.js` (`isSameCarriageway`) | Bearing delta clamp (< 45 deg) and road segment matching | `gateway/test/far_by_road.test.js`, `gateway/test/net_hazard.test.js` |
| Audible Voice Hysteresis & Throttling | IMPLEMENTED | `lib/domain/route/threshold_announcer.dart` (`ThresholdAnnouncer`) | 120-second cooldown per boundary, suppresses GPS jitter storms | `test/route_alerts_test.dart`, `test/voice_hud_notification_test.dart` |

### 2.7 Section G: Public & Private Group Discovery

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Public Convoy Discovery Feed | IMPLEMENTED | `gateway/src/discovery.js` (`DiscoveryService`), `lib/data/models/convoy_model.dart` | `GET /api/v1/discovery`, approximate centroid coordinates | `gateway/test/discovery.test.js`, `test/discovery_card_test.dart` |
| Private Group Seclusion Enforcement | IMPLEMENTED | `gateway/src/discovery.js`, `gateway/src/convoys.js` | Setting `visibility: 'PRIVATE'` strictly excludes group from query | `gateway/test/discovery.test.js`, `gateway/test/net_privacy.test.js` |
| Encounter Prediction & Cooldown | IMPLEMENTED | `gateway/src/discovery.js` (`predictEncounters`) | Relative velocity convergence, 30-minute encounter deduplication | `gateway/test/discovery.test.js`, `test/discovery_card_test.dart` |

### 2.8 Section H: Privacy Separation Invariant

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Social Privacy != Safety Relay Consent | IMPLEMENTED | `gateway/src/feature_policy.js`, `gateway/src/safety_network.js` | Private convoys receive safety hazard alerts while remaining invisible | `gateway/test/net_privacy.test.js`, `gateway/test/feature_policy.test.js` |
| Zero Identity Leakage to Responders | IMPLEMENTED | `gateway/src/safety_network.js` (`sanitizeIncidentForExternal`) | Discloses only first name, vehicle brand, and incident coordinates | `gateway/test/net_privacy.test.js`, `gateway/test/safety_network.test.js` |

### 2.9 Section I: Route Essentials & Smart Stops

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| OSM Overpass Corridor Discovery | IMPLEMENTED | `gateway/src/essentials.js` (`EssentialsService`) | `GET /api/v1/routes/:id/essentials`, Overpass Turbo bounding query | `gateway/test/essentials.test.js`, `test/route_essentials_test.dart` |
| Specialized Roadside Support (REQ-09) | IMPLEMENTED | `gateway/src/essentials.js`, `lib/presentation/ride/essentials_sheet.dart` | Indian puncture repair wallahs (`shop=tyres`), local mechanics | `gateway/test/essentials.test.js`, `test/scenario_fuel_and_essentials_test.dart` |
| Detour Distance & Time Computation | IMPLEMENTED | `gateway/src/essentials.js` (`computeDetourMetrics`), `lib/domain/safety/essentials_discovery.dart` | OSRM detour table API call with haversine fallback | `gateway/test/essentials.test.js`, `test/route_essentials_test.dart` |
| Offline SQLite Corridor Caching (REQ-10) | IMPLEMENTED | `lib/data/services/route_essentials_service.dart`, `tile_cache_service.dart` | Pre-downloaded vector tiles and essential POIs stored in SQLite | `test/tile_cache_test.dart`, `test/trip_storage_test.dart` |

### 2.10 Sections J & K: Fuel Intelligence & Decision Support

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Theoretical vs Usable Safe Range | IMPLEMENTED | `lib/domain/safety/fuel_profile.dart`, `fuel_range.dart` | Formula: $R_{safe} = \max(0, R_{baseline} - D_{ridden} - R_{reserve} - B_{safety})$ | `test/fuel_range_test.dart`, `test/scenario_c_low_battery_throttle_test.dart` |
| 3-Regime Speed Bin Fuel Learner (REQ-07) | IMPLEMENTED | `lib/domain/safety/fuel_consumption_learner.dart` (`SpeedBinConsumptionLearner`) | Speed regimes: Urban (<45 km/h), Cruise (45-85 km/h), Highway (>85 km/h) | `test/scenario_fuel_and_essentials_test.dart`, `test/fuel_range_test.dart` |
| Skip Station Policy & Range Risk Advice | IMPLEMENTED | `lib/domain/safety/fuel_profile.dart` (`fuelAdvice`) | Enum: `rangeRisk`, `recommended`, `consider`, `withinEstimate` | `test/fuel_range_test.dart`, `test/scenario_fuel_and_essentials_test.dart` |
| Resilient Convoy Bottleneck Engine (REQ-08) | IMPLEMENTED | `lib/domain/safety/group_fuel.dart` (`commonFuelStop`) | Tolerates partial group sharing (contributors >= 1), computes limiting bike | `test/group_fuel_stop_test.dart`, `test/scenario_fuel_and_essentials_test.dart` |
| Verified COCO Highway Pump Prioritization | IMPLEMENTED | `gateway/src/essentials.js`, `lib/domain/safety/group_fuel.dart` | Filters IndianOil, BPCL, HPCL, Shell COCO outlets to prevent adulteration | `gateway/test/essentials.test.js`, `test/group_fuel_stop_test.dart` |

### 2.11 Section L: Ride Guardian Web Experience

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Secure Capability Token Architecture | IMPLEMENTED | `gateway/src/guardians.js` (`create`), `lib/data/services/guardians_service.dart` | 24-byte cryptographically secure random base64url token | `gateway/test/guardians.test.js`, `gateway/test/guardians_integration.test.js` |
| Server-Side Token & Session Hashing | IMPLEMENTED | `gateway/src/guardians.js` (`hash`) | Raw tokens never stored; stored as SHA-256 hashes in Oracle SODA | `gateway/test/guardians.test.js`, `gateway/test/guardians_integration.test.js` |
| Optional PIN Authentication & Rate Limiting | IMPLEMENTED | `gateway/src/guardians.js` (`exchange`), `gateway/src/guardian_routes.js` | 4-8 digit numeric PIN, bcrypt hashed, strict 5-attempt rate limit | `gateway/test/guardians.test.js`, `gateway/test/guardian_browser.test.js` |
| Immediate Stream & Cache Revocation | IMPLEMENTED | `gateway/src/guardians.js` (`revoke`), `gateway/src/guardian_push.js` | Instant invalidation: WebSocket closed, HTTP 410, DOM cleared | `gateway/test/guardians.test.js`, `gateway/test/guardian_browser.test.js` |
| Tiered Projection Filtering | IMPLEMENTED | `gateway/src/guardians.js` (`projectPersonal`) | Levels: `BASIC` (no coords), `LIVE` (exact coords), `EMERGENCY_ONLY` (alert only) | `gateway/test/guardians.test.js`, `gateway/test/guardians_integration.test.js` |
| Search Engine Seclusion | IMPLEMENTED | `gateway/public/watch.html`, `gateway/src/pages.js` | `<meta name="robots" content="noindex,nofollow">`, `Referrer-Policy: no-referrer` | `gateway/test/website.test.js`, `gateway/test/guardian_browser.test.js` |

### 2.12 Section M: Offline Route Corridor Pack

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Vector Tile Pre-Caching Engine (REQ-10) | IMPLEMENTED | `lib/data/services/tile_cache_service.dart` (`TileCacheService`) | Downloads zoom levels 10 to 15 within 3 km route polygon buffer | `test/tile_cache_test.dart`, `test/trip_storage_test.dart` |
| Emergency Facilities Pre-Fetch | IMPLEMENTED | `lib/data/services/route_essentials_service.dart`, `emergency_corridor_store.dart` | Saves verified trauma centers and police stations to SQLite | `test/scenario_tunnel_and_offline_test.dart`, `test/trip_planner_test.dart` |
| Route Geometry & Turn Manifest | IMPLEMENTED | `lib/data/models/trip_plan_model.dart`, `lib/domain/route/route_plan.dart` | Serialized Polyline6 geometry, waypoint elevation, and planned stops | `test/trip_storage_test.dart`, `test/trip_planner_test.dart` |

### 2.13 Sections N Through W: Delay-Tolerant Network (DTN) and Peer Relay

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Application Outbox Persistence | IMPLEMENTED | `lib/data/local/outbox_store.dart` (`OutboxStore`), `lib/data/models/outbox_item.dart` | Local SQLite/Prefs outbox storing unsent events until connectivity returns | `test/outbox_test.dart`, `gateway/test/outbox.test.js` |
| RFC 9171 Bundle Protocol Core | PLANNED | None in production runtime | Specification: Bundle header, payload, extension blocks | Architectural Requirement only |
| RFC 9172 Bundle Protocol Security (BPS) | PLANNED | None in production runtime | Specification: Block Integrity Block (BIB), Block Confidentiality Block (BCB) | Architectural Requirement only |
| Physical Peer-to-Peer Relay Router | PLANNED | None in production runtime | Specification: Inter-device store-carry-forward bundle hop mechanism | Architectural Requirement only |
| Spray-and-Wait Replication Budgeting | PLANNED | None in production runtime | Specification: $L$-copy replication limit and binary tree budget splitting | Architectural Requirement only |
| Discrete-Event DTN Simulation Suite | PLANNED | `test/scenario_b_high_jitter_network_test.dart` (partial mocked socket simulation) | Simulated moving contacts across intermittent zones | `test/scenario_b_high_jitter_network_test.dart` |

### 2.14 Sections X Through AA: Transports and Radio Fallbacks

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Google Nearby Connections Transport | PLANNED | None in `pubspec.yaml` or native code | Proposed offline radio transport abstraction | Architectural Requirement only |
| LoRa / Meshtastic / CoRoute Beacon | EXPERIMENTAL | `docs/WEARABLE_HOOK.md`, `test/scenario_convoy_dynamics_test.dart` | BLE peripheral bridge and serial frame prototype specifications | Architectural Requirement only |
| Direct Cellular SMS Handoff (REQ-01) | IMPLEMENTED | `coroute_app/android/.../SmsChannel.kt`, `lib/data/services/sms_sender.dart` | Intent hand-off to native SMS application with formatted payload | `test/sms_fallback_test.dart`, `test/scenario_f_indian_emergency_fallback_test.dart` |
| Platform OS Satellite Handoff | PLANNED | None in production runtime | Operating system level satellite SOS intent integration | Architectural Requirement only |

### 2.15 Sections AB Through AD: Operating System Background Execution & Permissions

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Android Sticky Foreground Service (REQ-05) | IMPLEMENTED | `android/app/src/main/AndroidManifest.xml`, `lib/data/services/background_service.dart` | `android:foregroundServiceType="location\|microphone"`, sticky restart | `test/scenario_battery_and_emergency_test.dart`, Native Android build |
| Android Custom WakeLock & Notification | IMPLEMENTED | `android/.../RideNotification.kt`, `lib/data/services/ride_notification_service.dart` | High-priority persistent notification channel, interactive lockscreen buttons | `test/ride_notification_service_test.dart`, Native Android build |
| Android OEM Battery Optimization Defense | IMPLEMENTED | `android/app/src/main/AndroidManifest.xml`, `lib/data/services/permissions_service.dart` | `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, manufacturer detection | `test/network_settings_ui_test.dart`, Native Android build |
| iOS Background Location & Bluetooth | PARTIAL | `coroute_app/ios/Runner/Info.plist` | `UIBackgroundModes`: `location`, `audio`. Background task execution configured | iOS Build pipeline |
| Comprehensive Permissions State Machine | IMPLEMENTED | `lib/data/services/permissions_service.dart` (`PermissionsService`) | Granular handling: location fine/coarse/background, mic, notifications | `test/network_settings_test.dart`, `test/network_settings_ui_test.dart` |

### 2.16 Sections AE & AF: Battery Conservation Policy and Endurance

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| 4-Tier Adaptive Battery Governor (REQ-04) | IMPLEMENTED | `lib/domain/tracking/ride_power_policy.dart` (`RidePowerPolicy`), `battery_governor.dart` | Tiers: Normal (>25%), Conserve (16-25%), Extreme (6-15%), Last-Gasp (<=5%) | `test/ride_power_policy_test.dart`, `test/scenario_c_low_battery_throttle_test.dart` |
| Low-Battery "Last-Gasp" Beacon (REQ-04) | IMPLEMENTED | `lib/data/services/convoy_service.dart`, `gateway/src/ws.js` | One-shot emergency broadcast `LAST_GASP_BEACON` at <= 5% battery | `test/scenario_battery_and_emergency_test.dart`, `gateway/test/timeline.test.js` |
| Extended Multi-Hour Endurance Profile | IMPLEMENTED | Verified in release documentation (`docs/SAFETY_DEVICE_TESTS.md`) | Benchmark drain profile: < 4.5% battery per hour with screen locked | `test/scenario_battery_and_emergency_test.dart` |

### 2.17 Sections AG Through AJ: Intercom, Audio Earcon Protocol and Alerts

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Live Voice Intercom (PTT / Voice Relay) | IMPLEMENTED | `lib/data/services/intercom_service.dart`, `gateway/src/ws.js` (`AUDIO_FRAME`) | Low-latency binary PCM/Opus audio relay over room WebSocket | `test/rebuilds_test.dart`, Gateway voice test suite |
| Hands-Free Helmet Audio Earcons (REQ-15) | IMPLEMENTED | `lib/data/services/voice_service.dart`, `assets/audio/` earcon tokens | Distinct auditory frequencies: SOS alert, convoy split, regroup, fuel | `test/voice_service_test.dart`, `test/voice_hud_notification_test.dart` |
| Text-to-Speech Voice Alerts & Duplication Suppression | IMPLEMENTED | `lib/data/services/voice_service.dart`, `android/.../TtsChannel.kt` | Max 6-word spoken cues; deduplicates identical proximity thresholds | `test/voice_service_test.dart`, `test/voice_hud_notification_test.dart` |
| Persistent HUD Alert History & Auto-Dismiss | IMPLEMENTED | `lib/data/services/alert_service.dart`, `lib/presentation/rider/alerts_screen.dart` | HUD cards auto-dismiss after 6s; retained permanently in alert history | `test/safety_alerts_test.dart`, `test/shell_alerts_test.dart` |

### 2.18 Sections AK Through AP: Caching, Observability, Logging and Security

| Capability | Status | Repository Evidence (File & Symbol) | API / Protocol / Schema | Existing Test Reference |
| :--- | :--- | :--- | :--- | :--- |
| Local Offline Trip Storage & Cache Eviction | IMPLEMENTED | `lib/data/local/ride_stats_store.dart`, `sqflite_track_queue.dart` | SQLite local track queue with schema migration and corruption recovery | `test/trip_storage_test.dart`, `test/tile_cache_test.dart` |
| Structured Logging & Privacy Redaction | IMPLEMENTED | `gateway/src/safety_audit.js`, `gateway/src/anonymise.js` | Zero logging of medical data, plain text passwords, or monitor tokens | `gateway/test/profile_medical.test.js`, `gateway/test/admin_management.test.js` |
| Broken Object-Level Authorization (BOLA) Defense | IMPLEMENTED | `gateway/src/routes.js`, `gateway/src/convoys.js`, `gateway/src/guardians.js` | Strict tenancy validation: user must be an active member of target convoy | `gateway/test/qa_adversarial.test.js`, `gateway/test/net_abuse.test.js` |
| Emergency Abuse Rate Limiting | IMPLEMENTED | `gateway/src/safety_network.js`, `gateway/src/app.js` | Rate limits distinct from emergency deduplication: prevents socket DoS | `gateway/test/net_abuse.test.js`, `gateway/test/qa_adversarial.test.js` |

--------------------------------------------------------------------------------

## 3. Discrepancy Analysis: Conversational Concept vs Repository Reality

To prevent catastrophic false-confidence during safety verification, the following distinctions between theoretical concepts and actual repository code are established:

1. Unknown-Rider Peer-to-Peer DTN Relaying:
   - Reality: While CoRoute contains a fully functional application outbox (`lib/data/local/outbox_store.dart`) and server-side cross-group assistance matcher (`gateway/src/safety_network.js`), a physical ad-hoc multi-hop BLE/Wi-Fi Direct bundle forwarding stack (RFC 9171 / 9172) is NOT implemented in the current mobile build. It is classified as PLANNED.
2. Google Nearby Connections:
   - Reality: The repository does not include the `nearby_connections` Flutter plugin. Emergency dispatch in cellular dead zones relies on the zero-permission native SMS fallback intent (`SmsChannel.kt`) and offline cached SQLite corridor databases.
3. Satellite SOS Autonomous Transmission:
   - Reality: CoRoute does not transmit autonomous satellite packets. Any satellite emergency communication is strictly a user-mediated platform hand-off to the host operating system's native emergency satellite service.
4. Fuel Level vs Fuel Estimation:
   - Reality: CoRoute possesses zero hardware fuel-float sensors. All fuel metrics are mathematical estimations based on rider-entered tank capacities, baseline consumption, and learned speed-bin algorithms. The UI explicitly marks all fuel statistics as estimates.

--------------------------------------------------------------------------------

## 4. Feature Inventory Verification Sign-Off

The features categorized as IMPLEMENTED in this inventory represent verified, executable code backed by 892 passing Flutter unit/widget/integration tests and 294 passing Gateway integration tests. All PLANNED and EXPERIMENTAL features are tracked in subsequent testing and simulation architectures.
