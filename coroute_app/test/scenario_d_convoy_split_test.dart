import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/domain/notify/alert_priority.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';

void main() {
  group('Scenario D: Highway Convoy Split', () {
    // A 25 km stretch of NH44 highway northbound along lng 77.600
    // Lat 13.000 to 13.250 (~27.8 km)
    final highwayPoints = <(double, double)>[
      for (double lat = 13.000; lat <= 13.250 + 1e-9; lat += 0.005) (lat, 77.600)
    ];
    final routePolyline = GeoMath.encodePolyline(highwayPoints);
    final routeLengthM = GeoMath.alongRoute(13.250, 77.600, highwayPoints)!.along;

    const now = 1700000000000;
    // Toll plaza located at lat 13.050 (~5.5 km along route)

    RiderModel makeRider(
      String id,
      String name, {
      required double lat,
      required double speedKmh,
      String role = 'PACK',
      int stoppedSince = 0,
      String statusReason = '',
    }) =>
        RiderModel(
          userId: id,
          name: name,
          lat: lat,
          lng: 77.600,
          speedKmh: speedKmh,
          role: role,
          stoppedSince: stoppedSince,
          statusReason: statusReason,
          lastSeenEpochMs: now - 2000,
        );

    test('Convoy split at toll plaza: ahead/behind calculations and separation flag', () {
      // 5 riders:
      // Lead (Vikram) & Scout (Rohan) cleared toll and are at km 11 and km 10
      // Priya, Sweeper (Suresh), and Deepak are split behind toll plaza at km 5.5
      final convoy = ConvoyModel(
        groupId: 'NH44-SPLIT',
        name: 'NH44 Fast Track',
        joinCode: '556677',
        createdByUserId: 'u_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: now - 3600000,
        distanceThresholdMeters: 1000, // 1 km max separation limit
        destinationLat: 13.250,
        destinationLng: 77.600,
        route: RouteModel(
          distanceM: routeLengthM,
          durationS: 1800,
          polyline: routePolyline,
        ),
        riders: {
          'u_lead': makeRider('u_lead', 'Vikram Lead', lat: 13.100, speedKmh: 85, role: 'LEAD'), // ~11.1 km
          'u_scout': makeRider('u_scout', 'Rohan Scout', lat: 13.090, speedKmh: 80, role: 'PACK'), // ~10.0 km
          'u_priya': makeRider(
            'u_priya',
            'Priya',
            lat: 13.050,
            speedKmh: 0,
            role: 'PACK',
            stoppedSince: now - 90000,
            statusReason: 'Toll queue',
          ), // ~5.5 km
          'u_sweeper': makeRider(
            'u_sweeper',
            'Suresh Sweeper',
            lat: 13.048,
            speedKmh: 0,
            role: 'SWEEPER',
            stoppedSince: now - 90000,
          ), // ~5.3 km
          'u_deepak': makeRider(
            'u_deepak',
            'Deepak',
            lat: 13.042,
            speedKmh: 0,
            role: 'PACK',
            stoppedSince: now - 90000,
          ), // ~4.6 km
        },
      );

      // 1. Perspective of Priya (stuck at toll plaza)
      final ladderFromPriya = RideFacts.ladder(convoy, 'u_priya');
      expect(ladderFromPriya, hasLength(5));

      // Order must be strictly front-to-back: Lead -> Scout -> Priya -> Sweeper -> Deepak
      expect(ladderFromPriya[0].rider.userId, 'u_lead');
      expect(ladderFromPriya[1].rider.userId, 'u_scout');
      expect(ladderFromPriya[2].rider.userId, 'u_priya');
      expect(ladderFromPriya[3].rider.userId, 'u_sweeper');
      expect(ladderFromPriya[4].rider.userId, 'u_deepak');

      // Check ahead/behind boolean from Priya's perspective
      expect(ladderFromPriya[0].ahead, isTrue, reason: 'Lead is ahead of Priya');
      expect(ladderFromPriya[0].fromMeM!, greaterThan(5000));
      expect(ladderFromPriya[1].ahead, isTrue, reason: 'Scout is ahead of Priya');
      expect(ladderFromPriya[1].fromMeM!, greaterThan(4000));
      expect(ladderFromPriya[2].isMe, isTrue);
      expect(ladderFromPriya[2].ahead, isNull);
      expect(ladderFromPriya[3].ahead, isFalse, reason: 'Sweeper is behind Priya');
      expect(ladderFromPriya[3].fromMeM!, lessThan(0));
      expect(ladderFromPriya[4].ahead, isFalse, reason: 'Deepak is behind Priya');
      expect(ladderFromPriya[4].fromMeM!, lessThan(-500));

      // Check gapAhead and tooFarBehind separation limit flag
      // Gap between Priya and Scout is ~4.5 km (> 1000m threshold)
      expect(ladderFromPriya[2].tooFarBehind, isTrue, reason: 'Priya is split from the scout ahead');
      expect(ladderFromPriya[2].gapAheadM!, greaterThan(4000));

      // Lead is in front, so has no rider ahead
      expect(ladderFromPriya[0].gapAheadM, isNull);
      expect(ladderFromPriya[0].tooFarBehind, isFalse);

      // 2. Convoy Spread calculation
      final spread = RideFacts.spreadM(convoy);
      // Lead is at ~11.1 km, Deepak is at ~4.6 km => spread is approx 6.5 km
      expect(spread, greaterThan(6000));
      expect(spread, lessThan(7000));
    });

    test('Toll plaza stopped detection: duration tracked without false incident', () {
      final priya = makeRider(
        'u_priya',
        'Priya',
        lat: 13.050,
        speedKmh: 0,
        stoppedSince: now - 120000, // 2 minutes ago
        statusReason: 'Toll queue',
      );

      // Stopped duration computed accurately
      final duration = RideFacts.stoppedFor(priya, nowMs: now, thresholdSeconds: 300);
      expect(duration, isNotNull);
      expect(duration!.inSeconds, 120);

      // Nearby riders count in stopped cluster (toll plaza waiting together)
      final convoy = ConvoyModel(
        groupId: 'NH44-CLUSTER',
        name: 'Toll Plaza Cluster',
        joinCode: '111222',
        createdByUserId: 'u_priya',
        createdByUserName: 'Priya',
        createdAtEpochMs: now - 3600000,
        riders: {
          'u_priya': priya,
          'u_sweeper': makeRider('u_sweeper', 'Suresh', lat: 13.048, speedKmh: 0), // ~220m away
          'u_deepak': makeRider('u_deepak', 'Deepak', lat: 13.047, speedKmh: 0), // ~330m away
          'u_lead': makeRider('u_lead', 'Vikram Lead', lat: 13.100, speedKmh: 80), // 5.5 km away
        },
      );

      // Priya has 2 nearby riders clustered with her within 500m radius
      final nearby = RideFacts.nearbyCount(convoy, 'u_priya', radiusM: 500);
      expect(nearby, 2, reason: 'Suresh and Deepak are in the same toll cluster');
    });

    test('Sweeper alerts and regrouping: BEHIND_SWEEPER alert priority & regroup resolution', () {
      // 1. Behind sweeper alert priority
      final behindKey = 'BEHIND:u_deepak';
      expect(priorityForKey(behindKey), AlertPriority.groupSafety);

      // 2. Regrouping: Lead waits at layby, trailing pack clears toll and catches up
      final regroupedConvoy = ConvoyModel(
        groupId: 'NH44-REGROUP',
        name: 'NH44 Regrouped',
        joinCode: '556677',
        createdByUserId: 'u_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: now - 3600000,
        distanceThresholdMeters: 1000,
        destinationLat: 13.250,
        destinationLng: 77.600,
        route: RouteModel(
          distanceM: routeLengthM,
          durationS: 1800,
          polyline: routePolyline,
        ),
        riders: {
          // All riders now clustered together at km 11 within 400m
          'u_lead': makeRider('u_lead', 'Vikram Lead', lat: 13.102, speedKmh: 50, role: 'LEAD'),
          'u_scout': makeRider('u_scout', 'Rohan Scout', lat: 13.101, speedKmh: 50, role: 'PACK'),
          'u_priya': makeRider('u_priya', 'Priya', lat: 13.100, speedKmh: 50, role: 'PACK'),
          'u_deepak': makeRider('u_deepak', 'Deepak', lat: 13.099, speedKmh: 50, role: 'PACK'),
          'u_sweeper': makeRider('u_sweeper', 'Suresh Sweeper', lat: 13.098, speedKmh: 50, role: 'SWEEPER'),
        },
      );

      final regroupedLadder = RideFacts.ladder(regroupedConvoy, 'u_deepak');
      expect(regroupedLadder, hasLength(5));

      // After regrouping, no rider is flagged as tooFarBehind
      for (final rung in regroupedLadder) {
        expect(rung.tooFarBehind, isFalse, reason: 'All gaps are within 1000m threshold');
      }

      // Convoy spread contracted back to tight formation (~440m)
      final regroupedSpread = RideFacts.spreadM(regroupedConvoy);
      expect(regroupedSpread, lessThan(500));
      expect(regroupedSpread, greaterThan(300));

      // Deepak passed the sweeper and is now ahead of Suresh
      final deepakRung = regroupedLadder.firstWhere((r) => r.rider.userId == 'u_deepak');
      final sweeperRung = regroupedLadder.firstWhere((r) => r.rider.userId == 'u_sweeper');
      expect(deepakRung.progressM!, greaterThan(sweeperRung.progressM!));
    });
  });
}
