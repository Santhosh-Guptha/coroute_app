import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../../domain/membership/ride_capabilities.dart';

/// One plan of the server catalog as the app shows it: name, riders and what it includes.
/// Play payments policy (docs/features_355/play_payments_policy.md): the app never reads, keeps or
/// shows a plan's money fields; plans are managed in the rider's CoRoute account, not in the app.
@immutable
class MembershipCategory {
  final String id;
  final String name;
  final int capacity;
  final String description;
  final List<String> features;

  /// False for Community (every rider has it) and plans the server no longer offers.
  final bool offered;

  const MembershipCategory({
    required this.id,
    required this.name,
    required this.capacity,
    this.description = '',
    this.features = const [],
    this.offered = true,
  });

  bool get isIndividual => capacity <= 1 || id == 'individual';
  bool get isGroup => capacity > 1;

  /// The free Community plan (solo rides) every rider has.
  bool get isCommunity => id == 'community';

  /// A current group plan: Small Group or Large Group (not Community, not the retired Individual).
  bool get isGroupPlan => offered && !isCommunity && id != 'individual' && isGroup;

  factory MembershipCategory.fromJson(Map<String, dynamic> json) {
    return MembershipCategory(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      capacity: (json['capacity'] as num?)?.toInt() ?? 1,
      description: json['description']?.toString() ?? '',
      features: (json['features'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      offered: json['purchasable'] != false && json['active'] != false && json['id']?.toString() != 'community',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'capacity': capacity,
    'description': description,
    'features': features,
    if (!offered) 'purchasable': false,
  };
}

@immutable
class MembershipCatalog {
  final List<MembershipCategory> categories;

  /// False when the server runs without plans (every rider may host): the app then shows no plan UI.
  final bool plansEnforced;

  const MembershipCatalog({
    this.categories = const [],
    this.plansEnforced = true,
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
      cats = map.entries.where((e) => e.value is Map).map((e) {
        final val = Map<String, dynamic>.from(e.value as Map);
        if (!val.containsKey('id')) val['id'] = e.key;
        return MembershipCategory.fromJson(val);
      }).toList();
    }

    return MembershipCatalog(
      categories: cats,
      plansEnforced: json['paymentsEnabled'] != false,
    );
  }

  /// The group plans (Small Group, Large Group), fewest riders first.
  List<MembershipCategory> get groupCategories =>
      categories.where((c) => c.isGroupPlan).toList()..sort((a, b) => a.capacity.compareTo(b.capacity));

  /// The free Community plan as the server describes it (null from an older server).
  MembershipCategory? get community {
    for (final c in categories) {
      if (c.isCommunity) return c;
    }
    return null;
  }

  /// The catalog entry for [id], or null.
  MembershipCategory? byId(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'categories': categories.map((e) => e.toJson()).toList(),
    'paymentsEnabled': plansEnforced,
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
  final String status; // 'ACTIVE', 'EXPIRED'
  final int validUntil;
  final List<MembershipMember> members;

  const UserMembership({
    required this.membershipId,
    required this.ownerUserId,
    required this.category,
    this.categoryName,
    required this.capacity,
    required this.status,
    required this.validUntil,
    this.members = const [],
  });

  String get name {
    if (categoryName != null && categoryName!.isNotEmpty) return categoryName!;
    if (category == 'individual') return 'Legacy plan (Individual)';
    if (category == 'group_small') return 'Small Group (2–6)';
    if (category == 'group_large') return 'Large Group (7–12)';
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
      status: json['status']?.toString() ?? 'ACTIVE',
      validUntil: (json['validUntil'] as num?)?.toInt() ?? 0,
      members: membersList,
    );
  }

  Map<String, dynamic> toJson() => {
    'membershipId': membershipId,
    'ownerUserId': ownerUserId,
    'category': category,
    if (categoryName != null) 'categoryName': categoryName,
    'capacity': capacity,
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

  /// False when the server runs without plans (`paymentsEnabled: false` on the wire): every rider
  /// may host and the app shows no plan UI.
  final bool plansEnforced;

  /// The rider's plan as the gateway decided it (membership, or a legacy tier until it ends).
  /// Null from an older gateway: [planAccess] then derives it from [ownedMembership].
  final PlanAccess? plan;

  /// 3.56 what the rider may host as the gateway decided it from the admin access mode (no mode,
  /// plan or price on the wire). Null from an older gateway: [planAccess] decides alone.
  final RideCapabilities? capabilities;

  const MyMembershipOverview({
    this.ownedMembership,
    this.participating = const [],
    this.activeTrip,
    this.effectiveEntitlements = const {},
    this.plansEnforced = true,
    this.plan,
    this.capabilities,
  });

  /// What the rider may host now: the single answer every screen uses (Community when nothing else).
  PlanAccess get planAccess => plan ?? PlanAccess.fromMembership(ownedMembership);

  bool get hasActiveMembership => ownedMembership != null && ownedMembership!.isActive;
  bool get hasValidEntitlement => ownedMembership != null && ownedMembership!.isValidEntitlement;
  bool get hasActiveTrip => activeTrip != null;

  Map<String, dynamic> toJson() => {
    if (ownedMembership != null) 'ownedMembership': ownedMembership!.toJson(),
    'participating': participating.map((e) => e.toJson()).toList(),
    if (activeTrip != null) 'activeTrip': activeTrip!.toJson(),
    'effectiveEntitlements': effectiveEntitlements,
    'paymentsEnabled': plansEnforced,
    if (plan != null) 'plan': plan!.toJson(),
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
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
      // 3.56: "free for everyone" (capabilities.gated false) shows no plan UI, like payments off.
      plansEnforced: json['paymentsEnabled'] != false && !(json['capabilities'] is Map && (json['capabilities'] as Map)['gated'] == false),
      plan: json['plan'] is Map ? PlanAccess.fromJson(Map<String, dynamic>.from(json['plan'] as Map)) : null,
      capabilities: json['capabilities'] is Map ? RideCapabilities.fromJson(Map<String, dynamic>.from(json['capabilities'] as Map)) : null,
    );
  }
}

/// What a rider may do, from one source: the plans (Community, free for every rider; Small Group
/// 2–6 and Large Group 7–12) or, only until its end date, a legacy plan from before them
/// (the Individual membership, or a legacy tier).
///
/// Gating map (app side; the gateway enforces the same):
///  * Safety (SOS, crash detection, emergency texts, medical ID, guardians, offline maps,
///    re-routing, trip history): never gated, with or without a plan.
///  * Community: starts SOLO rides. No talk, messages, invite code or regroup in them.
///  * Joining someone else's ride: free. Inside a group ride every rider has the group features
///    (they follow the host's plan); the host's seats are the only limit.
///  * Hosting a group: a group plan ([canHostGroup]); [seats] riders including the host.
@immutable
class PlanAccess {
  /// 'community', 'membership', 'legacy' or 'none' (unknown, older gateway).
  final String source;

  /// 'community', 'group_small' or 'group_large' (a legacy plan maps to one of them; a legacy
  /// Individual membership reads 'individual').
  final String? category;
  final String name;

  /// Riders the rider may host, host included; 0 without a plan.
  final int seats;
  final int validUntil;

  /// 'proRider', 'roadCaptain' or 'tourOperator' for a legacy plan.
  final String? legacyTier;

  const PlanAccess({
    required this.source,
    this.category,
    required this.name,
    required this.seats,
    this.validUntil = 0,
    this.legacyTier,
  });

  static const PlanAccess none = PlanAccess(source: 'none', name: 'No plan', seats: 0);

  /// The free plan every rider has: solo rides, every safety feature, never ends.
  static const PlanAccess community = PlanAccess(source: 'community', category: 'community', name: 'Community', seats: 1);

  bool get isExpired => validUntil > 0 && validUntil <= DateTime.now().millisecondsSinceEpoch;
  bool get hasPlan => source != 'none' && seats >= 1 && !isExpired;
  bool get isLegacy => hasPlan && source == 'legacy';

  /// On the free Community plan (or a paid plan that ended: the rider is then on Community).
  bool get isCommunity => source == 'community' || (source != 'none' && !hasPlan);

  /// A paid plan (Small or Large Group, or a legacy plan) that is still running.
  bool get isPaid => hasPlan && source != 'community';
  bool get canStartTrip => hasPlan;
  bool get canHostGroup => hasPlan && seats >= 2;

  /// The plan in force now: an ended paid plan reads as Community.
  PlanAccess get current => (source != 'none' && source != 'community' && !hasPlan) ? community : this;

  factory PlanAccess.fromJson(Map<String, dynamic> json) => PlanAccess(
        source: json['source']?.toString() ?? 'none',
        category: json['category']?.toString(),
        name: json['name']?.toString() ?? 'No plan',
        seats: (json['seats'] as num?)?.toInt() ?? 0,
        validUntil: (json['validUntil'] as num?)?.toInt() ?? 0,
        legacyTier: json['legacyTier']?.toString(),
      );

  /// From the owned membership alone (an older gateway without `plan`): Community without one.
  factory PlanAccess.fromMembership(UserMembership? m) {
    if (m == null || !m.isActive || m.capacity < 1) return community;
    return PlanAccess(source: 'membership', category: m.category, name: m.name, seats: m.capacity, validUntil: m.validUntil);
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        if (category != null) 'category': category,
        'name': name,
        'seats': seats,
        'validUntil': validUntil,
        if (legacyTier != null) 'legacyTier': legacyTier,
      };

  /// Short plan name: "Community", "Small Group", "Large Group", or a legacy plan's own name.
  String get shortName {
    if (source == 'none') return 'No plan';
    if (!hasPlan || source == 'community') return 'Community';
    if (isLegacy) return name;
    switch (category) {
      case 'community':
        return 'Community';
      case 'individual':
        return 'Individual';
      case 'group_small':
        return 'Small Group';
      case 'group_large':
        return 'Large Group';
    }
    return name;
  }

  /// "12 Dec" (with the year when it is not this year).
  static String untilLabel(int epochMs, {DateTime? now}) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final year = (now ?? DateTime.now()).year;
    return DateFormat(d.year == year ? 'd MMM' : 'd MMM yyyy').format(d);
  }

  /// The plan line (account screen), neutral account status only:
  /// "Small Group · up to 6 riders · until 12 Dec", "Individual · solo trips · until 12 Dec",
  /// "Community · Solo rides free".
  String statusLine({DateTime? now}) {
    if (source == 'none') return 'Community · Solo rides free';
    if (!hasPlan || source == 'community') return 'Community · Solo rides free';
    final what = canHostGroup ? 'up to $seats riders' : 'solo trips';
    final until = validUntil > 0 ? ' · until ${untilLabel(validUntil, now: now)}' : '';
    return '$shortName · $what$until';
  }
}
