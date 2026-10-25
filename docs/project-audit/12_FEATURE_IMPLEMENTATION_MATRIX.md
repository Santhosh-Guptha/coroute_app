# 12. Feature Implementation Matrix

**Target**: CoRoute Consolidated Traceability Matrix  
**Scope**: All 28 Core, Safety, Navigation, Audio, and Administration Features  

---

## 1. Traceability Matrix

| Feature ID | Feature Name | Screens / UI Components | Source Files | Services / Models | Backend APIs | Test Files | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **FEAT-01** | BLE Handlebar Remote | `LiveCockpitMapScreen`, `BleRemoteHudPill` | `ble_remote_service.dart`, `ble_remote_hud_pill.dart` | `BleRemoteService`, `BleRemoteCommand` | Local BLE | `ble_remote_service_test.dart` | `PARTIALLY_IMPLEMENTED` |
| **FEAT-02** | Road Hazard AI Mesh | `LiveCockpitMapScreen`, `RoadHazardHudPill` | `road_hazard_detector.dart`, `road_hazards.js` | `RoadHazardDetector`, `RoadHazardModel` | WS: `ROAD_HAZARD` | `road_hazard_detector_test.dart`, `road_hazard_gateway.test.js` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-03** | Siren Acoustic Detector | `LiveCockpitMapScreen`, `SirenHudPill` | `siren_acoustic_detector.dart`, `siren_hud_pill.dart` | `SirenAcousticDetector`, `SirenEvent` | None (Local Signal) | `siren_acoustic_detector_test.dart`, `bystander_siren_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-04** | Biometric Pulse Bridge | `LiveCockpitMapScreen`, `BiometricPulseHudPill` | `biometric_safety_bridge.dart`, `biometric_pulse_hud_pill.dart` | `BiometricSafetyBridge`, `BiometricSample` | WS: `TELEMETRY` | `biometric_safety_bridge_test.dart` | `PARTIALLY_IMPLEMENTED` |
| **FEAT-05** | Satellite SOS Relay | `CrashAlarmScreen`, `SosHoldScreen` | `satellite_sos_service.dart`, `sos_packet_codec.dart` | `SatelliteSosService`, `SosEvent` | Native Satellite Intents | `satellite_sos_service_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-06** | Real-Time Convoy Tracking | `LiveCockpitMapScreen`, `ConvoyBeadWireWidget` | `convoy_service.dart`, `convoy_bead_wire_widget.dart` | `ConvoyService`, `RiderModel` | WS: `TELEMETRY`, `RIDER_UPDATE` | `convoy_bead_wire_test.dart`, `convoy_network_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-07** | Half-Duplex VOX/PTT Intercom | `LiveCockpitMapScreen`, `MinimalHoldToTalkBar` | `intercom_service.dart`, `voice_service.dart` | `IntercomService`, `AudioStreamer` | Binary WS audio frames | `intercom_lead_channel_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-08** | Road Captain Voice Ducking | `LiveCockpitMapScreen` | `intercom_service.dart:340` | `IntercomService` | Binary WS flag `isPriority` | `intercom_ducking_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-09** | Automated Crash Detection | `CrashAlarmHost`, `CrashAlarmScreen` | `crash_detector.dart`, `safety_service.dart` | `CrashDetector`, `SafetyService` | WS: `SOS`, SMS Intent | `crash_detector_test.dart`, `crash_alarm_screen_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-10** | Ride Guardian Live Share | `GuardianSheet` | `guardians.js`, `guardian_routes.js` | `RealtimeService`, `GuardianGrant` | `POST /guardians/links` | `guardian_ui_test.dart`, `guardians.test.js` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-11** | Fuel Range & Consensus | `FuelSheet`, `GarageScreen` | `fuel_range.dart`, `fuel_sharing_binding.dart` | `FuelRange`, `VehicleProfile` | WS: `TELEMETRY.fuelUsableKm` | `fuel_range_test.dart`, `group_fuel_consensus_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-12** | 2.5km Corridor Offline GIS | `OfflineMapManagerScreen`, `TileVerification` | `tile_cache_service.dart`, `saved_map_pack_store.dart` | `TileCache`, `TilePrefetcher` | OpenStreetMap Tile Servers | `offline_map_manager_test.dart`, `tile_cache_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-13** | Dynamic Waypoint Push | `LiveCockpitMapScreen`, `TripPlannerScreen` | `convoy_service.dart:1340`, `convoys.js:520` | `ConvoyService`, `StopPointModel` | WS: `ROUTE_SET`, `REGROUP_SET` | `trip_planner_test.dart`, `route.test.js` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-14** | Total Convoy Spread Alert | `LiveCockpitMapScreen`, `ConvoyBeadWireWidget` | `ride_facts.dart`, `convoy_service.dart` | `RideFacts`, `StatusText` | Client Math / WS `TELEMETRY` | `ride_facts_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-15** | Cross-Group Mutual Aid | `AssistBanner`, `AssistSheet` | `safety_network.js`, `assist_sheet.dart` | `SafetyNetworkService`, `IncidentModel` | WS: `ASSIST_REQUEST` | `assist_ui_test.dart`, `safety_network.test.js` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-16** | Medical ID Quick Tile | `IceMedicalCard`, `MedicalIdActivity` | `MedicalTileService.kt`, `ice_medical_card.dart` | `IceProfileStore`, `AuthService` | Local Android Tile Service | `medical_id_sync_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-17** | OEM Battery Guidance | `OemBatteryGuide` | `oem_battery_guide.dart`, `safety_native.dart` | `SafetyNative` | Native Settings Intent | `scenario_battery_and_emergency_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-18** | Multi-Bike Garage | `GarageScreen` | `garage_screen.dart`, `settings_service.dart` | `VehicleProfile`, `SettingsService` | Local SharedPreferences | `garage_and_gpx_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-19** | AMOLED Sunlight HUD Mode | All Cockpit Screens | `app_theme.dart`, `theme_controller.dart` | `ThemeController`, `AppPalette` | Local Theme System | `dark_check_test.dart`, `theme_layout_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-20** | 2D Replay & GPX Export | `TripReportScreen`, `ReplayScreen` | `replay_screen.dart`, `trip_report_screen.dart` | `TrackRecorder`, `TripStorageService` | `GET /convoys/:id/gpx` | `garage_and_gpx_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-21** | B2B Fleet Analytics | `MasterAdminDashboard`, `AdminInsights` | `admin_insights_screen.dart`, `feature_analytics.js` | `ApiClient` | `GET /admin/analytics` | `feature_analytics_ui_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-22** | Force App Update Gate | `ForceUpdateScreen`, `_UpdateGate` | `meta_service.dart`, `force_update_screen.dart` | `MetaService`, `AppVersionService` | `GET /api/meta` | `plan_subscription_and_version_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-23** | P2P Bluetooth / Wi-Fi Mesh | `LiveCockpitMapScreen` | `p2p_mesh_service.dart`, `mesh_packet_codec.dart` | `P2pMeshService`, `MeshPacket` | Local Wi-Fi Direct / BLE | `p2p_mesh_service_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-24** | Live Group Timeline | `LiveTimelineScreen` | `timeline_service.dart`, `timeline.js` | `TimelineService`, `TimelineEvent` | `GET /convoys/:id/timeline` | `timeline_ui_test.dart`, `timeline.test.js` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-25** | TTS Spoken Voice Guidance | Cockpit HUD | `voice_service.dart`, `helmet_voice_service.dart` | `VoiceService`, `HelmetVoiceService` | Native Android/iOS TTS | `voice_service_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-26** | Offline DTN Outbox | `MessagesView`, `CockpitBanner` | `outbox_store.dart`, `convoy_service.dart` | `OutboxStore`, `OutboxItem` | WS Reconnect Flush | `outbox_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-27** | Master Admin Governance | `MasterAdminDashboard`, `AdminUsers` | `master_admin_dashboard.dart`, `routes.js:400` | `ApiClient` | `/admin/*` Endpoints | `admin_console_test.dart` | `IMPLEMENTED_AND_WIRED` |
| **FEAT-28** | In-App Plan Selector | `PlanSelectorScreen` | `plan_selector_screen.dart`, `feature_gates.dart` | `PlanSubscriptionService`, `FeatureGates` | Local SharedPreferences | `plan_entitlements_strict_test.dart` | `IMPLEMENTED_AND_WIRED` |
