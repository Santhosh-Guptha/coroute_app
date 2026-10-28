import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_payments_logic.dart';
import 'admin_payments_widgets.dart';
import 'admin_ui.dart';

// Offers and Coupons tabs of "Payments & Plans".

const int _day = 86400000;

/// Lets the admin pick a day. [endOfDay] returns 23:59:59 of that day.
Future<int?> _pickDay(BuildContext context, int initialMs, {bool endOfDay = false}) async {
  final now = DateTime.now();
  final initial = initialMs > 0 ? DateTime.fromMillisecondsSinceEpoch(initialMs) : now;
  final picked = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(now.year - 2),
    lastDate: DateTime(now.year + 5),
  );
  if (picked == null) return null;
  final d = endOfDay ? DateTime(picked.year, picked.month, picked.day, 23, 59, 59) : DateTime(picked.year, picked.month, picked.day);
  return d.millisecondsSinceEpoch;
}

/// A tappable "label: date" field of the editors.
class _DateField extends StatelessWidget {
  final String label;
  final int value;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  const _DateField({required this.label, required this.value, required this.onTap, this.onClear});

  @override
  Widget build(BuildContext context) {
    final clear = onClear;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: InputDecorator(
        decoration: adminInput(label).copyWith(
          suffixIcon: value > 0 && clear != null
              ? IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded), onPressed: clear)
              : const Icon(Icons.event_rounded),
        ),
        child: Text(value > 0 ? adminDate(value) : 'Not set', style: AppText.body),
      ),
    );
  }
}

/// Live / scheduled / ended / off, from active flag and dates.
StatusTextChip _windowChip({required bool active, required int startsAt, required int endsAt, bool soldOut = false}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  if (!active) return StatusTextChip(icon: Icons.pause_circle_rounded, text: 'Off', color: AppTheme.text2);
  if (soldOut) return StatusTextChip(icon: Icons.block_rounded, text: 'Used up', color: AppTheme.warnText);
  if (startsAt > now) return StatusTextChip(icon: Icons.schedule_rounded, text: 'Starts ${adminDate(startsAt)}', color: AppTheme.warnText);
  if (endsAt > 0 && endsAt < now) return StatusTextChip(icon: Icons.history_rounded, text: 'Ended', color: AppTheme.text2);
  return StatusTextChip(icon: Icons.check_circle_rounded, text: 'Live', color: AppTheme.accentText);
}

// ======================================================================
// Offers
// ======================================================================

/// `GET/POST/PATCH/DELETE /admin/offers[/:id]`. An offer is applied
/// automatically at checkout (or with its coupon code) inside its dates.
class AdminOffersTab extends StatefulWidget {
  const AdminOffersTab({super.key});

  @override
  State<AdminOffersTab> createState() => _AdminOffersTabState();
}

class _AdminOffersTabState extends State<AdminOffersTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _offers = [];
  bool _loading = true;
  bool _loaded = false;
  String? _error;

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
      final res = await context.read<ApiClient>().get('/admin/offers');
      _offers = adminMapList(res is Map ? res['offers'] : res);
      _loaded = true;
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle(Map<String, dynamic> o, bool on) async {
    try {
      await context.read<ApiClient>().patch('/admin/offers/${Uri.encodeComponent(o['id'].toString())}', {'isActive': on});
      if (!mounted) return;
      adminSnack(context, on ? 'Offer switched on.' : 'Offer switched off.');
      _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  Future<void> _edit([Map<String, dynamic>? offer]) async {
    final saved = await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      title: offer == null ? 'New offer' : 'Edit offer',
      builder: (_) => _OfferEditor(offer: offer),
    );
    if (saved == true && mounted) _load();
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
        Text(
          'The best live offer for a plan is applied at checkout automatically; an offer with a coupon code only applies when the rider enters it. A coupon never stacks with an offer.',
          style: AppText.caption,
        ),
        const SizedBox(height: 12),
        AdminTable(
          title: 'Offers (${_offers.length})',
          trailing: TextButton.icon(
            onPressed: () => _edit(),
            icon: Icon(Icons.add_rounded, color: AppTheme.accentText),
            label: Text('New offer', style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w800)),
          ),
          rows: [
            for (var i = 0; i < _offers.length; i++) _offerRow(_offers[i], i == _offers.length - 1),
          ],
          empty: Text('No offers yet.', style: AppText.caption),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _offerRow(Map<String, dynamic> o, bool last) {
    final active = o['isActive'] != false;
    final starts = adminEpoch(o['startsAt']);
    final ends = adminEpoch(o['endsAt']);
    final max = adminNumOrNull(o['maxRedemptions'])?.toInt() ?? 0;
    final used = adminNumOrNull(o['redemptions'])?.toInt() ?? 0;
    final code = o['couponCode']?.toString() ?? '';
    return AdminRow(
      key: ValueKey(o['id']),
      leading: AdminRowIcon(Icons.campaign_outlined, color: active ? null : AppTheme.text2),
      title: o['title']?.toString() ?? 'Offer',
      subtitle: '${adminDiscountLabel(o['discountType'], o['discountValue'])} · ${adminTierLabel(o['planTier'])} · ${adminCycleLabel(o['billingCycle'])}',
      detail: [
        '${adminDate(starts)} → ${ends > 0 ? adminDate(ends) : 'no end'}',
        max > 0 ? '$used / $max used' : '$used used',
        if (code.isNotEmpty) 'code $code' else 'automatic',
        if (o['showOnCheckout'] == false) 'hidden at checkout',
      ].join(' · '),
      status: _windowChip(active: active, startsAt: starts, endsAt: ends, soldOut: max > 0 && used >= max),
      trailing: Switch.adaptive(value: active, onChanged: (v) => _toggle(o, v)),
      divider: !last,
      onTap: () => _edit(o),
    );
  }
}

class _OfferEditor extends StatefulWidget {
  final Map<String, dynamic>? offer;
  const _OfferEditor({this.offer});

  @override
  State<_OfferEditor> createState() => _OfferEditorState();
}

class _OfferEditorState extends State<_OfferEditor> {
  late final Map<String, dynamic> _o = widget.offer ?? const {};
  late final _title = TextEditingController(text: _o['title']?.toString() ?? '');
  late final _description = TextEditingController(text: _o['description']?.toString() ?? '');
  late final _value = TextEditingController(text: adminNumOrNull(_o['discountValue'])?.toString() ?? '');
  late final _code = TextEditingController(text: _o['couponCode']?.toString() ?? '');
  late final _max = TextEditingController(text: '${adminNumOrNull(_o['maxRedemptions'])?.toInt() ?? 0}');
  late String _tier = _o['planTier']?.toString() ?? 'all';
  late String _cycle = _o['billingCycle']?.toString() ?? 'all';
  late String _type = _o['discountType']?.toString() ?? 'percentage';
  late int _startsAt = adminEpoch(_o['startsAt']) > 0 ? adminEpoch(_o['startsAt']) : DateTime.now().millisecondsSinceEpoch;
  late int _endsAt = adminEpoch(_o['endsAt']) > 0 ? adminEpoch(_o['endsAt']) : _startsAt + 30 * _day;
  late bool _active = _o['isActive'] != false;
  late bool _showOnCheckout = _o['showOnCheckout'] != false;
  bool _busy = false;
  String? _problem;

  bool get _isNew => widget.offer == null;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _value.dispose();
    _code.dispose();
    _max.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = num.tryParse(_value.text.trim());
    final max = int.tryParse(_max.text.trim().isEmpty ? '0' : _max.text.trim());
    final problem = _title.text.trim().isEmpty
        ? 'Give the offer a title.'
        : validateDiscount(_type, value) ??
            (max == null || max < 0 ? 'Max redemptions must be 0 (no limit) or more.' : null) ??
            (_endsAt <= _startsAt ? 'The end date must be after the start date.' : null);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final body = <String, dynamic>{
      'title': _title.text.trim(),
      'description': _description.text.trim(),
      'planTier': _tier,
      'billingCycle': _cycle,
      'discountType': _type,
      'discountValue': value,
      'startsAt': _startsAt,
      'endsAt': _endsAt,
      'isActive': _active,
      'showOnCheckout': _showOnCheckout,
      'couponCode': _code.text.trim().isEmpty ? null : _code.text.trim().toUpperCase(),
      'maxRedemptions': max,
    };
    try {
      final api = context.read<ApiClient>();
      if (_isNew) {
        await api.post('/admin/offers', body);
      } else {
        await api.patch('/admin/offers/${Uri.encodeComponent(_o['id'].toString())}', body);
      }
      if (!mounted) return;
      adminSnack(context, _isNew ? 'Offer created.' : 'Offer saved.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = adminErrorOf(e);
        });
      }
    }
  }

  Future<void> _delete() async {
    final ok = await confirmAction(
      context,
      title: 'Delete this offer?',
      message: '"${_title.text.trim()}" stops applying at checkout. Orders that already used it keep their price.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<ApiClient>().delete('/admin/offers/${Uri.encodeComponent(_o['id'].toString())}');
      if (!mounted) return;
      adminSnack(context, 'Offer deleted.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = adminErrorOf(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _problem;
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(controller: _title, maxLength: 120, decoration: adminInput('Title', hint: 'Monsoon sale')),
          const SizedBox(height: 4),
          TextField(controller: _description, maxLines: 2, maxLength: 500, decoration: adminInput('Description (shown at checkout)')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _tier,
            decoration: adminInput('Plan'),
            items: [
              const DropdownMenuItem(value: 'all', child: Text('All paid plans')),
              for (final t in adminPaidTierNames) DropdownMenuItem(value: t, child: Text(adminTierLabel(t))),
            ],
            onChanged: (v) => setState(() => _tier = v ?? 'all'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _cycle,
            decoration: adminInput('Billing'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Monthly and annual')),
              DropdownMenuItem(value: 'monthly', child: Text('Monthly only')),
              DropdownMenuItem(value: 'annual', child: Text('Annual only')),
            ],
            onChanged: (v) => setState(() => _cycle = v ?? 'all'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: adminInput('Discount'),
                  items: const [
                    DropdownMenuItem(value: 'percentage', child: Text('% off')),
                    DropdownMenuItem(value: 'fixed', child: Text('₹ off')),
                    DropdownMenuItem(value: 'price', child: Text('Fixed price')),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'percentage'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _value,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: adminInput(_type == 'percentage' ? 'Percent' : 'Rupees', prefix: _type == 'percentage' ? null : '₹ ', suffix: _type == 'percentage' ? '%' : null),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Starts',
                  value: _startsAt,
                  onTap: () async {
                    final v = await _pickDay(context, _startsAt);
                    if (v != null && mounted) setState(() => _startsAt = v);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateField(
                  label: 'Ends',
                  value: _endsAt,
                  onTap: () async {
                    final v = await _pickDay(context, _endsAt, endOfDay: true);
                    if (v != null && mounted) setState(() => _endsAt = v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: adminInput('Coupon code (optional)', helper: 'Empty: applied automatically. Set: only with this code.'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _max,
            keyboardType: TextInputType.number,
            decoration: adminInput('Max redemptions', helper: '0 = no limit${_isNew ? '' : ' · ${adminNumOrNull(_o['redemptions'])?.toInt() ?? 0} used so far'}'),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Active'),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _showOnCheckout,
            onChanged: (v) => setState(() => _showOnCheckout = v),
            title: const Text('Show on the plans page and checkout'),
          ),
          if (p != null) ...[
            const SizedBox(height: 4),
            Text(p, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 12),
          DsButton(label: _busy ? 'Saving…' : (_isNew ? 'Create offer' : 'Save offer'), icon: Icons.save_rounded, onPressed: _busy ? null : _save),
          if (!_isNew) ...[
            const SizedBox(height: 8),
            DsButton(label: 'Delete offer', icon: Icons.delete_outline_rounded, tone: DsButtonTone.outline, onPressed: _busy ? null : _delete),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ======================================================================
// Coupons
// ======================================================================

List<String> _stringList(Object? v) => v is List ? v.map((e) => e.toString()).toList() : const <String>[];

/// `GET/POST/PATCH/DELETE /admin/coupons[/:code]`.
class AdminCouponsTab extends StatefulWidget {
  const AdminCouponsTab({super.key});

  @override
  State<AdminCouponsTab> createState() => _AdminCouponsTabState();
}

class _AdminCouponsTabState extends State<AdminCouponsTab> with AutomaticKeepAliveClientMixin {
  List<Map<String, dynamic>> _coupons = [];
  bool _loading = true;
  bool _loaded = false;
  String? _error;

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
      final res = await context.read<ApiClient>().get('/admin/coupons');
      _coupons = adminMapList(res is Map ? res['coupons'] : res);
      _loaded = true;
    } catch (e) {
      _error = adminErrorOf(e);
      if (mounted && _loaded) adminSnack(context, _error!, error: true);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _toggle(Map<String, dynamic> c, bool on) async {
    final code = c['code']?.toString() ?? '';
    try {
      await context.read<ApiClient>().patch('/admin/coupons/${Uri.encodeComponent(code)}', {'isActive': on});
      if (!mounted) return;
      adminSnack(context, 'Coupon $code ${on ? 'switched on' : 'switched off'}.');
      _load();
    } catch (e) {
      if (mounted) adminSnack(context, adminErrorOf(e), error: true);
    }
  }

  Future<void> _edit([Map<String, dynamic>? coupon]) async {
    final saved = await showAppSheet<bool>(
      context,
      isScrollControlled: true,
      title: coupon == null ? 'New coupon' : 'Coupon ${coupon['code']}',
      builder: (_) => _CouponEditor(coupon: coupon),
    );
    if (saved == true && mounted) _load();
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
        AdminTable(
          title: 'Coupons (${_coupons.length})',
          trailing: TextButton.icon(
            onPressed: () => _edit(),
            icon: Icon(Icons.add_rounded, color: AppTheme.accentText),
            label: Text('New coupon', style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w800)),
          ),
          rows: [
            for (var i = 0; i < _coupons.length; i++) _couponRow(_coupons[i], i == _coupons.length - 1),
          ],
          empty: Text('No coupons yet.', style: AppText.caption),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _couponRow(Map<String, dynamic> c, bool last) {
    final active = c['isActive'] != false;
    final used = adminNumOrNull(c['usageCount'])?.toInt() ?? 0;
    final max = adminNumOrNull(c['maxUsageTotal'])?.toInt() ?? 0;
    final perUser = adminNumOrNull(c['maxUsagePerUser'])?.toInt() ?? 1;
    final tiers = _stringList(c['applicableTiers']);
    final cycles = _stringList(c['applicableCycles']);
    final minOrder = adminNumOrNull(c['minOrderAmount']) ?? 0;
    return AdminRow(
      key: ValueKey(c['code']),
      leading: AdminRowIcon(Icons.discount_outlined, color: active ? null : AppTheme.text2),
      title: c['code']?.toString() ?? '',
      subtitle: [
        adminDiscountLabel(c['discountType'], c['discountValue']),
        if ((c['description']?.toString() ?? '').isNotEmpty) c['description'].toString(),
      ].join(' · '),
      detail: [
        tiers.isEmpty || tiers.contains('all') ? 'All plans' : tiers.map(adminTierLabel).join(', '),
        cycles.isEmpty || cycles.contains('all') ? 'any cycle' : cycles.map(adminCycleLabel).join(', '),
        max > 0 ? '$used / $max used' : '$used used',
        '$perUser per rider',
        if (minOrder > 0) 'min ${adminInr(minOrder)}',
        'until ${adminDate(c['expiresAt'])}',
      ].join(' · '),
      status: _windowChip(
        active: active,
        startsAt: adminEpoch(c['validFrom']),
        endsAt: adminEpoch(c['expiresAt']),
        soldOut: max > 0 && used >= max,
      ),
      trailing: Switch.adaptive(value: active, onChanged: (v) => _toggle(c, v)),
      divider: !last,
      onTap: () => _edit(c),
    );
  }
}

class _CouponEditor extends StatefulWidget {
  final Map<String, dynamic>? coupon;
  const _CouponEditor({this.coupon});

  @override
  State<_CouponEditor> createState() => _CouponEditorState();
}

class _CouponEditorState extends State<_CouponEditor> {
  late final Map<String, dynamic> _c = widget.coupon ?? const {};
  late final _code = TextEditingController(text: _c['code']?.toString() ?? '');
  late final _description = TextEditingController(text: _c['description']?.toString() ?? '');
  late final _value = TextEditingController(text: adminNumOrNull(_c['discountValue'])?.toString() ?? '');
  late final _maxTotal = TextEditingController(text: '${adminNumOrNull(_c['maxUsageTotal'])?.toInt() ?? 100}');
  late final _maxPerUser = TextEditingController(text: '${adminNumOrNull(_c['maxUsagePerUser'])?.toInt() ?? 1}');
  late final _minOrder = TextEditingController(text: '${adminNumOrNull(_c['minOrderAmount']) ?? 0}');
  late String _type = _c['discountType']?.toString() ?? 'percentage';
  late final Set<String> _tiers = {
    for (final t in _stringList(_c['applicableTiers']))
      if (t != 'all') t,
  };
  late String _cycle = () {
    final cycles = _stringList(_c['applicableCycles']);
    return cycles.length == 1 && cycles.first != 'all' ? cycles.first : 'all';
  }();
  late int _validFrom = adminEpoch(_c['validFrom']) > 0 ? adminEpoch(_c['validFrom']) : DateTime.now().millisecondsSinceEpoch;
  late int _expiresAt = adminEpoch(_c['expiresAt']) > 0 ? adminEpoch(_c['expiresAt']) : DateTime.now().millisecondsSinceEpoch + 30 * _day;
  late bool _active = _c['isActive'] != false;
  bool _busy = false;
  String? _problem;

  bool get _isNew => widget.coupon == null;
  String get _codePath => Uri.encodeComponent(_c['code']?.toString() ?? '');

  @override
  void dispose() {
    _code.dispose();
    _description.dispose();
    _value.dispose();
    _maxTotal.dispose();
    _maxPerUser.dispose();
    _minOrder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _code.text.trim().toUpperCase();
    final value = _type == 'free' ? 100 : num.tryParse(_value.text.trim());
    final maxTotal = int.tryParse(_maxTotal.text.trim());
    final maxPerUser = int.tryParse(_maxPerUser.text.trim());
    final minOrder = num.tryParse(_minOrder.text.trim().isEmpty ? '0' : _minOrder.text.trim());
    String? problem;
    if (_isNew && !RegExp(r'^[A-Z0-9_-]{3,32}$').hasMatch(code)) {
      problem = 'The code needs 3 to 32 letters, digits, - or _.';
    } else {
      problem = validateDiscount(_type, value);
    }
    problem ??= (maxTotal == null || maxTotal < 1) ? 'Total uses must be 1 or more.' : null;
    problem ??= (maxPerUser == null || maxPerUser < 1) ? 'Uses per rider must be 1 or more.' : null;
    problem ??= (minOrder == null || minOrder < 0) ? 'The minimum order must be ₹0 or more.' : null;
    problem ??= _expiresAt <= _validFrom ? 'The expiry must be after the start date.' : null;
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final body = <String, dynamic>{
      if (_isNew) 'code': code,
      'description': _description.text.trim(),
      'discountType': _type,
      'discountValue': value,
      'applicableTiers': _tiers.isEmpty ? ['all'] : _tiers.toList(),
      'applicableCycles': [_cycle],
      'maxUsageTotal': maxTotal,
      'maxUsagePerUser': maxPerUser,
      'validFrom': _validFrom,
      'expiresAt': _expiresAt,
      'isActive': _active,
      'minOrderAmount': minOrder,
    };
    try {
      final api = context.read<ApiClient>();
      if (_isNew) {
        await api.post('/admin/coupons', body);
      } else {
        await api.patch('/admin/coupons/$_codePath', body);
      }
      if (!mounted) return;
      adminSnack(context, _isNew ? 'Coupon $code created.' : 'Coupon saved.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = adminErrorOf(e);
        });
      }
    }
  }

  Future<void> _delete() async {
    final code = _c['code']?.toString() ?? '';
    final ok = await confirmAction(
      context,
      title: 'Delete coupon $code?',
      message: 'Riders can no longer use it. Orders that already used it keep their price.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<ApiClient>().delete('/admin/coupons/$_codePath');
      if (!mounted) return;
      adminSnack(context, 'Coupon $code deleted.');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = adminErrorOf(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _problem;
    final used = adminNumOrNull(_c['usageCount'])?.toInt() ?? 0;
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _code,
            enabled: _isNew,
            textCapitalization: TextCapitalization.characters,
            decoration: adminInput('Code', hint: 'MONSOON25', helper: _isNew ? null : 'The code cannot be changed. Used $used times.'),
          ),
          const SizedBox(height: 12),
          TextField(controller: _description, decoration: adminInput('Description')),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: adminInput('Discount'),
                  items: const [
                    DropdownMenuItem(value: 'percentage', child: Text('% off')),
                    DropdownMenuItem(value: 'fixed', child: Text('₹ off')),
                    DropdownMenuItem(value: 'free', child: Text('Free pass')),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'percentage'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _value,
                  enabled: _type != 'free',
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: adminInput(
                    _type == 'percentage' ? 'Percent' : (_type == 'free' ? '100% off' : 'Rupees'),
                    prefix: _type == 'fixed' ? '₹ ' : null,
                    suffix: _type == 'percentage' ? '%' : null,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('Plans', style: AppText.label.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              FilterChip(
                label: const Text('All plans'),
                selected: _tiers.isEmpty,
                onSelected: (_) => setState(_tiers.clear),
              ),
              for (final t in adminPaidTierNames)
                FilterChip(
                  label: Text(adminTierLabel(t)),
                  selected: _tiers.contains(t),
                  onSelected: (on) => setState(() => on ? _tiers.add(t) : _tiers.remove(t)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _cycle,
            decoration: adminInput('Billing'),
            items: const [
              DropdownMenuItem(value: 'all', child: Text('Monthly and annual')),
              DropdownMenuItem(value: 'monthly', child: Text('Monthly only')),
              DropdownMenuItem(value: 'annual', child: Text('Annual only')),
            ],
            onChanged: (v) => setState(() => _cycle = v ?? 'all'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: TextField(controller: _maxTotal, keyboardType: TextInputType.number, decoration: adminInput('Total uses'))),
              const SizedBox(width: 12),
              Expanded(child: TextField(controller: _maxPerUser, keyboardType: TextInputType.number, decoration: adminInput('Per rider'))),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _minOrder,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: adminInput('Minimum order', prefix: '₹ ', helper: 'Plan price before the discount; 0 = any.'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Valid from',
                  value: _validFrom,
                  onTap: () async {
                    final v = await _pickDay(context, _validFrom);
                    if (v != null && mounted) setState(() => _validFrom = v);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateField(
                  label: 'Expires',
                  value: _expiresAt,
                  onTap: () async {
                    final v = await _pickDay(context, _expiresAt, endOfDay: true);
                    if (v != null && mounted) setState(() => _expiresAt = v);
                  },
                ),
              ),
            ],
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Active'),
          ),
          if (p != null) ...[
            const SizedBox(height: 4),
            Text(p, style: AppText.caption.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 12),
          DsButton(label: _busy ? 'Saving…' : (_isNew ? 'Create coupon' : 'Save coupon'), icon: Icons.save_rounded, onPressed: _busy ? null : _save),
          if (!_isNew) ...[
            const SizedBox(height: 8),
            DsButton(label: 'Delete coupon', icon: Icons.delete_outline_rounded, tone: DsButtonTone.outline, onPressed: _busy ? null : _delete),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
