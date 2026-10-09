import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../domain/tracking/geo_math.dart';
import 'api_client.dart';
import 'settings_service.dart';

/// One place and time on the route to ask the weather for.
class WeatherPoint {
  final double lat;
  final double lng;

  /// Expected time there, epoch seconds.
  final int atS;

  /// Stop or destination name, '' for a plain point on the road.
  final String name;

  const WeatherPoint({required this.lat, required this.lng, required this.atS, this.name = ''});

  /// Points on the same 0.1 degree cell at the same hour ask the same thing.
  String get cacheKey => '${(lat * 10).round()},${(lng * 10).round()},${atS ~/ 3600}';
}

/// What the gateway said for one point (Open-Meteo hour containing [atS]).
class WeatherReading {
  final int precipProb;
  final double precipMm;
  final int code;
  final double? tempC;
  const WeatherReading({required this.precipProb, required this.precipMm, required this.code, this.tempC});

  /// WMO codes 51..67 (drizzle, rain) and 80..82 (showers).
  bool get rainCode => (code >= 51 && code <= 67) || (code >= 80 && code <= 82);

  /// WMO 95..99.
  bool get storm => code >= 95 && code <= 99;
  bool get rain => precipProb >= 50 || rainCode;

  static WeatherReading? fromJson(Object? j) {
    if (j is! Map) return null;
    return WeatherReading(
      precipProb: (j['precipProb'] as num?)?.toInt() ?? 0,
      precipMm: (j['precipMm'] as num?)?.toDouble() ?? 0,
      code: (j['code'] as num?)?.toInt() ?? 0,
      tempC: (j['tempC'] as num?)?.toDouble(),
    );
  }
}

/// The one plain line for the review and ride sheets.
class WeatherSummary {
  final String line;
  final bool rain;

  /// Index into the asked points of the first rainy one (null when dry).
  final int? firstRainIndex;
  final int fetchedAt;
  final String attribution;

  const WeatherSummary({
    required this.line,
    required this.rain,
    required this.firstRainIndex,
    required this.fetchedAt,
    required this.attribution,
  });
}

/// Weather along the route through the gateway (`POST /api/geo/weather`,
/// Open-Meteo behind it). Two calls per ride at most: the review sheet and the
/// ride start. Nothing in data saver, no timer, never two requests at once,
/// answers cached for [SafetyConstants.weatherCacheFor].
class WeatherService extends ChangeNotifier {
  WeatherService(this._api, this._settings, {int Function()? clock}) : _clock = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final ApiClient _api;
  final SettingsService _settings;
  final int Function() _clock;

  WeatherSummary? _last;
  String? _lastKey;
  Future<WeatherSummary?>? _inFlight;
  String? _inFlightKey;
  bool _checking = false;

  /// The latest answer (the ride sheet shows its line while [WeatherSummary.rain]).
  WeatherSummary? get last => _last;

  /// A request is on its way ("Checking weather...").
  bool get checking => _checking;

  /// Samples: the start, up to [max] - 2 points spread along the route (named after a
  /// planned stop within [SafetyConstants.weatherStopNearM], else ''), and the destination.
  /// Times by distance fraction of [durationS] from [departS] (epoch seconds).
  static List<WeatherPoint> samplePoints({
    required List<(double, double)> line,
    required int durationS,
    required int departS,
    required List<(String, double, double)> namedStops,
    String destinationName = '',
    int max = SafetyConstants.weatherMaxPoints,
  }) {
    if (line.isEmpty) return const [];
    final n = math.max(2, math.min(max, SafetyConstants.weatherMaxPoints));
    if (line.length == 1) {
      final p = line.first;
      return [WeatherPoint(lat: p.$1, lng: p.$2, atS: departS, name: destinationName)];
    }
    final cum = <double>[0];
    for (var i = 1; i < line.length; i++) {
      cum.add(cum.last + GeoMath.haversine(line[i - 1].$1, line[i - 1].$2, line[i].$1, line[i].$2));
    }
    final total = cum.last;
    final out = <WeatherPoint>[];
    for (var k = 0; k < n; k++) {
      final f = k / (n - 1);
      final target = total * f;
      var idx = 0;
      while (idx < cum.length - 1 && cum[idx + 1] < target) {
        idx++;
      }
      final p = _interpolate(line, cum, idx, target);
      String name;
      if (k == n - 1) {
        name = destinationName;
      } else if (k == 0) {
        name = '';
      } else {
        name = _nearStop(p.$1, p.$2, namedStops);
      }
      out.add(WeatherPoint(lat: p.$1, lng: p.$2, atS: departS + (durationS * f).round(), name: name));
    }
    return out;
  }

  static (double, double) _interpolate(List<(double, double)> line, List<double> cum, int idx, double target) {
    if (idx >= line.length - 1) return line.last;
    final a = line[idx], b = line[idx + 1];
    final seg = cum[idx + 1] - cum[idx];
    if (seg <= 0) return a;
    final t = ((target - cum[idx]) / seg).clamp(0.0, 1.0);
    return (a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t);
  }

  static String _nearStop(double lat, double lng, List<(String, double, double)> stops) {
    var best = '';
    var bestD = SafetyConstants.weatherStopNearM;
    for (final s in stops) {
      if (s.$1.trim().isEmpty) continue;
      final d = GeoMath.haversine(lat, lng, s.$2, s.$3);
      if (d <= bestD) {
        bestD = d;
        best = s.$1.trim();
      }
    }
    return best;
  }

  /// Asks for [pts] (1 to 5). Null in data saver, with no points, or when the gateway
  /// says no (503 WEATHER_OFF, errors). A fresh answer for the same points within
  /// [SafetyConstants.weatherCacheFor] is returned without a request unless [force].
  Future<WeatherSummary?> check(List<WeatherPoint> pts, {bool force = false}) async {
    if (_settings.lowData || pts.isEmpty) return null;
    final asked = pts.take(SafetyConstants.weatherMaxPoints).toList();
    final key = asked.map((p) => p.cacheKey).join('|');
    final now = _clock();
    final cached = _last;
    if (!force && cached != null && _lastKey == key && now - cached.fetchedAt < SafetyConstants.weatherCacheFor.inMilliseconds) {
      return cached;
    }
    final running = _inFlight;
    if (running != null && _inFlightKey == key) return running;
    if (running != null) return null; // one request at a time
    _inFlightKey = key;
    final f = _fetch(asked, key);
    _inFlight = f;
    return f;
  }

  Future<WeatherSummary?> _fetch(List<WeatherPoint> pts, String key) async {
    _checking = true;
    notifyListeners();
    WeatherSummary? out;
    try {
      final res = await _api.post('/geo/weather', {
        'points': [
          for (final p in pts)
            {'lat': double.parse(p.lat.toStringAsFixed(2)), 'lng': double.parse(p.lng.toStringAsFixed(2)), 'at': p.atS},
        ],
      });
      if (res is Map) {
        final raw = res['points'];
        final readings = <WeatherReading?>[
          if (raw is List)
            for (final r in raw) WeatherReading.fromJson(r),
        ];
        while (readings.length < pts.length) {
          readings.add(null);
        }
        final attribution = res['attribution']?.toString() ?? L10n.t('weather.by');
        out = summarise(pts, readings, fetchedAt: _clock(), attribution: attribution);
      }
    } on ApiException catch (e) {
      debugPrint('weather note: ${e.statusCode} ${e.code ?? ''}');
    } catch (e) {
      debugPrint('weather note: ${e.runtimeType}');
    } finally {
      _checking = false;
      _inFlight = null;
      _inFlightKey = null;
    }
    if (out != null) {
      _last = out;
      _lastKey = key;
    }
    notifyListeners();
    return out;
  }

  /// The line: thunderstorms anywhere win; else the first rainy point
  /// ("Rain likely after Warangal around 3 PM", "Rain likely from the start.");
  /// else "No rain expected on the route." Null when no point had data.
  static WeatherSummary? summarise(
    List<WeatherPoint> pts,
    List<WeatherReading?> readings, {
    required int fetchedAt,
    String? attribution,
  }) {
    final by = attribution ?? L10n.t('weather.by');
    var any = false;
    int? storm;
    int? rain;
    for (var i = 0; i < pts.length && i < readings.length; i++) {
      final r = readings[i];
      if (r == null) continue;
      any = true;
      if (r.storm && storm == null) storm = i;
      if (r.rain && rain == null) rain = i;
    }
    if (!any) return null;
    if (storm != null) {
      return WeatherSummary(
        line: L10n.t('weather.storm', {'place': _placeOf(pts, storm, self: true), 'time': hourText(pts[storm].atS)}),
        rain: true,
        firstRainIndex: rain ?? storm,
        fetchedAt: fetchedAt,
        attribution: by,
      );
    }
    if (rain != null) {
      final line = rain == 0
          ? L10n.t('weather.rain.start')
          : L10n.t('weather.rain.after', {'place': _placeOf(pts, rain, self: false), 'time': hourText(pts[rain].atS)});
      return WeatherSummary(line: line, rain: true, firstRainIndex: rain, fetchedAt: fetchedAt, attribution: by);
    }
    return WeatherSummary(line: L10n.t('weather.clear'), rain: false, firstRainIndex: null, fetchedAt: fetchedAt, attribution: by);
  }

  /// The name of the point itself (when [self]) or of the nearest named point before it; else "the start".
  static String _placeOf(List<WeatherPoint> pts, int i, {required bool self}) {
    if (self && pts[i].name.isNotEmpty) return pts[i].name;
    for (var j = i - 1; j >= 0; j--) {
      if (pts[j].name.isNotEmpty) return pts[j].name;
    }
    return L10n.t('weather.start');
  }

  /// "3 PM" (nearest hour) in English, "15:00" in Hindi and Telugu, local time.
  static String hourText(int atS) {
    final t = DateTime.fromMillisecondsSinceEpoch(atS * 1000).toLocal();
    var h = t.minute >= 30 ? t.hour + 1 : t.hour;
    h = h % 24;
    if (L10n.current != 'en') return '${h.toString().padLeft(2, '0')}:00';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12 ${h < 12 ? 'AM' : 'PM'}';
  }
}
