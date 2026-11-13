# Mobile app stability and accuracy audit (3.56, round 6)

Build stays 3.55.0+10026. Scope: `lib/**`, `android/**`, the Dart tests, plus the website account page and the
gateway modules for avatars, route weather and the risky-stretch counts.

**How it was done.** A read-through of the GPS path (`ConvoyService._onPosition`, the dead-reckoning tick,
`LocationCadence`, `SpeedEstimator`, `TrackFilter`, `TrackRecorder`), the ride lifecycle (`createConvoy`, join,
leave, the outbox, `RealtimeService` reconnect), the error capture in `main.dart`, every HTTP call site, the cockpit
controls and the lock-screen cockpit; plus scripted scans for timers, subscriptions and controllers that are never
cancelled. **The Flutter SDK is not installed in this workspace**, so widget tests and a device run were not
possible: pure-logic tests ran on the Dart VM with `tool/pure_dart_test/run.sh`, everything else is covered by the
device checklist in `ROUND6_APP_NOTES.md`. Findings marked "read" were confirmed by reading the code, not by a run.

**Totals:** 32 findings. High 2 (2 fixed). Medium 11 (11 fixed). Low 9 (3 fixed, 6 open, listed with the reason).
Info 10 (verified, nothing to change).

## Findings

Severity: **High** = wrong position / wrong safety behaviour for some riders; **Medium** = visible defect, privacy
or stability risk; **Low** = polish; **Info** = checked, fine.

### GPS accuracy

| Id | Sev | Issue | Fix | Status | Test |
|---|---|---|---|---|---|
| G-01 | High | The position stream is re-subscribed on every cadence change (speed band, idle profile, battery saver). Android may then replay its cached fix: an **older** fix was applied as the newest. The marker jumped back, `lastSeen` ran backwards and the track got an out-of-order point. | `FixGate` (new, `lib/domain/tracking/fix_gate.dart`): a fix whose time is not after the last accepted one is dropped, before the speed filter sees it. | Fixed | `test/fix_gate_356_test.dart` (timestamps), `round6_wiring_356_test.dart` |
| G-06 | High | "Age of the last fix" compared the **GPS time** of the fix with the **phone's clock** every second. On a phone whose clock is a few seconds off (no network time, manual clock) a rider on a planned route above 15 km/h was treated as "without GPS" for ever (permanent dead-reckoning coasting), or never when the clock was behind. | The time a fix arrives is stamped with the phone's clock (`_lastGpsFixTime = _clock()` in all three places). | Fixed | `round6_wiring_356_test.dart`; device G6 |
| G-02 | Medium | A cached fix from minutes ago (first fix after the stream opens) was taken as "now". | `FixGate`: older than 2 min against the phone's clock = dropped. Five in a row mean the clock is wrong, not the fixes: the rule switches itself off for the ride, so a wrong clock never costs the position. | Fixed | `fix_gate_356_test.dart` |
| G-03 | Medium | One wild fix (tunnel exit, tall buildings) teleported the live marker and what the group / guardian saw (the recorded track and the speed already had their own filters). | `FixGate`: more than 200 m at more than 360 km/h is dropped; three such fixes that agree with each other re-anchor (GPS really came back elsewhere). The Doppler speed of a dropped fix still feeds the speed filter. | Fixed | `fix_gate_356_test.dart` |
| G-04 | Medium | Parked bike "wandered": while stopped every fix moved the marker inside the GPS noise, and the idle profile (network accuracy) could replace a good position with one several hundred metres off; moves over 40 m were sent to the group. | `FixGate.holdPosition`: stopped and within the fix's own accuracy (12 m at least) = the marker stays; a fix worse than 100 m does not replace a good position newer than 30 s (10 s while moving). Speed, battery and "last seen" still update; the recorded track is untouched. | Fixed | `fix_gate_356_test.dart` |
| G-07 | Medium | The position stream's `onError` only printed, and there was no `onDone`: when the OS closed the listener (provider restart), the ride went on without positions until the app was restarted. | Re-open with growing waits 2, 5, 15, 30, 60 s (`GpsRestartBackoff`), reset by the first fix; never against a revoked permission (that path already existed); timer cancelled on stop and dispose. | Fixed | `fix_gate_356_test.dart`, `round6_wiring_356_test.dart`; device G7 |
| B-01 | Medium | Android's "let the app run in the background" question was opened at **every** ride start and every time GPS came back, also for riders who had answered Deny. | `BackgroundService.requestIgnoreBatteryOptimizationIfDue`: only when still restricted and not asked in the last 7 days. The pre-ride phone check keeps its button. | Fixed | `fix_gate_356_test.dart` (B-01) |
| G-05 | Low | Mock locations were not noticed. | Noted once per ride in the diagnostics log (`gps_mock_provider`). The fix is **still used**: external Bluetooth GNSS receivers feed Android through the mock provider and are legitimate. | Fixed (logged) | read |
| G-10 | Low | A GPS course of exactly 0° (due north) is read as "no course" and the compass / previous heading is used. | Not changed: one value in 360, and the plugin reports 0 for "unknown" on some phones. | Open | |
| G-11 | Low | `lastSeenEpochMs` of the own rider carries GPS time, other riders compare it with their clock. | Not changed: the gateway stamps what it relays; changing the meaning needs a gateway look. | Open | |
| G-08 | Info | Speed smoothing and spike rejection: `SpeedEstimator` (1.2 g limit, down-weighting, re-seed after an outage). | | Verified | `speed_estimator_test.dart` 11 pass here |
| G-09 | Info | Distance: only fixes that pass `TrackFilter` (30 m accuracy, teleport rule) and `TrackCleaner` count; estimated (coasting) positions are never recorded. | | Verified | read |
| K-01 | Info | After a reboot the ride service does not start by itself (`autoRunOnBoot: false`): Android 14+ does not allow a location foreground service from boot. The ride is restored when the rider opens the app (`keyActiveGroupId`, alive stamp, pending SOS store). | By design. | Verified | device K1-K5 |

### Ride lifecycle

| Id | Sev | Issue | Fix | Status | Test |
|---|---|---|---|---|---|
| L-01 | Medium | No guard against a double tap on "Start ride" / "Join": two requests could be on their way; two rides could be created and the rider left in both (the phone shows the last answer). | One create and one join at a time in `ConvoyService`: the second call gets the first call's result. | Fixed | read; device K6 |
| L-02 | Info | Leave is safe against a second tap (state cleared before the request) and an undelivered leave is replayed before the next create / join. | | Verified | read |
| L-03 | Info | Reconnect: quick first retry, then full-jitter backoff capped at 10 s (`ReconnectPolicy`); outbox and pending SOS are replayed in order with the same `clientId` (the gateway ignores repeats). | | Verified | read |
| L-04 | Low | "Stopped since" for the idle GPS profile uses the wall clock: a clock set back mid-ride delays the idle profile (battery only). | Not changed (no safety effect). | Open | |

### Crash detection, SOS, lock screen

| Id | Sev | Issue | Fix | Status | Test |
|---|---|---|---|---|---|
| C-01 | Info | Regression check after rounds 3-5 and this round: crash detector, false-positive guards, sensor safety, lock-screen cockpit policy, Ride AOD, screen-awake policy. No SOS / crash / emergency-text / Medical ID / ride-lock code was changed in this round; the private-places and GPS-gate code is not consulted by `SafetyService`. | | Verified | 107 tests pass here (see notes) |
| S-01 | Medium | Locked cockpit: "Call" on the ride safety cards, the incident banner, the safety card and the rider card dialled straight from a locked phone. | `callFromCockpit` + `LockScreenCockpitPolicy.callNeedsUnlock`: emergency lines always; the rider's own emergency contact while the rider's own SOS / crash alarm is open; every other number after the phone's unlock. The SOS sheet itself is never held back. | Fixed | `test/lock_call_rule_356_test.dart` (7) |

### Memory and performance

| Id | Sev | Issue | Fix | Status | Test |
|---|---|---|---|---|---|
| P-01 | Medium | Every incoming rider position told every listener (cockpit, safety checks, notification) separately; a `RIDER_UPDATES` batch frame of N riders caused N notifications in one turn. | State is updated at once; listeners are told once per turn (`_notifyRidersSoon`). A rider who **joined** still notifies immediately. | Fixed | read; device K7 |
| P-02 | Low | The cockpit screen watches `ConvoyService` as a whole and rebuilds on every own fix (1-2 per second). | Not changed: needs profiling on a device before splitting a 4,400-line screen. | Open | |
| P-03 | Low | Five screens create a `MapController` and never dispose it (map picker, trip route map, cockpit, replay, planner). | Not changed without a device run (dispose order with flutter_map 8). | Open | |
| P-04 | Info | Timers, stream subscriptions and controllers: scripted scan over `lib/` found no periodic timer or subscription without a cancel (five scan hits were multi-line false positives, checked by hand). | | Verified | scan |

### Error handling

| Id | Sev | Issue | Fix | Status | Test |
|---|---|---|---|---|---|
| E-01 | Info | Crash reporting without third parties exists: guarded zone, `FlutterError.onError`, `PlatformDispatcher.onError` and an isolate error listener write to the diagnostics log (redacted, `DiagLog.caught`); native crashes are merged at next start. Nothing to add. | | Verified | read |
| E-02 | Info | Every HTTP call has a timeout (ApiClient `_send`, bytes calls, tile fetches, push unregister). | | Verified | grep |
| E-03 | Medium | Website `/account`: the header picture was an `<img src="/api/avatars/...">`; that route needs the Bearer header, so the picture never loaded. | Fetched with the header and drawn on a canvas. | Fixed | Playwright screenshot |
| E-04 | Low | Profile: an exception while choosing a picture could leave the camera button "busy". | `try / finally`. | Fixed | read |

### Privacy and compliance

| Id | Sev | Issue | Fix | Status | Test |
|---|---|---|---|---|---|
| S-02 | Medium | The risky-stretch counts took hard brakes from every rider, without the road-data opt-in. | App queues and sends only with "Help make roads safer"; the gateway stores nothing without it. Warnings unchanged. | Fixed | `gateway/test/group_safety_355.test.js`, `round6_wiring_356_test.dart` |
| S-03 | Medium | Route weather used Open-Meteo's free API, which is for non-commercial use only. | MET Norway is the default provider (`WEATHER_PROVIDER=metno`), with their User-Agent, caching and credit rules. | Fixed | `gateway/test/weather_met_356.test.js` (6) |
| S-04 | Info | The new cropper is not FLAG_SECURE (your own public picture); FLAG_SECURE stays on sign-in, 2-step, ride lock and Medical ID. | | Verified | `avatar_crop_screen_356_test.dart` |

### Accessibility (gloves, sunlight)

| Id | Sev | Issue | Fix | Status | Test |
|---|---|---|---|---|---|
| A-01 | Low | Map buttons on the ride screen were 44 dp: zoom in, zoom out, map orientation, places. | 48 dp. | Fixed | read |
| A-02 | Low | Top bar of the cockpit: the back / navigation square is 40 dp. | Not changed: the bar's height is fixed around it; needs a layout check on a device. | Open | |

## TODO / FIXME / follow-up sweep (pending item g)

`lib/` holds no TODO, FIXME, XXX or HACK. Every "follow-up" comment describes work that is done. Open follow-ups in
`docs/features_355`: translations of the newer Settings / Ride screen texts (`lock_screen_cockpit.md`, P2, listed
in `docs/handbook/users/translations_needed.md`; needs a translator) and the owner decisions in
`docs/security/SECURITY_AUDIT_v3.55.md`. This round adds English-only texts as well (cropper, private places).

## What was not possible here

* `flutter test`, a build and a device run (no Flutter / Android SDK): widget tests were written but not run, Kotlin
  was reviewed by hand (`ImageEncodeChannel.kt`, 60 lines, framework APIs only).
* A live call to api.met.no (the workspace proxy refuses the host): the parser is tested against a fixture written
  from MET's documented data model; run the smoke check in `ROUND6_APP_NOTES.md` after deploy.
