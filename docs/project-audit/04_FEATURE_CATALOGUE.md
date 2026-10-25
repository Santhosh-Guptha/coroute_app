# 04. Comprehensive Feature Catalogue

**Target**: CoRoute Application Features  
**Total Identified Features**: 28  
**Verification Method**: Static source code inspection & automated test suite validation  

---

## 1. Feature Status Legend

* `IMPLEMENTED_AND_WIRED`: Full implementation and intended integration visible in source code.
* `PARTIALLY_IMPLEMENTED`: Code exists, but specific components or platform bridges are incomplete.
* `UI_ONLY`: Interface elements exist without backing business logic or service connections.
* `BACKEND_ONLY`: Backend service or database schema exists without mobile UI integration.
* `MOCK_OR_SIMULATED`: Logic operates using timer simulations, fake data, or stubs.
* `PLANNED_ONLY`: Referenced only in documentation, comments, or roadmap files.
* `BROKEN_OR_UNREACHABLE`: Route, code path, or compilation error prevents operation.
* `UNVERIFIED`: Insufficient local evidence to confirm execution without external physical hardware.

---

## 2. Feature Master Inventory

### FEAT-01: BLE Handlebar Wireless Remote Control
* **Purpose**: Hands-on-handlebar wireless remote control for half-duplex PTT intercom, tactical hazard signals, and emergency SOS trigger without taking hands off grips.
* **Screens**: `LiveCockpitMapScreen`, `BleRemoteHudPill`.
* **Source Files**: `coroute_app/lib/data/services/ble_remote_service.dart`, `coroute_app/lib/presentation/rider/widgets/ble_remote_hud_pill.dart`.
* **Services & Models**: `BleRemoteService`, `BleRemoteCommand`, `BleConnectionState`.
* **APIs / Backend**: None (Local Bluetooth Low Energy peripheral).
* **Permissions**: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`.
* **Tiers & Roles**: Community, all tiers (`Feature.bleHandlebarRemote`).
* **Online/Offline**: Works fully offline.
* **Tests**: `coroute_app/test/ble_remote_service_test.dart`.
* **Status**: `PARTIALLY_IMPLEMENTED` (Service state machine, command dispatch, and HUD pill implemented; hardware Bluetooth scanning uses simulation timers).

### FEAT-02: Road Hazard AI Telemetry Mesh
* **Purpose**: Collective crowd-sourced detection and broadcast of potholes, speed bumps, and road debris with 300-meter predictive spatial voice warnings.
* **Screens**: `LiveCockpitMapScreen`, `RoadHazardHudPill`.
* **Source Files**: `coroute_app/lib/data/services/road_hazard_detector.dart`, `coroute_app/lib/presentation/rider/widgets/road_hazard_hud_pill.dart`, `coroute_app/gateway/src/road_hazards.js`.
* **Services & Models**: `RoadHazardDetector`, `RoadHazardModel`, `RoadHazardService`.
* **APIs / Backend**: WS event `ROAD_HAZARD`, Gateway module `road_hazards.js`.
* **Permissions**: `ACCESS_FINE_LOCATION`, `RECORD_AUDIO`.
* **Tiers & Roles**: Broadcast: Road Captain / Tour Operator; Receive: All Tiers.
* **Online/Offline**: Operates online; persists local cache in dead zones.
* **Tests**: `coroute_app/test/road_hazard_detector_test.dart`, `gateway/test/road_hazard_gateway.test.js`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-03: Acoustic Emergency Siren Frequency Detector
* **Purpose**: Analyzes microphone audio stream for European/American/Indian emergency vehicle siren tones (600 Hz - 1800 Hz yelp/wail), ducks intercom audio by -20 dB, and shows cockpit yield warning.
* **Screens**: `LiveCockpitMapScreen`, `SirenHudPill`.
* **Source Files**: `coroute_app/lib/data/services/siren_acoustic_detector.dart`, `coroute_app/lib/presentation/rider/widgets/siren_hud_pill.dart`.
* **Services & Models**: `SirenAcousticDetector`, `SirenEvent`.
* **APIs / Backend**: None (Local signal processing).
* **Permissions**: `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`.
* **Tiers & Roles**: All tiers (`Feature.sirenAcousticDetector`).
* **Online/Offline**: Fully local/offline.
* **Tests**: `coroute_app/test/siren_acoustic_detector_test.dart`, `bystander_siren_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-04: Smartwatch Biometric Trauma & Pulse Bridge
* **Purpose**: Connects Apple Watch, WearOS, or BLE heart rate monitors to audit pulse during crash events, escalating dispatch for severe deceleration accompanied by tachycardia or cessation.
* **Screens**: `LiveCockpitMapScreen`, `BiometricPulseHudPill`, `CrashAlarmScreen`.
* **Source Files**: `coroute_app/lib/data/services/biometric_safety_bridge.dart`, `coroute_app/lib/presentation/rider/widgets/biometric_pulse_hud_pill.dart`.
* **Services & Models**: `BiometricSafetyBridge`, `BiometricSample`.
* **APIs / Backend**: Telemetry packet `biometrics` field in `TELEMETRY`.
* **Permissions**: `BODY_SENSORS` (Android).
* **Tiers & Roles**: Pro Rider & Road Captain (`Feature.biometricTraumaPulse`).
* **Online/Offline**: Works offline; broadcasts over local mesh or uploads when online.
* **Tests**: `coroute_app/test/biometric_safety_bridge_test.dart`.
* **Status**: `PARTIALLY_IMPLEMENTED` (Data structures and HUD pill complete; hardware sensor uses simulated heart rate generator).

### FEAT-05: Low-Connectivity SOS & Satellite Emergency Relay
* **Purpose**: Relays 16-byte emergency SOS distress packets via native OS satellite assistant, cellular ERSS 112, or connected satellite communicators when in deep dead zones.
* **Screens**: `CrashAlarmScreen`, `SosHoldScreen`.
* **Source Files**: `coroute_app/lib/data/services/satellite_sos_service.dart`, `coroute_app/lib/domain/safety/sos_packet_codec.dart`.
* **Services & Models**: `SatelliteSosService`, `SosEvent`, `SosPacketCodec`.
* **APIs / Backend**: Android satellite intents, Gateway `POST /convoys/:id/alerts`.
* **Permissions**: `USE_FULL_SCREEN_INTENT`, `SEND_SMS`.
* **Tiers & Roles**: Pro Rider & Tour Operator (`Feature.satelliteSosRelay`).
* **Online/Offline**: Specifically engineered for offline / zero-signal conditions.
* **Tests**: `coroute_app/test/satellite_sos_service_test.dart` (15/15 tests passing).
* **Status**: `IMPLEMENTED_AND_WIRED` (Compact 16-byte codec, India 112 ERSS handoff, and queue orchestration verified; initial static analysis type mismatch in `satellite_sos_service.dart:126` resolved in current working tree).

### FEAT-06: Real-Time Convoy Tracking & Bead Wire
* **Purpose**: Visualizes group members' relative positions along the route corridor on a 1D ladder widget and 2D map with heading arrows, speed, and stale states.
* **Screens**: `LiveCockpitMapScreen`, `ConvoyBeadWireWidget`.
* **Source Files**: `convoy_service.dart`, `convoy_bead_wire_widget.dart`, `ghost_rider_marker.dart`.
* **Services & Models**: `ConvoyService`, `RiderModel`, `ConvoyModel`, `GeoMath`.
* **APIs / Backend**: WS `TELEMETRY`, `RIDER_UPDATE`.
* **Permissions**: `ACCESS_FINE_LOCATION`, `ACCESS_BACKGROUND_LOCATION`.
* **Tiers & Roles**: Community (up to 4 bikes), Road Captain / Tour (up to 40+ bikes).
* **Online/Offline**: Online telemetry; drops to ghost-markers after 30s offline.
* **Tests**: `test/convoy_bead_wire_test.dart`, `test/convoy_network_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-07: Low-Latency Half-Duplex VOX / PTT Intercom
* **Purpose**: Voice communication between riders using Opus/PCM streaming with voice activity detection (VOX) and glove-friendly PTT hold bars.
* **Screens**: `LiveCockpitMapScreen`, `MinimalHoldToTalkBar`, `IntercomDock`.
* **Source Files**: `intercom_service.dart`, `voice_service.dart`, `flutter_pcm_sound`.
* **Services & Models**: `IntercomService`, `AudioStreamer`.
* **APIs / Backend**: Binary WebSocket frames over `/ws`.
* **Permissions**: `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: Requires active gateway connection or P2P mesh.
* **Tests**: `test/intercom_lead_channel_test.dart`, `test/intercom_network_resilience_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-08: Road Captain Priority Voice Ducking
* **Purpose**: Road Captain's voice transmission cuts through casual conversation by attenuating other audio streams by -18 dB.
* **Screens**: `LiveCockpitMapScreen`.
* **Source Files**: `intercom_service.dart:340`.
* **Services & Models**: `IntercomService`.
* **APIs / Backend**: Binary WS audio header flag `isPriority`.
* **Permissions**: Audio permissions.
* **Tiers & Roles**: Road Captain & Tour Operator (`Feature.priorityIntercomDucking`).
* **Online/Offline**: Online / Local relay.
* **Tests**: `test/intercom_ducking_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-09: Automated Crash & Fall Detection
* **Purpose**: Detects high-G impacts followed by cessation of movement, triggers full-screen 15s alarm, and notifies convoy and emergency contacts.
* **Screens**: `CrashAlarmHost`, `CrashAlarmScreen`.
* **Source Files**: `crash_detector.dart`, `safety_service.dart`, `crash_alarm_host.dart`.
* **Services & Models**: `CrashDetector`, `SafetyService`.
* **APIs / Backend**: WS `SOS`, SMS intent fallback.
* **Permissions**: `ACCESS_FINE_LOCATION`, `USE_FULL_SCREEN_INTENT`, `VIBRATE`.
* **Tiers & Roles**: All tiers (Core Safety).
* **Online/Offline**: Fully functional offline via native SMS and alarm siren.
* **Tests**: `test/crash_detector_test.dart`, `test/crash_alarm_screen_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-10: Ride Guardian Live Tracking Web Share
* **Purpose**: Lets riders share a temporary, token-authenticated live tracking URL with loved ones.
* **Screens**: `GuardianSheet`.
* **Source Files**: `guardians.js`, `guardian_routes.js`, `realtime_service.dart`.
* **Services & Models**: `RealtimeService`, `GuardianGrant`.
* **APIs / Backend**: `POST /guardians/links`, `GET /public/live/:token`.
* **Permissions**: Internet access.
* **Tiers & Roles**: Pro Rider & above (`Feature.guardianLiveShare`).
* **Online/Offline**: Online only.
* **Tests**: `test/guardian_ui_test.dart`, `gateway/test/guardians.test.js`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-11: Fuel Range & Dynamic Group Fuel Harmonization
* **Purpose**: Estimates remaining fuel range from odometer and vehicle tank profile; flags the "bottleneck rider" needing fuel earliest to coordinate group stops.
* **Screens**: `FuelSheet`, `GarageScreen`.
* **Source Files**: `fuel_range.dart`, `fuel_sharing_binding.dart`, `group_fuel_consensus_test.dart`.
* **Services & Models**: `FuelRange`, `VehicleProfile`.
* **APIs / Backend**: Telemetry `fuelUsableKm` field.
* **Permissions**: Location.
* **Tiers & Roles**: All tiers (Basic), Multi-bike (Pro Rider).
* **Online/Offline**: Works offline.
* **Tests**: `test/fuel_range_test.dart`, `test/group_fuel_consensus_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-12: Offline Map Manager & 2.5km Corridor Caching
* **Purpose**: Downloads and caches vector/raster map tiles in a 2.5 km lateral corridor around planned routes for offline navigation.
* **Screens**: `OfflineMapManagerScreen`, `OfflineTileVerificationScreen`.
* **Source Files**: `tile_cache_service.dart`, `saved_map_pack_store.dart`.
* **Services & Models**: `TileCache`, `TilePrefetcher`, `SavedMapPack`.
* **APIs / Backend**: OpenStreetMap / Carto tile endpoints.
* **Permissions**: Storage, Network.
* **Tiers & Roles**: Community (1 pack), Pro/Captain/Tour (Unlimited).
* **Online/Offline**: Offline operation.
* **Tests**: `test/offline_map_manager_test.dart`, `test/tile_cache_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-13: Dynamic Route Waypoint & Regroup Push
* **Purpose**: Allows Road Captain to push new waypoints, fuel stops, or regroup points mid-ride to all connected members' cockpit maps.
* **Screens**: `LiveCockpitMapScreen`, `TripPlannerScreen`.
* **Source Files**: `convoy_service.dart:1340`, `convoys.js:520`.
* **Services & Models**: `ConvoyService`, `StopPointModel`.
* **APIs / Backend**: WS `ROUTE_SET`, `REGROUP_SET`.
* **Permissions**: Network.
* **Tiers & Roles**: Road Captain & Tour Operator (`Feature.dynamicWaypointPush`).
* **Online/Offline**: Online.
* **Tests**: `test/trip_planner_test.dart`, `gateway/test/route.test.js`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-14: Total Convoy Spread Alert (Accordion Elasticity)
* **Purpose**: Calculates distance between Lead and Sweeper; triggers audio and HUD alerts when pack stretches beyond safe convoy formation limits (> 1500m).
* **Screens**: `LiveCockpitMapScreen`, `ConvoyBeadWireWidget`.
* **Source Files**: `ride_facts.dart`, `convoy_service.dart`.
* **Services & Models**: `RideFacts`, `StatusText`.
* **APIs / Backend**: WS `TELEMETRY`.
* **Permissions**: Location.
* **Tiers & Roles**: Road Captain & Tour Operator (`Feature.totalConvoySpreadAlert`).
* **Online/Offline**: Online.
* **Tests**: `test/ride_facts_test.dart`, `test/scenario_convoy_dynamics_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-15: Cross-Group Mutual Aid Safety Network
* **Purpose**: Routes SOS alerts from distressed solo riders or small groups to other nearby motorcycle convoys on the same highway carriageway.
* **Screens**: `AssistBanner`, `AssistSheet`.
* **Source Files**: `safety_network.js`, `assist_sheet.dart`.
* **Services & Models**: `SafetyNetworkService`, `IncidentModel`.
* **APIs / Backend**: WS `ASSIST_REQUEST`, `ASSIST_ANSWER`.
* **Permissions**: Location, Network.
* **Tiers & Roles**: All tiers (Universal mutual aid).
* **Online/Offline**: Online Gateway routing.
* **Tests**: `test/assist_ui_test.dart`, `gateway/test/safety_network.test.js`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-16: Emergency Medical ID (ICE) Lock Screen Tile
* **Purpose**: Android Quick Settings tile exposing medical notes, blood type, and emergency contact phone without requiring device unlock.
* **Screens**: `IceMedicalCard`, `MedicalIdActivity`.
* **Source Files**: `MedicalTileService.kt`, `MedicalIdActivity.kt`, `ice_medical_card.dart`.
* **Services & Models**: `IceProfileStore`, `AuthService`.
* **APIs / Backend**: None (Local Android SharedPreferences).
* **Permissions**: `BIND_QUICK_SETTINGS_TILE`.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: 100% offline.
* **Tests**: `test/medical_id_sync_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-17: OEM Battery Optimization Guidance
* **Purpose**: Guides users through OEM-specific Android battery settings (Xiaomi, OnePlus, Samsung, Oppo) to prevent background process killing.
* **Screens**: `OemBatteryGuide`.
* **Source Files**: `oem_battery_guide.dart`, `safety_native.dart`.
* **Services & Models**: `SafetyNative`.
* **APIs / Backend**: Intent `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
* **Permissions**: `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: Offline.
* **Tests**: `test/scenario_battery_and_emergency_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-18: Multi-Bike Motorcycle Garage & Service Log
* **Purpose**: Store multiple motorcycle profiles with tank capacity, reserve threshold, tyre pressure specs, and service intervals.
* **Screens**: `GarageScreen`.
* **Source Files**: `garage_screen.dart`, `settings_service.dart`.
* **Services & Models**: `VehicleProfile`, `SettingsService`.
* **APIs / Backend**: Local SharedPreferences.
* **Permissions**: None.
* **Tiers & Roles**: Pro Rider & above (`Feature.multiBikeGarage`).
* **Online/Offline**: Offline.
* **Tests**: `test/garage_and_gpx_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-19: High-Contrast AMOLED Sunlight HUD Mode
* **Purpose**: Ultra-high contrast color scheme (pure #000000 background, neon teal accents, #FFFFFF text) optimized for bright tropical sunlight.
* **Screens**: All Cockpit screens.
* **Source Files**: `app_theme.dart`, `theme_controller.dart`.
* **Services & Models**: `ThemeController`, `AppPalette`.
* **APIs / Backend**: None.
* **Permissions**: None.
* **Tiers & Roles**: Pro Rider & above (`Feature.sunlightHudMode`).
* **Online/Offline**: Offline.
* **Tests**: `test/dark_check_test.dart`, `test/theme_layout_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-20: 2D Route Replay & GPX Telemetry Export
* **Purpose**: Review completed rides with an animated route scrubber, speed graphs, and export standard GPX files with speed and cadence extensions.
* **Screens**: `TripReportScreen`, `ReplayScreen`.
* **Source Files**: `replay_screen.dart`, `trip_report_screen.dart`.
* **Services & Models**: `TrackRecorder`, `TripStorageService`.
* **APIs / Backend**: `GET /convoys/:id/gpx`.
* **Permissions**: Storage / Share.
* **Tiers & Roles**: Pro Rider & above (`Feature.advancedTelemetryReplay`).
* **Online/Offline**: Offline playback for synced trips.
* **Tests**: `test/garage_and_gpx_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-21: B2B Fleet Analytics & Dispatcher Dashboard
* **Purpose**: Fleet health, tour timetable variance, and client safety risk scorecard for commercial motorcycle tour operators.
* **Screens**: `MasterAdminDashboard`, `AdminInsightsScreen`.
* **Source Files**: `admin_insights_screen.dart`, `feature_analytics.js`.
* **Services & Models**: `ApiClient`.
* **APIs / Backend**: `GET /admin/analytics`, `GET /admin/feature-analytics`.
* **Permissions**: Admin auth.
* **Tiers & Roles**: Tour Operator / Master Admin (`Feature.fleetAnalytics`).
* **Online/Offline**: Online.
* **Tests**: `test/feature_analytics_ui_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-22: Force App Update & Minimum Build Gate
* **Purpose**: Prevents deprecated or insecure client versions from connecting to the convoy gateway.
* **Screens**: `ForceUpdateScreen`, `_UpdateGate`.
* **Source Files**: `meta_service.dart`, `force_update_screen.dart`.
* **Services & Models**: `MetaService`, `AppVersionService`.
* **APIs / Backend**: `GET /api/meta`.
* **Permissions**: Internet.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: Checked on startup.
* **Tests**: `test/plan_subscription_and_version_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-23: P2P Bluetooth / Wi-Fi Direct Mesh Fallback
* **Purpose**: Allows riders within 100 meters to exchange telemetry and distress packets without cellular towers.
* **Screens**: `LiveCockpitMapScreen`.
* **Source Files**: `p2p_mesh_service.dart`, `mesh_packet_codec.dart`.
* **Services & Models**: `P2pMeshService`, `MeshPacket`.
* **APIs / Backend**: Local Wi-Fi Direct / BLE L2CAP sockets.
* **Permissions**: `NEARBY_WIFI_DEVICES`, `BLUETOOTH_CONNECT`.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: Offline peer-to-peer.
* **Tests**: `test/p2p_mesh_service_test.dart`, `test/convoy_mesh_integration_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-24: Live Group Timeline & Stop Duration Audit
* **Purpose**: Tracks every stop and departure of each member with precise durations to avoid losing riders at highway toll plazas or rest stops.
* **Screens**: `LiveTimelineScreen`.
* **Source Files**: `timeline_service.dart`, `timeline.js`.
* **Services & Models**: `TimelineService`, `TimelineEvent`.
* **APIs / Backend**: `GET /convoys/:id/timeline`, WS `TIMELINE_SINCE`.
* **Permissions**: Location.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: Online sync.
* **Tests**: `test/timeline_ui_test.dart`, `gateway/test/timeline.test.js`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-25: Spoken Voice Guidance & TTS Road Hazard Prompts
* **Purpose**: Hands-free voice prompts over Bluetooth helmet communicator announcing convoy separation, upcoming fuel stops, and road hazards.
* **Screens**: Cockpit HUD.
* **Source Files**: `voice_service.dart`, `helmet_voice_service.dart`.
* **Services & Models**: `VoiceService`, `HelmetVoiceService`.
* **APIs / Backend**: Android/iOS native TTS engine (`android.intent.action.TTS_SERVICE`).
* **Permissions**: Audio output.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: 100% offline voice synthesis.
* **Tests**: `test/voice_service_test.dart`, `test/voice_hud_notification_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-26: Outbox Queue & Offline DTN Store-and-Forward
* **Purpose**: Buffers chat messages, stop decisions, and telemetry changes during cellular dead zones and automatically uploads them upon reconnection.
* **Screens**: `MessagesView`, `CockpitDualStateBanner`.
* **Source Files**: `outbox_store.dart`, `convoy_service.dart:1740`.
* **Services & Models**: `OutboxStore`, `OutboxItem`.
* **APIs / Backend**: WS reconnect flush.
* **Permissions**: Storage.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: Offline buffering -> Online flush.
* **Tests**: `test/outbox_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-27: Master Admin Dashboard & User Governance
* **Purpose**: Comprehensive moderation, convoy termination, user blocking, password resets, and system stats.
* **Screens**: `MasterAdminDashboard`, `AdminUsersScreen`, `AdminRideHistoryScreen`.
* **Source Files**: `master_admin_dashboard.dart`, `admin_ui.dart`, `routes.js:400`.
* **Services & Models**: `ApiClient`.
* **APIs / Backend**: `/admin/*` REST endpoints.
* **Permissions**: Master Admin role.
* **Tiers & Roles**: Master Admin.
* **Online/Offline**: Online only.
* **Tests**: `test/admin_console_test.dart`, `test/admin_emergencies_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.

### FEAT-28: In-App Dynamic Plan Selector & Feature Gating
* **Purpose**: Dynamic client-side subscription switcher for testing and gating tier-specific capabilities with zero hardcoded mock data.
* **Screens**: `PlanSelectorScreen`.
* **Source Files**: `plan_selector_screen.dart`, `feature_gates.dart`, `plan_subscription_service.dart`.
* **Services & Models**: `PlanSubscriptionService`, `FeatureGates`.
* **APIs / Backend**: SharedPreferences.
* **Permissions**: None.
* **Tiers & Roles**: All tiers.
* **Online/Offline**: Offline state.
* **Tests**: `test/plan_subscription_and_version_test.dart`, `test/plan_entitlements_strict_test.dart`.
* **Status**: `IMPLEMENTED_AND_WIRED`.
