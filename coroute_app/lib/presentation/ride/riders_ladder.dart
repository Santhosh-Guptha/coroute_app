import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../domain/ride/ride_facts.dart';
import '../widgets/rider_status_sheet.dart';

/// One status for a rider, the same on the map marker, in the ladder and on
/// the rider card. For me, "last update" is my own phone (my position is
/// local and live while GPS runs); [online] is the link to the group.
RiderStatus riderStatusOf(
  RiderModel r,
  ConvoyModel convoy, {
  required bool isMe,
  required int nowMs,
  bool online = true,
  bool gpsActive = true,
  double? myAccuracyM,
}) {
  final sos = convoy.activeAlerts.any((a) => !a.resolved && a.userId == r.userId);
  return RiderStatus.fromSignals(
    sos: sos,
    online: isMe ? online : true,
    lastSeenMs: isMe ? (gpsActive ? nowMs : r.lastSeenEpochMs) : r.lastSeenEpochMs,
    speedKmh: r.speedKmh,
    accuracyM: isMe ? myAccuracyM : null,
    stoppedForMs: r.stoppedSince > 0 ? nowMs - r.stoppedSince : null,
    nowMs: nowMs,
  );
}

/// The words after the status: "8 min" for a stop, "last seen 6 min ago"
/// for a rider whose position may be old. Null when there is nothing to add.
String? riderStatusDetail(RiderModel r, RiderStatus s, {required int nowMs}) {
  switch (s) {
    case RiderStatus.stopped:
    case RiderStatus.resting:
      return r.stoppedSince > 0 ? formatDuration(Duration(milliseconds: nowMs - r.stoppedSince)) : null;
    case RiderStatus.offline:
    case RiderStatus.disconnected:
      return r.lastSeenEpochMs > 0 ? 'last seen ${formatAgo(Duration(milliseconds: nowMs - r.lastSeenEpochMs))}' : null;
    case RiderStatus.riding:
    case RiderStatus.lowGps:
    case RiderStatus.emergency:
      return null;
  }
}

/// The stop reason a rider gave, as text ("Fueling", "Custom Reason: tyre").
String riderReasonText(RiderModel r) {
  if (r.statusReason.isEmpty) return '';
  final label = RiderStatusSheet.getStatusLabel(r.statusReason);
  return r.statusMessage.isEmpty ? label : (r.statusReason == 'CUSTOM' ? r.statusMessage : '$label: ${r.statusMessage}');
}

/// The group from front to back: who is ahead of me and who is behind, the
/// gap between riders, and a "Too far behind" flag when a gap is larger than
/// the group's separation limit. Tapping a rider opens the rider card.
class RidersLadder extends StatelessWidget {
  final List<LadderRung> rungs;
  final Map<String, Color> colors;
  final Map<String, RiderStatus> statuses;
  final int nowMs;
  final ValueChanged<RiderModel> onTap;

  const RidersLadder({
    super.key,
    required this.rungs,
    required this.colors,
    required this.statuses,
    required this.nowMs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final rung in rungs) {
      final gap = rung.gapAheadM;
      if (gap != null) children.add(_GapRow(gapM: gap, tooFar: rung.tooFarBehind));
      children.add(_RiderRow(
        rung: rung,
        color: colors[rung.rider.userId],
        status: statuses[rung.rider.userId] ?? RiderStatus.offline,
        nowMs: nowMs,
        onTap: () => onTap(rung.rider),
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class _GapRow extends StatelessWidget {
  final double gapM;
  final bool tooFar;
  const _GapRow({required this.gapM, required this.tooFar});

  @override
  Widget build(BuildContext context) {
    final Color c = tooFar ? StatusColors.warning : AppTheme.textMuted;
    final text = tooFar ? '${formatDistanceRounded(gapM)} gap, too far behind' : '${formatDistanceRounded(gapM)} gap';
    return Semantics(
      container: true,
      label: text,
      excludeSemantics: true,
      child: Row(
        children: [
          SizedBox(
            width: 44,
            height: 24,
            child: Center(child: Container(width: 2, color: tooFar ? StatusColors.warning : AppTheme.subtleBorder)),
          ),
          const SizedBox(width: Space.s12),
          if (tooFar) ...[
            Icon(Icons.warning_amber_rounded, size: 16, color: c),
            const SizedBox(width: Space.s4),
          ],
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: c, fontWeight: tooFar ? FontWeight.w600 : null)),
          ),
        ],
      ),
    );
  }
}

class _RiderRow extends StatelessWidget {
  final LadderRung rung;
  final Color? color;
  final RiderStatus status;
  final int nowMs;
  final VoidCallback onTap;

  const _RiderRow({required this.rung, required this.color, required this.status, required this.nowMs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final r = rung.rider;
    final detail = riderStatusDetail(r, status, nowMs: nowMs);
    final reason = riderReasonText(r);
    final dist = rung.displayFromMeM;
    final lowBattery = r.batteryLevel > 0 && r.batteryLevel < 20;
    final extra = [
      if (reason.isNotEmpty) reason,
      if (rung.isMe || lowBattery) 'Battery ${r.batteryLevel}%${r.isCharging ? ', charging' : ''}',
      if (r.role == 'LEAD') 'Lead',
      if (r.role == 'SWEEPER') 'Sweeper',
    ].join(', ');
    final distText = dist == null || rung.isMe ? '' : describeDistance(dist, ahead: rung.ahead);
    final semantic = [
      rung.isMe ? 'You' : r.name,
      detail == null ? status.label : '${status.label}, $detail',
      if (distText.isNotEmpty) distText,
      if (rung.tooFarBehind) 'too far behind',
      if (extra.isNotEmpty) extra,
    ].join(', ');

    return Semantics(
      container: true,
      button: true,
      label: semantic,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.mdAll,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s8),
            child: Row(
              children: [
                RiderAvatar(name: r.name, color: color, status: status, size: 44),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rung.isMe ? '${r.name} (You)' : r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: Space.s4),
                      Wrap(
                        spacing: Space.s8,
                        runSpacing: Space.s4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          RiderStatusChip(status: status, detail: detail),
                          if (dist != null && !rung.isMe) DistanceIndicator(meters: dist, ahead: rung.ahead, warn: rung.tooFarBehind),
                        ],
                      ),
                      if (extra.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.s4),
                          child: Text(extra, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.caption),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
