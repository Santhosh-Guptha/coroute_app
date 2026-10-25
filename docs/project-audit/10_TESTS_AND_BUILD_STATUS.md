# 10. Tests, Quality & Build Status

**Target**: CoRoute Test Suite & Static Analysis Audit  
**Test Frameworks**: `flutter_test` (Mobile Client), Node.js native test runner (`node --test`) (Gateway)  
**Total Test Files**: 125+ Flutter test files, 45+ Gateway test files  

---

## 1. Local Command Execution Results

### 1. Flutter & Dart Version Checks
* **Command**: `flutter --version`
* **Exit Code**: `0`
* **Output**:
  ```text
  Flutter 3.47.1 • channel stable • https://github.com/flutter/flutter.git
  Framework • revision 6655482ec0 (9 weeks ago) • 2026-08-19 10:07:23 -0700
  Engine • hash 11d79658c444477b06513d32b52c8c4ccb7276b0 (revision 5d53178869)
  Tools • Dart 3.13.1 • DevTools 2.60.0
  ```

* **Command**: `dart --version`
* **Exit Code**: `0`
* **Output**:
  ```text
  Dart SDK version: 3.13.1 (stable) (Tue Aug 18 01:00:59 2026 -0700) on "windows_x64"
  ```

---

### 2. Static Code Analysis (`dart analyze`)
* **Command**: `cd coroute_app; dart analyze lib/`
* **Exit Code**: `0` (Clean - Verified in Current Working Tree)
* **Output**:
  ```text
  Analyzing lib...
  No issues found!
  ```
* **Historical Audit Note & Resolution**:
  * During initial audit of the in-progress FEAT-05 branch, `satellite_sos_service.dart:126` contained swapped arguments to `FeatureGates.isUnlocked(Feature feature, [SubscriptionTier? tier])`, triggering two type mismatch errors (`SubscriptionTier` passed for `Feature`).
  * In the current working tree, this has been corrected to `FeatureGates.isUnlocked(Feature.satelliteSosRelay, tier);`, and unused imports/style hints were resolved, yielding exit code 0.

---

### 3. Backend Gateway Test Suite
* **Command**: `npm --prefix coroute_app/gateway test`
* **Exit Code**: `0` (100% Green)
* **Output**:
  ```text
  > coroute-gateway@3.47.0 test
  > node --test test/*.test.js

  ℹ tests 323
  ℹ suites 0
  ℹ pass 323
  ℹ fail 0
  ℹ duration_ms 89567.2219
  ```
* **Analysis**:
  * 323 out of 323 tests passing across 61 test files (reflecting 8 new FEAT-02 road hazard gateway tests added since the 315-test baseline).

---

### 4. Sample Flutter Regression Test
* **Command**: `cd coroute_app; flutter test test/behaviour_regressions_test.dart`
* **Exit Code**: `0`
* **Output**:
  ```text
  00:00 +0: Android back on another tab returns to the Ride tab instead of leaving the app
  00:17 +1: Without a ride, back on the Ride tab may leave the app (PopScope allows the pop)
  00:18 +2: All tests passed!
  ```

---

## 2. Test Architecture & Coverage Mapping

### 1. Mobile Test Suites (`coroute_app/test/`)
* **Core & Network Tests**: `convoy_network_test.dart`, `outbox_test.dart`, `link_presence_test.dart`, `low_data_test.dart`.
* **Safety & Emergency Tests**: `crash_detector_test.dart`, `emergency_roster_test.dart`, `sos_queue_test.dart`, `hard_brake_test.dart`, `siren_acoustic_detector_test.dart`, `road_hazard_detector_test.dart`.
* **Ergonomics & Cockpit Tests**: `glove_cockpit_shortcuts_test.dart`, `minimal_cockpit_widgets_test.dart`, `cockpit_action_stack_test.dart`, `convoy_bead_wire_test.dart`.
* **Offline GIS Tests**: `offline_map_manager_test.dart`, `tile_cache_test.dart`, `scenario_tunnel_and_offline_test.dart`.
* **Monetization & Plans Tests**: `plan_entitlements_strict_test.dart`, `plan_subscription_and_version_test.dart`.
* **E2E Integration Suites**:
  * `test/e2e/application_level_test.dart`
  * `test/e2e/functionality_level_test.dart`
  * `test/e2e/ui_level_test.dart`

### 2. Mocking & Simulation Strategies
* **Network & Sockets**: `MockRt` (`RealtimeService` stub), `MockClient` (`http.Client` stub returning JSON snapshots).
* **Storage**: `SharedPreferences.setMockInitialValues()`.
* **Sensors**: Synthetic accelerometer waveforms injecting 3.2G spikes for crash testing; synthetic PCM sinusoidal tone generators injecting 1200 Hz yelp tones for siren testing.

---

## 3. Coverage Gaps & Hardware Constraints

1. **Bluetooth Low Energy Hardware Testing**:
   * `BleRemoteService` and `BiometricSafetyBridge` are verified via software mock timers; physical BLE peripheral advertisement, pairing, and RSSI degradation under motorcycle handlebar vibration require physical test benches.
2. **Satellite Radio Hardware Testing**:
   * `SatelliteSosService` relies on OS platform intents; physical satellite communicator uplink (Iridium SBD / Inmarsat) cannot be validated in CI.
3. **iOS Platform Channels**:
   * No macOS runner in current CI; iOS testing is performed via static Dart evaluation and unit tests without physical iOS device execution.
