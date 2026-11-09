import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

/// 3.55 "speak while moving, act when stopped": the compact form of a non-urgent card that needs a
/// tap (off-route, swap ask, historic place, place review) while the rider is moving. One line,
/// no buttons, no close button, nothing to tap: it only says what is waiting. The full card with
/// its buttons comes back once the rider has stopped ([RideTapGate]).
class MovingCardChip extends StatelessWidget {
  final String text;
  final IconData icon;

  /// Amber border (off-route, swap ask) instead of the plain card border.
  final bool important;

  const MovingCardChip({super.key, required this.text, this.icon = Icons.pan_tool_alt_rounded, this.important = false});

  @override
  Widget build(BuildContext context) {
    final fg = important ? AppTheme.warnText : AppTheme.text;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        container: true,
        label: text,
        excludeSemantics: true,
        child: IgnorePointer(
          child: Container(
            constraints: const BoxConstraints(minHeight: 40, maxWidth: 580),
            padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
            decoration: BoxDecoration(
              color: important ? AppTheme.warnTint : AppTheme.card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: important ? AppTheme.warnBorder : AppTheme.border, width: 2),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: important ? AppTheme.warnText : AppTheme.accentText),
              const SizedBox(width: Space.s8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
