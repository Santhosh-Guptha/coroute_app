import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/data/models/convoy_model.dart';
import 'package:coroute_app/data/models/membership_model.dart';

void main() {
  group('Membership & Monetization Models Test Suite', () {
    test('MembershipCategory parses Individual and Group categories correctly', () {
      final indJson = {
        'id': 'individual',
        'name': 'Individual',
        'priceRupees': 9,
        'capacity': 1,
        'description': 'Solo rider safety',
        'features': ['Solo Ride Tracking', 'Essential Safety'],
      };
      final ind = MembershipCategory.fromJson(indJson);
      expect(ind.id, 'individual');
      expect(ind.toJson().containsKey('priceRupees'), isFalse, reason: 'the app keeps no price (Play payments policy)');
      expect(ind.capacity, 1);
      expect(ind.isIndividual, isTrue);
      expect(ind.isGroup, isFalse);

      final grpJson = {
        'id': 'group_small',
        'name': 'Small Group',
        'priceRupees': 49,
        'capacity': 6,
        'description': 'Convoy tracking for up to 6 riders',
        'features': ['Convoy & Group Tracking', 'PTT & Intercom'],
      };
      final grp = MembershipCategory.fromJson(grpJson);
      expect(grp.id, 'group_small');
      expect(grp.isGroupPlan, isTrue);
      expect(grp.capacity, 6);
      expect(grp.isIndividual, isFalse);
      expect(grp.isGroup, isTrue);
    });

    test('UserMembership calculates seat capacity, availability and expiry correctly', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final memJson = {
        'membershipId': 'mem_123',
        'ownerUserId': 'owner_001',
        'category': 'group_small',
        'capacity': 6,
        'priceRupees': 49,
        'status': 'ACTIVE',
        'validUntil': now + 86400000, // 1 day in future
        'members': [
          {'userId': 'rider_1', 'name': 'Rider 1', 'status': 'ACCEPTED', 'invitedAt': now},
          {'userId': 'rider_2', 'name': 'Rider 2', 'status': 'ACCEPTED', 'invitedAt': now},
          {'userId': 'rider_3', 'name': 'Rider 3', 'status': 'PENDING', 'invitedAt': now},
        ],
      };
      final mem = UserMembership.fromJson(memJson);
      expect(mem.membershipId, 'mem_123');
      expect(mem.isOwner('owner_001'), isTrue);
      expect(mem.isOwner('rider_1'), isFalse);
      expect(mem.capacity, 6);
      expect(mem.occupiedSeats, 3);
      expect(mem.availableSeats, 3);
      expect(mem.isActive, isTrue);
      expect(mem.isExpired, isFalse);

      // Past validity
      final expiredMem = UserMembership.fromJson({
        ...memJson,
        'validUntil': now - 1000,
      });
      expect(expiredMem.isExpired, isTrue);
      expect(expiredMem.isActive, isFalse);
    });

    test('ActiveTripLock parses concurrency lock correctly', () {
      final lockJson = {
        'groupId': 'GRP-ABCD',
        'role': 'OWNER',
        'status': 'STARTED',
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
      final lock = ActiveTripLock.fromJson(lockJson);
      expect(lock.groupId, 'GRP-ABCD');
      expect(lock.isOwner, isTrue);
      expect(lock.isHead, isFalse);
    });

    test('ConvoyModel Two-Role Model: isTripOwner and isTripHead distinguish roles', () {
      final convoy = ConvoyModel(
        groupId: 'GRP-1001',
        name: 'Himalayan Expedition',
        joinCode: '556677',
        createdByUserId: 'owner_user',
        createdByUserName: 'Ride Owner',
        tripOwnerUserId: 'owner_user',
        tripHeadUserId: 'head_rider',
        createdAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      // Owner verification
      expect(convoy.isTripOwner('owner_user'), isTrue);
      expect(convoy.isTripOwner('head_rider'), isFalse);
      expect(convoy.isTripOwner('random_user'), isFalse);

      // Head verification
      expect(convoy.isTripHead('head_rider'), isTrue);

      // Fallback: when tripHeadUserId is null, falls back to owner
      final fallbackConvoy = ConvoyModel(
        groupId: 'GRP-1002',
        name: 'Solo Ride',
        joinCode: '112233',
        createdByUserId: 'owner_user',
        createdByUserName: 'Ride Owner',
        tripOwnerUserId: 'owner_user',
        tripHeadUserId: null,
        createdAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      );
      expect(fallbackConvoy.isTripHead('owner_user'), isTrue);
    });
  });
}
