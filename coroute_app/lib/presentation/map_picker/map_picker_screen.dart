import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../domain/geo/map_link_parser.dart';

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
            avatar: Icon(k.icon, size: 18, color: selected == k ? Colors.white : AppTheme.accentText),
            label: Text(stopKindChoiceLabel(k)),
            selected: selected == k,
            onSelected: (_) => onSelected(k),
            selectedColor: AppTheme.brand,
            backgroundColor: AppTheme.card,
            labelStyle: TextStyle(color: selected == k ? Colors.white : AppTheme.text, fontSize: 13, fontWeight: FontWeight.w600),
            side: BorderSide(color: selected == k ? AppTheme.brand : AppTheme.border, width: 2),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.padded,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  /// 3.56: text to put in the search box at once (a map link shared to CoRoute).
  final String? initialQuery;

  const MapPickerScreen({super.key, required this.title, this.initial, this.forStop = false, this.confirmLabel = 'Use this place', this.initialQuery});

  /// Opens the picker and returns the chosen place.
  static Future<PickedPlace?> pick(BuildContext context, {required String title, PickedPlace? initial, bool forStop = false, String confirmLabel = 'Use this place', String? initialQuery}) {
    return Navigator.push<PickedPlace>(
      context,
      MaterialPageRoute(builder: (_) => MapPickerScreen(title: title, initial: initial, forStop: forStop, confirmLabel: confirmLabel, initialQuery: initialQuery)),
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
  // 3.56 search states: every new text bumps [_searchSeq], so an older, slower answer is dropped.
  int _searchSeq = 0;
  String? _searchError;
  String _lastQuery = '';
  bool _searchedEverywhere = false;
  _PastedPlace? _pasted;
  bool _naming = false;
  bool _nameEdited = false;
  late LatLng _center;
  String _category = 'REST';
  int _dwell = 0;
  bool _isConfirming = false;

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
    final shared = widget.initialQuery?.trim();
    if (shared != null && shared.isNotEmpty) {
      _search.text = shared.length > 2000 ? shared.substring(0, 2000) : shared;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onSearchChanged(_search.text);
      });
    }
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

  static const Duration _searchDelay = Duration(milliseconds: 350);

  /// Every keystroke: a pasted map link or coordinates show a "Pasted location" row at
  /// once; text is searched 350 ms after the last key, and only the newest answer counts.
  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    final trimmed = q.trim();
    final link = MapLinkParser.parse(trimmed);
    setState(() {
      _searchError = null;
      _searchedEverywhere = false;
      _searching = false;
      _pasted = null;
    });

    if (link != null && link.hasPoint) {
      final p = _PastedPlace(lat: link.lat!, lng: link.lng!, name: link.name, precise: link.precise, naming: link.name == null);
      setState(() {
        _results = [];
        _pasted = p;
      });
      if (link.name == null) {
        _searchDebounce = Timer(_searchDelay, () async {
          final n = await _geo.reverse(p.lat, p.lng);
          if (!mounted || seq != _searchSeq) return;
          setState(() => _pasted = p.named(n));
        });
      }
      return;
    }
    if (link != null && link.needsExpansion) {
      setState(() {
        _results = [];
        _pasted = const _PastedPlace.resolving();
      });
      _searchDebounce = Timer(_searchDelay, () => _resolveLink(trimmed, seq));
      return;
    }
    // A link that only names a place (?q=Nandi+Hills): search for the name.
    final text = (link != null && link.query != null) ? link.query! : trimmed;
    if (text.length < 3) {
      setState(() => _results = []);
      return;
    }
    _searchDebounce = Timer(_searchDelay, () => _runSearch(text, seq));
  }

  Future<void> _runSearch(String text, int seq, {bool everywhere = false}) async {
    if (!mounted) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _lastQuery = text;
      _searchedEverywhere = everywhere;
    });
    final out = await _geo.searchPlaces(text, nearLat: _center.latitude, nearLng: _center.longitude, everywhere: everywhere);
    if (!mounted || seq != _searchSeq) return; // the rider typed on: a newer search owns the list
    setState(() {
      _searching = false;
      _results = out.results;
      _searchError = out.error;
    });
  }

  Future<void> _resolveLink(String text, int seq) async {
    if (!mounted) return;
    setState(() => _searching = true);
    final r = await _geo.resolveLink(text, nearLat: _center.latitude, nearLng: _center.longitude);
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _searching = false;
      final place = r.place;
      if (place != null) {
        final hasName = place.name.isNotEmpty && !RegExp(r'^-?\d+\.\d+, -?\d+\.\d+$').hasMatch(place.name);
        _pasted = _PastedPlace(lat: place.lat, lng: place.lng, name: hasName ? place.name : null, precise: r.precise, naming: false);
        _results = [];
      } else if (r.error != null) {
        _pasted = null;
        _searchError = r.error;
        _lastQuery = '';
      } else {
        _pasted = null;
        _lastQuery = r.query ?? '';
        _results = r.results;
      }
    });
  }

  /// Retry after an error: the same text again (a link is resolved again).
  void _retrySearch() {
    final text = _search.text;
    _onSearchChanged(text);
  }

  void _searchEverywhere() {
    if (_lastQuery.length < 3) return;
    _searchDebounce?.cancel();
    _runSearch(_lastQuery, ++_searchSeq, everywhere: true);
  }

  Future<void> _pasteCoordinates() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Clipboard is empty.')),
          );
        }
        return;
      }
      final clipped = text.length > 2000 ? text.substring(0, 2000) : text;
      _search.text = clipped;
      _search.selection = TextSelection.collapsed(offset: clipped.length);
      _onSearchChanged(clipped);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read clipboard.')),
        );
      }
    }
  }

  void _choose(LatLng p, String name) {
    FocusScope.of(context).unfocus();
    _searchDebounce?.cancel();
    _searchSeq++;
    setState(() {
      _results = [];
      _pasted = null;
      _searching = false;
      _searchError = null;
    });
    _moveTo(p, zoom: 15, name: name);
  }

  void _confirm() {
    if (_isConfirming || !mounted) return;
    _isConfirming = true;
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
      backgroundColor: AppTheme.map,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Center(
            child: DsRoundButton(
              icon: Icons.chevron_left_rounded,
              label: 'Back',
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
        leadingWidth: 60,
      ),
      body: LayoutBuilder(builder: (context, c) {
        return Column(
          children: [
            Expanded(child: _mapArea()),
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: c.maxHeight * 0.6,
                  maxWidth: c.maxWidth > 600 ? 680 : double.infinity,
                ),
                child: _confirmPanel(),
              ),
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
          minZoom: 3.0,
          maxZoom: 19.0,
          cameraConstraint: const CameraConstraint.containLatitude(),
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
            appTileLayer(),
          ],
        ),
        // Fixed centre pin: the map moves underneath it. The tip sits on the centre.
        IgnorePointer(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 44),
              child: Semantics(
                label: 'Pin. Move the map to place it.',
                child: Icon(Icons.location_on_rounded, size: 44, color: AppTheme.warnText),
              ),
            ),
          ),
        ),
        Positioned(
          left: Space.s12,
          right: Space.s12,
          top: Space.s12,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _searchField(),
                  if (_pasted != null || _results.isNotEmpty)
                    _resultList([
                      if (_pasted != null) _pastedRow(_pasted!),
                      for (final r in _results)
                        _ResultRow(
                          icon: Icons.place_rounded,
                          title: r.name,
                          subtitle: _resultSubtitle(r),
                          onTap: () => _choose(LatLng(r.lat, r.lng), r.name),
                        ),
                    ])
                  else if (_searchError != null && !_searching)
                    _resultList([
                      _MessageRow(
                        icon: Icons.cloud_off_rounded,
                        text: _searchError!,
                        actionLabel: 'Retry',
                        onAction: _retrySearch,
                      ),
                    ])
                  else if (_search.text.trim().length >= 3 && !_searching && _lastQuery.isNotEmpty && _searchDebounce?.isActive != true)
                    _resultList([
                      _MessageRow(
                        icon: Icons.search_off_rounded,
                        text: _searchedEverywhere
                            ? 'No matching places found. Try a town or landmark name, or paste a map link.'
                            : 'No matching places found in India. Try a town name, or search everywhere.',
                        actionLabel: _searchedEverywhere ? null : 'Search everywhere',
                        onAction: _searchedEverywhere ? null : _searchEverywhere,
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
    return Container(
      decoration: BoxDecoration(borderRadius: Radii.mdAll, boxShadow: dsFloatingShadow()),
      child: Material(
        color: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.border, width: 2)),
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
            hintText: 'Search a place, or paste a map link',
            hintStyle: AppText.body.copyWith(color: AppTheme.muted),
            prefixIcon: Icon(Icons.search_rounded, color: AppTheme.accentText),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Paste a map link, coordinates or text',
                  icon: Icon(Icons.content_paste_rounded, color: AppTheme.accentText, size: 20),
                  onPressed: _pasteCoordinates,
                ),
                if (_searching || _searchDebounce?.isActive == true && _search.text.trim().length >= 3)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accentText)),
                  )
                else if (_search.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear search',
                    icon: Icon(Icons.close_rounded, color: AppTheme.muted),
                    onPressed: () {
                      _searchDebounce?.cancel();
                      _searchSeq++;
                      setState(() {
                        _search.clear();
                        _results = [];
                        _pasted = null;
                        _searchError = null;
                        _lastQuery = '';
                      });
                    },
                  ),
              ],
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  String _resultSubtitle(PlaceResult r) {
    final d = placeDistanceLabel(r.distanceM);
    final parts = [if (r.displayName.isNotEmpty && r.displayName != r.name) r.displayName, if (d.isNotEmpty) '$d away'];
    return parts.join(' · ');
  }

  Widget _pastedRow(_PastedPlace p) {
    if (p.resolving) {
      return const _ResultRow(icon: Icons.link_rounded, title: 'Pasted link', subtitle: 'Opening the map link...', onTap: _noop);
    }
    final coords = '${p.lat.toStringAsFixed(5)}, ${p.lng.toStringAsFixed(5)}';
    final name = p.name;
    final subtitle = p.naming
        ? 'Finding the place name... · $coords'
        : [if (name != null && name.isNotEmpty) name, coords, if (!p.precise) 'map view centre, check the pin'].join(' · ');
    return _ResultRow(
      icon: Icons.push_pin_rounded,
      title: 'Pasted location',
      subtitle: subtitle,
      onTap: () => _choose(LatLng(p.lat, p.lng), (name != null && name.isNotEmpty) ? name : 'Location ($coords)'),
    );
  }

  static void _noop() {}

  Widget _resultList(List<Widget> rows) {
    return Container(
      margin: const EdgeInsets.only(top: Space.s8),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(color: AppTheme.card, borderRadius: Radii.mdAll, border: Border.all(color: AppTheme.border, width: 2), boxShadow: dsFloatingShadow()),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const BouncingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: rows,
        ),
      ),
    );
  }

  Widget _confirmPanel() {
    // A legacy type (Scenic, Toll) shows no chip selected and is kept unless one is tapped.
    final kind = StopKind.fromCategory(_category);
    final selected = StopKind.pickable.contains(kind) ? kind : null;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: Radii.sheetTop,
        boxShadow: dsFloatingShadow(),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10),
                width: 44,
                height: 5,
                decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, Space.s12, 20, 0),
                physics: const BouncingScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                                child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.muted)),
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
                      const SizedBox(height: Space.s16),
                      const DsSectionHeader('What kind of stop?'),
                      const SizedBox(height: 10),
                      StopKindChoices(
                        selected: selected,
                        onSelected: (k) => setState(() => _category = stopWireCode(k)),
                      ),
                      const SizedBox(height: Space.s8),
                      Row(
                        children: [
                          Expanded(child: Text('Planned stay', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
                          IconButton(
                            tooltip: 'Shorter stay',
                            onPressed: _dwell <= 0 ? null : () => setState(() => _dwell = (_dwell - 5).clamp(0, 600).toInt()),
                            icon: Icon(Icons.remove_circle_outline_rounded, color: _dwell <= 0 ? AppTheme.muted : AppTheme.accentText),
                          ),
                          Text(_dwell == 0 ? 'Not set' : '$_dwell min', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                          IconButton(
                            tooltip: 'Longer stay',
                            onPressed: () => setState(() => _dwell = (_dwell + 5).clamp(0, 600).toInt()),
                            icon: Icon(Icons.add_circle_outline_rounded, color: AppTheme.accentText),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, Space.s12, 20, Space.s16),
              child: DsButton(
                icon: Icons.check_rounded,
                label: widget.confirmLabel,
                onPressed: _confirm,
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
      leading: Icon(icon, color: AppTheme.accentText),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
      subtitle: sub == null || sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
      onTap: onTap,
    );
  }
}

/// The place read from a pasted map link or coordinates (shown above the results).
class _PastedPlace {
  final double lat;
  final double lng;
  final String? name;
  final bool precise;

  /// The name is being looked up (reverse geocoding).
  final bool naming;

  /// A short link is being opened by the gateway.
  final bool resolving;

  const _PastedPlace({required this.lat, required this.lng, this.name, this.precise = true, this.naming = false}) : resolving = false;
  const _PastedPlace.resolving()
      : lat = 0,
        lng = 0,
        name = null,
        precise = true,
        naming = false,
        resolving = true;

  _PastedPlace named(String? n) => _PastedPlace(lat: lat, lng: lng, name: n ?? name, precise: precise);
}

/// An empty or error state in the result list, with an optional action (Retry, Search everywhere).
class _MessageRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessageRow({required this.icon, required this.text, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.s16, Space.s12, Space.s8, Space.s12),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.muted, size: 20),
          const SizedBox(width: Space.s12),
          Expanded(child: Text(text, style: AppText.caption)),
          if (actionLabel != null && onAction != null) TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
