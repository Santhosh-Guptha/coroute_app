import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/geo_service.dart';

/// The stop category code sent to the gateway for a [StopKind].
///
/// Same as [StopKind.category], except that a meeting point is stored as
/// MEETING (the gateway accepts it since 3.12; older gateways fall back to
/// OTHER on their own). Custom is OTHER.
String stopWireCode(StopKind kind) => kind == StopKind.meeting ? 'MEETING' : kind.category;

/// Short label for the stop type choices: Fuel, Food, Rest, Meeting, Custom.
String stopKindChoiceLabel(StopKind kind) {
  switch (kind) {
    case StopKind.meeting:
      return 'Meeting';
    case StopKind.custom:
      return 'Custom';
    case StopKind.fuel:
    case StopKind.food:
    case StopKind.rest:
    case StopKind.scenic:
    case StopKind.toll:
      return kind.label;
  }
}

/// The five stop types (Fuel, Food, Rest, Meeting, Custom) as a wrapping
/// row of choice chips. No horizontal scrolling. [selected] may be null
/// (nothing chosen yet, or a legacy type such as Scenic).
class StopKindChoices extends StatelessWidget {
  final StopKind? selected;
  final ValueChanged<StopKind> onSelected;

  const StopKindChoices({super.key, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Space.s8,
      runSpacing: Space.s8,
      children: [
        for (final k in StopKind.pickable)
          ChoiceChip(
            avatar: Icon(k.icon, size: 18, color: selected == k ? Colors.black : AppTheme.textSecondary),
            label: Text(stopKindChoiceLabel(k)),
            selected: selected == k,
            onSelected: (_) => onSelected(k),
            selectedColor: AppTheme.neonCyan,
            backgroundColor: AppTheme.slateCard,
            labelStyle: AppText.label.copyWith(color: selected == k ? Colors.black : AppTheme.textPrimary),
            side: BorderSide(color: selected == k ? AppTheme.neonCyan : AppTheme.subtleBorder),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
          ),
      ],
    );
  }
}

/// The last few places confirmed in the picker, kept on this phone only
/// (SharedPreferences, no network). Newest first.
class RecentPlaces {
  RecentPlaces._();

  static const String prefsKey = 'coroute_recent_places_v1';
  static const int max = 5;

  static Future<List<PickedPlace>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(prefsKey) ?? const <String>[];
      final out = <PickedPlace>[];
      for (final s in raw) {
        final m = jsonDecode(s);
        if (m is! Map) continue;
        final lat = m['lat'], lng = m['lng'];
        if (lat is! num || lng is! num) continue;
        out.add(PickedPlace(lat: lat.toDouble(), lng: lng.toDouble(), name: (m['name'] ?? '').toString()));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> remember(PickedPlace p) async {
    if (p.name.trim().isEmpty) return;
    try {
      final list = await load();
      bool same(PickedPlace o) =>
          o.name == p.name || ((o.lat - p.lat).abs() < 0.0005 && (o.lng - p.lng).abs() < 0.0005);
      final next = [p, ...list.where((o) => !same(o))].take(max);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(prefsKey, [
        for (final o in next) jsonEncode({'lat': o.lat, 'lng': o.lng, 'name': o.name}),
      ]);
    } catch (_) {}
  }
}

/// Pick a place on the map: move the map under the centre pin (or tap,
/// search, pick a recent place or use the current location), see the place
/// name, confirm. Used for the start, the destination and every stop.
/// Returns a [PickedPlace] or null. For stops, [PickedPlace.category] holds
/// the gateway code (FUEL, FOOD, REST, MEETING, OTHER; legacy SCENIC and
/// TOLL are kept when an old stop is edited).
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
  late final GeoService _geo = GeoService(context.read<ApiClient>());
  final MapController _map = MapController();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final TextEditingController _name = TextEditingController();
  Timer? _searchDebounce;
  Timer? _reverseDebounce;
  List<PlaceResult> _results = [];
  List<PickedPlace> _recent = const [];
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
    _center = i != null ? LatLng(i.lat, i.lng) : const LatLng(AppConstants.defaultMapLat, AppConstants.defaultMapLng);
    if (i != null) {
      _name.text = i.name;
      _category = i.category;
      _dwell = i.plannedDwellMin;
      _nameEdited = i.name.isNotEmpty;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goToMyLocation(quiet: true));
    }
    if (_name.text.isEmpty) _scheduleReverse();
    _searchFocus.addListener(_onFocusChanged);
    RecentPlaces.load().then((r) {
      if (mounted) setState(() => _recent = r);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _reverseDebounce?.cancel();
    _searchFocus.removeListener(_onFocusChanged);
    _searchFocus.dispose();
    _search.dispose();
    _name.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
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
      if (!mounted) return;
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
      if (!mounted) return;
      setState(() => _searching = true);
      final r = await _geo.search(q, nearLat: _center.latitude, nearLng: _center.longitude);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = r;
      });
    });
  }

  void _choose(LatLng p, String name) {
    FocusScope.of(context).unfocus();
    setState(() => _results = []);
    _moveTo(p, zoom: 15, name: name);
  }

  void _confirm() {
    final name = _name.text.trim();
    final place = PickedPlace(
      lat: _center.latitude,
      lng: _center.longitude,
      name: name.isNotEmpty ? name : '${_center.latitude.toStringAsFixed(4)}, ${_center.longitude.toStringAsFixed(4)}',
      category: _category,
      plannedDwellMin: _dwell,
    );
    unawaited(RecentPlaces.remember(place));
    Navigator.pop(context, place);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: LayoutBuilder(builder: (context, c) {
        return Column(
          children: [
            Expanded(child: _mapArea()),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: c.maxHeight * 0.6),
              child: _confirmPanel(),
            ),
          ],
        );
      }),
    );
  }

  Widget _mapArea() {
    final showRecent = _searchFocus.hasFocus && _search.text.isEmpty && _recent.isNotEmpty;
    return Stack(
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
        // Fixed centre pin: the map moves underneath it. The tip sits on the centre.
        IgnorePointer(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 44),
              child: Semantics(
                label: 'Pin. Move the map to place it.',
                child: Icon(Icons.location_on_rounded, size: 44, color: AppTheme.hyperAmber),
              ),
            ),
          ),
        ),
        Positioned(
          left: Space.s12,
          right: Space.s12,
          top: Space.s12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _searchField(),
              if (_results.isNotEmpty)
                _resultList([
                  for (final r in _results)
                    _ResultRow(
                      icon: Icons.place_rounded,
                      title: r.name,
                      subtitle: r.displayName,
                      onTap: () => _choose(LatLng(r.lat, r.lng), r.name),
                    ),
                ])
              else if (showRecent)
                _resultList([
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Space.s16, Space.s12, Space.s16, Space.s4),
                    child: Text('Recent', style: AppText.label),
                  ),
                  for (final p in _recent)
                    _ResultRow(
                      icon: Icons.history_rounded,
                      title: p.name,
                      onTap: () => _choose(LatLng(p.lat, p.lng), p.name),
                    ),
                ]),
            ],
          ),
        ),
        Positioned(
          right: Space.s12,
          bottom: Space.s12,
          child: MapControl(
            icon: Icons.my_location_rounded,
            tooltip: 'Use my location',
            onPressed: () => _goToMyLocation(),
          ),
        ),
      ],
    );
  }

  Widget _searchField() {
    return Material(
      color: AppTheme.slateCard,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
      clipBehavior: Clip.antiAlias,
      child: TextField(
        controller: _search,
        focusNode: _searchFocus,
        onChanged: (q) {
          _onSearchChanged(q);
          setState(() {});
        },
        style: AppText.body,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search a place, town or address',
          hintStyle: AppText.body.copyWith(color: AppTheme.textMuted),
          prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted),
          suffixIcon: _searching
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.neonCyan)),
                )
              : (_search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: Icon(Icons.close_rounded, color: AppTheme.textMuted),
                      onPressed: () => setState(() {
                        _search.clear();
                        _results = [];
                      }),
                    )),
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _resultList(List<Widget> rows) {
    return Container(
      margin: const EdgeInsets.only(top: Space.s8),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: Radii.mdAll, border: Border.all(color: AppTheme.subtleBorder)),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: rows),
      ),
    );
  }

  Widget _confirmPanel() {
    // A legacy type (Scenic, Toll) shows no chip selected and is kept unless one is tapped.
    final kind = StopKind.fromCategory(_category);
    final selected = StopKind.pickable.contains(kind) ? kind : null;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.slateCard,
        borderRadius: Radii.sheetTop,
        border: Border(top: BorderSide(color: AppTheme.subtleBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _name,
                      onChanged: (_) => _nameEdited = true,
                      style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        labelText: 'Name',
                        suffixIcon: _naming
                            ? Padding(
                                padding: const EdgeInsets.all(14),
                                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textMuted)),
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(height: Space.s4),
                    Text(
                      '${_center.latitude.toStringAsFixed(5)}, ${_center.longitude.toStringAsFixed(5)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption,
                    ),
                    if (widget.forStop) ...[
                      const SizedBox(height: Space.s12),
                      StopKindChoices(
                        selected: selected,
                        onSelected: (k) => setState(() => _category = stopWireCode(k)),
                      ),
                      const SizedBox(height: Space.s4),
                      Row(
                        children: [
                          Expanded(child: Text('Planned stay', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label)),
                          IconButton(
                            tooltip: 'Shorter stay',
                            onPressed: _dwell <= 0 ? null : () => setState(() => _dwell = (_dwell - 5).clamp(0, 600).toInt()),
                            icon: Icon(Icons.remove_circle_outline_rounded, color: AppTheme.textSecondary),
                          ),
                          Text(_dwell == 0 ? 'Not set' : '$_dwell min', style: AppText.body),
                          IconButton(
                            tooltip: 'Longer stay',
                            onPressed: () => setState(() => _dwell = (_dwell + 5).clamp(0, 600).toInt()),
                            icon: Icon(Icons.add_circle_outline_rounded, color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.s16, Space.s12, Space.s16, Space.s16),
              child: FilledButton(
                onPressed: _confirm,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                child: Text(widget.confirmLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One search result or recent place row.
class _ResultRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _ResultRow({required this.icon, required this.title, this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sub = subtitle;
    return ListTile(
      leading: Icon(icon, color: AppTheme.neonCyan),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
      subtitle: sub == null || sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
      onTap: onTap,
    );
  }
}
