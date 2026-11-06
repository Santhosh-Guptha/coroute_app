import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' hide ServiceStatus;

import 'convoy_service.dart';
import 'intercom_service.dart';
import 'ble_remote_service.dart';
import 'smart_airbag_bridge_service.dart';
import 'permissions_service.dart';

/// Permissions monitored during an active CoRoute convoy trip.
enum TripPermission {
  /// Foreground Location / GPS tracking (Essential)
  location,

  /// System Location Service toggle in Android Quick Settings (Essential)
  locationService,

  /// Background Location for screen-locked convoy tracking (Optional / Background)
  locationAlways,

  /// Microphone for helmet intercom voice transmission (Optional)
  microphone,

  /// Bluetooth for BLE handlebar remote and smart airbag vest (Optional)
  bluetooth,

  /// Notifications for crash alarms and convoy separation (Optional)
  notification,
}

/// Service that monitors and enforces permission safety during active trips.
///
/// Mandate ISSUE-7:
/// 1. Detect permission changes while the trip is active (Location, Background Location,
///    Microphone, Notifications, Bluetooth).
/// 2. Detect permission revocation when the app resumes (`WidgetsBindingObserver`).
/// 3. Detect location service status changes (e.g., GPS toggled off from Quick Settings).
/// 4. Stop relying on revoked permissions immediately.
/// 5. Surface prominent high-visibility warning banners in the cockpit.
/// 6. Clearly explain which feature is affected and why the permission is required.
/// 7. Provide a direct button to open Android app settings (`openAppSettings()`).
/// 8. Recheck permissions after returning from settings and resume ONLY restored features.
/// 9. Distinguish essential permissions (GPS) from optional ones (Microphone).
/// 10. NEVER terminate an active trip automatically just because a permission was revoked;
///     keep unaffected local safety features operational.
class PermissionRevocationSafetyService extends ChangeNotifier with WidgetsBindingObserver {
  final ConvoyService? convoyService;
  final IntercomService? intercomService;
  final BleRemoteService? bleRemoteService;

  // Injection points for unit testing and platforms
  final Future<bool> Function(TripPermission permission)? permissionChecker;
  final Future<bool> Function()? locationServiceChecker;
  final Stream<ServiceStatus>? serviceStatusStream;
  final Future<bool> Function()? settingsOpener;
  final Duration checkInterval;

  final Map<TripPermission, bool> _states = {
    for (final p in TripPermission.values) p: true,
  };

  final Set<TripPermission> _dismissedOptional = <TripPermission>{};

  StreamSubscription<ServiceStatus>? _serviceStatusSub;
  Timer? _checkTimer;
  bool _isInitialized = false;

  PermissionRevocationSafetyService({
    this.convoyService,
    this.intercomService,
    this.bleRemoteService,
    this.permissionChecker,
    this.locationServiceChecker,
    this.serviceStatusStream,
    this.settingsOpener,
    this.checkInterval = const Duration(seconds: 5),
  });

  /// Initializes lifecycle and stream listeners, and runs an initial permission check.
  void init() {
    if (_isInitialized) return;
    _isInitialized = true;

    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (e) {
      debugPrint('PermissionSafety: WidgetsBinding note: $e');
    }

    _listenLocationServiceStream();

    if (checkInterval > Duration.zero) {
      _checkTimer = Timer.periodic(checkInterval, (_) {
        if (isTripActive) {
          recheckPermissions();
        }
      });
    }

    convoyService?.addListener(_onConvoyChanged);

    recheckPermissions();
  }

  void _onConvoyChanged() {
    if (isTripActive) {
      recheckPermissions();
    }
  }

  /// Whether an active convoy ride is currently in progress.
  bool get isTripActive => convoyService?.activeConvoy != null;

  /// Returns whether a specific permission is currently granted and operational.
  bool isGranted(TripPermission perm) => _states[perm] ?? false;

  /// Returns whether a specific permission is essential for core trip tracking.
  static bool isEssential(TripPermission perm) {
    switch (perm) {
      case TripPermission.location:
      case TripPermission.locationService:
        return true;
      case TripPermission.locationAlways:
      case TripPermission.microphone:
      case TripPermission.bluetooth:
      case TripPermission.notification:
        return false;
    }
  }

  /// Returns the human-readable name of the affected feature when the permission is revoked.
  static String affectedFeature(TripPermission perm) {
    switch (perm) {
      case TripPermission.location:
        return 'Live Convoy Tracking & Speedometer';
      case TripPermission.locationService:
        return 'Android GPS Hardware Service';
      case TripPermission.locationAlways:
        return 'Background Screen-Off Tracking';
      case TripPermission.microphone:
        return 'Helmet Intercom Voice Transmission';
      case TripPermission.bluetooth:
        return 'Handlebar Remote & Smart Airbag';
      case TripPermission.notification:
        return 'Emergency & Separation Alerts';
    }
  }

  /// Returns the rider-friendly explanation of why this permission is needed.
  static String reasonRequired(TripPermission perm) {
    switch (perm) {
      case TripPermission.location:
        return 'Location permission is required so your group can track your position and alert you to route hazards.';
      case TripPermission.locationService:
        return 'Android GPS is turned off in Quick Settings. Turn GPS on to transmit your live position.';
      case TripPermission.locationAlways:
        return 'Background location keeps you connected when your phone is locked or in your pocket.';
      case TripPermission.microphone:
        return 'Microphone permission is required to speak on intercom. Listening to other riders is still operational.';
      case TripPermission.bluetooth:
        return 'Bluetooth is required to connect to your handlebar remote and smart airbag vest.';
      case TripPermission.notification:
        return 'Notifications are required to receive emergency SOS and convoy separation alerts.';
    }
  }

  /// All currently revoked / missing permissions.
  List<TripPermission> get revokedPermissions =>
      TripPermission.values.where((p) => !isGranted(p)).toList();

  /// All currently revoked essential permissions.
  List<TripPermission> get revokedEssentialPermissions =>
      revokedPermissions.where(isEssential).toList();

  /// All currently revoked optional permissions (excluding dismissed ones).
  List<TripPermission> get activeRevokedOptionalPermissions =>
      revokedPermissions.where((p) => !isEssential(p) && !_dismissedOptional.contains(p)).toList();

  /// True if any essential permission is currently missing or revoked.
  bool get hasEssentialRevocation => revokedEssentialPermissions.isNotEmpty;

  /// True if any active warning should be displayed in the cockpit.
  bool get hasActiveWarning => hasEssentialRevocation || activeRevokedOptionalPermissions.isNotEmpty;

  /// The highest-priority revoked permission to highlight in the cockpit banner.
  TripPermission? get primaryRevokedPermission {
    if (revokedEssentialPermissions.isNotEmpty) {
      return revokedEssentialPermissions.first;
    }
    if (activeRevokedOptionalPermissions.isNotEmpty) {
      return activeRevokedOptionalPermissions.first;
    }
    return null;
  }

  void _listenLocationServiceStream() {
    final stream = serviceStatusStream ??
        (!kIsWeb && (Platform.isAndroid || Platform.isIOS)
            ? Geolocator.getServiceStatusStream()
            : null);
    if (stream != null) {
      _serviceStatusSub = stream.listen((status) {
        final isEnabled = status == ServiceStatus.enabled;
        _handleLocationServiceStatusChanged(isEnabled);
      });
    }
  }

  void _handleLocationServiceStatusChanged(bool isEnabled) {
    final wasEnabled = _states[TripPermission.locationService] ?? true;
    _states[TripPermission.locationService] = isEnabled;

    if (wasEnabled && !isEnabled) {
      // GPS toggled off from Quick Settings
      _handlePermissionRevoked(TripPermission.locationService);
    } else if (!wasEnabled && isEnabled) {
      // GPS toggled on
      _handlePermissionRestored(TripPermission.locationService);
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // User returned from Android Settings or Quick Settings
      recheckPermissions();
    }
  }

  /// Rechecks all monitored permissions and service statuses.
  /// Stops relying on newly revoked permissions immediately.
  /// Resumes ONLY those features whose permissions were restored.
  Future<void> recheckPermissions() async {
    final prevStates = Map<TripPermission, bool>.from(_states);

    for (final perm in TripPermission.values) {
      if (perm == TripPermission.locationService) {
        _states[perm] = await _checkLocationService();
      } else {
        _states[perm] = await _checkPermission(perm);
      }
    }

    // Process state transitions
    for (final perm in TripPermission.values) {
      final wasGranted = prevStates[perm] ?? true;
      final isNowGranted = _states[perm] ?? false;

      if (wasGranted && !isNowGranted) {
        _handlePermissionRevoked(perm);
      } else if (!wasGranted && isNowGranted) {
        _handlePermissionRestored(perm);
      }
    }

    notifyListeners();
  }

  void _handlePermissionRevoked(TripPermission perm) {
    switch (perm) {
      case TripPermission.location:
      case TripPermission.locationService:
        // Immediate action: Stop real GPS tracking without terminating the active trip
        convoyService?.onLocationRevoked();
        break;
      case TripPermission.microphone:
        // Immediate action: Stop recording stream & abort active intercom transmission
        intercomService?.onMicrophoneRevoked();
        break;
      case TripPermission.bluetooth:
        // Immediate action: Disconnect BLE accessories gracefully
        bleRemoteService?.onBluetoothRevoked();
        try {
          SmartAirbagBridgeService().disconnect();
        } catch (_) {}
        break;
      case TripPermission.locationAlways:
      case TripPermission.notification:
        // Local state flagged; banner will warn rider
        break;
    }
  }

  void _handlePermissionRestored(TripPermission perm) {
    // Clear dismiss cache if restored
    _dismissedOptional.remove(perm);

    switch (perm) {
      case TripPermission.location:
      case TripPermission.locationService:
        // Resume GPS tracking only if BOTH location permission and GPS hardware are active
        if (isGranted(TripPermission.location) && isGranted(TripPermission.locationService)) {
          convoyService?.onLocationRestored();
        }
        break;
      case TripPermission.microphone:
        intercomService?.onMicrophoneRestored();
        break;
      case TripPermission.bluetooth:
        bleRemoteService?.onBluetoothRestored();
        break;
      case TripPermission.locationAlways:
      case TripPermission.notification:
        break;
    }
  }

  Future<bool> _checkLocationService() async {
    if (locationServiceChecker != null) {
      return await locationServiceChecker!();
    }
    if (kIsWeb) return true;
    try {
      return await Geolocator.isLocationServiceEnabled();
    } catch (_) {
      return true;
    }
  }

  Future<bool> _checkPermission(TripPermission perm) async {
    if (permissionChecker != null) {
      return await permissionChecker!(perm);
    }
    if (kIsWeb) return true;

    try {
      switch (perm) {
        case TripPermission.location:
          return await PermissionsService.isLocationGranted();
        case TripPermission.locationAlways:
          return await PermissionsService.isLocationAlwaysGranted();
        case TripPermission.microphone:
          return await PermissionsService.isMicrophoneGranted();
        case TripPermission.bluetooth:
          return await PermissionsService.isBluetoothGranted();
        case TripPermission.notification:
          return await PermissionsService.isNotificationGranted();
        case TripPermission.locationService:
          return await _checkLocationService();
      }
    } catch (e) {
      debugPrint('PermissionSafety check error for $perm: $e');
      return true;
    }
  }

  /// Direct button action to open Android system app settings.
  Future<bool> openSettings() async {
    final opener = settingsOpener ?? openAppSettings;
    return await opener();
  }

  /// Allows rider to dismiss an optional warning banner during the current ride session.
  /// Essential permission warnings cannot be dismissed.
  void dismissOptionalWarning(TripPermission perm) {
    if (isEssential(perm)) return;
    _dismissedOptional.add(perm);
    notifyListeners();
  }

  /// Resets dismissed state.
  void resetDismissals() {
    _dismissedOptional.clear();
    notifyListeners();
  }

  /// Unit testing helper to simulate permission revocation or restoration directly.
  @visibleForTesting
  void setPermissionStateForTest(TripPermission perm, bool granted) {
    final wasGranted = _states[perm] ?? true;
    _states[perm] = granted;

    if (wasGranted && !granted) {
      _handlePermissionRevoked(perm);
    } else if (!wasGranted && granted) {
      _handlePermissionRestored(perm);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    convoyService?.removeListener(_onConvoyChanged);
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    _serviceStatusSub?.cancel();
    _checkTimer?.cancel();
    super.dispose();
  }
}
