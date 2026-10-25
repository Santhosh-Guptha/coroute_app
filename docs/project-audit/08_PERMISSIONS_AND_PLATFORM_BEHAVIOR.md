# 08. Permissions & Platform Behavior

**Target**: CoRoute Native Platform & Hardware Interoperability  
**Target Platforms**: Android (Primary / Fully Implemented), iOS (Secondary / Configuration In Place)  
**Configuration Sources**: [`AndroidManifest.xml`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/android/app/src/main/AndroidManifest.xml) & [`Info.plist`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/ios/Runner/Info.plist)  

---

## 1. Permission Manifest & Runtime Rationale

### Android Permissions

| Permission Name | Protection Level | Runtime Prompt? | Functional Purpose in CoRoute | Fallback Behavior When Denied |
| :--- | :---: | :---: | :--- | :--- |
| `ACCESS_FINE_LOCATION` | Dangerous | Yes | GPS tracking, speed, bearing, and distance separation. | App cannot join convoys or track speed. |
| `ACCESS_COARSE_LOCATION` | Dangerous | Yes | Approximate fallback in cellular triangulation. | Degraded positioning accuracy (> 500m). |
| `ACCESS_BACKGROUND_LOCATION` | Dangerous | Yes | Keeps sharing convoy location while the phone screen is locked. | Convoy drops rider into ghost state when phone sleeps. |
| `FOREGROUND_SERVICE` | Normal | No | Permits running foreground execution tasks during active rides. | OS kills tracking when app is minimized. |
| `FOREGROUND_SERVICE_LOCATION` | Normal | No | Android 14+ requirement for foreground GPS services. | Android OS runtime security exception. |
| `FOREGROUND_SERVICE_MICROPHONE` | Normal | No | Android 14+ requirement for background helmet intercom. | Background VOX mic recording blocked. |
| `RECORD_AUDIO` | Dangerous | Yes | Captures voice for half-duplex VOX/PTT intercom & siren detection. | Intercom muted; siren detection disabled. |
| `MODIFY_AUDIO_SETTINGS` | Normal | No | Enables Bluetooth SCO routing to helmet communicators (Sena/Cardo). | Audio defaults to phone speaker. |
| `POST_NOTIFICATIONS` | Dangerous | Yes (Android 13+) | Displays the sticky, ongoing ride status notification. | Ride notification hidden; background service at risk. |
| `USE_FULL_SCREEN_INTENT` | Normal / Special | Yes | Starts `CrashAlarmScreen` over the lock screen during severe impacts. | Alarm notification sounds, but rider cannot abort without unlocking. |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Normal | User Action | Exempts app from Doze mode and aggressive task killer termination. | OEM task killers (MIUI/ColorOS) kill app after 15m screen-off. |
| `WAKE_LOCK` | Normal | No | Keeps CPU awake while recording high-frequency crash telemetry. | Sensor sampling jitter during screen sleep. |
| `VIBRATE` | Normal | No | Haptic confirmation for 56dp buttons, countdowns, and SOS triggers. | Visual confirmation only. |
| `BIND_QUICK_SETTINGS_TILE` | Signature / System | User Tile Add | Powers the Android Quick Settings "Medical ID" tile for first responders. | Medical ID tile unavailable in status pull-down. |

### iOS Permissions (`Info.plist`)
* `NSMicrophoneUsageDescription`: *"CoRoute uses the microphone for the live convoy intercom while you hold Talk or arm VOX."*
* `NSLocationWhenInUseUsageDescription`: *"CoRoute shares your position with your convoy so riders can stay together."*
* `NSLocationAlwaysAndWhenInUseUsageDescription`: *"CoRoute keeps sharing your position with your convoy while the screen is off during a ride."*
* `UIBackgroundModes`: Configured with `audio` (intercom playback/recording) and `location` (convoy GPS tracking).

---

## 2. Foreground Service & Background Execution

CoRoute relies on **`flutter_foreground_task: ^11.0.0`** to manage continuous background operation.

### Lifecycle & Android Foreground Service
1. **Service Activation**:
   * Initiated in `ConvoyService._activate()` via `BackgroundService.startRideService()`.
   * Displays an ongoing notification (`id: 1001`, channel: `coroute_ride_service`) showing:
     * Convoy name & member count.
     * Ahead/behind separation from nearest rider.
     * Fast-action buttons: `Talk`, `SOS`, and `Leave Ride`.
2. **Process Death & Crash Recovery**:
   * If Android terminates the process due to extreme memory pressure (e.g. running 3D navigation concurrently), `SharedPreferences` retains the `keyRideAlive` and `keyLastAliveAt` flags.
   * Upon app relaunch, `ConvoyService._readPreviousExit()` detects the unclean exit and sends:
     `WS: JOIN { prevExit: "KILLED", prevAliveAt: 1700000000000 }`
   * Informs fellow riders that the phone experienced an OS kill rather than a voluntary departure.
3. **Minimize Handling**:
   * Tapping Android Back on the active ride cockpit invokes `BackgroundService.minimizeApp()`, which executes `moveTaskToBack(true)` via Android platform channel, preventing app disposal while leaving GPS active.

---

## 3. Native Audio & Bluetooth SCO Intercom

* **Helmet Communicator Integration (Sena, Cardo, FreedConn)**:
  * In `IntercomService`, audio routing detects connected Bluetooth headsets via `AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED`.
  * Automatically invokes `startBluetoothSco()` and `setBluetoothScoOn(true)` to route microphone input and intercom playback through helmet speakers.
* **Audio Interruption Policy**:
  * Incoming phone calls trigger an automatic VOX mute, pausing intercom transmission.
  * Approaching emergency vehicle siren detection automatically ducks intercom audio by -20 dB to ensure road awareness.

---

## 4. OEM Battery Optimization Mitigation

Aggressive Android OEM battery managers (Xiaomi MIUI/HyperOS, OnePlus OxygenOS, Oppo ColorOS, Samsung OneUI) frequently kill GPS foreground services after 15–20 minutes with the screen off. CoRoute mitigates this through:
1. Direct intent prompt requesting battery optimization exemption (`Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`).
2. `OemBatteryGuide` (`lib/presentation/safety/oem_battery_guide.dart`) providing step-by-step visual guides tailored to the user's specific device manufacturer (detected via `SafetyNative.deviceManufacturer()`).
3. Periodic 30-second heartbeat wake-locks ensuring the GPS isolate remains scheduled.
