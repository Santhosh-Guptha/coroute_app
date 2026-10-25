# FEAT-01 — Implementation Plan
## BLE Handlebar Wireless SOS & Intercom PTT Remote

> **Feature ID**: FEAT-01  
> **Target Release**: v3.48.0+  
> **Status**: Ready for Implementation  

---

## 1. Implementation Steps & Task Breakdown

### Task 1: Feature Gate Configuration
- **File**: `coroute_app/lib/core/config/feature_gates.dart`
- **Actions**:
  - Add `Feature.bleHandlebarRemote` to `Feature` enum.
  - Return `true` in `FeatureGates.isUnlocked(...)` for all tiers (`community`, `proRider`, `roadCaptain`, `tourOperator`).
  - Add name and description metadata in `FeatureGates.featureName` and `FeatureGates.featureDescription`.

### Task 2: Implement `BleRemoteService`
- **File**: `coroute_app/lib/data/services/ble_remote_service.dart`
- **Actions**:
  - Define `BleRemoteGesture`: `singlePress`, `doublePress`, `triplePress`, `longPress`.
  - Define `BleRemoteStatus`: `disconnected`, `paired`, `listening`.
  - Implement `BleRemoteService` with `HardwareKeyboard.instance.addHandler`.
  - Implement timing engine:
    - Multi-click window: $400\text{ ms}$.
    - Contact debounce: $35\text{ ms}$.
    - Long-press hold threshold: $2.5\text{ seconds}$.
  - Integrate with:
    - `IntercomService` for PTT start/end.
    - `IntercomNetworkResilience` for `TacticalSignal.hazardOnRoad`.
    - `SafetyService` & `ConvoyService` for Emergency SOS trigger.
  - Implement haptic feedback (`HapticFeedback.lightImpact`, `mediumImpact`, `heavyImpact`).
  - Provide `ValueNotifier<BleRemoteStatus>` and `ValueNotifier<int?> batteryLevelNotifier`.

### Task 3: Implement Cockpit HUD Status Widget
- **File**: `coroute_app/lib/presentation/rider/widgets/ble_remote_hud_pill.dart`
- **Actions**:
  - Compact, glove-friendly pill displaying remote pairing status and battery level.
  - Tapping opens remote diagnostics or trigger test.

### Task 4: Integrate with `LiveCockpitMapScreen`
- **File**: `coroute_app/lib/presentation/rider/live_cockpit_map_screen.dart`
- **Actions**:
  - Attach `BleRemoteService` in initState / didChangeDependencies.
  - Add `BleRemoteHudPill` to cockpit HUD slot list.
  - Ensure clean disposal on screen exit.

### Task 5: Comprehensive Unit & Widget Test Suite
- **File**: `coroute_app/test/ble_remote_service_test.dart`
- **Actions**:
  - Implement all 12 test cases outlined in `FEAT-01_TEST_PLAN.md`.
  - Verify 100% test passing and zero analyzer errors.
