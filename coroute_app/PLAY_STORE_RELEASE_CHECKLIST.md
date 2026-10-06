# CoRoute — Google Play Store Release Checklist & Launch Runbook

> **Target App:** CoRoute: Group Ride Convoy (`space.devmonks.coroute_app`)  
> **Production API:** `https://coroute.duckdns.org` (Oracle Cloud VM `152.67.181.198`)  
> **Maintainer Contact:** `santhoshbukka5@gmail.com`  
> **Current Version:** `3.8.0+68`

---

## 📋 Phase 1: Google Play Console Account & App Setup

### 1.1 App Identity & Categorization
- [ ] **App Name:** `CoRoute: Group Ride Convoy` *(28/30 characters)*
- [ ] **Short Description:** `Keep your group together: live convoy map, intercom, SOS and trip reports.` *(74/80 characters)*
- [ ] **Full Description:** Copy verbatim from [`store/LISTING.md`](store/LISTING.md) *(strictly adheres to Play Store policy: no emoji, no unverified claims, no simulated reviews)*.
- [ ] **Default Language:** English (United States) / English (India).
- [ ] **App Category:** `Maps & Navigation` *(Alternative: Travel & Local)*.
- [ ] **Tags:** `Motorcycle`, `Navigation`, `GPS Tracking`, `Intercom`, `Touring`.

### 1.2 Graphic Assets & Media
- [ ] **App Icon (Hi-Res):** `512 x 512 px`, PNG, 32-bit color, no transparency (`store/icon_512.png`).
- [ ] **Feature Graphic:** `1024 x 500 px`, PNG/JPEG, no alpha channel (`store/feature_graphic_1024x500.png`).
- [ ] **Phone Screenshots (4 to 8 required):**
  - Run `store/capture_screenshots.ps1` with an Android device connected via USB to capture authentic ride screens:
    1. *Cockpit Map HUD with real-time speed, heading and convoy radar*
    2. *Convoy Dashboard with active member list and tactical roles (Lead, Sweeper)*
    3. *Half-Duplex Intercom Dock with Push-To-Talk and private channel selector*
    4. *Stationary Stop Reason Picker & live marker status badges*
    5. *Emergency SOS Action Sheet with GPS coordinates and ICE dialer*
    6. *Trip Summary with individual telemetry cards and GPX export*

---

## 🛡️ Phase 2: Mandatory Policy & Data Safety Declarations

### 2.1 URLs & Contact Information
- [ ] **Privacy Policy URL:** `https://coroute.duckdns.org/privacy` *(Hosted on VM, HTTPS validated)*
- [ ] **Terms of Use URL:** `https://coroute.duckdns.org/terms` *(Hosted on VM, HTTPS validated)*
- [ ] **Support Email:** `santhoshbukka5@gmail.com`
- [ ] **Website:** `https://coroute.duckdns.org`

### 2.2 App Content Declarations
- [ ] **App Access:** *All functionality is available without special access restrictions.* Provide a demo test account (e.g. `rider_demo@coroute.test` / `Password#123`).
- [ ] **Ads:** Select **"No, my app does not contain ads"**.
- [ ] **Content Rating (IARC):** Complete questionnaire:
  - Violence/Sex/Gambling: None.
  - User interaction: Users share location and speak via intercom.
  - Content rating result: Typically **PEGI 3** / **Everyone**.
- [ ] **Target Audience:** Select **18 and older** (Motorcycle convoy riding).
- [ ] **News Apps:** Select **No**.
- [ ] **COVID-19 Contact Tracing:** Select **No**.
- [ ] **Government Apps:** Select **No**.
- [ ] **Financial Features:** Select **No**.

### 2.3 Data Safety Form (Google Play Data Safety Section)
Fill out the exact values below:
| Data Category | Collected? | Shared? | Purpose | Ephemeral / Retained | Deletion Mechanism |
|---|---|---|---|---|---|
| **Location → Approximate & Precise** | **Yes** | **No** | App functionality (Convoy tracking, SOS) | Retained for active ride + 90 days trip history | In-app trip deletion + Account deletion |
| **Personal Info → Name / Callsign** | **Yes** | **No** | Account management, convoy member identification | Retained with account | In-app account deletion |
| **Personal Info → Email Address** | **Yes** | **No** | Account management & authentication | Retained with account | In-app account deletion |
| **Personal Info → Phone Number** | **Yes** | **No** | Rider contact & SOS lifeline | Retained with account | In-app account deletion |
| **Personal Info → Vehicle & ICE Contact** | **Yes** | **No** | Emergency dispatch & convoy identification | Retained with account | In-app profile edit & account deletion |
| **Audio → Voice Recordings** | **Yes** | **No** | Intercom Push-To-Talk voice relay | **Ephemeral (processed live, never stored)** | Discarded immediately after socket packet |
| **User Generated Content (Chat/Status)** | **Yes** | **No** | Convoy stop reasons (Fueling, Mechanical, etc.) | Retained for ride duration | In-app ride termination |
| **Crash Logs / Diagnostics** | **No** | **No** | None (no third-party tracking/crash SDK) | N/A | N/A |
| **Device or other IDs** | **No** | **No** | None | N/A | N/A |

- [ ] **Data Encryption:** Answer **Yes** (All traffic encrypted in transit via TLS/HTTPS/WSS).
- [ ] **Account Deletion:** Answer **Yes** (In-app deletion available under `Account & security` → `Delete my account`, and via email request).

---

## 📍 Phase 3: Sensitive Permissions & Background Location Review

Google Play conducts strict human reviews for apps requesting `ACCESS_BACKGROUND_LOCATION`.

### 3.1 Background Location Declaration Form
- [ ] **Declaration Statement:**
  > *"CoRoute shares a rider's live position with the members of their convoy during a group ride so riders stay together, maintain formation, and can respond immediately to SOS distress alerts. Location sharing continues while the phone is mounted or in a pocket with the screen off and terminates immediately when the rider leaves the convoy."*

### 3.2 Verification Video Walkthrough (Required Link)
Upload an unlisted YouTube or Google Drive video showing:
1. Prominent in-app disclosure on `PermissionsScreen` explaining background location usage.
2. Rider joining or creating a convoy ride.
3. Turning the phone screen off or backgrounding the app.
4. Persistent Android foreground service notification showing CoRoute tracking active.
5. Showing that the rider's position continues to update on a second device's radar.
6. Leaving the convoy and showing the notification and tracking immediately terminate.

### 3.3 Audio Permission (`RECORD_AUDIO`)
- [ ] Disclosed in-app directly on the Push-To-Talk button and privacy policy. Used strictly while PTT is pressed or VOX triggered.

---

## 🔨 Phase 4: Production Build & Signing

### 4.1 Keystore Verification
- [ ] Verify `android/key.properties` points to `android/app/coroute.jks`.
- [ ] Verify `version` in `pubspec.yaml` (e.g. `3.8.0+68`).

### 4.2 Build Android App Bundle (AAB)
Run the release build command:
```powershell
& "C:\Users\santhosh\flutter\bin\flutter.bat" build appbundle --release --dart-define=COROUTE_API=https://coroute.duckdns.org
```
- [ ] Output artifact generated: `build/app/outputs/bundle/release/app-release.aab`
- [ ] Size verification: typically ~25–35 MB.

---

## 🚀 Phase 5: Release Track Strategy & Verification

### 5.1 Internal Testing Track (Immediate)
1. Upload `app-release.aab` to **Testing → Internal testing** in Play Console.
2. Add your developer email (`santhoshbukka5@gmail.com`) to the internal tester list.
3. Install via internal testing opt-in link on a physical device.
4. Verify:
   - [ ] Google Sign-In & Email login.
   - [ ] Master Admin elevation for `santhoshbukka5@gmail.com`.
   - [ ] Create convoy & join code generation.
   - [ ] Map radar loading & OpenStreetMap tiles.
   - [ ] SOS action sheet: GPS coordinates copy, ICE dialer intent, and SMS intent.
   - [ ] Stationary dwell prompt & status reason selection.
   - [ ] Profile editing (phone, vehicle plate, ICE name & number).

### 5.2 Closed Testing (20 Testers / 14 Days if required for new accounts)
- [ ] Invite 20 closed testing participants.
- [ ] Keep closed track active for 14 continuous days.

### 5.3 Production Promotion
- [ ] Promote build from Closed Testing to **Production**.
- [ ] Submit for final Google Play Review.
- [ ] Review approval typically takes 24–72 hours.
- [ ] Once approved, CoRoute is live on the Google Play Store!
