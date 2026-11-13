import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_motion.dart';
import 'optimistic.dart';
import 'ui_tokens.dart';

enum AppHaptic { none, light, selection, medium }

void _fire(AppHaptic h) {
  switch (h) {
    case AppHaptic.none:
      break;
    case AppHaptic.light:
      AppHaptics.light();
    case AppHaptic.selection:
      AppHaptics.selection();
    case AppHaptic.medium:
      AppHaptics.medium();
  }
}

/// Pressed feedback for any tappable: the child shrinks a little and dims
/// while the finger is down and springs back on release. The tap itself is
/// not delayed (it fires on finger up, like InkWell). Transform + opacity
/// only. Reduce motion: dim only.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final AppHaptic haptic;

  /// Null = from the child's size ([MotionSpec.pressedScale]).
  final double? pressedScale;
  final double pressedOpacity;
  final String? semanticsLabel;
  final HitTestBehavior behavior;

  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.haptic = AppHaptic.light,
    this.pressedScale,
    this.pressedOpacity = 0.85,
    this.semanticsLabel,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  double _side = 56;

  void _set(bool v) {
    if (v) _side = context.size?.shortestSide ?? 56; // read in a gesture callback, never during build
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final level = AppMotion.levelOf(context);
    final scale = !_down || !MotionSpec.decorative(level) ? 1.0 : (widget.pressedScale ?? MotionSpec.pressedScale(_side));
    final d = AppMotion.durationOf(context, AppMotion.fast);
    Widget body = AnimatedOpacity(
      opacity: _down ? widget.pressedOpacity : 1,
      duration: d,
      child: AnimatedScale(scale: scale, duration: d, curve: _down ? AppMotion.standard : Curves.easeOutBack, child: widget.child),
    );
    body = GestureDetector(
      behavior: widget.behavior,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              _fire(widget.haptic);
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _set(false);
              AppHaptics.medium();
              widget.onLongPress!();
            },
      child: body,
    );
    final label = widget.semanticsLabel;
    return Semantics(button: true, enabled: enabled, label: label, child: body);
  }
}

/// Only the pressed look (scale + dim), for controls that already handle
/// their own taps (InkWell, buttons). It listens to raw pointers and does not
/// take part in gesture recognition, so the tap underneath is never delayed
/// or lost. Reduce motion: no scale.
class PressScale extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final double? scale;
  const PressScale({super.key, required this.child, this.enabled = true, this.scale});

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  double _side = 56;

  void _set(bool v) {
    if (!widget.enabled && v) return;
    if (v) _side = context.size?.shortestSide ?? 56;
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final on = _down && widget.enabled && MotionSpec.decorative(AppMotion.levelOf(context));
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: on ? (widget.scale ?? MotionSpec.pressedScale(_side)) : 1,
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        child: widget.child,
      ),
    );
  }
}

/// A full-width button for an async action: the spinner runs INSIDE the
/// button and the page stays usable. A second tap while it runs is ignored.
///
///     AsyncButton(label: 'Join crew', onPressed: () => crews.join(id))
class AsyncButton extends StatefulWidget {
  final String label;
  final String? busyLabel;
  final IconData? icon;
  final Future<void> Function()? onPressed;
  final bool outlined;
  final bool destructive;
  final double height;
  final AppHaptic haptic;

  /// Drive the busy state from outside (optional).
  final bool? busy;

  const AsyncButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busyLabel,
    this.icon,
    this.outlined = false,
    this.destructive = false,
    this.height = 52,
    this.haptic = AppHaptic.light,
    this.busy,
  });

  @override
  State<AsyncButton> createState() => _AsyncButtonState();
}

class _AsyncButtonState extends State<AsyncButton> {
  bool _busy = false;

  bool get _isBusy => widget.busy ?? _busy;

  Future<void> _run() async {
    final f = widget.onPressed;
    if (f == null || _isBusy) return;
    _fire(widget.haptic);
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final Color bg = widget.outlined ? AppTheme.card : (widget.destructive ? AppTheme.sos : AppTheme.primary);
    final Color fg = widget.outlined ? (widget.destructive ? AppTheme.sos : AppTheme.text) : (widget.destructive ? Colors.white : AppTheme.onPrimary);
    final busy = _isBusy;
    return Semantics(
      button: true,
      enabled: enabled && !busy,
      label: busy ? '${widget.busyLabel ?? widget.label}, in progress' : null,
      child: Pressable(
        haptic: AppHaptic.none,
        onTap: enabled && !busy ? _run : null,
        child: AnimatedContainer(
          duration: AppMotion.durationOf(context, AppMotion.fast),
          constraints: BoxConstraints(minHeight: widget.height),
          padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
          decoration: BoxDecoration(
            color: enabled ? bg : bg.withValues(alpha: 0.5),
            borderRadius: Radii.mdAll,
            border: widget.outlined ? Border.all(color: AppTheme.border2) : null,
          ),
          // Fills the width it is given, but only as tall as its content (never stretches in a Row or a bar).
          child: Center(
            heightFactor: 1,
            child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: fg)),
                const SizedBox(width: 10),
              ] else if (widget.icon != null) ...[
                Icon(widget.icon, size: 20, color: fg),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  busy ? (widget.busyLabel ?? widget.label) : widget.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w600, height: 1.2),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// A number that counts to its new value instead of jumping (score, km,
/// members). Tabular figures, so the width does not wobble.
class AnimatedCount extends StatelessWidget {
  final num value;
  final int decimals;
  final String prefix;
  final String suffix;
  final TextStyle? style;
  final String Function(double v)? format;
  const AnimatedCount(this.value, {super.key, this.decimals = 0, this.prefix = '', this.suffix = '', this.style, this.format});

  @override
  Widget build(BuildContext context) {
    final base = (style ?? AppText.metric).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    String text(double v) => '$prefix${format?.call(v) ?? v.toStringAsFixed(decimals)}$suffix';
    final d = AppMotion.durationOf(context, AppMotion.slow);
    if (d == Duration.zero) return Text(text(value.toDouble()), style: base, maxLines: 1, softWrap: false, overflow: TextOverflow.fade);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value.toDouble()),
      duration: d,
      curve: AppMotion.standard,
      builder: (_, v, _) => Text(text(v), style: base, maxLines: 1, softWrap: false, overflow: TextOverflow.fade, semanticsLabel: text(value.toDouble())),
    );
  }
}

/// A short message at the bottom ("Could not save. Try again."), with an
/// optional action (Retry / Undo). Replaces the one on screen.
void showAppToast(BuildContext context, String message, {String? actionLabel, VoidCallback? onAction, bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: actionLabel == null ? 3 : 5),
        content: Row(
          children: [
            if (error) ...[Icon(Icons.error_outline_rounded, size: 20, color: AppTheme.sos), const SizedBox(width: Space.s8)],
            Expanded(child: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis)),
          ],
        ),
        action: actionLabel == null || onAction == null ? null : SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
}

/// A switch that changes at once and saves in the background; when saving
/// fails it goes back and a toast says so. For cheap settings.
///
///     OptimisticSwitch(value: s.nightVoice, onSave: (v) => api.save(v), onChanged: (v) => s.setLocal(v))
class OptimisticSwitch extends StatefulWidget {
  final bool value;

  /// Sends the new value. Throw (or answer false) to roll back.
  final Future<Object?> Function(bool value) onSave;

  /// Tells the owner about the shown value (also on roll-back).
  final ValueChanged<bool>? onChanged;
  final String failureMessage;
  final bool enabled;

  const OptimisticSwitch({
    super.key,
    required this.value,
    required this.onSave,
    this.onChanged,
    this.failureMessage = 'Could not save. Check your connection and try again.',
    this.enabled = true,
  });

  @override
  State<OptimisticSwitch> createState() => _OptimisticSwitchState();
}

class _OptimisticSwitchState extends State<OptimisticSwitch> {
  late bool _shown = widget.value;
  bool _saving = false;

  @override
  void didUpdateWidget(OptimisticSwitch old) {
    super.didUpdateWidget(old);
    if (!_saving && old.value != widget.value) _shown = widget.value;
  }

  Future<void> _toggle(bool v) async {
    if (_saving) return;
    AppHaptics.selection();
    _saving = true;
    await Optimistic.run<bool>(
      read: () => _shown,
      apply: (x) {
        if (mounted) setState(() => _shown = x);
        widget.onChanged?.call(x);
      },
      next: v,
      commit: widget.onSave,
      onError: (_) {
        if (mounted) showAppToast(context, widget.failureMessage, error: true);
      },
    );
    _saving = false;
  }

  @override
  Widget build(BuildContext context) => Switch(value: _shown, onChanged: widget.enabled ? _toggle : null);
}
