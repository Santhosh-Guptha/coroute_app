import 'package:flutter/foundation.dart';

@immutable
class MembershipCategory {
  final String id;
  final String name;
  final int priceRupees;
  final int capacity;
  final String description;
  final List<String> features;

  const MembershipCategory({
    required this.id,
    required this.name,
    required this.priceRupees,
    required this.capacity,
    this.description = '',
    this.features = const [],
  });

  bool get isIndividual => capacity <= 1 || id == 'individual';
  bool get isGroup => capacity > 1;

  factory MembershipCategory.fromJson(Map<String, dynamic> json) {
    return MembershipCategory(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      priceRupees: (json['priceRupees'] as num?)?.toInt() ??
          (json['monthlyPriceInr'] as num?)?.toInt() ??
          (json['priceInr'] as num?)?.toInt() ??
          0,
      capacity: (json['capacity'] as num?)?.toInt() ?? 1,
      description: json['description']?.toString() ?? '',
      features: (json['features'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'priceRupees': priceRupees,
    'capacity': capacity,
    'description': description,
    'features': features,
  };
}

@immutable
class MembershipCatalog {
  final List<MembershipCategory> categories;
  final List<Map<String, dynamic>> introductoryOffers;
  final bool paymentsEnabled;
  final String keyId;
  final String mode;

  const MembershipCatalog({
    this.categories = const [],
    this.introductoryOffers = const [],
    this.paymentsEnabled = true,
    this.keyId = '',
    this.mode = 'test',
  });

  factory MembershipCatalog.fromJson(Map<String, dynamic> json) {
    List<MembershipCategory> cats = [];
    if (json['categories'] is List) {
      cats = (json['categories'] as List<dynamic>)
          .whereType<Map>()
          .map((e) => MembershipCategory.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } else if (json['categories'] is Map) {
      final map = Map<String, dynamic>.from(json['categories'] as Map);
      cats = map.entries.map((e) {
        final val = Map<String, dynamic>.from(e.value as Map);
        if (!val.containsKey('id')) val['id'] = e.key;
        return MembershipCategory.fromJson(val);
      }).toList();
    }

    final rawOffers = (json['offers'] ?? json['introductoryOffers']) as List<dynamic>?;
    final offers = rawOffers
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const [];

    return MembershipCatalog(
      categories: cats,
      introductoryOffers: offers,
      paymentsEnabled: json['paymentsEnabled'] != false,
      keyId: json['keyId']?.toString() ?? '',
      mode: json['mode']?.toString() ?? 'test',
    );
  }

  Map<String, dynamic> toJson() => {
    'categories': categories.map((e) => e.toJson()).toList(),
    'introductoryOffers': introductoryOffers,
    'paymentsEnabled': paymentsEnabled,
    'keyId': keyId,
    'mode': mode,
  };
}

@immutable
class MembershipMember {
  final String userId;
  final String name;
  final String email;
  final String phone;
  final String status; // 'ACCEPTED', 'INVITED', 'DECLINED'
  final int invitedAt;
  final int? acceptedAt;

  const MembershipMember({
    required this.userId,
    this.name = '',
    this.email = '',
    this.phone = '',
    required this.status,
    required this.invitedAt,
    this.acceptedAt,
  });

  bool get isAccepted => status == 'ACCEPTED';
  bool get isPending => status == 'INVITED' || status == 'PENDING';

  factory MembershipMember.fromJson(Map<String, dynamic> json) {
    return MembershipMember(
      userId: json['userId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      status: json['status']?.toString() ?? 'PENDING',
      invitedAt: (json['invitedAt'] as num?)?.toInt() ?? 0,
      acceptedAt: (json['acceptedAt'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'name': name,
    'email': email,
    'phone': phone,
    'status': status,
    'invitedAt': invitedAt,
    if (acceptedAt != null) 'acceptedAt': acceptedAt,
  };
}

@immutable
class UserMembership {
  final String membershipId;
  final String ownerUserId;
  final String category;
  final String? categoryName;
  final int capacity;
  final int priceRupees;
  final String status; // 'ACTIVE', 'EXPIRED'
  final int validUntil;
  final List<MembershipMember> members;
  final String? offerApplied;
  final String? orderId;
  final String? paymentId;

  const UserMembership({
    required this.membershipId,
    required this.ownerUserId,
    required this.category,
    this.categoryName,
    required this.capacity,
    required this.priceRupees,
    required this.status,
    required this.validUntil,
    this.members = const [],
    this.offerApplied,
    this.orderId,
    this.paymentId,
  });

  String get name {
    if (categoryName != null && categoryName!.isNotEmpty) return categoryName!;
    if (category == 'individual') return 'Individual Solo';
    if (category == 'group_small') return 'Group (2–6)';
    if (category == 'group_large') return 'Group (7–12)';
    return category.replaceAll('_', ' ').toUpperCase();
  }

  /// Occupied seats includes 1 seat for the owner plus accepted member invitations.
  int get occupiedSeats => 1 + members.where((m) => m.status == 'ACCEPTED').length;
  int get availableSeats => capacity > occupiedSeats ? capacity - occupiedSeats : 0;
  bool get isExpired => validUntil > 0 && validUntil <= DateTime.now().millisecondsSinceEpoch;
  bool get isActive => (status.toUpperCase() == 'ACTIVE' || status.isEmpty) && !isExpired;
  bool get hasCapacity => capacity >= 1;
  bool get isValidEntitlement => !isExpired && hasCapacity;
  bool isOwner(String uid) => ownerUserId == uid;

  factory UserMembership.fromJson(Map<String, dynamic> json) {
    List<MembershipMember> membersList = [];
    final rawMembers = json['members'];
    if (rawMembers is List) {
      membersList = rawMembers
          .whereType<Map>()
          .map((e) => MembershipMember.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } else if (rawMembers is Map) {
      final map = Map<String, dynamic>.from(rawMembers);
      membersList = map.values
          .whereType<Map>()
          .map((e) => MembershipMember.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }

    return UserMembership(
      membershipId: json['membershipId']?.toString() ?? '',
      ownerUserId: json['ownerUserId']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      categoryName: json['categoryName']?.toString(),
      capacity: (json['capacity'] as num?)?.toInt() ?? 1,
      priceRupees: (json['priceRupees'] as num?)?.toInt() ??
          (json['monthlyPriceInr'] as num?)?.toInt() ??
          (json['priceInr'] as num?)?.toInt() ??
          0,
      status: json['status']?.toString() ?? 'ACTIVE',
      validUntil: (json['validUntil'] as num?)?.toInt() ?? 0,
      members: membersList,
      offerApplied: json['offerApplied']?.toString(),
      orderId: json['orderId']?.toString(),
      paymentId: json['paymentId']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'membershipId': membershipId,
    'ownerUserId': ownerUserId,
    'category': category,
    if (categoryName != null) 'categoryName': categoryName,
    'capacity': capacity,
    'priceRupees': priceRupees,
    'status': status,
    'validUntil': validUntil,
    'members': members.map((e) => e.toJson()).toList(),
    if (offerApplied != null) 'offerApplied': offerApplied,
    if (orderId != null) 'orderId': orderId,
    if (paymentId != null) 'paymentId': paymentId,
  };
}

@immutable
class ActiveTripLock {
  final String groupId;
  final String role; // 'OWNER', 'HEAD', 'PARTICIPANT'
  final String status;
  final int updatedAt;

  const ActiveTripLock({
    required this.groupId,
    required this.role,
    required this.status,
    required this.updatedAt,
  });

  bool get isOwner => role == 'OWNER';
  bool get isHead => role == 'HEAD';

  factory ActiveTripLock.fromJson(Map<String, dynamic> json) {
    return ActiveTripLock(
      groupId: json['groupId']?.toString() ?? '',
      role: json['role']?.toString() ?? 'PARTICIPANT',
      status: json['status']?.toString() ?? 'STARTED',
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'groupId': groupId,
    'role': role,
    'status': status,
    'updatedAt': updatedAt,
  };
}

@immutable
class MembershipPaymentItem {
  final String orderId;
  final String paymentId;
  final double amountInr;
  final String currency;
  final String category;
  final String status;
  final String mode;
  final bool isFree;
  final String? offerCode;
  final int paidAt;
  final int createdAt;
  final String? refundStatus;
  final double refundedAmount;

  const MembershipPaymentItem({
    required this.orderId,
    this.paymentId = '',
    required this.amountInr,
    this.currency = 'INR',
    required this.category,
    required this.status,
    this.mode = 'test',
    this.isFree = false,
    this.offerCode,
    this.paidAt = 0,
    this.createdAt = 0,
    this.refundStatus,
    this.refundedAmount = 0,
  });

  bool get isPaid => status == 'PAID';
  bool get isRefunded => refundStatus == 'PROCESSED' || refundedAmount > 0;

  factory MembershipPaymentItem.fromJson(Map<String, dynamic> json) {
    return MembershipPaymentItem(
      orderId: json['orderId']?.toString() ?? '',
      paymentId: json['paymentId']?.toString() ?? '',
      amountInr: (json['amountInr'] as num?)?.toDouble() ??
          ((json['amountInPaise'] as num?)?.toDouble() ?? 0) / 100,
      currency: json['currency']?.toString() ?? 'INR',
      category: json['category']?.toString() ?? '',
      status: json['status']?.toString() ?? 'CREATED',
      mode: json['mode']?.toString() ?? 'test',
      isFree: json['isFree'] == true,
      offerCode: json['offerCode']?.toString(),
      paidAt: (json['paidAt'] as num?)?.toInt() ?? 0,
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      refundStatus: json['refundStatus']?.toString(),
      refundedAmount: (json['refundedAmount'] as num?)?.toDouble() ?? 0,
    );
  }
}

@immutable
class MyMembershipOverview {
  final UserMembership? ownedMembership;
  final List<UserMembership> participating;
  final ActiveTripLock? activeTrip;
  final Map<String, dynamic> effectiveEntitlements;
  final bool paymentsEnabled;

  const MyMembershipOverview({
    this.ownedMembership,
    this.participating = const [],
    this.activeTrip,
    this.effectiveEntitlements = const {},
    this.paymentsEnabled = true,
  });

  bool get hasActiveMembership => ownedMembership != null && ownedMembership!.isActive;
  bool get hasValidEntitlement => ownedMembership != null && ownedMembership!.isValidEntitlement;
  bool get hasActiveTrip => activeTrip != null;

  Map<String, dynamic> toJson() => {
    if (ownedMembership != null) 'ownedMembership': ownedMembership!.toJson(),
    'participating': participating.map((e) => e.toJson()).toList(),
    if (activeTrip != null) 'activeTrip': activeTrip!.toJson(),
    'effectiveEntitlements': effectiveEntitlements,
    'paymentsEnabled': paymentsEnabled,
  };

  factory MyMembershipOverview.fromJson(Map<String, dynamic> json) {
    final ownedRaw = json['ownedMembership'] ?? json['owned'];
    return MyMembershipOverview(
      ownedMembership: ownedRaw is Map
          ? UserMembership.fromJson(Map<String, dynamic>.from(ownedRaw))
          : null,
      participating: (json['participating'] as List<dynamic>?)
              ?.whereType<Map>()
              .map((e) => UserMembership.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      activeTrip: json['activeTrip'] is Map
          ? ActiveTripLock.fromJson(Map<String, dynamic>.from(json['activeTrip'] as Map))
          : null,
      effectiveEntitlements: json['effectiveEntitlements'] is Map
          ? Map<String, dynamic>.from(json['effectiveEntitlements'] as Map)
          : const {},
      paymentsEnabled: json['paymentsEnabled'] != false,
    );
  }
}
