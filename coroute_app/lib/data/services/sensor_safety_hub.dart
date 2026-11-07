// 3.55 phone-only safety features that read the phone's own sensors (free on every plan, no
// signal needed). One hub owned by SafetyService, so the hot service file only carries small
// hooks:
//  * fatigue score (switch 'fatigueScore'): adaptive break prompts, [fatigueLevel] for the group
//    break planner (only the level is ever shared, never sensor data);
//  * rider-down check (switch 'riderDown'): "Bike down?" via the existing crash alarm;
//  * crash detection that learns (switch 'crashLearning'): per-bike bounded threshold tuning
//    after "I'm OK";
//  * phone-mount check (switch 'mountCheck'): one gentle card per ride when the phone is not
//    in a handlebar mount;
//  * ride safety report (switch 'safetyReport'): the private summary saved with RideStats.
// All of it rides on the fixes and 1 s buckets SafetyService already receives: no extra sensor,
// GPS or timer work while idle.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants/safety_constants.dart';
import '../../domain/safety/accel_bucket.dart';
import '../../domain/safety/crash_detector.dart';
import '../../domain/safety/crash_incident.dart';
import '../../domain/safety/crash_learning.dart';
import '../../domain/safety/fatigue_score.dart';
import '../../domain/safety/mount_classifier.dart';
import '../../domain/safety/ride_safety_summary.dart';
import '../../domain/safety/rider_down_detector.dart';
import '../../domain/tracking/track_point.dart';
import 'garage_service.dart';

/// A short informational card for the cockpit (never interactive while moving).
class SensorSafetyNotice {
  final String key;
  final String title;
  final String message;
  const SensorSafetyNotice({required this.key, required this.title, required this.message});
}

/// Crash learning on the phone (SharedPreferences, one small JSON map bikeId -> state).
class CrashLearningStore {
  CrashLearningStore._();
  static const String key = 'coroute_crash_learning_v1';

  static Future<Map<String, CrashLearningState>> loadAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return {};
      return CrashLearning.decodeAll(jsonDecode(raw));
    } catch (_) {
      return {};
    }
  }

  static Future<CrashLearningState> load(String bike) async => (await loadAll())[bike] ?? CrashLearningState.none;

  static Future<void> save(String bike, CrashLearningState s) async {
    try {
      final all = await loadAll();
      if (s.isEmpty) {
        all.remove(bike);
      } else {
        all[bike] = s;
      }
      // Bounded: the most recently written bikes stay.
      while (all.length > CrashLearning.maxBikes) {
        all.remove(all.keys.first);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(CrashLearning.encodeAll(all)));
    } catch (e) {
      debugPrint('crash learning note: ${e.runtimeType}');
    }
  }
}

/// The last phone-mount result, for the pre-ride phone check.
class MountCheckStore {
  MountCheckStore._();
  static const String key = 'coroute_mount_last_v1';

  static Future<(MountKind, int)?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return (MountKind.fromWire(j['k'] as String?), (j['t'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(MountKind k, int atMs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode({'k': k.wire, 't': atMs}));
    } catch (_) {}
  }
}

class SensorSafetyHub extends ChangeNotifier {
  SensorSafetyHub({String? Function()? bikeId, int Function()? clock, bool persist = true})
      : _bikeId = bikeId ?? _garageBike,
        _clock = clock, // ignore: prefer_initializing_formals
        _persist = persist; // ignore: prefer_initializing_formals

  static String? _garageBike() {
    try {
      return GarageService.shared.activeBikeNotifier.value?.id;
    } catch (_) {
      return null;
    }
  }

  final String? Function() _bikeId;
  final int Function()? _clock;
  final bool _persist;
  bool _disposed = false;

  /// 3.55 admin switches (SafetyService passes its own). Null = on.
  bool Function(String id)? featureOn;
  bool _on(String id) => featureOn?.call(id) ?? true;

  int _now() => _clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  // ---------------------------------------------------------------- parts
  final FatigueScoreTracker fatigueTracker = FatigueScoreTracker();
  final FatigueEarlyPromptGate fatigueGate = FatigueEarlyPromptGate(
    rideFor: SafetyConstants.fatigueRideFor,
    remindAgain: SafetyConstants.fatigueRemindAgain,
  );
  final RiderDownDetector riderDown = RiderDownDetector();
  final MountClassifier mount = MountClassifier();
  final RideSafetyAccumulator summary = RideSafetyAccumulator();

  FatigueAssessment _fatigue = FatigueAssessment.fresh;
  int _fatigueAt = 0;
  TrackPoint? _lastFix;

  /// The current fatigue reading (fresh when the switch is off or nobody rides).
  FatigueAssessment get fatigue => _on('fatigueScore') ? _fatigue : FatigueAssessment.fresh;

  /// 0-100, for the group break planner (another feature reads it through SafetyService).
  int get fatigueLevel => fatigue.level;

  // ---------------------------------------------------------------- crash learning
  String _bike = 'default';
  CrashLearningState _learning = CrashLearningState.none;
  CrashDetector? _detector;
  int _learnLoad = 0;
  bool _learningDirty = false;

  /// The bike the learning is kept for now.
  String get learningBike => _bike;
  CrashLearningState get learning => _learning;

  void _applyScales() {
    final d = _detector;
    if (d == null) return;
    if (_on('crashLearning')) {
      d.setLearnedScales(slide: _learning.slideScale, lowFall: _learning.lowFallScale);
    } else {
      d.setLearnedScales(); // switched off: the plain rule
    }
  }

  /// Loads this bike's learning and applies it to [d] (a new ride, or the bike changed).
  Future<void> loadLearning(CrashDetector d) async {
    _detector = d;
    final bike = CrashLearning.bikeKey(_bikeId());
    if (bike != _bike) {
      if (_learningDirty) _saveLearning();
      _learning = CrashLearningState.none; // another bike: its own learning (the plain rule until loaded)
      _bike = bike;
    }
    final ticket = ++_learnLoad;
    _applyScales();
    if (!_persist) return;
    final s = await CrashLearningStore.load(_bike);
    if (_disposed || ticket != _learnLoad) return;
    _learning = s;
    _applyScales();
    notifyListeners();
  }

  /// "I'm OK" on a crash alarm (not a "Bike down?" check, not an outside impact).
  void onFalseAlarm(CrashScenario scenario) {
    if (!_on('crashLearning')) return;
    final next = CrashLearning.onFalseAlarm(_learning, scenario);
    if (next == _learning) return;
    _learning = next;
    _applyScales();
    _saveLearning();
    notifyListeners();
  }

  /// The SOS went out for a crash alarm: the stage that fired forgets what it learned.
  void onRealAlarm(CrashScenario scenario) {
    final next = CrashLearning.onRealAlarm(_learning, scenario);
    if (next == _learning) return;
    _learning = next;
    _applyScales();
    _saveLearning();
    notifyListeners();
  }

  /// Settings "Reset learning" for the active bike.
  Future<void> resetLearning() async {
    _bike = CrashLearning.bikeKey(_bikeId());
    _learnLoad++;
    _learning = CrashLearningState.none;
    _applyScales();
    if (_persist) await CrashLearningStore.save(_bike, _learning);
    notifyListeners();
  }

  /// The active bike's learning for the Settings line (reads storage when no ride runs).
  Future<CrashLearningState> learningForActiveBike() async {
    final bike = CrashLearning.bikeKey(_bikeId());
    if (bike == _bike && (_detector != null || !_persist)) return _learning;
    if (!_persist) return CrashLearningState.none;
    return CrashLearningStore.load(bike);
  }

  void _saveLearning() {
    _learningDirty = false;
    if (_persist) CrashLearningStore.save(_bike, _learning).ignore();
  }

  // ---------------------------------------------------------------- notice (mount card)
  SensorSafetyNotice? _notice;
  Timer? _noticeClear;
  MountKind? _pendingMountCard;
  bool _mountCardShown = false;

  /// The phone-mount card while it shows (90 s, or until dismissed).
  SensorSafetyNotice? get notice => _notice;

  static const String mountCardTitle = 'Phone not in a mount?';
  static const String mountCardMessage = 'Crash detection works best with the phone in a handlebar mount.';

  void dismissNotice() {
    _noticeClear?.cancel();
    if (_notice == null) return;
    _notice = null;
    notifyListeners();
  }

  void _showMountCard(MountKind k) {
    if (_mountCardShown) return;
    _mountCardShown = true;
    _pendingMountCard = null;
    _notice = SensorSafetyNotice(key: 'MOUNT:${k.wire}', title: mountCardTitle, message: mountCardMessage);
    _noticeClear?.cancel();
    _noticeClear = Timer(const Duration(seconds: 90), () {
      _notice = null;
      if (!_disposed) notifyListeners();
    });
    notifyListeners();
  }

  // ---------------------------------------------------------------- ride lifecycle
  /// A new ride (or none): everything per ride starts again; the learning is reloaded.
  void resetRide(CrashDetector d) {
    if (_learningDirty) _saveLearning();
    fatigueTracker.reset();
    fatigueGate.reset();
    riderDown.reset();
    mount.reset();
    summary.reset();
    _fatigue = FatigueAssessment.fresh;
    _fatigueAt = 0;
    _lastFix = null;
    _pendingMountCard = null;
    _mountCardShown = false;
    _noticeClear?.cancel();
    _notice = null;
    loadLearning(d).ignore();
  }

  /// End of a ride: the decay progress is kept.
  void endRide() {
    if (_learningDirty) _saveLearning();
  }

  // ---------------------------------------------------------------- inputs
  /// A fix of mine during a ride. [stretchStart] is the FatigueTracker's stretch.
  void onFix(TrackPoint p, {int? stretchStart, int limitKmh = 0, bool dark = false}) {
    final last = _lastFix;
    if (last != null && p.ts < last.ts) return;
    _lastFix = p;
    riderDown.onFix(p);
    fatigueTracker.onFix(p, stretchStart: stretchStart);
    summary.onFix(p, limitKmh: limitKmh, toleranceKmh: SafetyConstants.overspeedToleranceKmh, dark: dark);
    // Alarm-free riding: the learning comes back down 2 points per hour.
    if (last != null) {
      final gap = p.ts - last.ts;
      if (gap > 0 && gap <= 30000 && p.speedKmh >= SafetyConstants.crashLowSpeedArmKmh) {
        final before = _learning;
        final next = CrashLearning.onRideTime(before, gap);
        if (next != before) {
          final stepped = next.slidePct != before.slidePct || next.lowFallPct != before.lowFallPct;
          _learning = next;
          _learningDirty = true;
          if (stepped) {
            _applyScales();
            _saveLearning();
          }
        }
      }
    }
    if (p.ts - _fatigueAt >= 15000 || _fatigueAt == 0) {
      _fatigueAt = p.ts;
      final a = fatigueTracker.assess(nowMs: p.ts, localTime: DateTime.fromMillisecondsSinceEpoch(p.ts));
      final changed = a.level != _fatigue.level;
      _fatigue = a;
      if (_on('fatigueScore')) summary.onFatigue(a.level);
      if (changed) notifyListeners();
    }
  }

  /// True when an adaptive break prompt should show now (the caller shows it and calls
  /// [noteEarlyPrompt]). Never replaces or delays the fixed 2 h rule.
  bool earlyFatigueDue({required int nowMs, required int? stretchStart}) {
    if (!_on('fatigueScore')) return false;
    return fatigueGate.allowed(nowMs: nowMs, stretchStart: stretchStart, level: _fatigue.level);
  }

  void noteRulePrompt(int tMs) {
    fatigueGate.noteRulePrompt(tMs);
    summary.fatiguePrompts++;
  }

  void noteEarlyPrompt(int tMs) {
    fatigueGate.noteEarlyPrompt(tMs);
    summary.fatiguePrompts++;
  }

  /// True while the rider-down check needs the sensor (a tip-over is being watched).
  bool get wantsSensor => riderDown.evaluating;

  /// A 1 s bucket while the sensor runs. [crashBusy]: the crash detector is weighing an impact
  /// or an alarm / SOS is open (the rider-down check then stays out of the way).
  /// [emergency]: an alarm or SOS is open (no card shows then). Returns a rider-down event.
  RiderDownEvent? onAccel(AccelBucket b, {required bool crashBusy, required bool emergency}) {
    final f = _lastFix;
    final fresh = f != null && (b.tMs - f.ts).abs() <= 5000;
    fatigueTracker.onAccel(b);
    if (_on('mountCheck') && fresh) {
      final k = mount.onBucket(b, speedKmh: f.speedKmh);
      if (k != null) {
        summary.mount = k.wire;
        if (_persist) MountCheckStore.save(k, b.tMs).ignore();
        if (k.weak) _pendingMountCard = k;
      }
    }
    final pending = _pendingMountCard;
    if (pending != null && !emergency) _showMountCard(pending);

    if (!_on('riderDown')) return null;
    if (crashBusy) {
      riderDown.suppress(b.tMs, forDuration: const Duration(seconds: 30));
      return null;
    }
    return riderDown.onAccel(b);
  }

  /// A crash alarm opened (rider-down or crash): summary count, and the rider-down check rests.
  void onAlarmOpened({required bool riderDownCheck}) {
    if (riderDownCheck) {
      summary.bikeDownChecks++;
    } else {
      summary.crashAlarms++;
    }
    riderDown.suppress(_now());
  }

  /// A road surface event (pothole, speed breaker, rough road) felt this ride.
  void onRoadHazard() => summary.roadHazards++;

  /// The summary of this ride so far.
  RideSafetySummary buildSummary({required int hardBrakes, required int breaks}) =>
      summary.build(hardBrakes: hardBrakes, breaks: breaks, nowMs: _now());

  @override
  void dispose() {
    _disposed = true;
    _noticeClear?.cancel();
    if (_learningDirty) _saveLearning();
    super.dispose();
  }
}
