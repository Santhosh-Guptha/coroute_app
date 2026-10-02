import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';

/// Master admin: list every account and promote/demote administrators.
/// Roles are stored in the database; the app only displays and requests changes.
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

  Future<void> _setRole(Map<String, dynamic> user, String role) async {
    final userId = user['userId']?.toString() ?? '';
    final name = user['name']?.toString() ?? userId;
    final promote = role == AppConstants.adminRole;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.slateCard,
        title: Text(promote ? 'Make $name an admin?' : 'Remove admin from $name?', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          promote
              ? 'Admins can see every convoy, broadcast fleet-wide alerts, dissolve convoys and manage roles.'
              : 'They will become a regular rider immediately.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: AppTheme.textMuted))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: promote ? AppTheme.neonCyan : AppTheme.laserRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(promote ? 'Promote' : 'Demote', style: TextStyle(color: promote ? Colors.black : Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<ApiClient>().patch('/admin/users/$userId/role', {'role': role});
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message), backgroundColor: AppTheme.laserRed));
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthService>().currentUserId;
    final q = _query.trim().toLowerCase();
    final visible = _users.where((u) {
      if (q.isEmpty) return true;
      return (u['name']?.toString().toLowerCase().contains(q) ?? false) || (u['email']?.toString().toLowerCase().contains(q) ?? false);
    }).toList()
      ..sort((a, b) {
        final ra = a['role'] == AppConstants.adminRole ? 0 : 1;
        final rb = b['role'] == AppConstants.adminRole ? 0 : 1;
        if (ra != rb) return ra - rb;
        return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
      });
    final adminCount = _users.where((u) => u['role'] == AppConstants.adminRole).length;

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Users & Roles'),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _load)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Search by name or e-mail',
                    prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  children: [
                    Text('${_users.length} accounts · $adminCount admin${adminCount == 1 ? '' : 's'}',
                        style: const TextStyle(color: AppTheme.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
                    : _error != null
                        ? Center(child: Text(_error!, style: const TextStyle(color: AppTheme.laserRed)))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: visible.length,
                              itemBuilder: (ctx, i) {
                                final u = visible[i];
                                final isAdmin = u['role'] == AppConstants.adminRole;
                                final isMe = u['userId'] == me;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: GlassCard(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          radius: 18,
                                          backgroundColor: (isAdmin ? AppTheme.devmonksPurple : AppTheme.neonCyan).withOpacity(0.2),
                                          child: Icon(isAdmin ? Icons.shield_rounded : Icons.person_rounded,
                                              color: isAdmin ? AppTheme.devmonksPurple : AppTheme.neonCyan, size: 18),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text('${u['name'] ?? ''}${isMe ? ' (you)' : ''}',
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                                              Text('${u['email'] ?? ''} · ${u['provider'] ?? 'password'}',
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        if (isAdmin)
                                          OutlinedButton(
                                            onPressed: isMe ? null : () => _setRole(u, AppConstants.riderRole),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppTheme.laserRed,
                                              side: const BorderSide(color: AppTheme.laserRed),
                                              visualDensity: VisualDensity.compact,
                                            ),
                                            child: const Text('Demote', style: TextStyle(fontSize: 12)),
                                          )
                                        else
                                          ElevatedButton(
                                            onPressed: () => _setRole(u, AppConstants.adminRole),
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: AppTheme.devmonksPurple,
                                              visualDensity: VisualDensity.compact,
                                            ),
                                            child: const Text('Make admin', style: TextStyle(fontSize: 12, color: Colors.white)),
                                          ),
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
}
