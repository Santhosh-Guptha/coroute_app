import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants/ride_notification_constants.dart';
import '../../core/l10n/l10n.dart';
import 'settings_service.dart';

/// How urgent a spoken alert is. Critical (emergencies) interrupts whatever is
/// being said; important (3.16: stopped rider, separation, stale update, low
/// battery) and warning (hazards, directions) wait their turn. Important ones
/// are also spoken after dark with "Speak more after dark" (see [VoiceService]).
enum VoicePriority { critical, important, warning }

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

/// An engine that can say which language it ended up with (3.16). [VoiceService]
/// uses it for [VoiceService.speechLang]; engines without it count as English.
abstract class VoiceEngineLanguage {
  /// BCP 47 tag the engine confirmed ('hi-IN', 'en-IN'), '' before init or without a voice.
  String get language;
}

/// Android TextToSpeech through MethodChannel `coroute/tts` (TtsChannel.kt): the
/// language of the app's safety setting (Hindi or Telugu when the phone has the
/// voice), else Indian English, else US English; ducks other audio while speaking.
class NativeVoiceEngine implements VoiceEngine, VoiceEngineLanguage {
  NativeVoiceEngine({MethodChannel? channel}) : _ch = channel ?? const MethodChannel(NotifConstants.ttsChannel);

  final MethodChannel _ch;

  /// The language the engine uses ('en-IN', 'hi-IN'), '' before [init] or without a voice.
  @override
  String language = '';

  @override
  Future<bool> init() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final r = await _ch.invokeMethod<Object?>('init', {'language': L10n.ttsTag});
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
/// - Important alerts (3.16) speak like warnings, and also after dark when "Speak
///   more after dark" is on and voice is on at all ("Speak emergency alerts").
/// - The same key is spoken at most once per [NotifConstants.voiceDedupe].
/// - The engine starts on the first alert of a ride (nothing at idle) and is
///   released at ride end. Without an engine or a usable voice everything is
///   silent ([available] false); banners and notifications still show.
/// - The engine is asked for the safety language (Hindi, Telugu); [speechLang]
///   says which one it confirmed, so alert texts are built in a language the
///   phone can actually say. A language change releases the engine; the next
///   alert starts it again in the new language.
/// - Social alerts are never spoken (the callers never pass them).
class VoiceService extends ChangeNotifier {
  VoiceService(this._settings, {VoiceEngine? engine, int Function()? clock})
      : _engine = engine ?? NativeVoiceEngine(),
        _clock = clock ?? _wallClock {
    L10n.changes.addListener(_onLanguage);
  }

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final SettingsService _settings;
  final VoiceEngine _engine;
  final int Function() _clock;

  Future<bool>? _init;
  bool _available = false;
  bool _failed = false;
  bool _groupVoice = true;
  bool _night = false;
  String _requested = 'en';
  String _speechLang = 'en';
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

  /// After sunset (set by SafetyService from the ride's fixes): important alerts are
  /// spoken too when "Speak more after dark" is on.
  void setNight(bool dark) => _night = dark;

  @visibleForTesting
  bool get night => _night;

  /// 'hi', 'te' or 'en': the safety language when the engine confirmed that voice,
  /// else 'en' (texts for speech are built in this language).
  String get speechLang => _speechLang;

  /// The settings used by this voice service.
  SettingsService get settings => _settings;

  bool _allowed(VoicePriority p) => switch (p) {
        VoicePriority.critical => _settings.voiceCritical,
        VoicePriority.warning => _settings.voiceWarnings && _groupVoice,
        VoicePriority.important =>
          (_settings.voiceWarnings && _groupVoice) || (_settings.speakMoreAfterDark && _night && _settings.voiceCritical),
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

  /// High-priority alert when Sweeper has halted or encountered distress (REQ-13).
  Future<bool> speakSweeperDistress({required String name, double? distanceKm}) {
    final dist = distanceKm != null ? ' ${distanceKm.toStringAsFixed(1)} kilometers behind' : '';
    return speak('Alert: Sweeper stopped$dist', priority: VoicePriority.critical, key: 'sweeper_distress');
  }

  /// Important alert when convoy splits into separate packs (REQ-11).
  Future<bool> speakConvoySplit({int? leadCount, int? trailCount, double? gapKm}) {
    final gap = gapKm != null ? ', ${gapKm.toStringAsFixed(1)} kilometers behind' : '';
    return speak('Warning: Convoy split into two packs$gap', priority: VoicePriority.important, key: 'convoy_split');
  }

  /// Important alert when lead sets a regroup rendezvous point (REQ-12).
  Future<bool> speakRegroupAlert({required String locationName}) {
    final loc = locationName.trim().isEmpty ? 'ahead' : 'at ${locationName.trim()}';
    return speak('Regroup point designated $loc', priority: VoicePriority.important, key: 'regroup_ahead');
  }

  /// Low fuel advisory warning (REQ-07, REQ-08).
  Future<bool> speakFuelRangeWarning({required double usableKm}) {
    return speak('Low fuel warning: ${usableKm.round()} kilometers remaining', priority: VoicePriority.warning, key: 'fuel_low');
  }

  Future<bool> _ensureEngine() async {
    final f = _init ??= _start();
    return f;
  }

  Future<bool> _start() async {
    bool ok;
    _requested = L10n.current;
    try {
      ok = await _engine.init();
    } catch (_) {
      ok = false;
    }
    final e = _engine;
    final got = ok && e is VoiceEngineLanguage ? (e as VoiceEngineLanguage).language.toLowerCase() : '';
    _speechLang = _requested != 'en' && got.startsWith(_requested) ? _requested : 'en';
    if (ok != _available) {
      _available = ok;
      notifyListeners();
    }
    // No engine or no usable voice: silent for this ride (tried again after release).
    if (!ok) _failed = true;
    return ok;
  }

  void _onLanguage() {
    // Re-init with the new language on the next alert (in practice between rides:
    // main.dart releases the engine at ride end anyway).
    _speechLang = 'en';
    if (_init != null) release().ignore();
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

  @override
  void dispose() {
    L10n.changes.removeListener(_onLanguage);
    super.dispose();
  }
}
