import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import 'admin_user_details_screen.dart';

/// Master admin: Registered Users directory.
/// Lists every registered account with live status, and opens detailed profile,
/// account hold/block controls, and all trips with fellow group members.
class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  String _filter = 'ALL'; // ALL, ACTIVE, ON_HOLD, BLOCKED, RIDING

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<ApiClient>().get('/admin/users');
      final list = (res is Map ? res['users'] : null);
      _users = (list is List) ? list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : [];
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load users.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'ON_HOLD':
        return AppTheme.hyperAmber;
      case 'BLOCKED':
        return AppTheme.laserRed;
      default:
        return AppTheme.emeraldSafe;
    }
  }

  void _openUserDetails(Map<String, dynamic> u) async {
    final userId = u['userId']?.toString() ?? '';
    if (userId.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AdminUserDetailsScreen(userId: userId, initialUser: u),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthService>().currentUserId;
    final q = _query.trim().toLowerCase();

    final visible = _users.where((u) {
      final status = (u['status']?.toString() ?? 'ACTIVE').toUpperCase();
      final isRiding = u['isInActiveConvoy'] == true;

      if (_filter == 'ACTIVE' && status != 'ACTIVE') return false;
      if (_filter == 'ON_HOLD' && status != 'ON_HOLD') return false;
      if (_filter == 'BLOCKED' && status != 'BLOCKED') return false;
      if (_filter == 'RIDING' && !isRiding) return false;

      if (q.isNotEmpty) {
        final name = (u['name']?.toString() ?? '').toLowerCase();
        final email = (u['email']?.toString() ?? '').toLowerCase();
        final phone = (u['phone']?.toString() ?? '').toLowerCase();
        final vehicle = (u['vehicleNo']?.toString() ?? '').toLowerCase();
        if (!name.contains(q) && !email.contains(q) && !phone.contains(q) && !vehicle.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList()
      ..sort((a, b) {
        // Active riders first, then by name
        final ra = a['isInActiveConvoy'] == true ? 0 : 1;
        final rb = b['isInActiveConvoy'] == true ? 0 : 1;
        if (ra != rb) return ra - rb;
        return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
      });

    final activeCount = _users.where((u) => (u['status']?.toString() ?? 'ACTIVE').toUpperCase() == 'ACTIVE').length;
    final onHoldCount = _users.where((u) => u['status'] == 'ON_HOLD').length;
    final blockedCount = _users.where((u) => u['status'] == 'BLOCKED').length;
    final ridingCount = _users.where((u) => u['isInActiveConvoy'] == true).length;

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Registered Users'),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: 'Refresh', onPressed: _load)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search by name, email, phone or vehicle no',
                    prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted),
                  ),
                ),
              ),

              // Filter Chips
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    _filterChip('All (${_users.length})', 'ALL'),
                    const SizedBox(width: 6),
                    _filterChip('Active ($activeCount)', 'ACTIVE', color: AppTheme.emeraldSafe),
                    const SizedBox(width: 6),
                    _filterChip('On Hold ($onHoldCount)', 'ON_HOLD', color: AppTheme.hyperAmber),
                    const SizedBox(width: 6),
                    _filterChip('Blocked ($blockedCount)', 'BLOCKED', color: AppTheme.laserRed),
                    const SizedBox(width: 6),
                    _filterChip('Riding Now ($ridingCount)', 'RIDING', color: AppTheme.neonCyan),
                  ],
                ),
              ),

              Expanded(
                child: _loading
                    ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
                    : _error != null
                        ? Center(child: Text(_error!, style: TextStyle(color: AppTheme.laserRed)))
                        : RefreshIndicator(
                            color: AppTheme.neonCyan,
                            onRefresh: _load,
                            child: visible.isEmpty
                                ? Center(
                                    child: Text('No users found.', style: TextStyle(color: AppTheme.textMuted)),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                                    itemCount: visible.length,
                                    itemBuilder: (ctx, i) {
                                      final u = visible[i];
                                      final isAdmin = u['role'] == AppConstants.adminRole;
                                      final isMe = u['userId'] == me;
                                      final status = (u['status']?.toString() ?? 'ACTIVE').toUpperCase();
                                      final statusColor = _statusColor(status);
                                      final isRiding = u['isInActiveConvoy'] == true;
                                      final activeGroup = u['activeGroup'] as Map?;

                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 8),
                                        child: GlassCard(
                                          onTap: () => _openUserDetails(u),
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                          child: Row(
                                            children: [
                                              CircleAvatar(
                                                radius: 20,
                                                backgroundColor: (isAdmin ? AppTheme.devmonksPurple : statusColor).withOpacity(0.2),
                                                child: Icon(
                                                  isAdmin ? Icons.shield_rounded : Icons.person_rounded,
                                                  color: isAdmin ? AppTheme.devmonksPurple : statusColor,
                                                  size: 20,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Flexible(
                                                          child: Text(
                                                            '${u['name'] ?? ''}${isMe ? ' (you)' : ''}',
                                                            overflow: TextOverflow.ellipsis,
                                                            style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 14),
                                                          ),
                                                        ),
                                                        const SizedBox(width: 6),
                                                        if (isAdmin)
                                                          Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                            decoration: BoxDecoration(
                                                              color: AppTheme.devmonksPurple.withOpacity(0.2),
                                                              borderRadius: BorderRadius.circular(4),
                                                              border: Border.all(color: AppTheme.devmonksPurple),
                                                            ),
                                                            child: Text('ADMIN', style: TextStyle(color: AppTheme.devmonksPurple, fontSize: 9, fontWeight: FontWeight.bold)),
                                                          )
                                                        else if (status != 'ACTIVE')
                                                          Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                                            decoration: BoxDecoration(
                                                              color: statusColor.withOpacity(0.2),
                                                              borderRadius: BorderRadius.circular(4),
                                                              border: Border.all(color: statusColor),
                                                            ),
                                                            child: Text(status.replaceAll('_', ' '), style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold)),
                                                          ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '${u['email'] ?? ''} ${u['phone'] != null && u['phone'].toString().isNotEmpty ? "· ${u['phone']}" : ""}',
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                                                    ),
                                                    if (isRiding && activeGroup != null)
                                                      Padding(
                                                        padding: const EdgeInsets.only(top: 4),
                                                        child: Container(
                                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                          decoration: BoxDecoration(
                                                            color: AppTheme.neonCyan.withOpacity(0.15),
                                                            borderRadius: BorderRadius.circular(4),
                                                            border: Border.all(color: AppTheme.neonCyan.withOpacity(0.6)),
                                                          ),
                                                          child: Row(
                                                            mainAxisSize: MainAxisSize.min,
                                                            children: [
                                                              Icon(Icons.two_wheeler_rounded, color: AppTheme.neonCyan, size: 12),
                                                              const SizedBox(width: 4),
                                                              Flexible(
                                                                child: Text(
                                                                  'Riding in ${activeGroup['name']}',
                                                                  style: TextStyle(color: AppTheme.neonCyan, fontSize: 10, fontWeight: FontWeight.bold),
                                                                  overflow: TextOverflow.ellipsis,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted, size: 20),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterChip(String label, String value, {Color? color}) {
    final isSelected = _filter == value;
    final chipColor = color ?? AppTheme.neonCyan;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => _filter = value),
      selectedColor: chipColor.withOpacity(0.2),
      labelStyle: TextStyle(color: isSelected ? chipColor : AppTheme.textSecondary, fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
      backgroundColor: AppTheme.slateCard,
      side: BorderSide(color: isSelected ? chipColor : AppTheme.subtleBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      showCheckmark: false,
    );
  }
}
