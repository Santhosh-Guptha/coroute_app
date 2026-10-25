# FEAT-01 — Test & Quality Assurance Plan
## BLE Handlebar Wireless SOS & Intercom PTT Remote

> **Feature ID**: FEAT-01  
> **Target Module**: `BleRemoteService`  
> **Test File**: `coroute_app/test/ble_remote_service_test.dart`  
> **Acceptance Standard**: 100% test pass rate, zero static analysis issues, zero regressions on audio or emergency services.

---

## 1. Test Architecture & Objectives

The test harness evaluates the multi-press classifier, hardware keyboard event interception, gesture timing windows, action dispatches, and cockpit status rendering without requiring a physical BLE hardware peripheral connected to the test runner.

---

## 2. Test Cases Specification

### Group 1: Feature Entitlement & Service Lifecycle
- **`TEST-BLE-01`**: **Community Tier Entitlement**
  - Verify `FeatureGates.isUnlocked(Feature.bleHandlebarRemote)` returns `true` for `community`, `proRider`, `roadCaptain`, and `tourOperator`.
- **`TEST-BLE-02`**: **Service Lifecycle & Handler Attachment**
  - Verify that `BleRemoteService` attaches to `HardwareKeyboard` on start and cleanly detaches on `dispose()`.

### Group 2: Gesture Classification & Timing Windows
- **`TEST-BLE-03`**: **Single Press PTT Toggle**
  - Simulate a single KeyDown / KeyUp event sequence on a supported remote key (e.g., `LogicalKeyboardKey.audioVolumeDown`).
  - Verify single press callback is invoked after the multi-click window ($400\text{ ms}$) without secondary clicks.
- **`TEST-BLE-04`**: **Key Repeat Suppression**
  - Simulate OS auto-repeat events (`KeyRepeatEvent`).
  - Verify that repeat events do not trigger multiple clicks or false multi-taps.
- **`TEST-BLE-05`**: **Double Press Tactical Marker**
  - Simulate two consecutive clicks spaced $180\text{ ms}$ apart.
  - Verify double press callback is invoked and dispatches `TacticalSignal.hazardOnRoad`.
- **`TEST-BLE-06`**: **Triple Press Emergency SOS Initiation**
  - Simulate three consecutive clicks spaced $150\text{ ms}$ apart.
  - Verify triple press callback triggers emergency SOS immediately without waiting for window timeout.
- **`TEST-BLE-07`**: **Sustained Long Press ($\ge 2.5\text{s}$) SOS Initiation**
  - Simulate KeyDown held for $2.6\text{ seconds}$ before KeyUp.
  - Verify long-press timer triggers emergency SOS trigger callback.

### Group 3: Keyboard Passthrough & Boundary Conditions
- **`TEST-BLE-08`**: **Unmapped Key Passthrough**
  - Send non-remote keyboard events (e.g., `LogicalKeyboardKey.keyA`, `LogicalKeyboardKey.space`).
  - Verify handler returns `false` (allowing standard text inputs and other listeners to process the key).
- **`TEST-BLE-09`**: **Rapid Multi-Click Debounce**
  - Inject noisy contact-bounce events ($<30\text{ ms}$ interval).
  - Verify contact-bounce events are coalesced into a single click.

### Group 4: Audio Coexistence & HUD Rendering
- **`TEST-BLE-10`**: **Zero Interference with Intercom Audio Playback**
  - Process remote key clicks while `IntercomService` is actively receiving voice frames.
  - Verify audio queue and playback state are not interrupted.
- **`TEST-BLE-11`**: **Cockpit HUD Pill Rendering**
  - Render `BleRemoteHudPill` in widget tester.
  - Verify displays `[ 🔘 Remote Paired ]` when active, with accessible semantics.
- **`TEST-BLE-12`**: **Battery Level Tracking**
  - Update `batteryLevelNotifier` to 85%.
  - Verify status reflection in HUD and listeners.
