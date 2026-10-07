import 'package:flutter/material.dart';
import '../constants/ride_thresholds.dart';
import 'ui_tokens.dart';

/// What a rider is doing, in one word the whole app uses.
enum RiderStatus {
  riding,
  stopped,
  resting,
  offline,
  lowGps,
  disconnected,
  emergency;

  /// Short label shown next to the icon.
  String get label {
    switch (this) {
      case RiderStatus.riding:
        return 'Riding';
      case RiderStatus.stopped:
        return 'Stopped';
      case RiderStatus.resting:
        return 'Resting';
      case RiderStatus.offline:
        return 'Offline';
      case RiderStatus.lowGps:
        return 'Low GPS';
      case RiderStatus.disconnected:
        return 'Disconnected';
      case RiderStatus.emergency:
        return 'Emergency';
    }
  }

  IconData get icon {
    switch (this) {
      case RiderStatus.riding:
        return Icons.two_wheeler_rounded;
      case RiderStatus.stopped:
        return Icons.pause_circle_filled_rounded;
      case RiderStatus.resting:
        return Icons.free_breakfast_rounded;
      case RiderStatus.offline:
        return Icons.cloud_off_rounded;
      case RiderStatus.lowGps:
        return Icons.gps_not_fixed_rounded;
      case RiderStatus.disconnected:
        return Icons.signal_cellular_connected_no_internet_0_bar_rounded;
      case RiderStatus.emergency:
        return Icons.sos_rounded;
    }
  }

  /// Status colour (follows the theme). Never use it without [icon] or [label].
  Color get color {
    switch (this) {
      case RiderStatus.riding:
        return StatusColors.success;
      case RiderStatus.stopped:
        return StatusColors.warning;
      case RiderStatus.resting:
        return StatusColors.info;
      case RiderStatus.offline:
        return StatusColors.offline;
      case RiderStatus.lowGps:
        return StatusColors.warning;
      case RiderStatus.disconnected:
        return StatusColors.warning;
      case RiderStatus.emergency:
        return StatusColors.critical;
    }
  }

  /// Higher means more urgent. Sort riders by this (descending) to put the
  /// ones who need attention first.
  int get priority {
    switch (this) {
      case RiderStatus.emergency:
        return 100;
      case RiderStatus.offline:
        return 80;
      case RiderStatus.disconnected:
        return 70;
      case RiderStatus.lowGps:
        return 50;
      case RiderStatus.stopped:
        return 40;
      case RiderStatus.resting:
        return 30;
      case RiderStatus.riding:
        return 10;
    }
  }

  /// True for states where the position on the map may be out of date.
  bool get isStale => this == RiderStatus.offline || this == RiderStatus.disconnected;

  /// Picks the status from raw signals. Pure, so it is easy to test.
  ///
  /// Checked in this order (first match wins), thresholds in [RideThresholds]:
  /// 1. [sos] raised: [RiderStatus.emergency].
  /// 2. No update yet ([lastSeenMs] null or 0) or the last update is at least
  ///    [RideThresholds.offlineAfter] old: [RiderStatus.offline].
  /// 3. Not [online], or the last update is at least
  ///    [RideThresholds.staleAfter] old: [RiderStatus.disconnected].
  /// 4. [accuracyM] worse than [RideThresholds.lowGpsAccuracyM]: [RiderStatus.lowGps].
  /// 5. [speedKmh] at least [RideThresholds.movingSpeedKmh]: [RiderStatus.riding].
  /// 6. [stoppedForMs] at least [RideThresholds.restingAfter]: [RiderStatus.resting].
  /// 7. Otherwise (slow or unknown speed): [RiderStatus.stopped].
  static RiderStatus fromSignals({
    bool sos = false,
    bool online = true,
    int? lastSeenMs,
    double? speedKmh,
    double? accuracyM,
    int? stoppedForMs,
    required int nowMs,
  }) {
    if (sos) return RiderStatus.emergency;
    if (lastSeenMs == null || lastSeenMs <= 0) return RiderStatus.offline;
    final age = nowMs - lastSeenMs;
    if (age >= RideThresholds.offlineAfter.inMilliseconds) return RiderStatus.offline;
    if (!online || age >= RideThresholds.staleAfter.inMilliseconds) return RiderStatus.disconnected;
    if (accuracyM != null && accuracyM > RideThresholds.lowGpsAccuracyM) return RiderStatus.lowGps;
    if (speedKmh != null && speedKmh >= RideThresholds.movingSpeedKmh) return RiderStatus.riding;
    if (stoppedForMs != null && stoppedForMs >= RideThresholds.restingAfter.inMilliseconds) return RiderStatus.resting;
    return RiderStatus.stopped;
  }
}

/// Small status chip: icon plus text, never colour alone.
/// [detail] is appended after a comma, e.g. "Stopped, 8 min".
class RiderStatusChip extends StatelessWidget {
  final RiderStatus status;
  final String? detail;

  const RiderStatusChip({super.key, required this.status, this.detail});

  @override
  Widget build(BuildContext context) {
    final c = status.color;
    final d = detail;
    final text = d == null || d.isEmpty ? status.label : '${status.label}, $d';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.s8, vertical: Space.s4),
      decoration: ShapeDecoration(
        color: c.withOpacity(0.14),
        shape: StadiumBorder(side: BorderSide(color: c.withOpacity(0.45))),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 16, color: c),
          const SizedBox(width: Space.s4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.label.copyWith(color: c),
            ),
          ),
        ],
      ),
    );
  }
}
