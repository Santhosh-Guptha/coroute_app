import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/constants/ride_notification_constants.dart';
import 'phone_call_service.dart';
import 'voice_service.dart';

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
  })  : _engine = engine ?? NativeVoiceEngine(),
        _phoneCall = phoneCallService,
        _clock = clock ?? _wallClock {
    _phoneCall?.addListener(_onPhoneCallChanged);
  }

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
  }

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
    if (_phoneCall?.isCallActive == false) {
      // Flushes post-call critical alerts when rider hangs up
      final pending = _phoneCall?.flushPostCallAlerts() ?? [];
      for (final alert in pending) {
        submit(
          text: 'Safety alert during your call: $alert',
          priority: AudioPriority.p0CriticalEmergency,
          dedupeKey: 'post_call_${alert.hashCode}',
        );
      }
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
      pauseOthers: pauseOthers || (priority == AudioPriority.p0CriticalEmergency),
      metadata: metadata,
    );

    // Broadcast visual fallback
    _visualAlertController.add(item);

    // Multi-modal haptic feedback based on priority level
    _triggerHapticsFor(priority);

    // 3. In-call audio safety handling:
    final inCall = _phoneCall?.isCallActive ?? false;
    if (inCall && priority == AudioPriority.p0CriticalEmergency) {
      // When a phone call is active, queue into post-call alerts in case OS/Bluetooth SCO blocks audio
      _phoneCall?.queuePostCallAlert(cleanText);
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
      _processNextInQueue();
      return false;
    }

    final interrupt = item.priority.isCritical;
    final said = item.text.length > NotifConstants.voiceMaxChars
        ? item.text.substring(0, NotifConstants.voiceMaxChars)
        : item.text;

    final isEmergency = item.priority == AudioPriority.p0CriticalEmergency;
    final pauseOthers = item.pauseOthers || isEmergency;
    bool success = false;
    try {
      success = await _engine.speak(
        said,
        interrupt: interrupt,
        id: item.id,
        isEmergency: isEmergency,
        pauseOthers: pauseOthers,
      );
    } catch (_) {
      success = false;
    }

    if (!success) {
      _dedupeHistory.remove(item.dedupeKey);
      _current = null;
      notifyListeners();
      _processNextInQueue();
      return false;
    }

    final at = _clock();
    if (interrupt) _queueEnds.clear();
    final start = _queueEnds.isEmpty ? at : _queueEnds.reduce((a, b) => a > b ? a : b);
    _queueEnds.add(start + VoiceService.estimateMs(said));

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
