import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

@immutable
class MembershipCategory {
  final String id;
  final String name;
  final int priceRupees;
  final int capacity;
  final String description;
  final List<String> features;

  /// False for Community (free for every rider, never bought); true for the paid plans.
  final bool purchasable;

  const MembershipCategory({
    required this.id,
    required this.name,
    required this.priceRupees,
    required this.capacity,
    this.description = '',
    this.features = const [],
    this.purchasable = true,
  });

  bool get isIndividual => capacity <= 1 || id == 'individual';
  bool get isGroup => capacity > 1;

  /// The free Community plan (solo rides) every rider has.
  bool get isCommunity => id == 'community';

  /// A plan the rider can buy: Small Group or Large Group (not Community, not the retired Individual).
  bool get canBuy => purchasable && !isCommunity && id != 'individual' && priceRupees > 0;

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
      purchasable: json['purchasable'] != false && json['id']?.toString() != 'community',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'priceRupees': priceRupees,
    'capacity': capacity,
    'description': description,
    'features': features,
    if (!purchasable) 'purchasable': false,
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

  /// The plans a rider can buy (Small Group, Large Group), cheapest first.
  List<MembershipCategory> get paidCategories =>
      categories.where((c) => c.canBuy).toList()..sort((a, b) => a.priceRupees.compareTo(b.priceRupees));

  /// The free Community plan as the server describes it (null from an older server).
  MembershipCategory? get community {
    for (final c in categories) {
      if (c.isCommunity) return c;
    }
    return null;
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

  /// The rider's plan as the gateway decided it (membership, or a legacy tier until it ends).
  /// Null from an older gateway: [planAccess] then derives it from [ownedMembership].
  final PlanAccess? plan;

  const MyMembershipOverview({
    this.ownedMembership,
    this.participating = const [],
    this.activeTrip,
    this.effectiveEntitlements = const {},
    this.paymentsEnabled = true,
    this.plan,
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
    'paymentsEnabled': paymentsEnabled,
    if (plan != null) 'plan': plan!.toJson(),
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
      plan: json['plan'] is Map ? PlanAccess.fromJson(Map<String, dynamic>.from(json['plan'] as Map)) : null,
    );
  }
}

/// What a rider may do, from one source: the plans (Community, free for every rider; Small Group
/// 2–6 and Large Group 7–12, paid) or, only until its end date, a legacy plan bought before them
/// (the ₹9 Individual membership, or a legacy tier).
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

  /// The plan line on the home screen, in plain words:
  /// "Small Group · up to 6 riders · until 12 Dec", "Individual · solo trips · until 12 Dec",
  /// "Community · Solo rides free · Host a group from ₹49".
  String statusLine({int? groupFromPrice, DateTime? now}) {
    final from = groupFromPrice != null && groupFromPrice > 0 ? ' from ₹$groupFromPrice' : '';
    if (source == 'none') return 'No plan · Join rides free · Host a group$from';
    if (!hasPlan || source == 'community') return 'Community · Solo rides free · Host a group$from';
    final what = canHostGroup ? 'up to $seats riders' : 'solo trips';
    final until = validUntil > 0 ? ' · until ${untilLabel(validUntil, now: now)}' : '';
    return '$shortName · $what$until';
  }
}

/// One line of a price breakdown ("Large Group (30 days)" ₹99, "Credit for 19 unused days" −₹31).
@immutable
class QuoteLine {
  final String label;
  final int amountInr;
  const QuoteLine(this.label, this.amountInr);

  /// "₹99", "−₹31".
  String get amountText => amountInr < 0 ? '−₹${-amountInr}' : '₹$amountInr';
}

/// The server's price of a plan for this rider now (GET /membership/quote): list price, coupon,
/// credit for the unused days of the current paid plan, what to pay and the new period. The order
/// charges exactly this; the app never computes a price itself.
@immutable
class PlanQuote {
  final String plan;
  final String planName;

  /// 'new' (from Community), 'upgrade', 'renewal' (early) or 'downgrade' (starts at the period end).
  final String kind;
  final int basePriceInr;
  final String? couponCode;
  final int couponDiscountInr;
  final int creditInr;
  final int unusedDays;
  final String? fromPlanName;
  final int extraDays;
  final int payableInr;
  final int startsAt;
  final int endsAt;
  final List<QuoteLine> breakdown;

  /// "Large Group ₹99 − ₹31 credit for 19 unused days = ₹68".
  final String summary;
  final List<String> notes;

  /// Why a typed code was refused (the quote is then the price without it): reason and message.
  final String? couponErrorReason;
  final String? couponErrorMessage;

  const PlanQuote({
    required this.plan,
    required this.planName,
    this.kind = 'new',
    required this.basePriceInr,
    this.couponCode,
    this.couponDiscountInr = 0,
    this.creditInr = 0,
    this.unusedDays = 0,
    this.fromPlanName,
    this.extraDays = 0,
    required this.payableInr,
    this.startsAt = 0,
    this.endsAt = 0,
    this.breakdown = const [],
    this.summary = '',
    this.notes = const [],
    this.couponErrorReason,
    this.couponErrorMessage,
  });

  bool get isFree => payableInr <= 0;
  bool get isDowngrade => kind == 'downgrade';
  bool get hasCoupon => couponCode != null && couponDiscountInr > 0;
  bool get couponRefused => couponErrorReason != null;

  static int _int(Object? v) => v is num ? v.round() : int.tryParse('${v ?? ''}') ?? 0;

  factory PlanQuote.fromJson(Map<String, dynamic> json) {
    final lines = <QuoteLine>[];
    final raw = json['breakdown'];
    if (raw is List) {
      for (final l in raw.whereType<Map>()) {
        lines.add(QuoteLine(l['label']?.toString() ?? '', _int(l['amountInr'])));
      }
    }
    final err = json['couponError'];
    return PlanQuote(
      plan: json['plan']?.toString() ?? '',
      planName: json['planName']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'new',
      basePriceInr: _int(json['basePriceInr']),
      couponCode: json['couponCode']?.toString(),
      couponDiscountInr: _int(json['couponDiscountInr']),
      creditInr: _int(json['creditInr']),
      unusedDays: _int(json['unusedDays']),
      fromPlanName: json['fromPlanName']?.toString(),
      extraDays: _int(json['extraDays']),
      payableInr: _int(json['payableInr']),
      startsAt: _int(json['startsAt']),
      endsAt: _int(json['endsAt']),
      breakdown: lines,
      summary: json['summary']?.toString() ?? '',
      notes: (json['notes'] is List) ? (json['notes'] as List).map((e) => e.toString()).toList() : const [],
      couponErrorReason: err is Map ? err['reason']?.toString() : null,
      couponErrorMessage: err is Map ? err['error']?.toString() : null,
    );
  }

  /// The price before the server answered (or when it cannot be reached): the list price only.
  factory PlanQuote.listPrice(MembershipCategory c) => PlanQuote(
        plan: c.id,
        planName: c.name,
        basePriceInr: c.priceRupees,
        payableInr: c.priceRupees,
        breakdown: [QuoteLine(c.name, c.priceRupees), QuoteLine('To pay now', c.priceRupees)],
        summary: '${c.name} ₹${c.priceRupees}',
      );

  /// The breakdown without its last "To pay now" line (that one is shown as the total).
  List<QuoteLine> get itemLines =>
      breakdown.isNotEmpty && breakdown.last.label == 'To pay now' ? breakdown.sublist(0, breakdown.length - 1) : breakdown;
}
