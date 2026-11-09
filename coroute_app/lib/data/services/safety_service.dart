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
import '../../domain/places/fuel_advisor.dart';
import '../../domain/places/fuel_ahead.dart';
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
import 'background_service.dart';
import 'biometric_safety_bridge.dart';
import 'convoy_service.dart';
import 'fuel_economy_service.dart';
import '../../core/config/feature_gates.dart';
import 'safety_native.dart';
import 'settings_service.dart';
import 'sms_sender.dart';
import 'solo_fix_source.dart';
import 'tile_cache_service.dart';
import 'voice_service.dart';
import 'weather_service.dart';
import '../../domain/garage/engine_care.dart';
import '../../domain/safety/effective_speed_limit.dart';
import '../../domain/safety/road_surface_detector.dart';
import '../../domain/safety/rider_down_detector.dart';
import '../../domain/safety/crash_incident.dart' show CrashScenario, MovementState;
import 'sensor_safety_hub.dart';
import 'sos_battery_reserve.dart';
import 'road_care_service.dart';

enum SafetyPromptKind { checkIn, fatigue, fuel, followUp, overspeed }

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
        SafetyPromptKind.overspeed => AlertTier.critical,
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
  final bool isUnresponsive;
  final bool isSirenActive;

  /// FEAT-04: Smartwatch biometric trauma & pulse verification vitals during crash alarm.
  final int? currentBpm;
  final BiometricTraumaLevel? traumaLevel;

  const CrashAlarmState({
    required this.startedAtMs,
    required this.secondsLeft,
    required this.impactG,
    required this.speedBeforeKmh,
    this.lat = 0,
    this.lng = 0,
    this.sent = false,
    this.isUnresponsive = false,
    this.isSirenActive = false,
    this.currentBpm,
    this.traumaLevel,
  });

  CrashAlarmState copyWith({
    int? secondsLeft,
    bool? sent,
    bool? isUnresponsive,
    bool? isSirenActive,
    int? currentBpm,
    BiometricTraumaLevel? traumaLevel,
  }) => CrashAlarmState(
        startedAtMs: startedAtMs,
        secondsLeft: secondsLeft ?? this.secondsLeft,
        impactG: impactG,
        speedBeforeKmh: speedBeforeKmh,
        lat: lat,
        lng: lng,
        sent: sent ?? this.sent,
        isUnresponsive: isUnresponsive ?? this.isUnresponsive,
        isSirenActive: isSirenActive ?? this.isSirenActive,
        currentBpm: currentBpm ?? this.currentBpm,
        traumaLevel: traumaLevel ?? this.traumaLevel,
      );
}

enum SmsFallbackState { idle, sending, sent, partly, failed, notAllowed, composer, composerWaiting }

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
        return 'Texts cannot be sent from this phone. Check "Text the group" in Settings, or call your emergency contact or 112.';
      case SmsFallbackState.composer:
        return 'Your messages app is open with the SOS text for $total ${total == 1 ? 'person' : 'people'}. Press Send.';
      case SmsFallbackState.composerWaiting:
        return 'No internet. Open CoRoute and tap the text button on the SOS screen to send the SOS by text.';
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
  String? get myBloodGroup;

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
    Map<String, dynamic>? biometrics,
    String? traumaLevel,
  });
}

/// Optional extension of [SafetyPort] (3.16): a check-in with a context (the post-crash
/// follow-up sends `CHECK_IN {context: FOLLOW_UP}`). Ports without it get the plain call.
abstract class SafetyCheckInPort {
  bool sendCheckInWith(CheckInResult result, {double? awayM, CheckInContext? context});
}

/// Optional extension of [SafetyPort]: updates telemetry status reason for safety escalation.
abstract class SafetyStatusReasonPort {
  void updateStatusReason({required String userId, required String reason, String message = ''});
}

/// Adapts the real ConvoyService and AuthService.
class ConvoySafetyPort implements SafetyPort, SafetySourcePort, SafetyCheckInPort, SafetyStatusReasonPort {
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
  String? get myBloodGroup => _auth.bloodGroup;

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
    Map<String, dynamic>? biometrics,
    String? traumaLevel,
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
        biometrics: biometrics,
        traumaLevel: traumaLevel,
      );

  @override
  bool sendCheckIn(CheckInResult result, {double? awayM}) => _convoys.sendCheckIn(result, awayM: awayM);

  @override
  bool sendCheckInWith(CheckInResult result, {double? awayM, CheckInContext? context}) =>
      _convoys.sendCheckIn(result, awayM: awayM, context: context);

  @override
  void updateStatusReason({required String userId, required String reason, String message = ''}) =>
      _convoys.updateStatusReason(userId: userId, reason: reason, message: message);
}

/// Rider safety on the phone: crash detection with a 15 s alarm ("Possible accident
/// detected. Are you okay?", [SafetyConstants.crashCountdown]), emergency texts
/// when an SOS cannot reach the group, the break reminder and the "Are you OK?"
/// check-in. 3.16 adds the fuel reminder, the hard-stop count (rider only), the
/// post-crash follow-up, the night flag for spoken alerts, the weather check and
/// the route map prefetch at ride start, and the wearable impact hook.
/// Battery: the accelerometer runs only during a ride (a convoy ride or an offline solo ride,
/// see [startOfflineSoloRide]), only while the detector is armed (12 km/h or more for 10 s, or
/// above 25 km/h; disarmed after 3 min parked) or an impact is being checked, and only with
/// crash detection on. No timer runs while idle: the
/// alarm countdown, the SMS wait and the check-in answer wait are one-shot or
/// alarm-only timers; everything new in 3.16 rides on fixes and convoy changes.
class SafetyService extends ChangeNotifier {
  static SafetyService? _instance;

  /// Globally accessible instance of [SafetyService] (initialized during app bootstrap).
  static SafetyService get instance {
    final inst = _instance;
    if (inst == null) {
      throw StateError('SafetyService.instance has not been initialized');
    }
    return inst;
  }

  /// Override or assign the active [SafetyService] instance (e.g. for testing or mocking).
  static set instance(SafetyService? service) {
    _instance = service;
  }

  /// Whether a global [SafetyService] instance is currently active.
  static bool get hasInstance => _instance != null;

  SafetyService(
    ConvoyService convoys,
    SettingsService settings,
    AuthService auth, {
    AccelSource? accel,
    SmsSender? sms,
    VoiceService? voice,
    WeatherService? weather,
    TilePrefetcher? tiles,
    Stream<TrackPoint> Function()? soloFixes,
  }) : this._(ConvoySafetyPort(convoys, auth), settings, accel ?? NativeAccelSource(), sms ?? NativeSmsSender(), null, true,
            voice: voice, weather: weather, tiles: tiles, soloFixes: soloFixes);

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
    Stream<TrackPoint> Function()? soloFixes,
  }) : this._(port, settings, accel, sms, clock, false,
            voice: voice, weather: weather, tiles: tiles, networkKind: networkKind,
            soloFixes: soloFixes);

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
    Stream<TrackPoint> Function()? soloFixes,
  })  : _networkKind = networkKind ?? SafetyNative.networkKind,
        _soloFixSource = soloFixes ?? nativeSoloFixes {
    _port.addListener(_onConvoy);
    _settings.addListener(_onSettings);
    _lowDataWas = _settings.lowData; // 3.55 fix: see _onSettings
    _crashDetectionWas = _settings.crashDetection;
    _fixSub = _port.myFixes.listen(_onFix, onError: (Object _) {});
    if (_native) {
      AlarmNotifier.ensureInitialized().ignore();
      AlarmNotifier.onAction(AlarmNotifier.payloadCrash, _onCrashAction);
      AlarmNotifier.onAction(AlarmNotifier.payloadPrompt, _onPromptAction);
    }
    sensorSafety.featureOn = (id) => featureOn?.call(id) ?? true; // 3.55 switches
    sensorSafety.addListener(notifyListeners);
    _onConvoy();
    _instance = this;
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

  // Offline solo ride (3.54): crash detection and a local SOS without a convoy or internet.
  final Stream<TrackPoint> Function() _soloFixSource;
  StreamSubscription<TrackPoint>? _soloFixSub;
  bool _soloActive = false;
  int _soloStartedAt = 0;
  PendingSos? _soloSos;

  /// The group id of an SOS raised during an offline solo ride (never sent to the server).
  static const String offlineSoloGroupId = 'offline-solo';

  CrashDetector get detector => _detector;

  final CrashDetector _detector = CrashDetector();
  final FatigueTracker _fatigue = FatigueTracker();
  final SoloCheckIn _checkIn = SoloCheckIn();
  FuelRangeTracker _fuel = FuelRangeTracker();

  /// Learned mileage, riding style and "fill up here" warnings (on the phone only).
  final FuelEconomyService fuelEconomy = FuelEconomyService();

  /// Stations ahead on the route for this bike, from the map places on the phone
  /// (set by the ride map). Called with each fix; null = range-only warnings.
  FuelAheadView? Function(double lat, double lng, double? usableKm, double marginKm)? fuelAheadSource;
  FuelAheadView? _fuelAhead;

  /// What the last fuel check saw ahead (for the fuel capsule and sheets).
  FuelAheadView? get fuelAhead => _fuelAhead;
  final HardBrakeCounter _brakes = HardBrakeCounter();

  StreamSubscription<TrackPoint>? _fixSub;
  StreamSubscription<AccelBucket>? _accelSub;

  // 3.55: road surface events (pothole, speed breaker, rough road) from the same 1 s buckets,
  // and engine care from the garage bike's details.
  final RoadSurfaceDetector _surface = RoadSurfaceDetector();

  /// 3.55 phone-only sensor safety (fatigue score, rider-down check, crash learning, phone-mount
  /// check, ride safety report): logic in [SensorSafetyHub], only hooks here.
  final SensorSafetyHub sensorSafety = SensorSafetyHub();

  /// 0-100 fatigue level of this rider (3.55 fatigue score), for the group break planner.
  /// Only this level is ever shared, never the sensor data behind it.
  int get fatigueLevel => sensorSafety.fatigueLevel;

  /// The open alarm is a "Bike down?" check (3.55 rider-down), not a crash.
  bool _alarmRiderDown = false;
  bool get alarmIsRiderDown => _alarm != null && _alarmRiderDown;
  static const String riderDownTitle = 'Bike down?';

  /// 3.55 fix: crash detection switched off while an alarm counts down stops new alarms only. The
  /// running alarm continues (never cancelled behind the rider's back: they may be hurt and the
  /// switch may have been bumped); the alarm screen says so and points to "I'm OK".
  static const String crashAlarmStillRunning = "Crash detection is off for new alarms. This alarm is still running: tap I'm OK to cancel it.";

  /// True while a countdown runs with crash detection switched off (see [crashAlarmStillRunning]).
  bool get alarmRunsWithDetectionOff {
    final a = _alarm;
    return a != null && !a.sent && !_settings.crashDetection;
  }

  /// Receives road surface events while riding (main.dart: ConvoyService reports them to the
  /// group when I ride at the front). Never called in an offline solo ride.
  void Function(RoadSurfaceEvent event)? onRoadSurface;

  final EngineCareAdvisor engineCare = EngineCareAdvisor();

  /// 3.55 road context on the phone: sharp bends, road speed limits, altitude and night care.
  late final RoadCareService roadCare = RoadCareService(
    voice: _voice,
    emergency: () => _alarm != null || _hasOpenSos || (_port.activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false),
    featureOn: (id) => featureOn?.call(id) ?? true,
    convoyLine: () => _port.activeConvoy?.route?.points,
    onChanged: () {
      if (!_disposed) notifyListeners();
    },
    now: _now,
  );
  EngineCareAdvice? _engineNotice;
  Timer? _engineNoticeClear;

  /// "Give your engine a rest" for 60 s after it is advised (the cockpit shows it as a card).
  EngineCareAdvice? get engineNotice => _engineNotice;

  void dismissEngineNotice() {
    _engineNoticeClear?.cancel();
    _engineNotice = null;
    notifyListeners();
  }
  bool _accelUnavailable = false;

  CrashAlarmState? _alarm;
  CrashEvent? _alarmEvent;
  Timer? _alarmTimer;
  Timer? _bystanderSirenTimer;

  /// Set for an alarm raised through [externalImpact] (sent as source WEARABLE; the
  /// developer action never schedules a follow-up).
  ExternalImpactSource? _alarmExternal;
  _FollowUp? _followUp;
  double _lastImpactG = 0;

  final Map<String, SafetyPrompt> _prompts = {};
  Timer? _checkInTimer;
  Timer? _fatigueTimer;
  bool _fatigueEscalated = false;
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

  // This ride's own safety counts for "Your ride analytics" (RideStats, on the phone only).
  int _rideBreaks = 0;
  int _rideAlerts = 0;
  bool _rideSos = false;
  bool _rideCrash = false;
  String? _weatherDoneFor;
  String? _tilesDoneFor;
  int _overspeedSince = 0;
  int _lastOverspeedAlertMs = 0;
  bool _isOverspeedActive = false;
  int _lastCheckedLimit = 0;

  int _now() => _clock?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// A convoy ride or an offline solo ride is running.
  bool get _rideOn => _port.rideActive || _soloActive;

  /// Only the offline solo ride is running (no convoy to send an SOS to).
  bool get _soloOnly => _soloActive && !_port.rideActive;

  bool get _hasOpenSos => _port.hasOpenSos || _soloSos != null;

  /// The SOS waiting for delivery: the convoy's, or the offline solo ride's.
  PendingSos? get _pendingSos => _port.pendingSos ?? _soloSos;

  // ------------------------------------------------------------------ offline solo ride
  /// An offline solo ride is running (3.54): no convoy and no internet needed. Crash detection
  /// runs on the phone's own GPS and accelerometer; an SOS opens the messages app with the text
  /// for the emergency contact, and the alarm screen offers a call to the contact or 112.
  bool get offlineSoloActive => _soloActive;

  /// When the offline solo ride started (epoch ms), 0 when none runs.
  int get offlineSoloStartedAt => _soloActive ? _soloStartedAt : 0;

  /// The SOS of the offline solo ride, while it is open (until [resolveOfflineSoloSos] or the end).
  PendingSos? get offlineSoloSos => _soloSos;

  /// My last fix during a ride (convoy or offline solo), for the SOS sheet's position.
  TrackPoint? get lastFix => _lastFix;

  /// Starts an offline solo ride. False when a convoy ride is active (it has crash detection
  /// already), one is running, or the service is disposed.
  bool startOfflineSoloRide() {
    if (_disposed || _soloActive || _port.rideActive) return false;
    _soloActive = true;
    _soloStartedAt = _now();
    _soloSos = null;
    _lastFix = null;
    _detector.reset();
    _soloFixSub = _soloFixSource().listen(_onFix, onError: (Object _) {});
    // The foreground service keeps GPS and the sensor alive with the screen off.
    if (_native) BackgroundService.start(convoyName: 'Solo ride (offline)', riderCount: 1).ignore();
    _updateSensor();
    notifyListeners();
    return true;
  }

  /// Ends the offline solo ride (sensor and GPS off, the foreground service stopped).
  void stopOfflineSoloRide() => _endSolo(stopService: true);

  /// "Help reached me" / "False alarm" for the solo ride's SOS: closes it on the phone.
  void resolveOfflineSoloSos() {
    if (_soloSos == null) return;
    _soloSos = null;
    notifyListeners();
  }

  void _endSolo({required bool stopService}) {
    if (!_soloActive) return;
    _soloActive = false;
    _soloStartedAt = 0;
    _soloFixSub?.cancel();
    _soloFixSub = null;
    _soloSos = null;
    if (!_port.rideActive) {
      _detector.reset();
      _lastFix = null;
      if (stopService && _native) BackgroundService.stop().ignore();
    }
    _updateSensor();
    notifyListeners();
  }

  /// The crash SOS of an offline solo ride: kept on the phone, and the emergency text goes out at
  /// once (the messages app when the phone is in hand; there is no server to wait for).
  void _raiseSoloSos({
    required String type,
    required double lat,
    required double lng,
    required EmergencySource source,
    double? speedBeforeKmh,
    double? impactG,
    int? occurredAtMs,
    bool auto = true,
    bool manual = false,
  }) {
    final now = _now();
    _soloSos ??= PendingSos(
      clientId: 'solo-${_port.myUserId ?? 'rider'}-$now',
      groupId: offlineSoloGroupId,
      lat: lat,
      lng: lng,
      type: type,
      createdAt: occurredAtMs ?? now,
      auto: auto,
      speedBeforeKmh: speedBeforeKmh,
      impactG: impactG,
      source: source,
    );
    notifyListeners();
    _smsRound(manual: manual).ignore();
  }

  // ------------------------------------------------------------------ public API
  CrashAlarmState? get alarm => _alarm;
  bool get isOverspeedActive => _isOverspeedActive;
  int get currentSpeedLimit => _lastCheckedLimit;
  List<SafetyPrompt> get prompts => List.unmodifiable(_prompts.values);

  // 3.55 (solo check-in by ETA, lib/data/services/solo_guardian_service.dart): a prompt owned by
  // another service, shown and notified like this service's own; the owner gets the answer.
  final Map<String, void Function(bool primary)> _promptOwners = <String, void Function(bool primary)>{};
  void showOwnedPrompt(SafetyPrompt p, void Function(bool primary) onAnswer) {
    _promptOwners[p.key] = onAnswer;
    _showPrompt(p, notifyAlways: true);
  }

  void removeOwnedPrompt(String key) {
    _promptOwners.remove(key);
    _removePrompt(key);
  }

  /// A crash alarm or an SOS of mine is open (nothing else may speak or ask then).
  bool get emergencyOpen => _alarm != null || _hasOpenSos;
  SmsFallbackStatus? get smsStatus => _smsStatus;

  /// The accelerometer is running right now.
  bool get detectorArmed => _accelSub != null;

  /// Whether the safety sensor hardware is unavailable or failed on this device.
  bool get isSensorUnavailable => _accelUnavailable;

  /// "Text the group now" can be used: texts allowed, an SOS is waiting and was not texted yet.
  bool get smsAvailable {
    final p = _pendingSos;
    return (_settings.smsFallback || p?.groupId == offlineSoloGroupId) && p != null && !_smsRounds.contains(p.clientId) && !_smsBusy;
  }

  /// Metres ridden since the last fill (item 2), for the ride sheet line.
  bool get fuelTrackingActive => _rideActive;
  double get riddenSinceFillM => _fuel.riddenM;
  FuelAlertTier get currentFuelAlertTier => _fuel.lastAlertTier;
  void markStationClosed(String stationId) => _fuel.markStationClosed(stationId);
  bool isStationClosed(String stationId) => _fuel.isStationClosed(stationId);

  double? get estimatedUsableKm {
    final p = _settings.fuelProfile;
    final explicit = _fuel.usableKm(p);
    if (explicit != null) return fuelEconomy.adjust(p, baselineKm: _fuel.baselineKm!, riddenKm: _fuel.riddenM / 1000) ?? explicit;
    if (p.valid) return fuelEconomy.adjust(p, baselineKm: p.rangeKm, riddenKm: _fuel.riddenM / 1000) ?? p.usableKm(p.rangeKm, _fuel.riddenM);
    if (_settings.fuelRangeKm > 0) {
      return math.max(0.0, _settings.fuelRangeKm - (_fuel.riddenM / 1000.0));
    }
    return null;
  }
  bool get fuelEstimateUncertain => _fuel.uncertain;
  int get fuelConfirmedAt => _fuel.lastFillAt;
  bool refuel({bool full = false, double? addedL, double? currentL, double? currentKm}) {
    final sinceKm = _fuel.riddenM / 1000, reliable = !_fuel.uncertain;
    if (!_fuel.refuel(_settings.fuelProfile, _now(), full: full, addedL: addedL, currentL: currentL, currentKm: currentKm)) return false;
    fuelEconomy.recordFill(kmSincePrev: sinceKm, amount: addedL, full: full, reliable: reliable,
        ratedKmPerUnit: _settings.fuelProfile.mileageKmL, at: _now()).ignore();
    _fuelMutation++;
    _removePrompt(SafetyConstants.promptFuel, notify: false);
    _saveFuel(force: true);
    notifyListeners();
    return true;
  }

  /// Allows the fuel sheet to report a disk failure before it closes.
  Future<bool> waitForFuelSave() async {
    await _fuelWrites;
    return !fuelSaveFailed;
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
    final sinceKm = _fuel.riddenM / 1000, reliable = !_fuel.uncertain;
    if (!_fuel.refuel(_settings.fuelProfile, _now(), full: true)) _fuel.filledUp(_now());
    fuelEconomy.recordFill(kmSincePrev: sinceKm, full: true, reliable: reliable,
        ratedKmPerUnit: _settings.fuelProfile.mileageKmL, at: _now()).ignore();
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
    if (_disposed || !_rideOn || !_settings.crashDetection || _alarm != null || _hasOpenSos) return;
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
    silenceSiren();
    _alarmTimer?.cancel();
    _alarmTimer = null;
    final e = _alarmEvent;
    _alarm = null;
    _alarmEvent = null;
    _detector.cooldown(_now());
    _endAlarmNative();
    // 3.55: "I'm OK" on a phone crash alarm tunes this bike's possible-crash stage (bounded, never
    // the severe paths); a "Bike down?" check or an outside impact never does.
    final riderDown = _alarmRiderDown;
    _alarmRiderDown = false;
    if (e != null && !riderDown && _alarmExternal == null) sensorSafety.onFalseAlarm(e.scenario);
    // A real impact answered with "I'm OK": ask once more at the next stop or in 20 min.
    if (e != null && !riderDown && _alarmExternal != ExternalImpactSource.developer) {
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
    silenceSiren();
    _alarmTimer?.cancel();
    _alarmTimer = null;
    _alarm = null;
    _alarmEvent = null;
    _alarmRiderDown = false;
    notifyListeners();
  }

  /// Silences the piercing bystander audio beacon when the rider confirms consciousness,
  /// while keeping the SOS distress broadcast active for the convoy and responders.
  void silenceSiren() {
    _bystanderSirenTimer?.cancel();
    _bystanderSirenTimer = null;
    _voice?.stop();
    if (_alarm != null && _alarm!.isSirenActive) {
      _alarm = _alarm!.copyWith(isSirenActive: false);
      notifyListeners();
    }
  }

  void answerPrompt(String key, {bool primary = true}) {
    if (!_prompts.containsKey(key)) return;
    final owner = _promptOwners.remove(key);
    if (owner != null) {
      _removePrompt(key);
      owner(primary);
      return;
    }
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
    } else if (key == SafetyConstants.promptFatigue) {
      final wasEscalated = _fatigueEscalated;
      _fatigueTimer?.cancel();
      _fatigueTimer = null;
      _fatigueEscalated = false;
      if (primary) {
        if (wasEscalated) {
          _sendCheckInWith(CheckInResult.ok, context: CheckInContext.fatigue);
          _updateStatusReason(reason: '', message: '');
        }
        _voice?.speakFatigueConfirmation('Safety confirmed. Continuing ride.', dedupeKey: 'fatigue_confirm_ok');
      } else {
        if (_fatigue.stretchStart != null) _rideBreaks++;
        _fatigue.reset();
        if (wasEscalated) {
          _sendCheckInWith(CheckInResult.ok, context: CheckInContext.fatigue);
          _updateStatusReason(reason: '', message: '');
        }
        _voice?.speakFatigueConfirmation('Break noted. Rest well.', dedupeKey: 'fatigue_break_ok');
      }
    } else if (key == SafetyConstants.promptOverspeed) {
      _lastOverspeedAlertMs = _now();
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

    final biometricsBridge = BiometricSafetyBridge();
    Map<String, dynamic>? bioPayload;
    String? traumaLevel;
    String alertType = SosTypes.crash;
    if (biometricsBridge.isActive) {
      final snap = biometricsBridge.snapshot;
      traumaLevel = snap.traumaLevel.wire;
      if (snap.isCritical) {
        alertType = 'CRITICAL_TRAUMA_L1';
      }
      bioPayload = biometricsBridge.toBiometricPayload(bloodGroup: _port.myBloodGroup);
    }

    if (port is SafetySourcePort) {
      (port as SafetySourcePort).raiseSosFrom(
        EmergencySource.needHelp,
        type: alertType,
        lat: lat,
        lng: lng,
        impactG: _lastImpactG,
        biometrics: bioPayload,
        traumaLevel: traumaLevel,
      );
    } else {
      port.raiseSos(type: alertType, lat: lat, lng: lng, impactG: _lastImpactG);
    }
  }

  /// "Text the group now" from the SOS sheet: the same round as the automatic one.
  Future<void> sendSmsNow() => _smsRound(manual: true);

  /// Tests replace how the messages app is opened (default [SmsComposer.open]).
  @visibleForTesting
  static Future<bool> Function(List<String> to, String body)? smsComposerOverride;

  static Future<bool> _openComposer(List<String> to, String body) => SmsComposer.open(to: to, body: body);

  /// Test hook: opens the alarm as if the detector had fired.
  @visibleForTesting
  void debugRaiseCrash(CrashEvent e) => _openAlarm(e);

  // ------------------------------------------------------------------ inputs
  void _onConvoy() {
    if (_disposed) return;
    _recheckSpeedLimit();
    // A convoy ride took over from an offline solo ride (it has its own crash detection and SOS);
    // the foreground service now belongs to the convoy, so it keeps running.
    if (_soloActive && _port.rideActive) _endSolo(stopService: false);
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
      if (active && gid != null) {
        _restoreFuel(gid).ignore();
        fuelEconomy.ensureLoaded(reload: true).ignore();
      }
    }
    final status = convoy?.tripStatus;
    if (status != _tripStatus) {
      _tripStatus = status;
      if (status == 'STARTED' && active) {
        _startWeather().ignore();
        _startTiles().ignore();
      }
    }
    if (_rideActive && _hasOpenSos) _rideSos = true;
    _watchPendingSos();
    _evalCheckIn();
    _evalFollowUp(convoy);
    _updateSensor();
    if (active) {
      if (FeatureGates.isUnlocked(Feature.biometricTraumaPulse) && !BiometricSafetyBridge().isActive) {
        BiometricSafetyBridge().start();
      }
    } else {
      if (BiometricSafetyBridge().isActive) {
        BiometricSafetyBridge().stop();
      }
    }
  }

  /// Data saver as last seen by [_onSettings] (3.55 fix).
  bool? _lowDataWas;

  /// Crash detection as last seen by [_onSettings] (3.55 fix).
  bool? _crashDetectionWas;

  void _onSettings() {
    if (_disposed) return;
    _recheckSpeedLimit();
    // 3.55 fix: Data saver switched off during a started ride: the route weather check and the
    // Wi-Fi route map save skipped at ride start (data saver was on) run now instead of never.
    // Both keep their once-per-ride guards. Switching it on stops nothing (the map save is Wi-Fi only).
    final lowData = _settings.lowData;
    if (_lowDataWas == true && !lowData && _rideActive && _tripStatus == 'STARTED') {
      _startWeather().ignore();
      _startTiles().ignore();
    }
    _lowDataWas = lowData;
    if (!_settings.crashDetection) _detector.reset();
    // 3.55 fix: switched off during a countdown: the alarm keeps running (deliberate, for safety)
    // and the alarm notification says how to cancel it, like the alarm screen does.
    final crashOn = _settings.crashDetection;
    if (_crashDetectionWas == true && !crashOn && alarmRunsWithDetectionOff && _native) {
      AlarmNotifier.showCrashAlarm(
        title: _alarmRiderDown ? riderDownTitle : L10n.t('notif.crash.title'),
        body: crashAlarmStillRunning,
      ).ignore();
    }
    _crashDetectionWas = crashOn;
    if (!_settings.fatigueReminder) {
      _fatigue.reset();
      _fatigueTimer?.cancel();
      _fatigueTimer = null;
      _fatigueEscalated = false;
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
    if (_disposed || !_rideOn) return;
    _lastFix = p;
    if (_settings.crashDetection) {
      final ev = _detector.onFix(p);
      // Hard stops are judged only while the detector is armed (the sensor runs then anyway).
      if (_detector.armedAt(p.ts)) _brakes.onFix(p);
      if (ev != null) _openAlarm(ev);
    }
    // 3.55 sensor safety: rider-down speed, fatigue score, ride safety report (phone only).
    sensorSafety.onFix(p, stretchStart: _fatigue.stretchStart, limitKmh: _lastCheckedLimit, dark: _dark);
    sensorSafety.summary.onReserve(SosBatteryReserve.isActive, p.ts);
    if (_soloOnly) {
      // Offline solo ride: crash detection only (no convoy for check-ins, fuel or route data).
      _updateSensor();
      return;
    }
    final wasRiding = _fatigue.stretchStart != null;
    final remind = _fatigue.onFix(p);
    if (wasRiding && _fatigue.stretchStart == null) _rideBreaks++; // a rest of 10 min or more
    // 3.55 fix: the 2 h rule also obeys the break reminder switch. The tracker keeps counting the
    // stretch (ride stats, the fatigue score), but with the reminder off it used to prompt and
    // speak anyway, so switching it off (before or during the ride) looked ignored.
    if (remind && _settings.fatigueReminder) {
      _triggerFatigueAlert();
      sensorSafety.noteRulePrompt(p.ts);
    } else if (_settings.fatigueReminder &&
        !_prompts.containsKey(SafetyConstants.promptFatigue) &&
        sensorSafety.earlyFatigueDue(nowMs: p.ts, stretchStart: _fatigue.stretchStart)) {
      _triggerAdaptiveFatigueAlert(p.ts); // 3.55 fatigue score: earlier, never later than the 2 h rule
    } else if (_settings.fatigueReminder) {
      // 3.55 night riding care: one softer break prompt at 90 min after sunset (shown by roadCare).
      roadCare.nightBreakDue(stretchStartMs: _fatigue.stretchStart, nowMs: p.ts);
    }
    _onFuelFix(p);
    _onEngineFix(p);
    _onDarkFix(p);
    _evalFollowUp(_port.activeConvoy);
    _checkSpeedLimit(p);
    roadCare.onFix(p, dark: _dark, otherLimitKmh: _lastCheckedLimit, otherActive: _isOverspeedActive); // 3.55
    _updateSensor();
  }

  /// 3.55 admin feature switches (set in main.dart to FeatureFlagsService.on). Null = on. Only
  /// non-safety extras read it (engine care); crash detection, SOS and texts never do.
  bool Function(String id)? featureOn;

  /// Engine care (3.55): once per hard stretch, spoken and shown for a minute.
  void _onEngineFix(TrackPoint p) {
    if (!(featureOn?.call('engineCare') ?? true)) return; // switched off by the admin
    final advice = engineCare.onFix(p);
    if (advice == null) return;
    // 3.55 safety review: an engine tip never shows or speaks over an emergency (my crash alarm,
    // my SOS, or any open SOS / crash alert in the group).
    final emergency = _alarm != null || _hasOpenSos || (_port.activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false);
    if (emergency) return;
    _engineNotice = advice;
    _engineNoticeClear?.cancel();
    _engineNoticeClear = Timer(const Duration(seconds: 60), () {
      _engineNotice = null;
      notifyListeners();
    });
    _voice?.speak(advice.speech);
    notifyListeners();
  }

  void _triggerFatigueAlert() {
    final hours = SafetyConstants.fatigueRideFor.inHours;
    _voice?.speakFatigueConfirmation(
      "Time for a break. You've been riding for $hours hours. Please confirm your safety.",
      dedupeKey: 'fatigue_break_alert',
    );
    _showPrompt(
      SafetyPrompt(
        key: SafetyConstants.promptFatigue,
        kind: SafetyPromptKind.fatigue,
        title: "Time for a Break",
        message: "You've been riding for $hours hours. Please confirm your safety.",
        primaryLabel: "I'm Alert & Safe",
        secondaryLabel: "Taking a Break",
      ),
      notifyAlways: true,
    );

    _fatigueTimer?.cancel();
    _fatigueEscalated = false;
    _fatigueTimer = Timer(const Duration(seconds: 60), _onFatigue60sTimeout);
  }

  /// 3.55 fatigue score: an earlier break prompt when the rider's pattern shows tiredness (at
  /// most one fatigue prompt per 30 min; the 2 h rule above still comes on time). Informational:
  /// no escalation to the lead, never over an emergency.
  void _triggerAdaptiveFatigueAlert(int nowMs) {
    final emergency = _alarm != null || _hasOpenSos || (_port.activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false);
    if (emergency) return;
    final a = sensorSafety.fatigue;
    sensorSafety.noteEarlyPrompt(nowMs);
    _voice?.speakFatigueConfirmation(
      'Time for a break soon. Your riding shows signs of tiredness.',
      dedupeKey: 'fatigue_adaptive_${nowMs ~/ 60000}',
    );
    _showPrompt(
      SafetyPrompt(
        key: SafetyConstants.promptFatigue,
        kind: SafetyPromptKind.fatigue,
        title: 'Time for a break',
        message: a.suggestedBreakInMin <= 5
            ? 'Your riding shows signs of tiredness. Stop at the next safe place for a break.'
            : 'Your riding shows signs of tiredness. Plan a break in the next ${a.suggestedBreakInMin} min.',
        primaryLabel: "I'm alert",
        secondaryLabel: 'Taking a break',
      ),
      notifyAlways: true,
    );
  }

  /// 3.55 rider-down check: the bike went down at a stop and nothing moved for a minute. Opens
  /// the same crash alarm ("Bike down?"), countdown, SOS and text fallback.
  void _openRiderDownAlarm(RiderDownEvent d) {
    if (_alarm != null || _hasOpenSos) {
      sensorSafety.riderDown.suppress(_now());
      return;
    }
    _alarmRiderDown = true;
    _openAlarm(CrashEvent(
      impactAtMs: d.tipAtMs,
      impactG: d.peakG,
      speedBeforeKmh: d.speedBeforeKmh,
      lat: d.lat,
      lng: d.lng,
      hasRotationOrTilt: true,
      isSlideFall: true,
      scenario: CrashScenario.stationaryDrop,
      confidence: 0.7,
      movementState: MovementState.stopped,
    ));
    if (_alarm == null) _alarmRiderDown = false;
  }

  void _onFatigue60sTimeout() {
    if (_disposed || !_prompts.containsKey(SafetyConstants.promptFatigue)) return;
    _voice?.speakFatigueConfirmation(
      "Safety confirmation required. Ride captain will be notified in 30 seconds.",
      dedupeKey: 'fatigue_warn_60s',
    );
    HapticFeedback.mediumImpact();
    _fatigueTimer = Timer(const Duration(seconds: 30), _onFatigue90sEscalate);
  }

  void _onFatigue90sEscalate() {
    if (_disposed || !_prompts.containsKey(SafetyConstants.promptFatigue)) return;
    _fatigueEscalated = true;
    _voice?.speakFatigueConfirmation(
      "Rider unconfirmed after break reminder. Notifying ride captain.",
      dedupeKey: 'fatigue_escalated_captain',
    );
    _sendCheckInWith(CheckInResult.noReply, context: CheckInContext.fatigue);
    _updateStatusReason(
      reason: 'FATIGUE_UNRESPONSIVE',
      message: 'Rider unconfirmed after 2h riding break reminder',
    );
  }

  void _updateStatusReason({required String reason, String message = ''}) {
    final uid = _port.myUserId;
    if (uid == null) return;
    final port = _port;
    if (port is SafetyStatusReasonPort) {
      (port as SafetyStatusReasonPort).updateStatusReason(userId: uid, reason: reason, message: message);
    }
  }

  void _onAccel(AccelBucket b) {
    if (_disposed) return;
    final armed = _detector.armedAt(b.tMs);
    if (armed) {
      _brakes.onAccel(b);
      if (_brakes.count > 0 && _brakes.count % 10 == 0 && _brakes.count != _brakesSaved) _saveRideStats(endedAt: 0);
    }
    // The crash detector sees every second first (3.55 safety review: before, the road surface
    // detector ran first on the same second and could report a crash impact as a pothole).
    final ev = _detector.onAccel(b);
    if (ev != null) _openAlarm(ev);
    // 3.55 rider-down check, steering wobble and phone-mount check from the same second, always
    // after the crash detector (which keeps priority: the check rests while it weighs an impact).
    final busy = _alarm != null || _hasOpenSos;
    final down = sensorSafety.onAccel(b, crashBusy: busy || _detector.evaluating, emergency: busy);
    if (down != null && _settings.crashDetection) _openRiderDownAlarm(down);
    // Road surface (3.55): only with a fresh fix (position and speed of this second), and never
    // while the crash detector is weighing a possible crash or a crash alarm is open (the tumbling
    // phone and the GPS speed lag after a fall must not become "pothole" / "rough road" reports).
    if (armed && !_detector.evaluating && _alarm == null) {
      final f = _lastFix;
      final sink = onRoadSurface;
      if (sink != null && f != null && !_soloOnly && (b.tMs - f.ts).abs() <= 5000) {
        final rev = _surface.onBucket(b, speedKmh: f.speedKmh, lat: f.lat, lng: f.lng);
        if (rev != null) {
          sensorSafety.onRoadHazard(); // 3.55 ride safety report
          try {
            sink(rev);
          } catch (_) {}
        }
      }
    }
    _updateSensor();
  }

  void _resetRide() {
    silenceSiren();
    _detector.reset();
    _surface.reset();
    sensorSafety.resetRide(_detector);
    _alarmRiderDown = false;
    engineCare.reset();
    roadCare.reset();
    _engineNoticeClear?.cancel();
    _engineNotice = null;
    _accelUnavailable = false; // try the sensor again on the next ride
    _fatigue.reset();
    _fatigueTimer?.cancel();
    _fatigueTimer = null;
    _fatigueEscalated = false;
    _removePrompt(SafetyConstants.promptFatigue);
    _checkIn.reset();
    _checkInTimer?.cancel();
    _checkInTimer = null;
    _lastCheckInEval = 0;
    _lastAwayM = null;
    _lastFix = null;
    _fuel = FuelRangeTracker();
    fuelEconomy.startRide();
    _fuelAhead = null;
    _fuelLoadedFor = null;
    _fuelSavedM = 0;
    _brakes.reset();
    _brakesSaved = 0;
    _rideBreaks = 0;
    _rideAlerts = 0;
    _rideSos = false;
    _rideCrash = false;
    _followUp = null;
    _lastImpactG = 0;
    _alarmExternal = null;
    _darkAt = 0;
    _darkChecks = 0;
    _darkFix = null;
    _overspeedSince = 0;
    _lastOverspeedAlertMs = 0;
    _isOverspeedActive = false;
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

  /// Sensor on only while needed (battery hard rule). Also while a crash alarm counts down: the
  /// native sensor session holds the partial wake lock, so the 15 s countdown (a Dart timer) is
  /// not frozen by a sleeping CPU when the screen stays off (full-screen alarm denied, Android 14+).
  /// The first bucket after the alarm is answered switches it off again.
  void _updateSensor() {
    final alarm = _alarm;
    final counting = alarm != null && !alarm.sent;
    final want = !_disposed &&
        !_accelUnavailable &&
        _settings.crashDetection &&
        _rideOn &&
        (_detector.wantsSensor || counting || sensorSafety.wantsSensor);
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
    if (_alarm != null || _hasOpenSos || !_settings.crashDetection) {
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
    if (_rideActive) _rideCrash = true;
    sensorSafety.onAlarmOpened(riderDownCheck: _alarmRiderDown);
    final seconds = SafetyConstants.crashCountdown.inSeconds;
    _alarmEvent = CrashEvent(
      impactAtMs: e.impactAtMs,
      impactG: e.impactG,
      speedBeforeKmh: e.speedBeforeKmh,
      lat: lat,
      lng: lng,
      hasRotationOrTilt: e.hasRotationOrTilt,
      isSlideFall: e.isSlideFall,
      scenario: e.scenario,
      confidence: e.confidence,
      peakJerkGPerS: e.peakJerkGPerS,
      movementState: e.movementState,
    );
    final bioSnap = BiometricSafetyBridge().isActive ? BiometricSafetyBridge().snapshot : null;
    _alarm = CrashAlarmState(
      startedAtMs: now,
      secondsLeft: seconds,
      impactG: e.impactG,
      speedBeforeKmh: e.speedBeforeKmh,
      lat: lat,
      lng: lng,
      currentBpm: bioSnap?.currentBpm,
      traumaLevel: bioSnap?.traumaLevel,
    );
    _alarmTimer?.cancel();
    _alarmTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickAlarm());
    if (_native) {
      SafetyNative.alarmWindow(true).ignore();
      AlarmNotifier.showCrashAlarm(
        title: _alarmRiderDown ? riderDownTitle : L10n.t('notif.crash.title'),
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
    final bioSnap = BiometricSafetyBridge().isActive ? BiometricSafetyBridge().snapshot : null;
    if (left != a.secondsLeft || bioSnap?.currentBpm != a.currentBpm || bioSnap?.traumaLevel != a.traumaLevel) {
      _alarm = a.copyWith(
        secondsLeft: left,
        currentBpm: bioSnap?.currentBpm,
        traumaLevel: bioSnap?.traumaLevel,
      );
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
    if (!_alarmRiderDown && _alarmExternal == null) sensorSafety.onRealAlarm(e.scenario); // 3.55 learning
    // An impact from outside the phone (wearable hook) is sent as such, whatever the answer.
    final external = _alarmExternal != null;
    _alarmExternal = null;

    final biometricsBridge = BiometricSafetyBridge();
    Map<String, dynamic>? bioPayload;
    String? traumaLevel;
    String alertType = SosTypes.crash;

    if (biometricsBridge.isActive) {
      final snap = biometricsBridge.snapshot;
      traumaLevel = snap.traumaLevel.wire;
      if (snap.isCritical) {
        alertType = 'CRITICAL_TRAUMA_L1';
      }
      bioPayload = biometricsBridge.toBiometricPayload(bloodGroup: _port.myBloodGroup);
    }

    final port = _port;
    if (_soloOnly) {
      _raiseSoloSos(
        type: alertType,
        lat: e.lat,
        lng: e.lng,
        source: external ? EmergencySource.wearable : source,
        speedBeforeKmh: e.speedBeforeKmh,
        impactG: e.impactG,
        occurredAtMs: e.impactAtMs,
      );
    } else if (port is SafetySourcePort) {
      (port as SafetySourcePort).raiseSosFrom(
        external ? EmergencySource.wearable : source,
        type: alertType,
        lat: e.lat,
        lng: e.lng,
        auto: true,
        speedBeforeKmh: e.speedBeforeKmh,
        impactG: e.impactG,
        occurredAtMs: e.impactAtMs,
        biometrics: bioPayload,
        traumaLevel: traumaLevel,
      );
    } else {
      port.raiseSos(
        type: alertType,
        lat: e.lat,
        lng: e.lng,
        auto: true,
        speedBeforeKmh: e.speedBeforeKmh,
        impactG: e.impactG,
        occurredAtMs: e.impactAtMs,
      );
    }
    final isUnresponsive = source == EmergencySource.crashAuto;
    _alarm = a.copyWith(
      sent: true,
      secondsLeft: 0,
      isUnresponsive: isUnresponsive,
      isSirenActive: isUnresponsive,
    );
    _detector.cooldown(_now());
    _endAlarmNative();
    if (isUnresponsive) {
      _startBystanderSiren();
    }
    notifyListeners();
  }

  /// Manually triggers an Emergency SOS. Offline delivery is the pending-SOS store's job
  /// (ConvoyService: persisted, resent on reconnect with its clientId; 3.55 retired the unused
  /// incident queue, see docs/features_355/platform.md).
  Future<void> triggerManualSos({String type = SosTypes.emergency}) async {
    if (_rideActive) _rideSos = true;
    final now = _now();
    final f = _lastFix;
    final uid = _port.myUserId;
    final me = uid == null ? null : _port.activeConvoy?.riders[uid];
    final lat = f?.lat ?? me?.lat ?? 0.0;
    final lng = f?.lng ?? me?.lng ?? 0.0;

    if (_soloOnly) {
      // Offline solo ride: no convoy to send to. The messages app opens for the emergency contact.
      _raiseSoloSos(type: type, lat: lat, lng: lng, source: EmergencySource.manual, occurredAtMs: now, auto: false, manual: true);
      return;
    }
    _port.raiseSos(
      type: type,
      lat: lat,
      lng: lng,
      auto: false,
      occurredAtMs: now,
    );
  }

  void _startBystanderSiren() {
    _bystanderSirenTimer?.cancel();
    _bystanderSiren();
    _bystanderSirenTimer = Timer.periodic(const Duration(seconds: 10), (_) => _bystanderSiren());
  }

  void _bystanderSiren() {
    if (_disposed || _alarm == null || !_alarm!.isSirenActive) {
      _bystanderSirenTimer?.cancel();
      _bystanderSirenTimer = null;
      return;
    }
    _haptic();
    _voice?.speak(
      'Emergency! Rider needs help! Check phone screen!',
      priority: VoicePriority.critical,
      key: 'bystander_siren_${_now() ~/ 10000}',
    );
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
    if (_rideActive && !_prompts.containsKey(p.key)) _rideAlerts++;
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
    final convoy = _port.activeConvoy;
    final uid = _port.myUserId;
    final me = uid == null || convoy == null ? null : convoy.riders[uid];
    if (me != null && (me.isTunnelCoasting || me.isCoasting)) {
      _checkInTimer?.cancel();
      _checkInTimer = null;
      _removePrompt(SafetyConstants.promptCheckIn);
      return;
    }
    final now = _now();
    if (_lastCheckInEval != 0 && now - _lastCheckInEval < SafetyConstants.checkInEvalEvery.inMilliseconds) return;
    _lastCheckInEval = now;
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
    if (meRider != null && (meRider.isTunnelCoasting || meRider.isCoasting)) {
      return null;
    }
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
    fuelEconomy.onFix(p);
    final range = _settings.fuelRangeKm;
    final useProfile = _settings.hasFuelProfile;

    if (useProfile) {
      final usableKm = estimatedUsableKm;
      final profile = _settings.fuelProfile;
      // Stations ahead for this bike's fuel type, matched on the phone from the
      // map places along the route (null without a route: range-only warnings).
      FuelAheadView? ahead;
      try {
        ahead = fuelAheadSource?.call(p.lat, p.lng, usableKm, profile.marginKm);
      } catch (_) {
        ahead = null;
      }
      _fuelAhead = ahead;
      final warning = decideFuelWarning(usableKm: usableKm, marginKm: profile.marginKm, fullRangeKm: profile.rangeKm, ahead: ahead);

      // "Fill up here" before a long stretch without fuel: once per station per fill.
      if (warning.kind == FuelWarningKind.longGap) {
        if (fuelEconomy.claimLongGap(warning.stationId ?? '')) {
          _voice?.speak(warning.voice);
          HapticFeedback.heavyImpact();
          _showPrompt(
            SafetyPrompt(
              key: SafetyConstants.promptFuel,
              kind: SafetyPromptKind.fuel,
              title: warning.title,
              message: warning.message,
              primaryLabel: 'Route to fuel',
              secondaryLabel: L10n.t('fuel.filled'),
            ),
            notifyAlways: true,
          );
          _saveFuel(force: true);
        } else {
          _saveFuel();
        }
        return;
      }

      final tier = switch (warning.kind) {
        FuelWarningKind.critical => FuelAlertTier.critical,
        FuelWarningKind.urgent => FuelAlertTier.urgent,
        FuelWarningKind.low => FuelAlertTier.warning,
        FuelWarningKind.rangeRisk => FuelAlertTier.rangeRisk,
        _ => FuelAlertTier.none,
      };

      // One pipeline, one prompt key: a new or higher tier replaces the prompt, never adds one.
      if (_fuel.shouldTriggerAlert(tier)) {
        switch (tier) {
          case FuelAlertTier.critical:
            HapticFeedback.vibrate();
            break;
          case FuelAlertTier.urgent:
          case FuelAlertTier.warning:
          case FuelAlertTier.rangeRisk:
            HapticFeedback.heavyImpact();
            break;
          case FuelAlertTier.none:
            return;
        }
        _voice?.speak(warning.voice);

        _showPrompt(
          SafetyPrompt(
            key: SafetyConstants.promptFuel,
            kind: SafetyPromptKind.fuel,
            title: warning.title,
            message: warning.message,
            primaryLabel: 'Route to fuel',
            secondaryLabel: L10n.t('fuel.filled'),
          ),
          notifyAlways: true,
        );
        _saveFuel(force: true);
      } else {
        _saveFuel();
      }
    } else if (range > 0 && _fuel.shouldWarn(range)) {
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
  /// 3.55 rider score: called (fire-and-forget) once a finished ride's stats are on disk, so its
  /// counts can be sent while the rider's setting allows it (set in main.dart).
  void Function()? onRideStatsEnded;

  void _endRideStats() {
    if (_groupId == null || !_rideActive) return;
    final saved = _saveRideStats(endedAt: _now());
    sensorSafety.endRide();
    final hook = onRideStatsEnded;
    if (saved != null && hook != null) {
      saved.then((_) => hook()).catchError((Object _) {}).ignore();
    }
  }

  Future<void>? _saveRideStats({required int endedAt}) {
    final gid = _groupId;
    if (gid == null) return null;
    _brakesSaved = _brakes.count;
    final saving = RideStatsStore.save(RideStats(
      groupId: gid,
      hardStops: _brakes.count,
      endedAt: endedAt,
      breaks: _rideBreaks,
      alerts: _rideAlerts,
      sos: _rideSos,
      crashAlert: _rideCrash,
      safety: sensorSafety.buildSummary(hardBrakes: _brakes.count, breaks: _rideBreaks), // 3.55, phone only
    ));
    saving.ignore();
    return saving;
  }

  // ------------------------------------------------------------------ follow-up (item 19)
  /// After "I'm OK" on a real impact: once, at the next stop of [SafetyConstants.followUpStopFor]
  /// or [SafetyConstants.followUpAfter] later, whichever comes first. No timer: checked on fixes
  /// and convoy changes.
  void _evalFollowUp(ConvoyModel? convoy) {
    final fu = _followUp;
    if (fu == null || !_rideActive || _port.hasOpenSos) {
      if (fu != null && _port.hasOpenSos) _followUp = null;
      return;
    }
    final uid = _port.myUserId;
    final me = uid == null || convoy == null ? null : convoy.riders[uid];
    if (me != null && (me.isTunnelCoasting || me.isCoasting)) {
      return;
    }
    final now = _now();
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

  // ------------------------------------------------------------------ overspeed alerts
  /// A limit changed (Settings or the lead's group setting): judged at once against my last fix,
  /// instead of waiting for the next one (3.55 fix: a change mid-ride used to look ignored).
  void _recheckSpeedLimit() {
    final f = _lastFix;
    if (f == null || !_port.rideActive) return;
    final limit = effectiveSpeedLimit(groupKmh: _groupLimitAt(_port.activeConvoy, f), personalKmh: _settings.speedLimitWarningKmh);
    if (limit != _lastCheckedLimit) _checkSpeedLimit(f);
  }

  /// The group limit where I am: the lead's town limit near the start, the destination and planned
  /// stops (3.55 fix: it used to apply on the server only), else the group limit.
  static int _groupLimitAt(ConvoyModel? c, TrackPoint p) {
    if (c == null) return 0;
    return groupLimitAt(
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
  }

  void _checkSpeedLimit(TrackPoint p) {
    if (_disposed || !_port.rideActive) return;
    final convoy = _port.activeConvoy;
    final convoyLimit = _groupLimitAt(convoy, p);
    final personalLimit = _settings.speedLimitWarningKmh;
    // The stricter of the group and personal limits; read on every fix, so a change in Settings
    // or by the lead applies on the next GPS fix.
    final limit = effectiveSpeedLimit(groupKmh: convoyLimit, personalKmh: personalLimit);
    if (limit != _lastCheckedLimit) {
      // The limit changed: start the hold again and let the voice say the new limit.
      _overspeedSince = 0;
      _lastOverspeedAlertMs = 0;
      if (_isOverspeedActive && (limit <= 0 || p.speedKmh <= limit)) {
        _isOverspeedActive = false;
        _removePrompt(SafetyConstants.promptOverspeed);
      }
    }
    _lastCheckedLimit = limit;

    if (limit <= 0) {
      if (_isOverspeedActive) {
        _isOverspeedActive = false;
        _overspeedSince = 0;
        _removePrompt(SafetyConstants.promptOverspeed);
      }
      return;
    }

    final speed = p.speedKmh;
    final now = _now();

    if (speed > limit + SafetyConstants.overspeedToleranceKmh) {
      if (_overspeedSince == 0) {
        _overspeedSince = now;
      }
      final holdElapsed = now - _overspeedSince;
      final immediate = speed >= limit + SafetyConstants.overspeedImmediateOverKmh;

      if (immediate || holdElapsed >= SafetyConstants.overspeedHoldMs) {
        final wasActive = _isOverspeedActive;
        _isOverspeedActive = true;

        final shouldVoice = !wasActive || (now - _lastOverspeedAlertMs >= SafetyConstants.overspeedVoiceRenotifyMs);
        if (shouldVoice) {
          _lastOverspeedAlertMs = now;
          _haptic();
          _voice?.speakOverspeed(currentSpeedKmh: speed.round(), limitKmh: limit);
        }

        _showPrompt(
          SafetyPrompt(
            key: SafetyConstants.promptOverspeed,
            kind: SafetyPromptKind.overspeed,
            title: '⚠️ SLOW DOWN (${speed.round()} km/h)',
            message: 'You are riding above the limit of $limit km/h. Please slow down safely.',
            primaryLabel: 'Slowing down',
          ),
          notifyAlways: true,
        );
      }
    } else if (speed <= limit) {
      _overspeedSince = 0;
      if (_isOverspeedActive) {
        _isOverspeedActive = false;
        _removePrompt(SafetyConstants.promptOverspeed);
      }
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
    if (_settings.lowData || t.running) return;
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
    final p = _pendingSos;
    if (p == null || _smsBusy || _smsRounds.contains(p.clientId)) return;
    final now = _now();
    // An offline solo ride has no group to reach: the text to the emergency contact is the SOS
    // itself, so it does not wait for the "Text the group" opt-in.
    final solo = p.groupId == offlineSoloGroupId;
    if (!_settings.smsFallback && !solo) {
      if (manual) _setSms(SmsFallbackStatus(state: SmsFallbackState.notAllowed, sent: 0, total: 0, capped: 0, at: now), p.clientId);
      return;
    }
    _smsBusy = true;
    try {
      final cap = await _sms.capability();
      if (_disposed) return;
      // The Play build has no SEND_SMS permission: the texts then go through the messages app,
      // opened with the SOS text and every recipient filled in (the rider or a bystander presses
      // Send). Android does not let an app open another app from the background, so the automatic
      // round only says so and "Text the group now" opens it once the phone is in hand.
      final viaComposer = !cap.permission || !cap.hasTelephony;
      if (viaComposer && !manual && _inBackground) {
        _setSms(SmsFallbackStatus(state: SmsFallbackState.composerWaiting, sent: 0, total: 0, capped: 0, at: _now()), p.clientId);
        return;
      }
      // Still not delivered? (It may have gone through while we checked.)
      final still = _pendingSos;
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
      if (cap.hasTelephony && !cap.simReady) {
        _setSms(SmsFallbackStatus(state: SmsFallbackState.failed, sent: 0, total: total, capped: plan.capped, at: _now()), p.clientId);
        await log.save(p.clientId, _now());
        return;
      }
      if (viaComposer) {
        final open = smsComposerOverride ?? _openComposer;
        final opened = await open([for (final r in plan.recipients) r.phone], body);
        if (_disposed) return;
        // Not sent by this app: no budget is used, nothing is logged as texted, and the rider can
        // open it again with "Text the group now" (for example after closing the messages app).
        _smsRounds.remove(p.clientId);
        _setSms(
          SmsFallbackStatus(
            state: opened ? SmsFallbackState.composer : SmsFallbackState.notAllowed,
            sent: 0,
            total: opened ? total : 0,
            capped: plan.capped,
            at: _now(),
          ),
          p.clientId,
        );
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

  /// Suppresses "Rider Stopped" and "Rider Separated" false alarms during active tunnel coasting (FEAT-09).
  bool shouldSuppressFalseAlarm(String alertType) {
    final uid = _port.myUserId;
    final me = uid != null ? _port.activeConvoy?.riders[uid] : null;
    if (me == null || (!me.isTunnelCoasting && !me.isCoasting)) return false;
    final upper = alertType.toUpperCase();
    return upper.contains('STOP') || upper.contains('SEPARAT');
  }

  @override
  void dispose() {
    _disposed = true;
    _engineNoticeClear?.cancel();
    sensorSafety.dispose();
    silenceSiren();
    _saveFuel(force: true);
    _port.removeListener(_onConvoy);
    _settings.removeListener(_onSettings);
    _fixSub?.cancel();
    _soloFixSub?.cancel();
    _soloFixSub = null;
    _accelSub?.cancel();
    _accelSub = null;
    _alarmTimer?.cancel();
    _checkInTimer?.cancel();
    _fatigueTimer?.cancel();
    _fatigueTimer = null;
    _smsTimer?.cancel();
    if (BiometricSafetyBridge().isActive) {
      BiometricSafetyBridge().stop();
    }
    if (_native) {
      AlarmNotifier.removeAction(AlarmNotifier.payloadCrash);
      AlarmNotifier.removeAction(AlarmNotifier.payloadPrompt);
    }
    if (_instance == this) {
      _instance = null;
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
