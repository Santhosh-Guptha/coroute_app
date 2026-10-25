# FEAT-04: Smartwatch Biometric Trauma & Pulse Verification — Test Plan

> **Feature ID**: FEAT-04  
> **Feature Name**: Smartwatch Biometric Trauma & Pulse Verification  
> **Tier Entitlement**: Pro Rider / Road Captain  
> **Test File**: `coroute_app/test/biometric_safety_bridge_test.dart`  

---

## 1. Test Objectives & Strategy

The objective of this test plan is to rigorously verify the end-to-end functionality of `BiometricSafetyBridge`:
1. Accurate tier gating via `FeatureGates.isUnlocked(Feature.biometricTraumaPulse)`.
2. Safe lifecycle management during rides, respecting low power consumption and disposal.
3. Accurate 5-minute heart rate buffer management and baseline estimation.
4. Robust classification of cardiac trauma levels (`criticalTraumaLevel1`, `elevatedTrauma`, `stableTrauma`, `unverified`).
5. Seamless incorporation of medical details (blood group from `MedicalInfo`) and biometric graphs into paramedic SOS payloads.
6. Graceful fallbacks when a watch is disconnected or unlinked.
7. HUD and Crash Alarm UI presentation without RenderFlex overflow.

---

## 2. Test Cases & Verification Matrix

| Test ID | Test Scenario | Expected Outcome | Verification Metric |
| :--- | :--- | :--- | :--- |
| **TEST-BIO-01** | **Tier Entitlement Gating** | Unlocked on Pro, Captain, Tour Operator; locked on Community. | `FeatureGates.isUnlocked` returns expected booleans. |
| **TEST-BIO-02** | **Bridge Lifecycle Management** | Starts streaming pulse on ride start; halts immediately on ride stop or disposal. | Active status notifier transitions correctly; no orphaned timers. |
| **TEST-BIO-03** | **Rolling 5-Min History Buffer** | Samples older than 300 seconds are pruned; capacity bounded. | Buffer size remains $\le 60$ entries; timestamps monotonically increase. |
| **TEST-BIO-04** | **Dynamic Baseline Pulse** | Calculates pre-crash average BPM over available history window. | Baseline correctly reflects pre-impact resting/active average. |
| **TEST-BIO-05** | **Critical Trauma L1 — Asystole** | Post-impact BPM drops to 0 or flatlines while watch is on wrist. | Classifies as `BiometricTraumaLevel.criticalTraumaLevel1`. |
| **TEST-BIO-06** | **Critical Trauma L1 — Tachycardia** | Post-impact BPM spikes $\ge 160$ or baseline $+ 60\text{ BPM}$. | Classifies as `BiometricTraumaLevel.criticalTraumaLevel1`. |
| **TEST-BIO-07** | **Elevated Trauma — Stress** | Post-impact BPM in range $[120, 159]$. | Classifies as `BiometricTraumaLevel.elevatedTrauma`. |
| **TEST-BIO-08** | **Stable Trauma — Normal Sinus** | Post-impact BPM in normal range $[60, 100]$. | Classifies as `BiometricTraumaLevel.stableTrauma`. |
| **TEST-BIO-09** | **Sensor Disconnected Fallback** | Watch unlinked or disconnected during crash. | Classifies as `unverified`; SOS dispatch is unblocked. |
| **TEST-BIO-10** | **Paramedic Payload Packaging** | Structured JSON with blood group, baseline, history, and trauma level. | `toBiometricPayload()` contains valid schema for gateway `details.biometrics`. |
| **TEST-BIO-11** | **Cockpit HUD Pill Widget** | High-contrast heart rate pill on map cockpit (`BiometricPulseHudPill`). | Widget renders BPM, pulsing indicator, and handles null/unpaired states. |
| **TEST-BIO-12** | **Crash Alarm View Integration** | Countdown screen displays live pulse and trauma badge during 15s alarm. | Alarm screen displays heart rate and trauma severity alert cleanly. |

---

## 3. Regression Testing Plan

Following the execution of `biometric_safety_bridge_test.dart`, run the complete safety regression suite to guarantee zero side-effects on existing safety systems:
- `flutter test test/ble_remote_service_test.dart`
- `flutter test test/siren_acoustic_detector_test.dart`
- `flutter test test/road_hazard_detector_test.dart`
- `flutter test test/road_hazard_mesh_timing_test.dart`
- `flutter test test/emergency_guidance_test.dart`
- `flutter test test/garage_and_gpx_test.dart`
- `flutter test test/safety_card_test.dart`
- `dart analyze lib test/biometric_safety_bridge_test.dart`
