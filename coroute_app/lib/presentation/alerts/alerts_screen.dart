import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../core/constants/network_constants.dart';
import '../../core/ui/ui.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/safety_wire.dart';
import '../../data/models/sos_alert_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/timeline_service.dart';
import '../../domain/notify/alert_policy.dart';
import '../../domain/notify/alert_priority.dart';
import '../ride/assist_banner.dart';
import '../ride/discovery_card.dart';
import '../ride/emergency_guidance.dart';
import '../ride/hazard_marker.dart';
import '../ride/incident_banner.dart';
import '../ride/incident_sheet.dart';
import '../ride/incident_view.dart';
import '../rider/rider_home_screen.dart';
import '../timeline/live_timeline_screen.dart';
import '../widgets/emergency_sos_sheet.dart';
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
/// [lat] and [lng] (my last position) add "3.4 km from you" to a new meeting point.
List<InAppAlert> alertsFor(AlertFacts f, TimelineService timeline, {required int nowMs, double? lat, double? lng}) {
  final uid = f.userId;
  if (f.groupId == null || uid == null || timeline.groupId != f.groupId) return const [];
  return inAppAlerts(
    timeline.events,
    AlertViewer(userId: uid, isLead: f.isLead, isSweeper: f.isSweeper, lat: lat, lng: lng),
    nowMs: nowMs,
  );
}

/// What a widget showing ride safety prompts depends on. SafetyService also
/// notifies every second while a crash alarm counts down; selecting this
/// text (not the list) keeps those ticks from rebuilding the ride screen.
String safetyPromptsSignature(SafetyService? s) =>
    (s?.prompts ?? const <SafetyPrompt>[]).map((p) => '${p.key}|${p.title}|${p.message}|${p.primaryLabel}|${p.secondaryLabel}').join('\n');

/// The prompts after selecting [safetyPromptsSignature] (null-safe when no SafetyService is provided).
List<SafetyPrompt> safetyPromptsOf(BuildContext context) {
  context.select<SafetyService?, String>(safetyPromptsSignature);
  return context.read<SafetyService?>()?.prompts ?? const <SafetyPrompt>[];
}

/// What the Alerts tab shows from the safety and discovery networks; a
/// value that changes only when one of them changes (not on positions).
String networkAlertsSignature(ConvoyService s) {
  final b = StringBuffer();
  final active = s.activeAssist;
  if (active != null) b.write('A${active.incidentId}:${active.myStatus.name}:${active.arrivalCheck};');
  for (final a in s.assistRequests) {
    b.write('R${a.incidentId}:${a.myStatus.name}:${a.arrivalCheck}:${a.lastUpdateAt};');
  }
  for (final h in s.hazards) {
    b.write('H${h.hazardId}:${h.level.name};');
  }
  for (final n in s.assistNotices) {
    b.write('N${n.incidentId}:${n.at};');
  }
  for (final e in s.encounters) {
    b.write('E${e.encounterId}:${e.type.name}:${e.riders}:${e.distanceM.round()}:${e.iWaved}:${e.theyWavedAt};');
  }
  return b.toString();
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

  /// Switches to the Ride tab, centres the map on the rider and opens their card.
  static void _showOnMap(BuildContext context, String userId) => RiderHomeScreen.showRiderOnMap(context, userId);

  static Future<void> _call(BuildContext context, String phone) async {
    final ok = await launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(' ', '')));
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open the phone app.')));
    }
  }

  /// My accepted request first, then the others (closed ones left out).
  static List<AssistRequest> _assists(ConvoyService s) {
    final out = <AssistRequest>[];
    final active = s.activeAssist;
    if (active != null) out.add(active);
    for (final a in s.assistRequests) {
      if (active != null && a.incidentId == active.incidentId) continue;
      if (assistStageOf(a) == AssistStage.closed) continue;
      out.add(a);
    }
    return out;
  }

  static void _imOk(BuildContext context) {
    final ok = context.read<ConvoyService>().sendCheckIn(CheckInResult.ok);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? 'Your group knows you are OK.' : 'Could not tell the group right now. Riding on also closes this alert.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final facts = context.select<ConvoyService, AlertFacts>(alertFactsOf);
    final timeline = context.watch<TimelineService>();
    // Open SOS and crash alerts (responders, medical) change this list; positions do not.
    context.select<ConvoyService, List<SosAlertModel>>((s) => s.activeConvoy?.activeAlerts ?? const <SosAlertModel>[]);
    // Assistance requests, accidents ahead, notices and nearby groups change it too.
    context.select<ConvoyService, String>(networkAlertsSignature);
    final guidance = context.watch<EmergencyGuidance?>();
    final prompts = safetyPromptsOf(context);
    // My position only for "km from you" text: read, not watched (no rebuild on every fix).
    final service = context.read<ConvoyService>();
    final myUid = facts.userId;
    final mePos = myUid == null ? null : service.activeConvoy?.riders[myUid];
    final now = DateTime.now().millisecondsSinceEpoch;
    final alerts = alertsFor(facts, timeline, nowMs: now, lat: mePos?.lat, lng: mePos?.lng);
    final convoy = service.activeConvoy;
    // Emergencies (SOS, crash, possible incident, no signal, no reply) get the big incident card
    // with Navigate and Open; the plain timeline row with the same key is then left out.
    final incidents = (convoy == null || myUid == null) ? const <IncidentView>[] : incidentsFor(convoy, timeline, myUid, now);
    final incidentKeys = {for (final i in incidents) i.key};

    // Someone else's emergency first, then my own SOS (the notification rules leave it out,
    // because the sender knows).
    final local = <Widget>[
      for (final i in incidents.where((x) => !x.isMe))
        IncidentBanner(
          incident: i,
          myLat: mePos?.lat,
          myLng: mePos?.lng,
          nowMs: now,
          route: convoy?.routeLine ?? const [],
          phone: convoy?.riders[i.subjectUserId]?.phone ?? '',
          onOpen: () => showIncidentSheet(context, convoyId: convoy?.groupId ?? '', subjectUserId: i.subjectUserId, alertId: i.alertId),
        ),
      if (facts.mySosOpen)
        RideAlert(
          tier: AlertTier.critical,
          title: 'Your SOS is on',
          message: 'Your group can see where you are.',
          actionLabel: 'View SOS',
          onAction: () => EmergencySosSheet.show(context, lat: mePos?.lat ?? 0.0, lng: mePos?.lng ?? 0.0),
        )
      else if (facts.sosWaiting)
        RideAlert(
          tier: AlertTier.critical,
          title: 'SOS waiting for signal',
          message: 'It is sent as soon as the phone is back online.',
          actionLabel: 'View SOS',
          onAction: () => EmergencySosSheet.show(context, lat: mePos?.lat ?? 0.0, lng: mePos?.lng ?? 0.0),
        ),
      // Assistance requests from other groups (also after "Can't assist": I can still help).
      for (final a in _assists(service))
        AssistBanner(
          request: a,
          myLat: mePos?.lat,
          myLng: mePos?.lng,
          route: convoy?.routeLine ?? const [],
          nowMs: now,
        ),
    ];

    // Automatic checks about me and this phone's own prompts ("Are you OK?", "Time for a break").
    Widget prompt(SafetyPrompt p) => RideAlert(
          tier: p.tier,
          title: p.title,
          message: p.message,
          actionLabel: p.primaryLabel,
          onAction: () => context.read<SafetyService>().answerPrompt(p.key),
          onDismiss: p.secondaryLabel == null ? null : () => context.read<SafetyService>().answerPrompt(p.key, primary: false),
        );
    final hazardViews = <String, HazardView>{for (final v in guidance?.hazards ?? const <HazardView>[]) v.hazard.hazardId: v};
    final localImportant = <Widget>[
      for (final h in service.hazards)
        if (guidance == null || hazardViews.containsKey(h.hazardId))
          HazardBanner(hazard: h, view: hazardViews[h.hazardId], onTap: () => RiderHomeScreen.selectTab(context, HomeTab.ride)),
      for (final i in incidents.where((x) => x.isMe && !x.isAlert))
        RideAlert(
          tier: AlertTier.important,
          title: i.title,
          message: "Automatic check. Tap I'm OK if you are fine.",
          actionLabel: "I'm OK",
          onAction: () => _imOk(context),
        ),
      for (final p in prompts.where((p) => p.tier != AlertTier.normal)) prompt(p),
    ];
    final social = AlertArbiter.socialAllowed(
      anyEmergency: incidents.any((i) => i.isAlert) || facts.mySosOpen || facts.sosWaiting,
      anyAssist: service.assistRequests.isNotEmpty || service.activeAssist != null,
      anyHazard: service.hazards.isNotEmpty,
    );
    final localNormal = <Widget>[
      for (final n in service.assistNotices)
        if (n.reason == AssistClosedReason.taken && now < n.at + NetworkConstants.assistTakenShowFor.inMilliseconds)
          const RideAlert(tier: AlertTier.normal, title: AssistTexts.takenTitle, message: AssistTexts.takenBody),
      for (final p in prompts.where((p) => p.tier == AlertTier.normal)) prompt(p),
      if (social)
        for (final e in service.encounters)
          DiscoveryCard(
            encounter: e,
            onView: () => showDiscoverySheet(context, e, onWave: () => service.wave(e.encounterId)),
            onWave: () => service.wave(e.encounterId),
            onIgnore: () => service.ignoreEncounter(e.encounterId),
          ),
    ];

    if (alerts.isEmpty && local.isEmpty && localImportant.isEmpty && localNormal.isEmpty) {
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

    final shown = alerts.where((a) => !incidentKeys.contains(a.key)).toList();
    final critical = shown.where((a) => a.tier == AlertTier.critical).toList();
    final important = shown.where((a) => a.tier == AlertTier.important).toList();
    final normal = shown.where((a) => a.tier == AlertTier.normal).toList();
    final riders = service.activeConvoy?.riders ?? const {};

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
              onAction: onMap ? () => _showOnMap(context, rider.userId) : null,
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
    Widget padded(Widget w) => Padding(padding: const EdgeInsets.only(bottom: Space.s8), child: w);
    if (important.isNotEmpty || localImportant.isNotEmpty) {
      section('Important');
      children.addAll(localImportant.map(padded));
      children.addAll(important.map(tile));
    }
    if (normal.isNotEmpty || localNormal.isNotEmpty) {
      section('Updates');
      children.addAll(localNormal.map(padded));
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
