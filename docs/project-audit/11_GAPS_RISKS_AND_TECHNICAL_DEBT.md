# 11. Gaps, Risks & Technical Debt

**Target**: CoRoute Risk & Remediation Register  
**Audit Date**: October 23, 2026  
**Classification Severities**: `CRITICAL`, `HIGH`, `MEDIUM`, `LOW`  

---

## 1. Severity Matrix Overview

| Finding ID | Severity | Category | Affected Subsystem | Summary |
| :--- | :---: | :---: | :--- | :--- |
| **GAP-01** | `CRITICAL` | Build / Compilation | FEAT-05 (Satellite SOS) | Type mismatch in `satellite_sos_service.dart:126` fails static analysis. |
| **GAP-02** | `HIGH` | Native / Hardware | FEAT-01 (BLE Remote) | BLE remote scanning and pairing logic is simulated via timers. |
| **GAP-03** | `HIGH` | Native / Hardware | FEAT-04 (Biometric Pulse) | Smartwatch trauma sensor relies on random number generator stub. |
| **GAP-04** | `HIGH` | Build / iOS | iOS Packaging | Missing committed `Podfile` in `coroute_app/ios/`. |
| **GAP-05** | `MEDIUM` | Architecture / State | Core Convoy | `ConvoyService` exceeds 2,400 lines with high cyclomatic complexity. |
| **GAP-06** | `MEDIUM` | Monetization | Plan Entitlements | In-app purchases rely on local state switcher; no store billing SDK integrated. |
| **GAP-07** | `MEDIUM` | Security / Testing | Feature Gates | `forceAllUnlocked` debug override can bypass tier restrictions if left true. |
| **GAP-08** | `LOW` | Code Quality | General | Unused import in `sos_transport_adapter.dart` and legacy TODO markers. |

---

## 2. Detailed Findings & Remediation Plans

### GAP-01: Static Analysis Compile Error in `satellite_sos_service.dart` [RESOLVED]
* **Source Evidence**: `coroute_app/lib/data/services/satellite_sos_service.dart:125-126`
  ```dart
  final hasSatelliteAccess = isSimulated ||
      FeatureGates.isUnlocked(Feature.satelliteSosRelay, tier);
  ```
* **Resolution Status**: Resolved in current working tree. `dart analyze lib/` exits with code 0 (`No issues found!`).
* **Root Cause & Diagnosis**: Method signature in `feature_gates.dart:88` is `static bool isUnlocked(Feature feature, [SubscriptionTier? tier])`. During earlier feature development, the arguments were inverted (`isUnlocked(tier, Feature.satelliteSosRelay)`), passing `SubscriptionTier` for `Feature` and `Feature` for `SubscriptionTier?`. Correcting the argument order resolved the analyzer error.
* **Reproduction**: Run `dart analyze lib/` from `coroute_app/` (currently passes with 0 errors).

---

### GAP-02: Simulated Hardware in BLE Handlebar Remote [HIGH]
* **Source Evidence**: `coroute_app/lib/data/services/ble_remote_service.dart:18`
* **Impact**: While the internal state machine and HUD pill UI respond to simulated buttons, physical Bluetooth handlebar buttons (e.g., Carpe Iter, WonderWheel) cannot establish hardware RF connections.
* **Root Cause**: `BleRemoteService` uses a software timer to emit commands rather than integrating `flutter_reactive_ble` or a native Kotlin BluetoothGatt callback.
* **Recommended Next Step**: Integrate `flutter_reactive_ble` to scan for Nordic Semiconductor HID profiles (Service UUID `0x1812`).

---

### GAP-03: Simulated Heart Rate in Biometric Safety Bridge [HIGH]
* **Source Evidence**: `coroute_app/lib/data/services/biometric_safety_bridge.dart:55`
* **Impact**: Crash escalation logic cannot read actual physiological vitals on physical Apple Watch or WearOS hardware.
* **Root Cause**: Uses an internal synthetic random pulse generator (`72 + Random().nextInt(15)`) for unit testing.
* **Recommended Next Step**: Create an Android Health Services / Wearable DataLayer channel to sync real PPG pulse data.

---

### GAP-04: Missing iOS CocoaPods Podfile [HIGH]
* **Source Evidence**: `coroute_app/ios/` contains `Runner.xcodeproj`, `Info.plist`, but no `Podfile`.
* **Impact**: Building the iOS application on a macOS machine without first running `flutter build ios` or `pod init` will fail dependency resolution.
* **Recommended Next Step**: Commit standard Flutter-generated `Podfile` specifying `platform :ios, '15.0'`.

---

### GAP-05: High Coupling & Monolithic Service Architecture [MEDIUM]
* **Source Evidence**: `coroute_app/lib/data/services/convoy_service.dart` (2,399 lines).
* **Impact**: Increases cognitive overhead during code reviews and risk of unintended regressions across telemetry, outbox, and audio subsystems.
* **Recommended Next Step**: Decompose `ConvoyService` into distinct focused delegates:
  * `ConvoyTelemetryDelegate`: GPS fix ingestion and broadcast.
  * `ConvoyOutboxDelegate`: DTN queueing and replay.
  * `ConvoyRosterDelegate`: Participant presence and heartbeat timers.

---

### GAP-06: Simulated In-App Purchases (IAP) [MEDIUM]
* **Source Evidence**: `coroute_app/lib/data/services/plan_subscription_service.dart`
* **Impact**: Users can switch plans freely in the app UI, which is ideal for testing but lacks Google Play Billing / Apple StoreKit integration for production monetization.
* **Recommended Next Step**: Integrate `in_app_purchase: ^3.2.0` when ready for commercial release.

---

### GAP-07: Testing Override Exposure Risk [MEDIUM]
* **Source Evidence**: `coroute_app/lib/core/config/feature_gates.dart:82`
  ```dart
  static bool forceAllUnlocked = false;
  ```
* **Impact**: If toggled to `true` during testing and mistakenly committed, commercial feature tiers will be unlocked for all users without verification.
* **Recommended Next Step**: Wrap `forceAllUnlocked` in `kDebugMode` assertion so release builds ignore the flag:
  ```dart
  static bool get forceAllUnlocked => kDebugMode && _forceAllUnlockedDebug;
  ```
