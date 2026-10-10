import 'geo_math.dart';
import 'track_point.dart';

/// A detected stop (open while [endTs] is null).
class DetectedStop {
  final int startTs;
  final int? endTs;
  final double lat;
  final double lng;

  const DetectedStop({required this.startTs, this.endTs, required this.lat, required this.lng});

  bool get isOpen => endTs == null;
  Duration durationAt(int nowMs) => Duration(milliseconds: (endTs ?? nowMs) - startTs);
}

/// On-device stop detection, the same rule the gateway uses for the timeline:
/// the rider stays within [radiusM] of a moving centre for at least
/// [minStop]. The stop ends with the first fix more than [exitM] away.
/// Slow traffic never qualifies: it leaves the radius long before [minStop].
class StopDetector {
  StopDetector({this.radiusM = 50, this.exitM = 60, this.minStop = const Duration(minutes: 2)});

  final double radiusM;
  final double exitM;
  Duration minStop;

  TrackPoint? _first;
  TrackPoint? _lastIn;
  double _sumLat = 0, _sumLng = 0;
  int _n = 0;
  DetectedStop? _current;

  /// The stop in progress, if any.
  DetectedStop? get current => _current;

  void reset() {
    _first = null;
    _lastIn = null;
    _sumLat = 0;
    _sumLng = 0;
    _n = 0;
    _current = null;
  }

  /// Feeds one fix. Returns a [StopEvent] when a stop starts or ends.
  StopEvent? add(TrackPoint p, {bool isTunnelCoasting = false}) {
    if (isTunnelCoasting) return null;
    if (_first == null) {
      _startCluster(p);
      return null;
    }
    final cLat = _sumLat / _n, cLng = _sumLng / _n;
    final d = GeoMath.haversine(cLat, cLng, p.lat, p.lng);
    final stopped = _current != null;
    if (d <= radiusM || (stopped && d <= exitM)) {
      _lastIn = p;
      _sumLat += p.lat;
      _sumLng += p.lng;
      _n++;
      if (!stopped && p.ts - _first!.ts >= minStop.inMilliseconds) {
        _current = DetectedStop(startTs: _first!.ts, lat: _sumLat / _n, lng: _sumLng / _n);
        return StopEvent.started(_current!);
      }
      return null;
    }
    StopEvent? ended;
    if (stopped) {
      final s = _current!;
      ended = StopEvent.ended(DetectedStop(startTs: s.startTs, endTs: _lastIn!.ts, lat: s.lat, lng: s.lng));
      _current = null;
    }
    _startCluster(p);
    return ended;
  }

  void _startCluster(TrackPoint p) {
    _first = p;
    _lastIn = p;
    _sumLat = p.lat;
    _sumLng = p.lng;
    _n = 1;
  }
}

class StopEvent {
  final bool started;
  final DetectedStop stop;
  const StopEvent._(this.started, this.stop);
  factory StopEvent.started(DetectedStop s) => StopEvent._(true, s);
  factory StopEvent.ended(DetectedStop s) => StopEvent._(false, s);
}
