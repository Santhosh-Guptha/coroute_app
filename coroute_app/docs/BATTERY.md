# CoRoute battery, always-on ride screen, lock screen and notifications

Owner: Agent 4. Code: `lib/domain/tracking/battery_saver.dart`, `lib/domain/tracking/screen_awake_policy.dart`,
`lib/domain/notify/ride_notification_content.dart`, `RideNotification.kt`, `UrgentAlertActivity.kt`.
Tests: `test/battery_saver_test.dart`, `test/screen_awake_policy_test.dart`, `test/ride_notification_content_test.dart`,
`test/ride_notification_service_test.dart` (Agent 4 group).

The mAh figures below are **engineering estimates** for a typical 2024-2026 Android phone (6.5" OLED,
4,500-5,000 mAh, 4G), not measurements. Confirm them on a real device (see "How to measure").

## 1. What runs during a ride (audit)

| Consumer | Screen on, riding | Screen off / background | Battery saver |
|---|---|---|---|
| GPS (`LocationCadence`, speed bands) | stopped 3 s / town 1 s / road 1 s / highway 0.5 s, navigation grade | same stream (foreground service keeps it); parked > 60 s: idle plan 20 s / 25 m | low-battery table: 5 / 2 / 2 / 1 s, high (not navigation) precision; parked after 30 s: 45 s / 40 m |
| Follow camera (`NavCameraController`) | **30 fps cap** (was 60), stops as soon as the camera has settled | **0 fps**: ticker stopped (`setForeground(false)`) | **15 fps** |
| Compass (`flutter_compass`) | only while the map is on screen and GPS heading is not usable (slow / stopped) | off | same |
| Accelerometer / gyro (crash detection) | 50 Hz with a 2 s hardware FIFO batch, only while crash detection is armed | same (needed for crash detection); bounded partial wakelock (30 min, renewed every 10 min while armed) | unchanged (safety) |
| WebSocket | server ping every 30 s, stale check every 40 s | same | unchanged (safety) |
| Telemetry (own position to the group) | 1-2.5 s by speed band, 30 s heartbeat parked | same | data-saver cadence: **5 s** moving (never slowed during an open emergency) |
| Track upload | every 60 s or 120 points, batched | same | same |
| Ride notification | at most one update per **10 s**, only when the text changed; emergencies at once | same | 20 s |
| Dead reckoning timer (1 Hz) | only does work while GPS is lost (tunnels) | **skipped while parked** (new) | same |
| Map tiles | on demand; route prefetch on Wi-Fi only | none | prefetch paused |
| Timers | status 10 s, alert reconcile 30 s, battery read 60 s, mesh prune 5 s (only with the offline mesh on), service isolate 10 s | same | same |
| Screen wakelock (`WakelockPlus`) | only with the ride screen in front | released | released when parked > 5 min or < 15 % |
| TTS engine | initialised lazily, released with the engine | idle | idle |
| Microphone / audio session | **off** unless push-to-talk is held or VOX is on | same | same |
| Bluetooth | only with a BLE remote / helmet paired by the rider | same | same |

## 2. Changes made (estimated impact)

| Change | Where | Estimated saving |
|---|---|---|
| Follow camera capped at 30 fps while riding (was 60 fps), 15 fps in battery saver, 0 when settled / background / screen off | `nav_camera_controller.dart`, `BatterySaverProfile.cameraFrame` | 60 -> 30 fps: **~40-80 mAh/h** (GPU + raster thread); 30 -> 15 fps: a further ~20-40 mAh/h |
| Ride screen dims to 12 % window brightness after 30 s without a touch (any touch restores it) | `ScreenAwakePolicy`, `SafetyChannel.windowBrightness` | OLED at outdoor brightness ~250-400 mA vs dimmed ~60-100 mA: **~150-250 mAh/h** while untouched |
| Screen keep-on released when parked > 5 min or battery < 15 % (not charging), with a "why" toast | `ScreenAwakePolicy`, cockpit `_evaluateAwake` | **~200-350 mAh per parked hour** (the screen sleeps normally) |
| Battery saver (switch in Settings > Maps, automatic at <= 20 %, off again at >= 25 % or charging) | `BatterySaverPolicy`, `ConvoyService.batterySaverActive` | GPS low-battery table ~10-20 mAh/h; telemetry 5 s ~20-40 mAh/h (fewer radio wake-ups); 15 fps ~20-40 mAh/h; dark map on OLED ~40-100 mAh/h with the screen on. **Total ~90-200 mAh/h** |
| Dark ride theme / dark map forced in battery saver | `ThemeController.setRideDarkOverride` | included above |
| Dead reckoning 1 Hz tick skipped while parked | `ConvoyService._onDeadReckoningTick` | ~1-3 mAh/h (CPU wake-ups) |
| Ride notification content redesigned; still at most one push per 10 s (20 s in saver), not per fix | `RideNotificationService`, `RideNotificationThrottle` | ~5-10 mAh/h vs per-fix updates |
| Tile prefetch and offline mesh follow battery saver too | `ConvoyService._applyLowBatteryPolicy` | ~5-30 mAh/h depending on the mesh |

Rough whole-ride picture (screen on, group ride, 4G): before ~650-900 mAh/h; after with the screen
mostly untouched ~450-650 mAh/h; battery saver on top ~350-500 mAh/h; screen off in the pocket (GPS +
crash sensor + socket + telemetry) ~120-200 mAh/h, unchanged by design except for the parked tick.

Not reduced on purpose: crash detection sampling, the SOS path, alert sounds, the WebSocket, and the
fast telemetry cadence while an emergency is open.

## 3. Always-on ride screen

* Riding with the ride screen in front: the window keep-screen-on flag (`WakelockPlus`) as before.
* No touch for 30 s: CoRoute's window brightness goes to 12 % (Android `WindowManager.LayoutParams.screenBrightness`;
  iOS `UIScreen.brightness`, restored afterwards). The system brightness setting is never changed, no
  WRITE_SETTINGS permission.
* Keep-on is turned off, with a short message on the ride screen, when parked for more than 5 min
  ("Screen can sleep: parked over 5 min. The ride keeps running.") or below 15 % battery and not charging.
  Moving again turns it back on.
* An open emergency (any open alert, the SOS hold screen) keeps the screen on at full brightness.
* Background ride: unchanged; the foreground service keeps GPS, crash detection and the socket running.

## 4. Ride notification (Android)

* Ongoing, on the existing low-importance channel `coroute_convoy` (no sound), same id as the foreground service.
* Title: `Riding with <group>` or `Solo ride`. Text: `speed • distance • next stop, ETA` (e.g.
  `42 km/h • 12 km • Kolar fuel stop, ETA 4:35 PM`); next planned stop, else the destination.
* Buttons: **SOS** (big, solid red, opens the hold-to-send screen over the lock screen, never sends by itself),
  **Talk** (group rides; the plan gate is the `talkAllowed` hook of `RideNotificationService`, null = shown for
  group rides; when it is false the free slot shows **Wait**), **End ride** (solo) / **Leave** (group): opens the
  app's confirm (needs unlock), never ends anything by itself. During an emergency: SOS / Map / Navigate or I can help.
* Medical ID badge row (only what the rider entered: name, blood group, allergies, emergency contact): tap opens
  the ICE card over the lock screen. It is also the public (lock screen) text when ride details are hidden.
* Updates: at most one per 10 s (20 s in battery saver), only when the visible text changed; a change of
  emergency state is pushed at once.
* Alerts: another rider's SOS is posted natively on the high-importance `coroute_sos` channel with a full-screen
  intent to `UrgentAlertActivity` (shows over the lock screen, names only, "Open CoRoute" asks for the unlock,
  "Close" silences). Android 14+ without "Allow full-screen notifications": a heads-up notification instead
  (checked with `NotificationManager.canUseFullScreenIntent`). The crash alarm keeps its full-screen
  notification on `coroute_crash`; fuel-low and safety prompts stay on the high-importance `coroute_safety`.
  The pre-ride checklist already offers the Android 14 permission page ("Alarm on lock screen").

## 5. Lock screen and Medical ID

* Crash countdown: full-screen alarm over the lock screen (unchanged) with I'm OK / Need help buttons that work
  without unlocking.
* Ride notification SOS from the lock screen: SOS -> `RideSosActivity` trampoline -> hold-to-send screen over the
  lock screen (hold to confirm, cannot be pocket-triggered).
* Medical ID: **always available**, no on/off switch. Shown by default on the lock screen during rides (ride
  notification badge and public text), via the quick settings tile, and in full during the rider's own SOS.
  Riders control it by editing or clearing their medical info in the profile; signing out clears the copy the
  tile reads. No position or location history is ever on the lock screen.
* Removed switch: Settings > Ride safety > "Show my medical ID on the lock screen during an SOS"
  (`safety_settings_sheet.dart`); `SettingsService.medicalIdOnLockScreen` is now always true and
  `setMedicalIdOnLockScreen` is gone. The profile <-> lock screen copy is kept in step by `MedicalIdLockSync`.
* Kept on purpose (data sharing consent, not Medical ID visibility): "Share medical info with a responder"
  (profile form, riders-helping-riders consent sheet, Settings > Nearby). These send health data to riders of
  other groups over the network and stay opt-in.

## 6. iOS

| Android behaviour | iOS equivalent | Gap |
|---|---|---|
| Full-screen SOS / crash alarm | Time-sensitive notifications (`InterruptionLevel.timeSensitive`) for SOS, crash and safety prompts | Critical alerts (sound in silent mode / Focus) need Apple's critical-alerts entitlement, which CoRoute does not have. Time sensitive also needs the "Time Sensitive Notifications" capability enabled on the Runner target (signing change, not done here). |
| Ongoing ride notification with buttons | Regular notification, `.passive` (never lights the screen), actions SOS / Talk / End ride / Leave / Wait / Map | Not truly ongoing (can be swiped away); no custom layout; no Medical ID row. |
| Window dimming | `UIScreen.brightness` (whole screen), restored on touch / exit | Changes the device brightness while CoRoute is in front. |
| Medical ID quick settings tile / ICE card over the lock screen | None (Apple's Health Medical ID is the iOS place for it) | Riders should fill in Health > Medical ID; the app does not link to it yet. |
| Lock-screen Live Activity | Not done (out of scope) | Needs an ActivityKit widget extension. |

## 7. How to measure (real device)

1. `adb shell dumpsys batterystats --reset`, unplug, ride 60 min (or replay a GPX with the screen on).
2. `adb bugreport` -> Battery Historian: compare `screen`, `gps`, `cpu` and `mobile radio` for CoRoute.
3. Repeat with Battery saver on, and with the phone in the pocket (screen off).
4. Profile the map with `flutter run --profile` + DevTools: frame rate must be <= 30 fps riding, 15 fps in
   battery saver, and 0 (no frames) once the camera settles or the screen is off.
