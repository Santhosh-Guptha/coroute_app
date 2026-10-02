import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/realtime_service.dart';

/// Thin strip shown while the realtime link to the convoy is down, so stale
/// positions are never mistaken for live ones.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<RealtimeService>().state;
    if (state == RealtimeState.connected) return const SizedBox.shrink();
    final connecting = state == RealtimeState.connecting;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      color: AppTheme.hyperAmber.withOpacity(0.15),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: connecting
                ? const CircularProgressIndicator(strokeWidth: 2, color: AppTheme.hyperAmber)
                : const Icon(Icons.cloud_off_rounded, size: 12, color: AppTheme.hyperAmber),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              connecting ? 'Reconnecting to the convoy…' : 'Offline. Positions shown may be out of date.',
              style: const TextStyle(color: AppTheme.hyperAmber, fontSize: 12, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
