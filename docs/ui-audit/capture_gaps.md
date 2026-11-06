# CoRoute – UI Capture Gaps & Simulated State Matrix

This report details extreme operational environments, sensory edge cases, and hardware fault states that were not captured directly in standard static screens due to environmental or hardware prerequisites.

---

## 1. Operational Edge Cases & Visual Stress States

| Gap ID | Scenario / Edge Case | Expected UI State | Simulation Method |
|---|---|---|---|
| **GAP-01** | **100+ Rider Mega-Convoy Visual Density** | Dense cluster clustering on map, scrollable ladder with 100 entries, bead wire compressed mode | Inject 100 simulated rider telemetry packets via `RealtimeService` mock stream |
| **GAP-02** | **Tunnel Blackout (Complete GPS Multi-Path Loss)** | Amber warning pill "Tunnel Mode: Dead Reckoning Active", compass gyro direction tracking | Emulate GPS fix timeout via Android LocationManager mock test provider |
| **GAP-03** | **High-G Impact Event (6.5G Highside Crash)** | Immediate full-screen crimson strobe `CrashAlarmScreen`, 15-second local countdown with haptic pulse | Inject high-g accelerometer vectors into `SensorManager` via adb sensor emulation |
| **GAP-04** | **Extreme Device Thermal Throttling (> 48°C)** | Brightness dimming warning pill, background GPS rate throttle notice | Set battery thermal status to `THERMAL_STATUS_SEVERE` via adb shell |
| **GAP-05** | **Critical Low Battery (< 5%) in Active Convoy** | Yellow battery warning banner, automatic power-saving throttle of screen awake mode | Send battery level broadcast `adb shell dumpsys battery set level 4` |
| **GAP-06** | **Dual SIM Rural Ghat Cellular Failover** | Socket retry pill "Switching SIM data link...", queued outbox counter increment | Disconnect active network interface and verify fallback socket reconnection |

---

## 2. Gap Descriptions & Recommendations

### GAP-01: 100-Rider Mega-Convoy Visualization
- **Impact on UI:**
  Under the Pro/Fleet subscription tiers, a convoy can scale up to 100 motorcycles. In the expanded bottom sheet, the `RidersLadder` uses a `ListView.builder` which gracefully virtualizes rows. On the map layer, however, 100 unclustered markers can degrade frame rates. CoRoute implements marker clustering when zoomed out beyond level 13.
- **Verification Plan:**
  Run `test/convoy_performance_benchmark_test.dart` with a synthetic 100-rider convoy fixture to capture high-density bead wire and map clustering frames.

### GAP-02: Tunnel / Ghat Section GPS Loss
- **Impact on UI:**
  When riding through mountain passes or tunnels (e.g., Western Ghats tunnels), the GPS status transitions from `GpsState.accurate` to `GpsState.lost`. The top cockpit pill replaces speed limit indicators with an amber `Low GPS` badge and preserves the last known vector using inertial sensors.
- **Verification Plan:**
  Feed synthetic `scenario_tunnel_and_offline_test.dart` telemetry and render the top pill state.

### GAP-03: Sudden Sensor Impact Detection
- **Impact on UI:**
  When an impact exceeds the 4.0G threshold followed by a zero-velocity decay, the `LocalCrashCountdownDialog` triggers over all current views with an audible beep. If not canceled within 15 seconds, the emergency broadcast triggers.
- **Verification Plan:**
  Verified in unit tests via `advanced_crash_detection_test.dart`. Visual frame captured in `SCR-047_local_crash_countdown_dialog.png`.

---

## 3. Summary Assessment

All core user-facing and administrator screens (90 total captures) are fully captured and accounted for in the primary audit. The gaps listed above represent transient sensor conditions and dynamic network fluctuations rather than missing layout screens.

