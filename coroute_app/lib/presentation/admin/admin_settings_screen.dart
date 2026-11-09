import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../auth/access_gate_screen.dart';
import '../subscription/membership_dashboard_screen.dart';
import 'admin_config_tabs.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';
import 'master_admin_dashboard.dart';

/// Master admin: settings. What the public website shows (community numbers,
/// longest trips, anonymous labels), the payment gateway and the audit log,
/// the rider view of plans, the membership repair tool and sign out.
/// Website settings come from `/admin/community-stats/config`.
class AdminSettingsScreen extends StatefulWidget {
  const AdminSettingsScreen({super.key});

  @override
  State<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends State<AdminSettingsScreen> {
  final TextEditingController _labelPrefix = TextEditingController();
  bool _showPublicStats = true;
  bool _showLongestTrips = true;
  bool _showAnonymousLabels = true;
  bool _loading = true;
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _labelPrefix.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    String? error;
    try {
      final res = await context.read<ApiClient>().get('/admin/community-stats/config');
      final c = res is Map && res['config'] is Map ? Map<String, dynamic>.from(res['config'] as Map) : null;
      if (c != null) {
        _showPublicStats = c['showPublicStats'] != false;
        _showLongestTrips = c['showLongestTrips'] != false;
        _showAnonymousLabels = c['showAnonymousLabels'] != false;
        _labelPrefix.text = c['labelPrefix']?.toString() ?? 'Rider';
        _loaded = true;
        _dirty = false;
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

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<ApiClient>().put('/admin/community-stats/config', {
        'showPublicStats': _showPublicStats,
        'showLongestTrips': _showLongestTrips,
        'showAnonymousLabels': _showAnonymousLabels,
        'labelPrefix': _labelPrefix.text.trim().isEmpty ? 'Rider' : _labelPrefix.text.trim(),
      });
      if (!mounted) return;
      setState(() => _dirty = false);
      adminSnack(context, 'Website settings saved.');
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _reconcile() async {
    final ok = await confirmAction(
      context,
      title: 'Repair memberships?',
      message: 'Merges duplicate memberships and marks orders that were paid but not linked. Safe to run more than once.',
      confirmLabel: 'Repair',
    );
    if (!ok || !mounted) return;
    try {
      await context.read<ApiClient>().post('/admin/membership/reconcile', {});
      if (mounted) adminSnack(context, 'Memberships checked and repaired.');
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  Future<void> _signOut() async {
    await context.read<AuthService>().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => const AccessGateScreen()), (_) => false);
  }

  void _push(Widget screen) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

  void _set(void Function() change) => setState(() {
        change();
        _dirty = true;
      });

  @override
  Widget build(BuildContext context) {
    final e = _error;
    return AdminShell(
      title: 'Settings',
      subtitle: 'Website, payments and tools',
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      nav: adminNavItems(context, AdminPage.settings),
      tabs: adminSectionTabs(context, AdminPage.settings),
      body: LoadingState(
        loading: _loading,
        child: adminRefresh(
          onRefresh: _load,
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
                      const AdminSectionLabel('Public website'),
                      AdminCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!_loaded && e != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(e, style: AppText.body.copyWith(color: AppTheme.sos)),
                              ),
                            DsSwitchRow(
                              label: 'Show community numbers',
                              subtitle: 'Riders, rides and kilometres on the website. Totals only, no names.',
                              value: _showPublicStats,
                              onChanged: _loaded ? (v) => _set(() => _showPublicStats = v) : null,
                            ),
                            DsSwitchRow(
                              label: 'Show longest trips',
                              value: _showLongestTrips,
                              onChanged: _loaded ? (v) => _set(() => _showLongestTrips = v) : null,
                            ),
                            DsSwitchRow(
                              label: 'Anonymous rider labels',
                              subtitle: 'Shows "${_labelPrefix.text.trim().isEmpty ? 'Rider' : _labelPrefix.text.trim()} #1" instead of a name.',
                              value: _showAnonymousLabels,
                              onChanged: _loaded ? (v) => _set(() => _showAnonymousLabels = v) : null,
                              divider: false,
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: _labelPrefix,
                              enabled: _loaded,
                              maxLength: 30,
                              onChanged: (_) => _set(() {}),
                              decoration: adminInput('Label word', hint: 'Rider'),
                            ),
                            const SizedBox(height: 8),
                            DsButton(
                              label: _saving ? 'Saving...' : 'Save website settings',
                              icon: Icons.save_outlined,
                              onPressed: _loaded && _dirty && !_saving ? _save : null,
                            ),
                          ],
                        ),
                      ),
                      const AdminSectionLabel('Payments'),
                      AdminTable(
                        rows: [
                          AdminRow(
                            leading: const AdminRowIcon(Icons.account_balance_wallet_outlined),
                            title: 'Payment gateway',
                            subtitle: 'Razorpay keys, test or live mode',
                            onTap: () => _push(const _SettingsPage(title: 'Payment gateway', subtitle: 'Razorpay keys, test or live mode', child: AdminGatewayTab())),
                          ),
                          AdminRow(
                            leading: const AdminRowIcon(Icons.fact_check_outlined),
                            title: 'Audit log',
                            subtitle: 'Every admin change',
                            onTap: () => _push(const _SettingsPage(title: 'Audit log', subtitle: 'Every admin change', child: AdminAuditTab())),
                          ),
                          AdminRow(
                            leading: const AdminRowIcon(Icons.preview_rounded),
                            title: 'Rider view of plans',
                            subtitle: 'What riders see when they pick a plan',
                            onTap: () => _push(const MembershipDashboardScreen()),
                            divider: false,
                          ),
                        ],
                      ),
                      const AdminSectionLabel('Tools'),
                      AdminTable(
                        rows: [
                          AdminRow(
                            leading: const AdminRowIcon(Icons.build_outlined),
                            title: 'Repair memberships',
                            subtitle: 'Fix duplicate or unlinked memberships',
                            onTap: _reconcile,
                          ),
                          AdminRow(
                            leading: AdminRowIcon(Icons.logout_rounded, color: AppTheme.sos),
                            title: 'Sign out',
                            onTap: _signOut,
                            divider: false,
                          ),
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
}

/// One settings page (payment gateway, audit log) in the console frame, with a back button.
class _SettingsPage extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SettingsPage({required this.title, required this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      title: title,
      subtitle: subtitle,
      onBack: () => Navigator.maybePop(context),
      nav: adminNavItems(context, AdminPage.settings),
      body: child,
    );
  }
}
