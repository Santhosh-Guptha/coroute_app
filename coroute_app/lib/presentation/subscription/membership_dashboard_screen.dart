import 'membership_payment_screen.dart';
import 'package:flutter/material.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/membership_service.dart';
import 'payment_history_screen.dart';

/// Comprehensive dashboard for CoRoute Membership, Group Seat Capacity,
/// Member Invitations, Single Active Trip Concurrency status, and
/// Mandatory Payment Checkout Flows.
class MembershipDashboardScreen extends StatefulWidget {
  const MembershipDashboardScreen({super.key});

  @override
  State<MembershipDashboardScreen> createState() => _MembershipDashboardScreenState();
}

class _MembershipDashboardScreenState extends State<MembershipDashboardScreen> {
  static final DateFormat _dateFmt = DateFormat('d MMM yyyy');
  final TextEditingController _inviteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final ms = context.read<MembershipService>();
        ms.fetchMyMembership().ignore();
        ms.fetchCatalog().ignore();
      }
    });
  }

  @override
  void dispose() {
    _inviteCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.redAccent.shade700 : AppTheme.brand,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _handleInvite(BuildContext dialogCtx) async {
    final identifier = _inviteCtrl.text.trim();
    if (identifier.isEmpty) {
      _showSnack('Please enter a phone number, username or email.', isError: true);
      return;
    }
    final ms = context.read<MembershipService>();
    final success = await ms.inviteMember(identifier);
    if (!mounted) return;
    if (success) {
      _inviteCtrl.clear();
      if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
      _showSnack('Invitation sent to $identifier.');
    } else {
      _showSnack(ms.lastError ?? 'Failed to invite rider.', isError: true);
    }
  }

  void _openInviteDialog() {
    _inviteCtrl.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Invite Group Rider', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the rider\'s email, username, or phone number. They will be added to your group membership and can join your convoys at zero extra cost.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _inviteCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Email or username or phone',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.black26,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand),
            onPressed: () => _handleInvite(ctx),
            child: const Text('Send Invite', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleRemoveMember(String userId, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: const Text('Remove Rider?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Remove $name from your group membership? This frees up a seat and removes them from any active convoys.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final ms = context.read<MembershipService>();
    final success = await ms.removeMember(userId);
    if (!mounted) return;
    if (success) {
      _showSnack('$name removed from group membership.');
    } else {
      _showSnack(ms.lastError ?? 'Failed to remove rider.', isError: true);
    }
  }

  /// Opens the Mandatory Payment Checkout Sheet for a specific membership category.
  void _openPaymentCheckoutSheet(MembershipCategory cat) async {
    HapticFeedback.mediumImpact();
    final ok = await MembershipPaymentScreen.push(context, category: cat);
    if (ok == true && mounted) {
      final ms = context.read<MembershipService>(); await ms.fetchMyMembership();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ms = context.watch<MembershipService>();
    final auth = context.watch<AuthService>();
    final overview = ms.myOverview;
    final owned = overview?.ownedMembership;
    final activeTrip = overview?.activeTrip;
    final catalog = ms.catalog;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.card,
        elevation: 0,
        title: const Text('CoRoute Membership & Plans', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.receipt_long_rounded),
            tooltip: 'Payment & Invoice History',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PaymentHistoryScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () {
              HapticFeedback.lightImpact();
              ms.fetchMyMembership();
              ms.fetchCatalog();
            },
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await ms.fetchMyMembership();
          await ms.fetchCatalog();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (activeTrip != null) ...[
              _buildActiveTripLockBanner(activeTrip),
              const SizedBox(height: 16),
            ],
            _buildSafetyGuaranteeBanner(),
            const SizedBox(height: 16),
            if (owned != null) ...[
              _buildOwnedMembershipCard(owned, auth.currentUserId ?? '', catalog),
              const SizedBox(height: 16),
              if (owned.capacity > 1) ...[
                _buildSeatCapacityCard(owned),
                const SizedBox(height: 16),
                _buildMemberListCard(owned),
                const SizedBox(height: 24),
              ],
            ] else if (overview != null && overview.participating.isNotEmpty) ...[
              _buildParticipatingCard(overview.participating.first),
              const SizedBox(height: 16),
            ],
            _buildCatalogSection(catalog, owned),
          ],
        ),
      ),
    );
  }

  Widget _buildSafetyGuaranteeBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.brand.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_rounded, color: AppTheme.brand, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Safety-First Membership Guarantee',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                SizedBox(height: 4),
                Text(
                  'Membership is owned permanently by you. Active rides never terminate if a subscription expires mid-trip. Crash detection and emergency SOS remain active at all times.',
                  style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveTripLockBanner(ActiveTripLock lock) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.amber.shade900.withValues(alpha: 0.25),
        border: Border.all(color: Colors.amber.shade600, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lock_clock_rounded, color: Colors.amberAccent, size: 22),
              SizedBox(width: 8),
              Text(
                'Single Active Trip Lock Engaged',
                style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'You are currently in active ride [${lock.groupId}] as ${lock.role}. CoRoute enforces a strict single-active-trip policy to prevent split telemetry and ensure convoy safety. To start or join another ride, leave or end this ride first.',
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _buildOwnedMembershipCard(UserMembership mem, String currentUid, MembershipCatalog? catalog) {
    final validDate = mem.validUntil > 0 ? _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(mem.validUntil)) : 'Permanent';
    final isExpired = mem.isExpired;

    MembershipCategory? currentCat;
    if (catalog != null) {
      for (final c in catalog.categories) {
        if (c.id == mem.category) {
          currentCat = c;
          break;
        }
      }
    }
    currentCat ??= MembershipCategory(
      id: mem.category,
      name: mem.name,
      priceRupees: mem.priceRupees,
      capacity: mem.capacity,
    );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            isExpired ? Colors.red.shade900.withValues(alpha: 0.4) : AppTheme.brand.withValues(alpha: 0.25),
            AppTheme.card,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isExpired ? Colors.redAccent : AppTheme.brand.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isExpired ? Colors.redAccent : AppTheme.brand,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isExpired ? 'EXPIRED' : 'ACTIVE MEMBERSHIP',
                  style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11),
                ),
              ),
              Text(
                '₹${mem.priceRupees} / month',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            mem.category == 'individual'
                ? 'Individual Solo Membership'
                : 'Group Membership (${mem.capacity} Riders Capacity)',
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Row(
            children: [
              Icon(Icons.verified_user_rounded, color: Colors.lightGreenAccent, size: 16),
              SizedBox(width: 6),
              Text(
                'Owner: You (Permanent & Non-transferable)',
                style: TextStyle(color: Colors.lightGreenAccent, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            isExpired ? 'Expired on $validDate · Mid-trip continuity protected' : 'Renews on: $validDate',
            style: TextStyle(color: isExpired ? Colors.redAccent : Colors.white60, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.autorenew_rounded, size: 18, color: Colors.black),
                  label: Text(
                    isExpired ? 'Reactivate Plan' : 'Renew Plan (+30 Days)',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => _openPaymentCheckoutSheet(currentCat!),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeatCapacityCard(UserMembership mem) {
    final used = mem.occupiedSeats;
    final total = mem.capacity;
    final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final isFull = used >= total;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Group Seat Capacity', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
              Text('$used / $total Seats', style: TextStyle(color: isFull ? Colors.redAccent : AppTheme.brand, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 10,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(isFull ? Colors.redAccent : AppTheme.brand),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isFull
                ? 'Your membership group is full. Remove inactive riders or upgrade capacity to invite more.'
                : 'You have ${mem.availableSeats} available seat(s). Invited members ride in your convoys without purchasing separate memberships.',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildMemberListCard(UserMembership mem) {
    final members = mem.members;
    final isFull = mem.occupiedSeats >= mem.capacity;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Group Participants', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
              ElevatedButton.icon(
                icon: const Icon(Icons.person_add_rounded, size: 16, color: Colors.black),
                label: const Text('Invite', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isFull ? Colors.white24 : AppTheme.brand,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                onPressed: isFull
                    ? () => _showSnack('Seat capacity reached (${mem.capacity} seats). Upgrade or remove a member to invite.', isError: true)
                    : _openInviteDialog,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (members.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('No members invited yet. Tap "Invite" to add riders.', style: TextStyle(color: Colors.white38, fontSize: 13)),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: members.length,
              separatorBuilder: (_, index) => const Divider(color: Colors.white10, height: 16),
              itemBuilder: (ctx, i) {
                final m = members[i];
                return Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white12,
                      child: Text(
                        (m.name.isNotEmpty ? m.name[0] : (m.email.isNotEmpty ? m.email[0] : 'R')).toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.name.isNotEmpty ? m.name : (m.email.isNotEmpty ? m.email : m.phone), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                          Text(
                            m.isAccepted ? 'Accepted • Full Convoy Access' : 'Invited (Pending Confirmation)',
                            style: TextStyle(color: m.isAccepted ? Colors.lightGreenAccent : Colors.amberAccent, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.person_remove_rounded, color: Colors.redAccent, size: 20),
                      tooltip: 'Remove from group',
                      onPressed: () => _handleRemoveMember(m.userId, m.name.isNotEmpty ? m.name : m.email),
                    ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildParticipatingCard(UserMembership mem) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.lightGreenAccent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Colors.lightGreenAccent, borderRadius: BorderRadius.circular(20)),
                child: const Text('GROUP PARTICIPANT', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
              ),
              const Spacer(),
              const Text('Zero Extra Cost', style: TextStyle(color: Colors.lightGreenAccent, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Invited Member Access', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 6),
          const Text(
            'You are part of an active group membership. You can join all convoys, track fellow riders, and access group features without paying a separate membership fee.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogSection(MembershipCatalog? catalog, UserMembership? owned) {
    final categories = (catalog != null && catalog.categories.isNotEmpty)
        ? catalog.categories
        : const [
            MembershipCategory(
              id: 'individual',
              name: 'Individual Solo Rider',
              priceRupees: 9,
              capacity: 1,
              description: 'Essential personal safety, crash detection and solo tracking.',
              features: ['Solo Ride Tracking', 'Essential Safety & Crash SOS', 'Turn-by-Turn GPS Navigation'],
            ),
            MembershipCategory(
              id: 'group_small',
              name: 'Group Membership (2–6)',
              priceRupees: 49,
              capacity: 6,
              description: 'Convoy tracking and PTT intercom for your riding crew.',
              features: ['Convoy & Group Tracking', 'PTT Voice Intercom', 'Captain & Sweeper Roles', 'Participants Ride for ₹0'],
            ),
            MembershipCategory(
              id: 'group_large',
              name: 'Extended Group (7–12)',
              priceRupees: 99,
              capacity: 12,
              description: 'Large motorcycle fleet coordination with channel isolation.',
              features: ['Large Fleet Matrix', 'Sweeper Priority Voice', 'Live Convoy Dispatch', '12 Covered Seats'],
            ),
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              owned != null ? 'Upgrade or Switch Plan' : 'Select Membership Plan',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
            ),
            const Text(
              'Mandatory Payments',
              style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Choose the right capacity for your riding style. All plans include 30 days of coverage with mid-trip continuity protection.',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
        const SizedBox(height: 14),
        for (final cat in categories) ...[
          _buildCategoryCard(cat, owned),
        ],
      ],
    );
  }

  Widget _buildCategoryCard(MembershipCategory cat, UserMembership? owned) {
    final isCurrent = owned != null && owned.category == cat.id;
    final isPopular = cat.id == 'group_small';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCurrent
              ? Colors.lightGreenAccent
              : (isPopular ? AppTheme.brand.withValues(alpha: 0.8) : Colors.white12),
          width: isPopular || isCurrent ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(cat.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  if (isPopular) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppTheme.brand,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text('POPULAR', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 10)),
                    ),
                  ],
                ],
              ),
              Text(
                '₹${cat.priceRupees} / mo',
                style: TextStyle(color: AppTheme.brand, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(cat.isIndividual ? Icons.person_rounded : Icons.groups_rounded, color: Colors.white60, size: 16),
              const SizedBox(width: 6),
              Text(
                cat.isIndividual ? 'Solo Rider (1 Seat)' : 'Group Convoy (${cat.capacity} Total Seats)',
                style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (cat.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(cat.description, style: const TextStyle(color: Colors.white60, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          if (cat.features.isNotEmpty) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final feat in cat.features) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle_outline_rounded, color: Colors.lightGreenAccent, size: 14),
                        const SizedBox(width: 6),
                        Text(feat, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
          ],
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isCurrent ? Colors.white12 : AppTheme.brand,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _openPaymentCheckoutSheet(cat),
              child: Text(
                isCurrent
                    ? 'Currently Active (Tap to Renew)'
                    : (owned != null ? 'Switch to ${cat.name}' : 'Select & Pay ₹${cat.priceRupees}'),
                style: TextStyle(
                  color: isCurrent ? Colors.white70 : Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mandatory Payment Checkout Bottom Sheet
class _PaymentCheckoutSheet extends StatefulWidget {
  final MembershipCategory category;
  final void Function(UserMembership mem, String paymentId) onSuccess;

  const _PaymentCheckoutSheet({
    required this.category,
    required this.onSuccess,
  });

  @override
  State<_PaymentCheckoutSheet> createState() => _PaymentCheckoutSheetState();
}

class _PaymentCheckoutSheetState extends State<_PaymentCheckoutSheet> {
  late Razorpay _razorpay;
  String? _lastCreatedOrderId;
  final TextEditingController _offerCtrl = TextEditingController(text: 'RIDERFREE');
  final TextEditingController _upiVpaCtrl = TextEditingController();

  String _paymentMethod = 'upi_instant'; // 'upi_instant', 'upi_custom', 'card_netbanking'
  bool _isProcessing = false;
  int _discountPercent = 100; // Default introductory offer applies 100% off
  String? _promoMessage = 'Introductory promo applied: 100% OFF (₹0)';
  String? _checkoutError;

  @override
  void initState() {
    super.initState();
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  @override
  void dispose() {
    _razorpay.clear();
    _offerCtrl.dispose();
    _upiVpaCtrl.dispose();
    super.dispose();
  }

  void _openRazorpayCheckout({
    required String orderId,
    required String keyId,
    required int amountInPaise,
  }) {
    final auth = context.read<AuthService?>();
    final options = <String, dynamic>{
      'key': keyId,
      'amount': amountInPaise,
      'name': 'CoRoute Membership',
      'description': '${widget.category.name} (${widget.category.capacity} riders)',
      'order_id': orderId,
      'prefill': {
        'contact': auth?.phone ?? '',
        'email': auth?.currentUserEmail ?? '',
        'name': auth?.currentUserName ?? '',
      },
      'theme': {
        'color': '#FF5722',
      },
    };

    try {
      _razorpay.open(options);
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _checkoutError = 'Could not launch payment gateway: $e';
      });
    }
  }

  void _handlePaymentSuccess(PaymentSuccessResponse response) async {
    final ms = context.read<MembershipService>();
    final orderId = response.orderId ?? _lastCreatedOrderId;
    final paymentId = response.paymentId ?? '';
    final signature = response.signature ?? '';

    if (orderId == null || orderId.isEmpty) {
      setState(() {
        _isProcessing = false;
        _checkoutError = 'Missing order reference from payment gateway.';
      });
      return;
    }

    final mem = await ms.verifyPayment(
      orderId: orderId,
      paymentId: paymentId,
      signature: signature,
    );

    if (!mounted) return;
    if (mem != null) {
      widget.onSuccess(mem, paymentId);
    } else {
      setState(() {
        _isProcessing = false;
        _checkoutError = ms.lastError ?? 'Payment signature verification failed.';
      });
    }
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
      _checkoutError = response.message ?? 'Payment cancelled or failed (Code: ${response.code}).';
    });
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    // External wallet handler
  }

  Future<void> _applyPromoCode() async {
    final code = _offerCtrl.text.trim().toUpperCase();
    if (code.isEmpty) {
      setState(() {
        _discountPercent = 0;
        _promoMessage = null;
        _checkoutError = null;
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _checkoutError = null;
    });

    final ms = context.read<MembershipService>();
    final val = await ms.validateCoupon(code: code, categoryId: widget.category.id);
    if (!mounted) return;

    setState(() {
      _isProcessing = false;
      if (val != null && val['valid'] == true) {
        _discountPercent = (val['discountPercent'] as num?)?.toInt() ??
            (val['discountInr'] != null && widget.category.priceRupees > 0
                ? ((val['discountInr'] as num) / widget.category.priceRupees * 100).round()
                : 100);
        _promoMessage = val['message'] as String? ?? 'Coupon applied: $_discountPercent% OFF';
        _checkoutError = null;
      } else {
        _discountPercent = 0;
        _promoMessage = null;
        _checkoutError = val?['message'] as String? ?? ms.lastError ?? 'Invalid or inapplicable coupon.';
      }
    });
  }

  Future<void> _submitPayment() async {
    final ms = context.read<MembershipService>();
    final basePrice = widget.category.priceRupees;
    final discountAmount = (basePrice * (_discountPercent / 100)).round();
    final netPayable = (basePrice - discountAmount).clamp(0, 999999);

    setState(() {
      _isProcessing = true;
      _checkoutError = null;
    });

    try {
      // 1. Zero-amount activation (₹0): Direct activation without Razorpay orders or SDK
      if (netPayable == 0) {
        final couponCode = _discountPercent > 0 ? _offerCtrl.text.trim().toUpperCase() : 'RIDERFREE';
        final mem = await ms.activateFreeMembership(
          categoryId: widget.category.id,
          couponCode: couponCode,
        );
        if (!mounted) return;
        if (mem != null) {
          widget.onSuccess(mem, 'FREE-${DateTime.now().millisecondsSinceEpoch}');
        } else {
          setState(() {
            _isProcessing = false;
            _checkoutError = ms.lastError ?? 'Free membership activation failed.';
          });
        }
        return;
      }

      // 2. Monetary payment: Official Razorpay order creation and checkout
      final orderRes = await ms.createOrder(
        categoryId: widget.category.id,
        offerCode: _discountPercent > 0 ? _offerCtrl.text.trim().toUpperCase() : null,
      );

      if (orderRes == null) {
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
          _checkoutError = ms.lastError ?? 'Failed to create payment order.';
        });
        return;
      }

      final orderId = orderRes['orderId']?.toString() ?? '';
      final keyId = orderRes['keyId']?.toString() ?? '';
      final amountInPaise = orderRes['amountInPaise'] as int? ?? (netPayable * 100);

      _lastCreatedOrderId = orderId;

      if (keyId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _isProcessing = false;
          _checkoutError = 'Payment gateway key configuration missing. Please contact support.';
        });
        return;
      }

      _openRazorpayCheckout(orderId: orderId, keyId: keyId, amountInPaise: amountInPaise);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _checkoutError = 'Payment checkout error: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cat = widget.category;
    final basePrice = cat.priceRupees;
    final discountAmount = (basePrice * (_discountPercent / 100)).round();
    final netPayable = (basePrice - discountAmount).clamp(0, 999999);

    return Container(
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text('Membership Checkout', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    SizedBox(height: 2),
                    Text('Mandatory Payment & Instant Activation', style: TextStyle(color: Colors.white60, fontSize: 12)),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white60),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Plan Summary Card
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(cat.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('₹${cat.priceRupees} / mo', style: TextStyle(color: AppTheme.brand, fontWeight: FontWeight.bold, fontSize: 15)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cat.isIndividual
                        ? '1 Solo Rider Seat · Essential Safety & GPS'
                        : '${cat.capacity} Total Seats · Convoy Tracking & PTT Intercom',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 6),
                  Row(
                    children: const [
                      Icon(Icons.shield_outlined, color: Colors.lightGreenAccent, size: 14),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Non-transferable ownership. Active trips never disconnect on expiry.',
                          style: TextStyle(color: Colors.lightGreenAccent, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Promo Code Input
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _offerCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    decoration: InputDecoration(
                      labelText: 'Introductory Offer / Promo Code',
                      labelStyle: const TextStyle(color: Colors.white60, fontSize: 13),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white12,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _isProcessing ? null : _applyPromoCode,
                  child: const Text('Apply', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                if (_discountPercent > 0) ...[
                  const SizedBox(width: 6),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: _isProcessing
                        ? null
                        : () {
                            setState(() {
                              _offerCtrl.clear();
                              _discountPercent = 0;
                              _promoMessage = null;
                              _checkoutError = null;
                            });
                          },
                    child: const Text('Remove', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ),
                ],
              ],
            ),
            if (_promoMessage != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.lightGreenAccent, size: 14),
                  const SizedBox(width: 6),
                  Text(_promoMessage!, style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 12, fontWeight: FontWeight.w600)),
                ],
              ),
            ],
            const SizedBox(height: 16),

            // Price Breakdown
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                children: [
                  _priceRow('Base Membership Price', '₹$basePrice'),
                  if (discountAmount > 0) ...[
                    const SizedBox(height: 6),
                    _priceRow('Introductory Discount', '-₹$discountAmount', isDiscount: true),
                  ],
                  const SizedBox(height: 6),
                  _priceRow('Goods & Services Tax (GST 18%)', 'Included in Price'),
                  const Divider(color: Colors.white24, height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total Amount Payable', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      Text('₹$netPayable', style: TextStyle(color: AppTheme.brand, fontWeight: FontWeight.bold, fontSize: 18)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Mandatory Payment Methods (Only shown when netPayable > 0)
            if (netPayable > 0) ...[
              const Text('Select Payment Method (Mandatory)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 10),
              _buildPaymentRadio('upi_instant', 'UPI Instant Pay', 'Google Pay, PhonePe, Paytm, BHIM', Icons.flash_on_rounded),
              _buildPaymentRadio('upi_custom', 'Custom UPI ID / VPA', 'Pay via any UPI handle', Icons.account_balance_wallet_rounded),
              if (_paymentMethod == 'upi_custom') ...[
                Padding(
                  padding: const EdgeInsets.only(left: 36, right: 8, bottom: 8),
                  child: TextField(
                    controller: _upiVpaCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Enter UPI ID (e.g. rider@okaxis)',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.black38,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
              ],
              _buildPaymentRadio('card_netbanking', 'Cards & Net Banking', 'Visa, Mastercard, RuPay, All Banks', Icons.credit_card_rounded),
              const SizedBox(height: 8),
            ] else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.verified_rounded, color: Colors.tealAccent, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '100% Promo Applied. Direct zero-payment membership activation — no card or UPI required.',
                        style: TextStyle(color: Colors.tealAccent, fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (_checkoutError != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_checkoutError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12))),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Action Button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _isProcessing ? null : _submitPayment,
                child: _isProcessing
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : Text(
                        netPayable > 0 ? 'Pay ₹$netPayable & Activate Membership' : 'Activate Free Introductory Offer (₹0)',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _priceRow(String label, String value, {bool isDiscount = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        Text(
          value,
          style: TextStyle(
            color: isDiscount ? Colors.lightGreenAccent : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildPaymentRadio(String value, String title, String subtitle, IconData icon) {
    final isSelected = _paymentMethod == value;
    return GestureDetector(
      onTap: () => setState(() => _paymentMethod = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.brand.withValues(alpha: 0.15) : Colors.black26,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? AppTheme.brand : Colors.white12),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? AppTheme.brand : Colors.white60, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: Colors.white, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500, fontSize: 13)),
                  Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 11)),
                ],
              ),
            ),
            Radio<String>(
              value: value,
              groupValue: _paymentMethod,
              activeColor: AppTheme.brand,
              onChanged: (val) => setState(() => _paymentMethod = val!),
            ),
          ],
        ),
      ),
    );
  }
}
