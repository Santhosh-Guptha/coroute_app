import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../domain/tracking/stop_detector.dart';
import '../../domain/tracking/track_filter.dart';
import '../../domain/tracking/track_point.dart';
import '../local/track_queue.dart';
import 'track_uploader.dart';

/// Records this rider's route during a convoy.
///
/// Uses the GPS fixes the app already receives (no extra GPS work), keeps
/// them on the phone first, and uploads them in batches. Also runs the same
/// stop rule as the gateway so the app knows at once that the rider has
/// stopped and for how long, even without a connection.
class TrackRecorder extends ChangeNotifier {
  TrackRecorder(this._queue, this._uploader, {this.uploadEvery = const Duration(seconds: 60), this.uploadAfterPoints = 120});

  final TrackQueue _queue;
  final TrackUploader _uploader;
  final Duration uploadEvery;
  final int uploadAfterPoints;
  final TrackFilter _filter = TrackFilter();
  final StopDetector _stops = StopDetector();

  String? _groupId;
  Timer? _timer;
  int _sinceUpload = 0;
  int _recorded = 0;
  TrackPoint? _lastFix;
  int _pendingPoints = 0;

  String? get groupId => _groupId;

  /// Points of the current trip still waiting on the phone for upload. Read from the queue
  /// when the connection changes and after each upload; counted up locally in between
  /// (no polling, and no rebuild per GPS fix).
  int get pendingPoints => _pendingPoints;

  /// Re-reads [pendingPoints] from the queue (one COUNT query).
  Future<void> refreshPendingCount() async {
    final gid = _groupId;
    final n = gid == null ? 0 : await _queue.countPending(gid);
    if (n != _pendingPoints) {
      _pendingPoints = n;
      notifyListeners();
    }
  }
  bool get isRecording => _groupId != null;
  int get recordedPoints => _recorded;

  /// The stop in progress for this rider, if any.
  DetectedStop? get currentStop => _stops.current;

  /// Starts recording for [groupId]. Also sends anything left from earlier trips.
  void start(String groupId, {Duration minStop = const Duration(minutes: 3)}) {
    _stops.minStop = minStop < const Duration(seconds: 30) ? const Duration(seconds: 30) : minStop;
    if (_groupId == groupId) return;
    _groupId = groupId;
    _filter.reset();
    _stops.reset();
    _sinceUpload = 0;
    _recorded = 0;
    _lastFix = null;
    _pendingPoints = 0;
    _timer?.cancel();
    _timer = Timer.periodic(uploadEvery, (_) => _upload());
    _uploader.flush().ignore();
    notifyListeners();
  }

  /// Stops recording; by default uploads what is left right away.
  Future<void> stop({bool upload = true}) async {
    final gid = _groupId;
    _timer?.cancel();
    _timer = null;
    _groupId = null;
    _stops.reset();
    notifyListeners();
    await _queue.flushBuffer();
    if (upload && gid != null) {
      try {
        await _uploader.flush(onlyGroup: gid).timeout(const Duration(seconds: 15));
      } catch (_) {
        // Still queued on the phone; the next session uploads it.
      }
    }
  }

  /// Feeds one GPS fix.
  void onFix(TrackPoint p) {
    final gid = _groupId;
    if (gid == null) return;
    if (!_filter.accept(p)) return;
    _lastFix = p;
    _recorded++;
    _pendingPoints++;
    _queue.add(gid, p).ignore();
    final ev = _stops.add(p);
    if (ev != null) notifyListeners();
    if (++_sinceUpload >= uploadAfterPoints) _upload();
  }

  /// While parked the GPS stream goes quiet (battery profile). The app's
  /// heartbeat calls this so the parked time is still recorded and the stop
  /// is still detected.
  void onHeartbeat({int? nowMs}) {
    final last = _lastFix;
    if (last == null || _groupId == null) return;
    onFix(TrackPoint(ts: nowMs ?? DateTime.now().millisecondsSinceEpoch, lat: last.lat, lng: last.lng, speedKmh: 0, accuracyM: last.accuracyM));
  }

  /// Uploads now (for example when the connection comes back).
  void uploadNow() => _upload();

  void _upload() {
    _sinceUpload = 0;
    _queue.flushBuffer().then((_) => _uploader.flush()).then((_) => refreshPendingCount()).ignore();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
