import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/models/rider_model.dart';
import '../../data/models/safety_wire.dart';
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

/// Talking indicator chip when a rider is transmitting on the intercom.
class SpeakingChip extends StatelessWidget {
  const SpeakingChip({super.key});

  @override
  Widget build(BuildContext context) {
    return _StatusPill(
      icon: Icons.graphic_eq_rounded,
      text: 'Talking',
      color: StatusColors.info,
      background: StatusColors.info.withOpacity(0.12),
      border: StatusColors.info.withOpacity(0.4),
    );
  }
}

/// Muted microphone chip when a rider has muted their microphone.
class MicMutedChip extends StatelessWidget {
  const MicMutedChip({super.key});

  @override
  Widget build(BuildContext context) {
    return _StatusPill(
      icon: Icons.mic_off_rounded,
      text: 'Muted',
      color: AppTheme.muted,
      background: AppTheme.muted.withOpacity(0.10),
    );
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

