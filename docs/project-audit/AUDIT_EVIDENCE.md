# 14. Audit Evidence & Source Citations

**Target**: Verifiable Source Code Evidence  
**Audit Date**: October 23, 2026  
**Auditor**: Antigravity Core Autonomous Agent  

---

## 1. Ergonomic Cockpit & Glove Touch Target Citations

* **56dp Glove Touch Targets**:
  * Evidence: [`coroute_app/lib/core/ui/design_kit.dart:34`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/ui/design_kit.dart#L34)
    ```dart
    static const double minTouchTarget = 56.0;
    ```
  * Evidence: [`coroute_app/lib/presentation/rider/widgets/minimal_cockpit_overlay.dart:184`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/rider/widgets/minimal_cockpit_overlay.dart#L184)
    ```dart
    constraints: const BoxConstraints(minWidth: 56.0, minHeight: 56.0),
    ```
* **0.8-Second Glance Budget Constrained Action Stack**:
  * Evidence: [`coroute_app/lib/presentation/rider/widgets/cockpit_action_stack.dart:110`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/rider/widgets/cockpit_action_stack.dart#L110)
    ```dart
    // Constrained to at most 1 primary action capsule with swipe/tap to view next
    ```

---

## 2. Chat Box Sheet Layout & Keyboard Overflow Evidence

* **Bounded Height & Expanded Chat List**:
  * Evidence: [`coroute_app/lib/presentation/ride/messages_sheet.dart:246-260`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/ride/messages_sheet.dart#L246-L260)
    ```dart
    final screenH = MediaQuery.sizeOf(context).height;
    final sheetH = (screenH * 0.72).clamp(380.0, 750.0);

    return SizedBox(
      height: sheetH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DsSectionHeader('Quick replies'),
          const SizedBox(height: 8),
          QuickReplyBar(onSend: (q) => _sendQuick(service, q), queued: () => !service.isOnline),
          const SizedBox(height: 6),
          Divider(height: 2, thickness: 2, color: AppTheme.border),
          Expanded(
            child: messages.isEmpty ? ... : ListView.builder(...)
          ),
          ...
    ```

---

## 3. Admin End Ride Synchronization Evidence

* **WebSocket & REST Permission Checks**:
  * Evidence: [`coroute_app/gateway/src/ws.js:604-612`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/ws.js#L604-L612)
    ```javascript
    const isLead = rider && rider.role === 'LEAD';
    const isCreator = room.meta.createdByUserId === u.userId;
    const isAdmin = u.role === ROLE_ADMIN;
    if (!isLead && !isCreator && !isAdmin) {
      throw new ConvoyError('Only the convoy lead or admin can change the trip state.', 403);
    }
    ```
  * Evidence: [`coroute_app/gateway/src/routes.js:247-255`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/routes.js#L247-L255)
* **Dissolution & Zombie Room Prevention**:
  * Evidence: [`coroute_app/gateway/src/convoys.js:335-360`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/convoys.js#L335-L360)
    ```javascript
    this._emit(groupId, 'TRIP_STATUS', { tripStatus: status, system });
    if (status === 'ENDED') {
      this._emit(groupId, 'DISSOLVED', { reason: 'TRIP_ENDED' });
    }
    ...
    patchRider(room, userId, patch, { emit = true, trusted = false } = {}) {
      if (room.meta.tripStatus === 'ENDED') return null;
      ...
    ```
* **Client Teardown & Notification**:
  * Evidence: [`coroute_app/lib/data/services/convoy_service.dart:955-980`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/convoy_service.dart#L955-L980)
    ```dart
    case 'TRIP_STATUS':
      final status = e['tripStatus']?.toString() ?? convoy?.tripStatus;
      if (convoy != null) {
        _allConvoys[gid] = convoy.copyWith(tripStatus: status);
      }
      if (status == 'ENDED') {
        if (convoy != null) {
          _onTripEnded(convoy.copyWith(tripStatus: 'ENDED'));
        } else {
          _dropActiveConvoyLocally();
        }
      }
      break;
    case 'DISSOLVED':
      final c = activeConvoy;
      if (c != null) {
        _onTripEnded(c.copyWith(tripStatus: 'ENDED'));
      } else {
        _dropActiveConvoyLocally();
      }
      break;
    ```
  * Evidence: [`coroute_app/lib/presentation/rider/rider_home_screen.dart:206-218`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/rider/rider_home_screen.dart#L206-L218)
    ```dart
    } else if (ended) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      setState(() => _rideSaved = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The ride was ended. Trip saved to your history.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    ```

---

## 4. Static Analysis Verification Evidence

* **Argument Order & Method Signature in Satellite Service**:
  * Method Signature: [`coroute_app/lib/core/config/feature_gates.dart:88`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/core/config/feature_gates.dart#L88)
    ```dart
    static bool isUnlocked(Feature feature, [SubscriptionTier? tier])
    ```
  * Call Site: [`coroute_app/lib/data/services/satellite_sos_service.dart:125-126`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/satellite_sos_service.dart#L125-L126)
    ```dart
    final hasSatelliteAccess = isSimulated ||
        FeatureGates.isUnlocked(Feature.satelliteSosRelay, tier);
    ```
  * Historical Defect: Prior inverted call `FeatureGates.isUnlocked(tier, Feature.satelliteSosRelay)` caused `argument_type_not_assignable`.
  * Current Verification: `cd coroute_app; dart analyze lib/` -> `Analyzing lib... No issues found!` (Exit code `0`).

---

## 5. Acoustic Siren Detector & Audio Ducking Evidence

* **Frequency Spectrum & -20 dB Ducking**:
  * Evidence: [`coroute_app/lib/data/services/siren_acoustic_detector.dart:45-75`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/siren_acoustic_detector.dart#L45-L75)
    ```dart
    static const double sirenBandMinHz = 600.0;
    static const double sirenBandMaxHz = 1800.0;
    static const double duckingAttenuationDb = -20.0;
    ```
  * Evidence: [`coroute_app/lib/presentation/rider/widgets/siren_hud_pill.dart:35`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/presentation/rider/widgets/siren_hud_pill.dart#L35)

---

## 6. Road Hazard AI Mesh Citations

* **Vertical Accelerometer Spike & Spatial Broadcast**:
  * Evidence: [`coroute_app/lib/data/services/road_hazard_detector.dart:65-90`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/data/services/road_hazard_detector.dart#L65-L90)
    ```dart
    static const double severeImpactZThresholdG = 2.8;
    static const double upcomingWarningDistanceMeters = 300.0;
    ```
  * Evidence: [`coroute_app/gateway/src/road_hazards.js:25-50`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/gateway/src/road_hazards.js#L25-L50)
    ```javascript
    function clusterHazard(groupId, hazard) { ... }
    ```

---

## 7. Ultra-Compact 16-Byte SOS Packet Encoding Evidence

* **Binary Codec Specification**:
  * Evidence: [`coroute_app/lib/domain/safety/sos_packet_codec.dart:45-130`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/lib/domain/safety/sos_packet_codec.dart#L45-L130)
    ```dart
    static const int packetLength = 16;
    static const int sentinelAltitude = 0x7FFF; // 32767 meters
    // Bytes 0-3: Signed Int32 Latitude (10^7 scaling, Big Endian)
    // Bytes 4-7: Signed Int32 Longitude (10^7 scaling, Big Endian)
    // Bytes 8-9: Signed Int16 Altitude (meters, sentinel 0x7FFF)
    // Bytes 10-13: Uint32 UTC Epoch Timestamp Seconds
    // Byte 14: Uint8 Severity / Trauma Code (0-6)
    // Byte 15: Upper 4 bits = Blood Group; Lower 4 bits = Modulo-16 Checksum
    ```

---

## 8. Android Native Quick Settings Tile & Lock Screen Evidence

* **Medical Tile Service**:
  * Evidence: [`coroute_app/android/app/src/main/kotlin/space/devmonks/coroute_app/MedicalTileService.kt:12-40`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/android/app/src/main/kotlin/space/devmonks/coroute_app/MedicalTileService.kt#L12-L40)
* **Full-Screen Lock Screen Activity**:
  * Evidence: [`coroute_app/android/app/src/main/AndroidManifest.xml:71-78`](file:///C:/Users/santhosh/Documents/antigravity/wise-chandrasekhar/coroute_app/android/app/src/main/AndroidManifest.xml#L71-L78)
    ```xml
    <activity
        android:name=".RideSosActivity"
        android:exported="false"
        android:showWhenLocked="true"
        android:turnScreenOn="true"
        android:theme="@android:style/Theme.Translucent.NoTitleBar" />
    ```
