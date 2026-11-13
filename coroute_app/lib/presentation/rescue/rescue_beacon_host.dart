// Round 10 rescue beacon: pushes the victim's beacon screen (over the lock screen, named route
// 'safety/rescue_beacon') while the beacon runs or "Still able to respond?" asks, and no crash alarm
// screen is open (that screen shows the same panel itself). Shows nothing itself and does nothing
// without RescueBeaconService. Same pattern as CrashAlarmHost.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/alarm_notifier.dart';
import '../../data/services/rescue_beacon_service.dart';
import '../../data/services/safety_service.dart';
import '../../domain/security/lock_screen_cockpit_policy.dart';
import 'rescue_beacon_panel.dart';
import 'rescue_widgets.dart';

class RescueBeaconHost extends StatefulWidget {
  const RescueBeaconHost({super.key, required this.child, this.navigatorKey});

  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<RescueBeaconHost> createState() => _RescueBeaconHostState();
}

class _RescueBeaconHostState extends State<RescueBeaconHost> {
  RescueBeaconService? _rescue;
  SafetyService? _safety;
  Route<void>? _route;
  bool _askNotified = false;
  String? _shownFor;
  String? _dismissedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = Provider.of<RescueBeaconService?>(context, listen: false);
    final s = Provider.of<SafetyService?>(context, listen: false);
    if (!identical(r, _rescue)) {
      _rescue?.removeListener(_sync);
      _rescue = r;
      _rescue?.addListener(_sync);
    }
    if (!identical(s, _safety)) {
      _safety?.removeListener(_sync);
      _safety = s;
      _safety?.addListener(_sync);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    final r = _rescue;
    final asking = r?.askingResponse ?? false;
    // The check needs the rider's attention even with the phone in a pocket: one heads-up.
    if (asking && !_askNotified) {
      _askNotified = true;
      AlarmNotifier.showCriticalAlert('Still able to respond?', 'Open CoRoute and tap "I can respond", or a loud rescue siren starts in about a minute.').ignore();
    } else if (!asking) {
      _askNotified = false;
    }
    // One push per beacon start / per check: Back closes it (the beacon keeps running).
    final key = r == null ? null : (r.active ? 'beacon:${r.plan.startedAt}' : (asking ? 'ask:${r.check.key}' : null));
    final want = r != null && key != null && key != _dismissedFor && _safety?.alarm == null;
    if (want && _route == null) {
      final nav = widget.navigatorKey?.currentState;
      if (nav == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
        return;
      }
      final route = MaterialPageRoute<void>(
        fullscreenDialog: true,
        settings: const RouteSettings(name: LockScreenCockpitPolicy.routeRescueBeacon),
        builder: (_) => const RescueBeaconScreen(),
      );
      _route = route;
      _shownFor = key;
      nav.push(route).whenComplete(() {
        if (identical(_route, route)) {
          _route = null;
          _dismissedFor = _shownFor; // closed by Back: not pushed again for this start
        }
      });
    } else if (!want && _route != null) {
      final route = _route!;
      _route = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  @override
  void dispose() {
    _rescue?.removeListener(_sync);
    _safety?.removeListener(_sync);
    super.dispose();
  }

  /// The screen flash (torch not available) covers the whole app, also the crash alarm screen.
  @override
  Widget build(BuildContext context) {
    final r = _rescue;
    if (r == null) return widget.child;
    return Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(child: ListenableBuilder(listenable: r, builder: (_, _) => RescueStrobeOverlay(active: r.screenStrobe))),
      ],
    );
  }
}
