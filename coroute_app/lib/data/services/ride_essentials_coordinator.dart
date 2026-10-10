import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/route/route_guide.dart';
import '../../domain/tracking/track_point.dart';
import '../models/convoy_model.dart';
import 'convoy_service.dart';
import 'route_essentials_service.dart';
import 'settings_service.dart';

/// Uses the ride's existing GPS stream; never starts a location subscription.
abstract class RideEssentialsPort implements Listenable {
  ConvoyModel? get activeConvoy;
  String? get myUserId;
  bool get isOnline;
  bool get isRealGpsActive;
  bool get conservingBattery;
  Stream<TrackPoint> get myFixes;
}

class ConvoyEssentialsPort implements RideEssentialsPort {
  ConvoyEssentialsPort(this.convoys);
  final ConvoyService convoys;
  @override
  ConvoyModel? get activeConvoy => convoys.activeConvoy;
  @override
  String? get myUserId => convoys.myUserId;
  @override
  bool get isOnline => convoys.isOnline;
  @override
  bool get isRealGpsActive => convoys.isRealGpsActive;
  @override
  bool get conservingBattery => convoys.conservingBattery;
  @override
  Stream<TrackPoint> get myFixes => convoys.myFixes;
  @override
  void addListener(VoidCallback listener) => convoys.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => convoys.removeListener(listener);
}

/// Shared map/background route following and bounded essentials discovery.
/// A single expiry timer invalidates GPS guidance without making a request.
class RideEssentialsCoordinator extends ChangeNotifier {
  RideEssentialsCoordinator(this.port, this.settings, this.essentials,
      {required this._fetchRoute, int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _guide = _newGuide();
    port.addListener(_onState);
    settings.addListener(_onState);
    essentials.addListener(_changed);
    _fixes = port.myFixes.listen(_onFix);
    _onState();
  }

  static const fixLifetime = Duration(minutes: 2);
  final RideEssentialsPort port;
  final SettingsService settings;
  final RouteEssentialsService essentials;
  final RouteFetcher _fetchRoute;
  final int Function() _clock;
  late RouteGuide _guide;
  late final StreamSubscription<TrackPoint> _fixes;
  Timer? _expiry;
  TrackPoint? _fix;
  String? _session;
  String? groupId;
  bool _disposed = false;
  bool _feeding = false;

  RouteGuide get guide => _guide;
  bool get hasCurrentPosition => _session != null && port.isRealGpsActive &&
      _fix != null && _clock() >= _fix!.ts &&
      _clock() - _fix!.ts < fixLifetime.inMilliseconds;

  RouteGuide _newGuide() => RouteGuide(fetchRoute: _fetchRoute)..addListener(_onGuide);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _onState() {
    if (_disposed) return;
    final convoy = port.activeConvoy;
    final uid = port.myUserId;
    final session = convoy != null && uid != null && convoy.tripStatus != 'ENDED'
        ? '${convoy.groupId}|$uid' : null;
    if (session != _session) {
      _expiry?.cancel();
      _fix = null;
      _guide.removeListener(_onGuide);
      _guide.dispose();
      _guide = _newGuide();
      _session = session;
      groupId = session == null ? null : convoy!.groupId;
      // Invalidates outstanding responses, including a same-route account switch.
      essentials.update(null, fromM: 0, online: false).ignore();
    }
    if (session != null) {
      _feeding = true;
      _guide.setConvoy(convoy!, uid!);
      _feed();
      _feeding = false;
    }
    refresh().ignore();
  }

  void _onFix(TrackPoint fix) {
    if (_disposed || _session == null || !port.isRealGpsActive) return;
    final now = _clock();
    if (fix.ts > now || now - fix.ts >= fixLifetime.inMilliseconds ||
        (_fix != null && fix.ts <= _fix!.ts) ||
        !fix.lat.isFinite || !fix.lng.isFinite || fix.lat.abs() > 85 || fix.lng.abs() > 180 ||
        !fix.accuracyM.isFinite || fix.accuracyM < 0 || fix.accuracyM > 100 ||
        !fix.speedKmh.isFinite || fix.speedKmh < 0) {
      return;
    }
    _fix = fix;
    _expiry?.cancel();
    _expiry = Timer(Duration(milliseconds: fix.ts + fixLifetime.inMilliseconds - now), () {
      // No polling on expiry: hide route-dependent guidance until another fix.
      refresh(allowNetwork: false).ignore();
    });
    _feeding = true;
    _feed();
    _feeding = false;
    refresh().ignore();
  }

  void _feed() {
    if (!hasCurrentPosition) return;
    final fix = _fix!;
    _guide.onFix(lat: fix.lat, lng: fix.lng, speedKmh: fix.speedKmh,
        accuracyM: fix.accuracyM, nowMs: fix.ts, online: port.isOnline,
        lowData: settings.lowData || port.conservingBattery);
  }

  void _onGuide() {
    if (!_feeding) refresh().ignore();
  }

  Future<void> refresh({String? category, bool force = false, bool allowNetwork = true}) {
    essentials.groupId = groupId;
    final policy = port.activeConvoy?.featurePolicy;
    final valid = policy?.essentialsEnabled != false && hasCurrentPosition && _guide.active?.last?.onLine == true;
    return essentials.update(valid ? _guide.activeRoute : null,
        fromM: valid ? _guide.active!.matched!.alongM : 0,
        online: port.isOnline,
        lowData: !allowNetwork || policy?.autoDiscovery == false || settings.lowData || port.conservingBattery,
        selectedCategory: category ?? essentials.category,
        force: force && allowNetwork);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _expiry?.cancel();
    _fixes.cancel();
    port.removeListener(_onState);
    settings.removeListener(_onState);
    _guide.removeListener(_onGuide);
    _guide.dispose();
    essentials.removeListener(_changed);
    essentials.dispose();
    super.dispose();
  }
}
