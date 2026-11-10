import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants/ride_notification_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../domain/audio/audio_diag_log.dart';
import '../../domain/audio/sound_alert_policy.dart';
import 'audio_priority_manager.dart';
import 'phone_call_service.dart';
import 'settings_service.dart';

/// How urgent a spoken alert is. Critical (emergencies) interrupts whatever is
/// being said; important (3.16: stopped rider, separation, stale update, low
/// battery) and warning (hazards, directions) wait their turn. Important ones
/// are also spoken after dark (see [VoiceService]).
enum VoicePriority { critical, important, warning }

/// The speech engine behind [VoiceService] (the phone's text-to-speech; a fake in tests).
abstract class VoiceEngine {
  /// Binds the engine and picks a language. False when there is no usable engine or voice.
  Future<bool> init();

  /// [interrupt] true drops anything queued or being said (QUEUE_FLUSH), else it is queued.
  Future<bool> speak(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
  });
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

/// 3.55: extra native abilities of the real engine (fakes in tests do not need them; the
/// [AudioPriorityManager] checks `engine is VoiceEngineExtras`).
abstract class VoiceEngineExtras {
  /// Like [VoiceEngine.speak], plus [inCall] (a critical phrase in the phone call's audio, after a short
  /// tone) and [afterCall] (wait until the phone left call mode, then speak).
  Future<bool> speakExtended(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
    bool inCall = false,
    bool afterCall = false,
  });

  /// Tone + vibration when speech is impossible ([critical]: alarm stream, long buzz).
  Future<void> fallbackAlert({required bool critical, bool inCall = false});
}

/// 3.55 alert latency: what only the real (native) engine can do. Fakes in tests do not implement it;
/// [AudioPriorityManager] checks `engine is VoiceEngineLive`.
abstract class VoiceEngineLive {
  /// Like [VoiceEngine.speak]; [earcon] plays a short beep first (at once, while the engine
  /// synthesises the words) unless the line is pre-synthesised (then it starts instantly anyway).
  Future<bool> speakAlert(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
    bool earcon = false,
  });

  /// Pre-synthesises [phrases] to audio clips (ride start), so those exact lines, or lines that
  /// START with one of them ("Slow down." + the rest), begin playing instantly.
  Future<void> prepare(List<String> phrases);

  /// Speech progress from the engine: [event] 'start' (with [ms] = delay from the speak call to the
  /// first audio) or 'done' (finished, stopped or failed).
  set onSpeechEvent(void Function(String id, String event, int ms)? handler);
}

/// Android TextToSpeech through MethodChannel `coroute/tts` (TtsChannel.kt): the
/// language of the app's safety setting (Hindi or Telugu when the phone has the
/// voice), else Indian English, else US English; ducks other audio while speaking.
class NativeVoiceEngine implements VoiceEngine, VoiceEngineLanguage, VoiceEngineExtras, VoiceEngineLive {
  NativeVoiceEngine({MethodChannel? channel}) : _ch = channel ?? const MethodChannel(NotifConstants.ttsChannel);

  final MethodChannel _ch;
  void Function(String id, String event, int ms)? _onSpeechEvent;
  bool _listening = false;

  @override
  set onSpeechEvent(void Function(String id, String event, int ms)? handler) => _onSpeechEvent = handler;

  /// Native -> Dart calls on `coroute/tts`: 'speechEvent' {id, event, ms} and 'diag' {line}
  /// (focus results, volume changes; nothing personal). Set once the engine is used.
  void _listen() {
    if (_listening) return;
    _listening = true;
    try {
      _ch.setMethodCallHandler((call) async {
        final a = call.arguments;
        if (a is! Map) return null;
        switch (call.method) {
          case 'speechEvent':
            final id = a['id']?.toString() ?? '';
            final ev = a['event']?.toString() ?? '';
            final ms = (a['ms'] as num?)?.toInt() ?? 0;
            if (ev == 'start') AudioDiagLog.add('speech start $id +${ms}ms${a['clip'] == true ? ' (clip)' : ''}');
            _onSpeechEvent?.call(id, ev, ms);
          case 'diag':
            final line = a['line']?.toString();
            if (line != null && line.isNotEmpty) AudioDiagLog.add('native $line');
        }
        return null;
      });
    } catch (_) {
      _listening = false; // no binding (unit tests): events are optional
    }
  }

  /// The language the engine uses ('en-IN', 'hi-IN'), '' before [init] or without a voice.
  @override
  String language = '';

  @override
  Future<bool> init() async {
    if (kIsWeb || (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS)) return false;
    _listen();
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
  Future<bool> speak(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
  }) async {
    try {
      return (await _ch.invokeMethod<bool>('speak', {
        'text': text,
        'id': id,
        'interrupt': interrupt,
        'isEmergency': isEmergency,
        'pauseOthers': pauseOthers,
      })) == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> speakExtended(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
    bool inCall = false,
    bool afterCall = false,
  }) async {
    try {
      return (await _ch.invokeMethod<bool>('speak', {
        'text': text,
        'id': id,
        'interrupt': interrupt,
        'isEmergency': isEmergency,
        'pauseOthers': pauseOthers,
        'inCall': inCall,
        'afterCall': afterCall,
      })) == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> speakAlert(
    String text, {
    required bool interrupt,
    required String id,
    bool isEmergency = false,
    bool pauseOthers = false,
    bool earcon = false,
  }) async {
    try {
      return (await _ch.invokeMethod<bool>('speak', {
        'text': text,
        'id': id,
        'interrupt': interrupt,
        'isEmergency': isEmergency,
        'pauseOthers': pauseOthers,
        'earcon': earcon,
      })) == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> prepare(List<String> phrases) async {
    if (phrases.isEmpty) return;
    try {
      await _ch.invokeMethod<void>('prepare', {'phrases': phrases});
    } catch (_) {}
  }

  @override
  Future<void> fallbackAlert({required bool critical, bool inCall = false}) async {
    try {
      await _ch.invokeMethod<bool>('fallbackAlert', {'critical': critical, 'inCall': inCall});
    } catch (_) {}
  }

  /// 3.55 sound awareness: the rider's hearing situation from the phone's audio state (no mic):
  /// headset kind ('bluetooth' | 'wired' | 'hearingAid' | ''), other apps' music, phone call.
  /// Null off Android or when the native side cannot answer.
  static Future<ListeningState?> readListeningState({MethodChannel? channel}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final r = await (channel ?? const MethodChannel(NotifConstants.ttsChannel)).invokeMethod<Object?>('listeningState');
      return r is Map ? ListeningState.fromMap(r) : null;
    } catch (_) {
      return null;
    }
  }

  /// 3.55: one short alert tone (a siren close by while the rider can hear outside: no speech).
  static Future<void> alertTone({MethodChannel? channel}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await (channel ?? const MethodChannel(NotifConstants.ttsChannel)).invokeMethod<void>('alertTone');
    } catch (_) {}
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
/// - The engine is warmed up at ride start ([warmUp]: bound, voice chosen, common lines
///   pre-synthesised) or else starts on the first alert of a ride (nothing at idle), and is
///   released at ride end. Without an engine or a usable voice everything is
///   silent ([available] false); banners and notifications still show.
/// - The engine is asked for the safety language (Hindi, Telugu); [speechLang]
///   says which one it confirmed, so alert texts are built in a language the
///   phone can actually say. A language change releases the engine; the next
///   alert starts it again in the new language.
/// - Social alerts are never spoken (the callers never pass them).
class VoiceService extends ChangeNotifier {
  VoiceService(
    this._settings, {
    VoiceEngine? engine,
    int Function()? clock,
    AudioPriorityManager? priorityManager,
  })  : _engine = engine ?? NativeVoiceEngine(),
        _clock = clock ?? _wallClock {
    _priorityManager = priorityManager ??
        AudioPriorityManager(
          engine: _engine,
          phoneCallService: _phoneCall,
          clock: _clock,
        );
    _priorityManager.bindEnsureEngine(_ensureEngine);
    L10n.changes.addListener(_onLanguage);
    _settings.addListener(_onSettings);
  }

  /// 3.55 fix: spoken warnings / accident warnings switched off mid-ride: the lines already queued
  /// that the new choice no longer allows are dropped (they used to be read out anyway). Emergencies
  /// and safety confirmations (P0, P1) always stay.
  void _onSettings() => dropDisallowedQueued();

  /// Same for the group's voice switch (called by [setGroupVoice]).
  @visibleForTesting
  int dropDisallowedQueued() => _priorityManager.dropQueuedWhere((i) => switch (i.priority) {
        AudioPriority.p0CriticalEmergency || AudioPriority.p1SafetyConfirmation => false,
        AudioPriority.p2ImmediateHazard => !_settings.hazardAlerts && !_settings.voiceWarnings,
        AudioPriority.p3Navigation => !_settings.voiceWarnings || !_groupVoice,
        AudioPriority.p4ConvoyAnnouncement => !_allowed(VoicePriority.important),
        AudioPriority.p5Informational => !_settings.voiceWarnings,
      });

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final SettingsService _settings;
  final VoiceEngine _engine;
  final int Function() _clock;
  late final AudioPriorityManager _priorityManager;
  PhoneCallService? _phoneCall;

  AudioPriorityManager get priorityManager => _priorityManager;

  PhoneCallService? get phoneCallService => _phoneCall;

  void attachPhoneCallService(PhoneCallService? service) {
    if (_phoneCall == service) return;
    _phoneCall?.removeListener(_onPhoneCallChanged);
    _phoneCall = service;
    _priorityManager.attachPhoneCallService(service);
    _phoneCall?.addListener(_onPhoneCallChanged);
  }

  void _onPhoneCallChanged() {
    // Phone call changes are handled within AudioPriorityManager
  }

  Future<bool>? _init;
  bool _available = false;
  bool _failed = false;
  bool _groupVoice = true;
  bool _night = false;
  String _requested = 'en';
  String _speechLang = 'en';

  /// The engine is running with a usable language.
  bool get available => _available;

  /// The group's "Voice guidance" switch (convoy.voiceGuidanceEnabled), set by AlertService.
  void setGroupVoice(bool enabled) {
    if (_groupVoice == enabled) return;
    _groupVoice = enabled;
    if (!enabled) dropDisallowedQueued(); // 3.55 fix: the lead switched spoken alerts off mid-ride
  }

  @visibleForTesting
  bool get groupVoice => _groupVoice;

  /// After sunset (set by SafetyService from the ride's fixes): important alerts are
  /// spoken too.
  void setNight(bool dark) => _night = dark;

  @visibleForTesting
  bool get night => _night;

  /// 'hi', 'te' or 'en': the safety language when the engine confirmed that voice,
  /// else 'en' (texts for speech are built in this language).
  String get speechLang => _speechLang;

  /// The settings used by this voice service.
  SettingsService get settings => _settings;

  /// Emergencies are always spoken; after sunset important group alerts are spoken too.
  bool _allowed(VoicePriority p) => switch (p) {
        VoicePriority.critical => true,
        VoicePriority.warning => _settings.voiceWarnings && _groupVoice,
        VoicePriority.important => (_settings.voiceWarnings && _groupVoice) || _night,
      };

  /// About how long the engine takes to say [text] (for the queue cap only).
  static int estimateMs(String text) => 600 + text.length * 70;

  /// Speaks [text] once. False when it was not spoken (setting off, duplicate key,
  /// queue full, no engine, or audio congestion). Emergency alerts always speak.
  Future<bool> speak(
    String text, {
    VoicePriority priority = VoicePriority.warning,
    String? key,
    Duration? ttl,
    bool isRecoverable = true,
    bool? pauseOthers,
  }) async {
    final t = text.trim();
    if (t.isEmpty || !_allowed(priority)) return false;

    final audioPriority = switch (priority) {
      VoicePriority.critical => AudioPriority.p0CriticalEmergency,
      VoicePriority.important => AudioPriority.p4ConvoyAnnouncement,
      VoicePriority.warning => AudioPriority.p3Navigation,
    };
    if (_failed) {
      // 3.55: no speech engine this ride: a tone + buzz (and a notification) for critical lines.
      _priorityManager.alertWithoutVoice(audioPriority, t);
      return false;
    }

    return _priorityManager.submit(
      text: t,
      priority: audioPriority,
      dedupeKey: key ?? t,
      ttl: ttl,
      dedupeWindow: NotifConstants.voiceDedupe,
      isRecoverable: isRecoverable,
      pauseOthers: pauseOthers ?? (priority == VoicePriority.critical || _settings.pauseOtherAudio),
    );
  }

  /// P0: Immediate emergency alert (SOS, crash, vehicle collision).
  Future<bool> speakEmergency(String text, {String? dedupeKey, Duration? ttl}) {
    final t = text.trim();
    if (t.isEmpty) return Future.value(false);
    if (_failed) {
      _priorityManager.alertWithoutVoice(AudioPriority.p0CriticalEmergency, t);
      return Future.value(false);
    }
    return _priorityManager.submit(
      text: t,
      priority: AudioPriority.p0CriticalEmergency,
      dedupeKey: dedupeKey ?? t,
      ttl: ttl,
      dedupeWindow: const Duration(seconds: 5),
      pauseOthers: true,
    );
  }

  /// P1: Fatigue warning & rider safety confirmation prompt.
  Future<bool> speakFatigueConfirmation(String text, {String? dedupeKey, Duration? ttl}) {
    final t = text.trim();
    if (t.isEmpty) return Future.value(false);
    if (_failed) {
      _priorityManager.alertWithoutVoice(AudioPriority.p1SafetyConfirmation, t);
      return Future.value(false);
    }
    return _priorityManager.submit(
      text: t,
      priority: AudioPriority.p1SafetyConfirmation,
      dedupeKey: dedupeKey ?? t,
      ttl: ttl,
      dedupeWindow: const Duration(seconds: 15),
      pauseOthers: _settings.pauseOtherAudio,
    );
  }

  /// P2: Immediate road hazard (Black ice, animal, sharp curve).
  Future<bool> speakHazard(String text, {String? dedupeKey, Duration? ttl}) {
    final t = text.trim();
    if (t.isEmpty || (!_settings.hazardAlerts && !_settings.voiceWarnings)) {
      return Future.value(false);
    }
    if (_failed) {
      _priorityManager.alertWithoutVoice(AudioPriority.p2ImmediateHazard, t);
      return Future.value(false);
    }
    return _priorityManager.submit(
      text: t,
      priority: AudioPriority.p2ImmediateHazard,
      dedupeKey: dedupeKey ?? t,
      ttl: ttl,
      dedupeWindow: const Duration(seconds: 10),
      pauseOthers: _settings.pauseOtherAudio,
    );
  }

  /// P3: Navigation cue (Turn instructions, rerouting).
  Future<bool> speakNavigation(String text, {String? dedupeKey, Duration? ttl}) {
    final t = text.trim();
    if (t.isEmpty || !_settings.voiceWarnings || !_groupVoice || _failed) {
      return Future.value(false);
    }
    return _priorityManager.submit(
      text: t,
      priority: AudioPriority.p3Navigation,
      dedupeKey: dedupeKey ?? t,
      ttl: ttl,
      dedupeWindow: const Duration(seconds: 8),
      pauseOthers: _settings.pauseOtherAudio,
    );
  }

  /// P4: Convoy announcement (Sweeper stop, convoy split, regroup).
  Future<bool> speakConvoyAnnouncement(String text, {String? dedupeKey, Duration? ttl}) {
    final t = text.trim();
    if (t.isEmpty || !_allowed(VoicePriority.important) || _failed) {
      return Future.value(false);
    }
    return _priorityManager.submit(
      text: t,
      priority: AudioPriority.p4ConvoyAnnouncement,
      dedupeKey: dedupeKey ?? t,
      ttl: ttl,
      dedupeWindow: const Duration(seconds: 15),
      pauseOthers: _settings.pauseOtherAudio,
    );
  }

  /// P5: Informational notification (Fuel advisory, weather, speed limits).
  Future<bool> speakInformational(String text, {String? dedupeKey, Duration? ttl}) {
    final t = text.trim();
    if (t.isEmpty || !_settings.voiceWarnings || _failed) {
      return Future.value(false);
    }
    return _priorityManager.submit(
      text: t,
      priority: AudioPriority.p5Informational,
      dedupeKey: dedupeKey ?? t,
      ttl: ttl,
      dedupeWindow: const Duration(seconds: 30),
      pauseOthers: _settings.pauseOtherAudio,
    );
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

  /// Alert when rider exceeds speed limit. Brief, non-distracting voice cue.
  ///
  /// 3.55: far over the limit ([farOverFraction], 40 %) it is a critical line: music paused, alarm
  /// stream (clear even with the media volume down or lowered by "Lower music when speeding").
  Future<bool> speakOverspeed({required int currentSpeedKmh, required int limitKmh}) {
    if (limitKmh > 0 && currentSpeedKmh >= limitKmh * (1 + farOverFraction)) {
      final t = 'Slow down. $currentSpeedKmh km/h, limit $limitKmh.';
      if (_failed) {
        _priorityManager.alertWithoutVoice(AudioPriority.p1SafetyConfirmation, t);
        return Future.value(false);
      }
      return _priorityManager.submit(
        text: t,
        priority: AudioPriority.p1SafetyConfirmation,
        dedupeKey: 'overspeed_far_${_clock() ~/ 60000}',
        dedupeWindow: const Duration(seconds: 30),
        ttl: const Duration(seconds: 10),
        pauseOthers: true,
        metadata: const {'kind': 'overspeed'},
      );
    }
    return speak(
      'Over limit. $currentSpeedKmh km/h.',
      priority: VoicePriority.warning,
      key: 'overspeed_${DateTime.now().millisecondsSinceEpoch ~/ 60000}',
      pauseOthers: _settings.pauseOtherAudio,
    );
  }

  /// Over the limit by this fraction or more, the overspeed line is critical (see [speakOverspeed]).
  static const double farOverFraction = 0.40;

  /// 3.55: whether a line of [priority] would be spoken now (settings, engine not failed, not held
  /// for a phone call). AlertService posts its notification silently when the voice speaks it, so
  /// the notification sound never doubles with the speech; when this is false, the notification
  /// sounds instead.
  bool willSpeak(VoicePriority priority) {
    if (!_allowed(priority) || _failed) return false;
    if (_init != null && !_available) return false; // started this ride without a usable voice
    final call = _phoneCall;
    if (priority != VoicePriority.critical && call != null && call.isCallActive) return false;
    return true;
  }

  /// 3.55 alert latency: ride start. Binds the engine and picks the voice now (binding the phone's
  /// text-to-speech and loading a voice takes 0.3-2 s, which the first alert used to wait for),
  /// then pre-synthesises the common short warnings ([phrases] plus [commonLeadPhrases]) so they
  /// start instantly (synthesised with the same voice the line would be spoken in). Safe to call
  /// again (the engine starts once per ride).
  Future<bool> warmUp({List<String> phrases = const []}) async {
    final sw = Stopwatch()..start();
    final ok = await _ensureEngine();
    AudioDiagLog.add('engine warm ok=$ok lang=$_speechLang ${sw.elapsedMilliseconds}ms');
    final e = _engine;
    if (ok && e is VoiceEngineLive && !_prepared) {
      _prepared = true;
      await (e as VoiceEngineLive).prepare([...commonLeadPhrases, ...phrases]);
    }
    return ok;
  }

  bool _prepared = false;

  /// Short first sentences of frequent warnings: a line that starts with one of them begins with
  /// the ready clip while the rest is synthesised (no gap is heard).
  static const List<String> commonLeadPhrases = ['Slow down.', 'Over limit.', 'Please slow down.'];

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
    if (_init == null) return;
    await _priorityManager.stop();
    try {
      await _engine.stop();
    } catch (_) {}
  }

  /// Ride end: the engine is unbound; the next alert starts it again.
  Future<void> release() async {
    final wasStarted = _init != null;
    _init = null;
    _failed = false;
    _prepared = false;
    if (_available) {
      _available = false;
      notifyListeners();
    }
    await _priorityManager.release();
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
    _settings.removeListener(_onSettings);
    _priorityManager.dispose();
    super.dispose();
  }
}
