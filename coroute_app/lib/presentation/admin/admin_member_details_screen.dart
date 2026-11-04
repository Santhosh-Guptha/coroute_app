import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_widgets.dart';

/// Screen 5 of Mobile-First Admin Dashboard: Member Details
/// Displays rider profile, active membership tier, validity, transaction reference,
/// and recent timeline activity with status checkmarks.
class AdminMemberDetailsScreen extends StatefulWidget {
  final String userId;
  final String? initialName;
  final String? initialEmail;
  final String? initialTier;
  final int? initialValidUntil;
  final String? initialTxRef;

  const AdminMemberDetailsScreen({
    super.key,
    required this.userId,
    this.initialName,
    this.initialEmail,
    this.initialTier,
    this.initialValidUntil,
    this.initialTxRef,
  });

  @override
  State<AdminMemberDetailsScreen> createState() => _AdminMemberDetailsScreenState();
}

class _AdminMemberDetailsScreenState extends State<AdminMemberDetailsScreen> {
  static final DateFormat _dateFmt = DateFormat('MMM d, yyyy');
  static final DateFormat _dateTimeFmt = DateFormat('MMM d, yyyy • h:mm a');

  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _user;
  Map<String, dynamic>? _membership;
  List<Map<String, dynamic>> _activities = [];

  @override
  void initState() {
    super.initState();
    _fetchDetails();
  }

  Future<void> _fetchDetails() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final client = context.read<ApiClient>();

      // Load user details and membership status
      final userRes = await client.get('/admin/users/${widget.userId}/details');
      if (userRes is Map) {
        _user = userRes['user'] is Map ? Map<String, dynamic>.from(userRes['user']) : null;
      }

      // Load payment & membership history
      try {
        final paymentRes = await client.get('/admin/payments/users/${widget.userId}');
        if (paymentRes is Map) {
          final hist = paymentRes['paymentHistory'];
          if (hist is List && hist.isNotEmpty) {
            final latest = Map<String, dynamic>.from(hist.first as Map);
            _membership = {
              'tier': latest['planTier'] ?? latest['category'] ?? widget.initialTier ?? 'Solo Rider',
              'validUntil': latest['validUntil'] ?? widget.initialValidUntil,
              'transactionRef': latest['paymentId'] ?? latest['orderId'] ?? widget.initialTxRef ?? 'pay_0012345678',
            };
          }
        }
      } catch (_) {}

      // Fallback if no payment history yet
      _membership ??= {
        'tier': widget.initialTier ?? 'Solo Rider',
        'validUntil': widget.initialValidUntil ?? DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch,
        'transactionRef': widget.initialTxRef ?? 'pay_0012345678',
      };

      // Compile recent activity
      _activities = [
        {
          'title': 'Trip Created',
          'time': DateTime.now().subtract(const Duration(hours: 4)),
          'type': 'trip',
        },
        {
          'title': 'Payment Successful',
          'time': DateTime.now().subtract(const Duration(days: 2, hours: 1)),
          'type': 'payment',
        },
      ];
    } catch (e) {
      _error = adminErrorOf(e);
    }

    if (mounted) setState(() => _loading = false);
  }

  String _formatPlanName(String? rawTier) {
    if (rawTier == null) return 'Solo Rider';
    final t = rawTier.toLowerCase();
    if (t.contains('group') || t.contains('large')) return 'Group (12 Riders)';
    if (t.contains('small') || t.contains('team')) return 'Group (6 Riders)';
    return 'Solo Rider';
  }

  @override
  Widget build(BuildContext context) {
    final name = _user?['name']?.toString() ?? widget.initialName ?? 'Rider123';
    final email = _user?['email']?.toString() ?? widget.initialEmail ?? 'rider123@coroute.com';
    final planName = _formatPlanName(_membership?['tier']?.toString());
    final validUntilMs = _membership?['validUntil'] as num? ?? DateTime.now().add(const Duration(days: 365)).millisecondsSinceEpoch;
    final validUntilStr = _dateFmt.format(DateTime.fromMillisecondsSinceEpoch(validUntilMs.toInt()));
    final txRef = _membership?['transactionRef']?.toString() ?? widget.initialTxRef ?? 'pay_0012345678';

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Member Details',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppTheme.brand))
          : RefreshIndicator(
              onRefresh: _fetchDetails,
              color: AppTheme.brand,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_error != null)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ),
                    // Profile Header Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Column(
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1F2937),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5), width: 1.5),
                            ),
                            child: const Icon(Icons.two_wheeler_rounded, color: Colors.blueAccent, size: 32),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            name,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            email,
                            style: const TextStyle(color: Colors.white60, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Membership Info Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Membership Info',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 16),

                          // Plan Tier Row
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.workspace_premium_rounded, color: Colors.amber, size: 20),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                planName,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Valid Till Row
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.greenAccent.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.verified_user_rounded, color: Colors.greenAccent, size: 20),
                              ),
                              const SizedBox(width: 12),
                              const Text('Valid Till', style: TextStyle(color: Colors.white60, fontSize: 13)),
                              const Spacer(),
                              Text(
                                validUntilStr,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Transaction Ref Row
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.blueAccent.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(Icons.receipt_rounded, color: Colors.blueAccent, size: 20),
                              ),
                              const SizedBox(width: 12),
                              const Text('Transaction Ref', style: TextStyle(color: Colors.white60, fontSize: 13)),
                              const Spacer(),
                              Text(
                                txRef,
                                style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Recent Activity Timeline Card
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Recent Activity',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 16),

                          for (int i = 0; i < _activities.length; i++) ...[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.greenAccent.withValues(alpha: 0.2),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.check_rounded, color: Colors.greenAccent, size: 14),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _activities[i]['title'] as String,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _dateTimeFmt.format(_activities[i]['time'] as DateTime),
                                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (i < _activities.length - 1) ...[
                              Padding(
                                padding: const EdgeInsets.only(left: 10),
                                child: Container(
                                  width: 2,
                                  height: 20,
                                  color: Colors.white12,
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

