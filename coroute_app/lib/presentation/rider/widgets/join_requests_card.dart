import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';

/// v3.60 join approval, in the cockpit of the host / ride head: riders waiting to join with the ride code.
/// One row per rider with "Let in" and "Not now". Large touch targets (gloves), no more than three rows shown.
class JoinRequestsCard extends StatelessWidget {
  /// userId -> first name.
  final Map<String, String> pending;
  final Future<void> Function(String userId, bool approve) onDecide;
  const JoinRequestsCard({super.key, required this.pending, required this.onDecide});

  @override
  Widget build(BuildContext context) {
    final rows = pending.entries.take(3).toList();
    final more = pending.length - rows.length;
    return Container(
      key: const Key('join_requests_card'),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      decoration: BoxDecoration(
        color: AppTheme.card.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.7), width: 1.5),
        boxShadow: dsFloatingShadow(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            pending.length == 1 ? 'A rider wants to join' : '${pending.length} riders want to join',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.label.copyWith(fontWeight: FontWeight.w700, color: AppTheme.accentText),
          ),
          for (final e in rows)
            Row(
              children: [
                Expanded(child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
                TextButton(
                  key: Key('join_decline_${e.key}'),
                  style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
                  onPressed: () => onDecide(e.key, false),
                  child: const Text('Not now'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  key: Key('join_approve_${e.key}'),
                  style: FilledButton.styleFrom(minimumSize: const Size(72, 48), backgroundColor: AppTheme.brand),
                  onPressed: () {
                    AppHaptics.light();
                    onDecide(e.key, true);
                  },
                  child: const Text('Let in'),
                ),
              ],
            ),
          if (more > 0) Text('+$more more waiting', style: AppText.caption),
        ],
      ),
    );
  }
}
