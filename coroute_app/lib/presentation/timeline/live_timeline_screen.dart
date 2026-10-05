import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/timeline_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../report/replay_screen.dart';
import 'member_colors.dart';
import 'timeline_list.dart';

/// The active convoy's shared timeline, updating live.
class LiveTimelineScreen extends StatelessWidget {
  final String groupId;
  const LiveTimelineScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    final timeline = context.watch<TimelineService>();
    final convoy = context.watch<ConvoyService>().allConvoys[groupId];
    final events = timeline.groupId == groupId ? timeline.events : const <TimelineEventModel>[];

    // Colours in join order; names from the convoy plus anyone who already left.
    final names = <String, String>{};
    if (convoy != null) {
      for (final r in convoy.riders.values) {
        names[r.userId] = r.name;
      }
    }
    for (final e in events) {
      if (e.userId != null && !names.containsKey(e.userId)) names[e.userId!] = e.userName;
    }
    final colors = MemberColors.assign(names.keys);

    void openOnMap(TimelineEventModel e) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReplayScreen(
            groupId: groupId,
            title: TimelineText.title(e, nowMs: DateTime.now().millisecondsSinceEpoch),
            initialTs: e.startedAt,
            focusUserId: e.userId,
            pin: LatLng(e.lat!, e.lng!),
            colors: colors,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Text(convoy != null ? '${convoy.name}: timeline' : 'Group timeline'),
        actions: [
          IconButton(
            tooltip: 'Replay the ride',
            icon: Icon(Icons.slow_motion_video_rounded, color: AppTheme.neonCyan),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ReplayScreen(groupId: groupId, title: 'Replay', colors: colors)),
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: timeline.groupId == groupId ? () => timeline.reload() : () => timeline.attach(groupId),
          ),
        ],
      ),
      body: timeline.isLoading && events.isEmpty
          ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
          : TimelineList(
              events: events,
              colors: colors,
              memberNames: names,
              newestFirst: true,
              onTap: openOnMap,
              emptyState: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    timeline.error ?? 'The timeline fills in as the ride goes: who joins, stops, falls behind and arrives.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                ),
              ),
            ),
    );
  }
}
