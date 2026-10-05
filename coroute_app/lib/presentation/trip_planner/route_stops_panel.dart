import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/stop_point_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/geo_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../../domain/tracking/geo_math.dart';
import '../map_picker/map_picker_screen.dart';

/// The route during a ride: start, stops (with suggestions from members),
/// destination and the route summary. The lead can add, reorder, skip and
/// remove stops and change the destination; everyone else can suggest a stop.
class RouteStopsPanel extends StatelessWidget {
  final ConvoyModel convoy;
  final bool shrinkWrap;
  const RouteStopsPanel({super.key, required this.convoy, this.shrinkWrap = false});

  static const Map<String, IconData> categoryIcons = {
    'FUEL': Icons.local_gas_station_rounded,
    'FOOD': Icons.restaurant_rounded,
    'REST': Icons.airline_seat_recline_normal_rounded,
    'SCENIC': Icons.landscape_rounded,
    'TOLL': Icons.toll_rounded,
    'OTHER': Icons.place_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final lead = service.canEditRoute;
    final me = service.myUserId != null ? convoy.riders[service.myUserId] : null;
    final meLat = me?.lat ?? 0.0, meLng = me?.lng ?? 0.0;
    final hasMe = meLat != 0 || meLng != 0;
    final planned = convoy.plannedStops;
    final skipped = convoy.stopPoints.where((s) => s.isSkipped).toList();
    final suggestions = convoy.suggestedStops;
    final route = convoy.route;

    String fromMe(double lat, double lng) => hasMe ? TimelineText.distance(GeoMath.haversine(meLat, meLng, lat, lng)) : '';

    Future<void> addOrSuggest() async {
      final p = await MapPickerScreen.pick(
        context,
        title: lead ? 'Add a stop' : 'Suggest a stop',
        forStop: true,
        confirmLabel: lead ? 'Add stop' : 'Send suggestion',
        initial: hasMe ? PickedPlace(lat: meLat, lng: meLng) : null,
      );
      if (p == null) return;
      final ok = lead ? service.addStop(p) : service.suggestStop(p);
      if (ok && !lead && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Suggestion sent to the lead.')));
      }
    }

    Future<void> changeDestination() async {
      final p = await MapPickerScreen.pick(
        context,
        title: 'Destination',
        initial: (convoy.destinationLat != 0 || convoy.destinationLng != 0)
            ? PickedPlace(lat: convoy.destinationLat, lng: convoy.destinationLng, name: convoy.destinationName)
            : null,
      );
      if (p != null) service.setDestination(p);
    }

    final children = <Widget>[
      if (route != null)
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.subtleBorder)),
          child: Row(children: [
            const Icon(Icons.directions_rounded, color: AppTheme.emeraldSafe),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${TimelineText.distance(route.distanceM)} · about ${TimelineText.duration(Duration(seconds: route.durationS))} riding'
                '${route.approximate ? '\nStraight-line estimate: the road route is not available right now.' : ''}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ]),
        ),
      _row(
        icon: Icons.trip_origin_rounded,
        color: AppTheme.emeraldSafe,
        title: convoy.startLocationName.isNotEmpty ? convoy.startLocationName : 'Start',
        subtitle: 'Start',
      ),
      if (planned.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Text('No stops planned.', style: TextStyle(color: AppTheme.textMuted)),
        )
      else
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: planned.length,
          onReorder: (from, to) {
            if (!lead) return;
            final ids = planned.map((s) => s.stopId).toList();
            final id = ids.removeAt(from);
            ids.insert(to > from ? to - 1 : to, id);
            service.reorderStops(ids);
          },
          itemBuilder: (_, i) {
            final s = planned[i];
            return _StopTile(
              key: ValueKey(s.stopId),
              stop: s,
              index: i,
              lead: lead,
              distance: s.isVisited ? 'visited' : fromMe(s.lat, s.lng),
              onVisited: (v) => service.toggleStopVisited(s.stopId, v),
              onSkip: () => service.skipStop(s.stopId),
              onRemove: () => service.removeStop(s.stopId),
            );
          },
        ),
      for (final s in skipped)
        _row(icon: Icons.not_interested_rounded, color: AppTheme.textMuted, title: s.name, subtitle: 'Skipped', strike: true),
      _row(
        icon: Icons.sports_score_rounded,
        color: AppTheme.laserRed,
        title: convoy.destinationName.isNotEmpty ? convoy.destinationName : 'No destination set',
        subtitle: (convoy.destinationLat != 0 || convoy.destinationLng != 0) ? 'Destination ${fromMe(convoy.destinationLat, convoy.destinationLng)}' : 'Destination',
        trailing: lead ? IconButton(tooltip: 'Change destination', icon: const Icon(Icons.edit_location_alt_rounded, color: AppTheme.textSecondary), onPressed: changeDestination) : null,
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: planned.length + suggestions.length >= 20 ? null : addOrSuggest,
        icon: Icon(lead ? Icons.add_location_alt_rounded : Icons.add_comment_rounded),
        label: Text(lead ? 'Add a stop' : 'Suggest a stop'),
        style: OutlinedButton.styleFrom(foregroundColor: AppTheme.hyperAmber, side: const BorderSide(color: AppTheme.hyperAmber), minimumSize: const Size.fromHeight(44)),
      ),
      if (suggestions.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(lead ? 'SUGGESTED BY THE GROUP' : 'SUGGESTIONS WAITING FOR THE LEAD',
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const SizedBox(height: 6),
        for (final s in suggestions)
          Card(
            color: AppTheme.elevatedCard,
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: ListTile(
              leading: Icon(categoryIcons[s.category] ?? Icons.place_rounded, color: AppTheme.hyperAmber),
              title: Text(s.name, style: const TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: Text(
                [if (s.suggestedByName.isNotEmpty) 'from ${s.suggestedByName}', if (fromMe(s.lat, s.lng).isNotEmpty) fromMe(s.lat, s.lng)].join(' · '),
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
              trailing: lead
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Decline', icon: const Icon(Icons.close_rounded, color: AppTheme.laserRed), onPressed: () => service.declineStop(s.stopId)),
                      IconButton(tooltip: 'Add to the route', icon: const Icon(Icons.check_rounded, color: AppTheme.emeraldSafe), onPressed: () => service.acceptStop(s.stopId)),
                    ])
                  : null,
            ),
          ),
      ],
    ];

    return ListView(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.all(12),
      children: children,
    );
  }

  static Widget _row({required IconData icon, required Color color, required String title, required String subtitle, Widget? trailing, bool strike = false}) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: Colors.white, fontSize: 14, decoration: strike ? TextDecoration.lineThrough : null)),
      subtitle: Text(subtitle, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
      trailing: trailing,
    );
  }
}

class _StopTile extends StatelessWidget {
  final StopPointModel stop;
  final int index;
  final bool lead;
  final String distance;
  final ValueChanged<bool> onVisited;
  final VoidCallback onSkip;
  final VoidCallback onRemove;

  const _StopTile({
    super.key,
    required this.stop,
    required this.index,
    required this.lead,
    required this.distance,
    required this.onVisited,
    required this.onSkip,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final s = stop;
    final details = [
      if (distance.isNotEmpty) distance,
      if (s.plannedDwellMin > 0) 'stay ${s.plannedDwellMin} min',
      if (s.suggestedByName.isNotEmpty) 'added by ${s.suggestedByName}',
    ].join(' · ');
    return Card(
      color: AppTheme.elevatedCard,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: s.isVisited ? AppTheme.emeraldSafe : AppTheme.hyperAmber,
          child: s.isVisited
              ? const Icon(Icons.check_rounded, color: Colors.black, size: 16)
              : Text('${index + 1}', style: const TextStyle(color: Colors.black, fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        title: Row(children: [
          Icon(RouteStopsPanel.categoryIcons[s.category] ?? Icons.place_rounded, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(s.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontSize: 14, decoration: s.isVisited ? TextDecoration.lineThrough : null)),
          ),
        ]),
        subtitle: details.isEmpty ? null : Text(details, style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Checkbox(value: s.isVisited, activeColor: AppTheme.emeraldSafe, onChanged: (v) {
            if (v != null) onVisited(v);
          }),
          if (lead)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: AppTheme.textSecondary),
              color: AppTheme.elevatedCard,
              onSelected: (v) {
                if (v == 'skip') {
                  onSkip();
                } else {
                  onRemove();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'skip', child: Text('Skip this stop')),
                PopupMenuItem(value: 'remove', child: Text('Remove from the route')),
              ],
            ),
          if (lead) ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle_rounded, color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}
