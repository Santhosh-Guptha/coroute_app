import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/safety_wire.dart';
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

/// Why another rider's position stopped, in words, from the server's
/// presence: "No signal since 10:42 near Hosur" (the link dropped: tunnel,
/// dead zone, or the phone was killed) or "App closed on this phone" (the
/// rider closed CoRoute). Null for me, for riders who are online, and when
/// an older gateway sends no presence. [clock] formats epoch ms as a time of
/// day ("10:42 AM"); [place] is the OFFLINE timeline place, may be empty.
String? presenceLine(RiderModel r, {required bool isMe, String place = '', required String Function(int ms) clock}) {
  if (isMe) return null;
  switch (r.presenceState) {
    case RiderPresence.noSignal:
      final since = r.lastSeenEpochMs > 0 ? r.lastSeenEpochMs : r.presenceAt;
      final near = place.trim().isEmpty ? '' : ' near ${place.trim()}';
      return since > 0 ? 'No signal since ${clock(since)}$near' : 'No signal$near';
    case RiderPresence.appClosed:
      return 'App closed on this phone';
    case RiderPresence.online:
    case RiderPresence.unknown:
      return null;
  }
}

/// [presenceLine]'s clock: the device's own 12 or 24 hour format.
String presenceClock(BuildContext context, int ms) => MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(ms)),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

/// Icon for a presence line: no signal and app closed look different.
IconData presenceIcon(RiderModel r) =>
    r.presenceState == RiderPresence.appClosed ? Icons.phonelink_erase_rounded : Icons.signal_cellular_connected_no_internet_0_bar_rounded;

/// Small icon + text status pill in the canvas chip style (tinted fill,
/// 7 dp corners, 700 weight). Never colour alone: the text says it.
class _StatusPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  final Color background;
  final Color? border;
  const _StatusPill({required this.icon, required this.text, required this.color, required this.background, this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(7),
        border: border == null ? null : Border.all(color: border!, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: color, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }
}

/// "Possible incident" as a small red chip with an icon (never colour alone).
class PossibleIncidentChip extends StatelessWidget {
  const PossibleIncidentChip({super.key});

  @override
  Widget build(BuildContext context) {
    final Color c = AppTheme.sos;
    return _StatusPill(icon: Icons.report_rounded, text: 'Possible incident', color: c, background: c.withOpacity(0.12));
  }
}

/// "14% battery" as a small amber chip with an icon (3.16, item 12): shown
/// in the ladder and on the rider card while [RiderModel.lowBattery].
class LowBatteryChip extends StatelessWidget {
  final int level;
  const LowBatteryChip({super.key, required this.level});

  static String text(int level) => '$level% battery';

  @override
  Widget build(BuildContext context) {
    return _StatusPill(icon: Icons.battery_alert_rounded, text: text(level), color: AppTheme.warnText, background: AppTheme.warnTint);
  }
}

/// The sweeper's tail marker (3.16, item 11): a flag and "Sweeper", muted.
/// Used on the sweeper's rung in the ladder and on their card.
class SweeperMarker extends StatelessWidget {
  const SweeperMarker({super.key});

  static const String label = 'Sweeper';

  @override
  Widget build(BuildContext context) {
    return _StatusPill(icon: Icons.flag_rounded, text: label, color: AppTheme.text2, background: Colors.transparent, border: AppTheme.border);
  }
}

/// A presence line with its icon, for the ladder and the rider card.
class PresenceText extends StatelessWidget {
  final RiderModel rider;
  final String text;
  const PresenceText({super.key, required this.rider, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(presenceIcon(rider), size: 16, color: AppTheme.warnText),
        const SizedBox(width: 4),
        Expanded(
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

/// The stop reason a rider gave, as text ("Fueling", "Custom Reason: tyre").
String riderReasonText(RiderModel r) {
  if (r.statusReason.isEmpty) return '';
  final label = RiderStatusSheet.getStatusLabel(r.statusReason);
  return r.statusMessage.isEmpty ? label : (r.statusReason == 'CUSTOM' ? r.statusMessage : '$label: ${r.statusMessage}');
}

/// The group from front to back, one card per rider (canvas "Riding
/// order"): who is ahead of me and who is behind, the gap between riders,
/// and a "Too far behind" flag when a gap is larger than the group's
/// separation limit. Tapping a rider opens the rider card.
class RidersLadder extends StatelessWidget {
  final List<LadderRung> rungs;
  final Map<String, Color> colors;
  final Map<String, RiderStatus> statuses;
  final int nowMs;
  final ValueChanged<RiderModel> onTap;

  /// userId to the place of their open OFFLINE entry ("near Hosur"), for "No signal since".
  final Map<String, String> offlinePlaces;

  /// Riders with an open possible incident (shown as a chip).
  final Set<String> possibleIncident;

  const RidersLadder({
    super.key,
    required this.rungs,
    required this.colors,
    required this.statuses,
    required this.nowMs,
    required this.onTap,
    this.offlinePlaces = const {},
    this.possibleIncident = const {},
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final rung in rungs) {
      final gap = rung.gapAheadM;
      if (children.isNotEmpty) children.add(const SizedBox(height: 10));
      if (gap != null) children.add(_GapRow(gapM: gap, tooFar: rung.tooFarBehind));
      children.add(_RiderRow(
        rung: rung,
        color: colors[rung.rider.userId],
        status: statuses[rung.rider.userId] ?? RiderStatus.offline,
        nowMs: nowMs,
        place: offlinePlaces[rung.rider.userId] ?? '',
        incident: possibleIncident.contains(rung.rider.userId),
        onTap: () => onTap(rung.rider),
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// The distance between two cards: a short tick on the avatar axis and the
/// gap in words, amber when it is too large.
class _GapRow extends StatelessWidget {
  final double gapM;
  final bool tooFar;
  const _GapRow({required this.gapM, required this.tooFar});

  @override
  Widget build(BuildContext context) {
    final Color c = tooFar ? AppTheme.warnText : AppTheme.muted;
    final text = tooFar ? '${formatDistanceRounded(gapM)} gap, too far behind' : '${formatDistanceRounded(gapM)} gap';
    return Semantics(
      container: true,
      label: text,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            SizedBox(
              width: 48 + 18,
              height: 18,
              child: Center(child: Container(width: 3, decoration: BoxDecoration(color: tooFar ? AppTheme.warnText : AppTheme.border2, borderRadius: BorderRadius.circular(2)))),
            ),
            if (tooFar) ...[
              Icon(Icons.warning_amber_rounded, size: 16, color: c),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
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
  final String place;
  final bool incident;

  const _RiderRow({
    required this.rung,
    required this.color,
    required this.status,
    required this.nowMs,
    required this.onTap,
    this.place = '',
    this.incident = false,
  });

  @override
  Widget build(BuildContext context) {
    final r = rung.rider;
    final presence = presenceLine(r, isMe: rung.isMe, place: place, clock: (ms) => presenceClock(context, ms));
    // The presence line says why the position is old; the chip then needs no "last seen".
    final detail = presence == null ? riderStatusDetail(r, status, nowMs: nowMs) : null;
    final reason = riderReasonText(r);
    final dist = rung.displayFromMeM;
    final lowBattery = r.lowBattery;
    final sweeper = r.isSweeper;
    final isLead = r.role == RiderRoles.lead;
    final tooFar = rung.tooFarBehind;
    final extra = [
      if (reason.isNotEmpty) reason,
      if (rung.isMe && !lowBattery) 'Battery ${r.batteryLevel}%${r.isCharging ? ', charging' : ''}',
    ].join(', ');
    final distText = dist == null || rung.isMe ? '' : describeDistance(dist, ahead: rung.ahead);
    final speed = status == RiderStatus.riding && r.speedKmh.isFinite && r.speedKmh > 0 ? '${r.speedKmh.round()} km/h' : null;
    final fuelKm = r.fuelUsableKm;
    final fuel = fuelKm != null && fuelKm.isFinite ? 'Fuel ${fuelKm.floor()} km' : null;
    final semantic = [
      rung.isMe ? 'You' : r.name,
      detail == null ? status.label : '${status.label}, $detail',
      ?presence,
      if (incident) 'possible incident',
      if (lowBattery) LowBatteryChip.text(r.batteryLevel),
      if (sweeper) SweeperMarker.label,
      if (distText.isNotEmpty) distText,
      if (tooFar) 'too far behind',
      ?speed,
      ?fuel,
      if (extra.isNotEmpty) extra,
      if (isLead) 'Lead',
    ].join(', ');

    final Color secondary = rung.isMe ? AppTheme.text2 : (tooFar ? AppTheme.warnText : AppTheme.muted);
    final avatarRing = tooFar ? AppTheme.warnText : (color ?? AppTheme.accentText);

    return Semantics(
      container: true,
      button: true,
      label: semantic,
      excludeSemantics: true,
      onTap: onTap,
      child: DsCard(
        onTap: onTap,
        tinted: rung.isMe,
        accent: rung.isMe,
        warning: !rung.isMe && tooFar,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            DsAvatar(initialsOf(r.name), size: 48, filled: rung.isMe, ringColor: avatarRing),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        rung.isMe ? '${r.name} (You)' : r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.title,
                      ),
                      if (isLead) const DsChip('Lead')
                      else if (tooFar) const DsChip('Falling back', warning: true)
                      else if (rung.isMe) const DsChip('Pack', inverse: true),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      RiderStatusChip(status: status, detail: detail),
                      if (incident) const PossibleIncidentChip(),
                      if (lowBattery) LowBatteryChip(level: r.batteryLevel),
                      if (sweeper) const SweeperMarker(),
                      if (dist != null && !rung.isMe)
                        DistanceIndicator(meters: dist, ahead: rung.ahead, warn: tooFar, style: AppText.label.copyWith(color: secondary)),
                    ],
                  ),
                  if (presence != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: PresenceText(rider: r, text: presence),
                    ),
                  if (extra.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(extra, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: secondary)),
                    ),
                ],
              ),
            ),
            if (speed != null || fuel != null) ...[
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (speed != null)
                    Text(speed, maxLines: 1, style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
                  if (speed != null && fuel != null) const SizedBox(height: 4),
                  if (fuel != null)
                    Text(fuel, maxLines: 1, style: AppText.caption.copyWith(color: tooFar ? AppTheme.warnText : secondary, fontWeight: FontWeight.w700)),
                ],
              ),
            ],
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
          ],
        ),
      ),
    );
  }
}
