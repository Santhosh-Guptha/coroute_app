import 'package:flutter/material.dart';
import '../../core/l10n/l10n.dart';
import '../../core/ui/ui.dart';
import '../../data/services/safety_native.dart';

/// The SOS screen opened from the ride notification (also over the lock
/// screen). Nothing is sent by opening it: the rider holds the big SOS
/// button for 1.5 s ([SOSButton]) or taps Cancel. Full screen, red, big
/// targets, no typing, no scrolling needed. Texts follow the rider's
/// language ([L10n], 3.16).
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

  /// The heading in the rider's language (read at build time).
  static String get title => L10n.t('sos.hold.title');

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
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final Color onRed = StatusColors.onCritical;
    final heading = Semantics(
      header: true,
      liveRegion: true,
      child: Text(
        title,
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: AppText.metric.copyWith(color: onRed, fontSize: 30, height: 1.15),
      ),
    );
    final help = Text(
      L10n.t('sos.hold.hint'),
      textAlign: TextAlign.center,
      maxLines: 8,
      overflow: TextOverflow.ellipsis,
      style: AppText.body.copyWith(color: onRed),
    );
    final hold = Center(
      child: Semantics(
        container: true,
        button: true,
        label: L10n.t('sos.hold.label'),
        hint: L10n.t('sos.hold.action'),
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
          padding: const EdgeInsets.symmetric(horizontal: Space.s12),
          textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        icon: const Icon(Icons.close_rounded, size: 28),
        label: Text(L10n.t('sos.cancel'), maxLines: 1, overflow: TextOverflow.ellipsis),
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
                          children: [heading, const SizedBox(height: Space.s12), help, const SizedBox(height: Space.s16), cancel],
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.s16),
                    // The hold button shrinks on a very low landscape screen instead of overflowing.
                    Expanded(child: FittedBox(fit: BoxFit.scaleDown, child: hold)),
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
                    Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [heading, const SizedBox(height: Space.s12), help]),
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
