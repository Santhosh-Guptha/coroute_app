import '../tracking/geo_math.dart';
import 'geohash.dart';

/// Road & safety signal kinds the phone may share (consent "Help make roads safer"). SOS and crash alerts are
/// counted by the gateway from the alert itself, so the phone never sends them here.
enum IntelEventType {
  hardBrake('hard_brake'),
  swerve('swerve'),
  skid('skid'),
  pothole('pothole'),
  rough('rough');

  const IntelEventType(this.wire);
  final String wire;
}

/// One compact event: {type, geohash-7, heading bucket, speed bucket, hour of week, ts, confidence}.
class IntelEvent {
  const IntelEvent({required this.type, required this.gh, required this.hb, required this.sb, required this.ts, this.conf = 1, this.lat = 0, this.lng = 0});

  final IntelEventType type;
  final String gh;
  final int hb;
  final int sb;
  final int ts;
  final double conf;

  /// Kept on the phone only for trimming (never sent).
  final double lat, lng;

  /// 8 heading buckets of 45 degrees (0 = north); -1 unknown.
  static int headingBucket(double? deg) => deg == null || !deg.isFinite || deg < 0 ? -1 : ((deg % 360) / 45).round() % 8;

  /// 0 <20, 1 20-40, 2 40-60, 3 60-80, 4 >=80 km/h; -1 unknown.
  static int speedBucket(double kmh) => !kmh.isFinite || kmh < 0 ? -1 : (kmh ~/ 20).clamp(0, 4);

  /// 0..167, Monday 00:00 India time = 0.
  static int hourOfWeek(int tsMs) {
    final ist = DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true).add(const Duration(minutes: 330));
    return (ist.weekday - 1) * 24 + ist.hour;
  }

  static IntelEvent? at({required IntelEventType type, required double lat, required double lng, double? headingDeg, double speedKmh = 0, required int ts, double conf = 1}) {
    final g = Geohash.encode(lat, lng, 7);
    if (g == null || (lat == 0 && lng == 0)) return null;
    return IntelEvent(type: type, gh: g, hb: headingBucket(headingDeg), sb: speedBucket(speedKmh), ts: ts, conf: conf.clamp(0.1, 1.0).toDouble(), lat: lat, lng: lng);
  }

  /// The wire form (no exact position).
  Map<String, Object> toWire() => {'type': type.wire, 'gh': gh, 'hb': hb, 'sb': sb, 'how': hourOfWeek(ts), 'ts': ts, 'conf': double.parse(conf.toStringAsFixed(2))};

  /// The stored form (pending queue on the phone; includes the position for end-of-ride trimming).
  Map<String, Object> toStore() => {...toWire(), 'la': lat, 'lo': lng};

  static IntelEvent? fromStore(Object? j) {
    if (j is! Map) return null;
    final t = IntelEventType.values.where((e) => e.wire == j['type']).firstOrNull;
    final gh = j['gh'], ts = j['ts'];
    if (t == null || gh is! String || ts is! num) return null;
    return IntelEvent(type: t, gh: gh, hb: (j['hb'] as num?)?.toInt() ?? -1, sb: (j['sb'] as num?)?.toInt() ?? -1, ts: ts.toInt(),
        conf: (j['conf'] as num?)?.toDouble() ?? 1, lat: (j['la'] as num?)?.toDouble() ?? 0, lng: (j['lo'] as num?)?.toDouble() ?? 0);
  }
}

/// Collects one ride's events and decides which may leave the phone (pure; persistence and upload live in
/// IntelService):
///  * nothing within [trimM] of the ride's first fix (the start);
///  * at the ride's end, nothing within [trimM] of the last fix (the destination);
///  * nothing within [trimM] of a privacy zone (saved home / work, when the rider has them);
///  * at most [maxPerRide] events per ride and [maxQueue] waiting overall (offline queue).
class IntelEventQueue {
  IntelEventQueue({this.trimM = 300, this.maxPerRide = 200, this.maxQueue = 1000, List<(double, double)> zones = const []}) {
    this.zones = zones;
  }

  final double trimM;
  final int maxPerRide;
  final int maxQueue;
  List<(double, double)> _zones = const [];

  (double, double)? _start;
  final List<IntelEvent> _ride = [];

  /// Events of finished rides, trimmed, waiting for upload (survives offline time; IntelService stores it).
  final List<IntelEvent> ready = [];

  set zones(List<(double, double)> z) => _zones = z.take(4).toList();

  bool get rideOpen => _start != null;
  int get pendingInRide => _ride.length;

  void startRide() {
    _start = null;
    _ride.clear();
  }

  /// My fixes: the first one is the ride's start.
  void onFix(double lat, double lng) {
    if (lat == 0 && lng == 0) return;
    _start ??= (lat, lng);
  }

  bool _near((double, double) p, double lat, double lng) => GeoMath.haversine(p.$1, p.$2, lat, lng) < trimM;

  /// A detected event during the ride (kept until the ride ends).
  bool add(IntelEvent e) {
    final s = _start;
    if (s == null || _near(s, e.lat, e.lng)) return false;
    if (_zones.any((z) => _near(z, e.lat, e.lng))) return false;
    if (_ride.length >= maxPerRide) return false;
    _ride.add(e);
    return true;
  }

  /// End of the ride at (lat, lng): events near the end are dropped, the rest become [ready].
  int endRide(double? lat, double? lng) {
    var kept = 0;
    for (final e in _ride) {
      if (lat != null && lng != null && !(lat == 0 && lng == 0) && GeoMath.haversine(lat, lng, e.lat, e.lng) < trimM) continue;
      ready.add(e);
      kept++;
    }
    while (ready.length > maxQueue) {
      ready.removeAt(0);
    }
    _ride.clear();
    _start = null;
    return kept;
  }

  /// Up to [n] events for one upload (they stay in [ready] until [confirm]).
  List<IntelEvent> batch([int n = 200]) => ready.take(n).toList();

  void confirm(int n) => ready.removeRange(0, n.clamp(0, ready.length));

  /// Consent turned off, or "Delete my contributions": nothing waiting leaves the phone.
  void clear() {
    ready.clear();
    _ride.clear();
  }
}
