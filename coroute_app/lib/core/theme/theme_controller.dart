import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_palette.dart';
import 'app_theme.dart';

/// How the app picks light or dark.
///
/// Design system v3.55 offers three choices: [system] (the default),
/// [light] and [dark]. [auto] and [lightSensor] are older choices kept so
/// saved settings and existing callers still compile; both now behave like
/// [system] and a saved value is moved to [system] on load.
enum ThemePreference {
  /// Older "sunrise to sunset" choice. Now the same as [system].
  auto,

  /// Older light-sensor choice. Now the same as [system].
  lightSensor,
  light,
  dark,

  /// Whatever the phone's own dark-mode setting says (the default).
  system,
}

/// Chooses and applies the theme. No timers, no sensors, no GPS: it follows
/// the phone's dark-mode setting unless the rider picks Light or Dark.
class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeController({SharedPreferences? prefs}) : _prefsOverride = prefs;

  static const String _prefKey = 'theme.preference';

  /// The three choices shown in settings, in order.
  static const List<ThemePreference> choices = [ThemePreference.system, ThemePreference.light, ThemePreference.dark];

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;
  ThemePreference _pref = ThemePreference.system;
  AppPalette _palette = AppPalette.light;
  bool _rideDark = false;

  ThemePreference get preference => _pref;

  /// Night riding: the dark palette and the dimmed map, whatever the preference.
  bool get rideDarkOverride => _rideDark;
  void setRideDarkOverride(bool on) {
    if (on == _rideDark) return;
    _rideDark = on;
    _evaluate();
  }

  AppPalette get palette => _palette;
  bool get isLight => _palette.isLight;

  /// The light sensor choice is no longer offered.
  bool get sensorSupported => false;

  /// Kept for older callers; there is no scheduled switch any more.
  DateTime? nextSunChange;

  /// Reads the saved choice and applies it. Call once before runApp.
  Future<void> load() async {
    try {
      _prefs = _prefsOverride ?? await SharedPreferences.getInstance();
      final saved = _prefs!.getString(_prefKey);
      _pref = _normalise(ThemePreference.values.firstWhere((p) => p.name == saved, orElse: () => ThemePreference.system));
      if (saved != null && saved != _pref.name) await _prefs!.setString(_prefKey, _pref.name);
    } catch (_) {
      // No storage: use the default.
    }
    WidgetsBinding.instance.addObserver(this);
    _evaluate(initial: true);
  }

  static ThemePreference _normalise(ThemePreference p) =>
      (p == ThemePreference.auto || p == ThemePreference.lightSensor) ? ThemePreference.system : p;

  Future<void> setPreference(ThemePreference p) async {
    p = _normalise(p);
    if (p == _pref) return;
    _pref = p;
    try {
      await _prefs?.setString(_prefKey, p.name);
    } catch (_) {}
    _evaluate();
    notifyListeners();
  }

  /// Kept for older callers (the theme no longer depends on where you are).
  void notePosition(double lat, double lng) {}

  void _evaluate({bool initial = false}) {
    bool light;
    switch (_pref) {
      case ThemePreference.light:
        light = true;
      case ThemePreference.dark:
        light = false;
      case ThemePreference.system:
      case ThemePreference.auto:
      case ThemePreference.lightSensor:
        light = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.light;
    }
    if (_rideDark) light = false;
    _apply(light ? AppPalette.light : AppPalette.dark, initial: initial);
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _evaluate();
  }

  @override
  void didChangePlatformBrightness() {
    if (_normalise(_pref) == ThemePreference.system) _evaluate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
