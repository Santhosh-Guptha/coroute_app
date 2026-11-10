import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import 'admin_nav.dart';
import 'admin_ui.dart';

/// 3.55 admin: app log bundles riders sent (docs/features_355/diagnostics_logs.md).
/// System › Diagnostics, or one rider's logs from the rider detail ("App logs").
///
/// GET /api/admin/diag-logs?username=&userId=&build=&reason=&days=, GET /api/admin/diag-logs/:id
/// (summary), GET /api/admin/diag-logs/:id/lines?cat=&level=&offset=&limit=, GET
/// /api/admin/diag-logs/:id/download (gzip), DELETE /api/admin/diag-logs/:id. Every view and
/// download is recorded in the audit log by the gateway.
class AdminDiagLogsScreen extends StatefulWidget {
  /// Only this rider's logs (from the rider detail); null = every rider (System › Diagnostics).
  final String? userId;
  final String? title;
  const AdminDiagLogsScreen({super.key, this.userId, this.title});

  @override
  State<AdminDiagLogsScreen> createState() => _AdminDiagLogsScreenState();
}

class _AdminDiagLogsScreenState extends State<AdminDiagLogsScreen> {
  final _username = TextEditingController();
  final _build = TextEditingController();
  String _reason = '';
  int _days = 7;
  List<Map<String, dynamic>> _logs = const [];
  bool _loading = true;
  String? _error;

  static const _reasons = {'': 'Any reason', 'manual': 'Sent by rider', 'safety_prompt': 'After a safety moment', 'admin_request': 'Asked by admin'};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _username.dispose();
    _build.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final q = <String, String>{
      'days': '$_days',
      if (widget.userId != null) 'userId': widget.userId!,
      if (_username.text.trim().isNotEmpty) 'username': _username.text.trim(),
      if (_build.text.trim().isNotEmpty) 'build': _build.text.trim(),
      if (_reason.isNotEmpty) 'reason': _reason,
    };
    final query = q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    try {
      final res = await context.read<ApiClient>().get('/admin/diag-logs?$query', timeout: const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _logs = res is Map && res['logs'] is List ? (res['logs'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : const [];
        _error = null;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  static String _size(num b) => b < 1024 * 1024 ? '${(b / 1024).toStringAsFixed(0)} KB' : '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  static String _date(num? ms) => ms == null || ms <= 0 ? '-' : DateFormat('d MMM, HH:mm').format(DateTime.fromMillisecondsSinceEpoch(ms.toInt()));

  @override
  Widget build(BuildContext context) {
    final standalone = widget.userId != null;
    return AdminShell(
      title: widget.title ?? 'Diagnostics',
      subtitle: '${_logs.length} app logs · kept 30 days',
      onBack: () => Navigator.maybePop(context),
      nav: standalone ? const [] : adminNavItems(context, AdminPage.diagnostics),
      tabs: standalone ? const [] : adminSectionTabs(context, AdminPage.diagnostics),
      actions: [AdminIconAction(icon: Icons.refresh_rounded, label: 'Refresh', onTap: _load)],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            children: [
              if (!standalone) ...[
                TextField(
                  controller: _username,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.search_rounded)),
                  onSubmitted: (_) => _load(),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: _build,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(labelText: 'Build (e.g. 3.55.0+10020)', prefixIcon: Icon(Icons.numbers_rounded)),
                onSubmitted: (_) => _load(),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _reasons.entries)
                    ChoiceChip(label: Text(e.value), selected: _reason == e.key, onSelected: (_) {
                      setState(() => _reason = e.key);
                      _load();
                    }),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final d in const [1, 7, 30])
                    ChoiceChip(label: Text(d == 1 ? 'Last 24 h' : 'Last $d days'), selected: _days == d, onSelected: (_) {
                      setState(() => _days = d);
                      _load();
                    }),
                ],
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else if (_error != null)
                AdminCard(warning: true, child: Text(_error!, style: AppText.body))
              else if (_logs.isEmpty)
                AdminCard(child: Text('No app logs in this period.', style: AppText.body))
              else
                AdminCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(
                    children: [
                      for (var i = 0; i < _logs.length; i++)
                        AdminRow(
                          leading: AdminRowIcon(_logs[i]['reason'] == 'safety_prompt' ? Icons.health_and_safety_outlined : Icons.description_outlined),
                          title: '${_logs[i]['username'] ?? 'Rider'} · ${_reasons[_logs[i]['reason']] ?? _logs[i]['reason']}',
                          subtitle: '${_date(_logs[i]['at'] as num?)} · ${_logs[i]['build'] ?? '-'} · ${_logs[i]['device'] ?? ''} Android ${_logs[i]['os'] ?? '?'}',
                          detail: '${_size((_logs[i]['bytes'] as num?) ?? 0)} · ${_logs[i]['lines'] ?? 0} lines · ${_logs[i]['errors'] ?? 0} errors${_logs[i]['rideId'] != null ? ' · ride ${_logs[i]['rideId']}' : ''}',
                          divider: i < _logs.length - 1,
                          onTap: () async {
                            final deleted = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => AdminDiagLogViewer(log: _logs[i])));
                            if (deleted == true) _load();
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One log bundle: summary by category, then the lines with a category / level filter.
class AdminDiagLogViewer extends StatefulWidget {
  final Map<String, dynamic> log;
  const AdminDiagLogViewer({super.key, required this.log});

  @override
  State<AdminDiagLogViewer> createState() => _AdminDiagLogViewerState();
}

class _AdminDiagLogViewerState extends State<AdminDiagLogViewer> {
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _lines = [];
  String _cat = '';
  String _level = '';
  int _total = 0;
  bool _loading = true;
  String? _error;

  String get _id => Uri.encodeComponent(widget.log['id'].toString());

  @override
  void initState() {
    super.initState();
    _loadSummary();
    _loadLines(reset: true);
  }

  Future<void> _loadSummary() async {
    try {
      final res = await context.read<ApiClient>().get('/admin/diag-logs/$_id', timeout: const Duration(seconds: 20));
      if (mounted) setState(() => _summary = res is Map && res['summary'] is Map ? Map<String, dynamic>.from(res['summary'] as Map) : null);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _loadLines({bool reset = false}) async {
    setState(() => _loading = true);
    final offset = reset ? 0 : _lines.length;
    final q = 'offset=$offset&limit=500${_cat.isEmpty ? '' : '&cat=$_cat'}${_level.isEmpty ? '' : '&level=$_level'}';
    try {
      final res = await context.read<ApiClient>().get('/admin/diag-logs/$_id/lines?$q', timeout: const Duration(seconds: 30));
      if (!mounted) return;
      final got = res is Map && res['lines'] is List ? (res['lines'] as List).whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : <Map<String, dynamic>>[];
      setState(() {
        _lines = reset ? got : [..._lines, ...got];
        _total = res is Map && res['total'] is num ? (res['total'] as num).toInt() : _lines.length;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  Future<void> _download() async {
    try {
      final bytes = await context.read<ApiClient>().getBytes('/admin/diag-logs/$_id/download');
      final name = 'coroute-diag-${widget.log['id']}.jsonl.gz';
      await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, mimeType: 'application/gzip', name: name)], fileNameOverrides: [name]));
    } on ApiException catch (e) {
      if (mounted) adminSnack(context, e.message, error: true);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmAction(context, title: 'Delete this log?', message: 'The log is deleted for good. This is recorded in the audit log.', confirmLabel: 'Delete', destructive: true);
    if (!ok || !mounted) return;
    try {
      await context.read<ApiClient>().delete('/admin/diag-logs/$_id');
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) adminSnack(context, e.message, error: true);
    }
  }

  Color _colorOf(String? level) => level == 'E'
      ? AppTheme.danger
      : level == 'W'
          ? AppTheme.warnText
          : AppTheme.text;

  static String _time(num? ms) => ms == null ? '' : DateFormat('d MMM HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(ms.toInt()));

  @override
  Widget build(BuildContext context) {
    final cats = _summary?['byCategory'] is Map ? Map<String, dynamic>.from(_summary!['byCategory'] as Map) : const <String, dynamic>{};
    final levels = _summary?['byLevel'] is Map ? Map<String, dynamic>.from(_summary!['byLevel'] as Map) : const <String, dynamic>{};
    return AdminShell(
      title: '${widget.log['username'] ?? 'Rider'}: app log',
      subtitle: '${widget.log['build'] ?? ''} · ${widget.log['device'] ?? ''} · $_total lines',
      onBack: () => Navigator.maybePop(context),
      actions: [
        AdminIconAction(icon: Icons.download_rounded, label: 'Download', onTap: _download),
        AdminIconAction(icon: Icons.delete_outline_rounded, label: 'Delete', onTap: _delete),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          if (_error != null) AdminCard(warning: true, child: Text(_error!, style: AppText.body)),
          if (levels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Errors ${levels['E'] ?? 0} · warnings ${levels['W'] ?? 0} · info ${levels['I'] ?? 0} · debug ${levels['D'] ?? 0}',
                style: AppText.label,
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(label: const Text('Problems'), selected: _level == 'W', onSelected: (_) {
                setState(() => _level = _level == 'W' ? '' : 'W');
                _loadLines(reset: true);
              }),
              ChoiceChip(label: const Text('All'), selected: _cat.isEmpty, onSelected: (_) {
                setState(() => _cat = '');
                _loadLines(reset: true);
              }),
              for (final c in (cats.keys.toList()..sort()))
                ChoiceChip(label: Text('$c ${cats[c]}'), selected: _cat == c, onSelected: (_) {
                  setState(() => _cat = _cat == c ? '' : c);
                  _loadLines(reset: true);
                }),
            ],
          ),
          const SizedBox(height: 12),
          AdminCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final l in _lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: SelectableText(
                      '${_time(l['t'] as num?)} ${l['l'] ?? 'I'} ${l['c'] ?? ''} ${l['e'] ?? ''}${l['f'] is Map ? ' ${(l['f'] as Map).entries.map((e) => '${e.key}=${e.value}').join(' ')}' : ''}',
                      style: AppText.caption.copyWith(color: _colorOf(l['l']?.toString()), fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                if (_lines.isEmpty && !_loading) Text('No lines match.', style: AppText.body),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()))
          else if (_lines.length < _total)
            DsButton(label: 'Load more', tone: DsButtonTone.outline, onPressed: () => _loadLines()),
        ],
      ),
    );
  }
}
