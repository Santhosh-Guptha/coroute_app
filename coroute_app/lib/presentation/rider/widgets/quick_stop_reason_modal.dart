import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_tokens.dart';
import '../../../data/services/convoy_service.dart';

/// Instant glove-friendly popup modal with 4 oversized buttons to report stop reasons.
///
/// Designed for quick 1-tap operation on motorcycle handlebars:
/// - 4 oversized buttons: 'Fueling', 'Rest/Break', 'Mechanical/Tyre', 'Phone/Nav'.
/// - Glove-sized touch targets (>64dp tall).
/// - Instant broadcast to convoy via [ConvoyService.updateStatusReason] without opening the sheet.
/// - Glowing active border for currently active reason.
/// - ZERO emojis, ASCII hyphens only.
class QuickStopReasonModal extends StatelessWidget {
  final ConvoyService convoyService;
  final String userId;
  final String currentReason;
  final void Function(String reason, String label)? onBroadcast;

  const QuickStopReasonModal({
    super.key,
    required this.convoyService,
    required this.userId,
    this.currentReason = '',
    this.onBroadcast,
  });

  static Future<void> show(
    BuildContext context, {
    required ConvoyService convoyService,
    required String userId,
    String currentReason = '',
    void Function(String reason, String label)? onBroadcast,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.75),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s24),
        child: QuickStopReasonModal(
          convoyService: convoyService,
          userId: userId,
          currentReason: currentReason,
          onBroadcast: onBroadcast,
        ),
      ),
    );
  }

  void _select(BuildContext context, String code, String label) {
    convoyService.updateStatusReason(userId: userId, reason: code, message: label);
    onBroadcast?.call(code, label);
    Navigator.of(context).pop();
  }

  void _clear(BuildContext context) {
    convoyService.updateStatusReason(userId: userId, reason: '', message: '');
    onBroadcast?.call('', 'Moving - Stop Cleared');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final reasons = [
      (
        key: const Key('stop_reason_fueling'),
        code: 'FUELING',
        label: 'Fueling',
        icon: Icons.local_gas_station_rounded,
        accent: AppTheme.hyperAmber,
      ),
      (
        key: const Key('stop_reason_rest_break'),
        code: 'REST_BREAK',
        label: 'Rest/Break',
        icon: Icons.free_breakfast_rounded,
        accent: AppTheme.infoBlue,
      ),
      (
        key: const Key('stop_reason_mechanical_tyre'),
        code: 'MECHANICAL',
        label: 'Mechanical/Tyre',
        icon: Icons.build_rounded,
        accent: AppTheme.laserRed,
      ),
      (
        key: const Key('stop_reason_phone_nav'),
        code: 'PHONE_NAV',
        label: 'Phone/Nav',
        icon: Icons.phone_android_rounded,
        accent: AppTheme.neonCyan,
      ),
    ];

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: AppTheme.obsidianVoid,
        borderRadius: Radii.lgAll,
        border: Border.all(color: AppTheme.glassBorder, width: 2.0),
        boxShadow: [
          BoxShadow(
            color: AppTheme.shadow,
            blurRadius: 16.0,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(Space.s16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.pause_circle_filled_rounded, color: AppTheme.hyperAmber, size: 28),
                      const SizedBox(width: Space.s8),
                      Expanded(
                        child: Text(
                          'Quick Stop Reason',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('stop_reason_close'),
                  tooltip: 'Close modal',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: Icon(Icons.close_rounded, color: AppTheme.textSecondary, size: 26),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          const SizedBox(height: Space.s4),
          Text(
            '1-Tap broadcasts status to convoy without opening sheet',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: Space.s16),
          // 2x2 grid of oversized cards for glove operation
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Space.s12,
            crossAxisSpacing: Space.s12,
            childAspectRatio: 1.35,
            children: [
              for (final r in reasons)
                _ReasonButton(
                  key: r.key,
                  label: r.label,
                  icon: r.icon,
                  accentColor: r.accent,
                  isSelected: currentReason == r.code,
                  onTap: () => _select(context, r.code, r.label),
                ),
            ],
          ),
          if (currentReason.isNotEmpty) ...[
            const SizedBox(height: Space.s12),
            FilledButton.icon(
              key: const Key('stop_reason_clear'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.slateCard,
                foregroundColor: AppTheme.textPrimary,
                minimumSize: const Size.fromHeight(52),
                shape: const RoundedRectangleBorder(
                  borderRadius: Radii.mdAll,
                  side: BorderSide(color: Colors.white24, width: 1.5),
                ),
              ),
              icon: Icon(Icons.play_arrow_rounded, color: AppTheme.emeraldSafe, size: 24),
              label: const Text(
                'Resume Ride (Clear Stop)',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              onPressed: () => _clear(context),
            ),
          ],
        ],
      ),
    ),
  );
}
}

class _ReasonButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color accentColor;
  final bool isSelected;
  final VoidCallback onTap;

  const _ReasonButton({
    super.key,
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      selected: isSelected,
      child: Material(
        color: isSelected ? accentColor.withOpacity(0.18) : AppTheme.slateCard,
        borderRadius: Radii.mdAll,
        child: InkWell(
          borderRadius: Radii.mdAll,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(Space.s12),
            decoration: BoxDecoration(
              borderRadius: Radii.mdAll,
              border: Border.all(
                color: isSelected ? accentColor : AppTheme.subtleBorder,
                width: isSelected ? 2.5 : 1.5,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: accentColor.withOpacity(0.35),
                        blurRadius: 10,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 32,
                  color: isSelected ? accentColor : AppTheme.textPrimary,
                ),
                const SizedBox(height: Space.s8),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isSelected ? accentColor : AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
