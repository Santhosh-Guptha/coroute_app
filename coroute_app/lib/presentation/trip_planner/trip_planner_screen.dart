import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/route_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/geo_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../map_picker/map_picker_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../rider/convoy_dashboard_screen.dart';
import '../widgets/pre_ride_checklist_sheet.dart';
import '../../core/theme/map_tiles.dart';

/// Plan a trip before starting it: name, start, destination and any number
/// of stops, all picked on the map, with a live route preview through every
/// stop (distance and time per leg).
class TripPlannerScreen extends StatefulWidget {
  const TripPlannerScreen({super.key});

  @override
  State<TripPlannerScreen> createState() => _TripPlannerScreenState();
}

class _TripPlannerScreenState extends State<TripPlannerScreen> {
  static const _categoryIcons = {
    'FUEL': Icons.local_gas_station_rounded,
    'FOOD': Icons.restaurant_rounded,
    'REST': Icons.airline_seat_recline_normal_rounded,
    'SCENIC': Icons.landscape_rounded,
    'TOLL': Icons.toll_rounded,
    'OTHER': Icons.place_rounded,
  };

  final _name = TextEditingController();
  late final GeoService _geo = GeoService(context.read<ApiClient>());
  final MapController _map = MapController();
  PickedPlace? _start;
  PickedPlace? _destination;
  final List<PickedPlace> _stops = [];
  RouteModel? _route;
  bool _routing = false;
  bool _launching = false;
  int _speedLimit = 0;
  int _routeRequest = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _useCurrentLocationAsStart());
  }

  @override
  void dispose() {
    _name.dispose();
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
      final name = await _geo.reverse(p.latitude, p.longitude);
      if (mounted && name != null && _start?.name == 'My location') setState(() => _start = _start!.copyWith(name: name));
      _refreshRoute();
    } catch (_) {}
  }

  List<(double, double)> get _waypoints => [
        if (_start != null) (_start!.lat, _start!.lng),
        for (final s in _stops) (s.lat, s.lng),
        if (_destination != null) (_destination!.lat, _destination!.lng),
      ];

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

  Future<void> _editStop(int i) async {
    final p = await MapPickerScreen.pick(context, title: 'Edit stop', forStop: true, confirmLabel: 'Save stop', initial: _stops[i]);
    if (p == null) return;
    setState(() => _stops[i] = p);
    _refreshRoute();
  }

  Future<void> _launch() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      _snack('Give the trip a name.');
      return;
    }
    final auth = context.read<AuthService>();
    final convoys = context.read<ConvoyService>();
    if (!await PermissionsScreen.ensure(context)) return;
    if (!mounted) return;
    // Pre-ride checklist (never blocks; closing it without starting cancels the launch).
    if (!await PreRideChecklistSheet.show(context)) return;
    if (!mounted) return;
    setState(() => _launching = true);
    final ConvoyModel convoy;
    try {
      convoy = await convoys.createConvoy(
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
      _snack(e is ApiException ? e.message : 'Could not create the convoy. Check your connection.');
      return;
    }
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ConvoyDashboardScreen(groupId: convoy.groupId)));
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: const Text('Plan a trip')),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth > 760;
        final map = _mapView();
        final form = _form();
        if (wide) return Row(children: [SizedBox(width: 420, child: form), Expanded(child: map)]);
        return Column(children: [SizedBox(height: c.maxHeight * 0.34, child: map), Expanded(child: form)]);
      }),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ElevatedButton.icon(
            onPressed: _launching ? null : _launch,
            icon: _launching
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Start convoy', style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(50)),
          ),
        ),
      ),
    );
  }

  Widget _mapView() {
    final line = <LatLng>[for (final (lat, lng) in _route?.points ?? const <(double, double)>[]) LatLng(lat, lng)];
    final center = _start != null ? LatLng(_start!.lat, _start!.lng) : const LatLng(17.385, 78.4867);
    return FlutterMap(
      mapController: _map,
      options: MapOptions(initialCenter: center, initialZoom: 11, onMapReady: _fit),
      children: [
        TileLayer(tileBuilder: mapTileBuilder, urlTemplate: AppConstants.osmTileUrl, userAgentPackageName: AppConstants.osmUserAgent),
        if (line.length >= 2) PolylineLayer(polylines: [Polyline(points: line, strokeWidth: 5, color: AppTheme.neonCyan)]),
        MarkerLayer(markers: [
          if (_start != null)
            Marker(point: LatLng(_start!.lat, _start!.lng), width: 30, height: 30, child: Icon(Icons.trip_origin_rounded, color: AppTheme.emeraldSafe, size: 24)),
          for (var i = 0; i < _stops.length; i++)
            Marker(
              point: LatLng(_stops[i].lat, _stops[i].lng),
              width: 28,
              height: 28,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(color: AppTheme.hyperAmber, shape: BoxShape.circle, border: Border.all(color: Colors.black, width: 1.5)),
                child: Text('${i + 1}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          if (_destination != null)
            Marker(point: LatLng(_destination!.lat, _destination!.lng), width: 34, height: 34, child: Icon(Icons.sports_score_rounded, color: AppTheme.laserRed, size: 30)),
        ]),
      ],
    );
  }

  Widget _placeTile({required IconData icon, required Color color, required String label, required PickedPlace? place, required VoidCallback onTap, String empty = 'Choose on map'}) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
      subtitle: Text(place?.name ?? empty, style: TextStyle(color: place == null ? AppTheme.neonCyan : AppTheme.textPrimary, fontSize: 15)),
      trailing: Icon(Icons.edit_location_alt_rounded, color: AppTheme.textSecondary),
      onTap: onTap,
    );
  }

  Widget _form() {
    final r = _route;
    final legs = r?.legs ?? const <RouteLeg>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        TextField(
          controller: _name,
          style: TextStyle(color: AppTheme.textPrimary),
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'Trip name', hintText: 'e.g. Sunday ride to Srisailam', prefixIcon: Icon(Icons.flag_rounded)),
        ),
        const SizedBox(height: 8),
        _placeTile(icon: Icons.trip_origin_rounded, color: AppTheme.emeraldSafe, label: 'START', place: _start, onTap: _pickStart, empty: 'Finding your location...'),
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
            return ListTile(
              key: ValueKey('stop_${i}_${s.lat}_${s.lng}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: CircleAvatar(radius: 13, backgroundColor: AppTheme.hyperAmber, child: Text('${i + 1}', style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold))),
              title: Row(children: [
                Icon(_categoryIcons[s.category] ?? Icons.place_rounded, size: 16, color: AppTheme.textSecondary),
                const SizedBox(width: 6),
                Expanded(child: Text(s.name, style: TextStyle(color: AppTheme.textPrimary, fontSize: 14), overflow: TextOverflow.ellipsis)),
              ]),
              subtitle: Text(
                [
                  if (leg != null) '${TimelineText.distance(leg.distanceM)}, ${TimelineText.duration(Duration(seconds: leg.durationS))} from previous',
                  if (s.plannedDwellMin > 0) 'stay ${s.plannedDwellMin} min',
                ].join(' · '),
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
              onTap: () => _editStop(i),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                  tooltip: 'Remove stop',
                  icon: Icon(Icons.close_rounded, color: AppTheme.textMuted, size: 20),
                  onPressed: () {
                    setState(() => _stops.removeAt(i));
                    _refreshRoute();
                  },
                ),
                ReorderableDragStartListener(index: i, child: Icon(Icons.drag_handle_rounded, color: AppTheme.textSecondary)),
              ]),
            );
          },
        ),
        TextButton.icon(
          onPressed: _stops.length >= 20 ? null : _addStop,
          icon: const Icon(Icons.add_location_alt_rounded),
          label: const Text('Add a stop'),
          style: TextButton.styleFrom(foregroundColor: AppTheme.hyperAmber, alignment: Alignment.centerLeft),
        ),
        _placeTile(icon: Icons.sports_score_rounded, color: AppTheme.laserRed, label: 'DESTINATION', place: _destination, onTap: _pickDestination),
        const SizedBox(height: 10),
        if (_routing)
          Row(children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan)),
            SizedBox(width: 8),
            Text('Working out the route...', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ])
        else if (r != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppTheme.emeraldSafe.withOpacity(0.10), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.emeraldSafe.withOpacity(0.35))),
            child: Row(children: [
              Icon(Icons.directions_rounded, color: AppTheme.emeraldSafe),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${TimelineText.distance(r.distanceM)} · about ${TimelineText.duration(Duration(seconds: r.durationS))} riding'
                  '${_stops.isEmpty ? '' : ' · ${_stops.length} stop${_stops.length == 1 ? '' : 's'}'}',
                  style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          )
        else if (_waypoints.length >= 2)
          Text('Route preview is not available right now. The trip can still start; the route is worked out on the server.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12))
        else
          Text('Pick a destination to see the route. Stops are optional and can be added during the ride too.',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
        const SizedBox(height: 16),
        Row(children: [
          Icon(Icons.speed_rounded, size: 18, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text('Group speed limit', style: TextStyle(color: AppTheme.textPrimary, fontSize: 14, fontWeight: FontWeight.w600))),
          Text(_speedLimit > 0 ? '$_speedLimit km/h' : 'Off', style: TextStyle(color: AppTheme.speedWarning, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final v in AppConstants.speedLimitChoices)
            ChoiceChip(
              label: Text(v == 0 ? 'Off' : '$v'),
              selected: _speedLimit == v,
              onSelected: (_) => setState(() => _speedLimit = v),
              selectedColor: AppTheme.speedWarning.withOpacity(0.2),
              labelStyle: TextStyle(color: _speedLimit == v ? AppTheme.speedWarning : AppTheme.textSecondary, fontSize: 12),
              backgroundColor: AppTheme.slateCard,
              side: BorderSide(color: AppTheme.subtleBorder),
              showCheckmark: false,
            ),
        ]),
        const SizedBox(height: 4),
        Text('Riding over it for 10 seconds is logged and the group is told once. You can change it during the ride.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12)),
      ],
    );
  }
}
