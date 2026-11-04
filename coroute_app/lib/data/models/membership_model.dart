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
      priceRupees: (json['priceRupees'] as num?)?.toInt() ?? 0,
      capacity: (json['capacity'] as num?)?.toInt() ?? 1,
      description: json['description']?.toString() ?? '',
      features: (json['features'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? const [],
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

  const MembershipCatalog({
    this.categories = const [],
    this.introductoryOffers = const [],
  });

  factory MembershipCatalog.fromJson(Map<String, dynamic> json) {
    final cats = (json['categories'] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => MembershipCategory.fromJson(Map<String, dynamic>.from(e)))
            .toList() ??
        [];
    final offers = (json['introductoryOffers'] as List<dynamic>?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        [];
    return MembershipCatalog(categories: cats, introductoryOffers: offers);
  }

  Map<String, dynamic> toJson() => {
    'categories': categories.map((e) => e.toJson()).toList(),
    'introductoryOffers': introductoryOffers,
  };
}

@immutable
class MembershipMember {
  final String userId;
  final String name;
  final String email;
  final String phone;
  final String status; // 'ACCEPTED', 'PENDING'
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
  bool get isPending => status == 'PENDING';

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
  final int capacity;
  final int priceRupees;
  final String status; // 'ACTIVE', 'EXPIRED'
  final int validUntil;
  final List<MembershipMember> members;

  const UserMembership({
    required this.membershipId,
    required this.ownerUserId,
    required this.category,
    required this.capacity,
    required this.priceRupees,
    required this.status,
    required this.validUntil,
    this.members = const [],
  });

  int get occupiedSeats => members.length;
  int get availableSeats => capacity > occupiedSeats ? capacity - occupiedSeats : 0;
  bool get isExpired => validUntil > 0 && validUntil <= DateTime.now().millisecondsSinceEpoch;
  bool get isActive => status == 'ACTIVE' && !isExpired;
  bool isOwner(String uid) => ownerUserId == uid;

  factory UserMembership.fromJson(Map<String, dynamic> json) {
    final rawMembers = json['members'] as List<dynamic>? ?? [];
    return UserMembership(
      membershipId: json['membershipId']?.toString() ?? '',
      ownerUserId: json['ownerUserId']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      capacity: (json['capacity'] as num?)?.toInt() ?? 1,
      priceRupees: (json['priceRupees'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'ACTIVE',
      validUntil: (json['validUntil'] as num?)?.toInt() ?? 0,
      members: rawMembers
          .whereType<Map>()
          .map((e) => MembershipMember.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'membershipId': membershipId,
    'ownerUserId': ownerUserId,
    'category': category,
    'capacity': capacity,
    'priceRupees': priceRupees,
    'status': status,
    'validUntil': validUntil,
    'members': members.map((e) => e.toJson()).toList(),
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
  bool get hasActiveTrip => activeTrip != null;

  factory MyMembershipOverview.fromJson(Map<String, dynamic> json) {
    return MyMembershipOverview(
      ownedMembership: json['ownedMembership'] is Map
          ? UserMembership.fromJson(Map<String, dynamic>.from(json['ownedMembership'] as Map))
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

