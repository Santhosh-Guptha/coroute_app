import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/feature_flags_service.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// One feature of the admin switch list (GET /admin/features).
@immutable
class AdminFeature {
  final String id;
  final String label;
  final String description;
  final String group;
  final bool locked;
  final bool enabled;
  final Map<String, dynamic>? lastChange;

  const AdminFeature({
    required this.id,
    required this.label,
    required this.description,
    required this.group,
    required this.locked,
    required this.enabled,
    this.lastChange,
  });

  /// Null for a row without an id (ignored). A missing `enabled` is on, a locked one is always on.
  static AdminFeature? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final locked = raw['locked'] == true;
    return AdminFeature(
      id: id,
      label: raw['label']?.toString() ?? id,
      description: raw['description']?.toString() ?? '',
      group: raw['group']?.toString() ?? 'Platform',
      locked: locked,
      enabled: locked || raw['enabled'] != false,
      lastChange: raw['lastChange'] is Map ? Map<String, dynamic>.from(raw['lastChange'] as Map) : null,
    );
  }

  /// "Turned off by asha@x.com, 7 Nov 2026, 10:42: Photo upload bug", or null without a change.
  String? get lastChangeLine {
    final c = lastChange;
    if (c == null) return null;
    final on = c['enabled'] == true;
    final by = c['by']?.toString() ?? 'admin';
    final reason = c['reason']?.toString() ?? '';
    return '${on ? 'Turned on' : 'Turned off'} by $by, ${adminDate(c['at'], time: true)}${reason.isEmpty ? '' : ': $reason'}';
  }
}

/// Features grouped in the server's group order (groups the server does not name come last).
Map<String, List<AdminFeature>> adminGroupFeatures(List<AdminFeature> features, List<String> order) {
  final out = <String, List<AdminFeature>>{for (final g in order) g: <AdminFeature>[]};
  for (final f in features) {
    out.putIfAbsent(f.group, () => <AdminFeature>[]).add(f);
  }
  out.removeWhere((_, v) => v.isEmpty);
  return out;
}

/// 3.55 master admin: feature switches ("kill switches"). Every feature with a switch: off stops it
/// for every rider within seconds (the gateway refuses it with FEATURE_OFF and tells every app).
/// Core safety (SOS, crash detection, emergency texts, medical ID) is shown as "Always on".
/// Turning a feature off asks for a reason (kept in the change history and the audit log).
class AdminFeaturesScreen extends StatefulWidget {
  const AdminFeaturesScreen({super.key});

  @override
  State<AdminFeaturesScreen> createState() => _AdminFeaturesScreenState();
}

class _AdminFeaturesScreenState extends State<AdminFeaturesScreen> {
  List<AdminFeature> _features = const [];
  List<String> _groups = const ['Safety', 'Riding', 'Group', 'Places', 'Community', 'Platform'];
  List<Map<String, dynamic>> _history = const [];
  bool _loading = true;
  bool _loaded = false;
  String? _error;
  final Set<String> _busy = {};

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
      final res = await context.read<ApiClient>().get('/admin/features', timeout: const Duration(seconds: 15));
      _apply(res);
    } catch (e) {
      error = adminErrorOf(e);
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
    if (error != null && _loaded) adminSnack(context, error, error: true);
  }

  void _apply(Object? res) {
    if (res is! Map) return;
    _features = (res['features'] is List ? res['features'] as List : const []).map(AdminFeature.fromJson).whereType<AdminFeature>().toList();
    final g = res['groups'];
    if (g is List && g.isNotEmpty) _groups = g.map((e) => e.toString()).toList();
    _history = adminMapList(res['history']);
    _loaded = true;
  }

  Future<String?> _askReason(AdminFeature f) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final text = controller.text.trim();
        return AlertDialog(
          backgroundColor: AppTheme.card,
          title: Text('Turn off ${f.label}?', style: AppText.title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'It stops for every rider within seconds and the app says "Turned off for now". You can turn it back on at any time.',
                style: AppText.body.copyWith(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 200,
                maxLines: 2,
                onChanged: (_) => setLocal(() {}),
                decoration: adminInput('Reason (required)', hint: 'For example: crashes on some phones'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.sos, foregroundColor: Colors.white),
              onPressed: text.isEmpty ? null : () => Navigator.of(ctx).pop(text),
              child: const Text('Turn off'),
            ),
          ],
        );
      }),
    );
    controller.dispose();
    return reason;
  }

  Future<void> _toggle(AdminFeature f, bool enabled) async {
    if (f.locked || _busy.contains(f.id)) return;
    String reason = '';
    if (!enabled) {
      final r = await _askReason(f);
      if (r == null || r.trim().isEmpty || !mounted) return;
      reason = r.trim();
    } else {
      final ok = await confirmAction(
        context,
        title: 'Turn on ${f.label}?',
        message: 'It starts working again for every rider within seconds.',
        confirmLabel: 'Turn on',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _busy.add(f.id));
    try {
      final res = await context.read<ApiClient>().put('/admin/features/${Uri.encodeComponent(f.id)}', {
        'enabled': enabled,
        if (reason.isNotEmpty) 'reason': reason,
      });
      // The console itself follows the change at once (the socket push follows too).
      if (mounted && res is Map) context.read<FeatureFlagsService?>()?.applyPayload(res);
      if (!mounted) return;
      adminSnack(context, '${f.label} turned ${enabled ? 'on' : 'off'} for every rider.');
      await _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
    if (mounted) setState(() => _busy.remove(f.id));
  }

  @override
  Widget build(BuildContext context) {
    final e = _error;
    return AdminShell(
      title: 'Feature switches',
      subtitle: 'Turn a feature off for every rider',
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminSection.features),
      body: LoadingState(
        loading: _loading && !_loaded,
        child: !_loaded && e != null
            ? AdminErrorState(message: e, onRetry: _load)
            : adminRefresh(
                onRefresh: _load,
                child: LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth >= adminWideBreakpoint;
                  final switchable = _features.where((f) => !f.locked).toList();
                  final off = switchable.where((f) => !f.enabled).length;
                  final grouped = adminGroupFeatures(_features, _groups);
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    children: [
                      AdminContent(
                        wide: wide,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AdminCard(
                              warning: off > 0,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  StatusLine(
                                    icon: off > 0 ? Icons.toggle_off_outlined : Icons.check_circle_outline_rounded,
                                    text: off > 0
                                        ? '$off of ${switchable.length} features turned off for every rider'
                                        : 'All ${switchable.length} features are on',
                                    color: off > 0 ? AppTheme.warnText : StatusColors.success,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'A change reaches every app within seconds. Core safety (SOS, crash detection, emergency texts, medical ID) is always on.',
                                    style: AppText.caption,
                                  ),
                                ],
                              ),
                            ),
                            for (final entry in grouped.entries) ...[
                              AdminSectionLabel(entry.key),
                              AdminCard(
                                padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: 4),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    for (var i = 0; i < entry.value.length; i++)
                                      _FeatureRow(
                                        feature: entry.value[i],
                                        busy: _busy.contains(entry.value[i].id),
                                        divider: i < entry.value.length - 1,
                                        onChanged: (v) => _toggle(entry.value[i], v),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                            if (_history.isNotEmpty) ...[
                              const AdminSectionLabel('Recent changes'),
                              AdminTable(
                                rows: [
                                  for (var i = 0; i < _history.length && i < 10; i++)
                                    AdminRow(
                                      leading: AdminRowIcon(
                                        _history[i]['enabled'] == true ? Icons.toggle_on_outlined : Icons.toggle_off_outlined,
                                        color: _history[i]['enabled'] == true ? StatusColors.success : AppTheme.sos,
                                      ),
                                      title: '${_labelOf(_history[i]['id'])} turned ${_history[i]['enabled'] == true ? 'on' : 'off'}',
                                      subtitle: '${_history[i]['by'] ?? 'admin'}, ${adminDate(_history[i]['at'], time: true)}'
                                          '${(_history[i]['reason']?.toString() ?? '').isEmpty ? '' : ': ${_history[i]['reason']}'}',
                                      divider: i < _history.length - 1 && i < 9,
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                }),
              ),
      ),
    );
  }

  String _labelOf(Object? id) {
    for (final f in _features) {
      if (f.id == id) return f.label;
    }
    return id?.toString() ?? 'Feature';
  }
}

class _FeatureRow extends StatelessWidget {
  final AdminFeature feature;
  final bool busy;
  final bool divider;
  final ValueChanged<bool> onChanged;

  const _FeatureRow({required this.feature, required this.busy, required this.divider, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final f = feature;
    final last = f.lastChangeLine;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(f.label, style: AppText.body.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
                if (f.description.isNotEmpty) Text(f.description, style: AppText.caption),
                if (!f.locked && !f.enabled)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: StatusTextChip(icon: Icons.block_rounded, text: 'Off for every rider', color: AppTheme.sos),
                  ),
                if (last != null && !f.locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(last, style: AppText.caption.copyWith(color: AppTheme.muted)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (f.locked)
            StatusTextChip(icon: Icons.lock_outline_rounded, text: 'Always on', color: StatusColors.success)
          else if (busy)
            const SizedBox(width: 48, height: 24, child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
          else
            Semantics(
              label: '${f.label}: ${f.enabled ? 'on' : 'off'}',
              child: Switch(value: f.enabled, onChanged: onChanged),
            ),
        ],
      ),
    );
  }
}
