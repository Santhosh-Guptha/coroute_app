import '../../core/ui/app_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/adaptive.dart';
import '../../core/ui/skeleton.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/models/membership_model.dart';
import '../../data/services/membership_service.dart';
import '../../domain/membership/plan_summary.dart';
import 'your_plan_card.dart';

/// "Your plan": the rider's CoRoute plan, read-only (Play payments policy,
/// docs/features_355/play_payments_policy.md). Shows the [YourPlanCard] (plan name, what it
/// includes, status, end date, "Your plan is managed in your CoRoute account."), the active trip
/// lock, and for the owner of a group plan the riders on it. Nothing here sells, prices, changes
/// or extends a plan, and nothing links out. The plan is re-read on open, on pull-to-refresh and
/// on the SUBSCRIPTION_* socket / push events (so a plan activated in the account shows at once).
class MembershipDashboardScreen extends StatefulWidget {
  const MembershipDashboardScreen({super.key});

  /// The screen title.
  static const String title = 'Your plan';

  @override
  State<MembershipDashboardScreen> createState() => _MembershipDashboardScreenState();
}

class _MembershipDashboardScreenState extends State<MembershipDashboardScreen> {
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
        backgroundColor: isError ? AppTheme.sos : AppTheme.brand,
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
      _showSnack(ms.lastError ?? 'Could not invite this rider. Try again.', isError: true);
    }
  }

  void _openInviteDialog() {
    _inviteCtrl.clear();
    showAppDialog(
      context, // round 7: app motion (spring scale + fade, reduce-motion aware)
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Invite a rider', style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the rider\'s email, username or phone number. They join your plan and ride in your group rides at no extra cost.',
              style: TextStyle(color: AppTheme.text2, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _inviteCtrl,
              autofocus: true,
              style: TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                hintText: 'Email or username or phone',
                hintStyle: TextStyle(color: AppTheme.muted),
                filled: true,
                fillColor: AppTheme.soft,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: AppTheme.text2)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.brand),
            onPressed: () => _handleInvite(ctx),
            child: const Text('Send invite', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _handleRemoveMember(String userId, String name) async {
    final confirm = await showAppDialog<bool>(
      context, // round 7: app motion (spring scale + fade, reduce-motion aware)
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.card,
        title: Text('Remove rider?', style: TextStyle(color: AppTheme.text)),
        content: Text(
          'Remove $name from your plan? Their seat becomes free.',
          style: TextStyle(color: AppTheme.text2),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.sos),
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
      _showSnack('$name removed from your plan.');
    } else {
      _showSnack(ms.lastError ?? 'Could not remove this rider. Try again.', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ms = context.watch<MembershipService>();
    final overview = ms.myOverview;
    final owned = overview?.ownedMembership;
    final activeTrip = overview?.activeTrip;
    final ridesOnFriendsPlan = owned == null && (overview?.participating.isNotEmpty ?? false);
    final summary = PlanSummary.from(planFactsOf(
      access: ms.planAccess,
      owned: owned,
      catalog: ms.catalog,
      ridesOnFriendsPlan: ridesOnFriendsPlan,
    ));
    final ownsGroupPlan = owned != null && owned.isActive && owned.capacity >= 2;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.card,
        elevation: 0,
        title: const Text(MembershipDashboardScreen.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
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
          // Pull-to-refresh works even when the content is short; the bottom
          // inset keeps the last card above the system nav bar.
          physics: const AlwaysScrollableScrollPhysics(),
          // Round 7: on tablets / landscape the cards stay a readable 640 dp column in the middle.
          padding: Adaptive.of(context).pagePadding(top: 16, bottom: 16 + MediaQuery.paddingOf(context).bottom),
          children: [
            if (activeTrip != null) ...[
              _buildActiveTripLockBanner(activeTrip),
              const SizedBox(height: 16),
            ],
            if (ms.isLoading && overview == null)
              _buildVerificationState()
            else
              YourPlanCard(summary: summary),
            if (ownsGroupPlan) ...[
              const SizedBox(height: 16),
              _buildSeatCapacityCard(owned),
              const SizedBox(height: 16),
              _buildMemberListCard(owned),
            ],
            const SizedBox(height: 24),
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
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Round 7: the plan text takes shape while it loads (no spinner).
          const Shimmer(child: SkeletonParagraph(lines: 3)),
          const SizedBox(height: 16),
          Text(
            'Checking your plan',
            style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 6),
          Text(
            'This takes a few seconds.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.text2, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveTripLockBanner(ActiveTripLock lock) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.warnTint,
        border: Border.all(color: AppTheme.warnBorder, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_clock_rounded, color: AppTheme.warnText, size: 22),
              SizedBox(width: 8),
              Text(
                'You are already in a ride',
                style: TextStyle(color: AppTheme.warnText, fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Leave or end your current ride to start another one.',
            style: TextStyle(color: AppTheme.text2, fontSize: 13, height: 1.3),
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
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                mem.capacity == 1 ? 'Your seat' : 'Group seats',
                style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              Text(
                '$used of $total ${total == 1 ? "seat" : "seats"}',
                style: TextStyle(color: isFull ? AppTheme.sos : AppTheme.brand, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 10,
              backgroundColor: AppTheme.soft,
              valueColor: AlwaysStoppedAnimation<Color>(isFull ? AppTheme.sos : AppTheme.brand),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isFull
                ? 'All seats are taken.'
                : '${mem.availableSeats} ${mem.availableSeats == 1 ? 'seat' : 'seats'} free. Invited riders ride free.',
            style: TextStyle(color: AppTheme.text2, fontSize: 12),
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
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Riders on your plan',
                style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.person_add_rounded, size: 16, color: Colors.black),
                label: const Text('Invite', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isFull ? AppTheme.border : AppTheme.brand,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                ),
                onPressed: isFull
                    ? () => _showSnack('All ${mem.capacity} seats are taken.', isError: true)
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
                  'No riders invited yet. Tap "Invite" to add riders.',
                  style: TextStyle(color: AppTheme.muted, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: members.length,
              separatorBuilder: (_, index) => Divider(color: AppTheme.soft, height: 16),
              itemBuilder: (ctx, i) {
                final m = members[i];
                return Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: AppTheme.border,
                      child: Text(
                        (m.name.isNotEmpty ? m.name[0] : (m.email.isNotEmpty ? m.email[0] : 'R')).toUpperCase(),
                        style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.name.isNotEmpty ? m.name : (m.email.isNotEmpty ? m.email : m.phone), style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600, fontSize: 14)),
                          Text(
                            m.isAccepted ? 'Accepted' : 'Invited, waiting',
                            style: TextStyle(color: m.isAccepted ? StatusColors.success : AppTheme.warnText, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.person_remove_rounded, color: AppTheme.sos, size: 20),
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
}
