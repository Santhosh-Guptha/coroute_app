import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/convoy_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/convoy_service.dart';
import 'admin_convoy_inspector.dart';
import 'admin_emergencies_panel.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_rider_insights.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// Master admin: safety. Every open SOS and crash (the Emergencies panel with
/// its alarm), riders with repeated false alarms (with reset), and the safety
/// broadcast to every live ride. Data from `/admin/emergencies` and
/// `/admin/safety`. Pull down to refresh.
class AdminSafetyScreen extends StatefulWidget {
  /// The emergency alarm sound; tests pass a fake.
  final AdminAlarm? alarm;

  const AdminSafetyScreen({super.key, this.alarm});

  @override
  State<AdminSafetyScreen> createState() => _AdminSafetyScreenState();
}

class _AdminSafetyScreenState extends State<AdminSafetyScreen> {
  final GlobalKey<AdminEmergenciesPanelState> _panel = GlobalKey<AdminEmergenciesPanelState>();
  List<Map<String, dynamic>> _falseAlarmUsers = [];
  int _incidents = 0;
  bool _loading = true;
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ConvoyService>().startAdminFleetWatch();
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    String? error;
    try {
      final res = await context.read<ApiClient>().get('/admin/safety', timeout: const Duration(seconds: 20));
      if (res is Map) {
        _falseAlarmUsers = adminMapList(res['falseAlarmUsers']);
        final inc = res['incidents'];
        _incidents = inc is List ? inc.length : 0;
        _loaded = true;
      }
    } catch (e) {
      error = adminErrorOf(e);
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
    });
  }

  Future<void> _refresh() async {
    await Future.wait([_load(), _panel.currentState?.reload() ?? Future<void>.value()]);
  }

  Future<void> _reset(Map<String, dynamic> u) async {
    final name = (u['name']?.toString() ?? '').trim();
    final ok = await confirmAction(
      context,
      title: 'Reset false alarms?',
      message: 'Clears the false-alarm count of ${name.isEmpty ? 'this rider' : name}. Their SOS is no longer slowed down.',
      confirmLabel: 'Reset',
    );
    if (!ok || !mounted) return;
    try {
      await context.read<ApiClient>().post('/admin/users/${Uri.encodeComponent(u['userId']?.toString() ?? '')}/false-alarms/reset', {});
      if (!mounted) return;
      adminSnack(context, 'False alarms reset.');
      await _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  Future<void> _broadcast() async {
    final convoys = context.read<ConvoyService>();
    final msg = await adminAskText(
      context,
      title: 'Safety broadcast',
      message: 'Every rider in a live ride sees this alert on their map right away.',
      label: 'Message',
      hint: 'Heavy rain on NH 48. Slow down and regroup.',
      confirmLabel: 'Send to all live rides',
      validator: (t) => t.isEmpty ? 'Write the message.' : (t.length > 300 ? 'Keep it under 300 characters.' : null),
    );
    if (msg == null || msg.isEmpty || !mounted) return;
    await convoys.adminBroadcastSafetyAlert(msg);
    if (mounted) adminSnack(context, 'Safety alert sent to every live ride.');
  }

  void _openConvoy(ConvoyModel convoy) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => AdminConvoyInspector(convoy: convoy)));

  @override
  Widget build(BuildContext context) {
    final e = _error;
    return AdminShell(
      title: 'Safety',
      subtitle: 'Emergencies and false alarms',
      actions: [
        AdminIconAction(icon: Icons.campaign_rounded, label: 'Safety broadcast', onTap: _broadcast),
        AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _refresh),
      ],
      nav: adminNavItems(context, AdminSection.safety),
      body: LoadingState(
        loading: _loading,
        child: adminRefresh(
          onRefresh: _refresh,
          child: LayoutBuilder(builder: (context, c) {
            final wide = c.maxWidth >= adminWideBreakpoint;
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                AdminContent(
                  wide: wide,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AdminEmergenciesPanel(key: _panel, alarm: widget.alarm ?? const NotifierAdminAlarm(), onOpenConvoy: _openConvoy),
                      if (_incidents > 0) ...[
                        const SizedBox(height: 12),
                        StatusLine(icon: Icons.groups_rounded, text: 'Nearby help is working on ${adminCount(_incidents)} ${_incidents == 1 ? 'incident' : 'incidents'}.'),
                      ],
                      AdminSectionLabel('False alarms, last 30 days (${_falseAlarmUsers.length})'),
                      AdminTable(
                        empty: Text(
                          !_loaded && e != null ? e : 'No rider has false alarms.',
                          style: AppText.body.copyWith(color: AppTheme.text2),
                        ),
                        rows: [
                          for (var i = 0; i < _falseAlarmUsers.length; i++) _falseAlarmRow(_falseAlarmUsers[i], last: i == _falseAlarmUsers.length - 1),
                        ],
                      ),
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

  Widget _falseAlarmRow(Map<String, dynamic> u, {required bool last}) {
    final name = (u['name']?.toString() ?? '').trim();
    final throttled = u['throttled'] == true;
    return AdminRow(
      leading: RiderAvatar(name: name.isEmpty ? '?' : name),
      title: name.isEmpty ? 'Rider' : name,
      subtitle: '${adminCount(u['count30d'])} false alarms, last ${adminDate(u['lastAt'], time: true)}',
      status: throttled ? StatusLine(icon: Icons.speed_rounded, text: 'SOS slowed down', color: AppTheme.warnText) : null,
      trailing: TextButton(onPressed: () => _reset(u), child: const Text('Reset')),
      divider: !last,
    );
  }
}
