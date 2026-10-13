import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_ui.dart';
import 'feature_analytics_view.dart';
import 'master_admin_dashboard.dart';

/// Master admin: website/app feedback, first-party page-view counts and the
/// app builds riders use (to know when the minimum build can be raised).
/// Pull down to refresh; the old numbers stay visible while they reload.
class AdminInsightsScreen extends StatefulWidget {
  const AdminInsightsScreen({super.key});

  @override
  State<AdminInsightsScreen> createState() => _AdminInsightsScreenState();
}

class _AdminInsightsScreenState extends State<AdminInsightsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
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
      return adminRefresh(
        onRefresh: _load,
        child: AdminScrollFill(child: AdminErrorState(message: _error!, onRetry: _load)),
      );
    }
    return LoadingState(
      loading: _loading,
      hasData: _loaded,
      child: adminRefresh(onRefresh: _load, child: child()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      title: 'Feedback and analytics',
      subtitle: 'Last 30 days',
      onBack: () => Navigator.maybePop(context),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminSection.insights),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: adminMaxContentWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
                child: TabBar(
                  controller: _tabs,
                  indicatorColor: AppTheme.brand,
                  indicatorWeight: 3,
                  dividerColor: Colors.transparent,
                  labelColor: AppTheme.accentText,
                  unselectedLabelColor: AppTheme.muted,
                  labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                  unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tabs: [
                    Tab(height: 48, text: _loaded ? 'Feedback (${_feedback.length})' : 'Feedback'),
                    const Tab(height: 48, text: 'Page views'),
                    const Tab(height: 48, text: 'App versions'),
                    const Tab(height: 48, text: 'Live features'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [_tab(_feedbackList), _tab(_viewsList), _tab(_buildsList), const FeatureAnalyticsView()],
                ),
              ),
            ],
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      itemCount: _feedback.length,
      itemBuilder: (ctx, i) {
        final f = _feedback[i];
        final ts = (f['createdAt'] as num?)?.toInt() ?? 0;
        final name = (f['name']?.toString() ?? '').trim();
        final from = [f['name'], f['email']].where((x) => x != null && x.toString().isNotEmpty).join(', ');
        final meta = [f['source'], f['appVersion'], f['device']].where((x) => x != null && x.toString().isNotEmpty).join(', ');
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DsAvatar(name.isEmpty ? '?' : name.substring(0, 1), size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(from.isEmpty ? 'Anonymous' : from, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.body.copyWith(fontWeight: FontWeight.w800)),
                          if (ts > 0) Text(fmt.format(DateTime.fromMillisecondsSinceEpoch(ts)), style: AppText.caption),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(f['message']?.toString() ?? '', style: AppText.body),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final m in meta.split(', '))
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: AppTheme.soft, borderRadius: BorderRadius.circular(7)),
                          child: Text(m, style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                        ),
                    ],
                  ),
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
    final busiest = days.isEmpty ? null : (days.toList()..sort((a, b) => b.value.compareTo(a.value))).first;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        AdminKpiGrid(
          tiles: [
            AdminKpiTile(label: 'Page views, last 30 days', value: '$total', delta: '${byPath.length} ${byPath.length == 1 ? 'page' : 'pages'} visited'),
            AdminKpiTile(label: 'Days with visits', value: '${days.length}', delta: busiest == null ? null : 'Busiest ${busiest.key}: ${busiest.value}'),
            AdminKpiTile(label: 'Referrers', value: '${byRef.length}', delta: byRef.isEmpty ? 'None recorded' : 'Top ${sorted(byRef).first.key}'),
          ],
        ),
        const SizedBox(height: 16),
        _DayChart(days: days),
        AdminTwoUp(
          left: _CountBlock(title: 'By page', rows: sorted(byPath)),
          right: _CountBlock(title: 'By referrer', rows: sorted(byRef)),
        ),
        const SizedBox(height: 16),
        _CountBlock(title: 'By day', rows: days),
        const SizedBox(height: 16),
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
    final rows = <Widget>[
      for (var i = 0; i < builds.length; i++)
        _buildRow(
          title: 'Build ${builds[i]['build']}',
          note: (lockout[(builds[i]['build'] as num).toInt()] ?? 0) == 0
              ? 'Safe as the minimum: nobody would be locked out.'
              : 'As the minimum it would lock out ${lockout[(builds[i]['build'] as num).toInt()]} riders.',
          safe: (lockout[(builds[i]['build'] as num).toInt()] ?? 0) == 0,
          count: '${builds[i]['users']} (${pct((builds[i]['users'] as num).toInt())})',
          share: total == 0 ? 0 : (builds[i]['users'] as num).toDouble() / total,
          last: older == 0 && i == builds.length - 1,
        ),
      if (older > 0)
        _buildRow(
          title: 'Older than build 65',
          note: 'These builds do not report their number.',
          safe: false,
          count: '$older (${pct(older)})',
          share: total == 0 ? 0 : older / total,
          last: true,
        ),
    ];
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        AdminKpiGrid(
          tiles: [
            AdminKpiTile(label: 'Riders, 30 days', value: '$total', delta: 'Reported a build'),
            AdminKpiTile(label: 'On latest', value: pct(onLatest), delta: '$onLatest riders'),
            AdminKpiTile(label: 'Minimum build', value: '$minBuild', delta: 'Older builds are locked out'),
            AdminKpiTile(label: 'Latest build', value: '$latest', delta: 'In the stores'),
          ],
        ),
        const AdminSectionLabel('Builds in use'),
        AdminTable(
          columns: const ['Build', 'Riders'],
          empty: Text('No app versions reported yet.', style: AppText.body.copyWith(color: AppTheme.text2)),
          rows: rows,
        ),
        const SizedBox(height: 16),
        DsCard(
          tinted: true,
          borderColor: AppTheme.tint,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            'To raise the minimum build, set MIN_APP_BUILD in /etc/coroute/gateway.env on the server and restart the gateway. '
            'Riders below it see "Update required" and a download link.',
            style: AppText.caption.copyWith(color: AppTheme.text),
          ),
        ),
      ],
    );
  }

  Widget _buildRow({required String title, required String note, required bool safe, required String count, required double share, required bool last}) {
    final c = safe ? AppTheme.accentText : AppTheme.warnText;
    return AdminRow(
      leading: AdminRowIcon(Icons.system_update_rounded, color: c),
      title: title,
      status: StatusLine(icon: safe ? Icons.check_circle_rounded : Icons.warning_amber_rounded, text: note, color: c),
      trailing: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(count, style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 4),
            SizedBox(width: 72, child: AdminMiniBar(value: share, height: 6, color: c)),
          ],
        ),
      ),
      divider: !last,
    );
  }
}

/// Page views per day as a bar chart card (newest 14 days, oldest at the
/// left), the canvas "Rides and incidents" chart with the app's real data.
class _DayChart extends StatelessWidget {
  final List<MapEntry<String, int>> days;

  const _DayChart({required this.days});

  @override
  Widget build(BuildContext context) {
    final shown = days.take(14).toList().reversed.toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    var max = 0;
    for (final d in shown) {
      if (d.value > max) max = d.value;
    }
    String label(String day) {
      // "2026-10-12" -> "12"; anything else as is, shortened.
      final parts = day.split('-');
      final s = parts.length == 3 ? parts[2] : day;
      return s.length > 3 ? s.substring(0, 3) : s;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AdminTitledCard(
        title: 'Views by day',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: AppTheme.brand, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 5),
            Text('Page views', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        child: SizedBox(
          height: 160,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(
                  child: Semantics(
                    label: '${shown[i].key}: ${shown[i].value}',
                    excludeSemantics: true,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              widthFactor: 0.62,
                              heightFactor: max == 0 ? 0.0 : (shown[i].value / max).clamp(0.03, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppTheme.brand,
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(label(shown[i].key), maxLines: 1, style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled card of name, count and bar rows (top 12), bars scaled to the
/// largest count.
class _CountBlock extends StatelessWidget {
  final String title;
  final List<MapEntry<String, int>> rows;

  const _CountBlock({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    final shown = rows.take(12).toList();
    var max = 0;
    for (final r in shown) {
      if (r.value > max) max = r.value;
    }
    return AdminTitledCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (shown.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('None', style: AppText.caption)),
          for (final r in shown)
            AdminBarRow(
              label: r.key.isEmpty ? '(none)' : r.key,
              value: '${r.value}',
              fraction: max == 0 ? 0 : r.value / max,
            ),
        ],
      ),
    );
  }
}
