# Play Store submission checklist (CoRoute)

## Store listing
- App name: **CoRoute** · Category: **Maps & Navigation** (alt: Travel & Local) · Free, no ads, no in-app purchases.
- Short description and full description: see `store/LISTING.md` (kept in one place).
- Privacy policy URL: `https://coroute.duckdns.org/privacy` (served by the gateway).
- Contact e-mail: santhoshbukka5@gmail.com

## Data safety form answers
| Question | Answer |
|---|---|
| Does your app collect or share user data? | Collect: yes. Share with third parties: **no**. |
| Encrypted in transit? | Yes (TLS). |
| Can users request deletion? | Yes. In the app: trips (Trip history) and the whole account (Account & security, Delete my account). By e-mail if they cannot sign in. |
| **Location → Precise location** | Collected, not shared. Purpose: App functionality. Required (core feature). Ephemeral? No: the latest position is stored while in a convoy and traces are deleted after 90 days. |
| **Personal info → Name, Email, Phone** | Collected, not shared. Purpose: App functionality, Account management. |
| **Personal info → Other (vehicle, emergency contact)** | Collected, not shared. Purpose: App functionality. Optional. |
| **Audio → Voice or sound recordings** | **Collected (ephemeral: processed in real time, never stored)**, not shared. Purpose: App functionality. |
| **App activity → Other user-generated content** (chat/status messages) | Collected, not shared. Purpose: App functionality. |
| **Personal info → Phone number of other users** (3.14 emergency texts) | Processed **on the device only** during a ride when the rider switched on emergency texts: the phone gets the other riders' numbers (no names), stores them encrypted, never shows them and deletes them when the ride ends. Not shared with third parties. Riders can opt out of being texted. |
| **Health info → Health info** (3.14, optional blood group, allergies, medical notes) | Collected, optional, not shared with third parties. Purpose: App functionality (shown to the rider's own convoy only while their SOS is open). Users can clear it at any time. |
| **Location → Precise location: riders of other groups** (3.15 nearby rider network) | Not "sharing" in the Play sense (transfer to other users of the app as part of the safety feature the rider turned on, no third party): when a rider raises an SOS or crash alert, up to 3 riders of other groups riding toward it get the **emergency point only** (no name, group or phone); after one accepts, they get the rider's first name and vehicle. Riders can switch off "Ask nearby riders to help me". Accident warnings carry the point only. Discovery ("groups nearby", opt-in, Public groups only) sends group name, rider count and a rounded distance, **never positions**. |
| **Health info → Health info** (3.15) | Additionally, only if the rider switched on "Share medical info with a rider from another group who comes to help me" (off by default): shown to the one rider of another group who accepted to help, only while the alert is open. |
| **App activity → Other actions** (3.15 safety log) | Collected, not shared: ids and short codes of safety network actions (raised, asked, answered, false alert reported), no positions or text, deleted after 180 days and with the account. Purpose: Fraud prevention, security, and compliance. |
| **Location → Approximate location: weather** (3.16) | Up to 5 points along the planned route, rounded to about 10 km, with the expected time there, are sent by the CoRoute server to Open-Meteo (free weather service, no account, no key) for the rain forecast, once when the ride is reviewed and once when it starts, never in data saver. The answer is cached on the server for 30 minutes and shared by everyone. No rider identity leaves the server. Shown with "Weather data by Open-Meteo.com". |
| **Location → Precise location: live emergency link** (3.16) | Only when the rider (or their lead) taps "Share live link" during an open SOS: a web page shows the rider's first name, last position and time to anyone with the link, for 30 minutes or until it is stopped or the alert closes. The link is random and never listed; the server keeps only a hash of it and who created or stopped it. |
| **Location → Precise location: nearest hospital** (3.16) | During an SOS or crash alert the CoRoute server asks OpenStreetMap (Nominatim, already used for place names) once for the nearest hospital to the alert position, so the group can navigate there. Nothing else is sent. |
| **App activity → Other actions** (3.16 ride alerts) | Battery level and update times were already shared with the ride group; 3.16 turns them into alerts for the lead and the sweeper ("Kiran 14% battery", "last update 6 min ago"). Hard braking is counted on the phone only and never uploaded. Map tiles along the route are saved on the phone only (30 days). |
| **App activity → Other actions** (3.14 crash detection) | The motion sensor is read **on the device only** during a ride above 25 km/h. Not collected, not sent. |
| **App info and performance → Crash logs / Diagnostics** | Not collected (no analytics/crash SDK). |
| **Device or other IDs** | Not collected. (The app build number is stored with the account so old builds can be retired safely; it is not a device ID.) |

## Permissions declarations
- `ACCESS_BACKGROUND_LOCATION`: Play requires a **declaration form + video**. Wording: *"CoRoute shares a rider's live position with the members of their convoy during a group ride so riders stay together and can respond to SOS alerts. Sharing continues while the phone is in a pocket/mounted with the screen off and stops when the rider leaves the convoy."* Video: show join convoy → position visible on a second phone → screen off → position still updating → leave convoy → sharing stops; show the persistent Android notification.
- `RECORD_AUDIO`: used only while Talk is held / VOX armed (in-app prominent disclosure is the Talk button itself; the privacy page explains it).
- `FOREGROUND_SERVICE_LOCATION`: tied to the background-location feature above.
- `SEND_SMS` (3.14, restricted permission): needs the **Permissions Declaration Form** before the Play release, otherwise the
  release is rejected. Core use case to pick: **"Emergency / safety alerts"** (send emergency SMS when a crash or SOS cannot be
  delivered). Wording: *"When a rider's SOS or automatic crash alert cannot reach our server (no internet), and only if the rider
  switched this on before the ride, the rider's own phone texts their emergency contact, the convoy lead and the nearest riders
  (at most 10) with a map link to the position. The app never sends SMS for any other purpose and never reads SMS."* Video: pre-ride
  checklist, switch on "Text the group if there is no internet", grant SMS, airplane mode with mobile signal on, raise SOS,
  wait 45 seconds, show the text arriving on a second phone. If Play refuses: remove `SEND_SMS` from the Play build only; the
  app then falls back to the existing SMS composer (the rider taps send), and the APK on the website keeps direct sending.
- `USE_FULL_SCREEN_INTENT` (3.14): declare it in Play Console (App content, Full-screen intent) as an **alarm / safety alert**:
  the crash alarm ("Possible accident detected. Are you okay?") rings on the lock screen with a **15 second** countdown (3.15;
  was 30) before an automatic SOS. On Android 14+ the app also asks the rider to allow it ("Alarm on lock screen" in the
  pre-ride checklist). 3.15 also opens the "Hold to send SOS" screen over the lock screen from the ride notification's SOS
  button (never a one-tap send).
- 3.15 adds **no new permission**: spoken alerts use the phone's own text-to-speech engine (manifest `<queries>` entry for
  `android.intent.action.TTS_SERVICE`, not a permission), and the large ride notification replaces the existing foreground
  service notification (same id and channel). The lock screen view follows the rider's setting and Android's "hide sensitive
  content"; it never shows phone numbers.
- 3.16 adds **no new permission** and removes one: `BLUETOOTH_CONNECT` was declared but never used and is gone from the
  manifest (wearable input is a documented hook only, `docs/WEARABLE_HOOK.md`). Offline route maps use the phone's own
  storage (app cache, no storage permission). The optional "medical ID on the lock screen" shows blood group, allergies and
  the emergency contact as notification text only while the rider's own SOS is open, off by default.
- Telephony is declared `required="false"`, so tablets without SMS can still install the app.

### Release order
Upgrade the gateway to 3.14.0 **before** publishing build 74 (see `RUNBOOK.md`, "Release order for 3.14"). The app only uses
the new safety messages when the gateway offers them, but nothing new works until it is upgraded.

Upgrade the gateway to **3.15.0 before publishing build 75** (see `RUNBOOK.md`, "Release order for 3.15"). Update the Data
safety answers above (rows marked 3.15) and the listing text (`store/LISTING.md`) in the same release.

Upgrade the gateway to **3.16.0 before publishing build 76** (see `RUNBOOK.md`, "Release order for 3.16"), and allow the one
new outbound host `api.open-meteo.com` on the server (or leave `WEATHER_URL` empty). Update the Data safety answers above
(rows marked 3.16) and the listing text (`store/LISTING.md`) in the same release.

## Build
```
flutter build appbundle --release --dart-define=COROUTE_API=https://coroute.duckdns.org
```
Upload `build/app/outputs/bundle/release/app-release.aab`. Screenshots: `store/capture_screenshots.ps1`. When the listing is live, set `PLAY_STORE_URL` (see the end of `store/LISTING.md`). Target SDK is set by Flutter's default (34+).

## Test track
Use an **internal testing** track with the three-phone matrix from PRODUCTION_PLAN.md §4 before promoting to production.
