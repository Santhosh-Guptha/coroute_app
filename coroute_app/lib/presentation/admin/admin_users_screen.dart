import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import 'admin_ui.dart';
import 'admin_user_details_screen.dart';
import 'master_admin_dashboard.dart';

/// Which users the list shows.
enum AdminUserFilter { all, active, onHold, blocked, riding }

/// Master admin: every registered account with its status. Search and filter
/// sit in one row; tapping a user opens the details (beside the list on a
/// tablet, as a new screen on a phone). Pull down to refresh; the list stays
/// visible while it reloads.
class AdminUsersScreen extends StatefulWidget {
  /// The filter the list opens with (the admin home opens "On hold").
  final AdminUserFilter initialFilter;

  const AdminUsersScreen({super.key, this.initialFilter = AdminUserFilter.all});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loaded = false;
  bool _loading = true;
  String? _error;
  String _query = '';
  late AdminUserFilter _filter = widget.initialFilter;
  String? _selectedId; // wide layout only

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
    String? error;
    try {
      final res = await context.read<ApiClient>().get('/admin/users');
      _users = adminMapList(res is Map ? res['users'] : null);
      _loaded = true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Could not load users.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error != null && _loaded) adminSnack(context, error, error: true);
  }

  static AccountStatus _statusOf(Map<String, dynamic> u) => AccountStatus.fromCode(u['status'] ?? 'ACTIVE');
  static bool _isRiding(Map<String, dynamic> u) => u['isInActiveConvoy'] == true;

  bool _matches(Map<String, dynamic> u, AdminUserFilter f) {
    switch (f) {
      case AdminUserFilter.all:
        return true;
      case AdminUserFilter.active:
        return _statusOf(u) == AccountStatus.active;
      case AdminUserFilter.onHold:
        return _statusOf(u) == AccountStatus.onHold;
      case AdminUserFilter.blocked:
        return _statusOf(u) == AccountStatus.blocked;
      case AdminUserFilter.riding:
        return _isRiding(u);
    }
  }

  static String _filterLabel(AdminUserFilter f) {
    switch (f) {
      case AdminUserFilter.all:
        return 'All';
      case AdminUserFilter.active:
        return 'Active';
      case AdminUserFilter.onHold:
        return 'On hold';
      case AdminUserFilter.blocked:
        return 'Blocked';
      case AdminUserFilter.riding:
        return 'Riding now';
    }
  }

  List<Map<String, dynamic>> _visible() {
    final q = _query.trim().toLowerCase();
    return _users.where((u) {
      if (!_matches(u, _filter)) return false;
      if (q.isEmpty) return true;
      for (final k in const ['name', 'email', 'phone', 'vehicleNo']) {
        if ((u[k]?.toString() ?? '').toLowerCase().contains(q)) return true;
      }
      return false;
    }).toList()
      ..sort((a, b) {
        // Riders in a live ride first, then by name.
        final ra = _isRiding(a) ? 0 : 1;
        final rb = _isRiding(b) ? 0 : 1;
        if (ra != rb) return ra - rb;
        return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
      });
  }

  Future<void> _open(Map<String, dynamic> u, bool wide) async {
    final userId = u['userId']?.toString() ?? '';
    if (userId.isEmpty) return;
    if (wide) {
      setState(() => _selectedId = userId);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AdminUserDetailsScreen(userId: userId, initialUser: u)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthService>().currentUserId;
    final visible = _visible();

    final filter = AdminFilterButton<AdminUserFilter>(
      value: _filter,
      label: _filterLabel(_filter),
      options: [
        for (final f in AdminUserFilter.values) (f, '${_filterLabel(f)} (${_users.where((u) => _matches(u, f)).length})'),
      ],
      onSelected: (f) => setState(() => _filter = f),
    );

    final riding = _users.where(_isRiding).length;
    return AdminShell(
      title: 'Users',
      subtitle: _loaded ? '${_users.length} ${_users.length == 1 ? 'account' : 'accounts'}${riding > 0 ? ' · $riding riding now' : ''}' : 'Registered accounts',
      onBack: () => Navigator.maybePop(context),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminSection.users),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= adminWideBreakpoint;
        final list = _buildList(visible, me, wide, filter);
        if (!wide) {
          return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 800), child: list));
        }
        Map<String, dynamic>? selected;
        for (final u in _users) {
          if (u['userId']?.toString() == _selectedId) selected = u;
        }
        final sel = selected;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: (c.maxWidth * 0.42).clamp(340.0, 480.0).toDouble(), child: list),
            VerticalDivider(width: 1, color: AppTheme.border),
            Expanded(
              child: sel == null
                  ? const EmptyState(
                      icon: Icons.person_search_rounded,
                      title: 'Pick a user',
                      message: 'Their profile, account status and rides show here.',
                    )
                  : AdminUserDetailsScreen(
                      key: ValueKey(_selectedId),
                      userId: _selectedId!,
                      initialUser: sel,
                      embedded: true,
                      onChanged: _load,
                      onDeleted: () {
                        setState(() => _selectedId = null);
                        _load();
                      },
                    ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> visible, String? me, bool wide, Widget filter) {
    final Widget content;
    if (!_loaded && _error != null) {
      content = AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _load));
    } else if (visible.isEmpty) {
      final filtered = _query.trim().isNotEmpty || _filter != AdminUserFilter.all;
      content = AdminScrollFill(
        child: EmptyState(
          icon: Icons.people_outline_rounded,
          title: filtered ? 'No matching users' : 'No users yet',
          message: filtered ? 'Try another search or filter.' : 'Accounts appear here when riders register.',
          primaryLabel: _filter != AdminUserFilter.all ? 'Show all' : null,
          onPrimary: _filter != AdminUserFilter.all ? () => setState(() => _filter = AdminUserFilter.all) : null,
        ),
      );
    } else {
      content = ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          AdminTable(
            columns: const ['Rider', 'Status'],
            rows: [
              for (var i = 0; i < visible.length; i++)
                _UserRow(
                  key: ValueKey(visible[i]['userId']),
                  user: visible[i],
                  isMe: me != null && visible[i]['userId'] == me,
                  selected: wide && visible[i]['userId']?.toString() == _selectedId,
                  last: i == visible.length - 1,
                  onTap: () => _open(visible[i], wide),
                ),
            ],
          ),
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 10),
          child: AdminSearchRow(
            hint: 'Name, email, phone or vehicle',
            onChanged: (v) => setState(() => _query = v),
            filter: filter,
          ),
        ),
        Expanded(
          child: LoadingState(
            loading: _loading,
            hasData: _loaded || _error != null,
            child: adminRefresh(onRefresh: _load, child: content),
          ),
        ),
      ],
    );
  }
}

/// One user: avatar, name, email and phone, and what stands out: an account
/// that is not active, an admin, a rider in a live ride.
class _UserRow extends StatelessWidget {
  final Map<String, dynamic> user;
  final bool isMe;
  final bool selected;
  final bool last;
  final VoidCallback onTap;

  const _UserRow({super.key, required this.user, required this.isMe, required this.selected, required this.onTap, this.last = false});

  @override
  Widget build(BuildContext context) {
    final u = user;
    final name = (u['name']?.toString() ?? '').trim();
    final isAdmin = u['role'] == AppConstants.adminRole;
    final status = AccountStatus.fromCode(u['status'] ?? 'ACTIVE');
    final activeGroup = u['activeGroup'];
    final groupName = activeGroup is Map ? (activeGroup['name']?.toString() ?? '') : '';
    final riding = u['isInActiveConvoy'] == true;
    final phone = u['phone']?.toString() ?? '';
    final contact = [u['email']?.toString() ?? '', phone].where((s) => s.isNotEmpty).join(', ');

    final lines = <Widget>[
      if (riding)
        StatusLine(
          icon: Icons.two_wheeler_rounded,
          text: groupName.isEmpty ? 'In a live ride' : 'Riding in $groupName',
          color: AppTheme.accentText,
        ),
    ];

    return AdminRow(
      leading: RiderAvatar(name: name.isEmpty ? '?' : name, color: isAdmin ? AppTheme.warnText : null),
      title: '${name.isEmpty ? 'Unnamed rider' : name}${isMe ? ' (you)' : ''}',
      subtitle: contact,
      detail: isAdmin ? 'Admin' : null,
      status: lines.isEmpty
          ? null
          : Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: lines),
      trailing: Padding(padding: const EdgeInsets.only(left: 8), child: StatusTextChip.account(status)),
      selected: selected,
      divider: !last,
      onTap: onTap,
    );
  }
}
