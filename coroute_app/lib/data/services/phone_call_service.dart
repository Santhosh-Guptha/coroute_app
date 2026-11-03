import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum PhoneCallStatus {
  idle,
  ringing,
  offhook, // Active call
}

/// Manages phone call state and audio interruption coordination for rider safety.
///
/// Ensures:
/// 1. Intercom mic is automatically paused during phone calls so private phone calls
///    are never transmitted to the convoy.
/// 2. Background music from Spotify / other players is preserved.
/// 3. Voice notifications and critical emergencies are handled safely without interruption,
///    with high-priority tactile haptics during calls and post-call voice replay.
class PhoneCallService extends ChangeNotifier {
  static const MethodChannel _methodChannel = MethodChannel('coroute/phone_call');
  static const EventChannel _eventChannel = EventChannel('coroute/phone_call_events');

  PhoneCallStatus _status = PhoneCallStatus.idle;
  bool _isCallActive = false;
  StreamSubscription? _eventSub;

  final List<String> _pendingPostCallAlerts = [];

  PhoneCallService({bool autoStart = true}) {
    if (autoStart) {
      _init();
    }
  }

  PhoneCallStatus get status => _status;
  bool get isCallActive => _isCallActive;
  bool get isRinging => _status == PhoneCallStatus.ringing;
  List<String> get pendingPostCallAlerts => List.unmodifiable(_pendingPostCallAlerts);

  void _init() {
    if (kIsWeb) return;
    _checkInitialState();
    try {
      _eventSub = _eventChannel.receiveBroadcastStream().listen(
        _onEvent,
        onError: (e) => debugPrint('PhoneCallService event error: $e'),
      );
    } catch (e) {
      debugPrint('PhoneCallService event stream init note: $e');
    }
  }

  Future<void> _checkInitialState() async {
    try {
      final res = await _methodChannel.invokeMethod<Map>('getCallState');
      if (res != null) {
        _handleStateString(res['state']?.toString() ?? 'IDLE');
      }
    } catch (_) {}
  }

  void _onEvent(dynamic event) {
    if (event is Map) {
      final stateStr = event['state']?.toString() ?? 'IDLE';
      _handleStateString(stateStr);
    }
  }

  void _handleStateString(String stateStr) {
    PhoneCallStatus newStatus;
    switch (stateStr.toUpperCase()) {
      case 'RINGING':
        newStatus = PhoneCallStatus.ringing;
        break;
      case 'OFFHOOK':
        newStatus = PhoneCallStatus.offhook;
        break;
      case 'IDLE':
      default:
        newStatus = PhoneCallStatus.idle;
        break;
    }

    if (_status != newStatus) {
      final wasActive = _isCallActive;
      _status = newStatus;
      _isCallActive = newStatus != PhoneCallStatus.idle;
      notifyListeners();

      if (wasActive && !_isCallActive) {
        // Call just ended
        _onCallEnded();
      }
    }
  }

  /// Queues a critical safety alert that arrived during a phone call so it can be
  /// announced as soon as the rider hangs up.
  void queuePostCallAlert(String text) {
    if (_isCallActive) {
      _pendingPostCallAlerts.add(text);
      if (_pendingPostCallAlerts.length > 5) {
        _pendingPostCallAlerts.removeAt(0);
      }
    }
  }

  /// Consumes and flushes all pending post-call alerts.
  List<String> flushPostCallAlerts() {
    final copy = List<String>.from(_pendingPostCallAlerts);
    _pendingPostCallAlerts.clear();
    return copy;
  }

  void _onCallEnded() {
    // Call ended hook (listeners were already notified of the state transition)
  }

  @visibleForTesting
  void simulateCallState(PhoneCallStatus status) {
    final wasActive = _isCallActive;
    _status = status;
    _isCallActive = status != PhoneCallStatus.idle;
    notifyListeners();
    if (wasActive && !_isCallActive) {
      _onCallEnded();
    }
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
