import '../ride/essentials_sheet.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/route_model.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/tile_cache_service.dart';
import '../../data/services/weather_service.dart';
import '../../domain/safety/sun_helper.dart';
import '../ride/ride_sheet.dart' show SaveRouteMapRow;

/// The last step before a ride starts: what the trip looks like (distance,
/// estimated time, stops, riders, departure), the weather along the route
/// and whether the ride ends after dark (3.16), "Save route map", how the
/// group is invited, the optional group speed limit, then [Start Ride].
///
/// [show] returns the chosen speed limit in km/h (0 = off) when the rider
/// presses Start Ride, or null when the sheet is closed.
class TripReviewSheet extends StatefulWidget {
  final String name;
  final String? startName;
  final String? destinationName;
  final RouteModel? route;
  final int stops;
  final int speedLimitKmh;

  /// Planned stops (name, lat, lng) for the weather sample points.
  final List<(String, double, double)> namedStops;
  final double? startLat;
  final double? startLng;
  final double? destinationLat;
  final double? destinationLng;

  /// For the sunset line in tests; defaults to now.
  final DateTime? now;

  const TripReviewSheet({
    super.key,
    required this.name,
    this.startName,
    this.destinationName,
    this.route,
    this.stops = 0,
    this.speedLimitKmh = 0,
    this.namedStops = const [],
    this.startLat,
    this.startLng,
    this.destinationLat,
    this.destinationLng,
    this.now,
  });

  static const String checkingWeather = 'Checking weather...';

  static Future<int?> show(
    BuildContext context, {
    required String name,
    String? startName,
    String? destinationName,
    RouteModel? route,
    int stops = 0,
    int speedLimitKmh = 0,
    List<(String, double, double)> namedStops = const [],
    double? startLat,
    double? startLng,
    double? destinationLat,
    double? destinationLng,
  }) {
    return showAppSheet<int>(
      context,
      isScrollControlled: true,
      builder: (_) => TripReviewSheet(
        name: name,
        startName: startName,
        destinationName: destinationName,
        route: route,
        stops: stops,
        speedLimitKmh: speedLimitKmh,
        namedStops: namedStops,
        startLat: startLat,
        startLng: startLng,
        destinationLat: destinationLat,
        destinationLng: destinationLng,
      ),
    );
  }

  /// The sunset line for this trip (pure): null by day. The destination position,
  /// else the route's last point, decides the sunset.
  static String? darkLine({
    required DateTime now,
    required RouteModel? route,
    double? destinationLat,
    double? destinationLng,
    required String Function(DateTime) fmtTime,
  }) {
    if (route == null) return null;
    var lat = destinationLat ?? 0.0, lng = destinationLng ?? 0.0;
    if ((lat == 0 && lng == 0) && route.points.isNotEmpty) {
      final (la, ln) = route.points.last;
      lat = la;
      lng = ln;
    }
    if (lat == 0 && lng == 0) return null;
    return DarkCheck.reviewLine(departure: now, eta: Duration(seconds: route.durationS), lat: lat, lng: lng, fmtTime: fmtTime);
  }

  /// "From Home to Fort", "From Home", "To Fort" or "".
  static String fromTo(String? start, String? destination) {
    final s = (start ?? '').trim();
    final d = (destination ?? '').trim();
    if (s.isNotEmpty && d.isNotEmpty) return 'From $s to $d';
    if (s.isNotEmpty) return 'From $s';
    if (d.isNotEmpty) return 'To $d';
    return '';
  }

  @override
  State<TripReviewSheet> createState() => _TripReviewSheetState();
}

class _TripReviewSheetState extends State<TripReviewSheet> {
  late int _limit = widget.speedLimitKmh;
  WeatherSummary? _weather;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkWeather());
  }

  /// One weather check when the sheet opens (cached 30 min; none under data saver).
  Future<void> _checkWeather() async {
    if (!mounted) return;
    final r = widget.route;
    final weather = Provider.of<WeatherService?>(context, listen: false);
    if (r == null || weather == null || r.points.isEmpty) return;
    final now = widget.now ?? DateTime.now();
    final pts = WeatherService.samplePoints(
      line: r.points,
      durationS: r.durationS,
      departS: now.millisecondsSinceEpoch ~/ 1000,
      namedStops: widget.namedStops,
      destinationName: widget.destinationName ?? '',
    );
    setState(() => _checking = true);
    WeatherSummary? w;
    try {
      w = await weather.check(pts);
    } catch (_) {
      w = null;
    }
    if (!mounted) return;
    setState(() {
      _weather = w;
      _checking = false;
    });
  }

  String _clock(DateTime d) => MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(d),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    final hasDestination = (widget.destinationName ?? '').trim().isNotEmpty;
    final lowData = Provider.of<SettingsService?>(context)?.lowData ?? false;
    final pf = Provider.of<TilePrefetcher?>(context);
    final weatherLine = _checking ? TripReviewSheet.checkingWeather : (lowData ? L10n.t('weather.off') : _weather?.line);
    final dark = TripReviewSheet.darkLine(
      now: widget.now ?? DateTime.now(),
      route: r,
      destinationLat: widget.destinationLat,
      destinationLng: widget.destinationLng,
      fmtTime: _clock,
    );
    final canSaveMap = r != null && !r.approximate && r.points.length >= 2;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSheetHeader(
          title: widget.name,
          subtitle: TripReviewSheet.fromTo(widget.startName, widget.destinationName),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              if (r != null)
                RouteSummary(
                  distanceKm: r.distanceM / 1000,
                  duration: Duration(seconds: r.durationS),
                  stops: widget.stops,
                  riders: 1,
                  departure: DateTime.now(),
                )
              else
                _Note(
                  icon: Icons.route_rounded,
                  text: hasDestination
                      ? 'Route preview is not available right now. It is worked out when the ride starts.'
                      : 'No destination yet. You can set it during the ride.',
                ),
              if (r != null && !r.approximate) EssentialsPreview(route: r),
              if (r != null && r.approximate)
                Padding(
                  padding: const EdgeInsets.only(top: Space.s8),
                  child: Text('Distance and time are a straight-line estimate.', style: AppText.caption),
                ),
              if (r != null && weatherLine != null) ...[
                const SizedBox(height: Space.s12),
                _Note(icon: Icons.umbrella_rounded, text: weatherLine),
                if (!_checking && _weather != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.s4, left: 28),
                    child: Text(L10n.t('weather.by'), style: AppText.caption),
                  ),
              ],
              if (dark != null) ...[
                const SizedBox(height: Space.s12),
                _Note(icon: Icons.nights_stay_rounded, text: dark),
              ],
              if (r != null && pf != null && canSaveMap)
                Padding(
                  padding: const EdgeInsets.only(top: Space.s8),
                  child: SaveRouteMapRow(
                    running: pf.running,
                    done: pf.done,
                    total: pf.total,
                    error: pf.error,
                    onSave: () => pf.start(r.points, label: widget.name),
                  ),
                ),
              const SizedBox(height: Space.s16),
              const _Note(
                icon: Icons.group_add_rounded,
                text: 'After you start, share the ride code so your group can join.',
              ),
              const SizedBox(height: Space.s16),
              Row(
                children: [
                  Icon(Icons.speed_rounded, size: 20, color: AppTheme.textSecondary),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text('Group speed limit', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  Text(_limit > 0 ? '$_limit km/h' : 'Off', style: AppText.label.copyWith(color: AppTheme.textPrimary)),
                ],
              ),
              const SizedBox(height: Space.s8),
              Wrap(
                spacing: Space.s8,
                runSpacing: Space.s8,
                children: [
                  for (final v in AppConstants.speedLimitChoices)
                    ChoiceChip(
                      label: Text(v == 0 ? 'Off' : '$v'),
                      selected: _limit == v,
                      onSelected: (_) => setState(() => _limit = v),
                      selectedColor: AppTheme.neonCyan,
                      backgroundColor: AppTheme.slateCard,
                      labelStyle: AppText.label.copyWith(color: _limit == v ? Colors.black : AppTheme.textPrimary),
                      side: BorderSide(color: _limit == v ? AppTheme.neonCyan : AppTheme.subtleBorder),
                      showCheckmark: false,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      shape: const RoundedRectangleBorder(borderRadius: Radii.smAll),
                    ),
                ],
              ),
              const SizedBox(height: Space.s4),
              Text(
                'Riding over it for 10 seconds is logged and the group is told once. You can change it during the ride.',
                style: AppText.caption,
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s16),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, _limit),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start Ride', style: TextStyle(fontWeight: FontWeight.w700)),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Note({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppTheme.textSecondary),
        const SizedBox(width: Space.s8),
        Expanded(child: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.body)),
      ],
    );
  }
}
