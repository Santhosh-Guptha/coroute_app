import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
    // Header line: how many alerts need attention (critical and important), like the
    // canvas "3 unread · today" / "All caught up".
    final facts = context.select<ConvoyService, AlertFacts>(alertFactsOf);
    final timeline = context.watch<TimelineService>();
    final attention = gid == null ? 0 : alertsBadgeCount(facts, timeline);
    final subtitle = gid == null
        ? 'Alerts appear during a ride'
        : attention == 0
            ? 'All caught up'
            : '$attention ${attention == 1 ? 'alert needs' : 'alerts need'} attention';

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: DsScreenHeader(title: 'Alerts', subtitle: subtitle),
                ),
              ),
            ),
            if (gid != null)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Row(
                      children: [
                        _FilterPill(
                          label: 'Alerts',
                          icon: Icons.notifications_rounded,
                          selected: _segment == _Segment.alerts,
                          onTap: () => setState(() => _segment = _Segment.alerts),
                        ),
                        const SizedBox(width: 8),
                        _FilterPill(
                          label: 'Timeline',
                          icon: Icons.timeline_rounded,
                          selected: _segment == _Segment.timeline,
                          onTap: () => setState(() => _segment = _Segment.timeline),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: gid == null
                  ? const EmptyState(
                      icon: Icons.notifications_none_rounded,
                      title: 'No alerts right now',
                      message: 'Alerts appear during a ride.',
                    )
                  : switch (_segment) {
                      _Segment.alerts => _AlertsList(onOpenTimeline: () => setState(() => _segment = _Segment.timeline)),
                      _Segment.timeline => LiveTimelineView(key: ValueKey(gid), groupId: gid),
                    },
            ),
          ],
        ),
      ),
    );
  }
}

/// Canvas filter pill: 38 px, fully round, 2 px border; selected = solid teal.
class _FilterPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;
  const _FilterPill({required this.label, this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.white : AppTheme.text;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? AppTheme.brand : AppTheme.card,
        shape: StadiumBorder(side: BorderSide(color: selected ? AppTheme.brand : AppTheme.border, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(label, style: TextStyle(color: fg, fontSize: 13, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ),
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
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Could not open the phone app.')));
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
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
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
          RideAlert(tier: AlertTier.normal, title: AssistTexts.takenTitle, message: AssistTexts.takenBody),
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
          padding: EdgeInsets.fromLTRB(0, children.isEmpty ? 4 : 18, 0, 10),
          child: Semantics(header: true, child: DsSectionHeader(title)),
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
        padding: const EdgeInsets.only(bottom: 10),
        child: _AlertCard(
          tier: a.tier,
          title: a.spec.title,
          body: a.spec.body,
          atMs: a.at,
          riderName: rider?.name,
          actionLabel: onMap ? 'Show on map' : null,
          onAction: (other && rider != null) ? () => _showOnMap(context, rider.userId) : null,
          callLabel: canCall ? 'Call ${_firstName(rider?.name ?? '')}' : null,
          onCall: canCall ? () => _call(context, phone) : null,
        ),
      );
    }

    Widget padded(Widget w) => Padding(padding: const EdgeInsets.only(bottom: 10), child: w);
    if (local.isNotEmpty || critical.isNotEmpty) {
      section('Critical');
      children.addAll(local.map(padded));
      children.addAll(critical.map(tile));
    }
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
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          children: children,
        ),
      ),
    );
  }
}

/// One alert from the timeline, as on the canvas: a 44 px tinted badge with
/// the rider's initials (or the tier icon), title and time on one line, the
/// body under it, and the action in teal. The border follows the tier.
class _AlertCard extends StatelessWidget {
  final AlertTier tier;
  final String title;
  final String? body;
  final int atMs;
  final String? riderName;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? callLabel;
  final VoidCallback? onCall;

  const _AlertCard({
    required this.tier,
    required this.title,
    this.body,
    required this.atMs,
    this.riderName,
    this.actionLabel,
    this.onAction,
    this.callLabel,
    this.onCall,
  });

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1);
    return parts.first.substring(0, 1) + parts.last.substring(0, 1);
  }

  @override
  Widget build(BuildContext context) {
    final critical = tier == AlertTier.critical;
    final important = tier == AlertTier.important;
    final Color badgeFg = critical ? AppTheme.sos : (important ? AppTheme.warnText : AppTheme.accentText);
    final Color badgeBg = critical ? AppTheme.sos.withValues(alpha: 0.12) : (important ? AppTheme.warnTint : AppTheme.tint);
    final Color border = critical ? AppTheme.sos : (important ? AppTheme.warnBorder : AppTheme.border);
    final name = riderName?.trim() ?? '';
    final time = atMs > 0 ? DateFormat('HH:mm').format(DateTime.fromMillisecondsSinceEpoch(atMs)) : '';
    final b = body;
    final action = actionLabel;
    final call = callLabel;

    return Semantics(
      container: true,
      liveRegion: critical,
      child: DsCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        borderColor: border,
        onTap: onAction,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: badgeBg, borderRadius: BorderRadius.circular(14)),
              child: name.isNotEmpty
                  ? Text(
                      _initials(name).toUpperCase(),
                      textScaler: TextScaler.noScaling,
                      style: TextStyle(color: badgeFg, fontSize: 13, fontWeight: FontWeight.w800),
                    )
                  : Icon(tier.icon, size: 22, color: badgeFg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15)),
                      ),
                      if (time.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(time, style: AppText.caption.copyWith(fontSize: 11, fontWeight: FontWeight.w700)),
                      ],
                    ],
                  ),
                  if (b != null && b.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(b, maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(height: 1.4)),
                  ],
                  if (action != null || call != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (action != null)
                            Text(action, style: TextStyle(color: AppTheme.accentText, fontSize: 13, fontWeight: FontWeight.w800)),
                          if (call != null && onCall != null)
                            TextButton.icon(
                              onPressed: onCall,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 44),
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                foregroundColor: AppTheme.accentText,
                              ),
                              icon: const Icon(Icons.call_rounded, size: 18),
                              label: Text(call, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
