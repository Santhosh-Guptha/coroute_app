import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/route_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/geo_service.dart';
import '../../data/services/map_places_service.dart';
import '../../data/services/safety_service.dart';
import '../../domain/intel/intel_policies.dart';
import '../../domain/places/poi_category.dart';
import '../map_places/map_places_layer.dart';
import '../map_places/place_chips.dart';
import '../map_picker/map_picker_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../widgets/pre_ride_checklist_sheet.dart';
import 'trip_review_sheet.dart';
import '../../data/services/tile_cache_service.dart';
import '../../data/services/membership_service.dart';
import '../garage/complete_bike_sheet.dart'; // 3.55 mandatory bike details

/// Plan a ride on one screen, map first: name, start, destination, stops
/// (picked on the map or by long-pressing it), then Review and Start Ride.
/// The live route preview runs through every stop.
///
/// After the ride is created the planner returns to the root route; the
/// home shell sees the new active ride and switches to the Ride tab.
class TripPlannerScreen extends StatefulWidget {
  /// 3.56: text shared to CoRoute (a maps link, a place, coordinates): the destination
  /// picker opens with it in the search box.
  final String? sharedText;

  const TripPlannerScreen({super.key, this.sharedText});

  @override
  State<TripPlannerScreen> createState() => _TripPlannerScreenState();
}

class _TripPlannerScreenState extends State<TripPlannerScreen> {
  static const int _maxStops = 20;

  final _name = TextEditingController();
  final _nameFocus = FocusNode();
  late final GeoService _geo = GeoService(context.read<ApiClient>());
  final MapController _map = MapController();
  PickedPlace? _start;
  PickedPlace? _destination;
  final List<PickedPlace> _stops = [];
  List<PickedPlace> _recent = const [];
  RouteModel? _route;
  List<LatLng> _cachedDisplayLine = const [];
  Timer? _routeDebounce;
  bool _routing = false;
  bool _launching = false;
  bool _isPicking = false;
  bool _isAddingStopSheet = false;
  bool _isReviewing = false;
  String? _nameError;
  int _speedLimit = 0;
  int _routeRequest = 0;
  String? _loadingMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _useCurrentLocationAsStart());
    final shared = widget.sharedText;
    if (shared != null && shared.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickDestination(initialQuery: shared);
      });
    }
    RecentPlaces.load().then((r) {
      if (mounted) setState(() => _recent = r);
    });
  }

  @override
  void dispose() {
    _routeDebounce?.cancel();
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _scheduleRouteRefresh() {
    _routeDebounce?.cancel();
    _routeDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _refreshRoute();
    });
  }

  Future<void> _useCurrentLocationAsStart() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final p = await Geolocator.getLastKnownPosition() ??
          await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 6)));
      if (!mounted || _start != null) return;
      setState(() => _start = PickedPlace(lat: p.latitude, lng: p.longitude, name: 'My location'));
      _refreshRoute();
      final name = await _geo.reverse(p.latitude, p.longitude);
      if (mounted && name != null && _start?.name == 'My location') setState(() => _start = _start!.copyWith(name: name));
    } catch (_) {}
  }

  List<(double, double)> get _waypoints => [
        if (_start != null) (_start!.lat, _start!.lng),
        for (final s in _stops) (s.lat, s.lng),
        if (_destination != null) (_destination!.lat, _destination!.lng),
      ];

  /// Recomputes the route. The old line stays on the map (with a thin
  /// progress bar) until the new one arrives.
  Future<void> _refreshRoute() async {
    _routeDebounce?.cancel();
    final wp = _waypoints;
    final req = ++_routeRequest;
    if (wp.length < 2) {
      setState(() {
        _route = null;
        _cachedDisplayLine = const [];
        _routing = false;
      });
      return;
    }
    setState(() => _routing = true);
    final r = await _geo.route(wp);
    if (!mounted || req != _routeRequest) return;
    final displayPts = r != null
        ? [for (final (lat, lng) in r.displayPoints) LatLng(lat, lng)]
        : const <LatLng>[];
    setState(() {
      _route = r;
      _cachedDisplayLine = displayPts;
      _routing = false;
    });
    _fit();
    // Round 4: road intelligence tiles along the planned route (learned rider stops for the map layer and the fuel
    // gap check; hazards for the ride, kept offline). Never in the way of planning.
    if (r != null && SafetyService.hasInstance) {
      SafetyService.instance.intel.prefetchAlong(r.points).then((_) {
        if (mounted && req == _routeRequest) setState(() => _gapKey = null);
      }).catchError((Object _) {});
    }
  }

  void _fit() {
    final r = _route;
    if (r != null) {
      final b = r.bounds ?? r.calculatedBounds;
      if (b != null) {
        try {
          _map.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds(LatLng(b.minLat, b.minLng), LatLng(b.maxLat, b.maxLng)),
            padding: const EdgeInsets.all(36),
          ));
          return;
        } catch (_) {}
      }
    }
    final wp = _waypoints;
    if (wp.length < 2) return;
    try {
      final pts = [for (final (lat, lng) in wp) LatLng(lat, lng)];
      _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(36)));
    } catch (_) {}
  }

  Future<void> _pickStart() async {
    if (_isPicking || _launching) return;
    _isPicking = true;
    try {
      final p = await MapPickerScreen.pick(context, title: 'Start', initial: _start);
      if (p == null || !mounted) return;
      setState(() => _start = p);
      _refreshRoute();
    } finally {
      _isPicking = false;
    }
  }

  Future<void> _pickDestination({String? initialQuery}) async {
    if (_isPicking || _launching) return;
    _isPicking = true;
    try {
      final p = await MapPickerScreen.pick(context, title: 'Destination', initial: _destination, initialQuery: initialQuery);
      if (p == null || !mounted) return;
      _setDestination(p);
    } finally {
      _isPicking = false;
    }
  }

  void _setDestination(PickedPlace p) {
    setState(() => _destination = p);
    _scheduleRouteRefresh();
  }

  Future<void> _addStop() async {
    if (_isPicking || _launching) return;
    _isPicking = true;
    try {
      final near = _stops.isNotEmpty ? _stops.last : (_start ?? _destination);
      final p = await MapPickerScreen.pick(
        context,
        title: 'Add a stop',
        forStop: true,
        confirmLabel: 'Add stop',
        initial: near == null ? null : PickedPlace(lat: near.lat, lng: near.lng),
      );
      if (p == null || !mounted) return;
      setState(() => _stops.add(p));
      _scheduleRouteRefresh();
    } finally {
      _isPicking = false;
    }
  }

  /// Long-press on the map: name the place, choose its type, add it.
  Future<void> _addStopAt(LatLng point) async {
    if (_launching || _isAddingStopSheet) return;
    if (_stops.length >= _maxStops) {
      _snack('A trip can have up to $_maxStops stops.');
      return;
    }
    _isAddingStopSheet = true;
    try {
      final p = await showAppSheet<PickedPlace>(
        context,
        title: 'Add a stop here',
        isScrollControlled: true,
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        builder: (_) => _AddStopSheet(geo: _geo, point: point),
      );
      if (p == null || !mounted) return;
      setState(() => _stops.add(p));
      _scheduleRouteRefresh();
    } finally {
      _isAddingStopSheet = false;
    }
  }

  Future<void> _editStop(int i) async {
    if (_isPicking || _launching || i < 0 || i >= _stops.length) return;
    _isPicking = true;
    try {
      final p = await MapPickerScreen.pick(
        context,
        title: 'Edit stop',
        forStop: true,
        confirmLabel: 'Save stop',
        initial: _stops[i],
      );
      if (p == null || !mounted) return;
      setState(() => _stops[i] = p);
      _scheduleRouteRefresh();
    } finally {
      _isPicking = false;
    }
  }

  void _removeStop(int i) {
    setState(() => _stops.removeAt(i));
    _scheduleRouteRefresh();
  }

  Future<void> _review() async {
    if (_isReviewing || _launching) return;
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _nameError = 'Give the trip a name.');
      _nameFocus.requestFocus();
      return;
    }
    setState(() {
      _isReviewing = true;
      _loadingMessage = 'Checking trip details...';
    });
    FocusScope.of(context).unfocus();
    try {
      // Every rider can start a ride: Community (free) rides solo, a group plan hosts a group. The
      // plan only decides the seats, which the gateway sets. The plan
      // is refreshed in the background so the home line and the ride sheet read right.
      final ms = context.read<MembershipService?>();
      if (ms != null && ms.plansEnforced) ms.fetchMyMembership().ignore();

      if (!mounted) return;

      setState(() => _loadingMessage = 'Preparing your trip...');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
      setState(() => _loadingMessage = null);

      // Stage 4: Return to exact trip creation review stage with all details restored
      final limit = await TripReviewSheet.show(
        context,
        name: name,
        startName: _start?.name,
        destinationName: _destination?.name,
        route: _route,
        stops: _stops.length,
        speedLimitKmh: _speedLimit,
        namedStops: [for (final s in _stops) (s.name, s.lat, s.lng)],
        startLat: _start?.lat,
        startLng: _start?.lng,
        destinationLat: _destination?.lat,
        destinationLng: _destination?.lng,
        confirmLabel: 'Confirm and Create Trip',
      );

      if (limit == null || !mounted) return;
      setState(() => _speedLimit = limit);

      // Final step: explicit user confirmation launches trip
      await _launch(name);
    } finally {
      if (mounted) {
        setState(() {
          _isReviewing = false;
          _loadingMessage = null;
        });
      }
    }
  }

  Future<void> _launch(String name) async {
    if (_launching) return;
    if (!await PermissionsScreen.ensure(context)) return;
    if (!mounted) return;
    // 3.55 mandatory bike details: the trip owner rides too, so a rider needs a complete bike
    // (a pillion account goes on). Closing the sheet only cancels this launch.
    final gate = await BikeGate.ensureReady(context, pillionAccount: context.read<AuthService>().isPillion, allowPillion: false);
    if (gate == BikeGateResult.cancelled || !mounted) return;
    // Pre-ride checklist (never blocks; closing it without starting cancels the launch).
    if (!await PreRideChecklistSheet.show(context)) return;
    if (!mounted) return;
    await _create(name);
  }

  /// Creates the ride (after the checks) and goes back to the home shell. Also the "Retry"
  /// of the server-busy message, which does not ask the checks again.
  Future<void> _create(String name) async {
    if (_launching || !mounted) return;
    final auth = context.read<AuthService>();
    final convoys = context.read<ConvoyService>();
    setState(() {
      _launching = true;
      _loadingMessage = 'Creating your trip...';
    });

    ConvoyModel? convoy;
    try {
      convoy = await convoys.createConvoy(
        name: name,
        creatorId: auth.currentUserId ?? '',
        creatorName: auth.currentUserName ?? 'Trip owner',
        startPoint: _start?.name ?? '',
        destination: _destination?.name ?? '',
        destLat: _destination?.lat ?? 0,
        destLng: _destination?.lng ?? 0,
        vehicleType: auth.vehicleType ?? 'Motorcycle',
        vehicleNo: auth.vehicleNo ?? '',
        phone: auth.phone ?? '',
        start: _start,
        stops: List.of(_stops),
        speedLimitKmh: _speedLimit,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _launching = false;
          _loadingMessage = null;
        });
      }
      if (e is ApiException && e.isServerBusy) {
        // The gateway is full for new rides right now: plain words and a retry, nothing else.
        _busySnack(name);
      } else {
        _snack(e is ApiException ? e.message : 'Could not start the ride. Check your connection.');
      }
      return;
    }
    if (!mounted) return;

    // FEAT-MAP-01: Invisible Background Route Tile Prefetch
    // Seamlessly prefetch route corridor tiles in the background without blocking or showing separate download screens.
    // Respects battery (< 20%) and network conditions.
    try {
      final prefetcher = context.read<TilePrefetcher?>();
      final routePts = _route?.points ?? convoy.routeLine;
      if (prefetcher != null && routePts.isNotEmpty) {
        prefetcher.prefetchCorridorBackground(
          routeLine: routePts,
          label: name,
          riderLocation: _start != null ? (_start!.lat, _start!.lng) : null,
          destination: _destination != null ? (_destination!.lat, _destination!.lng) : null,
          stops: [for (final s in _stops) (s.lat, s.lng)],
          tripId: convoy.groupId,
        ).ignore();
      }
    } catch (_) {}

    HapticFeedback.mediumImpact();
    // Back to the home shell; it switches to the Ride tab when the active ride appears.
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void _busySnack(String name) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text(ApiException.serverBusyMessage),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(label: 'Retry', onPressed: () => _create(name)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.map,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          LayoutBuilder(builder: (context, c) {
            final map = LoadingState(loading: _routing, child: _mapView());
            final sideBySide = c.maxWidth > c.maxHeight && c.maxWidth >= 560;
            if (sideBySide) {
              final formWidth = (c.maxWidth * 0.45).clamp(280.0, 480.0).toDouble();
              return Row(
                children: [
                  SizedBox(width: formWidth, child: _sheet(sideBySide: true)),
                  Expanded(child: Stack(children: [Positioned.fill(child: map), _floatingTop()])),
                ],
              );
            }
            // Half the screen, at least 300 dp and always leaving 120 dp of map;
            // with the keyboard up (little height) the sheet takes most of it.
            final sheetHeight = c.maxHeight < 420 ? c.maxHeight * 0.75 : (c.maxHeight * 0.5).clamp(300.0, c.maxHeight - 120).toDouble();
            return Stack(
              children: [
                // The map runs under the sheet's rounded corners.
                Positioned(left: 0, right: 0, top: 0, bottom: sheetHeight - Radii.sheet, child: map),
                _floatingTop(),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: sheetHeight,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 680),
                      child: _sheet(),
                    ),
                  ),
                ),
              ],
            );
          }),
          if (_loadingMessage != null)
            Positioned.fill(
              child: AbsorbPointer(
                child: Container(
                  color: Colors.black54,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                      decoration: BoxDecoration(
                        color: AppTheme.card,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: dsFloatingShadow(),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: AppTheme.brand),
                          ),
                          const SizedBox(width: 16),
                          Flexible(
                            child: Text(
                              _loadingMessage!,
                              style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Floating row over the map: round back button, "Route · 82 km" pill,
  /// round fit-route button.
  Widget _floatingTop() {
    final r = _route;
    final pill = r != null
        ? 'Route · ${formatDistance(r.distanceM)}'
        : _destination != null
            ? 'Plan a ride · finding route'
            : 'Plan a ride';
    return Positioned(
      left: 16,
      right: 16,
      top: 0,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: dsFloatingShadow()),
                    child: DsRoundButton(
                      icon: Icons.chevron_left_rounded,
                      label: 'Back',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppTheme.card,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: dsFloatingShadow(),
                        ),
                        child: Text(
                          pill,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppTheme.text, fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                  if (_placesService() case final places?) ...[
                    PlacesMapButton(service: places),
                    const SizedBox(width: 8),
                  ],
                  DecoratedBox(
                    decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: dsFloatingShadow()),
                    child: DsRoundButton(
                      icon: Icons.fit_screen_rounded,
                      label: 'Fit the route on the map',
                      iconColor: AppTheme.accentText,
                      onTap: _fit,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _gapKey;
  List<FuelGap> _gapList = const [];

  /// No-fuel gaps over 80 km on the planned route (known fuel from the cached map places and learned rider stops).
  List<FuelGap> _fuelGaps(RouteModel r) {
    final key = '${r.polyline.hashCode}:${SafetyService.hasInstance ? SafetyService.instance.intel.learnedStops.length : 0}';
    if (key == _gapKey) return _gapList;
    _gapKey = key;
    try {
      final places = _placesService()?.all ?? const [];
      final fuel = [for (final p in places) if (p.category == PoiCategory.fuel) (lat: p.lat, lng: p.lng, name: p.displayName)];
      _gapList = SafetyService.hasInstance ? SafetyService.instance.intel.fuelGaps(r.points, fuel) : FuelGapFinder.gaps(r.points, fuel);
    } catch (_) {
      _gapList = const [];
    }
    return _gapList;
  }

  MapPlacesService? _placesService() {
    final api = context.read<ApiClient?>();
    return api == null ? null : MapPlacesService.shared(api);
  }

  Widget _mapView() {
    final line = _cachedDisplayLine;
    final center = _start != null ? LatLng(_start!.lat, _start!.lng) : const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng);
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
          minZoom: 3.0,
          maxZoom: 19.0,
          cameraConstraint: const CameraConstraint.containLatitude(),
        initialCenter: center,
        initialZoom: _start != null ? 11 : 5,
        onMapReady: _fit,
        onLongPress: (_, p) => _addStopAt(p),
      ),
      children: [
        appTileLayer(),
        if (line.length >= 2) PolylineLayer(polylines: [Polyline(points: line, strokeWidth: 6, color: AppTheme.brand)]),
        // Map places along the planned route and on screen (zoom 12+), from the phone's cache first.
        if (_placesService() case final places?) MapPlacesLayer(service: places, routeLine: _route?.points, browse: true),
        // Round 4 (feature 9): "Where riders stop" (learned, k-anonymous rider stops along the route).
        if (_route != null && SafetyService.hasInstance)
          MarkerLayer(markers: [
            for (final st in SafetyService.instance.intel.learnedStops.take(60))
              Marker(
                point: LatLng(st.lat, st.lng),
                width: 26,
                height: 26,
                child: Semantics(
                  label: 'Where riders stop${st.name.isEmpty ? '' : ': ${st.name}'}',
                  child: Container(
                    decoration: BoxDecoration(color: AppTheme.card, shape: BoxShape.circle, border: Border.all(color: AppTheme.accent, width: 2)),
                    child: Icon(st.fuel ? Icons.local_gas_station_rounded : Icons.coffee_rounded, size: 14, color: AppTheme.accent),
                  ),
                ),
              ),
          ]),
        MarkerLayer(markers: [
          if (_start != null)
            Marker(
              point: LatLng(_start!.lat, _start!.lng),
              width: 32,
              height: 32,
              child: Semantics(label: 'Start: ${_start!.name}', child: _RouteDot(ring: AppTheme.brand, size: 22)),
            ),
          for (var i = 0; i < _stops.length; i++)
            Marker(
              point: LatLng(_stops[i].lat, _stops[i].lng),
              width: 32,
              height: 32,
              child: _StopMarker(index: i, place: _stops[i]),
            ),
          if (_destination != null)
            Marker(
              point: LatLng(_destination!.lat, _destination!.lng),
              width: 36,
              height: 36,
              child: Semantics(label: 'Destination: ${_destination!.name}', child: _RouteDot(ring: AppTheme.card, fill: AppTheme.brand, size: 24)),
            ),
        ]),
      ],
    );
  }

  /// The bottom sheet card (radius 28, handle): stats, the stop timeline,
  /// then "Add stop" and "Review".
  Widget _sheet({bool sideBySide = false}) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: sideBySide ? BorderRadius.zero : Radii.sheetTop,
        boxShadow: dsFloatingShadow(),
      ),
      child: SafeArea(
        top: sideBySide,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!sideBySide)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(3)),
                ),
              ),
            Expanded(child: _form()),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: DsButton(
                      tone: DsButtonTone.outline,
                      icon: Icons.add_rounded,
                      fontSize: 15,
                      label: 'Add stop',
                      onPressed: _stops.length >= _maxStops || _launching || _isReviewing ? null : _addStop,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DsButton(
                      icon: (_launching || _isReviewing) ? Icons.hourglass_top_rounded : Icons.fact_check_rounded,
                      fontSize: 15,
                      label: _launching
                          ? (_loadingMessage ?? 'Creating your trip...')
                          : (_isReviewing
                              ? (_loadingMessage ?? 'Checking trip details...')
                              : 'Review'),
                      onPressed: (_launching || _isReviewing) ? null : _review,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form() {
    final r = _route;
    final legs = r?.legs ?? const <RouteLeg>[];
    final recent = _destination == null
        ? _recent.where((p) => _start == null || p.name != _start!.name).take(3).toList()
        : const <PickedPlace>[];
    final startName = _start?.name;
    final destinationName = _destination?.name;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        TextField(
          controller: _name,
          focusNode: _nameFocus,
          style: AppText.body,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_nameError != null) setState(() => _nameError = null);
          },
          decoration: InputDecoration(
            labelText: 'Trip name',
            hintText: 'For example: Sunday ride to Srisailam',
            errorText: _nameError,
            prefixIcon: Icon(Icons.edit_rounded, color: AppTheme.accentText),
          ),
        ),
        if (r != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: DsStatCell(label: 'Distance', value: formatDistance(r.distanceM))),
              const SizedBox(width: 10),
              Expanded(child: DsStatCell(label: r.etaFromRiders ? 'Time (riders)' : 'Time', value: formatDuration(Duration(seconds: r.durationS)))),
              const SizedBox(width: 10),
              Expanded(child: DsStatCell(label: 'Stops', value: '${_stops.length}')),
            ],
          ),
          if (r.approximate)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Straight-line estimate: the road route is not available right now.', style: AppText.caption),
            ),
          // Round 4 (feature 10): the time comes from how fast riders really ride these roads.
          if (r.etaFromRiders)
            Padding(
              key: const ValueKey('planner_eta_riders'),
              padding: const EdgeInsets.only(top: 8),
              child: Text('ETA based on riders', style: AppText.caption),
            ),
          // Round 4 (feature 9): long stretches without known fuel.
          for (final g in _fuelGaps(r).take(2))
            Padding(
              key: ValueKey('planner_fuel_gap_${g.fromKm.round()}'),
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.local_gas_station_rounded, size: 18, color: AppTheme.warning),
                  const SizedBox(width: 6),
                  Expanded(child: Text(g.text, style: AppText.caption.copyWith(color: AppTheme.text, fontWeight: FontWeight.w600))),
                ],
              ),
            ),
        ],
        const SizedBox(height: 16),
        _TimelineRow(
          ring: AppTheme.accentText,
          title: startName != null && startName.isNotEmpty ? startName : 'Finding your location',
          titleColor: startName != null && startName.isNotEmpty ? null : AppTheme.accentText,
          subtitle: 'Start',
          onTap: _pickStart,
          trailing: Icon(Icons.edit_location_alt_outlined, size: 22, color: AppTheme.muted),
          semanticsLabel: 'Start: ${startName ?? 'not set'}. Pick on the map',
        ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _stops.length,
          onReorder: (from, to) {
            setState(() {
              final s = _stops.removeAt(from);
              _stops.insert(to > from ? to - 1 : to, s);
            });
            _scheduleRouteRefresh();
          },
          itemBuilder: (_, i) {
            final s = _stops[i];
            final leg = i < legs.length ? legs[i] : null;
            final kind = StopKind.fromCategory(s.category);
            final detail = [
              if (leg != null) '${formatDistance(leg.distanceM)} · ${formatDuration(Duration(seconds: leg.durationS))} from previous',
              if (s.plannedDwellMin > 0) 'stay ${s.plannedDwellMin} min',
            ].join(' · ');
            return _TimelineRow(
              key: ObjectKey(s),
              ring: AppTheme.warnText,
              title: s.name.isEmpty ? kind.label : s.name,
              subtitle: detail.isEmpty ? 'Stop ${i + 1}' : detail,
              chip: DsChip(stopKindChoiceLabel(kind), warning: true),
              onTap: () => _editStop(i),
              semanticsLabel: 'Stop ${i + 1}, ${stopKindChoiceLabel(kind)}: ${s.name}. Edit',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Remove stop',
                  icon: Icon(Icons.close_rounded, color: AppTheme.muted),
                  onPressed: () => _removeStop(i),
                ),
                ReorderableDragStartListener(
                  index: i,
                  child: Semantics(
                    label: 'Drag to reorder ${s.name}',
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.drag_handle_rounded, color: AppTheme.muted),
                    ),
                  ),
                ),
              ]),
            );
          },
        ),
        _TimelineRow(
          ring: AppTheme.accentText,
          fill: AppTheme.brand,
          last: true,
          title: destinationName != null && destinationName.isNotEmpty ? destinationName : 'Choose on the map',
          titleColor: destinationName != null && destinationName.isNotEmpty ? null : AppTheme.accentText,
          subtitle: r != null ? 'Destination · ${formatDistance(r.distanceM)}' : 'Destination',
          onTap: _pickDestination,
          trailing: Icon(Icons.edit_location_alt_outlined, size: 22, color: AppTheme.muted),
          semanticsLabel: 'Destination: ${destinationName ?? 'not set'}. Pick on the map',
        ),
        if (recent.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [
                for (final p in recent)
                  ActionChip(
                    avatar: Icon(Icons.history_rounded, size: 18, color: AppTheme.accentText),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    labelStyle: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w700),
                    tooltip: 'Ride to ${p.name}',
                    backgroundColor: AppTheme.card,
                    side: BorderSide(color: AppTheme.border, width: 2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onPressed: () => _setDestination(p),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Text('Stops are optional. Long-press the map to add one there.', style: AppText.caption),
      ],
    );
  }
}

/// 18 px timeline dot: a 4 px ring on the card, or [fill]ed solid.
class _RouteDot extends StatelessWidget {
  final Color ring;
  final Color? fill;
  final double size;
  const _RouteDot({required this.ring, this.fill, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fill ?? AppTheme.card,
          border: Border.all(color: ring, width: 4),
        ),
      ),
    );
  }
}

/// One entry of the vertical route timeline: ring dot and a 3 px rail on
/// the left, name 15/800 and detail 13/600, optional chip and trailing.
class _TimelineRow extends StatelessWidget {
  final Color ring;
  final Color? fill;
  final String title;
  final Color? titleColor;
  final String subtitle;
  final Widget? chip;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool last;
  final String? semanticsLabel;

  const _TimelineRow({
    super.key,
    required this.ring,
    this.fill,
    required this.title,
    this.titleColor,
    required this.subtitle,
    this.chip,
    this.trailing,
    this.onTap,
    this.last = false,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = chip;
    final t = trailing;
    final body = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _RouteDot(ring: ring, fill: fill),
                ),
                if (!last) Expanded(child: Center(child: Container(width: 3, color: AppTheme.border2))),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(0, 10, 0, last ? 10 : 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: titleColor ?? AppTheme.text, fontSize: 15, fontWeight: FontWeight.w600, height: 1.25),
                        ),
                      ),
                      if (c != null) ...[const SizedBox(width: 8), c],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label),
                ],
              ),
            ),
          ),
          if (t != null) Center(child: t),
        ],
      ),
    );
    final tappable = onTap == null
        ? body
        : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(12), child: body);
    if (semanticsLabel == null) return tappable;
    return Semantics(label: semanticsLabel, button: onTap != null, child: tappable);
  }
}

/// A planned stop on the planner map: its type icon in an amber ring.
class _StopMarker extends StatelessWidget {
  final int index;
  final PickedPlace place;

  const _StopMarker({required this.index, required this.place});

  @override
  Widget build(BuildContext context) {
    final kind = StopKind.fromCategory(place.category);
    return Semantics(
      label: 'Stop ${index + 1}, ${stopKindChoiceLabel(kind)}: ${place.name}',
      excludeSemantics: true,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(color: AppTheme.card, shape: BoxShape.circle, border: Border.all(color: AppTheme.warnText, width: 3)),
        child: Icon(kind.icon, size: 16, color: AppTheme.warnText),
      ),
    );
  }
}

/// Opened by a long-press on the planner map: the place name (looked up,
/// editable), the stop type, then [Add stop]. Returns a [PickedPlace].
class _AddStopSheet extends StatefulWidget {
  final GeoService geo;
  final LatLng point;

  const _AddStopSheet({required this.geo, required this.point});

  @override
  State<_AddStopSheet> createState() => _AddStopSheetState();
}

class _AddStopSheetState extends State<_AddStopSheet> {
  final TextEditingController _name = TextEditingController();
  bool _naming = true;
  bool _edited = false;
  StopKind? _kind;

  @override
  void initState() {
    super.initState();
    _lookUpName();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _lookUpName() async {
    final n = await widget.geo.reverse(widget.point.latitude, widget.point.longitude);
    if (!mounted) return;
    setState(() {
      _naming = false;
      if (!_edited && n != null) _name.text = n;
    });
  }

  void _add() {
    final kind = _kind;
    if (kind == null) return;
    final typed = _name.text.trim();
    final p = widget.point;
    if (!mounted) return;
    Navigator.pop(
      context,
      PickedPlace(
        lat: p.latitude,
        lng: p.longitude,
        name: typed.isNotEmpty ? typed : stopKindChoiceLabel(kind),
        category: stopWireCode(kind),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            onChanged: (_) => _edited = true,
            style: AppText.body,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: _naming ? 'Finding the place name' : 'Name this stop',
              suffixIcon: _naming
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.muted)),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 18),
          const DsSectionHeader('What kind of stop?'),
          const SizedBox(height: 10),
          StopKindChoices(selected: _kind, onSelected: (k) => setState(() => _kind = k)),
          const SizedBox(height: 18),
          DsButton(
            icon: Icons.add_location_alt_rounded,
            label: 'Add stop',
            onPressed: _kind == null ? null : _add,
          ),
        ],
      ),
    );
  }
}
