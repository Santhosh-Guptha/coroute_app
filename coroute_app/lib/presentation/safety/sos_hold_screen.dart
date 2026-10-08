import 'package:flutter/material.dart';
import '../../core/ui/ui.dart';
import '../../data/services/safety_native.dart';

/// The SOS screen opened from the ride notification (also over the lock
/// screen). Nothing is sent by opening it: the rider holds the big SOS
/// button for 1.5 s ([SOSButton]) or taps Cancel. Full screen, red, big
/// targets, no typing, no scrolling needed.
///
/// [show] returns true when the SOS was triggered (the caller then sends it
/// through the normal SOS path and shows the delivery sheet). On close the
/// lock-screen window flag set for this launch is cleared
/// ([SafetyNative.alarmWindow]).
class SosHoldScreen extends StatelessWidget {
  final VoidCallback onSend;
  final VoidCallback onCancel;

  const SosHoldScreen({super.key, required this.onSend, required this.onCancel});

  static const double buttonSize = 132;

  static bool _open = false;

  /// True while the screen is showing (a second request does not open another one).
  static bool get isOpen => _open;

  /// Opens the hold screen on [context]'s navigator. True when the rider held SOS.
  static Future<bool> show(BuildContext context) async {
    if (_open) return false;
    _open = true;
    try {
      final sent = await Navigator.of(context, rootNavigator: true).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (ctx) => SosHoldScreen(
            onSend: () => Navigator.of(ctx).pop(true),
            onCancel: () => Navigator.of(ctx).pop(false),
          ),
        ),
      );
      return sent ?? false;
    } finally {
      _open = false;
      SafetyNative.alarmWindow(false).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color onRed = StatusColors.onCritical;
    final title = Semantics(
      header: true,
      liveRegion: true,
      child: Text('Hold to send SOS', textAlign: TextAlign.center, style: AppText.metric.copyWith(color: onRed, fontSize: 30, height: 1.15)),
    );
    final help = Text(
      'Press and hold the button until the ring is full. Your group then sees where you are. Nothing is sent until you hold it.',
      textAlign: TextAlign.center,
      style: AppText.body.copyWith(color: onRed),
    );
    final hold = Center(
      child: Semantics(
        container: true,
        button: true,
        label: 'Send SOS to your group',
        hint: 'Press and hold to send',
        excludeSemantics: true,
        onLongPress: onSend,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: onRed, width: 3)),
          child: Padding(
            padding: const EdgeInsets.all(Space.s4),
            child: SOSButton(onTriggered: onSend, size: buttonSize),
          ),
        ),
      ),
    );
    final cancel = SizedBox(
      height: 64,
      child: OutlinedButton.icon(
        onPressed: onCancel,
        style: OutlinedButton.styleFrom(
          foregroundColor: onRed,
          side: BorderSide(color: onRed, width: 2),
          minimumSize: const Size.fromHeight(64),
          textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        icon: const Icon(Icons.close_rounded, size: 28),
        label: const Text('Cancel', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: StatusColors.critical,
        body: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth > box.maxHeight && box.maxWidth >= 480;
            if (wide) {
              return Padding(
                padding: const EdgeInsets.all(Space.s16),
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [title, const SizedBox(height: Space.s12), help, const SizedBox(height: Space.s16), cancel],
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.s16),
                    Expanded(child: hold),
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(Space.s16),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight > Space.s32 ? box.maxHeight - Space.s32 : 0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [title, const SizedBox(height: Space.s12), help]),
                    Padding(padding: const EdgeInsets.symmetric(vertical: Space.s24), child: hold),
                    cancel,
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
