// Round 10 rescue beacon: small widgets shared by the victim's beacon screen and the finder.
// Glove-friendly: every control is at least 64 dp tall.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/rescue/proximity_trend.dart';
import '../../domain/rescue/rescue_strobe.dart';

/// A button that acts only after being held for [hold] (a deliberate action: a bystander stopping
/// the siren). A ring fills while held; letting go early does nothing.
class HoldToConfirmButton extends StatefulWidget {
  const HoldToConfirmButton({
    super.key,
    required this.label,
    required this.holdingLabel,
    required this.onConfirmed,
    this.icon = Icons.volume_off_rounded,
    this.hold = const Duration(seconds: 3),
    this.color,
  });

  final String label;
  final String holdingLabel;
  final VoidCallback onConfirmed;
  final IconData icon;
  final Duration hold;
  final Color? color;

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.hold)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact().catchError((Object _) {});
        widget.onConfirmed();
        _c.reset();
      }
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() {
    HapticFeedback.selectionClick().catchError((Object _) {});
    _c.forward(from: 0);
  }

  void _up() {
    if (_c.status != AnimationStatus.completed) _c.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppTheme.sos;
    return Semantics(
      button: true,
      label: '${widget.label}. Press and hold for ${widget.hold.inSeconds} seconds.',
      child: Listener(
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final holding = _c.value > 0;
            return Container(
              constraints: const BoxConstraints(minHeight: 72),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: color, width: 2),
                gradient: LinearGradient(
                  colors: [color.withValues(alpha: 0.9), color.withValues(alpha: 0.9), color.withValues(alpha: 0.15), color.withValues(alpha: 0.15)],
                  stops: [0, _c.value, _c.value, 1],
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(widget.icon, color: holding ? Colors.white : color, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      holding ? widget.holdingLabel : widget.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: holding ? Colors.white : AppTheme.text, fontSize: 17, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A horizontal strength meter with a hotter / colder chip ("Bluetooth", "Rescue beacon").
class RescueMeter extends StatelessWidget {
  const RescueMeter({super.key, required this.title, required this.value, required this.trend, required this.emptyText, this.detail});

  final String title;

  /// 0..1, null when nothing is heard.
  final double? value;
  final TrendDirection trend;
  final String emptyText;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final v = value;
    final color = v == null
        ? AppTheme.textMuted
        : (v > 0.66 ? AppTheme.sos : (v > 0.33 ? AppTheme.warning : AppTheme.infoBlue));
    return Container(
      padding: const EdgeInsets.all(Space.s12),
      decoration: BoxDecoration(color: AppTheme.card, borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.subtleBorder)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AppText.label)),
              if (v != null) TrendChip(trend: trend),
            ],
          ),
          const SizedBox(height: Space.s8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: v ?? 0,
              minHeight: 18,
              backgroundColor: AppTheme.subtleBorder,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: Space.s4),
          Text(v == null ? emptyText : (detail ?? ''), style: AppText.caption),
        ],
      ),
    );
  }
}

class TrendChip extends StatelessWidget {
  const TrendChip({super.key, required this.trend});
  final TrendDirection trend;

  @override
  Widget build(BuildContext context) {
    final (text, color, icon) = switch (trend) {
      TrendDirection.hotter => ('Hotter', AppTheme.sos, Icons.trending_up_rounded),
      TrendDirection.colder => ('Colder', AppTheme.infoBlue, Icons.trending_down_rounded),
      TrendDirection.steady => ('Same', AppTheme.textSecondary, Icons.trending_flat_rounded),
      TrendDirection.unknown => ('Reading...', AppTheme.textMuted, Icons.more_horiz_rounded),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 13)),
      ]),
    );
  }
}

/// A full-screen white flash in the SOS Morse pattern (when the torch is not available).
/// Uses [RescueStrobe.sosPattern]: never more than 3 flashes per second.
class RescueStrobeOverlay extends StatefulWidget {
  const RescueStrobeOverlay({super.key, required this.active});
  final bool active;

  @override
  State<RescueStrobeOverlay> createState() => _RescueStrobeOverlayState();
}

class _RescueStrobeOverlayState extends State<RescueStrobeOverlay> {
  static final List<int> _pattern = RescueStrobe.sosPattern();
  Timer? _t;
  int _i = 0;
  bool _on = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _step();
  }

  @override
  void didUpdateWidget(covariant RescueStrobeOverlay old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _i = 0;
      _step();
    } else if (!widget.active && old.active) {
      _t?.cancel();
      setState(() => _on = false);
    }
  }

  void _step() {
    if (!mounted || !widget.active) return;
    setState(() => _on = _i.isEven);
    final d = _pattern[_i % _pattern.length];
    _i = (_i + 1) % _pattern.length;
    _t = Timer(Duration(milliseconds: d), _step);
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active || !_on) return const SizedBox.shrink();
    return const IgnorePointer(child: ColoredBox(color: Colors.white, child: SizedBox.expand()));
  }
}
