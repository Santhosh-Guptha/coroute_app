import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/plan_subscription_service.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

// Pricing, Gateway and Audit tabs of "Payments & Plans".

// ======================================================================
// Pricing
// ======================================================================

/// `GET/PUT /admin/subscription/pricing`: monthly and annual INR prices and
/// the label of each paid plan, checked (annual ≥ monthly) before sending.
class AdminPricingTab extends StatefulWidget {
  const AdminPricingTab({super.key});

  @override
  State<AdminPricingTab> createState() => _AdminPricingTabState();
}

class _PlanControllers {
  final TextEditingController label = TextEditingController();
  final TextEditingController monthly = TextEditingController();
  final TextEditingController annual = TextEditingController();

  void dispose() {
    label.dispose();
    monthly.dispose();
    annual.dispose();
  }
}

class _AdminPricingTabState extends State<AdminPricingTab> with AutomaticKeepAliveClientMixin {
  final Map<String, _PlanControllers> _form = {for (final t in adminPaidTierNames) t: _PlanControllers()};
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;
  bool _loaded = false;
  bool _saving = false;
  String? _error;
  String? _problem;
  int _updatedAt = 0;
  String _updatedBy = '';
  final Map<String, TextEditingController> _memPrices = {
    'individual': TextEditingController(),
    'group_small': TextEditingController(),
    'group_large': TextEditingController(),
  };
  final Map<String, TextEditingController> _memCapacities = {
    'individual': TextEditingController(),
    'group_small': TextEditingController(),
    'group_large': TextEditingController(),
  };
  Map<String, dynamic>? _membershipAnalytics;
  bool _savingMembership = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _form.values) {
      c.dispose();
    }
    for (final c in _memPrices.values) {
      c.dispose();
    }
    for (final c in _memCapacities.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<ApiClient>().get('/admin/subscription/pricing');
      if (res is Map) {
        final plans = res['plans'] is Map ? Map<String, dynamic>.from(res['plans'] as Map) : <String, dynamic>{};
        for (final t in adminPaidTierNames) {
          final p = plans[t] is Map ? plans[t] as Map : const {};
          final c = _form[t]!;
          c.label.text = p['label']?.toString() ?? adminTierLabel(t);
          c.monthly.text = adminNumOrNull(p['monthly'])?.toInt().toString() ?? '';
          c.annual.text = adminNumOrNull(p['annual'])?.toInt().toString() ?? '';
        }
        _history = adminMapList(res['history']);
        _updatedAt = adminEpoch(res['updatedAt']);
        _updatedBy = res['updatedBy']?.toString() ?? '';
      }
      try {
        final api = context.read<ApiClient>();
        final memRes = await api.get('/admin/membership/catalog');
        if (memRes is Map) {
          final catsRaw = memRes['catalog'] ?? memRes['categories'];
          final Iterable<dynamic> catList = (catsRaw is Map)
              ? catsRaw.values
              : (catsRaw is List ? catsRaw : const []);
          for (final cat in catList) {
            if (cat is Map) {
              final id = cat['id']?.toString();
              if (id != null) {
                final price = (cat['monthlyPriceInr'] as num?)?.toInt() ??
                    (cat['priceRupees'] as num?)?.toInt();
                if (price != null) {
                  _memPrices[id]?.text = price.toString();
                }
                final cap = (cat['capacity'] as num?)?.toInt();
                if (cap != null) {
                  _memCapacities[id]?.text = cap.toString();
                }
              }
            }
          }
        }
        final analyticsRes = await api.get('/admin/membership/analytics');
        if (analyticsRes is Map) {
          _membershipAnalytics = Map<String, dynamic>.from(analyticsRes);
        }
      } catch (e) {
        debugPrint('[AdminPricingTab] membership load error: $e');
      }
      _loaded = true;
      _problem = null;
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, PlanPriceDraft> get _drafts => {
        for (final e in _form.entries) e.key: (monthly: e.value.monthly.text, annual: e.value.annual.text),
      };

  Future<void> _save() async {
    final drafts = _drafts;
    final problem = validatePlanPricing(drafts);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    final plans = planPricingPayload(drafts, {
      for (final e in _form.entries)
        if (e.value.label.text.trim().isNotEmpty) e.key: e.value.label.text.trim(),
    });
    final ok = await confirmAction(
      context,
      title: 'Publish new prices?',
      message: 'New orders in the app and on the website use these prices right away. Active plans keep what they paid.',
      confirmLabel: 'Publish',
    );
    if (!ok || !mounted) return;
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      final res = await context.read<ApiClient>().put('/admin/subscription/pricing', {'plans': plans});
      if (!mounted) return;
      final saved = res is Map && res['plans'] is Map ? Map<String, dynamic>.from(res['plans'] as Map) : plans;
      // This admin's own app shows the new prices at once.
      context.read<PlanSubscriptionService?>()?.applyConfiguredPlans(saved);
      adminSnack(context, 'Prices published.');
      _load();
    } catch (e) {
      if (mounted) setState(() => _problem = adminErrorOf(e));
    }
    if (mounted) setState(() => _saving = false);
  }

  String _historyLine(Map<String, dynamic> h) {
    final prices = h['prices'] is Map ? h['prices'] as Map : const {};
    return [
      for (final t in adminPaidTierNames)
        if (prices[t] is Map)
          '${adminTierLabel(t)} ${adminInr(adminNumOrNull((prices[t] as Map)['monthly']))}/${adminInr(adminNumOrNull((prices[t] as Map)['annual']))}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = _problem;
    return AdminTabBody(
      loading: _loading,
      hasData: _loaded,
      error: _error,
      onRefresh: _load,
      children: [
        const SizedBox(height: 4),
        AdminTitledCard(
          title: 'Plan prices (INR)',
          trailing: _updatedAt > 0 ? Text('Saved ${adminDate(_updatedAt, time: true)}', style: AppText.caption) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Community is always free. A year must cost at least as much as a month; riders see the annual saving in the app.',
                style: AppText.caption,
              ),
              if (_updatedBy.isNotEmpty) Text('Last change by $_updatedBy', style: AppText.caption),
              for (final t in adminPaidTierNames) ...[
                const SizedBox(height: 16),
                _priceRow(t, _form[t]!),
              ],
              if (p != null) ...[
                const SizedBox(height: 12),
                Text(p, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w700)),
              ],
              const SizedBox(height: 16),
              DsButton(label: _saving ? 'Publishing…' : 'Publish prices', icon: Icons.publish_rounded, onPressed: _saving ? null : _save),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _buildMembershipSection(),
        if (_membershipAnalytics != null) ...[
          const SizedBox(height: 20),
          _buildMembershipAnalytics(),
        ],
        if (_history.isNotEmpty) ...[
          const SizedBox(height: 16),
          AdminTable(
            title: 'Price history',
            rows: [
              for (var i = 0; i < _history.length; i++)
                AdminRow(
                  leading: const AdminRowIcon(Icons.history_rounded),
                  title: adminDate(_history[i]['at'], time: true),
                  subtitle: _history[i]['by']?.toString() ?? '',
                  detail: _historyLine(_history[i]),
                  divider: i < _history.length - 1,
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _saveMembership() async {
    setState(() => _savingMembership = true);
    try {
      final categories = [
        {
          'id': 'individual',
          'name': 'Individual',
          'priceRupees': int.tryParse(_memPrices['individual']?.text ?? '9') ?? 9,
          'capacity': int.tryParse(_memCapacities['individual']?.text ?? '1') ?? 1,
          'description': 'Solo rider safety, personal navigation, tracking & profile',
          'features': ['Solo Ride Tracking', 'Essential Safety', 'Basic Navigation', 'Emergency Alert Routing'],
        },
        {
          'id': 'group_small',
          'name': 'Small Group',
          'priceRupees': int.tryParse(_memPrices['group_small']?.text ?? '49') ?? 49,
          'capacity': int.tryParse(_memCapacities['group_small']?.text ?? '6') ?? 6,
          'description': 'Convoy tracking, live group safety coordination & PTT for up to 6 riders',
          'features': ['Convoy & Group Tracking', 'Up to 6 Group Members', 'Shared Trip Coordination', 'PTT & Intercom Access', 'Safety Escalations'],
        },
        {
          'id': 'group_large',
          'name': 'Large Group',
          'priceRupees': int.tryParse(_memPrices['group_large']?.text ?? '99') ?? 99,
          'capacity': int.tryParse(_memCapacities['group_large']?.text ?? '12') ?? 12,
          'description': 'Convoy tracking, live group safety coordination & PTT for up to 12 riders',
          'features': ['Convoy & Group Tracking', 'Up to 12 Group Members', 'Shared Trip Coordination', 'PTT & Intercom Access', 'Safety Escalations'],
        },
      ];
      await context.read<ApiClient>().put('/admin/membership/catalog', {'catalog': categories, 'categories': categories});
      if (mounted) adminSnack(context, 'Membership catalog updated successfully.');
      _load();
    } catch (e) {
      if (mounted) adminSnack(context, 'Failed to update membership catalog.', error: true);
    } finally {
      if (mounted) setState(() => _savingMembership = false);
    }
  }

  Widget _buildMembershipSection() {
    return AdminTitledCard(
      title: 'CoRoute Membership & Group Seat Capacities',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Configurable pricing and capacities for Individual and Group memberships. The owner purchases the capacity, not individual seats.',
            style: AppText.caption,
          ),
          const SizedBox(height: 16),
          _memCategoryRow('individual', 'Individual (Solo Rider)', _memPrices['individual']!, _memCapacities['individual']!, fixedCapacity: 1),
          const SizedBox(height: 16),
          _memCategoryRow('group_small', 'Small Group', _memPrices['group_small']!, _memCapacities['group_small']!),
          const SizedBox(height: 16),
          _memCategoryRow('group_large', 'Large Group', _memPrices['group_large']!, _memCapacities['group_large']!),
          const SizedBox(height: 16),
          DsButton(
            label: _savingMembership ? 'Saving...' : 'Save Membership Catalog',
            icon: Icons.save_rounded,
            onPressed: _savingMembership ? null : _saveMembership,
          ),
        ],
      ),
    );
  }

  Widget _memCategoryRow(String id, String title, TextEditingController priceCtrl, TextEditingController capCtrl, {int? fixedCapacity}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: priceCtrl,
                keyboardType: TextInputType.number,
                decoration: adminInput('Price INR', prefix: 'INR '),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: capCtrl,
                readOnly: fixedCapacity != null,
                keyboardType: TextInputType.number,
                decoration: adminInput(fixedCapacity != null ? 'Capacity (Fixed)' : 'Max Capacity', prefix: 'Riders: '),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMembershipAnalytics() {
    final a = _membershipAnalytics;
    if (a == null) return const SizedBox.shrink();
    return AdminTitledCard(
      title: 'Privacy-Safe Membership & Trip Analytics',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Zero raw GPS coordinates or location breadcrumbs are stored or exposed. Aggregate figures only.',
            style: AppText.caption.copyWith(color: AppTheme.accentText),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _analyticsTile('Active Memberships', '${a['activeMemberships'] ?? 0}', Icons.card_membership_rounded),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _analyticsTile('Total Capacity', '${a['totalCapacity'] ?? 0}', Icons.groups_rounded),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _analyticsTile('Occupied Seats', '${a['occupiedSeats'] ?? 0}', Icons.person_pin_rounded),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _analyticsTile('Active Convoys', '${a['activeConvoys'] ?? 0}', Icons.two_wheeler_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _analyticsTile(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: AppTheme.accentText),
              const SizedBox(width: 6),
              Expanded(child: Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11), overflow: TextOverflow.ellipsis)),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        ],
      ),
    );
  }

  Widget _priceRow(String tier, _PlanControllers c) {
    final m = num.tryParse(c.monthly.text.trim()) ?? 0;
    final a = num.tryParse(c.annual.text.trim()) ?? 0;
    final pct = PlanSubscriptionService.annualSavingPercent(m, a);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(adminTierLabel(tier), style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        TextField(controller: c.label, decoration: adminInput('Name shown to riders')),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c.monthly,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: adminInput('Monthly', prefix: '₹ '),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: c.annual,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: adminInput('Annual', prefix: '₹ '),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          a > 0 && m > 0 && a < m
              ? 'Annual is lower than monthly: fix before publishing.'
              : (pct > 0 ? 'Annual saves riders $pct% (${adminInr(PlanSubscriptionService.annualSaving(m, a))} a year).' : 'No annual saving.'),
          style: AppText.caption.copyWith(color: a > 0 && m > 0 && a < m ? AppTheme.sos : AppTheme.accentText, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

// ======================================================================
// Gateway
// ======================================================================

/// `GET/PUT /admin/payment-gateway` and `POST /admin/payment-gateway/test`.
/// Secrets are write-only: the screen only ever says "saved" or "not set".
class AdminGatewayTab extends StatefulWidget {
  const AdminGatewayTab({super.key});

  @override
  State<AdminGatewayTab> createState() => _AdminGatewayTabState();
}

class _KeyControllers {
  final TextEditingController keyId = TextEditingController();
  final TextEditingController keySecret = TextEditingController();
  final TextEditingController webhookSecret = TextEditingController();

  bool get isEmpty => keyId.text.trim().isEmpty && keySecret.text.trim().isEmpty && webhookSecret.text.trim().isEmpty;

  /// Only what was typed: blank keeps the saved value on the server.
  Map<String, String> toJson() => {
        if (keyId.text.trim().isNotEmpty) 'keyId': keyId.text.trim(),
        if (keySecret.text.trim().isNotEmpty) 'keySecret': keySecret.text.trim(),
        if (webhookSecret.text.trim().isNotEmpty) 'webhookSecret': webhookSecret.text.trim(),
      };

  void clear() {
    keyId.clear();
    keySecret.clear();
    webhookSecret.clear();
  }

  void dispose() {
    keyId.dispose();
    keySecret.dispose();
    webhookSecret.dispose();
  }
}

class _AdminGatewayTabState extends State<AdminGatewayTab> with AutomaticKeepAliveClientMixin {
  Map<String, dynamic>? _data;
  final Map<String, _KeyControllers> _keys = {'test': _KeyControllers(), 'live': _KeyControllers()};
  bool _loading = true;
  String? _error;
  String? _busy; // 'mode', 'save:test', 'test:live', …

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final k in _keys.values) {
      k.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await context.read<ApiClient>().get('/admin/payment-gateway');
      if (res is Map) _data = Map<String, dynamic>.from(res);
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _data != null) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _mode => (_data?['mode']?.toString() ?? 'test') == 'live' ? 'live' : 'test';

  Map<String, dynamic> _view(String mode) => _data?[mode] is Map ? Map<String, dynamic>.from(_data![mode] as Map) : const {};

  Future<void> _switchMode() async {
    final next = _mode == 'live' ? 'test' : 'live';
    if (next == 'live') {
      final live = _view('live');
      if ((live['keyId']?.toString() ?? '').isEmpty || live['keySecretSet'] != true) {
        adminSnack(context, 'Save the live key id and key secret first.', error: true);
        return;
      }
      final typed = await adminAskText(
        context,
        title: 'Switch to LIVE payments?',
        message: 'Riders will pay real money through Razorpay from now on. Type LIVE to confirm.',
        label: 'Type LIVE',
        confirmLabel: 'Switch to LIVE',
        destructive: true,
        validator: (t) => adminLiveConfirmed(t) ? null : 'Type LIVE in capitals to confirm.',
      );
      if (typed == null || !adminLiveConfirmed(typed)) return;
    } else {
      final ok = await confirmAction(
        context,
        title: 'Switch to TEST mode?',
        message: 'New orders use the Razorpay test keys and no real money is taken. Riders cannot really pay while this is on.',
        confirmLabel: 'Switch to TEST',
      );
      if (!ok) return;
    }
    if (!mounted) return;
    setState(() => _busy = 'mode');
    try {
      final res = await context.read<ApiClient>().put('/admin/payment-gateway', {'mode': next});
      if (!mounted) return;
      if (res is Map) _data = Map<String, dynamic>.from(res)..remove('success');
      adminSnack(context, 'Payments are now in ${next.toUpperCase()} mode.');
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _saveKeys(String mode) async {
    final k = _keys[mode]!;
    if (k.isEmpty) {
      adminSnack(context, 'Type at least one value. Blank fields keep what is saved.', error: true);
      return;
    }
    setState(() => _busy = 'save:$mode');
    try {
      final res = await context.read<ApiClient>().put('/admin/payment-gateway', {mode: k.toJson()});
      if (!mounted) return;
      k.clear(); // never keep secrets on screen
      if (res is Map) _data = Map<String, dynamic>.from(res)..remove('success');
      adminSnack(context, '${mode.toUpperCase()} keys saved.');
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _testKeys(String mode) async {
    setState(() => _busy = 'test:$mode');
    try {
      final res = await context.read<ApiClient>().post('/admin/payment-gateway/test', {'mode': mode});
      if (!mounted) return;
      final ok = res is Map && (res['ok'] == true || res['success'] == true);
      adminSnack(context, ok ? 'Razorpay accepted the ${mode.toUpperCase()} keys.' : (res is Map ? res['error']?.toString() ?? 'Test failed.' : 'Test failed.'), error: !ok);
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final live = _mode == 'live';
    return AdminTabBody(
      loading: _loading,
      hasData: _data != null,
      error: _error,
      onRefresh: _load,
      children: [
        const SizedBox(height: 4),
        AdminCard(
          warning: _data?['paymentsEnabled'] == false,
          child: Row(
            children: [
              AdminRowIcon(
                _data?['paymentsEnabled'] != false ? Icons.payments_rounded : Icons.lock_open_rounded,
                color: _data?['paymentsEnabled'] != false ? AppTheme.accentText : AppTheme.warnText,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _data?['paymentsEnabled'] != false
                          ? 'Payment Screen: ON (Plan-Based)'
                          : 'Payment Screen: OFF (Free Mode)',
                      style: AppText.title,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _data?['paymentsEnabled'] != false
                          ? 'Features are gated by plan tiers. Payment screens and checkout are active.'
                          : 'Payment screen is OFF. All features across all tiers are unlocked freely for all riders.',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch.adaptive(
                value: _data?['paymentsEnabled'] != false,
                activeColor: AppTheme.accentText,
                onChanged: _busy != null
                    ? null
                    : (val) async {
                        final api = context.read<ApiClient>();
                        final planSub = context.read<PlanSubscriptionService>();
                        setState(() => _busy = 'payments');
                        try {
                          final res = await api.put('/admin/payment-gateway', {'paymentsEnabled': val});
                          if (!context.mounted) return;
                          if (res is Map) _data = Map<String, dynamic>.from(res)..remove('success');
                          planSub.setPaymentsEnabled(val).ignore();
                          adminSnack(context, val ? 'Payment screen and plan gating enabled.' : 'Payment screen turned OFF (All features unlocked).');
                        } catch (e) {
                          if (!context.mounted) return;
                          adminSnack(context, adminErrorOf(e), error: true);
                        }
                        if (mounted) setState(() => _busy = null);
                      },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AdminCard(
          warning: !live,
          child: Row(
            children: [
              AdminRowIcon(live ? Icons.bolt_rounded : Icons.science_outlined, color: live ? AppTheme.accentText : AppTheme.warnText),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(live ? 'LIVE: riders pay real money' : 'TEST: no real money is taken', style: AppText.title),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (adminEpoch(_data?['updatedAt']) > 0) 'Changed ${adminDate(_data?['updatedAt'], time: true)}',
                        if ((_data?['updatedBy']?.toString() ?? '').isNotEmpty) 'by ${_data?['updatedBy']}',
                      ].join(' '),
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        DsButton(
          label: _busy == 'mode' ? 'Switching…' : (live ? 'Switch to TEST mode' : 'Switch to LIVE mode'),
          icon: live ? Icons.science_outlined : Icons.bolt_rounded,
          tone: live ? DsButtonTone.outline : DsButtonTone.warn,
          onPressed: _busy != null ? null : _switchMode,
        ),
        for (final mode in const ['live', 'test']) ...[
          const SizedBox(height: 16),
          _keysCard(mode),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _keysCard(String mode) {
    final v = _view(mode);
    final k = _keys[mode]!;
    final keyId = v['keyId']?.toString() ?? '';
    final source = v['source']?.toString() ?? '';
    String saved(Object? set) => set == true ? 'saved' : 'not set';
    return AdminTitledCard(
      title: '${mode == 'live' ? 'Live' : 'Test'} keys',
      trailing: AdminModeBadge(mode == 'live' ? 'LIVE' : 'TEST'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AdminDetailLine('Key id', keyId.isEmpty ? 'not set' : keyId),
          AdminDetailLine('Key secret', saved(v['keySecretSet']), color: v['keySecretSet'] == true ? null : AppTheme.warnText),
          AdminDetailLine('Webhook secret', saved(v['webhookSecretSet']), color: v['webhookSecretSet'] == true ? null : AppTheme.warnText),
          if (source.isNotEmpty) AdminDetailLine('Source', source),
          const SizedBox(height: 12),
          Text('Change keys (blank keeps what is saved)', style: AppText.label.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          TextField(
            controller: k.keyId,
            autocorrect: false,
            enableSuggestions: false,
            decoration: adminInput('Key id', hint: 'rzp_${mode}_…'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: k.keySecret,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: adminInput('Key secret', hint: v['keySecretSet'] == true ? 'saved, type to replace' : 'not set'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: k.webhookSecret,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: adminInput('Webhook secret', hint: v['webhookSecretSet'] == true ? 'saved, type to replace' : 'not set'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DsButton(
                  label: _busy == 'save:$mode' ? 'Saving…' : 'Save',
                  icon: Icons.save_rounded,
                  height: 48,
                  fontSize: 14,
                  onPressed: _busy != null ? null : () => _saveKeys(mode),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DsButton(
                  label: _busy == 'test:$mode' ? 'Testing…' : 'Test keys',
                  icon: Icons.verified_rounded,
                  height: 48,
                  fontSize: 14,
                  tone: DsButtonTone.outline,
                  onPressed: _busy != null ? null : () => _testKeys(mode),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ======================================================================
// Audit
// ======================================================================

/// `GET /admin/audit?limit=`: who changed what in payments and plans.
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
