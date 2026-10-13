import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/safety_wire.dart';
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
/// 3.16: a low battery chip, the sweeper marker, and for the lead "Make
/// sweeper" / "Remove sweeper".
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
        padding: const EdgeInsets.symmetric(vertical: 24),
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
    // The lead assigns one sweeper (3.16); never the lead themself, needs a 3.16 gateway.
    final riderIsLead = r.role == RiderRoles.lead || r.userId == convoy.createdByUserId;
    final canSetSweeper = !isMe && service.canEditRoute && !riderIsLead && service.supports(ProtocolFeatures.ride316);

    (String, String?) split(double? m) {
      if (m == null) return ('-', null);
      final parts = formatDistanceRounded(m).split(' ');
      return (parts.first, parts.length > 1 ? parts[1] : null);
    }

    final (fromVal, fromUnit) = split(fromMe);
    final (destVal, destUnit) = split(toDest);

    Widget action(IconData icon, String label, VoidCallback onTap, {bool primary = false}) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: DsButton(
          label: label,
          icon: icon,
          tone: primary ? DsButtonTone.brand : DsButtonTone.outline,
          height: primary ? 56 : 52,
          fontSize: 15,
          onPressed: onTap,
        ),
      );
    }

    final isSpeaking = r.isSpeaking || (ic?.isRiderSpeaking(r.userId) ?? false);
    final isMuted = r.micMuted || (ic?.isRiderMuted(r.userId) ?? false);

    // Avatar ring: red on an open SOS, speaking blue/info, amber when the position may be old, else the rider's map colour.
    final Color ring = status == RiderStatus.emergency
        ? AppTheme.sos
        : isSpeaking
            ? StatusColors.info
            : status.isStale
                ? AppTheme.warnText
                : (colors[r.userId] ?? AppTheme.accentText);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            DsAvatar(initialsOf(r.name), size: 56, filled: isMe, ringColor: ring),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Semantics(
                          header: true,
                          child: Text(isMe ? '${r.name} (You)' : r.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 20)),
                        ),
                      ),
                      if (riderIsLead) ...[const SizedBox(width: 8), const DsChip('Lead')],
                    ],
                  ),
                  Text(
                    [r.vehicleType, if (r.vehicleNo.isNotEmpty) r.vehicleNo].join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.label,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      RiderStatusChip(status: status, detail: detail),
                      if (isSpeaking) const SpeakingChip()
                      else if (isMuted) const MicMutedChip(),
                      if (inc != null && inc.kind == IncidentKind.possibleIncident) const PossibleIncidentChip(),
                      if (r.lowBattery) LowBatteryChip(level: r.batteryLevel),
                      if (r.isSweeper) const SweeperMarker(),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (presence != null) ...[
          const SizedBox(height: 10),
          DsCard(
            warning: true,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: PresenceText(rider: r, text: presence),
          ),
        ],
        if (inc != null && !isMe)
          action(Icons.emergency_rounded, 'Open alert', () {
            final nav = Navigator.of(context);
            nav.pop();
            showIncidentSheet(nav.context, convoyId: convoyId, subjectUserId: r.userId, alertId: inc.alertId);
          }, primary: true),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.chat_bubble_outline_rounded, size: 18, color: AppTheme.accentText),
              const SizedBox(width: 8),
              Expanded(child: Text('Reason: $reason', maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body)),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DsStatCell(
                label: isMe ? 'From you' : (ahead == null ? 'From you' : (ahead ? 'Ahead of you' : 'Behind you')),
                value: fromUnit == null ? fromVal : '$fromVal $fromUnit',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DsStatCell(
                label: 'Speed',
                value: '${r.speedKmh.isFinite ? r.speedKmh.round().toString() : '0'} km/h',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DsStatCell(
                label: 'To destination',
                value: destUnit == null ? destVal : '$destVal $destUnit',
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(r.isCharging ? Icons.battery_charging_full_rounded : Icons.battery_std_rounded, size: 16, color: AppTheme.muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                [
                  r.lastSeenEpochMs > 0 ? 'Last update ${formatAgo(Duration(milliseconds: now - r.lastSeenEpochMs))}' : 'No update yet',
                  'battery ${r.batteryLevel}%${r.isCharging ? ', charging' : ''}',
                ].join(', '),
                style: AppText.caption,
              ),
            ),
          ],
        ),
        if (!isMe && r.emergencyContact.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Emergency contact: ${r.emergencyContactName.isNotEmpty ? '${r.emergencyContactName}, ' : ''}${r.emergencyContact}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption,
          ),
        ],
        if (openSos.isNotEmpty) ...[
          const SizedBox(height: 12),
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
        const SizedBox(height: 8),
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
        if (canSetSweeper)
          action(
            r.isSweeper ? Icons.flag_outlined : Icons.flag_rounded,
            r.isSweeper ? 'Remove sweeper' : 'Make sweeper',
            () {
              final ok = service.setSweeper(r.userId, on: !r.isSweeper);
              if (!ok) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not change this now. Try again with signal.')));
              }
            },
          ),
      ],
    );
  }
}
