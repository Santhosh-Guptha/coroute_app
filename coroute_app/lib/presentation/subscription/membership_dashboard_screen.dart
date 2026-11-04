import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/membership_service.dart';

/// Comprehensive dashboard for CoRoute Membership, Group Seat Capacity,
/// Member Invitations, and Single Active Trip Concurrency status.
class MembershipDashboardScreen extends StatefulWidget {
  const MembershipDashboardScreen({super.key});

  @override
  State<MembershipDashboardScreen> createState() => _MembershipDashboardScreenState();
}

class _MembershipDashboardScreenState extends State<MembershipDashboardScreen> {
  static final DateFormat _dateFmt = DateFormat('d MMM yyyy');
  final TextEditingController _offerCodeCtrl = TextEditingController(text: 'RIDERFREE');
  final TextEditingController _inviteCtrl = TextEditingController();
  bool _isSubmitting = false;

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
    _offerCodeCtrl.dispose();
    _inviteCtrl.dispose();
    super.dispose();
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.redAccent.shade700 : AppTheme.brand,
      ),
    );
  }

  Future<void> _handleInvite(BuildContext dialogCtx) async {
    final identifier = _inviteCtrl.text.trim();
    if (identifier.isEmpty) {
      _showSnack('Please enter a phone number or email.', isError: true);
      return;
    }
    setState(() => _isSubmitting = true);
    final ms = context.read<MembershipService>();
    final success = await ms.inviteMember(identifier);
    if (!mounted) return;
    setState(() => _isSubmitting = false);
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
              'Enter the rider\'s email or phone number. They will be added to your group membership and can join your convoys at zero extra cost.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _inviteCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Email or phone (e.g. 9876543210)',
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

  Future<void> _handleClaimOffer(String categoryId) async {
    final code = _offerCodeCtrl.text.trim();
    setState(() => _isSubmitting = true);
    final ms = context.read<MembershipService>();
    final mem = await ms.purchaseMembership(categoryId: categoryId, offerCode: code);
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (mem != null) {
      _showSnack('Membership activated successfully!');
    } else {
      _showSnack(ms.lastError ?? 'Failed to activate membership.', isError: true);
    }
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
        title: const Text('Membership & Convoys', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
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
            if (owned != null) ...[
              _buildOwnedMembershipCard(owned, auth.currentUserId ?? ''),
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
            ] else ...[
              _buildNoMembershipCard(),
              const SizedBox(height: 16),
            ],
            if (catalog != null && catalog.categories.isNotEmpty) ...[
              _buildCatalogSection(catalog, owned != null),
            ],
          ],
        ),
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

  Widget _buildOwnedMembershipCard(UserMembership mem, String currentUid) {
    final validDate = mem.validUntil > 0 ? _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(mem.validUntil)) : 'Permanent';
    final isExpired = mem.isExpired;

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
            isExpired ? 'Expired on $validDate mid-trip continuity protected' : 'Renews on: $validDate',
            style: TextStyle(color: isExpired ? Colors.redAccent : Colors.white60, fontSize: 12),
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
                onPressed: isFull ? () => _showSnack('Seat capacity reached (${mem.capacity} seats). Remove a member to invite.', isError: true) : _openInviteDialog,
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

  Widget _buildNoMembershipCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Choose Your Membership', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'CoRoute membership is owned by you permanently. Individual provides solo safety; Group provides convoy tracking and covers your entire riding crew under one simple monthly subscription.',
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.3),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _offerCodeCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Introductory Offer Code',
                    labelStyle: const TextStyle(color: Colors.white60),
                    filled: true,
                    fillColor: Colors.black26,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogSection(MembershipCatalog catalog, bool hasOwned) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hasOwned ? 'Available Categories' : 'Select a Category to Activate',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
        ),
        const SizedBox(height: 12),
        for (final cat in catalog.categories) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(cat.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    Text('₹${cat.priceRupees} / mo', style: TextStyle(color: AppTheme.brand, fontWeight: FontWeight.bold, fontSize: 16)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  cat.isIndividual ? 'Solo Rider (1 user)' : 'Group (Capacity: ${cat.capacity} members)',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                if (cat.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(cat.description, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
                const SizedBox(height: 12),
                if (!hasOwned)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: _isSubmitting ? null : () => _handleClaimOffer(cat.id),
                      child: _isSubmitting
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                          : Text('Activate ${cat.name}', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
