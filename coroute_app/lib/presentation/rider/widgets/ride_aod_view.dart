import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/notify/status_text.dart';
import '../../../domain/route/next_turn.dart';
import '../../../domain/tracking/screen_awake_policy.dart';

/// Ride AOD (docs/features_355/lock_screen_cockpit.md): after 30 s without a touch while the ride screen is kept on,
/// a pure black, minimal view replaces the plain dim (the window brightness is very low at the same time).
///
/// Shows the speed, the next turn and its distance, the leader's distance and direction (or the group status),
/// the time, the battery and a small "Hold SOS" hint. Everything moves a few pixels once a minute
/// ([ScreenAwakePolicy.burnInShift]) so no pixel stays lit in one place. A tap anywhere brings the full cockpit
/// back (the cockpit's global pointer route); holding the SOS hint opens the hold-to-send SOS screen.
/// Always dark, whatever the app theme: black pixels are off on OLED screens.
class RideAodView extends StatefulWidget {
  const RideAodView({
    super.key,
    required this.speedKmh,
    this.limitKmh = 0,
    this.turn,
    this.leaderDistanceM,
    this.leaderRelativeBearing,
    this.groupLine,
    this.batteryPercent = -1,
    this.charging = false,
    this.onHoldSos,
    this.onWake,
    this.now,
  });

  final double speedKmh;

  /// Round 9: the limit I am warned at (0 = none), so a limit changed mid-ride shows here too.
  final int limitKmh;
  final NextTurn? turn;
  final double? leaderDistanceM;

  /// Direction to the leader relative to my heading, degrees (0 = straight ahead).
  final double? leaderRelativeBearing;

  /// "3 of 5 riding" when there is no leader to point at (null on a solo ride).
  final String? groupLine;
  final int batteryPercent;
  final bool charging;
  final VoidCallback? onHoldSos;

  /// A short tap on the SOS hint (the hint itself does not wake the screen on touch, so it can be held).
  final VoidCallback? onWake;

  /// Clock for tests.
  final DateTime Function()? now;

  /// True while a finger is on the SOS hint: the cockpit's "any touch wakes the screen" route lets it be held.
  static bool sosPointerDown = false;

  static const Color _fg = Color(0xFFD0D0D0);
  static const Color _dim = Color(0xFF8A8A8A);
  static const Color _sos = Color(0xFFE53935);

  static IconData turnIcon(TurnDirection d) => switch (d) {
        TurnDirection.straight => Icons.straight,
        TurnDirection.slightLeft => Icons.turn_slight_left,
        TurnDirection.slightRight => Icons.turn_slight_right,
        TurnDirection.left => Icons.turn_left,
        TurnDirection.right => Icons.turn_right,
        TurnDirection.sharpLeft => Icons.turn_sharp_left,
        TurnDirection.sharpRight => Icons.turn_sharp_right,
        TurnDirection.uTurn => Icons.u_turn_left,
      };

  @override
  State<RideAodView> createState() => _RideAodViewState();
}

class _RideAodViewState extends State<RideAodView> {
  Timer? _tick;

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _arm();
  }

  /// One timer per minute: the clock and the burn-in shift change together.
  void _arm() {
    _tick?.cancel();
    final now = _now().millisecondsSinceEpoch;
    final wait = ScreenAwakePolicy.nextShiftAt(now) - now;
    _tick = Timer(Duration(milliseconds: wait <= 0 ? 1000 : wait), () {
      if (!mounted) return;
      setState(() {});
      _arm();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    RideAodView.sosPointerDown = false;
    super.dispose();
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final now = _now();
    final shift = ScreenAwakePolicy.burnInShift(now.millisecondsSinceEpoch);
    final w = widget;
    final turn = w.turn;
    final speed = w.speedKmh.isFinite && w.speedKmh > 0 ? w.speedKmh.round() : 0;
    const label = TextStyle(color: RideAodView._dim, fontSize: 16, fontWeight: FontWeight.w500, decoration: TextDecoration.none);
    return Semantics(
      label: 'Ride screen resting. Tap to show the full ride screen.',
      container: true,
      child: ColoredBox(
        key: const Key('ride_aod'),
        color: Colors.black,
        child: SafeArea(
          child: Transform.translate(
            key: const Key('ride_aod_content'),
            offset: Offset(shift.dx.toDouble(), shift.dy.toDouble()),
            child: DefaultTextStyle(
              style: label,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${_two(now.hour)}:${_two(now.minute)}', key: const Key('ride_aod_time')),
                        if (w.batteryPercent >= 0)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(w.charging ? Icons.battery_charging_full_rounded : Icons.battery_std_rounded, size: 16, color: RideAodView._dim),
                              const SizedBox(width: 4),
                              Text('${w.batteryPercent}%'),
                            ],
                          ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      '$speed',
                      key: const Key('ride_aod_speed'),
                      style: const TextStyle(color: RideAodView._fg, fontSize: 112, fontWeight: FontWeight.w300, height: 1.0, decoration: TextDecoration.none),
                    ),
                    const Text('km/h'),
                    if (w.limitKmh > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          speed > w.limitKmh ? 'Over limit ${w.limitKmh}' : 'Limit ${w.limitKmh}',
                          key: const Key('ride_aod_limit'),
                          style: TextStyle(
                            color: speed > w.limitKmh ? RideAodView._sos : RideAodView._dim,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    const SizedBox(height: 28),
                    if (turn != null)
                      Row(
                        key: const Key('ride_aod_turn'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(RideAodView.turnIcon(turn.direction), size: 44, color: RideAodView._fg),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(turn.distanceText,
                                    style: const TextStyle(color: RideAodView._fg, fontSize: 28, fontWeight: FontWeight.w500, decoration: TextDecoration.none)),
                                if (turn.road.isNotEmpty) Text(turn.road, maxLines: 1, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 20),
                    if (w.leaderDistanceM != null)
                      Row(
                        key: const Key('ride_aod_leader'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Transform.rotate(
                            angle: (w.leaderRelativeBearing ?? 0) * math.pi / 180.0,
                            child: const Icon(Icons.navigation_rounded, size: 24, color: RideAodView._fg),
                          ),
                          const SizedBox(width: 8),
                          Text('Leader ${StatusText.roundedDistance(w.leaderDistanceM!)}'),
                        ],
                      )
                    else if (w.groupLine != null)
                      Text(w.groupLine!, key: const Key('ride_aod_group')),
                    const Spacer(),
                    _sosHint(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sosHint() {
    return Listener(
      onPointerDown: (_) => RideAodView.sosPointerDown = true,
      onPointerUp: (_) => RideAodView.sosPointerDown = false,
      onPointerCancel: (_) => RideAodView.sosPointerDown = false,
      child: Semantics(
        button: true,
        label: 'Hold for SOS',
        child: GestureDetector(
          key: const Key('ride_aod_sos'),
          behavior: HitTestBehavior.opaque,
          onLongPress: widget.onHoldSos,
          onTap: widget.onWake,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: RideAodView._sos.withValues(alpha: 0.7)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sos_rounded, size: 18, color: RideAodView._sos),
                SizedBox(width: 6),
                Text('Hold SOS', style: TextStyle(color: RideAodView._sos, fontSize: 15, fontWeight: FontWeight.w600, decoration: TextDecoration.none)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
