import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/map_places_service.dart';
import '../../domain/places/fuel_match.dart';
import '../../domain/places/place_poi.dart';
import '../../domain/places/poi_category.dart';
import '../../domain/places/poi_declutter.dart';
import '../../domain/tracking/geo_math.dart';
import 'place_card.dart';
import 'place_style.dart';

/// Map places as a flutter_map layer: icons from zoom 12, names from zoom 14,
/// nearest first, never overlapping, at most a few dozen at once. Tap opens the
/// place card. Also tells [service] where the rider and route are, so it can
/// load the corridor ahead (no work unless a new chunk is entered).
class MapPlacesLayer extends StatefulWidget {
  const MapPlacesLayer({
    super.key,
    required this.service,
    this.riderLat,
    this.riderLng,
    this.routeLine,
    this.groupFuelStops = const [],
    this.browse = false,
  });

  final MapPlacesService service;
  final double? riderLat, riderLng;
  final List<(double, double)>? routeLine;
  final List<({double lat, double lng, String name})> groupFuelStops;

  /// Trip planner: also load the cells on screen while the map is moved.
  final bool browse;

  @override
  State<MapPlacesLayer> createState() => _MapPlacesLayerState();
}

class _MapPlacesLayerState extends State<MapPlacesLayer> {
  String? _lastViewport;
  List<(double, double)>? _warmedFor;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_changed);
    _sync();
  }

  @override
  void didUpdateWidget(MapPlacesLayer old) {
    super.didUpdateWidget(old);
    if (old.service != widget.service) {
      old.service.removeListener(_changed);
      widget.service.addListener(_changed);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _sync() {
    final s = widget.service;
    s.setRoute(widget.routeLine);
    if (widget.browse && widget.routeLine != null && !identical(widget.routeLine, _warmedFor)) {
      _warmedFor = widget.routeLine;
      s.warmRouteStart();
    }
    s.setGroupFuelStops(widget.groupFuelStops);
    final la = widget.riderLat, ln = widget.riderLng;
    if (la != null && ln != null && !(la == 0 && ln == 0)) s.onPosition(la, ln);
  }

  void _browse(MapCamera camera) {
    if (!widget.browse || camera.zoom < PoiZoom.iconsFrom) return;
    final c = camera.center;
    final sig = '${camera.zoom.floor()}|${(c.latitude / 0.02).round()}|${(c.longitude / 0.02).round()}';
    if (sig == _lastViewport) return;
    _lastViewport = sig;
    final b = camera.visibleBounds;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.service.onViewport(s: b.south, w: b.west, n: b.north, e: b.east, zoom: camera.zoom);
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    _browse(camera);
    if (camera.zoom < PoiZoom.iconsFrom) return const SizedBox.shrink();
    final s = widget.service;
    final labels = camera.zoom >= PoiZoom.labelsFrom;
    final b = camera.visibleBounds;
    final refLat = widget.riderLat ?? camera.center.latitude, refLng = widget.riderLng ?? camera.center.longitude;
    final items = <DeclutterItem<PlacePoi>>[];
    for (final p in s.visible) {
      if (p.lat < b.south || p.lat > b.north || p.lng < b.west || p.lng > b.east) continue;
      final o = camera.latLngToScreenOffset(LatLng(p.lat, p.lng));
      final unknown = p.category == PoiCategory.fuel && fuelMatch(p, s.fuelType) == FuelMatch.unknown;
      items.add(DeclutterItem(
        value: p,
        x: o.dx,
        y: o.dy,
        distanceM: GeoMath.haversine(refLat, refLng, p.lat, p.lng),
        rank: p.category.rank + (unknown ? 3 : 0),
        pinned: p.isEmergencyHospital,
        labelWidth: labels && p.hasName ? estimateLabelWidth(p.name) : 0,
      ));
    }
    final placed = declutter(items, max: PoiZoom.maxVisible(camera.zoom), viewW: camera.nonRotatedSize.width, viewH: camera.nonRotatedSize.height);
    return MarkerLayer(
      rotate: true,
      markers: [for (final pl in placed.reversed) _marker(context, pl, s)],
    );
  }

  Marker _marker(BuildContext context, Placed<PlacePoi> pl, MapPlacesService s) {
    final p = pl.value;
    const icon = 26.0;
    final lw = pl.showLabel ? estimateLabelWidth(p.name) : 0.0;
    final w = icon + (lw > 0 ? 4 + lw : 0);
    final unknown = p.category == PoiCategory.fuel && fuelMatch(p, s.fuelType) == FuelMatch.unknown;
    return Marker(
      key: ValueKey('poi_${p.id}'),
      point: LatLng(p.lat, p.lng),
      width: w,
      height: icon,
      alignment: Marker.computePixelAlignment(width: w, height: icon, left: icon / 2, top: icon / 2),
      child: PoiMarker(
        poi: p,
        label: pl.showLabel ? p.name : null,
        labelWidth: lw,
        dimmed: unknown,
        onTap: () => showPlaceCard(context, p, s),
      ),
    );
  }
}

/// One place on the map: coloured disc with a white icon, optional name.
class PoiMarker extends StatelessWidget {
  const PoiMarker({super.key, required this.poi, this.label, this.labelWidth = 0, this.dimmed = false, this.onTap});
  final PlacePoi poi;
  final String? label;
  final double labelWidth;
  final bool dimmed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final emergency = poi.isEmergencyHospital;
    final color = poi.category.color.withValues(alpha: dimmed ? 0.6 : 1);
    final halo = AppTheme.card;
    return Semantics(
      button: true,
      label: '${poi.displayName}, ${poi.category.singular}${emergency ? ', 24 hour emergency' : ''}${dimmed ? ', fuel type unknown' : ''}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: emergency ? Colors.yellowAccent : Colors.white, width: emergency ? 2.5 : 1.5),
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1))],
            ),
            child: Icon(poi.category.icon, size: 15, color: Colors.white),
          ),
          if (label != null && labelWidth > 0) ...[
            const SizedBox(width: 4),
            SizedBox(
              width: labelWidth,
              child: Text(
                label!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.text,
                  shadows: [Shadow(color: halo, blurRadius: 3), Shadow(color: halo, blurRadius: 6)],
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
