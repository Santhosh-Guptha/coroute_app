import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/ui/ui.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/presentation/rider/live_cockpit_map_screen.dart';

void main() {
  const now = 1000000;
  RiderModel rider(double speed) => RiderModel(userId: 'a', name: 'A very long rider name', lat: 17, lng: 78, speedKmh: speed, lastSeenEpochMs: now);

  test('speed is numeric even at low speed or with a stop reason', () {
    for (final speed in [0.0, 2.0, 62.4]) {
      expect(riderMapSpeedLabel(rider(speed).copyWith(statusReason: 'FUEL'), status: RiderStatus.stopped, nowMs: now), '${speed.round()} km/h');
    }
  });

  test('old, missing, future, offline, low GPS and invalid speeds are unavailable', () {
    for (final sample in [rider(40).copyWith(lastSeenEpochMs: 0), rider(40).copyWith(lastSeenEpochMs: now - 300000), rider(40).copyWith(lastSeenEpochMs: now + 1), rider(double.nan), rider(double.infinity), rider(-1)]) {
      expect(riderMapSpeedLabel(sample, status: RiderStatus.emergency, nowMs: now), 'Speed unavailable');
    }
    for (final status in [RiderStatus.offline, RiderStatus.disconnected, RiderStatus.lowGps]) {
      expect(riderMapSpeedLabel(rider(40), status: status, nowMs: now), 'Speed unavailable');
    }
  });

  testWidgets('marker updates speed, preserves zero, and opens rider details', (tester) async {
    var taps = 0;
    Future<void> show(double speed, {bool isMe = false, RiderStatus status = RiderStatus.riding}) => tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 144, height: 140, child: RiderMapMarker(rider: rider(speed), isMe: isMe, color: Colors.orange, status: status, selected: false, nowMs: now, onTap: () => taps++))))));
    await show(42);
    expect(find.text('42 km/h'), findsOneWidget);
    await show(67);
    expect(find.text('42 km/h'), findsNothing);
    expect(find.text('67 km/h'), findsOneWidget);
    await tester.tap(find.text('67 km/h'));
    expect(taps, 1);
    await show(0, isMe: true);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('0 km/h'), findsOneWidget);
    await show(67, status: RiderStatus.disconnected);
    expect(find.text('Speed unavailable'), findsOneWidget);
    expect(find.text('67 km/h'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
