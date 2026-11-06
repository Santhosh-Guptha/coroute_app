// The single fuel alert pipeline (SafetyService) with stations ahead from the
// map places on the phone: "fill up here" once before a long gap, then the
// usual low-fuel tiers on the same prompt key (never a second popup).
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:coroute_app/core/constants/safety_constants.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/safety_service.dart';
import 'package:coroute_app/data/services/settings_service.dart';
import 'package:coroute_app/domain/places/fuel_ahead.dart';
import 'package:coroute_app/domain/places/fuel_match.dart';
import 'package:coroute_app/domain/places/place_poi.dart';
import 'package:coroute_app/domain/safety/fuel_profile.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

import 'safety_service_test.dart' show FakePort, FakeAccel, FakeSms, t0;

TrackPoint at(int s, double km, {double kmh = 50}) => TrackPoint(ts: t0 + s * 1000, lat: 17.0 + km * 0.009, lng: 78.0, speedKmh: kmh);

FuelStop stopAt(String id, double km) => FuelStop(
    poi: PlacePoi.fromWire({'i': id, 'a': 17.0, 'o': 78.0, 't': {'amenity': 'fuel', 'name': 'Pump $id', 'fuel:octane_91': 'yes'}})!,
    match: FuelMatch.match,
    alongM: km * 1000,
    offM: 0,
    distanceKm: km,
    reach: Reach.unknown);

void main() {
  late int now;
  late FakePort port;
  late SafetyService safety;
  late SettingsService settings;

  Future<void> start(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    now = t0;
    port = FakePort(() => now);
    settings = SettingsService();
    await settings.load();
    await settings.setFuelProfile(const FuelProfile(fullRangeKm: 400, bufferKm: 20));
    safety = SafetyService.forTest(port, settings, accel: FakeAccel(), sms: FakeSms(), clock: () => now);
    port.convoy = ConvoyModel(
      groupId: 'G',
      name: 'Ride',
      joinCode: '123456',
      createdByUserId: 'lead',
      createdByUserName: 'Lead',
      createdAtEpochMs: t0,
      tripStatus: 'STARTED',
      riders: {'me': RiderModel(userId: 'me', name: 'Kiran', lat: 17, lng: 78, lastSeenEpochMs: t0)},
    );
    port.changed();
    await tester.pump();
  }

  Future<void> end(WidgetTester tester) async {
    safety.dispose();
    await port.fixes.close();
    port.dispose();
    settings.dispose();
    await tester.pump();
  }

  testWidgets('fill up here once before a long gap, then low fuel on the same prompt', (tester) async {
    await start(tester);
    expect(safety.refuel(currentKm: 120), true); // 100 km usable before the 20 km buffer
    var stops = [stopAt('here', 3), stopAt('next', 150)];
    var calls = 0;
    safety.fuelAheadSource = (lat, lng, usableKm, marginKm) {
      calls++;
      return FuelAheadView(type: BikeFuelType.petrol, stops: stops, coverageKm: 200);
    };
    port.fixes.add(at(0, 0));
    await tester.pump();
    expect(calls, 1);
    expect(safety.prompts.map((p) => p.key), [SafetyConstants.promptFuel]);
    expect(safety.prompts.single.title, 'Fill up here');
    expect(safety.prompts.single.message, contains('Next fuel after this is 147 km away'));
    expect(safety.fuelAhead?.stops.first.poi.id, 'here');

    port.fixes.add(at(10, 0.1));
    await tester.pump();
    expect(safety.prompts.length, 1, reason: 'given once per station');

    stops = [stopAt('next', 30)];
    expect(safety.refuel(currentKm: 70), true); // 50 km usable: low
    expect(safety.prompts, isEmpty);
    port.fixes.add(at(20, 0.2));
    await tester.pump();
    expect(safety.prompts.single.title, 'Fuel low');
    expect(safety.prompts.single.message, contains('Fuel low — next petrol station in 30 km'));
    port.fixes.add(at(30, 0.3));
    await tester.pump();
    expect(safety.prompts.length, 1, reason: 'same tier: no duplicate');
    await end(tester);
  });

  testWidgets('without route data the warning uses the range only', (tester) async {
    await start(tester);
    expect(safety.refuel(currentKm: 60), true);
    port.fixes.add(at(0, 0));
    await tester.pump();
    expect(safety.prompts.single.title, 'Fuel low');
    expect(safety.prompts.single.message, contains('no petrol station mapped ahead yet'));
    expect(safety.fuelAhead, isNull);
    await end(tester);
  });
}
