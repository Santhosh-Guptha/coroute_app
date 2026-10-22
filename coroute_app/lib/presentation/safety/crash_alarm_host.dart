import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/services/safety_service.dart';
import 'crash_alarm_screen.dart';

/// Wraps the app (MaterialApp.builder, above the navigator). When a crash
/// alarm opens it pushes [CrashAlarmScreen] on top of whatever is showing;
/// when the alarm is closed it removes the screen again. Shows nothing itself
/// and does nothing when [SafetyService] is not provided.
class CrashAlarmHost extends StatefulWidget {
  final Widget child;

  /// The app's navigator (the host sits above it, so it cannot look it up).
  final GlobalKey<NavigatorState>? navigatorKey;

  const CrashAlarmHost({super.key, required this.child, this.navigatorKey});

  @override
  State<CrashAlarmHost> createState() => _CrashAlarmHostState();
}

class _CrashAlarmHostState extends State<CrashAlarmHost> {
  SafetyService? _safety;
  Route<void>? _route;
  bool _isPushing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final safety = Provider.of<SafetyService?>(context, listen: false);
    if (!identical(safety, _safety)) {
      _safety?.removeListener(_sync);
      _safety = safety;
      _safety?.addListener(_sync);
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
  }

  void _sync() {
    if (!mounted) return;
    final open = _safety?.alarm != null;
    final route = _route;

    if (open && route == null && !_isPushing) {
      final nav = widget.navigatorKey?.currentState;
      if (nav == null) {
        // Navigator not attached yet; retry on the next frame so the emergency alarm is never missed.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _sync();
        });
        return;
      }
      _isPushing = true;
      final r = MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const CrashAlarmScreen());
      _route = r;
      nav.push(r).whenComplete(() {
        _isPushing = false;
        if (identical(_route, r)) _route = null;
      });
    } else if (!open && (route != null || _isPushing)) {
      // After the frame: a button on the screen may be popping it right now
      // (the SOS sheet's "I am safe" closes the alarm and then pops).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _safety?.alarm != null) return;
        final currentRoute = _route;
        _route = null;
        _isPushing = false;
        if (currentRoute != null && currentRoute.isActive) {
          final nav = currentRoute.navigator;
          if (nav != null) {
            nav.removeRoute(currentRoute);
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _safety?.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
