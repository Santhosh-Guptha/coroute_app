import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui_format.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/realtime_service.dart';

/// Thin strip shown while the realtime link to the convoy is down, so stale
/// positions are never mistaken for live ones. It also says what is waiting
/// on the phone: recorded points to upload and, in red, an SOS not sent yet.
///
/// The ride screen does not place this strip; it shows [status] in its top
/// bar and the SOS state in its alert slot. The strip stays usable elsewhere.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  /// The text lines of the banner (pure, for tests).
  /// [serverUnreachable]: the phone has internet but the CoRoute server does not answer;
  /// the ride is still recorded on the phone, so the text only talks about the server.
  static List<String> lines({required bool connecting, required int pendingPoints, required bool sosWaiting, bool serverUnreachable = false}) => [
        serverUnreachable
            ? 'CoRoute server not reachable'
            : (connecting ? 'Reconnecting to the convoy...' : 'Offline. Positions shown may be out of date.'),
        if (pendingPoints > 0) '$pendingPoints ${pendingPoints == 1 ? 'point' : 'points'} waiting to upload',
        if (sosWaiting) 'SOS waiting to send',
      ];

  /// One short line for the ride top bar, or null when everything is live:
  /// "Reconnecting, last updated 2 min ago", "Offline, last updated 6 min ago",
  /// "SOS waiting to send" (pure, for tests). [lastUpdateMs] is the newest
  /// position heard from the group (epoch ms, 0 or null when none).
  static String? status({
    required RealtimeState state,
    int? lastUpdateMs,
    required int nowMs,
    bool sosWaiting = false,
    bool serverUnreachable = false,
  }) {
    final connected = state == RealtimeState.connected;
    if (sosWaiting) return connected ? 'Sending your SOS' : 'SOS waiting to send';
    if (connected) return null;
    if (serverUnreachable) return 'CoRoute server not reachable';
    final last = lastUpdateMs;
    final ago = (last == null || last <= 0) ? null : formatAgo(Duration(milliseconds: (nowMs - last).clamp(0, 1 << 40).toInt()));
    final head = state == RealtimeState.connecting ? 'Reconnecting' : 'Offline';
    return ago == null ? head : '$head, last updated $ago';
  }

  @override
  Widget build(BuildContext context) {
    final rt = context.watch<RealtimeService>();
    final state = rt.state;
    // ConvoyService is optional here (some screens and tests show the banner without it).
    final (sosWaiting, pendingPoints) = context.select<ConvoyService?, (bool, int)>(
      (s) => (s?.pendingSos != null, s?.pendingTrackPoints ?? 0),
    );
    if (state == RealtimeState.connected && !sosWaiting) return const SizedBox.shrink();
    if (state == RealtimeState.connected) {
      // Connected but the SOS is not confirmed yet: it is being sent.
      return _strip(
        icon: Icon(Icons.sos_rounded, size: 16, color: AppTheme.laserRed),
        children: [_line('Sending your SOS to the convoy...', AppTheme.laserRed)],
        color: AppTheme.laserRed,
      );
    }
    final connecting = state == RealtimeState.connecting;
    final text = lines(connecting: connecting, pendingPoints: pendingPoints, sosWaiting: sosWaiting, serverUnreachable: rt.serverUnreachable);
    return _strip(
      icon: SizedBox(
        width: 16,
        height: 16,
        child: connecting
            ? Icon(Icons.sync_rounded, size: 16, color: AppTheme.hyperAmber)
            : Icon(Icons.cloud_off_rounded, size: 16, color: AppTheme.hyperAmber),
      ),
      color: sosWaiting ? AppTheme.laserRed : AppTheme.hyperAmber,
      children: [
        _line(text.first, AppTheme.hyperAmber),
        for (final t in text.skip(1)) _line(t, t.startsWith('SOS') ? AppTheme.laserRed : AppTheme.hyperAmber),
      ],
    );
  }

  Widget _line(String text, Color color) => Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
      );

  Widget _strip({required Widget icon, required List<Widget> children, required Color color}) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: color.withOpacity(0.15),
        child: Row(
          children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: icon),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
