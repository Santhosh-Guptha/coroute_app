# 3.55 alert latency review (owner report: "the alerts and speed alerts are so late")

Scope of this round: detection and decision latency (GPS → speed → rule → alert call). Speech /
audio output latency (TTS start, audio focus, ducking) is the audio round's part and is not
counted below.

## Where the time went

Overspeed, end to end (HEAD): GPS fix (1 s, or **2 s on the battery saver** in town and on the
open road) → speed estimator (Kalman, steady-mode smoothing; on a phone with noisy Doppler a
gradual speed-up crossed the limit up to 3 s after the truth, p90) → `SafetyService._checkSpeedLimit`
(limit + 1.5 km/h held **1.5 s**, i.e. the third fix over the line at 1 Hz) → card + voice. After a
stop longer than **60 s** the GPS went to the idle profile (20 s interval, 25 m distance filter,
network accuracy), so the first riding fixes after a long light came several seconds late. And
hovering at the limit ended the episode at the limit and spoke again on the next crossing, which
kept the speech queue busy and delayed the next real alert.

Nothing in these paths awaited I/O before alerting: the overspeed, road-limit, bend, crash and
rider-down decisions are synchronous on the fix or the sensor second (alert first; logging and
saving happen after). Server alerts (SEPARATED, BEHIND_SWEEPER, OVERSPEED, INCIDENT, SOS) reach the
app as socket events and `AlertService._onTimeline` reconciles at once; its 30 s timer only
refreshes time-based text (distances, durations).

## Latency table (before → after)

| Alert | Before (HEAD) | After | Change |
|---|---|---|---|
| Overspeed (own limit), 1 Hz fixes | estimator lag 0–3 s (p90) + 2 s hold → about 3–5 s | 0–2 s (p90) + 1 s hold → about 1–3 s | `OverspeedGate` (warn at limit + 2 on the 2nd fix, +10 at once), `SpeedEstimator.maneuverSigmas` 2.5 → 2.0 |
| Overspeed on the battery saver (town / open road) | 2 s fixes: about 4–7 s | 1 Hz: as above | `LocationCadence.lowBattery` city / road 2000 → 1000 ms |
| Overspeed right after a long red light (> 60 s) | + several seconds (idle GPS profile: 25 m filter, 20 s) | idle profile only after 3 min (90 s on the battery saver) | `ConvoyService._onPosition` stationary threshold |
| Overspeed repeats while over | spoke again on every re-crossing of the limit | reminder every 25 s while over; re-arm only after 5 s under limit - 3 | `OverspeedGate` |
| Road / school / hospital zone limit | 8 s over limit + 5 (a 150 m zone mostly ridden through at 50 km/h) | 2 s | `SpeedLimitAdvisor.holdFor` |
| Group overspeed (lead / group notified, server) | 3 s hold | 2 s hold | gateway `OVERSPEED_HOLD_MS` |
| Separated / behind the sweeper / regroup reached (server, on telemetry) | rules ran at most every 5 s per ride (+ the 60 s hold by design) | every 2 s (+ 60 s hold) | gateway `GROUP_CHECK_MS` |
| Offline, stale rider, possible incident when parked, sweeper distress, end of overspeed (server tick) | up to +30 s after the condition | up to +2 s | gateway `TIMELINE_TICK_MS` 30000 → 2000 (18 ms per tick for 5,000 riders, 0.9 % of a core) |
| Sharp bend ahead | 6 s of riding + braking distance (150–600 m) | unchanged (already speed-based) | `BendAdvisor.leadFor` |
| Accident / hazard ahead (network) | shown on the server event | unchanged | `AlertService` reconciles on `networkRevision` |
| Crash alarm | stop + 20 s still, 15 s countdown | detection unchanged for real crashes; countdown 30 s (deliberate, see sensor_safety.md section 7) | `SafetyConstants.crashCountdown` |

Location request while riding: 1 s interval (500 ms on the highway band, normal battery), no
distance filter, high / navigation accuracy, on the fused provider (`geolocator_android`
`AndroidSettings`), also on the battery saver.

## Not changed (noted)

- Separation and behind-sweeper keep their 60 s hold (riders split briefly in traffic all the time).
- Road-hazard reports ("Pothole ahead") show within a fixed 500 m in the cockpit (18 s at 100
  km/h); the cockpit file was being edited by the audio round, so a speed-based distance was not
  added here.
- Road speed-limit points are matched within 150 m ahead (not speed-based).

## Tests

- `test/alert_latency_355_test.dart`: overspeed gate (hold, spike, hysteresis, 25 s reminders, new
  limit), zone limit 2 s, 1 Hz cadence on the battery saver, estimator p90 lag <= 2 s on noisy Doppler.
- `test/road_context_355_test.dart`, `test/location_cadence_test.dart`, `test/speed_estimator_test.dart` updated / passing.
- `gateway/test/timeline_tick_load_355.test.js`: tick cost and a 50-rider telemetry burst.

## Device checks

- Ride past a set personal limit (e.g. 40 km/h): the warning should be spoken within about 2 s of
  the speedometer passing 42; at 39–43 km/h it should speak once, then at most every 25 s.
- Battery saver on: the speed readout keeps updating every second in town.
- Wait at a light for 2 minutes, ride off: the speed readout moves within a second or two.

## Speech output (audio round)

Scope: from the alert decision (the `speak` / `submit` call) to the first sound in the rider's
ears: priority queue → audio focus → text-to-speech engine → playback. Code:
`lib/data/services/audio_priority_manager.dart`, `voice_service.dart`, `TtsChannel.kt`.

### Where the time went (HEAD)

| Step | HEAD | Effect |
|---|---|---|
| Engine start | bound lazily **on the first alert of a ride** (`TextToSpeech(...)` + `onInit` + language checks: about 0.3-2 s, up to the 8 s timeout on a cold phone), the first line also loads the voice model (0.2-0.8 s) | the first alert of every ride came 0.5-2.5 s late |
| Engine released mid-ride | `main.dart` released the engine whenever the convoy service notified without an active group, i.e. **all through an offline solo ride** | every solo-ride alert paid the engine start again |
| Voice | the engine default, which can be a **network voice** (0.5-2 s per line, worse on a weak signal) | late lines on some phones / languages |
| Synthesis | every line synthesised before any sound (about 150-450 ms on a local voice) | |
| Queue | only P0 / P1 interrupted; a P2 hazard waited for a P3-P5 line already queued in the engine (2-5 s for a long group / fuel line); an equal P1 flushed the earlier P1, which was lost | hazards late behind chatter |
| Audio focus | requested synchronously right before `speak` (5-20 ms binder call), released 0.7 s after the queue drains | no start delay (the 0.7 s is after the line); ducking fade is the system's (~100-300 ms, in parallel with synthesis) |
| Phone call | ordinary lines held by design; critical: tone at once, phrase after 0.55 s | unchanged |

### What changed

1. **Warm engine for the whole ride.** `VoiceService.warmUp()` runs at ride start (group trip
   STARTED or offline solo ride; `main.dart`, sound awareness block): binds the engine, sets the
   language and an installed **offline voice with the lowest latency** (`pickOfflineVoice`), writes
   the earcon. The engine is released only when the ride really ends (group trip ENDED / left, or
   the solo ride ends), no longer on unrelated convoy updates.
2. **Pre-synthesised clips.** `prepare` synthesises the common lines to WAV in the cache, one at a
   time and only while nothing is being said, and maps them with `TextToSpeech.addSpeech`: all 16
   siren lines for the rider's give-way side and the lead phrases "Slow down.", "Over limit.",
   "Please slow down.". A line that is a clip starts at once; a line that starts with one
   ("Slow down. 95 km/h, limit 65.") plays the clip while the rest is synthesised (no audible gap).
   Clips are reused across rides (file name = hash of language, voice and text).
3. **Earcon.** P0-P2 lines that are not clips start with a 0.16 s two-tone earcon (same stream,
   same focus, through the engine's own queue), so the rider hears the alert at once while the
   words are synthesised behind it.
4. **Preemption by priority.** A line interrupts what is being said when everything in the
   engine's queue is of lower priority: P0 / P1 over any lower level, P2-P5 over lines two levels
   lower (a hazard cuts a group or fuel line; navigation cuts an info line). Cut lines are said
   again after it (unless stale: TTL), held until it ends (native "done" event, or the estimate).
   Equal priorities queue (a second P1 no longer erases the first).
5. **Real progress from the engine.** `TtsChannel` reports `speechEvent` start (with the delay
   from the speak call to the first audio) and done back to Dart, so the queue knows what is still
   playing (and the siren detector knows when the phone itself is speaking).

### Timings (budget per line; device numbers come from the diagnostics below)

| Line | HEAD, first of the ride | HEAD, later | After |
|---|---|---|---|
| P1 siren "Ambulance siren close by. Keep left and give way." | 0.7-2.5 s | 0.15-0.45 s (+ any line ahead of it) | **~0.05-0.15 s** (clip, MediaPlayer start), preempts lower lines |
| P1 overspeed "Slow down. 95 km/h, limit 65." | 0.7-2.5 s | 0.15-0.45 s | **~0.05-0.15 s** ("Slow down." clip; the numbers are synthesised during it) |
| P0 SOS / crash line (free text with names) | 0.7-2.5 s | 0.15-0.45 s | **earcon at ~0.05-0.1 s**, words at 0.15-0.45 s; preempts everything lower |
| P2 hazard ("Sharp bend ahead...") behind a P4 line | + 2-5 s queue | + 2-5 s | **earcon at ~0.05-0.1 s**, words 0.15-0.45 s (preempts P4 / P5) |
| P3-P5 ordinary line, engine idle | 0.7-2.5 s | 0.15-0.45 s | 0.15-0.45 s (warm engine, offline voice) |

Targets: speech (or its earcon) starts within 500 ms of the decision for P0 / P1 and within 800 ms
otherwise, unless an equal or higher priority line is already being said (then it follows it).
The Dart side adds a MethodChannel round trip (2-10 ms).

### How to measure on a phone

`adb logcat -s CoRouteAudio flutter` during a ride (no text, no names are logged):

- `audio: P1 siren_newEpisode_# to engine: waited 0ms, call 4ms, preempt` (queue wait, channel time);
- `audio: native ...` / `CoRouteAudio: focus pause critical granted music=true` (focus result);
- `audio: speech start alert_12 +96ms (clip)` (engine: speak call to the first audio);
- `audio: P1 siren_newEpisode_# decision->audio 112ms` (decision to sound, end to end);
- `audio: engine warm ok=true lang=en 840ms`, `CoRouteAudio: tts voice offline picked latency=200 quality=400`, `tts clips ready=19`.

`AudioDiagLog` (lib/domain/audio/audio_diag_log.dart) keeps the last 300 lines in memory for a
support screen (`AudioDiagLog.dump()`).
