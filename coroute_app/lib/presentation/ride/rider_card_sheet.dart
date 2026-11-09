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
import '../../domain/ride/ride_roles.dart';
import '../../domain/ride/vehicle_swap.dart';
import '../../domain/tracking/geo_math.dart';
import '../../domain/timeline/timeline_text.dart';
import '../timeline/member_colors.dart';
import 'incident_sheet.dart';
import 'incident_view.dart';
import 'riders_ladder.dart';
import '../widgets/feature_switch.dart';
import '../../domain/ride/pillion_seat.dart'; // 3.55 pillion seat
import 'pillion_seat_sheet.dart';
import '../social/rider_username_line.dart'; // 3.55 usernames

bool _isRiderCardShowing = false;

/// Opens the compact rider card (a sheet, never a new screen): name, status,
/// distance from me, speed, last update, distance to the destination, and
/// the actions Show on map, Call, Talk privately, Pair as pillion. When the
/// rider has an open SOS it also offers "Mark as handled" (confirmed first).
/// 3.16: a low battery chip, the sweeper marker, and for the lead "Make
/// sweeper" / "Remove sweeper".
/// Under "Riding role" on the rider card (3.55 naming guide §2/§4).
const String ridingRoleExplanation = 'Lead rides first and guides the group, Middle rides between, Sweeper rides last.';

Future<void> showRiderCard(
  BuildContext context, {
  required String convoyId,
  required String userId,
  required ValueChanged<RiderModel> onShowOnMap,
}) async {
  if (_isRiderCardShowing) return;
  _isRiderCardShowing = true;
  try {
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (ctx) => SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: RiderCard(convoyId: convoyId, userId: userId, onShowOnMap: onShowOnMap),
      ),
    );
  } finally {
    _isRiderCardShowing = false;
  }
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
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cannot call $clean')));
    }
  }

  /// 3.55: confirms, then asks [r] for the swap (the answer comes back as a cockpit card).
  static Future<void> _askSwap(BuildContext context, ConvoyService service, RiderModel r, SwapKind kind) async {
    final first = r.name.split(' ').first;
    final ok = await confirmAction(
      context,
      title: kind == SwapKind.bikes ? 'Swap bikes with $first?' : 'Change places with $first?',
      message: kind == SwapKind.bikes
          ? '$first is asked to accept. You then ride each other\'s bike for the rest of this ride. Stop safely before you swap.'
          : '$first is asked to accept. The pillion becomes the rider and the rider sits pillion. Stop safely before you swap.',
      confirmLabel: 'Ask $first',
    );
    if (!ok || !context.mounted) return;
    final sent = service.requestSwap(r.userId, kind);
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent ? 'Asked $first. Waiting for their answer.' : 'Could not ask now. Try again with signal.'),
    ));
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
    // 3.55: the riding lead may be any rider (the owner keeps the owner's rights).
    final riderIsLead = service.supportsRideRoles ? convoy.ridingLeadId == r.userId : (r.role == RiderRoles.lead || r.userId == convoy.createdByUserId);
    final canSetSweeper = !isMe && service.canEditRoute && !riderIsLead && service.supports(ProtocolFeatures.ride316) && !service.supportsRideRoles;
    // Lead / middle / sweeper for any rider (me included) and "swap with me" (3.55 gateways).
    final canSetRoles = service.canEditRoute && service.supportsRideRoles && convoy.riders.length >= 2;
    // 3.55 admin feature switch: riding roles turned off for every rider (the gateway refuses too).
    final rolesOn = context.featureOn('rideRoles');
    final roleNow = riderIsLead ? RideRole.lead : (r.isSweeper ? RideRole.sweeper : RideRole.middle);
    final myRole = convoy.ridingLeadId == myId ? RideRole.lead : ((me?.isSweeper ?? false) ? RideRole.sweeper : RideRole.middle);
    final canSwap = !isMe && me != null && service.supportsRideRoles && !convoy.isSoloRide && context.featureOn('vehicleSwap');

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
                    // 3.55: the garage bike's model when known (live bike change), else the type.
                    [r.vehicleModel.isNotEmpty ? r.vehicleModel : r.vehicleType, if (r.vehicleNo.isNotEmpty) r.vehicleNo].join(', '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.label,
                  ),
                  RiderUsernameLine(groupId: convoy.groupId, userId: r.userId),
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
        // 3.55 pillion seat: "I am their pillion" asks to confirm the bike first ("You'll ride pillion
        // on Asha's Classic 350 (Red). Confirm?"); the rider of the bike may decline or remove.
        if (!isMe && me != null && (pairedWithThem || PillionSeat.candidates(convoy.riders, myId).any((x) => x.userId == r.userId)))
          action(
            pairedWithThem ? Icons.link_off_rounded : Icons.link_rounded,
            pairedWithThem ? 'Stop riding as pillion' : 'I am their pillion',
            // Paired: the pillion is told when they get separated from their rider.
            () => pairedWithThem ? service.unseatPillion() : confirmPillionSeat(context, service, r),
          ),
        if (!isMe && me != null && r.isCoRiding && r.ridingWithUserId == myId && service.supportsPillionSeat)
          action(Icons.person_remove_rounded, 'Remove pillion', () => service.unseatPillion(r.userId)),
        // 3.55 bike / pillion swap: asks the other rider, who accepts or declines on their phone
        // (hidden while the admin switched 'vehicleSwap' off; the gateway refuses too).
        if (canSwap && SwapRules.canSwapBikes(me, r))
          action(Icons.swap_horiz_rounded, 'Swap bikes', () => _askSwap(context, service, r, SwapKind.bikes)),
        if (canSwap && SwapRules.canSwapPillion(me, r))
          action(Icons.airline_seat_recline_normal_rounded, 'Change places (rider and pillion)', () => _askSwap(context, service, r, SwapKind.pillion)),
        if (canSetRoles && !rolesOn) ...[
          const SizedBox(height: 12),
          Semantics(header: true, child: const DsSectionHeader('Riding role')),
          const FeatureOffNote(),
        ],
        if (canSetRoles && rolesOn) ...[
          const SizedBox(height: 12),
          Semantics(header: true, child: const DsSectionHeader('Riding role')),
          const SizedBox(height: 2),
          // 3.55 naming: a riding position, not the trip owner / trip head who run the trip.
          Text(ridingRoleExplanation, style: AppText.caption),
          const SizedBox(height: 6),
          DsSegment<String>(
            values: RideRole.all,
            selected: roleNow,
            label: (v) => '${RideRole.label(v)}\n${RideRole.place(v)}',
            onChanged: (v) {
              if (v == roleNow) return;
              final ok = service.setRiderRole(r.userId, v);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok
                    ? (isMe
                        ? 'You are now ${RideRole.label(v)}: ride at the ${RideRole.place(v)} when it is safe.'
                        : '${r.name.split(' ').first} is now ${RideRole.label(v)} and will be told to move to the ${RideRole.place(v)}.')
                    : 'Could not change this now. Try again with signal.'),
              ));
            },
          ),
          if (convoy.autoRoles)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Automatic roles are on: roles may follow the order on the road again.', style: AppText.caption),
            ),
          // Hidden when we already ride the same role (a swap would change nothing).
          if (!isMe && me != null && myRole != roleNow)
            action(Icons.swap_vert_rounded, 'Swap roles with me', () {
              final ok = service.swapRiderRoles(myId, r.userId);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(ok
                    ? 'Swapping roles with ${r.name.split(' ').first}. You will both be told where to ride.'
                    : 'Could not change this now. Try again with signal.'),
              ));
            }),
        ],
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
