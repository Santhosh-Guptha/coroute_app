import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_palette.dart';
import 'app_theme.dart';
import 'sun_times.dart';

/// How the app picks light or dark.
enum ThemePreference {
  /// Light from sunrise to sunset where you are (the default).
  auto,

  /// The phone's light sensor (Android), with a delay so passing under a
  /// bridge or through a tunnel does not flip the screen.
  lightSensor,
  light,
  dark,

  /// Whatever the phone's own dark-mode setting says.
  system,
}

/// Chooses and applies the theme.
///
/// Battery: Auto computes sunrise and sunset on the phone from the last
/// known position (never asks for a new GPS fix) and sets one timer for the
/// next change, so it costs nothing in between. The light sensor is read
/// only while CoRoute is on screen and that option is chosen, at most once a
/// second, and is released as soon as the app goes to the background.
class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeController({SharedPreferences? prefs}) : _prefsOverride = prefs;

  static const String _prefKey = 'theme.preference';
  static const String _latKey = 'theme.lastLat';
  static const String _lngKey = 'theme.lastLng';

  /// Below this the room counts as dark, above [lightLux] as bright.
  /// The gap between them stops flicker around a single threshold.
  static const double darkLux = 10;
  static const double lightLux = 60;

  /// A light-sensor change must last this long before the theme follows.
  static const Duration sensorHold = Duration(seconds: 30);

  static const EventChannel _lightChannel = EventChannel('coroute/ambient_light');

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;
  ThemePreference _pref = ThemePreference.auto;
  AppPalette _palette = AppPalette.dark;
  Timer? _sunTimer;
  Timer? _holdTimer;
  StreamSubscription<dynamic>? _lightSub;
  bool _resumed = true;
  bool _sensorAvailable = true;
  bool? _sensorDark;
  double? _lat, _lng;

  ThemePreference get preference => _pref;
  AppPalette get palette => _palette;
  bool get isLight => _palette.isLight;

  /// The light sensor option is shown only where it can work.
  bool get sensorSupported => !kIsWeb && Platform.isAndroid && _sensorAvailable;

  /// When Auto switches next, for the settings screen ("Dark from 18:02").
  DateTime? nextSunChange;

  /// Reads the saved choice and applies it. Call once before runApp.
  Future<void> load() async {
    try {
      _prefs = _prefsOverride ?? await SharedPreferences.getInstance();
      final saved = _prefs!.getString(_prefKey);
      _pref = ThemePreference.values.firstWhere((p) => p.name == saved, orElse: () => ThemePreference.auto);
      _lat = _prefs!.getDouble(_latKey);
      _lng = _prefs!.getDouble(_lngKey);
    } catch (_) {
      // No storage: use the defaults.
    }
    WidgetsBinding.instance.addObserver(this);
    _evaluate(initial: true);
    _refreshPlace();
  }

  Future<void> setPreference(ThemePreference p) async {
    if (p == _pref) return;
    _pref = p;
    try {
      await _prefs?.setString(_prefKey, p.name);
    } catch (_) {}
    _evaluate();
    notifyListeners();
  }

  /// The convoy screens report positions anyway; this keeps Auto accurate
  /// when the rider travels far without an extra GPS request.
  void notePosition(double lat, double lng) {
    if (lat == 0 && lng == 0) return;
    final moved = _lat == null || (lat - _lat!).abs() > 0.5 || (lng - _lng!).abs() > 0.5;
    if (!moved) return;
    _lat = lat;
    _lng = lng;
    try {
      _prefs?.setDouble(_latKey, lat);
      _prefs?.setDouble(_lngKey, lng);
    } catch (_) {}
    if (_pref == ThemePreference.auto) _evaluate();
  }

  Future<void> _refreshPlace() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      if (p != null) notePosition(p.latitude, p.longitude);
    } catch (_) {
      // No permission yet: the time zone gives a close enough estimate.
    }
  }

  /// Where to compute sunrise for when no position is known: the time zone's
  /// central meridian (15 degrees per hour) and the latitude of the tropics
  /// middle band, which is within a few minutes for India.
  ({double lat, double lng}) _place() {
    if (_lat != null && _lng != null) return (lat: _lat!, lng: _lng!);
    final offsetH = DateTime.now().timeZoneOffset.inMinutes / 60.0;
    return (lat: 20.0, lng: offsetH * 15);
  }

  void _evaluate({bool initial = false}) {
    _sunTimer?.cancel();
    _sunTimer = null;
    nextSunChange = null;
    _syncSensor();

    bool light;
    switch (_pref) {
      case ThemePreference.light:
        light = true;
        break;
      case ThemePreference.dark:
        light = false;
        break;
      case ThemePreference.system:
        light = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light;
        break;
      case ThemePreference.lightSensor:
        if (sensorSupported && _sensorDark != null) {
          light = !_sensorDark!;
          break;
        }
        light = _sunLight(); // until the first reading, or with no sensor
        break;
      case ThemePreference.auto:
        light = _sunLight();
        break;
    }
    _apply(light ? AppPalette.light : AppPalette.dark, initial: initial);
  }

  bool _sunLight() {
    final at = _place();
    final now = DateTime.now();
    final s = SunTimes.state(now, at.lat, at.lng);
    nextSunChange = s.nextChange;
    final wait = s.nextChange.difference(now) + const Duration(seconds: 5);
    _sunTimer = Timer(wait.isNegative ? const Duration(minutes: 1) : wait, _evaluate);
    return s.day;
  }

  void _apply(AppPalette p, {bool initial = false}) {
    if (identical(p, _palette) && !initial) return;
    _palette = p;
    AppTheme.use(p);
    if (initial) return;
    notifyListeners();
    _rebuildAll();
  }

  /// Screens read colours from [AppTheme] directly, so after a switch every
  /// element is rebuilt once (state, scroll positions and routes are kept).
  static void _rebuildAll() {
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      // Never mark widgets dirty in the middle of a frame.
      binding.addPostFrameCallback((_) => _rebuildAll());
      return;
    }
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    binding.rootElement?.visitChildren(visit);
  }

  // ------------------------------------------------------------ light sensor
  void _syncSensor() {
    final want = _pref == ThemePreference.lightSensor && _resumed && sensorSupported;
    if (want && _lightSub == null) {
      _lightSub = _lightChannel.receiveBroadcastStream().listen(
        (v) {
          if (v is num) _onLux(v.toDouble());
        },
        onError: (Object _) {
          _sensorAvailable = false;
          _stopSensor();
          _evaluate();
          notifyListeners();
        },
      );
    } else if (!want && _lightSub != null) {
      _stopSensor();
    }
  }

  void _stopSensor() {
    _lightSub?.cancel();
    _lightSub = null;
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _onLux(double lux) {
    final wantDark = lux < darkLux ? true : (lux > lightLux ? false : null);
    if (wantDark == null) return; // in between: keep what we have
    if (_sensorDark == null) {
      _sensorDark = wantDark; // first reading applies at once
      _evaluate();
      return;
    }
    if (wantDark == _sensorDark) {
      _holdTimer?.cancel();
      _holdTimer = null;
      return;
    }
    _holdTimer ??= Timer(sensorHold, () {
      _holdTimer = null;
      _sensorDark = wantDark;
      _evaluate();
    });
  }

  // --------------------------------------------------------------- lifecycle
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_resumed) {
      // Timers can be late while the phone sleeps: check again on return.
      _evaluate();
    } else {
      _syncSensor();
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (_pref == ThemePreference.system) _evaluate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sunTimer?.cancel();
    _holdTimer?.cancel();
    _stopSensor();
    super.dispose();
  }
}
