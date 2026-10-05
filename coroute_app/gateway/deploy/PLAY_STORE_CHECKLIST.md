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
| **App info and performance → Crash logs / Diagnostics** | Not collected (no analytics/crash SDK). |
| **Device or other IDs** | Not collected. (The app build number is stored with the account so old builds can be retired safely; it is not a device ID.) |

## Permissions declarations
- `ACCESS_BACKGROUND_LOCATION`: Play requires a **declaration form + video**. Wording: *"CoRoute shares a rider's live position with the members of their convoy during a group ride so riders stay together and can respond to SOS alerts. Sharing continues while the phone is in a pocket/mounted with the screen off and stops when the rider leaves the convoy."* Video: show join convoy → position visible on a second phone → screen off → position still updating → leave convoy → sharing stops; show the persistent Android notification.
- `RECORD_AUDIO`: used only while Talk is held / VOX armed (in-app prominent disclosure is the Talk button itself; the privacy page explains it).
- `FOREGROUND_SERVICE_LOCATION`: tied to the background-location feature above.

## Build
```
flutter build appbundle --release --dart-define=COROUTE_API=https://coroute.duckdns.org
```
Upload `build/app/outputs/bundle/release/app-release.aab`. Screenshots: `store/capture_screenshots.ps1`. When the listing is live, set `PLAY_STORE_URL` (see the end of `store/LISTING.md`). Target SDK is set by Flutter's default (34+).

## Test track
Use an **internal testing** track with the three-phone matrix from PRODUCTION_PLAN.md §4 before promoting to production.
