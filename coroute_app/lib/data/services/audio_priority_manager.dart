import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants/ride_notification_constants.dart';
import '../../domain/voice/call_alert_queue.dart';
import 'feature_flags_service.dart';
import 'phone_call_service.dart';
import 'voice_service.dart';

// ─────────────────────────────────────────────────────────────────────────────────────────────
// How CoRoute's spoken lines treat other apps' sound (3.55, docs/features_355/audio_and_calls.md)
//
//  * Ordinary lines (P2..P5): transient audio focus that DUCKS other apps (music gets quiet) with
//    the "navigation guidance" usage (helmet Bluetooth set over A2DP, like map directions). With the
//    rider's "Pause music during alerts" on, music apps pause instead.
//  * Critical lines (P0 emergency, P1 safety confirmation): ALWAYS pause other apps
//    (AUDIOFOCUS_GAIN_TRANSIENT). P0 preempts anything being said. The route picks the usage
//    (TtsChannel.kt decides, at the moment the line is spoken):
//      - a headset is connected (Bluetooth / LE audio / hearing aid / wired): "navigation guidance"
//        media speech, so it plays in the helmet / earbuds over A2DP (noise cancellation does not
//        block playback), with the media volume raised to at least 60 % for the line. The ALARM
//        usage is not used then: Android may play alarms on the phone speaker too;
//      - no headset: the ALARM usage, heard on the speaker with media volume 0 and through Do Not
//        Disturb (when alarms are allowed).
//  * Focus is given back ~0.7 s after the native queue drains (not between lines: no pumping).
//  * Phone call (admin switch `callAwareAlerts`, unknown = on): ordinary lines are held and summed up
//    after the call ("While you were on the call: 2 road warnings, Asha fell behind."), stale ones
//    (> 60 s) dropped, navigation dropped; critical lines get through as a tone + a very short phrase
//    in the call audio, a buzz and a heads-up notification, and are replayed in full after the call.
//    Switch off: the 3.54 behaviour (everything spoken, P0 queued for a post-call replay).
//  * No speech engine / engine error: a tone + vibration instead (critical also posts a sounding
//    heads-up notification through [criticalNotifier]).
//
// API for services outside the voice stack (horn / siren detector, ...):
//    `priorityManager.announce(AudioPriority.p0CriticalEmergency, 'Emergency vehicle siren close by',
//         key: 'siren_close')`
//  speaks a line at that priority with the rules above (P0/P1 pause music, others duck it). It does
//  NOT apply the rider's voice settings: callers that are not emergencies should go through
//  VoiceService (speak / speakHazard / speakEmergency), which does, and which still works as before.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Centralized Audio Priority Levels (P0 to P5).
/// Lower [level] index indicates higher urgency.
enum AudioPriority {
  /// P0: SOS, crash and critical emergencies (Immediate preemption; never muted).
  p0CriticalEmergency(0),

  /// P1: Fatigue and safety confirmation (Safety check-in, break confirmation; never muted).
  p1SafetyConfirmation(1),

  /// P2: Immediate road hazards (Black ice, animal, sharp curve, collision alert).
  p2ImmediateHazard(2),

  /// P3: Navigation (Turn instructions, rerouting, destination cues).
  p3Navigation(3),

  /// P4: Convoy and group announcements (Sweeper distress, convoy split, regroup point).
  p4ConvoyAnnouncement(4),

  /// P5: Informational notifications (Low fuel warning, overspeed, weather).
  p5Informational(5);

  final int level;
  const AudioPriority(this.level);

  /// P0 and P1 are life-safety critical and cannot be silenced by manual background voice switch.
  bool get isCritical => level <= 1;

  bool operator <(AudioPriority other) => level < other.level;
  bool operator <=(AudioPriority other) => level <= other.level;
  bool operator >(AudioPriority other) => level > other.level;
  bool operator >=(AudioPriority other) => level >= other.level;
}

/// Represents an item submitted to the [AudioPriorityManager].
class AudioAlertItem {
  final String id;
  final String text;
  final AudioPriority priority;
  final String dedupeKey;
  final Duration ttl;
  final Duration dedupeWindow;
  final int createdAtMs;
  final bool isInterruptible;
  final bool isRecoverable;
  final bool pauseOthers;
  final Map<String, dynamic>? metadata;

  const AudioAlertItem({
    required this.id,
    required this.text,
    required this.priority,
    required this.dedupeKey,
    this.ttl = const Duration(seconds: 30),
    this.dedupeWindow = const Duration(seconds: 10),
    required this.createdAtMs,
    this.isInterruptible = true,
    this.isRecoverable = true,
    this.pauseOthers = false,
    this.metadata,
  });

  bool isExpired(int nowMs) => (nowMs - createdAtMs) > ttl.inMilliseconds;
}

/// Centralized manager orchestrating all spoken audio, text-to-speech dispatch,
/// priority preemption, deduplication, TTL pruning, call-state handling, and multi-modal fallbacks.
class AudioPriorityManager extends ChangeNotifier {
  AudioPriorityManager({
    VoiceEngine? engine,
    PhoneCallService? phoneCallService,
    int Function()? clock,
    bool Function()? callAware,
  })  : _engine = engine ?? NativeVoiceEngine(),
        _phoneCall = phoneCallService,
        _clock = clock ?? _wallClock,
        _callAware = callAware ?? _callAwareSwitch {
    _phoneCall?.addListener(_onPhoneCallChanged);
    _wasInCall = _phoneCall?.isCallActive ?? false;
  }

  /// Admin switch `callAwareAlerts` (unknown = on; safety ids are never gated, this is not one).
  static bool _callAwareSwitch() => FeatureFlagsService.on('callAwareAlerts');

  /// Posts a heads-up notification (critical channel, sounding) for a critical line the rider may not
  /// hear: during a phone call, or when speech failed. Set by AlarmNotifier once notifications are
  /// initialised; null in tests.
  static Future<void> Function(String title, String body)? criticalNotifier;

  final bool Function() _callAware;
  final CallAlertQueue _callQueue = CallAlertQueue();
  bool _wasInCall = false;
  int _criticalUntilMs = 0;
  int _lastFallbackMs = -1 << 40;

  /// Lines held during the current phone call (call-aware mode).
  @visibleForTesting
  CallAlertQueue get callQueue => _callQueue;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final VoiceEngine _engine;
  final int Function() _clock;
  PhoneCallService? _phoneCall;
  Future<bool> Function()? _onEnsureEngine;
  bool _engineInitialized = false;

  PhoneCallService? get phoneCallService => _phoneCall;

  void bindEnsureEngine(Future<bool> Function() ensureEngine) {
    _onEnsureEngine = ensureEngine;
  }

  void attachPhoneCallService(PhoneCallService? service) {
    if (_phoneCall == service) return;
    _phoneCall?.removeListener(_onPhoneCallChanged);
    _phoneCall = service;
    _phoneCall?.addListener(_onPhoneCallChanged);
    _wasInCall = _phoneCall?.isCallActive ?? false;
  }

  /// A phone call rings or is active right now.
  bool get _inCall => _phoneCall?.isCallActive ?? false;

  /// Priority queue of waiting alerts (sorted by priority level ascending, then age).
  final List<AudioAlertItem> _queue = [];

  /// Currently playing audio alert, if any.
  AudioAlertItem? _current;

  /// Alert item that was preempted mid-utterance by a higher-priority alert.
  AudioAlertItem? _preemptedItem;

  /// Deduplication history: dedupeKey -> (lastSpokenEpochMs, dedupeWindowMs).
  final Map<String, (int, int)> _dedupeHistory = {};

  /// Estimated end timestamps of utterances passed to engine.
  final List<int> _queueEnds = [];

  /// Stream controller broadcasting alerts for visual HUD / toast rendering.
  final StreamController<AudioAlertItem> _visualAlertController = StreamController<AudioAlertItem>.broadcast();
  Stream<AudioAlertItem> get onVisualAlert => _visualAlertController.stream;

  bool _isProcessing = false;
  int _seq = 0;

  AudioAlertItem? get currentAlert => _current;
  int get queueLength => _queue.length;

  /// Default deduplication window per priority.
  static Duration dedupeWindowFor(AudioPriority p) => switch (p) {
        AudioPriority.p0CriticalEmergency => NotifConstants.voiceDedupe,
        AudioPriority.p1SafetyConfirmation => const Duration(seconds: 15),
        AudioPriority.p2ImmediateHazard => const Duration(seconds: 10),
        AudioPriority.p3Navigation => const Duration(seconds: 8),
        AudioPriority.p4ConvoyAnnouncement => const Duration(seconds: 15),
        AudioPriority.p5Informational => const Duration(seconds: 30),
      };

  /// Default TTL / expiry per priority.
  static Duration defaultTtlFor(AudioPriority p) => switch (p) {
        AudioPriority.p0CriticalEmergency => const Duration(seconds: 60),
        AudioPriority.p1SafetyConfirmation => const Duration(seconds: 60),
        AudioPriority.p2ImmediateHazard => const Duration(seconds: 30),
        AudioPriority.p3Navigation => const Duration(seconds: 18),
        AudioPriority.p4ConvoyAnnouncement => const Duration(seconds: 30),
        AudioPriority.p5Informational => const Duration(seconds: 20),
      };

  void _onPhoneCallChanged() {
    final inCall = _inCall;
    final started = inCall && !_wasInCall;
    final ended = !inCall && _wasInCall;
    _wasInCall = inCall;
    if (!_callAware()) {
      _callQueue.clear();
      if (!inCall) _replayLegacy();
      return;
    }
    if (started) _holdQueuedForCall();
    if (ended) _speakAfterCallSummary();
  }

  /// 3.54 behaviour (switch `callAwareAlerts` off): critical alerts replayed after the call.
  void _replayLegacy() {
    final pending = _phoneCall?.flushPostCallAlerts() ?? [];
    for (final alert in pending) {
      submit(
        text: 'Safety alert during your call: $alert',
        priority: AudioPriority.p0CriticalEmergency,
        dedupeKey: 'post_call_${alert.hashCode}',
      );
    }
  }

  /// A call started: lines waiting to be said are held instead (critical ones stay queued), and an
  /// ordinary line being said is cut so CoRoute never talks over the call.
  void _holdQueuedForCall() {
    final now = _clock();
    final moved = _queue.where((i) => !i.priority.isCritical).toList();
    for (final i in moved) {
      _holdItem(i, now);
    }
    _queue.removeWhere((i) => !i.priority.isCritical);
    final pre = _preemptedItem;
    if (pre != null && !pre.priority.isCritical) {
      _holdItem(pre, now);
      _preemptedItem = null;
    }
    if (now >= _criticalUntilMs && _queueEnds.any((e) => e > now) && _engineInitialized) {
      _queueEnds.clear();
      _engine.stop().ignore();
    }
    if (moved.isNotEmpty) notifyListeners();
  }

  void _holdItem(AudioAlertItem i, int now) {
    _callQueue.hold(HeldAlert(
      kind: i.metadata?['kind']?.toString() ?? CallAlertQueue.kindOf(i.dedupeKey),
      text: i.text,
      priority: i.priority.level,
      atMs: i.createdAtMs > 0 ? i.createdAtMs : now,
    ));
  }

  /// The call ended: one critical line and one summary line (stale ones dropped), said once the phone
  /// has left call mode (the native side waits for it).
  void _speakAfterCallSummary() {
    _phoneCall?.flushPostCallAlerts(); // replaced by the summary below
    final summary = _callQueue.summarize(_clock());
    final seq = ++_seq;
    final critical = summary.criticalLine;
    if (critical != null) {
      submit(
        text: critical,
        priority: AudioPriority.p0CriticalEmergency,
        dedupeKey: 'post_call_critical_$seq',
        dedupeWindow: const Duration(seconds: 1),
        metadata: const {'afterCall': true},
      );
    }
    final ordinary = summary.ordinaryLine;
    if (ordinary != null) {
      submit(
        text: ordinary,
        priority: AudioPriority.p4ConvoyAnnouncement,
        dedupeKey: 'post_call_summary_$seq',
        dedupeWindow: const Duration(seconds: 1),
        metadata: const {'afterCall': true},
      );
    }
  }

  Future<bool> _ensureReady() async {
    if (_engineInitialized) return true;
    if (_onEnsureEngine != null) {
      _engineInitialized = await _onEnsureEngine!();
      return _engineInitialized;
    }
    try {
      _engineInitialized = await _engine.init();
    } catch (_) {
      _engineInitialized = false;
    }
    return _engineInitialized;
  }

  /// Submits an audio alert for playback.
  /// Returns `true` if scheduled or played immediately; `false` if suppressed by
  /// deduplication or queue congestion. Which alerts may speak at all is decided by
  /// [VoiceService] (emergencies always do).
  Future<bool> submit({
    required String text,
    required AudioPriority priority,
    String? dedupeKey,
    Duration? ttl,
    Duration? dedupeWindow,
    bool isRecoverable = true,
    bool pauseOthers = false,
    Map<String, dynamic>? metadata,
  }) async {
    final cleanText = text.trim();
    if (cleanText.isEmpty) return false;

    final now = _clock();
    final key = dedupeKey ?? cleanText;
    final window = dedupeWindow ?? dedupeWindowFor(priority);

    // 1. Deduplication check:
    _pruneDedupeHistory(now);
    final history = _dedupeHistory[key];
    if (history != null) {
      final (lastSpoken, winMs) = history;
      if (now - lastSpoken < winMs) {
        return false;
      }
    }

    // Also check if an identical key is already waiting in the queue
    if (_queue.any((item) => item.dedupeKey == key && !item.isExpired(now))) {
      return false;
    }

    // 2. Queue congestion check for non-critical alerts:
    _queueEnds.removeWhere((end) => end <= now);
    if (!priority.isCritical && _queueEnds.length >= NotifConstants.voiceMaxQueued) {
      return false;
    }

    final item = AudioAlertItem(
      id: 'alert_${++_seq}',
      text: cleanText,
      priority: priority,
      dedupeKey: key,
      ttl: ttl ?? defaultTtlFor(priority),
      dedupeWindow: window,
      createdAtMs: now,
      isRecoverable: isRecoverable,
      pauseOthers: pauseOthers || priority.isCritical,
      metadata: metadata,
    );

    // Broadcast visual fallback
    _visualAlertController.add(item);

    // Multi-modal haptic feedback based on priority level
    _triggerHapticsFor(priority);

    // 3. In-call audio safety handling:
    final inCall = _inCall;
    if (inCall && priority == AudioPriority.p0CriticalEmergency) {
      // When a phone call is active, queue into post-call alerts in case OS/Bluetooth SCO blocks audio
      _phoneCall?.queuePostCallAlert(cleanText);
    }
    if (inCall && _callAware() && metadata?['afterCall'] != true) {
      if (!priority.isCritical) {
        // Never talk over a call: held for the after-call summary (navigation is dropped: stale).
        _holdItem(item, now);
        return CallAlertQueue.worthHolding(priority.level);
      }
      // Critical: kept for the full replay after the call, and said now as a tone + a very short
      // phrase in the call audio (while ringing: on the alarm stream over the ringtone), with a
      // heads-up notification.
      _holdItem(item, now);
      _notifyCritical(cleanText);
      final callItem = AudioAlertItem(
        id: item.id,
        text: _phoneCall?.status == PhoneCallStatus.offhook ? CallAlertQueue.shortPhrase(cleanText) : cleanText,
        priority: priority,
        dedupeKey: key,
        ttl: item.ttl,
        dedupeWindow: window,
        createdAtMs: now,
        isRecoverable: false,
        pauseOthers: true,
        metadata: {...?metadata, 'inCall': _phoneCall?.status == PhoneCallStatus.offhook},
      );
      if (_current != null) {
        await _engine.stop();
        _current = null;
        _queueEnds.clear();
      }
      return _playAlert(callItem);
    }

    // 4. Preemption check:
    if (_current != null) {
      if (priority < _current!.priority) {
        // Higher priority arrives: PREEMPT currently playing item immediately!
        final interrupted = _current!;
        _preemptedItem = (interrupted.isRecoverable && !interrupted.isExpired(now)) ? interrupted : null;

        // Stop TTS engine immediately
        await _engine.stop();
        _current = null;
        _queueEnds.clear();

        // Play the higher-priority item directly
        return _playAlert(item);
      } else {
        // Enqueue by priority
        _enqueue(item);
        return true;
      }
    } else {
      if (priority.isCritical) {
        _queueEnds.clear();
      }
      return _playAlert(item);
    }
  }

  void _enqueue(AudioAlertItem item) {
    _pruneExpiredQueue();
    // Insert sorted: lowest priority.level first (P0 at index 0, then P1, etc.)
    int index = 0;
    while (index < _queue.length && _queue[index].priority <= item.priority) {
      index++;
    }
    _queue.insert(index, item);
    notifyListeners();
  }

  void _pruneExpiredQueue() {
    final now = _clock();
    _queue.removeWhere((item) => item.isExpired(now));
  }

  void _pruneDedupeHistory(int now) {
    _dedupeHistory.removeWhere((_, pair) => now - pair.$1 > max(120000, pair.$2));
  }

  void _triggerHapticsFor(AudioPriority p) {
    switch (p) {
      case AudioPriority.p0CriticalEmergency:
        HapticFeedback.heavyImpact();
        break;
      case AudioPriority.p1SafetyConfirmation:
        HapticFeedback.mediumImpact();
        break;
      case AudioPriority.p2ImmediateHazard:
        HapticFeedback.mediumImpact();
        break;
      case AudioPriority.p3Navigation:
      case AudioPriority.p4ConvoyAnnouncement:
      case AudioPriority.p5Informational:
        // No heavy haptic distraction for routine guidance
        break;
    }
  }

  Future<bool> _playAlert(AudioAlertItem item) async {
    _current = item;
    final now = _clock();
    _dedupeHistory[item.dedupeKey] = (now, item.dedupeWindow.inMilliseconds);
    notifyListeners();

    final ready = await _ensureReady();
    if (!ready) {
      _dedupeHistory.remove(item.dedupeKey);
      _current = null;
      notifyListeners();
      _fallback(item);
      _processNextInQueue();
      return false;
    }

    final interrupt = item.priority.isCritical;
    final said = item.text.length > NotifConstants.voiceMaxChars
        ? item.text.substring(0, NotifConstants.voiceMaxChars)
        : item.text;

    // Critical (P0 / P1): music paused; alarm usage on the speaker, media speech on a headset (native).
    final isEmergency = item.priority.isCritical;
    final pauseOthers = item.pauseOthers || isEmergency;
    final inCall = item.metadata?['inCall'] == true;
    final afterCall = item.metadata?['afterCall'] == true;
    bool success = false;
    try {
      final e = _engine;
      if (e is VoiceEngineExtras && (inCall || afterCall)) {
        success = await (e as VoiceEngineExtras).speakExtended(
          said,
          interrupt: interrupt,
          id: item.id,
          isEmergency: isEmergency,
          pauseOthers: pauseOthers,
          inCall: inCall,
          afterCall: afterCall,
        );
      } else {
        success = await e.speak(
          said,
          interrupt: interrupt,
          id: item.id,
          isEmergency: isEmergency,
          pauseOthers: pauseOthers,
        );
      }
    } catch (_) {
      success = false;
    }

    if (!success) {
      _dedupeHistory.remove(item.dedupeKey);
      _current = null;
      notifyListeners();
      _fallback(item);
      _processNextInQueue();
      return false;
    }

    final at = _clock();
    if (interrupt) _queueEnds.clear();
    final start = _queueEnds.isEmpty ? at : _queueEnds.reduce((a, b) => a > b ? a : b);
    final end = start + VoiceService.estimateMs(said);
    _queueEnds.add(end);
    if (isEmergency && end > _criticalUntilMs) _criticalUntilMs = end;

    _current = null;
    notifyListeners();

    // Check if we need to recover the preempted alert
    if (_preemptedItem != null) {
      final prev = _preemptedItem!;
      _preemptedItem = null;
      if (!prev.isExpired(_clock())) {
        _enqueue(prev);
      }
    }

    // Process next item in priority queue
    _processNextInQueue();
    return true;
  }

  /// Speech impossible for [item] (no engine, engine error): tone + vibration for hazards and above,
  /// and a sounding heads-up notification for critical lines. At most once per 3 s.
  void _fallback(AudioAlertItem item) => alertWithoutVoice(item.priority, item.text);

  /// For callers whose speech is off for the ride (no engine): the same tone / vibration /
  /// notification fallback as a failed line. Lines below P2 stay visual only.
  void alertWithoutVoice(AudioPriority priority, String text) {
    if (priority > AudioPriority.p2ImmediateHazard) return;
    final now = _clock();
    if (now - _lastFallbackMs < 3000 && !priority.isCritical) return;
    _lastFallbackMs = now;
    final e = _engine;
    if (e is VoiceEngineExtras) {
      (e as VoiceEngineExtras).fallbackAlert(critical: priority.isCritical, inCall: _inCall).ignore();
    }
    if (priority.isCritical) _notifyCritical(text);
  }

  void _notifyCritical(String text) {
    final n = criticalNotifier;
    if (n == null) return;
    n('CoRoute safety alert', text).catchError((Object _) {});
  }

  /// Speaks [text] at [priority] with the audio rules in the header of this file (for services outside
  /// the voice stack, e.g. the horn / siren detector). P0 / P1 always pause other apps (alarm stream on
  /// the speaker, media speech on a headset); lower priorities duck other apps (or pause them with [pauseOthers]). The rider's voice
  /// settings are NOT applied here (use VoiceService for that). False when not spoken (duplicate key
  /// within the dedupe window, queue full, no engine) or held for a phone call (true for held lines
  /// that will be summed up after the call).
  Future<bool> announce(
    AudioPriority priority,
    String text, {
    String? key,
    bool pauseOthers = false,
    Duration? ttl,
    Duration? dedupeWindow,
  }) =>
      submit(
        text: text,
        priority: priority,
        dedupeKey: key,
        ttl: ttl,
        dedupeWindow: dedupeWindow,
        pauseOthers: pauseOthers,
      );

  void _processNextInQueue() {
    if (_isProcessing || _current != null) return;
    _isProcessing = true;
    _pruneExpiredQueue();

    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      _isProcessing = false;
      _playAlert(next);
    } else {
      _isProcessing = false;
    }
  }

  /// 3.55 fix: drops queued (not yet spoken) alerts that [test] matches, e.g. after the rider
  /// switched spoken warnings off mid-ride: lines already waiting used to be read out anyway.
  /// The line being spoken now finishes. Emergencies (P0) are never dropped.
  int dropQueuedWhere(bool Function(AudioAlertItem item) test) {
    bool drop(AudioAlertItem i) => i.priority != AudioPriority.p0CriticalEmergency && test(i);
    final before = _queue.length;
    _queue.removeWhere(drop);
    var dropped = before - _queue.length;
    final pre = _preemptedItem;
    if (pre != null && drop(pre)) {
      _preemptedItem = null;
      dropped++;
    }
    if (dropped > 0) notifyListeners();
    return dropped;
  }

  /// Stops current speech and clears priority queue.
  Future<void> stop() async {
    _queue.clear();
    _queueEnds.clear();
    _preemptedItem = null;
    _current = null;
    if (_onEnsureEngine == null && _engineInitialized) {
      await _engine.stop();
    }
    notifyListeners();
  }

  /// Releases audio resources at ride end.
  Future<void> release() async {
    await stop();
    _dedupeHistory.clear();
    _callQueue.clear();
    final wasInitialized = _engineInitialized;
    _engineInitialized = false;
    if (_onEnsureEngine == null && wasInitialized) {
      await _engine.release();
    }
  }

  @override
  void dispose() {
    _phoneCall?.removeListener(_onPhoneCallChanged);
    _visualAlertController.close();
    super.dispose();
  }
}
