import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/timeline_event_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/timeline_service.dart';
import '../../domain/timeline/timeline_text.dart';
import '../report/replay_screen.dart';
import 'member_colors.dart';
import 'timeline_list.dart';

/// A convoy's shared timeline as a full screen (app bar with Replay and
/// Refresh). Used by an admin for any convoy. Riders see the same content as
/// [LiveTimelineView] inside the Alerts tab.
class LiveTimelineScreen extends StatelessWidget {
  final String groupId;
  const LiveTimelineScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    final name = context.select<ConvoyService, String>((s) => s.allConvoys[groupId]?.name ?? '');
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: Text(name.isNotEmpty ? '$name: timeline' : 'Group timeline', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Replay the ride',
            icon: Icon(Icons.slow_motion_video_rounded, color: AppTheme.neonCyan),
            onPressed: () => LiveTimelineView.openReplay(context, groupId),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => LiveTimelineView.refresh(context, groupId),
          ),
        ],
      ),
      body: LiveTimelineView(groupId: groupId, showReplay: false),
    );
  }
}

/// The live group timeline without a Scaffold, for embedding (the Alerts tab
/// "Timeline" segment). It attaches the timeline to [groupId] when that is
/// not the rider's own convoy, and goes back to the rider's convoy when
/// removed. Pull down to refresh. Tapping an entry with a place opens the
/// replay at that moment.
class LiveTimelineView extends StatefulWidget {
  final String groupId;

  /// Shows a "Replay the ride" button above the list (off when the host has
  /// its own Replay action, like [LiveTimelineScreen]).
  final bool showReplay;

  const LiveTimelineView({super.key, required this.groupId, this.showReplay = true});

  /// Opens the replay of [groupId] with the colours and waits of the timeline.
  static void openReplay(BuildContext context, String groupId, {TimelineEventModel? at}) {
    final timeline = context.read<TimelineService>();
    final events = timeline.groupId == groupId ? timeline.events : const <TimelineEventModel>[];
    final colors = MemberColors.assign(_names(context.read<ConvoyService>(), groupId, events).keys);
    final e = at;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => e != null && e.hasPlace
            ? ReplayScreen(
                groupId: groupId,
                title: TimelineText.title(e, nowMs: DateTime.now().millisecondsSinceEpoch),
                initialTs: e.startedAt,
                focusUserId: e.userId,
                pin: LatLng(e.lat!, e.lng!),
                colors: colors,
                events: events,
              )
            : ReplayScreen(groupId: groupId, title: 'Replay', colors: colors, events: events),
      ),
    );
  }

  /// Reloads the timeline of [groupId] (attaching it first when needed).
  static Future<void> refresh(BuildContext context, String groupId) async {
    final t = context.read<TimelineService>();
    if (t.groupId == groupId) {
      await t.reload();
    } else {
      await t.attach(groupId);
    }
  }

  /// Names in join order from the convoy, plus anyone who already left.
  static Map<String, String> _names(ConvoyService convoys, String groupId, List<TimelineEventModel> events) {
    final names = <String, String>{};
    final convoy = convoys.allConvoys[groupId];
    if (convoy != null) {
      for (final r in convoy.riders.values) {
        names[r.userId] = r.name;
      }
    }
    for (final e in events) {
      if (e.userId != null && !names.containsKey(e.userId)) names[e.userId!] = e.userName;
    }
    return names;
  }

  @override
  State<LiveTimelineView> createState() => _LiveTimelineViewState();
}

class _LiveTimelineViewState extends State<LiveTimelineView> {
  TimelineService? _timeline;
  ConvoyService? _convoys;
  String? _attachedTo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attach(widget.groupId));
  }

  @override
  void didUpdateWidget(LiveTimelineView old) {
    super.didUpdateWidget(old);
    if (old.groupId != widget.groupId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _release(old.groupId);
        _attach(widget.groupId);
      });
    }
  }

  void _attach(String groupId) {
    if (!mounted) return;
    final t = context.read<TimelineService>();
    _timeline = t;
    _convoys = context.read<ConvoyService>();
    if (t.groupId != groupId) {
      _attachedTo = groupId;
      t.attach(groupId).ignore();
    }
  }

  /// Gives the timeline back to the rider's own convoy when this view attached another one.
  void _release(String groupId) {
    final t = _timeline;
    final active = _convoys?.activeGroupId;
    if (_attachedTo != groupId || t == null || active == groupId) return;
    _attachedTo = null;
    // After the frame: listeners must not be notified while the tree is being torn down.
    Future.microtask(() {
      if (t.groupId != groupId) return; // something else attached meanwhile
      t.detach();
      if (active != null) t.attach(active).ignore();
    });
  }

  @override
  void dispose() {
    _release(widget.groupId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    final timeline = context.watch<TimelineService>();
    // Only the convoy's member names matter here, not positions.
    context.select<ConvoyService, String>((s) {
      final c = s.allConvoys[groupId];
      if (c == null) return '';
      return c.riders.values.map((r) => '${r.userId}\u0002${r.name}').join('\u0001');
    });
    final events = timeline.groupId == groupId ? timeline.events : const <TimelineEventModel>[];
    final names = LiveTimelineView._names(context.read<ConvoyService>(), groupId, events);
    final colors = MemberColors.assign(names.keys);

    final list = TimelineList(
      events: events,
      colors: colors,
      memberNames: names,
      newestFirst: true,
      onTap: (e) => LiveTimelineView.openReplay(context, groupId, at: e),
      emptyState: LayoutBuilder(
        builder: (context, c) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: c.maxHeight,
              child: EmptyState(
                icon: Icons.timeline_rounded,
                title: timeline.error != null ? 'Could not load the timeline' : 'No events yet',
                message: timeline.error ?? 'The timeline fills in as the ride goes: who joins, stops, falls behind and arrives.',
                primaryLabel: timeline.error != null ? 'Try again' : null,
                onPrimary: timeline.error != null ? () => LiveTimelineView.refresh(context, groupId) : null,
              ),
            ),
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showReplay)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.s12, Space.s4, Space.s12, 0),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () => LiveTimelineView.openReplay(context, groupId),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.slow_motion_video_rounded),
                label: const Text('Replay the ride', maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        Expanded(
          child: LoadingState(
            loading: timeline.isLoading,
            hasData: events.isNotEmpty,
            child: RefreshIndicator(
              color: AppTheme.neonCyan,
              onRefresh: () => LiveTimelineView.refresh(context, groupId),
              child: list,
            ),
          ),
        ),
      ],
    );
  }
}
