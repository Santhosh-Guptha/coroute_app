# CoRoute Master Project Context & Architectural Handover Document
**Organization**: devmonks.space  
**Product**: CoRoute — Group Motorcycle & Convoy Safety Telemetry Platform  
**Package Identifier**: `space.devmonks.coroute_app`  
**Current Active Version**: `2.0.0 (Build 46)` / `1.0.0+46`  
**Target Environment**: Single Unified Project `corout-uat` (GCP / Firebase) & Oracle 26ai Cloud  
**Primary Maintainer / Master Admin**: `santhoshbukka5@gmail.com`

---

## 1. Executive Summary & Project Purpose

CoRoute is an ultra-reliable, real-time convoy safety, navigation, and audio communication platform built specifically for motorcycle groups and vehicle convoys. The system eliminates the high latency, bloated dependencies, and unreliable peer-to-peer tracking of legacy fleet applications by combining:
1. **Real GPS Telemetry & Progress Tracking** (live distance, ahead/behind route ranking, dynamic bearing, and speed).
2. **Push-To-Talk (PTT) Voice Intercom** (low-latency audio bursts over HTTP/WebSocket with noise gating and Bluetooth headset integration).
3. **Oracle 26ai Autonomous Cloud Database Storage** (SODA REST collections storing persistent convoy data, trips, and rider telemetry).
4. **Google Cloud OAuth 2.0 Sign-In** with automatic Master Admin privileges for `santhoshbukka5@gmail.com`.
5. **Zero Mocks & Zero Fallback Dummies** — all data flows through real device hardware (GPS, microphone, network) and live cloud endpoints.

---

## 2. Architectural Evolution: Why the App was Re-engineered

### The 190 MB Legacy App vs. The 54.5 MB Modern Flutter Architecture

| Metric / Dimension | Legacy Native App (`TravelSafetyApp`) | Current Modern Architecture (`coroute_app`) |
| :--- | :--- | :--- |
| **Framework** | Native Android (Kotlin + Jetpack Compose) | **Flutter 3.13+ (Dart AOT compiled)** |
| **APK Release Size** | **~190 MB** | **54.5 MB** *(71.3% reduction)* |
| **Causes of Bloat** | Heavy embedded C++ NDK binaries, uncompressed sound assets, duplicate native architecture libs (x86, x86_64, armeabi-v7a, arm64-v8a bundled together without ABI splitting) | **Optimized Flutter AOT snapshot, tree-shaken font/icon assets (99.1% reduction), stripped release symbols** |
| **Map Rendering** | Proprietary map SDKs requiring API keys | **100% Free OpenStreetMap Mapnik raster/vector tiles via `flutter_map` (zero watermarks, zero cost)** |
| **State Management** | Fragmented ViewModels with leaky coroutine listeners | **Provider pattern (`ChangeNotifier`) with clean lifecycle decoupling** |
| **Audio Subsystem** | Custom raw AudioRecord with thread contention | **`record: ^7.1.1` high-performance federated recording engine** |

---

## 3. Database & Cloud Backend Architecture

### 3.1. Primary Authoritative Database: Oracle 26ai Autonomous Database
The app does **NOT** rely on Firebase Realtime Database (RTDB) for data persistence. The backend is completely anchored on **Oracle Autonomous Database 26ai** via Simple Oracle Document Access (SODA) REST APIs.

- **Oracle Cloud Region**: `ap-hyderabad-1`
- **Instance Name**: `coroutedb`
- **Base SODA REST URL**:
  ```
  https://gfe473165e66472-coroutedb.adb.ap-hyderabad-1.oraclecloudapps.com/ords/admin/soda/latest
  ```
- **SODA Collections**:
  - `riders`: Rider profile metadata, emergency contacts, vehicle information, and role assignments.
  - `convoys`: Active convoy groups, join codes (6-character uppercase codes), route polylines, lead riders, and active trip configurations.
  - `trips`: Historical trip logs, telemetry snapshots, distance covered, average speed, and SOS incident reports.
- **Oracle Cloud Gateway VM**:
  - Public IP: `152.67.181.198` (Healthy, running relay gateway services for audio and telemetry).

### 3.2. Firebase Realtime Database (RTDB) Decoupling
Firebase RTDB was originally configured in earlier prototypes. In the modern codebase:
- All calls to Firebase RTDB are wrapped with graceful fallbacks.
- If Firebase RTDB is unreachable or unconfigured, the application functions seamlessly using **Oracle SODA REST** and localized state caches.

---

## 4. Authentication, Authorization & Roles

### 4.1. Google OAuth 2.0 Sign-In Integration
The authentication system uses the official `google_sign_in` package configured against the unified Google Cloud project **`corout-uat`**.

- **Google Cloud Project ID**: `corout-uat`
- **Project Number**: `87798956679`
- **OAuth Web Client ID (`serverClientId`)**:
  ```
  87798956679-ivggpbpote5cf2cvi8mtg8gja3r1sfve.apps.googleusercontent.com
  ```
- **Registered SHA-1 Fingerprints in Google Cloud & `google-services.json`**:
  - **Release SHA-1**: `D5:94:93:54:97:3A:FF:CB:D6:39:99:63:F6:B2:68:E0:1B:F4:2F:AC`
  - **Release SHA-256**: `EC:87:7C:44:CD:5C:DA:E0:00:F3:E4:F0:B8:C4:D9:07:35:07:5C:09:29:B3:71:10:73:E9:21:12:2B:3B:B1:F8`
  - **Debug SHA-1**: `62:46:F8:05:32:92:9D:D5:42:D0:D9:AF:1E:81:5C:E4:A0:55:F1:1F`
  - **Debug SHA-256**: `5D:1D:3F:A3:5C:45:70:46:E0:C0:D2:D1:65:95:6E:1C:E0:B3:EB:AA:61:24:48:72:CC:4D:4D:AE:10:47:97:EF`

### 4.2. Master Admin Privileges
- **Designated Master Admin**: `santhoshbukka5@gmail.com`
- **Mechanism**:
  - In `lib/data/services/auth_service.dart`, whenever an authentication event completes (either via Google Sign-In or credentials), the app checks if `cleanEmail == AppConstants.masterAdminEmail.toLowerCase()`.
  - When verified, the role is automatically elevated to `AppConstants.adminRole` (`MASTER_ADMIN`).
  - Master Admins gain immediate access to the **Admin Dashboard**, fleet controls, broadcast telemetry, and user management screens.
- **Purging of Mock Credentials**: All legacy default passwords (`admin@devmonks.space` / `devmonks@admin2026`) and static dummy users have been permanently removed.

---

## 5. Core Feature Matrix & Implementation Details

### 5.1. Real-Time GPS Telemetry Engine
- **Service**: `lib/data/services/telemetry_service.dart`
- **Location Engine**: Uses `geolocator: ^13.0.2` with high-accuracy GPS settings (`LocationAccuracy.high`, distance filter: 5 meters).
- **Dynamic Attributes**:
  - Continuous latitude, longitude, and altitude.
  - Calculated speed in km/h and cardinal heading (`N`, `NE`, `E`, `SE`, `S`, `SW`, `W`, `NW`).
  - Battery level tracking (`battery_plus: ^6.2.3`) to alert teammates if a rider's phone battery is critical.
  - Route Snapping & Ahead/Behind calculation: Evaluates relative position to the lead rider and planned polyline to warn riders when they stray or fall behind.
- **Zero Mocks**: Simulated GPS coordinates and timer-based dummy position generators have been eradicated.

### 5.2. Push-To-Talk (PTT) Voice Intercom
- **Service**: `lib/data/services/audio_service.dart`
- **Engine**: Upgraded to `record: ^7.1.1` for robust multi-platform microphone capture without dependency conflicts.
- **Features**:
  - Touch-to-talk press-and-hold button with haptic feedback.
  - Audio encoded in lightweight AAC / PCM buffers.
  - Dispatched directly via HTTP multipart upload or WebSocket stream to the VM relay server (`152.67.181.198`).
  - Native Bluetooth SCO support for motorcycle helmet headsets (Cardo, Sena, and standard Bluetooth communicators).

### 5.3. Convoy & Group Lifecycle
- **Service**: `lib/data/services/convoy_service.dart`
- **Lifecycle Flow**:
  1. **Create Convoy**: User specifies Convoy Name and optional Destination. Generates a unique 6-character code (e.g. `CR8X92`). Stored in Oracle SODA `convoys`.
  2. **Join Convoy**: Fellow riders enter the 6-character code. Device registers rider in the convoy document.
  3. **Live Map Display**: Leaflet-compatible OpenStreetMap tiles rendered smoothly with rider markers, direction arrows, and status badges.
  4. **Leave / End Trip**: Persists completed trip data into Oracle SODA `trips` collection and cleans up active session state in `SharedPreferences`.

### 5.4. SOS Emergency Protocol
- **Trigger**: High-priority floating SOS button on dashboard or hardware trigger.
- **Payload**: Precise GPS coordinates, emergency contact notification, and visual distress beacon broadcast to all convoy members.
- **Integration**: `url_launcher` triggers immediate direct phone call and SMS with Google Maps coordinates link (`https://maps.google.com/?q=lat,lng`) to designated emergency contacts.

### 5.5. Stopped Rider Status Cards
- When a rider remains stationary for more than the configured stop threshold (default: 3 minutes), the UI prompts the rider to select an informative status card:
  - ⛽ **Fueling**
  - ☕ **Rest Break**
  - 🔧 **Mechanical Issue**
  - 🛞 **Flat Tire**
  - 🚦 **Traffic Congestion**
  - 🌧️ **Weather Delay**
  - 📸 **Photo Stop**
  - 🛑 **Regroup Request**
- The status card is instantly rendered as a badge on the team's live map.

---

## 6. Firebase & Cloud Infrastructure Consolidation

### 6.1. Legacy Project Deprecation
All previous experimental and split projects have been dismantled:
1. `coroute-flutter-devmonks` (Project Number: `939171022786`) $\rightarrow$ Tester access deleted, project placed in GCP shutdown/inactive state.
2. `coroute-production-app` (Project Number: `1023060337089`) $\rightarrow$ Tester access deleted, project placed in GCP shutdown/inactive state.
3. `coroute-testing-app` (Project Number: `165459528646`) $\rightarrow$ Tester access deleted, project placed in GCP shutdown/inactive state.

### 6.2. Active Unified Project: `corout-uat`
All testing, distribution, and cloud configuration are consolidated under **`corout-uat`**:
- **Project ID**: `corout-uat`
- **Project Number**: `87798956679`
- **Android App ID**: `1:87798956679:android:3c80773227ff3cee24ee22`
- **Package Name**: `space.devmonks.coroute_app`
- **Local CLI Target**: Locked via `coroute_app/.firebaserc` (`"default": "corout-uat"`).

---

## 7. Codebase Directory Structure & Key Files

```
wise-chandrasekhar/
├── coroute_app/                         # Modern Flutter Production Codebase
│   ├── android/
│   │   ├── app/
│   │   │   ├── google-services.json    # corout-uat configuration with OAuth client IDs
│   │   │   ├── build.gradle.kts        # Android build config (targetSdk 34, compileSdk 34)
│   │   │   └── src/main/AndroidManifest.xml # Permissions: GPS, Background, Audio, Bluetooth
│   ├── lib/
│   │   ├── core/
│   │   │   ├── constants/
│   │   │   │   ├── api_endpoints.dart  # Oracle Cloud SODA & VM Gateway URLs
│   │   │   │   └── app_constants.dart  # App identity, version, masterAdminEmail
│   │   │   ├── theme/
│   │   │   │   └── app_theme.dart      # Dark cyberpunk glassmorphic design system
│   │   │   └── widgets/                # Reusable GlassCard, DevMonks badges, buttons
│   │   ├── data/
│   │   │   ├── models/
│   │   │   │   ├── convoy_model.dart   # Convoy state & members data model
│   │   │   │   ├── rider_model.dart    # Rider profile & telemetry data model
│   │   │   │   └── trip_model.dart     # Historical trip records data model
│   │   │   └── services/
│   │   │       ├── audio_service.dart   # PTT recording, compression, transmission
│   │   │       ├── auth_service.dart    # Google Sign-In, Master Admin role logic
│   │   │       ├── convoy_service.dart  # Convoy lifecycle & Oracle SODA sync
│   │   │       └── telemetry_service.dart # Real GPS positioning & calculation
│   │   ├── presentation/
│   │   │   ├── admin/                  # Master Admin screens & fleet management
│   │   │   ├── auth/                   # Login, Registration & Google Sign-In screens
│   │   │   └── rider/                  # Rider Dashboard, Live Map, Settings, SOS
│   │   └── main.dart                   # Application entry point & Provider registration
│   ├── test/
│   │   ├── coroute_unit_test.dart      # Unit tests for telemetry & compass math
│   │   └── widget_test.dart            # Widget rendering & UI component tests
│   └── pubspec.yaml                    # Flutter dependencies & version (1.0.0+43)
│
├── TravelSafetyApp/                     # [DEPRECATED ARCHIVE] Legacy Native Kotlin App
├── CoRoute-iOS/                         # [ARCHIVE] Early iOS prototype
└── web-app/                             # [ARCHIVE] Early web prototype
```

---

## 8. Build, Test & Deployment Guide

### 8.1. Quality Assurance Commands
Always run these checks before triggering any deployment:
```powershell
# 1. Code analysis (must return 0 issues)
flutter analyze

# 2. Automated test suite (all 16 unit & widget tests must pass)
flutter test
```

### 8.2. Compiling the Production Release APK
```powershell
cd C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar\coroute_app
flutter build apk --release
```
*Generated output*: `build\app\outputs\flutter-apk\app-release.apk` (approx. 54.5 MB).

### 8.3. Distributing via Firebase App Distribution
```powershell
firebase appdistribution:distribute "build\app\outputs\flutter-apk\app-release.apk" `
  --app "1:87798956679:android:3c80773227ff3cee24ee22" `
  --project "corout-uat" `
  --testers "santhoshbukka5@gmail.com" `
  --release-notes "CoRoute UAT Release Build: Full Google Cloud OAuth, Real GPS, PTT Audio, Oracle Cloud DB."
```

---

## 9. Architectural Rules for Future Developments

1. **Maintain Single Source of Truth**:
   - `coroute_app/` is the **only** active codebase. Do not make modifications to `TravelSafetyApp/` or other archive directories.
2. **Never Re-introduce Mock Data**:
   - Every coordinate, speed value, bearing, and user status must originate from device sensors or the Oracle Cloud database.
3. **Preserve Master Admin Routing**:
   - `santhoshbukka5@gmail.com` must always resolve to `MASTER_ADMIN`. Any future changes to role-based access control (RBAC) must maintain this invariant.
4. **Preserve Oracle Cloud Decoupling**:
   - Never tie business logic strictly to Firebase RTDB. Keep persistent storage routed to Oracle 26ai Cloud SODA REST endpoints.
5. **Keep APK Size Under 65 MB**:
   - Use vector SVG or tree-shaken icons. Avoid uncompressed audio files or bulky 3rd-party binary SDKs.
