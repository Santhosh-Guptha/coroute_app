# Cockpit on the lock screen + Ride AOD (app build 3.55.0+10025, not released)

Owner request: "what about the always on display and even if screen was locked also we should show our cockpit
screen".

Two parts:

1. **Cockpit on the lock screen while riding.** During a ride, pressing power (or the phone locking by itself)
   brings the ride screen straight back when the screen wakes, without unlocking. Private things still need the
   fingerprint or PIN.
2. **Ride AOD.** Apps cannot draw on the system always-on display, so:
   - (a) an OLED-friendly "Ride AOD" view inside the app replaces the plain dim after 30 s without a touch, and
   - (b) on Android 16 the ride notification becomes a **Live Update** (status bar chip, top of the lock screen,
     and the AOD on phones that show promoted notifications there).

## 1. Cockpit over the keyguard

### When

`LockScreenCockpitPolicy.showOverKeyguard` (pure, `lib/domain/security/lock_screen_cockpit_policy.dart`):

| Condition | Source |
|---|---|
| A ride is on, solo or group | `RideSafetyState.rideActive \|\| inConvoy` (the SessionGuard probe: SafetyService.rideOn, ConvoyService.activeConvoy) |
| Someone is signed in | `AuthService.isAuthenticated` |
| Setting "Show cockpit on lock screen while riding" is on (default) | `SettingsService.rideOnLockScreen` |
| The cockpit is in front | the ride screen is the visible tab of an active ride, and no private screen the rider opened after unlocking is above it (safety screens and screens waiting for the unlock do not count) |

All four true: `MainActivity` gets `setShowWhenLocked(true)` (API 27+; `FLAG_SHOW_WHEN_LOCKED` below) through
`coroute/ride_window` → `RideWindowChannel.kt` → `LockWindow`. Any of them false: off at once (ride ended,
signed out, setting off, rider in a private screen). The Flutter engine going away (`cleanUpFlutterEngine`) also
turns it off natively.

**Never** `turnScreenOn` for this: the screen wakes only by the rider (power button, double tap) or by the existing
SOS / crash paths (`LockWindow.setAlarm`, unchanged behaviour: over the keyguard + screen on + keep on).
`LockWindow` owns both reasons, so closing the SOS screen no longer clears the cockpit's flag and the end of a ride
never hides an open crash alarm.

A private screen in front when the phone locks (rider unlocked earlier and opened chat) means the normal keyguard
shows, by design: nothing private is ever shown over the keyguard.

### Locked mode

`locked = overKeyguard && KeyguardManager.isKeyguardLocked`. The keyguard state is pushed to Dart
(`onKeyguardChanged`): checked on screen on (now, +400 ms, +1200 ms), screen off (+600 ms), user present (unlocked),
`onResume` and window focus changes (the system unlock sheet).

| Allowed without unlock | Needs the unlock (`KeyguardManager.requestDismissKeyguard`, the action continues on success) |
|---|---|
| Live cockpit: speed, navigation, ETA, group on the map, convoy status, alerts (siren yield, crash countdown, SOS of others) | Chat (message text), profile, settings, ride history, clubs, account |
| SOS hold, "I'm OK", Call 112, Medical ID | Search / route editing, ending or leaving the ride, admin |
| Mute / unmute voice, Talk (audio only, as on the lock-screen notification) | Calling anyone but 112, sharing a live link or the invite |
| "New message from `name`" (no text) | Any other screen, sheet or dialog opened from the cockpit |

How it is enforced (one place, no per-button lists to forget):

- **Screens**: `LockedRouteGuard` (a NavigatorObserver on the app's navigator, owned by
  `LockScreenCockpitService`) sees every route pushed above the cockpit. Safety routes are allowed by name
  (`safety/sos_hold`, `safety/crash_alarm`, `safety/emergency_sos`) or while an SOS flow is open
  (`SosHoldScreen.isOpen`, `EmergencySosSheet.isShowing`, crash alarm open) so their own dialogs work. Anything else
  pushed while locked is **pending**: `LockedCockpitGate` covers it ("Unlock to open this" / "Back to ride").
  For the rider's own tap (a pointer down within 2 s) the unlock is asked at once; a screen that opens by itself
  waits for the rider. Unlock succeeds: the screen shows (the action continues). Cancelled: the screen is removed
  again (its caller gets null, as for Back).
- **Non-screen actions** (share ETA, share invite, copy code): `LockedCockpit.run(context, CockpitAction.x, fn)`.
- **Chat**: the cockpit's chat card uses `LockScreenCockpitPolicy.chatBanner` (locked: title
  "New message from `name`", no text).
- **Back**: `RiderHomeScreen`'s PopScope does nothing while locked (no minimise, no tab switch). During a ride the
  shell shows no bottom bar on the Ride tab, so there is nothing else to navigate to.
- **Padlock chip** at the top: "Locked: unlock to open more". Tapped: Unlock, Call 112 (`tel:112`, the dialer may
  ask for the unlock on some phones, as from the Medical ID card), Medical ID (`MedicalIdActivity`, already
  `showWhenLocked`). Hidden on the black Ride AOD.
- **End-of-ride prompts** wait for the unlock: a ride that ends takes the window off the keyguard at once, so the
  wrap-up / review sheets are seen after the rider unlocks (a sheet pushed in the same instant is pending and
  shows after the unlock).

### App lock interplay

The fingerprint app lock (`AppLockPolicy.exempt`) never locks while a ride or convoy is on, which is exactly when
the cockpit may be over the keyguard (test: `lock_screen_cockpit_policy_test.dart`, "never fights the app lock").
`LockedCockpitGate` sits above `AppLockGate` and hides itself while the app lock screen shows. After the ride the
window leaves the keyguard and the app lock's normal rules apply again (the app went to the background behind the
keyguard, so the resume check runs).

### Setting

Settings › **Ride screen** › "Show cockpit on lock screen while riding", default **on**, hint: "Your ride screen
comes back when you wake the phone, without unlocking. Private things need your fingerprint or PIN."
Stored under the existing key `coroute_ride_lock_screen` (3.54 "Show ride on lock screen"). It left the 3.55
always-on list: no migration rewrites it, so a 3.54 choice stays (3.55 is unreleased, so the v1 step never forced it
on a rider's phone). The ride notification and its SOS button stay public on the lock screen whatever this setting
says (3.55 owner decision): `lockScreenPublic` is always true.

## 2a. Ride AOD (in the app)

`ScreenAwakePolicy.decide` (pure, `lib/domain/tracking/screen_awake_policy.dart`), view
`lib/presentation/rider/widgets/ride_aod_view.dart`.

- After **30 s** without a touch (or an alert) while the screen is kept on: Settings › Ride screen › **When idle**:
  - **Ride AOD** (default): pure black, window brightness 0.03; large speed, next turn arrow + distance (from the
    route steps, `NextTurn`), leader distance + arrow (or "3 of 5 riding"), time, battery, "Hold SOS" (long press
    opens the hold-to-send screen; the hint does not wake the cockpit on touch so it can be held). A tap anywhere
    else brings the full cockpit back.
  - **Dim**: the cockpit at window brightness 0.12 (the earlier behaviour).
  - **Let the screen sleep**: keep-on released; the phone's own timeout takes over; power brings the cockpit back
    over the keyguard.
- **Burn-in**: the AOD content moves by up to 6 px once a minute (`burnInShift`, 10-step cycle).
- **Alerts wake the full cockpit at normal brightness**: an open emergency (SOS of others, own SOS / crash countdown)
  forces full; a new important / critical card (off-route, regroup, hazard, group safety) or a siren counts like a
  touch (`lastAlertMs`).
- **Keep screen on**: "Only while moving" (default; a stop longer than **2 min** lets the screen sleep, "Press power
  to see your ride") or "Always during a ride" (stays on at stops). The parked rule (5 min) and the battery rule
  apply in both.

## 3. Battery and heat

| Rule | Result |
|---|---|
| Battery < 15 % and not charging | keep-on off, notice "Screen can sleep: battery below 15%. The ride keeps running." (unchanged) |
| Thermal status severe (3) | Ride AOD after 10 s instead of 30 s (Dim becomes AOD; Sleep stays sleep), notice "Phone is hot: ride screen simplified to cool it down." |
| Thermal status critical or worse (4+) | keep-on off, notice "Phone is too hot: screen can sleep. The ride keeps running." |
| Open emergency | always full screen, whatever the battery or heat |

Thermal status: `PowerManager.getCurrentThermalStatus` + `addThermalStatusListener` (API 29+, 0 below).

Battery estimates shown in the Settings hints (`RideScreenBattery`, to be confirmed by the device measurement in
the QA list): screen on "about 6–10% per hour with the screen on"; Ride AOD "about 2–4% per hour on OLED screens";
Dim "about 3–6% per hour"; Sleep "no screen cost while it sleeps". These are on top of the ride itself (GPS and the
group link).

## 2b. Android 16 Live Update (system lock screen / AOD)

Status: **shipped behind `Build.VERSION.SDK_INT >= 36`**, compiled against the project's compileSdk 37.

- Dart (`RideNotificationService`) adds `live` to the ride notification args in normal ride mode
  (`LiveUpdateContent`): title = next turn and distance ("Turn right in 400 m") or the group status ("Arjun 1.2 km
  ahead" / "You lead · 4 riders"), text = road or "Pack #2 of 4", chip (≤ 7 characters, e.g. "400 m"), route
  progress 0–100.
- Kotlin (`RideNotification.buildLiveUpdate`): framework `Notification.Builder` (the app has no NotificationCompat
  dependency; androidx.core is only a transitive plugin dependency and was **not** bumped). Standard template, no
  custom views, not colorized, ongoing, `Notification.EXTRA_REQUEST_PROMOTED_ONGOING` ("android.requestPromotedOngoing")
  in the extras, `Notification.ProgressStyle` (route progress) or BigTextStyle, `setShortCriticalText` (chip),
  actions SOS / Talk / Mute / Map (at most three, SOS first). The Android 16 methods
  (`canPostPromotedNotifications`, `ProgressStyle`, `setShortCriticalText`) are called by reflection, so the code
  does not depend on the exact compile SDK and falls back to BigTextStyle when one is missing.
- Posted only when `NotificationManager.canPostPromotedNotifications()` is true (the rider can turn Live Updates off
  for CoRoute) and the channel is above `IMPORTANCE_MIN`; otherwise the full custom notification as before.
  Emergencies, assists and hazards always use the full notification.
- Manifest: `android.permission.POST_PROMOTED_NOTIFICATIONS` (normal permission).
- Older Android: unchanged (public lock-screen version without private data when the visibility is private).
- Play policy: no `USE_FULL_SCREEN_INTENT` for the cockpit or the Live Update; it stays limited to the crash alarm
  and another rider's SOS (docs/handbook/compliance/play_store_compliance.md).

Samsung One UI 8 shows promoted notifications in the **Now Bar** on some models; not verified (device QA).

## Files

- Domain: `lib/domain/security/lock_screen_cockpit_policy.dart`, `lib/domain/tracking/screen_awake_policy.dart`
  (AOD, thermal, keep-on modes, burn-in, battery estimates), `lib/domain/route/next_turn.dart`,
  `lib/domain/notify/live_update.dart`.
- Data: `lib/data/services/lock_screen_cockpit_service.dart` (service + `LockedRouteGuard`),
  `lib/data/services/ride_window_native.dart`, `SettingsService` (`rideOnLockScreen` is a switch again,
  `rideIdleMode`, `keepScreenOnMode`), `RideNotificationService` (`live` args, `lockScreenPublic` always true).
- Presentation: `lib/presentation/security/locked_cockpit_gate.dart`, `lib/presentation/rider/widgets/ride_aod_view.dart`,
  `live_cockpit_map_screen.dart` (reports itself, AOD, alerts, chat line, guarded shares), `rider_home_screen.dart`
  (Back), `settings_screen.dart` (Ride screen section), `sos_hold_screen.dart` / `crash_alarm_host.dart` (route
  names), `emergency_sos_sheet.dart` (`isShowing`), `main.dart` (provider, observer, gate, wiring).
- Android: `RideWindowChannel.kt` (new: `LockWindow` + channel), `MainActivity.kt`, `SafetyChannel.kt` and
  `RideNotification.kt` (through `LockWindow`; Live Update), `AndroidManifest.xml`.
- Tests: `lock_screen_cockpit_policy_test.dart`, `ride_aod_policy_test.dart`, `next_turn_live_update_test.dart`,
  `settings_lock_cockpit_migration_test.dart`, `locked_cockpit_gate_test.dart`, `ride_aod_view_test.dart` (plus
  updated settings / notification tests).

## Follow-ups

- Translations: the new Ride screen texts and the chip are English only (like the rest of Settings); listed in
  `docs/handbook/users/translations_needed.md` (P2).
- Device QA list: docs/NEXT_AGENT_PROMPT_v3.55_round3.md §8.
