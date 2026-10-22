# FEAT-02 — Remediation & Hardening Plan
## CoRoute Collective Pothole & Road Hazard AI Telemetry Mesh

> **Status**: APPROVED & IN EXECUTION  
> **Target Release**: v3.47.0+  
> **Master Branch Verification**: Strict Zero-Regression Mandate  

---

### 1. Executive Summary & Defect Findings

Following the deep production readiness audit of **FEAT-02**, six critical areas require remediation and hardening to ensure full compliance with the product requirements, safety invariants, and field reliability.

| ID | Module | Finding / Gap | Severity | Remediation Strategy |
| :--- | :--- | :--- | :---: | :--- |
| **REM-01** | `road_hazard_detector.dart` | Wheelbase cooldown was set to 2000ms. At 80 km/h (22.2 m/s), this spans 44.4m, suppressing distinct genuine potholes 20m-35m apart. | **HIGH** | Reduce cooldown to 750ms (sufficient for 1.4-1.6m motorcycle wheelbase down to 8 km/h) and associate with displacement tracking. |
| **REM-02** | `road_hazard_detector.dart` | Fixed 4x baseline variance multiplier on gravel roads could reject genuine potholes when washboard noise $\sigma_g > 0.6\text{ g}$. | **MEDIUM** | Implement dual-stage gravel impulse filter: dynamic shock $> 3\sigma_g$ and peak $> 1.8\text{ g}$ coincident with asymmetric yaw twitch ($> 25^\circ/\text{s}$). |
| **REM-03** | `road_hazards.js` | Gateway incremented `corroborationCount` unconditionally on every observation within 100m, allowing a single rider to artificially boost corroboration. | **HIGH** | Track `contributingRiderIds` (Set) and `seenEventIds` (Set). Idempotently ignore retries and prevent single-rider corroboration inflation. |
| **REM-04** | `road_hazard_aggregator.dart` & `road_hazards.js` | Missing boundary tests for 20m, 35m, 99m, 101m, parallel roads, and GPS accuracy uncertainty near 100m cutoff. | **MEDIUM** | Implement explicit unit tests covering all spatial boundary edge cases and accuracy degradation. |
| **REM-05** | `road_hazard_mesh_timing_test.dart` | Formal timestamp sequence ($t_0 \dots t_5$) needed explicit instrumentation across 80 km/h and 100 km/h stress scenarios. | **MEDIUM** | Implement deterministic simulated timeline test measuring $t_5 - t_4 \ge 5.0\text{ s}$ across 80 km/h and 100 km/h with 1Hz GPS jitter. |
| **REM-06** | Audio / Spatial Headset | Bluetooth SCO helmet intercoms do not support 3D HRTF binaural panning. Mono/dual-mono speech delivered with visual HUD direction. | **DOCUMENTATION / LIMITATION** | Formally document hardware limitation, provide safe dual-mono audio fallback with spatial HUD markers, and record status as PASS WITH LIMITATIONS. |

---

### 2. Remediation Tasks & Action Items

#### Phase 2: Kinematic Detector Hardening (`road_hazard_detector.dart`)
- [x] Shorten cooldown to 750ms to allow detection of separate hazards 20m-35m apart.
- [x] Implement robust Earth-vertical gravity estimation with sanity checks ($8.0 \le |\vec{g}| \le 12.0\text{ m/s}^2$).
- [x] Prevent uncalibrated sensor states or missing gyroscopes from generating active hazard alerts.
- [x] Harden gravel baseline filtering to detect genuine potholes on rough surfaces.
- [x] Add synthetic trace unit tests covering:
  1. Severe pothole with coincident shock and yaw.
  2. Railway crossing (shock without yaw).
  3. Bridge expansion joint.
  4. Intentional lane change (yaw without shock).
  5. Ordinary and hard braking deceleration.
  6. Continuous washboard gravel vibration.
  7. Genuine pothole on gravel road.
  8. Stationary phone tap / mount adjustment.
  9. Phone mounted in portrait, landscape, and 45-degree tilt.
  10. Missing gyro / missing accelerometer / stale timestamps.
  11. Front and rear wheel double-hit collapse.
  12. Two separate hazards inside previous cooldown window (e.g. 35m apart).

#### Phase 3: Spatial Aggregation Hardening (`road_hazard_aggregator.dart` & `road_hazards.js`)
- [x] Implement `contributingRiderIds` and `seenEventIds` tracking on both client and server.
- [x] Test boundary conditions: 20m, 35m, 99m (merge), 101m (split), 250m.
- [x] Test opposite carriageways ($180^\circ$ heading difference) and parallel roads.
- [x] Test low GPS accuracy ($> 25\text{ m}$) rejection.
- [x] Test retried message idempotency.

#### Phase 4: WebSocket Security & Entitlements (`ws.js`)
- [x] Validate authoritative role from room/session on server.
- [x] Return structured WebSocket `{ type: 'ERROR', code: 403, reason: 'ENTITLEMENT_REQUIRED' }` for unauthorized publishers.
- [x] Validate coordinates, finite numbers, timestamp freshness, and room membership.
- [x] Filter recipients by upstream route corridor, excluding passed riders and opposing carriageway.
- [x] Rate limit repeated frames.

#### Phase 5: Defensible 5-Second Timing Model
- [x] Define $t_0$ (detection), $t_1$ (gateway receipt), $t_2$ (client trigger), $t_3$ (audio start), $t_4$ (audio finish), $t_5$ (hazard arrival).
- [x] Assert $t_5 - t_4 \ge 5.0\text{ s}$ under 80 km/h and 100 km/h conditions with 1Hz GPS jitter.

#### Phase 6: Audio Integrity & Limitations
- [x] Verify exact phrase: `"Caution: severe road hazard 300 meters ahead"`.
- [x] Ensure non-repeating alert per hazard event ID.
- [x] Prioritize emergency alerts over road hazard warnings.
- [x] Document Bluetooth SCO/A2DP helmet audio constraints.

---

### 3. Validation Commands

```bash
flutter test test/road_hazard_detector_test.dart
flutter test test/road_hazard_mesh_timing_test.dart
flutter test test/emergency_guidance_test.dart
flutter test test/garage_and_gpx_test.dart
dart analyze lib
node --test coroute_app/gateway/test/road_hazard_gateway.test.js
npm test --prefix coroute_app/gateway
```
