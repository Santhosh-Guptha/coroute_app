import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/intercom_service.dart';
import '../../data/services/timeline_service.dart';
import '../../domain/ride/ride_facts.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/timeline/timeline_text.dart';
import '../timeline/member_colors.dart';
import 'incident_sheet.dart';
import 'incident_view.dart';
import 'riders_ladder.dart';

/// Opens the compact rider card (a sheet, never a new screen): name, status,
/// distance from me, speed, last update, distance to the destination, and
/// the actions Show on map, Call, Talk privately, Pair as pillion. When the
/// rider has an open SOS it also offers "Mark as handled" (confirmed first).
Future<void> showRiderCard(
  BuildContext context, {
  required String convoyId,
  required String userId,
  required ValueChanged<RiderModel> onShowOnMap,
}) {
  return showAppSheet<void>(
    context,
    isScrollControlled: true,
    builder: (ctx) => SingleChildScrollView(
      child: RiderCard(convoyId: convoyId, userId: userId, onShowOnMap: onShowOnMap),
    ),
  );
}

/// The body of the rider card. Follows live updates of the rider.
class RiderCard extends StatelessWidget {
  final String convoyId;
  final String userId;
  final ValueChanged<RiderModel> onShowOnMap;

  const RiderCard({super.key, required this.convoyId, required this.userId, required this.onShowOnMap});

  static Future<void> _call(BuildContext context, String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot call $clean')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final ConvoyModel? convoy = service.allConvoys[convoyId];
    final r = convoy?.riders[userId];
    if (convoy == null || r == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.s24),
        child: Text('This rider is no longer in the ride.', style: AppText.body),
      );
    }
    final myId = service.myUserId ?? '';
    final isMe = myId.isNotEmpty && r.userId == myId;
    final me = convoy.riders[myId];
    final now = DateTime.now().millisecondsSinceEpoch;
    final status = riderStatusOf(r, convoy,
        isMe: isMe, nowMs: now, online: service.isOnline, gpsActive: service.isRealGpsActive, myAccuracyM: service.myFixAccuracyM);
    // Why the position is old ("No signal since 10:42 near Hosur", "App closed on this phone"),
    // and any open emergency about this rider (SOS, crash, possible incident, no signal, no reply).
    final timeline = context.watch<TimelineService?>();
    final offline = timeline?.groupId == convoy.groupId ? timeline?.openFor(r.userId, 'OFFLINE') : null;
    final presence = presenceLine(r, isMe: isMe, place: offline?.placeName ?? '', clock: (ms) => presenceClock(context, ms));
    final detail = presence == null ? riderStatusDetail(r, status, nowMs: now) : null;
    IncidentView? incident;
    for (final i in incidentsFor(convoy, timeline, myId, now)) {
      if (i.subjectUserId == r.userId) {
        incident = i;
        break;
      }
    }
    final inc = incident;
    final colors = MemberColors.assign(convoy.riders.keys);
    final line = convoy.routeLine;

    // Distance from me, ahead or behind along the ride when that is known.
    double? fromMe;
    bool? ahead;
    if (!isMe && me != null && RideFacts.hasPosition(me) && RideFacts.hasPosition(r)) {
      final pm = RideFacts.progressM(me, line, destLat: convoy.destinationLat, destLng: convoy.destinationLng);
      final pr = RideFacts.progressM(r, line, destLat: convoy.destinationLat, destLng: convoy.destinationLng);
      if (pm != null && pr != null) {
        fromMe = (pr - pm).abs();
        if (fromMe > RideFacts.sameSpotM) ahead = pr > pm;
      } else {
        fromMe = GeoMath.haversine(me.lat, me.lng, r.lat, r.lng);
      }
    }
    final toDest = RideFacts.remainingM(lat: r.lat, lng: r.lng, line: line, destLat: convoy.destinationLat, destLng: convoy.destinationLng);
    final openSos = convoy.activeAlerts.where((a) => !a.resolved && a.userId == r.userId).toList();
    final ic = context.watch<IntercomService?>();
    final pairedWithThem = me != null && me.isCoRiding && me.ridingWithUserId == r.userId;
    final reason = riderReasonText(r);

    (String, String?) split(double? m) {
      if (m == null) return ('-', null);
      final parts = formatDistanceRounded(m).split(' ');
      return (parts.first, parts.length > 1 ? parts[1] : null);
    }

    final (fromVal, fromUnit) = split(fromMe);
    final (destVal, destUnit) = split(toDest);

    Widget action(IconData icon, String label, VoidCallback onTap, {bool primary = false}) {
      const min = Size.fromHeight(48);
      return Padding(
        padding: const EdgeInsets.only(top: Space.s8),
        child: primary
            ? FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: min),
                onPressed: onTap,
                icon: Icon(icon),
                label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis))
            : OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: min),
                onPressed: onTap,
                icon: Icon(icon),
                label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            RiderAvatar(name: r.name, color: colors[r.userId], status: status, size: 56),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(isMe ? '${r.name} (You)' : r.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title),
                  ),
                  Text(
                    [r.vehicleType, if (r.vehicleNo.isNotEmpty) r.vehicleNo, if (r.role == 'LEAD') 'Lead', if (r.role == 'SWEEPER') 'Sweeper'].join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption,
                  ),
                  const SizedBox(height: Space.s4),
                  Wrap(
                    spacing: Space.s8,
                    runSpacing: Space.s4,
                    children: [
                      RiderStatusChip(status: status, detail: detail),
                      if (inc != null && inc.kind == IncidentKind.possibleIncident) const PossibleIncidentChip(),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (presence != null) ...[
          const SizedBox(height: Space.s8),
          PresenceText(rider: r, text: presence),
        ],
        if (inc != null && !isMe)
          action(Icons.emergency_rounded, 'Open alert', () {
            final nav = Navigator.of(context);
            nav.pop();
            showIncidentSheet(nav.context, convoyId: convoyId, subjectUserId: r.userId, alertId: inc.alertId);
          }, primary: true),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: Space.s8),
          Text('Reason: $reason', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body),
        ],
        const SizedBox(height: Space.s16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: RideMetric(
                value: fromVal,
                unit: fromUnit,
                label: isMe ? 'From you' : (ahead == null ? 'From you' : (ahead ? 'Ahead of you' : 'Behind you')),
              ),
            ),
            Expanded(child: RideMetric(value: r.speedKmh.isFinite ? r.speedKmh.round().toString() : '0', unit: 'km/h', label: 'Speed')),
            Expanded(child: RideMetric(value: destVal, unit: destUnit, label: 'To destination')),
          ],
        ),
        const SizedBox(height: Space.s8),
        Text(
          [
            r.lastSeenEpochMs > 0 ? 'Last update ${formatAgo(Duration(milliseconds: now - r.lastSeenEpochMs))}' : 'No update yet',
            'battery ${r.batteryLevel}%${r.isCharging ? ', charging' : ''}',
          ].join(', '),
          style: AppText.caption,
        ),
        if (!isMe && r.emergencyContact.isNotEmpty) ...[
          const SizedBox(height: Space.s4),
          Text(
            'Emergency contact: ${r.emergencyContactName.isNotEmpty ? '${r.emergencyContactName}, ' : ''}${r.emergencyContact}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption,
          ),
        ],
        if (openSos.isNotEmpty) ...[
          const SizedBox(height: Space.s12),
          RideAlert(
            tier: AlertTier.critical,
            title: isMe ? 'Your SOS is on' : 'SOS: ${r.name} needs help',
            message: TimelineText.reason(openSos.last.alertType),
          ),
          if (!isMe)
            action(Icons.task_alt_rounded, 'Mark SOS as handled', () async {
              final ok = await confirmAction(
                context,
                title: "Mark ${r.name}'s SOS as handled?",
                message: 'The SOS alert closes for the whole group. Do this only when ${r.name} is safe or help is with them.',
                confirmLabel: 'Mark as handled',
                destructive: true,
              );
              if (ok) service.resolveSosAlert(openSos.last.alertId);
            }),
        ],
        const SizedBox(height: Space.s8),
        if (RideFacts.hasPosition(r))
          action(Icons.near_me_rounded, 'Show on map', () {
            Navigator.pop(context);
            onShowOnMap(r);
          }, primary: true),
        if (!isMe && r.phone.isNotEmpty) action(Icons.call_rounded, 'Call ${r.name.split(' ').first}', () => _call(context, r.phone)),
        if (!isMe && r.emergencyContact.isNotEmpty && openSos.isNotEmpty)
          action(Icons.emergency_rounded, 'Call their emergency contact', () => _call(context, r.emergencyContact)),
        if (!isMe && ic != null)
          action(
            ic.talkTargetUserId == r.userId ? Icons.groups_rounded : Icons.lock_rounded,
            ic.talkTargetUserId == r.userId ? 'Talk to everyone again' : 'Talk privately',
            () {
              if (ic.talkTargetUserId == r.userId) {
                ic.setTalkTarget();
              } else {
                ic.setTalkTarget(userId: r.userId, name: r.name);
              }
            },
          ),
        if (!isMe && me != null)
          action(
            pairedWithThem ? Icons.link_off_rounded : Icons.link_rounded,
            pairedWithThem ? 'Stop riding as pillion' : 'I am their pillion',
            // Paired: the pillion is told when they get separated from their rider.
            () => service.setCoRiderDriver(myId, pairedWithThem ? '' : r.userId),
          ),
      ],
    );
  }
}
