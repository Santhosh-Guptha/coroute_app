import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../constants/ride_thresholds.dart';
import '../theme/app_theme.dart';
import 'ui_tokens.dart';

/// Press-and-hold SOS button.
///
/// A tap does nothing (so a glove or a bump cannot raise an SOS). Holding
/// for [RideThresholds.sosHold] (1.5 s) fills a ring around the button,
/// then gives a heavy haptic and calls [onTriggered]; the caller runs the
/// existing SOS flow (ConvoyService.triggerSosAlert, EmergencySosSheet.show).
/// Letting go early cancels. The animation runs only while pressed.
///
/// Screen readers: "Emergency SOS, press and hold"; their long-press
/// action (double tap and hold) raises the SOS directly.
class SOSButton extends StatefulWidget {
  final VoidCallback onTriggered;
  final double size;

  const SOSButton({super.key, required this.onTriggered, this.size = 64});

  @override
  State<SOSButton> createState() => _SOSButtonState();
}

class _SOSButtonState extends State<SOSButton> with SingleTickerProviderStateMixin {
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
    final size = widget.size;
    final ring = size + 12;
    final red = StatusColors.critical;
    return Semantics(
      container: true,
      button: true,
      label: 'Emergency SOS, press and hold',
      excludeSemantics: true,
      onLongPress: _trigger,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _down(),
        onTapUp: (_) => _release(),
        onTapCancel: _release,
        child: SizedBox(
          width: ring,
          height: ring,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _hold,
                builder: (context, _) => _hold.value == 0
                    ? const SizedBox.shrink()
                    : SizedBox(
                        width: ring,
                        height: ring,
                        child: CircularProgressIndicator(
                          value: _hold.value,
                          strokeWidth: 5,
                          color: red,
                          backgroundColor: red.withOpacity(0.2),
                        ),
                      ),
              ),
              Material(
                color: red,
                shape: CircleBorder(side: BorderSide(color: AppTheme.slateCard, width: 2)),
                elevation: 3,
                shadowColor: AppTheme.shadow,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.s4),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'SOS',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            color: StatusColors.onCritical,
                            fontSize: size * 0.3,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
