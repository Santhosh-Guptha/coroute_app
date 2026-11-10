import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

// The audit log of admin changes. Play payments policy (docs/features_355/play_payments_policy.md):
// plan prices, coupons and the payment gateway settings are managed in the web admin, not here.

// ======================================================================
// Audit
// ======================================================================

/// `GET /admin/audit?limit=`: who changed what (staff only).
class AdminAuditTab extends StatefulWidget {
  const AdminAuditTab({super.key});

  @override
  State<AdminAuditTab> createState() => _AdminAuditTabState();
}

class _AdminAuditTabState extends State<AdminAuditTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _loaded = false;
  String? _error;
  String _q = '';
  int _limit = 200;

  @override
  bool get wantKeepAlive => true;

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
      final res = await context.read<ApiClient>().get('/admin/audit?limit=$_limit');
      _rows = adminMapList(res is Map ? (res['entries'] ?? res['audit'] ?? res['items']) : res);
      _rows.sort((a, b) => adminEpoch(b['at']).compareTo(adminEpoch(a['at'])));
      _loaded = true;
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  static String _details(Object? d) {
    if (d == null) return '';
    if (d is Map) {
      return d.entries
          .where((e) => !RegExp('secret|password|token', caseSensitive: false).hasMatch(e.key.toString()))
          .map((e) => '${e.key}: ${e.value is Map || e.value is List ? '…' : e.value}')
          .join(', ');
    }
    return d.toString();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final q = _q.trim().toLowerCase();
    final visible = q.isEmpty
        ? _rows
        : _rows.where((r) => ['by', 'action', 'target'].any((k) => (r[k]?.toString() ?? '').toLowerCase().contains(q)) || _details(r['details']).toLowerCase().contains(q)).toList();
    return AdminTabBody(
      loading: _loading,
      hasData: _loaded,
      error: _error,
      onRefresh: _load,
      children: [
        const SizedBox(height: 4),
        AdminSearchRow(hint: 'Search action, admin, target', onChanged: (v) => setState(() => _q = v)),
        const SizedBox(height: 12),
        AdminTable(
          title: 'Audit log (${visible.length})',
          rows: [
            for (var i = 0; i < visible.length; i++)
              AdminRow(
                leading: const AdminRowIcon(Icons.fact_check_outlined),
                title: adminCapitalize((visible[i]['action']?.toString() ?? 'change').replaceAll('_', ' ')),
                subtitle: '${visible[i]['by'] ?? 'system'} · ${adminDate(visible[i]['at'], time: true)}',
                detail: [
                  if ((visible[i]['target']?.toString() ?? '').isNotEmpty) visible[i]['target'].toString(),
                  _details(visible[i]['details']),
                ].where((s) => s.isNotEmpty).join(' · '),
                divider: i < visible.length - 1,
              ),
          ],
          empty: Text('Nothing logged yet.', style: AppText.caption),
        ),
        if (_rows.length >= _limit) ...[
          const SizedBox(height: 12),
          Center(
            child: OutlinedButton(
              onPressed: _loading
                  ? null
                  : () {
                      _limit += 200;
                      _load();
                    },
              child: const Text('Load older entries'),
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}
