# Round 10: rescue beacon (notes for the lead)

Owner request: an SOS siren for a real, unanswered accident that gets louder, plus a high-frequency
sound other riders' phones can detect and use to find the rider (forests). Design, ranges, battery,
safety and privacy: [docs/features_355/rescue_beacon.md](../features_355/rescue_beacon.md).
Build left at 3.55.0+10028.

## Verified versus written

| Part | State |
|---|---|
| Domain DSP, state machine, strobe, finder guide, BLE payload, self-test, decimator (pure Dart) | **Verified**: `tool/pure_dart_test/run.sh test/rescue_beacon_dsp_test.dart test/rescue_beacon_plan_test.dart test/rescue_finder_test.dart` → 20 + 27 + 22 pass |
| Victim service (`rescue_beacon_service.dart`) | **Verified on the Dart VM with a throw-away Flutter stub** (ChangeNotifier / MethodChannel): `test/rescue_beacon_service_test.dart` 9 / 9. Run it with `flutter test` on a machine with the SDK. |
| `test/rescue_mic_plan_test.dart` | Analyzer-clean, **not run** (needs Flutter: record / widgets) |
| Finder service, bindings, UI (panel, host, finder screen, Find button), mic hub change | Analyzer-clean, **not run** (no Flutter SDK here) |
| Kotlin `RescueBeaconChannel.kt` + MainActivity registration | **Written, not compiled.** API guards checked by hand (see below) |
| Gateway | **Verified**: `test/rescue_beacon_355.test.js` (7), `test/rescue_beacon_net_355.test.js` (1); full `npm test` result is in the final report |
| Lab | `tool/rescue_lab/run.sh` (results below) |
| `dart analyze lib test` | clean; `dart tool/play_policy_scan.dart`: 0 hits |

## Files

New:

- `lib/domain/rescue/`
  - `rescue_id.dart`, `rescue_acoustics.dart`, `rescue_beacon_detector.dart`, `rescue_beacon_plan.dart`
  - `rescue_strobe.dart`, `rescue_finder_model.dart`, `proximity_trend.dart`, `rescue_ble.dart`
  - `speaker_self_test.dart`, `decimator.dart`
  - `acoustic_scene.dart` (lab and tests only; tree-shaken from the app)
- `lib/data/services/`
  - `rescue_native.dart`, `rescue_beacon_service.dart`, `rescue_finder_service.dart`, `rescue_bindings.dart`
- `lib/presentation/rescue/`
  - `rescue_widgets.dart`, `rescue_beacon_panel.dart`, `rescue_beacon_host.dart`
  - `rescue_finder_screen.dart`, `find_rider_button.dart`
- `android/app/src/main/kotlin/space/devmonks/coroute_app/RescueBeaconChannel.kt`
- `gateway/src/rescue_beacon.js`, `gateway/test/rescue_beacon_355.test.js`, `gateway/test/rescue_beacon_net_355.test.js`
- `test/rescue_beacon_dsp_test.dart`, `test/rescue_beacon_plan_test.dart`, `test/rescue_finder_test.dart`,
  `test/rescue_beacon_service_test.dart`, `test/rescue_mic_plan_test.dart`
- `tool/rescue_lab/rescue_lab.dart`, `tool/rescue_lab/run.sh`

Shared files, minimal marked edits ("Round 10 rescue beacon"):

| File | Edit |
|---|---|
| `lib/main.dart` | imports; `RescueBeaconService` + `RescueFinderService` providers after the mic block; `RescueBeaconHost` wrapping `CrashAlarmHost` |
| `lib/data/services/ride_mic_hub.dart` | wide-band (48 kHz) listeners + decimation for the existing consumers; `MicPlan.wideBand` / `forNeeds(wide:)`. Nothing changes without a rescue listener. |
| `lib/presentation/safety/crash_alarm_screen.dart` | `const RescueBeaconPanel()` above the SOS sheet (sent state) |
| `lib/presentation/ride/incident_sheet.dart` | "Find Ravi" button (others' SOS); beacon panel on my own SOS |
| `lib/presentation/ride/assist_sheet.dart` | "Find" button for an accepted nearby request |
| `lib/domain/security/lock_screen_cockpit_policy.dart` | `safety/rescue_beacon`, `safety/rescue_finder` allowed over the keyguard |
| `android/.../MainActivity.kt` | registers / disposes `coroute/rescue` |
| `AndroidManifest.xml` | Bluetooth permissions (below) |
| `docs/PLAYSTORE_PERMISSIONS.md` | Bluetooth rows |
| `gateway/src/convoys.js` | `alert.rescueId`; `publicAlert.rescueId` |
| `gateway/src/safety_network.js` | `ASSIST_UPDATE.rescueId` for active responders |
| `gateway/src/ws.js` | `RESCUE_PING` case, action budget, safety-only delivery of own pings |

Not touched: `safety_service.dart`, `alarm_notifier.dart` (only `showCriticalAlert` is called),
`siren_acoustic_detector.dart`, `convoy_service.dart`, `sos_battery_reserve.dart` (read through
`SosBatteryReserve.isActive`). The beacon watches SafetyService / ConvoyService state through
`AppRescueVictimPort`.

## Permissions

- **Added:** `BLUETOOTH_ADVERTISE`, `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH` and
  `BLUETOOTH_ADMIN` (`maxSdkVersion 30`), uses-feature `bluetooth_le` (`required="false"`).
  - Agent A's offline link uses the same entries, which are declared once.
  - Android 12+ "Nearby devices" is asked from the finder ("Allow microphone and nearby devices").
  - For the **victim** side it must already be granted before a crash. Recommend asking it in the
    pre-ride phone check together with the mesh. Not granted: BLE is skipped; siren and sound still
    work.
- **Not added:** CAMERA (the torch needs none), anything for audio (alarm stream, no focus).
  `ACCESS_NOTIFICATION_POLICY` already exists: with DND access granted, "total silence" is switched
  to "alarms only" during the beacon and restored after.
- **Microphone:** existing `RECORD_AUDIO`, plus the ride foreground service with the microphone type
  for listening with the screen off.

## Kotlin guards (checked by hand, needs a compile)

| Feature | Guard |
|---|---|
| AudioTrack.Builder | API 23 ≤ minSdk 24 |
| VibrationAttributes | API 33 |
| VibrationEffect | API 26; older phones use `vibrate(long[], -1)` |
| setTorchMode | API 23 |
| BLUETOOTH_ADVERTISE / BLUETOOTH_SCAN check | API 31+ |
| ACCESS_FINE_LOCATION for scans | ≤ 30 |
| AdvertisingSet / Coded PHY / `ScanSettings.setLegacy` / `setPhy` / `ScanResult.primaryPhy` | API 26 + chip support checks |
| `@SuppressLint("MissingPermission")` | only after explicit checks |

Audio is written in 100 ms chunks on a thread, so a stop takes effect in about 100 ms. Everything is
disposed with the Flutter engine.

## Lab results (`tool/rescue_lab/run.sh --trials 6`, 716 s)

Model: 82 dB SPL siren at 1 m; speaker −5 dB at 15 kHz and −10 dB at 18.6 kHz; locator −11 dB under
the siren peak; air absorption (ISO 9613-1) plus woodland excess attenuation; mic 0 dBFS = 120 dB SPL,
30 dBA self-noise. Each cell = 6 trials of 8 s; "confirmed" = 2 matching packets.

Largest distance with ≥ 80 % confirmed detection:

| band | phone | quiet forest | forest + wind | roadside, engine idling | handling noise | everything |
|---|---|---|---|---|---|---|
| high | open | 30 m | 20 m | 15 m | 30 m | 15 m |
| high | face-down | 25 m | 10 m | 10 m | 25 m | 5 m |
| high | pocket/jacket | 20 m | 5 m | 5 m | 15 m | < 5 m |
| high | old phone (−25 dB at 18.6 kHz) | 20 m | 5 m | 5 m | 15 m | < 5 m |
| low | open | 50 m | 30 m | 20 m | 50 m | 20 m |
| low | face-down | 30 m | 20 m | 10 m | 30 m | 10 m |
| low | pocket/jacket | 25 m | 10 m | 5 m | 25 m | 5 m |
| low | old phone (−12 dB at 15 kHz) | 40 m | 20 m | 15 m | 30 m | 10 m |

Audible siren, SPL at the rescuer:

| distance | open phone, forest | pocket, forest |
|---|---|---|
| 10 m | 61 dB | 53 dB |
| 25 m | 52 dB | 44 dB |
| 50 m | 44 dB | 36 dB |
| 100 m | 33 dB | 25 dB |
| 150 m | 26 dB | 18 dB |

Ambient in the 2 to 4 kHz band: quiet forest ~28 dB, roadside ~45 dB. So the siren is just audible
at ~100 m in a quiet forest and clear at 50 m. Open park: 40 dB at 100 m.

False positives:

- 5 scenarios × 300 s of noise (forest with katydid-like 14 to 19 kHz pulse trains, wind, engine,
  road, handling, all mixed): **1 stray packet decoded in 25 min, 0 confirmed ids** in "help anyone"
  mode, target never confirmed.
- Another rider's beacon at 5 m for 30 s: decoded as that id, never confirmed as the target, shown as
  "another beacon nearby".
- The victim's own siren at 2 m: 0 packets.

Findings:

- The low band reaches farther than the high band (less absorption and less speaker roll-off). The
  self-test therefore keeps **both** when both play.
- Engine noise near the rescuer is the worst case. The finder tells the rider to stop the engine and
  listen.
- Pocket / jacket costs about half the range.
- Matched (known-id) detection gives a small extra margin at the edge (25 m: 100 % vs 67 %).

These are model numbers. Real forests vary by ±10 dB: verify R1 to R4.

## Device QA items

| # | Check |
|---|---|
| R1 | **Forest / park, 2 to 3 phones.** Victim phone (a) in the open, (b) in a jacket pocket, (c) under a jacket on the ground, (d) face-down on leaves. Walk in from 150 m with 1 to 2 responder phones. Note where each meter first moves and where it confirms. |
| R2 | Detection distances per signal: siren heard by ear, locator confirmed (each band), BLE first sighting and "very close" (≥ −70 dBm). Note LE Coded on / off from the diagnostics log `rescue_ble {coded}`. |
| R3 | The finder guidance makes sense while walking: status line, hotter / colder within ~10 s of a direction change, compass arrow (hold flat), "Listen" prompt at < 150 m, offline map tiles, screen stays on, works over the lock screen. |
| R4 | DND / silent override: ringer silent, vibrate, DND priority, DND alarms-only, DND total silence with and without CoRoute DND access. Alarm volume set to 1 beforehand: raised to max during, restored after the SOS closes / rider OK. |
| R5 | Start only after the countdown: let a crash alarm run out → siren within 1 s. "I'm OK" during the countdown → nothing. "Need Help" → no siren; after 3 min "Still able to respond?" heads-up; no tap → siren at ~4 min; a tap → never. |
| R6 | Stops: rider "I'm OK" (single tap) and the existing "I'M CONSCIOUS" button → all stop; "I am safe" / group resolve → all stop; bystander 3 s hold (shorter = nothing) → siren stops, BLE continues (scanner), log line present, SOS still open on the group. |
| R7 | Strobe at night: torch flashes SOS (≤ 3/s, film it at 60 fps and count), none in daylight, none face-down / in a pocket; phone without a torch (or camera app open) → white screen flash over the alarm screen. |
| R8 | Ping the phone: from a group member and from an accepted nearby helper. Burst within ~2 s of the press, "Wait N s" on a second press, victim offline → "No connection" text. |
| R9 | Battery drain per hour of beacon (duty phase), victim phone at 80 %, screen off: target ≤ 8 %/h. At 10 % (reserve) the siren stops; SOS texts still go. |
| R10 | Old phones whose speakers roll off at high frequency (e.g. Android 8 to 9 budget models): the self-test result (`rescue_speaker_test` in the diagnostics log), and whether the low band is detected at 10 / 20 m. |
| R11 | Responder mic: the siren detector and the intercom still work while the finder is open (48 kHz capture plus decimation); hands-free talk sounds the same; push-to-talk on a helmet headset pauses the listener and it comes back on release. |
| R12 | Background: finder closed, responder within 1 km, screen locked → one heads-up "Ravi is close" when the beacon or BLE is picked up. No listening far away or without an open SOS (check the diagnostics log `rescue_listen`). |
| R13 | Permissions: Android 12+ "Nearby devices" prompt from the finder, the legacy path on Android 11, and that the existing Bluetooth headset permission check is unchanged with `BLUETOOTH_SCAN` declared again. |
| R14 | Kotlin compile on compileSdk 37 / minSdk 24; one run on Android 7 (API 24) and one on Android 14+ (VibrationAttributes, Nearby devices). |

## Integration ideas (offline mesh, Agent A)

- **Ping over the mesh:** set `RescueFinderService.meshPing = (rescueId) => mesh.sendRescuePing(rescueId)`
  (return true when queued). On the victim side, a received mesh ping calls
  `RescueBeaconService.instance?.onPingForRescueId(rescueId)`. The victim side is rate-limited
  already.
- **Rescue id over the mesh:** the mesh can carry the 16-bit id with its SOS frames, so an offline
  responder's finder knows whom to listen for (`RescueTarget` with `rescueId`).
- **BLE:** separate UUIDs, no shared advertiser. If a phone cannot run two advertisement sets, the
  rescue legacy advertisement should win during an open SOS (decide in device QA).

## User handbook text (suggested)

**Rescue siren and "Find" (if you crash and cannot answer).** If CoRoute's crash alarm counts down and
you do not answer, your SOS goes out as before. Your phone then starts a loud rescue siren that gets
louder over two minutes, then sounds for 10 seconds every half minute. It also sends a quiet signal
that other riders' CoRoute phones can pick up, and a Bluetooth signal. At night your torch flashes SOS.
If you raised an SOS yourself, CoRoute asks "Still able to respond?" after three minutes. If you do not
tap "I can respond", the siren starts.

To stop it, tap "I'm OK". Someone helping you can hold "Stop siren: help is here" for three seconds;
your SOS stays open. When your battery gets low, the siren stops so your SOS and texts keep working.

**Finding a rider.** On a rider's SOS, tap **Find Ravi**. Follow the arrow and the route to the last
GPS position. When you are close, the Bluetooth and sound meters start to move. They tell you how
close you are, not which way: walk 10 to 20 steps, and if the meter rises keep going, if it falls turn
around. Stop your engine and listen for the siren. **Ping Ravi's phone** makes it sound at once.

**Privacy.** Only during an SOS do helpers' phones listen for the rescue signal, on the phone itself.
Nothing is recorded or sent.

## Website wording (suggestions for the lead)

- "**Rescue siren when you can't answer.** After a crash you don't respond to, your phone sounds a loud
  siren, a Bluetooth beacon and, at night, an SOS light, so your group can find you, even in a forest."
- "**Find a fallen rider.** Group riders get a 'Find' screen that combines the last GPS position,
  Bluetooth and a near-silent locator sound into one simple guide for the last few metres."
- Honest small print: "Works best within tens of metres for the sound and Bluetooth; GPS and the
  route get you there. Nothing is recorded; helpers' phones listen only during an SOS."
- Avoid claiming a fixed range or "finds anyone anywhere".
