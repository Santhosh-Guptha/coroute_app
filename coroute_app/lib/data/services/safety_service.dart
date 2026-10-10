import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/ui/ride_alert.dart';
import '../../domain/safety/accel_bucket.dart';
import '../../domain/safety/crash_detector.dart';
import '../../domain/safety/fatigue_tracker.dart';
import '../../domain/safety/fuel_range.dart';
import '../../domain/safety/hard_brake_counter.dart';
import '../../domain/safety/sms_plan.dart';
import '../../domain/safety/solo_check_in.dart';
import '../../domain/safety/sun_helper.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/tracking/track_point.dart';
import '../local/ride_stats_store.dart';
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
import 'tile_cache_service.dart';
import 'voice_service.dart';
import 'weather_service.dart';

enum SafetyPromptKind { checkIn, fatigue, fuel, followUp }

/// Where an impact reported from outside the phone's own sensor came from (3.16, item 22):
/// a wearable (no device work this round; the hook is documented in docs/WEARABLE_HOOK.md)
/// or the hidden developer action that simulates one.
enum ExternalImpactSource { wearable, developer }

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

  AlertTier get tier => switch (kind) {
        SafetyPromptKind.checkIn || SafetyPromptKind.fuel || SafetyPromptKind.followUp => AlertTier.important,
        SafetyPromptKind.fatigue => AlertTier.normal,
      };

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

/// Optional extension of [SafetyPort] (3.16): a check-in with a context (the post-crash
/// follow-up sends `CHECK_IN {context: FOLLOW_UP}`). Ports without it get the plain call.
abstract class SafetyCheckInPort {
  bool sendCheckInWith(CheckInResult result, {double? awayM, CheckInContext? context});
}

/// Adapts the real ConvoyService and AuthService.
class ConvoySafetyPort implements SafetyPort, SafetySourcePort, SafetyCheckInPort {
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

  @override
  bool sendCheckInWith(CheckInResult result, {double? awayM, CheckInContext? context}) =>
      _convoys.sendCheckIn(result, awayM: awayM, context: context);
}

/// Rider safety on the phone: crash detection with a 15 s alarm ("Possible accident
/// detected. Are you okay?", [SafetyConstants.crashCountdown]), emergency texts
/// when an SOS cannot reach the group, the break reminder and the "Are you OK?"
/// check-in. 3.16 adds the fuel reminder, the hard-stop count (rider only), the
/// post-crash follow-up, the night flag for spoken alerts, the weather check and
/// the route map prefetch at ride start, and the wearable impact hook.
/// Battery: the accelerometer runs only during a ride, only while the
/// rider was faster than 25 km/h in the last 30 s (or an impact is being
/// checked), and only with crash detection on. No timer runs while idle: the
/// alarm countdown, the SMS wait and the check-in answer wait are one-shot or
/// alarm-only timers; everything new in 3.16 rides on fixes and convoy changes.
class SafetyService extends ChangeNotifier {
  SafetyService(
    ConvoyService convoys,
    SettingsService settings,
    AuthService auth, {
    AccelSource? accel,
    SmsSender? sms,
    VoiceService? voice,
    WeatherService? weather,
    TilePrefetcher? tiles,
  }) : this._(ConvoySafetyPort(convoys, auth), settings, accel ?? NativeAccelSource(), sms ?? NativeSmsSender(), null, true,
            voice: voice, weather: weather, tiles: tiles);

  @visibleForTesting
  SafetyService.forTest(
    SafetyPort port,
    SettingsService settings, {
    required AccelSource accel,
    required SmsSender sms,
    int Function()? clock,
    VoiceService? voice,
    WeatherService? weather,
    TilePrefetcher? tiles,
    Future<String> Function()? networkKind,
  }) : this._(port, settings, accel, sms, clock, false, voice: voice, weather: weather, tiles: tiles, networkKind: networkKind);

  SafetyService._(
    this._port,
    this._settings,
    this._accel,
    this._sms,
    this._clock,
    this._native, {
    this._voice,
    this._weather,
    this._tiles,
    Future<String> Function()? networkKind,
  })  : _networkKind = networkKind ?? SafetyNative.networkKind {
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
  final VoiceService? _voice;
  final WeatherService? _weather;
  final TilePrefetcher? _tiles;
  final Future<String> Function() _networkKind;

  final CrashDetector _detector = CrashDetector();
  final FatigueTracker _fatigue = FatigueTracker();
  final SoloCheckIn _checkIn = SoloCheckIn();
  FuelRangeTracker _fuel = FuelRangeTracker();
  final HardBrakeCounter _brakes = HardBrakeCounter();

  StreamSubscription<TrackPoint>? _fixSub;
  StreamSubscription<AccelBucket>? _accelSub;
  bool _accelUnavailable = false;

  CrashAlarmState? _alarm;
  CrashEvent? _alarmEvent;
  Timer? _alarmTimer;

  /// Set for an alarm raised through [externalImpact] (sent as source WEARABLE; the
  /// developer action never schedules a follow-up).
  ExternalImpactSource? _alarmExternal;
  _FollowUp? _followUp;
  double _lastImpactG = 0;

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
  String? _tripStatus;
  TrackPoint? _lastFix;
  bool _disposed = false;

  bool _dark = false;
  int _darkAt = 0;
  int _darkChecks = 0;
  TrackPoint? _darkFix;
  String? _fuelLoadedFor;
  double _fuelSavedM = 0;
  int _fuelMutation = 0;
  String? _fuelUserId;
  bool _fuelSavedUncertain = false;
  Future<void> _fuelWrites = Future.value();
  bool fuelSaveFailed = false;
  int _brakesSaved = 0;
  String? _weatherDoneFor;
  String? _tilesDoneFor;

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

  /// Metres ridden since the last fill (item 2), for the ride sheet line.
  double get riddenSinceFillM => _fuel.riddenM;
  double? get estimatedUsableKm => _fuel.usableKm(_settings.fuelProfile);
  bool get fuelEstimateUncertain => _fuel.uncertain;
  int get fuelConfirmedAt => _fuel.lastFillAt;
  bool refuel({bool full = false, double? addedL, double? currentL, double? currentKm}) {
    if (!_fuel.refuel(_settings.fuelProfile, _now(), full: full, addedL: addedL, currentL: currentL, currentKm: currentKm)) return false;
    _fuelMutation++;
    _removePrompt(SafetyConstants.promptFuel, notify: false);
    _saveFuel(force: true);
    notifyListeners();
    return true;
  }

  /// The fuel reminder is showing.
  bool get fuelReminderActive => _prompts.containsKey(SafetyConstants.promptFuel);

  /// Hard stops counted in this ride (item 14; rider only, never shared).
  int get hardStops => _brakes.count;

  /// After sunset at the last fix (item 15); recomputed at most every 5 min on fixes.
  bool get isDark => _dark;

  /// How many times the day/night flag was computed this ride (battery tests).
  @visibleForTesting
  int get darkChecks => _darkChecks;

  /// "Filled up" (quick action or the fuel prompt): the distance count starts again.
  void filledUp() {
    if (!_fuel.refuel(_settings.fuelProfile, _now(), full: true)) _fuel.filledUp(_now());
    _fuelMutation++;
    _removePrompt(SafetyConstants.promptFuel, notify: false);
    _saveFuel(force: true);
    notifyListeners();
  }

  /// Item 22: an impact reported by a wearable (or the hidden developer action). Opens
  /// the same alarm as the phone's own detector, with the last fix's position and speed;
  /// the SOS then carries source WEARABLE. Ignored outside a ride, with crash detection
  /// off, while an alarm or my SOS is open, or without a finite [g].
  void externalImpact({required ExternalImpactSource source, required double g, required int atMs}) {
    if (_disposed || !_port.rideActive || !_settings.crashDetection || _alarm != null || _port.hasOpenSos) return;
    if (!g.isFinite || g <= 0) return;
    final f = _lastFix;
    final uid = _port.myUserId;
    final me = uid == null ? null : _port.activeConvoy?.riders[uid];
    _alarmExternal = source;
    _openAlarm(CrashEvent(
      impactAtMs: atMs,
      impactG: g,
      speedBeforeKmh: f?.speedKmh ?? me?.speedKmh ?? 0,
      lat: f?.lat ?? me?.lat ?? 0,
      lng: f?.lng ?? me?.lng ?? 0,
    ));
    if (_alarm == null) _alarmExternal = null; // refused (cooldown, no answer yet)
  }

  /// The ride-start weather check when it did not run yet (the ride sheet may ask).
  Future<void> maybeRunStartWeather() => _startWeather();

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
    final e = _alarmEvent;
    _alarm = null;
    _alarmEvent = null;
    _detector.cooldown(_now());
    _endAlarmNative();
    // A real impact answered with "I'm OK": ask once more at the next stop or in 20 min.
    if (e != null && _alarmExternal != ExternalImpactSource.developer) {
      _lastImpactG = e.impactG;
      _followUp = _FollowUp(at: _now(), lat: e.lat, lng: e.lng);
    }
    _alarmExternal = null;
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
    } else if (key == SafetyConstants.promptFuel) {
      if (!primary) {
        filledUp();
        return;
      }
    } else if (key == SafetyConstants.promptFollowUp) {
      if (primary) {
        _sendCheckInWith(CheckInResult.ok, context: CheckInContext.followUp);
      } else {
        _needHelpAfterCrash();
      }
    }
    _removePrompt(key);
  }

  void _sendCheckInWith(CheckInResult result, {CheckInContext? context}) {
    final port = _port;
    if (port is SafetyCheckInPort) {
      (port as SafetyCheckInPort).sendCheckInWith(result, context: context);
    } else {
      port.sendCheckIn(result);
    }
  }

  /// "Need help" on the follow-up: an ordinary SOS (source NEED_HELP) from the last fix.
  void _needHelpAfterCrash() {
    final f = _lastFix;
    final uid = _port.myUserId;
    final me = uid == null ? null : _port.activeConvoy?.riders[uid];
    final fu = _followUp;
    final lat = f?.lat ?? me?.lat ?? fu?.lat ?? 0;
    final lng = f?.lng ?? me?.lng ?? fu?.lng ?? 0;
    final port = _port;
    if (port is SafetySourcePort) {
      (port as SafetySourcePort).raiseSosFrom(EmergencySource.needHelp, type: SosTypes.crash, lat: lat, lng: lng, impactG: _lastImpactG);
    } else {
      port.raiseSos(type: SosTypes.crash, lat: lat, lng: lng, impactG: _lastImpactG);
    }
  }

  /// "Text the group now" from the SOS sheet: the same round as the automatic one.
  Future<void> sendSmsNow() => _smsRound(manual: true);

  /// Test hook: opens the alarm as if the detector had fired.
  @visibleForTesting
  void debugRaiseCrash(CrashEvent e) => _openAlarm(e);

  // ------------------------------------------------------------------ inputs
  void _onConvoy() {
    if (_disposed) return;
    final convoy = _port.activeConvoy;
    final gid = convoy?.groupId;
    final active = _port.rideActive;
    if (gid != _groupId || active != _rideActive || _fuelUserId != _port.myUserId) {
      _fuelUserId = _port.myUserId;
      _fuelMutation++;
      _fuelLoadedFor = null;
      _endRideStats();
      // The ride ended or changed: a route map still being saved is for the old route (no data after the ride).
      if (_rideActive) _tiles?.cancel();
      _groupId = gid;
      _rideActive = active;
      _resetRide();
      if (active && gid != null) _restoreFuel(gid).ignore();
    }
    final status = convoy?.tripStatus;
    if (status != _tripStatus) {
      _tripStatus = status;
      if (status == 'STARTED' && active) {
        _startWeather().ignore();
        _startTiles().ignore();
      }
    }
    _watchPendingSos();
    _evalCheckIn();
    _evalFollowUp(convoy);
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
      // Hard stops are judged only while the detector is armed (the sensor runs then anyway).
      if (_detector.armedAt(p.ts)) _brakes.onFix(p);
      if (ev != null) _openAlarm(ev);
    }
    if (_settings.fatigueReminder && _fatigue.onFix(p)) {
      final hours = SafetyConstants.fatigueRideFor.inHours;
      final mins = SafetyConstants.fatigueBreakFor.inMinutes;
      _showPrompt(
        SafetyPrompt(
          key: SafetyConstants.promptFatigue,
          kind: SafetyPromptKind.fatigue,
          title: L10n.t('prompt.fatigue.title'),
          message: L10n.t('prompt.fatigue.body', {'h': hours, 'min': mins}),
          primaryLabel: L10n.t('prompt.ok'),
        ),
        notifyAlways: false,
      );
    }
    _onFuelFix(p);
    _onDarkFix(p);
    _evalFollowUp(_port.activeConvoy);
    _updateSensor();
  }

  void _onAccel(AccelBucket b) {
    if (_disposed) return;
    if (_detector.armedAt(b.tMs)) {
      _brakes.onAccel(b);
      if (_brakes.count > 0 && _brakes.count % 10 == 0 && _brakes.count != _brakesSaved) _saveRideStats(endedAt: 0);
    }
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
    _fuel = FuelRangeTracker();
    _fuelLoadedFor = null;
    _fuelSavedM = 0;
    _brakes.reset();
    _brakesSaved = 0;
    _followUp = null;
    _lastImpactG = 0;
    _alarmExternal = null;
    _darkAt = 0;
    _darkChecks = 0;
    _darkFix = null;
    if (_dark) {
      _dark = false;
      _voice?.setNight(false);
    }
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
        title: L10n.t('notif.crash.title'),
        body: L10n.t('notif.crash.body', {'n': seconds}),
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
    // An impact from outside the phone (wearable hook) is sent as such, whatever the answer.
    final external = _alarmExternal != null;
    _alarmExternal = null;
    final port = _port;
    if (port is SafetySourcePort) {
      (port as SafetySourcePort).raiseSosFrom(
        external ? EmergencySource.wearable : source,
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
    if (payload == null || payload.length <= AlarmNotifier.payloadPrompt.length + 1) return;
    final key = payload.substring(AlarmNotifier.payloadPrompt.length + 1);
    if (actionId == AlarmNotifier.actionPromptOk) {
      answerPrompt(key);
    } else if (actionId == AlarmNotifier.actionPromptSecondary) {
      answerPrompt(key, primary: false);
    }
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
        title: L10n.t('prompt.checkin.title'),
        message: told ? L10n.t('prompt.checkin.told') : L10n.t('prompt.checkin.body', {'min': mins, 'answer': answer}),
        primaryLabel: L10n.t('prompt.checkin.ok'),
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

  // ------------------------------------------------------------------ fuel range (item 2)
  void _onFuelFix(TrackPoint p) {
    _fuel.onFix(p);
    final range = _settings.fuelRangeKm;
    if (range > 0 && _fuel.shouldWarn(range)) {
      final km = (_fuel.riddenM / 1000).round();
      _showPrompt(
        SafetyPrompt(
          key: SafetyConstants.promptFuel,
          kind: SafetyPromptKind.fuel,
          title: L10n.t('fuel.title'),
          message: L10n.t('fuel.body', {'km': '$km km', 'range': range}),
          primaryLabel: L10n.t('prompt.ok'),
          secondaryLabel: L10n.t('fuel.filled'),
        ),
        notifyAlways: true,
      );
      _saveFuel(force: true);
    } else {
      _saveFuel();
    }
  }

  /// Written when the count moved by 500 m, on a fill or a reminder (cheap JSON, no timer).
  void _saveFuel({bool force = false}) {
    final gid = _groupId;
    if (gid == null || !_rideActive) return;
    if (!force && !fuelSaveFailed && _fuel.uncertain == _fuelSavedUncertain && (_fuel.riddenM - _fuelSavedM).abs() < 500) return;
    _fuelSavedM = _fuel.riddenM;
    _fuelSavedUncertain = _fuel.uncertain;
    final json = jsonEncode({'g': gid, 'u': _port.myUserId, 's': _fuel.toJson()});
    _fuelWrites = _fuelWrites.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        fuelSaveFailed = !await prefs.setString(SafetyConstants.keyFuelState, json);
      } catch (_) { fuelSaveFailed = true; }
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _restoreFuel(String gid) async {
    if (_fuelLoadedFor == gid) return;
    _fuelLoadedFor = gid;
    final mutation = _fuelMutation;
    final uid = _port.myUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(SafetyConstants.keyFuelState);
      if (_disposed || raw == null || raw.isEmpty || _groupId != gid || _port.myUserId != uid || mutation != _fuelMutation) return;
      final j = jsonDecode(raw);
      if (j is! Map || j['g'] != gid || j['u'] != uid) return;
      final saved = FuelRangeTracker.fromJson(j['s'] is Map ? j['s'] as Map : null);
      if (saved == null) return;
      // Fixes that came in while loading are few; the saved count is the larger one.
      if (saved.riddenM >= _fuel.riddenM) {
        _fuel = saved;
        _fuelSavedM = saved.riddenM;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------------ hard stops (item 14)
  void _endRideStats() {
    if (_groupId == null || !_rideActive) return;
    if (_brakes.count > 0) _saveRideStats(endedAt: _now());
  }

  void _saveRideStats({required int endedAt}) {
    final gid = _groupId;
    if (gid == null) return;
    _brakesSaved = _brakes.count;
    RideStatsStore.save(RideStats(groupId: gid, hardStops: _brakes.count, endedAt: endedAt)).ignore();
  }

  // ------------------------------------------------------------------ follow-up (item 19)
  /// After "I'm OK" on a real impact: once, at the next stop of [SafetyConstants.followUpStopFor]
  /// or [SafetyConstants.followUpAfter] later, whichever comes first. No timer: checked on fixes
  /// and convoy changes.
  void _evalFollowUp(ConvoyModel? convoy) {
    final fu = _followUp;
    if (fu == null || !_rideActive || _port.hasOpenSos) {
      if (fu != null && _port.hasOpenSos) _followUp = null; // an SOS is open: the group already knows
      return;
    }
    final now = _now();
    final uid = _port.myUserId;
    final me = uid == null || convoy == null ? null : convoy.riders[uid];
    final stoppedSince = me?.stoppedSince ?? 0;
    final stopped = stoppedSince > fu.at && now - stoppedSince >= SafetyConstants.followUpStopFor.inMilliseconds;
    final overdue = now - fu.at >= SafetyConstants.followUpAfter.inMilliseconds;
    if (!stopped && !overdue) return;
    _followUp = null;
    _showPrompt(
      SafetyPrompt(
        key: SafetyConstants.promptFollowUp,
        kind: SafetyPromptKind.followUp,
        title: L10n.t('prompt.followup.title'),
        message: L10n.t('prompt.followup.body'),
        primaryLabel: L10n.t('prompt.followup.fine'),
        secondaryLabel: L10n.t('prompt.followup.help'),
      ),
      notifyAlways: true,
    );
  }

  // ------------------------------------------------------------------ dark (item 15)
  void _onDarkFix(TrackPoint p) {
    if (p.lat == 0 && p.lng == 0) return;
    final now = _now();
    final last = _darkFix;
    final moved = last == null || GeoMath.haversine(last.lat, last.lng, p.lat, p.lng) > SafetyConstants.darkRecheckMoveM;
    if (_darkAt != 0 && !moved && now - _darkAt < SafetyConstants.darkRecheckEvery.inMilliseconds) return;
    _darkAt = now;
    _darkFix = p;
    _darkChecks++;
    final dark = DarkCheck.isDark(DateTime.fromMillisecondsSinceEpoch(now), p.lat, p.lng);
    if (dark != _dark) {
      _dark = dark;
      _voice?.setNight(dark);
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ ride start (items 7, 16)
  Future<void> _startWeather() async {
    final w = _weather;
    final convoy = _port.activeConvoy;
    final gid = convoy?.groupId;
    if (w == null || convoy == null || gid == null || _weatherDoneFor == gid || convoy.tripStatus != 'STARTED') return;
    final route = convoy.route;
    if (route == null || route.points.length < 2 || _settings.lowData) return;
    _weatherDoneFor = gid;
    final pts = WeatherService.samplePoints(
      line: route.points,
      durationS: route.durationS,
      departS: _now() ~/ 1000,
      namedStops: [for (final s in convoy.plannedStops) (s.name, s.lat, s.lng)],
      destinationName: convoy.destinationName.split(',').first.trim(),
    );
    try {
      await w.check(pts);
    } catch (_) {}
  }

  /// Saves the route's tiles once per group, only on Wi-Fi, with the setting on and not in
  /// data saver. The "Save route map" tap in the sheets starts the same job on any network.
  Future<void> _startTiles() async {
    final t = _tiles;
    final convoy = _port.activeConvoy;
    final gid = convoy?.groupId;
    if (t == null || convoy == null || gid == null || _tilesDoneFor == gid) return;
    if (!_settings.saveRouteMaps || _settings.lowData || t.running) return;
    final route = convoy.route;
    if (route == null || route.approximate || route.points.length < 2) return;
    _tilesDoneFor = gid;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || prefs.getString(SafetyConstants.keyTilesPrefetchedFor) == gid) return;
      if (await _networkKind() != 'wifi') {
        _tilesDoneFor = null; // not now: tried again when the status changes, or by the rider's tap
        return;
      }
      await prefs.setString(SafetyConstants.keyTilesPrefetchedFor, gid);
      await t.start(route.points, label: convoy.name);
    } catch (_) {}
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
    _saveFuel(force: true);
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

/// A follow-up question waiting for the next stop (item 19).
class _FollowUp {
  final int at;
  final double lat;
  final double lng;
  const _FollowUp({required this.at, required this.lat, required this.lng});
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
