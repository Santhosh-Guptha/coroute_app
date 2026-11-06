import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../domain/tracking/nav_motion.dart';

/// Which way is up on the riding map.
enum MapOrientation {
  /// The direction of travel points up (Google Maps navigation style).
  courseUp,

  /// North is always up.
  northUp,
}

/// Where my marker is drawn this frame (smoothed and extrapolated between fixes).
@immutable
class NavPose {
  final double lat;
  final double lng;

  /// Smoothed bearing in degrees, 0 = north.
  final double heading;
  final double speedKmh;

  const NavPose({required this.lat, required this.lng, required this.heading, required this.speedKmh});

  LatLng get point => LatLng(lat, lng);
}

/// Drives the riding map like a navigation app: follows my position with a
/// course-up (or north-up) camera, my marker in the lower third above the
/// bottom sheet, zoom from speed, and everything animated per frame between
/// GPS fixes (exponential smoothing, short dead reckoning, never backwards).
///
/// Feed it with [onRiderFix] (every update of my rider) and give it a ticker
/// with [NavCameraTicker]. A map gesture calls [pauseFollow]; the recenter
/// chip calls [resumeFollow]. Listeners hear about [following] and
/// [orientation] changes only (never per frame); per-frame values are in
/// [pose] and [mapRotation].
class NavCameraController extends ChangeNotifier {
  NavCameraController({required this.mapController, this._enableCompass = true}) {
    _loadOrientation();
  }

  final MapController mapController;
  final bool _enableCompass;

  static const String prefsKeyOrientation = 'cockpit_map_orientation_v1';

  /// No camera motion faster than this (battery): 60 fps riding, 30 fps slow / saving.
  static const Duration _frameRiding = Duration(microseconds: 16000);
  static const Duration _frameRelaxed = Duration(microseconds: 33000);

  /// Fixes older than this are not projected forward any further.
  static const double _maxExtrapolationSec = 1.5;

  static const double _minZoom = 3.0;
  static const double _maxZoom = 19.0;

  // ---------------------------------------------------------------- public state

  /// My drawn position, per frame. Null until the first good fix.
  final ValueNotifier<NavPose?> pose = ValueNotifier<NavPose?>(null);

  /// The map's rotation in degrees (for the compass button), per frame.
  final ValueNotifier<double> mapRotation = ValueNotifier<double>(0.0);

  bool get following => _following;
  MapOrientation get orientation => _orientation;
  bool get courseUp => _orientation == MapOrientation.courseUp;

  /// Bad fixes dropped since the last good one (diagnostics).
  int get rejectedFixes => _gate.consecutiveRejects;

  // ---------------------------------------------------------------- internals

  final FixGate _gate = FixGate();
  final HeadingFusion _heading = HeadingFusion();
  final SpeedZoomPolicy _zoomPolicy = SpeedZoomPolicy();
  final PositionSmoother _smoother = PositionSmoother();

  Ticker? _ticker;
  Duration? _lastTick;

  /// Monotonic animation clock in seconds (advanced only by the ticker, so it
  /// follows fake time in widget tests).
  double _clock = 0.0;

  bool _following = true;
  MapOrientation _orientation = MapOrientation.courseUp;
  bool _foreground = true;
  bool _powerSaving = false;
  bool _disposed = false;

  // Newest accepted fix.
  double? _fixLat;
  double? _fixLng;
  double _fixSpeedMps = 0.0;
  double _fixCourse = 0.0;
  double _fixAt = 0.0;
  bool _fixEstimated = false;
  int? _lastFixTs;
  double? _lastFixRawLat;
  double? _lastFixRawLng;
  double? _prevAcceptedLat;
  double? _prevAcceptedLng;

  // Drawn values.
  double? _bearing;
  double? _zoom;
  double? _rotation;
  Offset _offset = Offset.zero;
  double _zoomBias = 0.0;
  EdgeInsets _obscured = EdgeInsets.zero;

  // Last values sent to the map (to skip identical moves).
  LatLng? _sentCenter;
  double? _sentZoom;
  double? _sentRotation;

  // Recenter blend: from where the user left the camera back to the follow camera.
  LatLng? _blendFromCenter;
  double _blendFromZoom = 0.0;
  double _blendFromRotation = 0.0;
  double _blendT = 1.0;

  // Auto-resume while riding: a pan is respected for a while, then follow comes back.
  double? _pausedAt;
  static const double _autoResumeAfterSec = 15.0;
  static const double _autoResumeKmh = 15.0;

  StreamSubscription<CompassEvent>? _compassSub;
  int _compassMs = 0;

  // ---------------------------------------------------------------- lifecycle

  /// Called by [NavCameraTicker] with its state as the provider.
  void attach(TickerProvider vsync) {
    _ticker?.dispose();
    _ticker = vsync.createTicker(_onTick);
    _lastTick = null;
    _wake();
  }

  void detach() {
    _ticker?.dispose();
    _ticker = null;
    _lastTick = null;
  }

  /// App visible and the cockpit on screen. Off: no frames, no compass.
  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    if (!value) {
      _stopTicker();
    } else {
      _wake();
    }
    _syncCompass();
  }

  /// Low battery / battery saver: at most 30 camera frames a second.
  void setPowerSaving(bool value) => _powerSaving = value;

  /// Room taken by overlays (top bar, bottom sheet, side panel) in logical
  /// pixels: my marker is placed inside what is left.
  void setObscuredInsets(EdgeInsets insets) {
    if (insets == _obscured) return;
    _obscured = insets;
    _wake();
  }

  @override
  void dispose() {
    _disposed = true;
    _compassSub?.cancel();
    _compassSub = null;
    detach();
    pose.dispose();
    mapRotation.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- follow & orientation

  /// A map gesture took over: stop moving the camera (my marker keeps moving).
  void pauseFollow() {
    if (!_following) return;
    _following = false;
    _pausedAt = _clock;
    _blendT = 1.0;
    _notifySafely();
  }

  /// Back to following, gliding from where the camera is now.
  void resumeFollow() {
    _zoomBias = 0.0;
    _pausedAt = null;
    _startBlendFromCurrentCamera();
    final changed = !_following;
    _following = true;
    _sentCenter = null;
    _wake();
    if (changed) _notifySafely();
  }

  /// Listeners may call setState: never notify in the middle of a build.
  void _notifySafely() {
    if (_disposed) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks || phase == SchedulerPhase.midFrameMicrotasks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  /// Zoom buttons while following: shift the speed zoom instead of fighting it.
  void nudgeZoom(double delta) {
    _zoomBias = (_zoomBias + delta).clamp(-6.0, 3.0).toDouble();
    _wake();
  }

  void setOrientation(MapOrientation value) {
    if (_orientation == value) return;
    _orientation = value;
    _wake();
    _syncCompass();
    _notifySafely();
    _saveOrientation();
  }

  void toggleOrientation() =>
      setOrientation(courseUp ? MapOrientation.northUp : MapOrientation.courseUp);

  Future<void> _loadOrientation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(prefsKeyOrientation);
      if (_disposed || v == null) return;
      final o = v == 'northUp' ? MapOrientation.northUp : MapOrientation.courseUp;
      if (o != _orientation) {
        _orientation = o;
        _wake();
        _notifySafely();
      }
    } catch (_) {
      // No preferences (tests, first run): course-up.
    }
  }

  Future<void> _saveOrientation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKeyOrientation, _orientation == MapOrientation.northUp ? 'northUp' : 'courseUp');
    } catch (_) {}
  }

  // ---------------------------------------------------------------- input

  /// Every update of my rider (real fix or a dead-reckoned estimate). Safe to
  /// call from build: it never touches the map directly, it only wakes the
  /// ticker. Duplicate updates are ignored.
  ///
  /// [accuracyM] is the fix's horizontal accuracy (null when unknown);
  /// [estimated] marks tunnel / dead-reckoned positions (no accuracy test).
  void onRiderFix({
    required double lat,
    required double lng,
    required double speedKmh,
    required double heading,
    required int timestampMs,
    double? accuracyM,
    bool estimated = false,
  }) {
    if (_disposed) return;
    if (timestampMs == _lastFixTs && lat == _lastFixRawLat && lng == _lastFixRawLng) return;
    _lastFixTs = timestampMs;
    _lastFixRawLat = lat;
    _lastFixRawLng = lng;

    final verdict = _gate.check(lat: lat, lng: lng, tsMs: timestampMs, accuracyM: estimated ? null : accuracyM);
    if (!verdict.accepted) return;

    final kmh = (speedKmh.isFinite && speedKmh > 0) ? speedKmh : 0.0;
    final first = _fixLat == null;

    // Course: the GPS course while fast enough to trust it, else the bearing
    // between two fixes far enough apart, else whatever the service reported.
    var course = heading;
    final pLat = _prevAcceptedLat, pLng = _prevAcceptedLng;
    if (kmh < 10.0 && pLat != null && pLng != null) {
      final moved = NavMath.distanceM(pLat, pLng, lat, lng);
      if (moved >= math.max(4.0, (accuracyM ?? 0.0) * 0.6)) {
        course = NavMath.bearingDeg(pLat, pLng, lat, lng);
      }
    }
    _prevAcceptedLat = lat;
    _prevAcceptedLng = lng;

    final switched = _heading.updateSpeed(kmh);
    if (_heading.bearing == null) _heading.seed(course);
    if (_heading.usingGps) {
      _heading.addCourse(course);
    } else if (!_compassAlive && kmh >= 3.0) {
      // Slow and no compass (none on this phone, or it went quiet): the course still beats nothing.
      _heading.seed(course);
    }
    if (switched) _syncCompass();

    _fixLat = lat;
    _fixLng = lng;
    _fixSpeedMps = kmh / 3.6;
    _fixCourse = NavMath.normalizeDeg(course);
    _fixAt = _clock;
    _fixEstimated = estimated;

    if (first || verdict == FixVerdict.reanchor) {
      _smoother.snap(lat, lng);
      _bearing ??= _heading.bearing ?? _fixCourse;
      _zoomPolicy.seed(kmh);
      // Start from where the map is, so the first follow frame eases in instead of jumping.
      try {
        final cam = mapController.camera;
        _zoom ??= cam.zoom;
        _rotation ??= NavMath.normalizeDeg(cam.rotation);
      } catch (_) {
        _zoom ??= _zoomPolicy.zoom;
      }
    } else {
      _zoomPolicy.update(kmh, timestampMs);
    }

    // Riding again after a pan: follow comes back by itself after a while.
    final pausedAt = _pausedAt;
    if (!_following && pausedAt != null && kmh >= _autoResumeKmh && _clock - pausedAt >= _autoResumeAfterSec) {
      resumeFollow();
      return;
    }
    _wake();
  }

  // ---------------------------------------------------------------- compass

  bool get _compassAlive =>
      _compassSub != null && DateTime.now().millisecondsSinceEpoch - _compassMs < 3000;

  bool get _wantCompass =>
      _enableCompass && _foreground && !_heading.usingGps && _fixLat != null && !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  void _syncCompass() {
    if (_wantCompass) {
      if (_compassSub != null) return;
      try {
        _compassSub = FlutterCompass.events?.listen(_onCompass, onError: (Object _) {
          _compassSub?.cancel();
          _compassSub = null;
        });
      } catch (_) {
        _compassSub = null;
      }
    } else {
      _compassSub?.cancel();
      _compassSub = null;
    }
  }

  void _onCompass(CompassEvent event) {
    final h = event.heading;
    if (h == null || !h.isFinite || _disposed) return;
    // Wall-clock milliseconds only pace the compass low-pass filter.
    final now = DateTime.now().millisecondsSinceEpoch;
    _compassMs = now;
    if (_heading.addCompass(NavMath.normalizeDeg(h), now)) {
      final b = _bearing, target = _heading.bearing;
      if (b == null || target == null || NavMath.shortestDelta(b, target).abs() > 1.0) _wake();
    }
  }

  // ---------------------------------------------------------------- frames

  void _wake() {
    final t = _ticker;
    if (t == null || _disposed || !_foreground || _fixLat == null) return;
    if (!t.isActive) {
      _lastTick = null;
      t.start();
    }
  }

  void _stopTicker() {
    final t = _ticker;
    if (t != null && t.isActive) t.stop();
    _lastTick = null;
  }

  void _onTick(Duration elapsed) {
    if (_disposed) return;
    final last = _lastTick;
    final minFrame = (_powerSaving || _fixSpeedMps < 8 / 3.6) ? _frameRelaxed : _frameRiding;
    if (last != null && elapsed - last < minFrame) return;
    final dt = last == null ? 1 / 60 : ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, 0.25).toDouble();
    _lastTick = elapsed;
    _clock += dt;
    final busy = _advance(dt);
    if (!busy) _stopTicker();
  }

  /// One frame. Returns false once everything has settled (the ticker then stops).
  bool _advance(double dt) {
    final fLat = _fixLat, fLng = _fixLng;
    if (fLat == null || fLng == null) return false;

    // 1. Where I should be now: the newest fix projected along the course.
    final age = _clock - _fixAt;
    final extrapolating = !_fixEstimated && _fixSpeedMps >= 1.0 && age < _maxExtrapolationSec;
    final (tLat, tLng) = extrapolating
        ? NavMath.extrapolate(fLat, fLng, _fixCourse, _fixSpeedMps, age, maxSec: _maxExtrapolationSec)
        : (fLat, fLng);
    final movedM = _smoother.step(
      targetLat: tLat,
      targetLng: tLng,
      headingDeg: _fixCourse,
      speedMps: _fixSpeedMps,
      dtSec: dt,
    );

    // 2. Bearing: shortest way round, faster when moving than on the compass.
    final targetBearing = _heading.bearing ?? _fixCourse;
    final b0 = _bearing ?? targetBearing;
    final bTau = _heading.usingGps ? 0.35 : 0.5;
    var b = NavMath.lerpAngle(b0, targetBearing, NavMath.smoothingAlpha(dt, bTau));
    if (NavMath.shortestDelta(b, targetBearing).abs() < 0.05) b = NavMath.normalizeDeg(targetBearing);
    final bearingMoved = NavMath.shortestDelta(b0, b).abs();
    _bearing = b;

    // 3. Zoom from speed (+ the rider's own nudge), eased.
    final targetZoom = (_zoomPolicy.zoom + _zoomBias).clamp(_minZoom, _maxZoom).toDouble();
    final z0 = _zoom ?? targetZoom;
    var z = z0 + (targetZoom - z0) * NavMath.smoothingAlpha(dt, 0.9);
    if ((targetZoom - z).abs() < 0.002) z = targetZoom;
    _zoom = z;

    // 4. Map rotation: -bearing course-up, 0 north-up, eased so a toggle turns smoothly.
    final targetRotation = courseUp ? NavMath.normalizeDeg(-b) : 0.0;
    final r0 = _rotation ?? targetRotation;
    var r = NavMath.lerpAngle(r0, targetRotation, NavMath.smoothingAlpha(dt, 0.12));
    if (NavMath.shortestDelta(r, targetRotation).abs() < 0.05) r = targetRotation;
    _rotation = r;

    // 5. Where my marker sits on screen: lower third of the free area course-up, its middle north-up.
    final targetOffset = _targetOffset();
    final o0 = _offset;
    var o = Offset.lerp(o0, targetOffset, NavMath.smoothingAlpha(dt, 0.25)) ?? targetOffset;
    if ((o - targetOffset).distance < 0.5) o = targetOffset;
    _offset = o;

    _publishPose();

    var cameraBusy = false;
    if (_following) cameraBusy = _applyCamera(dt);

    final settled = !extrapolating &&
        movedM < 0.01 &&
        bearingMoved < 0.01 &&
        (z - targetZoom).abs() < 1e-6 &&
        NavMath.shortestDelta(r, targetRotation).abs() < 1e-6 &&
        o == targetOffset &&
        !cameraBusy;
    return !settled;
  }

  Offset _targetOffset() {
    Size size;
    try {
      size = mapController.camera.nonRotatedSize;
    } catch (_) {
      return Offset.zero;
    }
    if (!size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0) return Offset.zero;
    final left = _obscured.left.clamp(0.0, size.width * 0.7).toDouble();
    final right = size.width - _obscured.right.clamp(0.0, size.width * 0.7).toDouble();
    final top = _obscured.top.clamp(0.0, size.height * 0.5).toDouble();
    final bottom = size.height - _obscured.bottom.clamp(0.0, size.height * 0.75).toDouble();
    if (right - left < 80 || bottom - top < 120) return Offset.zero;
    final x = (left + right) / 2;
    final y = courseUp ? top + (bottom - top) * 0.70 : (top + bottom) / 2;
    return Offset(x - size.width / 2, y - size.height / 2);
  }

  void _publishPose() {
    final lat = _smoother.lat, lng = _smoother.lng;
    if (lat == null || lng == null) return;
    final p = pose.value;
    final h = _bearing ?? _fixCourse;
    final kmh = _fixSpeedMps * 3.6;
    if (p != null && p.lat == lat && p.lng == lng && p.heading == h && p.speedKmh == kmh) return;
    pose.value = NavPose(lat: lat, lng: lng, heading: h, speedKmh: kmh);
  }

  void _startBlendFromCurrentCamera() {
    try {
      final cam = mapController.camera;
      _blendFromCenter = cam.center;
      _blendFromZoom = cam.zoom;
      _blendFromRotation = NavMath.normalizeDeg(cam.rotation);
      _blendT = 0.0;
    } catch (_) {
      _blendFromCenter = null;
      _blendT = 1.0;
    }
  }

  /// Moves the map to the follow camera (or towards it while blending back).
  /// Returns true while a recenter blend is still running.
  bool _applyCamera(double dt) {
    final lat = _smoother.lat, lng = _smoother.lng, z = _zoom, r = _rotation;
    if (lat == null || lng == null || z == null || r == null) return false;
    var (cLat, cLng) = NavMath.cameraCenterFor(
      lat: lat,
      lng: lng,
      zoom: z,
      rotationDeg: r,
      screenOffsetX: _offset.dx,
      screenOffsetY: _offset.dy,
    );
    var zoom = z;
    var rotation = r;
    var blending = false;
    final from = _blendFromCenter;
    if (_blendT < 1.0 && from != null) {
      _blendT = math.min(1.0, _blendT + dt / 0.6);
      final e = Curves.easeInOutCubic.transform(_blendT);
      cLat = from.latitude + (cLat - from.latitude) * e;
      cLng = from.longitude + (cLng - from.longitude) * e;
      zoom = _blendFromZoom + (z - _blendFromZoom) * e;
      rotation = NavMath.lerpAngle(_blendFromRotation, r, e);
      blending = _blendT < 1.0;
      if (!blending) _blendFromCenter = null;
    }
    if (!cLat.isFinite || !cLng.isFinite || !zoom.isFinite || !rotation.isFinite) return blending;
    final center = LatLng(cLat.clamp(-85.0, 85.0).toDouble(), cLng);
    final sc = _sentCenter, sz = _sentZoom, sr = _sentRotation;
    if (sc != null &&
        sz != null &&
        sr != null &&
        (sc.latitude - center.latitude).abs() < 1e-8 &&
        (sc.longitude - center.longitude).abs() < 1e-8 &&
        (sz - zoom).abs() < 1e-5 &&
        NavMath.shortestDelta(sr, rotation).abs() < 1e-4) {
      return blending;
    }
    try {
      mapController.moveAndRotate(center, zoom, rotation);
      _sentCenter = center;
      _sentZoom = zoom;
      _sentRotation = rotation;
    } catch (_) {
      // The map is not laid out yet: the next fix or wake tries again (no busy loop).
      _sentCenter = null;
      return false;
    }
    return blending;
  }

  /// Keeps [mapRotation] in step with the real camera (gestures included).
  void onCameraChanged(MapCamera camera) {
    final r = camera.rotation;
    if (r.isFinite && (mapRotation.value - r).abs() > 0.01) mapRotation.value = r;
  }

  @visibleForTesting
  double get debugZoomBias => _zoomBias;

  @visibleForTesting
  int get debugCompassMs => _compassMs;
}

/// Gives a [NavCameraController] its frame ticker for as long as this widget
/// is mounted (put it anywhere under the cockpit; it draws nothing).
class NavCameraTicker extends StatefulWidget {
  final NavCameraController controller;

  const NavCameraTicker({super.key, required this.controller});

  @override
  State<NavCameraTicker> createState() => _NavCameraTickerState();
}

class _NavCameraTickerState extends State<NavCameraTicker> with TickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    widget.controller.attach(this);
  }

  @override
  void didUpdateWidget(covariant NavCameraTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.detach();
      widget.controller.attach(this);
    }
  }

  @override
  void dispose() {
    widget.controller.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
