import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/glass_card.dart';
import '../../data/services/api_client.dart';

/// Master admin: website/app feedback and first-party page-view counts.
class AdminInsightsScreen extends StatefulWidget {
  const AdminInsightsScreen({super.key});

  @override
  State<AdminInsightsScreen> createState() => _AdminInsightsScreenState();
}

class _AdminInsightsScreenState extends State<AdminInsightsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  List<Map<String, dynamic>> _feedback = [];
  List<Map<String, dynamic>> _views = [];
  bool _loading = true;
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
    try {
      final fb = await api.get('/admin/feedback');
      final an = await api.get('/admin/analytics?days=30');
      _feedback = ((fb is Map ? fb['feedback'] : null) as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      _views = ((an is Map ? an['pageviews'] : null) as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } on ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Could not load data.';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        title: const Text('Feedback & analytics'),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _load)],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppTheme.neonCyan,
          labelColor: AppTheme.neonCyan,
          unselectedLabelColor: AppTheme.textMuted,
          tabs: [Tab(text: 'Feedback (${_feedback.length})'), const Tab(text: 'Page views, 30 days')],
        ),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppTheme.neonCyan))
          : _error != null
              ? Center(child: Text(_error!, style: TextStyle(color: AppTheme.laserRed)))
              : TabBarView(controller: _tabs, children: [_feedbackList(), _viewsList()]),
    );
  }

  Widget _feedbackList() {
    if (_feedback.isEmpty) {
      return Center(child: Text('No feedback yet.', style: TextStyle(color: AppTheme.textMuted)));
    }
    final fmt = DateFormat('d MMM yyyy, HH:mm');
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _feedback.length,
      itemBuilder: (ctx, i) {
        final f = _feedback[i];
        final ts = (f['createdAt'] as num?)?.toInt() ?? 0;
        final from = [f['name'], f['email']].where((x) => x != null && x.toString().isNotEmpty).join(' · ');
        final meta = [f['source'], f['appVersion'], f['device']].where((x) => x != null && x.toString().isNotEmpty).join(' · ');
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(from, style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600, fontSize: 13), overflow: TextOverflow.ellipsis)),
                    Text(ts > 0 ? fmt.format(DateTime.fromMillisecondsSinceEpoch(ts)) : '', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(f['message']?.toString() ?? '', style: TextStyle(color: AppTheme.textPrimary, fontSize: 13, height: 1.4)),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(meta, style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
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
      return Center(child: Text('No page views recorded yet.', style: TextStyle(color: AppTheme.textMuted)));
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
    Widget block(String title, List<MapEntry<String, int>> rows) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GlassCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(color: AppTheme.textMuted, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                const SizedBox(height: 8),
                for (final r in rows.take(12))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(child: Text(r.key, style: TextStyle(color: AppTheme.textPrimary, fontSize: 13), overflow: TextOverflow.ellipsis)),
                        Text('${r.value}', style: TextStyle(color: AppTheme.neonCyan, fontSize: 13, fontWeight: FontWeight.bold, fontFeatures: [FontFeature.tabularFigures()])),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
    final days = byDay.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Expanded(child: Text('Total page views, last 30 days', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))),
              Text('$total', style: TextStyle(color: AppTheme.textPrimary, fontSize: 22, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        block('BY PAGE', sorted(byPath)),
        block('BY DAY', days),
        block('BY REFERRER', sorted(byRef)),
        Text('Counts only: no cookies, IP addresses or identifiers are stored.', style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
      ],
    );
  }
}
