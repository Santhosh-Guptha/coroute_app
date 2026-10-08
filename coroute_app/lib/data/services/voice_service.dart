import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants/ride_notification_constants.dart';
import 'settings_service.dart';

/// How urgent a spoken alert is. Critical (emergencies) interrupts whatever is
/// being said; warning (hazards, directions) waits its turn.
enum VoicePriority { critical, warning }

/// The speech engine behind [VoiceService] (the phone's text-to-speech; a fake in tests).
abstract class VoiceEngine {
  /// Binds the engine and picks a language. False when there is no usable engine or voice.
  Future<bool> init();

  /// [interrupt] true drops anything queued or being said (QUEUE_FLUSH), else it is queued.
  Future<bool> speak(String text, {required bool interrupt, required String id});
  Future<void> stop();

  /// Unbinds the engine (ride end).
  Future<void> release();
}

/// Android TextToSpeech through MethodChannel `coroute/tts` (TtsChannel.kt): Indian
/// English when installed, else US English; ducks other audio while speaking.
class NativeVoiceEngine implements VoiceEngine {
  NativeVoiceEngine({MethodChannel? channel}) : _ch = channel ?? const MethodChannel(NotifConstants.ttsChannel);

  final MethodChannel _ch;

  /// The language the engine uses ('en-IN', 'en-US'), '' before [init] or without a voice.
  String language = '';

  @override
  Future<bool> init() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final r = await _ch.invokeMethod<Object?>('init');
      if (r is! Map) return false;
      language = r['language']?.toString() ?? '';
      return r['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> speak(String text, {required bool interrupt, required String id}) async {
    try {
      return (await _ch.invokeMethod<bool>('speak', {'text': text, 'id': id, 'interrupt': interrupt})) == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {}
  }

  @override
  Future<void> release() async {
    try {
      await _ch.invokeMethod<void>('release');
    } catch (_) {}
  }
}

/// Short spoken alerts during a ride ("Emergency. Rahul may have met with an
/// accident 4.8 kilometers behind you.").
///
/// - Critical alerts speak when "Speak emergency alerts" is on (default on) and
///   interrupt anything being said.
/// - Warnings (hazards, emergency navigation distances) speak when "Speak warnings
///   and directions" is on AND the group has voice guidance on; they queue, and
///   never more than [NotifConstants.voiceMaxQueued] wait (extra ones are dropped).
/// - The same key is spoken at most once per [NotifConstants.voiceDedupe].
/// - The engine starts on the first alert of a ride (nothing at idle) and is
///   released at ride end. Without an engine or an English voice everything is
///   silent ([available] false); banners and notifications still show.
/// - Social alerts are never spoken (the callers never pass them).
class VoiceService extends ChangeNotifier {
  VoiceService(this._settings, {VoiceEngine? engine, int Function()? clock})
      : _engine = engine ?? NativeVoiceEngine(),
        _clock = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final SettingsService _settings;
  final VoiceEngine _engine;
  final int Function() _clock;

  Future<bool>? _init;
  bool _available = false;
  bool _failed = false;
  bool _groupVoice = true;
  int _seq = 0;

  /// key -> when it was last spoken (only keys from the last [NotifConstants.voiceDedupe]).
  final Map<String, int> _spoken = {};

  /// Estimated end times of what was handed to the engine (to cap the queue).
  final List<int> _queueEnds = [];

  /// The engine is running with a usable language.
  bool get available => _available;

  /// The group's "Voice guidance" switch (convoy.voiceGuidanceEnabled), set by AlertService.
  void setGroupVoice(bool enabled) => _groupVoice = enabled;

  @visibleForTesting
  bool get groupVoice => _groupVoice;

  bool _allowed(VoicePriority p) => switch (p) {
        VoicePriority.critical => _settings.voiceCritical,
        VoicePriority.warning => _settings.voiceWarnings && _groupVoice,
      };

  /// About how long the engine takes to say [text] (for the queue cap only).
  static int estimateMs(String text) => 600 + text.length * 70;

  /// Speaks [text] once. False when it was not spoken (setting off, duplicate key,
  /// queue full, no engine).
  Future<bool> speak(String text, {VoicePriority priority = VoicePriority.warning, String? key}) async {
    final t = text.trim();
    if (t.isEmpty || !_allowed(priority) || _failed) return false;
    final now = _clock();
    _spoken.removeWhere((_, at) => now - at >= NotifConstants.voiceDedupe.inMilliseconds);
    final k = key ?? t;
    if (_spoken.containsKey(k)) return false;
    final interrupt = priority == VoicePriority.critical;
    _queueEnds.removeWhere((end) => end <= now);
    if (!interrupt && _queueEnds.length >= NotifConstants.voiceMaxQueued) return false;
    // Taken before the first await, so two quick calls with the same key speak once.
    _spoken[k] = now;
    final ok = await _ensureEngine();
    if (!ok) {
      _spoken.remove(k);
      return false;
    }
    final said = t.length > NotifConstants.voiceMaxChars ? t.substring(0, NotifConstants.voiceMaxChars) : t;
    bool spoken;
    try {
      spoken = await _engine.speak(said, interrupt: interrupt, id: 'v${++_seq}');
    } catch (_) {
      spoken = false;
    }
    if (!spoken) {
      _spoken.remove(k);
      return false;
    }
    final at = _clock();
    if (interrupt) _queueEnds.clear();
    final start = _queueEnds.isEmpty ? at : _queueEnds.reduce((a, b) => a > b ? a : b);
    _queueEnds.add(start + estimateMs(said));
    return true;
  }

  Future<bool> _ensureEngine() async {
    final f = _init ??= _start();
    return f;
  }

  Future<bool> _start() async {
    bool ok;
    try {
      ok = await _engine.init();
    } catch (_) {
      ok = false;
    }
    if (ok != _available) {
      _available = ok;
      notifyListeners();
    }
    // No engine or no English voice: silent for this ride (tried again after release).
    if (!ok) _failed = true;
    return ok;
  }

  /// Stops what is being said and drops the queue.
  Future<void> stop() async {
    _queueEnds.clear();
    if (_init == null) return;
    try {
      await _engine.stop();
    } catch (_) {}
  }

  /// Ride end: the engine is unbound; the next alert starts it again.
  Future<void> release() async {
    _queueEnds.clear();
    _spoken.clear();
    final wasStarted = _init != null;
    _init = null;
    _failed = false;
    if (_available) {
      _available = false;
      notifyListeners();
    }
    if (!wasStarted) return;
    try {
      await _engine.release();
    } catch (_) {}
  }

  /// The engine was started in this ride (tests and main.dart's ride-end hook).
  bool get started => _init != null;
}
