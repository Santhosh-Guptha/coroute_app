import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'intercom_service.dart';
import 'intercom_network_resilience.dart';
import 'safety_service.dart';
import 'convoy_service.dart';
import 'voice_service.dart';
import '../models/network_wire.dart';

/// Connection and pairing state of a Bluetooth Handlebar Remote.
enum BleRemoteStatus {
  disconnected,
  paired,
  listening,
}

/// Gesture detected from the remote button.
enum BleRemoteGesture {
  singlePress,
  doublePress,
  triplePress,
  longPress,
}

/// An event emitted when the rider presses a handlebar remote button.
class BleRemoteEvent {
  final BleRemoteGesture gesture;
  final LogicalKeyboardKey key;
  final DateTime timestamp;

  const BleRemoteEvent({
    required this.gesture,
    required this.key,
    required this.timestamp,
  });

  @override
  String toString() => 'BleRemoteEvent($gesture, key: ${key.keyLabel}, at: $timestamp)';
}

/// Service that manages wireless Bluetooth Low Energy (BLE) and HID handlebar remotes.
///
/// Supports generic $5 BLE camera shutters (AB Shutter 3), steering wheel media buttons,
/// and dedicated motorcycle remotes (Sena RC4/RC3, Flic 2, BlueCadence).
///
/// Features:
/// * Single Press: PTT Intercom speak toggle or momentary hold.
/// * Double Press (<400ms): Quick tactical marker / "Hazard on road" signal.
/// * Triple Press (<600ms) or 2.5s Long Press: Emergency SOS alarm trigger.
/// * Tactile haptic confirmation pulse for gloved feedback.
/// * Zero interference with Bluetooth Classic helmet audio headsets.
class BleRemoteService extends ChangeNotifier {
  BleRemoteService({
    this.intercomService,
    this.networkResilience,
    this.safetyService,
    this.convoyService,
    this.voiceService,
    Set<LogicalKeyboardKey>? supportedKeys,
    bool autoAttachKeyboard = true,
  }) : _supportedKeys = supportedKeys ?? defaultRemoteKeys {
    if (autoAttachKeyboard) {
      _attachKeyboard();
    }
  }

  final IntercomService? intercomService;
  final IntercomNetworkResilience? networkResilience;
  final SafetyService? safetyService;
  final ConvoyService? convoyService;
  final VoiceService? voiceService;

  final Set<LogicalKeyboardKey> _supportedKeys;

  /// Default keys emitted by Bluetooth HID handlebar remotes and camera shutters.
  static final Set<LogicalKeyboardKey> defaultRemoteKeys = {
    LogicalKeyboardKey.audioVolumeDown,
    LogicalKeyboardKey.audioVolumeUp,
    LogicalKeyboardKey.headsetHook,
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
    LogicalKeyboardKey.mediaPause,
    LogicalKeyboardKey.mediaTrackNext,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.camera,
  };

  final ValueNotifier<BleRemoteStatus> statusNotifier =
      ValueNotifier<BleRemoteStatus>(BleRemoteStatus.listening);

  final ValueNotifier<int?> batteryLevelNotifier = ValueNotifier<int?>(95);

  final ValueNotifier<BleRemoteEvent?> lastEventNotifier =
      ValueNotifier<BleRemoteEvent?>(null);

  final StreamController<BleRemoteEvent> _eventStreamController =
      StreamController<BleRemoteEvent>.broadcast();

  Stream<BleRemoteEvent> get eventStream => _eventStreamController.stream;

  BleRemoteStatus get status => statusNotifier.value;
  int? get batteryLevel => batteryLevelNotifier.value;
  BleRemoteEvent? get lastEvent => lastEventNotifier.value;

  // Multi-press timing engine
  int _pressCount = 0;
  Timer? _multiClickTimer;
  Timer? _longPressTimer;
  DateTime? _lastKeyDownTime;
  LogicalKeyboardKey? _currentKey;
  bool _longPressFired = false;
  bool _isKeyPressed = false;
  bool _isDisposed = false;

  /// Maximum interval between clicks to count as multi-press (380ms).
  static const Duration multiClickWindow = Duration(milliseconds: 380);

  /// Contact bounce suppression window (35ms).
  static const Duration contactDebounceWindow = Duration(milliseconds: 35);

  /// Long press duration required to trigger Emergency SOS (2.5 seconds).
  static const Duration longPressThreshold = Duration(milliseconds: 2500);

  void _attachKeyboard() {
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  void _detachKeyboard() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
  }

  /// Manually update remote status (e.g. for BLE scanner connection updates).
  void updateStatus(BleRemoteStatus newStatus) {
    if (statusNotifier.value != newStatus) {
      statusNotifier.value = newStatus;
      notifyListeners();
    }
  }

  /// Manually update battery level percentage [0 .. 100].
  void updateBatteryLevel(int? percent) {
    batteryLevelNotifier.value = percent?.clamp(0, 100);
    notifyListeners();
  }

  /// Exposed for testing or direct hardware key delivery.
  bool handleKeyEvent(KeyEvent event) => _handleKeyEvent(event);

  bool _handleKeyEvent(KeyEvent event) {
    if (_isDisposed) return false;

    // Filter for supported remote keys
    if (!_supportedKeys.contains(event.logicalKey)) {
      return false;
    }

    final now = DateTime.now();

    if (event is KeyRepeatEvent) {
      // Consume key repeat from long holds so OS volume/media overlays don't spam
      return true;
    }

    if (event is KeyDownEvent) {
      // Debounce contact bounce
      if (_lastKeyDownTime != null &&
          now.difference(_lastKeyDownTime!) < contactDebounceWindow) {
        return true;
      }
      _lastKeyDownTime = now;
      _currentKey = event.logicalKey;
      _longPressFired = false;
      _isKeyPressed = true;

      // Mark remote as active/paired
      if (statusNotifier.value != BleRemoteStatus.paired) {
        statusNotifier.value = BleRemoteStatus.paired;
      }

      // Start long press timer (2.5s)
      _longPressTimer?.cancel();
      _longPressTimer = Timer(longPressThreshold, () {
        _longPressFired = true;
        _multiClickTimer?.cancel();
        _pressCount = 0;
        _dispatchGesture(BleRemoteGesture.longPress, event.logicalKey);
      });

      // Increment click count and check immediate triple press
      _pressCount++;
      if (_pressCount >= 3) {
        _longPressTimer?.cancel();
        _multiClickTimer?.cancel();
        final count = _pressCount;
        _pressCount = 0;
        if (count >= 3) {
          _dispatchGesture(BleRemoteGesture.triplePress, event.logicalKey);
        }
        return true;
      }

      return true;
    } else if (event is KeyUpEvent) {
      _isKeyPressed = false;
      _longPressTimer?.cancel();
      if (_longPressFired) {
        // Already handled long-press
        return true;
      }

      // Start or extend multi-click window timer on key release
      _multiClickTimer?.cancel();
      _multiClickTimer = Timer(multiClickWindow, () {
        if (_longPressFired || _isKeyPressed) return;
        final currentCount = _pressCount;
        _pressCount = 0;
        final key = _currentKey ?? event.logicalKey;

        if (currentCount == 1) {
          _dispatchGesture(BleRemoteGesture.singlePress, key);
        } else if (currentCount == 2) {
          _dispatchGesture(BleRemoteGesture.doublePress, key);
        }
      });

      return true;
    }

    return false;
  }

  void _dispatchGesture(BleRemoteGesture gesture, LogicalKeyboardKey key) {
    if (_isDisposed) return;

    final event = BleRemoteEvent(
      gesture: gesture,
      key: key,
      timestamp: DateTime.now(),
    );

    lastEventNotifier.value = event;
    if (!_eventStreamController.isClosed) {
      _eventStreamController.add(event);
    }
    notifyListeners();

    switch (gesture) {
      case BleRemoteGesture.singlePress:
        _handleSinglePress();
        break;
      case BleRemoteGesture.doublePress:
        _handleDoublePress();
        break;
      case BleRemoteGesture.triplePress:
      case BleRemoteGesture.longPress:
        _handleSosTrigger(gesture);
        break;
    }
  }

  /// Single Press: Toggle PTT transmission in IntercomService.
  void _handleSinglePress() {
    HapticFeedback.lightImpact().ignore();
    final ic = intercomService;
    if (ic != null) {
      if (ic.isTransmitting) {
        ic.endTransmission();
      } else if (!ic.isMicMuted) {
        ic.beginTransmission();
      }
    }
  }

  /// Double Press: Dispatch quick tactical marker ("Caution: Hazard on road").
  void _handleDoublePress() {
    HapticFeedback.mediumImpact().ignore();

    // 1. Send tactical network signal if resilience service available
    final nr = networkResilience;
    if (nr != null) {
      nr.sendTacticalSignal(TacticalSignal.hazardOnRoad).ignore();
    }

    // 2. Announce locally via VoiceService
    final vs = voiceService;
    if (vs != null) {
      vs.speak(
        'Caution: Hazard on road.',
        priority: VoicePriority.critical,
        key: 'BLE_REMOTE_HAZARD',
      ).ignore();
    }
  }

  /// Triple Press or Long Press: Immediate Emergency SOS Trigger.
  void _handleSosTrigger(BleRemoteGesture gesture) {
    // Heavy haptic confirmation
    HapticFeedback.heavyImpact().ignore();
    Future.delayed(const Duration(milliseconds: 150), () {
      HapticFeedback.heavyImpact().ignore();
    });

    // 1. Trigger via SafetyService external impact hook if available
    final ss = safetyService;
    if (ss != null) {
      ss.externalImpact(
        source: ExternalImpactSource.wearable,
        g: 3.5,
        atMs: DateTime.now().millisecondsSinceEpoch,
      );
    }

    // 2. Also trigger via ConvoyService directly if safety service is not active
    final cs = convoyService;
    if (cs != null && ss?.alarm == null) {
      final uid = cs.myUserId;
      final me = uid == null ? null : cs.activeConvoy?.riders[uid];
      if (me != null && (me.lat != 0 || me.lng != 0)) {
        cs.raiseSos(
          type: 'MANUAL',
          lat: me.lat,
          lng: me.lng,
          source: EmergencySource.manual,
        );
      }
    }
  }

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _detachKeyboard();
    _multiClickTimer?.cancel();
    _longPressTimer?.cancel();
    _eventStreamController.close();
    statusNotifier.dispose();
    batteryLevelNotifier.dispose();
    lastEventNotifier.dispose();
    super.dispose();
  }
}
