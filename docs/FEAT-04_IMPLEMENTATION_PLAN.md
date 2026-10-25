# FEAT-04: Smartwatch Biometric Trauma & Pulse Verification — Implementation Plan

> **Feature ID**: FEAT-04  
> **Feature Name**: Smartwatch Biometric Trauma & Pulse Verification  
> **Target Release Line**: v3.47.0+  

---

## 1. Module & Task Breakdown

### Phase 1: Entitlement & Feature Gating
- File: `lib/core/config/feature_gates.dart`
- Task:
  - Add `Feature.biometricTraumaPulse` to `Feature` enum.
  - Set entitlement rule: unlocked for `SubscriptionTier.proRider`, `roadCaptain`, and `tourOperator`; locked for `community`.
  - Add title and description mapping.

### Phase 2: Biometric Data Models & Bridge Service
- File: `lib/data/services/biometric_safety_bridge.dart`
- Components:
  - Enums & Models:
    - `enum BiometricTraumaLevel`: `stableTrauma`, `elevatedTrauma`, `criticalTraumaLevel1`, `unverified`.
    - `enum BiometricSensorSource`: `appleHealthKit`, `googleHealthConnect`, `bleHeartRateGatt`, `mock`.
    - `class BiometricSample`: `int timestampMs`, `int bpm`.
    - `class BiometricSnapshot`: `int currentBpm`, `int baselineBpm`, `BiometricTraumaLevel traumaLevel`, `BiometricSensorSource source`, `bool isWatchOnWrist`, `bool isConnected`, `List<BiometricSample> history`.
  - Service: `BiometricSafetyBridge`:
    - Manages rolling 5-minute heart rate buffer (60 samples maximum, pruned $>300\text{s}$).
    - Calculates dynamic baseline heart rate ($BPM_{\text{baseline}}$).
    - Classifies trauma severity on crash impact:
      - Asystole / pulselessness ($BPM == 0$) $\to$ `criticalTraumaLevel1`.
      - Extreme tachycardia ($BPM \ge 160$ or $BPM \ge \text{Baseline} + 60$) $\to$ `criticalTraumaLevel1`.
      - High stress tachycardia ($BPM \in [120, 159]$) $\to$ `elevatedTrauma`.
      - Normal sinus rhythm ($BPM \in [50, 119]$) $\to$ `stableTrauma`.
      - Sensor disconnected / watch unlinked $\to$ `unverified`.
    - Packages payload for paramedic dispatch attaching `MedicalInfo.bloodGroup`.

### Phase 3: Wire into Core Safety & Dispatch
- Files:
  - `lib/data/models/pending_sos.dart`: Update `toMessage()` and `toJson()` to serialize `biometrics` and `traumaLevel`.
  - `lib/data/services/safety_service.dart`:
    - Accept `BiometricSafetyBridge` dependency.
    - Feed crash event to bridge on impact to evaluate cardiac state.
    - Attach biometric payload to `_sendCrash()` and `_needHelpAfterCrash()`.
  - `lib/data/services/convoy_service.dart`:
    - Pass biometric payload into `_raise()` and `PendingSos`.

### Phase 4: HUD & Alarm UI Integration
- Files:
  - `lib/presentation/rider/widgets/biometric_pulse_hud_pill.dart`:
    - Glove-friendly, high-contrast cockpit pill showing live BPM and pulsing heart icon.
  - `lib/presentation/safety/crash_alarm_screen.dart`:
    - Display real-time heart rate and trauma status badge in `CrashAlarmView`.
  - `lib/presentation/rider/live_cockpit_map_screen.dart`:
    - Integrate `BiometricPulseHudPill` into `_slots` in cockpit overlay.

### Phase 5: Verification & Regression Testing
- Create `test/biometric_safety_bridge_test.dart` (12 test cases).
- Run full safety regression test suite (58+ tests).
- Execute `dart analyze` across `lib/` and `test/`.
