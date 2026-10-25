# 03. Navigation Flows & User Journeys

**Target**: CoRoute Navigation Architecture  
**Router Type**: Imperative Navigation with `MaterialPageRoute` & `GlobalKey<NavigatorState>` (`appNavigatorKey`)  
**Shell**: `RiderHomeScreen` with `IndexedStack` (4 persistent tabs)  

---

## 1. Flow 1: First Launch & Authentication

```mermaid
flowchart TD
    Start([App Launch]) --> Splash[SCR-01 SplashScreen]
    Splash --> ReadToken{Token in SecureStorage?}
    ReadToken -->|No / Expired| Auth[SCR-02 AccessGateScreen]
    ReadToken -->|Valid| CheckProfile{Profile Complete?}
    
    Auth -->|Email & Password Login| CallLogin[POST /auth/login]
    Auth -->|Google OAuth| CallGoogle[POST /auth/google]
    Auth -->|Register New Account| CallReg[POST /auth/register]
    
    CallLogin --> ValidateProfile{Name & Phone Exist?}
    CallGoogle --> ValidateProfile
    CallReg --> CompleteProfile[SCR-03 CompleteProfileScreen]
    
    ValidateProfile -->|No| CompleteProfile
    CompleteProfile -->|Save Profile| CallPatchMe[PATCH /me]
    CallPatchMe --> CheckOnboard{First Run?}
    
    ValidateProfile -->|Yes| CheckOnboard
    CheckOnboard -->|Yes| Onboard[SCR-04 OnboardingScreen]
    Onboard --> Perms[SCR-05 PermissionsScreen]
    Perms --> Shell[SCR-06 RiderHomeScreen]
    
    CheckOnboard -->|No| Shell
```

* **Starting Screen**: `SplashScreen`
* **Transitions**: Automatically resolves session token; routes to `AccessGateScreen` if missing, or restores session and verifies whether mandatory profile fields (name, phone, motorcycle model) are present.
* **Failure Path**: If JWT validation fails via `onAuthRejected`, `_SessionBinder` automatically pops all screens back to `AccessGateScreen`.

---

## 2. Flow 2: Ride Creation, Joining & Deep Linking

```mermaid
flowchart TD
    Home[SCR-07 RideStartView] -->|Tap 'Create Group Ride'| SHT01[SHT-01 CreateRideSheet]
    Home -->|Tap 'Join with Code'| SHT02[SHT-02 JoinRideSheet]
    Link[Universal Link: coroute://join/CODE] --> DeepLink[_DeepLinkListener]
    
    DeepLink --> SetPending[ConvoyService.setPendingJoinCode]
    SetPending --> SHT02
    
    SHT01 -->|Submit Name & Visibility| CallCreate[POST /convoys]
    CallCreate --> SetActive[ConvoyService._activate]
    
    SHT02 -->|Enter 6-digit Code / Scan QR| CallJoin[POST /convoys/join]
    CallJoin --> SetActive
    
    SetActive --> StartForeground[BackgroundService.startRideService]
    StartForeground --> OpenCockpit[SCR-08 LiveCockpitMapScreen]
```

* **Deep Link Scheme**: Supports custom scheme `coroute://join/{CODE}` and verified web link `https://coroute.duckdns.org/join/{CODE}` via Android App Links (`autoVerify=true`).
* **Active Ride Guard**: If a user clicks an invite link while already in an active convoy, the link is discarded to prevent accidental convoy desertion (`rider_home_screen.dart:223`).

---

## 3. Flow 3: Active Cockpit, Telemetry & Regrouping

```mermaid
flowchart TD
    Cockpit[SCR-08 LiveCockpitMapScreen] --> ActionStack[Cockpit Action Stack]
    
    ActionStack -->|Tap Fuel| SHT05[SHT-05 FuelSheet]
    ActionStack -->|Tap Essentials| SHT06[SHT-06 EssentialsSheet]
    ActionStack -->|Tap Chat| SHT03[SHT-03 MessagesView]
    ActionStack -->|Tap Guardian| SHT08[SHT-08 GuardianSheet]
    ActionStack -->|Tap Plan Route| SCR12[SCR-12 TripPlannerScreen]
    ActionStack -->|Tap Timeline| SCR27[SCR-27 LiveTimelineScreen]
    
    Cockpit -->|Long Press Stop Button| SHT17[SHT-17 QuickStopReasonModal]
    SHT17 -->|Select: Flat Tire / Fuel / Mechanical| SendStatus[ConvoyService.setMyStatus]
    SendStatus --> BroadcastWS[WS: STATUS & CHAT]
    
    Cockpit -->|Lead Taps 'Regroup Here'| PushRegroup[WS: REGROUP_SET]
    PushRegroup --> NotifyAll[Spoken Alert & Map Pin on all Riders]
    
    Cockpit -->|Lead Taps 'End Ride'| ConfirmEnd{Confirm End Ride?}
    ConfirmEnd -->|Yes| CallStatusEnded[POST /convoys/:id/status ENDED]
    CallStatusEnded --> BroadcastDissolve[WS: TRIP_STATUS ENDED & DISSOLVED]
    BroadcastDissolve --> AutoTearDown[All Riders Auto-Pop to Home & SnackBar]
```

---

## 4. Flow 4: Emergency Crash Detection & SOS Abort

```mermaid
flowchart TD
    Sensor[IMU Accelerometer Spike > 3.2G] --> DecelCheck{Decel to Stop within 18s?}
    DecelCheck -->|Yes| TriggerAlarm[SafetyService.triggerCrashAlarm]
    DecelCheck -->|No| NormalRide[Continue Monitoring]
    
    TriggerAlarm --> Host[CrashAlarmHost]
    Host --> AlarmScreen[SCR-22 CrashAlarmScreen]
    AlarmScreen --> StartCountdown[15s Abort Countdown & Max Audio Siren]
    
    StartCountdown -->|Rider Taps 'I am OK'| Abort[Log False Alarm & Dismiss]
    StartCountdown -->|Timer Expires OR 'Send Now' Tapped| Dispatch[Emergency Broadcast]
    
    Dispatch --> SendWS[WS: SOS Type CRASH_AUTO]
    Dispatch --> CheckNet{Internet Connected?}
    CheckNet -->|No| SMSFallback[SafetyNative.sendSmsEmergency]
    CheckNet -->|Yes| SafetyNetPush[Gateway Mutual Aid Alert]
    
    SafetyNetPush --> AllCockpits[Emergency Red Banner on all Convoy Maps]
```

* **Lock Screen Override**: Utilizes Android `android.permission.USE_FULL_SCREEN_INTENT` with `showWhenLocked="true"` and `turnScreenOn="true"` in `RideSosActivity` and `MedicalIdActivity`.
* **High-Speed Slide Compensation**: Stop detection window extended from 10.0s to 18.0s for initial speeds > 60 km/h to prevent missing riders sliding on wet pavement.

---

## 5. Flow 5: Offline Loss & DTN Outbox Recovery

```mermaid
flowchart TD
    OnlineRide[Active Convoy Online] --> CellBlackout[Enter Mountain Tunnel / Remote Valley]
    CellBlackout --> SocketDisconnect[WS Closes]
    SocketDisconnect --> Banner[CockpitDualStateBanner: OFFLINE - PACK ACTIVE]
    
    OnlineRide --> UserAction[User sends Chat / Stop Request / SOS]
    UserAction --> Enqueue[ConvoyService._enqueue]
    Enqueue --> OutboxStore[(SQLite / Memory OutboxStore)]
    
    CellBlackout --> CellReturns[Signal Restored / 4G Available]
    CellReturns --> SocketReconnect[RealtimeService Auto-Reconnect]
    SocketReconnect --> CallJoin[WS: JOIN with lastAliveAt]
    CallJoin --> ServerSnapshot[Receive SNAPSHOT]
    ServerSnapshot --> FlushOutbox[ConvoyService._flushOutbox]
    FlushOutbox --> EmptyQueue[Deliver Queued Packets in Monotonic Order]
```

---

## 6. Dead Ends & Navigation Analysis

1. **PopScope Behavior**:
   * On `RiderHomeScreen`, Android Back button behavior is strictly controlled:
     * If on tabs 1, 2, or 3 (`Trips`, `Alerts`, `Profile`), Back switches to tab 0 (`Ride`).
     * If on tab 0 during an active ride, Back invokes `BackgroundService.minimizeApp()` to prevent accidental termination of the ride tracking service.
     * Back only exits the app when on tab 0 with **no active ride**.
2. **Missing Deep-Link Back Stack**:
   * Launching the app via `coroute://join/CODE` directly presents `RiderHomeScreen` with `JoinRideSheet` pushed above it. Canceling the join sheet leaves the user cleanly on `RideStartView` without dead ends.
3. **Admin Dashboard Back Navigation**:
   * `MasterAdminDashboard` has a standard `AppBar` back button returning to `AccountScreen`. All sub-screens (`AdminUsersScreen`, `AdminRideHistoryScreen`, `AdminInsightsScreen`) pop cleanly back to the dashboard.
