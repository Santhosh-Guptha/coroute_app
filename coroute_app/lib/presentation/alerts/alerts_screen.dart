import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/timeline_service.dart';
import '../../domain/notify/alert_policy.dart';
import '../rider/rider_home_screen.dart';
import '../timeline/live_timeline_screen.dart';
import 'alert_tiers.dart';

/// The ride facts the alerts depend on. A record compares by value, so a
/// widget that selects it does not rebuild on every position update.
typedef AlertFacts = ({String? groupId, String? userId, bool isLead, bool isSweeper, bool mySosOpen, bool sosWaiting});

AlertFacts alertFactsOf(ConvoyService s) {
  final viewer = alertViewerFor(s.activeConvoy, s.myUserId);
  return (
    groupId: s.activeGroupId,
    userId: s.myUserId,
    isLead: viewer?.isLead ?? false,
    isSweeper: viewer?.isSweeper ?? false,
    mySosOpen: s.myOpenSosAlertId != null,
    sosWaiting: s.pendingSos != null,
  );
}

/// Alerts from the group timeline for [f], or an empty list when there is no ride.
List<InAppAlert> alertsFor(AlertFacts f, TimelineService timeline, {required int nowMs}) {
  final uid = f.userId;
  if (f.groupId == null || uid == null || timeline.groupId != f.groupId) return const [];
  return inAppAlerts(
    timeline.events,
    AlertViewer(userId: uid, isLead: f.isLead, isSweeper: f.isSweeper),
    nowMs: nowMs,
  );
}

/// Critical and important alerts, for the badge on the Alerts tab.
int alertsBadgeCount(AlertFacts f, TimelineService timeline) {
  if (f.groupId == null) return 0;
  final local = (f.mySosOpen ? 1 : 0) + (f.sosWaiting && !f.mySosOpen ? 1 : 0);
  return alertBadgeCount(alertsFor(f, timeline, nowMs: DateTime.now().millisecondsSinceEpoch), local: local);
}

enum _Segment { alerts, timeline }

/// The Alerts tab: what needs attention now, grouped critical, important and
/// other, and the full group timeline as a second segment. The same rules as
/// the notifications decide what appears, so nothing shows up twice.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  _Segment _segment = _Segment.alerts;

  @override
  Widget build(BuildContext context) {
    final groupId = context.select<ConvoyService, String?>((s) => s.activeGroupId);
    final gid = groupId;
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(automaticallyImplyLeading: false, title: const Text('Alerts')),
      body: gid == null
          ? const EmptyState(
              icon: Icons.notifications_none_rounded,
              title: 'No alerts right now',
              message: 'Alerts appear during a ride.',
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Space.s16, Space.s8, Space.s16, Space.s8),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<_Segment>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(0, 48))),
                      segments: const [
                        ButtonSegment(value: _Segment.alerts, label: Text('Alerts'), icon: Icon(Icons.notifications_rounded)),
                        ButtonSegment(value: _Segment.timeline, label: Text('Timeline'), icon: Icon(Icons.timeline_rounded)),
                      ],
                      selected: {_segment},
                      onSelectionChanged: (s) => setState(() => _segment = s.first),
                    ),
                  ),
                ),
                Expanded(
                  child: switch (_segment) {
                    _Segment.alerts => _AlertsList(onOpenTimeline: () => setState(() => _segment = _Segment.timeline)),
                    _Segment.timeline => LiveTimelineView(key: ValueKey(gid), groupId: gid),
                  },
                ),
              ],
            ),
    );
  }
}

class _AlertsList extends StatelessWidget {
  final VoidCallback onOpenTimeline;
  const _AlertsList({required this.onOpenTimeline});

  static String _firstName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'rider';
    final space = n.indexOf(' ');
    return space > 0 ? n.substring(0, space) : n;
  }

  static void _showOnMap(BuildContext context) => RiderHomeScreen.selectTab(context, HomeTab.ride);

  static Future<void> _call(BuildContext context, String phone) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(' ', '')));
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the phone app.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final facts = context.select<ConvoyService, AlertFacts>(alertFactsOf);
    final timeline = context.watch<TimelineService>();
    final alerts = alertsFor(facts, timeline, nowMs: DateTime.now().millisecondsSinceEpoch);

    // Your own SOS comes first. The notification rules leave it out, because the sender knows.
    final local = <Widget>[
      if (facts.mySosOpen)
        RideAlert(
          tier: AlertTier.critical,
          title: 'Your SOS is on',
          message: 'Your group can see where you are.',
          actionLabel: 'I am safe',
          onAction: () => context.read<ConvoyService>().cancelMySos(),
        )
      else if (facts.sosWaiting)
        RideAlert(
          tier: AlertTier.critical,
          title: 'SOS waiting for signal',
          message: 'It is sent as soon as the phone is back online.',
          actionLabel: 'I am safe',
          onAction: () => context.read<ConvoyService>().cancelMySos(),
        ),
    ];

    if (alerts.isEmpty && local.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'All clear',
        message: 'Nothing needs your attention. Every event of this ride is in the timeline.',
        primaryLabel: 'Open timeline',
        onPrimary: onOpenTimeline,
      );
    }

    final children = <Widget>[];
    void section(String title) => children.add(Padding(
          padding: const EdgeInsets.fromLTRB(0, Space.s16, 0, Space.s8),
          child: Semantics(header: true, child: Text(title, style: AppText.label)),
        ));

    final critical = alerts.where((a) => a.tier == AlertTier.critical).toList();
    final important = alerts.where((a) => a.tier == AlertTier.important).toList();
    final normal = alerts.where((a) => a.tier == AlertTier.normal).toList();
    final riders = context.read<ConvoyService>().activeConvoy?.riders ?? const {};

    Widget tile(InAppAlert a) {
      final uid = a.userId;
      final rider = uid == null ? null : riders[uid];
      final phone = rider?.phone.trim() ?? '';
      final other = uid != null && uid != facts.userId;
      final canCall = other && phone.isNotEmpty && a.tier == AlertTier.critical;
      final onMap = other && rider != null;
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RideAlert(
              tier: a.tier,
              title: a.spec.title,
              message: a.spec.body,
              actionLabel: onMap ? 'Show on map' : null,
              onAction: onMap ? () => _showOnMap(context) : null,
            ),
            if (canCall)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => _call(context, phone),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  icon: const Icon(Icons.call_rounded),
                  label: Text('Call ${_firstName(rider?.name ?? '')}', maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
          ],
        ),
      );
    }

    if (local.isNotEmpty || critical.isNotEmpty) {
      section('Critical');
      for (final w in local) {
        children.add(Padding(padding: const EdgeInsets.only(bottom: Space.s8), child: w));
      }
      children.addAll(critical.map(tile));
    }
    if (important.isNotEmpty) {
      section('Important');
      children.addAll(important.map(tile));
    }
    if (normal.isNotEmpty) {
      section('Updates');
      children.addAll(normal.map(tile));
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Space.s16, 0, Space.s16, Space.s24),
          children: children,
        ),
      ),
    );
  }
}
