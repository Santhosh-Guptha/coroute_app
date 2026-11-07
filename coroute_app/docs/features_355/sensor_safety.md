# 3.55 sensor safety (phone-only, free on every plan, works without signal)

Area: `sensor_safety`. Six features from the v3.55 plan table "Phone-only safety". All logic runs on
the phone, from the GPS fixes and 1 s accelerometer buckets SafetyService already receives (no new
sensor, GPS or idle timer work). Nothing new is uploaded; the only thing that ever leaves the phone
is the fatigue *level* (for the group break planner, via `SafetyService.fatigueLevel`) and the one
last-location message of the SOS battery reserve.

Hub: `lib/data/services/sensor_safety_hub.dart` (`SensorSafetyHub`, owned by SafetyService as
`sensorSafety`). SafetyService only carries small anchored hooks (`_onFix`, `_onAccel`,
`_resetRide`, `_updateSensor`, `_openAlarm`, `alarmImOk`, `_sendCrash`, `closeAlarm`,
`_saveRideStats`, `dispose`).

Admin switches (gateway/src/feature_flags.js, group Safety, default on, not locked):
`fatigueScore`, `riderDown`, `crashLearning`, `mountCheck`, `sosBatteryReserve`, `safetyReport`.
The app reads them through `SafetyService.featureOn` / `FeatureFlagsService.on` (null/unknown = on).
Crash detection, SOS and emergency texts themselves are never gated by these.

---

## 1. Fatigue score (`fatigueScore`) — done

**Behaviour.** Break prompts adapt to the rider. A level 0–100 is computed every 15 s of fixes:

| Signal | Points |
|---|---|
| Ride time in the current stretch (FatigueTracker stretch: no stop >= 10 min) | linear, 60 at 2 h, cap 75 |
| Time of day (local) | time points x1.25 at 14:00–16:00, x1.4 at 00:00–06:00 |
| Micro-stops (stops of 1–10 min inside the stretch) | 4 each, cap 12 |
| Steering wobble: variance of `peakGyroRadS` at steady speed (>= 30 km/h, < 5 km/h change between fixes) over the last 10 min vs the rider's own baseline from the first 30 min of riding this ride (>= 120 baseline / 60 recent samples) | ratio > 1.5 → up to 20 |

Output: `FatigueAssessment.level` and `suggestedBreakInMin` (never later than the 2 h rule).

**Prompt rules** (`FatigueEarlyPromptGate`): an early "Time for a break" prompt when level >= 70,
stretch >= 45 min, no fatigue prompt (early or rule) in the last 30 min, and the rule's next
reminder is not due within 30 min. The existing fixed rule (2 h, then hourly) is untouched and
always fires on time, so the adaptive prompt can only make the prompt *earlier*. The early prompt
uses the existing prompt key (`LOCAL:FATIGUE`, "I'm alert" / "Taking a break"), is informational
(no 60/90 s escalation to the lead), is skipped while any alarm/SOS/group alert is open, and
respects the rider's "Break reminder" setting. Typical effect: a calm daytime rider still gets the
2 h rule; at night (x1.4) the early prompt comes at ~1 h 40 min, with wobble + micro-stops from ~45 min.

**Shared value.** `SafetyService.fatigueLevel` (int 0–100; 0 when the switch is off).

Files: `lib/domain/safety/fatigue_score.dart` (`FatigueScore`, `FatigueScoreTracker`,
`FatigueEarlyPromptGate`), hooks in `safety_service.dart` (`_onFix`, `_triggerAdaptiveFatigueAlert`).

## 2. Rider-down check (`riderDown`) — done (needs device tuning)

**Behaviour.** "Bike down?" when the bike falls while stopped or at walking pace and nothing moves
for a minute. Opens the existing crash alarm (same 15 s countdown, "I'm OK" / "Need Help", SOS
`CRASH` with source CRASH_AUTO on no answer, the same SMS fallback / messages-app path and offline
solo SOS); the alarm screen and the notification are titled "Bike down?"
(`SafetyService.alarmIsRiderDown`, `CrashAlarmView.titleOverride`).

**Rules** (`RiderDownDetector`):
- last fix at most 30 s old and < 8 km/h (no fix / GPS lost → never; the crash detector owns speed);
- tilt rose by > 60° within ~2 s and reached >= 60° (a side stand at 10–15° never qualifies);
- a thud in that window: peak >= 1.5 g or dynamic peak >= 0.6 g (lifting the phone out of the mount has the turn but not the impact);
- no steps before (std >= 0.15 g in 3 of the 5 s before);
- then 60 s after a 3 s settle: >= 75% of seconds calm (std <= 0.06 g, gyro <= 0.15 rad/s), tilt still >= 35°, no fix >= 8 km/h, none > 30 m away.
- Cancels: any second with std > 0.12 g (walking, picking the phone up), 10 seconds of gyro > 0.3 rad/s (body sway in a pocket), bike lifted (tilt < 35°), riding on, moved, 120 s give-up.
- Rests while the crash detector weighs an impact or any alarm/SOS is open; 5 min cooldown after an alarm.

The sensor stays on only while a tip-over is being watched (`wantsSensor`); otherwise it follows
the crash detector's arming, so a bike that falls more than 3 min after the last riding (sensor
off) is not covered — by design (battery rule). "I'm OK" on a "Bike down?" alarm never feeds crash
learning and schedules no post-crash follow-up.

Files: `lib/domain/safety/rider_down_detector.dart`, hooks in `safety_service.dart`
(`_onAccel`, `_openRiderDownAlarm`, `_updateSensor`), `lib/presentation/safety/crash_alarm_screen.dart`.

## 3. Crash detection that learns (`crashLearning`) — done

**Behaviour.** Each "I'm OK" on a phone crash alarm raises the threshold of the *stage that fired*
for this bike: +5% per false alarm, cap +25%, back down 2 points per alarm-free riding hour (fixes
>= 10 km/h). A real alarm (SOS sent) forgets the learning of the stage that fired.

**Bounds / safety.** Only two stages learn: lowside/slide (`CrashScenario.lowsideSlide`,
2.0 g → max 2.5 g) and low-speed fall (`CrashScenario.stationaryDrop`, 1.5/1.8 g → max
1.875/2.25 g). The high-impact path (3.8 g dynamic / 4 g raw) and the high-side tumble path never
read the learned scales, so a severe impact or tumble always alarms exactly as before (tested at
max learning). `CrashDetector.setLearnedScales` clamps to 1.0–1.25; default 1.0 is the previous
rule byte-for-byte. Outside impacts (wearable / developer) and rider-down checks never learn.
Note: at riding speed the low-speed fall stage overlaps the slide stage (it is armed by any fix
>= 10 km/h in the last 30 s), so in practice most false alarms that learn are `stationaryDrop`.

**Storage.** SharedPreferences `coroute_crash_learning_v1`: `{bikeId: {s, l, n, r}}`, bike id =
garage active bike (`GarageService.shared`), else `default`; at most 10 bikes. Loaded at each ride
reset; saved on every change and at ride end.

**Settings.** Settings › Safety, under Crash detection: "Learned from N false alarms on this bike"
with "Reset learning" (`CrashLearningRow`; hidden when nothing learned or switch off).

Files: `lib/domain/safety/crash_learning.dart`, additive change in
`lib/domain/safety/crash_detector.dart` (`slideScale`, `lowFallScale`, `setLearnedScales`),
`lib/presentation/safety/crash_learning_row.dart`, `lib/presentation/settings/settings_screen.dart`.

## 4. Phone-mount check (`mountCheck`) — done (thresholds need device data)

**Behaviour.** From the first 3 min (up to 5 min) of riding seconds at >= 15 km/h,
`MountClassifier` decides mounted / pocket / loose / unknown from: tilt jump rate (|Δtilt| > 25°
between seconds), tilt spread, median std (vibration) and median gyro (body motion).
- loose: jump rate >= 0.12 or tilt std >= 25°;
- pocket: median std < 0.035 g (damped) and (median gyro >= 0.35 rad/s or tilt std >= 6°);
- mounted: undamped vibration, jump rate < 0.05, tilt std < 18°;
- else unknown (no card).

Pocket or loose → once per ride a gentle cockpit card (normal tier, route-info priority, 90 s,
dismissible): "Phone not in a mount? — Crash detection works best with the phone in a handlebar
mount." Never while an alarm/SOS is open (deferred). The last result is kept
(`coroute_mount_last_v1`) and shown in the pre-ride phone check as a "Phone mount" line
(`MountCheckLine`), and stored in the ride safety summary.

Files: `lib/domain/safety/mount_classifier.dart`, `lib/data/services/sensor_safety_hub.dart`,
`lib/presentation/safety/mount_check_line.dart`, cockpit slot in `live_cockpit_map_screen.dart`,
`lib/presentation/diagnostics/pre_ride_phone_check_screen.dart`.

## 5. SOS battery reserve (`sosBatteryReserve`) — done

**Behaviour.** `SosBatteryReserve.shared` (query `SosBatteryReserve.isActive`). On in a ride when
battery < 10% and not charging; off when charging, at >= 15% (hysteresis) or when the ride ends.
On switch-on:
- map tile downloads/prefetch stop (`TilePrefetcher.handleLowBattery(true)`; restored to the ride's
  own battery policy on exit);
- hands-free group talk (VOX) goes back to push-to-talk;
- place review prompts (main.dart `emergencyOpen` gate), heritage notices (cockpit
  `heritageEnabled`) and the stops-on-the-way network refresh (`ConvoyEssentialsPort.conservingBattery`) pause;
- one last-location update per ride: the existing `LAST_GASP_BEACON` message over RealtimeService
  (gateway: rider patched with battery level and `statusReason: BATTERY_SHUTDOWN`, fans out
  `RIDER_BATTERY_SHUTDOWN` to the group, timeline `BATTERY_SHUTDOWN`; guardians see the rider's
  state). Retried on the next update when the send fails or no position is known yet;
- cockpit card "Battery saver for SOS is on" (important tier, group-safety priority below SOS,
  dismissible).
GPS: already on the gentle low-battery cadence below 20% (ConvoyService battery policy /
`LocationCadence lowBattery`), unchanged. SOS, crash detection, emergency texts are never paused.
Minutes in the reserve are recorded in the ride safety summary.

Files: `lib/domain/safety/sos_battery_reserve_policy.dart`, `lib/data/services/sos_battery_reserve.dart`
(`SosBatteryReserve`, `SosBatteryReserveBinding`), `lib/main.dart` (provider + binding + review gate),
`lib/data/services/ride_essentials_coordinator.dart`, cockpit slot + heritage gate.

## 6. Ride safety report (`safetyReport`) — done

**Behaviour.** A private "Safety summary" card on my own trip report (not in the admin view):
hard brakes, minutes over the speed limit (ride/personal limit + 1.5 km/h tolerance, from fixes),
km after dark (sun-based night flag), breaks, highest tiredness, break reminders, "Bike down?"
checks, crash alarms, road hazards felt (my own pothole / speed breaker / rough road detections),
minutes on the SOS battery reserve. Saved with the existing `RideStats` under key `sf`
(backward compatible: old entries have no summary, empty summaries are not written), never
uploaded. "From your phone only. Only you can see this."

Files: `lib/domain/safety/ride_safety_summary.dart`, `lib/data/local/ride_stats_store.dart`,
`lib/presentation/report/ride_safety_summary_card.dart`, `lib/presentation/report/trip_report_screen.dart`.

---

## Tests

- `test/sensor_safety_355_test.dart` (pure): fatigue monotonicity, circadian weighting, bounded
  points, break never after 2 h, micro-stops, wobble vs baseline, prompt gate spacing; rider-down
  tip-over vs side stand vs pocket pickup vs thud+walking vs body sway vs walking before vs speed /
  no fix vs lifted / riding on, cooldown; learning step/cap/decay/real-alarm reset/JSON bounds,
  severe impact and high-side still alarm at max learning, default rule unchanged, clamping; mount
  classifier mounted/pocket/loose/unknown; battery reserve hysteresis, charging, ride end,
  beacon once per ride; summary over-limit/night km/JSON compat.
  Executed here through a temporary `dart` shim of flutter_test: 34/34 pass. Existing
  `crash_detector_test` (32), `crash_false_positive_guards_test` (6) and
  `advanced_crash_detection_test` (14) also pass unchanged through the same shim.
- `test/sensor_safety_355_service_test.dart` (flutter_test, needs the engine): reserve controller
  (pause, single beacon, retry, switch), hub (learning applied to the detector, per-bike
  persistence, switches, rider-down rest, summary counts), RideStats compatibility, summary card.
- Gateway: `node --test test/feature_flags_355.test.js` passes with the six new entries.

## Needs real-device validation

- Native bucket semantics while stopped: `tiltDeg` is relative to the riding baseline; confirm it
  reads ~80–90° for a bike on its side and ~10–15° on a side stand, and that std/gyro of a phone on
  a fallen bike stay under 0.06 g / 0.15 rad/s.
- Rider-down thud threshold (1.5 g / 0.6 g dyn) vs soft ground; pocket-pickup and walking cancels.
- Mount classifier thresholds (vibration medians differ between singles, twins and scooters).
- Wobble ratio on rough roads (could inflate the level by up to 20 points; the 45-min minimum and
  30-min spacing bound the effect).
- LAST_GASP_BEACON delivery at < 10% with weak signal; guardian page showing the last position.
