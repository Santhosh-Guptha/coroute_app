import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/map_tiles.dart';
import '../../data/services/gpx_service.dart';
import '../../domain/garage/bike_profile.dart';
import 'widgets/ride_share_card.dart';

/// Interactive 2D post-ride trail replay screen with timeline scrubbing,
/// momentary speedometer HUD, elevation tracking, and GPX export.
class RideReplayScreen extends StatefulWidget {
  final String rideTitle;
  final String? convoyCode;
  final List<GpxTrackpoint> trackpoints;
  final List<GpxWaypoint> waypoints;
  final BikeProfile? bike;

  const RideReplayScreen({
    super.key,
    required this.rideTitle,
    this.convoyCode,
    required this.trackpoints,
    this.waypoints = const [],
    this.bike,
  });

  @override
  State<RideReplayScreen> createState() => _RideReplayScreenState();
}

class _RideReplayScreenState extends State<RideReplayScreen> {
  final MapController _mapController = MapController();

  int _currentIndex = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 2.0;
  Timer? _playbackTimer;
  bool _isShowingSheet = false;

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _stopPlayback();
    } else {
      _startPlayback();
    }
  }

  void _startPlayback() {
    if (widget.trackpoints.isEmpty) return;
    _playbackTimer?.cancel();
    setState(() => _isPlaying = true);

    _playbackTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        final step = (_playbackSpeed * 1.5).round().clamp(1, 20);
        _currentIndex += step;
        if (_currentIndex >= widget.trackpoints.length - 1) {
          _currentIndex = widget.trackpoints.length - 1;
          _stopPlayback();
        }
      });

      final currentPt = widget.trackpoints[_currentIndex];
      _mapController.move(LatLng(currentPt.latitude, currentPt.longitude), _mapController.camera.zoom);
    });
  }

  void _stopPlayback() {
    _playbackTimer?.cancel();
    if (mounted) setState(() => _isPlaying = false);
  }

  void _onSliderChanged(double val) {
    if (widget.trackpoints.isEmpty) return;
    final newIndex = val.round().clamp(0, widget.trackpoints.length - 1);
    setState(() => _currentIndex = newIndex);
    final currentPt = widget.trackpoints[newIndex];
    _mapController.move(LatLng(currentPt.latitude, currentPt.longitude), _mapController.camera.zoom);
  }

  void _openShareSheet() {
    if (widget.trackpoints.isEmpty) return;

    final first = widget.trackpoints.first;
    final last = widget.trackpoints.last;
    final duration = last.timestamp.difference(first.timestamp);

    double totalDistKm = 0;
    double maxSpeed = 0;
    double speedSum = 0;
    const distanceCalc = Distance();

    for (int i = 0; i < widget.trackpoints.length; i++) {
      final p = widget.trackpoints[i];
      if (p.speedKmh > maxSpeed) maxSpeed = p.speedKmh;
      speedSum += p.speedKmh;
      if (i > 0) {
        final prev = widget.trackpoints[i - 1];
        totalDistKm += distanceCalc.as(
          LengthUnit.Kilometer,
          LatLng(prev.latitude, prev.longitude),
          LatLng(p.latitude, p.longitude),
        );
      }
    }

    final avgSpeed = widget.trackpoints.isNotEmpty ? (speedSum / widget.trackpoints.length) : 0.0;

    if (_isShowingSheet) return;
    _isShowingSheet = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        maxWidth: 600,
      ),
      backgroundColor: Colors.transparent,
      builder: (ctx) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: RideShareCard(
                rideTitle: widget.rideTitle,
                convoyCode: widget.convoyCode,
                startTime: first.timestamp,
                distanceKm: totalDistKm,
                duration: duration,
                avgSpeedKmh: avgSpeed,
                topSpeedKmh: maxSpeed,
                bike: widget.bike,
                onExportGpx: () async {
                  if (ctx.mounted) Navigator.pop(ctx);
                  await GpxService.shareGpxFile(
                    rideName: widget.rideTitle,
                    trackpoints: widget.trackpoints,
                    waypoints: widget.waypoints,
                  );
                },
                onShareCard: () {
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).clearSnackBars();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Ride summary card ready to share!')),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      _isShowingSheet = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.trackpoints.isEmpty) {
      return Scaffold(
        backgroundColor: AppTheme.darkCanvas,
        appBar: AppBar(title: Text(widget.rideTitle)),
        body: Center(
          child: Text('No telemetry points found for this trip.', style: TextStyle(color: AppTheme.textMuted)),
        ),
      );
    }

    final currentPt = widget.trackpoints[_currentIndex];
    final allPoints = widget.trackpoints.map((p) => LatLng(p.latitude, p.longitude)).toList();
    final playedPoints = widget.trackpoints.sublist(0, _currentIndex + 1).map((p) => LatLng(p.latitude, p.longitude)).toList();

    return Scaffold(
      backgroundColor: AppTheme.darkCanvas,
      body: Stack(
        children: [
          // Map Canvas
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(currentPt.latitude, currentPt.longitude),
              initialZoom: 15.0,
            ),
            children: [
              appTileLayer(),

              // Full route (dimmed base)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: allPoints,
                    strokeWidth: 4.0,
                    color: AppTheme.isLight ? AppTheme.border2 : Colors.white.withOpacity(0.25),
                  ),
                  Polyline(
                    points: playedPoints,
                    strokeWidth: 4.5,
                    color: AppTheme.accentText,
                  ),
                ],
              ),

              // Waypoints Layer (Stops, Incidents)
              MarkerLayer(
                markers: widget.waypoints.map((wpt) {
                  return Marker(
                    point: LatLng(wpt.latitude, wpt.longitude),
                    width: 36,
                    height: 36,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.elevatedCard,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppTheme.neonCyan, width: 2),
                      ),
                      child: Icon(
                        wpt.symbol == 'Gas Station'
                            ? Icons.local_gas_station
                            : wpt.symbol == 'Danger Area'
                                ? Icons.warning
                                : wpt.symbol == 'Wrench'
                                    ? Icons.build
                                    : Icons.flag,
                        color: AppTheme.neonCyan,
                        size: 18,
                      ),
                    ),
                  );
                }).toList(),
              ),

              // Active moving rider marker
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(currentPt.latitude, currentPt.longitude),
                    width: 44,
                    height: 44,
                    child: Transform.rotate(
                      angle: ((currentPt.bearing ?? 0) * (3.141592653589793 / 180)),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.brand,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppTheme.card, width: 2.5),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.brand.withOpacity(0.6),
                              blurRadius: 12,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.navigation,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Top Telemetry HUD
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 700),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      // Back button
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppTheme.elevatedCard.withOpacity(0.92),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.subtleBorder),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.arrow_back, color: AppTheme.textPrimary),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Stats capsule
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppTheme.elevatedCard.withOpacity(0.92),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppTheme.subtleBorder),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _HudItem(
                                label: 'SPEED',
                                value: '${currentPt.speedKmh.round()}',
                                unit: 'km/h',
                              ),
                              _HudItem(
                                label: 'ALTITUDE',
                                value: '${currentPt.elevationM?.round() ?? "--"}',
                                unit: 'm',
                              ),
                              _HudItem(
                                label: 'TIME',
                                value:
                                    '${currentPt.timestamp.hour.toString().padLeft(2, '0')}:${currentPt.timestamp.minute.toString().padLeft(2, '0')}',
                                unit: '',
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Share / GPX button
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppTheme.brand,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.share, color: Colors.white),
                          tooltip: 'Share Card / Export GPX',
                          onPressed: _openShareSheet,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Bottom Playback Controller
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppTheme.elevatedCard.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: AppTheme.subtleBorder, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.shadow,
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Scrubbing Slider
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: AppTheme.accentText,
                            inactiveTrackColor: AppTheme.border2,
                            thumbColor: AppTheme.accentText,
                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                            trackHeight: 3.5,
                          ),
                          child: Slider(
                            value: _currentIndex.toDouble(),
                            min: 0,
                            max: (widget.trackpoints.length - 1).toDouble(),
                            onChanged: _onSliderChanged,
                          ),
                        ),

                        // Controls Row
                        Row(
                          children: [
                            // Play/Pause button
                            InkWell(
                              onTap: _togglePlayPause,
                              borderRadius: BorderRadius.circular(14),
                              child: Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: _isPlaying ? AppTheme.soft : AppTheme.brand,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  _isPlaying ? Icons.pause : Icons.play_arrow,
                                  color: _isPlaying ? AppTheme.text : Colors.white,
                                  size: 28,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            // Track Title and progress
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.rideTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    'Point ${_currentIndex + 1} of ${widget.trackpoints.length}',
                                    style: TextStyle(
                                      color: AppTheme.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Speed multiplier buttons
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: const BouncingScrollPhysics(),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [1.0, 2.0, 5.0, 10.0].map((spd) {
                                  final isSelected = _playbackSpeed == spd;
                                  return Padding(
                                    padding: const EdgeInsets.only(left: 4),
                                    child: InkWell(
                                      onTap: () => setState(() => _playbackSpeed = spd),
                                      borderRadius: BorderRadius.circular(8),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: isSelected ? AppTheme.neonCyan.withOpacity(0.2) : Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: isSelected ? AppTheme.neonCyan : AppTheme.subtleBorder,
                                          ),
                                        ),
                                        child: Text(
                                          '${spd.round()}x',
                                          style: TextStyle(
                                            color: isSelected ? AppTheme.neonCyan : AppTheme.textMuted,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
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
}

class _HudItem extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const _HudItem({
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Flexible(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Text(
                  unit,
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
