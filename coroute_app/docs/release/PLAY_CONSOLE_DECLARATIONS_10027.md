# Play Console declarations checklist: release 3.55.0+10027

Do these in Play Console > App content (and Policy > App content > Sensitive permissions) **before promoting 10027
beyond internal testing** (plan section 6/7). Texts are ready to paste; replace nothing unless the app changed.
Source of truth for older answers: [../handbook/compliance/play_store_compliance.md](../handbook/compliance/play_store_compliance.md)
(sections 2, 3, 3a, 3b). Permission decisions for this build: [R8_KEEP_RULES_v3.57.md](R8_KEEP_RULES_v3.57.md) section 3.

All videos: screen recording of the Play-signed internal-testing build, phone language English, no real personal
data on screen (team phone numbers and test accounts only), 30 to 90 s, uploaded to YouTube as **Unlisted**, link
pasted in the form. One video can serve several forms if it shows each item clearly.

## Checklist

- [ ] Location permissions (background location) — text A, video V1
- [ ] Foreground service types: location and microphone — texts B1, B2, video V1 + V2
- [ ] SMS and Call Log permissions: `SEND_SMS` — text C (already submitted in round 2; re-check it still matches), video V3
- [ ] Full-screen intent: `USE_FULL_SCREEN_INTENT` — text D, video V4 (or screenshots if the form allows)
- [ ] `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` — text E (review notes; there is no separate form)
- [ ] Advertising ID: **No** (no ads, no Analytics; `AD_ID` is removed from the manifest)
- [ ] Data safety form — section F; must match the merged manifest of the uploaded bundle
- [ ] Open-source notice: RNNoise (BSD-3-Clause) is listed in the app (Privacy & terms > Open-source licences)
- [ ] Release notes / review notes mention: crash detection, SOS, emergency texts are the core safety function

## A. Background location (`ACCESS_BACKGROUND_LOCATION`)

> CoRoute is a motorcycle group-ride safety app. During an active ride it shares the rider's position with their
> ride group and keeps SOS and crash detection working while the phone is locked in a handlebar mount or a pocket.
> If the rider crashes or raises an SOS with the screen off, the alert must carry the current location so the group
> and the emergency contacts can reach them. Location is used only while a ride is running (a persistent ride
> notification is shown the whole time) and is not collected outside a ride. The app explains this in a prominent
> in-app disclosure before Android asks for "Allow all the time", and riders who decline can still ride with the app
> open.

## B. Foreground service types

**B1. `FOREGROUND_SERVICE_LOCATION`** (type `location`)

> The ride foreground service keeps GPS, the connection to the ride group and crash detection running while the
> screen is off during a ride the rider started. The persistent notification shows the ride status and an SOS button.
> The service stops when the ride ends. Without it Android stops location updates and crash/SOS alerts would be sent
> without a position or not at all.

Task the rider is doing: navigation / location sharing during a ride. User-initiated: yes (Start ride).

**B2. `FOREGROUND_SERVICE_MICROPHONE`** (type `microphone`)

> The same ride service adds the microphone type only while the rider has the group voice intercom or siren alerts
> turned on, so a rider wearing a helmet can talk to the group and hear emergency-vehicle sirens with the phone
> locked. It is started from the app in the foreground after the microphone permission is granted. Voice is sent live
> to the ride group and is not recorded or stored; siren detection runs on the phone only.

## C. `SEND_SMS` (SMS and Call Log permissions form)

Use the exact text and answers in
[play_store_compliance.md section 3a](../handbook/compliance/play_store_compliance.md#3a-send_sms-permissions-declaration-form-sms-and-call-log-permissions)
(exception "Physical safety / emergency alerts", not the default SMS handler) and video script 3b there (= V3).

## D. Full-screen intent (`USE_FULL_SCREEN_INTENT`)

Category: **Alarm** (safety alarm). Form text:

> CoRoute detects motorcycle crashes. When a likely crash is detected, the phone rings a 30-second alarm that must
> appear over the lock screen so the rider (or someone next to them) can answer "I'm OK" or "Send now" without
> unlocking the phone; if nobody answers, the rider's emergency contacts are alerted. The same full-screen alert is
> used when another rider in the group raises an SOS. Full-screen intents are used only for these two emergency
> alarms, never for ordinary notifications, the ride status or the Live Update. If the permission is not granted the
> app falls back to a high-priority heads-up notification, which an injured rider may not see in time.

## E. `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (review notes / Device and network abuse policy)

> CoRoute's core function is crash detection and SOS during rides that last several hours with the screen off.
> Battery managers on many Android phones (Xiaomi, Samsung, Oppo, Vivo and others) stop the ride service despite the
> foreground notification, which silently disables crash detection. The app asks once, from the pre-ride phone check
> and after explaining why, to exempt CoRoute from battery optimization. Riders can decline; the app then shows how
> to change the battery setting manually.

Fallback agreed earlier: if Play rejects it, remove the permission and keep the "open battery settings" fix button.

## F. Data safety answers (this build)

Same as play_store_compliance.md section 2, plus the round 3 and round 4 updates. Summary to enter:

| Data type | Collected | Shared | Ephemeral | Required / optional | Purposes |
|---|---|---|---|---|---|
| Location: precise | Yes | Yes (with other users: ride group, guardians, helpers during SOS) | No | Required for rides | App functionality, safety |
| Location: approximate | Yes (road-safety cells, opt-in "Help make roads safer") | No | No | Optional | App functionality, Analytics |
| Audio: voice or sound recordings | Yes (intercom voice relayed live; siren detection on device) | Yes, with ride members (live) | **Yes** (not stored) | Optional | App functionality |
| Photos | Yes (profile picture and private original, review photos) | Review photos only after consent and approval | No | Optional | App functionality |
| Device or other IDs | Yes: FCM push token; hashed device key (SHA-256 of Android's app-scoped device id) and random install id for the ride sign-in lock (round 3) | No | No | Push optional; device key required for sign-in security | App functionality (notifications), Fraud prevention, security and compliance |
| App activity: other actions | Yes (crash alarm outcome, "Was this a real crash?") | No | No | Optional | App functionality, Analytics |
| App activity: app interactions / in-app search | Limited (feature aggregates, map searches proxied) | No | No | — | Analytics, App functionality |
| App info and performance: crash logs, diagnostics | Only when the rider sends the diagnostics log | No | No | Optional | Analytics (troubleshooting) |
| Personal info (name, e-mail, phone, user IDs, emergency contact), Health (Medical ID), Messages | as in play_store_compliance.md section 2 | | | | |
| Financial info | No (app is consumption-only) | | | | |

Security practices: encrypted in transit — Yes; deletion request — Yes (in-app and
`https://coroute.devmonks.space/delete-account`). Advertising ID — No. Data sold — No.

Permissions that need **no** Data safety change in 10027: `POST_PROMOTED_NOTIFICATIONS` (Live Update),
`ACCESS_NOTIFICATION_POLICY`. Not in the app (removed if a library adds them): `AD_ID`, `READ_PHONE_STATE`,
`READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`, `CAMERA`.

## Video scripts

**V1. Ride with the screen off (background location + foreground service location), 60 to 90 s**
1. Title card: "CoRoute: background location and ride service during a ride".
2. Open CoRoute, start a ride. The in-app disclosure for background location appears: show the full text, tap
   continue, the Android dialog, choose "Allow all the time".
3. The persistent ride notification appears (ride status, SOS button). Show it in the shade.
4. Lock the phone; wait a few seconds; on the second phone (group member) the rider's position keeps moving on the
   group map.
5. On the locked phone, open the notification and show the SOS button (do not send).
6. End the ride: the notification disappears (service stopped; no location outside a ride).

**V2. Intercom with the screen off (foreground service microphone), 30 to 60 s**
1. During a ride, turn on the intercom; the microphone permission dialog (first time), Allow.
2. Lock the phone; speak; the second phone hears it. Show the notification indicating the intercom is on.
3. Turn the intercom off; the microphone indicator disappears.

**V3. Emergency texts (`SEND_SMS`)** — script 3b in play_store_compliance.md.

**V4. Crash alarm over the lock screen (full-screen intent), 30 to 45 s**
1. During a ride, lock the phone. Trigger a test crash alarm with the hidden developer test impact
   (`ExternalImpactSource.developer` in `safety_service.dart`; a test alarm never texts anyone; the developer
   team knows the gesture), or film a real shake-and-drop test with a team phone as the contact.
2. The full-screen alarm appears over the lock screen with the 30-second countdown; tap "I'm OK" without unlocking.
3. Optional: show another rider's SOS arriving as a full-screen alert on the second phone.

## G. Round 10 offline group link: Nearby devices (Bluetooth) (appended for 3.55.0+10028)

Feature: docs/features_355/offline_long_range_link.md; notes and device checks: docs/quality/ROUND10_MESH_NOTES.md.

**Manifest.** No new entries for this feature. The rescue beacon round already declares the Bluetooth set once (see
that agent's section if appended):
- `BLUETOOTH_SCAN` with `android:usesPermissionFlags="neverForLocation"`;
- `BLUETOOTH_ADVERTISE`;
- `BLUETOOTH_CONNECT` (already there for helmet headsets);
- legacy `BLUETOOTH` / `BLUETOOTH_ADMIN` with `maxSdkVersion="30"`;
- `<uses-feature android.hardware.bluetooth_le required="false">`.

**What it does.** During a group ride only, phones advertise a small CoRoute beacon and connect to nearby riders'
phones (Bluetooth LE, long-range Coded PHY when supported). They pass positions, SOS alerts and push-to-talk voice rider
to rider when there is no mobile signal. A phone with signal forwards them to the CoRoute server. All data is encrypted
for the ride (AES-256-GCM with a per-ride key). Off outside group rides.

**Play Console actions.**
- **No permissions declaration form**: Nearby devices permissions are not restricted permissions.
- **`neverForLocation` is accurate**:
  - the scan reads only CoRoute's own beacons;
  - RSSI is used for link quality and the "chain stretching" warning only;
  - no location is derived from Bluetooth (positions come from GPS, as declared under A);
  - **no extra location justification is needed.** Android 11 and older need the location permission for any BLE
    scan; CoRoute already holds it for ride tracking.
- **Foreground service**: no new type. The radios run inside the existing `location` ride service (B). If review asks,
  the Bluetooth work is part of the same core ride function (group safety and positions) and stops when the ride ends.
- **Data safety (F)**: no new data type and no new purpose.
  - Location, voice (not stored) and SOS data already declared as shared with the group for App functionality may now
    travel phone to phone over Bluetooth.
  - Through a bridge phone they reach the server exactly as from the rider's own phone.
  - "Encrypted in transit" stays **Yes** (Bluetooth frames are encrypted end to end per ride; the socket uses TLS).
- **Privacy policy / store listing**: add the Nearby devices paragraph from ROUND10_MESH_NOTES.md section 4 ("Privacy
  wording").
- **Review notes text** (if Play asks why the app needs Nearby devices):
  "CoRoute is a group motorcycle safety app. During a group ride, when riders lose mobile signal, phones use Bluetooth
  to pass each other's positions and SOS alerts rider to rider until one phone has signal. Bluetooth is not used to
  determine location (neverForLocation) and is off outside group rides."
- **Optional video V5 (only if asked), 30-45 s**:
  1. Two phones in a group ride, both in flight mode with Bluetooth on.
  2. The "Offline link: 1 rider" chip appears.
  3. Rider B moves; rider A's map follows.
  4. Rider B raises a test SOS (test contact); rider A's phone shows the SOS alert.
  5. End the ride: the chip disappears (radios off).
