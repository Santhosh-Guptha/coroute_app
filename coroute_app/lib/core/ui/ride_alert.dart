import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// How urgent an alert is.
///
/// * critical: SOS, accident, unexpected disconnect, extreme separation.
/// * important: a rider stopped, route changed, meeting point changed.
/// * normal: a rider joined, trip update, arrival.
enum AlertTier {
  critical,
  important,
  normal;

  IconData get icon {
    switch (this) {
      case AlertTier.critical:
        return Icons.error_rounded;
      case AlertTier.important:
        return Icons.warning_amber_rounded;
      case AlertTier.normal:
        return Icons.info_outline_rounded;
    }
  }

  Color get color {
    switch (this) {
      case AlertTier.critical:
        return StatusColors.critical;
      case AlertTier.important:
        return StatusColors.warning;
      case AlertTier.normal:
        return StatusColors.info;
    }
  }
}

/// A compact alert banner: icon, title, optional one line, optional action.
///
/// Critical alerts are solid red with white text and are announced by
/// screen readers as they appear. Important ones have an amber tint and
/// border; normal ones are a plain card with a blue icon.
class RideAlert extends StatelessWidget {
  final AlertTier tier;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Shows a close button when set.
  final VoidCallback? onDismiss;

  const RideAlert({
    super.key,
    required this.tier,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final critical = tier == AlertTier.critical;
    final accent = tier.color;
    final Color bg = critical
        ? accent
        : (tier == AlertTier.important ? Color.alphaBlend(accent.withOpacity(0.14), AppTheme.slateCard) : AppTheme.slateCard);
    final Color fg = critical ? StatusColors.onCritical : AppTheme.textPrimary;
    final Color sub = critical ? StatusColors.onCritical : AppTheme.textSecondary;
    final Color iconColor = critical ? StatusColors.onCritical : accent;
    final Color border = critical ? accent : (tier == AlertTier.important ? accent.withOpacity(0.6) : AppTheme.subtleBorder);
    final m = message;
    final action = actionLabel;
    final dismiss = onDismiss;

    return Semantics(
      container: true,
      liveRegion: critical,
      child: Material(
        color: bg,
        elevation: critical ? 2 : 1,
        shadowColor: AppTheme.shadow,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.mdAll,
          side: BorderSide(color: border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(Space.s12, Space.s8, dismiss == null ? Space.s12 : 0.0, Space.s8),
            child: Row(
              children: [
                Icon(tier.icon, color: iconColor, size: 24),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(color: fg, fontWeight: FontWeight.w700),
                      ),
                      if (m != null && m.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            m,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.label.copyWith(color: sub, fontWeight: FontWeight.w400),
                          ),
                        ),
                      if (action != null && onAction != null)
                        Padding(
                          padding: const EdgeInsets.only(top: Space.s4),
                          child: TextButton(
                            onPressed: onAction,
                            style: TextButton.styleFrom(
                              foregroundColor: critical ? StatusColors.onCritical : AppTheme.neonCyan,
                              backgroundColor: critical ? Colors.black.withOpacity(0.18) : AppTheme.neonCyan.withOpacity(0.12),
                              minimumSize: const Size(48, 44),
                              padding: const EdgeInsets.symmetric(horizontal: Space.s12),
                              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                            ),
                            child: Text(action, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                        ),
                    ],
                  ),
                ),
                if (dismiss != null)
                  IconButton(
                    onPressed: dismiss,
                    tooltip: 'Dismiss',
                    icon: Icon(Icons.close_rounded, color: sub, size: 20),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
