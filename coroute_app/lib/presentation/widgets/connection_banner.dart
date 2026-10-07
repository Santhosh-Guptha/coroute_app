import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/realtime_service.dart';

/// Thin strip shown while the realtime link to the convoy is down, so stale
/// positions are never mistaken for live ones. It also says what is waiting
/// on the phone: recorded points to upload and, in red, an SOS not sent yet.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  /// The text lines of the banner (pure, for tests).
  static List<String> lines({required bool connecting, required int pendingPoints, required bool sosWaiting}) => [
        connecting ? 'Reconnecting to the convoy...' : 'Offline. Positions shown may be out of date.',
        if (pendingPoints > 0) '$pendingPoints ${pendingPoints == 1 ? 'point' : 'points'} waiting to upload',
        if (sosWaiting) 'SOS waiting to send',
      ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RealtimeService>().state;
    // ConvoyService is optional here (some screens and tests show the banner without it).
    final (sosWaiting, pendingPoints) = context.select<ConvoyService?, (bool, int)>(
      (s) => (s?.pendingSos != null, s?.pendingTrackPoints ?? 0),
    );
    if (state == RealtimeState.connected && !sosWaiting) return const SizedBox.shrink();
    if (state == RealtimeState.connected) {
      // Connected but the SOS is not confirmed yet: it is being sent.
      return _strip(
        icon: Icon(Icons.sos_rounded, size: 14, color: AppTheme.laserRed),
        children: [_line('Sending your SOS to the convoy...', AppTheme.laserRed)],
        color: AppTheme.laserRed,
      );
    }
    final connecting = state == RealtimeState.connecting;
    final text = lines(connecting: connecting, pendingPoints: pendingPoints, sosWaiting: sosWaiting);
    return _strip(
      icon: SizedBox(
        width: 12,
        height: 12,
        child: connecting
            ? CircularProgressIndicator(strokeWidth: 2, color: AppTheme.hyperAmber)
            : Icon(Icons.cloud_off_rounded, size: 12, color: AppTheme.hyperAmber),
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
