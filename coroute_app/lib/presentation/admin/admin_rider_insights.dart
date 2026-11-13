import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

/// "12" for whole numbers, "12.5" otherwise.
String adminCount(Object? v) {
  final n = adminNumOrNull(v) ?? 0;
  return n == n.roundToDouble() ? '${n.toInt()}' : n.toStringAsFixed(1);
}

/// "3 h 20 min" style text for a number of hours.
String adminHours(Object? v) {
  final h = (adminNumOrNull(v) ?? 0).toDouble();
  return formatDuration(Duration(minutes: (h * 60).round()));
}

/// "today", "3 days ago" or the date; "never" for 0.
String adminSeen(Object? ms) {
  final t = adminEpoch(ms);
  if (t <= 0) return 'Never';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t));
  if (d.inHours < 24) return 'Today';
  if (d.inDays < 30) return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'} ago';
  return adminDate(t);
}

/// One rider's numbers and settings for the admin (inside the user details):
/// riding totals, SOS, plan and access (change plan, trip limit, role),
/// devices and the recent admin changes (no payments: they are in the web admin). Data from
/// `/admin/analytics/riders/:userId`; changes go to `PATCH /admin/users/:userId/config`
/// (every change is written to the audit log by the server).
class AdminRiderInsights extends StatefulWidget {
  final String userId;

  /// Called after a change was saved (the details screen reloads).
  final VoidCallback? onChanged;

  /// True for the signed-in admin's own account (role cannot be changed here).
  final bool isSelf;

  const AdminRiderInsights({super.key, required this.userId, this.onChanged, this.isSelf = false});

  @override
  State<AdminRiderInsights> createState() => _AdminRiderInsightsState();
}

class _AdminRiderInsightsState extends State<AdminRiderInsights> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _saving = false;
  String? _error;

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
    Map<String, dynamic>? data;
    try {
      final res = await context.read<ApiClient>().get('/admin/analytics/riders/${Uri.encodeComponent(widget.userId)}', timeout: const Duration(seconds: 20));
      if (res is Map && res['stats'] is Map) data = Map<String, dynamic>.from(res);
    } catch (e) {
      error = adminErrorOf(e);
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
      if (data != null) _data = data;
    });
  }

  Map<String, dynamic> _map(String k) {
    final v = _data?[k];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  Future<void> _patch(Map<String, dynamic> body, String done) async {
    setState(() => _saving = true);
    try {
      await context.read<ApiClient>().patch('/admin/users/${Uri.encodeComponent(widget.userId)}/config', body);
      if (!mounted) return;
      adminSnack(context, done);
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _changePlan() async {
    final plan = _map('plan');
    final result = await showAppDialog<Map<String, dynamic>>(
      context, // round 7: app motion (spring scale + fade, reduce-motion aware)
      builder: (_) => _PlanDialog(currentTier: plan['tier']?.toString() ?? 'community'),
    );
    if (result == null || !mounted) return;
    await _patch({'plan': result}, result['tier'] == 'community' ? 'Plan removed. The rider is on Community now.' : 'Plan saved.');
  }

  Future<void> _tripLimit() async {
    final limits = _map('limits');
    final current = adminNumOrNull(limits['maxTrips']);
    final dflt = adminCount(limits['defaultMaxTrips']);
    final text = await adminAskText(
      context,
      title: 'Saved trip limit',
      message: 'How many trips this rider can keep. Leave empty for the default ($dflt).',
      label: 'Trips',
      hint: current == null ? dflt : adminCount(current),
      confirmLabel: 'Save',
      validator: (t) {
        if (t.isEmpty) return null;
        final n = int.tryParse(t);
        return n == null || n < 0 || n > 5000 ? 'Enter a number from 0 to 5000.' : null;
      },
    );
    if (text == null || !mounted) return;
    await _patch({
      'limits': {'maxTrips': text.isEmpty ? null : int.parse(text)},
    }, text.isEmpty ? 'Trip limit set back to the default.' : 'Trip limit saved.');
  }

  Future<void> _toggleRole(bool isAdmin) async {
    final ok = await confirmAction(
      context,
      title: isAdmin ? 'Remove admin access?' : 'Make this rider an admin?',
      message: isAdmin
          ? 'They lose access to the admin console at once.'
          : 'Admins see every rider, ride and emergency, and can change plans and accounts.',
      confirmLabel: isAdmin ? 'Remove admin' : 'Make admin',
      destructive: !isAdmin,
    );
    if (!ok || !mounted) return;
    await _patch({'role': isAdmin ? 'RIDER' : 'MASTER_ADMIN'}, isAdmin ? 'Admin access removed.' : 'Admin access given.');
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      final e = _error;
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: AdminCard(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _loading ? 'Loading riding numbers...' : (e ?? 'No riding numbers yet.'),
                  style: AppText.body.copyWith(color: AppTheme.text2),
                ),
              ),
              if (!_loading && e != null) TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final stats = _map('stats');
    final rider = _map('rider');
    final plan = _map('plan');
    final limits = _map('limits');
    final membership = plan['membership'] is Map ? Map<String, dynamic>.from(plan['membership'] as Map) : null;
    final devices = adminMapList(data['devices']);
    final audit = adminMapList(data['audit']);
    final isAdmin = rider['role']?.toString() == 'MASTER_ADMIN';
    final sos = adminNum(stats, 'sos');
    final falseAlarms = adminNum(stats, 'falseAlarms');
    final tier = adminPlanIdOf(plan['tier']?.toString());
    final planName = plan['name']?.toString() ?? '';
    final legacyTier = plan['legacyTier']?.toString() ?? '';
    final validUntil = adminEpoch(plan['validUntil']);
    final maxTrips = adminNumOrNull(limits['maxTrips']);
    final bikeLine = adminBikeLine(rider['bike']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading || _saving) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(minHeight: 2)),
        AdminSectionLabel('Riding', trailing: Text('Last seen ${adminSeen(rider['lastSeenAt']).toLowerCase()}', style: AppText.caption)),
        AdminKpiGrid(
          minTileWidth: 130,
          tiles: [
            AdminKpiTile(label: 'Trips', value: adminCount(stats['trips']), delta: '${adminCount(stats['groups'])} group rides'),
            AdminKpiTile(label: 'Distance', value: '${adminCount(stats['km'])} km', delta: 'Top ${adminCount(stats['topSpeedKmh'])} km/h'),
            AdminKpiTile(label: 'Riding time', value: adminHours(stats['ridingHours']), delta: 'Avg ${adminCount(stats['avgSpeedKmh'])} km/h'),
            AdminKpiTile(
              label: 'SOS',
              value: adminCount(sos),
              valueColor: adminNum(stats, 'sosOpen') > 0 ? AppTheme.sos : null,
              delta: falseAlarms > 0 ? '${adminCount(falseAlarms)} false alarms' : (sos > 0 ? 'No false alarms' : 'None raised'),
            ),
          ],
        ),
        // 3.55: the bike the rider's app shared (engine care and fuel analysis).
        if (bikeLine != null) ...[
          const SizedBox(height: 12),
          AdminCard(child: AdminDetailLine('Bike', bikeLine)),
        ],
        const AdminSectionLabel('Plan and access'),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdminDetailLine(
                'Plan',
                tier == 'community'
                    ? 'Community (free)'
                    : '${planName.isNotEmpty ? planName : adminTierLabel(tier)}${legacyTier.isNotEmpty ? ' (legacy ${adminTierLabel(legacyTier).replaceFirst('Legacy: ', '')})' : ''} until ${adminDate(validUntil)}',
              ),
              if (membership != null)
                AdminDetailLine(
                  'Membership',
                  '${membership['name']?.toString() ?? membership['category']?.toString() ?? ''}, ${adminCapitalize((membership['status']?.toString() ?? '').toLowerCase())} until ${adminDate(membership['validUntil'])}',
                ),
              AdminDetailLine('Role', isAdmin ? 'Admin' : 'Rider'),
              AdminDetailLine('Trip limit', maxTrips == null ? 'Default (${adminCount(limits['defaultMaxTrips'])})' : adminCount(maxTrips)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _changePlan,
                    icon: const Icon(Icons.workspace_premium_rounded, size: 18),
                    label: const Text('Change plan'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _tripLimit,
                    icon: const Icon(Icons.archive_outlined, size: 18),
                    label: const Text('Trip limit'),
                  ),
                  if (!widget.isSelf)
                    OutlinedButton.icon(
                      onPressed: _saving ? null : () => _toggleRole(isAdmin),
                      icon: Icon(isAdmin ? Icons.person_outline_rounded : Icons.admin_panel_settings_rounded, size: 18),
                      label: Text(isAdmin ? 'Remove admin' : 'Make admin'),
                    ),
                ],
              ),
            ],
          ),
        ),
        AdminSectionLabel('Devices (${devices.length})'),
        AdminTable(
          empty: Text('No device reports.', style: AppText.body.copyWith(color: AppTheme.text2)),
          rows: [
            for (var i = 0; i < devices.length; i++)
              AdminRow(
                leading: const AdminRowIcon(Icons.phone_android_rounded),
                title: '${devices[i]['manufacturer'] ?? ''} ${devices[i]['model'] ?? ''}'.trim(),
                subtitle: [
                  if ((devices[i]['os']?.toString() ?? '').isNotEmpty) 'Android ${devices[i]['os']}',
                  if ((devices[i]['appVersion']?.toString() ?? '').isNotEmpty) 'app ${devices[i]['appVersion']}',
                ].join(', '),
                detail: '${devices[i]['result'] ?? ''} · ${adminDate(devices[i]['reportedAt'])}',
                divider: i < devices.length - 1,
              ),
          ],
        ),
        if (audit.isNotEmpty) ...[
          const AdminSectionLabel('Admin changes'),
          AdminTable(
            rows: [
              for (var i = 0; i < audit.length; i++)
                AdminRow(
                  leading: const AdminRowIcon(Icons.history_rounded),
                  title: _auditLabel(audit[i]['action']?.toString() ?? ''),
                  subtitle: '${audit[i]['by'] ?? 'admin'}, ${adminDate(audit[i]['at'], time: true)}',
                  divider: i < audit.length - 1,
                ),
            ],
          ),
        ],
      ],
    );
  }

  static String _auditLabel(String action) {
    switch (action) {
      case 'user.role':
        return 'Role changed';
      case 'user.status':
        return 'Account status changed';
      case 'user.limits':
        return 'Trip limit changed';
      case 'subscription.grant':
        return 'Plan given';
      case 'subscription.revoke':
        return 'Plan removed';
      default:
        return action;
    }
  }
}

/// Plan picker: the tier and, for a paid tier, how many days.
class _PlanDialog extends StatefulWidget {
  final String currentTier;

  const _PlanDialog({required this.currentTier});

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  /// 3.55: the plans riders have. The rider gets a real membership, so their app shows it at once.
  static const List<String> _tiers = ['community', ...adminGroupPlanIds];
  late String _tier = _tiers.contains(widget.currentTier) ? widget.currentTier : adminPlanIdOf(widget.currentTier);
  final TextEditingController _days = TextEditingController(text: '30');
  final TextEditingController _note = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _days.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (_tier == 'community') {
      Navigator.pop(context, <String, dynamic>{'tier': 'community', 'note': _note.text.trim()});
      return;
    }
    final days = int.tryParse(_days.text.trim());
    if (days == null || days < 1 || days > 3660) {
      setState(() => _problem = 'Enter 1 to 3660 days.');
      return;
    }
    Navigator.pop(context, <String, dynamic>{'tier': _tier, 'days': days, 'note': _note.text.trim()});
  }

  @override
  Widget build(BuildContext context) {
    final p = _problem;
    return AlertDialog(
      title: const Text('Change plan'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _tier,
              decoration: adminInput('Plan'),
              items: [
                for (final t in _tiers) DropdownMenuItem<String>(value: t, child: Text(t == 'community' ? 'Community (free)' : adminTierLabel(t))),
              ],
              onChanged: (v) => setState(() => _tier = v ?? 'community'),
            ),
            if (_tier != 'community') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _days,
                keyboardType: TextInputType.number,
                decoration: adminInput('Days', helper: 'Adds to the time left when the rider already has this plan.'),
              ),
            ],
            const SizedBox(height: 12),
            TextField(controller: _note, decoration: adminInput('Note (optional)', hint: 'Why')),
            if (p != null) ...[
              const SizedBox(height: 8),
              Text(p, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

/// "Classic 350 · 349 cc · Air/oil-cooled · Black · 13 L tank · 35 km/L" from the rider
/// detail's `bike` block (3.55); null when the rider shared no bike (or an older gateway).
String? adminBikeLine(Object? raw) {
  if (raw is! Map) return null;
  num n(String k) => raw[k] is num ? raw[k] as num : 0;
  String fmt(num v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  const cooling = {'air': 'Air-cooled', 'oil': 'Air/oil-cooled', 'liquid': 'Liquid-cooled'};
  final parts = <String>[
    if ((raw['model'] ?? '').toString().trim().isNotEmpty) raw['model'].toString().trim(),
    if (n('cc') > 0) '${fmt(n('cc'))} cc',
    ?cooling[raw['cooling']],
    if ((raw['colour'] ?? '').toString().trim().isNotEmpty) raw['colour'].toString().trim(),
    if (n('tankL') > 0) '${fmt(n('tankL'))} L tank',
    if (n('mileageKmL') > 0) '${fmt(n('mileageKmL'))} km/L',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
