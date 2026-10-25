# 01. Project Structure & Baseline

**Target**: CoRoute Codebase Baseline  
**Workspace Root**: `C:\Users\santhosh\Documents\antigravity\wise-chandrasekhar`  
**Mobile Module**: `coroute_app/`  
**Gateway Module**: `coroute_app/gateway/`  

---

## 1. Version Control & Git Status

| Property | Value | Notes |
| :--- | :--- | :--- |
| **Branch** | `main` | Tracking `origin/main` |
| **Last Commit** | `6ce33cf3363b861291db2d31a94706d4aa61ee5d` | Date: Thu Oct 22 19:51:25 2026 +0530 |
| **Commit Message** | `feat(release): release v3.47.0+107 - FEAT-02 Road Hazard AI Mesh & FEAT-03 Emergency Siren Detector` | Deployed across cluster |
| **Working Tree Status** | Dirty (Unstaged changes in FEAT-01/04/05) | Preserved without modification per audit instructions |

### Unstaged / Modified Files in Working Tree
* `coroute_app/lib/core/config/feature_gates.dart` (Feature enum additions: `bleHandlebarRemote`, `biometricTraumaPulse`, `satelliteSosRelay`)
* `coroute_app/lib/data/models/pending_sos.dart` (Safety model updates)
* `coroute_app/lib/data/services/convoy_service.dart` (Convoy session telemetry extensions)
* `coroute_app/lib/data/services/safety_service.dart` (Crash detection & sensor bridge hooks)
* `coroute_app/lib/presentation/rider/live_cockpit_map_screen.dart` (HUD integration of pills)
* `coroute_app/lib/presentation/safety/crash_alarm_screen.dart` (Biometric & satellite display additions)
* Untracked files: `ble_remote_service.dart`, `biometric_safety_bridge.dart`, `ble_remote_hud_pill.dart`, `biometric_pulse_hud_pill.dart`, and respective unit tests.

---

## 2. Platform SDK & Runtime Baseline

### Flutter & Dart
* **Flutter SDK**: `3.47.1` (channel `stable`, revision `6655482ec0`)
* **Dart SDK**: `3.13.1` (stable, revision `Wed Aug 18 2026`)
* **Flutter DevTools**: `2.60.0`
* **SDK Constraint in `pubspec.yaml`**: `sdk: ^3.13.1`

### Android
* **Application ID**: `space.devmonks.coroute_app`
* **Compile SDK**: `37` (Android 16 / Vanilla Ice Cream preview compatibility)
* **Minimum SDK**: `23` (Android 6.0 Marshmallow)
* **Target SDK**: Managed by Flutter (`flutter.targetSdkVersion`, defaults to 34/35)
* **Android Gradle Plugin (AGP)**: `9.0.1` (`android/settings.gradle.kts`)
* **Gradle Wrapper**: `9.1.0` (`android/gradle/wrapper/gradle-wrapper.properties`)
* **Kotlin Version**: `2.4.0` (`android/settings.gradle.kts`)
* **Java Compatibility**: `JavaVersion.VERSION_17` (`jvmTarget = JVM_17`)
* **Core Library Desugaring**: Enabled (`isCoreLibraryDesugaringEnabled = true` via `desugar_jdk_libs:2.1.4`)
* **R8 Minification**: Enabled for release (`isMinifyEnabled = true`, `isShrinkResources = true`, `proguard-rules.pro`)

### iOS
* **Bundle Identifier**: `space.devmonks.coroute`
* **Deployment Target**: `15.0` (`IPHONEOS_DEPLOYMENT_TARGET = 15.0` in `Runner.xcodeproj/project.pbxproj`)
* **Audio & Location Background Modes**: `audio`, `location` in `Info.plist`
* **Custom URL Scheme**: `coroute://` for deep links (`coroute://join/CODE`, `coroute://cockpit`)
* **Universal Links**: `https://coroute.duckdns.org/join/` (`autoVerify = true`)

### Node.js Gateway
* **Node Runtime**: `>= 20.0.0` (`gateway/package.json` engines)
* **Database**: Oracle Autonomous Database Cloud (SODA Document Store via `oracledb 6.6.0`)
* **Web Server**: Express 4.21.0 with `ws 8.18.0` WebSocket engine
* **Authentication**: JWT (`jsonwebtoken 9.0.2`, `bcrypt 5.1.1`)

---

## 3. Application Metadata & Identifiers

* **App Name**: `CoRoute`
* **Package Name**: `coroute_app`
* **Namespace**: `space.devmonks.coroute_app`
* **Version**: `3.47.0`
* **Build Number**: `107`
* **Author / Publisher**: DevMonks / Santhosh Bukka (`santhoshbukka5@gmail.com`)

---

## 4. Entry Points & Initialization Lifecycle

### Flutter App (`coroute_app/lib/main.dart`)
1. **Low-level Binding**: `WidgetsFlutterBinding.ensureInitialized()`
2. **IPC Port Initialization**: `BackgroundService.initCommunicationPort()` initializes the bidirectional platform channel isolate communication.
3. **Screen Orientation**: `SystemChrome.setPreferredOrientations(DeviceOrientation.values)` enables dynamic portrait/landscape rotation.
4. **Metadata & Package Info**: `MetaService.readPackageInfo()` fetches application version and build number.
5. **Theme Initialization**: `ThemeController.load()` loads theme preference and syncs sun times.
6. **Localization**: `L10n.systemLanguage` reads system language for safety cues.
7. **Settings Persistence**: `SettingsService.load()` loads data-saver and battery preferences.
8. **Offline Map Cache**: `SafetyNative.cacheDir()` opens SQLite raster/vector tile database at `$cacheDir/tiles`.
9. **History Maintenance**: `RideStatsStore.prune()` purges local rider history older than 90 days.
10. **Application Tree**: `runApp(CoRouteApp)` builds the `MultiProvider` dependency tree and sets the root navigation gate (`CrashAlarmHost` -> `_UpdateGate` -> `SplashScreen`).

### Gateway Server (`coroute_app/gateway/src/server.js`)
1. **Configuration**: `config.js` validates environment variables (`PORT`, `JWT_SECRET`, `SODA_URL`, `ORACLE_DIR`).
2. **Oracle Database Connection**: Initializes Oracle SODA connection pool or in-memory fallback.
3. **Express App**: Configures security middleware (`helmet`, rate limiters, CORS, JSON/URL-encoded parsers).
4. **WebSocket Server**: Binds `ws.Server` on `/ws` route, hooking into `ConvoyManager` and `Hub`.
5. **Background Sweepers**: Starts 30-second heartbeat timers, emergency expiration monitors, and track retention cleaners.
6. **HTTP Listen**: Binds to `0.0.0.0:3000` (proxied by Caddy on ports 80/443).

---

## 5. Repository Directory Tree

```text
wise-chandrasekhar/
├── .github/                         # GitHub Actions CI workflows
├── CLUSTER_CREDENTIALS.md           # Multi-node VM deployment documentation
├── PENDING_FEATURES.md              # Safety roadmap tracking
├── PROJECT_CONTEXT.md               # Architecture and rider safety context
├── docs/                            # Feature specifications and audit reports
│   └── project-audit/               # Exhaustive repository audit documentation
└── coroute_app/                     # Primary Flutter application & backend
    ├── analysis_options.yaml        # Flutter linter configuration
    ├── pubspec.yaml                 # Flutter dependencies & assets manifest
    ├── android/                     # Native Android project (SDK 37, Kotlin 2.4)
    │   ├── app/
    │   │   ├── build.gradle.kts     # Application build script & signing config
    │   │   ├── proguard-rules.pro   # R8 optimization & reflection rules
    │   │   └── src/main/
    │   │       ├── AndroidManifest.xml # Permissions, activities & services
    │   │       └── kotlin/space/devmonks/coroute_app/ # Native Java/Kotlin files
    │   ├── build.gradle.kts         # Root Gradle build script
    │   └── settings.gradle.kts      # Plugin management & repositories
    ├── assets/                      # Bundled static resources
    │   ├── branding/                # Logos, app icons, badges
    │   └── fonts/                   # Manrope-Variable.ttf
    ├── gateway/                     # Real-time WebSocket & REST Gateway
    │   ├── package.json             # Node.js dependencies
    │   ├── deploy/                  # Caddyfile, systemd services, provisioning
    │   ├── src/                     # Gateway implementation
    │   │   ├── app.js               # Express application builder
    │   │   ├── auth.js              # JWT & Google OAuth verification
    │   │   ├── convoys.js           # Room management & telemetry hub
    │   │   ├── routes.js            # REST API route handlers
    │   │   ├── safety_network.js    # Cross-convoy mutual aid router
    │   │   ├── timeline.js          # Convoy stop & state timeline
    │   │   ├── ws.js                # WebSocket message protocol handler
    │   │   └── oracle/              # Oracle SODA document repository
    │   └── test/                    # 45+ Node.js test files (315 tests)
    ├── ios/                         # Native iOS project (iOS 15.0+)
    │   └── Runner/                  # Xcode project files & Info.plist
    ├── lib/                         # Flutter Dart source code
    │   ├── core/                    # Cross-cutting constants, theme, UI tokens
    │   ├── data/                    # Models, repositories, remote services
    │   ├── domain/                  # Safety detectors, math, alert policies
    │   ├── presentation/            # Screens, HUD overlays, sheets, widgets
    │   └── main.dart                # Application entrypoint
    └── test/                        # 125+ Flutter unit, widget, and E2E tests
```
