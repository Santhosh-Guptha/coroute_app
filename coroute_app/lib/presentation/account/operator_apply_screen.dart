import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';

/// v3.60 operators in the app: a riding club, tour company or fleet applies to run rides on CoRoute
/// (POST /operators/apply), sees the review status (GET /operators/application) and, once approved, opens the
/// operator console (rosters, rides, live map, attendance, broadcasts) in the browser. Same rules as the website.
class OperatorApplyScreen extends StatefulWidget {
  const OperatorApplyScreen({super.key});

  static const String rowTitle = 'Run a club or tour on CoRoute';
  static const Map<String, String> types = {
    'RIDING_CLUB': 'Riding club',
    'TOUR_OPERATOR': 'Tour operator',
    'RENTAL_FLEET': 'Rental fleet',
    'CORPORATE_FLEET': 'Corporate fleet',
  };

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const OperatorApplyScreen()));

  @override
  State<OperatorApplyScreen> createState() => _OperatorApplyScreenState();
}

class _OperatorApplyScreenState extends State<OperatorApplyScreen> {
  Map<String, dynamic>? _app;
  bool _loading = true;
  bool _editing = false;
  bool _busy = false;
  String? _error;
  Map<String, String> _fieldErrors = const {};
  String _type = 'RIDING_CLUB';
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _website = TextEditingController();
  final _riders = TextEditingController();
  final _about = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final c in [_name, _city, _email, _phone, _website, _riders, _about]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<ApiClient?>();
    if (api == null) return;
    try {
      final res = await api.get('/operators/application');
      final app = res is Map && res['application'] is Map ? Map<String, dynamic>.from(res['application'] as Map) : null;
      if (!mounted) return;
      setState(() {
        _app = app;
        _loading = false;
        _error = null;
        if (app != null) _fill(app);
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.statusCode == 403 ? 'Operator sign-up is closed right now.' : e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not reach CoRoute. Try again.';
        });
      }
    }
  }

  void _fill(Map<String, dynamic> a) {
    _type = OperatorApplyScreen.types.containsKey(a['type']) ? a['type'] as String : _type;
    _name.text = a['name']?.toString() ?? '';
    _city.text = a['city']?.toString() ?? '';
    final c = a['contact'] is Map ? a['contact'] as Map : const {};
    _email.text = c['email']?.toString() ?? '';
    _phone.text = c['phone']?.toString() ?? '';
    _website.text = a['website']?.toString() ?? '';
    _riders.text = a['expectedRiders']?.toString() ?? '';
    _about.text = a['description']?.toString() ?? '';
  }

  Future<void> _submit() async {
    final api = context.read<ApiClient?>();
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _fieldErrors = const {};
    });
    try {
      final res = await api.post('/operators/apply', {
        'type': _type,
        'name': _name.text.trim(),
        'city': _city.text.trim(),
        'email': _email.text.trim(),
        'phone': _phone.text.trim(),
        'website': _website.text.trim(),
        'expectedRiders': int.tryParse(_riders.text.trim()) ?? 0,
        'description': _about.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _app = res is Map && res['application'] is Map ? Map<String, dynamic>.from(res['application'] as Map) : _app;
        _editing = false;
      });
      showAppToast(context, 'Application sent. We will e-mail you after the review.');
    } on ApiException catch (e) {
      if (!mounted) return;
      final fields = <String, String>{};
      final raw = e.body?['fields'];
      if (raw is Map) raw.forEach((k, v) => fields[k.toString()] = v.toString());
      setState(() {
        _error = e.message;
        _fieldErrors = fields;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not send. Try again when you have signal.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openConsole() => launchUrl(Uri.parse('${AppConfig.apiBaseUrl}/operator'), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final app = _app;
    final status = app?['status']?.toString();
    final showForm = !_loading && _error == null && (app == null || _editing);
    return Scaffold(
      appBar: AppBar(title: const Text('Clubs and tours')),
      body: _loading
          ? const Padding(padding: EdgeInsets.all(20), child: SkeletonRows(count: 4))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              children: [
                if (_error != null && !showForm) ErrorState(title: _error!, onRetry: _load),
                if (app != null && !_editing) _statusCard(app, status),
                if (showForm) ..._form(),
              ],
            ),
    );
  }

  Widget _statusCard(Map<String, dynamic> app, String? status) {
    final name = app['name']?.toString() ?? '';
    final (icon, title, line) = switch (status) {
      'APPROVED' => (Icons.verified_rounded, '$name is approved', 'Run your roster, rides, live map, attendance and broadcasts from the operator console.'),
      'REJECTED' => (Icons.info_outline_rounded, 'Not approved yet', (app['reason']?.toString() ?? '').isNotEmpty ? app['reason'].toString() : 'You can change the details and send it again.'),
      'SUSPENDED' => (Icons.pause_circle_outline_rounded, '$name is paused', (app['reason']?.toString() ?? '').isNotEmpty ? app['reason'].toString() : 'Contact CoRoute support to reopen it.'),
      'EXPIRED' => (Icons.schedule_rounded, 'Approval ended', 'Send the application again to continue.'),
      _ => (Icons.hourglass_top_rounded, 'Application sent', 'We review every club and tour company. You will get an e-mail after the review.'),
    };
    return DsCard(
      key: const Key('operator_status_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(icon, color: AppTheme.accentText, size: 28),
            const SizedBox(width: 12),
            Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.title)),
          ]),
          const SizedBox(height: 8),
          Text(line, style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: 16),
          if (status == 'APPROVED')
            DsButton(key: const Key('operator_open_console'), label: 'Open operator console', icon: Icons.open_in_new_rounded, onPressed: _openConsole)
          else if (status == 'REJECTED' || status == 'EXPIRED')
            DsButton(key: const Key('operator_edit'), label: 'Change and send again', onPressed: () => setState(() => _editing = true)),
        ],
      ),
    );
  }

  List<Widget> _form() {
    InputDecoration deco(String label, String field, {String? hint}) => InputDecoration(labelText: label, hintText: hint, errorText: _fieldErrors[field]);
    return [
      Text('Run rides for your club, tour company or fleet: a roster, scheduled rides with a lead and sweeper, a live map with SOS, attendance and broadcasts.',
          style: AppText.body.copyWith(color: AppTheme.text2)),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: const Key('operator_type'),
        initialValue: _type,
        isExpanded: true,
        decoration: deco('Type', 'type'),
        items: [for (final e in OperatorApplyScreen.types.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => setState(() => _type = v ?? _type),
      ),
      const SizedBox(height: 12),
      TextField(key: const Key('operator_name'), controller: _name, maxLength: 80, decoration: deco('Organisation name', 'name')),
      TextField(key: const Key('operator_city'), controller: _city, maxLength: 60, decoration: deco('City', 'city')),
      TextField(key: const Key('operator_email'), controller: _email, keyboardType: TextInputType.emailAddress, decoration: deco('Business e-mail (private)', 'email')),
      const SizedBox(height: 12),
      TextField(key: const Key('operator_phone'), controller: _phone, keyboardType: TextInputType.phone, decoration: deco('Business phone (private)', 'phone')),
      const SizedBox(height: 12),
      TextField(key: const Key('operator_website'), controller: _website, keyboardType: TextInputType.url, decoration: deco('Website or social page (optional)', 'website', hint: 'https://')),
      const SizedBox(height: 12),
      TextField(key: const Key('operator_riders'), controller: _riders, keyboardType: TextInputType.number, decoration: deco('Riders you expect', 'expectedRiders')),
      const SizedBox(height: 12),
      TextField(key: const Key('operator_about'), controller: _about, maxLength: 500, minLines: 3, maxLines: 5, decoration: deco('What rides do you run?', 'description')),
      if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(_error!, style: AppText.label.copyWith(color: AppTheme.warnText))),
      DsButton(key: const Key('operator_submit'), label: _busy ? 'Sending…' : 'Send application', loading: _busy, onPressed: _busy ? null : _submit),
      const SizedBox(height: 8),
      Text('Your e-mail and phone are seen only by you and the CoRoute review team.', style: AppText.caption, textAlign: TextAlign.center),
    ];
  }
}
