import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// The one confirmation dialog, for End Ride, Leave Ride, Delete Trip and
/// Remove Rider only. Returns true when the rider confirmed; false for
/// Cancel, the back button or a tap outside.
///
/// [destructive] makes the confirm button red. Confirming gives a medium
/// haptic. Example: title "End ride?", message "Your live location sharing
/// with this group will stop.", confirmLabel "End Ride".
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final Color confirmBg = destructive ? StatusColors.critical : AppTheme.neonCyan;
      final Color confirmFg = destructive ? StatusColors.onCritical : Colors.black;
      return AlertDialog(
        backgroundColor: AppTheme.slateCard,
        shape: const RoundedRectangleBorder(borderRadius: Radii.lgAll),
        title: Text(title, style: AppText.title),
        content: Text(message, style: AppText.body.copyWith(color: AppTheme.textSecondary)),
        actionsPadding: const EdgeInsets.fromLTRB(Space.s16, 0, Space.s16, Space.s16),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.textPrimary,
              minimumSize: const Size(64, 48),
            ),
            child: Text(cancelLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          FilledButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.of(ctx).pop(true);
            },
            style: FilledButton.styleFrom(
              backgroundColor: confirmBg,
              foregroundColor: confirmFg,
              minimumSize: const Size(64, 48),
              shape: const RoundedRectangleBorder(borderRadius: Radii.mdAll),
            ),
            child: Text(confirmLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
