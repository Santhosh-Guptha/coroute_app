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
import '../../data/models/route_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/geo_service.dart';
import '../map_picker/map_picker_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../widgets/pre_ride_checklist_sheet.dart';
import 'trip_review_sheet.dart';

/// Plan a ride on one screen, map first: name, start, destination, stops
/// (picked on the map or by long-pressing it), then Review and Start Ride.
/// The live route preview runs through every stop.
///
/// After the ride is created the planner returns to the root route; the
/// home shell sees the new active ride and switches to the Ride tab.
class TripPlannerScreen extends StatefulWidget {
  const TripPlannerScreen({super.key});

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
  bool _routing = false;
  bool _launching = false;
  String? _nameError;
  int _speedLimit = 0;
  int _routeRequest = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _useCurrentLocationAsStart());
    RecentPlaces.load().then((r) {
      if (mounted) setState(() => _recent = r);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
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
    final wp = _waypoints;
    final req = ++_routeRequest;
    if (wp.length < 2) {
      setState(() {
        _route = null;
        _routing = false;
      });
      return;
    }
    setState(() => _routing = true);
    final r = await _geo.route(wp);
    if (!mounted || req != _routeRequest) return;
    setState(() {
      _route = r;
      _routing = false;
    });
    _fit();
  }

  void _fit() {
    final pts = <LatLng>[
      for (final (lat, lng) in _route?.points ?? _waypoints) LatLng(lat, lng),
    ];
    if (pts.length < 2) return;
    try {
      _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(36)));
    } catch (_) {}
  }

  Future<void> _pickStart() async {
    final p = await MapPickerScreen.pick(context, title: 'Start', initial: _start);
    if (p == null) return;
    setState(() => _start = p);
    _refreshRoute();
  }

  Future<void> _pickDestination() async {
    final p = await MapPickerScreen.pick(context, title: 'Destination', initial: _destination);
    if (p == null) return;
    _setDestination(p);
  }

  void _setDestination(PickedPlace p) {
    setState(() => _destination = p);
    _refreshRoute();
  }

  Future<void> _addStop() async {
    final near = _stops.isNotEmpty ? _stops.last : (_start ?? _destination);
    final p = await MapPickerScreen.pick(context, title: 'Add a stop', forStop: true, confirmLabel: 'Add stop',
        initial: near == null ? null : PickedPlace(lat: near.lat, lng: near.lng));
    if (p == null) return;
    setState(() => _stops.add(p));
    _refreshRoute();
  }

  /// Long-press on the map: name the place, choose its type, add it.
  Future<void> _addStopAt(LatLng point) async {
    if (_launching) return;
    if (_stops.length >= _maxStops) {
      _snack('A trip can have up to $_maxStops stops.');
      return;
    }
    final p = await showAppSheet<PickedPlace>(
      context,
      title: 'Add a stop here',
      isScrollControlled: true,
      builder: (_) => _AddStopSheet(geo: _geo, point: point),
    );
    if (p == null || !mounted) return;
    setState(() => _stops.add(p));
    _refreshRoute();
  }

  Future<void> _editStop(int i) async {
    final p = await MapPickerScreen.pick(context, title: 'Edit stop', forStop: true, confirmLabel: 'Save stop', initial: _stops[i]);
    if (p == null) return;
    setState(() => _stops[i] = p);
    _refreshRoute();
  }

  void _removeStop(int i) {
    setState(() => _stops.removeAt(i));
    _refreshRoute();
  }

  Future<void> _review() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _nameError = 'Give the trip a name.');
      _nameFocus.requestFocus();
      return;
    }
    FocusScope.of(context).unfocus();
    final limit = await TripReviewSheet.show(
      context,
      name: name,
      startName: _start?.name,
      destinationName: _destination?.name,
      route: _route,
      stops: _stops.length,
      speedLimitKmh: _speedLimit,
    );
    if (limit == null || !mounted) return;
    setState(() => _speedLimit = limit);
    await _launch(name);
  }

  Future<void> _launch(String name) async {
    final auth = context.read<AuthService>();
    final convoys = context.read<ConvoyService>();
    if (!await PermissionsScreen.ensure(context)) return;
    if (!mounted) return;
    // Pre-ride checklist (never blocks; closing it without starting cancels the launch).
    if (!await PreRideChecklistSheet.show(context)) return;
    if (!mounted) return;
    setState(() => _launching = true);
    try {
      await convoys.createConvoy(
        name: name,
        creatorId: auth.currentUserId ?? '',
        creatorName: auth.currentUserName ?? 'Lead rider',
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
      if (mounted) setState(() => _launching = false);
      _snack(e is ApiException ? e.message : 'Could not start the ride. Check your connection.');
      return;
    }
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    // Back to the home shell; it switches to the Ride tab when the active ride appears.
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: const Text('Plan a ride')),
      body: LayoutBuilder(builder: (context, c) {
        final map = LoadingState(loading: _routing, child: _mapView());
        final form = _form();
        final sideBySide = c.maxWidth > c.maxHeight && c.maxWidth >= 560;
        if (sideBySide) {
          final formWidth = (c.maxWidth * 0.45).clamp(280.0, 420.0).toDouble();
          return Row(children: [SizedBox(width: formWidth, child: form), Expanded(child: map)]);
        }
        return Column(children: [SizedBox(height: c.maxHeight * 0.55, child: map), Expanded(child: form)]);
      }),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.s16, Space.s8, Space.s16, Space.s12),
          child: FilledButton.icon(
            onPressed: _launching ? null : _review,
            icon: _launching
                ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textSecondary))
                : const Icon(Icons.fact_check_rounded),
            label: Text(_launching ? 'Starting the ride' : 'Review', style: const TextStyle(fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
        ),
      ),
    );
  }

  Widget _mapView() {
    final line = <LatLng>[for (final (lat, lng) in _route?.points ?? const <(double, double)>[]) LatLng(lat, lng)];
    final center = _start != null ? LatLng(_start!.lat, _start!.lng) : const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng);
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: center,
        initialZoom: _start != null ? 11 : 5,
        onMapReady: _fit,
        onLongPress: (_, p) => _addStopAt(p),
      ),
      children: [
        TileLayer(tileBuilder: mapTileBuilder, urlTemplate: AppConstants.osmTileUrl, userAgentPackageName: AppConstants.osmUserAgent),
        if (line.length >= 2) PolylineLayer(polylines: [Polyline(points: line, strokeWidth: 5, color: AppTheme.neonCyan)]),
        MarkerLayer(markers: [
          if (_start != null)
            Marker(
              point: LatLng(_start!.lat, _start!.lng),
              width: 32,
              height: 32,
              child: Semantics(label: 'Start: ${_start!.name}', child: Icon(Icons.trip_origin_rounded, color: AppTheme.emeraldSafe, size: 24)),
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
              child: Semantics(label: 'Destination: ${_destination!.name}', child: Icon(Icons.sports_score_rounded, color: AppTheme.laserRed, size: 30)),
            ),
        ]),
      ],
    );
  }

  Widget _form() {
    final legs = _route?.legs ?? const <RouteLeg>[];
    final recent = _destination == null
        ? _recent.where((p) => _start == null || p.name != _start!.name).take(3).toList()
        : const <PickedPlace>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s16),
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
            prefixIcon: const Icon(Icons.edit_rounded),
          ),
        ),
        const SizedBox(height: Space.s8),
        _PlaceRow(
          icon: Icons.trip_origin_rounded,
          color: AppTheme.emeraldSafe,
          label: 'Start',
          value: _start?.name,
          empty: 'Finding your location',
          onTap: _pickStart,
        ),
        _PlaceRow(
          icon: Icons.sports_score_rounded,
          color: AppTheme.laserRed,
          label: 'Destination',
          value: _destination?.name,
          empty: 'Choose on the map',
          onTap: _pickDestination,
        ),
        if (recent.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: Space.s4, bottom: Space.s8),
            child: Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [
                for (final p in recent)
                  ActionChip(
                    avatar: Icon(Icons.history_rounded, size: 18, color: AppTheme.textSecondary),
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    labelStyle: AppText.label.copyWith(color: AppTheme.textPrimary),
                    tooltip: 'Ride to ${p.name}',
                    backgroundColor: AppTheme.slateCard,
                    side: BorderSide(color: AppTheme.subtleBorder),
                    shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onPressed: () => _setDestination(p),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Space.s8),
        Text('Stops', style: AppText.title),
        const SizedBox(height: Space.s4),
        Text('Optional. Long-press the map to add one there.', style: AppText.caption),
        const SizedBox(height: Space.s8),
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
            _refreshRoute();
          },
          itemBuilder: (_, i) {
            final s = _stops[i];
            final leg = i < legs.length ? legs[i] : null;
            final detail = [
              if (leg != null) '${formatDistance(leg.distanceM)}, ${formatDuration(Duration(seconds: leg.durationS))} from previous',
              if (s.plannedDwellMin > 0) 'stay ${s.plannedDwellMin} min',
            ].join(', ');
            return Padding(
              key: ObjectKey(s),
              padding: const EdgeInsets.only(bottom: Space.s8),
              child: StopCard(
                kind: StopKind.fromCategory(s.category),
                name: s.name,
                subtitle: detail,
                onTap: () => _editStop(i),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Remove stop',
                    icon: Icon(Icons.close_rounded, color: AppTheme.textMuted),
                    onPressed: () => _removeStop(i),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: Semantics(
                      label: 'Drag to reorder ${s.name}',
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.drag_handle_rounded, color: AppTheme.textSecondary),
                      ),
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _stops.length >= _maxStops ? null : _addStop,
            icon: const Icon(Icons.add_location_alt_rounded),
            label: const Text('Add a stop'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
        ),
      ],
    );
  }
}

/// Start or destination row: icon, small label, place name, tap to pick on the map.
class _PlaceRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String? value;
  final String empty;
  final VoidCallback onTap;

  const _PlaceRow({required this.icon, required this.color, required this.label, required this.value, required this.empty, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final v = value;
    final has = v != null && v.isNotEmpty;
    final text = v != null && v.isNotEmpty ? v : empty;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.s4),
      leading: Icon(icon, color: color),
      title: Text(label, style: AppText.caption),
      subtitle: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(color: has ? AppTheme.textPrimary : AppTheme.neonCyan),
      ),
      trailing: Icon(Icons.edit_location_alt_rounded, color: AppTheme.textSecondary),
      onTap: onTap,
    );
  }
}

/// A planned stop on the planner map: its type icon in an amber circle.
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
        decoration: BoxDecoration(color: AppTheme.hyperAmber, shape: BoxShape.circle, border: Border.all(color: Colors.black, width: 1.5)),
        child: Icon(kind.icon, size: 18, color: Colors.black),
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
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textMuted)),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: Space.s16),
          Text('What kind of stop?', style: AppText.label),
          const SizedBox(height: Space.s8),
          StopKindChoices(selected: _kind, onSelected: (k) => setState(() => _kind = k)),
          const SizedBox(height: Space.s16),
          FilledButton.icon(
            onPressed: _kind == null ? null : _add,
            icon: const Icon(Icons.add_location_alt_rounded),
            label: const Text('Add stop', style: TextStyle(fontWeight: FontWeight.w700)),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
        ],
      ),
    );
  }
}
