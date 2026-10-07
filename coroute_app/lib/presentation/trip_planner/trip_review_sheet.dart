import 'package:flutter/material.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/route_model.dart';

/// The last step before a ride starts: what the trip looks like (distance,
/// estimated time, stops, riders, departure), how the group is invited, the
/// optional group speed limit, then [Start Ride].
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

  const TripReviewSheet({
    super.key,
    required this.name,
    this.startName,
    this.destinationName,
    this.route,
    this.stops = 0,
    this.speedLimitKmh = 0,
  });

  static Future<int?> show(
    BuildContext context, {
    required String name,
    String? startName,
    String? destinationName,
    RouteModel? route,
    int stops = 0,
    int speedLimitKmh = 0,
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
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    final hasDestination = (widget.destinationName ?? '').trim().isNotEmpty;
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
              if (r != null && r.approximate)
                Padding(
                  padding: const EdgeInsets.only(top: Space.s8),
                  child: Text('Distance and time are a straight-line estimate.', style: AppText.caption),
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
        Expanded(child: Text(text, style: AppText.body)),
      ],
    );
  }
}
