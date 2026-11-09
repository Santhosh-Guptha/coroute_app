# Speed accuracy (3.55)

Owner report: "I rode at 86 with a limit of 80, but the app only showed 79 and 80."

## The path traced (platform fix to number on screen and to the overspeed check)

1. `Geolocator.getPositionStream` (Android: FusedLocationProvider via `AndroidSettings`;
   cadence from `LocationCadence` in `lib/domain/tracking/location_cadence.dart`, chosen in
   `ConvoyService._settingsFor`).
2. `ConvoyService._onPosition` (`lib/data/services/convoy_service.dart`) turned `Position.speed`
   (m/s, GNSS Doppler) into km/h with `* 3.6`, clamped 0-300. No smoothing, no clamp to the limit,
   no truncation.
3. That value went to the local `RiderModel.speedKmh` (cockpit), the `TrackPoint` on `myFixes`
   (SafetyService `_onFix` -> `_checkSpeedLimit`, crash detector, track recorder) and TELEMETRY
   (`toStringAsFixed(1)`).
4. Display: `CockpitSpeedometer` / `MinimalSpeedAlert`
   (`lib/presentation/rider/widgets/minimal_cockpit_overlay.dart`) use `.round()`. Correct.
5. Overspeed: `SafetyService._checkSpeedLimit` warns above limit + 1.5 km/h held 1.5 s
   (immediately at +10). Correct.
6. Gateway: `ws.js` TELEMETRY -> `convoys.patchRider` -> `sanitizeTelemetry` clamps 0-300 and
   trusts the client speed; `timeline.js _speed` rounds it for OVERSPEED entries. It never
   recomputes speed from positions. Your own position updates are not echoed back to you (the
   fan-out skips the sender), so the server never overwrote the local readout. No change needed.
7. Solo rides: `nativeSoloFixes()` (`lib/data/services/solo_fix_source.dart`) feeds SafetyService
   directly.

The app used the right source (Doppler, not distance / time), and nothing clamped, truncated or
over-smoothed it. So at a steady speed on open road the readout was already the phone's GPS speed
within about +/-0.5 km/h.

## Real defects found and fixed

| # | Defect | Effect | Fix |
|---|--------|--------|-----|
| 1 | Missing Doppler read as 0 (`position.speed` is a 0.0 placeholder when `hasSpeed` is false; iOS sends -1) | A fix without speed showed 0 km/h for a second, reset the overspeed hold, dropped the GPS band | `speedFixOf()` passes Doppler only when present; the estimator falls back to distance / time over 1-4 s, accuracy-weighted; a placeholder 0 while positions clearly move is not taken as a stop |
| 2 | No outlier rejection | A Doppler glitch (e.g. 400 km/h, or a single 0) went straight to the readout and could fire / reset the overspeed warning | Physical gate (> 1.2 g change since the last estimate, or > 300 km/h, rejected); big-but-possible jumps down-weighted; agreeing rejections re-seed (2 fixes for a sudden stop, so a fall still reads 0 within ~1-2 s for the crash detector) |
| 3 | Raw 1 Hz Doppler jitter | Readout flickered +/-1-2 km/h; near a limit the warning could flap | Adaptive 2-state (speed, acceleration) Kalman filter: steady riding cuts noise ~3x, a change of speed switches it to fast tracking (lag about 1 s, no lag on a steady ramp) |
| 4 | Speed frozen while "coasting" on a route ride | With a route loaded, one fix with accuracy > 50 m (trees, city) starts tunnel coasting; the readout then showed the frozen entry speed until a fix <= 50 m came back, even though those degraded fixes still carry good Doppler speed | Every fix goes through the estimator; while coasting the readout uses a fresh (< 2.5 s) Doppler estimate, and the projection's speed only in a real dead zone (`ConvoyService._coastingSpeedKmh`). A crash stop in the tunnel still reads 0 |
| 5 | Distance filter while riding (2-10 m; solo 5 m) | When stopping, the last fix (often 5-8 km/h) stayed on screen while parked; no new fix until the bike moved again | `distanceFilter: 0` for all riding bands (normal and battery saver) and solo; parked (idle profile after 60 s still) keeps its 25 m / 20 s plan |
| 6 | Battery saver "stopped" band 5 s | Slow stop -> 0 | 4 s when below 10 km/h; riding bands stay at <= 2 s (normal: 1 s, highway 500 ms) |
| 7 | No stop hysteresis | Parked Doppler noise (0-2 km/h) showed as 1-2 km/h | Shows 0 below 2.5 km/h, leaves 0 only above 4 km/h |

Accelerometer fusion was considered and not added: the phone's mounting orientation is unknown and
changes (pocket / tank bag / handlebar), so integrating it into speed is not safe; a tuned filter on
Doppler meets the targets.

## The estimator

`lib/domain/tracking/speed_estimator.dart` (pure Dart, no imports beyond `dart:`):
`SpeedEstimator.update(SpeedFix)` -> `SpeedEstimate.kmh`. Used by `ConvoyService` (one instance
per ride, reset at GPS start) and by the solo fix stream. The cockpit, the overspeed check,
TELEMETRY, the track and the crash detector all get the same number. It never clamps to a limit
and never truncates; the widgets round.

## Tests

`test/speed_estimator_test.dart` (11 tests), also sanity-run with plain Dart (a copy of the class
and a tiny `expect` shim in the scratchpad), all passing:

- steady 86 km/h with noisy Doppler (sigma 0.3 m/s, raw readings spread ~82-90): every displayed
  value 85-87 (50-seed sweep: 5 of 8,500 readings outside 85-87, none outside 84-88)
- 60 -> 90 km/h in 5 s: never more than 2 s behind, overshoot <= 3.5 km/h, settles at 90 +/- 2
- braking 80 -> 0: reads 0 when stopped, no jitter while parked
- no Doppler: distance / time fallback reads 72 +/- 2 at 72
- placeholder 0 while moving is not a stop; a real stop with the placeholder reads 0
- no Doppler and poor positions (60 m): holds the speed, no made-up measurement
- outliers (400 km/h glitch, single 0, single 150) rejected; a genuine 250 km/h is not
- sudden stop (fall) reads 0 within 2 s; consistent new speed after an outage accepted
- on a 60 m radius bend at 80 km/h Doppler is used (80 +/- 0.5), not the shorter chord
- repeated / out-of-order fixes ignored; a long gap restarts the filter

Updated for the new cadence: `test/location_cadence_test.dart`,
`test/battery_and_performance_benchmark_test.dart`. `dart analyze lib test`: No issues found.

## Why the bike said 86 and the app said 79-80

Motorcycle speedometers over-read by law. UN ECE R39 (and India's CMVR, which follows it) require
the indicated speed never to be below the true speed and allow up to 10 % + 4 km/h above it:
`0 <= V_indicated - V_true <= 0.1 * V_true + 4 km/h`. Makers aim for the middle of that band, and
tyre wear, pressure and a different tyre size add a few percent more.

At a true 79.5 km/h the allowed reading is 79.5 to 91.5 km/h. 86 indicated is +8 %, a typical
over-read. A readout alternating "79" and "80" is exactly what the GPS shows at a true ~79.5 km/h.
The app's limit check judged the true speed, so with a limit of 80 (+1.5 km/h tolerance) it
correctly did not warn.

How much each cause explains of the 6-7 km/h gap:

- Speedometer over-read: essentially all of it (~6-7 km/h at 80-86 km/h is within the normal range).
- App defects above: none of them causes a steady under-read on an open road. #4 (coasting freeze
  on a route ride under trees / in a town) could hold an older, lower speed for some seconds while
  accelerating; #1 and #2 cause single-second glitches. They were real and are fixed, but they do
  not explain a steady 79-80 at an indicated 86.

So the app is now as accurate as the phone's GNSS (about +/-1 km/h), and will keep reading a few
km/h below the bike's speedometer. That is the true speed, and the right one for a limit warning.

## Proposal (not implemented, for the owner to decide)

An optional per-bike "Speedometer offset" display setting in the garage (e.g. +0 to +10 %), so
the cockpit number can match the rider's own speedometer, while the overspeed check, telemetry,
reports and the gateway keep using the true GPS speed. No inflation was added.
