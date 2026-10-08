import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/emergency_nav_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/outbox_item.dart';
import '../../data/services/convoy_service.dart';
import '../../domain/notify/relation.dart';
import '../../domain/tracking/geo_math.dart';
import 'assist_sheet.dart';
import 'emergency_guidance.dart';
import 'incident_banner.dart';
import 'incident_sheet.dart';
import 'incident_view.dart';

/// Which face of an assistance request to show.
enum AssistStage {
  /// Asked, not answered yet (also after "Can't assist" or no answer: the rider may still help).
  request,

  /// I said I can help and I am on the way.
  responding,

  /// Near the point: "Have you reached the rider?"
  arrivalCheck,

  /// I found them.
  onScene,

  /// I said I cannot reach them, or I cancelled.
  closed,
}

/// The stage of [a]; [near] is true when this phone sees me within
/// [EmergencyNavConstants.arrivalAskM] of the point.
AssistStage assistStageOf(AssistRequest a, {bool near = false}) {
  switch (a.myStatus) {
    case ResponderStatus.requested:
    case ResponderStatus.timeout:
    case ResponderStatus.declined:
      return AssistStage.request;
    case ResponderStatus.accepted:
    case ResponderStatus.enRoute:
    case ResponderStatus.arriving:
      return (a.arrivalCheck || near) ? AssistStage.arrivalCheck : AssistStage.responding;
    case ResponderStatus.arrived:
      return AssistStage.onScene;
    case ResponderStatus.unableToReach:
    case ResponderStatus.cancelled:
      return AssistStage.closed;
  }
}

/// Texts of an assistance request. Before I accept they carry no name, no
/// group and nothing about the rider (minimum information).
class AssistTexts {
  AssistTexts._();

  static const String requestTitle = 'RIDER EMERGENCY NEARBY';
  static const String faster = 'Your group may be able to reach them before their own group.';
  static const String responding = 'You are responding';
  static const String arrivalQuestion = 'Have you reached the rider?';
  static const String takenTitle = 'Another nearby rider is responding';
  static const String takenBody = 'No assistance is currently required.';

  /// "A rider from another group may have met with an accident."
  static String what(AssistRequest a) => a.kind.toUpperCase() == 'EMERGENCY'
      ? 'A rider from another group may need help.'
      : 'A rider from another group may have met with an accident.';

  /// Metres to the point: the in-app route when it leads there, else straight from me, else what the server said.
  static double distanceOf(AssistRequest a, {double? myLat, double? myLng, double? liveM}) {
    final live = liveM;
    if (live != null && live.isFinite) return live;
    final la = myLat, ln = myLng;
    if (la != null && ln != null && (la != 0 || ln != 0)) {
      final m = GeoMath.haversine(la, ln, a.lat, a.lng);
      if (m.isFinite) return m;
    }
    return a.distanceM;
  }

  /// "1.6 km ahead on your route" (along my route when both are on it), or the server's distance.
  static String where(AssistRequest a, {double? myLat, double? myLng, List<(double, double)> route = const []}) {
    final la = myLat, ln = myLng;
    if (la != null && ln != null && (la != 0 || ln != 0)) {
      return Relation.text(myLat: la, myLng: ln, lat: a.lat, lng: a.lng, route: route);
    }
    final d = Relation.distanceText(a.distanceM);
    return a.aheadOnRoute ? '$d ahead on your route' : '$d from you';
  }

  /// "RIDER EMERGENCY 1.2 km ahead" (after I accepted).
  static String respondingTitle(AssistRequest a, double distanceM) =>
      'RIDER EMERGENCY ${Relation.distanceText(distanceM)} ${a.aheadOnRoute ? 'ahead' : 'away'}';
}

/// Sends an answer and says so when it could not be queued.
void sendAssistAnswer(BuildContext context, String incidentId, AssistAnswer answer) {
  final ok = context.read<ConvoyService>().answerAssist(incidentId, answer);
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not send your answer. Try again.')));
  }
}

/// "I Can Help": accepts and starts the in-app navigation to the point.
void acceptAssist(BuildContext context, AssistRequest a) {
  final ok = context.read<ConvoyService>().answerAssist(a.incidentId, AssistAnswer.accept);
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not send your answer. Try again.')));
    return;
  }
  navigateToEmergency(context, NavTarget(kind: NavTargetKind.assist, ref: a.incidentId), a.lat, a.lng);
}

/// Starts the in-app navigation to the request's point (no answer is sent).
void navigateToAssist(BuildContext context, AssistRequest a) =>
    navigateToEmergency(context, NavTarget(kind: NavTargetKind.assist, ref: a.incidentId), a.lat, a.lng).ignore();

/// The critical banner for an assistance request from another group
/// ("RIDER EMERGENCY NEARBY"): red like an emergency, with its own label and
/// icon so it never reads as my group's own emergency. Big single-tap
/// buttons, no typing, no scrolling:
/// * request: **I Can Help** / **Navigate** / **Can't Assist**;
/// * responding: "RIDER EMERGENCY 1.2 km ahead", "ETA 3 min", "You are
///   responding", **Navigate** / **Unable to Assist** / **Arrived**;
/// * arrival check: "Have you reached the rider?" **Yes, I Found Them** /
///   **Unable to Locate**;
/// * on scene: "Call emergency services 112".
/// A tap on the text opens the sheet. Static: no timers.
class AssistBanner extends StatelessWidget {
  final AssistRequest request;
  final double? myLat;
  final double? myLng;

  /// My group's route (for "ahead on your route").
  final List<(double, double)> route;

  /// For "Last location update"; defaults to now.
  final int? nowMs;

  /// Opens the sheet (defaults to [showAssistSheet]).
  final VoidCallback? onOpen;

  const AssistBanner({
    super.key,
    required this.request,
    this.myLat,
    this.myLng,
    this.route = const [],
    this.nowMs,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final a = request;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final guidance = context.watch<EmergencyGuidance?>();
    final navigating = guidance != null && guidance.isTarget(NavTargetKind.assist, a.incidentId);
    final liveM = (guidance != null && navigating) ? guidance.remainingM : null;
    final liveEtaS = (guidance != null && navigating) ? guidance.eta?.inSeconds : null;
    final distance = AssistTexts.distanceOf(a, myLat: myLat, myLng: myLng, liveM: liveM);
    final near = distance <= EmergencyNavConstants.arrivalAskM;
    final stage = assistStageOf(a, near: near);
    final compact = MediaQuery.sizeOf(context).height < 480;
    final updated = a.lastUpdateAt > 0 ? Relation.lastUpdate(a.lastUpdateAt, now) : null;
    final Color bg = StatusColors.critical;
    final Color fg = StatusColors.onCritical;
    final open = onOpen ?? () => showAssistSheet(context, incidentId: a.incidentId);

    String title;
    final lines = <String>[];
    switch (stage) {
      case AssistStage.request:
      case AssistStage.closed:
        title = AssistTexts.requestTitle;
        lines.add(AssistTexts.what(a));
        lines.add(AssistTexts.where(a, myLat: myLat, myLng: myLng, route: route));
        if (a.fasterThanGroup && !compact) lines.add(AssistTexts.faster);
        break;
      case AssistStage.responding:
        title = AssistTexts.respondingTitle(a, distance);
        final eta = etaWords(liveEtaS ?? a.etaS);
        if (eta != null) lines.add(eta);
        break;
      case AssistStage.arrivalCheck:
        title = AssistTexts.arrivalQuestion;
        lines.add('The emergency point is ${Relation.distanceText(distance)} away.');
        break;
      case AssistStage.onScene:
        title = 'You are with the rider';
        lines.add('Call emergency services 112 if they need more help.');
        break;
    }
    if (updated != null && !compact && stage != AssistStage.onScene) lines.add(updated);

    final ButtonStyle outlined = OutlinedButton.styleFrom(
      foregroundColor: fg,
      side: BorderSide(color: fg, width: 1.5),
      minimumSize: const Size.fromHeight(48),
      padding: const EdgeInsets.symmetric(horizontal: Space.s8),
    );
    final ButtonStyle primary = FilledButton.styleFrom(
      backgroundColor: fg,
      foregroundColor: bg,
      minimumSize: const Size.fromHeight(56),
      padding: const EdgeInsets.symmetric(horizontal: Space.s8),
    );
    Widget filled(IconData icon, String label, VoidCallback onTap, {ButtonStyle? style}) => FilledButton.icon(
          onPressed: onTap,
          style: style ?? primary,
          icon: Icon(icon),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    Widget outline(IconData icon, String label, VoidCallback onTap) => OutlinedButton.icon(
          onPressed: onTap,
          style: outlined,
          icon: Icon(icon),
          label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    Widget pair(Widget x, Widget y) => Row(children: [Expanded(child: x), const SizedBox(width: Space.s8), Expanded(child: y)]);

    final List<Widget> actions;
    switch (stage) {
      case AssistStage.request:
      case AssistStage.closed:
        actions = [
          filled(Icons.volunteer_activism_rounded, "I Can Help", () => acceptAssist(context, a)),
          const SizedBox(height: Space.s8),
          pair(
            outline(Icons.navigation_rounded, 'Navigate', () => navigateToAssist(context, a)),
            outline(Icons.block_rounded, "Can't Assist", () => sendAssistAnswer(context, a.incidentId, AssistAnswer.decline)),
          ),
        ];
        break;
      case AssistStage.responding:
        actions = [
          filled(Icons.navigation_rounded, 'Navigate', () => navigateToAssist(context, a)),
          const SizedBox(height: Space.s8),
          pair(
            outline(Icons.do_not_disturb_on_rounded, 'Unable to Assist', () => sendAssistAnswer(context, a.incidentId, AssistAnswer.unable)),
            outline(Icons.flag_rounded, 'Arrived', () => sendAssistAnswer(context, a.incidentId, AssistAnswer.arrived)),
          ),
        ];
        break;
      case AssistStage.arrivalCheck:
        actions = [
          filled(
            Icons.check_circle_rounded,
            'Yes, I Found Them',
            () => sendAssistAnswer(context, a.incidentId, AssistAnswer.arrived),
            style: FilledButton.styleFrom(
              backgroundColor: StatusColors.success,
              foregroundColor: fg,
              side: BorderSide(color: fg, width: 1.5),
              minimumSize: const Size.fromHeight(56),
              padding: const EdgeInsets.symmetric(horizontal: Space.s8),
            ),
          ),
          const SizedBox(height: Space.s8),
          outline(Icons.location_searching_rounded, 'Unable to Locate', () => sendAssistAnswer(context, a.incidentId, AssistAnswer.notFound)),
        ];
        break;
      case AssistStage.onScene:
        actions = [
          pair(
            outline(Icons.local_hospital_rounded, 'Call 112', () => dialNumber(context, '112')),
            outline(Icons.open_in_full_rounded, 'Details', open),
          ),
        ];
        break;
    }

    final service = context.read<ConvoyService>();
    OutboxItem? pending;
    for (final o in service.outbox) {
      if (o.type == 'ASSIST_ANSWER' && o.payload['incidentId']?.toString() == a.incidentId) pending = o;
    }
    final p = pending;

    return Semantics(
      container: true,
      liveRegion: true,
      label: [title, ...lines].join('. '),
      child: Material(
        color: bg,
        elevation: 2,
        shadowColor: AppTheme.shadow,
        shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(Space.s12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExcludeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.emergency_share_rounded, color: fg, size: 28),
                      const SizedBox(width: Space.s12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(color: fg, fontWeight: FontWeight.w800)),
                            for (var i = 0; i < lines.length; i++)
                              Text(
                                lines[i],
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: (i == 1 && stage == AssistStage.request)
                                    ? AppText.label.copyWith(color: fg, fontWeight: FontWeight.w700)
                                    : AppText.label.copyWith(color: fg, fontWeight: FontWeight.w400),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (stage == AssistStage.responding) ...[
                  const SizedBox(height: Space.s8),
                  const PositiveLine(text: AssistTexts.responding),
                ],
                const SizedBox(height: Space.s8),
                ...actions,
                if (p != null)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.s4),
                    child: Semantics(
                      liveRegion: true,
                      child: Row(
                        children: [
                          Icon(p.state == OutboxState.failed ? Icons.error_outline_rounded : Icons.schedule_rounded, size: 16, color: fg),
                          const SizedBox(width: Space.s4),
                          Expanded(
                            child: Text(
                              QueuedLine.textFor(failed: p.state == OutboxState.failed, sending: service.isOnline, what: 'Your answer'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.caption.copyWith(color: fg),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

