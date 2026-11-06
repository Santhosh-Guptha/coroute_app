import 'membership_payment_screen.dart';
import 'package:flutter/material.dart';
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
          'Remove $name from your plan? Their seat becomes free.',
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

  /// Opens checkout for a paid plan (the server prices it: coupon and upgrade credit included).
  /// A plan that is not sold any more (the retired Individual) opens the cheapest paid plan.
  void _openPaymentCheckoutSheet(MembershipCategory cat) async {
    HapticFeedback.mediumImpact();
    if (!cat.canBuy) {
      final paid = context.read<MembershipService>().catalog?.paidCategories ?? const <MembershipCategory>[];
      if (paid.isEmpty || cat.isCommunity) return;
      cat = paid.first;
    }
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
        title: const Text('CoRoute Membership & Plans', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
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
          // Pull-to-refresh works even when the content is short; the bottom
          // inset keeps the last card above the system nav bar.
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (activeTrip != null) ...[
              _buildActiveTripLockBanner(activeTrip),
              const SizedBox(height: 16),
            ],
            _buildSafetyGuaranteeBanner(),
            const SizedBox(height: 16),
            if (owned != null && !owned.isExpired) ...[
              // Active owned membership: Show details, validity, seat count, and member controls.
              // Initial purchase selection cards & payment prompts are NOT unconditionally rendered.
              _buildOwnedMembershipCard(owned, auth.currentUserId ?? '', catalog),
              const SizedBox(height: 16),
              _buildSeatCapacityCard(owned),
              const SizedBox(height: 16),
              _buildMemberListCard(owned),
              const SizedBox(height: 20),
              _buildExpandableUpgradeSection(catalog, owned),
              const SizedBox(height: 24),
            ] else if (owned != null && owned.isExpired) ...[
              // Expired membership: Display renewal options prominently.
              _buildOwnedMembershipCard(owned, auth.currentUserId ?? '', catalog),
              const SizedBox(height: 16),
              _buildExpiredRenewalBanner(owned, catalog),
              const SizedBox(height: 20),
              _buildCatalogSection(catalog, owned, isRenewal: true),
              const SizedBox(height: 24),
            ] else if (ms.isLoading && overview == null) ...[
              // Clean verification state while checking server entitlement (ISSUE-10)
              _buildVerificationState(),
              const SizedBox(height: 24),
            ] else ...[
              // No owned membership: a legacy plan (kept until it ends), the participating card (if
              // any) and the catalog selection cards.
              if (ms.planAccess.isLegacy) ...[
                _buildLegacyPlanCard(ms.planAccess),
                const SizedBox(height: 16),
              ],
              if (overview != null && overview.participating.isNotEmpty) ...[
                _buildParticipatingCard(overview.participating.first),
                const SizedBox(height: 16),
              ],
              _buildCatalogSection(catalog, null),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationState() {
    return Container(
      key: const Key('membership_verification_state'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppTheme.brand,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Verifying Membership Status',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 6),
          const Text(
            'Checking your plan...',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// A plan bought before the membership plans (CoRoute Pro, Road Captain, Tour Operator): its
  /// name and end date; it keeps the same hosting until then and cannot be renewed.
  Widget _buildLegacyPlanCard(PlanAccess access) {
    final until = access.validUntil > 0 ? PlanAccess.untilLabel(access.validUntil) : null;
    return Container(
      key: const Key('membership_legacy_plan'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.accentText, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${access.name}${until != null ? ' · until $until' : ''}',
              style: TextStyle(color: AppTheme.text, fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            '${access.canHostGroup ? 'Host up to ${access.seats} riders' : 'Solo trips'} until it ends. '
            'This older plan is not sold any more: when it ends you are on Community (free, solo rides). '
            'Small Group or Large Group below lets you host a group.',
            style: TextStyle(color: AppTheme.text2, fontSize: 12, height: 1.35),
          ),
        ],
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
                  'Community is free for every rider: solo rides with SOS, crash alerts and guardians. '
                  'If a paid plan ends mid-ride, the ride goes on.',
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
            'You are in a ride (${lock.groupId}) as ${lock.role}. Leave or end it to start another.',
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
          const SizedBox(height: 8),
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
          Row(
            children: [
              Icon(
                isExpired ? Icons.event_busy_rounded : Icons.event_available_rounded,
                color: isExpired ? Colors.redAccent : Colors.white70,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                isExpired ? 'Ended on $validDate' : 'Valid until: $validDate',
                style: TextStyle(
                  color: isExpired ? Colors.redAccent : Colors.white70,
                  fontSize: 12,
                  fontWeight: isExpired ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.people_outline_rounded, color: Colors.white70, size: 16),
              const SizedBox(width: 6),
              Text(
                'Seat Count: ${mem.occupiedSeats} / ${mem.capacity} ${mem.capacity == 1 ? "seat" : "seats"}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          if (isExpired) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.autorenew_rounded, size: 18, color: Colors.black),
                    label: const Text(
                      'Reactivate Plan',
                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
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
        ],
      ),
    );
  }

  Widget _buildExpiredRenewalBanner(UserMembership owned, MembershipCatalog? catalog) {
    final validDate = owned.validUntil > 0 ? _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(owned.validUntil)) : 'Unknown';
    MembershipCategory? currentCat;
    if (catalog != null) {
      for (final c in catalog.categories) {
        if (c.id == owned.category) {
          currentCat = c;
          break;
        }
      }
    }
    currentCat ??= MembershipCategory(
      id: owned.category,
      name: owned.name,
      priceRupees: owned.priceRupees,
      capacity: owned.capacity,
    );
    // A plan that is not sold any more (the retired ₹9 Individual) is not renewed: the rider is on
    // Community (free, solo rides) and the button offers the cheapest group plan.
    final paid = catalog?.paidCategories ?? const <MembershipCategory>[];
    final renewable = currentCat.canBuy || paid.isEmpty;
    final renewCat = renewable ? currentCat : paid.first;
    final renewLabel = renewable ? 'Renew Current Plan (₹${owned.priceRupees} / mo)' : 'Host a group from ₹${renewCat.priceRupees}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.8), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
              SizedBox(width: 8),
              Text(
                'Membership Expired',
                style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            renewable
                ? 'Your ${owned.name} plan ended on $validDate. You ride on Community (free, solo rides) until you renew.'
                : 'Your ${owned.name} plan ended on $validDate. You ride on Community now: free, solo rides, every safety feature.',
            style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.3),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.autorenew_rounded, color: Colors.black, size: 20),
              label: Text(
                renewLabel,
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _openPaymentCheckoutSheet(renewCat),
            ),
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
              Text(
                mem.capacity == 1 ? 'Seat Capacity' : 'Group Seat Capacity',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              Text(
                '$used / $total ${total == 1 ? "Seat" : "Seats"}',
                style: TextStyle(color: isFull ? Colors.redAccent : AppTheme.brand, fontWeight: FontWeight.bold),
              ),
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
                ? (mem.capacity == 1
                    ? 'Solo plan: 1 seat. Upgrade below to invite riders.'
                    : 'All seats are taken. Remove a rider or upgrade.')
                : '${mem.availableSeats} seat(s) free. Invited riders ride free.',
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
              Text(
                mem.capacity == 1 ? 'Rider Invitations' : 'Group Participants',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.person_add_rounded, size: 16, color: Colors.black),
                label: const Text('Invite', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isFull ? Colors.white24 : AppTheme.brand,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                onPressed: isFull
                    ? () => _showSnack(
                          mem.capacity == 1
                              ? 'Solo plan: 1 seat. Upgrade below to add seats.'
                              : 'Seat capacity reached (${mem.capacity} seats). Upgrade or remove a member to invite.',
                          isError: true,
                        )
                    : _openInviteDialog,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (members.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  mem.capacity == 1
                      ? 'Solo plan: 1 seat. Upgrade below to invite friends.'
                      : 'No members invited yet. Tap "Invite" to add riders.',
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
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
                            m.isAccepted ? 'Accepted' : 'Invited, waiting',
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

  Widget _buildExpandableUpgradeSection(MembershipCatalog? catalog, UserMembership owned) {
    return Material(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('upgrade_capacity_expansion_tile'),
            initiallyExpanded: false,
            tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            childrenPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.brand.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.upgrade_rounded, color: AppTheme.brand, size: 20),
            ),
            title: const Text(
              'Change plan or seats',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
            subtitle: const Text(
              'Add seats or change plan',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            iconColor: AppTheme.brand,
            collapsedIconColor: Colors.white60,
            children: [
              const Divider(color: Colors.white10, height: 16),
              const Text(
                'Pick a plan below. Changes apply right away.',
                style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.3),
              ),
              const SizedBox(height: 14),
              _buildCatalogSection(catalog, owned, isExpandableContent: true),
            ],
          ),
        ),
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
            'You are in a group plan. You ride with all features for free.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogSection(
    MembershipCatalog? catalog,
    UserMembership? owned, {
    bool isExpandableContent = false,
    bool isRenewal = false,
  }) {
    // Community (free, shown for what it includes) and the paid plans; the retired ₹9 Individual is not offered.
    final listed = (catalog?.categories ?? const <MembershipCategory>[]).where((c) => c.isCommunity || c.canBuy).toList();
    // Prices and seats come only from the server catalog. Until it loads (offline), only the
    // free Community plan is shown, never invented paid plans.
    final categories = listed.isNotEmpty
        ? listed
        : const [
            MembershipCategory(
              id: 'community',
              name: 'Community',
              priceRupees: 0,
              capacity: 1,
              purchasable: false,
              description: 'Free for every rider: solo rides with every safety feature.',
              features: ['Solo rides with live tracking', 'SOS, crash alerts and guardians', 'Join any group ride for free'],
            ),
          ];

    final title = isRenewal
        ? 'Renew or Switch Plan'
        : (owned != null ? 'Upgrade or Switch Plan' : 'Select Membership Plan');
    final subtitle = isRenewal
        ? 'Select a plan below to renew your membership or switch to a different tier.'
        : (owned != null
            ? 'An upgrade starts now and credits your unused days. Fewer seats start when your plan ends.'
            : 'Ride solo for free, or pick how many riders you host. Each plan lasts 30 days.');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isExpandableContent) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
              ),
              if (owned == null)
                const Text(
                  'Community is free',
                  style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w600),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const SizedBox(height: 14),
        ],
        for (final cat in categories) ...[
          _buildCategoryCard(cat, owned, isRenewal: isRenewal),
        ],
        if (listed.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text(
              'Group plans show here when you are online.',
              key: Key('membership_catalog_offline'),
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ),
      ],
    );
  }

  /// Community: free for every rider, never bought. No button: it is simply what every rider has.
  Widget _buildCommunityCard(MembershipCategory cat, UserMembership? owned) {
    final yours = owned == null || owned.isExpired;
    return Container(
      key: const Key('membership_community_card'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: yours ? Colors.lightGreenAccent.withValues(alpha: 0.6) : Colors.white12, width: yours ? 1.5 : 1.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(cat.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              const Text('Free', style: TextStyle(color: Colors.lightGreenAccent, fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.person_rounded, color: Colors.white60, size: 16),
              const SizedBox(width: 6),
              Text(
                yours ? 'Your plan · solo rides' : 'Every rider has it · solo rides',
                style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          if (cat.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(cat.description, style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.35)),
          ],
          if (cat.features.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final feat in cat.features)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline_rounded, color: Colors.lightGreenAccent, size: 14),
                    const SizedBox(width: 8),
                    Expanded(child: Text(feat, style: const TextStyle(color: Colors.white70, fontSize: 12))),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 6),
          const Text(
            'Talk, messages and hosting a group come with Small Group or Large Group.',
            style: TextStyle(color: Colors.white38, fontSize: 11, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryCard(
    MembershipCategory cat,
    UserMembership? owned, {
    bool isRenewal = false,
  }) {
    if (cat.isCommunity) return _buildCommunityCard(cat, owned);
    final isCurrent = owned != null && owned.category == cat.id;
    final isPopular = cat.id == 'group_small';
    final isExpired = owned != null && owned.isExpired;

    String buttonLabel;
    if (isCurrent) {
      if (isExpired) {
        buttonLabel = 'Renew Current Plan (₹${cat.priceRupees})';
      } else {
        buttonLabel = 'Current Active Plan (Tap to Extend)';
      }
    } else if (owned != null) {
      if (cat.capacity > owned.capacity) {
        buttonLabel = 'Upgrade to ${cat.name} (₹${cat.priceRupees})';
      } else if (isExpired) {
        buttonLabel = 'Switch to ${cat.name} (₹${cat.priceRupees})';
      } else {
        buttonLabel = 'Switch to ${cat.name} (₹${cat.priceRupees}) when this plan ends';
      }
    } else {
      buttonLabel = 'Select & Pay ₹${cat.priceRupees}';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCurrent
              ? (isExpired ? Colors.redAccent : Colors.lightGreenAccent)
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
                cat.isIndividual ? 'Solo Rider (1 Seat)' : 'Group (${cat.capacity} seats)',
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
                backgroundColor: (isCurrent && !isExpired) ? Colors.white12 : AppTheme.brand,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _openPaymentCheckoutSheet(cat),
              child: Text(
                buttonLabel,
                style: TextStyle(
                  color: (isCurrent && !isExpired) ? Colors.white70 : Colors.black,
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
