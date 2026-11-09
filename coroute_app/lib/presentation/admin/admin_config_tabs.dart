import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/membership_service.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

// Pricing, Gateway and Audit tabs of "Payments & Plans".

// ======================================================================
// Pricing
// ======================================================================

/// "Plans & Coupons": the plans from `GET/PUT /admin/membership/catalog`. Community is free for
/// every rider (solo rides) and never sold: only its description and feature list are edited.
/// Small Group and Large Group are paid: price, seats, duration, description, features and whether
/// each is on sale. The legacy tiers and the retired ₹9 Individual plan are not edited here.
class AdminPricingTab extends StatefulWidget {
  const AdminPricingTab({super.key});

  @override
  State<AdminPricingTab> createState() => _AdminPricingTabState();
}

/// One membership plan of the catalog being edited.
class _MemControllers {
  final TextEditingController name = TextEditingController();
  final TextEditingController price = TextEditingController();
  final TextEditingController capacity = TextEditingController();
  final TextEditingController days = TextEditingController();
  final TextEditingController description = TextEditingController();
  final TextEditingController features = TextEditingController();
  bool active = true;

  void dispose() {
    name.dispose();
    price.dispose();
    capacity.dispose();
    days.dispose();
    description.dispose();
    features.dispose();
  }
}

/// Lines of [text] as a list of features (blank lines dropped, at most 20).
List<String> _featureLines(String text) =>
    text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).take(20).toList();

class _AdminPricingTabState extends State<AdminPricingTab> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _loaded = false;
  String? _error;
  /// The membership catalog as stored (every field kept on save) and its form.
  Map<String, Map<String, dynamic>> _catalog = {};
  final Map<String, _MemControllers> _mem = {};
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
    for (final c in _mem.values) {
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
      {
        final api = context.read<ApiClient>();
        final memRes = await api.get('/admin/membership/catalog');
        final catsRaw = memRes is Map ? memRes['catalog'] : null;
        if (catsRaw is Map) {
          final next = <String, Map<String, dynamic>>{};
          for (final e in catsRaw.entries) {
            if (e.value is! Map) continue;
            final id = e.key.toString();
            // Only the plans riders can buy (a stored legacy entry is never shown or saved back).
            if (!adminMembershipPlanNames.containsKey(id)) continue;
            final cat = Map<String, dynamic>.from(e.value as Map);
            next[id] = cat;
            final c = _mem.putIfAbsent(id, _MemControllers.new);
            c.name.text = cat['name']?.toString() ?? id;
            c.price.text = adminNumOrNull(cat['monthlyPriceInr'])?.toString() ?? '';
            c.capacity.text = adminNumOrNull(cat['capacity'])?.toInt().toString() ?? '1';
            c.days.text = adminNumOrNull(cat['billingPeriodDays'])?.toInt().toString() ?? '30';
            c.description.text = cat['description']?.toString() ?? '';
            final f = cat['features'];
            c.features.text = f is List ? f.map((x) => x.toString()).join('\n') : '';
            c.active = cat['isActive'] != false;
          }
          _catalog = next;
        }
      }
      _loaded = true;
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return AdminTabBody(
      loading: _loading,
      hasData: _loaded,
      error: _error,
      onRefresh: _load,
      children: [
        const SizedBox(height: 4),
        _buildMembershipSection(),
        const SizedBox(height: 24),
      ],
    );
  }

  Future<void> _saveMembership() async {
    // Every plan keeps its stored fields (entitlements, description...); the form changes
    // the name, price, capacity, duration, features and whether it is on sale.
    final catalog = <String, dynamic>{};
    for (final e in _catalog.entries) {
      final c = _mem[e.key];
      if (c == null) continue;
      if (e.key == 'community') {
        // Community is free with one seat (the server keeps it so): only the words change.
        catalog[e.key] = <String, dynamic>{
          ...e.value,
          'description': c.description.text.trim(),
          'features': _featureLines(c.features.text),
        };
        continue;
      }
      final price = num.tryParse(c.price.text.trim());
      final cap = int.tryParse(c.capacity.text.trim());
      final days = int.tryParse(c.days.text.trim());
      final name = c.name.text.trim();
      String? problem;
      if (name.isEmpty) problem = 'Every plan needs a name.';
      if (price == null || price < 0) problem = '$name: the price must be ₹0 or more.';
      if (cap == null || cap < 1) problem = '$name: the seats must be 1 or more.';
      if (days == null || days < 1 || days > 3660) problem = '$name: the duration must be 1 to 3660 days.';
      if (problem != null) {
        adminSnack(context, problem, error: true);
        return;
      }
      final current = e.value;
      catalog[e.key] = <String, dynamic>{
        ...current,
        'id': current['id'] ?? e.key,
        'name': name,
        'monthlyPriceInr': price,
        'capacity': cap,
        if (current['maxCapacity'] != null) 'maxCapacity': cap,
        'billingPeriodDays': days,
        'description': c.description.text.trim(),
        'features': _featureLines(c.features.text),
        'isActive': c.active,
      };
    }
    if (catalog.isEmpty) return;
    setState(() => _savingMembership = true);
    try {
      await context.read<ApiClient>().put('/admin/membership/catalog', {'catalog': catalog});
      if (mounted) adminSnack(context, 'Membership plans saved.');
      _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    } finally {
      if (mounted) setState(() => _savingMembership = false);
    }
  }

  Widget _buildMembershipSection() {
    return AdminTitledCard(
      title: 'Plans',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Community is free for every rider (solo rides, every safety feature). Small Group and Large Group are paid: '
            'price, seats (riders the trip owner can bring, trip owner included), how long it lasts, what it includes and whether it is on sale. '
            'Plans that are off sale are hidden from riders and refused at checkout. Joining someone\'s ride is always free.',
            style: AppText.caption.copyWith(height: 1.4),
          ),
          if (_catalog.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text('No membership plans loaded.', style: AppText.body.copyWith(color: AppTheme.text2)),
            ),
          for (final id in _catalog.keys)
            if (_mem[id] != null) ...[
              const SizedBox(height: 16),
              _memCategoryRow(id, _mem[id]!),
            ],
          const SizedBox(height: 16),
          DsButton(
            label: _savingMembership ? 'Saving...' : 'Save membership plans',
            icon: Icons.save_rounded,
            onPressed: _savingMembership || _catalog.isEmpty ? null : _saveMembership,
          ),
        ],
      ),
    );
  }

  Widget _memCategoryRow(String id, _MemControllers c) {
    if (id == 'community') return _communityRow(c);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DsSwitchRow(
          label: c.name.text.isEmpty ? id : c.name.text,
          subtitle: c.active ? 'On sale' : 'Off sale',
          value: c.active,
          onChanged: (v) => setState(() => c.active = v),
          divider: false,
        ),
        TextField(controller: c.name, decoration: adminInput('Name shown to riders')),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: c.price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: adminInput('Price a month', prefix: '₹ '),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: c.capacity,
                keyboardType: TextInputType.number,
                decoration: adminInput('Seats (trip owner incl.)'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: c.days,
                keyboardType: TextInputType.number,
                decoration: adminInput('Days'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: c.description,
          minLines: 1,
          maxLines: 3,
          decoration: adminInput('Description'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: c.features,
          minLines: 2,
          maxLines: 6,
          decoration: adminInput('Features', helper: 'One per line.'),
        ),
      ],
    );
  }

  /// Community: free, one seat, never sold; the admin edits only what riders read about it.
  Widget _communityRow(_MemControllers c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(c.name.text.isEmpty ? 'Community' : c.name.text, style: AppText.title)),
            Text('Free · solo rides', style: AppText.label.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        Text('Every rider has it. Not sold, so no price, seats or on-sale switch.', style: AppText.caption),
        const SizedBox(height: 10),
        TextField(
          controller: c.description,
          minLines: 1,
          maxLines: 3,
          decoration: adminInput('Description'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: c.features,
          minLines: 2,
          maxLines: 8,
          decoration: adminInput('Features', helper: 'One per line.'),
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
                      _data?['paymentsEnabled'] != false ? 'Plans are sold' : 'Free mode: no plans sold',
                      style: AppText.title,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _data?['paymentsEnabled'] != false
                          ? 'Riders buy a group plan to host group rides.'
                          : 'Checkout is off and every rider can host a group ride.',
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
                        final membership = context.read<MembershipService?>();
                        final ok = await confirmAction(
                          context,
                          title: val ? 'Start selling plans?' : 'Turn on free mode?',
                          message: val
                              ? 'Riders need a group plan again to host a group ride. Rides already running keep their seats.'
                              : 'Checkout stops and every rider can host a group ride for free until you turn plans back on.',
                          confirmLabel: val ? 'Sell plans' : 'Free mode',
                        );
                        if (!ok || !mounted) return;
                        setState(() => _busy = 'payments');
                        try {
                          final res = await api.put('/admin/payment-gateway', {'paymentsEnabled': val});
                          if (!context.mounted) return;
                          if (res is Map) _data = Map<String, dynamic>.from(res)..remove('success');
                          membership?.fetchMyMembership().ignore();
                          adminSnack(context, val ? 'Plans are on sale again.' : 'Free mode is on.');
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
          Text('Change keys (blank keeps what is saved)', style: AppText.label.copyWith(fontWeight: FontWeight.w600)),
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
