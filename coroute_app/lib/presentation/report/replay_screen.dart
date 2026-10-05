import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/api_client.dart';
import '../../domain/tracking/replay_math.dart';
import '../timeline/member_colors.dart';

/// Replays a convoy: drag the time slider (or press play) and every rider's
/// marker moves to where they were at that moment, with a 10-minute tail.
/// Opened from a timeline entry it starts at that moment, with a pin on the
/// place and that rider highlighted.
class ReplayScreen extends StatefulWidget {
  final String groupId;
  final String title;
  final int? initialTs;
  final String? focusUserId;
  final LatLng? pin;
  final String? pinLabel;
  final Map<String, Color>? colors;

  const ReplayScreen({
    super.key,
    required this.groupId,
    this.title = 'Replay',
    this.initialTs,
    this.focusUserId,
    this.pin,
    this.pinLabel,
    this.colors,
  });

  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  List<ReplayTrack> _tracks = [];
  Map<String, Color> _colors = {};
  bool _loading = true;
  String? _error;
  int _t = 0, _from = 0, _to = 0;
  Timer? _timer;
  int _speedIndex = 1;
  static const _speeds = [30, 120, 600]; // seconds of ride per second of replay

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    try {
      final res = await api.get('/convoys/${widget.groupId}/tracks?simplify=8', timeout: const Duration(seconds: 25));
      final list = (res is Map ? res['tracks'] : null) as List? ?? const [];
      final tracks = list.whereType<Map>().map((m) => ReplayTrack.fromJson(Map<String, dynamic>.from(m))).where((t) => t.points.length >= 2).toList();
      if (!mounted) return;
      final from = tracks.isEmpty ? 0 : tracks.map((t) => t.firstTs).reduce((a, b) => a < b ? a : b);
      final to = tracks.isEmpty ? 0 : tracks.map((t) => t.lastTs).reduce((a, b) => a > b ? a : b);
      setState(() {
        _tracks = tracks;
        _colors = widget.colors ?? MemberColors.assign(tracks.map((t) => t.userId));
        _from = from;
        _to = to;
        final start = widget.initialTs ?? from;
        _t = start.clamp(from, to < from ? from : to).toInt();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load the routes.'; _loading = false; });
    }
  }

  void _togglePlay() {
    if (_timer != null) {
      _timer!.cancel();
      setState(() => _timer = null);
      return;
    }
    if (_t >= _to) _t = _from;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() {
        _t += _speeds[_speedIndex] * 100;
        if (_t >= _to) {
          _t = _to;
          _timer?.cancel();
          _timer = null;
        }
      });
    });
    setState(() {});
  }

  LatLngBounds? _bounds() {
    final pts = <LatLng>[for (final t in _tracks) for (final p in t.points) LatLng(p.lat, p.lng)];
    if (widget.pin != null) pts.add(widget.pin!);
    if (pts.length < 2) return null;
    return LatLngBounds.fromPoints(pts);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(title: Text(widget.title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.laserRed))))
              : LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth > c.maxHeight && c.maxWidth > 700;
                  final map = _map();
                  final panel = _panel();
                  return wide
                      ? Row(children: [Expanded(flex: 3, child: map), SizedBox(width: 360, child: panel)])
                      : Column(children: [Expanded(child: map), panel]);
                }),
    );
  }

  Widget _map() {
    final bounds = _bounds();
    final center = widget.pin ?? (bounds?.center ?? const LatLng(17.385, 78.4867));
    final focus = widget.focusUserId;
    return FlutterMap(
      options: MapOptions(
        initialCenter: center,
        initialZoom: 13,
        initialCameraFit: (widget.pin == null && bounds != null) ? CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40)) : null,
      ),
      children: [
        TileLayer(urlTemplate: AppConstants.osmTileUrl, userAgentPackageName: AppConstants.osmUserAgent),
        PolylineLayer(polylines: [
          for (final t in _tracks)
            Polyline(
              points: [for (final p in t.points) LatLng(p.lat, p.lng)],
              strokeWidth: t.userId == focus ? 3 : 2,
              color: (_colors[t.userId] ?? AppTheme.neonCyan).withOpacity(focus == null || t.userId == focus ? 0.35 : 0.15),
            ),
          for (final t in _tracks)
            Polyline(
              points: [for (final p in t.tail(_t)) LatLng(p.lat, p.lng)],
              strokeWidth: t.userId == focus ? 6 : 4.5,
              color: _colors[t.userId] ?? AppTheme.neonCyan,
            ),
        ]),
        MarkerLayer(markers: [
          if (widget.pin != null)
            Marker(point: widget.pin!, width: 36, height: 36, child: const Icon(Icons.location_on, color: AppTheme.hyperAmber, size: 34)),
          for (final t in _tracks)
            if (t.positionAt(_t) != null)
              Marker(
                point: LatLng(t.positionAt(_t)!.lat, t.positionAt(_t)!.lng),
                width: 34,
                height: 34,
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.obsidianVoid,
                    shape: BoxShape.circle,
                    border: Border.all(color: _colors[t.userId] ?? AppTheme.neonCyan, width: t.userId == focus ? 3 : 2),
                  ),
                  child: Text(MemberColors.initials(t.name), style: TextStyle(color: _colors[t.userId] ?? AppTheme.neonCyan, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
        ]),
      ],
    );
  }

  Widget _panel() {
    final fmt = DateFormat('HH:mm:ss');
    final hasRange = _to > _from;
    return Container(
      color: AppTheme.darkCanvas,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_tracks.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No recorded route for this trip yet. Routes appear a minute after riders move.',
                    textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
              )
            else ...[
              Row(
                children: [
                  IconButton(
                    onPressed: hasRange ? _togglePlay : null,
                    icon: Icon(_timer != null ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, color: AppTheme.neonCyan, size: 36),
                    tooltip: _timer != null ? 'Pause' : 'Play',
                  ),
                  Expanded(
                    child: Text(_t > 0 ? fmt.format(DateTime.fromMillisecondsSinceEpoch(_t)) : '',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _speedIndex = (_speedIndex + 1) % _speeds.length),
                    child: Text('${_speeds[_speedIndex]}x', style: const TextStyle(color: AppTheme.neonCyan)),
                  ),
                ],
              ),
              if (hasRange)
                Slider(
                  value: _t.toDouble().clamp(_from.toDouble(), _to.toDouble()).toDouble(),
                  min: _from.toDouble(),
                  max: _to.toDouble(),
                  activeColor: AppTheme.neonCyan,
                  onChanged: (v) => setState(() => _t = v.round()),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  for (final t in _tracks)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(radius: 5, backgroundColor: _colors[t.userId] ?? AppTheme.neonCyan),
                        const SizedBox(width: 5),
                        Text(
                          t.positionAt(_t) == null ? '${t.name}: no data' : '${t.name}: ${t.positionAt(_t)!.kmh.round()} km/h',
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
