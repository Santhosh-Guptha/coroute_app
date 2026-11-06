import 'dart:async';
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

/// Order of the list (the gateway's `sort` values).
enum AdminRiderSort { lastSeen, joined, trips, km, sos, name }

/// Master admin: every registered account, from the server-side rider analytics
/// (`GET /api/admin/analytics/riders`): search, status / plan filters and the sort run on the
/// gateway, a page of [AdminUsersScreen.pageSize] at a time with "Load more". Tapping a rider
/// opens the details (beside the list on a tablet, as a new screen on a phone). Pull down to
/// refresh; the list stays visible while it reloads. An older gateway without the endpoint
/// (404) falls back to `GET /api/admin/users`, filtered and sorted on the phone.
class AdminUsersScreen extends StatefulWidget {
  /// The filter the list opens with (the admin home opens "On hold").
  final AdminUserFilter initialFilter;

  const AdminUsersScreen({super.key, this.initialFilter = AdminUserFilter.all});

  /// Riders per request.
  static const int pageSize = 50;

  /// The plan tiers the gateway knows ('' = every plan).
  static const List<String> tiers = ['', 'community', 'proRider', 'roadCaptain', 'tourOperator'];

  /// Query string for one page (pure, for tests).
  static Map<String, String> queryFor({
    required String q,
    required AdminUserFilter filter,
    required String tier,
    required AdminRiderSort sort,
    int cursor = 0,
    int limit = pageSize,
  }) {
    final status = switch (filter) {
      AdminUserFilter.active => 'ACTIVE',
      AdminUserFilter.onHold => 'ON_HOLD',
      AdminUserFilter.blocked => 'BLOCKED',
      _ => '',
    };
    return {
      if (q.trim().isNotEmpty) 'q': q.trim(),
      if (status.isNotEmpty) 'status': status,
      if (tier.isNotEmpty) 'tier': tier,
      if (filter == AdminUserFilter.riding) 'riding': '1',
      'sort': sort.name,
      'limit': '$limit',
      'cursor': '$cursor',
    };
  }

  /// One account of the legacy `/admin/users` list as a rider row of the analytics endpoint.
  static Map<String, dynamic> rowFromLegacy(Map<String, dynamic> u) {
    final group = u['activeGroup'];
    return {
      ...u,
      'riding': u['isInActiveConvoy'] == true ? (group is Map ? Map<String, dynamic>.from(group) : <String, dynamic>{}) : null,
    };
  }

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  List<Map<String, dynamic>> _riders = [];
  int _total = 0;
  int? _nextCursor;
  bool _loaded = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String _query = '';
  late AdminUserFilter _filter = widget.initialFilter;
  String _tier = '';
  AdminRiderSort _sort = AdminRiderSort.lastSeen;
  String? _selectedId; // wide layout only
  Timer? _debounce;
  int _generation = 0;

  /// The gateway has no analytics endpoint (404): the whole legacy list, filtered here.
  bool _legacy = false;
  List<Map<String, dynamic>> _legacyAll = [];
  int _legacyShown = AdminUsersScreen.pageSize;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() => _fetch(more: false);

  Future<void> _loadMore() async {
    if (_legacy) {
      setState(() => _legacyShown += AdminUsersScreen.pageSize);
      return;
    }
    if (_nextCursor == null || _loadingMore) return;
    await _fetch(more: true);
  }

  Future<void> _fetch({required bool more}) async {
    final gen = ++_generation;
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
      }
      _error = null;
    });
    String? error;
    final api = context.read<ApiClient>();
    try {
      if (_legacy) {
        await _fetchLegacy(api);
      } else {
        final params = AdminUsersScreen.queryFor(
          q: _query,
          filter: _filter,
          tier: _tier,
          sort: _sort,
          cursor: more ? (_nextCursor ?? 0) : 0,
        );
        final path = Uri(path: '/admin/analytics/riders', queryParameters: params).toString();
        final res = await api.get(path);
        if (gen != _generation || !mounted) return;
        final page = adminMapList(res is Map ? res['riders'] : null);
        _riders = more ? [..._riders, ...page] : page;
        _total = res is Map && res['total'] is num ? (res['total'] as num).toInt() : _riders.length;
        final next = res is Map ? res['nextCursor'] : null;
        _nextCursor = next is num ? next.toInt() : null;
        _loaded = true;
      }
    } on ApiException catch (e) {
      if (e.statusCode == 404 && !_legacy) {
        _legacy = true;
        try {
          await _fetchLegacy(api);
        } on ApiException catch (e2) {
          error = e2.message;
        } catch (_) {
          error = 'Could not load riders.';
        }
      } else {
        error = e.message;
      }
    } catch (_) {
      error = 'Could not load riders.';
    }
    if (gen != _generation || !mounted) return;
    setState(() {
      _loading = false;
      _loadingMore = false;
      _error = error;
    });
    if (error != null && _loaded) adminSnack(context, error, error: true);
  }

  Future<void> _fetchLegacy(ApiClient api) async {
    final res = await api.get('/admin/users');
    _legacyAll = [for (final u in adminMapList(res is Map ? res['users'] : null)) AdminUsersScreen.rowFromLegacy(u)];
    _legacyShown = AdminUsersScreen.pageSize;
    _loaded = true;
  }

  /// Changes a filter, the plan or the sort: the first page again.
  void _changed(VoidCallback change) {
    setState(change);
    if (_legacy) {
      setState(() => _legacyShown = AdminUsersScreen.pageSize);
    } else {
      _load();
    }
  }

  void _onSearch(String v) {
    _query = v;
    _debounce?.cancel();
    if (_legacy) {
      setState(() => _legacyShown = AdminUsersScreen.pageSize);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _load();
    });
  }

  static AccountStatus _statusOf(Map<String, dynamic> u) => AccountStatus.fromCode(u['status'] ?? 'ACTIVE');
  static bool _isRiding(Map<String, dynamic> u) => u['riding'] != null || u['isInActiveConvoy'] == true;

  bool _matchesLegacy(Map<String, dynamic> u) {
    final ok = switch (_filter) {
      AdminUserFilter.all => true,
      AdminUserFilter.active => _statusOf(u) == AccountStatus.active,
      AdminUserFilter.onHold => _statusOf(u) == AccountStatus.onHold,
      AdminUserFilter.blocked => _statusOf(u) == AccountStatus.blocked,
      AdminUserFilter.riding => _isRiding(u),
    };
    if (!ok) return false;
    if (_tier.isNotEmpty && (u['tier']?.toString() ?? '') != _tier) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    for (final k in const ['name', 'email', 'phone', 'vehicleNo', 'userId']) {
      if ((u[k]?.toString() ?? '').toLowerCase().contains(q)) return true;
    }
    return false;
  }

  static num _n(Map<String, dynamic> u, String k) => u[k] is num ? u[k] as num : 0;

  int _compareLegacy(Map<String, dynamic> a, Map<String, dynamic> b) {
    String name(Map<String, dynamic> u) => u['name']?.toString() ?? '';
    return switch (_sort) {
      AdminRiderSort.name => name(a).compareTo(name(b)),
      AdminRiderSort.joined => _n(b, 'createdAt').compareTo(_n(a, 'createdAt')),
      AdminRiderSort.trips => _n(b, 'trips').compareTo(_n(a, 'trips')),
      AdminRiderSort.km => _n(b, 'km').compareTo(_n(a, 'km')),
      AdminRiderSort.sos => _n(b, 'sos').compareTo(_n(a, 'sos')),
      // The legacy list has no last-seen time: riders in a live ride first, then by name.
      AdminRiderSort.lastSeen => (_isRiding(a) ? 0 : 1) != (_isRiding(b) ? 0 : 1) ? (_isRiding(a) ? -1 : 1) : name(a).compareTo(name(b)),
    };
  }

  /// The rows on screen, the total matching, and whether more can be loaded.
  (List<Map<String, dynamic>>, int, bool) _view() {
    if (!_legacy) return (_riders, _total, _nextCursor != null);
    final all = _legacyAll.where(_matchesLegacy).toList()..sort(_compareLegacy);
    return (all.take(_legacyShown).toList(), all.length, all.length > _legacyShown);
  }

  static String _filterLabel(AdminUserFilter f) => switch (f) {
        AdminUserFilter.all => 'All',
        AdminUserFilter.active => 'Active',
        AdminUserFilter.onHold => 'On hold',
        AdminUserFilter.blocked => 'Blocked',
        AdminUserFilter.riding => 'Riding now',
      };

  static String _sortLabel(AdminRiderSort s) => switch (s) {
        AdminRiderSort.lastSeen => 'Last seen',
        AdminRiderSort.joined => 'Newest',
        AdminRiderSort.trips => 'Most trips',
        AdminRiderSort.km => 'Most km',
        AdminRiderSort.sos => 'Most SOS',
        AdminRiderSort.name => 'Name',
      };

  static String tierLabel(String t) => switch (t) {
        '' => 'All plans',
        'community' => 'Community',
        'proRider' => 'Pro Rider',
        'roadCaptain' => 'Road Captain',
        'tourOperator' => 'Tour Operator',
        _ => t,
      };

  Future<void> _open(Map<String, dynamic> u, bool wide) async {
    final userId = u['userId']?.toString() ?? '';
    if (userId.isEmpty) return;
    if (wide) {
      setState(() => _selectedId = userId);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AdminUserDetailsScreen(userId: userId, initialUser: _detailSeed(u))),
    );
    if (mounted) _load();
  }

  /// The details screen still reads the legacy keys of a riding account.
  static Map<String, dynamic> _detailSeed(Map<String, dynamic> u) {
    final riding = u['riding'];
    return {
      ...u,
      'isInActiveConvoy': _isRiding(u),
      if (riding is Map && u['activeGroup'] == null) 'activeGroup': riding,
    };
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthService>().currentUserId;
    final (visible, total, hasMore) = _view();

    final filter = AdminFilterButton<AdminUserFilter>(
      value: _filter,
      label: _filterLabel(_filter),
      options: [for (final f in AdminUserFilter.values) (f, _filterLabel(f))],
      onSelected: (f) => _changed(() => _filter = f),
    );

    return AdminShell(
      title: 'Riders',
      subtitle: _loaded ? '$total ${total == 1 ? 'account' : 'accounts'}' : 'Registered accounts',
      onBack: () => Navigator.maybePop(context),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminSection.users),
      body: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= adminWideBreakpoint;
        final list = _buildList(visible, total, hasMore, me, wide, filter);
        if (!wide) {
          return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 800), child: list));
        }
        Map<String, dynamic>? selected;
        for (final u in visible) {
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
                      initialUser: _detailSeed(sel),
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

  Widget _buildList(List<Map<String, dynamic>> visible, int total, bool hasMore, String? me, bool wide, Widget filter) {
    final Widget content;
    if (!_loaded && _error != null) {
      content = AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _load));
    } else if (visible.isEmpty) {
      final filtered = _query.trim().isNotEmpty || _filter != AdminUserFilter.all || _tier.isNotEmpty;
      final narrowed = _filter != AdminUserFilter.all || _tier.isNotEmpty;
      content = AdminScrollFill(
        child: EmptyState(
          icon: Icons.people_outline_rounded,
          title: filtered ? 'No matching users' : 'No users yet',
          message: filtered ? 'Try another search or filter.' : 'Accounts appear here when riders register.',
          primaryLabel: narrowed ? 'Show all' : null,
          onPrimary: narrowed
              ? () => _changed(() {
                    _filter = AdminUserFilter.all;
                    _tier = '';
                  })
              : null,
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
          if (hasMore) ...[
            const SizedBox(height: 12),
            Center(
              child: _loadingMore
                  ? const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : OutlinedButton(
                      onPressed: _loadMore,
                      child: Text('Load more (${total - visible.length} left)'),
                    ),
            ),
          ],
        ],
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
          child: AdminSearchRow(
            hint: 'Name, email or phone',
            onChanged: _onSearch,
            filter: filter,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AdminFilterButton<String>(
                tooltip: 'Plan',
                value: _tier,
                label: tierLabel(_tier),
                options: [for (final t in AdminUsersScreen.tiers) (t, tierLabel(t))],
                onSelected: (t) => _changed(() => _tier = t),
              ),
              AdminFilterButton<AdminRiderSort>(
                tooltip: 'Sort',
                icon: Icons.sort_rounded,
                value: _sort,
                label: _sortLabel(_sort),
                options: [for (final s in AdminRiderSort.values) (s, _sortLabel(s))],
                onSelected: (s) => _changed(() => _sort = s),
              ),
            ],
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

/// "3 d ago" / "6 min ago" / "never" for an epoch-ms time.
String _seenAgo(Object? ms) {
  final t = ms is num ? ms.toInt() : 0;
  if (t <= 0) return 'never';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t));
  if (d.inDays >= 1) return '${d.inDays} d ago';
  return formatAgo(d);
}

/// One user: avatar, name, email and phone, the rider numbers (trips, km, SOS, last seen),
/// and what stands out: an account that is not active, an admin, a rider in a live ride.
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
    final ridingInfo = u['riding'] ?? u['activeGroup'];
    final groupName = ridingInfo is Map ? (ridingInfo['name']?.toString() ?? '') : '';
    final riding = u['riding'] != null || u['isInActiveConvoy'] == true;
    final phone = u['phone']?.toString() ?? '';
    final contact = [u['email']?.toString() ?? '', phone].where((s) => s.isNotEmpty).join(', ');
    final tier = u['tier']?.toString() ?? '';
    final hasStats = u['trips'] is num;
    final stats = hasStats
        ? '${(u['trips'] as num).toInt()} trips · ${(u['km'] is num ? (u['km'] as num) : 0).toStringAsFixed(0)} km'
            '${u['sos'] is num && (u['sos'] as num) > 0 ? ' · ${(u['sos'] as num).toInt()} SOS' : ''}'
            ' · seen ${_seenAgo(u['lastSeenAt'])}'
        : '';

    final lines = <Widget>[
      if (riding)
        StatusLine(
          icon: Icons.two_wheeler_rounded,
          text: groupName.isEmpty ? 'In a live ride' : 'Riding in $groupName',
          color: AppTheme.accentText,
        ),
      if (stats.isNotEmpty) StatusLine(icon: Icons.insights_rounded, text: stats),
    ];
    final tags = [
      if (isAdmin) 'Admin',
      if (u['guest'] == true) 'Guest',
      if (tier.isNotEmpty && tier != 'community') _AdminUsersScreenState.tierLabel(tier),
    ];

    return AdminRow(
      leading: RiderAvatar(name: name.isEmpty ? '?' : name, color: isAdmin ? AppTheme.warnText : null),
      title: '${name.isEmpty ? 'Unnamed rider' : name}${isMe ? ' (you)' : ''}',
      subtitle: contact,
      detail: tags.isEmpty ? null : tags.join(' · '),
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
