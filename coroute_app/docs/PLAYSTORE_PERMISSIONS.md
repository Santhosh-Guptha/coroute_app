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
| `BLUETOOTH_ADVERTISE`, `BLUETOOTH_SCAN` (`neverForLocation`); `BLUETOOTH`, `BLUETOOTH_ADMIN` (maxSdk 30) (round 10 rescue beacon; shared with the offline mesh) | A down rider's phone advertises a 5-byte rescue id under CoRoute's rescue UUID (no name, no position) after an unanswered crash alarm / SOS; responders' phones scan for that UUID only, during another rider's open SOS (docs/features_355/rescue_beacon.md) | Android 12+ "Nearby devices": from the finder screen ("Allow microphone and nearby devices") and wherever the mesh asks; it must be granted BEFORE a crash for the victim side. Android 11-: install time (scan uses the existing location permission) | none (Data safety: nothing collected or shared; processed on the device) |
