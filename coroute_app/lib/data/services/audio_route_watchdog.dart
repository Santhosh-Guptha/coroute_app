import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'convoy_service.dart';
import 'intercom_service.dart';

export 'intercom_service.dart' show ActiveSpeakerInfo;

/// Available audio output routes for CoRoute intercom.
enum AudioRouteType {
  bluetooth,
  speaker,
  earpiece,
  wiredHeadset,
  unknown,
}

/// Health state of the audio routing pipeline.
class AudioHealthState {
  final bool isBluetoothConnected;
  final double volumeLevel;
  final bool isVolumeMuted;
  final bool isAudioRoutingIssue;
  final bool bluetoothExpected;
  final String? statusDescription;

  const AudioHealthState({
    this.isBluetoothConnected = true,
    this.volumeLevel = 1.0,
    this.isVolumeMuted = false,
    this.isAudioRoutingIssue = false,
    this.bluetoothExpected = true,
    this.statusDescription,
  });

  AudioHealthState copyWith({
    bool? isBluetoothConnected,
    double? volumeLevel,
    bool? isVolumeMuted,
    bool? isAudioRoutingIssue,
    bool? bluetoothExpected,
    String? statusDescription,
  }) {
    final newVol = volumeLevel ?? this.volumeLevel;
    final newMuted = isVolumeMuted ?? (newVol <= 0.0);
    return AudioHealthState(
      isBluetoothConnected: isBluetoothConnected ?? this.isBluetoothConnected,
      volumeLevel: newVol,
      isVolumeMuted: newMuted,
      isAudioRoutingIssue: isAudioRoutingIssue ?? this.isAudioRoutingIssue,
      bluetoothExpected: bluetoothExpected ?? this.bluetoothExpected,
      statusDescription: statusDescription ?? this.statusDescription,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioHealthState &&
          runtimeType == other.runtimeType &&
          isBluetoothConnected == other.isBluetoothConnected &&
          volumeLevel == other.volumeLevel &&
          isVolumeMuted == other.isVolumeMuted &&
          isAudioRoutingIssue == other.isAudioRoutingIssue &&
          bluetoothExpected == other.bluetoothExpected &&
          statusDescription == other.statusDescription;

  @override
  int get hashCode => Object.hash(
        isBluetoothConnected,
        volumeLevel,
        isVolumeMuted,
        isAudioRoutingIssue,
        bluetoothExpected,
        statusDescription,
      );

  @override
  String toString() =>
      'AudioHealthState(bt: $isBluetoothConnected, vol: $volumeLevel, muted: $isVolumeMuted, issue: $isAudioRoutingIssue, status: $statusDescription)';
}

/// Watchdog service to monitor audio output routes, volume drops, and Bluetooth drops.
///
/// Ensures motorcycle riders on live intercom are instantly notified of audio failures:
/// - Detects Bluetooth disconnects from helmet headsets and flags routing issues.
/// - Detects accidental 0% volume / mute states.
/// - Provides emergency intercom volume boost to 100%.
/// - Manages Bluetooth headset reconnection attempts (including Bluetooth SCO).
class AudioRouteWatchdog extends ChangeNotifier {
  static const MethodChannel _defaultChannel = MethodChannel('coroute/audio_watchdog');

  final ConvoyService? convoyService;
  final MethodChannel? _channel;
  final Future<bool> Function()? onReconnectBluetooth;
  final Future<void> Function(double volume)? onSetVolume;

  bool _isBluetoothConnected;
  double _volumeLevel;
  bool _isVolumeMuted = false;
  bool bluetoothExpected;
  bool _mockDisconnected = false;
  bool _mockMuted = false;
  bool _mockConvoyActive = false;
  AudioRouteType _currentRoute = AudioRouteType.bluetooth;

  late final ValueNotifier<AudioHealthState> healthNotifier;
  late final ValueNotifier<ActiveSpeakerInfo?> activeSpeakerNotifier;

  AudioRouteWatchdog({
    this.convoyService,
    MethodChannel? channel,
    double initialVolume = 1.0,
    bool initialBluetoothConnected = true,
    this.bluetoothExpected = true,
    AudioRouteType initialRoute = AudioRouteType.bluetooth,
    this.onReconnectBluetooth,
    this.onSetVolume,
    IntercomService? intercomService,
  })  : _channel = channel ?? (kIsWeb ? null : _defaultChannel),
        _volumeLevel = initialVolume.clamp(0.0, 1.0),
        _isBluetoothConnected = initialBluetoothConnected,
        _currentRoute = initialRoute {
    _isVolumeMuted = _volumeLevel <= 0.0;

    final initialState = _calculateHealthState();
    healthNotifier = ValueNotifier<AudioHealthState>(initialState);
    activeSpeakerNotifier = ValueNotifier<ActiveSpeakerInfo?>(null);

    convoyService?.addListener(_onConvoyUpdated);

    if (intercomService != null) {
      intercomService.activeSpeakerNotifier.addListener(() {
        activeSpeakerNotifier.value = intercomService.activeSpeakerNotifier.value;
      });
    }
  }

  void _onConvoyUpdated() {
    _updateHealthState();
  }

  bool get isConvoyActive => _mockConvoyActive || (convoyService?.activeConvoy != null);
  bool get isBluetoothConnected => !_mockDisconnected && _isBluetoothConnected;
  double get volumeLevel => _mockMuted ? 0.0 : _volumeLevel;
  double get currentVolume => volumeLevel;
  bool get isVolumeMuted => _isVolumeMuted;
  bool get isAudioRoutingIssue => healthNotifier.value.isAudioRoutingIssue;
  AudioRouteType get currentRoute => _currentRoute;
  AudioHealthState get state => healthNotifier.value;

  AudioHealthState _calculateHealthState() {
    final btDropped = _mockDisconnected || (bluetoothExpected && !_isBluetoothConnected);
    _isVolumeMuted = _mockMuted || _volumeLevel <= 0.0;
    // Audio routing issue: Bluetooth expected but dropped, OR volume is muted during active convoy (or in mock)
    final routingIssue = btDropped || (_isVolumeMuted && (isConvoyActive || _mockMuted));

    String? status;
    if (btDropped) {
      status = 'HELMET_BLUETOOTH_DISCONNECTED';
    } else if (_isVolumeMuted && (isConvoyActive || _mockMuted)) {
      status = 'INTERCOM_VOLUME_MUTED';
    } else {
      status = 'HEALTHY';
    }

    return AudioHealthState(
      isBluetoothConnected: !_mockDisconnected && _isBluetoothConnected,
      volumeLevel: _mockMuted ? 0.0 : _volumeLevel,
      isVolumeMuted: _isVolumeMuted,
      isAudioRoutingIssue: routingIssue,
      bluetoothExpected: bluetoothExpected,
      statusDescription: status,
    );
  }

  AudioHealthState _updateHealthState() {
    final newState = _calculateHealthState();
    if (healthNotifier.value != newState) {
      healthNotifier.value = newState;
    }
    notifyListeners();
    return newState;
  }

  /// Evaluates current audio setup and updates [healthNotifier].
  Future<AudioHealthState> checkAudioHealth() async {
    final ch = _channel;
    if (ch != null && !_mockDisconnected && !_mockMuted) {
      try {
        final res = await ch.invokeMethod<Map<Object?, Object?>>('getAudioStatus');
        if (res != null) {
          if (res.containsKey('bluetoothConnected')) {
            _isBluetoothConnected = res['bluetoothConnected'] == true;
          }
          if (res.containsKey('volume')) {
            final v = res['volume'];
            if (v is num) {
              _volumeLevel = v.toDouble().clamp(0.0, 1.0);
              _isVolumeMuted = _volumeLevel <= 0.0;
            }
          }
          if (res.containsKey('bluetoothExpected')) {
            bluetoothExpected = res['bluetoothExpected'] == true;
          }
        }
      } catch (_) {}
    }

    return _updateHealthState();
  }

  /// Requests Bluetooth SCO reconnection.
  Future<bool> attemptReconnectBluetooth() async {
    bool success = true;
    _mockDisconnected = false;
    _isBluetoothConnected = true;
    _currentRoute = AudioRouteType.bluetooth;
    _updateHealthState();

    final onReconnect = onReconnectBluetooth;
    final ch = _channel;
    if (onReconnect != null) {
      success = await onReconnect();
    } else if (ch != null) {
      try {
        final res = await ch.invokeMethod<bool>('reconnectBluetooth');
        success = res ?? true;
      } catch (_) {
        success = true;
      }
    }

    if (!success) {
      _isBluetoothConnected = false;
      _currentRoute = AudioRouteType.speaker;
      _updateHealthState();
    }

    return success;
  }

  /// Alias for attemptReconnectBluetooth.
  Future<bool> reconnectBluetooth() => attemptReconnectBluetooth();

  /// Resets intercom volume to 100%.
  Future<void> boostIntercomVolume() async {
    _mockMuted = false;
    _volumeLevel = 1.0;
    _isVolumeMuted = false;

    final onSetVol = onSetVolume;
    final ch = _channel;
    if (onSetVol != null) {
      await onSetVol(1.0);
    } else if (ch != null) {
      try {
        await ch.invokeMethod<void>('setVolume', {'volume': 1.0});
      } catch (_) {}
    }

    _updateHealthState();
  }

  /// Testing helper to mock Bluetooth disconnection.
  void setMockBluetoothDisconnected(bool disconnected) {
    _mockDisconnected = disconnected;
    if (disconnected) {
      _isBluetoothConnected = false;
    } else {
      _isBluetoothConnected = true;
    }
    _updateHealthState();
  }

  /// Testing helper to mock volume mute.
  void setMockVolumeMuted(bool muted) {
    _mockMuted = muted;
    if (muted) {
      _volumeLevel = 0.0;
      _isVolumeMuted = true;
    } else {
      _volumeLevel = 1.0;
      _isVolumeMuted = false;
    }
    _updateHealthState();
  }

  /// Testing helper to mock active convoy status.
  void setMockConvoyActive(bool active) {
    _mockConvoyActive = active;
    _updateHealthState();
  }

  /// Testing helper for active speaker updates.
  void onSpeakerActive({
    required String speakerId,
    required String speakerName,
    bool isLead = false,
    bool isEmergency = false,
  }) {
    activeSpeakerNotifier.value = ActiveSpeakerInfo(
      speakerId: speakerId,
      speakerName: speakerName,
      isLead: isLead,
      isEmergency: isEmergency,
      timestamp: DateTime.now(),
    );
    notifyListeners();
  }

  /// Testing helper for clearing active speaker.
  void onSpeakerIdle() {
    activeSpeakerNotifier.value = null;
    notifyListeners();
  }

  void onBluetoothStateChanged(bool connected) {
    _isBluetoothConnected = connected;
    if (!connected) {
      if (_currentRoute == AudioRouteType.bluetooth) {
        _currentRoute = AudioRouteType.speaker;
      }
    } else {
      _currentRoute = AudioRouteType.bluetooth;
    }
    _updateHealthState();
  }

  void handleBluetoothDisconnection() => onBluetoothStateChanged(false);

  void onAudioRouteChanged(AudioRouteType newRoute) {
    if (_currentRoute == newRoute) return;
    final previous = _currentRoute;
    _currentRoute = newRoute;

    if (previous == AudioRouteType.bluetooth && newRoute != AudioRouteType.bluetooth) {
      _isBluetoothConnected = false;
    }
    _updateHealthState();
  }

  void onVolumeChanged(double volume) {
    _volumeLevel = volume.clamp(0.0, 1.0);
    _isVolumeMuted = _volumeLevel <= 0.0;
    _updateHealthState();
  }

  void clearAudioRoutingIssue() {
    _mockDisconnected = false;
    _mockMuted = false;
    _updateHealthState();
  }

  @override
  void dispose() {
    convoyService?.removeListener(_onConvoyUpdated);
    healthNotifier.dispose();
    activeSpeakerNotifier.dispose();
    super.dispose();
  }
}
