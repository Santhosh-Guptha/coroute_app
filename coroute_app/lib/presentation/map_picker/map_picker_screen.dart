import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/api_client.dart';
import '../../data/services/geo_service.dart';
import '../../core/theme/map_tiles.dart';

/// Pick a place on the map: move the map under the centre pin (or tap,
/// or search), see the place name, confirm. Used for the start, the
/// destination and every stop. Returns a [PickedPlace] or null.
class MapPickerScreen extends StatefulWidget {
  final String title;
  final PickedPlace? initial;
  final bool forStop;
  final String confirmLabel;

  const MapPickerScreen({super.key, required this.title, this.initial, this.forStop = false, this.confirmLabel = 'Use this place'});

  /// Opens the picker and returns the chosen place.
  static Future<PickedPlace?> pick(BuildContext context, {required String title, PickedPlace? initial, bool forStop = false, String confirmLabel = 'Use this place'}) {
    return Navigator.push<PickedPlace>(
      context,
      MaterialPageRoute(builder: (_) => MapPickerScreen(title: title, initial: initial, forStop: forStop, confirmLabel: confirmLabel)),
    );
  }

  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  static const _categories = [
    ('FUEL', 'Fuel', Icons.local_gas_station_rounded),
    ('FOOD', 'Food', Icons.restaurant_rounded),
    ('REST', 'Rest', Icons.airline_seat_recline_normal_rounded),
    ('SCENIC', 'Scenic', Icons.landscape_rounded),
    ('TOLL', 'Toll', Icons.toll_rounded),
    ('OTHER', 'Other', Icons.place_rounded),
  ];

  late final GeoService _geo = GeoService(context.read<ApiClient>());
  final MapController _map = MapController();
  final TextEditingController _search = TextEditingController();
  final TextEditingController _name = TextEditingController();
  Timer? _searchDebounce;
  Timer? _reverseDebounce;
  List<PlaceResult> _results = [];
  bool _searching = false;
  bool _naming = false;
  bool _nameEdited = false;
  late LatLng _center;
  String _category = 'REST';
  int _dwell = 0;

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    _center = i != null ? LatLng(i.lat, i.lng) : const LatLng(17.385, 78.4867);
    if (i != null) {
      _name.text = i.name;
      _category = i.category;
      _dwell = i.plannedDwellMin;
      _nameEdited = i.name.isNotEmpty;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goToMyLocation(quiet: true));
    }
    if (_name.text.isEmpty) _scheduleReverse();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _reverseDebounce?.cancel();
    _search.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _goToMyLocation({bool quiet = false}) async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final p = await Geolocator.getLastKnownPosition() ??
          await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 6)));
      if (!mounted) return;
      _moveTo(LatLng(p.latitude, p.longitude), zoom: 15);
    } catch (_) {
      if (!quiet && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not get your location.')));
    }
  }

  void _moveTo(LatLng p, {double? zoom, String? name}) {
    try {
      _map.move(p, zoom ?? _map.camera.zoom);
    } catch (_) {
      // Map not laid out yet; the centre below still applies.
    }
    setState(() {
      _center = p;
      if (name != null) {
        _name.text = name;
        _nameEdited = false;
      }
    });
    if (name == null) _scheduleReverse();
  }

  void _scheduleReverse() {
    _reverseDebounce?.cancel();
    _reverseDebounce = Timer(const Duration(milliseconds: 800), () async {
      final at = _center;
      setState(() => _naming = true);
      final n = await _geo.reverse(at.latitude, at.longitude);
      if (!mounted || at != _center) return;
      setState(() {
        _naming = false;
        if (!_nameEdited && n != null) _name.text = n;
      });
    });
  }

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    if (q.trim().length < 3) {
      setState(() => _results = []);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 600), () async {
      setState(() => _searching = true);
      final r = await _geo.search(q, nearLat: _center.latitude, nearLng: _center.longitude);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = r;
      });
    });
  }

  void _confirm() {
    final name = _name.text.trim();
    Navigator.pop(
      context,
      PickedPlace(
        lat: _center.latitude,
        lng: _center.longitude,
        name: name.isNotEmpty ? name : '${_center.latitude.toStringAsFixed(4)}, ${_center.longitude.toStringAsFixed(4)}',
        category: _category,
        plannedDwellMin: _dwell,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: widget.initial != null ? 15 : 12,
              onTap: (_, p) => _moveTo(p),
              onPositionChanged: (camera, hasGesture) {
                if (!hasGesture) return;
                setState(() => _center = camera.center);
                _scheduleReverse();
              },
            ),
            children: [
              TileLayer(tileBuilder: mapTileBuilder, urlTemplate: AppConstants.osmTileUrl, userAgentPackageName: AppConstants.osmUserAgent),
            ],
          ),
          // Fixed centre pin: the map moves underneath it.
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 40),
                child: Icon(Icons.location_on, size: 46, color: AppTheme.hyperAmber, shadows: [Shadow(blurRadius: 8, color: Colors.black54)]),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Column(
              children: [
                Material(
                  color: AppTheme.slateCard,
                  borderRadius: BorderRadius.circular(12),
                  elevation: 4,
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    style: TextStyle(color: AppTheme.textPrimary),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search a place, town or address',
                      hintStyle: TextStyle(color: AppTheme.textMuted),
                      prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted),
                      suffixIcon: _searching
                          ? Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan)))
                          : (_search.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: Icon(Icons.close_rounded, color: AppTheme.textMuted),
                                  onPressed: () => setState(() {
                                    _search.clear();
                                    _results = [];
                                  }),
                                )),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                if (_results.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    constraints: const BoxConstraints(maxHeight: 260),
                    decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.subtleBorder)),
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => Divider(height: 1, color: AppTheme.subtleBorder),
                      itemBuilder: (_, i) {
                        final r = _results[i];
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.place_outlined, color: AppTheme.neonCyan, size: 20),
                          title: Text(r.name, style: TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
                          subtitle: Text(r.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                          onTap: () {
                            FocusScope.of(context).unfocus();
                            setState(() => _results = []);
                            _moveTo(LatLng(r.lat, r.lng), zoom: 15, name: r.name);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            bottom: widget.forStop ? 262 : 196,
            child: FloatingActionButton.small(
              heroTag: 'picker_my_location',
              backgroundColor: AppTheme.slateCard,
              onPressed: () => _goToMyLocation(),
              tooltip: 'My location',
              child: Icon(Icons.my_location_rounded, color: AppTheme.neonCyan),
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, child: _confirmSheet()),
        ],
      ),
    );
  }

  Widget _confirmSheet() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.darkCanvas,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 12)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              onChanged: (_) => _nameEdited = true,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                labelText: 'Name',
                labelStyle: TextStyle(color: AppTheme.textMuted),
                suffixIcon: _naming ? Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textMuted))) : null,
              ),
            ),
            const SizedBox(height: 4),
            Text('${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
            if (widget.forStop) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final (id, label, icon) in _categories)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          avatar: Icon(icon, size: 16, color: _category == id ? Colors.black : AppTheme.textSecondary),
                          label: Text(label),
                          selected: _category == id,
                          onSelected: (_) => setState(() => _category = id),
                          selectedColor: AppTheme.neonCyan,
                          labelStyle: TextStyle(color: _category == id ? Colors.black : AppTheme.textSecondary, fontSize: 12),
                          backgroundColor: AppTheme.slateCard,
                          showCheckmark: false,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('Planned stay', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    onPressed: _dwell <= 0 ? null : () => setState(() => _dwell = (_dwell - 5).clamp(0, 600).toInt()),
                    icon: Icon(Icons.remove_circle_outline_rounded, color: AppTheme.textSecondary),
                  ),
                  Text(_dwell == 0 ? 'not set' : '$_dwell min', style: TextStyle(color: AppTheme.textPrimary)),
                  IconButton(
                    onPressed: () => setState(() => _dwell = (_dwell + 5).clamp(0, 600).toInt()),
                    icon: Icon(Icons.add_circle_outline_rounded, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _confirm,
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.neonCyan, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(48)),
              child: Text(widget.confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
