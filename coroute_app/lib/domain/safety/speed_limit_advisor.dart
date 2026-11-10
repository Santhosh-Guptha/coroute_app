import 'dart:math' as math;

import '../tracking/geo_math.dart';

/// A road with a tagged speed limit (the centre of an OSM way from the cached places cells).
class RoadLimitPoint {
  const RoadLimitPoint({required this.lat, required this.lng, required this.limitKmh, this.highway = ''});
  final double lat, lng;
  final int limitKmh;
  final String highway;
}

enum SpeedZoneKind { school, hospital }

/// A school or hospital near the road.
class SpeedZonePoint {
  const SpeedZonePoint({required this.lat, required this.lng, required this.kind});
  final double lat, lng;
  final SpeedZoneKind kind;
}

/// Why a limit applies.
enum LimitReason { road, school, hospital }

/// The limit that applies where the rider is.
class LimitContext {
  const LimitContext({required this.limitKmh, required this.reason, this.roadLimitKmh});
  final int limitKmh;
  final LimitReason reason;
  final int? roadLimitKmh;

  /// One key per zone / limit, for the cooldown.
  String get key => '${reason.name}:$limitKmh';
}

/// "Slow down: 62 km/h, limit 50."
class SpeedLimitWarning {
  const SpeedLimitWarning({required this.context, required this.speedKmh});
  final LimitContext context;
  final double speedKmh;

  int get limitKmh => context.limitKmh;

  String get title => switch (context.reason) {
        LimitReason.school => 'School zone: slow to $limitKmh',
        LimitReason.hospital => 'Hospital zone: slow to $limitKmh',
        LimitReason.road => 'Speed limit $limitKmh',
      };

  String get message => 'You are at ${speedKmh.round()} km/h.';

  String get speech => switch (context.reason) {
        LimitReason.school => 'School zone. Slow to $limitKmh.',
        LimitReason.hospital => 'Hospital zone. Slow to $limitKmh.',
        LimitReason.road => 'Speed limit $limitKmh. Please slow down.',
      };
}

/// Smart speed limits (3.55), pure and offline: OSM maxspeed tags and school / hospital zones from
/// the cached places corridor.
///
/// * Road limit: a road point within [matchM] of the rider, or one ahead on the rider's heading
///   (within [aheadM] ahead and [aheadLateralM] to the side). A matched limit stays for
///   [stickyM] while the heading stays within [stickyTurnDeg] of the heading at the match (the
///   cells only carry one point per way). No road data = no road limit.
/// * Zones: within [zoneM] of a school (cap [schoolKmh], only Mon-Sat 07:00-18:00 local, and only
///   where the road limit is unknown or at most [zoneRoadMaxKmh]) or a hospital (cap
///   [hospitalKmh], only on a road whose known limit is at most [zoneRoadMaxKmh]).
/// * Warning: above limit + [toleranceKmh] for [holdFor] (2 s), then at most once per [cooldown] for
///   the same zone / limit. Another limit (the group or personal limit in SafetyService) that is
///   as strict or stricter, or already warning, takes precedence: one prompt only.
class SpeedLimitAdvisor {
  SpeedLimitAdvisor({
    // 3.55 alert latency review: 2 s (was 8 s: at 50 km/h a school zone's 150 m was mostly
    // ridden through before the warning came).
    this.holdFor = const Duration(seconds: 2),
    this.cooldown = const Duration(seconds: 60),
  });

  static const double matchM = 40;
  static const double aheadM = 150;
  static const double aheadLateralM = 15;
  static const double stickyM = 600;
  static const double stickyTurnDeg = 45;
  static const double zoneM = 150;
  static const int schoolKmh = 25;
  static const int hospitalKmh = 30;
  static const int zoneRoadMaxKmh = 60;
  static const double toleranceKmh = 5;

  final Duration holdFor;
  final Duration cooldown;

  int _overSince = 0;
  String? _overKey;
  final Map<String, int> _lastWarn = {};

  // Sticky road limit.
  int? _stickyLimit;
  double _stickyLat = 0, _stickyLng = 0, _stickyHeading = 0;

  /// The last limit context found (null = no data here).
  LimitContext? last;

  void reset() {
    _overSince = 0;
    _overKey = null;
    _lastWarn.clear();
    _stickyLimit = null;
    last = null;
  }

  // ------------------------------------------------------------------ parsing
  static const Map<String, int> _zoneDefaults = {
    'urban': 50,
    'rural': 80,
    'motorway': 100,
    'trunk': 80,
    'living_street': 20,
  };

  /// km/h from an OSM maxspeed value ("50", "50 mph", "IN:urban", "zone30"); null for anything
  /// unknown ("none", "signals", "variable", nonsense). Several values ("60;40"): the first.
  static int? parseMaxspeed(String? raw) {
    if (raw == null) return null;
    var s = raw.trim().toLowerCase();
    if (s.isEmpty) return null;
    if (s.contains(';')) s = s.split(';').first.trim();
    final num = RegExp(r'^(\d{1,3}(?:\.\d+)?)\s*(km/h|kmh|kph|mph|knots)?$').firstMatch(s);
    if (num != null) {
      final v = double.parse(num.group(1)!);
      final unit = num.group(2);
      final kmh = unit == 'mph' ? v * 1.609344 : (unit == 'knots' ? v * 1.852 : v);
      return _plausible(kmh.round());
    }
    final zone = RegExp(r'zone:?(\d{1,3})$').firstMatch(s);
    if (zone != null) return _plausible(int.parse(zone.group(1)!));
    // Implicit limits: "IN:urban", "in:rural", "IN:motorway".
    final colon = s.lastIndexOf(':');
    final kind = colon >= 0 ? s.substring(colon + 1) : s;
    return _zoneDefaults[kind];
  }

  static int? _plausible(int v) => v >= 5 && v <= 140 ? v : null;

  /// A road limit from a tag set (maxspeed first, then maxspeed:type / source:maxspeed); null when
  /// the tags carry none.
  static RoadLimitPoint? roadFromTags(double lat, double lng, Map<String, String> t) {
    final highway = t['highway'];
    if (highway == null) return null;
    final v = parseMaxspeed(t['maxspeed']) ?? parseMaxspeed(t['maxspeed:type']) ?? parseMaxspeed(t['source:maxspeed']);
    if (v == null) return null;
    return RoadLimitPoint(lat: lat, lng: lng, limitKmh: v, highway: highway);
  }

  /// A school zone from a tag set; null for anything else.
  static SpeedZonePoint? schoolFromTags(double lat, double lng, Map<String, String> t) {
    final a = t['amenity'];
    if (a == 'school' || a == 'college' || a == 'kindergarten') {
      return SpeedZonePoint(lat: lat, lng: lng, kind: SpeedZoneKind.school);
    }
    return null;
  }

  static bool schoolHours(DateTime local) =>
      local.weekday != DateTime.sunday && local.hour >= 7 && local.hour < 18;

  // ------------------------------------------------------------------ where am I
  /// The limit here, or null with no data. [headingDeg] null = not known (no ahead match).
  LimitContext? limitAt({
    required double lat,
    required double lng,
    double? headingDeg,
    required Iterable<RoadLimitPoint> roads,
    required Iterable<SpeedZonePoint> zones,
    required DateTime localNow,
  }) {
    int? road;
    var bestD = double.infinity;
    for (final r in roads) {
      if ((r.lat - lat).abs() > 0.002) continue; // about 220 m: cheap reject
      final d = GeoMath.haversine(lat, lng, r.lat, r.lng);
      if (d > aheadM + 10) continue;
      var ok = d <= matchM;
      if (!ok && headingDeg != null && d > 1) {
        final diff = GeoMath.bearingDiff(headingDeg, GeoMath.bearing(lat, lng, r.lat, r.lng)) * math.pi / 180;
        final ahead = d * math.cos(diff), side = (d * math.sin(diff)).abs();
        ok = ahead > 0 && ahead <= aheadM && side <= aheadLateralM;
      }
      if (ok && d < bestD) {
        bestD = d;
        road = r.limitKmh;
      }
    }
    if (road != null) {
      _stickyLimit = road;
      _stickyLat = lat;
      _stickyLng = lng;
      _stickyHeading = headingDeg ?? _stickyHeading;
    } else if (_stickyLimit != null) {
      final far = GeoMath.haversine(lat, lng, _stickyLat, _stickyLng) > stickyM;
      final turned = headingDeg == null || GeoMath.bearingDiff(headingDeg, _stickyHeading) > stickyTurnDeg;
      if (far || turned) {
        _stickyLimit = null;
      } else {
        road = _stickyLimit;
      }
    }

    LimitContext? out = road == null ? null : LimitContext(limitKmh: road, reason: LimitReason.road, roadLimitKmh: road);
    final roadAllowsZone = road == null || road <= zoneRoadMaxKmh;
    if (roadAllowsZone) {
      var school = false, hospital = false;
      for (final z in zones) {
        if (z.kind == SpeedZoneKind.school && school) continue;
        if (z.kind == SpeedZoneKind.hospital && hospital) continue;
        if ((z.lat - lat).abs() > 0.002) continue;
        if (GeoMath.haversine(lat, lng, z.lat, z.lng) > zoneM) continue;
        if (z.kind == SpeedZoneKind.school) {
          school = true;
        } else {
          hospital = true;
        }
      }
      if (school && schoolHours(localNow) && (out == null || schoolKmh < out.limitKmh)) {
        out = LimitContext(limitKmh: schoolKmh, reason: LimitReason.school, roadLimitKmh: road);
      } else if (hospital && road != null && (out == null || hospitalKmh < out.limitKmh)) {
        out = LimitContext(limitKmh: hospitalKmh, reason: LimitReason.hospital, roadLimitKmh: road);
      }
    }
    return last = out;
  }

  // ------------------------------------------------------------------ warning
  /// A warning once the rider has been over the limit long enough, or null.
  /// [otherLimitKmh]: the group or personal limit (0 = none); [otherActive]: that warning is showing.
  SpeedLimitWarning? onSpeed({
    required LimitContext? context,
    required double speedKmh,
    required int nowMs,
    int otherLimitKmh = 0,
    bool otherActive = false,
  }) {
    if (context == null || !speedKmh.isFinite) {
      _overSince = 0;
      _overKey = null;
      return null;
    }
    // The stricter limit applies, one prompt: the other limit covers this one.
    if (otherActive || (otherLimitKmh > 0 && otherLimitKmh <= context.limitKmh)) {
      _overSince = 0;
      _overKey = null;
      return null;
    }
    if (speedKmh <= context.limitKmh + toleranceKmh) {
      _overSince = 0;
      _overKey = null;
      return null;
    }
    if (_overKey != context.key) {
      _overKey = context.key;
      _overSince = nowMs;
    }
    if (nowMs - _overSince < holdFor.inMilliseconds) return null;
    final lastAt = _lastWarn[context.key];
    if (lastAt != null && nowMs - lastAt < cooldown.inMilliseconds) return null;
    _lastWarn[context.key] = nowMs;
    return SpeedLimitWarning(context: context, speedKmh: speedKmh);
  }
}
