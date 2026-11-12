// Cockpit on the lock screen while riding: the service (over-keyguard window, locked mode, screens opened above the
// cockpit) and the gate (padlock chip, private screens covered until the unlock). Fake native side.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:coroute_app/data/services/lock_screen_cockpit_service.dart';
import 'package:coroute_app/data/services/ride_window_native.dart';
import 'package:coroute_app/domain/auth/session_policy.dart';
import 'package:coroute_app/domain/security/lock_screen_cockpit_policy.dart';
import 'package:coroute_app/presentation/security/locked_cockpit_gate.dart';

class FakeRideWindow implements RideWindowPort {
  bool over = false;
  final List<bool> overCalls = [];
  bool locked = true;
  KeyguardUnlock answer = KeyguardUnlock.ok;
  int unlockCalls = 0;
  int thermal = 0;
  void Function(bool)? onKeyguard;
  void Function(int)? onThermal;

  @override
  Future<void> setCockpitOverKeyguard(bool on) async {
    over = on;
    overCalls.add(on);
  }

  @override
  Future<bool> keyguardLocked() async => locked;

  @override
  Future<KeyguardUnlock> requestUnlock() async {
    unlockCalls++;
    if (answer == KeyguardUnlock.ok) locked = false;
    return answer;
  }

  @override
  Future<int> thermalStatus() async => thermal;

  @override
  void listen({required void Function(bool locked) onKeyguard, required void Function(int status) onThermal}) {
    this.onKeyguard = onKeyguard;
    this.onThermal = onThermal;
  }
}

class _Cockpit extends StatefulWidget {
  const _Cockpit();

  @override
  State<_Cockpit> createState() => _CockpitState();
}

class _CockpitState extends State<_Cockpit> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<LockScreenCockpitService>().setCockpit(route: ModalRoute.of(context), visible: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const SizedBox(height: 120), // clear of the padlock chip at the top
          const Text('COCKPIT'),
          TextButton(
            key: const Key('open_private'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('PRIVATE')))),
            child: const Text('Chat'),
          ),
          TextButton(
            key: const Key('open_sos'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              settings: const RouteSettings(name: LockScreenCockpitPolicy.routeSosHold),
              builder: (_) => const Scaffold(body: Text('SOS HOLD')),
            )),
            child: const Text('SOS'),
          ),
        ],
      ),
    );
  }
}

class _Harness {
  _Harness() {
    service = LockScreenCockpitService(
      port: port,
      ride: () => ride,
      signedIn: () => signedIn,
      settingOn: () => setting,
      clock: () => 1000000,
    );
  }

  final FakeRideWindow port = FakeRideWindow();
  late final LockScreenCockpitService service;
  RideSafetyState ride = const RideSafetyState(rideActive: true);
  bool signedIn = true;
  bool setting = true;
  final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();

  Widget app() => ChangeNotifierProvider<LockScreenCockpitService>.value(
        value: service,
        child: MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [service.guard],
          builder: (context, child) => LockedCockpitGate(child: child ?? const SizedBox.shrink()),
          home: const _Cockpit(),
        ),
      );

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await service.start();
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('over the keyguard during a ride with the cockpit in front; off when the ride ends', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    expect(h.service.overKeyguard, isTrue);
    expect(h.port.over, isTrue);
    expect(h.service.locked, isTrue, reason: 'the fake keyguard is locked');

    h.ride = const RideSafetyState();
    h.service.refresh();
    await tester.pumpAndSettle();
    expect(h.port.over, isFalse, reason: 'never over the keyguard after the ride');
    expect(h.service.locked, isFalse);
    expect(find.byKey(const Key('locked_cockpit_chip')), findsNothing);
  });

  testWidgets('off after sign-out and with the setting off', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    expect(h.port.over, isTrue);
    h.signedIn = false;
    h.service.refresh();
    expect(h.port.over, isFalse, reason: 'signed out');
    h.signedIn = true;
    h.service.refresh();
    expect(h.port.over, isTrue);
    h.setting = false;
    h.service.refresh();
    expect(h.port.over, isFalse, reason: 'setting off');
  });

  testWidgets('locked: the padlock chip; it opens Unlock, Call 112 and Medical ID; gone once unlocked', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    expect(find.text(LockScreenCockpitPolicy.chipText), findsOneWidget);
    await tester.tap(find.byKey(const Key('locked_cockpit_chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('locked_cockpit_unlock')), findsOneWidget);
    expect(find.byKey(const Key('locked_cockpit_call_112')), findsOneWidget);
    expect(find.byKey(const Key('locked_cockpit_medical_id')), findsOneWidget);

    h.port.onKeyguard!(false); // unlocked with the fingerprint on the keyguard
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('locked_cockpit_chip')), findsNothing);
    expect(h.port.over, isTrue, reason: 'still the ride screen in front: back over the keyguard at the next lock');
  });

  testWidgets('a private screen asks for the unlock and opens when it succeeds', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('open_private')));
    await tester.pump();
    expect(h.port.unlockCalls, 1, reason: "the rider's own tap: asked at once");
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('locked_cockpit_shield')), findsNothing);
    expect(find.text('PRIVATE'), findsOneWidget);
    expect(h.service.locked, isFalse);
    expect(h.port.over, isFalse, reason: 'a private screen in front: locking now shows the normal keyguard');

    h.nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(h.port.over, isTrue, reason: 'back on the cockpit');
  });

  testWidgets('a cancelled unlock closes the private screen again; the cockpit stays', (tester) async {
    final h = _Harness();
    h.port.answer = KeyguardUnlock.cancelled;
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('open_private')));
    await tester.pumpAndSettle();
    expect(h.port.unlockCalls, 1);
    expect(find.text('PRIVATE'), findsNothing);
    expect(find.text('COCKPIT'), findsOneWidget);
    expect(h.service.guard.pendingCount, 0);
    expect(h.service.locked, isTrue);
    expect(find.byKey(const Key('locked_cockpit_chip')), findsOneWidget);
  });

  testWidgets('a screen that opens by itself is covered and waits; Back to ride closes it', (tester) async {
    final h = _Harness();
    h.port.answer = KeyguardUnlock.cancelled;
    await h.pump(tester);
    h.nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('PROMPT'))));
    await tester.pumpAndSettle();
    expect(h.port.unlockCalls, 0, reason: 'no tap: nothing pops up by itself');
    expect(find.byKey(const Key('locked_cockpit_shield')), findsOneWidget);
    expect(find.text(LockScreenCockpitPolicy.shieldTitle), findsOneWidget);
    expect(h.port.over, isTrue, reason: 'stays over the keyguard while it waits');
    await tester.tap(find.byKey(const Key('locked_shield_back')));
    await tester.pumpAndSettle();
    expect(find.text('PROMPT'), findsNothing);
    expect(find.byKey(const Key('locked_cockpit_shield')), findsNothing);
  });

  testWidgets('safety screens (SOS hold) open over the keyguard without unlocking', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.byKey(const Key('open_sos')));
    await tester.pumpAndSettle();
    expect(find.text('SOS HOLD'), findsOneWidget);
    expect(find.byKey(const Key('locked_cockpit_shield')), findsNothing);
    expect(h.port.unlockCalls, 0);
    expect(h.port.over, isTrue, reason: 'the SOS screen stays over the lock screen');
  });

  testWidgets('actions that are not screens (share, call a contact) wait for the unlock', (tester) async {
    final h = _Harness();
    h.port.answer = KeyguardUnlock.cancelled;
    await h.pump(tester);
    var ran = 0;
    expect(await h.service.runUnlocked(CockpitAction.call112, () => ran++), isTrue);
    expect(ran, 1);
    expect(h.port.unlockCalls, 0);
    expect(await h.service.runUnlocked(CockpitAction.shareLiveLink, () => ran++), isFalse);
    expect(ran, 1);
    expect(h.port.unlockCalls, 1);
    h.port.answer = KeyguardUnlock.ok;
    expect(await h.service.runUnlocked(CockpitAction.dialContact, () => ran++), isTrue);
    expect(ran, 2, reason: 'continues after the unlock');
  });

  testWidgets('the phone heat is passed on for the Ride AOD', (tester) async {
    final h = _Harness();
    h.port.thermal = 1;
    await h.pump(tester);
    expect(h.service.thermalStatus, 1);
    h.port.onThermal!(3);
    expect(h.service.thermalStatus, 3);
  });

  testWidgets('the chip hides on the black Ride AOD', (tester) async {
    final h = _Harness();
    await h.pump(tester);
    h.service.aodShowing = true;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('locked_cockpit_chip')), findsNothing);
    h.service.aodShowing = false;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('locked_cockpit_chip')), findsOneWidget);
  });
}
