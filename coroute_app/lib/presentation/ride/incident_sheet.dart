import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/emergency_nav_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/medical_info.dart';
import '../../data/models/network_wire.dart';
import '../../data/models/outbox_item.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/safety_wire.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/timeline_service.dart';
import '../../domain/notify/relation.dart';
import '../../domain/tracking/geo_math.dart';
import '../alerts/alert_tiers.dart';
import 'emergency_guidance.dart';
import 'incident_banner.dart';
import 'incident_view.dart';
import 'navigate_to.dart';

/// Opens the incident sheet for [subjectUserId] (and [alertId] for an SOS or
/// crash): where they are, my distance and ETA, the nearest member, nearby
/// assistance from other groups, Navigate (in the app), Call, "I'm going" /
/// "I'm with them", who is already helping, medical info while the alert is
/// open, "Open in Google Maps" and "Mark as handled". For my own SOS it
/// offers "Help reached me" / "False alarm"; for an automatic check "I'm OK".
Future<void> showIncidentSheet(
  BuildContext context, {
  required String convoyId,
  required String subjectUserId,
  String? alertId,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (_) => SingleChildScrollView(
      child: IncidentSheetBody(convoyId: convoyId, subjectUserId: subjectUserId, alertId: alertId),
    ),
  );
}

/// The body of the incident sheet. Follows live changes (responders, the
/// alert closing) through ConvoyService and TimelineService.
class IncidentSheetBody extends StatelessWidget {
  final String convoyId;
  final String subjectUserId;
  final String? alertId;

  /// For "x min ago" in tests; defaults to now.
  final int? nowMs;

  const IncidentSheetBody({super.key, required this.convoyId, required this.subjectUserId, this.alertId, this.nowMs});

  static Future<void> _dial(BuildContext context, String phone) => dialNumber(context, phone);

  static String _first(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'rider';
    final i = n.indexOf(' ');
    return i > 0 ? n.substring(0, i) : n;
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final timeline = context.watch<TimelineService?>();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final convoy = service.allConvoys[convoyId];
    final myId = service.myUserId ?? '';
    final incidents = convoy == null ? const <IncidentView>[] : incidentsFor(convoy, timeline, myId, now);
    IncidentView? incident;
    for (final i in incidents) {
      final hit = alertId != null ? i.alertId == alertId : i.subjectUserId == subjectUserId;
      if (hit) {
        incident = i;
        break;
      }
    }
    final RiderModel? rider = convoy?.riders[subjectUserId];
    final inc = incident;
    if (inc == null) return _closed(context, rider);

    final me = convoy?.riders[myId];
    final viewer = alertViewerFor(convoy, myId);
    final isLead = viewer?.isLead ?? false;
    final ago = inc.startedAt > 0 ? formatAgo(Duration(milliseconds: (now - inc.startedAt).clamp(0, 1 << 40).toInt())) : null;
    final where = incidentDistanceText(inc, myLat: me?.lat, myLng: me?.lng);
    final phone = rider?.phone.trim() ?? '';
    final contact = rider?.emergencyContact.trim() ?? '';
    final id = inc.alertId;
    final canRespond = inc.isAlert && !inc.isMe && id != null && service.supports(ProtocolFeatures.respond);

    final emergency = inc.isAlert && !inc.isMe;
    final relation = emergency ? incidentRelationText(inc, myLat: me?.lat, myLng: me?.lng, route: convoy?.routeLine ?? const []) : null;
    final updated = (inc.isAlert && inc.positionAt > 0) ? Relation.lastUpdate(inc.positionAt, now) : null;
    final header = emergency
        ? _Header(
            incident: inc,
            title: 'EMERGENCY',
            what: [inc.summary, if (inc.auto) 'Automatic alert', if (inc.reportedByName.trim().isNotEmpty) 'Reported by ${inc.reportedByName.trim()}'].join('. '),
            where: relation ?? where,
            updated: updated,
          )
        : _Header(incident: inc, what: ago == null ? inc.what : '${inc.what}, $ago', where: where, updated: updated);

    if (inc.isMe) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: Space.s16),
          if (inc.isAlert) ...[
            NetworkStatusLines(incident: inc, forMe: true),
            _Responders(responders: inc.responders, now: now, forMe: true),
            const SizedBox(height: Space.s16),
            _BigButton(
              icon: Icons.check_circle_rounded,
              label: 'Help reached me',
              color: StatusColors.success,
              onPressed: () {
                service.cancelMySos(reason: ResolveReason.resolved);
                Navigator.of(context).maybePop();
              },
            ),
            const SizedBox(height: Space.s8),
            _BigButton(
              icon: Icons.do_not_disturb_on_rounded,
              label: 'False alarm',
              outlined: true,
              onPressed: () {
                service.cancelMySos(reason: ResolveReason.falseAlarm);
                Navigator.of(context).maybePop();
              },
            ),
          ] else ...[
            Text(
              inc.kind == IncidentKind.noReply
                  ? "Your lead was told you did not answer. Tap I'm OK so they know you are fine."
                  : "You stopped suddenly, so your group was asked to check on you. Tap I'm OK if you are fine.",
              style: AppText.body,
            ),
            const SizedBox(height: Space.s16),
            _BigButton(
              icon: Icons.check_circle_rounded,
              label: "I'm OK",
              color: StatusColors.success,
              onPressed: () {
                final ok = service.sendCheckIn(CheckInResult.ok);
                if (ok) {
                  Navigator.of(context).maybePop();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not tell the group right now. Riding on also closes this alert.')),
                  );
                }
              },
            ),
          ],
        ],
      );
    }

    final respond = canRespond ? _RespondButtons(service: service, alertId: id) : null;
    final responders = inc.isAlert ? _Responders(responders: inc.responders, now: now) : null;
    final medical = inc.isAlert ? inc.medical : null;

    Future<void> openMaps() async {
      final ok = await navigateTo(inc.lat, inc.lng, label: inc.who);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No map app found on this phone.')));
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: Space.s16),
        if (emergency) ...[
          _DistanceEta(incident: inc, myLat: me?.lat, myLng: me?.lng, relation: relation),
          NetworkStatusLines(incident: inc, myUserId: myId),
          const SizedBox(height: Space.s8),
        ],
        if (inc.hasPosition)
          _BigButton(
            icon: Icons.navigation_rounded,
            label: emergency ? 'Navigate to ${_first(inc.who)}' : 'Navigate',
            onPressed: emergency
                ? () => navigateToEmergency(
                      context,
                      NavTarget(kind: NavTargetKind.groupEmergency, ref: id ?? inc.subjectUserId, label: _first(inc.who)),
                      inc.lat,
                      inc.lng,
                    )
                : openMaps,
          ),
        if (phone.isNotEmpty) ...[
          const SizedBox(height: Space.s8),
          _BigButton(icon: Icons.call_rounded, label: 'Call ${_first(inc.who)}', outlined: true, onPressed: () => _dial(context, phone)),
        ],
        // The lead sees who is already helping first; everyone else first says if they go.
        if (isLead && responders != null) ...[const SizedBox(height: Space.s24), responders],
        if (respond != null) ...[const SizedBox(height: Space.s24), respond],
        if (!isLead && responders != null) ...[const SizedBox(height: Space.s24), responders],
        if (medical != null) ...[const SizedBox(height: Space.s24), MedicalCard(info: medical)],
        if (inc.isAlert && contact.isNotEmpty) ...[
          const SizedBox(height: Space.s16),
          _BigButton(
            icon: Icons.emergency_rounded,
            label: 'Call their emergency contact',
            outlined: true,
            onPressed: () => _dial(context, contact),
          ),
        ],
        if (emergency && inc.hasPosition) ...[
          const SizedBox(height: Space.s8),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.textPrimary),
            onPressed: openMaps,
            icon: const Icon(Icons.map_rounded),
            label: const Text('Open in Google Maps', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
        if (inc.isAlert && id != null) ...[
          const SizedBox(height: Space.s8),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.textPrimary),
            onPressed: () async {
              final ok = await confirmAction(
                context,
                title: "Mark ${inc.who}'s SOS as handled?",
                message: 'The SOS alert closes for the whole group. Do this only when ${inc.who} is safe or help is with them.',
                confirmLabel: 'Mark as handled',
                destructive: true,
              );
              if (!ok) return;
              service.resolveSosAlert(id);
              if (context.mounted) Navigator.of(context).maybePop();
            },
            icon: const Icon(Icons.task_alt_rounded),
            label: const Text('Mark as handled', maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ],
    );
  }

  Widget _closed(BuildContext context, RiderModel? rider) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.check_circle_rounded, size: 40, color: StatusColors.success),
          const SizedBox(height: Space.s8),
          Text('This alert is closed', textAlign: TextAlign.center, style: AppText.title),
          const SizedBox(height: Space.s4),
          Text(
            rider == null ? 'The rider is no longer in the ride.' : '${rider.name} is not in an open alert any more.',
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: Space.s16),
          OutlinedButton(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final IncidentView incident;
  final String what;
  final String? where;
  final String? title;
  final String? updated;

  const _Header({required this.incident, required this.what, this.where, this.title, this.updated});

  @override
  Widget build(BuildContext context) {
    final w = where;
    final u = updated;
    final Color accent = incident.isMe && !incident.isAlert ? StatusColors.warning : StatusColors.critical;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: accent.withOpacity(0.14), shape: BoxShape.circle),
            child: Icon(incidentIcon(incident.kind), color: accent, size: 28),
          ),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title ?? incident.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 2),
                Text(what, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: accent)),
                if (w != null) Text(w, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                if (u != null) Text(u, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                if (incident.placeName.isNotEmpty)
                  Text('Near ${incident.placeName}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A 56 dp full-width button (gloves, glance).
class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool outlined;
  final Color? color;

  const _BigButton({required this.icon, required this.label, required this.onPressed, this.outlined = false, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color;
    final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    if (outlined) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: onPressed,
        icon: Icon(icon),
        label: text,
      );
    }
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        backgroundColor: c,
        foregroundColor: c == null ? null : StatusColors.onCritical,
      ),
      onPressed: onPressed,
      icon: Icon(icon),
      label: text,
    );
  }
}

/// "I'm going" / "I'm with them": one tap answers, the chosen one shows a
/// tick, "Undo" takes it back. While the phone has no signal the answer
/// waits in the outbox and says "Waiting for signal".
class _RespondButtons extends StatelessWidget {
  final ConvoyService service;
  final String alertId;

  const _RespondButtons({required this.service, required this.alertId});

  void _send(BuildContext context, SosResponseKind kind) {
    final ok = service.respondToSos(alertId, kind);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not send your answer. Try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mine = service.myResponseTo(alertId);
    OutboxItem? pending;
    for (final o in service.outbox) {
      if (o.type == 'SOS_RESPOND' && o.payload['alertId']?.toString() == alertId) pending = o;
    }
    final p = pending;
    final failed = p != null && p.state == OutboxState.failed;

    Widget choice(SosResponseKind kind, IconData icon, String label) {
      final selected = mine == kind;
      final text = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
      void tap() => _send(context, selected ? SosResponseKind.cancel : kind);
      return Semantics(
        selected: selected,
        child: selected
            ? FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  backgroundColor: StatusColors.success,
                  foregroundColor: StatusColors.onCritical,
                ),
                onPressed: tap,
                icon: const Icon(Icons.check_rounded),
                label: text,
              )
            : OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: tap,
                icon: Icon(icon),
                label: text,
              ),
      );
    }

    final going = choice(SosResponseKind.going, Icons.directions_run_rounded, "I'm going");
    final withThem = choice(SosResponseKind.withThem, Icons.handshake_rounded, "I'm with them");
    final m = mine;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(header: true, child: Text('Tell the group', style: AppText.label)),
        const SizedBox(height: Space.s8),
        LayoutBuilder(builder: (context, c) {
          // Side by side only when both labels fit at the rider's text size.
          final wide = c.maxWidth >= 420;
          if (wide) {
            return Row(children: [Expanded(child: going), const SizedBox(width: Space.s8), Expanded(child: withThem)]);
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [going, const SizedBox(height: Space.s8), withThem],
          );
        }),
        if (m != null && m != SosResponseKind.cancel)
          Row(
            children: [
              Expanded(
                child: Text(
                  m == SosResponseKind.going ? 'You said you are on the way.' : 'You said you are with them.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                onPressed: () => _send(context, SosResponseKind.cancel),
                child: const Text('Undo'),
              ),
            ],
          ),
        if (p != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.s4),
            child: QueuedLine(failed: failed, sending: service.isOnline),
          ),
      ],
    );
  }
}

/// "Waiting for signal" (or "Not sent") under something that is queued.
class QueuedLine extends StatelessWidget {
  final bool failed;

  /// What is waiting, e.g. "Your stop reason" ("Your stop reason, waiting for signal").
  final String? what;

  /// Connected: the item is on its way (waiting for the server's receipt), so it says "Sending".
  final bool sending;

  const QueuedLine({super.key, this.failed = false, this.what, this.sending = false});

  /// The words shown (pure, for tests).
  static String textFor({bool failed = false, String? what, bool sending = false}) {
    final base = failed ? 'Not sent' : (sending ? 'Sending' : 'Waiting for signal');
    final w = what;
    return w == null || w.isEmpty ? base : '$w, ${base.toLowerCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final Color c = failed ? StatusColors.critical : StatusColors.warning;
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(failed ? Icons.error_outline_rounded : Icons.schedule_rounded, size: 16, color: c),
          const SizedBox(width: Space.s4),
          Flexible(
            child: Text(textFor(failed: failed, what: what, sending: sending), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: c)),
          ),
        ],
      ),
    );
  }
}

/// Who answered: "Arjun, on the way, 2 min ago".
class _Responders extends StatelessWidget {
  final List<SosResponder> responders;
  final int now;
  final bool forMe;

  const _Responders({required this.responders, required this.now, this.forMe = false});

  @override
  Widget build(BuildContext context) {
    final list = responders.where((r) => r.kind != SosResponseKind.cancel).toList()..sort((a, b) => b.at.compareTo(a.at));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(list.isEmpty ? 'Who is helping' : 'Who is helping (${list.length})', style: AppText.label),
        ),
        const SizedBox(height: Space.s8),
        if (list.isEmpty)
          Text(forMe ? 'No one has answered yet. Your group can see where you are.' : 'No one has answered yet.', style: AppText.body.copyWith(color: AppTheme.textSecondary))
        else
          for (final r in list)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s4),
              child: Row(
                children: [
                  Icon(r.kind == SosResponseKind.withThem ? Icons.handshake_rounded : Icons.directions_run_rounded, size: 20, color: StatusColors.success),
                  const SizedBox(width: Space.s8),
                  Expanded(
                    child: Text(
                      [
                        r.name.trim().isEmpty ? 'A rider' : r.name.trim(),
                        responderWords(r.kind),
                        if (r.at > 0) formatAgo(Duration(milliseconds: (now - r.at).clamp(0, 1 << 40).toInt())),
                      ].join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Medical info of the rider in an open SOS or crash alert.
class MedicalCard extends StatelessWidget {
  final MedicalInfo info;
  const MedicalCard({super.key, required this.info});

  /// The lines shown, e.g. "Blood group O+", "Allergies: penicillin".
  static List<String> linesOf(MedicalInfo info) => [
        if (info.bloodGroup.trim().isNotEmpty) 'Blood group ${info.bloodGroup.trim()}',
        if (info.allergies.trim().isNotEmpty) 'Allergies: ${info.allergies.trim()}',
        if (info.notes.trim().isNotEmpty) 'Notes: ${info.notes.trim()}',
      ];

  @override
  Widget build(BuildContext context) {
    final lines = linesOf(info);
    if (lines.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(
        color: AppTheme.elevatedCard,
        borderRadius: Radii.mdAll,
        border: Border.all(color: AppTheme.subtleBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.medical_information_rounded, size: 20, color: StatusColors.critical),
              const SizedBox(width: Space.s8),
              Expanded(child: Semantics(header: true, child: Text('Medical info', style: AppText.label))),
            ],
          ),
          const SizedBox(height: Space.s8),
          for (final l in lines) Text(l, maxLines: 4, overflow: TextOverflow.ellipsis, style: AppText.body),
          const SizedBox(height: Space.s4),
          Text('Shown only while this alert is open.', style: AppText.caption),
        ],
      ),
    );
  }
}

/// "Your distance: 4.8 km behind your location" and "Your ETA: about 9 min"
/// (from the in-app navigation when it leads there, else a rough guess).
class _DistanceEta extends StatelessWidget {
  final IncidentView incident;
  final double? myLat;
  final double? myLng;
  final String? relation;

  const _DistanceEta({required this.incident, this.myLat, this.myLng, this.relation});

  @override
  Widget build(BuildContext context) {
    final guidance = context.watch<EmergencyGuidance?>();
    final la = myLat, ln = myLng;
    final id = incident.alertId;
    Duration? eta;
    if (guidance != null && id != null && guidance.isTarget(NavTargetKind.groupEmergency, id)) eta = guidance.eta;
    if (eta == null && la != null && ln != null && (la != 0 || ln != 0) && incident.hasPosition) {
      final m = GeoMath.haversine(la, ln, incident.lat, incident.lng);
      if (m.isFinite) {
        eta = Duration(seconds: (m * EmergencyNavConstants.straightDetourFactor / (EmergencyNavConstants.straightSpeedKmh / 3.6)).round());
      }
    }
    final r = relation;
    final e = eta;
    if (r == null && e == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (r != null) InfoLine(icon: Icons.social_distance_rounded, text: 'Your distance: $r'),
          if (e != null) InfoLine(icon: Icons.schedule_rounded, text: 'Your ETA: about ${formatDuration(Duration(minutes: e.inSeconds <= 60 ? 1 : (e.inSeconds / 60).round()))}'),
        ],
      ),
    );
  }
}

/// One plain line with an icon (status never by colour alone).
class InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;
  const InfoLine({super.key, required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppTheme.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: c),
          const SizedBox(width: Space.s8),
          Expanded(child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.body)),
        ],
      ),
    );
  }
}

/// The safety network lines of an open group emergency: the nearest member
/// ("Nearest member: Arjun, ETA 9 min"), nearby assistance from another
/// group (green: "Nearby assistance: Arjun, ETA 3 min, En route", never the
/// other group's name), "Asking nearby riders" / "No nearby riders found",
/// and "A nearby rider reported they are at the scene".
class NetworkStatusLines extends StatelessWidget {
  final IncidentView incident;
  final String myUserId;

  /// My own SOS: the lines speak to me ("A nearby rider is responding").
  final bool forMe;

  const NetworkStatusLines({super.key, required this.incident, this.myUserId = '', this.forMe = false});

  static String _clock(BuildContext context, int ms) {
    final t = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms));
    return MaterialLocalizations.of(context).formatTimeOfDay(t, alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));
  }

  @override
  Widget build(BuildContext context) {
    final net = incident.network;
    final own = incident.ownNearest;
    final lines = <Widget>[];
    if (own != null && !forMe) {
      final eta = etaWords(own.etaS);
      final who = own.userId == myUserId ? 'You' : (own.name.trim().isEmpty ? 'A rider' : own.name.trim());
      lines.add(InfoLine(
        icon: Icons.groups_rounded,
        text: who == 'You' ? 'You are the nearest member${eta == null ? '' : ', $eta'}' : 'Nearest member: $who${eta == null ? '' : ', $eta'}',
      ));
    }
    if (net != null) {
      final r = net.activeResponder;
      if (r != null) {
        final name = r.name.trim().isEmpty ? 'A nearby rider' : r.name.trim();
        if (r.status == ResponderStatus.arrived) {
          final at = r.arrivedAt > 0 ? '. Reached ${_clock(context, r.arrivedAt)}' : '';
          lines.add(PositiveLine(
            text: forMe ? 'A nearby rider has reached you' : 'Nearby rider has reached ${incident.firstName}',
            detail: 'Responder: $name$at',
          ));
        } else {
          final parts = <String>[
            forMe ? 'A nearby rider is responding' : 'Nearby assistance: $name',
            ?etaWords(r.etaS),
            responderStatusWords(r.status),
          ];
          lines.add(PositiveLine(text: parts.join(', '), detail: forMe ? null : '$name from a nearby riding group'));
        }
      } else {
        final words = networkStateWords(net.state);
        if (words != null) lines.add(InfoLine(icon: Icons.person_search_rounded, text: words));
      }
      for (final x in net.responders) {
        if (x.status == ResponderStatus.unableToReach && x.reason == 'NOT_FOUND') {
          final name = x.name.trim().isEmpty ? 'A nearby rider' : x.name.trim();
          lines.add(InfoLine(icon: Icons.location_searching_rounded, text: '$name could not find ${forMe ? 'you' : incident.firstName}'));
        }
      }
      if (net.onScene) lines.add(InfoLine(icon: Icons.place_rounded, text: 'A nearby rider reported they are at the scene'));
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.s8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: Space.s4), child: l),
        ],
      ),
    );
  }
}
