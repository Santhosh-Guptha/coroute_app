import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants/ride_notification_constants.dart';
import '../../domain/audio/audio_diag_log.dart';
import '../../domain/safety/effective_speed_limit.dart';
import '../../domain/safety/speed_audio_policy.dart';
import '../../domain/tracking/track_point.dart';
import '../models/convoy_model.dart';
import 'convoy_service.dart';
import 'feature_flags_service.dart';
import 'intercom_service.dart';
import 'safety_service.dart';
import 'settings_service.dart';

/// Native half of "Lower music when speeding" (TtsChannel.kt / MediaVolumeGuard.kt, MethodChannel
/// `coroute/tts`). Replaceable in tests. Every call answers `{lowered, paused, userChanged}`.
class SpeedAudioChannel {
  SpeedAudioChannel({MethodChannel? channel}) : _ch = channel ?? const MethodChannel(NotifConstants.ttsChannel);
  final MethodChannel _ch;

  static bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<bool> _call(String action, {double fraction = 1.0, bool pause = false}) async {
    if (!_supported) return false;
    try {
      final r = await _ch.invokeMethod<Object?>('speedAudio', {'action': action, 'fraction': fraction, 'pause': pause});
      if (r is Map && action != 'status') {
        AudioDiagLog.add('speed music $action ${pause ? 'pause' : '${(fraction * 100).round()}%'}: '
            'lowered=${r['lowered']} paused=${r['paused']} mode=${r['mode']} userChanged=${r['userChanged']}');
      }
      return r is Map && r['userChanged'] == true;
    } catch (e) {
      AudioDiagLog.add('speed music $action failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Lowers other apps' music to [level]. True when the rider had changed the volume (nothing applied).
  Future<bool> apply(SpeedAudioLevel level) => _call('apply', fraction: level.fraction, pause: level.isPause);

  /// Restores the rider's volume smoothly and resumes paused music.
  Future<bool> restore() => _call('restore');

  /// Forgets the saved volume without touching anything (the rider took over).
  Future<bool> forget() => _call('forget');

  /// True when the rider changed the volume / resumed the music since the last call.
  Future<bool> status() => _call('status');

  /// The intercom plays a rider's voice: kept at the original volume while music is lowered.
  Future<void> ownAudio(bool active) async {
    if (!_supported) return;
    try {
      await _ch.invokeMethod<void>('ownAudio', {'active': active});
    } catch (_) {}
  }
}

/// 3.55 "Lower music when speeding" (setting [SettingsService.lowerMusicWhenSpeeding], default on;
/// admin switch `speedAudio`, unknown = on). Feeds my GPS fixes and the effective speed limit into
/// [SpeedAudioPolicy] and applies its commands on the native side. The limit is the strictest
/// known one, the same values the rider is warned about:
///  * SafetyService's rule: the group limit (with the lead's town limit near start, destination and
///    stops) and my own limit (Settings > Speed warning);
///  * 3.55 fix: the ROAD limit / school or hospital zone from Road care (admin switch
///    `speedLimits`), which is what most riders are warned at (no group or personal limit is set by
///    default). Music used to stay loud then, because only the group / personal limit was used.
/// Solo rides (offline) count as rides too (Road care warns there as well). The overspeed voice warning itself stays in SafetyService / VoiceService (far over the
/// limit it is a critical line on the alarm stream, so it is never quieted by this).
///
/// Restores the music: after 5 s back under the limit, at ride end, on an SOS / crash alarm, when the
/// setting or the admin switch goes off, when fixes stop for [staleFixAfter], and (native side) when
/// the app's screen engine goes away or at the next start after a kill.
///
/// Wiring (main.dart, by the lead):
/// ```dart
///   Provider<SpeedAudioService>(lazy: false, create: (ctx) => SpeedAudioService(
///       ctx.read<ConvoyService>(), ctx.read<SettingsService>(),
///       safety: ctx.read<SafetyService>(), intercom: ctx.read<IntercomService>()),
///     dispose: (_, s) => s.dispose()),
/// ```
class SpeedAudioService {
  SpeedAudioService(
    this._convoys,
    this._settings, {
    this.safety,
    this.intercom,
    SpeedAudioChannel? channel,
    SpeedAudioPolicy? policy,
    bool Function(String id)? featureOn,
    int Function()? clock,
    int Function()? roadLimitKmh,
  })  : _channel = channel ?? SpeedAudioChannel(),
        _policy = policy ?? SpeedAudioPolicy(),
        _featureOn = featureOn ?? FeatureFlagsService.on,
        _clock = clock ?? _wallClock,
        _roadLimit = roadLimitKmh {
    _fixSub = _convoys.myFixes.listen(onFix, onError: (Object _) {});
    _convoys.addListener(_onState);
    _settings.addListener(_onState);
    safety?.addListener(_onState);
    intercom?.addListener(_onIntercom);
    FeatureFlagsService.instance?.addListener(_onState);
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// No fix for this long while music is lowered: restore (GPS lost, app paused...).
  static const Duration staleFixAfter = Duration(seconds: 15);

  final ConvoyService _convoys;
  final SettingsService _settings;
  /// Open SOS / crash alarm ends the episode at once.
  final SafetyService? safety;

  /// Its received voice is kept at the original volume while music is lowered.
  final IntercomService? intercom;
  final SpeedAudioChannel _channel;
  final SpeedAudioPolicy _policy;
  final bool Function(String id) _featureOn;
  final int Function() _clock;
  final int Function()? _roadLimit;

  StreamSubscription<TrackPoint>? _fixSub;
  Timer? _staleTimer;
  Future<void> _chain = Future<void>.value();
  bool _ownAudioOn = false;
  bool _disposed = false;

  @visibleForTesting
  SpeedAudioPolicy get policy => _policy;

  bool get _enabled => _settings.lowerMusicWhenSpeeding && _featureOn('speedAudio');
  bool get _emergency => safety?.emergencyOpen ?? false;

  bool get _rideActive {
    if (safety?.offlineSoloActive ?? false) return true;
    final c = _convoys.activeConvoy;
    return c != null && _convoys.myUserId != null && c.tripStatus != 'ENDED';
  }

  /// The road limit / zone limit where I am (0 = none known): Road care's last context.
  int _roadLimitHere() {
    final f = _roadLimit;
    if (f != null) return f();
    if (!_featureOn('speedLimits')) return 0;
    return safety?.roadCare.limitHere?.limitKmh ?? 0;
  }

  /// The strictest positive limit of [a] and [b] (0 = none).
  static int stricter(int a, int b) {
    if (a <= 0) return b > 0 ? b : 0;
    if (b <= 0) return a;
    return a < b ? a : b;
  }

  /// The effective limit at [p], the same rule SafetyService warns at.
  static int limitAt(ConvoyModel? c, TrackPoint p, int personalKmh) {
    final group = c == null
        ? 0
        : groupLimitAt(
            groupKmh: c.speedLimitKmh,
            townKmh: c.townLimitKmh,
            lat: p.lat,
            lng: p.lng,
            places: [
              if (c.startLat != null && c.startLng != null) (c.startLat!, c.startLng!),
              (c.destinationLat, c.destinationLng),
              for (final s in c.plannedStops) (s.lat, s.lng),
            ],
          );
    return effectiveSpeedLimit(groupKmh: group, personalKmh: personalKmh);
  }

  @visibleForTesting
  void onFix(TrackPoint p) {
    if (_disposed) return;
    if (!_rideActive) {
      _end();
      return;
    }
    final limit = stricter(limitAt(_convoys.activeConvoy, p, _settings.speedLimitWarningKmh), _roadLimitHere());
    final cmd = _policy.onSample(speedKmh: p.speedKmh, limitKmh: limit, nowMs: _clock(), enabled: _enabled, emergency: _emergency);
    if (cmd != null) {
      _send(cmd);
    } else if (_policy.applied != SpeedAudioLevel.normal && !_policy.userOverride) {
      _enqueue(() async {
        if (await _channel.status()) _policy.noteUserAdjusted();
      });
    }
    _armStale();
  }

  void _armStale() {
    _staleTimer?.cancel();
    if (!_policy.episodeActive) return;
    _staleTimer = Timer(staleFixAfter, _end);
  }

  void _onState() {
    if (_disposed) return;
    if (!_rideActive || !_enabled || _emergency) _end();
  }

  void _onIntercom() {
    final i = intercom;
    if (_disposed || i == null) return;
    final want = i.isReceiving && _policy.applied != SpeedAudioLevel.normal && !_policy.userOverride;
    _setOwnAudio(want);
  }

  void _setOwnAudio(bool on) {
    if (_ownAudioOn == on) return;
    _ownAudioOn = on;
    _enqueue(() => _channel.ownAudio(on));
  }

  void _end() {
    _staleTimer?.cancel();
    _staleTimer = null;
    final cmd = _policy.end();
    if (cmd != null) _send(cmd);
  }

  void _send(SpeedAudioCommand cmd) {
    AudioDiagLog.add('speed music policy: ${cmd.kind.name} ${cmd.level.name}');
    switch (cmd.kind) {
      case SpeedAudioCommandKind.apply:
        _enqueue(() async {
          if (await _channel.apply(cmd.level)) _policy.noteUserAdjusted();
        });
        _onIntercom();
        break;
      case SpeedAudioCommandKind.restore:
        _setOwnAudio(false);
        _enqueue(() async => await _channel.restore());
        break;
      case SpeedAudioCommandKind.forget:
        _setOwnAudio(false);
        _enqueue(() async => await _channel.forget());
        break;
    }
  }

  /// Native calls run one after another, in order.
  void _enqueue(Future<void> Function() job) {
    _chain = _chain.then((_) => job()).then((_) {}, onError: (Object _) {});
  }

  void dispose() {
    if (_disposed) return;
    _end();
    _disposed = true;
    _fixSub?.cancel();
    _convoys.removeListener(_onState);
    _settings.removeListener(_onState);
    safety?.removeListener(_onState);
    intercom?.removeListener(_onIntercom);
    FeatureFlagsService.instance?.removeListener(_onState);
  }
}
