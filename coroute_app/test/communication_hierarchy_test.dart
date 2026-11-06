import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/safety/communication_hierarchy.dart';
import 'package:coroute_app/data/models/rider_model.dart';

void main() {



  group('RiderModel Accuracy and Freshness Integration Tests (ISSUE-6D)', () {
    test('RiderModel maintains accuracy and calculates live vs stale correctly', () {
      final now = 500000;
      final freshRider = RiderModel(
        userId: 'rider_alpha',
        name: 'Alpha',
        lat: 12.97,
        lng: 77.59,
        accuracy: 12.4,
        lastSeenEpochMs: now - 10000, // 10s ago
      );

      expect(freshRider.accuracy, equals(12.4));
      expect(freshRider.accuracyM, equals(12.4));
      expect(freshRider.freshnessStatus(now), equals(LocationFreshnessStatus.live));
      expect(freshRider.isLocationLive(now), isTrue);
      expect(freshRider.isLocationStale(now), isFalse);

      final staleRider = freshRider.copyWith(lastSeenEpochMs: now - 90000);
      expect(staleRider.freshnessStatus(now), equals(LocationFreshnessStatus.stale));
      expect(staleRider.isLocationLive(now), isFalse);
      expect(staleRider.isLocationStale(now), isTrue);
    });

    test('RiderModel JSON roundtrip preserves accuracy and serializes freshness', () {
      final rider = RiderModel(
        userId: 'rider_beta',
        name: 'Beta',
        lat: 12.9716,
        lng: 77.5946,
        accuracy: 6.8,
        lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      final json = rider.toJson();
      expect(json['accuracy'], equals(6.8));
      expect(json['freshness'], equals('LIVE'));

      final reconstructed = RiderModel.fromJson(json);
      expect(reconstructed.userId, equals('rider_beta'));
      expect(reconstructed.accuracy, equals(6.8));
      expect(reconstructed.isLive, isTrue);
    });
  });
}
