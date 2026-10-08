import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/ui/ride_alert.dart';
import '../../domain/safety/accel_bucket.dart';
import '../../domain/safety/crash_detector.dart';
import '../../domain/safety/fatigue_tracker.dart';
import '../../domain/safety/sms_plan.dart';
import '../../domain/safety/solo_check_in.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import '../models/convoy_model.dart';
import '../models/emergency_roster.dart';
import '../models/network_wire.dart';
import '../models/pending_sos.dart';
import '../models/safety_wire.dart';
import 'accel_source.dart';
import 'alarm_notifier.dart';
import 'auth_service.dart';
import 'convoy_service.dart';
import 'safety_native.dart';
import 'settings_service.dart';
import 'sms_sender.dart';

enum SafetyPromptKind { checkIn, fatigue }

/// A question or reminder for the rider only ("Are you OK?", "Time for a break").
class SafetyPrompt {
  final String key;
  final SafetyPromptKind kind;
  final String title;
  final String message;
  final String primaryLabel;
  final String? secondaryLabel;

  const SafetyPrompt({
    required this.key,
    required this.kind,
    required this.title,
    required this.message,
    required this.primaryLabel,
    this.secondaryLabel,
  });

  AlertTier get tier => kind == SafetyPromptKind.checkIn ? AlertTier.important : AlertTier.normal;

  @override
  bool operator ==(Object other) =>
      other is SafetyPrompt && other.key == key && other.kind == kind && other.title == title && other.message == message;

  @override
  int get hashCode => Object.hash(key, kind, title, message);
}

/// The crash alarm while it is open. [sent] is true once the SOS went out
/// (the screen then shows the SOS sheet content until the rider closes it).
class CrashAlarmState {
  final int startedAtMs;
  final int secondsLeft;
  final double impactG;
  final double speedBeforeKmh;
  final double lat;
  final double lng;
  final bool sent;

  const CrashAlarmState({
    required this.startedAtMs,
    required this.secondsLeft,
    required this.impactG,
    required this.speedBeforeKmh,
    this.lat = 0,
    this.lng = 0,
    this.sent = false,
  });

  CrashAlarmState copyWith({int? secondsLeft, bool? sent}) => CrashAlarmState(
        startedAtMs: startedAtMs,
        secondsLeft: secondsLeft ?? this.secondsLeft,
        impactG: impactG,
        speedBeforeKmh: speedBeforeKmh,
        lat: lat,
        lng: lng,
        sent: sent ?? this.sent,
      );
}

enum SmsFallbackState { idle, sending, sent, partly, failed, notAllowed }

/// What the emergency texts did, for the SOS sheet. Counts only, never numbers.
class SmsFallbackStatus {
  final SmsFallbackState state;
  final int sent;
  final int total;

  /// People left out by the cap or the text budget.
  final int capped;
  final int at;

  /// The emergency contact was among the texts that went out.
  final bool contactReached;

  const SmsFallbackStatus({
    required this.state,
    required this.sent,
    required this.total,
    required this.capped,
    required this.at,
    this.contactReached = false,
  });

  /// One plain line for the SOS sheet.
  String get text {
    switch (state) {
      case SmsFallbackState.idle:
        return '';
      case SmsFallbackState.sending:
        return 'Texting your group: $sent of $total sent...';
      case SmsFallbackState.sent:
      case SmsFallbackState.partly:
        final riders = contactReached ? sent - 1 : sent;
        final who = <String>[
          if (contactReached) 'your emergency contact',
          if (riders > 0) '$riders ${riders == 1 ? 'rider' : 'riders'}',
        ].join(' and ');
        final base = state == SmsFallbackState.sent ? 'Texted $who.' : 'Texted $sent of $total ($who). Some texts did not go out.';
        final cap = capped > 0
            ? ' Phones allow about ${SafetyConstants.smsMaxRecipients} texts at once, so the nearest riders were chosen.'
            : '';
        return '$base$cap';
      case SmsFallbackState.failed:
        return total == 0
            ? 'No phone numbers to text. Call your emergency contact or 112.'
            : 'The texts could not be sent. Call your emergency contact or 112.';
      case SmsFallbackState.notAllowed:
        return 'Texts are not allowed on this phone. Turn on "Text the group" and allow SMS.';
    }
  }
}

/// The narrow view of ConvoyService and AuthService that [SafetyService] uses
/// (a fake in tests). Listeners fire on every convoy change.
abstract class SafetyPort implements Listenable {
  /// Every fix of mine while a ride is active (no extra GPS request).
  Stream<TrackPoint> get myFixes;
  ConvoyModel? get activeConvoy;
  String? get myUserId;
  String get myName;
  String? get myPhone;

  /// In a ride that has not ended.
  bool get rideActive;

  /// My SOS is open on the server or still waiting to be sent.
  bool get hasOpenSos;
  PendingSos? get pendingSos;
  EmergencyRoster? get emergencyRoster;
  RosterContact? get myEmergencyContact;

  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  });
  bool sendCheckIn(CheckInResult result, {double? awayM});
}

/// Optional extension of [SafetyPort] (3.15): raise with the emergency source, so the
/// server can tell "Need Help" (the rider answered) from no answer (CRASH_AUTO).
/// Ports that do not implement it get the 3.14 call (the server derives the source).
abstract class SafetySourcePort {
  SosDelivery raiseSosFrom(
    EmergencySource source, {
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  });
}

/// Adapts the real ConvoyService and AuthService.
class ConvoySafetyPort implements SafetyPort, SafetySourcePort {
  ConvoySafetyPort(this._convoys, this._auth);

  final ConvoyService _convoys;
  final AuthService _auth;

  @override
  void addListener(VoidCallback listener) => _convoys.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _convoys.removeListener(listener);

  @override
  Stream<TrackPoint> get myFixes => _convoys.myFixes;
  @override
  ConvoyModel? get activeConvoy => _convoys.activeConvoy;
  @override
  String? get myUserId => _convoys.myUserId;
  @override
  String get myName {
    final n = (_auth.currentUserName ?? '').trim();
    if (n.isNotEmpty) return n;
    final uid = _convoys.myUserId;
    return (uid == null ? null : _convoys.activeConvoy?.riders[uid]?.name) ?? '';
  }

  @override
  String? get myPhone => _auth.phone;
  @override
  bool get rideActive {
    final c = _convoys.activeConvoy;
    return c != null && c.tripStatus != 'ENDED';
  }

  @override
  bool get hasOpenSos => _convoys.pendingSos != null || _convoys.myOpenSosAlertId != null;
  @override
  PendingSos? get pendingSos => _convoys.pendingSos;
  @override
  EmergencyRoster? get emergencyRoster => _convoys.emergencyRoster;
  @override
  RosterContact? get myEmergencyContact {
    final phone = (_auth.emergencyContact ?? '').trim();
    if (phone.isEmpty) return null;
    return RosterContact(name: (_auth.emergencyContactName ?? '').trim(), phone: phone);
  }

  @override
  SosDelivery raiseSos({
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) =>
      _convoys.raiseSos(
        type: type,
        lat: lat,
        lng: lng,
        auto: auto,
        speedBeforeKmh: speedBeforeKmh,
        impactG: impactG,
        occurredAtMs: occurredAtMs,
      );

  @override
  SosDelivery raiseSosFrom(
    EmergencySource source, {
    required String type,
    required double lat,
    required double lng,
    bool auto = false,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
  }) =>
      _convoys.raiseSos(
        type: type,
        lat: lat,
        lng: lng,
        auto: auto,
        speedBeforeKmh: speedBeforeKmh,
        impactG: impactG,
        occurredAtMs: occurredAtMs,
        source: source,
      );

  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) => _convoys.sendCheckIn(result, awayM: awayM);
}

/// Rider safety on the phone: crash detection with a 15 s alarm ("Possible accident
/// detected. Are you okay?", [SafetyConstants.crashCountdown]), emergency texts
/// when an SOS cannot reach the group, the break reminder and the "Are you OK?"
/// check-in. Battery: the accelerometer runs only during a ride, only while the
/// rider was faster than 25 km/h in the last 30 s (or an impact is being
/// checked), and only with crash detection on. No timer runs while idle: the
/// alarm countdown, the SMS wait and the check-in answer wait are one-shot or
/// alarm-only timers.
class SafetyService extends ChangeNotifier {
  SafetyService(ConvoyService convoys, SettingsService settings, AuthService auth, {AccelSource? accel, SmsSender? sms})
      : this._(ConvoySafetyPort(convoys, auth), settings, accel ?? NativeAccelSource(), sms ?? NativeSmsSender(), null, true);

  @visibleForTesting
  SafetyService.forTest(SafetyPort port, SettingsService settings, {required AccelSource accel, required SmsSender sms, int Function()? clock})
      : this._(port, settings, accel, sms, clock, false);

  SafetyService._(this._port, this._settings, this._accel, this._sms, this._clock, this._native) {
    _port.addListener(_onConvoy);
    _settings.addListener(_onSettings);
    _fixSub = _port.myFixes.listen(_onFix, onError: (Object _) {});
    if (_native) {
      AlarmNotifier.ensureInitialized().ignore();
      AlarmNotifier.onAction(AlarmNotifier.payloadCrash, _onCrashAction);
      AlarmNotifier.onAction(AlarmNotifier.payloadPrompt, _onPromptAction);
    }
    _onConvoy();
  }

  final SafetyPort _port;
  final SettingsService _settings;
  final AccelSource _accel;
  final SmsSender _sms;
  final int Function()? _clock;
  final bool _native;

  final CrashDetector _detector = CrashDetector();
  final FatigueTracker _fatigue = FatigueTracker();
  final SoloCheckIn _checkIn = SoloCheckIn();

  StreamSubscription<TrackPoint>? _fixSub;
  StreamSubscription<AccelBucket>? _accelSub;
  bool _accelUnavailable = false;

  CrashAlarmState? _alarm;
  CrashEvent? _alarmEvent;
  Timer? _alarmTimer;

  final Map<String, SafetyPrompt> _prompts = {};
  Timer? _checkInTimer;
  int _lastCheckInEval = 0;
  double? _lastAwayM;

  Timer? _smsTimer;
  String? _smsTimerFor;
  String? _pendingSeenFor;
  int _pendingSeenAt = 0;
  final Set<String> _smsRounds = {};
  bool _smsBusy = false;
  SmsFallbackStatus? _smsStatus;
  String? _smsStatusFor;

  String? _groupId;
  bool _rideActive = false;
  TrackPoint? _lastFix;
  bool _disposed = false;

  int _now() => _clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  // ------------------------------------------------------------------ public API
  CrashAlarmState? get alarm => _alarm;
  List<SafetyPrompt> get prompts => List.unmodifiable(_prompts.values);
  SmsFallbackStatus? get smsStatus => _smsStatus;

  /// The accelerometer is running right now.
  bool get detectorArmed => _accelSub != null;

  /// "Text the group now" can be used: texts allowed, an SOS is waiting and was not texted yet.
  bool get smsAvailable {
    final p = _port.pendingSos;
    return _settings.smsFallback && p != null && !_smsRounds.contains(p.clientId) && !_smsBusy;
  }

  /// "I'm OK" on the alarm: closes it and sends nothing.
  void alarmImOk() {
    final a = _alarm;
    if (a == null) return;
    if (a.sent) {
      closeAlarm();
      return;
    }
    _alarmTimer?.cancel();
    _alarmTimer = null;
    _alarm = null;
    _alarmEvent = null;
    _detector.cooldown(_now());
    _endAlarmNative();
    notifyListeners();
  }

  /// "Need Help" on the alarm: the SOS goes out at once (source NEED_HELP).
  /// At 0 s without an answer the same happens with source CRASH_AUTO.
  void alarmSendNow() {
    final a = _alarm;
    if (a == null || a.sent) return;
    _sendCrash(EmergencySource.needHelp);
  }

  /// Closes the alarm screen after the SOS was sent (the SOS itself stays open).
  void closeAlarm() {
    if (_alarm == null) return;
    _alarmTimer?.cancel();
    _alarmTimer = null;
    _alarm = null;
    _alarmEvent = null;
    notifyListeners();
  }

  void answerPrompt(String key, {bool primary = true}) {
    if (!_prompts.containsKey(key)) return;
    if (key == SafetyConstants.promptCheckIn) {
      final told = _checkIn.noReplySent;
      _checkIn.answeredOk(_now());
      _checkInTimer?.cancel();
      _checkInTimer = null;
      // The lead was told "No reply": tell them the rider is fine. Otherwise nothing is sent.
      if (told) _port.sendCheckIn(CheckInResult.ok);
    }
    _removePrompt(key);
  }

  /// "Text the group now" from the SOS sheet: the same round as the automatic one.
  Future<void> sendSmsNow() => _smsRound(manual: true);

  /// Test hook: opens the alarm as if the detector had fired.
  @visibleForTesting
  void debugRaiseCrash(CrashEvent e) => _openAlarm(e);

  // ------------------------------------------------------------------ inputs
  void _onConvoy() {
    if (_disposed) return;
    final gid = _port.activeConvoy?.groupId;
    final active = _port.rideActive;
    if (gid != _groupId || active != _rideActive) {
      _groupId = gid;
      _rideActive = active;
      _resetRide();
    }
    _watchPendingSos();
    _evalCheckIn();
    _updateSensor();
  }

  void _onSettings() {
    if (_disposed) return;
    if (!_settings.crashDetection) _detector.reset();
    if (!_settings.fatigueReminder) {
      _fatigue.reset();
      _removePrompt(SafetyConstants.promptFatigue);
    }
    if (!_settings.soloCheckIn) {
      _checkIn.reset();
      _checkInTimer?.cancel();
      _checkInTimer = null;
      _removePrompt(SafetyConstants.promptCheckIn);
    }
    _watchPendingSos();
    _updateSensor();
    notifyListeners();
  }

  void _onFix(TrackPoint p) {
    if (_disposed || !_port.rideActive) return;
    _lastFix = p;
    if (_settings.crashDetection) {
      final ev = _detector.onFix(p);
      if (ev != null) _openAlarm(ev);
    }
    if (_settings.fatigueReminder && _fatigue.onFix(p)) {
      final hours = SafetyConstants.fatigueRideFor.inHours;
      final mins = SafetyConstants.fatigueBreakFor.inMinutes;
      _showPrompt(
        SafetyPrompt(
          key: SafetyConstants.promptFatigue,
          kind: SafetyPromptKind.fatigue,
          title: 'Time for a break',
          message: 'You have been riding for $hours h. A $mins min stop helps you stay sharp.',
          primaryLabel: 'OK',
        ),
        notifyAlways: false,
      );
    }
    _updateSensor();
  }

  void _onAccel(AccelBucket b) {
    if (_disposed) return;
    final ev = _detector.onAccel(b);
    if (ev != null) _openAlarm(ev);
    _updateSensor();
  }

  void _resetRide() {
    _detector.reset();
    _accelUnavailable = false; // try the sensor again on the next ride
    _fatigue.reset();
    _checkIn.reset();
    _checkInTimer?.cancel();
    _checkInTimer = null;
    _lastCheckInEval = 0;
    _lastAwayM = null;
    _lastFix = null;
    final hadPrompts = _prompts.isNotEmpty;
    for (final key in _prompts.keys.toList()) {
      _removePrompt(key, notify: false);
    }
    if (!_rideActive) {
      _smsStatus = null;
      _smsStatusFor = null;
      _smsTimer?.cancel();
      _smsTimer = null;
      _smsTimerFor = null;
    }
    if (hadPrompts) notifyListeners();
  }

  /// Sensor on only while needed (battery hard rule).
  void _updateSensor() {
    final want = !_disposed &&
        !_accelUnavailable &&
        _settings.crashDetection &&
        _port.rideActive &&
        _detector.wantsSensor;
    if (want && _accelSub == null) {
      _accelSub = _accel.buckets().listen(_onAccel, onError: (Object e) {
        // No accelerometer (or the sensor failed): stop asking for it during this ride.
        _accelUnavailable = true;
        _accelSub?.cancel();
        _accelSub = null;
        notifyListeners();
      }, onDone: () {
        _accelSub = null;
      });
      notifyListeners();
    } else if (!want && _accelSub != null) {
      _accelSub?.cancel();
      _accelSub = null;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ crash alarm
  void _openAlarm(CrashEvent e) {
    final now = _now();
    if (_alarm != null || _port.hasOpenSos || !_settings.crashDetection) {
      _detector.cooldown(now);
      return;
    }
    var lat = e.lat, lng = e.lng;
    if (lat == 0 && lng == 0) {
      final f = _lastFix;
      final uid = _port.myUserId;
      final me = uid == null ? null : _port.activeConvoy?.riders[uid];
      lat = f?.lat ?? me?.lat ?? 0;
      lng = f?.lng ?? me?.lng ?? 0;
    }
    final seconds = SafetyConstants.crashCountdown.inSeconds;
    _alarmEvent = CrashEvent(impactAtMs: e.impactAtMs, impactG: e.impactG, speedBeforeKmh: e.speedBeforeKmh, lat: lat, lng: lng);
    _alarm = CrashAlarmState(
      startedAtMs: now,
      secondsLeft: seconds,
      impactG: e.impactG,
      speedBeforeKmh: e.speedBeforeKmh,
      lat: lat,
      lng: lng,
    );
    _alarmTimer?.cancel();
    _alarmTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickAlarm());
    if (_native) {
      SafetyNative.alarmWindow(true).ignore();
      AlarmNotifier.showCrashAlarm(
        title: 'Possible accident detected',
        body: 'Are you okay? Sending SOS to your group in $seconds seconds. Tap I\'m OK if you are fine.',
      ).ignore();
    }
    _haptic();
    notifyListeners();
  }

  void _tickAlarm() {
    final a = _alarm;
    if (a == null || a.sent) {
      _alarmTimer?.cancel();
      _alarmTimer = null;
      return;
    }
    final elapsed = _now() - a.startedAtMs;
    final left = ((SafetyConstants.crashCountdown.inMilliseconds - elapsed) / 1000).ceil();
    if (left <= 0) {
      _sendCrash(EmergencySource.crashAuto);
      return;
    }
    if (left != a.secondsLeft) {
      _alarm = a.copyWith(secondsLeft: left);
      _haptic();
      notifyListeners();
    }
  }

  void _sendCrash(EmergencySource source) {
    final a = _alarm;
    final e = _alarmEvent;
    _alarmTimer?.cancel();
    _alarmTimer = null;
    if (a == null || e == null) return;
    final port = _port;
    if (port is SafetySourcePort) {
      (port as SafetySourcePort).raiseSosFrom(
        source,
        type: SosTypes.crash,
        lat: e.lat,
        lng: e.lng,
        auto: true,
        speedBeforeKmh: e.speedBeforeKmh,
        impactG: e.impactG,
        occurredAtMs: e.impactAtMs,
      );
    } else {
      port.raiseSos(
        type: SosTypes.crash,
        lat: e.lat,
        lng: e.lng,
        auto: true,
        speedBeforeKmh: e.speedBeforeKmh,
        impactG: e.impactG,
        occurredAtMs: e.impactAtMs,
      );
    }
    _alarm = a.copyWith(sent: true, secondsLeft: 0);
    _detector.cooldown(_now());
    _endAlarmNative();
    notifyListeners();
  }

  void _endAlarmNative() {
    if (!_native) return;
    AlarmNotifier.cancelCrashAlarm().ignore();
    SafetyNative.alarmWindow(false).ignore();
  }

  void _onCrashAction(String? actionId, String? payload) {
    if (actionId == AlarmNotifier.actionCrashOk) {
      alarmImOk();
    } else if (actionId == AlarmNotifier.actionCrashSend) {
      alarmSendNow();
    }
    // A tap on the notification itself opens the app; CrashAlarmHost shows the screen.
  }

  void _haptic() {
    try {
      HapticFeedback.heavyImpact().catchError((Object _) {});
    } catch (_) {}
  }

  // ------------------------------------------------------------------ prompts
  void _showPrompt(SafetyPrompt p, {required bool notifyAlways}) {
    _prompts[p.key] = p;
    notifyListeners();
    if (_native && (notifyAlways || _inBackground)) AlarmNotifier.showPrompt(p).ignore();
  }

  void _removePrompt(String key, {bool notify = true}) {
    if (_prompts.remove(key) == null) return;
    if (_native) AlarmNotifier.cancelPrompt(key).ignore();
    if (notify) notifyListeners();
  }

  void _onPromptAction(String? actionId, String? payload) {
    if (actionId != AlarmNotifier.actionPromptOk || payload == null) return;
    final key = payload.substring(AlarmNotifier.payloadPrompt.length + 1);
    answerPrompt(key);
  }

  bool get _inBackground {
    try {
      final s = SchedulerBinding.instance.lifecycleState;
      return s != null && s != AppLifecycleState.resumed;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ solo check-in
  void _evalCheckIn() {
    if (!_settings.soloCheckIn || !_port.rideActive) return;
    final now = _now();
    if (_lastCheckInEval != 0 && now - _lastCheckInEval < SafetyConstants.checkInEvalEvery.inMilliseconds) return;
    _lastCheckInEval = now;
    final convoy = _port.activeConvoy;
    if (convoy == null || _port.hasOpenSos) return;
    // Only while the ride is under way: before the start riders come from home to the meeting
    // point, and during a pause the group is spread out on purpose. Nothing counts then.
    final away = convoy.tripStatus == 'STARTED' ? awayFromGroup(convoy, _port.myUserId, now, myFix: _lastFix) : null;
    _lastAwayM = away;
    final wasWaiting = _checkIn.awaitingAnswer;
    final step = _checkIn.onSample(tMs: now, awayM: away, limitM: convoy.distanceThresholdMeters);
    if (step == CheckInStep.prompt) {
      _showCheckInPrompt(told: false);
      _checkInTimer?.cancel();
      _checkInTimer = Timer(SafetyConstants.checkInAnswerWithin, _onCheckInTimeout);
    } else if (wasWaiting && !_checkIn.awaitingAnswer) {
      // Back with the group before the answer was due: nothing to ask any more.
      _checkInTimer?.cancel();
      _checkInTimer = null;
      _removePrompt(SafetyConstants.promptCheckIn);
    }
  }

  void _showCheckInPrompt({required bool told}) {
    final mins = SafetyConstants.checkInFarFor.inMinutes;
    final answer = SafetyConstants.checkInAnswerWithin.inMinutes;
    _showPrompt(
      SafetyPrompt(
        key: SafetyConstants.promptCheckIn,
        kind: SafetyPromptKind.checkIn,
        title: 'Are you OK?',
        message: told
            ? 'Your lead was told that you did not answer. Tap I\'m OK if you are fine.'
            : 'You have been far from your group for $mins min. If you do not answer in $answer min, your lead is told.',
        primaryLabel: 'I\'m OK',
      ),
      notifyAlways: true,
    );
  }

  void _onCheckInTimeout() {
    _checkInTimer = null;
    if (_disposed) return;
    final step = _checkIn.onTimeout(_now());
    if (step != CheckInStep.noReply) return;
    _port.sendCheckIn(CheckInResult.noReply, awayM: _lastAwayM);
    _showCheckInPrompt(told: true);
  }

  /// Distance from me to the group: the middle (median latitude and longitude) of the
  /// other riders seen in the last 5 min, or the nearest of them when that is closer
  /// (a rider riding with someone is not alone, and when a group splits in two halves the
  /// median lies in the other half for everyone). Null when nobody else was seen.
  static double? awayFromGroup(ConvoyModel convoy, String? myUserId, int nowMs, {TrackPoint? myFix}) {
    if (myUserId == null) return null;
    final meRider = convoy.riders[myUserId];
    final myLat = myFix?.lat ?? meRider?.lat;
    final myLng = myFix?.lng ?? meRider?.lng;
    if (myLat == null || myLng == null || (myLat == 0 && myLng == 0)) return null;
    final fresh = SafetyConstants.checkInOthersFresh.inMilliseconds;
    final lats = <double>[], lngs = <double>[];
    var nearest = double.infinity;
    for (final r in convoy.riders.values) {
      if (r.userId == myUserId) continue;
      if (r.lat == 0 && r.lng == 0) continue;
      if (r.lastSeenEpochMs <= 0 || nowMs - r.lastSeenEpochMs > fresh) continue;
      lats.add(r.lat);
      lngs.add(r.lng);
      nearest = math.min(nearest, GeoMath.haversine(myLat, myLng, r.lat, r.lng));
    }
    if (lats.isEmpty) return null;
    return math.min(nearest, GeoMath.haversine(myLat, myLng, _median(lats), _median(lngs)));
  }

  static double _median(List<double> v) {
    final s = List<double>.of(v)..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  // ------------------------------------------------------------------ emergency texts
  void _watchPendingSos() {
    final p = _port.pendingSos;
    if (p == null) {
      _smsTimer?.cancel();
      _smsTimer = null;
      _smsTimerFor = null;
      return;
    }
    if (_smsStatusFor != null && _smsStatusFor != p.clientId) {
      _smsStatus = null; // a new SOS: the old line does not apply
      _smsStatusFor = null;
    }
    // The wait counts from when this phone first had the SOS waiting, not from p.createdAt:
    // a crash SOS carries the impact time (about a minute earlier, after the stillness check
    // and the countdown), which would text everyone before the socket could deliver it.
    if (_pendingSeenFor != p.clientId) {
      _pendingSeenFor = p.clientId;
      _pendingSeenAt = _now();
    }
    if (!_settings.smsFallback || _smsRounds.contains(p.clientId) || _smsTimerFor == p.clientId) return;
    _smsTimer?.cancel();
    _smsTimerFor = p.clientId;
    final age = _now() - _pendingSeenAt;
    final waitMs = (SafetyConstants.smsFallbackAfter.inMilliseconds - (age > 0 ? age : 0))
        .clamp(0, SafetyConstants.smsFallbackAfter.inMilliseconds)
        .toInt();
    _smsTimer = Timer(Duration(milliseconds: waitMs), () {
      _smsTimer = null;
      _smsRound(manual: false).ignore();
    });
  }

  void _setSms(SmsFallbackStatus s, String clientId) {
    _smsStatus = s;
    _smsStatusFor = clientId;
    if (!_disposed) notifyListeners();
  }

  Future<void> _smsRound({required bool manual}) async {
    final p = _port.pendingSos;
    if (p == null || _smsBusy || _smsRounds.contains(p.clientId)) return;
    final now = _now();
    if (!_settings.smsFallback) {
      if (manual) _setSms(SmsFallbackStatus(state: SmsFallbackState.notAllowed, sent: 0, total: 0, capped: 0, at: now), p.clientId);
      return;
    }
    _smsBusy = true;
    try {
      final cap = await _sms.capability();
      if (_disposed) return;
      if (!cap.hasTelephony || !cap.permission) {
        _setSms(SmsFallbackStatus(state: SmsFallbackState.notAllowed, sent: 0, total: 0, capped: 0, at: _now()), p.clientId);
        return;
      }
      // Still not delivered? (It may have gone through while we checked.)
      final still = _port.pendingSos;
      if (still == null || still.clientId != p.clientId) return;
      final log = await _SmsLog.load();
      if (_disposed) return;
      _smsRounds.add(p.clientId);
      if (log.texted(p.clientId)) return; // texted before the app restarted
      final convoy = _port.activeConvoy;
      final body = SmsText.sos(
        name: _port.myName,
        auto: p.auto || p.type == SosTypes.crash,
        lat: p.lat,
        lng: p.lng,
        at: DateTime.fromMillisecondsSinceEpoch(p.createdAt > 0 ? p.createdAt : now),
        convoyName: convoy?.name,
      );
      final perMessage = SmsText.parts(body);
      final roster = _port.emergencyRoster;
      final validRoster = roster != null && roster.isValidFor(p.groupId, now) ? roster : null;
      final serverCap = validRoster?.cap ?? SafetyConstants.smsMaxRecipients;
      final uid = _port.myUserId;
      final plan = SmsPlanner.plan(
        roster: validRoster,
        contact: _port.myEmergencyContact,
        lastPositions: {
          if (convoy != null)
            for (final r in convoy.riders.values)
              if (r.userId != uid && !(r.lat == 0 && r.lng == 0)) r.userId: (r.lat, r.lng),
        },
        me: (p.lat, p.lng),
        cap: math.min(serverCap > 0 ? serverCap : SafetyConstants.smsMaxRecipients, SafetyConstants.smsMaxRecipients),
        partsLeft: log.partsLeft(now),
        partsPerMessage: perMessage,
        selfUserId: uid,
        selfPhone: _port.myPhone,
      );
      final total = plan.recipients.length;
      if (total == 0) {
        _setSms(SmsFallbackStatus(state: SmsFallbackState.failed, sent: 0, total: 0, capped: plan.capped, at: _now()), p.clientId);
        await log.save(p.clientId, _now());
        return;
      }
      if (!cap.simReady) {
        _setSms(SmsFallbackStatus(state: SmsFallbackState.failed, sent: 0, total: total, capped: plan.capped, at: _now()), p.clientId);
        await log.save(p.clientId, _now());
        return;
      }
      var sent = 0;
      var contact = false;
      _setSms(SmsFallbackStatus(state: SmsFallbackState.sending, sent: 0, total: total, capped: plan.capped, at: _now()), p.clientId);
      for (final r in plan.recipients) {
        if (_disposed) return;
        final status = await _sms
            .send(r.phone, body)
            .timeout(SafetyConstants.smsSendTimeout + const Duration(seconds: 5), onTimeout: () => SmsStatus.timeout);
        log.add(_now(), perMessage);
        if (status == SmsStatus.sent) {
          sent++;
          if (r.label == 'contact') contact = true;
        }
        _setSms(
          SmsFallbackStatus(state: SmsFallbackState.sending, sent: sent, total: total, capped: plan.capped, at: _now(), contactReached: contact),
          p.clientId,
        );
        // No signal or no permission: the next ones would fail the same way.
        if (status == SmsStatus.noService || status == SmsStatus.noPermission) break;
      }
      await log.save(p.clientId, _now());
      final state = sent == total ? SmsFallbackState.sent : (sent > 0 ? SmsFallbackState.partly : SmsFallbackState.failed);
      _setSms(
        SmsFallbackStatus(state: state, sent: sent, total: total, capped: plan.capped, at: _now(), contactReached: contact),
        p.clientId,
      );
    } catch (e) {
      debugPrint('emergency text note: ${e.runtimeType}');
    } finally {
      _smsBusy = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _port.removeListener(_onConvoy);
    _settings.removeListener(_onSettings);
    _fixSub?.cancel();
    _accelSub?.cancel();
    _accelSub = null;
    _alarmTimer?.cancel();
    _checkInTimer?.cancel();
    _smsTimer?.cancel();
    if (_native) {
      AlarmNotifier.removeAction(AlarmNotifier.payloadCrash);
      AlarmNotifier.removeAction(AlarmNotifier.payloadPrompt);
    }
    super.dispose();
  }
}

/// Text budget on the phone: timestamps and part counts only (no numbers, no text),
/// plus the SOS ids that were already texted (so a restart does not text twice).
class _SmsLog {
  _SmsLog(this._entries, this._rounds);

  final List<List<int>> _entries;
  final List<String> _rounds;

  static Future<_SmsLog> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SafetyConstants.keySmsLog);
      if (raw == null || raw.isEmpty) return _SmsLog([], []);
      final j = jsonDecode(raw);
      if (j is! Map) return _SmsLog([], []);
      final entries = <List<int>>[
        for (final e in (j['e'] as List? ?? const []))
          if (e is List && e.length == 2 && e[0] is num && e[1] is num) [(e[0] as num).toInt(), (e[1] as num).toInt()],
      ];
      final rounds = <String>[
        for (final r in (j['r'] as List? ?? const []))
          if (r is String) r,
      ];
      return _SmsLog(entries, rounds);
    } catch (_) {
      return _SmsLog([], []);
    }
  }

  int partsLeft(int nowMs) {
    final from = nowMs - SafetyConstants.smsBudgetWindow.inMilliseconds;
    var used = 0;
    for (final e in _entries) {
      if (e[0] >= from) used += e[1];
    }
    final left = SafetyConstants.smsMaxPartsPer30Min - used;
    return left < 0 ? 0 : left;
  }

  void add(int tMs, int parts) => _entries.add([tMs, parts]);

  Future<void> save(String clientId, int nowMs) async {
    // Only the budget window matters; older entries are dropped.
    _entries.removeWhere((e) => e[0] < nowMs - SafetyConstants.smsBudgetWindow.inMilliseconds);
    if (!_rounds.contains(clientId)) _rounds.add(clientId);
    while (_rounds.length > 20) {
      _rounds.removeAt(0);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SafetyConstants.keySmsLog, jsonEncode({'e': _entries, 'r': _rounds}));
    } catch (_) {}
  }

  bool texted(String clientId) => _rounds.contains(clientId);
}
