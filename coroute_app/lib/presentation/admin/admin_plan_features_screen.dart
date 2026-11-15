import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_nav.dart';
import 'admin_payments_widgets.dart' show adminErrorOf;
import 'admin_ui.dart';

/// v3.60 in-app admin: Features by plan (gateway/src/plans.js). Which community and chat features each plan
/// includes, and its limits. Safety is never listed (free for everyone). Same data as the web admin; audited.
class AdminPlanFeaturesScreen extends StatefulWidget {
  const AdminPlanFeaturesScreen({super.key});

  @override
  State<AdminPlanFeaturesScreen> createState() => _AdminPlanFeaturesScreenState();
}

class _AdminPlanFeaturesScreenState extends State<AdminPlanFeaturesScreen> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _plans; // editable copy
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await context.read<ApiClient>().get('/admin/plan-features');
      if (!mounted) return;
      final m = Map<String, dynamic>.from(res as Map);
      setState(() {
        _data = m;
        _plans = _deepCopy(m['plans']);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = adminErrorOf(e);
        });
      }
    }
  }

  static Map<String, dynamic> _deepCopy(Object? raw) {
    final out = <String, dynamic>{};
    if (raw is Map) {
      raw.forEach((p, v) {
        final m = v is Map ? v : const {};
        out[p.toString()] = {
          'features': Map<String, dynamic>.from(m['features'] is Map ? m['features'] as Map : const {}),
          'limits': Map<String, dynamic>.from(m['limits'] is Map ? m['limits'] as Map : const {}),
        };
      });
    }
    return out;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<ApiClient>().put('/admin/plan-features', {'plans': _plans});
      if (mounted) showAppToast(context, 'Saved. Riders get it within a minute.');
      await _load();
    } catch (e) {
      if (mounted) showAppToast(context, adminErrorOf(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final plans = _plans;
    final ids = d == null ? const <String>[] : [for (final x in (d['planIds'] as List? ?? const [])) x.toString()];
    final names = d == null ? const <String, dynamic>{} : Map<String, dynamic>.from(d['planNames'] as Map? ?? const {});
    final features = d == null ? const <Map>[] : (d['features'] as List? ?? const []).whereType<Map>().toList();
    final limits = d == null ? const <Map>[] : (d['limits'] as List? ?? const []).whereType<Map>().toList();
    return AdminShell(
      title: 'Features by plan',
      subtitle: 'Communities and chat per plan. Safety is free for everyone.',
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminPage.planFeatures),
      tabs: adminSectionTabs(context, AdminPage.planFeatures),
      body: LoadingState(
        loading: _loading && d == null,
        child: d == null || plans == null
            ? AdminErrorState(message: _error ?? 'Could not load.', onRetry: _load)
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
                children: [
                  for (final p in ids) ...[
                    DsSectionHeader(names[p]?.toString() ?? p),
                    const SizedBox(height: 8),
                    DsCard(
                      key: Key('plan_card_$p'),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: Column(children: [
                        for (final f in features)
                          DsSwitchRow(
                            key: Key('plan_${p}_${f['id']}'),
                            label: f['label']?.toString() ?? '',
                            subtitle: f['desc']?.toString(),
                            value: (plans[p]['features'] as Map)[f['id']] != false,
                            onChanged: (v) => setState(() => (plans[p]['features'] as Map)[f['id'].toString()] = v),
                          ),
                        for (final l in limits)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(children: [
                              Expanded(child: Text('${l['label']} (${l['min']} to ${l['max']})', style: AppText.body)),
                              SizedBox(
                                width: 84,
                                child: TextFormField(
                                  key: Key('plan_${p}_${l['id']}'),
                                  initialValue: '${(plans[p]['limits'] as Map)[l['id']] ?? ''}',
                                  keyboardType: TextInputType.number,
                                  textAlign: TextAlign.end,
                                  onChanged: (v) {
                                    final n = int.tryParse(v.trim());
                                    if (n != null) (plans[p]['limits'] as Map)[l['id'].toString()] = n;
                                  },
                                ),
                              ),
                            ]),
                          ),
                      ]),
                    ),
                    const SizedBox(height: Space.s16),
                  ],
                  DsButton(key: const Key('plan_save'), label: _saving ? 'Saving…' : 'Save', onPressed: _saving ? null : _save),
                ],
              ),
      ),
    );
  }
}
