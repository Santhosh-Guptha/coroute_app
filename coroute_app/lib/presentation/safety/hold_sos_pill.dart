import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';

/// A wide red "Send SOS" button for cards (3.55 missing-rider check): hold it for
/// [RideThresholds.sosHold] (3 s, the same hold as the big SOS button) to raise the real SOS.
/// A tap or a bump does nothing; letting go early cancels. While held, the fill grows from the
/// left and the label says "Keep holding…". Screen readers: "Send SOS, press and hold"; their
/// long-press action sends it.
class HoldSosPill extends StatefulWidget {
  final VoidCallback onTriggered;
  final String label;

  const HoldSosPill({super.key, required this.onTriggered, this.label = HoldSosPill.defaultLabel});

  static const String defaultLabel = 'Send SOS';
  static const String holdingLabel = 'Keep holding…';
  static const String hint = 'Hold to send';

  @override
  State<HoldSosPill> createState() => _HoldSosPillState();
}

class _HoldSosPillState extends State<HoldSosPill> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: RideThresholds.sosHold,
    reverseDuration: Motion.sheet,
  )..addStatusListener(_onStatus);

  bool _fired = false;

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_fired) {
      _fired = true;
      _trigger();
    }
  }

  void _trigger() {
    HapticFeedback.heavyImpact();
    widget.onTriggered();
  }

  void _down() {
    _fired = false;
    _hold.forward(from: 0);
  }

  void _release() {
    if (_fired) {
      _hold.value = 0;
    } else if (_hold.value > 0 || _hold.isAnimating) {
      _hold.reverse();
    }
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final red = AppTheme.sos;
    return Semantics(
      container: true,
      button: true,
      label: '${widget.label}, press and hold',
      excludeSemantics: true,
      onLongPress: _trigger,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _down(),
        onTapUp: (_) => _release(),
        onTapCancel: _release,
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: SizedBox(
            height: 52,
            child: AnimatedBuilder(
              animation: _hold,
              builder: (context, _) {
                final v = _hold.value;
                return Stack(fit: StackFit.expand, children: [
                  ColoredBox(color: red),
                  // The hold progress: a darker fill growing from the start edge.
                  FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: v,
                    child: ColoredBox(color: Colors.black.withValues(alpha: 0.28)),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.s16),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.sos_rounded, color: Colors.white, size: 24),
                      const SizedBox(width: Space.s8),
                      Flexible(
                        child: Text(
                          v > 0 ? HoldSosPill.holdingLabel : '${widget.label} · ${HoldSosPill.hint.toLowerCase()}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ]),
                  ),
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }
}
