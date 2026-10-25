# FEAT-05: CoRoute Low-Connectivity SOS and Satellite Relay — Test Plan

> **Feature ID**: FEAT-05  
> **Feature Name**: CoRoute Low-Connectivity SOS and Satellite Relay  
> **Target Test Suite**: `coroute_app/test/satellite_sos_service_test.dart`  
> **Execution Environment**: Flutter Test / CI Offline Mock  

---

## 1. Test Objectives & Coverage Strategy

The test suite validates:
1. Mathematical precision and integrity of the 16-byte internal SOS binary packet codec (`SosPacketCodec`).
2. Robust error handling for invalid coordinates, corrupted packets, and sentinel values.
3. State machine integrity: accurate progression between `created`, `queued`, `attempting`, `handoffRequired`, `providerAccepted`, and `deliveredIfConfirmedByProvider`.
4. Transport resolution: online gateway preferred, falling back to emergency handoff under dead-zone conditions.
5. Indian emergency ERSS 112 message generation with human-readable coordinates, maps links, and trauma levels.
6. Feature gating enforcement (Pro Rider / Tour Operator convenience gating with unrestricted Community core emergency call access).
7. Strict confidentiality and absence of sensitive medical data logging.

---

## 2. Test Cases & Verification Matrix

| Test ID | Test Scenario | Expected Outcome | Verification Metric |
| :--- | :--- | :--- | :--- |
| **TEST-SAT-01** | **16-Byte Codec Valid Round-Trip** | Encodes valid lat/lng/alt/ts/trauma/bloodGroup into 16 bytes; decodes identically. | Decoded values equal original within precision tolerances. |
| **TEST-SAT-02** | **Invalid Latitude Out-of-Range** | Latitude $> 90.0$ or $< -90.0$ throws `ArgumentError`. | Exception caught; no packet produced. |
| **TEST-SAT-03** | **Invalid Longitude Out-of-Range** | Longitude $> 180.0$ or $< -180.0$ throws `ArgumentError`. | Exception caught; no packet produced. |
| **TEST-SAT-04** | **Negative Coordinates (S / W Hemispheres)** | Encodes and decodes negative lat/lng (e.g., $-33.8688, -151.2093$). | Correct sign preservation and precision. |
| **TEST-SAT-05** | **Unknown Altitude Sentinel** | Altitude `null` maps to sentinel `0x7FFF` ($32767\text{ m}$); decodes as `null`. | Sentinel encoded and safely recovered. |
| **TEST-SAT-06** | **Timestamp Boundary & Epoch** | Validates epoch bounds (from 2024 to 2106). | Correct 32-bit unsigned integer serialization. |
| **TEST-SAT-07** | **Corruption & Checksum Rejection** | Flips bits in payload; decoder detects checksum mismatch and throws `FormatException`. | Corrupted packet rejected without crash. |
| **TEST-SAT-08** | **SOS Event Lifecycle State Machine** | Correct transitions through `created` $\to$ `queued` $\to$ `attempting` $\to$ `providerAccepted`. | State notifier emits ordered transitions. |
| **TEST-SAT-09** | **Deduplication by Event ID** | Submitting the same event ID twice does not spawn duplicate attempts. | Deduplication map prevents duplicate dispatch. |
| **TEST-SAT-10** | **Offline Queue & Bounded Retries** | When transport fails, retries with backoff up to max attempts, then transitions to `failed`. | Bounded backoff verified; no runaway timers. |
| **TEST-SAT-11** | **Transport Selection Routing** | Selects Online Transport when connected; routes to Handoff Transport when offline. | Appropriate transport adapter invoked based on connectivity. |
| **TEST-SAT-12** | **India 112 ERSS Message Formatting** | Generates human-readable emergency text with coordinates, Google Maps link, trauma level, and blood group. | Formatted string matches ERSS 112 and SMS standards. |
| **TEST-SAT-13** | **Simulation Transport Explicit Flagging** | Mock transport returns `isSimulated = true`; never claimed as live satellite delivery. | Delivery state flagged as simulated. |
| **TEST-SAT-14** | **Privacy & Consent Enforcement** | Blood group excluded from payload unless user explicitly provided and consented. | Unconsented profile sets blood group to unknown. |
| **TEST-SAT-15** | **Feature Entitlement Gating** | Advanced satellite relay gated to Pro/Tour Operator; Community retains direct 112 calling. | `FeatureGates.isUnlocked` verified for all tiers. |

---

## 3. Regression Test Suite Execution

After executing `satellite_sos_service_test.dart`, run the complete safety regression suite:
- `flutter test test/satellite_sos_service_test.dart`
- `flutter test test/biometric_safety_bridge_test.dart`
- `flutter test test/ble_remote_service_test.dart`
- `flutter test test/siren_acoustic_detector_test.dart`
- `flutter test test/road_hazard_detector_test.dart`
- `flutter test test/emergency_guidance_test.dart`
- `dart analyze lib test/`
