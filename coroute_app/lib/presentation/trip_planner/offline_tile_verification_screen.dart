import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/tile_cache_service.dart';

/// Interactive one-tap offline tile verification preview screen.
/// Renders purely from the phone's local cache (TileCache) with network
/// requests strictly disabled (CachedTileProvider with offlineOnly: true).
/// Allows riders to pan, zoom, inspect street labels, junctions, and verify
/// tile coverage before venturing into cellular dead zones.
class OfflineTileVerificationScreen extends StatefulWidget {
  final String packName;
  final List<(double, double)> routePoints;
  final bool highDetail;

  final bool showTileLayer;

  const OfflineTileVerificationScreen({
    super.key,
    required this.packName,
    required this.routePoints,
    this.highDetail = true,
    this.showTileLayer = true,
  });

  @override
  State<OfflineTileVerificationScreen> createState() => _OfflineTileVerificationScreenState();
}

class _OfflineTileVerificationScreenState extends State<OfflineTileVerificationScreen> {
  final MapController _mapController = MapController();
  double _currentZoom = 14.0;
  late final List<LatLng> _latLngPoints;

  @override
  void initState() {
    super.initState();
    _latLngPoints = widget.routePoints.map((p) => LatLng(p.$1, p.$2)).toList();
    if (_latLngPoints.isNotEmpty) {
      _currentZoom = widget.highDetail ? 16.0 : 14.0;
    }
  }

  void _snapToZoom(double targetZoom) {
    if (_latLngPoints.isEmpty) return;
    final center = _mapController.camera.center;
    _mapController.move(center, targetZoom);
    setState(() => _currentZoom = targetZoom);
  }

  void _fitRoute() {
    if (_latLngPoints.length < 2) return;
    var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    for (final p in _latLngPoints) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final bounds = LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(48),
      ),
    );
  }

  String _zoomDescription(double z) {
    if (z >= 17.0) return 'Junction turns, landmark POIs & buildings';
    if (z >= 16.0) return 'Sharp street names & local roads';
    if (z >= 14.0) return 'Primary highways & township connectors';
    return 'Regional corridor overview';
  }

  @override
  Widget build(BuildContext context) {
    final startPt = _latLngPoints.isNotEmpty ? _latLngPoints.first : const LatLng(17.385, 78.4867);
    final endPt = _latLngPoints.isNotEmpty ? _latLngPoints.last : startPt;

    final cachedCount = TileCache.instance?.count ?? 0;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Text(widget.packName, style: AppText.headline),
        backgroundColor: AppTheme.card,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.crop_free_rounded),
            tooltip: 'Fit route bounds',
            onPressed: _fitRoute,
          ),
        ],
      ),
      body: Stack(
        children: [
          // Offline-only FlutterMap
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: startPt,
              initialZoom: widget.highDetail ? 16.0 : 14.0,
              minZoom: 10,
              maxZoom: 18,
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture && (pos.zoom - _currentZoom).abs() > 0.1) {
                  setState(() => _currentZoom = pos.zoom);
                }
              },
            ),
            children: [
              // Strict offline tile layer
              if (widget.showTileLayer)
                TileLayer(
                  urlTemplate: AppConstants.osmTileUrl,
                  tileProvider: CachedTileProvider(
                    cache: TileCache.instance,
                    offlineOnly: true,
                  ),
                  maxZoom: 18,
                ),

              // Route Polyline
              if (_latLngPoints.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _latLngPoints,
                      strokeWidth: 5.0,
                      color: AppTheme.brand,
                    ),
                  ],
                ),

              // Start & Finish Markers
              if (_latLngPoints.length >= 2)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: startPt,
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.brand,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: dsFloatingShadow(),
                        ),
                        child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 16),
                      ),
                    ),
                    Marker(
                      point: endPt,
                      width: 28,
                      height: 28,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.sos,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: dsFloatingShadow(),
                        ),
                        child: const Icon(Icons.flag_rounded, color: Colors.white, size: 16),
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // Top Offline Banner & Zoom HUD
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppTheme.card.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.border, width: 1.5),
                    boxShadow: dsFloatingShadow(),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: StatusColors.success, // Green indicator
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'OFFLINE TILE VERIFICATION',
                                  style: AppText.caption.copyWith(
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                    fontSize: 11,
                                    color: AppTheme.brand,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  'Z ${_currentZoom.toStringAsFixed(1)}',
                                  style: AppText.headline.copyWith(fontSize: 14, color: AppTheme.text),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _zoomDescription(_currentZoom),
                              style: AppText.caption.copyWith(color: AppTheme.accentText),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                // Zoom Quick Snaps
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildSnapChip('Z12 Overview', 12.0),
                      const SizedBox(width: 6),
                      _buildSnapChip('Z14 Highways', 14.0),
                      const SizedBox(width: 6),
                      _buildSnapChip('Z16 Streets', 16.0),
                      const SizedBox(width: 6),
                      _buildSnapChip('Z17 Junctions', 17.0),
                      const SizedBox(width: 6),
                      ActionChip(
                        avatar: Icon(Icons.fit_screen_rounded, size: 16, color: AppTheme.text),
                        label: const Text('Fit Corridor'),
                        backgroundColor: AppTheme.card,
                        labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.text),
                        side: BorderSide(color: AppTheme.border),
                        onPressed: _fitRoute,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Bottom Verification Confirmation Card
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.border, width: 1.5),
                boxShadow: dsFloatingShadow(),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(Icons.verified_rounded, color: AppTheme.brand, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Offline Storage Ready', style: AppText.headline.copyWith(fontSize: 15)),
                            const SizedBox(height: 2),
                            Text(
                              '$cachedCount tiles cached · High detail corridor active',
                              style: AppText.caption,
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppTheme.brand.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          widget.highDetail ? 'HIGH DETAIL' : 'STANDARD',
                          style: AppText.caption.copyWith(
                            color: AppTheme.brand,
                            fontWeight: FontWeight.w800,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Return to Trip Planner', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSnapChip(String label, double zoom) {
    final isSelected = (_currentZoom - zoom).abs() < 0.6;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => _snapToZoom(zoom),
      selectedColor: AppTheme.brand,
      backgroundColor: AppTheme.card,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: isSelected ? Colors.white : AppTheme.accentText,
      ),
      side: BorderSide(
        color: isSelected ? AppTheme.brand : AppTheme.border,
      ),
    );
  }
}
