# Play Store permissions & Data safety (release checklist)

Source of truth: `android/app/src/main/AndroidManifest.xml` and `ios/Runner/Info.plist`.
Keep this file in step with them. Last reviewed: 2026-11-06.

## 1. Android permissions

| Permission | Why CoRoute needs it | Asked when | Play Console action |
|---|---|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | Convoy sync, SOS delivery, map tiles; network type for tile cache and the phone check | Install time | none |
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | Live position for the group; exact place in an SOS / crash alert | Onboarding, phone check | none |
| `ACCESS_BACKGROUND_LOCATION` | Keep sharing if Android restarts CoRoute in the background during a ride | After the in-app prominent disclosure (permissions screen, phone check fix) | **Location permissions declaration + video** (see 4) |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` | Ride service (type `location`): GPS, convoy link and crash detection with the screen off | Ride start | **Foreground service declaration: location** |
| `FOREGROUND_SERVICE_MICROPHONE` | Same service gets type `microphone` only while the intercom is on (started in the foreground, RECORD_AUDIO granted) | Intercom on | **Foreground service declaration: microphone** |
| `RECORD_AUDIO` | Push-to-talk / hands-free intercom; 1 s microphone test in the phone check (bytes counted, nothing kept) | First Talk, phone check | none |
| `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH_CONNECT` | Route voice alerts and intercom to a Bluetooth helmet headset (SCO) | Phone check / settings | none |
| `POST_NOTIFICATIONS` | Ride notification, crash alarm, SOS and group alerts (Android 13+) | Onboarding, phone check | none |
| `POST_PROMOTED_NOTIFICATIONS` (lock-screen cockpit round) | Android 16+: the ride notification as a **Live Update** (promoted ongoing notification: status bar chip, lock screen, always-on display) with the next turn or the group status (`RideNotification.kt`, docs/features_355/lock_screen_cockpit.md) | Install time (normal permission); riders can turn Live Updates off for CoRoute in Android settings | none |
| `USE_FULL_SCREEN_INTENT` | Crash alarm over the lock screen so the rider can cancel without unlocking | Android 14+: phone check sends rider to the system page | **Full-screen intent declaration** (category: alarm / safety). Android 14+ may deny it by default; app falls back to a heads-up notification |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | OEMs kill multi-hour rides; asked once from phone check / checklist | User taps "Allow" | Be ready to justify (core safety function stops otherwise). Remove if Play rejects; phone check still links to the battery settings page |
| `WAKE_LOCK` | Motion sensor keeps running in deep sleep during a ride (bounded, renewed every 10 min) | none | none |
| `VIBRATE` | Crash alarm and alert haptics | none | none |
| `RECEIVE_BOOT_COMPLETED` | flutter_local_notifications re-schedules plan expiry reminders; 3.57: `EmergencyTextReceiver` resumes emergency texts still waiting | none | none (the ride service has `autoRunOnBoot: false`) |
| `SEND_SMS` (3.57) | Phone-first emergency texts: an SOS or an unanswered crash alarm texts the rider's emergency contacts from their own SIM without a tap, "safe now" when closed (`EmergencyTexts.kt`) | Runtime, after the in-app disclosure (`EmergencyTextsDisclosure`: contact form once, permissions screen, Safety health) | Permissions Declaration Form, "Physical safety / emergency alerts" + video 2 (`docs/handbook/compliance/play_store_compliance.md` 3a/3b). Denied: the messages app opens prefilled (`SmsComposer`) |

`<uses-feature android:name="android.hardware.telephony" android:required="false"/>`: tablets without a SIM stay eligible.

Removed / not used:
- `READ_SMS`, `RECEIVE_SMS`, `READ_PHONE_STATE` are **not** declared: the default SMS SIM is used
  without listing SIMs, and no message is ever read.
- `BLUETOOTH_SCAN` is not declared; the app no longer asks for it (it made Bluetooth always look "denied").
- `HIGH_SAMPLING_RATE_SENSORS` not needed: crash detection samples at 50 Hz (cap 200 Hz).
- `FOREGROUND_SERVICE_HEALTH` not needed: sensors run inside the `location` service.

Exported components: only `MainActivity` (launcher + deep links) and `MedicalTileService`
(protected by `BIND_QUICK_SETTINGS_TILE`). Everything else is `exported="false"`.

`<queries>`: tel/sms/geo/https/upi/navigation schemes, Organic Maps, TTS engines, and
`SENDTO smsto:` / `DIAL tel:` (phone check looks for a messages and phone app).

## 2. iOS Info.plist

| Key | Purpose string covers |
|---|---|
| `NSLocationWhenInUseUsageDescription` | position shared with the convoy |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | sharing with the screen off during a ride |
| `NSLocationTemporaryUsageDescriptionDictionary` → **`PreciseRiding`** | one-time precise location (`Geolocator.requestTemporaryFullAccuracy(purposeKey: 'PreciseRiding')`) |
| `NSMicrophoneUsageDescription` | intercom |
| `NSMotionUsageDescription` | crash detection (future CoreMotion use; harmless today) |
| `NSBluetoothAlwaysUsageDescription` | helmet headset / remotes (permission_handler Bluetooth request needs it) |
| `NSSpeechRecognitionUsageDescription` | voice commands (remove if speech recognition is not shipped) |
| `UIBackgroundModes` | `audio`, `location` |
| `LSApplicationQueriesSchemes` | `sms`, `tel`, `om`, `googlechromes`, `comgooglemaps` |

`ios/Podfile` enables permission_handler macros `PERMISSION_LOCATION`, `PERMISSION_MICROPHONE`,
`PERMISSION_NOTIFICATIONS`, `PERMISSION_BLUETOOTH` (without them every iOS permission reads "denied").
Crash detection is Android-only for now (the phone check says so on iPhone).

## 3. Data safety form (answers)

Data is encrypted in transit (HTTPS only, `usesCleartextTraffic=false`). Riders can ask for deletion
(confirm the account-deletion path/URL before submitting). No data is sold. No ads SDK.

| Data type | Collected | Shared* | Optional? | Purpose | Notes |
|---|---|---|---|---|---|
| Location: precise & approximate | Yes | No | Required for rides | App functionality, safety | Live position to own group; SOS/crash position to group and emergency contacts; ride tracks if saved |
| Personal info: name, email | Yes | No | Required (Google sign-in) | Account management, app functionality | |
| Personal info: phone number | Yes | No | Optional | App functionality (SOS, group contact) | Rider's own number |
| Personal info: other (emergency contact name/number) | Yes | No | Optional | Safety (SOS texts/calls) | Entered by the rider |
| Health info (blood group, medical notes) | Yes | No | Optional | Safety (ICE card, SOS) | Shown to own group during an SOS |
| Audio: voice | Yes, processed ephemerally | No | Optional | App functionality (intercom) | Streamed live, not stored. Phone-check mic test never leaves the phone |
| Financial info: purchase history | Yes | No | Optional | Subscription | Card/UPI data handled by Razorpay (check Razorpay SDK's own disclosure) |
| App info & performance: diagnostics | Yes | No | Optional (explicit consent) | Analytics / support | Phone-check report: model, OS, check results. No IMEI/serial/recordings/location trail |
| Device or other IDs | No | | | | |
| Photos | Yes | No (review photos reach the website only after consent and admin approval) | Optional | App functionality | Profile picture (the round picture plus a private copy of the chosen picture for later adjusting, round 6) and trip / place review photos. EXIF removed. See docs/handbook/compliance/play_store_compliance.md |
| Messages / contacts / files | No | | | | Emergency texts are sent by the rider's phone to the contact the rider chose (SEND_SMS); no message is read or uploaded |

*Transfers to the rider's own group or emergency contacts are user-initiated (exempt); SMS/
maps providers act as service providers.

## 4. Declarations to file in Play Console

1. **Background location**: feature = "share live position with your riding group and alert them
   after a crash during an active ride". Video: start ride → disclosure dialog → "Allow all the time"
   → lock phone → position keeps updating on a second phone. Decision pending: the ride foreground
   service (type `location`) already covers screen-off tracking; if Play rejects, remove
   `ACCESS_BACKGROUND_LOCATION` and set `locationAlways` to `required: false` in `PermissionsService`.
2. **Foreground service types**: `location` (ride tracking + crash detection, user-started),
   `microphone` (intercom, user-started). Video of each.
3. **Full-screen intent**: crash alarm (safety alarm) with countdown and "I'm OK".
4. **Battery optimisation exemption** justification (if asked).

## 5. Build / release notes

- 3.54: `targetSdk = 36` is pinned (Play requires API 36 for updates from 31 Aug 2026); compileSdk
  stays 37. Run the edge-to-edge / predictive-back checks.
- 3.54: a release assemble/bundle **fails** when `key.properties` / `COROUTE_*` env vars or the
  keystore are missing; it never signs with the debug key.
- 3.54: `<queries>` declares `android.media.action.IMAGE_CAPTURE` for the image_picker camera (no
  CAMERA permission). Full checklist: [PLAYSTORE_RELEASE_CHECKLIST_v3.54.md](PLAYSTORE_RELEASE_CHECKLIST_v3.54.md).

## 6. Must be tested on a real device before release

- Crash detection with the screen off for > 30 min (wake-lock renewal), on Xiaomi/Samsung/Oppo/Vivo.
- Phone check on Android 12, 13, 14, 15/16: sensor rates, headset detection (SCO vs A2DP), DND,
  "Background use" restricted, precise-location upgrade dialog, full-screen intent page.
- Offline SOS: airplane mode + SIM → after 45 s (app in foreground) the messages app opens with
  all recipients; Samsung (comma separator) and Pixel (semicolon).
- Bystander voice beacon when a Bluetooth helmet headset is connected (may play inside the helmet).
- iOS: permission prompts appear after `pod install` with the new Podfile macros; precise-location
  prompt shows the `PreciseRiding` text.
