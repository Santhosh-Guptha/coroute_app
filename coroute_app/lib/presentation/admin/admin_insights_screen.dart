import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_ui.dart';

/// Master admin: website/app feedback, first-party page-view counts and the
/// app builds riders use (to know when the minimum build can be raised).
/// Pull down to refresh; the old numbers stay visible while they reload.
class AdminInsightsScreen extends StatefulWidget {
  const AdminInsightsScreen({super.key});

  @override
  State<AdminInsightsScreen> createState() => _AdminInsightsScreenState();
}

class _AdminInsightsScreenState extends State<AdminInsightsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  List<Map<String, dynamic>> _feedback = [];
  List<Map<String, dynamic>> _views = [];
  Map<String, dynamic> _builds = {};
  bool _loading = true;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<ApiClient>();
    String? error;
    try {
      final fb = await api.get('/admin/feedback');
      final an = await api.get('/admin/analytics?days=30');
      final ab = await api.get('/admin/app-builds?days=30');
      _builds = ab is Map ? Map<String, dynamic>.from(ab) : {};
      _feedback = adminMapList(fb is Map ? fb['feedback'] : null);
      _views = adminMapList(an is Map ? an['pageviews'] : null);
      _loaded = true;
    } on ApiException catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Could not load data.';
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error != null && _loaded) adminSnack(context, error, error: true);
  }

  /// One tab body: error, spinner, or [child] with pull to refresh.
  Widget _tab(Widget Function() child) {
    if (!_loaded && _error != null) {
      return RefreshIndicator(
        color: AppTheme.neonCyan,
        onRefresh: _load,
        child: AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _load)),
      );
    }
    return LoadingState(
      loading: _loading,
      hasData: _loaded,
      child: RefreshIndicator(color: AppTheme.neonCyan, onRefresh: _load, child: child()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Feedback and analytics'),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: 'Refresh', onPressed: _load)],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppTheme.neonCyan,
          labelColor: AppTheme.neonCyan,
          unselectedLabelColor: AppTheme.textSecondary,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(height: 48, text: _loaded ? 'Feedback (${_feedback.length})' : 'Feedback'),
            const Tab(height: 48, text: 'Page views'),
            const Tab(height: 48, text: 'App versions'),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: TabBarView(
            controller: _tabs,
            children: [_tab(_feedbackList), _tab(_viewsList), _tab(_buildsList)],
          ),
        ),
      ),
    );
  }

  Widget _feedbackList() {
    if (_feedback.isEmpty) {
      return const AdminScrollFill(
        child: EmptyState(
          icon: Icons.forum_outlined,
          title: 'No feedback yet',
          message: 'Messages from the website and the app show here.',
        ),
      );
    }
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
      itemCount: _feedback.length,
      itemBuilder: (ctx, i) {
        final f = _feedback[i];
        final ts = (f['createdAt'] as num?)?.toInt() ?? 0;
        final from = [f['name'], f['email']].where((x) => x != null && x.toString().isNotEmpty).join(', ');
        final meta = [f['source'], f['appVersion'], f['device']].where((x) => x != null && x.toString().isNotEmpty).join(', ');
        return Padding(
          padding: const EdgeInsets.only(bottom: Space.s8),
          child: AdminCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(from.isEmpty ? 'Anonymous' : from, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                if (ts > 0) Text(fmt.format(DateTime.fromMillisecondsSinceEpoch(ts)), style: AppText.caption),
                const SizedBox(height: Space.s8),
                SelectableText(f['message']?.toString() ?? '', style: AppText.body),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: Space.s8),
                  Text(meta, style: AppText.caption),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _viewsList() {
    if (_views.isEmpty) {
      return const AdminScrollFill(
        child: EmptyState(
          icon: Icons.bar_chart_rounded,
          title: 'No page views yet',
          message: 'Website visits of the last 30 days show here.',
        ),
      );
    }
    final total = _views.fold<int>(0, (a, v) => a + ((v['count'] as num?)?.toInt() ?? 0));
    final byPath = <String, int>{};
    final byDay = <String, int>{};
    final byRef = <String, int>{};
    for (final v in _views) {
      final c = (v['count'] as num?)?.toInt() ?? 0;
      byPath.update(v['path']?.toString() ?? '/', (x) => x + c, ifAbsent: () => c);
      byDay.update(v['day']?.toString() ?? '', (x) => x + c, ifAbsent: () => c);
      final refs = v['referrers'];
      if (refs is Map) {
        refs.forEach((k, n) => byRef.update(k.toString(), (x) => x + ((n as num?)?.toInt() ?? 0), ifAbsent: () => (n as num?)?.toInt() ?? 0));
      }
    }
    List<MapEntry<String, int>> sorted(Map<String, int> m) => m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final days = byDay.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
      children: [
        AdminCard(child: RideMetric(value: '$total', label: 'Page views, last 30 days', emphasis: true)),
        _CountBlock(title: 'By page', rows: sorted(byPath)),
        _CountBlock(title: 'By day', rows: days),
        _CountBlock(title: 'By referrer', rows: sorted(byRef)),
        const SizedBox(height: Space.s16),
        Text('Counts only: no cookies, IP addresses or identifiers are stored.', style: AppText.caption),
      ],
    );
  }

  /// Which app builds the riders of the last 30 days use, and how many riders
  /// each possible minimum build would lock out.
  Widget _buildsList() {
    int n(String k) => (_builds[k] as num?)?.toInt() ?? 0;
    final total = n('total'), older = n('older'), minBuild = n('minBuild'), latest = n('latestBuild'), onLatest = n('onLatest');
    final builds = (_builds['builds'] as List? ?? const []).whereType<Map>().toList();
    final lockout = {
      for (final l in (_builds['lockout'] as List? ?? const []).whereType<Map>()) (l['build'] as num).toInt(): (l['wouldLockOut'] as num).toInt(),
    };
    String pct(int part) => total == 0 ? '0%' : '${(part * 100 / total).round()}%';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Space.s16, Space.s16, Space.s16, Space.s32),
      children: [
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: RideMetric(value: '$total', label: 'Riders, 30 days')),
                  Expanded(child: RideMetric(value: pct(onLatest), label: 'On latest')),
                  Expanded(child: RideMetric(value: '$minBuild', label: 'Minimum build')),
                  Expanded(child: RideMetric(value: '$latest', label: 'Latest build')),
                ],
              ),
            ],
          ),
        ),
        const AdminSectionLabel('Builds in use'),
        if (builds.isEmpty && older == 0) Text('No app versions reported yet.', style: AppText.body.copyWith(color: AppTheme.textSecondary)),
        for (final b in builds)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: _buildRow(
              title: 'Build ${b['build']}',
              note: (lockout[(b['build'] as num).toInt()] ?? 0) == 0
                  ? 'Safe as the minimum: nobody would be locked out.'
                  : 'As the minimum it would lock out ${lockout[(b['build'] as num).toInt()]} riders.',
              safe: (lockout[(b['build'] as num).toInt()] ?? 0) == 0,
              count: '${b['users']} (${pct((b['users'] as num).toInt())})',
            ),
          ),
        if (older > 0)
          _buildRow(
            title: 'Older than build 65',
            note: 'These builds do not report their number.',
            safe: false,
            count: '$older (${pct(older)})',
          ),
        const SizedBox(height: Space.s16),
        Text(
          'To raise the minimum build, set MIN_APP_BUILD in /etc/coroute/gateway.env on the server and restart the gateway. '
          'Riders below it see "Update required" and a download link.',
          style: AppText.caption,
        ),
      ],
    );
  }

  Widget _buildRow({required String title, required String note, required bool safe, required String count}) {
    return AdminRow(
      leading: AdminRowIcon(Icons.system_update_rounded, color: safe ? StatusColors.success : StatusColors.warning),
      title: title,
      status: StatusLine(
        icon: safe ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
        text: note,
        color: safe ? StatusColors.success : StatusColors.warning,
      ),
      trailing: Padding(
        padding: const EdgeInsets.only(left: Space.s8),
        child: Text(count, style: AppText.label.copyWith(color: AppTheme.textPrimary, fontFeatures: const [FontFeature.tabularFigures()])),
      ),
    );
  }
}

/// A titled list of name and count rows (top 12).
class _CountBlock extends StatelessWidget {
  final String title;
  final List<MapEntry<String, int>> rows;

  const _CountBlock({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSectionLabel(title),
        AdminCard(
          padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
          child: Column(
            children: [
              if (rows.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: Space.s8), child: Text('None', style: AppText.caption)),
              for (final r in rows.take(12))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.s8),
                  child: Row(
                    children: [
                      Expanded(child: Text(r.key.isEmpty ? '(none)' : r.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body)),
                      const SizedBox(width: Space.s8),
                      Text('${r.value}', style: AppText.body.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
