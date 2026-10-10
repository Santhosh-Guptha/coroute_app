import 'package:flutter_test/flutter_test.dart';

import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/models/route_model.dart';
import 'package:coroute_app/data/models/stop_point_model.dart';
import 'package:coroute_app/data/models/timeline_event_model.dart';
import 'package:coroute_app/domain/notify/alert_policy.dart';
import 'package:coroute_app/domain/notify/alert_priority.dart';
import 'package:coroute_app/domain/ride/ride_facts.dart';
import 'package:coroute_app/domain/route/lost_rider_recovery_coordinator.dart';
import 'package:coroute_app/domain/route/route_plan.dart';
import 'package:coroute_app/domain/route/route_progress.dart';
import 'package:coroute_app/domain/tracking/geo_math.dart';
import 'package:coroute_app/domain/tracking/track_point.dart';

void main() {
  group('Scenario Convoy Dynamics and Regroup Verification', () {
    // 30 km highway segment on NH44 northbound along lng 77.600
    // Lat 13.000 to 13.270 (approx 30.0 km)
    final highwayPoints = <(double, double)>[
      for (double lat = 13.000; lat <= 13.270 + 1e-9; lat += 0.005) (lat, 77.600)
    ];
    final routePolyline = GeoMath.encodePolyline(highwayPoints);
    final routeLengthM = GeoMath.alongRoute(13.270, 77.600, highwayPoints)!.along;

    const int t0 = 1700000000000;

    RiderModel makeRider(
      String id,
      String name, {
      required double lat,
      required double speedKmh,
      String role = 'PACK',
      int stoppedSince = 0,
      String statusReason = '',
      int lastSeenEpochMs = t0 - 2000,
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
          lastSeenEpochMs: lastSeenEpochMs,
        );

    test('REQ-11: Toll plaza convoy split into Lead and Trail clusters, gap calculations, and alarm spam suppression', () {
      // 6 riders on NH44:
      // Lead Pack (cleared toll plaza, cruising northbound at km 16.7 and 16.2):
      // - Vikram (LEAD) at lat 13.150 (~16.7 km)
      // - Rohan (PACK scout) at lat 13.146 (~16.2 km)
      //
      // Trail Pack (held up at toll plaza queue at km 10.0, 9.8, 9.6):
      // - Priya (PACK) at lat 13.090 (~10.0 km)
      // - Deepak (PACK) at lat 13.088 (~9.8 km)
      // - Suresh (SWEEPER) at lat 13.086 (~9.6 km)
      // - Arun (PACK) at lat 13.085 (~9.5 km)
      final splitConvoy = ConvoyModel(
        groupId: 'NH44-TOLL-SPLIT',
        name: 'NH44 Highway Run',
        joinCode: '445566',
        createdByUserId: 'u_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: t0 - 3600000,
        distanceThresholdMeters: 1000, // 1 km max separation limit
        destinationLat: 13.270,
        destinationLng: 77.600,
        route: RouteModel(
          distanceM: routeLengthM,
          durationS: 1800,
          polyline: routePolyline,
        ),
        riders: {
          'u_lead': makeRider('u_lead', 'Vikram Lead', lat: 13.150, speedKmh: 85, role: 'LEAD'),
          'u_scout': makeRider('u_scout', 'Rohan Scout', lat: 13.146, speedKmh: 80, role: 'PACK'),
          'u_priya': makeRider(
            'u_priya',
            'Priya',
            lat: 13.090,
            speedKmh: 0,
            role: 'PACK',
            stoppedSince: t0 - 90000,
            statusReason: 'Toll plaza queue',
          ),
          'u_deepak': makeRider(
            'u_deepak',
            'Deepak',
            lat: 13.088,
            speedKmh: 0,
            role: 'PACK',
            stoppedSince: t0 - 90000,
            statusReason: 'Toll plaza queue',
          ),
          'u_sweeper': makeRider(
            'u_sweeper',
            'Suresh Sweeper',
            lat: 13.086,
            speedKmh: 0,
            role: 'SWEEPER',
            stoppedSince: t0 - 90000,
            statusReason: 'Toll plaza queue',
          ),
          'u_arun': makeRider(
            'u_arun',
            'Arun',
            lat: 13.087,
            speedKmh: 0,
            role: 'PACK',
            stoppedSince: t0 - 90000,
            statusReason: 'Toll plaza queue',
          ),
        },
      );

      // Part 1: Cluster formation and distance gap verification
      final priyaLadder = RideFacts.ladder(splitConvoy, 'u_priya');
      expect(priyaLadder, hasLength(6));

      // Correct front-to-back ordering
      expect(priyaLadder[0].rider.userId, 'u_lead');
      expect(priyaLadder[1].rider.userId, 'u_scout');
      expect(priyaLadder[2].rider.userId, 'u_priya');
      expect(priyaLadder[3].rider.userId, 'u_deepak');
      expect(priyaLadder[4].rider.userId, 'u_arun');
      expect(priyaLadder[5].rider.userId, 'u_sweeper');

      // Lead pack internal gap is tight (approx 440m <= 1000m)
      expect(priyaLadder[1].gapAheadM, isNotNull);
      expect(priyaLadder[1].gapAheadM!, lessThan(500));
      expect(priyaLadder[1].tooFarBehind, isFalse);

      // Trail pack bridge gap to the Lead pack ahead is large (> 6 km)
      expect(priyaLadder[2].isMe, isTrue);
      expect(priyaLadder[2].tooFarBehind, isTrue, reason: 'Priya is split from Rohan ahead by more than 1000m');
      expect(priyaLadder[2].gapAheadM!, greaterThan(6000));
      expect(priyaLadder[2].gapAheadM!, lessThan(6500));

      // Trail pack internal gaps are tight (approx 220m, 110m, 110m <= 1000m)
      expect(priyaLadder[3].tooFarBehind, isFalse, reason: 'Deepak is clustered with Priya');
      expect(priyaLadder[3].gapAheadM!, lessThan(300));
      expect(priyaLadder[4].tooFarBehind, isFalse, reason: 'Arun is clustered with Deepak');
      expect(priyaLadder[4].gapAheadM!, lessThan(200));
      expect(priyaLadder[5].tooFarBehind, isFalse, reason: 'Sweeper is clustered with Arun');
      expect(priyaLadder[5].gapAheadM!, lessThan(200));

      // Total convoy spread calculation across both clusters
      final spread = RideFacts.spreadM(splitConvoy);
      expect(spread, greaterThan(7000));
      expect(spread, lessThan(7500));

      // Lead perspective ahead/behind metrics
      expect(priyaLadder[0].ahead, isTrue);
      expect(priyaLadder[0].fromMeM!, greaterThan(6500));
      expect(priyaLadder[1].ahead, isTrue);
      expect(priyaLadder[1].fromMeM!, greaterThan(6000));
      expect(priyaLadder[3].ahead, isFalse);
      expect(priyaLadder[3].fromMeM!, lessThan(0));

      // Part 2: Proximity clustering suppresses false incident alarms
      // Priya, Deepak, Suresh, Arun are stationary together in the toll cluster
      final nearbyPriya = RideFacts.nearbyCount(splitConvoy, 'u_priya', radiusM: 500);
      expect(nearbyPriya, 3, reason: 'Deepak, Suresh, and Arun are within 500m of Priya');
      final nearbySweeper = RideFacts.nearbyCount(splitConvoy, 'u_sweeper', radiusM: 500);
      expect(nearbySweeper, 3, reason: 'Priya, Deepak, and Arun are within 500m of Sweeper');

      final stoppedDuration = RideFacts.stoppedFor(
        splitConvoy.riders['u_priya']!,
        nowMs: t0,
        thresholdSeconds: 300,
      );
      expect(stoppedDuration, isNotNull);
      expect(stoppedDuration!.inSeconds, 90);

      // Part 3: Alarm spam suppression verification
      // A) Canonical notification key deduplication prevents notification stacking
      final priyaSeparatedKey = 'SEPARATED:u_priya';
      final alertSpecA = AlertSpec(
        priyaSeparatedKey,
        AlertChannel.alerts,
        'Separated from group',
        'You are 6.2 km from your group.',
      );
      final alertSpecB = AlertSpec(
        priyaSeparatedKey,
        AlertChannel.alerts,
        'Separated from group',
        'You are 6.3 km from your group.',
      );
      // Both map to the exact same notification ID so Android updates rather than creating new alerts
      expect(alertSpecA.id, equals(alertSpecB.id));

      // B) Priority arbitration: SOS outranks separation alerts
      expect(priorityForKey('SOS:alert_toll_emergency'), AlertPriority.sos);
      expect(priorityForKey(priyaSeparatedKey), AlertPriority.groupSafety);
      expect(priorityForKey('EV:MEETING'), AlertPriority.routeInfo);

      // High-priority emergency is always arranged first, preventing alarm masking
      final mixedAlertKeys = ['EV:MEETING', priyaSeparatedKey, 'SOS:alert_toll_emergency'];
      final sortedAlertKeys = AlertArbiter.arrange(mixedAlertKeys, (k) => priorityForKey(k));
      expect(sortedAlertKeys, ['SOS:alert_toll_emergency', priyaSeparatedKey, 'EV:MEETING']);
    });

    test('REQ-12: Dynamic rendezvous marker broadcast, convergence tracking, and completion when riders arrive within 150m', () {
      final routeProgress = RouteProgress(highwayPoints);

      // Step 1: Lead sets dynamic rendezvous marker ahead at Highway Layby (lat 13.200, ~22.2 km)
      final rendezvousLat = 13.200;
      final rendezvousLng = 77.600;

      final initialConvoy = ConvoyModel(
        groupId: 'NH44-REGROUP',
        name: 'NH44 Fast Track',
        joinCode: '778899',
        createdByUserId: 'u_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: t0 - 3600000,
        distanceThresholdMeters: 1000,
        destinationLat: 13.270,
        destinationLng: 77.600,
        route: RouteModel(
          distanceM: routeLengthM,
          durationS: 1800,
          polyline: routePolyline,
        ),
        riders: {
          'u_lead': makeRider('u_lead', 'Vikram Lead', lat: 13.150, speedKmh: 85, role: 'LEAD'),
          'u_priya': makeRider('u_priya', 'Priya', lat: 13.090, speedKmh: 0, role: 'PACK'),
          'u_sweeper': makeRider('u_sweeper', 'Suresh Sweeper', lat: 13.086, speedKmh: 0, role: 'SWEEPER'),
        },
      );

      // Placement calculation places meeting point in plan
      final placement = RoutePlan.meetingPlacement(
        initialConvoy,
        lat: rendezvousLat,
        lng: rendezvousLng,
        plan: routeProgress,
      );
      expect(placement.replaces, isNull);

      final rendezvousStop = StopPointModel(
        stopId: 'stop_layby_rendezvous',
        name: 'NH44 Layby Rendezvous',
        lat: rendezvousLat,
        lng: rendezvousLng,
        category: RoutePlan.meetingCategory,
        status: 'PLANNED',
      );

      expect(rendezvousStop.category, RoutePlan.meetingCategory);
      expect(rendezvousStop.isPlanned, isTrue);
      expect(rendezvousStop.isVisited, isFalse);
      expect(RoutePlan.stillAhead(rendezvousStop, 'u_priya'), isTrue);
      expect(RoutePlan.stillAhead(rendezvousStop, 'u_lead'), isTrue);

      // Dynamic replacement check: if a new rendezvous marker is set, it replaces the old open one
      final convoyWithStop = initialConvoy.copyWith(stopPoints: [rendezvousStop]);
      final replacementPlacement = RoutePlan.meetingPlacement(
        convoyWithStop,
        lat: 13.220,
        lng: rendezvousLng,
        plan: routeProgress,
      );
      expect(replacementPlacement.replaces?.stopId, 'stop_layby_rendezvous');

      // Step 2: Dynamic rendezvous marker broadcast
      final meetingEvent = TimelineEventModel(
        eventId: 'ev_rendezvous_broadcast',
        groupId: 'NH44-REGROUP',
        type: 'MEETING_POINT_SET',
        lat: rendezvousLat,
        lng: rendezvousLng,
        placeName: 'NH44 Layby Rendezvous',
        startedAt: t0,
        open: true,
      );

      final viewerPriya = AlertViewer(
        userId: 'u_priya',
        lat: 13.090,
        lng: 77.600,
        route: highwayPoints,
      );
      final broadcastAlert = AlertPolicy.meetingChanged(meetingEvent, viewerPriya);
      expect(broadcastAlert.key, AlertPolicy.meetingKey);
      expect(broadcastAlert.channel, AlertChannel.alerts);
      expect(broadcastAlert.title, 'Meeting point changed');
      expect(broadcastAlert.body, contains('NH44 Layby Rendezvous'));
      expect(broadcastAlert.body, contains('from you'));

      // Step 3: Convergence tracking
      // Stage A (Initial): Lead is 5.5 km away, Priya is 12.2 km away, Sweeper is 12.6 km away
      final leadDistA = RideFacts.distanceToM(
        initialConvoy.riders['u_lead']!,
        rendezvousLat,
        rendezvousLng,
        highwayPoints,
      )!;
      final priyaDistA = RideFacts.distanceToM(
        initialConvoy.riders['u_priya']!,
        rendezvousLat,
        rendezvousLng,
        highwayPoints,
      )!;
      final sweeperDistA = RideFacts.distanceToM(
        initialConvoy.riders['u_sweeper']!,
        rendezvousLat,
        rendezvousLng,
        highwayPoints,
      )!;
      expect(leadDistA, greaterThan(5000));
      expect(priyaDistA, greaterThan(12000));
      expect(sweeperDistA, greaterThan(12500));

      // Stage B (Convergence in progress): Lead waits at rendezvous, Trail pack approaches
      final leadAtRendezvous = makeRider('u_lead', 'Vikram Lead', lat: 13.200, speedKmh: 0, role: 'LEAD');
      final priyaApproaching = makeRider('u_priya', 'Priya', lat: 13.185, speedKmh: 75, role: 'PACK');
      final sweeperApproaching = makeRider('u_sweeper', 'Suresh Sweeper', lat: 13.180, speedKmh: 75, role: 'SWEEPER');

      final leadDistB = RideFacts.distanceToM(leadAtRendezvous, rendezvousLat, rendezvousLng, highwayPoints)!;
      final priyaDistB = RideFacts.distanceToM(priyaApproaching, rendezvousLat, rendezvousLng, highwayPoints)!;
      final sweeperDistB = RideFacts.distanceToM(sweeperApproaching, rendezvousLat, rendezvousLng, highwayPoints)!;

      expect(leadDistB, equals(0.0));
      expect(priyaDistB, lessThan(priyaDistA));
      expect(priyaDistB, lessThan(2000));
      expect(sweeperDistB, lessThan(sweeperDistA));
      expect(sweeperDistB, lessThan(2500));

      // Step 4: Completion when riders arrive within 150m
      // Reach threshold in config is 150m (reachRadiusM = 150)
      const double reachRadiusM = 150.0;
      final priyaArrived = makeRider('u_priya', 'Priya', lat: 13.1995, speedKmh: 5, role: 'PACK');
      final sweeperArrived = makeRider('u_sweeper', 'Suresh Sweeper', lat: 13.1990, speedKmh: 5, role: 'SWEEPER');

      final priyaOffsetM = GeoMath.haversine(priyaArrived.lat, priyaArrived.lng, rendezvousLat, rendezvousLng);
      final sweeperOffsetM = GeoMath.haversine(sweeperArrived.lat, sweeperArrived.lng, rendezvousLat, rendezvousLng);

      expect(priyaOffsetM, lessThanOrEqualTo(reachRadiusM), reason: 'Priya arrived within 150m boundary');
      expect(sweeperOffsetM, lessThanOrEqualTo(reachRadiusM), reason: 'Sweeper arrived within 150m boundary');

      // Record arrivals
      final completedStop = StopPointModel(
        stopId: 'stop_layby_rendezvous',
        name: 'NH44 Layby Rendezvous',
        lat: rendezvousLat,
        lng: rendezvousLng,
        category: RoutePlan.meetingCategory,
        status: 'PLANNED',
        isVisited: true,
        arrivals: {
          'u_lead': const StopArrival(name: 'Vikram Lead', arrivedAt: t0 + 300000),
          'u_priya': const StopArrival(name: 'Priya', arrivedAt: t0 + 600000),
          'u_sweeper': const StopArrival(name: 'Suresh Sweeper', arrivedAt: t0 + 620000),
        },
      );

      // Validation of completion
      expect(completedStop.isVisited, isTrue);
      expect(completedStop.arrivals['u_lead']!.reached, isTrue);
      expect(completedStop.arrivals['u_priya']!.reached, isTrue);
      expect(completedStop.arrivals['u_sweeper']!.reached, isTrue);

      // Stop is no longer still ahead of any rider
      expect(RoutePlan.stillAhead(completedStop, 'u_lead'), isFalse);
      expect(RoutePlan.stillAhead(completedStop, 'u_priya'), isFalse);
      expect(RoutePlan.stillAhead(completedStop, 'u_sweeper'), isFalse);

      // Verify STOP_ALL_REACHED one-shot notification generated
      final allReachedEvent = TimelineEventModel(
        eventId: 'ev_all_rendezvous',
        groupId: 'NH44-REGROUP',
        type: 'STOP_ALL_REACHED',
        startedAt: t0 + 620000,
        lat: rendezvousLat,
        lng: rendezvousLng,
        data: {'name': 'NH44 Layby Rendezvous'},
      );
      final allReachedAlert = AlertPolicy().oneShot(allReachedEvent, viewerPriya);
      expect(allReachedAlert, isNotNull);
      expect(allReachedAlert!.title, 'Everyone reached NH44 Layby Rendezvous');
      expect(allReachedAlert.body, 'The whole group is together.');

      // Final convoy spread contracts back under 150m threshold
      final regroupedConvoy = ConvoyModel(
        groupId: 'NH44-REGROUP',
        name: 'NH44 Fast Track',
        joinCode: '778899',
        createdByUserId: 'u_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: t0 - 3600000,
        distanceThresholdMeters: 1000,
        destinationLat: 13.270,
        destinationLng: 77.600,
        route: RouteModel(
          distanceM: routeLengthM,
          durationS: 1800,
          polyline: routePolyline,
        ),
        riders: {
          'u_lead': leadAtRendezvous,
          'u_priya': priyaArrived,
          'u_sweeper': sweeperArrived,
        },
        stopPoints: [completedStop],
      );

      final regroupedSpread = RideFacts.spreadM(regroupedConvoy);
      expect(regroupedSpread, lessThan(150.0), reason: 'Regrouped convoy spread contracted within 150m');
      final regroupedLadder = RideFacts.ladder(regroupedConvoy, 'u_priya');
      for (final rung in regroupedLadder) {
        expect(rung.tooFarBehind, isFalse, reason: 'No rider is too far behind after regrouping');
      }
    });

    test('REQ-13: Sweeper distress detection when sweeper stops while pack is riding, reverse-escalation alert to Lead', () {
      // 5 riders:
      // Lead, Scout, Priya, Deepak cruising northbound at 75 to 80 km/h between km 22 and km 25
      // Sweeper Suresh had a sudden breakdown and stopped at km 20 (lat 13.180, speed 0 km/h)
      final cruisingConvoy = ConvoyModel(
        groupId: 'NH44-SWEEPER-DISTRESS',
        name: 'NH44 Pack Ride',
        joinCode: '990011',
        createdByUserId: 'u_lead',
        createdByUserName: 'Vikram Lead',
        createdAtEpochMs: t0 - 3600000,
        distanceThresholdMeters: 1000,
        destinationLat: 13.270,
        destinationLng: 77.600,
        route: RouteModel(
          distanceM: routeLengthM,
          durationS: 1800,
          polyline: routePolyline,
        ),
        riders: {
          'u_lead': makeRider('u_lead', 'Vikram Lead', lat: 13.230, speedKmh: 80, role: 'LEAD'),
          'u_scout': makeRider('u_scout', 'Rohan Scout', lat: 13.226, speedKmh: 80, role: 'PACK'),
          'u_priya': makeRider('u_priya', 'Priya', lat: 13.222, speedKmh: 78, role: 'PACK'),
          'u_deepak': makeRider('u_deepak', 'Deepak', lat: 13.218, speedKmh: 76, role: 'PACK'),
          'u_sweeper': makeRider(
            'u_sweeper',
            'Suresh Sweeper',
            lat: 13.180,
            speedKmh: 0,
            role: 'SWEEPER',
            stoppedSince: t0 - 180000, // stopped for 3 minutes
          ),
        },
      );

      // Part 1: Sweeper distress anomaly detection
      // Pack is riding at cruising speed
      final movingPackCount = RideFacts.ridingCount(cruisingConvoy.riders.values, nowMs: t0);
      expect(movingPackCount, equals(4), reason: 'All 4 front pack riders are actively riding');

      // Sweeper is stationary
      final sweeperModel = cruisingConvoy.riders['u_sweeper']!;
      expect(sweeperModel.role, equals('SWEEPER'));
      expect(sweeperModel.speedKmh, equals(0.0));
      final sweeperStoppedDuration = RideFacts.stoppedFor(sweeperModel, nowMs: t0, thresholdSeconds: 120);
      expect(sweeperStoppedDuration, isNotNull);
      expect(sweeperStoppedDuration!.inSeconds, equals(180));

      // Gap between the pack rear (Deepak) and Sweeper is widening
      final gapToSweeper = RideFacts.distanceToM(
        sweeperModel,
        cruisingConvoy.riders['u_deepak']!.lat,
        cruisingConvoy.riders['u_deepak']!.lng,
        highwayPoints,
      )!;
      expect(gapToSweeper, greaterThan(4000), reason: 'Deepak is over 4 km ahead of the stopped sweeper');

      // Part 2: Reverse-escalation alert routed to Lead
      // When the sweeper stops unexpectedly, an incident event is raised with notify targeted to Lead
      final sweeperDistressEvent = TimelineEventModel(
        eventId: 'ev_sweeper_incident',
        groupId: 'NH44-SWEEPER-DISTRESS',
        userId: 'u_sweeper',
        userName: 'Suresh Sweeper',
        type: 'POSSIBLE_INCIDENT',
        lat: 13.180,
        lng: 77.600,
        placeName: 'NH44 Km 20 Layby',
        startedAt: t0 - 180000,
        open: true,
        data: {
          'fromKmh': 75.0,
          'notify': ['u_lead'], // Reverse-escalation targeting Lead
        },
      );

      final leadViewer = AlertViewer(
        userId: 'u_lead',
        isLead: true,
        isSweeper: false,
        lat: 13.230,
        lng: 77.600,
        route: highwayPoints,
      );

      final packViewer = AlertViewer(
        userId: 'u_priya',
        isLead: false,
        isSweeper: false,
        lat: 13.222,
        lng: 77.600,
        route: highwayPoints,
      );

      final sweeperViewer = AlertViewer(
        userId: 'u_sweeper',
        isLead: false,
        isSweeper: true,
        lat: 13.180,
        lng: 77.600,
        route: highwayPoints,
      );

      // Lead receives the reverse-escalation alert
      final leadStanding = AlertPolicy().standing([sweeperDistressEvent], leadViewer, nowMs: t0);
      expect(leadStanding, hasLength(1));
      expect(leadStanding.first.key, 'INCIDENT:u_sweeper');
      expect(leadStanding.first.channel, AlertChannel.alerts);
      expect(leadStanding.first.title, 'Possible incident: check on Suresh Sweeper');
      expect(leadStanding.first.body, contains('Stopped suddenly from 75 km/h'));
      expect(leadStanding.first.body, contains('NH44 Km 20 Layby'));

      // Pack member does NOT receive the incident alert (avoids highway panic)
      final packStanding = AlertPolicy().standing([sweeperDistressEvent], packViewer, nowMs: t0);
      expect(packStanding, isEmpty);

      // Sweeper gets self-prompt confirmation
      final sweeperStanding = AlertPolicy().standing([sweeperDistressEvent], sweeperViewer, nowMs: t0);
      expect(sweeperStanding, hasLength(1));
      expect(sweeperStanding.first.aboutMe, isTrue);
      expect(sweeperStanding.first.title, 'Your group was asked to check on you');

      // Part 3: Relative distance and reverse direction vector from Lead to Sweeper
      final directionToSweeper = AlertPolicy.directionFromMe(leadViewer, sweeperModel.lat, sweeperModel.lng);
      expect(directionToSweeper, isNotEmpty);
      expect(directionToSweeper, contains('south'));

      // Part 4: Alert priority ordering
      expect(priorityForKey('INCIDENT:u_sweeper'), AlertPriority.groupSafety);
      final alertOrder = AlertArbiter.arrange(
        ['OFF_ROUTE:u_scout', 'INCIDENT:u_sweeper', 'MEET:encounter_1'],
        (k) => priorityForKey(k),
      );
      expect(alertOrder.first, equals('INCIDENT:u_sweeper'), reason: 'Sweeper distress outranks route and social alerts');

      // Part 5: Sweeper prolonged stop alert if unacknowledged
      final sweeperStoppedEvent = TimelineEventModel(
        eventId: 'ev_sweeper_stopped',
        groupId: 'NH44-SWEEPER-DISTRESS',
        userId: 'u_sweeper',
        userName: 'Suresh Sweeper',
        type: 'STOPPED',
        lat: 13.180,
        lng: 77.600,
        startedAt: t0 - 180000,
        open: true,
        data: {'reason': ''},
      );
      final policyWithShortStationary = AlertPolicy(stationaryAlert: const Duration(minutes: 2));
      final leadStoppedAlerts = policyWithShortStationary.standing([sweeperStoppedEvent], leadViewer, nowMs: t0);
      expect(leadStoppedAlerts, hasLength(1));
      expect(leadStoppedAlerts.first.key, 'STOPPED:u_sweeper');
      expect(leadStoppedAlerts.first.title, contains('Suresh Sweeper has been stopped'));

      // Part 6: Distress cleared when Sweeper resumes riding or resolves status
      final resolvedDistressEvent = TimelineEventModel(
        eventId: 'ev_sweeper_incident',
        groupId: 'NH44-SWEEPER-DISTRESS',
        userId: 'u_sweeper',
        userName: 'Suresh Sweeper',
        type: 'POSSIBLE_INCIDENT',
        startedAt: t0 - 180000,
        open: false, // Closed/resolved
      );
      final leadClearedAlerts = AlertPolicy().standing([resolvedDistressEvent], leadViewer, nowMs: t0);
      expect(leadClearedAlerts, isEmpty, reason: 'Alert automatically clears once incident is resolved');
    });

    test('REQ-14: Lost rider offline homing vectors, closest route point intercept, and sweeper/backtrack recovery', () {
      // Rider gets separated in hilly terrain off NH44 at lat 13.160, lng 77.625
      const lostLat = 13.160;
      const lostLng = 77.625;

      // Mode 1: Intercept calculation to the nearest point on the route polyline
      final routeRecovery = LostRiderRecoveryCoordinator.computeRecovery(
        riderLat: lostLat,
        riderLng: lostLng,
        compassHeading: 270.0,
        speedKmh: 35.0,
        plannedRoute: highwayPoints,
      );

      expect(routeRecovery, isNotNull);
      expect(routeRecovery!.targetType, RecoveryTargetType.routeLine);
      expect(routeRecovery.usingGpsCourse, isFalse);
      expect(routeRecovery.distanceMeters, greaterThan(2500));
      expect(routeRecovery.distanceMeters, lessThan(3000));
      // Closest point on the north-south route (lng 77.600) from east (lng 77.625) is West
      expect(routeRecovery.cardinalDirection, 'W');
      expect(routeRecovery.instruction, contains('Rejoin Route: Head West'));

      // Mode 2: Homing to Sweeper position when route polyline is absent
      final sweeperRecovery = LostRiderRecoveryCoordinator.computeRecovery(
        riderLat: lostLat,
        riderLng: lostLng,
        speedKmh: 45.0,
        gpsHeading: 220.0,
        sweeperLat: 13.120,
        sweeperLng: 77.600,
      );

      expect(sweeperRecovery, isNotNull);
      expect(sweeperRecovery!.targetType, RecoveryTargetType.sweeper);
      expect(sweeperRecovery.usingGpsCourse, isTrue); // moving > 4 km/h with no compass heading
      expect(sweeperRecovery.distanceMeters, greaterThan(4500));
      expect(sweeperRecovery.instruction, contains('Homing to Sweeper'));
      expect(sweeperRecovery.cardinalDirection, anyOf('SW', 'S'));

      // Mode 3: Backtrack along breadcrumbs when off route with recorded trail
      final breadcrumbs = <TrackPoint>[
        const TrackPoint(lat: 13.155, lng: 77.610, speedKmh: 40, ts: t0 - 120000),
        const TrackPoint(lat: 13.156, lng: 77.613, speedKmh: 40, ts: t0 - 90000),
        const TrackPoint(lat: 13.158, lng: 77.617, speedKmh: 38, ts: t0 - 60000),
        const TrackPoint(lat: 13.159, lng: 77.620, speedKmh: 35, ts: t0 - 30000),
        const TrackPoint(lat: 13.160, lng: 77.625, speedKmh: 30, ts: t0),
      ];

      final backtrackRecovery = LostRiderRecoveryCoordinator.computeRecovery(
        riderLat: lostLat,
        riderLng: lostLng,
        compassHeading: 180.0,
        speedKmh: 0.0,
        breadcrumbs: breadcrumbs,
      );

      expect(backtrackRecovery, isNotNull);
      expect(backtrackRecovery!.targetType, RecoveryTargetType.backtrackFork);
      expect(backtrackRecovery.targetLat, equals(13.155));
      expect(backtrackRecovery.targetLng, equals(77.610));
      expect(backtrackRecovery.instruction, contains('Backtrack along trail'));

      // Mode 4: Invalid coordinates return null safely
      expect(
        LostRiderRecoveryCoordinator.computeRecovery(
          riderLat: double.nan,
          riderLng: 77.600,
        ),
        isNull,
      );
    });
  });
}
