import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/services/convoy_service.dart';

/// Instant glove-friendly "Stopping?" sheet with 4 oversized reason rows.
///
/// Designed for quick 1-tap operation on motorcycle handlebars:
/// - 4 oversized rows: 'Fueling', 'Rest/Break', 'Mechanical/Tyre', 'Phone/Nav'.
/// - Glove-sized touch targets (72 dp tall).
/// - Instant broadcast to convoy via [ConvoyService.updateStatusReason] without opening the sheet.
/// - Teal accent border and tint on the currently active reason.
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
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0xFF15232E).withOpacity(0.5),
      builder: (ctx) => QuickStopReasonModal(
        convoyService: convoyService,
        userId: userId,
        currentReason: currentReason,
        onBroadcast: onBroadcast,
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
        hint: 'Convoy sees you at the pump',
        icon: Icons.local_gas_station_outlined,
        warn: false,
      ),
      (
        key: const Key('stop_reason_rest_break'),
        code: 'REST_BREAK',
        label: 'Rest/Break',
        hint: 'Convoy pauses with you',
        icon: Icons.free_breakfast_outlined,
        warn: false,
      ),
      (
        key: const Key('stop_reason_mechanical_tyre'),
        code: 'MECHANICAL',
        label: 'Mechanical/Tyre',
        hint: 'Riders nearby can come back to help',
        icon: Icons.build_outlined,
        warn: true,
      ),
      (
        key: const Key('stop_reason_phone_nav'),
        code: 'PHONE_NAV',
        label: 'Phone/Nav',
        hint: 'Others keep riding - you stay on the map',
        icon: Icons.phone_android_outlined,
        warn: false,
      ),
    ];

    final bottom = MediaQuery.paddingOf(context).bottom;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: Radii.sheetTop,
        boxShadow: const [
          BoxShadow(color: Color(0x40000000), blurRadius: 40, offset: Offset(0, -12)),
        ],
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 32 + bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(color: AppTheme.border2, borderRadius: BorderRadius.circular(3)),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: AppTheme.warnTint, borderRadius: BorderRadius.circular(16)),
                  child: Icon(Icons.pause_rounded, color: AppTheme.warnText, size: 30),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Stopping?', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.headline),
                      const SizedBox(height: 2),
                      Text(
                        'Tell the convoy so nobody waits or worries',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                DsRoundButton(
                  key: const Key('stop_reason_close'),
                  icon: Icons.close_rounded,
                  label: 'Close modal',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 18),
            for (var i = 0; i < reasons.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              _ReasonRow(
                key: reasons[i].key,
                label: reasons[i].label,
                hint: reasons[i].hint,
                icon: reasons[i].icon,
                warn: reasons[i].warn,
                isSelected: currentReason == reasons[i].code,
                onTap: () => _select(context, reasons[i].code, reasons[i].label),
              ),
            ],
            const SizedBox(height: 18),
            if (currentReason.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: DsButton(
                      label: 'Keep riding',
                      tone: DsButtonTone.outline,
                      height: 58,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DsButton(
                      key: const Key('stop_reason_clear'),
                      label: 'Resume ride',
                      icon: Icons.play_arrow_rounded,
                      height: 58,
                      onPressed: () => _clear(context),
                    ),
                  ),
                ],
              )
            else
              DsButton(
                label: 'Keep riding',
                tone: DsButtonTone.outline,
                height: 58,
                onPressed: () => Navigator.of(context).pop(),
              ),
          ],
        ),
      ),
    );
  }
}

/// One 72 dp reason row: icon, title, hint. Teal border and tint when selected.
class _ReasonRow extends StatelessWidget {
  final String label;
  final String hint;
  final IconData icon;
  final bool warn;
  final bool isSelected;
  final VoidCallback onTap;

  const _ReasonRow({
    super.key,
    required this.label,
    required this.hint,
    required this.icon,
    required this.warn,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      selected: isSelected,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: DsCard(
          accent: isSelected,
          tinted: isSelected,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          onTap: onTap,
          child: Row(
            children: [
              Icon(icon, size: 26, color: warn ? AppTheme.warnText : AppTheme.accentText),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title),
                    const SizedBox(height: 2),
                    Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                  ],
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle_rounded, size: 22, color: AppTheme.accentText),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
